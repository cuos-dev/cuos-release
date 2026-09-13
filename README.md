# CuOS Release Tooling

Build bootable [CuOS](https://github.com/cuos-dev/cuos) systems from a
configuration file.

CuOS is a container-based operating system: the OS itself is a container image,
installed onto A/B BTRFS subvolumes and updated by replacing one of them. This
repository is where you *make* one — a disk image, an ISO installer, or an LXC
container — from a `system.json` that describes the system you want.

**Start here if you want a running system.** If you want to understand or extend
the OS, start at [cuos](https://github.com/cuos-dev/cuos) instead.

## Requirements

- Linux or macOS. The host does not have to match the target's architecture. Windows is untested.
- **Docker**, running, and usable by your user. The factories run as containers.
- **jq**
- **git**
- For `image` and `installer`: **loop devices, device-mapper, and the right to
  mount filesystems.** These belong to the host kernel, so building a disk image
  works on a host or in a VM but **not inside an LXC container**.
  `image --platform lxc` needs none of it — it exports a container instead of
  partitioning a disk, so it builds anywhere Docker runs.
- For `config-sign`: **ssh-keygen**
- For `proxmox-*`: **ssh** and **scp**
- Around 6 GB of free disk space.

## Quickstart

```sh
git clone https://github.com/cuos-dev/cuos-release.git
```

Everything below is run from the directory the clone landed in — beside
`cuos-release/`, not inside it. That is also where `output/` appears.

Write a minimal `system.json`. The versions of the CuOS images themselves are
already pinned in [`release.json`](release.json), so include it rather than
naming image versions yourself:

```json
{
  "#include": "cuos-release/release.json",
  "hostname": "my-system"
}
```

That is a complete system. `release.json` pins
[CuOS IaC](https://github.com/cuos-dev/cuos-iac) as `init_image`, so the
finished system starts it and deploys your services from a git repository.

`init_image` names the **Application Init Container** — the one container CuOS
starts, and from which everything else is started. CuOS IaC is one of those;
to run your own instead, name it in the same key:

```json
{
  "#include": "cuos-release/release.json",
  "hostname": "my-system",
  "init_image": "ghcr.io/my-org/my-init-app",
  "init_image_version": "latest"
}
```

What such a container has to look like:
[Your Application Init Container](https://github.com/cuos-dev/cuos/blob/development/docs/common/cuos-app-init.md).

Build a disk image:

```sh
./cuos-release/tool.sh image my-system.json
```

The result lands in `./output/`. The file name comes from your configuration,
not from a fixed name — ask for it:

```sh
./cuos-release/tool.sh name my-system.json      # -> CuOS-my-system
```

Write it to a disk or boot it in a VM:

```sh
IMAGE="output/$(./cuos-release/tool.sh name my-system.json).img"

qemu-system-x86_64 -m 2048 -drive format=raw,file="${IMAGE}" -nographic
```

On first boot CuOS sets up its subvolumes, applies the configuration, and starts
`init_image` as the application container. Check it with `cuos state`,
`cuos version` and `cuos log` on the running system.

## What you can build

| Command | Result | Guide |
|---|---|---|
| `tool.sh image CONFIG` | A raw disk image (`.img`) to write to a disk | [Building disk images](docs/building-images.md) |
| `tool.sh installer CONFIG` | An ISO installer that installs onto the target's disk | [Building an installer](docs/building-installers.md) |
| `tool.sh image --platform lxc CONFIG` | A `tar.gz` to import as an LXC container | [LXC and Proxmox](docs/lxc-proxmox.md) |

To try one of them out, `tool.sh` can also put the result on a
[Proxmox VE](https://www.proxmox.com/) host and start it:

```sh
./cuos-release/tool.sh proxmox-create my-system.json
```

A VM or a container, depending on the platform, with everything it needs read
from `system.json` — see [Deploying to Proxmox VE](docs/testing-on-proxmox.md).

Use `--platform` for a target other than the machine you are building on:

```sh
./cuos-release/tool.sh image --platform rpi-arm64 my-system.json
```

| `--platform` | Target |
|---|---|
| *(default)* | The build host's architecture |
| `x86_64` | 64-bit PC |
| `rpi-arm64` | 64-bit Raspberry Pi |
| `rpi-arm32` | 32-bit Raspberry Pi (legacy — see the platform support docs) |
| `orangepi-zero3` | Orange Pi Zero 3 |
| `lxc` | LXC container |

The platform also selects the OS image: `<platform>_image` if your configuration
has that key, `os_image` otherwise. One configuration can therefore describe
several targets. `release.json` carries pinned images for `os`, `rpi-arm64`,
`rpi-arm32`, `orangepi-zero3` and `lxc`.

Any other platform name works as well, but then its disk layout has to be stated
with `--layout mbr` or `--layout gpt`, because a wrong layout produces an image
that builds cleanly and never boots.

The installer is x86-only: it produces an ISO, and no other target has an ISO
boot path.

## Configuration

`system.json` describes one system. Every key is documented in the
[system.json reference](https://github.com/cuos-dev/cuos/blob/development/docs/common/system-json-reference.md).

**Compose, do not copy.** A configuration can pull in others with `#include`,
which takes one path or a list, relative to the including file:

```json
{
  "#include": [
    "cuos-release/release.json",
    "common/network.json"
  ],
  "hostname": "gateway-01"
}
```

Includes are merged first and the including file wins, so a shared base can be
overridden per system. Several files given on the command line merge the same
way, left to right. To see what a build will actually use:

```sh
./cuos-release/tool.sh config my-system.json
```

### Naming

Artefacts are named `<product_name>-<system_name>`, both optional:

- `product_name` defaults to `CuOS`, or `CuOS IaC` for an IaC system
- `system_name` defaults to `hostname`, then to the configuration file's name —
  or its directory name if the file is called `system.json`

`./cuos-release/tool.sh name CONFIG` prints the result.

### Passwords, signing and encryption

```sh
./cuos-release/tool.sh root-password -r -w my-system.json   # hash a root password into the file
./cuos-release/tool.sh config-sign my-system.json           # merged config, SSH-signed
./cuos-release/tool.sh config-encrypt secrets.json          # encrypt a file at rest
```

`root-password` also writes `console_password` (`-c`) and
`console_expert_password` (`-e`). Run `./cuos-release/tool.sh help` for the full list of
commands.

## Using it in your own repository

Keep your system definitions in your own repository and add this one as a
submodule, so your configurations and the tooling that builds them are versioned
together:

```sh
git submodule add https://github.com/cuos-dev/cuos-release.git
./cuos-release/tool.sh update
```

`./cuos-release/tool.sh update` updates the CuOS submodules of the surrounding repository and
**verifies their commit signatures**, refusing to move to an unsigned commit.

## Running the IaC manager without CuOS

The IaC manager can run on any Docker host, which is useful for existing
infrastructure and for development:

```sh
./cuos-release/tool.sh start-iac-local my-system.json
./cuos-release/tool.sh stop-iac-local my-system.json
```

See [`cuos-iac-local/README.md`](cuos-iac-local/README.md).

## Debugging a build

`image` and `installer` print one line per step and keep the technical output —
`debootstrap`, `kpartx`, `xorriso`, the command tracing of every script
involved — in a log file beside the artefact:

```
==> Merging the configuration
==> Building the system image for 'x86_64'
==> Fetching ghcr.io/cuos-dev/cuos-image-factory:v0.5.7
  ==> Creating an empty image of 1636 MB
  ==> Installing the system from ghcr.io/cuos-dev/cuos-system:v0.6.0
==> output/CuOS-my-system.img written in 4m12s
```

The log is `output/NAME.build.log`, written on every run.
`NAME` is what `./cuos-release/tool.sh name my-system.json` reports.

```sh
./cuos-release/tool.sh shell my-system.json      # shell inside the built image
./cuos-release/tool.sh shell output/my-system.img
DEBUG=1 ./cuos-release/tool.sh image my-system.json
```

`shell` mounts the image's boot and root filesystems and drops you into a shell.
The image must have been built already.

`DEBUG=1` puts everything on the terminal instead, and writes no log file.

`proxmox-create` and `proxmox-destroy` follow the same convention, with their
log in `output/NAME.proxmox.log` —
[Deploying to Proxmox VE](docs/testing-on-proxmox.md#what-you-see-of-it).

## Environment switches

Everything you normally need is a command-line option. These variables exist for
the cases that are not normal — working on CuOS itself, or on this tooling.

| Variable | Effect |
|---|---|
| `DEBUG=1` | Put the full output of `image`, `installer`, `shell` and the `proxmox-*` commands on the terminal — command tracing (`set -x`) here, inside the factory containers and on the Proxmox host included — and write no `output/NAME.build.log` or `output/NAME.proxmox.log`. |
| `DEVELOPMENT=1` | Use the factories' `:development` tags instead of the versions pinned in [`.versions.env`](.versions.env), and **skip the digest check**. Also switches the IaC-local commands to `cuos-iac-local/docker-compose.development.yml`. For testing a factory change before it is released. |
| `BUILD=1` | Build the **image** factory from source instead of pulling it, and pull nothing at all. Needs a `cuos` checkout beside, one level above, or two levels above this repository — it runs `cuos/image-factory/build.sh`. The *installer* factory is neither built nor pulled, so `installer` only works if that image is already on your machine. |
| `IAC_SIGNKEY_PATH` | The SSH key `config-sign` signs with. Default `~/.ssh/id_ed25519`. |
| `PASSWORD_LENGTH` | Length of the password `root-password -g` generates. Default `20`. |
| `PROXMOX_HOST`, `PROXMOX_VMID`, `PROXMOX_ARTEFACT` | Defaults for `--host`, `--id` and `--artefact` of the `proxmox-*` commands, for driving them from a script. The options win. See [Deploying to Proxmox VE](docs/testing-on-proxmox.md). |

**`DEVELOPMENT` and `BUILD` both disable the digest check**, which is the
integrity guarantee that a normal build gives you: every image is pinned by
digest and a mismatch is fatal. Use them while developing, not to produce an
artefact anyone else will run.

## How the pieces fit together

| Repository | Contains |
|---|---|
| [cuos](https://github.com/cuos-dev/cuos) | The OS: system image, updater, the image and installer factories, `system.json` semantics |
| **cuos-release** | This repository: `tool.sh`, pinned image versions, config merging, signing and encryption |
| [cuos-iac](https://github.com/cuos-dev/cuos-iac) | Running containers on a CuOS device: IaC manager, WebUI, fleet |

`tool.sh` does not build the OS. It runs the factory containers published from
`cuos`, pinned by digest in [`.versions.env`](.versions.env), and fails if a
pulled image's digest does not match.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Contributions need a Developer
Certificate of Origin sign-off (`git commit -s`, see [DCO.txt](DCO.txt)).

## License

Apache-2.0 — see [LICENSE.txt](LICENSE.txt) and [NOTICE](NOTICE).
No warranty; see [DISCLAIMER.md](DISCLAIMER.md).

