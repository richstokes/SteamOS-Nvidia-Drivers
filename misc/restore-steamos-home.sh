#!/usr/bin/env bash
# Restore a SteamOS home tar.zst archive over SSH.
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: restore-steamos-home.sh --host HOST BACKUP.tar.zst [options]

Restores a tar.zst backup created by backup-steamos-home.sh, preserving numeric
ownership, modes, ACLs, extended attributes, hard links, symlinks, and sparse files.

Options:
  -H, --host HOST          SteamOS hostname or IP (or STEAMOS_HOST).
  -u, --user USER          SSH user. Default: steamosadmin (STEAMOS_USER).
  -r, --remote-home PATH   Restore target. Default: /home/deck.
      --replace            Move the existing target aside before restoring.
      --dry-run            Validate locally without copying or changing files.
  -h, --help               Show this help.
EOF
}
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }
human_bytes() { awk -v n="$1" 'BEGIN { split("B KiB MiB GiB TiB",u," "); i=1; while(n>=1024&&i<5){n/=1024;i++}; printf "%.1f %s",n,u[i] }'; }

HOST=${STEAMOS_HOST:-}; SSH_USER=${STEAMOS_USER:-steamosadmin}; REMOTE_HOME=/home/deck
REPLACE=false; DRY_RUN=false; BACKUP=
while [[ $# -gt 0 ]]; do
  case "$1" in
    -H|--host) HOST=$2; shift 2 ;;
    -u|--user) SSH_USER=$2; shift 2 ;;
    -r|--remote-home) REMOTE_HOME=$2; shift 2 ;;
    --replace) REPLACE=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown option: $1" ;;
    *) [[ -z "$BACKUP" ]] || die "only one archive may be supplied"; BACKUP=$1; shift ;;
  esac
done
[[ -n "$HOST" && -n "$BACKUP" && -f "$BACKUP" ]] || { usage >&2; exit 2; }
[[ "$BACKUP" == *.tar.zst ]] || die "backup must be a .tar.zst file"
[[ "$REMOTE_HOME" =~ ^/home/[^/]+$ ]] || die "--remote-home must be a direct home directory"
need zstd; need tar; need ssh; need scp
BACKUP=$(cd "$(dirname "$BACKUP")" && pwd)/$(basename "$BACKUP")
HOME_NAME=${REMOTE_HOME##*/}

zstd -tq "$BACKUP"
zstd -d -q -c "$BACKUP" | tar -tf - >/dev/null
while IFS= read -r entry; do
  [[ "$entry" != /* && "$entry" != '..' && "$entry" != */../* && "$entry" != */.. ]] || die "unsafe archive entry: $entry"
  case "$entry" in "$HOME_NAME"|"$HOME_NAME"/*) ;; *) die "entry outside $HOME_NAME: $entry" ;; esac
done < <(zstd -d -q -c "$BACKUP" | tar -tf -)

METADATA=$(zstd -d -q -c "$BACKUP" | tar -xOf - "$HOME_NAME/.steamos-home-backup-manifest") || die "backup metadata is missing or invalid"
FORMAT=; SOURCE_KIB=; HOME_UID=; HOME_GID=; METADATA_HOME=
while IFS='=' read -r key value; do
  case "$key" in
    format) FORMAT=$value ;; source_disk_kib) SOURCE_KIB=$value ;;
    home_uid) HOME_UID=$value ;; home_gid) HOME_GID=$value ;; home_name) METADATA_HOME=$value ;;
  esac
done <<<"$METADATA"
[[ "$FORMAT" == steamos-home-tar-zst-v1 && "$SOURCE_KIB" =~ ^[0-9]+$ &&
   "$HOME_UID" =~ ^[0-9]+$ && "$HOME_GID" =~ ^[0-9]+$ && "$METADATA_HOME" == "$HOME_NAME" ]] ||
  die "backup metadata is invalid or does not match $REMOTE_HOME"

ARCHIVE_BYTES=$(wc -c <"$BACKUP" | tr -d ' '); PAYLOAD_BYTES=$(( SOURCE_KIB * 1024 ))
printf 'Archive:              %s\nRecorded source size: %s\nRecorded owner:       UID %s, GID %s\nTarget:               %s on %s\n' \
  "$BACKUP" "$(human_bytes "$PAYLOAD_BYTES")" "$HOME_UID" "$HOME_GID" "$REMOTE_HOME" "$HOST"
[[ "$DRY_RUN" == true ]] && { printf 'Dry run: archive is valid; no files changed.\n'; exit 0; }

TARGET="$SSH_USER@$HOST"; SSH=(ssh -o ServerAliveInterval=15 -o ServerAliveCountMax=3 "$TARGET")
remote() { "${SSH[@]}" "$1"; }
SUDO_MODE=; SUDO_PASSWORD=
if remote 'sudo -n true' >/dev/null 2>&1; then SUDO_MODE=noninteractive
else
  [[ -t 0 ]] || die "SteamOS sudo needs an interactive password"
  printf 'SteamOS sudo password for %s: ' "$TARGET" >&2; IFS= read -r -s SUDO_PASSWORD; printf '\n' >&2
  SUDO_MODE=password
fi
remote_sudo() {
  local quoted; printf -v quoted '%q' "$1"
  if [[ "$SUDO_MODE" == noninteractive ]]; then remote "sudo -n bash -c $quoted"
  else printf '%s\n' "$SUDO_PASSWORD" | "${SSH[@]}" "sudo -S -p '' bash -c $quoted"; fi
}
STAGE="/home/$SSH_USER/.cache/steamos-home-restore"; REMOTE_ARCHIVE="$STAGE/$(basename "$BACKUP")"
cleanup() { remote "rm -f $(printf '%q' "$REMOTE_ARCHIVE")" >/dev/null 2>&1 || true; unset SUDO_PASSWORD; }
trap cleanup EXIT

remote 'command -v tar >/dev/null && command -v zstd >/dev/null' || die "SteamOS needs GNU tar and zstd"
remote "mkdir -p $(printf '%q' "$STAGE")"
printf -v free_script 'df -Pk %q | awk '\''NR == 2 { print $4 * 1024 }'\''' "$STAGE"
FREE_BYTES=$(remote_sudo "$free_script")
REQUIRED_BYTES=$(( PAYLOAD_BYTES + ARCHIVE_BYTES + (PAYLOAD_BYTES + ARCHIVE_BYTES + 19) / 20 ))
[[ "$FREE_BYTES" =~ ^[0-9]+$ && "$FREE_BYTES" -ge "$REQUIRED_BYTES" ]] ||
  die "not enough free space on SteamOS; restore was not started"

printf -v account_script 'account=%q; uid=%q; gid=%q
getent passwd "$account" >/dev/null || { echo "target account does not exist: $account" >&2; exit 1; }
[[ "$(id -u "$account")" == "$uid" && "$(id -g "$account")" == "$gid" ]] ||
  { echo "target account UID/GID does not match backup metadata" >&2; exit 1; }' "$HOME_NAME" "$HOME_UID" "$HOME_GID"
remote_sudo "$account_script"

printf 'Copying archive to SteamOS...\n'; scp "$BACKUP" "$TARGET:$REMOTE_ARCHIVE"
STAMP=$(date +%Y%m%d-%H%M%S)
if [[ "$REPLACE" == true ]]; then
  printf -v restore_script 'archive=%q; target=%q; home=%q; stamp=%q
if [[ -e "$target" ]]; then mv "$target" "/home/.$home.pre-restore-$stamp"; fi
tar --acls --xattrs --xattrs-include='\''*'\'' --numeric-owner --same-owner --sparse \
  --exclude="$home/.steamos-home-backup-manifest" -I zstd -xpf "$archive" -C /home' \
    "$REMOTE_ARCHIVE" "$REMOTE_HOME" "$HOME_NAME" "$STAMP"
else
  printf -v restore_script 'archive=%q; home=%q
tar --acls --xattrs --xattrs-include='\''*'\'' --numeric-owner --same-owner --sparse \
  --exclude="$home/.steamos-home-backup-manifest" -I zstd -xpf "$archive" -C /home' \
    "$REMOTE_ARCHIVE" "$HOME_NAME"
fi
printf 'Extracting backup on SteamOS...\n'; remote_sudo "$restore_script"
printf 'Restore complete: %s\n' "$REMOTE_HOME"
