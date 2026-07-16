#!/usr/bin/env bash
# Repair the SteamOS dirlock SDDM integration when its autologin override is missing.
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: fix-steamos-encryption.sh --host HOST [options]

Repair a SteamOS dirlock/SDDM integration bug that can leave an encrypted
/home/deck at a black screen after boot. Affected dirlock-sddm-helper versions
expect /etc/sddm.conf.d/zz-steamos-autologin.conf, but some SteamOS installs
keep the session only in steamos.conf. With the home locked, the helper exits
before completing the SDDM handoff.

The script changes only an affected host. It creates the missing override with
the existing Session value and keeps it across SteamOS atomic A/B updates.

Options:
  -H, --host HOST       SteamOS hostname or IP (or STEAMOS_HOST).
  -u, --user USER       SSH user. Default: steamosadmin (STEAMOS_USER).
      --dry-run         Report whether the host is affected; make no changes.
      --restart-sddm    Restart SDDM after repairing. This ends the current
                        graphical session and returns to the login screen.
  -h, --help            Show this help.
EOF
}

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }

HOST=${STEAMOS_HOST:-}
SSH_USER=${STEAMOS_USER:-steamosadmin}
DRY_RUN=false
RESTART_SDDM=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -H|--host) [[ $# -ge 2 ]] || die "$1 requires a value"; HOST=$2; shift 2 ;;
    -u|--user) [[ $# -ge 2 ]] || die "$1 requires a value"; SSH_USER=$2; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --restart-sddm) RESTART_SDDM=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[[ -n "$HOST" ]] || { usage >&2; exit 2; }
[[ "$SSH_USER" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || die "invalid SSH user: $SSH_USER"
require_cmd ssh

TARGET="$SSH_USER@$HOST"
SSH=(ssh -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=3 "$TARGET")
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
cleanup() { unset SUDO_PASSWORD; }
trap cleanup EXIT

read -r -d '' REMOTE_TEMPLATE <<'REMOTE_SCRIPT' || true
set -Eeuo pipefail

helper=/usr/lib/steamos/dirlock-sddm-helper
sddm_conf=/etc/sddm.conf.d/steamos.conf
autologin_conf=/etc/sddm.conf.d/zz-steamos-autologin.conf
keep_conf=/etc/atomic-update.conf.d/50-steamos-dirlock-sddm-autologin.conf

get_autologin_value() {
  local file=$1 key=$2
  sed -n "/^\\[Autologin\\]$/,/^[[:space:]]*$/{s/^${key}=//p}" "$file" | tail -n 1
}

if [[ ! -x "$helper" ]]; then
  printf 'Not applicable: dirlock-sddm-helper is not installed.\n'
  exit 0
fi
if [[ ! -f "$sddm_conf" ]]; then
  printf 'Not applicable: %s is missing.\n' "$sddm_conf"
  exit 0
fi
if ! systemctl is-enabled -q dirlock-sddm.service; then
  printf 'Not applicable: dirlock-sddm.service is not enabled.\n'
  exit 0
fi
if [[ -e "$autologin_conf" ]]; then
  printf 'No repair needed: %s already exists.\n' "$autologin_conf"
  exit 0
fi

# Only repair the helper version that unconditionally reads the optional file.
if ! grep -Fq 'SDDM_AUTOLOGIN_CONF=/etc/sddm.conf.d/zz-steamos-autologin.conf' "$helper" ||
   ! grep -Fq '"$SDDM_AUTOLOGIN_CONF")' "$helper"; then
  printf 'No repair needed: the installed dirlock SDDM helper is not affected.\n'
  exit 0
fi

session=$(get_autologin_value "$sddm_conf" Session)
if [[ ! "$session" =~ ^[A-Za-z0-9._-]+$ ]]; then
  printf 'Cannot repair safely: no valid Autologin Session was found in %s.\n' "$sddm_conf" >&2
  exit 1
fi
user=$(get_autologin_value "$sddm_conf" User)
if [[ ! "$user" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]]; then
  printf 'Cannot repair safely: no valid Autologin User was found in %s.\n' "$sddm_conf" >&2
  exit 1
fi

printf 'Affected dirlock SDDM configuration detected.\n'
printf 'Autologin user: %s\n' "$user"
printf 'Session fallback: %s\n' "$session"
if [[ "$dry_run" == true ]]; then
  printf 'Dry run: no files changed.\n'
  exit 0
fi

tmp=$(mktemp "${autologin_conf}.XXXXXX")
trap 'rm -f "$tmp"' EXIT
printf '[Autologin]\nSession=%s\n' "$session" >"$tmp"
install -o root -g root -m 0644 "$tmp" "$autologin_conf"
rm -f "$tmp"
trap - EXIT

if [[ -d /etc/atomic-update.conf.d ]]; then
  tmp=$(mktemp "${keep_conf}.XXXXXX")
  trap 'rm -f "$tmp"' EXIT
  printf '%s\n%s\n' "$keep_conf" "$autologin_conf" >"$tmp"
  install -o root -g root -m 0644 "$tmp" "$keep_conf"
  rm -f "$tmp"
  trap - EXIT
  printf 'Installed atomic-update keep-list: %s\n' "$keep_conf"
fi

printf 'Installed SDDM autologin-session override: %s\n' "$autologin_conf"
if [[ "$restart_sddm" == true ]]; then
  printf 'Restarting SDDM; the current graphical session will close.\n'
  systemctl restart sddm
else
  printf 'Repair complete. Reboot, or rerun with --restart-sddm to return to the login screen now.\n'
fi
REMOTE_SCRIPT

printf -v REMOTE_SCRIPT 'dry_run=%q\nrestart_sddm=%q\n%s' "$DRY_RUN" "$RESTART_SDDM" "$REMOTE_TEMPLATE"
init_remote_sudo
remote_sudo "$REMOTE_SCRIPT"
