#!/bin/sh
# Offline tests for tools/scan-release. Lockfiles are tiny synthetic ones; osv-scanner is a stub that
# "finds" whatever a lockfile declares in `# vuln: ID[,ALIAS...] crate version` comment lines.
# Needs jq.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TOOL="$ROOT/tools/scan-release"
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
FAILED=0
ok() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAILED=1; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required for this suite"; exit 1; }

FX="$W/fx"; UP="$W/up"; mkdir -p "$FX" "$UP"
REG='registry+https://github.com/rust-lang/crates.io-index'

# --- stub osv-scanner ---------------------------------------------------------------------------------
cat > "$W/osv-stub" <<'EOF'
#!/bin/sh
# usage: osv-stub scan --format json -L FILE
[ -n "${STUB_RC:-}" ] && { echo "stub failure" >&2; exit "$STUB_RC"; }
[ -n "${STUB_GARBAGE:-}" ] && { echo "this is not json"; exit 1; }
f=$5
v=$(grep '^# vuln: ' "$f" | sed 's/^# vuln: //')
if [ -z "$v" ]; then echo '{"results":[]}'; exit 0; fi
printf '%s\n' "$v" | jq -R -n '[inputs | split(" ") | {ids: (.[0]|split(",")), name: .[1], version: .[2]}]
  | {results: [{source: {path: "x", type: "lockfile"},
                packages: map({package: {name: .name, version: .version, ecosystem: "crates.io"},
                               vulnerabilities: [{id: .ids[0], aliases: .ids[1:]}]})}]}'
exit 1
EOF
chmod +x "$W/osv-stub"

# --- fixtures -----------------------------------------------------------------------------------------------
# pkg NAME VERSION [CHECKSUM [SOURCE]] -> one [[package]] block
pkg() {
  printf '\n[[package]]\nname = "%s"\nversion = "%s"\n' "$1" "$2"
  [ -z "${4:-$REG}" ] || { [ -z "${3:-}" ] || printf 'source = "%s"\nchecksum = "%s"\n' "${4:-$REG}" "$3"; }
}
base_lock() { # the shipped litterbox lockfile
  printf 'version = 3\n'
  pkg alpha 1.0.0 aaaa
  pkg beta 2.0.0 bbbb
  pkg litterbox 0.1.0
}
tiny_lock() { printf 'version = 3\n'; pkg "$1" 0.1.0; }

# setup_old [extra lines appended to the shipped litterbox lockfile]
setup_old() {
  rm -rf "$FX"; mkdir -p "$FX/locks/litterbox" "$FX/locks/lbx-init" "$FX/locks/shared"
  { base_lock; printf '%s\n' "$@"; } > "$FX/locks/litterbox/Cargo.lock"
  tiny_lock lbx-init > "$FX/locks/lbx-init/Cargo.lock"
  tiny_lock shared > "$FX/locks/shared/Cargo.lock"
}
# make_new VERSION: reads the new litterbox lockfile from stdin and builds the fake upstream tarball
make_new() {
  s=$(mktemp -d "$W/stage.XXXXXX"); d="$s/Litterbox-$1"
  mkdir -p "$d/litterbox" "$d/lbx-init" "$d/shared"
  cat > "$d/litterbox/Cargo.lock"
  tiny_lock lbx-init > "$d/lbx-init/Cargo.lock"; tiny_lock shared > "$d/shared/Cargo.lock"
  tar -czf "$UP/v$1.tar.gz" -C "$s" "Litterbox-$1"; rm -rf "$s"
}
export LBX_ROOT="$FX" LITTERBOX_TARBALL_URL_BASE="file://$UP" OSV_SCANNER="$W/osv-stub"
unset STUB_RC STUB_GARBAGE LBX_MAX_NEW_CRATES
EXTRA=

# run_scan VERSION -> sets rc and out
# EXTRA holds one VAR=value for the next run (a plain `VAR=x function` is not portable across shells).
run_scan() { out=$(env ${EXTRA:+"$EXTRA"} sh "$TOOL" "$@" 2>&1); rc=$?; }
expect() { # expect NAME WANT_RC [grep pattern]
  if [ "$rc" = "$2" ] && { [ -z "${3:-}" ] || printf '%s\n' "$out" | grep -q -- "$3"; }; then ok "$1"; else echo "$out" | tail -12; fail "$1 (rc=$rc, wanted $2 ${3:-})"; fi
}

# --- 1. clean bump ------------------------------------------------------------------------------------
setup_old
{ printf 'version = 3\n'; pkg alpha 1.0.1 cccc; pkg beta 2.0.0 bbbb; pkg gamma 0.3.0 gggg; pkg litterbox 0.1.0; } | make_new 1.1.0
run_scan 1.1.0 --report "$W/report.md"
expect "clean update passes" 0 "RESULT: clean"
grep -q 'New crate names: 1' "$W/report.md" && grep -q '  - gamma' "$W/report.md" && ok "report lists the new crate" || fail "report content"
grep -q 'Result: \*\*clean\*\*' "$W/report.md" && ok "--report writes the markdown report" || fail "--report"

# --- 2. checksum changed for the same version ------------------------------------------------------------
{ printf 'version = 3\n'; pkg alpha 1.0.0 aaaa; pkg beta 2.0.0 EVIL; pkg litterbox 0.1.0; } | make_new 1.2.0
run_scan 1.2.0
expect "same crate version with a different checksum holds" 20 'checksum changed for beta 2.0.0'

# --- 3. non-crates.io sources ------------------------------------------------------------------------------
{ base_lock; pkg delta 0.1.0 dddd 'git+https://github.com/x/delta#abcdef'; } | make_new 1.3.0
run_scan 1.3.0
expect "git dependency holds" 20 'non-crates.io source: git+https://github.com/x/delta'
{ base_lock; pkg eps 0.1.0 eeee 'registry+https://example.com/index'; } | make_new 1.3.1
run_scan 1.3.1
expect "alternate registry holds" 20 'non-crates.io source'
{ base_lock; pkg sp 0.1.0 ssss 'sparse+https://index.crates.io/'; } | make_new 1.3.2
run_scan 1.3.2
expect "sparse crates.io index is accepted" 0 'RESULT: clean'

# --- 4. too many new crates ----------------------------------------------------------------------------------
{ base_lock; pkg n1 1.0.0 1111; pkg n2 1.0.0 2222; pkg n3 1.0.0 3333; } | make_new 1.4.0
EXTRA=LBX_MAX_NEW_CRATES=2; run_scan 1.4.0; EXTRA=
expect "more new crates than the limit holds" 20 '3 new crates in one update'
run_scan 1.4.0
expect "the same update passes under the default limit" 0 'RESULT: clean'

# --- 5. advisories --------------------------------------------------------------------------------------------
{ base_lock; printf '# vuln: RUSTSEC-2099-0001 alpha 1.0.0\n'; } | make_new 1.5.0
run_scan 1.5.0
expect "advisory that is new in the update holds" 20 'new advisory RUSTSEC-2099-0001 affects alpha'

setup_old '# vuln: RUSTSEC-2099-0002 beta 2.0.0'
{ base_lock; printf '# vuln: RUSTSEC-2099-0002 beta 2.0.0\n'; } | make_new 1.5.1
run_scan 1.5.1
expect "advisory the shipped version already had does not block" 0 'RESULT: clean'
printf '%s\n' "$out" | grep -q 'Already present in the shipped version (informational): 1' && ok "pre-existing advisories are reported as information" || fail "informational count"

setup_old '# vuln: GHSA-aaaa-bbbb-cccc,RUSTSEC-2099-0003 beta 2.0.0'
{ base_lock; printf '# vuln: RUSTSEC-2099-0003 beta 2.0.0\n'; } | make_new 1.5.2
run_scan 1.5.2
expect "a known advisory under a different id (alias) does not block" 0 'RESULT: clean'

setup_old
{ base_lock; printf '# vuln: RUSTSEC-2099-0004 alpha 1.0.0\n'; } | make_new 1.5.3
printf '[[IgnoredVulns]]\nid = "RUSTSEC-2099-0004"\nreason = "does not apply: we never call the affected function (checked by test)"\n' > "$FX/.osv-scanner.toml"
run_scan 1.5.3
expect "advisory ignored with a reason does not block" 0 'RESULT: clean'
printf '[[IgnoredVulns]]\nid = "RUSTSEC-2099-0004"\n' > "$FX/.osv-scanner.toml"
run_scan 1.5.3
expect "ignore entry without a reason is an error" 1 'without both an id and a reason'
printf '[[IgnoredVulns]]\nid = "RUSTSEC-2099-0004"\nreason = ""\n' > "$FX/.osv-scanner.toml"
run_scan 1.5.3
expect "ignore entry with an empty reason is an error" 1 'without both an id and a reason'
printf '# [[IgnoredVulns]]\n# id = "x"\n' > "$FX/.osv-scanner.toml"
run_scan 1.5.3
expect "a commented-out example entry is not an ignore" 20 'new advisory RUSTSEC-2099-0004'
rm -f "$FX/.osv-scanner.toml"

# --- 6. fail closed ----------------------------------------------------------------------------------------------
setup_old
{ base_lock; } | make_new 1.6.0
EXTRA=STUB_RC=127; run_scan 1.6.0; EXTRA=
expect "scanner exit 127 is an error (no merge)" 1 'RESULT: error'
EXTRA=STUB_RC=128; run_scan 1.6.0; EXTRA=
expect "scanner exit 128 (no packages found) is an error" 1 'RESULT: error'
EXTRA=STUB_GARBAGE=1; run_scan 1.6.0; EXTRA=
expect "non-JSON scanner output is an error" 1 'not JSON'
EXTRA=OSV_SCANNER=/nonexistent/osv; run_scan 1.6.0; EXTRA=
expect "missing scanner binary is an error" 1 'osv-scanner not found'
run_scan 9.9.9
expect "tarball that cannot be downloaded is an error" 1 'could not download'
rm "$FX/locks/shared/Cargo.lock"
run_scan 1.6.0
expect "missing baseline lockfile is an error" 1 'baseline'
setup_old
s=$(mktemp -d "$W/stage.XXXXXX"); mkdir -p "$s/Litterbox-1.6.1/litterbox"; base_lock > "$s/Litterbox-1.6.1/litterbox/Cargo.lock"; tar -czf "$UP/v1.6.1.tar.gz" -C "$s" Litterbox-1.6.1
run_scan 1.6.1
expect "tarball without all three lockfiles is an error" 1 'has no lbx-init/Cargo.lock'

# --- 7. argument validation ------------------------------------------------------------------------------------------
for bad in '' 1.2 v1.2.3 '1.2.3;ls' ../x; do
  run_scan "$bad"; if [ "$rc" = 1 ]; then ok "rejected VERSION '$bad'"; else fail "accepted VERSION '$bad'"; fi
done

[ "$FAILED" = 0 ] && echo "ALL PASSED" || { echo "SOME FAILED"; exit 1; }
