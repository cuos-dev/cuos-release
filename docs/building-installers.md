# Building an installer

An installer is a bootable ISO that installs CuOS onto the target machine's own
disk. Use it when the target boots from removable media and keeps its internal
storage — for a device you flash directly, see
[Building disk images](building-images.md).

**x86 only.** The installer produces an ISO, and no other target has an ISO boot
path. For a Raspberry Pi or an Orange Pi, write a disk image instead.

## Prerequisites

- Docker, running and usable by your user
- `jq`
- An x86-64 build host (or emulation)

## Build

```sh
./cuos-release/tool.sh installer path/to/system.json
```

The ISO is written to `./output/`, named after your configuration
(`./cuos-release/tool.sh name path/to/system.json` prints the name).

This builds a system image first and then wraps it into the ISO, so it takes
about as long as a disk image build plus the ISO step.

## Reuse an existing ISO

If you already have an installer ISO and only want a different configuration on
it, build from that one instead of from scratch:

```sh
./cuos-release/tool.sh installer --base existing-installer.iso path/to/system.json
```

This is much faster: nothing is rebuilt, only the configuration inside the ISO
is exchanged.

**The base ISO is not modified.** A *new* ISO is written to `./output/`, named by
the same rules as any other build. If that name would collide with the base ISO,
the command refuses rather than overwrite it — rename the base, move it out of
`./output/`, or give the configuration a different `system_name`.

`--base` cannot be combined with `--platform`: the platform is fixed by the base
ISO.

## Use the installer

Write it to a USB device:

```sh
ISO="output/$(./cuos-release/tool.sh name path/to/system.json).iso"

sudo dd if="${ISO}" of=/dev/sdX bs=4M status=progress conv=fsync
```

**Check `of=` before pressing enter.**

Or attach it to a VM as a CD-ROM, add a disk for the installation, and set the
boot order to the CD-ROM.

On the target: boot from the installer, choose the disk to install onto, and
follow the prompts. The machine boots CuOS from its own disk afterwards.

## Further reading

- [How the installer works and what a machine needs to boot it](https://github.com/cuos-dev/cuos/blob/development/docs/common/installation.md)
- [system.json reference](https://github.com/cuos-dev/cuos/blob/development/docs/common/system-json-reference.md)
