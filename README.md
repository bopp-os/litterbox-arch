# litterbox-arch

Packaging and helper tools for running [Litterbox](https://litterbox.work/) (a Podman-based development sandbox with a
confirm-before-sign SSH agent) on Arch, CachyOS and BoppOS.

[bopp-os/pkgbuilds](https://github.com/bopp-os/pkgbuilds) holds only links to this repo and builds the newest release tag of each package
(see "Releases and the pkgbuilds link"), so this repo is where the packages are written and kept up to date.

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

Launchers call `litterbox-export <name> --exec -- <command> [args]` instead of `litterbox enter` directly, and that matters:
Litterbox runs `$SHELL -l -c '<command> <args joined with single spaces>'` in the container **without quoting**, so the login shell
(bash, fish, ...) re-parses every argument. A browser URL like `claude://cb?code=1&state=2` would be cut at the `&`, and a
hostile link could run commands inside the sandbox. `--exec` single-quotes every argument. Arguments containing a backslash or a
newline are refused (bash and fish disagree about backslashes inside quotes). If you call `litterbox enter` yourself with
arguments from an untrusted source, quote them the same way.

**`litterbox-update`** (host) updates the packages inside a Litterbox and works out the package manager for you:

```
litterbox-update dev                 # detect, then update as root
litterbox-update --dry-run dev       # only show what it found and what it would run
litterbox-update dev work scratch    # several at once
litterbox-update --all               # every Litterbox with a definition in ~/Litterbox/definitions
```

It runs `litterbox enter <name> --root` twice: once to read the container's `os-release` and see which package managers exist,
once to run the update. The package manager comes from the distribution (Arch family `pacman -Syu --noconfirm`; Debian family
`apt-get update && apt-get -y upgrade`; Fedora family `dnf -y upgrade --refresh`, or `dnf5`; openSUSE Tumbleweed `zypper dup`,
Leap `zypper up`), falling back to whatever it finds for unknown distributions. What the container reports only *selects* one of
these fixed commands; it is sanitised and never pasted into a command. Updates are made inside the running container: they survive
restarts but are lost when the Litterbox is rebuilt or deleted, so anything permanent belongs in its Dockerfile. If pacman fails
with sandbox or Landlock errors inside the container, try `--no-sandbox` (pacman 7+).

**`litterbox-assemble`** (host) generates a Litterbox definition, `~/Litterbox/definitions/<name>.Dockerfile` and `<name>.ron`, from a template, a
package list, addons and settings, so a new sandbox with your usual tools is one command. It never builds anything unless you add `--build`.

```
litterbox-assemble web -p git -p neovim -a boxed-run -s expose_pipewire=true
litterbox build web                       # answer No when asked to change the settings
litterbox-assemble --dry-run web -p git   # show what would be written, write nothing
litterbox-assemble --file boxes.conf      # one or many boxes from a manifest; add names to pick some
litterbox-assemble --list-templates
```

Manifest format (`#` comments, CRLF fine; the whole file is validated and staged before anything is written, so one bad section writes nothing):

```
[web]
template = cachyos            # cachyos (default), fedora, tumbleweed, ubuntu-latest
packages = git neovim ripgrep
addons   = boxed-run          # Arch/CachyOS template only, because litterbox-addon is
set.expose_pipewire = true
set.network_mode    = Pasta
```

The Dockerfile is upstream Litterbox's own template for the installed version (the `litterbox-sandbox` package installs them under
`/usr/share/litterbox-sandbox/templates`) plus a marked block that installs your packages with the template's package manager, plus the
`litterbox-addon` block. Settings default to the most isolated values; the ones you widen are listed after generation, and any that need
something this host lacks (`/dev/kvm`, `/dev/kfd`, PipeWire) get a warning. `custom_podman_args` is deliberately not accepted, since it can
add arbitrary podman flags: edit the `.ron` yourself if you need it. An existing definition is refused unless you pass `--replace`.

**`litterbox-prune`** (host) removes the old images that `litterbox build` leaves behind (upstream's own TODO list asks for a prune command).
It lists by default and only removes with `--yes`; it never uses `--force`, never touches an image that still has a tag, and keeps any image a
container still uses. `litterbox-prune dev work` limits it to those Litterboxes.

**`litterbox-export <name> --shell`** adds a menu entry that opens a terminal inside a Litterbox (the `distrobox-generate-entry` equivalent).

**Completions** for bash, fish and zsh cover `litterbox` itself and all the tools above: subcommands, options, your Litterbox names (from
`~/Litterbox/definitions`), addon names and template names. One file per shell is installed; the other command names are symlinks to it.

## How updates reach users

```
upstream Litterbox release
  -> upstream-litterbox.yml (daily, or run it by hand)
       verify  (read-only token, unprivileged user): release gate, tests, test build on Arch
       publish (write token, never runs upstream code): PR into this repo
         clean  -> merged automatically, then released as a tag (litterbox-sandbox-<ver>-<rel>)
         flagged -> left open, label needs-review
         failed  -> an issue, no PR
  -> bopp-os/pkgbuilds nightly job sees the new tag and opens a PR bumping .upstream-ref   <- the human review point
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
not in any advisory, so the PR in pkgbuilds is a sanity check, not an audit. GitHub's Dependabot alerts (alerts only, no update PRs)
also watch `locks/` between releases.

## Releases and the pkgbuilds link

Two packages, two independent version streams:

| package | its version comes from | released by | tag |
|---|---|---|---|
| `litterbox-sandbox` | upstream Litterbox's release (`pkgver` is upstream's, `pkgrel` is our packaging revision) | the daily workflow, automatically, right after a clean update merges; by hand for a packaging-only fix (bump `pkgrel`) | `litterbox-sandbox-0.6.5-1` |
| `litterbox-sandbox-addons` | us: it is hosted here and changes whenever we decide, regardless of Litterbox | by hand | `litterbox-sandbox-addons-0.1.0-1` |

To declare a release: bump `pkgver` (or `pkgrel`) in the package's PKGBUILD, merge to `main`, then run `tools/release <package>`. It refuses unless that
version has no tag yet and the commit is on `origin/main`, runs the whole test suite on a clean export of the commit, and only then creates the tag
and GitHub release (`--dry-run` shows what it would do). `pkgver` changes only when you declare a release, not with every commit.

`bopp-os/pkgbuilds` holds **only links** to this repo: each of its `packages/<name>/` folders has `.upstream-url`, `.upstream-path` and `.upstream-ref`
(the pinned release tag). Its nightly job opens a PR bumping `.upstream-ref` when a newer tag exists, and its build fetches the package files at that
tag. So nothing here reaches the pacman repo until that PR in pkgbuilds is merged.

Package folders hold only the PKGBUILD and its source files; `sh tests/run.sh` checks the checksums and the installed file list.

## Patches to Litterbox (`litterbox-sandbox`)

`litterbox-sandbox` applies two patches to upstream's source in `prepare()`:

- `litterbox-stable-wayland-socket.patch`: the container's Wayland socket is mounted from a stable per-Litterbox link
  (`$XDG_RUNTIME_DIR/litterbox/<name>/wayland-0`) that is refreshed whenever the container starts, so a compositor that comes up as a
  different `wayland-N` no longer breaks it. Litterboxes built before the patch keep their old mount until `litterbox build <name>`.
  Starting a stopped container now needs `WAYLAND_DISPLAY` to be set and its socket to exist.
- `litterbox-cachyos-cpu-variants.patch`: `litterbox define` (and `litterbox-assemble --template`) also offer `cachyos-v4`
  (`docker.io/cachyos/cachyos-v4`) and `cachyos-znver4` (`ghcr.io/bopp-os/cachyos-docker/cachyos-znver4`, built from
  [bopp-os/cachyos-docker](https://github.com/bopp-os/cachyos-docker)). The existing `cachyos` template stays x86-64-v3.

A patch that stops applying to a new upstream release fails the build, so the update workflow files an Issue instead of a pull request.
`tests/pkgbuild.sh` checks that the patches apply to the pinned release and that the two new templates still equal upstream's
`cachyos.Dockerfile` below their `FROM` line. Fix the patch, then refresh its checksum in the PKGBUILD.

## Tests

```
sh tests/run.sh              # everything
sh tests/run.sh export scan  # chosen suites
```

Needs `sh`, `bash`, `tar`, `awk`, `sed`, `jq`, `curl` (network), `script` (util-linux); `shellcheck` is optional.

`.github/workflows/ci.yml` runs this on every push to `main` and every pull request, then does a real `makepkg` build of each package in an Arch
container and checks that exactly one package file comes out. Nothing is published from there. The `litterbox-sandbox` build compiles Litterbox
(about 15 minutes), so it runs only when `litterbox-sandbox/`, `locks/` or the workflow changed (always on a manual run). Pull requests opened by the
update workflow use `GITHUB_TOKEN` and do not trigger it, so it is not a required check.

## Status

Tested with stub `podman`, `gnome-keyring`, `xdg-mime`, `osv-scanner` and `gh`, with a fake container filesystem, with upstream's real
CachyOS Dockerfile template, and against the real upstream lockfiles. **Not** tested against real Podman, a real keyring, a real desktop
session, or a real `makepkg` run. The first workflow run (`dry_run`) is the first real build of `litterbox-sandbox`.

Known unverified points:

* `--tty true --interactive true` (used for terminal apps and interactive `--bin` wrappers) is inferred from Litterbox's argument definitions, not run.
* Litterbox's join-without-quoting behaviour is read from its source (`lbx-init`), and the tests emulate it with `sh` and with real fish
  (every default template makes fish the login shell). Nothing here has been run against the real Litterbox.
* `litterbox-update` has not run against a real container: whether pacman's download sandbox works as root inside rootless Podman is untested.
* The `.ron` that `litterbox-assemble` writes follows the structure of Litterbox's own settings code and is complete, but it has never been fed to a
  real `litterbox build`. Litterbox rewrites the file in its own format after loading it.
* The zsh completion file was written without a zsh to test with. bash and fish (real fish 4.9.3) are tested; the fish login-shell quoting
  checks run when a fish binary is available (`FISH=/path/to/fish sh tests/run.sh`; the update workflow installs fish so CI runs them).
* `boxed-run` starts a new D-Bus session and keyring daemon on every launch, including for URL-handler launches that only forward a link to a running app.
* `osv-scanner`'s JSON shape and exit codes are taken from its documentation.

## License

GPL-3.0-or-later for everything in this repository. Litterbox itself is Apache-2.0 upstream and is not included.
