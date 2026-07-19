#!/usr/bin/env bash
set -Eeuo pipefail

LOG=${STEAMOS_NVIDIA_LOG:-/var/log/steamos-nvidia-install.log}
LOCK=${STEAMOS_NVIDIA_LOCK:-/run/steamos-nvidia-install.lock}
STATE_DIR=${STEAMOS_NVIDIA_STATE_DIR:-/home/.steamos-nvidia}
DKMS_DIR=${STEAMOS_NVIDIA_DKMS_DIR:-$STATE_DIR/dkms}
DKMS_TMP_DIR=${STEAMOS_NVIDIA_DKMS_TMP_DIR:-/var/tmp/steamos-nvidia-dkms}
OFFLOAD_DIR=${STEAMOS_NVIDIA_OFFLOAD_DIR:-$STATE_DIR/offload}
PERSISTENT_INSTALL=${STEAMOS_NVIDIA_PERSISTENT_INSTALL:-$STATE_DIR/install}
FALLBACK_MARKER=${STEAMOS_NVIDIA_FALLBACK_MARKER:-$STATE_DIR/fallback-nouveau-requested}
ARCH_NVIDIA_DIR=${STEAMOS_NVIDIA_ARCH_DIR:-$STATE_DIR/arch-nvidia}
ARCH_NVIDIA_DB=${STEAMOS_NVIDIA_ARCH_DB:-$ARCH_NVIDIA_DIR/db}
ARCH_NVIDIA_CACHE=${STEAMOS_NVIDIA_ARCH_CACHE:-$ARCH_NVIDIA_DIR/cache}
ARCH_NVIDIA_CONFIG=${STEAMOS_NVIDIA_ARCH_CONFIG:-$ARCH_NVIDIA_DIR/pacman.conf}
BUILD_PACKAGE_STATE=${STEAMOS_NVIDIA_BUILD_PACKAGE_STATE:-$STATE_DIR/build-packages-installed-by-script}
RUNTIME_OFFLOAD_MARKER=${STEAMOS_NVIDIA_RUNTIME_OFFLOAD_MARKER:-$STATE_DIR/runtime-offload-build-id}
DKMS_PACKAGE=nvidia-open-dkms
REBOOT=${STEAMOS_NVIDIA_REBOOT:-prompt} # prompt, yes, no
RESTORE_READONLY=${STEAMOS_NVIDIA_RESTORE_READONLY:-yes} # yes, no

ARCH_NVIDIA_PACKAGES=(
  nvidia-utils
  lib32-nvidia-utils
  nvidia-settings
  libva-nvidia-driver
  egl-wayland
  egl-wayland2
  nvidia-open-dkms
)

BUILD_PACKAGES=(
  gcc
  make
  patch
  pahole
)

NON_NVIDIA_GPU_PACKAGES=(
  libva-intel-driver
  mesa-utils
  vulkan-intel
  vulkan-mesa-implicit-layers
  vulkan-radeon
  vulkan-virtio
)

log() {
  install -d -m 0755 "$(dirname "$LOG")"
  printf '[%(%Y-%m-%dT%H:%M:%S%z)T] %s\n' -1 "$*" | tee -a "$LOG"
}

die() {
  log "ERROR: $*"
  exit 1
}

on_error() {
  local line=$1 status=$2
  log "ERROR: command failed at line $line with status $status"
  exit "$status"
}

acquire_lock() {
  install -d -m 0755 "$(dirname "$LOCK")"
  exec 9>"$LOCK"
  flock -n 9 || die "Another $0 run is already active"
}

require_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    exec sudo -E bash "$0" "$@"
  fi
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

install_self() {
  local destination=$1 source
  source=$(readlink -f "$0")
  install -d -m 0755 "$(dirname "$destination")"

  if [[ -e "$destination" && "$(readlink -f "$destination")" == "$source" ]]; then
    return 0
  fi

  install -m 0755 "$source" "$destination"
}

write_file_atomically() {
  local destination=$1 mode=$2 directory temporary
  directory=$(dirname "$destination")
  install -d -m 0755 "$directory"
  temporary=$(mktemp "$directory/.${destination##*/}.XXXXXX")

  if ! cat >"$temporary"; then
    rm -f "$temporary"
    return 1
  fi

  chmod "$mode" "$temporary" || {
    rm -f "$temporary"
    return 1
  }
  mv -f "$temporary" "$destination"
}

has_nvidia_gpu() {
  local vendor
  for vendor in /sys/bus/pci/devices/*/vendor; do
    [[ -r "$vendor" ]] || continue
    [[ "$(cat "$vendor")" == "0x10de" ]] && return 0
  done
  return 1
}

nvidia_only_graphics() {
  local dev class vendor seen=0
  for dev in /sys/bus/pci/devices/*; do
    [[ -r "$dev/class" && -r "$dev/vendor" ]] || continue
    class=$(<"$dev/class")
    case "$class" in
      0x03*)
        seen=1
        vendor=$(<"$dev/vendor")
        [[ "$vendor" == "0x10de" ]] || return 1
        ;;
    esac
  done

  [[ "$seen" -eq 1 ]]
}

root_free_mib() {
  df -Pm / | awk 'NR == 2 { print $4 }'
}

runtime_build_id() {
  local build_id=

  if [[ -r /etc/os-release ]]; then
    build_id=$(sed -n 's/^BUILD_ID=//p' /etc/os-release | tr -d '"' | head -n1)
  fi
  build_id=${build_id:-$(uname -r)}
  printf '%s' "$build_id" | tr -c 'A-Za-z0-9._-' '_'
}

is_exact_mountpoint() {
  [[ "$(findmnt -rn -T "$1" -o TARGET 2>/dev/null || true)" == "$1" ]]
}

make_root_writable() {
  if command -v steamos-readonly >/dev/null 2>&1; then
    steamos-readonly disable || true
  elif findmnt -no OPTIONS / | tr ',' '\n' | grep -qx ro; then
    mount -o remount,rw /
  fi
}

restore_root_readonly() {
  case "$RESTORE_READONLY" in
    yes)
      ;;
    no)
      log "Leaving SteamOS read-only mode disabled by request"
      return 0
      ;;
    *)
      die "Invalid STEAMOS_NVIDIA_RESTORE_READONLY value: $RESTORE_READONLY"
      ;;
  esac

  if ! command -v steamos-readonly >/dev/null 2>&1; then
    log "SteamOS read-only helper is unavailable; root remains writable"
    return 0
  fi

  if steamos-readonly enable; then
    log "Restored SteamOS read-only mode"
  else
    log "WARNING: could not restore SteamOS read-only mode"
  fi
}

init_pacman_keyring() {
  if [[ -s /etc/pacman.d/gnupg/pubring.gpg ]]; then
    return 0
  fi

  log "Initializing pacman keyring"
  install -d -m 0755 /etc/pacman.d/gnupg
  pacman-key --init
  pacman-key --populate archlinux holo
}

kernel_pkgbase() {
  local kernel=$1
  if [[ -r /usr/lib/modules/$kernel/pkgbase ]]; then
    cat "/usr/lib/modules/$kernel/pkgbase"
    return 0
  fi

  pacman -Qoq "/usr/lib/modules/$kernel" 2>/dev/null | head -n1
}

header_package_for_kernel() {
  local pkgbase=$1
  local candidate="${pkgbase}-headers"
  if pacman -Si "$candidate" >/dev/null 2>&1; then
    printf '%s\n' "$candidate"
    return 0
  fi

  die "Could not find matching kernel headers for package base '$pkgbase'"
}

configure_dkms_workspace() {
  install -d -m 0755 "$STATE_DIR"
  install -d -m 0755 "$DKMS_DIR" "$DKMS_TMP_DIR" /etc/dkms/framework.conf.d

  cat >/etc/dkms/framework.conf.d/90-steamos-nvidia.conf <<EOF
# Keep DKMS build state off SteamOS's tiny /var partition.
dkms_tree="$DKMS_DIR"
tmp_location="$DKMS_TMP_DIR"
EOF

  if [[ "$DKMS_DIR" != /var/lib/dkms && -d /var/lib/dkms && ! -L /var/lib/dkms ]]; then
    log "Migrating existing DKMS state from /var/lib/dkms to $DKMS_DIR"
    cp -a /var/lib/dkms/. "$DKMS_DIR"/
    rm -rf /var/lib/dkms
    install -d -m 0755 /var/lib/dkms
  fi
}

install_build_stack() {
  local kernel pkgbase headers pkg
  local cleanup_candidates=()
  kernel=$(uname -r)
  pkgbase=$(kernel_pkgbase "$kernel")
  headers=$(header_package_for_kernel "$pkgbase")
  cleanup_candidates=("$headers" "${BUILD_PACKAGES[@]}" libisl libmpc)

  # Persist ownership before starting the transaction. If this run is
  # interrupted, a later successful run can still remove packages that this
  # installer introduced without touching packages the user already had.
  {
    [[ ! -r "$BUILD_PACKAGE_STATE" ]] || cat "$BUILD_PACKAGE_STATE"
    for pkg in "${cleanup_candidates[@]}"; do
      pacman -Q "$pkg" >/dev/null 2>&1 || printf '%s\n' "$pkg"
    done
  } | sort -u | write_file_atomically "$BUILD_PACKAGE_STATE" 0644

  log "Installing SteamOS DKMS build stack for $kernel using $headers"
  pacman -Sy --noconfirm
  pacman -S --noconfirm "$headers" dkms "${BUILD_PACKAGES[@]}"
}

prepare_arch_nvidia_bundle() {
  local steam_db

  log "Preparing current Arch NVIDIA package bundle in $ARCH_NVIDIA_DIR"
  steam_db=$(pacman-conf DBPath)
  [[ -d "$steam_db/local" ]] || die "SteamOS pacman database is missing: $steam_db/local"

  rm -rf "$ARCH_NVIDIA_DIR"
  install -d -m 0755 "$ARCH_NVIDIA_DB" "$ARCH_NVIDIA_CACHE"
  cp -a "$steam_db/local" "$ARCH_NVIDIA_DB/"

  cat >"$ARCH_NVIDIA_CONFIG" <<EOF
[options]
RootDir = /
DBPath = $ARCH_NVIDIA_DB
CacheDir = $ARCH_NVIDIA_CACHE
GPGDir = /etc/pacman.d/gnupg
LogFile = $ARCH_NVIDIA_DIR/pacman.log
Architecture = auto
SigLevel = Required DatabaseOptional

[core]
Server = https://geo.mirror.pkgbuild.com/core/os/\$arch

[extra]
Server = https://geo.mirror.pkgbuild.com/extra/os/\$arch

[multilib]
Server = https://geo.mirror.pkgbuild.com/multilib/os/\$arch
EOF

  pacman --config "$ARCH_NVIDIA_CONFIG" -Sy --noconfirm
  pacman --config "$ARCH_NVIDIA_CONFIG" -Sw --needed --noconfirm "${ARCH_NVIDIA_PACKAGES[@]}"
}

install_arch_nvidia_bundle() {
  local packages=()

  mapfile -t packages < <(find "$ARCH_NVIDIA_CACHE" -maxdepth 1 -type f \( -name '*.pkg.tar.zst' -o -name '*.pkg.tar.xz' \) -print | sort)
  ((${#packages[@]} > 0)) || die "Current Arch NVIDIA bundle was not downloaded"

  log "Installing current Arch NVIDIA package bundle"
  pacman -U --needed --noconfirm "${packages[@]}"
}

build_current_module() {
  local kernel module_version installed_module_version
  kernel=$(uname -r)
  module_version=$(pacman -Q "$DKMS_PACKAGE" | awk '{ print $2 }' | sed 's/-[0-9][0-9]*$//')
  installed_module_version=$(modinfo -k "$kernel" -F version nvidia 2>/dev/null || true)

  export TMPDIR=$DKMS_TMP_DIR
  install -d -m 1777 "$TMPDIR"

  if [[ "$installed_module_version" == "$module_version" ]]; then
    log "NVIDIA DKMS module $module_version is already installed for $kernel"
    offload_dkms_source "$module_version"
    return 0
  fi

  log "Building NVIDIA DKMS module $module_version for $kernel"
  dkms remove -m nvidia -v "$module_version" --all >/dev/null 2>&1 || true
  dkms add -m nvidia -v "$module_version" || true
  dkms build -m nvidia -v "$module_version" -k "$kernel"
  dkms install --no-depmod -m nvidia -v "$module_version" -k "$kernel"
  depmod -a "$kernel"
  offload_dkms_source "$module_version"
}

offload_dkms_source() {
  local module_version=$1 source_dir target_dir
  source_dir="/usr/src/nvidia-$module_version"
  target_dir="$OFFLOAD_DIR/usr-src/nvidia-$module_version"

  install -d -m 0755 /usr/src "$(dirname "$target_dir")"

  if [[ -L "$source_dir" ]]; then
    if [[ "$(readlink "$source_dir")" == "$target_dir" && -d "$target_dir" ]]; then
      return 0
    fi
    rm -f "$source_dir"
  fi

  if [[ -d "$source_dir" ]]; then
    log "Offloading DKMS source $source_dir to $target_dir"
    rm -rf "$target_dir"
    mv "$source_dir" "$target_dir"
  elif [[ ! -d "$target_dir" ]]; then
    log "DKMS source $source_dir is absent; it will be restored by reinstalling $DKMS_PACKAGE"
    return 0
  fi

  ln -s "$target_dir" "$source_dir"
}

remove_build_only_packages() {
  local pkg
  local owned=()
  local installed=()
  local remaining=()

  if [[ ! -r "$BUILD_PACKAGE_STATE" ]]; then
    log "No installer-owned build packages need removal"
    return 0
  fi

  mapfile -t owned <"$BUILD_PACKAGE_STATE"
  for pkg in "${owned[@]}"; do
    [[ -n "$pkg" ]] || continue
    pacman -Q "$pkg" >/dev/null 2>&1 && installed+=("$pkg")
  done

  if ((${#installed[@]} > 0)); then
    log "Removing build packages introduced by this installer: ${installed[*]}"
    pacman -Rdd --noconfirm "${installed[@]}" || true
  fi

  for pkg in "${owned[@]}"; do
    [[ -n "$pkg" ]] || continue
    pacman -Q "$pkg" >/dev/null 2>&1 && remaining+=("$pkg")
  done

  if ((${#remaining[@]} > 0)); then
    printf '%s\n' "${remaining[@]}" | sort -u | write_file_atomically "$BUILD_PACKAGE_STATE" 0644
  else
    rm -f "$BUILD_PACKAGE_STATE"
  fi

  sync
  btrfs filesystem sync / >/dev/null 2>&1 || true
}

remove_non_nvidia_gpu_packages() {
  local pkg
  local installed=()

  if ! nvidia_only_graphics; then
    log "Non-NVIDIA display hardware detected; keeping Mesa/Intel/AMD runtime packages"
    return 0
  fi

  for pkg in "${NON_NVIDIA_GPU_PACKAGES[@]}"; do
    if pacman -Q "$pkg" >/dev/null 2>&1; then
      installed+=("$pkg")
    fi
  done

  if ((${#installed[@]} == 0)); then
    return 0
  fi

  log "Removing non-NVIDIA GPU runtime packages from NVIDIA-only system"
  pacman -Rdd --noconfirm "${installed[@]}" || true
  sync
  btrfs filesystem sync / >/dev/null 2>&1 || true
}

offload_root_directory() {
  local source_dir=$1 offload_name=$2 generation_dir=$3
  local target_dir fstab_line lower_view lower_marker staging backup='' mounted_source=0
  target_dir="$generation_dir/$offload_name"
  fstab_line="$target_dir $source_dir none bind,x-systemd.requires-mounts-for=$OFFLOAD_DIR 0 0"

  install -d -m 0755 "$generation_dir" "$source_dir"

  # Snapshot the currently visible tree before revealing the lower root-slot
  # directory. On Btrfs this is normally a cheap reflink. It is the safe source
  # for same-build reruns (whose lower directory was already reclaimed) and for
  # migrating the legacy, unversioned offload layout.
  staging=$(mktemp -d "$generation_dir/.${offload_name}.new.XXXXXX")

  if is_exact_mountpoint "$source_dir"; then
    mounted_source=1
    if ! cp -a --reflink=auto "$source_dir"/. "$staging"/; then
      rm -rf "$staging"
      return 1
    fi
    if ! umount "$source_dir"; then
      log "ERROR: $source_dir is busy; cannot refresh its persistent offload safely"
      rm -rf "$staging"
      return 1
    fi
  fi

  # Keep a second view of the new slot's lower directory. Once the new bind
  # mount is active, this view lets us reclaim the hidden duplicate without a
  # window where source_dir is empty or unrecoverable.
  lower_view=$(mktemp -d /run/steamos-nvidia-lower.XXXXXX)
  if ! mount --bind "$source_dir" "$lower_view"; then
    rmdir "$lower_view"
    rm -rf "$staging"
    return 1
  fi
  lower_marker="$lower_view/.steamos-nvidia-offloaded"

  if [[ -e "$lower_marker" ]]; then
    log "Refreshing $source_dir from its existing offload for SteamOS build $(runtime_build_id)"
    if (( ! mounted_source )); then
      log "ERROR: $source_dir has an offload marker but no mounted source tree"
      umount "$lower_view" || true
      rmdir "$lower_view" || true
      rm -rf "$staging"
      return 1
    fi
  elif [[ -n "$(find "$lower_view" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    log "Staging exact $source_dir offload for SteamOS build $(runtime_build_id)"
    find "$staging" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
    if ! cp -a --reflink=auto "$lower_view"/. "$staging"/; then
      umount "$lower_view" || true
      rmdir "$lower_view" || true
      rm -rf "$staging"
      return 1
    fi
  elif (( mounted_source )); then
    log "Migrating legacy $source_dir offload into SteamOS build $(runtime_build_id)"
  else
    log "Staging empty $source_dir offload for SteamOS build $(runtime_build_id)"
  fi

  if [[ -e "$target_dir" ]]; then
    backup=$(mktemp -d "$generation_dir/.${offload_name}.previous.XXXXXX")
    rmdir "$backup"
    if ! mv "$target_dir" "$backup"; then
      umount "$lower_view" || true
      rmdir "$lower_view" || true
      rm -rf "$staging"
      return 1
    fi
  fi

  if ! mv "$staging" "$target_dir"; then
    [[ -z "$backup" ]] || mv "$backup" "$target_dir" || true
    umount "$lower_view" || true
    rmdir "$lower_view" || true
    rm -rf "$staging"
    return 1
  fi

  if ! mount --bind "$target_dir" "$source_dir"; then
    rm -rf "$target_dir"
    [[ -z "$backup" ]] || mv "$backup" "$target_dir" || true
    umount "$lower_view" || true
    rmdir "$lower_view" || true
    return 1
  fi

  touch /etc/fstab
  sed -i "\|[[:space:]]${source_dir}[[:space:]]|d" /etc/fstab
  printf '%s\n' "$fstab_line" >>/etc/fstab

  if ! find "$lower_view" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +; then
    log "ERROR: could not reclaim the lower $source_dir directory"
    umount "$lower_view" || true
    rmdir "$lower_view" || true
    return 1
  fi
  if ! printf '%s\n' "$(runtime_build_id)" >"$lower_marker"; then
    umount "$lower_view" || true
    rmdir "$lower_view" || true
    return 1
  fi
  if ! umount "$lower_view"; then
    log "ERROR: could not release temporary lower view for $source_dir"
    return 1
  fi
  rmdir "$lower_view"
  [[ -z "$backup" ]] || rm -rf "$backup"
}

offload_runtime_space() {
  local build_id generation_dir
  build_id=$(runtime_build_id)
  generation_dir="$OFFLOAD_DIR/runtime/$build_id"

  offload_root_directory /usr/share/fonts usr-share-fonts "$generation_dir"
  offload_root_directory /usr/share/icons usr-share-icons "$generation_dir"
  offload_root_directory /usr/share/ibus usr-share-ibus "$generation_dir"
  offload_root_directory /usr/share/locale usr-share-locale "$generation_dir"
  offload_root_directory /usr/share/qt6 usr-share-qt6 "$generation_dir"
  offload_root_directory /usr/share/wallpapers usr-share-wallpapers "$generation_dir"
  offload_root_directory /usr/lib/steam usr-lib-steam "$generation_dir"
  sync
  btrfs filesystem sync / >/dev/null 2>&1 || true
  printf '%s\n' "$build_id" | write_file_atomically "$RUNTIME_OFFLOAD_MARKER" 0644
  prune_runtime_offload_generations "$generation_dir"
}

prune_runtime_offload_generations() {
  local current_dir=$1 candidate
  local generations=()

  [[ -d "$OFFLOAD_DIR/runtime" ]] || return 0
  mapfile -t generations < <(
    find "$OFFLOAD_DIR/runtime" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' |
      sort -nr | awk 'NR > 3 { sub(/^[^ ]+ /, ""); print }'
  )

  for candidate in "${generations[@]}"; do
    [[ -n "$candidate" && "$candidate" != "$current_dir" ]] || continue
    log "Pruning old runtime offload generation ${candidate##*/}"
    rm -rf -- "$candidate"
  done
}

compress_btrfs_root_for_space() {
  local path

  if ! findmnt -no FSTYPE / | grep -qx btrfs; then
    return 0
  fi

  log "Compressing root filesystem paths before NVIDIA runtime install"
  for path in /usr /lib /bin /sbin; do
    [[ -e "$path" ]] || continue
    btrfs filesystem defragment -r -czstd "$path" >/dev/null 2>&1 || true
  done
  sync
  btrfs filesystem sync / >/dev/null 2>&1 || true
}

write_config() {
  log "Writing NVIDIA boot and runtime configuration"
  install -d -m 0755 /etc/modprobe.d /etc/mkinitcpio.conf.d /etc/environment.d

  cat >/etc/modprobe.d/steamos-nvidia.conf <<'EOF'
blacklist nouveau
options nouveau modeset=0
options nvidia_drm modeset=1 fbdev=1
EOF

  cat >/etc/mkinitcpio.conf.d/30-nvidia.conf <<'EOF'
MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)
EOF

  cat >/etc/environment.d/90-nvidia.conf <<'EOF'
__GLX_VENDOR_LIBRARY_NAME=nvidia
GBM_BACKEND=nvidia-drm
LIBVA_DRIVER_NAME=nvidia
EOF
}

install_gamescope_session_override() {
  if [[ ! -x /usr/lib/steamos/gamescope-session ]]; then
    log "SteamOS Gamescope session wrapper not found; skipping Gamescope override"
    return 0
  fi

  log "Installing NVIDIA-friendly Gamescope session override"
  install -d -m 0755 /etc/steamos-nvidia /etc/systemd/user/gamescope-session.service.d

  cat >/etc/steamos-nvidia/gamescope-session <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

source_script=/usr/lib/steamos/gamescope-session
width=${STEAMOS_NVIDIA_GAMESCOPE_OUTPUT_WIDTH:-1920}
height=${STEAMOS_NVIDIA_GAMESCOPE_OUTPUT_HEIGHT:-1080}
refresh=${STEAMOS_NVIDIA_GAMESCOPE_REFRESH:-60}
force_composition=${STEAMOS_NVIDIA_GAMESCOPE_FORCE_COMPOSITION:-0}

[[ $width =~ ^[0-9]+$ ]] || width=1920
[[ $height =~ ^[0-9]+$ ]] || height=1080
[[ $refresh =~ ^[0-9]+([.][0-9]+)?$ ]] || refresh=60
[[ $force_composition == 0 || $force_composition == 1 ]] || force_composition=0

tmp_parent=${XDG_RUNTIME_DIR:-/tmp}
patched_script=$(mktemp -p "$tmp_parent" steamos-nvidia-gamescope-session.XXXXXX)
trap 'rm -f "$patched_script"' EXIT

awk -v width="$width" -v height="$height" -v refresh="$refresh" -v force_composition="$force_composition" '
  /^[[:space:]]*export[[:space:]]+STEAM_GAMESCOPE_HDR_SUPPORTED=[[:space:]]*1([[:space:]]*(#.*)?)?$/ {
    sub(/=[[:space:]]*1/, "=0")
    hdr++
    print
    next
  }
  /^[[:space:]]*export[[:space:]]+STEAM_GAMESCOPE_VRR_SUPPORTED=[[:space:]]*1([[:space:]]*(#.*)?)?$/ {
    sub(/=[[:space:]]*1/, "=0")
    vrr++
    print
    next
  }
  /^[[:space:]]*export[[:space:]]+STEAM_GAMESCOPE_COLOR_MANAGED=[[:space:]]*1([[:space:]]*(#.*)?)?$/ {
    sub(/=[[:space:]]*1/, "=0")
    color_managed++
    print
    next
  }
  /^[[:space:]]*export[[:space:]]+STEAM_GAMESCOPE_VIRTUAL_WHITE=[[:space:]]*1([[:space:]]*(#.*)?)?$/ {
    sub(/=[[:space:]]*1/, "=0")
    virtual_white++
    print
    next
  }
  /^[[:space:]]*export[[:space:]]+STEAM_GAMESCOPE_FORCE_HDR_DEFAULT=[[:space:]]*1([[:space:]]*(#.*)?)?$/ {
    sub(/=[[:space:]]*1/, "=0")
    force_hdr++
    print
    next
  }
  /^[[:space:]]*export[[:space:]]+STEAM_GAMESCOPE_FORCE_OUTPUT_TO_HDR10PQ_DEFAULT=[[:space:]]*1([[:space:]]*(#.*)?)?$/ {
    sub(/=[[:space:]]*1/, "=0")
    force_hdr10pq++
    print
    next
  }
  /^[[:space:]]*--generate-drm-mode[[:space:]]+fixed[[:space:]]*\\[[:space:]]*$/ {
    drm_mode++
    if (force_composition == 1) print "\t\t--force-composition \\"
    printf "\t\t-W %s -H %s -r %s \\\n", width, height, refresh
  }
  { print }
  END {
    if (hdr != 1 || vrr != 1 || color_managed != 1 || virtual_white != 1 || force_hdr != 1 || force_hdr10pq != 1 || drm_mode != 1) {
      printf "SteamOS Gamescope wrapper layout changed; NVIDIA override was not applied (HDR=%d, VRR=%d, color=%d, white=%d, force-HDR=%d, HDR10PQ=%d, DRM-mode=%d)\n", hdr, vrr, color_managed, virtual_white, force_hdr, force_hdr10pq, drm_mode > "/dev/stderr"
      exit 1
    }
  }
' "$source_script" >"$patched_script"

chmod 0700 "$patched_script"
exec "$patched_script" "$@"
EOF
  chmod 0755 /etc/steamos-nvidia/gamescope-session

  # Keep the launch override separate from the user-owned display-mode drop-in.
  cat >/etc/systemd/user/gamescope-session.service.d/90-steamos-nvidia.conf <<'EOF'
[Service]
ExecStart=
ExecStart=/etc/steamos-nvidia/gamescope-session
EOF

  if id deck >/dev/null 2>&1; then
    local deck_uid
    deck_uid=$(id -u deck)
    if [[ -d /run/user/$deck_uid ]]; then
      runuser -u deck -- env XDG_RUNTIME_DIR="/run/user/$deck_uid" systemctl --user daemon-reload >/dev/null 2>&1 || true
    fi
  fi
}

post_install() {
  log "Running post-install integration"
  systemd-sysusers /usr/lib/sysusers.d/nvidia-utils.conf >/dev/null 2>&1 || true
  ldconfig
  depmod -a
  systemctl daemon-reload
  systemctl enable nvidia-persistenced.service >/dev/null 2>&1 || true
  mkinitcpio -P
}

compress_btrfs_paths() {
  if findmnt -no FSTYPE / | grep -qx btrfs; then
    log "Compressing large runtime paths on Btrfs root"
    btrfs filesystem defragment -r -czstd /usr/lib /usr/lib32 /usr/share/nvidia >/dev/null 2>&1 || true
    sync
  fi
}

verify_install() {
  log "Verifying install"
  modinfo nvidia >/dev/null 2>&1 || die "nvidia module is not available to modinfo"
  command -v nvidia-smi >/dev/null 2>&1 || die "nvidia-smi was not installed"

  if nvidia_active; then
    log "NVIDIA compute and DRM display drivers are working"
    rm -f "$FALLBACK_MARKER"
  elif nvidia-smi >/dev/null 2>&1; then
    log "NVIDIA compute driver is working but NVIDIA DRM is not active; reboot to activate display output"
  elif lsmod | awk '{print $1}' | grep -qx nouveau; then
    log "Nouveau is still loaded in this boot; reboot to bind NVIDIA"
  else
    log "nvidia-smi is installed but not working yet; reboot and re-check"
  fi
}

install_persistence_hooks() {
  log "Installing persistence hooks"
  install -d -m 0755 "$STATE_DIR" /etc/steamos-nvidia /etc/systemd/system

  # SteamOS updates switch to a freshly populated A/B root slot. Keep runnable
  # installer copies both in persistent /home state and in /etc so either side
  # of the atomic-update migration can repair the NVIDIA stack on first boot.
  install_self "$PERSISTENT_INSTALL"
  install_self /etc/steamos-nvidia/install

  # The ensure wrapper can be the process invoking this installer. Replace it
  # atomically so its shell keeps reading the old inode until that run exits.
  # Truncating it in place can make Bash parse a mixture of old and new text.
  write_file_atomically /etc/steamos-nvidia/ensure 0755 <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

PERSISTENT_INSTALL=$PERSISTENT_INSTALL
FALLBACK_MARKER=$FALLBACK_MARKER
ACTIVATION_MARKER=$STATE_DIR/nvidia-activation-reboot-requested
RUNTIME_OFFLOAD_MARKER=$RUNTIME_OFFLOAD_MARKER
REBOOT_DELAY_SEC=\${STEAMOS_NVIDIA_REBOOT_DELAY_SEC:-60}

schedule_reboot() {
  local reason=\$1

  if [[ ! \$REBOOT_DELAY_SEC =~ ^[0-9]+$ ]]; then
    logger -t steamos-nvidia-ensure "Invalid reboot delay '\$REBOOT_DELAY_SEC'; using 60 seconds"
    REBOOT_DELAY_SEC=60
  fi

  logger -t steamos-nvidia-ensure "\$reason; scheduling reboot in \$REBOOT_DELAY_SEC seconds"
  systemctl stop steamos-nvidia-reboot.timer >/dev/null 2>&1 || true
  if systemd-run --quiet \
      --unit=steamos-nvidia-reboot \
      --on-active="\${REBOOT_DELAY_SEC}s" \
      --timer-property=AccuracySec=1s \
      --property=Type=oneshot \
      /usr/bin/systemctl reboot; then
    return 0
  fi

  logger -t steamos-nvidia-ensure "Unable to schedule delayed reboot; rebooting immediately"
  systemctl reboot
}

runtime_build_id() {
  local build_id=

  if [[ -r /etc/os-release ]]; then
    build_id=\$(sed -n 's/^BUILD_ID=//p' /etc/os-release | tr -d '"' | head -n1)
  fi
  build_id=\${build_id:-\$(uname -r)}
  printf '%s' "\$build_id" | tr -c 'A-Za-z0-9._-' '_'
}

refresh_runtime_offloads() {
  local current_build recorded_build='' installer
  current_build=\$(runtime_build_id)
  [[ ! -r "\$RUNTIME_OFFLOAD_MARKER" ]] || recorded_build=\$(<"\$RUNTIME_OFFLOAD_MARKER")
  [[ "\$recorded_build" != "\$current_build" ]] || return 0

  logger -t steamos-nvidia-ensure "Refreshing persistent runtime offloads for SteamOS build \$current_build"
  for installer in "\$PERSISTENT_INSTALL" /etc/steamos-nvidia/install; do
    [[ -x "\$installer" ]] || continue
    if STEAMOS_NVIDIA_REBOOT=no "\$installer" --refresh-runtime-offloads; then
      return 0
    fi
  done

  logger -t steamos-nvidia-ensure "Runtime offload refresh failed; retaining the currently mounted generation"
  return 1
}

make_root_writable() {
  if command -v steamos-readonly >/dev/null 2>&1; then
    steamos-readonly disable || true
  elif findmnt -no OPTIONS / | tr ',' '\n' | grep -qx ro; then
    mount -o remount,rw /
  fi
}

restore_root_readonly() {
  command -v steamos-readonly >/dev/null 2>&1 || return 0
  steamos-readonly enable || logger -t steamos-nvidia-ensure "Could not restore SteamOS read-only mode after fallback preparation"
}

nvidia_active() {
  command -v nvidia-smi >/dev/null 2>&1 || return 1
  nvidia-smi >/dev/null 2>&1 || return 1
  ! lsmod | awk '{print \$1}' | grep -qx nouveau
  lsmod | awk '{print \$1}' | grep -qx nvidia_drm
}

refresh_runtime_offloads || true

if nvidia_active; then
  rm -f "\$FALLBACK_MARKER" "\$ACTIVATION_MARKER"
  exit 0
fi

logger -t steamos-nvidia-ensure "NVIDIA stack is missing; attempting reinstall"
systemctl enable --now sshd.service >/dev/null 2>&1 || true
systemctl enable --now sshd.socket >/dev/null 2>&1 || true

installer_succeeded=0
if [[ -x "\$PERSISTENT_INSTALL" ]]; then
  if STEAMOS_NVIDIA_REBOOT=no "\$PERSISTENT_INSTALL"; then
    installer_succeeded=1
  fi
fi

if (( ! installer_succeeded )) && [[ -x /etc/steamos-nvidia/install ]]; then
  if STEAMOS_NVIDIA_REBOOT=no /etc/steamos-nvidia/install; then
    installer_succeeded=1
  fi
fi

if (( installer_succeeded )); then
  if nvidia_active; then
    rm -f "\$FALLBACK_MARKER" "\$ACTIVATION_MARKER"
    exit 0
  fi

  if [[ ! -e "\$ACTIVATION_MARKER" ]]; then
    touch "\$ACTIVATION_MARKER"
    schedule_reboot "NVIDIA installed; one reboot is required to activate the new kernel module"
    exit 0
  fi

  logger -t steamos-nvidia-ensure "NVIDIA remained inactive after its activation reboot"
fi

logger -t steamos-nvidia-ensure "NVIDIA reinstall failed; removing NVIDIA-only boot config"
make_root_writable
rm -f /etc/modprobe.d/steamos-nvidia.conf
rm -f /etc/mkinitcpio.conf.d/30-nvidia.conf
rm -f /etc/environment.d/90-nvidia.conf
modprobe nouveau >/dev/null 2>&1 || true

if command -v mkinitcpio >/dev/null 2>&1; then
  mkinitcpio -P >/dev/null 2>&1 || true
fi
restore_root_readonly

if [[ ! -e "\$FALLBACK_MARKER" ]]; then
  touch "\$FALLBACK_MARKER"
  schedule_reboot "NVIDIA reinstall failed; one reboot into Nouveau fallback is required"
fi
EOF

  write_file_atomically /etc/systemd/system/steamos-nvidia-ensure.service 0644 <<'EOF'
[Unit]
Description=Ensure NVIDIA driver stack is installed after SteamOS updates
Wants=network-online.target
After=local-fs.target network-online.target
Before=display-manager.service

[Service]
Type=oneshot
ExecStart=/etc/steamos-nvidia/ensure
TimeoutStartSec=45min

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable steamos-nvidia-ensure.service >/dev/null 2>&1 || true
  systemctl enable sshd.service >/dev/null 2>&1 || true
  systemctl enable sshd.socket >/dev/null 2>&1 || true
  write_atomic_update_keep_list
}

write_atomic_update_keep_list() {
  if [[ ! -d /etc/atomic-update.conf.d ]]; then
    return 0
  fi

  log "Writing SteamOS atomic update keep-list"
  # SteamOS does not migrate all local /etc changes between atomic root slots.
  # This allow-list is the durable handoff: atomupd copies these files into the
  # next slot, then steamos-nvidia-ensure.service rebuilds/reinstalls whatever
  # pacman/DKMS state the new root still lacks.
  cat >/etc/atomic-update.conf.d/90-steamos-nvidia.conf <<'EOF'
/etc/atomic-update.conf.d/90-steamos-nvidia.conf
/etc/dkms/framework.conf.d/90-steamos-nvidia.conf
/etc/environment.d/90-nvidia.conf
/etc/fstab
/etc/mkinitcpio.conf.d/30-nvidia.conf
/etc/modprobe.d/steamos-nvidia.conf
/etc/pacman.d/gnupg/**
/etc/steamos-nvidia/**
/etc/systemd/system/multi-user.target.wants/nvidia-persistenced.service
/etc/systemd/system/multi-user.target.wants/sshd.service
/etc/systemd/system/multi-user.target.wants/steamos-nvidia-ensure.service
/etc/systemd/system/sockets.target.wants/sshd.socket
/etc/systemd/system/steamos-nvidia-ensure.service
/etc/systemd/user/gamescope-session.service.d/90-steamos-nvidia.conf
/etc/systemd/user/gamescope-session.service.d/90-steamos-nvidia-display.conf
EOF
}

nvidia_active() {
  command -v nvidia-smi >/dev/null 2>&1 || return 1
  nvidia-smi >/dev/null 2>&1 || return 1
  ! lsmod | awk '{print $1}' | grep -qx nouveau
  lsmod | awk '{print $1}' | grep -qx nvidia_drm
}

maybe_reboot() {
  case "$REBOOT" in
    yes)
      if nvidia_active; then
        log "NVIDIA is already active; reboot not required"
        return 0
      fi
      log "Rebooting now"
      systemctl reboot
      ;;
    no)
      if nvidia_active; then
        log "Reboot skipped; NVIDIA is already active"
      else
        log "Reboot skipped. Reboot before expecting NVIDIA to replace Nouveau."
      fi
      ;;
    prompt)
      if nvidia_active; then
        log "NVIDIA is already active; reboot not required"
        return 0
      fi
      if [[ -t 0 ]]; then
        read -r -p "Reboot now to activate NVIDIA? [y/N] " answer
        case "$answer" in
          y|Y|yes|YES) systemctl reboot ;;
          *) log "Reboot skipped. Reboot before expecting NVIDIA to replace Nouveau." ;;
        esac
      else
        log "Non-interactive run; reboot skipped. Set STEAMOS_NVIDIA_REBOOT=yes to reboot automatically."
      fi
      ;;
    *)
      die "Invalid STEAMOS_NVIDIA_REBOOT value: $REBOOT"
      ;;
  esac
}

main() {
  local mode=${1:-install}

  trap 'on_error "$LINENO" "$?"' ERR
  require_root "$@"
  require_command flock
  acquire_lock

  case "$mode" in
    install)
      ;;
    --refresh-persistence)
      make_root_writable
      install_persistence_hooks
      restore_root_readonly
      log "Refreshed persistent installer and boot-time recovery hooks"
      return 0
      ;;
    --refresh-runtime-offloads)
      make_root_writable
      offload_runtime_space
      restore_root_readonly
      log "Refreshed persistent runtime offloads for SteamOS build $(runtime_build_id)"
      return 0
      ;;
    *)
      die "Usage: $0 [--refresh-persistence|--refresh-runtime-offloads]"
      ;;
  esac

  require_command pacman

  has_nvidia_gpu || die "No NVIDIA PCI GPU detected"
  make_root_writable
  init_pacman_keyring
  configure_dkms_workspace
  install_build_stack
  remove_non_nvidia_gpu_packages
  offload_runtime_space
  compress_btrfs_root_for_space

  prepare_arch_nvidia_bundle
  install_arch_nvidia_bundle
  build_current_module
  remove_build_only_packages
  write_config
  install_gamescope_session_override
  install_persistence_hooks
  post_install
  compress_btrfs_paths
  verify_install

  log "Done. Root free space: $(root_free_mib) MiB"
  restore_root_readonly
  maybe_reboot
}

main "$@"
