#!/bin/sh
# Offline tests for tools/publish-update: `gh` is a stub that logs every call, git talks to a real local
# bare repository standing in for GitHub, upstream is a set of file:// tarballs, osv-scanner is a stub.
# This is the code that can merge on its own, so it gets the hostile cases too.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required for this suite"; exit 1; }
FAILED=0
ok() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAILED=1; }

FX="$W/fx"; ORIGIN="$W/origin.git"; UP="$W/up"; BIN="$W/bin"; LOG="$W/gh.log"
BRANCH=upstream-update/litterbox-sandbox
mkdir -p "$FX/litterbox-sandbox" "$UP" "$BIN"

# --- stubs ---------------------------------------------------------------------------------------------
cat > "$BIN/osv-stub" <<'EOF'
#!/bin/sh
[ -n "${STUB_RC:-}" ] && { echo "stub failure" >&2; exit "$STUB_RC"; }
f=$5
v=$(grep '^# vuln: ' "$f" | sed 's/^# vuln: //')
if [ -z "$v" ]; then echo '{"results":[]}'; exit 0; fi
printf '%s\n' "$v" | jq -R -n '[inputs | split(" ") | {ids: (.[0]|split(",")), name: .[1], version: .[2]}]
  | {results: [{source: {path: "x", type: "lockfile"},
                packages: map({package: {name: .name, version: .version, ecosystem: "crates.io"},
                               vulnerabilities: [{id: .ids[0], aliases: .ids[1:]}]})}]}'
exit 1
EOF
cat > "$BIN/gh" <<'EOF'
#!/bin/sh
echo "gh $*" >> "$GH_LOG"
prev=''
for a in "$@"; do
  if [ "$prev" = "--body-file" ]; then
    case "$1" in issue) cp "$a" "$STUB_DIR/last-issue.md" ;; *) cp "$a" "$STUB_DIR/last-pr.md" ;; esac
  fi
  prev=$a
done
case "$*" in
  "api repos/Gerharddc/litterbox/releases/tags/"*) cat "${NOTES_FILE:-/dev/null}" ;;
  "pr list "*) if [ -n "${EXISTING_PR:-}" ]; then echo "$EXISTING_PR"; elif [ -f "$STUB_DIR/pr_created" ]; then echo 7; fi ;;
  "pr create "*) touch "$STUB_DIR/pr_created"; echo "https://github.com/bopp-os/litterbox-arch/pull/7" ;;
  "pr merge "*) [ -z "${STUB_MERGE_FAIL:-}" ] || exit 1 ;;
  "pr view "*) [ -n "${STUB_NO_MERGE_COMMIT:-}" ] || echo cafe0123456789cafe0123456789cafe01234567 ;;
  "issue list "*) [ -z "${EXISTING_ISSUE:-}" ] || echo "$EXISTING_ISSUE" ;;
esac
exit 0
EOF
cat > "$BIN/release-stub" <<'EOF'
#!/bin/sh
echo "release $*" >> "$RELEASE_LOG"
exit "${RELEASE_RC:-0}"
EOF
chmod +x "$BIN/osv-stub" "$BIN/gh" "$BIN/release-stub"

# --- fixture repo + fake GitHub ----------------------------------------------------------------------------
cp "$ROOT/litterbox-sandbox/PKGBUILD" "$FX/litterbox-sandbox/PKGBUILD"
cp -r "$ROOT/locks" "$FX/locks"
cp -r "$ROOT/tools" "$FX/tools"
git init -q --bare -b main "$ORIGIN"
git -C "$FX" init -q -b main
git -C "$FX" -c user.name=t -c user.email=t@example.invalid add -A
git -C "$FX" -c user.name=t -c user.email=t@example.invalid commit -q -m base
git -C "$FX" remote add origin "$ORIGIN"
git -C "$FX" push -q origin main

# mk_up VERSION [extra comment line for the litterbox lockfile]
mk_up() {
  s=$(mktemp -d "$W/stage.XXXXXX"); d="$s/Litterbox-$1"
  for c in litterbox lbx-init shared; do
    mkdir -p "$d/$c"; cp "$ROOT/locks/$c/Cargo.lock" "$d/$c/Cargo.lock"; printf '# fake upstream %s\n' "$1" >> "$d/$c/Cargo.lock"
  done
  [ -z "${2:-}" ] || printf '%s\n' "$2" >> "$d/litterbox/Cargo.lock"
  tar -czf "$UP/v$1.tar.gz" -C "$s" "Litterbox-$1"; rm -rf "$s"
}
mk_up 0.6.6; mk_up 0.7.0; mk_up 0.8.0 '# vuln: RUSTSEC-2099-9999 serde 1.0.0'
printf 'Fixes the thing.\n\nSee https://example.invalid for details.\n' > "$W/notes.txt"

reset_all() {
  git -C "$FX" checkout -q main; git -C "$FX" reset -q --hard; git -C "$FX" clean -fdq
  git -C "$FX" branch -D "$BRANCH" >/dev/null 2>&1 || true
  git --git-dir="$ORIGIN" branch -D "$BRANCH" >/dev/null 2>&1 || true
  : > "$LOG"; : > "$W/release.log"; rm -f "$W/pr_created" "$W/last-pr.md" "$W/last-issue.md"; mkdir -p "$W/reports"
}
branch_exists() { git --git-dir="$ORIGIN" rev-parse --verify -q "$BRANCH" >/dev/null; }
logged() { grep -q -- "$1" "$LOG"; }

# publish [VAR=val ...]: run tools/publish-update with the happy-path environment plus overrides
publish() {
  out=$(env LBX_ROOT="$FX" GH_LOG="$LOG" STUB_DIR="$W" PATH="$BIN:$PATH" \
        LITTERBOX_TARBALL_URL_BASE="file://$UP" OSV_SCANNER="$BIN/osv-stub" LBX_RELEASE_TOOL="$BIN/release-stub" RELEASE_LOG="$W/release.log" NOTES_FILE="$W/notes.txt" \
        CURRENT=0.6.5 TARGET=0.7.0 V_SCAN=0 V_TESTS=success V_BUILD=success \
        RUN_URL=https://github.com/bopp-os/litterbox-arch/actions/runs/1 REPORT_DIR="$W/reports" \
        "$@" sh "$ROOT/tools/publish-update" 2>&1); rc=$?
}

# --- 1. clean update: branch, PR, squash-merge --------------------------------------------------------------
reset_all; publish
[ "$rc" = 0 ] && ok "clean update exits 0" || { echo "$out"; fail "clean rc=$rc"; }
branch_exists && ok "update branch was pushed" || fail "no branch"
changed=$(git --git-dir="$ORIGIN" diff --name-only "main...$BRANCH" | sort | tr '\n' ' ')
[ "$changed" = "litterbox-sandbox/PKGBUILD locks/lbx-init/Cargo.lock locks/litterbox/Cargo.lock locks/shared/Cargo.lock " ] && ok "the commit touches only PKGBUILD and locks/" || fail "changed files: $changed"
[ "$(git --git-dir="$ORIGIN" log -1 --format=%s "$BRANCH")" = "upstream(litterbox-sandbox): update to 0.7.0" ] && ok "commit subject follows the repo convention" || fail "commit subject"
git --git-dir="$ORIGIN" show "$BRANCH:litterbox-sandbox/PKGBUILD" | grep -qx 'pkgver=0.7.0' && ok "pushed PKGBUILD has the new pkgver" || fail "pushed pkgver"
logged 'pr create --base main --head upstream-update/litterbox-sandbox --title upstream(litterbox-sandbox): update to 0.7.0' && logged -- '--label upstream-update' && ok "PR opened with the upstream-update label" || { cat "$LOG"; fail "pr create"; }
logged 'pr merge 7 --squash --delete-branch' && ok "clean update is squash-merged and the branch deleted" || fail "no merge"
! logged 'add-label needs-review' && ok "clean update is not labelled needs-review" || fail "needs-review on clean"
grep -q 'Result: \*\*clean\*\*' "$W/last-pr.md" && grep -q '^    Fixes the thing\.' "$W/last-pr.md" && ok "PR body has the gate report and the release notes (indented)" || fail "PR body"
[ "$(git -C "$FX" rev-parse main)" = "$(git --git-dir="$ORIGIN" rev-parse main)" ] && ok "the base branch itself is never pushed to" || fail "main was touched"

grep -qx 'release --skip-tests --sha cafe0123456789cafe0123456789cafe01234567 litterbox-sandbox' "$W/release.log" && ok "after a clean merge the litterbox-sandbox release is declared at the merge commit (tests already ran)" || { cat "$W/release.log"; fail "release not declared"; }

# --- 2. held by the gate: left open --------------------------------------------------------------------------------
reset_all; publish TARGET=0.8.0
[ "$rc" = 0 ] && ok "held update exits 0" || { echo "$out"; fail "hold rc=$rc"; }
! logged 'pr merge' && logged 'pr edit 7 --add-label needs-review' && ok "advisory in the new version: PR labelled needs-review, not merged" || { cat "$LOG"; fail "hold handling"; }
grep -q 'HOLD' "$W/last-pr.md" && grep -q 'RUSTSEC-2099-9999' "$W/last-pr.md" && ok "the PR body says why it was held" || fail "hold body"

[ ! -s "$W/release.log" ] && ok "a held update is not released" || fail "held update released"

# --- 3. existing PR is updated, not duplicated -------------------------------------------------------------------------
reset_all; publish EXISTING_PR=5
logged 'pr edit 5 --title' && ! logged 'pr create' && logged 'pr merge 5 --squash' && ok "an open PR for the branch is updated and merged, no duplicate" || { cat "$LOG"; fail "existing PR"; }

# --- 4. breaking per upstream (middle number) ---------------------------------------------------------------------------
reset_all; publish
logged 'pr edit 7 --add-label breaking-per-upstream' && grep -q 'Breaking per upstream' "$W/last-pr.md" && logged 'pr merge 7' && ok "0.6.x -> 0.7.0 is flagged as breaking but still merges when clean" || fail "breaking flag"
reset_all; publish TARGET=0.6.6
! logged 'add-label breaking-per-upstream' && ! grep -q 'Breaking per upstream' "$W/last-pr.md" && logged 'pr merge' && ok "a patch bump is not flagged" || fail "patch flagged"

# --- 5. failed checks: an Issue, never a PR ----------------------------------------------------------------------------------
reset_all; publish V_BUILD=failure
! branch_exists && ! logged 'pr create' && ! logged 'pr merge' && logged 'issue create' && ok "failed build: no branch, no PR, an issue instead" || { cat "$LOG"; fail "build failure"; }
grep -q 'failed the update checks' "$LOG" && grep -q '| Test build on Arch | failure |' "$W/last-issue.md" && ok "the issue records which check failed" || fail "issue body"
reset_all; publish V_TESTS=failure EXISTING_ISSUE=9
logged 'issue comment 9' && ! logged 'issue create' && ! logged 'pr create' && ok "failed tests: an existing issue gets a comment, no duplicate" || fail "issue dedupe"

# --- 6. scan errors fail closed ------------------------------------------------------------------------------------------------
reset_all; publish V_SCAN=1
! branch_exists && ! logged 'pr merge' && logged 'issue create' && ok "scan error in the verify job: no merge" || fail "verify scan error"
reset_all; publish STUB_RC=127
! branch_exists && ! logged 'pr merge' && logged 'issue create' && ok "scanner failing in the publish job: no merge (fail closed)" || fail "publish scan error"
reset_all; publish V_SCAN=banana
! logged 'pr merge' && ok "an unknown verify status is treated as an error" || fail "unknown status"

# --- 7. hostile release notes ---------------------------------------------------------------------------------------------------------
cat > "$W/notes.txt" <<EOF
\$(touch $W/pwned) and \`touch $W/pwned2\`
ping @octocat @bopp-os/everyone
\`\`\`
</details><img src=x onerror=alert(1)>
[click](javascript:alert(1))
EOF
reset_all; publish
[ ! -e "$W/pwned" ] && [ ! -e "$W/pwned2" ] && ok "command substitution in release notes is never evaluated" || fail "release notes were executed"
bad=$(grep -E '@octocat|<img|javascript:' "$W/last-pr.md" | grep -v '^    ' || true)
[ -z "$bad" ] && ok "every hostile line is inside the indented code block (no pings, no markup)" || { echo "$bad"; fail "unindented hostile content"; }
printf 'Fixes the thing.\n\nSee https://example.invalid for details.\n' > "$W/notes.txt"

# --- 8. merge refused: PR stays open ---------------------------------------------------------------------------------------------------
reset_all; publish STUB_MERGE_FAIL=1
[ "$rc" = 0 ] && logged 'pr edit 7 --add-label needs-review' && echo "$out" | grep -q 'left open' && ok "a refused merge leaves the PR open and labelled" || { echo "$out"; fail "merge refusal"; }

[ ! -s "$W/release.log" ] && ok "a refused merge is not released" || fail "refused merge released"
reset_all; publish RELEASE_RC=1
[ "$rc" != 0 ] && echo "$out" | grep -q 'declaring the release failed' && ok "a failing release makes the run fail loudly (the merge already happened)" || { echo "$out"; fail "release failure"; }
reset_all; publish STUB_NO_MERGE_COMMIT=1
[ "$rc" != 0 ] && echo "$out" | grep -q 'could not find its merge commit' && ok "no merge commit found: fails loudly with the manual command" || { echo "$out"; fail "no merge commit"; }
reset_all; publish V_BUILD=failure
[ ! -s "$W/release.log" ] && ok "a failed check is not released" || fail "failed check released"

# --- 9. guards --------------------------------------------------------------------------------------------------------------------------
reset_all; echo stray > "$FX/stray.txt"; publish
[ "$rc" != 0 ] && ! branch_exists && ! logged 'pr create' && ok "a dirty working tree aborts before anything is pushed" || { echo "$out"; fail "dirty tree guard"; }
reset_all; publish TARGET=0.6.5
[ "$rc" = 0 ] && [ ! -s "$LOG" ] && ok "TARGET equal to CURRENT does nothing" || fail "no-op"
reset_all; publish 'TARGET=1.2.3;ls'
[ "$rc" != 0 ] && ok "malformed TARGET is rejected" || fail "bad TARGET"
reset_all; publish CURRENT=bogus
[ "$rc" != 0 ] && ok "malformed CURRENT is rejected" || fail "bad CURRENT"

[ "$FAILED" = 0 ] && echo "ALL PASSED" || { echo "SOME FAILED"; exit 1; }
