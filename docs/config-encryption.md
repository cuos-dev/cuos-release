# Encrypting configuration at rest

Everything in `system.json` ends up in the built artefact, and everything in
your IaC repository ends up on the device — including whatever you put there in
plain text. `config-encrypt` lets you commit a secret file as ciphertext and
have it opened again where it is needed: on your own machine, and on the running
device.

```sh
./cuos-release/tool.sh config-encrypt-init my-system.json   # once per repository
./cuos-release/tool.sh config-encrypt      secrets.json     # after every change
./cuos-release/tool.sh config-decrypt      secrets.json     # get the plaintext back
./cuos-release/tool.sh config-decrypt-all                   # all of them, after a clone
```

One passphrase opens everything. It is generated once, kept out of git, and
carried to the device inside the built configuration — which is why nothing has
to be typed on the device.

The whole workflow, and how much of it is yours:

| | | |
|---|---|---|
| 1 | [Set it up](#setting-it-up-once-per-repository) — `config-encrypt-init` | once per repository |
| 2 | [Put the passphrase somewhere safe](#keep-the-passphrase-somewhere-else) | once, by hand, outside this repository |
| 3 | [Encrypt what you want to keep secret](#encrypting-files) — `config-encrypt`, commit the `.enc` | whenever a secret changes or a new one appears |
| 4 | Build the image | as always — the secrets come along by themselves |
| 5 | The device decrypts its files | nothing to do |

Steps 4 and 5 need no encryption-specific action at all:
`./cuos-release/tool.sh image my-system.json` is the whole of step 4, and the
device does step 5 on its own — see
[How it gets onto the device](#how-it-gets-onto-the-device). On a second
machine, [one command](#on-another-machine) precedes all of it.

## Prerequisites

- `openssl` and `jq`
- A `system.json`. `config-encrypt-init` edits it.

## Setting it up, once per repository

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
| `.gitignore` | The two plaintext files added. |

It refuses to run twice: an existing `system_file_password.txt` is an error, so
a second run cannot replace the passphrase of files you can no longer open.

## Keep the passphrase somewhere else

**Do this before anything else, and do it by hand** — it is the one step no
command performs for you, and `config-encrypt-init` closes by asking for it:

- into a password manager, or
- as a file encrypted with `gpg`, kept outside this repository

`system_file_password.txt` itself stays where it is, git-ignored, so the tooling
keeps finding it. The copy is what survives a lost laptop or a re-clone.

Why it matters more than it looks: `system_secrets.json.enc` is encrypted with
the passphrase it contains, so the passphrase cannot be recovered from anything
in the repository. Lose it and every encrypted file is lost with it. It is also
the one thing a new colleague needs — and the one file that must never be
committed.

## Encrypting files

Two kinds of file go through `config-encrypt`, and they differ only in what
happens to them afterwards.

### Secrets that belong in the configuration

Keep them in `system_secrets.json` and they reach the configuration by
themselves — the `#include` makes them part of the merge, so a key put there can
be used like any other `system.json` key:

```sh
$EDITOR system_secrets.json        # e.g. "iac_repo_url": "https://user:TOKEN@github.com/me/my-iac.git"
./cuos-release/tool.sh config-encrypt system_secrets.json
git add system_secrets.json.enc && git commit -m "feat: iac repo credentials"
```

`config-encrypt` writes `<file>.enc` and **leaves the plaintext in place** — it
encrypts, it does not replace. So the two files exist side by side, the
plaintext ignored by git and the `.enc` committed; after every edit the
`config-encrypt` has to be repeated, or the commit carries the old secret.

### Any other file

`config-encrypt` takes a path, not a format — nothing about it is specific to
JSON or to `system.json`. So anything a service needs but nobody should read in
git goes the same way:

```sh
./cuos-release/tool.sh config-encrypt iac/.env               # → iac/.env.enc
./cuos-release/tool.sh config-encrypt iac/ssh/id_ed25519
./cuos-release/tool.sh config-encrypt iac/certs/server.key   # the HTTPS private key
./cuos-release/tool.sh config-encrypt iac/app/license.dat
```

Typical: `.env` files with service credentials, SSH private keys and deploy
keys, TLS/HTTPS private keys and certificates, API tokens, licence files,
VPN configurations.

These are **not** merged into the configuration — they stay files. Commit the
`.enc`, ignore the plaintext, and the device puts each one back exactly where it
was, next to its `.enc` and under its original name, before the services start.
A service that reads `./certs/server.key` therefore needs no change: on the
device the file is simply there.

Only `config-encrypt-init` writes `.gitignore`, and only for its own two files.
For everything you encrypt afterwards, ignoring the plaintext is your job:

```gitignore
# beside the .enc files you commit
iac/.env
iac/ssh/id_ed25519
iac/certs/server.key
```

(On a clone, `config-decrypt-all` covers them too — it writes every name it
decrypts into `.git/info/exclude`. The `.gitignore` is what protects the machine
the file was *created* on.)

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
it, and writes the plaintext names into `.git/info/exclude` — so the files it
just created cannot be committed by accident, even where no `.gitignore` covers
them. `config-decrypt FILE` does one file; it takes the name with or without
`.enc`.

A file is skipped when its plaintext is **newer** than the `.enc`, so your local
edits survive a `config-decrypt-all`. The flip side: a plaintext left over from
earlier will not be refreshed from an `.enc` someone else updated. Delete it and
decrypt again if in doubt.

### Where the passphrase comes from

Every one of the four commands looks for it in the same order and takes the
first it finds:

1. `IAC_FILE_PASSPHRASE` in the environment
2. `system_file_password.txt` — in the current directory, then one and two
   levels up
3. `.system_file_password` in `system_secrets.json` — same three levels
4. a prompt

The search upwards is what lets you work inside a subdirectory of the
configuration repository. For CI, set the environment variable and no file is
needed:

```sh
IAC_FILE_PASSPHRASE="$(cat "$RUNNER_SECRET")" ./cuos-release/tool.sh config-decrypt-all
```

## How it gets onto the device

**Steps 4 and 5 are automatic.** Build the image as you always would —

```sh
./cuos-release/tool.sh image my-system.json
```

— and that is everything you do. No key is copied to the device, nothing is
typed on it, and no `config-decrypt` is run there by hand. The chain is the
configuration itself:

1. `system_secrets.json` is `#include`d, so the merge puts `system_file_password`
   into the built configuration.
2. The configuration is baked into the artefact — and signed with
   `config-sign`, if you sign.
3. On the device the IaC manager reads `system_file_password` from that
   configuration, clones your IaC repository, and decrypts every `*.enc` in it
   before the services start. The plaintext names go into the clone's
   `.git/info/exclude`, exactly as `config-decrypt-all` does.

The one thing that has to be true: the files must have been encrypted with
**this** system's passphrase. An `.enc` from another configuration repository is
skipped with a warning, and the service that wanted it starts without its file.

So the device can open anything you encrypted with this passphrase, and the
git repository never holds a plaintext secret.

**What this protects, and what it does not.** The secrets are protected in the
repository — in git history, in a mirror, in a backup of the clone. They are not
protected on the device: the passphrase is in the configuration, the
configuration is in the image, and the decrypted files are on the device's disk
while it runs. Anyone who can read the image or the running system reads the
secrets. For that, see the disk encryption work in the CuOS repository — not
this.

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

- **One passphrase per repository, for every file.** There is no per-file key
  and no way to give someone one file without giving them all of them.
- **Rotating it is manual**: decrypt everything with the old passphrase, replace
  `system_file_password.txt` and the `system_file_password` key in
  `system_secrets.json`, re-encrypt everything, rebuild. Devices in the field
  keep the old passphrase until they are updated with a configuration carrying
  the new one.
- **`config-encrypt-init` writes `.gitignore` entries next to the configuration
  file.** If your `system.json` is not in the repository root, check them — the
  paths are written relative to the root, into a `.gitignore` that is not there.
- **`config-decrypt-all` writes `.git/info/exclude` wholesale**, replacing what
  that file contained. It is a generated file here, not one to edit.
