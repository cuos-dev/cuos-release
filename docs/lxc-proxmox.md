# LXC containers and Proxmox VE

CuOS can run as an LXC container instead of on its own disk. The build produces
a container root filesystem rather than a partitioned image, so there is no
kernel, no bootloader and no partition table involved.

How the container variant differs from a normal CuOS system is described in
[the LXC notes in cuos](https://github.com/cuos-dev/cuos/blob/development/docs/common/lxc-deployment.md).

## Build

Give the configuration an LXC image and build with `--platform lxc`:

```json
{
  "#include": "release.json",
  "hostname": "my-container",
  "initial_image": "docker.io/library/nginx",
  "initial_image_version": "latest"
}
```

```sh
./tool.sh image --platform lxc my-container.json
```

Unlike a disk image, this one **runs** a script inside the container while
building it. Building an LXC image for a foreign architecture therefore needs
binfmt/QEMU emulation on the build host; same-architecture builds need nothing
extra.

The result is a gzipped tarball in `./output/`:

```sh
./tool.sh name my-container.json      # -> CuOS-my-container, so CuOS-my-container.tar.gz
```

## How the container gets its configuration

This is the part worth understanding before deploying, because it decides
whether one image serves one container or many.

At startup CuOS looks for **`/system_init.json`** inside the container and copies
it to `/system.json`. If the file is not there yet, **it waits** — the container
starts and blocks until the configuration appears.

The build copies the configuration you passed in to `/system_init.json`, so a
freshly built tarball already carries its own configuration and needs nothing
further.

That gives you two ways to work:

- **One image per system.** Build with the configuration you want; deploy; done.
- **One image for many systems.** Build a generic image, then place a
  per-container `/system_init.json` after creating the container. The container
  waits for it, so the order is safe.

## Proxmox VE

`tool.sh` can do all of the following in one command —
`./tool.sh proxmox-create my-container.json`, see
[Deploying to Proxmox VE](testing-on-proxmox.md). The manual steps below are
what it does, and what to reach for when the container is not being built by
this tooling.

### Upload the template

```sh
scp output/CuOS-my-container.tar.gz \
    root@proxmox:/var/lib/vz/template/cache/cuos-my-container.tar.gz
```

### Create the container

In the web interface: **Datacenter → Node → Create CT**, pick the uploaded
template, then set hostname, resources and network. Under *Options/Features*
enable **nesting** — CuOS runs Docker inside the container and needs it.
Privileged and unprivileged both work.

From the command line:

```sh
pct create 100 /var/lib/vz/template/cache/cuos-my-container.tar.gz \
  --hostname cuos-container \
  --memory 2048 \
  --cores 2 \
  --net0 name=eth0,bridge=vmbr0,ip=dhcp \
  --features nesting=1 \
  --unprivileged 0
```

The password Proxmox asks for is replaced at the first system update.

### Supply the configuration

If the image was built generically, or you want to deploy it with a different
configuration than it was built with, copy one into the container:

```sh
pct push 100 my-container.json /system_init.json
```

The container picks it up from its wait loop and continues starting. Do this
before the container has configured itself — once `/system.json` exists, it is
not read again.

### Network

**Proxmox configures the container's network, always.** CuOS does not: inside a
container `configure_network()` returns without touching anything, because the
interface belongs to the host. A `network` section in `system.json` is therefore
not applied by the container — it is ignored.

That does not make it pointless to write one. `./tool.sh proxmox-create` reads it
and hands the address to Proxmox, so the network is stated once, in the same
file as the rest of the system:

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

becomes

```
--net0 name=eth0,bridge=vmbr0,ip=10.10.10.14/24,gw=10.10.10.1,ip6=none --nameserver 10.10.10.1
```

Creating the container by hand, that translation is yours to make.

### Look inside

```sh
pct enter 100
journalctl -f
```

## Plain LXC / LXD

Untested, for advanced users:

```sh
lxc image import output/CuOS-my-container.tar.gz --alias cuos-base
lxc launch cuos-base my-cuos
```

Nesting and the kernel modules Docker needs:

```yaml
config:
  security.nesting: "true"
  security.privileged: "true"
  linux.kernel_modules: overlay,nf_nat,ip_tables
```

Persistent storage:

```sh
lxc config device add my-cuos data disk source=/host/path path=/data
```

Logs: `lxc exec my-cuos -- journalctl -f`

## Troubleshooting

| Symptom | Check |
|---|---|
| The container starts but nothing happens | Is `/system_init.json` present? It waits for it — `pct push` it. |
| Docker does not start inside the container | Nesting enabled? Kernel modules available? Try privileged mode. |
| No network | Configured on the Proxmox side? A `network` section in `system.json` is not applied inside a container — see [Network](#network) |
| Application container not pulled | Registry credentials in the configuration, and DNS inside the container |
