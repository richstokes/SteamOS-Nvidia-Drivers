# SteamOS VFIO end-to-end test

These helpers run a disposable SteamOS recovery/install VM with the host's
single NVIDIA GPU passed through. They are intentionally specific to the test
PC:

- GPU: `0000:01:00.0` (RTX 4090)
- HDMI audio: `0000:01:00.1`
- Guest: 22 vCPUs pinned to host CPUs `4-15,18-27`, plus 20 GiB RAM
- VM state: `/home/steamosadmin/steamos-vm`
- Guest SSH: host loopback port `2222`
- QEMU monitor: host loopback port `55555`

The host has no alternate display adapter. Its display will be unavailable
while the VM owns the GPU, so confirm SSH works before every run. Do not adapt
these scripts to different hardware without checking the PCI addresses, IOMMU
group, CPU topology, and available memory.

## What was tested

The complete flow passed in July 2026:

1. Boot an official SteamOS 3.8.14 recovery image with the real RTX 4090.
2. Reimage a blank 64 GiB virtual NVMe disk.
3. Boot the installed VM and run the production NVIDIA installer.
4. Automatically reboot into NVIDIA 610.43.03 with `nvidia_drm` active.
5. Apply the SteamOS 3.8.16 A/B update and boot its new kernel/root slot.
6. Let `steamos-nvidia-ensure` refresh offloads and rebuild DKMS for the new
   kernel.
7. Let its delayed activation reboot fire automatically.
8. Verify NVIDIA, Gamescope/display services, persistent mounts, and read-only
   mode, then power off and return the GPU to the host.

## Safety model

`vfio-gpu-bind.sh` refuses GPU handoff unless the IOMMU group contains exactly
the graphics and HDMI-audio functions. `run-steamos-vfio-vm.sh` restores both
functions to the host drivers and restarts the display manager whenever QEMU
exits or the launcher receives a signal. A failed restore makes the launcher
fail rather than silently reporting success.

Never expose the physical host NVMe disk to the VM. The launcher only attaches
the QCOW2 files named below, so Valve's destructive recovery command can see
only the disposable virtual NVMe target.

## One-time host setup

Copy this directory to the host:

```bash
scp vm/* steamosadmin@192.168.1.75:/home/steamosadmin/steamos-vm/vfio/
ssh steamosadmin@192.168.1.75 \
  'chmod +x /home/steamosadmin/steamos-vm/vfio/*.sh'
```

Install persistent Intel IOMMU boot arguments, then reboot the physical host:

```bash
sudo /home/steamosadmin/steamos-vm/vfio/enable-steamos-vfio.sh
sudo systemctl reboot
```

After reboot, verify the kernel arguments and isolation before attempting a
handoff:

```bash
cat /proc/cmdline
sudo /home/steamosadmin/steamos-vm/vfio/vfio-gpu-bind.sh status
```

The command line must include `intel_iommu=on iommu=pt`. On this PC the status
command must report IOMMU group 11 containing the GPU on `nvidia` and audio on
`snd_hda_intel`. The bind script independently checks that no third device has
joined the group.

IOMMU configuration is installed at:

- `/etc/default/grub.d/90-steamos-vfio.cfg`
- `/etc/atomic-update.conf.d/91-steamos-vfio-keep.conf`

GRUB backups are kept under `/home/steamosadmin/steamos-vm/backups`.

## Required VM assets

The launcher expects these existing host assets:

```text
/home/steamosadmin/steamos-vm/
├── disks/
│   ├── recovery-gpu-session.qcow2
│   └── steamos-gpu-target.qcow2
├── images/
│   └── steamdeck-oobe-repair-ssh.img
├── root-podman/
├── run/
│   ├── OVMF_GPU_VARS.4m.fd
│   └── vm-test-key
└── vfio/
```

Rootful Podman storage must contain `localhost/steamos-qemu:latest`. The image
must provide QEMU/KVM, `qemu-img`, and these OVMF files:

```text
/usr/share/edk2/x64/OVMF_CODE.4m.fd
/usr/share/edk2/x64/OVMF_VARS.4m.fd
```

Verify the runtime without detaching the GPU:

```bash
sudo podman \
  --root /home/steamosadmin/steamos-vm/root-podman \
  --runroot /run/steamos-vm-podman \
  run --rm localhost/steamos-qemu:latest \
  qemu-system-x86_64 --version
```

The recovery raw image on the test PC has been patched to create an SSH admin
account and enable `sshd`. The patch helper and original compressed recovery
image are retained in `/home/steamosadmin/steamos-vm`. Keep credentials out of
the repository.

To refresh the recovery source later, download a current image from Valve's
official recovery directory, retain the compressed download, and expand a raw
copy under `images/`. Then use the retained helper to produce the SSH-enabled
base image without modifying the unpatched raw file:

```bash
read -rsp 'Temporary recovery admin password: ' RECOVERY_ADMIN_PASSWORD
echo
/home/steamosadmin/steamos-vm/patch-steamos-ssh-admin.sh \
  --output /home/steamosadmin/steamos-vm/images/steamdeck-oobe-repair-ssh.img \
  --user steamosadmin --password "$RECOVERY_ADMIN_PASSWORD" \
  /home/steamosadmin/steamos-vm/images/<unpatched-recovery>.img
unset RECOVERY_ADMIN_PASSWORD
```

The helper uses a privileged temporary Docker container to edit `rootfs-A`.
Choose a fresh temporary password and do not put it in shell history or this
repository. The official recovery image directory is:
<https://steamdeck-images.steamos.cloud/recovery/>.

## Create a fresh disposable test

Do this only while the VM service is stopped. Preserve or move the previous
QCOW2 files if its installed guest is still useful; do not overwrite a running
disk.

Create a fresh recovery overlay, blank 64 GiB sparse target, and clean writable
OVMF variable store from inside the QEMU container:

```bash
sudo podman \
  --root /home/steamosadmin/steamos-vm/root-podman \
  --runroot /run/steamos-vm-podman \
  run --rm --security-opt label=disable \
  -v /home/steamosadmin/steamos-vm:/vm:rw \
  localhost/steamos-qemu:latest sh -lc '
    qemu-img create -f qcow2 -F raw \
      -b /vm/images/steamdeck-oobe-repair-ssh.img \
      /vm/disks/recovery-gpu-session.qcow2
    qemu-img create -f qcow2 \
      /vm/disks/steamos-gpu-target.qcow2 64G
    cp /usr/share/edk2/x64/OVMF_VARS.4m.fd \
      /vm/run/OVMF_GPU_VARS.4m.fd
    chmod 0644 /vm/run/OVMF_GPU_VARS.4m.fd
  '
```

Confirm the files are QCOW2 and the target is sparse:

```bash
sudo podman \
  --root /home/steamosadmin/steamos-vm/root-podman \
  --runroot /run/steamos-vm-podman \
  run --rm --security-opt label=disable \
  -v /home/steamosadmin/steamos-vm:/vm:rw \
  localhost/steamos-qemu:latest \
  qemu-img info /vm/disks/steamos-gpu-target.qcow2
```

## Start and monitor a VM

Always launch through a transient system service so the VM and cleanup trap
survive the controlling SSH session ending:

```bash
sudo systemd-run --unit=steamos-vfio-test --property=Type=exec \
  /home/steamosadmin/steamos-vm/vfio/run-steamos-vfio-vm.sh recovery
```

Useful host-side monitoring commands:

```bash
sudo systemctl status steamos-vfio-test.service --no-pager -l
sudo journalctl -fu steamos-vfio-test.service
tail -f /home/steamosadmin/steamos-vm/run/gpu-serial.log
sudo podman \
  --root /home/steamosadmin/steamos-vm/root-podman \
  --runroot /run/steamos-vm-podman ps
```

The serial log is truncated at each launch. Installed SteamOS normally does
not put its kernel console on serial, so SSH is the primary guest interface.

Connect from the physical host:

```bash
ssh -i /home/steamosadmin/steamos-vm/run/vm-test-key \
  -p 2222 -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  steamosadmin@127.0.0.1
```

On the first recovery and installed boots, the public key may need to be added
to the guest again using its configured password. The recovery reimage creates
a new `/home`, so a key installed in the recovery environment does not carry
into the installed guest.

The easiest way to install the retained test key is:

```bash
ssh-copy-id -i /home/steamosadmin/steamos-vm/run/vm-test-key.pub \
  -p 2222 -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  steamosadmin@127.0.0.1
```

## Reimage the virtual NVMe

Before running the destructive recovery flow, verify all of the following
inside the recovery guest:

```bash
nproc
free -h
lspci -nnk -s 00:02.0
lspci -nnk -s 00:03.0
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS
```

Expected results are 22 CPUs, about 20 GiB RAM, the RTX 4090 and its audio
function, the recovery USB as `sda`, and one blank 64 GiB target as
`nvme0n1`. Stop immediately if the block-device list is different.

Run Valve's reimage as a guest system service:

```bash
sudo systemd-run --unit=steamos-reimage --property=Type=exec \
  env NOPROMPT=1 POWEROFF=1 /home/deck/tools/repair_device.sh all
```

It partitions and overwrites only the virtual `nvme0n1`, then powers down. When
QEMU exits, the host launcher restores the GPU automatically. Confirm the host
unit is inactive and the native drivers are back before continuing:

```bash
systemctl is-active steamos-vfio-test.service
sudo /home/steamosadmin/steamos-vm/vfio/vfio-gpu-bind.sh status
nvidia-smi
systemctl is-active display-manager nvidia-persistenced
```

## Test the NVIDIA installer

Boot the installed virtual NVMe without the recovery USB:

```bash
sudo systemd-run --unit=steamos-vfio-test --property=Type=exec \
  /home/steamosadmin/steamos-vm/vfio/run-steamos-vfio-vm.sh installed
```

From the physical host, copy the exact production installer into the guest:

```bash
scp -i /home/steamosadmin/steamos-vm/run/vm-test-key \
  -P 2222 -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  /home/.steamos-nvidia/install \
  steamosadmin@127.0.0.1:/home/steamosadmin/install-steamos-nvidia.sh
```

Run it in the guest with unattended reboot enabled:

```bash
chmod +x /home/steamosadmin/install-steamos-nvidia.sh
sudo systemd-run --unit=steamos-nvidia-e2e --property=Type=exec \
  env STEAMOS_NVIDIA_REBOOT=yes \
  /home/steamosadmin/install-steamos-nvidia.sh
```

Follow `/var/log/steamos-nvidia-install.log`. After the automatic reboot,
verify:

```bash
lspci -nnk -s 00:02.0
nvidia-smi
lsmod | grep -E '^(nvidia|nouveau)'
sudo dkms status
sudo steamos-readonly status
systemctl is-active display-manager nvidia-persistenced
systemctl --failed
```

The GPU must use `nvidia`, `nvidia_drm` must be loaded, Nouveau must not be
loaded, DKMS must match `uname -r`, and read-only mode must be enabled.

## Test a SteamOS A/B update

The legacy `steamos-update` wrapper requires root when called over this SSH
session. Check for an update with:

```bash
sudo atomupd-manager check
```

If an update is available, apply it without tying its lifetime to SSH:

```bash
sudo systemd-run --unit=steamos-atomic-e2e --property=Type=exec \
  /usr/bin/steamos-update
```

Wait until the service succeeds, then confirm the update is staged:

```bash
sudo systemctl status steamos-atomic-e2e.service --no-pager -l
sudo atomupd-manager get-update-status
```

Reboot the guest into the updated A/B slot. On its first boot,
`steamos-nvidia-ensure` should:

1. Refresh persistent runtime offloads for the new `BUILD_ID`.
2. Install the new kernel's matching headers.
3. Reinstall the Arch NVIDIA bundle and build DKMS.
4. Restore SteamOS read-only mode.
5. Schedule `steamos-nvidia-reboot.timer` for activation after 60 seconds.

Monitor it from the guest:

```bash
sudo systemctl status steamos-nvidia-ensure.service --no-pager -l
sudo tail -f /var/log/steamos-nvidia-install.log
systemctl list-timers --all | grep steamos-nvidia
```

Let the timer reboot the guest; do not replace this part of the test with a
manual reboot. After SSH returns for the second time, repeat the NVIDIA,
DKMS, service, mount, and read-only checks. Also confirm the activation marker
and timer are gone:

```bash
test ! -e /home/.steamos-nvidia/nvidia-activation-reboot-requested
systemctl list-timers --all | grep steamos-nvidia || true
sudo atomupd-manager check
```

For a complete persistence check, confirm the offloads resolve to a directory
for the new build ID:

```bash
for path in \
  /usr/share/fonts /usr/share/icons /usr/share/ibus /usr/share/locale \
  /usr/share/qt6 /usr/share/wallpapers /usr/lib/steam; do
  findmnt -rn -T "$path" -o TARGET,SOURCE,FSTYPE | head -1
done
```

## Normal shutdown and host recovery

Power off the guest normally when finished:

```bash
sudo systemctl poweroff
```

QEMU exits and the launcher returns the GPU to the host. Verify from host SSH:

```bash
systemctl is-active steamos-vfio-test.service
sudo /home/steamosadmin/steamos-vm/vfio/vfio-gpu-bind.sh status
nvidia-smi
systemctl is-active display-manager nvidia-persistenced sshd
sudo steamos-readonly status
systemctl --failed
```

If the guest is stuck, stop the launcher rather than binding devices out from
under a running QEMU process:

```bash
sudo systemctl stop steamos-vfio-test.service
```

If cleanup itself failed, remove the VM container and explicitly request host
rebinding:

```bash
sudo podman \
  --root /home/steamosadmin/steamos-vm/root-podman \
  --runroot /run/steamos-vm-podman rm -f steamos-vfio-vm
sudo /home/steamosadmin/steamos-vm/vfio/vfio-gpu-bind.sh to-host
```

If `nvidia-smi` still fails, keep the machine on SSH and reboot the physical
host. Do not repeatedly unbind or reset an in-use GPU.

## Expected non-fatal messages

These appeared during the successful test and did not indicate failure:

- QEMU: `VFIO dma-buf not supported in kernel`.
- Recovery Nouveau GSP/DisplayPort reply errors.
- Recovery NVMe format: `Invalid Field in Command`; partitioning continued.
- Recovery controller updater: device does not look like a Steam Deck.
- The recovery reimage's ten-second NVMe format warning.
- NVIDIA's normal out-of-tree/unsigned-module kernel taint message.

The real success criteria are the guest and host verification checks above,
not the absence of every warning.

## Keeping or resetting the guest

`steamos-gpu-target.qcow2` is the installed guest and can be reused for future
update tests. `recovery-gpu-session.qcow2` is a writable overlay over the
patched recovery image. `OVMF_GPU_VARS.4m.fd` retains UEFI boot entries.

Only copy, move, replace, or inspect these files while the VM service is
stopped. For a completely clean install test, recreate all three using the
fresh-test procedure. For another update test, retain the target and OVMF
state and launch `installed` directly.
