#!/usr/bin/env bash
# Allow SteamOS's deck session to use GameMode's CPU-governor helper over SSH.
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: enable-steamos-gamemode-governor.sh --host HOST [options]

Grant SteamOS's deck user access to GameMode's CPU-governor helper. The rule is
kept across SteamOS atomic A/B updates. This does not grant general pkexec or
administrator access.

Options:
  -H, --host HOST   SteamOS hostname or IP (or STEAMOS_HOST).
  -u, --user USER   SSH user. Default: steamosadmin (STEAMOS_USER).
      --remove      Remove this GameMode authorization and its keep-list.
  -h, --help        Show this help.
EOF
}

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }

HOST=${STEAMOS_HOST:-}
SSH_USER=${STEAMOS_USER:-steamosadmin}
REMOVE=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    -H|--host) [[ $# -ge 2 ]] || die "$1 requires a value"; HOST=$2; shift 2 ;;
    -u|--user) [[ $# -ge 2 ]] || die "$1 requires a value"; SSH_USER=$2; shift 2 ;;
    --remove) REMOVE=true; shift ;;
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

read -r -d '' ENABLE_SCRIPT <<'REMOTE_SCRIPT' || true
set -Eeuo pipefail
id deck >/dev/null 2>&1 || { echo "deck user was not found" >&2; exit 1; }
test -f /usr/share/polkit-1/actions/com.feralinteractive.GameMode.policy || {
  echo "GameMode Polkit policy was not found" >&2
  exit 1
}

install -d -m 0755 /etc/polkit-1/rules.d
cat >/etc/polkit-1/rules.d/50-steamos-gamemode-governor.rules <<'RULE'
polkit.addRule(function(action, subject) {
    if (action.id == "com.feralinteractive.GameMode.governor-helper" &&
        subject.user == "deck") {
        return polkit.Result.YES;
    }

    return polkit.Result.NOT_HANDLED;
});
RULE
chmod 0644 /etc/polkit-1/rules.d/50-steamos-gamemode-governor.rules

if [[ -d /etc/atomic-update.conf.d ]]; then
  cat >/etc/atomic-update.conf.d/50-steamos-gamemode-governor.conf <<'KEEP_LIST'
/etc/atomic-update.conf.d/50-steamos-gamemode-governor.conf
/etc/polkit-1/rules.d/50-steamos-gamemode-governor.rules
KEEP_LIST
fi

# Migrate the rule installed by the earlier NVIDIA-integrated implementation.
legacy=/etc/polkit-1/rules.d/50-steamos-nvidia-gamemode-governor.rules
rm -f "$legacy"
keep=/etc/atomic-update.conf.d/90-steamos-nvidia.conf
if [[ -f "$keep" ]]; then
  tmp=$(mktemp "${keep}.XXXXXX")
  grep -Fvx "$legacy" "$keep" >"$tmp" || true
  install -m 0644 "$tmp" "$keep"
  rm -f "$tmp"
fi
REMOTE_SCRIPT

read -r -d '' REMOVE_SCRIPT <<'REMOTE_SCRIPT' || true
set -Eeuo pipefail
rm -f /etc/polkit-1/rules.d/50-steamos-gamemode-governor.rules
rm -f /etc/atomic-update.conf.d/50-steamos-gamemode-governor.conf

# Clean up the filename used by the earlier NVIDIA-integrated implementation.
legacy=/etc/polkit-1/rules.d/50-steamos-nvidia-gamemode-governor.rules
rm -f "$legacy"
keep=/etc/atomic-update.conf.d/90-steamos-nvidia.conf
if [[ -f "$keep" ]]; then
  tmp=$(mktemp "${keep}.XXXXXX")
  grep -Fvx "$legacy" "$keep" >"$tmp" || true
  install -m 0644 "$tmp" "$keep"
  rm -f "$tmp"
fi
REMOTE_SCRIPT

init_remote_sudo
if [[ "$REMOVE" == true ]]; then
  remote_sudo "$REMOVE_SCRIPT"
  printf 'Removed the GameMode CPU-governor authorization from %s.\n' "$TARGET"
else
  remote_sudo "$ENABLE_SCRIPT"
  printf 'Enabled GameMode CPU-governor authorization on %s. Relaunch games to apply it.\n' "$TARGET"
fi
