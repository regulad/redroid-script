#!/usr/bin/env bash
# The machine redroid boots on in CI: an Ubuntu 22.04 VM on its stock 5.15
# kernel, the newest Ubuntu kernel that ships ashmem (in linux-modules-extra).
# Android 16 will not run on memfd without Android's own kernel patches, so
# every image is booted on ashmem, as it will run in production.
#
#   scripts/vm.sh deps <arch>                install QEMU and the rest (apt, sudo)
#   scripts/vm.sh prepare <arch> <disk>      make the VM's disk from the pinned cloud image
#   scripts/vm.sh start <arch> <disk> <dir>  boot a throwaway copy of <disk>, sharing <dir> as /job
#   scripts/vm.sh ssh <command...>           run a command in the running VM
#   scripts/vm.sh stop                       stop it
#
# <arch> is the guest's: amd64 or arm64. The VM runs under KVM when the host
# has the same architecture and /dev/kvm, and is emulated by QEMU otherwise.
# That is the case for arm64 on GitHub's runners, whose Arm machines have no
# KVM. The VM's SSH (as 2222) and adb (5555, or VM_ADB_PORT, the same number
# in the VM) are forwarded to 127.0.0.1 on the host.
#
# State is kept in $VM_STATE (default ./.vm): the SSH key, the copy-on-write
# disk, QEMU's pid and the serial console log.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
state=${VM_STATE:-$PWD/.vm}
ssh_port=${VM_SSH_PORT:-2222}
adb_port=${VM_ADB_PORT:-5555}
memory=${VM_MEMORY:-10G}
cpus=${VM_CPUS:-$(nproc)}

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0" >&2; exit 2; }

host_arch() {
  case "$(uname -m)" in
    x86_64) echo amd64 ;;
    aarch64 | arm64) echo arm64 ;;
    *) uname -m ;;
  esac
}

efi() {
  local fd=${VM_EFI:-/usr/share/qemu-efi-aarch64/QEMU_EFI.fd}
  [ -e "$fd" ] || { echo "no arm64 UEFI firmware at $fd (install qemu-efi-aarch64, or set VM_EFI)" >&2; exit 1; }
  echo "$fd"
}

# The emulator, machine and accelerator for a guest. Emulated arm64 uses the
# max CPU with QEMU's own pointer-authentication algorithm, which measured
# 2-4x faster than the architected one, or than neoverse-n1.
qemu_args() {
  local arch=$1 accel=tcg
  if [ "$arch" = "$(host_arch)" ] && [ -w /dev/kvm ]; then accel=kvm; fi
  case "$arch/$accel" in
    amd64/kvm) echo qemu-system-x86_64 -machine q35 -accel kvm -cpu host ;;
    amd64/tcg) echo qemu-system-x86_64 -machine q35 -accel tcg,thread=multi,tb-size=1024 -cpu max ;;
    arm64/kvm) echo qemu-system-aarch64 -machine virt,gic-version=max -accel kvm -cpu host -bios "$(efi)" ;;
    arm64/tcg) echo qemu-system-aarch64 -machine virt,gic-version=3 -accel tcg,thread=multi,tb-size=1024 -cpu max,pauth-impdef=on -bios "$(efi)" ;;
    *) echo "unknown architecture $arch" >&2; exit 1 ;;
  esac
}

# boot <arch> <disk> [qemu arguments...]: starts QEMU in the background.
boot() {
  local arch=$1 disk=$2 cmd
  shift 2
  read -ra cmd <<<"$(qemu_args "$arch")"
  echo "booting ${cmd[*]:0:5} ... ($arch, $cpus CPUs, $memory)" >&2
  "${cmd[@]}" -smp "$cpus" -m "$memory" -display none -monitor none \
    -serial "file:$state/serial.log" \
    -drive "if=virtio,format=qcow2,discard=unmap,detect-zeroes=unmap,file=$disk" \
    -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:$ssh_port-:22,hostfwd=tcp:127.0.0.1:$adb_port-:$adb_port" \
    -device virtio-net-pci,netdev=net0 \
    -daemonize -pidfile "$state/qemu.pid" "$@"
}

pid() { cat "$state/qemu.pid" 2>/dev/null || true; }
running() { local p; p=$(pid); [ -n "$p" ] && kill -0 "$p" 2>/dev/null; }

ssh_() {
  ssh -i "$state/id_ed25519" -p "$ssh_port" -o BatchMode=yes -o ConnectTimeout=10 \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    ubuntu@127.0.0.1 "$@"
}

fail() {
  echo "::error::$*" >&2
  tail -n 40 "$state/serial.log" >&2 2>/dev/null || true
  stop
  exit 1
}

start() {
  local arch=$1 disk=$2 share=$3 timeout=${VM_BOOT_TIMEOUT:-1800}
  mkdir -p "$state" "$share"
  [ -f "$state/id_ed25519" ] || ssh-keygen -q -t ed25519 -N '' -f "$state/id_ed25519"
  cp "$state/id_ed25519.pub" "$share/authorized_keys"
  rm -f "$state/run.qcow2"
  qemu-img create -q -f qcow2 -F qcow2 -b "$(realpath "$disk")" "$state/run.qcow2"
  boot "$arch" "$state/run.qcow2" \
    -virtfs "local,path=$(realpath "$share"),mount_tag=job,security_model=none,id=job"
  local deadline=$((SECONDS + timeout))
  until ssh_ true 2>/dev/null; do
    running || fail "the VM exited while booting"
    [ $SECONDS -lt $deadline ] || fail "the VM did not answer on SSH within ${timeout}s"
    sleep 5
  done
  echo "VM up after ${SECONDS}s: $(ssh_ uname -sr)" >&2
}

stop() {
  local p
  p=$(pid)
  if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then
    kill "$p" || true
    for _ in $(seq 30); do kill -0 "$p" 2>/dev/null || break; sleep 1; done
    kill -9 "$p" 2>/dev/null || true
  fi
  rm -f "$state/qemu.pid" "$state/run.qcow2"
}

prepare() {
  local arch=$1 out=$2 timeout=${VM_PREPARE_TIMEOUT:-7200}
  local images=$root/vm/images.json release file sha
  release=$(jq -r .release "$images")
  file=$(jq -er ".$arch.file" "$images")
  sha=$(jq -er ".$arch.sha256" "$images")
  mkdir -p "$state"

  if ! echo "$sha  $state/cloud.img" | sha256sum -c --status - 2>/dev/null; then
    curl -fsSL --retry 5 --retry-all-errors -o "$state/cloud.img" "$release/$file"
  fi
  echo "$sha  $state/cloud.img" | sha256sum -c -
  rm -f "$state/prepare.qcow2"
  qemu-img create -q -f qcow2 -F qcow2 -b "$state/cloud.img" "$state/prepare.qcow2" 24G

  # First boot: cloud-init installs the kernel, Docker and the modules' config,
  # then powers the VM off. It reads its configuration over HTTP from here
  # (10.0.2.2 is this machine on QEMU's user network), as the SMBIOS serial
  # tells it to, so no seed disk needs making.
  local seed=$state/seed port=${VM_SEED_PORT:-8099}
  mkdir -p "$seed"
  cp "$root/vm/user-data.yaml" "$seed/user-data"
  printf 'instance-id: redroid-vm\nlocal-hostname: redroid\n' > "$seed/meta-data"
  : > "$seed/vendor-data"
  python3 -m http.server --bind 127.0.0.1 --directory "$seed" "$port" > "$state/seed.log" 2>&1 &
  local server=$!
  # shellcheck disable=SC2064  # expand $server now; it is local to this function
  trap "kill $server 2>/dev/null || true" EXIT
  boot "$arch" "$state/prepare.qcow2" -smbios "type=1,serial=ds=nocloud;s=http://10.0.2.2:$port/"
  local deadline=$((SECONDS + timeout))
  while running; do
    [ $SECONDS -lt $deadline ] || { stop; fail "cloud-init did not finish within ${timeout}s"; }
    sleep 10
  done
  kill "$server" 2>/dev/null || true
  trap - EXIT
  grep -q 'GET /user-data' "$state/seed.log" || fail "the VM never fetched its cloud-init configuration"
  echo "cloud-init finished after ${SECONDS}s" >&2

  # Second boot, of a throwaway copy: check that the disk gives what it is for.
  local check=$state/check
  start "$arch" "$state/prepare.qcow2" "$check"
  ssh_ test -f /var/lib/redroid-vm-prepared || fail "cloud-init did not get to the end of its commands"
  local kernel
  kernel=$(ssh_ uname -r)
  case "$kernel" in 5.15.*) ;; *) fail "the VM booted kernel $kernel, not a 5.15 one" ;; esac
  ssh_ test -c /dev/ashmem || fail "no /dev/ashmem on $kernel"
  ssh_ 'test -e /dev/binder || grep -qw binder /proc/filesystems' || fail "no binder on $kernel"
  ssh_ docker version --format '{{.Server.Version}}' >/dev/null || fail "Docker is not running"
  echo "prepared: kernel $kernel, docker $(ssh_ docker version --format '{{.Server.Version}}'), /dev/ashmem present" >&2
  stop

  # Flatten onto the cloud image and compress, for the cache.
  qemu-img convert -c -O qcow2 "$state/prepare.qcow2" "$out"
  rm -rf "$state/prepare.qcow2" "$state/cloud.img" "$seed"
  echo "wrote $out ($(du -h "$out" | cut -f1))" >&2
}

# What running a guest of <arch> needs, on Ubuntu or Debian, and access to
# /dev/kvm for the user running QEMU (GitHub's runners leave it root's).
deps() {
  local arch=$1 packages=(qemu-utils openssh-client python3)
  case "$arch" in
    amd64) packages+=(qemu-system-x86) ;;
    arm64) packages+=(qemu-system-arm qemu-efi-aarch64) ;;
    *) echo "unknown architecture $arch" >&2; exit 1 ;;
  esac
  sudo apt-get update -q
  sudo apt-get install -y -q "${packages[@]}"
  if [ -e /dev/kvm ]; then sudo chmod 666 /dev/kvm; fi
}

[ $# -ge 1 ] || usage
command=$1
shift
case "$command" in
  deps) [ $# -eq 1 ] || usage; deps "$@" ;;
  prepare) [ $# -eq 2 ] || usage; prepare "$@" ;;
  start) [ $# -eq 3 ] || usage; start "$@" ;;
  # ssh hands the remote shell one string; quote each argument so the command
  # runs there as it was written here.
  ssh) [ $# -ge 1 ] || usage; ssh_ "$(printf '%q ' "$@")" ;;
  stop) stop ;;
  *) usage ;;
esac
