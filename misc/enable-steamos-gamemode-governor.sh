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
      --set-launch-options
                     Prepend gamemoderun to every installed game's launch
                     options after an interactive confirmation.
      --yes          Confirm --set-launch-options without prompting.
  -h, --help        Show this help.
EOF
}

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }

HOST=${STEAMOS_HOST:-}
SSH_USER=${STEAMOS_USER:-steamosadmin}
REMOVE=false
SET_LAUNCH_OPTIONS=false
ASSUME_YES=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    -H|--host) [[ $# -ge 2 ]] || die "$1 requires a value"; HOST=$2; shift 2 ;;
    -u|--user) [[ $# -ge 2 ]] || die "$1 requires a value"; SSH_USER=$2; shift 2 ;;
    --remove) REMOVE=true; shift ;;
    --set-launch-options) SET_LAUNCH_OPTIONS=true; shift ;;
    --yes) ASSUME_YES=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[[ -n "$HOST" ]] || { usage >&2; exit 2; }
[[ "$SSH_USER" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || die "invalid SSH user: $SSH_USER"
[[ "$REMOVE" == false || "$SET_LAUNCH_OPTIONS" == false ]] ||
  die "--remove and --set-launch-options cannot be used together"
[[ "$ASSUME_YES" == false || "$SET_LAUNCH_OPTIONS" == true ]] ||
  die "--yes requires --set-launch-options"
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

read -r -d '' LAUNCH_OPTIONS_SCRIPT <<'REMOTE_SCRIPT' || true
set -Eeuo pipefail

if pgrep -u deck -f 'SteamLaunch|steamwebhelper|pressure-vessel|/steam( |$)' >/dev/null 2>&1; then
  echo "Steam or a Steam game is still running; fully exit Steam before changing launch options" >&2
  exit 1
fi

python3 - <<'PYTHON'
from __future__ import annotations

import os
import re
import shutil
import stat
import time
from pathlib import Path


class VdfError(ValueError):
    pass


def parse_vdf(data: str):
    """Parse Valve KeyValues text into ordered [key, value] pairs."""
    index = 0
    length = len(data)

    def skip_space_and_comments():
        nonlocal index
        while index < length:
            if data[index].isspace():
                index += 1
            elif data.startswith("//", index):
                newline = data.find("\n", index + 2)
                index = length if newline == -1 else newline + 1
            else:
                return

    def token() -> str:
        nonlocal index
        skip_space_and_comments()
        if index >= length or data[index] in "{}":
            raise VdfError("expected a key or value")
        if data[index] != '"':
            start = index
            while index < length and not data[index].isspace() and data[index] not in "{}":
                index += 1
            return data[start:index]

        index += 1
        value = []
        while index < length:
            character = data[index]
            index += 1
            if character == '"':
                return "".join(value)
            if character == "\\" and index < length:
                escaped = data[index]
                index += 1
                value.append({"n": "\n", "t": "\t"}.get(escaped, escaped))
            else:
                value.append(character)
        raise VdfError("unterminated quoted string")

    def block(expect_close: bool):
        nonlocal index
        pairs = []
        while True:
            skip_space_and_comments()
            if index >= length:
                if expect_close:
                    raise VdfError("unterminated block")
                return pairs
            if data[index] == "}":
                if not expect_close:
                    raise VdfError("unexpected closing brace")
                index += 1
                return pairs

            key = token()
            skip_space_and_comments()
            if index < length and data[index] == "{":
                index += 1
                value = block(True)
            else:
                value = token()
            pairs.append([key, value])

    result = block(False)
    skip_space_and_comments()
    if index != length:
        raise VdfError("unexpected trailing data")
    return result


def quote(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'


def dump_vdf(pairs, indent: str = "") -> str:
    output = []
    for key, value in pairs:
        if isinstance(value, list):
            output.extend((f"{indent}{quote(key)}\n", f"{indent}{{\n", dump_vdf(value, indent + "\t"), f"{indent}}}\n"))
        else:
            output.append(f"{indent}{quote(key)}\t\t{quote(value)}\n")
    return "".join(output)


def find_blocks(pairs, name: str):
    for key, value in pairs:
        if key.lower() == name.lower() and isinstance(value, list):
            yield value
        if isinstance(value, list):
            yield from find_blocks(value, name)


def find_string_values(pairs, name: str):
    for key, value in pairs:
        if key.lower() == name.lower() and isinstance(value, str):
            yield value
        if isinstance(value, list):
            yield from find_string_values(value, name)


def update_launch_options(apps, app_ids: set[str]) -> int:
    changed = 0
    for app_id in sorted(app_ids, key=int):
        app = next((value for key, value in apps if key == app_id and isinstance(value, list)), None)
        if app is None:
            app = []
            apps.append([app_id, app])

        option = next((entry for entry in app if entry[0].lower() == "launchoptions" and isinstance(entry[1], str)), None)
        previous = option[1] if option is not None else ""
        if re.search(r"(?:^|\s)gamemoderun(?:\s|$)", previous):
            continue
        updated = "gamemoderun %command%" if not previous.strip() else f"gamemoderun {previous.strip()}"
        if option is None:
            app.append(["LaunchOptions", updated])
        else:
            option[1] = updated
        changed += 1
    return changed


steam_root = Path(os.path.realpath("/home/deck/.local/share/Steam"))
if not steam_root.is_dir():
    raise SystemExit(f"Steam root was not found: {steam_root}")

library_roots = {steam_root}
library_file = steam_root / "steamapps" / "libraryfolders.vdf"
if library_file.is_file():
    try:
        for path in find_string_values(parse_vdf(library_file.read_text(encoding="utf-8")), "path"):
            candidate = Path(path)
            if candidate.is_dir():
                library_roots.add(candidate)
    except (OSError, UnicodeDecodeError, VdfError) as error:
        raise SystemExit(f"could not parse {library_file}: {error}")

app_ids = set()
for library in library_roots:
    for manifest in (library / "steamapps").glob("appmanifest_*.acf"):
        match = re.fullmatch(r"appmanifest_(\d+)\.acf", manifest.name)
        if match:
            app_ids.add(match.group(1))
if not app_ids:
    raise SystemExit("no installed Steam app manifests were found")

configs = sorted(steam_root.glob("userdata/*/config/localconfig.vdf"))
if not configs:
    raise SystemExit("no Steam user localconfig.vdf files were found")

stamp = time.strftime("%Y%m%d-%H%M%S")
total = 0
for config in configs:
    try:
        tree = parse_vdf(config.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, VdfError) as error:
        raise SystemExit(f"could not parse {config}: {error}")

    app_blocks = list(find_blocks(tree, "apps"))
    if not app_blocks:
        print(f"Skipped {config}: no apps block")
        continue
    changed = sum(update_launch_options(apps, app_ids) for apps in app_blocks)
    if not changed:
        print(f"No launch-option changes needed in {config}")
        continue

    backup = config.with_name(f"{config.name}.pre-gamemode-{stamp}.bak")
    shutil.copy2(config, backup)
    original = config.stat()
    temporary = config.with_name(f".{config.name}.gamemode.tmp")
    temporary.write_text(dump_vdf(tree), encoding="utf-8")
    os.chmod(temporary, stat.S_IMODE(original.st_mode))
    os.chown(temporary, original.st_uid, original.st_gid)
    os.replace(temporary, config)
    print(f"Updated {changed} installed games in {config}; backup: {backup}")
    total += changed

print(f"GameMode launch options updated for {total} installed-game entries.")
PYTHON
REMOTE_SCRIPT

if [[ "$SET_LAUNCH_OPTIONS" == true && "$ASSUME_YES" == false ]]; then
  [[ -t 0 ]] || die "--set-launch-options needs a terminal confirmation; use --yes to confirm non-interactively"
  read -r -p "Fully exit Steam first. Prepend gamemoderun to every installed game's launch options? [y/N] " response
  [[ "$response" =~ ^[Yy]([Ee][Ss])?$ ]] || { printf 'No launch options were changed.\n'; SET_LAUNCH_OPTIONS=false; }
fi

init_remote_sudo
if [[ "$REMOVE" == true ]]; then
  remote_sudo "$REMOVE_SCRIPT"
  printf 'Removed the GameMode CPU-governor authorization from %s.\n' "$TARGET"
else
  remote_sudo "$ENABLE_SCRIPT"
  if [[ "$SET_LAUNCH_OPTIONS" == true ]]; then
    remote_sudo "$LAUNCH_OPTIONS_SCRIPT"
    printf 'Enabled GameMode authorization and updated Steam launch options on %s.\n' "$TARGET"
  else
    printf 'Enabled GameMode CPU-governor authorization on %s. Relaunch games to apply it.\n' "$TARGET"
  fi
fi
