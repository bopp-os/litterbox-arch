#!/bin/sh
# Offline tests for tools/update-litterbox: a fake upstream (file:// tarballs + a fake releases/latest JSON)
# and a throwaway git repo built from the real PKGBUILD and lockfiles.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TOOL="$ROOT/tools/update-litterbox"
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
FAILED=0
ok() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAILED=1; }

FX="$W/fx"; UP="$W/up"
mkdir -p "$FX/litterbox-sandbox" "$FX/locks" "$UP"
cp "$ROOT/litterbox-sandbox/PKGBUILD" "$FX/litterbox-sandbox/PKGBUILD"
# Pin the version the cases below are written against, so a real upstream bump does not break them.
sed -i 's/^pkgver=.*/pkgver=0.6.5/' "$FX/litterbox-sandbox/PKGBUILD"
cp -r "$ROOT/locks/." "$FX/locks/"
git -C "$FX" init -q -b main
git -C "$FX" -c user.name=t -c user.email=t@example.invalid add -A
git -C "$FX" -c user.name=t -c user.email=t@example.invalid commit -q -m base
export LBX_ROOT="$FX" LITTERBOX_TARBALL_URL_BASE="file://$UP" LITTERBOX_API_URL="file://$UP/latest.json"
unset GITHUB_TOKEN

reset_fx() { git -C "$FX" reset --hard -q; git -C "$FX" clean -fdq; }
latest_is() { printf '{\n  "url": "x",\n  "tag_name": "v%s",\n  "prerelease": false\n}\n' "$1" > "$UP/latest.json"; }

# mk_up VERSION [topdir] [skip_crate]: fake upstream tarball whose lockfiles differ from ours.
mk_up() {
  v=$1; top=${2:-Litterbox-$1}; skip=${3:-}
  s=$(mktemp -d "$W/stage.XXXXXX"); mkdir -p "$s/$top"
  for c in litterbox lbx-init shared; do
    [ "$c" = "$skip" ] && continue
    mkdir -p "$s/$top/$c"
    cp "$ROOT/locks/$c/Cargo.lock" "$s/$top/$c/Cargo.lock"
    printf '# fake upstream %s\n' "$v" >> "$s/$top/$c/Cargo.lock"
  done
  echo "fake readme" > "$s/$top/README.md"
  tar -czf "$UP/v$v.tar.gz" -C "$s" "$top"
  rm -rf "$s"
}

mk_up 0.7.0; mk_up 0.6.0; latest_is 0.7.0
P="$FX/litterbox-sandbox/PKGBUILD"

# --- read-only commands -------------------------------------------------------------------------
[ "$(sh "$TOOL" --current)" = "0.6.5" ] && ok "--current reads pkgver" || fail "--current"
[ "$(sh "$TOOL" --latest)" = "0.7.0" ] && ok "--latest reads the API tag (v prefix stripped)" || fail "--latest"
sh "$TOOL" --check >/dev/null; [ $? = 0 ] && ok "--check exits 0 when upstream is newer" || fail "--check newer"
printf '{"tag_name":"v0.8.0-rc1","prerelease":false}' > "$UP/latest.json"
sh "$TOOL" --latest >/dev/null 2>&1 && fail "pre-release style tag accepted" || ok "non x.y.z tag is rejected"
printf '{"id":1,"tag_name":"v0.7.0","assets":[{"tag_name":"v9.9.9"}]}' > "$UP/latest.json"
[ "$(sh "$TOOL" --latest)" = "0.7.0" ] && ok "minified JSON: first tag_name wins" || fail "minified json"
latest_is 0.7.0

# --- apply the update ------------------------------------------------------------------------------
cp "$P" "$W/PKGBUILD.orig"
sh "$TOOL" >/dev/null; rc=$?
[ "$rc" = 0 ] && ok "default run applies the newer release" || fail "apply rc=$rc"
sum=$(sha256sum "$UP/v0.7.0.tar.gz" | cut -d' ' -f1)
grep -qx 'pkgver=0.7.0' "$P" && grep -qx 'pkgrel=1' "$P" && grep -q "^sha256sums=('$sum'" "$P" && ok "pkgver, pkgrel and the tarball's sha256 rewritten (sha256 is of the real tarball)" || { grep -E '^(pkgver|pkgrel|sha256sums)=' "$P"; fail "rewrite"; }
bad=$(diff "$W/PKGBUILD.orig" "$P" | grep -E '^[<>]' | grep -vE '^[<>] (pkgver|pkgrel|sha256sums)=' || true)
[ -z "$bad" ] && ok "no PKGBUILD line other than pkgver/pkgrel/sha256sums changed" || { echo "$bad"; fail "extra PKGBUILD changes"; }
[ -n "$(grep -E "^ +'[0-9a-f]{64}'" "$W/PKGBUILD.orig")" ] && [ "$(grep -E "^ +'[0-9a-f]{64}'" "$W/PKGBUILD.orig")" = "$(grep -E "^ +'[0-9a-f]{64}'" "$P")" ] \
  && ok "the patch checksums after the tarball's are left alone" || fail "patch checksums touched"
okl=1
for c in litterbox lbx-init shared; do
  tar -xzOf "$UP/v0.7.0.tar.gz" "Litterbox-0.7.0/$c/Cargo.lock" | cmp -s - "$FX/locks/$c/Cargo.lock" || okl=0
done
[ "$okl" = 1 ] && ok "locks/ are byte-identical to the tarball's lockfiles" || fail "locks content"
changed=$(git -C "$FX" status --porcelain | sed 's/^...//' | sort | tr '\n' ' ')
[ "$changed" = "litterbox-sandbox/PKGBUILD locks/lbx-init/Cargo.lock locks/litterbox/Cargo.lock locks/shared/Cargo.lock " ] && ok "only PKGBUILD and locks/ changed in the working tree" || fail "changed files: $changed"

# --- after committing, we are up to date ---------------------------------------------------------------
git -C "$FX" -c user.name=t -c user.email=t@example.invalid commit -qam "update"
sh "$TOOL" --check >/dev/null; [ $? = 10 ] && ok "--check exits 10 when up to date" || fail "--check up to date"
sh "$TOOL" >/dev/null; [ $? = 10 ] && ok "default run exits 10 when up to date" || fail "default up to date"
[ -z "$(git -C "$FX" status --porcelain)" ] && ok "up-to-date run changes nothing" || fail "dirty after no-op"
sh "$TOOL" 0.7.0 | grep -q 'Already at 0.7.0' && ok "explicit same version is a no-op" || fail "explicit same"
latest_is 0.6.0
sh "$TOOL" >/dev/null; [ $? = 10 ] && ok "default run refuses to downgrade" || fail "silent downgrade"
sh "$TOOL" 0.6.0 >/dev/null 2>&1; [ -n "$(git -C "$FX" status --porcelain)" ] && grep -qx 'pkgver=0.6.0' "$P" && ok "explicit older version is allowed (human-initiated)" || fail "explicit downgrade"
reset_fx; latest_is 0.7.0

# --- argument validation ------------------------------------------------------------------------------------
cp "$P" "$W/before"
for bad in 0.7 v0.7.0 0.7.0-rc1 ../x '0.7.0;ls' 1.2.3.4; do
  sh "$TOOL" "$bad" >/dev/null 2>&1 && fail "accepted bad version '$bad'" || ok "rejected bad version '$bad'"
done
cmp -s "$P" "$W/before" && ok "rejected versions left the PKGBUILD untouched" || fail "PKGBUILD changed by rejected input"

# --- hostile / changed upstream layouts --------------------------------------------------------------------------
mk_up 0.9.0 litterbox-0.9.0
sh "$TOOL" 0.9.0 >/dev/null 2>&1 && fail "wrong top-level directory accepted" || ok "tarball with wrong top-level directory rejected"
mk_up 0.9.1 Litterbox-0.9.1 shared
sh "$TOOL" 0.9.1 2>&1 | grep -q 'no shared/Cargo.lock' && ok "tarball missing a lockfile rejected with a clear message" || fail "missing lockfile"
[ -z "$(git -C "$FX" status --porcelain)" ] && ok "rejected upgrades leave the tree clean" || { git -C "$FX" status --porcelain; fail "tree dirty after rejection"; }
sh "$TOOL" 0.9.9 >/dev/null 2>&1 && fail "download failure accepted" || ok "missing tarball (404) is an error"

# The tree is at 0.7.0 here, so target 0.6.0 (a tarball exists) to get past the "already at" shortcut.
printf "sha256sums=('x')\n" >> "$P"; git -C "$FX" -c user.name=t -c user.email=t@example.invalid commit -qam "layout change"
sh "$TOOL" 0.6.0 2>&1 | grep -q "exactly one 'sha256sums='" && ok "changed PKGBUILD layout is refused" || fail "layout guard"
[ -z "$(git -C "$FX" status --porcelain)" ] && ok "layout refusal left the tree clean" || fail "layout refusal dirtied tree"
git -C "$FX" reset --hard -q HEAD~1

echo stray > "$FX/stray.txt"
sh "$TOOL" 0.6.0 2>&1 | grep -q 'not clean' && ok "dirty working tree is refused" || fail "dirty guard"
reset_fx

[ "$FAILED" = 0 ] && echo "ALL PASSED" || { echo "SOME FAILED"; exit 1; }
