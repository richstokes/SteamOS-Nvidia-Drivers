#!/usr/bin/env bash
# Stream a SteamOS home-directory ZIP over SSH to this machine.
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: backup-steamos-home.sh --host HOST [options]

Create a dated ZIP backup of a SteamOS user's home. SteamOS creates the ZIP and
streams it directly to this machine; no large temporary archive is left there.

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
[[ "$REMOTE_HOME" =~ ^/home/[^/]+$ ]] ||
  die "--remote-home must be a direct home directory such as /home/deck"
[[ "$SSH_USER" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || die "invalid SSH user: $SSH_USER"
require_cmd ssh
require_cmd unzip
require_cmd df

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR=$(cd "$OUTPUT_DIR" && pwd)
TARGET="$SSH_USER@$HOST"
SSH=(ssh -o ServerAliveInterval=15 -o ServerAliveCountMax=3 "$TARGET")
remote() { "${SSH[@]}" "$1"; }

SUDO_MODE=
SUDO_PASSWORD=
init_remote_sudo() {
  if remote 'sudo -n true' >/dev/null 2>&1; then
    SUDO_MODE=noninteractive
    return
  fi
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
remote 'command -v zip >/dev/null' || die "SteamOS is missing zip (install the 'zip' package first)"

if [[ "$INCLUDE_DOT_STEAM_BACKUPS" == true ]]; then
  printf -v du_script 'test -d %q && du -sk -- %q | awk '\''NR == 1 { print $1 }'\''' "$REMOTE_HOME" "$REMOTE_HOME"
else
  printf -v du_script 'test -d %q && du -sk --exclude='\''*/dot-steam.bak.*'\'' %q | awk '\''NR == 1 { print $1 }'\''' "$REMOTE_HOME" "$REMOTE_HOME"
fi
SOURCE_KIB=$(remote_sudo "$du_script")
[[ "$SOURCE_KIB" =~ ^[0-9]+$ ]] || die "could not determine disk usage for $REMOTE_HOME"

FREE_KIB=$(df -Pk "$OUTPUT_DIR" | awk 'NR == 2 { print $4 }')
[[ "$FREE_KIB" =~ ^[0-9]+$ ]] || die "could not determine free space in $OUTPUT_DIR"
# ZIP output can be slightly larger than its inputs, especially for incompressible files.
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
FINAL_FILE="$OUTPUT_DIR/steamos-${HOME_NAME}-home-${STAMP}.zip"
PARTIAL_FILE="$FINAL_FILE.partial"
[[ ! -e "$FINAL_FILE" && ! -e "$PARTIAL_FILE" ]] || die "destination already exists: $FINAL_FILE"

if [[ "$INCLUDE_DOT_STEAM_BACKUPS" == true ]]; then
  printf -v zip_script 'cd /home && exec zip -q -r -y - %q' "$HOME_NAME"
else
  printf -v zip_script 'cd /home && exec zip -q -r -y - %q -x '\''*/dot-steam.bak.*/*'\''' "$HOME_NAME"
fi
printf 'Creating compressed archive on %s and streaming it to %s\n' "$HOST" "$FINAL_FILE"
remote_sudo "$zip_script" >"$PARTIAL_FILE"
unzip -tqq "$PARTIAL_FILE" >/dev/null || die "the received ZIP failed validation"
mv "$PARTIAL_FILE" "$FINAL_FILE"
PARTIAL_FILE=

if command -v shasum >/dev/null 2>&1; then
  CHECKSUM=$(shasum -a 256 "$FINAL_FILE" | awk '{print $1}')
elif command -v sha256sum >/dev/null 2>&1; then
  CHECKSUM=$(sha256sum "$FINAL_FILE" | awk '{print $1}')
else
  CHECKSUM='(no SHA-256 tool available)'
fi
printf 'Backup complete: %s\nSHA-256: %s\n' "$FINAL_FILE" "$CHECKSUM"
