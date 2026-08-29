# Building disk images

A disk image is written directly onto the target's storage — an SD card, a USB
device, a VM disk. To install onto a machine's own disk from removable media
instead, see [Building an installer](installation.md); for a container, see
[LXC and Proxmox](lxc-proxmox.md).

## Prerequisites

- Docker, running and usable by your user
- `jq`
- Around 6 GB of free disk space
- A build host of the **same CPU architecture as the target**. Building ARM
  images on an x86 machine is not supported.

## Build

```sh
./tool.sh image path/to/system.json
```

The image is written to `./output/`. Its name comes from the configuration, so
ask rather than assume:

```sh
./tool.sh name path/to/system.json      # -> CuOS-my-system
```

### For another platform

```sh
./tool.sh image --platform rpi-arm64 path/to/system.json
```

| `--platform` | Target | Disk layout |
|---|---|---|
| *(default)* | The build host's architecture | GPT, BIOS + UEFI |
| `rpi-arm64` | 64-bit Raspberry Pi | MBR + FAT boot |
| `rpi-arm32` | 32-bit Raspberry Pi | MBR + FAT boot |
| `orangepi-zero3` | Orange Pi Zero 3 | MBR + FAT boot |
| `lxc` | LXC container | none — see [LXC and Proxmox](lxc-proxmox.md) |

The platform also chooses the OS image: `<platform>_image` from your
configuration if present, `os_image` otherwise. Including `release.json` gives
you pinned images for `os`, `rpi-arm64`, `rpi-arm32` and `lxc`.

Any other platform name is accepted, but then its disk layout has to be stated
with `--layout mbr` or `--layout gpt`. There is no default for an unknown board
on purpose: the wrong layout produces an image that builds without complaint and
never boots.

## Write it to a device

```sh
IMAGE="output/$(./tool.sh name path/to/system.json).img"

sudo dd if="${IMAGE}" of=/dev/sdX bs=4M status=progress conv=fsync
```

**Check `of=` before pressing enter** — `dd` will overwrite whatever it points
at, without asking.

The first boot takes longer than later ones: the root filesystem is grown to the
device and the application container is pulled.

## Run it in a VM

```sh
qemu-system-x86_64 -m 2048 -drive format=raw,file="${IMAGE}" -nographic
```

Use a second terminal with `screen` or `tmux` if you have no graphical console.

## Other formats

The image is a raw disk. Convert it with `qemu-img`:

```sh
qemu-img convert -f raw -O qcow2 "${IMAGE}" image.qcow2   # QEMU/KVM, Proxmox
qemu-img convert -f raw -O vpc  "${IMAGE}" image.vhd      # Hyper-V
```

### Proxmox VE, as a virtual machine

1. Convert to QCOW2 as above and copy the file to the Proxmox host.
2. Create a VM without a disk.
3. Import the image and attach it:

   ```sh
   qm importdisk <VMID> image.qcow2 <STORAGE>
   ```

4. Attach the imported disk and set the boot order to it.

For a Proxmox *container* rather than a VM, see
[LXC and Proxmox](lxc-proxmox.md).

## Looking inside a built image

```sh
./tool.sh shell path/to/system.json
```

This mounts the image's boot and root filesystems and gives you a shell. The
image has to have been built already.

## Further reading

- [What the image contains](https://github.com/cuos-dev/cuos/blob/development/docs/common/building-images.md)
  — partition layout, the A/B subvolumes, platform notes
- [system.json reference](https://github.com/cuos-dev/cuos/blob/development/docs/common/system-json-reference.md)
