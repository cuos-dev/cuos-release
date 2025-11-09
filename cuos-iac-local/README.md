# CuOS IaC local mode

You can run the IaC manager wihout CuOS (OS) on every docker environment.
This is useful for existing infrastructure and for development.

Prerequisits:

* Docker installed
* jq installed

## Start (quick)

From the repo root:

```sh
./packager.sh start-iac-local path/to/system.json
```

Check running containers:

```sh
docker ps
```

## Manual start


Generate or copy a merged system.json into this directory:

```sh
cd cuos-iac-local/
../packager.sh config path/to/system.json >system.json
```

Start the stack:

```sh
docker compose -d up
```

Verify services:

```sh
docker ps
```

## Stop

Just stop all started containers and remove dangling volumes.

**Attention**: `docker compose down` will only stop the iac manager, not the started applications.

