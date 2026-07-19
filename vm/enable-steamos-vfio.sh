#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BACKUP_DIR=${STEAMOS_VFIO_BACKUP_DIR:-/home/steamosadmin/steamos-vm/backups}
readonly_restore=0

cleanup() {
  local status=$?
  trap - EXIT
  if (( readonly_restore )); then
    steamos-readonly enable || true
  fi
  exit "$status"
}
trap cleanup EXIT

if (( EUID != 0 )); then
  exec sudo -E "$0" "$@"
fi

install -d -m 0755 "$BACKUP_DIR" /etc/default/grub.d /etc/atomic-update.conf.d
if [[ -f /efi/EFI/steamos/grub.cfg ]]; then
  cp -a /efi/EFI/steamos/grub.cfg "$BACKUP_DIR/grub.cfg.$(date +%Y%m%d-%H%M%S)"
fi

steamos-readonly disable || true
readonly_restore=1
install -m 0644 "$SCRIPT_DIR/90-steamos-vfio.cfg" /etc/default/grub.d/90-steamos-vfio.cfg
install -m 0644 "$SCRIPT_DIR/91-steamos-vfio-keep.conf" /etc/atomic-update.conf.d/91-steamos-vfio-keep.conf
update-grub
grep -q 'intel_iommu=on iommu=pt' /efi/EFI/steamos/grub.cfg
steamos-readonly enable
readonly_restore=0

printf 'VFIO boot parameters installed. Reboot, then verify IOMMU groups before detaching devices.\n'
