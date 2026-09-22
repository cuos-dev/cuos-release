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
| 2 | [Put the passphrase somewhere safe](#keep-the-passphrase-somewhere-else) | once, by hand, outside this repository |
| 3 | [Encrypt what you want to keep secret](#encrypting-files) — `config-encrypt`, commit the `.enc` | whenever a secret changes or a new one appears |
| 4 | Build the image | as always — the secrets come along by themselves |
| 5 | The device decrypts its files | nothing to do |
| — | [Change the passphrase](#changing-the-passphrase) — `config-sign`, pasted into the WebUI | only after a leak or a leaver |

Steps 4 and 5 need no encryption-specific action at all:
`./cuos-release/tool.sh image my-system.json` is the whole of step 4, and the
device does step 5 on its own — see
[How it gets onto the device](#how-it-gets-onto-the-device). On a second
machine, [one command](#on-another-machine) precedes all of it.

## This is a CuOS IaC feature

`config-encrypt` itself is generic — it encrypts a file, nothing more. What
makes the round trip work is the other end: **the CuOS IaC manager** reads
`system_file_password` from the configuration and decrypts the repository it
deploys. That is the only thing on a device that does so.

CuOS IaC is one [CuOS Init App](https://github.com/cuos-dev/cuos/blob/HEAD/docs/common/cuos-init-app.md)
among others, and it is the one `release.json` pins by default. **Run your own
Init App and none of this happens by itself**: `system_file_password` is then
just a key in your configuration, and decrypting anything is your app's job.
`config-encrypt` and `config-decrypt` still work on your own machine, but the
device does nothing with an `.enc` unless you write the code that does.

## Prerequisites

- `openssl` and `jq`
- A `system.json`. `config-encrypt-init` edits it.
- For the round trip on the device: CuOS IaC as the Init App.

## Setting it up, once per system

```sh
./cuos-release/tool.sh config-encrypt-init my-system.json
```

**Once per system, not once per repository** — a passphrase shared between
systems is a system that can read another system's secrets, see
[One passphrase per system](#one-passphrase-per-system).

With no argument it uses `./system.json`. It works next to that file and leaves
five things behind:

| | |
|---|---|
| `system_file_password.txt` | The passphrase, 25 characters from `openssl rand`. Git-ignored. **This is the only key to everything else.** |
| `system_secrets.json` | Your secrets, as JSON. Starts as `{}` plus `system_file_password`. Git-ignored. |
| `system_secrets.json.enc` | The encrypted form — this is what you commit. |
| `"#include"` in `system.json` | `./system_secrets.json` appended, so the secrets are merged into every build. |
| `.gitignore` | The two plaintext files added. |

The `.gitignore` is the one next to the configuration file — created if it is
not there, appended to if it is, and never the same entry twice.

It refuses to run twice: an existing `system_file_password.txt` (exit 2) or an
existing `system_secrets.json.enc` (exit 3) stops it, so a second run cannot
replace the passphrase of files you would then no longer be able to open.

### One passphrase per system

Give every system its own passphrase and its own `system_secrets.json`. The
reason is the decryption on the device: a device decrypts **every** `*.enc` it
finds in the IaC repository it deploys, with the one passphrase it carries. Two
systems sharing a passphrase therefore read each other's files — and if they
share the IaC repository, each device already has the other's ciphertext on its
disk. A shared passphrase makes every system as exposed as the least trusted one
that holds it.

Separate passphrases make that automatic rather than a matter of discipline: a
file encrypted for another system fails to decrypt, is skipped with a warning,
and its plaintext never exists on this device.

Keep each system in its own directory, and run `config-encrypt-init` in each:

```
systems/gateway-01/system.json               # "#include": ["./system_secrets.json"]
systems/gateway-01/system_secrets.json       # git-ignored
systems/gateway-01/system_secrets.json.enc   # committed
systems/gateway-01/system_file_password.txt  # git-ignored, kept out of band
systems/gateway-02/…                         # its own everything
```

```sh
./cuos-release/tool.sh config-encrypt-init systems/gateway-01/system.json
./cuos-release/tool.sh config-encrypt-init systems/gateway-02/system.json
```

Shared, non-secret configuration is `#include`d as usual — the split is between
secrets and everything else, not between systems:

```json
{
  "#include": ["../../common/network.json", "./system_secrets.json"],
  "hostname": "gateway-01"
}
```

For the secret *files* in the IaC repository the same rule holds: encrypt each
system's `.env` or key with that system's passphrase. Where several systems
genuinely need the same secret, encrypting it once per system — one `.enc` per
passphrase — keeps the blast radius at one system when one passphrase goes.

Note that each directory gets its own `system_file_password.txt` and its own
`.gitignore` entry, and that `config-encrypt` looks for the passphrase from the
working directory upwards — so work from the system's directory, or set
`IAC_FILE_PASSPHRASE`.

## Keep the passphrase somewhere else

**Do this before anything else, and do it by hand** — it is the one step no
command performs for you, and `config-encrypt-init` closes by asking for it:

- into a password manager, or
- as a file encrypted with `gpg`

```sh
gpg --encrypt --armor -r you@example.com -r colleague@example.com \
  -o systems/gateway-01/system_file_password.txt.asc \
  systems/gateway-01/system_file_password.txt
```

**The `.asc` may be committed.** That is what encrypting it is for, and keeping
it beside the configuration is how a colleague finds it at all. Name every
person who is to have it as a recipient, and re-encrypt to fewer recipients when
someone leaves.

`system_file_password.txt` itself stays where it is, git-ignored, so the tooling
keeps finding it. The `.asc` is what survives a lost laptop or a re-clone.

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

#### A `.env`, start to finish

The common case, in full. Write the file, encrypt it, ignore the plaintext,
commit the ciphertext:

```sh
cd systems/gateway-01          # where this system's passphrase lives

cat >iac/.env <<'EOF'
POSTGRES_PASSWORD=s3cr3t
SMTP_TOKEN=abc123
EOF

../../cuos-release/tool.sh config-encrypt iac/.env   # → iac/.env.enc
echo '/iac/.env' >>.gitignore

git add iac/.env.enc .gitignore
git commit -m "feat: database and smtp credentials"
```

The service uses it exactly as it would without any of this — the device has
put the plaintext back next to the `.enc` before compose runs:

```yaml
services:
  app:
    image: "ghcr.io/your-org/app:1.2.3"
    env_file: .env
```

Changing a value means editing `iac/.env` and running `config-encrypt` again;
the plaintext is not what gets committed, so an edit without the re-encrypt
changes nothing:

```sh
$EDITOR iac/.env
../../cuos-release/tool.sh config-encrypt iac/.env
git commit -am "feat: rotate the smtp token"
```

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

Each command looks in the same order and takes the first it finds:

1. `IAC_FILE_PASSPHRASE` in the environment
2. `system_file_password.txt` on disk
3. `.system_file_password` in `system_secrets.json`
4. a prompt

How far the search on disk reaches is **not** the same everywhere:

| | Looks in |
|---|---|
| `config-encrypt` | the current directory, then one and two levels up |
| `config-decrypt-all` | the same three levels |
| `config-decrypt` | **the current directory only** |

The search upwards is what lets you encrypt from inside a subdirectory of the
configuration repository. `config-decrypt` does not do it, so decrypting a
single file means standing in its system's directory — or naming the passphrase
in the environment. After a clone, reach for `config-decrypt-all` anyway.

For CI, set the environment variable and no file is needed:

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
**this** system's passphrase. An `.enc` belonging to another system is skipped
with a warning, and the service that wanted it starts without its file — which
is what keeps two systems in one IaC repository out of each other's secrets.

So the device can open anything you encrypted with this passphrase, and the
git repository never holds a plaintext secret.

**What this protects, and what it does not.** The secrets are protected in the
repository — in git history, in a mirror, in a backup of the clone. They are not
protected on the device: the passphrase is in the configuration, the
configuration is in the image, and the decrypted files are on the device's disk
while it runs. Anyone who can read the image or the running system reads the
secrets. For that, see the disk encryption work in the CuOS repository — not
this.

## Changing the passphrase

Someone leaves, or the passphrase leaks. Replacing it is not a normal commit,
and the reason is worth understanding before the steps.

**The repository cannot carry its own replacement.** The obvious move is to put
a new passphrase into `system_secrets.json`, encrypt, commit, let the devices
pick it up. It does not work: `system_secrets.json.enc` is encrypted with the
**old** passphrase, because that is the one the devices still have. Anyone with
the old passphrase and read access to the repository — exactly the person you
are locking out — decrypts it and reads the new one. Every route through the
git repository has this shape.

So the new passphrase has to reach the devices on a path the old one does not
protect. That path is a **signed configuration**, verified against
`iac_repo_signing_keys` and pasted into the WebUI.

Also: **rotating the passphrase alone is pointless.** Whoever had it has already
read every secret it opened. Re-encrypting the same tokens and keys under a new
passphrase protects nothing. Regenerate the secrets themselves — that is the
work; the passphrase is the small part.

**The work is per system**, and this is where
[one passphrase per system](#one-passphrase-per-system) pays for itself: a
leaked passphrase costs you one system's secrets and one paste. Had the systems
shared it, every one of them would need the full procedure, and every secret of
every system would have to be regenerated.

### The steps

1. **Regenerate every secret.** New repository tokens or deploy keys, new
   service credentials, new TLS keys, new API tokens — everything that was
   encrypted under the old passphrase, and anything else the person could read.
   Revoke the old ones at the issuing end.
2. **Regenerate the passphrase.** Write a new one into `system_file_password.txt`
   and into `system_secrets.json` as `system_file_password` — both, they must
   match. Store the new one as in step 2 of the workflow above.
3. **Re-encrypt everything** with the new passphrase and commit the `.enc`
   files. Devices in the field cannot read them yet; that is expected and it is
   the point.
4. **Remove the leaver's signing key** from `iac_repo_signing_keys` in the same
   change, if they had one. A signed configuration replaces the list wholesale,
   so dropping an entry works — see the merge note below.
5. **Sign the configuration:**

   ```sh
   ./cuos-release/tool.sh config-sign my-system.json
   ```

   This prints one line: the merged configuration and an SSH signature over it,
   base64url, separated by a dot. It signs with `~/.ssh/id_ed25519` unless
   `IAC_SIGNKEY_PATH` says otherwise. The output contains the new passphrase in
   clear — it is signed, not encrypted.

6. **Paste it into the WebUI**, on the *Config* page (`/config`), and submit.
   Per device.

The device verifies the signature against the keys from `iac_repo_signing_keys`,
merges the configuration, and applies it. From then on it holds the new
passphrase and can read the `.enc` files you committed in step 3.

### What can go wrong

- **`iac_repo_signing_keys` has to be set on the device already.** The manager
  writes those keys out only when the list is non-empty; with no list there is
  nothing to verify against and the paste is rejected with *no principal
  identified*. A device that never had signing keys configured cannot be
  rotated this way — it has to be reinstalled.
- **The signature expires after 15 minutes.** `config-sign` stamps the payload
  with `iat`, and the device accepts it from one minute before to fifteen
  minutes after. Sign, then paste — do not sign ahead of a maintenance window,
  and check the device's clock if it is refused.
- **Your own signing key must be in the list**, not just the leaver's removed.
- **The configuration is merged, not replaced.** Keys you send overwrite, keys
  you omit stay as they were — so this cannot delete a key from a device's
  configuration. Lists are the exception: a list you send replaces the old one
  entirely, which is what makes step 4 work.
- **It is one paste per device.** For a fleet, weigh this against reinstalling.

### Or reinstall

Building a fresh image with the new secrets and installing it is the other
answer, and for a small number of reachable devices it is often the simpler one.
It needs no signing key, no WebUI access and no clock. Signing wins when the
devices are remote, numerous enough that travel hurts, or must not lose their
state.

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
  no per-file key, so anyone given a system's passphrase can read all of its
  secrets. Across systems the separation is real — see
  [One passphrase per system](#one-passphrase-per-system).
- **Changing the passphrase cannot go through the repository** — the new one
  would be encrypted with the old. See
  [Changing the passphrase](#changing-the-passphrase).
- **The passphrase lookup starts at the working directory, not at the
  configuration**, and `config-decrypt` alone does not search upwards. With a
  `system.json` in a subdirectory, work from that directory or set
  `IAC_FILE_PASSPHRASE`.
- **`config-decrypt-all` writes `.git/info/exclude` wholesale**, replacing what
  that file contained. It is a generated file here, not one to edit.
