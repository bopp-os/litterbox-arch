#!/bin/sh
# PKGBUILD consistency checks (no makepkg needed):
#   - both PKGBUILDs parse, define the expected functions, and have one checksum per source
#   - local source files match their sha256sums
#   - the upstream Litterbox tarball in litterbox-sandbox/PKGBUILD matches its sha256 (needs network)
#   - litterbox-sandbox-addons package() installs exactly the expected files with the expected modes
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
FAILED=0
ok() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAILED=1; }

for pkg in litterbox-sandbox litterbox-sandbox-addons; do
  bash -n "$ROOT/$pkg/PKGBUILD" && ok "$pkg/PKGBUILD parses" || fail "$pkg/PKGBUILD syntax"
done

# Run in a subshell per package so one PKGBUILD's variables never leak into the next.
check_sources() {
  bash -c '
    set -eu
    cd "$1"; source ./PKGBUILD
    [ "${#source[@]}" = "${#sha256sums[@]}" ] || { echo "source/sha256sums count differs"; exit 1; }
    i=0
    for s in "${source[@]}"; do
      want=${sha256sums[$i]}; i=$((i + 1))
      case $s in
        *://*)
          url=${s#*::}
          got=$(curl -fsSL "$url" | sha256sum | cut -d" " -f1) ;;
        *)
          got=$(sha256sum "$s" | cut -d" " -f1) ;;
      esac
      [ "$got" = "$want" ] || { echo "checksum mismatch for $s: PKGBUILD has $want, actual $got"; exit 1; }
      echo "checksum ok: $s"
    done
  ' _ "$ROOT/$1"
}
check_sources litterbox-sandbox && ok "litterbox-sandbox: upstream tarball sha256 matches" || fail "litterbox-sandbox sources"
check_sources litterbox-sandbox-addons && ok "litterbox-sandbox-addons: local sources match sha256sums" || fail "litterbox-sandbox-addons sources"

# litterbox-sandbox installs upstream's Dockerfile templates (litterbox-assemble starts from them): they must exist in the pinned tarball.
n=$(bash -c 'source "$1/litterbox-sandbox/PKGBUILD"; curl -fsSL "${source[0]#*::}"' _ "$ROOT" | tar -tz 2>/dev/null | grep -Ec '^Litterbox-[0-9.]+/litterbox/templates/[^/]+\.Dockerfile$')
[ "$n" -ge 1 ] && grep -q 'litterbox/templates/\*.Dockerfile' "$ROOT/litterbox-sandbox/PKGBUILD" && ok "the pinned upstream tarball ships $n Dockerfile templates and the PKGBUILD installs them" || fail "templates: tarball has $n, PKGBUILD installs them: $(grep -c 'templates/' "$ROOT/litterbox-sandbox/PKGBUILD")"

for pkg in litterbox-sandbox litterbox-sandbox-addons; do
  bash -c 'source "$1/PKGBUILD"; for f in package; do declare -F $f >/dev/null || exit 1; done; [ -n "$pkgname" ] && [ -n "$pkgver" ]' _ "$ROOT/$pkg" \
    && ok "$pkg defines package(), pkgname and pkgver" || fail "$pkg missing package()/pkgname/pkgver"
done

# package() of the addons package (arch=any, nothing to build): run it as makepkg would.
PKGDIR=$(mktemp -d); trap 'rm -rf "$PKGDIR"' EXIT
bash -c 'set -eu; cd "$1"; source ./PKGBUILD; srcdir="$PWD" pkgdir="$2"; package' _ "$ROOT/litterbox-sandbox-addons" "$PKGDIR" \
  && ok "addons package() runs" || fail "addons package() failed"
got=$(cd "$PKGDIR" && { find . -type f -printf '%m %P\n'; find . -type l -printf 'L %P -> %l\n'; } | sort)
want=$(printf '%s\n' \
  '644 usr/share/litterbox-sandbox-addons/boxed-run/packages.arch' \
  '644 usr/share/bash-completion/completions/litterbox-addon' \
  '644 usr/share/fish/vendor_completions.d/litterbox-addon.fish' \
  '644 usr/share/zsh/site-functions/_litterbox-tools' \
  '755 usr/bin/litterbox-addon' \
  '755 usr/bin/litterbox-export' \
  '755 usr/bin/litterbox-update' \
  '755 usr/bin/litterbox-prune' \
  '755 usr/bin/litterbox-assemble' \
  '755 usr/share/litterbox-sandbox-addons/boxed-run/boxed-run' \
  'L usr/share/bash-completion/completions/litterbox -> litterbox-addon' \
  'L usr/share/bash-completion/completions/litterbox-export -> litterbox-addon' \
  'L usr/share/bash-completion/completions/litterbox-update -> litterbox-addon' \
  'L usr/share/bash-completion/completions/litterbox-prune -> litterbox-addon' \
  'L usr/share/bash-completion/completions/litterbox-assemble -> litterbox-addon' \
  'L usr/share/fish/vendor_completions.d/litterbox.fish -> litterbox-addon.fish' \
  'L usr/share/fish/vendor_completions.d/litterbox-export.fish -> litterbox-addon.fish' \
  'L usr/share/fish/vendor_completions.d/litterbox-update.fish -> litterbox-addon.fish' \
  'L usr/share/fish/vendor_completions.d/litterbox-prune.fish -> litterbox-addon.fish' \
  'L usr/share/fish/vendor_completions.d/litterbox-assemble.fish -> litterbox-addon.fish' | sort)
[ "$got" = "$want" ] && ok "addons package() installs exactly the expected files and modes" || { echo "--- got"; echo "$got"; echo "--- want"; echo "$want"; fail "addons file list"; }

# File modes in the repo: scripts executable, PKGBUILDs and data files not (a blanket chmod +x once got this wrong).
badmode=''
for f in "$ROOT"/litterbox-sandbox/PKGBUILD "$ROOT"/litterbox-sandbox-addons/PKGBUILD "$ROOT"/litterbox-sandbox-addons/boxed-run.packages.arch \
         "$ROOT"/litterbox-sandbox-addons/litterbox-tools.bash "$ROOT"/litterbox-sandbox-addons/litterbox-tools.fish "$ROOT"/litterbox-sandbox-addons/_litterbox-tools; do
  if [ -x "$f" ]; then badmode="$badmode ${f#"$ROOT"/}"; fi
done
for f in boxed-run litterbox-addon litterbox-export litterbox-update litterbox-prune litterbox-assemble; do
  if [ ! -x "$ROOT/litterbox-sandbox-addons/$f" ]; then badmode="$badmode litterbox-sandbox-addons/$f(not executable)"; fi
done
[ -z "$badmode" ] && ok "scripts are executable; PKGBUILDs and data files are not" || fail "wrong file modes:$badmode"

# The mirror in bopp-os/pkgbuilds copies a package folder wholesale: nothing but PKGBUILD + its sources may live there.
for pkg in litterbox-sandbox litterbox-sandbox-addons; do
  expected=$(cd "$ROOT/$pkg" && bash -c 'source ./PKGBUILD; for f in PKGBUILD "${source[@]}"; do case $f in *://*) ;; *) echo "$f" ;; esac; done' | sort)
  actual=$(cd "$ROOT/$pkg" && ls -A | sort)
  [ "$expected" = "$actual" ] && ok "$pkg/ contains only PKGBUILD and its local sources (safe to mirror)" \
    || { echo "--- expected"; echo "$expected"; echo "--- actual"; echo "$actual"; fail "$pkg/ has files outside PKGBUILD + sources"; }
done

# No -debug split package: makepkg would produce a second package file and the release would carry it.
# (The addons package is arch=any and has no binaries, so it never gets one.)
bash -c 'source "$1/litterbox-sandbox/PKGBUILD"; case " ${options[*]-} " in *" !debug "*) exit 0 ;; *) exit 1 ;; esac' _ "$ROOT" \
  && ok "litterbox-sandbox sets options=('!debug')" || fail "litterbox-sandbox/PKGBUILD does not set options=('!debug')"

# Patches that prepare() applies to upstream's source (needs network for the pinned tarball): every patch in source=() must
# be applied by prepare(), apply cleanly in that order to the pinned release, and the CachyOS variant templates they add
# must stay upstream's cachyos.Dockerfile except for the comment and FROM lines, so they cannot silently drift.
SRC="$PKGDIR/upstream"; mkdir -p "$SRC"
patches=$(bash -c 'source "$1/litterbox-sandbox/PKGBUILD"; for s in "${source[@]}"; do case $s in *.patch) echo "$s" ;; esac; done' _ "$ROOT")
prep=$(bash -c 'source "$1/litterbox-sandbox/PKGBUILD"; declare -f prepare' _ "$ROOT")
unused=''; for p in $patches; do printf '%s\n' "$prep" | grep -q "${p%.patch}" || unused="$unused $p"; done
[ -n "$patches" ] && [ -z "$unused" ] && ok "prepare() applies every patch listed in source ($(echo $patches | wc -w))" || fail "patches not applied by prepare():${unused:- none listed}"
bash -c 'source "$1/litterbox-sandbox/PKGBUILD"; curl -fsSL "${source[0]#*::}"' _ "$ROOT" | tar -xz -C "$SRC" --strip-components=1
bad=''; for p in $patches; do
  (cd "$SRC" && patch -Np1 -s -i "$ROOT/litterbox-sandbox/$p") || bad="$bad $p"
done
[ -z "$bad" ] && ok "the patches apply, in source() order, to the pinned upstream release" || fail "patch does not apply to the pinned release:$bad"
T="$SRC/litterbox/templates"; drift=''
[ "$(sed -n 3p "$T/cachyos.Dockerfile")" = "FROM docker.io/cachyos/cachyos-v3:latest" ] || drift="$drift cachyos.Dockerfile(not v3: relabel it)"
for v in cachyos-v4:docker.io/cachyos/cachyos-v4:latest cachyos-znver4:ghcr.io/bopp-os/cachyos-docker/cachyos-znver4:latest; do
  f=${v%%:*}; img=${v#*:}
  [ -f "$T/$f.Dockerfile" ] || { drift="$drift $f(missing)"; continue; }
  [ "$(sed -n 1p "$T/$f.Dockerfile")" = "$(sed -n 1p "$T/cachyos.Dockerfile")" ] || drift="$drift $f(line 1)"
  [ "$(sed -n 3p "$T/$f.Dockerfile")" = "FROM $img" ] || drift="$drift $f(FROM)"
  [ "$(tail -n +4 "$T/$f.Dockerfile")" = "$(tail -n +4 "$T/cachyos.Dockerfile")" ] || drift="$drift $f(body differs from upstream's cachyos.Dockerfile)"
  grep -q "templates/$f.Dockerfile" "$SRC/litterbox/src/template.rs" || drift="$drift $f(not in template.rs)"
done
[ -z "$drift" ] && ok "the cachyos-v4 and cachyos-znver4 templates match upstream's cachyos.Dockerfile below their FROM line" \
  || fail "CachyOS variant templates:$drift (regenerate them from upstream's cachyos.Dockerfile lines 1 and 4+ and refresh the patch + checksum)"

# litterbox-sandbox package() finds the binaries in each crate's own target/ directory, or in CARGO_TARGET_DIR when the pkgbuilds CI sets it
# (that is how it keeps a build cache between runs). Fake build output stands in for cargo.
for mode in own shared; do
  out="$PKGDIR/sandbox-$mode"; mkdir -p "$out"
  if bash -c 'set -eu; cd "$1"; source ./PKGBUILD; srcdir="$2/src" pkgdir="$2/pkg"; d="$srcdir/Litterbox-$pkgver"; mkdir -p "$srcdir" "$pkgdir"
      if [ "$3" = shared ]; then export CARGO_TARGET_DIR="$2/target"; m="$CARGO_TARGET_DIR"; i="$CARGO_TARGET_DIR"; else unset CARGO_TARGET_DIR; m="$d/litterbox/target"; i="$d/lbx-init/target"; fi
      mkdir -p "$m/release" "$i/$_musl/release" "$d/litterbox/templates"
      echo lbx > "$m/release/litterbox"; echo init > "$i/$_musl/release/lbx-init"; echo L > "$d/LICENSE"; echo F > "$d/litterbox/templates/t.Dockerfile"
      cd "$srcdir"; package' _ "$ROOT/litterbox-sandbox" "$out" "$mode" >/dev/null 2>&1 \
     && [ "$(cat "$out/pkg/usr/bin/litterbox")" = lbx ] && [ "$(cat "$out/pkg/usr/bin/lbx-init")" = init ]; then
    ok "litterbox-sandbox package() installs both binaries ($mode target directory)"
  else
    fail "litterbox-sandbox package() with the $mode target directory"
  fi
done
grep -q CARGO_TARGET_DIR "$ROOT/litterbox-sandbox/PKGBUILD" && ok "litterbox-sandbox/PKGBUILD mentions CARGO_TARGET_DIR (the pkgbuilds cache step keys on it)" || fail "CARGO_TARGET_DIR missing from litterbox-sandbox/PKGBUILD"

[ "$FAILED" = 0 ] && echo "ALL PASSED" || { echo "SOME FAILED"; exit 1; }
