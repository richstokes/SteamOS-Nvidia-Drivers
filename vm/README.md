# SteamOS VFIO end-to-end test

These helpers run a disposable SteamOS recovery/install VM with the host's
single NVIDIA GPU passed through. They are intentionally specific to the test
PC: GPU functions `0000:01:00.0` and `0000:01:00.1`, 22 guest vCPUs, and VM
state under `/home/steamosadmin/steamos-vm`.

The host has no alternate display adapter, so its display is unavailable while
the VM owns the GPU. Keep SSH working before starting a test.

## Safety model

`vfio-gpu-bind.sh` refuses handoff unless the GPU's IOMMU group contains only
the graphics and HDMI-audio functions. `run-steamos-vfio-vm.sh` restores both
functions to the host drivers and restarts the display manager whenever QEMU
exits or the launcher receives a signal. A host reboot is the fallback if the
GPU does not reset cleanly.

Run the launcher as a transient system service so it survives an SSH session
ending:

```bash
sudo systemd-run --unit=steamos-vfio-test --property=Type=exec \
  /home/steamosadmin/steamos-vm/vfio/run-steamos-vfio-vm.sh recovery
```

After the recovery image has populated the disposable target disk, launch the
installed system without the recovery disk:

```bash
sudo systemd-run --unit=steamos-vfio-test --property=Type=exec \
  /home/steamosadmin/steamos-vm/vfio/run-steamos-vfio-vm.sh installed
```

The guest SSH port is forwarded to the host at `127.0.0.1:2222`. QEMU's monitor
is at `127.0.0.1:55555`, and the serial log is
`/home/steamosadmin/steamos-vm/run/gpu-serial.log`.
