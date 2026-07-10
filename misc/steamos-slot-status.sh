#!/usr/bin/env bash
# Read-only SteamOS A/B slot and update metadata report over SSH.
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: steamos-slot-status.sh --host HOST [options]

Show the booted SteamOS A/B slot, inactive slot, boot health, update metadata,
and relevant partition/boot-loader information. This script is read-only.

Options:
  -H, --host HOST   SteamOS hostname or IP (or STEAMOS_HOST).
  -u, --user USER   SSH user. Default: steamosadmin (STEAMOS_USER).
  -h, --help        Show this help.
EOF
}
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

HOST=${STEAMOS_HOST:-}
SSH_USER=${STEAMOS_USER:-steamosadmin}
while [[ $# -gt 0 ]]; do
  case "$1" in
    -H|--host) [[ $# -ge 2 ]] || die "$1 requires a value"; HOST=$2; shift 2 ;;
    -u|--user) [[ $# -ge 2 ]] || die "$1 requires a value"; SSH_USER=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done
[[ -n "$HOST" ]] || { usage >&2; exit 2; }
[[ "$SSH_USER" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || die "invalid SSH user: $SSH_USER"
command -v ssh >/dev/null 2>&1 || die "missing required command: ssh"

ssh -o ConnectTimeout=10 -o ServerAliveInterval=15 "$SSH_USER@$HOST" 'bash -s' <<'REMOTE_SCRIPT'
set -u
section() { printf '\n== %s ==\n' "$1"; }

section 'System'
if [[ -r /etc/os-release ]]; then
  . /etc/os-release
  printf 'OS: %s\nBuild ID: %s\n' "${PRETTY_NAME:-unknown}" "${BUILD_ID:-unknown}"
fi
printf 'Kernel: %s\nBooted at: %s\n' "$(uname -r)" "$(uptime -s 2>/dev/null || true)"

section 'A/B slot state (RAUC)'
if command -v rauc >/dev/null 2>&1; then
  rauc status --detailed --output-format=json-pretty 2>/dev/null || rauc status --detailed || true
else
  printf 'rauc is not installed\n'
fi

section 'SteamOS boot configuration'
if command -v steamos-bootconf >/dev/null 2>&1; then
  printf 'Selected next boot image: '; steamos-bootconf selected-image 2>&1 || true
  printf 'Current boot image: '; steamos-bootconf this-image 2>&1 || true
  printf 'Known image configurations:\n'; steamos-bootconf list-images 2>&1 || true
  printf 'Current image configuration:\n'; steamos-bootconf dump-config 2>&1 || true
else
  printf 'steamos-bootconf is not installed\n'
fi

section 'Atomic-update metadata'
for file in /etc/steamos-atomupd/preferences.conf /etc/steamos-atomupd/remote-info.conf /etc/steamos-atomupd/manifest.json; do
  if [[ -r "$file" ]]; then
    printf '\n-- %s --\n' "$file"
    cat "$file"
  fi
done

section 'Relevant mounts and partitions'
for target in / /home /esp /efi; do
  findmnt -rn -T "$target" -o TARGET,SOURCE,FSTYPE,OPTIONS 2>/dev/null || true
done
lsblk -o NAME,SIZE,FSTYPE,LABEL,PARTLABEL,MOUNTPOINTS 2>/dev/null || true

section 'Boot loader'
command -v bootctl >/dev/null 2>&1 && bootctl --esp-path=/esp status 2>&1 || true
REMOTE_SCRIPT
