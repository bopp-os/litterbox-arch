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

for pkg in litterbox-sandbox litterbox-sandbox-addons; do
  bash -c 'source "$1/PKGBUILD"; for f in package; do declare -F $f >/dev/null || exit 1; done; [ -n "$pkgname" ] && [ -n "$pkgver" ]' _ "$ROOT/$pkg" \
    && ok "$pkg defines package(), pkgname and pkgver" || fail "$pkg missing package()/pkgname/pkgver"
done

# package() of the addons package (arch=any, nothing to build): run it as makepkg would.
PKGDIR=$(mktemp -d); trap 'rm -rf "$PKGDIR"' EXIT
bash -c 'set -eu; cd "$1"; source ./PKGBUILD; srcdir="$PWD" pkgdir="$2"; package' _ "$ROOT/litterbox-sandbox-addons" "$PKGDIR" \
  && ok "addons package() runs" || fail "addons package() failed"
got=$(cd "$PKGDIR" && find . -type f -printf '%m %P\n' | sort)
want=$(printf '%s\n' \
  '644 usr/share/litterbox-sandbox-addons/boxed-run/packages.arch' \
  '755 usr/bin/litterbox-addon' \
  '755 usr/bin/litterbox-export' \
  '755 usr/bin/litterbox-update' \
  '755 usr/share/litterbox-sandbox-addons/boxed-run/boxed-run' | sort)
[ "$got" = "$want" ] && ok "addons package() installs exactly the expected files and modes" || { echo "--- got"; echo "$got"; echo "--- want"; echo "$want"; fail "addons file list"; }

# File modes in the repo: scripts executable, PKGBUILDs and data files not (a blanket chmod +x once got this wrong).
badmode=''
for f in "$ROOT"/litterbox-sandbox/PKGBUILD "$ROOT"/litterbox-sandbox-addons/PKGBUILD "$ROOT"/litterbox-sandbox-addons/boxed-run.packages.arch; do
  if [ -x "$f" ]; then badmode="$badmode ${f#"$ROOT"/}"; fi
done
for f in boxed-run litterbox-addon litterbox-export litterbox-update; do
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

[ "$FAILED" = 0 ] && echo "ALL PASSED" || { echo "SOME FAILED"; exit 1; }
