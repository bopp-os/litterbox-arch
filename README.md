# litterbox-arch

Packaging and helper tools for running [Litterbox](https://litterbox.work/) (a Podman-based development sandbox with a
confirm-before-sign SSH agent) on Arch, CachyOS and BoppOS.

[bopp-os/pkgbuilds](https://github.com/bopp-os/pkgbuilds) mirrors the two package folders from here, so this repo is where
the packages are written and kept up to date.

## What is here

| Path | What it is |
|---|---|
| `litterbox-sandbox/` | PKGBUILD that builds upstream Litterbox from its release tarball (Apache-2.0 upstream, not included here). `lbx-init` is built for the musl target and installed next to `litterbox`, which looks for it beside its own executable. |
| `litterbox-sandbox-addons/` | PKGBUILD plus the scripts below. |
| `locks/` | Byte-for-byte copies of upstream's three `Cargo.lock` files for the version we ship. Data only: they are the baseline for the release gate, and GitHub's Dependabot watches them for new advisories. |
| `tools/` | `update-litterbox`, `scan-release`, `publish-update`: the automation behind the update workflow. |
| `tests/` | Offline-friendly test suites. `sh tests/run.sh` runs everything. |
| `.github/workflows/upstream-litterbox.yml` | Daily check for new upstream releases. |

## The tools in `litterbox-sandbox-addons`

**`litterbox-addon`** (host) adds helper scripts, and the packages they need, to a Litterbox definition:

```
litterbox-addon list
litterbox-addon install dev      # writes one marked block into ~/Litterbox/definitions/dev.Dockerfile
litterbox build dev              # rebuild to apply
litterbox-addon remove dev       # takes the block out again, byte-for-byte
```

Arch/CachyOS definitions only. An addon is a directory under `/usr/share/litterbox-sandbox-addons/<addon>/`
with executables (baked into the image as `/usr/local/bin/<name>`) and an optional `packages.arch`.

**`boxed-run`** (inside the sandbox) runs a command under its own D-Bus session with an unlocked `gnome-keyring`, so IDEs such as
VSCodium have somewhere to store tokens. It re-executes itself under a pty when there is no terminal (Codium freezes
otherwise) and keeps Litterbox's `SSH_AUTH_SOCK`, so a keyring-provided ssh agent cannot shadow the confirm-before-sign agent.
The keyring is created with an empty password: anything inside the sandbox can read it.

**`litterbox-export`** (host) is the equivalent of `distrobox-export`. It runs on the host because the sandbox must not be able
to write launchers there. It reads `.desktop` files and icons out of the container with `podman cp` (nothing is executed in the
container), copies only a whitelist of keys, and writes launchers that start the program with `litterbox enter`:

```
litterbox-export dev --app codium --boxed                          # application menu entry
litterbox-export dev --app claude-desktop --boxed --url-handler    # claude:// links from the browser reach the sandbox
litterbox-export dev --bin codium --boxed                          # command in ~/.local/bin
litterbox-export dev --list
litterbox-export dev --app codium --delete                         # exact names only
```

`--url-handler` registers the launcher as the default handler for its `x-scheme-handler/*` types through `xdg-mime`, never for
`http`, `https`, `mailto`, `file` and similar. `--scheme NAME` adds a scheme for apps whose `.desktop` file does not declare one.
Files passed from the host cannot be opened inside the sandbox, which only sees its own home.

## How updates reach users

```
upstream Litterbox release
  -> upstream-litterbox.yml (daily, or run it by hand)
       verify  (read-only token, unprivileged user): release gate, tests, test build on Arch
       publish (write token, never runs upstream code): PR into this repo
         clean  -> merged automatically
         flagged -> left open, label needs-review
         failed  -> an issue, no PR
  -> bopp-os/pkgbuilds nightly job sees the new pkgver and opens a mirror PR   <- the human review point
  -> merging that PR builds and publishes the package
```

Run it by hand: `gh workflow run upstream-litterbox.yml` (add `-f version=0.6.5 -f dry_run=true` to scan and build the shipped
version without opening a PR).

### The release gate (`tools/scan-release`)

Compares the new release's three `Cargo.lock` files with `locks/` (what we ship) and holds the update for a human if:

1. a crate has the same name and version but a different checksum;
2. a crate comes from anything other than crates.io (git, alternate registry);
3. `osv-scanner` reports an advisory the shipped version did not have (advisories can be ignored in `.osv-scanner.toml`, each with a reason);
4. more than 30 crate names are new in one update (real releases 0.6.0 to 0.6.5 added between 0 and 7).

If the scan cannot run properly it fails closed: no merge. It does **not** read Litterbox's own source or find a backdoor that is
not in any advisory, so the mirror PR is a sanity check, not an audit. GitHub's Dependabot alerts (alerts only, no update PRs)
also watch `locks/` between releases.

## Rules for the pkgbuilds mirror

* A package folder here is copied wholesale into `pkgbuilds/packages/<name>/`: only the PKGBUILD and its source files belong in it.
* The mirror notices changes by comparing `pkgver`. **Any change to a script needs a `pkgver` bump** and updated `sha256sums`.
* `sh tests/run.sh` checks the checksums and the installed file list.

## Tests

```
sh tests/run.sh              # everything
sh tests/run.sh export scan  # chosen suites
```

Needs `sh`, `bash`, `tar`, `awk`, `sed`, `jq`, `curl` (network), `script` (util-linux); `shellcheck` is optional.

## Status

Tested with stub `podman`, `gnome-keyring`, `xdg-mime`, `osv-scanner` and `gh`, with a fake container filesystem, with upstream's real
CachyOS Dockerfile template, and against the real upstream lockfiles. **Not** tested against real Podman, a real keyring, a real desktop
session, or a real `makepkg` run. The first workflow run (`dry_run`) is the first real build of `litterbox-sandbox`.

Known unverified points:

* `--tty true --interactive true` (used for terminal apps and interactive `--bin` wrappers) is inferred from Litterbox's argument definitions, not run.
* `boxed-run` starts a new D-Bus session and keyring daemon on every launch, including for URL-handler launches that only forward a link to a running app.
* `osv-scanner`'s JSON shape and exit codes are taken from its documentation.

## License

GPL-3.0-or-later for everything in this repository. Litterbox itself is Apache-2.0 upstream and is not included.
