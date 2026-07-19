#!/usr/bin/env bash
set -Eeuo pipefail

GPU_BDF=${STEAMOS_VFIO_GPU_BDF:-0000:01:00.0}
AUDIO_BDF=${STEAMOS_VFIO_AUDIO_BDF:-0000:01:00.1}
EXPECTED_DEVICES=("$GPU_BDF" "$AUDIO_BDF")

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

driver_for() {
  local link="/sys/bus/pci/devices/$1/driver"
  [[ -L "$link" ]] && basename -- "$(readlink -f -- "$link")" || printf 'unbound\n'
}

verify_group() {
  local group_link group_path
  local -a actual expected

  group_link="/sys/bus/pci/devices/$GPU_BDF/iommu_group"
  [[ -L "$group_link" ]] || die "$GPU_BDF has no IOMMU group; reboot with IOMMU enabled"
  group_path=$(readlink -f -- "$group_link")
  mapfile -t actual < <(find "$group_path/devices" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort)
  mapfile -t expected < <(printf '%s\n' "${EXPECTED_DEVICES[@]}" | sort)
  [[ "${actual[*]}" == "${expected[*]}" ]] || {
    printf 'Refusing GPU handoff. IOMMU group %s contains:\n' "${group_path##*/}" >&2
    printf '  %s\n' "${actual[@]}" >&2
    die "expected only ${expected[*]}"
  }
  printf '%s\n' "${group_path##*/}"
}

show_status() {
  local group
  group=$(verify_group)
  printf 'IOMMU group: %s\n' "$group"
  printf '%s driver: %s\n' "$GPU_BDF" "$(driver_for "$GPU_BDF")"
  printf '%s driver: %s\n' "$AUDIO_BDF" "$(driver_for "$AUDIO_BDF")"
}

to_vfio() {
  local device current
  verify_group >/dev/null

  systemctl stop display-manager.service || true
  systemctl stop nvidia-persistenced.service || true
  sleep 2

  shopt -s nullglob
  local -a nvidia_nodes=(/dev/nvidia*)
  if ((${#nvidia_nodes[@]})) && fuser "${nvidia_nodes[@]}" >/dev/null 2>&1; then
    systemctl start nvidia-persistenced.service || true
    systemctl start display-manager.service || true
    die 'an NVIDIA device is still in use after stopping the display manager'
  fi

  modprobe vfio-pci
  for device in "${EXPECTED_DEVICES[@]}"; do
    current=$(driver_for "$device")
    printf 'vfio-pci\n' >"/sys/bus/pci/devices/$device/driver_override"
    if [[ "$current" != unbound && "$current" != vfio-pci ]]; then
      printf '%s\n' "$device" >"/sys/bus/pci/drivers/$current/unbind"
    fi
    if [[ "$(driver_for "$device")" != vfio-pci ]]; then
      printf '%s\n' "$device" > /sys/bus/pci/drivers_probe
    fi
    [[ "$(driver_for "$device")" == vfio-pci ]] || die "failed to bind $device to vfio-pci"
  done

  printf 'GPU and HDMI audio are bound to vfio-pci.\n'
}

to_host() {
  local device current failed=0
  verify_group >/dev/null

  systemctl stop display-manager.service || true
  systemctl stop nvidia-persistenced.service || true

  for device in "${EXPECTED_DEVICES[@]}"; do
    current=$(driver_for "$device")
    if [[ "$current" == vfio-pci ]]; then
      printf '%s\n' "$device" > /sys/bus/pci/drivers/vfio-pci/unbind
    fi
    printf '\n' >"/sys/bus/pci/devices/$device/driver_override"
  done

  # FLR on the graphics function also resets the paired audio function. A
  # failed reset is non-fatal; the normal PCI probe often works without it.
  if [[ -w "/sys/bus/pci/devices/$GPU_BDF/reset" ]]; then
    printf '1\n' >"/sys/bus/pci/devices/$GPU_BDF/reset" || true
  fi

  modprobe snd_hda_intel || true
  modprobe nvidia
  modprobe nvidia_modeset || true
  modprobe nvidia_drm || true

  for device in "${EXPECTED_DEVICES[@]}"; do
    if [[ "$(driver_for "$device")" == unbound ]]; then
      printf '%s\n' "$device" > /sys/bus/pci/drivers_probe || true
    fi
  done

  [[ "$(driver_for "$GPU_BDF")" == nvidia ]] || failed=1
  [[ "$(driver_for "$AUDIO_BDF")" == snd_hda_intel ]] || failed=1

  systemctl start nvidia-persistenced.service || true
  systemctl start display-manager.service || true

  if ((failed)) || ! nvidia-smi >/dev/null 2>&1; then
    show_status >&2 || true
    die 'GPU did not recover cleanly; SSH is still available, and a host reboot is the fallback'
  fi
  printf 'GPU restored to the host; NVIDIA is responding.\n'
}

if ((EUID != 0)); then
  exec sudo -E "$0" "$@"
fi

case "${1:-status}" in
  status) show_status ;;
  to-vfio) to_vfio ;;
  to-host) to_host ;;
  *) die "usage: $0 {status|to-vfio|to-host}" ;;
esac
