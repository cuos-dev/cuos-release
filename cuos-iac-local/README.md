# CuOS IaC local mode

You can run the IaC manager without CuOS (OS) on every docker environment.
This is useful for existing infrastructure and for development.

Prerequisites:

* Docker installed
* jq installed

## Start (quick)

From the directory holding the checkout:

```sh
./cuos-release/tool.sh start-iac-local path/to/system.json
```

Check running containers:

```sh
docker ps
```

## Manual start


Generate or copy a merged system.json into this directory:

```sh
cd cuos-iac-local/
../tool.sh config path/to/system.json >system.json
```

Start the stack:

```sh
docker compose up -d
```

Verify services:

```sh
docker ps
```

## Stop or update

Trigger an update:

```sh
./cuos-release/tool.sh update-iac-local path/to/system.json
```

Stop the manager and all started services:

```sh
./cuos-release/tool.sh stop-iac-local path/to/system.json
```

`stop-iac-local` stops the started containers too, and removes dangling volumes.

**Attention**: `docker compose down` will only stop the iac manager, not the started applications.

