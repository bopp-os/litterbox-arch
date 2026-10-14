#!/bin/sh
# Functional test for litterbox-addon, run against upstream Litterbox's real CachyOS template.
# Needs network (fetches the two Dockerfile templates, pinned to Litterbox v0.6.5).
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC="$ROOT/litterbox-sandbox-addons"
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

mkdir -p "$W/addons/boxed-run" "$W/lbx/definitions"
cp "$SRC/boxed-run" "$W/addons/boxed-run/boxed-run"
cp "$SRC/boxed-run.packages.arch" "$W/addons/boxed-run/packages.arch"
TPL=https://raw.githubusercontent.com/Gerharddc/litterbox/v0.6.5/litterbox/templates
curl -fsSL "$TPL/cachyos.Dockerfile" -o "$W/lbx/definitions/dev.Dockerfile"
curl -fsSL "$TPL/ubuntu-latest.Dockerfile" -o "$W/lbx/definitions/ub.Dockerfile"
export LITTERBOX_ADDONS_DIR="$W/addons" LITTERBOX_ROOT="$W/lbx"
A="sh $SRC/litterbox-addon"
DEF="$W/lbx/definitions/dev.Dockerfile"
ok() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; exit 1; }

orig=$(sha256sum "$DEF" | cut -d' ' -f1)

[ "$($A list)" = "boxed-run" ] && ok "list" || fail "list"

$A install dev >/dev/null
grep -qxF '# >>> litterbox-addons >>>' "$DEF" && grep -qxF '# <<< litterbox-addons <<<' "$DEF" && ok "markers present" || fail "markers"
grep -q '^RUN pacman -S --noconfirm --needed dbus glib2 gnome-keyring gnome-themes-extra gsettings-desktop-schemas libsecret util-linux$' "$DEF" && ok "pacman line (sorted, deduped, comments dropped)" || { grep -n 'pacman' "$DEF"; fail "pacman line"; }

first=$(sha256sum "$DEF" | cut -d' ' -f1)
$A install dev >/dev/null
[ "$first" = "$(sha256sum "$DEF" | cut -d' ' -f1)" ] && ok "install is idempotent" || fail "idempotent"
[ "$(grep -c '^# >>> litterbox-addons >>>$' "$DEF")" = 1 ] && ok "exactly one block after reinstall" || fail "block count"

# Heredoc round trip: run the generated RUN body for boxed-run with /usr/local/bin redirected.
# Restricted to our managed block: upstream's own template has an earlier RUN <<'EOF' (/prep-home.sh).
body=$(awk '/^# >>> litterbox-addons >>>$/{blk=1} blk && /^RUN <<.EOF.$/{f=1; next} f && /^EOF$/{exit} f' "$DEF")
case "$body" in *"/usr/local/bin/boxed-run"*) ;; *) fail "extracted wrong heredoc body" ;; esac
mkdir -p "$W/fakebin"
printf '%s\n' "$body" | sed "s|/usr/local/bin|$W/fakebin|g" | sh
cmp "$W/fakebin/boxed-run" "$SRC/boxed-run" && ok "embedded script is byte-identical after heredoc round trip" || fail "round trip"
[ -x "$W/fakebin/boxed-run" ] && ok "installed script is executable" || fail "exec bit"

$A remove dev >/dev/null
[ "$orig" = "$(sha256sum "$DEF" | cut -d' ' -f1)" ] && ok "remove restores the original byte-for-byte" || fail "remove"
$A remove dev | grep -q 'No addons installed' && ok "remove when nothing installed is a no-op" || fail "remove noop"

$A install ub 2>&1 | grep -q 'Only Arch/CachyOS' && ok "non-Arch base image rejected" || fail "ubuntu reject"
$A install nope 2>&1 | grep -q 'not found' && ok "missing definition rejected" || fail "missing def"
$A install dev nope 2>&1 | grep -q "unknown addon" && ok "unknown addon rejected" || fail "unknown addon"
$A install '../evil' 2>&1 | grep -q 'invalid Litterbox name' && ok "path traversal rejected" || fail "traversal"

# A script that would terminate the heredoc early must be refused.
printf '#!/bin/sh\necho hi\nEOF\necho oops\n' > "$W/addons/boxed-run/bad"; chmod +x "$W/addons/boxed-run/bad"
$A install dev boxed-run 2>&1 | grep -q 'end the embedded heredoc early' && ok "heredoc-breaking script refused" || fail "heredoc guard"
[ "$orig" = "$(sha256sum "$DEF" | cut -d' ' -f1)" ] && ok "definition untouched after refused install" || fail "refused install modified file"
leaked=$(find "$W/lbx/definitions" -name 'dev.Dockerfile.*')
[ -z "$leaked" ] && ok "no temp files left behind" || fail "temp file leaked: $leaked"
echo "ALL PASSED"
