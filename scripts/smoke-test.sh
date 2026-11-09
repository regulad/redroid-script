#!/usr/bin/env bash
# Boots an image and checks what it was built to have.
#
#   scripts/smoke-test.sh <image> <native_bridge> <android>
#
# <native_bridge> is that platform's value in matrix.json (none, builtin or
# houdini), and <android> the image's redroid variant (used in messages).
#
# The image runs on a Docker host whose kernel has binder and ashmem. That is
# this machine, or, with SMOKE_REMOTE set to a command prefix that runs a
# command there (CI uses "scripts/vm.sh ssh"), another one, which must
# publish the container's adb port as 127.0.0.1:${ADB_PORT:-5555} here.
# Android runs on ashmem only, never memfd: Android 16 cannot use memfd
# without Android's own kernel patches, so no version is tested on it. The
# container runs privileged, as redroid must, as redroid-smoke, and is removed
# afterwards.
#
# SMOKE_ANDROID_ARGS adds arguments to the container's: CI emulates arm64, and
# gives it ro.hw_timeout_multiplier, which Android has for slow emulators.
#
# It passes when:
#   - Android finishes booting within BOOT_TIMEOUT (600) seconds.
#   - Play services, Google Services Framework and the Play Store are
#     installed as system apps, and in the next SETTLE_SECONDS (90) none
#     crashes and system_server does not restart.
#   - For builtin or houdini, the ARM native bridge is configured and its
#     binfmt_misc handler registered.
set -euo pipefail

image=$1 bridge=$2 android=$3
name=redroid-smoke
boot_timeout=${BOOT_TIMEOUT:-600}
settle=${SETTLE_SECONDS:-90}
serial=127.0.0.1:${ADB_PORT:-5555}
# Locally, publish adb on loopback only; in a VM, on the address QEMU forwards to.
publish=${SMOKE_PUBLISH:-127.0.0.1}

fail() { echo "::error::$*"; exit 1; }

# on_host <command...>: runs a command on the Docker host.
on_host() {
  if [ -n "${SMOKE_REMOTE:-}" ]; then
    # shellcheck disable=SC2086  # SMOKE_REMOTE is a command prefix, split on purpose
    $SMOKE_REMOTE "$@"
  else
    "$@"
  fi
}

dump() {
  echo "::group::container log"; on_host docker logs "$name" 2>&1 | tail -n 200 || true; echo "::endgroup::"
  echo "::group::logcat (last 400 lines)"; timeout 30 adb -s "$serial" logcat -d 2>&1 | tail -n 400 || true; echo "::endgroup::"
}
cleanup() { status=$?; [ $status -eq 0 ] || dump; on_host docker rm -f "$name" >/dev/null 2>&1 || true; exit $status; }
trap cleanup EXIT

kernel=$(on_host uname -r)
on_host test -c /dev/ashmem \
  || fail "the Docker host's kernel ($kernel) has no /dev/ashmem; load ashmem_linux, or use scripts/vm.sh"
on_host sh -c 'test -e /dev/binder || grep -qw binder /proc/filesystems' \
  || fail "the Docker host's kernel ($kernel) has no binder; load binder_linux"

read -ra android_args <<<"${SMOKE_ANDROID_ARGS:-}"
on_host docker rm -f "$name" >/dev/null 2>&1 || true
on_host docker run -d --privileged --name "$name" -p "$publish:${ADB_PORT:-5555}:5555" "$image" \
  androidboot.redroid_gpu_mode=guest "${android_args[@]}" >/dev/null

sh_() { timeout 60 adb -s "$serial" shell "$@" | tr -d '\r'; }

echo "waiting up to ${boot_timeout}s for $image ($android) to boot on $kernel"
deadline=$((SECONDS + boot_timeout))
until [ "$(sh_ getprop sys.boot_completed 2>/dev/null || true)" = 1 ]; do
  [ "$(on_host docker inspect -f '{{.State.Running}}' "$name")" = true ] || fail "the container exited during boot"
  [ $SECONDS -lt $deadline ] || fail "Android did not finish booting in ${boot_timeout}s"
  timeout 10 adb connect "$serial" >/dev/null 2>&1 || true
  sleep 5
done
echo "booted in about $((SECONDS - deadline + boot_timeout))s: $(sh_ getprop ro.build.fingerprint)"

# userdebug with ro.secure=1: adbd starts as shell, and /linkerconfig and
# binfmt_misc need root. adbd restarts, so reconnect.
timeout 30 adb -s "$serial" root >/dev/null 2>&1 || true
root_deadline=$((SECONDS + 60))
until [ "$(sh_ id -u 2>/dev/null || true)" = 0 ]; do
  [ $SECONDS -lt $root_deadline ] || fail "adbd did not come back as root within 60s"
  timeout 10 adb connect "$serial" >/dev/null 2>&1 || true
  sleep 2
done
system_pid=$(sh_ pidof system_server || true)

for package in com.google.android.gms com.google.android.gsf com.android.vending; do
  path=$(sh_ pm path "$package" || true)
  case "$path" in
    package:/system/*|package:/product/*|package:/system_ext/*) echo "$package: ${path#package:}" ;;
    *) fail "$package is not installed as a system app (pm path said: ${path:-nothing})" ;;
  esac
done

# Installed is not working: a GApps package that does not fit the base boots,
# then crash-loops. Give Play services time to start, then read the crash log.
echo "letting Google apps run for ${settle}s"
sleep "$settle"
crash_log=$(timeout 30 adb -s "$serial" logcat -b crash -d -v threadtime 2>/dev/null | tr -d '\r' || true)
# crashes_of count|trace <regex>: reads the crash buffer (threadtime: date,
# time, PID, ...) for the crashes of processes whose names match <regex>. A
# Java crash is logged by the crashing process ("Process: <name>, PID: <pid>",
# or for system_server "FATAL EXCEPTION IN SYSTEM PROCESS"), a native one by
# crash_dump (">>> <name> <<<"), each under its own PID. "count" prints how
# often each process crashed. "trace" prints every line of each one's first
# crash, however much else, such as a crash loop, fills the buffer.
crashes_of() {
  # shellcheck disable=SC2016  # awk's own $fields
  # The regex goes in through the environment: -v would take its backslashes
  # as escapes.
  NAMES=$2 awk -v mode="$1" '
    NR == FNR {
      name = ""
      if (match($0, /Process: [^,]+/)) name = substr($0, RSTART + 9, RLENGTH - 9)
      else if (match($0, />>> [^ ]+ <<</)) name = substr($0, RSTART + 4, RLENGTH - 8)
      else if ($0 ~ /FATAL EXCEPTION IN SYSTEM PROCESS/) name = "system_server"
      if (name == "" || name !~ ENVIRON["NAMES"]) next
      if (!(name in first)) first[name] = $3
      count[name]++
      next
    }
    FNR == 1 {
      if (mode == "count") { for (n in count) print count[n] "x " n; exit }
      for (n in first) want[first[n]] = 1
    }
    $3 in want
  ' <(printf '%s\n' "$crash_log") <(printf '%s\n' "$crash_log")
}

# When system_server dies, every app dies with it (DeadSystemException), so
# its own death is the one to report. A crash leaves its trace in the crash
# buffer; the watchdog, which kills it when it stops responding, logs to the
# system buffer instead.
now_pid=$(sh_ pidof system_server || true)
if [ "$now_pid" != "$system_pid" ]; then
  echo "::group::why system_server restarted"
  crashes_of trace '^system_server$'
  timeout 60 adb -s "$serial" logcat -d -b system -v threadtime 2>/dev/null | tr -d '\r' \
    | grep -E ' (Watchdog|WatchdogDiagnostics) *:' | head -n 200 || true
  echo "::endgroup::"
  fail "system_server restarted in the ${settle}s after boot (pid ${system_pid:-?}, now ${now_pid:-none})"
fi

google='^(com\.google\.|com\.android\.vending)'
crashes=$(crashes_of count "$google" | sort)
if [ -n "$crashes" ]; then
  echo "::group::the first crash of each Google app"; crashes_of trace "$google"; echo "::endgroup::"
  fail "Google apps crashed after boot: $(paste -sd ';' <<<"$crashes" | sed 's/;/; /g')"
fi
echo "no Google app crashed in ${settle}s"

if [ "$bridge" != none ]; then
  nb=$(sh_ getprop ro.dalvik.vm.native.bridge)
  [ "$nb" = libnb.so ] || fail "ro.dalvik.vm.native.bridge is '$nb', not libnb.so"
  sh_ ls /system/lib64/libnb.so >/dev/null || fail "/system/lib64/libnb.so is missing"
  case "$(sh_ getprop ro.product.cpu.abilist)" in
    *arm64-v8a*) ;;
    *) fail "ro.product.cpu.abilist does not offer arm64-v8a" ;;
  esac
  # Read whole, then searched: grep -q stops at its first match, and under
  # pipefail the reader it cut off would turn that match into a failure.
  binfmt=$(sh_ cat /proc/sys/fs/binfmt_misc/arm64_dyn || true)
  grep -q '^enabled' <<<"$binfmt" || fail "no enabled arm64_dyn handler in binfmt_misc"
  if [ "$bridge" = houdini ]; then
    ld_config=$(sh_ cat /linkerconfig/ld.config.txt || true)
    # ${LIB} is the linker's own variable, meant literally.
    # shellcheck disable=SC2016
    if ! grep -qF '/system/${LIB}/arm64/nb' <<<"$ld_config"; then
      echo "::group::why the linker-namespace patch is missing"
      sh_ ls -l /system/bin/patch /system/etc/ld_config.patch /linkerconfig/ld.config.txt || true
      sh_ dmesg | grep -i -E 'ld_config|patch|exec' | tail -n 20 || true
      # A dry run shows which hunks no longer match this base.
      sh_ /system/bin/patch --dry-run /linkerconfig/ld.config.txt /system/etc/ld_config.patch || true
      grep -n -E '^namespace\.(default|sphal)\.(asan\.|hwasan\.)?(search|permitted)\.paths' <<<"$ld_config" | head -n 80 || true
      echo "::endgroup::"
      fail "the houdini linker-namespace patch is not in /linkerconfig/ld.config.txt"
    fi
  fi
  echo "native bridge ($bridge): libnb.so -> $(sh_ readlink /system/lib64/libnb.so), arm64_dyn registered"
fi

echo "smoke test passed: $image"
