#!/usr/bin/env bash
# Restore a ZIP made by backup-steamos-home.sh to SteamOS over SSH.
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: restore-steamos-home.sh --host HOST BACKUP.zip [options]

Validate and restore a SteamOS home backup created by backup-steamos-home.sh.
The default merge overwrites matching files but retains files absent from the
backup. --replace moves the existing home aside before restoring.

Options:
  -H, --host HOST          SteamOS hostname or IP (or STEAMOS_HOST).
  -u, --user USER          SSH user. Default: steamosadmin (STEAMOS_USER).
  -r, --remote-home PATH   Restore target. Default: /home/deck.
      --replace            Move the existing target aside before restoring.
      --dry-run            Validate locally and display the planned action only.
  -h, --help               Show this help.
EOF
}

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }
human_bytes() {
  awk -v n="$1" 'BEGIN { split("B KiB MiB GiB TiB", u, " "); i=1; while (n >= 1024 && i < 5) { n /= 1024; i++ } printf "%.1f %s", n, u[i] }'
}

HOST=${STEAMOS_HOST:-}
SSH_USER=${STEAMOS_USER:-steamosadmin}
REMOTE_HOME=/home/deck
REPLACE=false
DRY_RUN=false
BACKUP=
while [[ $# -gt 0 ]]; do
  case "$1" in
    -H|--host) [[ $# -ge 2 ]] || die "$1 requires a value"; HOST=$2; shift 2 ;;
    -u|--user) [[ $# -ge 2 ]] || die "$1 requires a value"; SSH_USER=$2; shift 2 ;;
    -r|--remote-home) [[ $# -ge 2 ]] || die "$1 requires a value"; REMOTE_HOME=$2; shift 2 ;;
    --replace) REPLACE=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown option: $1" ;;
    *) [[ -z "$BACKUP" ]] || die "only one BACKUP.zip may be supplied"; BACKUP=$1; shift ;;
  esac
done

[[ -n "$HOST" && -n "$BACKUP" ]] || { usage >&2; exit 2; }
[[ -f "$BACKUP" ]] || die "backup file not found: $BACKUP"
[[ "$BACKUP" == *.zip ]] || die "backup must be a .zip file"
[[ "$REMOTE_HOME" =~ ^/home/[^/]+$ ]] ||
  die "--remote-home must be a direct home directory such as /home/deck"
[[ "$SSH_USER" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || die "invalid SSH user: $SSH_USER"
require_cmd python3
require_cmd ssh
require_cmd scp

BACKUP=$(cd "$(dirname "$BACKUP")" && pwd)/$(basename "$BACKUP")
HOME_NAME=${REMOTE_HOME##*/}
# Reject path traversal and archives for another home. Print uncompressed size.
ARCHIVE_BYTES=$(python3 - "$BACKUP" "$HOME_NAME" <<'PY'
import sys
import zipfile
from pathlib import PurePosixPath

archive, expected_home = sys.argv[1:]
try:
    with zipfile.ZipFile(archive) as zf:
        total = 0
        seen = False
        for info in zf.infolist():
            path = PurePosixPath(info.filename)
            if path.is_absolute() or '..' in path.parts or not path.parts:
                raise ValueError(f'unsafe archive entry: {info.filename!r}')
            if path.parts[0] != expected_home:
                raise ValueError(
                    f'archive contains {info.filename!r}; expected only {expected_home!r}')
            total += info.file_size
            seen = True
        if not seen:
            raise ValueError('archive is empty')
except (OSError, ValueError, zipfile.BadZipFile) as exc:
    print(f'error: {exc}', file=sys.stderr)
    sys.exit(1)
print(total)
PY
)
[[ "$ARCHIVE_BYTES" =~ ^[0-9]+$ ]] || die "could not inspect archive"
LOCAL_BYTES=$(wc -c <"$BACKUP" | tr -d ' ')

printf 'Archive:              %s\n' "$BACKUP"
printf 'Uncompressed payload: %s\n' "$(human_bytes "$ARCHIVE_BYTES")"
printf 'Target:               %s on %s\n' "$REMOTE_HOME" "$HOST"
if [[ "$DRY_RUN" == true ]]; then
  printf 'Dry run: archive is valid; no files will be copied or changed.\n'
  exit 0
fi

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

REMOTE_STAGE="/home/$SSH_USER/.cache/steamos-home-restore"
REMOTE_ARCHIVE="$REMOTE_STAGE/$(basename "$BACKUP")"
cleanup() {
  if [[ -n ${REMOTE_ARCHIVE:-} ]]; then
    remote "rm -f $(printf '%q' "$REMOTE_ARCHIVE")" >/dev/null 2>&1 || true
  fi
  unset SUDO_PASSWORD
}
trap cleanup EXIT

init_remote_sudo
remote 'command -v unzip >/dev/null' || die "SteamOS is missing unzip (install the 'unzip' package first)"
remote "mkdir -p $(printf '%q' "$REMOTE_STAGE")"

printf -v space_script 'df -Pk %q | awk '\''NR == 2 { print $4 * 1024 }'\''' "$REMOTE_STAGE"
REMOTE_FREE_BYTES=$(remote_sudo "$space_script")
# Staging ZIP + extracted payload + 5%% safety margin.
REQUIRED_REMOTE_BYTES=$(( ARCHIVE_BYTES + LOCAL_BYTES + (ARCHIVE_BYTES + LOCAL_BYTES + 19) / 20 ))
[[ "$REMOTE_FREE_BYTES" =~ ^[0-9]+$ ]] || die "could not determine free space on SteamOS"
printf 'SteamOS free space:   %s\n' "$(human_bytes "$REMOTE_FREE_BYTES")"
printf 'Required minimum:     %s\n' "$(human_bytes "$REQUIRED_REMOTE_BYTES")"
(( REMOTE_FREE_BYTES >= REQUIRED_REMOTE_BYTES )) || die "not enough free space on SteamOS; restore was not started"

printf 'Copying archive to SteamOS...\n'
scp "$BACKUP" "$TARGET:$REMOTE_ARCHIVE"

STAMP=$(date +%Y%m%d-%H%M%S)
printf -v restore_script 'set -Eeuo pipefail
archive=%q
target=%q
home_name=%q
replace=%q
backup_name=%q
unzip -tqq "$archive" >/dev/null
owner=$(stat -c "%%U" "$target" 2>/dev/null || true)
group=$(stat -c "%%G" "$target" 2>/dev/null || true)
if [[ -z "$owner" || "$owner" == UNKNOWN || -z "$group" || "$group" == UNKNOWN ]]; then
  owner="$home_name"
  group="$home_name"
fi
getent passwd "$owner" >/dev/null || { echo "target owner does not exist: $owner" >&2; exit 1; }
if [[ "$replace" == true && -e "$target" ]]; then
  mv "$target" "/home/.${home_name}.pre-restore-${backup_name}"
fi
install -d -m 0755 /home
unzip -oq "$archive" -d /home
chown -R "$owner:$group" "$target"' \
  "$REMOTE_ARCHIVE" "$REMOTE_HOME" "$HOME_NAME" "$REPLACE" "$STAMP"

printf 'Extracting backup on SteamOS...\n'
remote_sudo "$restore_script"
printf 'Restore complete: %s\n' "$REMOTE_HOME"
if [[ "$REPLACE" == true ]]; then
  printf 'Previous home (if present): /home/.%s.pre-restore-%s\n' "$HOME_NAME" "$STAMP"
fi
