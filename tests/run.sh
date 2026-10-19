#!/bin/sh
# Runs every test suite and (if installed) shellcheck. Exit status is non-zero if anything failed.
# Usage: sh tests/run.sh [suite ...]      suites: pkgbuild installer boxed-run export urlhandler litterbox-update prune assemble completions update scan publish
# Needs: sh, bash, tar, awk, sed, jq, curl (network), `script` (util-linux). Optional: shellcheck; fish (set FISH=/path/to/fish if it is
# not on PATH) to exercise the fish login shell and the fish completions; zsh (completion syntax check).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
SUITES=${*:-pkgbuild installer boxed-run export urlhandler litterbox-update prune assemble completions update scan publish}

failed=""
for s in $SUITES; do
  printf '\n=== %s ===\n' "$s"
  if [ ! -f "$HERE/$s.sh" ]; then
    echo "no such suite: $s"; failed="$failed $s"; continue
  fi
  if sh "$HERE/$s.sh"; then :; else failed="$failed $s"; fi
done

printf '\n=== shellcheck ===\n'
if command -v shellcheck >/dev/null 2>&1; then
  cd "$ROOT" || exit 1
  # Shipped scripts and tools: everything. Tests: warnings and errors only (they use `A && ok || fail` on purpose).
  if shellcheck -s sh litterbox-sandbox-addons/boxed-run litterbox-sandbox-addons/litterbox-addon \
       litterbox-sandbox-addons/litterbox-export litterbox-sandbox-addons/litterbox-update litterbox-sandbox-addons/litterbox-prune litterbox-sandbox-addons/litterbox-assemble tools/update-litterbox tools/scan-release tools/publish-update \
     && shellcheck -s bash litterbox-sandbox-addons/litterbox-tools.bash \
     && shellcheck -s sh -S warning tests/*.sh; then
    echo "PASS: shellcheck clean"
  else
    failed="$failed shellcheck"
  fi
else
  echo "SKIP: shellcheck is not installed"
fi

printf '\n'
if [ -z "$failed" ]; then echo "ALL SUITES PASSED"; exit 0; fi
echo "FAILED:$failed"; exit 1
