#!/bin/sh
# Tests for litterbox-prune with a stub `podman` that logs every call and serves a fixture image list.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/litterbox-sandbox-addons/litterbox-prune"
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
FAILED=0
ok() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAILED=1; }

BIN="$W/bin"; LOG="$W/podman.log"; mkdir -p "$BIN"
cat > "$BIN/podman" <<'EOF'
#!/bin/sh
echo "podman $*" >> "$PODMAN_LOG"
[ "$1 $2" = "image ls" ] || [ "$1 $2" = "image rm" ] || exit 2
if [ "$2" = ls ]; then
  case "$*" in *"--format"*) for i in $FAKE_IDS; do echo "$i"; done ;; *) echo "REPOSITORY  TAG  IMAGE ID  CREATED"; echo "<none>  <none>  ${FAKE_IDS%% *}  2 weeks ago" ;; esac
  exit 0
fi
# image rm ID
for i in $IN_USE; do
  if [ "$3" = "$i" ]; then echo "Error: image is in use by a container" >&2; exit 2; fi
done
echo "$3"
EOF
chmod +x "$BIN/podman"

EXTRA=''
run_prune() {
  out=$(env ${EXTRA:+"$EXTRA"} PATH="$BIN:$PATH" PODMAN_LOG="$LOG" FAKE_IDS="${FAKE_IDS:-}" IN_USE="${IN_USE:-}" sh "$SCRIPT" "$@" 2>&1); rc=$?
  EXTRA=''
}
fresh() { : > "$LOG"; }
removals() { grep -c '^podman image rm ' "$LOG"; }

FAKE_IDS='aaaaaaaaaaaa bbbbbbbbbbbb'; IN_USE=''

# --- lists by default, removes only with --yes ---------------------------------------------------------------------
fresh; run_prune
[ "$rc" = 0 ] && [ "$(removals)" = 0 ] && echo "$out" | grep -q '2 image(s)' && echo "$out" | grep -q 'Run again with --yes' && ok "default run only lists (nothing removed)" || { echo "$out"; fail "default list"; }
grep -q -- '--filter label=work.litterbox.name --filter dangling=true' "$LOG" && ok "it asks for label AND dangling=true" || { cat "$LOG"; fail "filters"; }
fresh; run_prune --yes
[ "$rc" = 0 ] && [ "$(removals)" = 2 ] && echo "$out" | grep -q 'removed aaaaaaaaaaaa' && echo "$out" | grep -q 'Removed 2, kept 0' && ok "--yes removes each listed image" || { echo "$out"; fail "--yes"; }
if grep -E 'podman .*(--force| -f( |$)|prune| rmi |system )' "$LOG" >/dev/null; then fail "a forceful or broad podman command was used"; else ok "never --force, never prune/rmi/system: only 'image rm <id>'"; fi
if grep -E '^podman image rm ' "$LOG" | grep -v -E '^podman image rm [0-9a-f]+$' >/dev/null; then fail "image rm got extra arguments"; else ok "image rm gets exactly one plain id and nothing else"; fi

# --- images still in use are kept ---------------------------------------------------------------------------------------
fresh; out=$(env PATH="$BIN:$PATH" PODMAN_LOG="$LOG" FAKE_IDS="$FAKE_IDS" IN_USE=bbbbbbbbbbbb sh "$SCRIPT" --yes 2>&1); rc=$?
[ "$rc" = 1 ] && echo "$out" | grep -q 'removed aaaaaaaaaaaa' && echo "$out" | grep -q 'kept    bbbbbbbbbbbb (Error: image is in use' && echo "$out" | grep -q 'Removed 1, kept 1' && ok "an image still used by a container is kept, reported, exit 1" || { echo "$out"; fail "in-use handling"; }

# --- names ----------------------------------------------------------------------------------------------------------------
fresh; run_prune dev work
grep -q -- 'label=work.litterbox.name=dev ' "$LOG" && grep -q -- 'label=work.litterbox.name=work ' "$LOG" && ok "names narrow the label filter, one query each" || { cat "$LOG"; fail "name filters"; }
fresh; out=$(env PATH="$BIN:$PATH" PODMAN_LOG="$LOG" FAKE_IDS="aaaaaaaaaaaa" IN_USE='' sh "$SCRIPT" --yes dev work 2>&1)
[ "$(removals)" = 1 ] && ok "the same image reported by two queries is removed once" || { cat "$LOG"; fail "dedupe"; }

# --- nothing to do -------------------------------------------------------------------------------------------------------------
fresh; out=$(env PATH="$BIN:$PATH" PODMAN_LOG="$LOG" FAKE_IDS="" IN_USE='' sh "$SCRIPT" --yes 2>&1); rc=$?
[ "$rc" = 0 ] && echo "$out" | grep -q 'No dangling Litterbox images' && ok "nothing to remove: says so, exit 0" || { echo "$out"; fail "empty"; }

# --- hostile output from podman ------------------------------------------------------------------------------------------
fresh; out=$(env PATH="$BIN:$PATH" PODMAN_LOG="$LOG" FAKE_IDS='aaaaaaaaaaaa x;touch$IFS'"$W"'/PWN ../../etc ABCDEF' IN_USE='' sh "$SCRIPT" --yes 2>&1); rc=$?
[ ! -e "$W/PWN" ] && [ "$(removals)" = 1 ] && echo "$out" | grep -q 'ignoring unexpected image id' && ok "ids that are not plain lowercase hex are ignored, never executed" || { echo "$out"; fail "hostile ids"; }

# --- input checks -------------------------------------------------------------------------------------------------------------
for bad in '../x' 'a b' '.hidden' 'x;ls' '$(id)'; do
  fresh; run_prune "$bad"
  [ "$rc" != 0 ] && [ ! -s "$LOG" ] && ok "name '$bad' is rejected before podman is called" || fail "accepted name '$bad'"
done
run_prune --bogus; [ "$rc" != 0 ] && ok "unknown option is refused" || fail "unknown option"
run_prune --help >/dev/null; [ "$rc" = 0 ] && ok "--help exits 0" || fail "help"
out=$(env PATH="/usr/bin:/bin" sh "$SCRIPT" 2>&1); rc=$?
[ "$rc" != 0 ] && echo "$out" | grep -q 'podman is not installed' && ok "missing podman is a clear error" || fail "missing podman"

[ "$FAILED" = 0 ] && echo "ALL PASSED" || { echo "SOME FAILED"; exit 1; }
