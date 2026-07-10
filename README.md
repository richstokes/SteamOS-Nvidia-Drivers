# SteamOS-Nvidia-Drivers
Mad hacks to get SteamOS working on my Nvidia PC

## Current status

This repo contains an experimental installer for SteamOS 3.x systems with an
NVIDIA desktop GPU. It has been tested on SteamOS 3.8.14 with:

- Kernel: `6.16.12-valve24.4-1-neptune-616`
- GPU: GeForce RTX 4090
- Driver packages from SteamOS repos: `575.64.05`

SteamOS does not officially support this setup. Expect to rerun the installer
after major SteamOS updates, especially when the kernel changes.

## Install

```bash
chmod +x install-steamos-nvidia.sh
sudo ./install-steamos-nvidia.sh
```

The installer uses normal pacman installs for the NVIDIA runtime. DKMS build
state and temporary build files are moved off SteamOS's tiny `/var` partition,
which is the part that caused the initial NVIDIA module build to fail.
The DKMS source tree is also moved to `/home/.steamos-nvidia/offload/usr-src`
and linked back into `/usr/src`, keeping DKMS usable without leaving the source
payload on root.
The installer itself is copied to `/home/.steamos-nvidia/install` so it
survives SteamOS A/B root image swaps.
Build-only packages are removed after the module is built so the NVIDIA runtime
fits on SteamOS's 5 GiB root partition. The boot ensure service reinstalls
them before future rebuilds.
On NVIDIA-only systems, the installer also removes Intel/AMD/Mesa GPU runtime
packages that are not useful for this target and compresses the Btrfs root
before installing the NVIDIA runtime.
Because the normal NVIDIA runtime packages are larger than SteamOS's default
root partition can comfortably transact, the installer offloads
`/usr/share/fonts`, `/usr/share/locale`, and `/usr/share/wallpapers` to
`/home/.steamos-nvidia/offload` with bind mounts. Those files remain available,
but their storage lives on the large home partition.
OpenCL packages are not installed by default because they are not needed for
Steam gaming and make the root partition fit much tighter.

Useful environment overrides:

```bash
# Use the proprietary DKMS kernel module package instead of NVIDIA's open module package.
STEAMOS_NVIDIA_DKMS_PACKAGE=nvidia-dkms sudo ./install-steamos-nvidia.sh

# Reboot automatically after installation.
STEAMOS_NVIDIA_REBOOT=yes sudo ./install-steamos-nvidia.sh
```

## What the installer does

- Disables SteamOS root read-only mode when needed.
- Initializes the `pacman` keyring with `archlinux` and `holo` keys.
- Detects the running Neptune kernel and installs matching headers.
- Configures DKMS to keep build state in `/home/.steamos-nvidia/dkms` and
  temporary build files in `/var/tmp/steamos-nvidia-dkms`, avoiding SteamOS's
  tiny `/var` partition without relying on a ramdisk.
- Builds and installs the NVIDIA DKMS module for the current kernel.
- Moves the NVIDIA DKMS source tree to `/home/.steamos-nvidia/offload/usr-src`
  and links it back into `/usr/src`, so `dkms status` and future rebuilds can
  still find the source while root stays small.
- Copies the installer to `/home/.steamos-nvidia/install`, which is the copy
  used by the boot repair service after SteamOS updates.
- Removes build-only packages before installing the NVIDIA runtime. This leaves
  DKMS installed without its build dependencies until the next rebuild is
  needed, keeping root space available for the runtime.
- On systems where all display-class PCI devices are NVIDIA, removes
  non-NVIDIA GPU runtime packages such as `vulkan-intel` and `vulkan-radeon`
  before installing the NVIDIA runtime.
- Offloads bulky `/usr/share` assets to `/home/.steamos-nvidia/offload` with
  persistent bind mounts, freeing enough root space for pacman's normal NVIDIA
  runtime transaction.
- Compresses the Btrfs root paths that matter for the runtime install so pacman
  has enough space on SteamOS's small root partition.
- Installs the display/gaming runtime packages, excluding OpenCL by default.
- Blacklists Nouveau and enables `nvidia_drm` modeset/fbdev.
- Installs `/etc/steamos-nvidia/install` and an `/etc` systemd ensure service.
  If a SteamOS update boots a root slot without the NVIDIA module/runtime, the
  service reruns this installer before the display manager starts. If reinstall
  fails, it enables SSH and removes the NVIDIA-only boot config so the machine
  can fall back to Nouveau instead of black-screening.
- Writes `/etc/atomic-update.conf.d/90-steamos-nvidia.conf` so SteamOS's
  atomic updater keeps the NVIDIA config, repair service, SSH enablement,
  DKMS configuration, and bind-mount configuration across A/B root updates.
- Rebuilds initramfs and enables `nvidia-persistenced`.

## Verify

After reboot:

```bash
lspci -nnk | sed -n '/VGA\|3D\|Display/,+5p'
lsmod | grep -E '^(nvidia|nvidia_drm|nvidia_modeset|nvidia_uvm|nouveau)'
nvidia-smi
```

The PCI device should show `Kernel driver in use: nvidia`, and `nvidia-smi`
should list the GPU. If Nouveau is still loaded, reboot once more and check
that `/etc/modprobe.d/steamos-nvidia.conf` exists.

## Persistence And Recovery

The installer enables `steamos-nvidia-ensure.service`. On each boot it checks
whether the NVIDIA module and `nvidia-smi` are present. If a SteamOS update
boots a clean root slot, the service reruns `/home/.steamos-nvidia/install` with
`STEAMOS_NVIDIA_REBOOT=no`, reinstalling build tools only for the rebuild and
removing them again before installing the runtime.

SteamOS 3.6 and newer only migrates selected `/etc` changes during atomic
updates. The installer therefore writes an additional keep-list at
`/etc/atomic-update.conf.d/90-steamos-nvidia.conf`. This is required for the
repair service, Nouveau blacklist, SSH enablement, DKMS config, and bind mounts
to survive the first post-install SteamOS update.

If SteamOS updates into a black screen, try a local TTY with `Ctrl+Alt+F2` or
`Ctrl+Alt+F3`, log in, and re-enable SSH:

```bash
sudo systemctl enable --now sshd
```

To undo the NVIDIA-only boot config and let Nouveau load again:

```bash
sudo steamos-readonly disable
sudo rm -f /etc/modprobe.d/steamos-nvidia.conf
sudo rm -f /etc/mkinitcpio.conf.d/30-nvidia.conf
sudo rm -f /etc/environment.d/90-nvidia.conf
sudo mkinitcpio -P
sudo reboot
```
