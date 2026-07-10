# SteamOS-Nvidia-Drivers

Instructions and scripts for installing SteamOS on a PC with an NVIDIA GPU.

## Current status

This is extremely experimental. I mostly did this to see if I could. It works
on my machine, but there are absolutely no guarantees.

SteamOS does not officially support NVIDIA desktop GPUs. Expect rough edges,
especially around Gamescope, display modes, HDR, VRR, and SteamOS updates.

Tested from a MacBook against a fresh SteamOS 3.8.14 PC install with:

- Kernel: `6.16.12-valve24.4-1-neptune-616`
- GPU: GeForce RTX 4090
- Driver packages from SteamOS repos: `575.64.05`

You need another machine that can run scripts and SSH into the SteamOS PC.

## End-To-End Install Path

### 1. Download A SteamOS Recovery Image

Download the latest Steam Deck recovery/OOBE repair image from:

https://steamdeck-images.steamos.cloud/recovery/

For example:

```bash
steamdeck-oobe-repair-20260707.10-3.8.14.img.bz2
```

### 2. Flash And Install SteamOS

Flash the image to a USB stick and boot the target PC from it.

This will wipe the target PC. I recommend physically disconnecting or removing
any drives that contain data you care about before installing.

After install, one of two things usually happens:

- You get a working desktop and can enable SSH normally.
- You get a black screen or an unresponsive keyboard before you can enable SSH.

If you get a working desktop, enable SSH from SteamOS. One common route is:

```bash
sudo systemctl enable --now sshd
```

If you cannot reach a working desktop, create an SSH-enabled SteamOS image
before flashing.

### 3. Optional: Create An SSH-Enabled Image

`patch-steamos-ssh-admin.sh` patches a SteamOS image so it boots with SSH
enabled and a sudo-capable admin user.

Default credentials:

```text
username: steamosadmin
password: steamtest123
```

The patch script requires Docker on the machine doing the patching.

First decompress the image:

```bash
bunzip2 -k steamdeck-oobe-repair-20260707.10-3.8.14.img.bz2
```

Then create a patched copy:

```bash
chmod +x patch-steamos-ssh-admin.sh

./patch-steamos-ssh-admin.sh \
  --output steamdeck-oobe-repair-20260707.10-3.8.14-ssh.img \
  steamdeck-oobe-repair-20260707.10-3.8.14.img
```

Use `--user` and `--password` if you want different temporary credentials.

Flash the `*-ssh.img` file to USB and install SteamOS from that USB stick.
After first boot, SSH should be available:

```bash
ssh steamosadmin@<steam-pc-ip>
```

### 4. Install The NVIDIA Driver Remotely

Once SSH is enabled, copy `install-steamos-nvidia.sh` to the SteamOS PC and run
it there with sudo.

Set these values for your machine:

```bash
STEAMOS_HOST=192.168.1.75
STEAMOS_USER=steamosadmin
```

Copy and run the installer:

```bash
scp install-steamos-nvidia.sh "$STEAMOS_USER@$STEAMOS_HOST:/tmp/"

ssh "$STEAMOS_USER@$STEAMOS_HOST" \
  'chmod +x /tmp/install-steamos-nvidia.sh && sudo STEAMOS_NVIDIA_REBOOT=yes /tmp/install-steamos-nvidia.sh'
```

If you enabled SSH for the normal `deck` user instead, set
`STEAMOS_USER=deck`.

The installer may take a while. It installs temporary build dependencies,
builds the NVIDIA DKMS module for the running SteamOS kernel, removes the build
dependencies again, installs the NVIDIA runtime, writes persistence hooks, and
then reboots if `STEAMOS_NVIDIA_REBOOT=yes` is set.

If you prefer to reboot manually, use:

```bash
ssh "$STEAMOS_USER@$STEAMOS_HOST" \
  'chmod +x /tmp/install-steamos-nvidia.sh && sudo STEAMOS_NVIDIA_REBOOT=no /tmp/install-steamos-nvidia.sh'
```

Then reboot the SteamOS PC yourself.

Useful environment overrides:

```bash
# Use the proprietary DKMS kernel module package instead of NVIDIA's open module package.
STEAMOS_NVIDIA_DKMS_PACKAGE=nvidia-dkms sudo ./install-steamos-nvidia.sh

# Reboot automatically after installation.
STEAMOS_NVIDIA_REBOOT=yes sudo ./install-steamos-nvidia.sh
```

### 5. Verify

After the SteamOS PC reboots, SSH back in and check:

```bash
ssh "$STEAMOS_USER@$STEAMOS_HOST" \
  'lspci -nnk | sed -n "/VGA\\|3D\\|Display/,+5p"; nvidia-smi'
```

The NVIDIA PCI device should show `Kernel driver in use: nvidia`, and
`nvidia-smi` should list the GPU.

## Installer Notes

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
- Installs a Gamescope session override that keeps Valve's current SteamOS
  wrapper but patches the launch at runtime for NVIDIA: HDR, VRR, and
  Gamescope color-management advertising are disabled, and the physical output
  is constrained to 1920x1080@60 by default. Override with
  `STEAMOS_NVIDIA_GAMESCOPE_OUTPUT_WIDTH`,
  `STEAMOS_NVIDIA_GAMESCOPE_OUTPUT_HEIGHT`, and
  `STEAMOS_NVIDIA_GAMESCOPE_REFRESH` if your display path is stable at a higher
  mode.
- Installs `/etc/steamos-nvidia/install` and an `/etc` systemd ensure service.
  If a SteamOS update boots a root slot without the NVIDIA module/runtime, the
  service reruns this installer before the display manager starts. If reinstall
  fails, it enables SSH and removes the NVIDIA-only boot config so the machine
  can fall back to Nouveau instead of black-screening.
- Writes `/etc/atomic-update.conf.d/90-steamos-nvidia.conf` so SteamOS's
  atomic updater keeps the NVIDIA config, repair service, SSH enablement,
  DKMS configuration, Gamescope override, and bind-mount configuration across
  A/B root updates.
- Rebuilds initramfs and enables `nvidia-persistenced`.

## Manual Verification

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

SteamOS atomic updates boot into a newly populated A/B root slot. Files under
`/home` survive, but local changes in `/etc` only survive when SteamOS's
atomic updater is told to migrate them. The installer handles this in two
parts:

1. It writes `/etc/atomic-update.conf.d/90-steamos-nvidia.conf` so atomupd
   copies the NVIDIA boot config, DKMS config, SSH enablement, repair service,
   Gamescope override, and bind mounts into the next root slot.
2. It enables `steamos-nvidia-ensure.service` before the display manager. On
   first boot after an update, that service checks whether the NVIDIA module
   and runtime are actually usable. If the new root slot is missing pacman/DKMS
   state, it reruns the persistent installer from `/home/.steamos-nvidia/install`
   with `STEAMOS_NVIDIA_REBOOT=no`.

The keep-list preserves the configuration handoff; the ensure service performs
the rebuild/reinstall that a fresh root slot may still need.

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
