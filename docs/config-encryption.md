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

**Put the passphrase somewhere safe before you do anything else** — a password
manager, or `gpg`, as the command's own closing message asks. `system_secrets.json.enc`
is encrypted with the passphrase it contains, so losing `system_file_password.txt`
loses every encrypted file with it. It is also the one file a new colleague
needs, and the one file that must never be committed.

## Working with secrets

Keep the secrets in `system_secrets.json` and they reach the configuration by
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

The same works for any other file in the repository — an `.env`, a key, a whole
compose file:

```sh
./cuos-release/tool.sh config-encrypt iac/.env   # → iac/.env.enc
```

Those files are not merged into the configuration; they are decrypted **on the
device**, in place, next to their `.enc` (see below).

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

Nothing is typed on the device, and no key is copied to it separately. The chain
is the configuration itself:

1. `system_secrets.json` is `#include`d, so the merge puts `system_file_password`
   into the built configuration.
2. The configuration is baked into the artefact — and signed with
   `config-sign`, if you sign.
3. On the device the IaC manager reads `system_file_password` from that
   configuration, clones your IaC repository, and decrypts every `*.enc` in it
   before the services start. The plaintext names go into the clone's
   `.git/info/exclude`, exactly as `config-decrypt-all` does.

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
