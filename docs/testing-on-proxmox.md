# Deploying to Proxmox VE

`tool.sh` can put an artefact it has built onto a [Proxmox VE](https://www.proxmox.com/)
host and start it — a VM from an installer ISO or a disk image, a container from
an LXC export. It is meant for testing a build: one command per build/boot cycle
instead of a scp, a `qm create` and a browser tab.

```sh
./tool.sh installer my-system.json          # build it
./tool.sh proxmox-create my-system.json     # put it on the host and start it
./tool.sh proxmox-status  my-system.json
./tool.sh proxmox-destroy my-system.json    # and away again
```

This is an add-on, not part of building or releasing: it needs `ssh` and no
Docker, and nothing else in `tool.sh` depends on it.

## What it needs

- **`ssh` access to the Proxmox node**, as a user allowed to run `qm`, `pct` and
  `pvesh` — in practice `root`. Key-based, since nothing here can answer a
  password prompt. The Proxmox API is only used through `pvesh` on the host.
- **The artefact already built**, in `./output/`.
- Proxmox VE 7 or newer. Deploying a **RAW disk image** additionally needs
  **PVE 8**, for `qm create --scsi0 …,import-from=…`.

## The commands

| Command | Effect |
|---|---|
| `proxmox-create CONFIG` | Upload the artefact, create the guest, start it |
| `proxmox-destroy CONFIG` | Stop and destroy it |
| `proxmox-status CONFIG` | Print its id and state; exit non-zero if it does not exist |

| Option | |
|---|---|
| `--host [user@]hostname` | The Proxmox node. Also `proxmox.host`; no default. |
| `--id N` | VMID/CTID to use. Default: whatever id the guest of this name already has, else the next free one. |
| `--artefact iso\|img` | Which build to deploy when both exist. |
| `--replace` | Stop and destroy an existing guest of the same name first. Without it, an existing guest is an error. |
| `--yes`, `-y` | Do not ask before destroying. |
| `--no-start` | Create the guest but leave it stopped. |
| `--dry-run` | Print the `scp` and the remote script instead of running them. |
| `--platform P` | As everywhere else — it decides VM or container. |

### VM or container is not a choice

It follows from the platform, exactly as it does when building:

| Platform | Artefact | Result |
|---|---|---|
| `lxc` | `output/NAME.tar.gz` | An LXC container, `pct create` from a template |
| anything else | `output/NAME.iso` | A VM booting the installer: empty disk first in the boot order, cdrom second, so the first boot installs and every later one comes off the disk |
| anything else | `output/NAME.img` | A VM whose disk *is* the image, imported into the target storage while the VM is created |

With both an ISO and an image built, the ISO wins; `--artefact img` overrides.

### The guest's name is its identity

The name comes from the configuration — `hostname`, or `proxmox.name` — so the
guest can be found again without an id being recorded anywhere. `--id` is only
needed to pin one.

Two rules follow from that:

- A guest of the **same name** is *yours*: `--replace` stops and destroys it, and
  its id is reused.
- An id held by a guest of a **different name** is never touched, not even with
  `--replace`. That is someone else's VM.

Without `--replace`, an existing guest is an error and nothing happens.

## Configuration

Everything is read from the merged `system.json`, under a single `proxmox`
object:

```json
{
  "#include": "release.json",
  "hostname": "test-box",
  "platform": "lxc",
  "network": [
    {
      "ip-address": "10.10.10.14",
      "network-mask": "255.255.255.0",
      "gateway": "10.10.10.1",
      "dns-server": "10.10.10.1"
    }
  ],

  "proxmox": {
    "host": "root@pve-1",
    "memory": 2048,
    "cores": 4,
    "disk_size": 20
  }
}
```

| Key | Default | |
|---|---|---|
| `host` | — | `[user@]hostname` of the node. Required. |
| `ssh_port` | your ssh config | |
| `name` | `hostname` | The guest's name, and how it is found again. |
| `vmid` | see above | |
| `storage` | `local` | Where the disk / rootfs goes. |
| `template_storage` | `local` | Where the ISO or container template is uploaded. Must be a directory storage. |
| `upload_dir` | `/var/tmp` | Where a RAW image is staged before it is imported. Removed afterwards. |
| `artefact` | `iso`, else `img` | |
| `bridge` | `vmbr0` | |
| `cores` | `2` | |
| `memory` | `4096` | MB |
| `disk_size` | `16` | GB. A RAW image is imported at its own size (1636 MB) and then grown to this, so that `/data` has room for the application images; a value below the image's size is ignored. |
| `onboot` | `true` | Start the guest when the *host* boots. |
| `agent` | `true` | VM only. QEMU guest agent, which the system starts by itself on KVM. |
| `unprivileged` | `false` | LXC only. |
| `features` | `nesting=1` | LXC only. CuOS runs Docker inside the container and needs nesting. |
| `ip`, `gateway`, `nameserver` | the `network` section | LXC only, see below. |
| `net0` | generated | LXC only, escape hatch: replaces the whole generated `net0` value. |

Precedence, for all of it: **command line > environment > `system.json` >
default**.

### These keys are not device configuration

They describe where a *test* guest goes, not how the system behaves, so the OS
never reads them and they are deliberately **not** in
[`system-schema.json`](https://github.com/cuos-dev/cuos/blob/development/system/cuos/system-schema.json).
The schema does not forbid extra keys, so a configuration carrying a `proxmox`
object still validates. They are documented here and nowhere else.

They do end up inside the artefact, like the rest of the merged configuration —
which is why nothing secret belongs in them. A host name and a bridge are not
secrets; an ssh key would be, so authentication stays in your ssh
configuration, where it is anyway.

### The container's network comes from the `network` section

A container's interface belongs to the host, and CuOS knows it: inside a
container `configure_network()` returns without doing anything, so a `network`
section in `system.json` is never applied by the container itself.

So it is free for Proxmox to use, and `proxmox-create` uses it — the address is
stated once, where the rest of the system is described:

```json
{
  "network": [
    {
      "ip-address": "10.10.10.14",
      "network-mask": "255.255.255.0",
      "gateway": "10.10.10.1",
      "dns-server": "10.10.10.1"
    }
  ]
}
```

```
--net0 name=eth0,bridge=vmbr0,ip=10.10.10.14/24,gw=10.10.10.1,ip6=manual --nameserver 10.10.10.1
```

The first entry is the one used — a container gets one interface. `dhcp: true`
becomes `ip=dhcp`. `network-mask` may be dotted-decimal or a prefix length, and
a `dns-server` list becomes the space-separated list `pct` expects.

`proxmox.ip`, `proxmox.gateway` and `proxmox.nameserver` override all of that,
for the case where the container should sit somewhere other than where the
configuration says. `proxmox.ip` needs a prefix length (`10.0.0.5/24`) or
`dhcp`. With nothing to go on anywhere, `net0` gets `ip=dhcp`.

`proxmox.net0` replaces the generated value wholesale, for anything this does
not express — a VLAN tag, a second bridge, a fixed MAC.

This applies to containers only. A VM's `net0` is just the bridge: the installed
system configures its own interfaces from `system.json`, exactly as on hardware.

## What a run does on the wire

Three steps, in this order, over **one** ssh connection — the first channel
opens it and the others reuse it, so a run costs one handshake and one
authentication rather than one per command:

1. **One read-only query** for everything the decisions need: what guests exist
   and in what state, which id is free, where the template storage keeps its
   files.
2. **The upload** of the artefact (`scp`, over the same connection).
3. **One script** with every mutating command — `stop`, `destroy`, `create`,
   `disk resize`, `start` as applicable — run under `set -eux` on the far side.

The decisions in between are made locally, which is what makes step 3 a single
batch: by then it is settled which id to use, whether a guest of this name
exists, and whether you have agreed to destroying it.

Step 3 running as one script also means it **stops at the first failure**. A
`--replace` that gets as far as destroying and then fails to create leaves no
guest — but it has destroyed the old one, so re-run rather than assume the old
state is still there.

`proxmox-status` is step 1 alone. `proxmox-destroy` is steps 1 and 3.

### What you see of it

`proxmox-create` and `proxmox-destroy` print step lines and keep the rest —
`scp`'s progress, the script sent to the host together with its tracing, and
`qm`'s import output — in `output/NAME.proxmox.log`:

```
==> Uploading CuOS-test-box.img (1636 MB) to root@pve-1
==> Creating qm 131 ('test-box') on root@pve-1
==> Created and started qm 131 ('test-box') on root@pve-1.
```

The log is truncated on every run, and a failing run prints the end of it
together with its path. `DEBUG=1` puts everything on the terminal instead and
writes no log; `--dry-run` writes none either.

`proxmox-status` is unchanged: one line on stdout, for a caller to read.

### Seeing what it would do

`--dry-run` prints the `scp` and the script instead of running them:

```sh
./tool.sh proxmox-create --dry-run my-system.json
```

```
scp output/CuOS-test-box.tar.gz root@pve-1:/var/lib/vz/template/cache/CuOS-test-box.tar.gz
ssh root@pve-1 bash -s <<'EOS'
set -eux
pct create 131 local:vztmpl/CuOS-test-box.tar.gz --hostname test-box …
pct start 131
EOS
```

That block can be pasted into a terminal as it stands.

Step 1 still runs — the values in the script depend on its answers, so printing
them without asking would print fiction. Nothing is uploaded, created, started
or destroyed.

## Building several systems from one configuration

The artefact name, and therefore the guest name, comes from the configuration
([Naming](../README.md#naming)). A second variant is a second file that includes
the first and changes `system_name`:

```json
{
  "#include": "my-system.json",
  "system_name": "latest-stable",
  "os_image_version": "latest"
}
```

```sh
./tool.sh installer      my-system-latest-stable.json
./tool.sh proxmox-create my-system-latest-stable.json
```

Both guests exist side by side, each found by its own name.

## Troubleshooting

| Symptom | Check |
|---|---|
| `No Proxmox host given` | `proxmox.host` or `--host`. There is deliberately no default. |
| `Artefact not found` | Build it first; the message names the command. `./tool.sh name CONFIG` prints the expected name. |
| `… is already named 'x'` | `--replace`, or give the configuration another `hostname`. |
| `131 is in use by qemu other-vm` | The id you asked for belongs to something else. Drop `--id` and let it pick. |
| `Could not read the state of …` | Step 1 failed: ssh reachable, may that user run `pvesh`, and does `template_storage` exist? |
| `Storage 'x' has no filesystem path` | An ISO or template needs a directory storage. Point `template_storage` at one (usually `local`). |
| `unknown option --import-from` | Proxmox VE 7. Deploy an ISO instead of a RAW image, or upgrade. |
| The guest boots but `no space left on device` while it pulls its application image | `proxmox.disk_size`, and that the guest's disk really has that size (`qm config ID`). The image is 1636 MB and leaves `/data` almost nothing; the grow is what makes room. |
| The container starts but nothing happens | It is waiting for `/system_init.json` — see [LXC and Proxmox](lxc-proxmox.md#how-the-container-gets-its-configuration). |

## See also

- [LXC and Proxmox](lxc-proxmox.md) — the container variant, and the same steps by hand
- [Building an installer](installation.md)
- [Building disk images](building-images.md)
