#!/usr/bin/env bash
set -Eeuo pipefail

VM_ROOT=${STEAMOS_VM_ROOT:-/home/steamosadmin/steamos-vm}
SCRIPT_DIR=${STEAMOS_VFIO_SCRIPT_DIR:-$VM_ROOT/vfio}
MODE=${1:-recovery}
CONTAINER_NAME=steamos-vfio-vm
PODMAN_ROOT="$VM_ROOT/root-podman"
PODMAN_RUNROOT=/run/steamos-vm-podman
PODMAN_CMD=(podman --root "$PODMAN_ROOT" --runroot "$PODMAN_RUNROOT")
IMAGE=localhost/steamos-qemu:latest
TARGET=/vm/disks/steamos-gpu-target.qcow2
RECOVERY=/vm/disks/recovery-gpu-session.qcow2
VARS=/vm/run/OVMF_GPU_VARS.4m.fd
SERIAL=/vm/run/gpu-serial.log
MONITOR_PORT=55555
GROUP_ID=
handoff_started=0
cleanup_running=0

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

podman_vm() {
  "${PODMAN_CMD[@]}" "$@"
}

cleanup() {
  local status=$?
  ((cleanup_running)) && exit "$status"
  cleanup_running=1
  trap - EXIT INT TERM HUP
  podman_vm rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  if ((handoff_started)); then
    "$SCRIPT_DIR/vfio-gpu-bind.sh" to-host || true
  fi
  exit "$status"
}
trap cleanup EXIT INT TERM HUP

if ((EUID != 0)); then
  exec sudo -E "$0" "$@"
fi

[[ "$MODE" == recovery || "$MODE" == installed ]] || die 'mode must be recovery or installed'
[[ -x "$SCRIPT_DIR/vfio-gpu-bind.sh" ]] || die "missing $SCRIPT_DIR/vfio-gpu-bind.sh"
[[ -f "$VM_ROOT/disks/steamos-gpu-target.qcow2" ]] || die 'missing GPU test target disk'
[[ -f "$VM_ROOT/run/OVMF_GPU_VARS.4m.fd" ]] || die 'missing writable OVMF variables file'
if [[ "$MODE" == recovery ]]; then
  [[ -f "$VM_ROOT/disks/recovery-gpu-session.qcow2" ]] || die 'missing recovery session disk'
fi

GROUP_ID=$(basename -- "$(readlink -f /sys/bus/pci/devices/0000:01:00.0/iommu_group)")
[[ -c "/dev/vfio/$GROUP_ID" ]] || modprobe vfio-pci

: >"$VM_ROOT/run/gpu-serial.log"
podman_vm rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

handoff_started=1
"$SCRIPT_DIR/vfio-gpu-bind.sh" to-vfio
[[ -c "/dev/vfio/$GROUP_ID" ]] || die "missing /dev/vfio/$GROUP_ID after GPU handoff"

# Commas below are intentionally part of individual QEMU option values.
# shellcheck disable=SC2054
qemu_args=(
  qemu-system-x86_64
  -name steamos-vfio-test
  -machine q35,accel=kvm
  -cpu host
  -smp 22,sockets=1,cores=22,threads=1
  -m 20G
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/x64/OVMF_CODE.4m.fd
  -drive "if=pflash,format=raw,file=$VARS"
  -drive "if=none,id=target,format=qcow2,file=$TARGET,cache=none,aio=native"
  -device nvme,drive=target,serial=STEAMOSVFIO0001,bootindex=2
  -device vfio-pci,host=0000:01:00.0,multifunction=on,x-vga=on
  -device vfio-pci,host=0000:01:00.1
  -device virtio-rng-pci
  -netdev user,id=net0,hostfwd=tcp:127.0.0.1:2222-:22
  -device e1000e,netdev=net0
  -vga none
  -display none
  -serial "file:$SERIAL"
  -monitor "tcp:127.0.0.1:$MONITOR_PORT,server=on,wait=off"
)

if [[ "$MODE" == recovery ]]; then
  # shellcheck disable=SC2054
  qemu_args+=(
    -drive "if=none,id=recovery,format=qcow2,file=$RECOVERY,cache=none,aio=native"
    -device qemu-xhci
    -device usb-storage,drive=recovery,removable=on,bootindex=1
  )
fi

printf 'Starting %s VM with 22 vCPUs, 20 GiB RAM, and IOMMU group %s.\n' "$MODE" "$GROUP_ID"
taskset -c 4-15,18-27 "${PODMAN_CMD[@]}" run --rm --name "$CONTAINER_NAME" \
  --privileged --network host --security-opt label=disable \
  --ulimit memlock=-1:-1 \
  -v "$VM_ROOT:/vm:rw" \
  "$IMAGE" "${qemu_args[@]}"
