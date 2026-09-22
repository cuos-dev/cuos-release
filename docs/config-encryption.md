# Encrypting configuration at rest

Everything in `system.json` ends up in the built artefact, and everything in
your IaC repository ends up on the device — including whatever you put there in
plain text. `config-encrypt` lets you commit a secret file as ciphertext and
have it opened again where it is needed: on your own machine, and — with CuOS
IaC as the Init App — on the running device.

```sh
./cuos-release/tool.sh config-encrypt-init my-system.json   # once per system
./cuos-release/tool.sh config-encrypt      secrets.json     # after every change
./cuos-release/tool.sh config-decrypt      secrets.json     # get the plaintext back
./cuos-release/tool.sh config-decrypt-all                   # all of them, after a clone
```

One passphrase per system opens that system's files. It is generated once, kept
out of git, and carried to the device inside the built configuration — which is
why nothing has to be typed on the device.

The whole workflow, and how much of it is yours:

| | | |
|---|---|---|
| 1 | [Set it up](#setting-it-up-once-per-system) — `config-encrypt-init` | once per system |
| 2 | [Put the passphrase somewhere safe](#keep-the-passphrase-somewhere-else) | once, by hand |
| 3 | [Encrypt your secrets](#encrypting-files) — `config-encrypt`, commit the `.enc` | whenever one changes or appears |
| 4 | Build the image | as always — the secrets come along |
| 5 | The device decrypts its files | nothing to do |
| — | [Change the passphrase](#changing-the-passphrase) — `config-sign`, pasted into the WebUI | only after a leak or a leaver |

Steps 4 and 5 need no encryption-specific action at all. On a second machine,
[one command](#on-another-machine) precedes all of it.

## This is a CuOS IaC feature

`config-encrypt` is generic — it encrypts a file, nothing more. What makes the
round trip work is the other end: **the CuOS IaC manager** reads
`system_file_password` from the configuration and decrypts the repository it
deploys. That is the only thing on a device that does so.

CuOS IaC is one [CuOS Init App](https://github.com/cuos-dev/cuos/blob/HEAD/docs/common/cuos-init-app.md)
among others, and the one `release.json` pins by default. **Run your own Init
App and none of this happens by itself**: `system_file_password` is then just a
key in your configuration, and decrypting anything is your app's job.

## Prerequisites

- `openssl` and `jq`
- A `system.json`. `config-encrypt-init` edits it.
- For the round trip on the device: CuOS IaC as the Init App.

## Setting it up, once per system

```sh
./cuos-release/tool.sh config-encrypt-init my-system.json
```

With no argument it uses `./system.json`. It works next to that file and leaves
five things behind:

| | |
|---|---|
| `system_file_password.txt` | The passphrase, 25 characters from `openssl rand`. Git-ignored. **This is the only key to everything else.** |
| `system_secrets.json` | Your secrets, as JSON. Starts as `{}` plus `system_file_password`. Git-ignored. |
| `system_secrets.json.enc` | The encrypted form — this is what you commit. |
| `"#include"` in `system.json` | `./system_secrets.json` appended, so the secrets are merged into every build. |
| `.gitignore` | The one next to the configuration, with the two plaintexts added. |

It refuses to run twice: an existing `system_file_password.txt` (exit 2) or
`system_secrets.json.enc` (exit 3) stops it, so a second run cannot replace the
passphrase of files you would then no longer be able to open.

### One passphrase per system

A device decrypts **every** `*.enc` in the IaC repository it deploys, with the
one passphrase it carries. Two systems sharing a passphrase therefore read each
other's files — and if they share the repository, each already has the other's
ciphertext on disk. A shared passphrase makes every system as exposed as the
least trusted one that holds it.

Separate passphrases make the separation automatic rather than a matter of
discipline: a file encrypted for another system fails to decrypt and is skipped.
So keep each system in its own directory and run `config-encrypt-init` in each:

```sh
./cuos-release/tool.sh config-encrypt-init systems/gateway-01/system.json
./cuos-release/tool.sh config-encrypt-init systems/gateway-02/system.json
```

```
systems/gateway-01/system.json               # "#include": ["./system_secrets.json"]
systems/gateway-01/system_secrets.json       # git-ignored
systems/gateway-01/system_secrets.json.enc   # committed
systems/gateway-01/system_file_password.txt  # git-ignored, kept out of band
systems/gateway-02/…                         # its own everything
```

Shared configuration is still shared — the split is between secrets and
everything else, not between systems:

```json
{
  "#include": ["../../common/network.json", "./system_secrets.json"],
  "hostname": "gateway-01"
}
```

The same holds for the secret *files* in the IaC repository: encrypt each
system's `.env` or key with that system's passphrase. Where several systems
genuinely need one secret, one `.enc` per passphrase keeps the blast radius at
one system.

## Keep the passphrase somewhere else

**Do this by hand, now** — it is the one step no command performs for you, and
`config-encrypt-init` closes by asking for it. Into a password manager, or as a
file encrypted with `gpg`:

```sh
gpg --encrypt --armor -r you@example.com -r colleague@example.com \
  -o systems/gateway-01/system_file_password.txt.asc \
  systems/gateway-01/system_file_password.txt
```

**The `.asc` may be committed** — that is what encrypting it is for, and beside
the configuration is where a colleague finds it. Name everyone who is to have it
as a recipient, and re-encrypt to fewer recipients when someone leaves.
`system_file_password.txt` itself stays where it is, git-ignored, so the tooling
keeps finding it.

Why it matters more than it looks: `system_secrets.json.enc` is encrypted with
the passphrase it contains, so the passphrase cannot be recovered from anything
in the repository. Lose it and every encrypted file is lost with it.

## Encrypting files

Two kinds of file go through `config-encrypt`, differing only in what happens to
them afterwards.

### Secrets that belong in the configuration

Keep them in `system_secrets.json` and the `#include` makes them part of the
merge, so a key put there can be used like any other `system.json` key:

```sh
$EDITOR system_secrets.json        # e.g. "iac_repo_url": "https://user:TOKEN@github.com/me/my-iac.git"
./cuos-release/tool.sh config-encrypt system_secrets.json
git add system_secrets.json.enc && git commit -m "feat: iac repo credentials"
```

`config-encrypt` writes `<file>.enc` and **leaves the plaintext in place** — it
encrypts, it does not replace. After every edit the `config-encrypt` has to be
repeated, or the commit carries the old secret.

### Any other file

`config-encrypt` takes a path, not a format. So anything a service needs but
nobody should read in git goes the same way — `.env` files, SSH and deploy keys,
TLS private keys, API tokens, licence files:

```sh
./cuos-release/tool.sh config-encrypt iac/.env               # → iac/.env.enc
./cuos-release/tool.sh config-encrypt iac/certs/server.key
```

These are **not** merged into the configuration — they stay files. Commit the
`.enc`, ignore the plaintext, and the device puts each one back next to its
`.enc` under its original name before the services start. A service that reads
`./certs/server.key` therefore needs no change.

Only `config-encrypt-init` writes `.gitignore`, and only for its own two files.
For everything you encrypt afterwards, ignoring the plaintext is your job:

```gitignore
# beside the .enc files you commit
iac/.env
iac/certs/server.key
```

Check what a build will really use — the merged configuration, secrets included:

```sh
./cuos-release/tool.sh config my-system.json
```

## On another machine

A fresh clone has only the `.enc` files. Put the passphrase in place and unpack
everything:

```sh
cp /somewhere/safe/system_file_password.txt .
./cuos-release/tool.sh config-decrypt-all
```

**Do this before building.** `system.json` `#include`s `system_secrets.json`,
and a missing include is a fatal error — so in a fresh clone every `tool.sh`
command that reads the configuration fails with `File not found:
.../system_secrets.json` until the secrets have been decrypted once.

`config-decrypt-all` finds every `*.enc` below the current directory, decrypts
it, and lists the plaintext names in its own block of `.git/info/exclude`, so
the files it just created cannot be committed by accident. `config-decrypt FILE`
does one file, named with or without `.enc`.

A file is skipped when its plaintext is **newer** than the `.enc`, so local
edits survive a `config-decrypt-all`. The flip side: a stale plaintext is not
refreshed from an `.enc` someone else updated. Delete it and decrypt again if in
doubt.

### Where the passphrase comes from

Each command takes the first it finds: `IAC_FILE_PASSPHRASE` from the
environment, then `system_file_password.txt` on disk, then
`.system_file_password` in `system_secrets.json`, then a prompt. How far the
search on disk reaches is **not** the same everywhere:

| | Looks in |
|---|---|
| `config-encrypt` | the current directory, then one and two levels up |
| `config-decrypt`, `config-decrypt-all` | **the current directory only** |

So you can encrypt from inside a subdirectory of the repository, but decrypting
means standing where the passphrase is — or naming it in the environment, as CI
would:

```sh
IAC_FILE_PASSPHRASE="$(cat "$RUNNER_SECRET")" ./cuos-release/tool.sh config-decrypt-all
```

## How it gets onto the device

Build the image as you always would, and that is everything you do. No key is
copied to the device, nothing is typed on it. The chain is the configuration
itself:

1. `system_secrets.json` is `#include`d, so the merge puts `system_file_password`
   into the built configuration.
2. The configuration is baked into the artefact — and signed with `config-sign`,
   if you sign.
3. On the device the IaC manager reads `system_file_password` from it, clones
   your IaC repository, and decrypts every `*.enc` in it before the services
   start. The plaintext names go into that clone's `.git/info/exclude`.

The files must have been encrypted with **this** system's passphrase. An `.enc`
belonging to another system is skipped with a warning and the service that
wanted it starts without its file — which is what keeps two systems in one IaC
repository out of each other's secrets.

**What this protects, and what it does not.** The secrets are protected in the
repository — in git history, in a mirror, in a backup of the clone. They are not
protected on the device: the passphrase is in the configuration, the
configuration is in the image, and the decrypted files are on the device's disk
while it runs. Anyone who can read the image or the running system reads the
secrets. For that, see the disk encryption work in the CuOS repository.

## Changing the passphrase

Someone leaves, or the passphrase leaks. Two things make this not a normal
commit.

**The repository cannot carry its own replacement.** Putting a new passphrase
into `system_secrets.json` and committing it does not work:
`system_secrets.json.enc` is encrypted with the **old** passphrase, because that
is the one the devices still have. Anyone with the old passphrase and read
access — exactly the person you are locking out — decrypts it and reads the new
one. Every route through the repository has this shape, so the new passphrase
has to travel on one the old does not protect: a **signed configuration**.

**And rotating the passphrase alone is pointless.** Whoever had it has already
read every secret it opened. Regenerate the secrets themselves — that is the
work; the passphrase is the small part.

The work is per system, which is where
[one passphrase per system](#one-passphrase-per-system) pays for itself: a leak
costs one system's secrets and one paste, not every system's.

### The steps

1. **Regenerate every secret** that was encrypted under the old passphrase, and
   revoke the old ones at the issuing end.
2. **Regenerate the passphrase**, into `system_file_password.txt` *and* into
   `system_secrets.json` as `system_file_password` — they must match. Store it
   as in step 2 above.
3. **Re-encrypt everything** and commit the `.enc` files. Devices in the field
   cannot read them yet; that is the point.
4. **Remove the leaver's signing key** from `iac_repo_signing_keys` in the same
   change, if they had one.
5. **Sign the configuration:**

   ```sh
   ./cuos-release/tool.sh config-sign my-system.json
   ```

   It prints one line: the merged configuration and an SSH signature over it,
   base64url, separated by a dot. Signs with `~/.ssh/id_ed25519` unless
   `IAC_SIGNKEY_PATH` says otherwise. The output contains the new passphrase in
   clear — it is signed, not encrypted.

6. **Paste it into the WebUI**, on the *Config* page (`/config`). Per device.

The device verifies the signature against `iac_repo_signing_keys`, merges the
configuration and applies it. From then on it can read the `.enc` files from
step 3.

### What can go wrong

- **`iac_repo_signing_keys` has to be set on the device already.** The manager
  writes those keys out only when the list is non-empty; with no list there is
  nothing to verify against and the paste is rejected with *no principal
  identified*. Such a device has to be reinstalled.
- **The signature expires after 15 minutes** — `config-sign` stamps it with
  `iat`, accepted from a minute before to fifteen minutes after. Sign, then
  paste; check the device's clock if it is refused.
- **Your own signing key must be in the list**, not just the leaver's removed.
- **The configuration is merged, not replaced.** Keys you send overwrite, keys
  you omit stay — so this cannot delete one. Lists are the exception: a list
  replaces the old one entirely, which is what makes step 4 work.
- **It is one paste per device.**

### Or reinstall

Building a fresh image with the new secrets is the other answer, and for a few
reachable devices often the simpler one: no signing key, no WebUI access, no
clock. Signing wins when the devices are remote, numerous, or must not lose
their state.

## The algorithm

`openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt`, passphrase-derived key,
no key file and no asymmetric part. Decryption is plain `openssl` too, so an
`.enc` can be opened without this tooling:

```sh
openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 \
  -in system_secrets.json.enc -out system_secrets.json \
  -pass pass:"$(cat system_file_password.txt)"
```

## Gotchas

- **One passphrase per system, for every one of that system's files.** There is
  no per-file key, so anyone given it can read all of that system's secrets.
- **Changing the passphrase cannot go through the repository** — the new one
  would be encrypted with the old. See
  [Changing the passphrase](#changing-the-passphrase).
- **The passphrase lookup starts at the working directory**, not at the
  configuration, and `config-decrypt` alone does not search upwards.
- **`config-decrypt-all` owns one block of `.git/info/exclude`**, between
  `# BEGIN cuos config-decrypt` and `# END cuos config-decrypt`. Everything
  outside it is yours and is kept; editing inside it is pointless, as the next
  run rewrites it.
