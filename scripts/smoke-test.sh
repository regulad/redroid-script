#!/usr/bin/env bash
# Boots an image and checks what it was built to have.
#
#   scripts/smoke-test.sh <image> <native_bridge> <android>
#
# <native_bridge> is that platform's value in matrix.json (none, builtin or
# houdini) and <android> the image's redroid variant. Needs a Linux host whose
# kernel has binder (binder_linux or binderfs), and, for Android 16, ashmem;
# root through sudo, Docker and adb. The image runs privileged, as redroid
# must, under the name redroid-smoke, which is removed afterwards.
#
# It passes when Android finishes booting; Play services, Google Services
# Framework and the Play Store are installed as system apps and do not crash in
# the next SETTLE_SECONDS (90); and, for builtin or houdini, the ARM native
# bridge is configured and its binfmt_misc handler registered.
set -euo pipefail

image=$1 bridge=$2 android=$3
name=redroid-smoke
boot_timeout=${BOOT_TIMEOUT:-600}

fail() { echo "::error::$*"; exit 1; }

dump() {
  echo "::group::container log"; docker logs "$name" 2>&1 | tail -n 200 || true; echo "::endgroup::"
  if [ -n "${serial:-}" ]; then
    echo "::group::logcat (last 400 lines)"; timeout 30 adb -s "$serial" logcat -d 2>&1 | tail -n 400 || true; echo "::endgroup::"
  fi
}
cleanup() { status=$?; [ $status -eq 0 ] || dump; docker rm -f "$name" >/dev/null 2>&1 || true; exit $status; }
trap cleanup EXIT

# binderfs needs only binder_linux; the devices= list is for kernels without it.
if ! grep -qw binder /proc/filesystems && [ ! -e /dev/binder ]; then
  sudo modprobe binder_linux devices=binder,hwbinder,vndbinder \
    || fail "this kernel ($(uname -r)) has no binder, which redroid needs"
fi

# memfd stands in for ashmem up to Android 15, but redroid 16's SurfaceFlinger
# aborts at boot ("output buffer not gpu writeable") without /dev/ashmem:
# remote-android/redroid-doc#934. Say so now rather than after a 10-minute
# boot loop.
if [ "${android%%.*}" -ge 16 ] && [ ! -e /dev/ashmem ]; then
  fail "Android $android needs /dev/ashmem, which this kernel ($(uname -r)) does not have (redroid-doc#934)"
fi

docker rm -f "$name" >/dev/null 2>&1 || true
docker run -d --privileged --name "$name" "$image" \
  androidboot.use_memfd=1 androidboot.redroid_gpu_mode=guest >/dev/null
ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$name")
[ -n "$ip" ] || fail "the container has no IP address; did it exit at once?"
serial=$ip:5555

sh_() { timeout 60 adb -s "$serial" shell "$@" | tr -d '\r'; }

echo "waiting up to ${boot_timeout}s for $image to boot ($serial)"
deadline=$((SECONDS + boot_timeout))
until [ "$(sh_ getprop sys.boot_completed 2>/dev/null || true)" = 1 ]; do
  [ "$(docker inspect -f '{{.State.Running}}' "$name")" = true ] || fail "the container exited during boot"
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

for package in com.google.android.gms com.google.android.gsf com.android.vending; do
  path=$(sh_ pm path "$package" || true)
  case "$path" in
    package:/system/*|package:/product/*|package:/system_ext/*) echo "$package: ${path#package:}" ;;
    *) fail "$package is not installed as a system app (pm path said: ${path:-nothing})" ;;
  esac
done

# Installed is not working: a GApps package that does not fit the base boots,
# then crash-loops. Give Play services time to start, then read the crash log.
settle=${SETTLE_SECONDS:-90}
echo "letting Google apps run for ${settle}s"
sleep "$settle"
crashes=$(timeout 30 adb -s "$serial" logcat -b crash -d 2>/dev/null | tr -d '\r' \
  | grep -E '^.*Process: (com\.google\.|com\.android\.vending)' | sed -E 's/.*Process: //' | sort | uniq -c || true)
if [ -n "$crashes" ]; then
  echo "::group::crash log"; timeout 30 adb -s "$serial" logcat -b crash -d 2>&1 | tail -n 150 || true; echo "::endgroup::"
  fail "Google apps crashed after boot: $(echo "$crashes" | tr '\n' ';')"
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
  sh_ cat /proc/sys/fs/binfmt_misc/arm64_dyn | grep -q '^enabled' \
    || fail "no enabled arm64_dyn handler in binfmt_misc"
  if [ "$bridge" = houdini ]; then
    # ${LIB} is the linker's own variable, meant literally.
    # shellcheck disable=SC2016
    if ! sh_ cat /linkerconfig/ld.config.txt | grep -qF '/system/${LIB}/arm64/nb'; then
      echo "::group::why the linker-namespace patch is missing"
      sh_ ls -l /system/bin/patch /system/etc/ld_config.patch /linkerconfig/ld.config.txt || true
      sh_ dmesg | grep -i -E 'ld_config|patch|exec' | tail -n 20 || true
      # A dry run shows which hunks no longer match this base.
      sh_ /system/bin/patch --dry-run /linkerconfig/ld.config.txt /system/etc/ld_config.patch || true
      sh_ grep -n -E '^namespace\.default\.(search|permitted)\.paths' /linkerconfig/ld.config.txt | head -n 40 || true
      echo "::endgroup::"
      fail "the houdini linker-namespace patch is not in /linkerconfig/ld.config.txt"
    fi
  fi
  echo "native bridge ($bridge): libnb.so -> $(sh_ readlink /system/lib64/libnb.so), arm64_dyn registered"
fi

echo "smoke test passed: $image"
