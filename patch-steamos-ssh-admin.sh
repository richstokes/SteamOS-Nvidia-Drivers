#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage:
  patch-steamos-ssh-admin.sh [options] IMAGE

Patches a SteamOS recovery/OOBE disk image so it boots with SSH enabled and a
sudo-capable admin user.

Options:
  -o, --output PATH     Write changes to PATH instead of modifying IMAGE in place.
  -u, --user NAME       Admin username to create. Default: steamosadmin
  -p, --password PASS   Admin password to set. Default: steamtest123
  -h, --help            Show this help.

Example:
  ./patch-steamos-ssh-admin.sh \
    -o ~/Downloads/steamdeck-oobe-repair-ssh.img \
    ~/Downloads/steamdeck-oobe-repair.img

Then SSH with:
  ssh steamosadmin@<machine-ip>
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

IMAGE=
OUTPUT=
ADMIN_USER=steamosadmin
ADMIN_PASSWORD=steamtest123

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--output)
      [[ $# -ge 2 ]] || die "$1 requires a path"
      OUTPUT=$2
      shift 2
      ;;
    -u|--user)
      [[ $# -ge 2 ]] || die "$1 requires a username"
      ADMIN_USER=$2
      shift 2
      ;;
    -p|--password)
      [[ $# -ge 2 ]] || die "$1 requires a password"
      ADMIN_PASSWORD=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      die "unknown option: $1"
      ;;
    *)
      [[ -z "$IMAGE" ]] || die "only one IMAGE may be provided"
      IMAGE=$1
      shift
      ;;
  esac
done

[[ -n "$IMAGE" ]] || { usage >&2; exit 2; }
[[ -f "$IMAGE" ]] || die "image not found: $IMAGE"
[[ "$ADMIN_USER" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || die "invalid Linux username: $ADMIN_USER"

require_cmd docker

if [[ -n "$OUTPUT" ]]; then
  mkdir -p "$(dirname "$OUTPUT")"
  cp -p "$IMAGE" "$OUTPUT"
  IMAGE=$OUTPUT
fi

IMAGE_DIR=$(cd "$(dirname "$IMAGE")" && pwd)
IMAGE_BASENAME=$(basename "$IMAGE")

printf 'Patching image: %s\n' "$IMAGE"
printf 'Admin user:     %s\n' "$ADMIN_USER"
printf 'SSH password:   %s\n' "$ADMIN_PASSWORD"

docker run --rm -i --privileged \
  -v "$IMAGE_DIR:/images" \
  -e IMAGE_BASENAME="$IMAGE_BASENAME" \
  -e ADMIN_USER="$ADMIN_USER" \
  -e ADMIN_PASSWORD="$ADMIN_PASSWORD" \
  debian:bookworm-slim bash -s <<'DOCKER_SCRIPT'
set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive
apt-get update >/dev/null
apt-get install -y --no-install-recommends \
  bash btrfs-progs coreutils gdisk openssl sudo util-linux >/dev/null

img="/images/$IMAGE_BASENAME"
[[ -f "$img" ]] || { echo "image not found inside container: $img" >&2; exit 1; }

read -r root_start root_end < <(
  sgdisk -p "$img" | awk '$7 == "rootfs-A" { print $2, $3; found=1 } END { if (!found) exit 1 }'
)

sector_size=512
offset=$((root_start * sector_size))
size=$(((root_end - root_start + 1) * sector_size))
password_hash=$(openssl passwd -6 "$ADMIN_PASSWORD")

loop=$(losetup --find --show --offset "$offset" --sizelimit "$size" "$img")
cleanup() {
  set +e
  mountpoint -q /mnt/root && umount /mnt/root
  losetup -d "$loop" 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p /mnt/root
mount -o rw "$loop" /mnt/root

old_ro=$(btrfs property get /mnt/root ro || true)
btrfs property set /mnt/root ro false || true

install -d -m 0755 /mnt/root/usr/local/sbin
cat >/mnt/root/usr/local/sbin/steamos-remote-admin-setup <<EOF
#!/bin/bash
set -Eeuo pipefail

USERNAME='$ADMIN_USER'
PASSWORD_HASH='$password_hash'
LOG=/var/log/steamos-remote-admin-setup.log

log() {
    printf '[%(%Y-%m-%dT%H:%M:%S%z)T] %s\n' -1 "\$*" | tee -a "\$LOG"
}

make_root_writable() {
    if command -v steamos-readonly >/dev/null 2>&1 && steamos-readonly status >/dev/null 2>&1; then
        steamos-readonly disable
    elif findmnt -no OPTIONS / | tr ',' '\n' | grep -qx ro; then
        mount -o remount,rw /
    fi
}

ensure_user() {
    if ! getent passwd "\$USERNAME" >/dev/null; then
        log "Creating \$USERNAME"
        useradd -m -G wheel -s /bin/bash -p "\$PASSWORD_HASH" "\$USERNAME"
    else
        log "\$USERNAME already exists"
        usermod -aG wheel "\$USERNAME"
    fi

    log "Setting password for \$USERNAME"
    usermod -p "\$PASSWORD_HASH" "\$USERNAME"
    install -d -m 0700 -o "\$USERNAME" -g "\$USERNAME" "/home/\$USERNAME"
}

ensure_sudo() {
    install -d -m 0755 /etc/sudoers.d
    cat >/etc/sudoers.d/90-steamos-remote-admin <<'SUDOEOF'
%wheel ALL=(ALL:ALL) ALL
SUDOEOF
    chmod 0440 /etc/sudoers.d/90-steamos-remote-admin
}

ensure_ssh() {
    install -d -m 0755 /etc/ssh/sshd_config.d
    cat >/etc/ssh/sshd_config.d/zz-steamos-remote-admin.conf <<'SSHEOF'
PasswordAuthentication yes
PermitRootLogin no
PubkeyAuthentication yes
SSHEOF

    systemctl enable sshd.service >/dev/null 2>&1 || true
    systemctl enable sshdgenkeys.service >/dev/null 2>&1 || true
}

main() {
    install -d -m 0755 "\$(dirname "\$LOG")"
    make_root_writable
    ensure_sudo
    ensure_ssh
    ensure_user
    log "Remote admin setup complete"
}

main "\$@"
EOF
chmod 0755 /mnt/root/usr/local/sbin/steamos-remote-admin-setup

install -d -m 0755 /mnt/root/usr/lib/systemd/system
cat >/mnt/root/usr/lib/systemd/system/steamos-remote-admin-setup.service <<'EOF'
[Unit]
Description=Create SteamOS remote admin account and enable SSH
DefaultDependencies=no
After=local-fs.target
Before=sshd.service multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/steamos-remote-admin-setup

[Install]
WantedBy=multi-user.target
EOF

install -d -m 0755 /mnt/root/etc/ssh/sshd_config.d
cat >/mnt/root/etc/ssh/sshd_config.d/zz-steamos-remote-admin.conf <<'EOF'
PasswordAuthentication yes
PermitRootLogin no
PubkeyAuthentication yes
EOF

install -d -m 0755 /mnt/root/etc/sudoers.d
cat >/mnt/root/etc/sudoers.d/90-steamos-remote-admin <<'EOF'
%wheel ALL=(ALL:ALL) ALL
EOF
chmod 0440 /mnt/root/etc/sudoers.d/90-steamos-remote-admin

install -d -m 0755 /mnt/root/etc/systemd/system/multi-user.target.wants
ln -sfn /usr/lib/systemd/system/sshd.service \
  /mnt/root/etc/systemd/system/multi-user.target.wants/sshd.service
ln -sfn /usr/lib/systemd/system/sshdgenkeys.service \
  /mnt/root/etc/systemd/system/multi-user.target.wants/sshdgenkeys.service
ln -sfn /usr/lib/systemd/system/steamos-remote-admin-setup.service \
  /mnt/root/etc/systemd/system/multi-user.target.wants/steamos-remote-admin-setup.service

bash -n /mnt/root/usr/local/sbin/steamos-remote-admin-setup
visudo -cf /mnt/root/etc/sudoers.d/90-steamos-remote-admin >/dev/null
test -L /mnt/root/etc/systemd/system/multi-user.target.wants/sshd.service
test -L /mnt/root/etc/systemd/system/multi-user.target.wants/sshdgenkeys.service
test -L /mnt/root/etc/systemd/system/multi-user.target.wants/steamos-remote-admin-setup.service
sgdisk -v "$img" >/dev/null

sync
if [[ "$old_ro" == "ro=true" ]]; then
  btrfs property set /mnt/root ro true
fi

echo "Patched rootfs-A sectors $root_start-$root_end"
DOCKER_SCRIPT

printf 'Done.\n'
printf 'SSH login: ssh %s@<machine-ip>\n' "$ADMIN_USER"
printf 'Password:  %s\n' "$ADMIN_PASSWORD"
