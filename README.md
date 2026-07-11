# SteamOS-Nvidia-Drivers

𝖨̶𝗇̶𝗌̶𝗍̶𝗋̶𝗎̶𝖼̶𝗍̶𝗂̶𝗈̶𝗇̶𝗌̶ 𝖺̶𝗇̶𝖽̶ 𝗌̶𝖼̶𝗋̶𝗂̶𝗉̶𝗍̶𝗌̶ Mad hax for installing SteamOS on a PC with an NVIDIA GPU.

## Current status

This is extremely experimental. I mostly did this to see if I could.. turns out I can!  

"It works on my machine", but there are absolutely no guarantees it will work for you.

SteamOS does not officially support NVIDIA desktop GPUs. Expect rough edges,
especially around Gamescope, display modes, HDR, VRR, and SteamOS updates.

Disclaimers out the way, I will say that once setup, SteamOS works great with my Nvidia GPU. Everything seems stable and games perform well.

## How to

This method relies on you having another machine which you will use to SSH into SteamOS in order to install the drivers etc. Using SSH to remotely set up SteamOS was really helpful here, since when I tried a plain SteamOS install, it would boot into a black screen and was unresponsive to keyboard input. However being able to remotely connect in via SSH, we can run the scripts from this repo to successfully install the Nvidia drivers.

A requirement is that the Steam PC is connected to your network via Ethernet.

So the super-high-level flow is:

1. Install SteamOS
2. Enable SSH for remote access
3. Run these scripts, which install and configure the nvidia driver

Tested from a MacBook against a fresh SteamOS 3.8.14 PC install with:

- Kernel: `6.16.12-valve24.4-1-neptune-616`
- GPU: GeForce RTX 4090
- Driver packages: current signed Arch Linux NVIDIA bundle, built against the
  SteamOS kernel with DKMS

## End-To-End Install Path

### 1. Download A SteamOS Recovery Image

Download the latest Steam Deck recovery/OOBE repair image from:

[Steam Deck recovery images](https://steamdeck-images.steamos.cloud/recovery/)

For example:

```bash
steamdeck-oobe-repair-20260707.10-3.8.14.img.bz2
```

### 2. Flash And Install SteamOS

[Flash the image to a USB stick and install SteamOS from it](https://help.steampowered.com/en/faqs/view/65B4-2AA3-5F37-4227).

> This will wipe the target PC. I recommend physically disconnecting or removing
any drives that contain data you care about before installing.

After install, one of two things usually happens:

- You get a working desktop and should [enable SSH normally](https://www.reddit.com/r/SteamDeck/comments/tz490v/enable_ssh_on_the_deck/).
- You get a black screen or an unresponsive keyboard and cannot use the desktop environment.

If you cannot reach a working desktop and enable SSH, create an "SSH-enabled-by-default" SteamOS image
before flashing - see step 3 below!

### 3. Optional: Create An SSH-Enabled Image

> You only need to do this step if you were not able to get SSH enabled by following the regular SteamOS install process above.

`patch-steamos-ssh-admin.sh` patches a SteamOS image so it installs with SSH
enabled and creates a sudo-capable admin user.

Default credentials:

```text
username: steamosadmin
password: steamtest123
```

The patch script requires Docker on the machine doing the patching, as it uses a bunch of Linux/filesystem tools and this was the easiest approach.

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
After first boot, SSH should be available and you can confirm with:

```bash
ssh steamosadmin@<steam-pc-ip>
```

### 4. Optional: Set up passwordless SSH login

After confirming that password-based SSH works, copy the public key from the
machine you will use to administer SteamOS. This lets subsequent `ssh` and
`scp` commands log in without repeatedly prompting for the SteamOS password:

```bash
ssh-copy-id steamosadmin@<steam-pc-ip>
```

If `ssh-copy-id` is unavailable, use this equivalent command instead:

```bash
cat ~/.ssh/id_ed25519.pub | ssh steamosadmin@<steam-pc-ip> \
  'umask 077; mkdir -p ~/.ssh; cat >> ~/.ssh/authorized_keys'
```

Replace `id_ed25519.pub` with the public-key filename you use, and substitute
`deck` for `steamosadmin` if that is the account you enabled SSH for. Verify it
before continuing:

```bash
ssh steamosadmin@<steam-pc-ip>
```

### 5. Install The NVIDIA Driver Remotely

Once SSH is enabled and confirmed working.

Set these values for your machine:

```bash
STEAMOS_HOST=192.168.1.75 # Replace with the IP of your Steam PC
STEAMOS_USER=steamosadmin
```

Copy and run the installer:

```bash
scp install-steamos-nvidia.sh "$STEAMOS_USER@$STEAMOS_HOST:/tmp/"

ssh "$STEAMOS_USER@$STEAMOS_HOST" \
  'chmod +x /tmp/install-steamos-nvidia.sh && sudo STEAMOS_NVIDIA_REBOOT=yes /tmp/install-steamos-nvidia.sh'
```

> If you enabled SSH for the normal `deck` user instead, set
`STEAMOS_USER=deck`.

The installer may take a while. It installs temporary build dependencies,
installs the NVIDIA package bundle, builds the DKMS module for the running
SteamOS kernel, removes the build dependencies again, writes persistence hooks,
and then reboots if `STEAMOS_NVIDIA_REBOOT=yes` is set.

#### Driver installation model

The installer uses two deliberately different sources:

- NVIDIA user-space packages come from Arch Linux's current signed repositories.
  They are downloaded using a temporary package database under
  `/home/.steamos-nvidia/arch-nvidia`, then installed through SteamOS's own
  `pacman`. SteamOS's configured repositories are not replaced.
- The kernel module is Arch's `nvidia-open-dkms` package. DKMS builds NVIDIA's
  open kernel module locally against the exact SteamOS kernel that is currently
  booted. This is neither Arch's prebuilt `nvidia-open` module package nor the
  NVIDIA `.run` installer.

For a SteamOS kernel update, the boot-time ensure service reruns the persistent
installer and DKMS rebuilds the module for the kernel in the new root slot.

If you prefer to reboot manually, use:

```bash
ssh "$STEAMOS_USER@$STEAMOS_HOST" \
  'chmod +x /tmp/install-steamos-nvidia.sh && sudo STEAMOS_NVIDIA_REBOOT=no /tmp/install-steamos-nvidia.sh'
```

Then reboot the SteamOS PC yourself.

Useful environment overrides:

```bash
# Reboot automatically after installation.
STEAMOS_NVIDIA_REBOOT=yes sudo ./install-steamos-nvidia.sh
```

### 6. Verify

After the SteamOS PC reboots, SSH back in and check:

```bash
ssh "$STEAMOS_USER@$STEAMOS_HOST" \
  'lspci -nnk | sed -n "/VGA\\|3D\\|Display/,+5p"; nvidia-smi'
```

The NVIDIA PCI device should show `Kernel driver in use: nvidia`, and
`nvidia-smi` should list the GPU.

## Installer Notes

- SteamOS's root partition is small, so the installer moves DKMS state, DKMS
  source, and bulky runtime assets under `/home/.steamos-nvidia` where possible.
- Build-only packages are installed only long enough to compile the NVIDIA DKMS
  module, then removed again after the module build completes.
- The installer copies itself to `/home/.steamos-nvidia/install` and installs a
  boot-time repair service so SteamOS A/B root updates can be repaired on first
  boot.
- The Gamescope override defaults to a conservative NVIDIA-friendly display
  path: 1920x1080@60, HDR off, VRR off.
- OpenCL is intentionally not installed by default because it is not needed for
  Steam gaming and makes the root partition much tighter.

## Gamescope Display Mode

SteamOS Game Mode runs through Gamescope, and NVIDIA support there is still
rough. The installer therefore defaults to a conservative output mode:

```text
1920x1080@60
HDR off
VRR off
Gamescope color-management advertising off
```

You can override the physical output mode with a systemd user drop-in:

```bash
sudo mkdir -p /etc/systemd/user/gamescope-session.service.d

sudo tee /etc/systemd/user/gamescope-session.service.d/90-steamos-nvidia-display.conf >/dev/null <<'EOF'
[Service]
ExecStart=
ExecStart=/etc/steamos-nvidia/gamescope-session
Environment=STEAMOS_NVIDIA_GAMESCOPE_OUTPUT_WIDTH=2560
Environment=STEAMOS_NVIDIA_GAMESCOPE_OUTPUT_HEIGHT=1440
Environment=STEAMOS_NVIDIA_GAMESCOPE_REFRESH=144
Environment=STEAM_GAMESCOPE_HDR_SUPPORTED=0
Environment=STEAM_GAMESCOPE_VRR_SUPPORTED=0
Environment=STEAM_GAMESCOPE_COLOR_MANAGED=0
Environment=STEAM_GAMESCOPE_VIRTUAL_WHITE=0
EOF

sudo systemctl restart sddm
```

For some NVIDIA systems, `STEAMOS_NVIDIA_GAMESCOPE_FORCE_COMPOSITION=1` can be
added to the same drop-in to disable Gamescope direct scan-out. This may avoid
display corruption at the cost of a small amount of latency and GPU work; leave
it unset unless it demonstrably improves the output.

For stable high-refresh 4K on NVIDIA, use SteamOS Desktop Mode instead: set
the output mode in KDE Display Configuration, then launch Steam Big Picture.
That path uses KDE's Wayland compositor rather than Gamescope's DRM scan-out.
On the tested system, `3840x2160@144` is stable in Desktop Mode even though it
flickers in SteamOS Game Mode.

On the tested RTX 4090 + ASUS PG32UQ setup:

- `1920x1080@60` is the stable fallback.
- `2560x1440@144` works well and is the best tested compromise.
- `3840x2160@155` is selectable with the monitor overclock enabled, but
  flickers in SteamOS Game Mode.
- With the monitor overclock disabled, native `3840x2160@144` and
  `3840x2160@120` are advertised by Linux DRM. Both flickered in Gamescope (SteamOS Game Mode), but were fine in Desktop/KDE mode.

If a mode gives you a black screen, SSH back in and restore the conservative
values above, then restart `sddm`.

## What the installer does

- Disables SteamOS root read-only mode when needed.
- Initializes the `pacman` keyring with `archlinux` and `holo` keys.
- Detects the running Neptune kernel and installs matching headers.
- Configures DKMS to keep build state in `/home/.steamos-nvidia/dkms` and
  temporary build files in `/var/tmp/steamos-nvidia-dkms`, avoiding SteamOS's
  tiny `/var` partition without relying on a ramdisk.
- Downloads the current signed Arch Linux NVIDIA package bundle into `/home`,
  then installs those local packages through SteamOS's real pacman database.
  It does not permanently replace SteamOS's configured package repositories.
- Builds and installs the NVIDIA DKMS module for the current SteamOS kernel.
- Moves the NVIDIA DKMS source tree to `/home/.steamos-nvidia/offload/usr-src`
  and links it back into `/usr/src`, so `dkms status` and future rebuilds can
  still find the source while root stays small.
- Copies the installer to `/home/.steamos-nvidia/install`, which is the copy
  used by the boot repair service after SteamOS updates.
- Removes build-only packages after the NVIDIA module build. This leaves DKMS
  installed without its build dependencies until the next rebuild is needed.
- On systems where all display-class PCI devices are NVIDIA, removes
  non-NVIDIA GPU runtime packages such as `vulkan-intel` and `vulkan-radeon`
  before installing the NVIDIA runtime.
- Offloads bulky `/usr/share` assets and Steam's user-space runtime to
  `/home/.steamos-nvidia/offload` with persistent bind mounts, freeing enough
  root space for pacman's normal NVIDIA runtime transaction.
- Compresses the Btrfs root paths that matter for the runtime install so pacman
  has enough space on SteamOS's small root partition.
- Installs matching NVIDIA utilities, 32-bit Steam/Vulkan support, VAAPI, and
  the current EGL Wayland packages required by Gamescope.
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
  service reruns this installer before the display manager starts, then performs
  one activation reboot so the new module binds. If it remains inactive after
  that reboot, it enables SSH and removes the NVIDIA-only boot config so the
  machine can fall back to Nouveau instead of black-screening.
- Writes `/etc/atomic-update.conf.d/90-steamos-nvidia.conf` so SteamOS's
  atomic updater keeps the NVIDIA config, repair service, SSH enablement,
  DKMS configuration, Gamescope override, and bind-mount configuration across
  A/B root updates.
- Rebuilds initramfs and enables `nvidia-persistenced`.

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

## Extras

The [misc directory](https://github.com/richstokes/SteamOS-Nvidia-Drivers/tree/main/misc) in this repo contains a collection of scripts for working with SteamOS, such as automating back ups and some performance tweaks.
