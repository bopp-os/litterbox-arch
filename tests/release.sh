#!/bin/sh
# Tests for tools/release: a throwaway repo with a local bare "origin", a stub `gh` that records the call and
# makes the tag the way GitHub would, and a fake tests/run.sh whose exit status the test controls.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TOOL="$ROOT/tools/release"
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
FAILED=0
ok() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAILED=1; }

FX="$W/fx"; ORIGIN="$W/origin.git"; BIN="$W/bin"; mkdir -p "$BIN" "$FX/litterbox-sandbox" "$FX/litterbox-sandbox-addons" "$FX/tests"
cat > "$BIN/gh" <<'EOF'
#!/bin/sh
echo "gh $*" >> "$GH_LOG"
if [ "$1 $2" = "release create" ]; then
  # args: release create TAG --target SHA --title TAG --notes-file FILE
  cp "$9" "$STUB_DIR/last-notes.md" 2>/dev/null || cp "${10}" "$STUB_DIR/last-notes.md"
  git tag "$3" "$5" && git push -q origin "$3"
fi
EOF
chmod +x "$BIN/gh"
printf '#!/bin/sh\necho ran > "$RUN_MARK"\nexit "${RUN_RC:-0}"\n' > "$FX/tests/run.sh"
pkgbuild() { printf 'pkgname=%s\npkgver=%s\npkgrel=%s\n' "$1" "$2" "$3" > "$FX/$1/PKGBUILD"; }
pkgbuild litterbox-sandbox 0.6.5 1; pkgbuild litterbox-sandbox-addons 0.1.0 1
git init -q --bare -b main "$ORIGIN"
git -C "$FX" init -q -b main
g() { git -C "$FX" -c user.name=t -c user.email=t@example.invalid "$@"; }
g add -A; g commit -q -m "initial"
g remote add origin "$ORIGIN"; g push -q origin main

GH_LOG="$W/gh.log"; : > "$GH_LOG"
release() { # release ARGS... -> $out, $rc
  out=$(env LBX_ROOT="$FX" GH_LOG="$GH_LOG" STUB_DIR="$W" RUN_MARK="$W/ran" RUN_RC="${RUN_RC:-0}" PATH="$BIN:$PATH" sh "$TOOL" "$@" 2>&1); rc=$?
}
created() { grep -c '^gh release create ' "$GH_LOG"; }
sha_of() { git -C "$FX" rev-parse HEAD; }

# --- first release of each package ----------------------------------------------------------------------------------
rm -f "$W/ran"; release litterbox-sandbox-addons
sha=$(sha_of)
[ "$rc" = 0 ] && grep -q "^gh release create litterbox-sandbox-addons-0.1.0-1 --target $sha --title litterbox-sandbox-addons-0.1.0-1 --notes-file " "$GH_LOG" \
  && ok "tag is <package>-<pkgver>-<pkgrel>, created at the commit" || { echo "$out"; cat "$GH_LOG"; fail "first release"; }
[ -f "$W/ran" ] && ok "the test suite ran before the release" || fail "tests did not run"
grep -q '^First release of litterbox-sandbox-addons\.$' "$W/last-notes.md" && ok "notes: first release" || fail "first notes"
release litterbox-sandbox
grep -q 'releases/tag/v0.6.5' "$W/last-notes.md" && grep -q 'packaging revision 1' "$W/last-notes.md" && ok "litterbox-sandbox notes link the upstream release" || fail "sandbox notes"

# --- refusals -------------------------------------------------------------------------------------------------------------
n=$(created); release litterbox-sandbox-addons
[ "$rc" != 0 ] && echo "$out" | grep -q 'already exists' && [ "$(created)" = "$n" ] && ok "an existing tag is refused" || { echo "$out"; fail "existing tag"; }

pkgbuild litterbox-sandbox-addons 0.2.0 1; echo more > "$FX/litterbox-sandbox-addons/x"; g add -A; g commit -q -m "addons: feat X"
release litterbox-sandbox-addons
[ "$rc" != 0 ] && echo "$out" | grep -q 'not on origin/main' && ok "a commit that is not pushed to origin/main is refused" || { echo "$out"; fail "unpushed"; }
g push -q origin main

echo scribble > "$FX/litterbox-sandbox-addons/uncommitted"; printf 'pkgname=x\npkgver=9.9.9\npkgrel=7\n' > "$FX/litterbox-sandbox-addons/PKGBUILD"
n=$(created); release litterbox-sandbox-addons --sha "$(sha_of)"
grep -q 'release create litterbox-sandbox-addons-0.2.0-1 ' "$GH_LOG" && ok "the version comes from the PKGBUILD at the commit, not the working tree" || { echo "$out"; fail "version from sha"; }
git -C "$FX" checkout -q -- litterbox-sandbox-addons/PKGBUILD; rm -f "$FX/litterbox-sandbox-addons/uncommitted"
grep -q '^- addons: feat X$' "$W/last-notes.md" && grep -q 'since litterbox-sandbox-addons-0.1.0-1' "$W/last-notes.md" && ok "notes list this package's commits since its previous tag" || { cat "$W/last-notes.md"; fail "notes since"; }

# the sandbox tag stream must not see the addons tags (prefix collision) and vice versa
echo y > "$FX/litterbox-sandbox/y"; g add -A; g commit -q -m "sandbox: packaging fix"; pkgbuild litterbox-sandbox 0.6.5 2; g add -A; g commit -q -m "sandbox: bump pkgrel"; g push -q origin main
release litterbox-sandbox
grep -q 'since litterbox-sandbox-0.6.5-1' "$W/last-notes.md" && ! grep -q 'addons' "$W/last-notes.md" && ok "a pkgrel bump is a new release; the addons tags are not mistaken for sandbox tags" || { cat "$W/last-notes.md"; fail "prefix collision"; }

# --- bad input ----------------------------------------------------------------------------------------------------------------
printf 'pkgname=x\npkgver=1.2;touch PWN\npkgrel=1\n' > "$FX/litterbox-sandbox-addons/PKGBUILD"; g add -A; g commit -q -m "bad pkgver"; g push -q origin main
n=$(created); release litterbox-sandbox-addons
[ "$rc" != 0 ] && echo "$out" | grep -q "bad pkgver" && [ "$(created)" = "$n" ] && [ ! -e "$FX/PWN" ] && ok "a malformed pkgver is refused, not executed" || { echo "$out"; fail "bad pkgver"; }
g revert -q --no-edit HEAD; g push -q origin main
release ../x; [ "$rc" != 0 ] && echo "$out" | grep -q 'unknown package' && ok "an unknown package (path tricks included) is refused" || fail "unknown package"
release; [ "$rc" != 0 ] && echo "$out" | grep -q 'packages:' && ok "no package prints usage" || fail "usage"

# --- tests gate the release ------------------------------------------------------------------------------------------------------
pkgbuild litterbox-sandbox-addons 0.3.0 1; g add -A; g commit -q -m "addons 0.3.0"; g push -q origin main
n=$(created); RUN_RC=1 release litterbox-sandbox-addons
[ "$rc" != 0 ] && echo "$out" | grep -q 'tests failed' && [ "$(created)" = "$n" ] && ok "failing tests block the release" || { echo "$out"; fail "tests gate"; }
RUN_RC=1 release --skip-tests litterbox-sandbox-addons
[ "$rc" = 0 ] && [ "$(created)" = "$((n + 1))" ] && ok "--skip-tests releases without running them" || { echo "$out"; fail "skip tests"; }
pkgbuild litterbox-sandbox-addons 0.4.0 1; g add -A; g commit -q -m "addons 0.4.0"; g push -q origin main
printf '#!/bin/sh\nexit 1\n' > "$FX/tests/run.sh"      # broken in the working tree only, uncommitted
n=$(created); release litterbox-sandbox-addons
[ "$rc" = 0 ] && ok "tests run on a clean export of the commit, not on the working tree" || { echo "$out"; fail "export tree"; }
printf '#!/bin/sh\necho ran > "$RUN_MARK"\nexit "${RUN_RC:-0}"\n' > "$FX/tests/run.sh"

# --- dry run -----------------------------------------------------------------------------------------------------------------------
pkgbuild litterbox-sandbox-addons 0.5.0 1; g add -A; g commit -q -m "addons 0.5.0"; g push -q origin main
rm -f "$W/ran"; n=$(created); release --dry-run litterbox-sandbox-addons
[ "$rc" = 0 ] && [ "$(created)" = "$n" ] && [ ! -e "$W/ran" ] && echo "$out" | grep -q 'Release litterbox-sandbox-addons-0.5.0-1' && ok "--dry-run shows the tag and notes and does nothing" || { echo "$out"; fail "dry run"; }

[ "$FAILED" = 0 ] && echo "ALL PASSED" || { echo "SOME FAILED"; exit 1; }
