#!/usr/bin/env bash
# Stream a faithful SteamOS home-directory tar.zst archive over SSH.
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: backup-steamos-home.sh --host HOST [options]

Create a dated .tar.zst backup of a SteamOS home directory. The archive is
created on SteamOS and streamed directly to this machine; no large temporary
archive is left there. It preserves numeric ownership, modes, ACLs, extended
attributes, hard links, symlinks, and sparse files.

Options:
  -H, --host HOST          SteamOS hostname or IP (or STEAMOS_HOST).
  -u, --user USER          SSH user. Default: steamosadmin (STEAMOS_USER).
  -r, --remote-home PATH   Home to back up. Default: /home/deck.
  -o, --output-dir PATH    Destination directory. Default: ~/Desktop.
      --include-dot-steam-backups
                           Include dot-steam.bak.<timestamp> directories.
      --dry-run            Run connection and capacity checks only.
  -h, --help               Show this help.
EOF
}

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }
human_kib() {
  local kib=$1
  if (( kib >= 1048576 )); then awk "BEGIN { printf \"%.1f GiB\", $kib / 1048576 }"
  elif (( kib >= 1024 )); then awk "BEGIN { printf \"%.1f MiB\", $kib / 1024 }"
  else printf '%s KiB' "$kib"; fi
}
filesystem_type() {
  local path=$1 type=
  if [[ $(uname -s) == Darwin ]] && command -v diskutil >/dev/null 2>&1; then
    type=$(diskutil info "$path" 2>/dev/null | awk -F: '/File System Personality/ { gsub(/^[[:space:]]+/, "", $2); print tolower($2); exit }')
  fi
  if [[ -z "$type" ]]; then
    type=$(stat -f -c %T "$path" 2>/dev/null || stat -f %T "$path" 2>/dev/null || true)
    type=${type,,}
  fi
  printf '%s' "$type"
}
stream_to_file() {
  local output=$1
  python3 -c '
import os
import sys
import time

path = sys.argv[1]
received = 0
started = last_report = time.monotonic()

def format_bytes(value):
    units = ("B", "KiB", "MiB", "GiB", "TiB")
    for unit in units:
        if value < 1024 or unit == units[-1]:
            return f"{value:.1f} {unit}" if unit != "B" else f"{value} B"
        value /= 1024

try:
    with open(path, "wb") as destination:
        while chunk := sys.stdin.buffer.read(1024 * 1024):
            destination.write(chunk)
            received += len(chunk)
            now = time.monotonic()
            if now - last_report >= 5:
                rate = received / (now - started)
                print(f"\rReceived: {format_bytes(received)} | Average: {format_bytes(rate)}/s", end="", file=sys.stderr, flush=True)
                last_report = now
except OSError as error:
    print(f"\nerror: cannot write {path}: {error}", file=sys.stderr)
    sys.exit(1)

elapsed = time.monotonic() - started
rate = received / elapsed if elapsed else 0
print(f"\rReceived: {format_bytes(received)} | Average: {format_bytes(rate)}/s", file=sys.stderr)
' "$output"
}

HOST=${STEAMOS_HOST:-}
SSH_USER=${STEAMOS_USER:-steamosadmin}
REMOTE_HOME=/home/deck
OUTPUT_DIR="$HOME/Desktop"
INCLUDE_DOT_STEAM_BACKUPS=false
DRY_RUN=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    -H|--host) [[ $# -ge 2 ]] || die "$1 requires a value"; HOST=$2; shift 2 ;;
    -u|--user) [[ $# -ge 2 ]] || die "$1 requires a value"; SSH_USER=$2; shift 2 ;;
    -r|--remote-home) [[ $# -ge 2 ]] || die "$1 requires a value"; REMOTE_HOME=$2; shift 2 ;;
    -o|--output-dir) [[ $# -ge 2 ]] || die "$1 requires a value"; OUTPUT_DIR=$2; shift 2 ;;
    --include-dot-steam-backups) INCLUDE_DOT_STEAM_BACKUPS=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[[ -n "$HOST" ]] || { usage >&2; exit 2; }
[[ "$REMOTE_HOME" =~ ^/home/[^/]+$ ]] || die "--remote-home must be a direct home directory such as /home/deck"
[[ "$SSH_USER" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || die "invalid SSH user: $SSH_USER"
require_cmd ssh
require_cmd tar
require_cmd zstd
require_cmd df
require_cmd python3

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR=$(cd "$OUTPUT_DIR" && pwd)
OUTPUT_FILESYSTEM=$(filesystem_type "$OUTPUT_DIR")
case "$OUTPUT_FILESYSTEM" in
  *fat32*|msdos|vfat|fat)
    die "$OUTPUT_DIR is on FAT32, which cannot store files larger than 4 GiB; use APFS, exFAT, or another filesystem that supports large files"
    ;;
esac
TARGET="$SSH_USER@$HOST"
SSH=(ssh -o ServerAliveInterval=15 -o ServerAliveCountMax=3 "$TARGET")
remote() { "${SSH[@]}" "$1"; }

SUDO_MODE=
SUDO_PASSWORD=
init_remote_sudo() {
  if remote 'sudo -n true' >/dev/null 2>&1; then SUDO_MODE=noninteractive; return; fi
  [[ -t 0 ]] || die "SteamOS sudo needs a password, but this script has no interactive terminal"
  printf 'SteamOS sudo password for %s: ' "$TARGET" >&2
  IFS= read -r -s SUDO_PASSWORD
  printf '\n' >&2
  SUDO_MODE=password
}
remote_sudo() {
  local script=$1 quoted
  printf -v quoted '%q' "$script"
  if [[ "$SUDO_MODE" == noninteractive ]]; then
    remote "sudo -n bash -c $quoted"
  else
    printf '%s\n' "$SUDO_PASSWORD" | "${SSH[@]}" "sudo -S -p '' bash -c $quoted"
  fi
}
cleanup() {
  [[ -n ${PARTIAL_FILE:-} && -e ${PARTIAL_FILE:-} ]] && rm -f "$PARTIAL_FILE"
  unset SUDO_PASSWORD
}
trap cleanup EXIT

init_remote_sudo
remote 'tar --version 2>/dev/null | grep -q "^tar (GNU tar)" && command -v zstd >/dev/null' ||
  die "SteamOS needs GNU tar and zstd"

if [[ "$INCLUDE_DOT_STEAM_BACKUPS" == true ]]; then
  printf -v du_script 'test -d %q && du -sk -- %q | awk '\''NR == 1 { print $1 }'\''' "$REMOTE_HOME" "$REMOTE_HOME"
else
  printf -v du_script 'test -d %q && du -sk --exclude='\''*/dot-steam.bak.*'\'' %q | awk '\''NR == 1 { print $1 }'\''' "$REMOTE_HOME" "$REMOTE_HOME"
fi
SOURCE_KIB=$(remote_sudo "$du_script")
[[ "$SOURCE_KIB" =~ ^[0-9]+$ ]] || die "could not determine disk usage for $REMOTE_HOME"

printf -v id_script 'stat -c '\''%%u %%g'\'' %q' "$REMOTE_HOME"
read -r HOME_UID HOME_GID <<<"$(remote_sudo "$id_script")"
[[ "$HOME_UID" =~ ^[0-9]+$ && "$HOME_GID" =~ ^[0-9]+$ ]] || die "could not determine owner of $REMOTE_HOME"

FREE_KIB=$(df -Pk "$OUTPUT_DIR" | awk 'NR == 2 { print $4 }')
[[ "$FREE_KIB" =~ ^[0-9]+$ ]] || die "could not determine free space in $OUTPUT_DIR"
REQUIRED_KIB=$(( SOURCE_KIB + (SOURCE_KIB + 19) / 20 ))
printf 'Remote home:      %s (%s used)\n' "$REMOTE_HOME" "$(human_kib "$SOURCE_KIB")"
printf 'Local free space: %s\n' "$(human_kib "$FREE_KIB")"
printf 'Required minimum: %s (source usage + 5%%)\n' "$(human_kib "$REQUIRED_KIB")"
(( FREE_KIB >= REQUIRED_KIB )) || die "not enough free space in $OUTPUT_DIR; backup was not started"
if [[ "$DRY_RUN" == true ]]; then
  printf 'Dry run: connection and capacity checks passed; no archive was created.\n'
  exit 0
fi

HOME_NAME=${REMOTE_HOME##*/}
STAMP=$(date +%Y%m%d-%H%M%S)
FINAL_FILE="$OUTPUT_DIR/steamos-${HOME_NAME}-home-${STAMP}.tar.zst"
PARTIAL_FILE="$FINAL_FILE.partial"
[[ ! -e "$FINAL_FILE" && ! -e "$PARTIAL_FILE" ]] || die "destination already exists: $FINAL_FILE"

printf -v archive_script 'set -Eeuo pipefail
home_name=%q
source_kib=%q
home_uid=%q
home_gid=%q
include_dot_steam_backups=%q
tmpdir=$(mktemp -d /tmp/steamos-home-backup.XXXXXX)
trap '\''rm -rf "$tmpdir"'\'' EXIT
printf '\''format=steamos-home-tar-zst-v1\nsource_disk_kib=%%s\nhome_uid=%%s\nhome_gid=%%s\nhome_name=%%s\n'\'' "$source_kib" "$home_uid" "$home_gid" "$home_name" >"$tmpdir/manifest"
exclude=()
[[ "$include_dot_steam_backups" == true ]] || exclude=(--exclude='\''*/dot-steam.bak.*'\'')
tar --warning=no-file-ignored --acls --xattrs --xattrs-include='\''*'\'' --numeric-owner --sparse "${exclude[@]}" \
  --transform="s,^manifest$,$home_name/.steamos-home-backup-manifest," \
  -C "$tmpdir" -cf - manifest -C /home "$home_name" | zstd -q -T0 -3' \
  "$HOME_NAME" "$SOURCE_KIB" "$HOME_UID" "$HOME_GID" "$INCLUDE_DOT_STEAM_BACKUPS"

printf 'Creating compressed archive on %s and streaming it to %s\n' "$HOST" "$FINAL_FILE"
printf 'Archive size is not known until compression finishes; reporting received bytes every 5 seconds.\n'
set +e
remote_sudo "$archive_script" | stream_to_file "$PARTIAL_FILE"
PIPELINE_STATUS=("${PIPESTATUS[@]}")
set -e
REMOTE_STATUS=${PIPELINE_STATUS[0]}
WRITE_STATUS=${PIPELINE_STATUS[1]}
if (( REMOTE_STATUS != 0 && WRITE_STATUS != 0 )); then
  die "the remote archive command failed (exit $REMOTE_STATUS) and writing the local archive failed (exit $WRITE_STATUS)"
elif (( REMOTE_STATUS != 0 )); then
  die "the remote archive command failed (exit $REMOTE_STATUS)"
elif (( WRITE_STATUS != 0 )); then
  die "writing the local archive failed (exit $WRITE_STATUS)"
fi
zstd -tq "$PARTIAL_FILE"
zstd -d -q -c "$PARTIAL_FILE" | tar -tf - >/dev/null
mv "$PARTIAL_FILE" "$FINAL_FILE"
PARTIAL_FILE=

if command -v shasum >/dev/null 2>&1; then
  CHECKSUM=$(shasum -a 256 "$FINAL_FILE" | awk '{print $1}')
else
  CHECKSUM=$(sha256sum "$FINAL_FILE" | awk '{print $1}')
fi
printf 'Backup complete: %s\nSHA-256: %s\n' "$FINAL_FILE" "$CHECKSUM"
