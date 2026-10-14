#!/bin/sh
# Stubbed behavioural test for litterbox-export. `podman` is a stub that serves files from a fake
# container root through the same `podman cp ... -` tar-stream interface, so nothing real is touched.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/litterbox-sandbox-addons/litterbox-export"
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin" "$W/home" "$W/rootfs"
FAILED=0
ok() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAILED=1; }
has() { grep -qxF -- "$2" "$1"; }

# --- fake container root ------------------------------------------------------------------------
R=$W/rootfs; A=$R/usr/share/applications; H=$R/usr/share/icons/hicolor
mkdir -p "$A" "$H/256x256/apps" "$H/scalable/apps" "$H/48x48/apps" "$R/usr/share/pixmaps" "$R/usr/share/code"
cat > "$A/codium.desktop" <<'EOF'
[Desktop Entry]
Name=VSCodium
Name[de]=VSCodium DE
GenericName=Text Editor
Comment=Code editing. Redefined.
Exec=/usr/bin/codium --unity-launch %F
Icon=vscodium
Type=Application
StartupNotify=false
StartupWMClass=VSCodium
Categories=Utility;TextEditor;Development;IDE;
MimeType=text/plain;
TryExec=/usr/bin/codium
DBusActivatable=true
Actions=new-empty-window;

[Desktop Action new-empty-window]
Name=New Empty Window
Exec=/usr/bin/codium --new-window %F
EOF
printf '[Desktop Entry]\nType=Application\nName=URL Handler\nExec=/usr/bin/codium --open-url %%U\nIcon=vscodium\n' > "$A/codium-url-handler.desktop"
printf '[Desktop Entry]\nType=Application\nName=htop\nExec=htop\nTerminal=true\nIcon=htop\n' > "$A/htop.desktop"
printf '[Desktop Entry]\nType=Application\nName=Pix\nExec=pix\nIcon=pixonly\n' > "$A/pixonly.desktop"
printf '[Desktop Entry]\nType=Application\nName=Abs\nExec=abs\nIcon=/usr/share/code/icon.png\n' > "$A/abs.desktop"
printf '[Desktop Entry]\nType=Application\nName=Evil\nExec=evil\nIcon=../../../etc/passwd\n' > "$A/evil.desktop"
printf '[Desktop Entry]\nType=Application\nName=Hid\nExec=hid\nHidden=true\n' > "$A/hidden.desktop"
printf '[Desktop Entry]\nType=Link\nName=Lnk\nURL=http://x\n' > "$A/notapp.desktop"
printf '[Desktop Entry]\nType=Application\nName=Sym\nExec=sym\nIcon=symicon\n' > "$A/symicon.desktop"
printf '[Desktop Entry]\nType=Application\nName=Fake\nExec=fake\n' > "$A/fake.desktop"
printf 'PNG256-bytes' > "$H/256x256/apps/vscodium.png"
printf '<svg>vscodium</svg>' > "$H/scalable/apps/vscodium.svg"
ln -s /etc/hostname "$H/48x48/apps/symicon.png"
printf 'PIXMAP-bytes' > "$R/usr/share/pixmaps/pixonly.png"
printf 'ABS-bytes' > "$R/usr/share/code/icon.png"

# --- stubs ---------------------------------------------------------------------------------------
cat > "$W/bin/podman" <<EOF
#!/bin/sh
ROOTFS="$R"
case "\$1" in
  ps) case "\$*" in *label=work.litterbox.name=dev*) echo cid123abc ;; esac ;;
  cp) src=\${2#*:}
      [ "\$3" = - ] || exit 1
      [ -e "\$ROOTFS\$src" ] || [ -L "\$ROOTFS\$src" ] || { echo "Error: no such path" >&2; exit 125; }
      tar -C "\$(dirname "\$ROOTFS\$src")" -cf - "\$(basename "\$src")" ;;
  *) exit 1 ;;
esac
EOF
printf '#!/bin/sh\nfor a in "$@"; do printf "%%s\\n" "$a"; done\n' > "$W/bin/litterbox"
chmod +x "$W/bin/"*
export PATH="$W/bin:$PATH" HOME="$W/home"
unset XDG_DATA_HOME
X="sh $SCRIPT"
APPS="$HOME/.local/share/applications"; ICONS="$HOME/.local/share/icons"
LB="$W/bin/litterbox"

# --- app export ------------------------------------------------------------------------------------
$X dev --app codium >/dev/null 2>&1 || fail "export codium failed"
F="$APPS/litterbox-dev-codium.desktop"
[ -f "$F" ] && ok "desktop file written" || fail "no desktop file"
has "$F" "Name=VSCodium (dev)" && ok "Name gets the litterbox suffix" || fail "Name"
has "$F" "Exec=$LB enter dev -- /usr/bin/codium --unity-launch %F" && ok "Exec runs through 'litterbox enter dev --' with original args and field codes" || { grep '^Exec' "$F"; fail "Exec"; }
has "$F" "Icon=litterbox-dev-vscodium" && ok "Icon renamed to a namespaced theme icon" || fail "Icon"
has "$F" "X-Litterbox-Export=dev" && ok "ownership marker present" || fail "marker"
has "$F" "Terminal=false" && ok "Terminal=false" || fail "Terminal"
grep -q 'Desktop Action' "$F" && fail "Actions group leaked" || ok "action groups not copied"
grep -qE '^(TryExec|DBusActivatable|Actions|Name\[)' "$F" && fail "non-whitelisted key copied" || ok "TryExec/DBusActivatable/Actions/localized Name not copied"
has "$F" "Categories=Utility;TextEditor;Development;IDE;" && has "$F" "StartupWMClass=VSCodium" && ok "whitelisted keys copied" || fail "whitelist"
[ "$(cat "$ICONS/hicolor/256x256/apps/litterbox-dev-vscodium.png")" = "PNG256-bytes" ] && [ "$(cat "$ICONS/hicolor/scalable/apps/litterbox-dev-vscodium.svg")" = "<svg>vscodium</svg>" ] && ok "png + svg icons installed under hicolor" || fail "icons"

# idempotent
sum1=$(sha256sum "$F" | cut -d' ' -f1); $X dev --app codium >/dev/null 2>&1; [ "$sum1" = "$(sha256sum "$F" | cut -d' ' -f1)" ] && ok "re-export is idempotent" || fail "idempotent"

# wrap / boxed
$X dev --app codium --boxed >/dev/null 2>&1
has "$F" "Exec=$LB enter dev -- boxed-run /usr/bin/codium --unity-launch %F" && ok "--boxed inserts boxed-run" || fail "--boxed"
$X dev --app codium --wrap 'a b' >/dev/null 2>&1 && fail "--wrap with a space accepted" || ok "--wrap with a space rejected"
$X dev --app codium --wrap '$(touch pwned)' >/dev/null 2>&1 && fail "--wrap with shell syntax accepted" || ok "--wrap with shell syntax rejected"
[ -e pwned ] && fail "command injection executed"

# terminal app, pixmap + absolute icons
$X dev --app htop >/dev/null 2>&1
has "$APPS/litterbox-dev-htop.desktop" "Exec=$LB enter dev --tty true --interactive true -- htop" && has "$APPS/litterbox-dev-htop.desktop" "Terminal=true" && ok "Terminal=true apps get tty flags" || fail "terminal app"
$X dev --app pixonly >/dev/null 2>&1
has "$APPS/litterbox-dev-pixonly.desktop" "Icon=$ICONS/litterbox/dev/pixonly.png" && [ "$(cat "$ICONS/litterbox/dev/pixonly.png")" = "PIXMAP-bytes" ] && ok "pixmaps icon fetched and referenced by path" || fail "pixmap icon"
$X dev --app abs >/dev/null 2>&1
has "$APPS/litterbox-dev-abs.desktop" "Icon=$ICONS/litterbox/dev/icon.png" && ok "absolute icon path fetched" || fail "abs icon"

# hostile content
$X dev --app evil >/dev/null 2>&1
has "$APPS/litterbox-dev-evil.desktop" "Icon=application-x-executable" && ok "'../' icon name ignored, fallback icon used" || fail "traversal icon"
$X dev --app symicon >/dev/null 2>&1
has "$APPS/litterbox-dev-symicon.desktop" "Icon=application-x-executable" && [ ! -e "$ICONS/hicolor/48x48/apps/litterbox-dev-symicon.png" ] && ok "symlinked icon not followed" || fail "symlink icon"
$X dev --app hidden >/dev/null 2>&1 && fail "Hidden=true exported" || ok "Hidden=true refused"
$X dev --app notapp >/dev/null 2>&1 && fail "Type=Link exported" || ok "non-Application refused"

# lookup
out=$($X dev --app odi 2>&1) && fail "ambiguous app accepted" || { echo "$out" | grep -q 'several apps' && echo "$out" | grep -q 'codium-url-handler.desktop' && ok "ambiguous match lists candidates and fails"; }
$X dev --app url >/dev/null 2>&1 && has "$APPS/litterbox-dev-codium-url-handler.desktop" "X-Litterbox-Export=dev" && ok "unique partial match resolves" || fail "partial match"
$X dev --app zzz >/dev/null 2>&1 && fail "unknown app accepted" || ok "unknown app rejected"
$X '../x' --app codium >/dev/null 2>&1 && fail "bad litterbox name accepted" || ok "bad litterbox name rejected"
$X ghost --app codium 2>&1 | grep -q "no container for 'ghost'" && ok "missing container gives a clear error" || fail "ghost"
$X dev --app 'a/b' >/dev/null 2>&1 && fail "app with slash accepted" || ok "app name with slash rejected"

# never clobber a file we did not create
printf 'mine\n' > "$APPS/litterbox-dev-fake.desktop"
$X dev --app fake >/dev/null 2>&1 && fail "overwrote unmarked file" || { [ "$(cat "$APPS/litterbox-dev-fake.desktop")" = mine ] && ok "unmarked existing file is not overwritten"; }

# --- bin export --------------------------------------------------------------------------------------
BO="$W/binout"
$X dev --bin codium --export-path "$BO" >/dev/null 2>&1
[ -x "$BO/codium" ] && sh -n "$BO/codium" && ok "bin wrapper created, executable, valid sh" || fail "bin wrapper"
got=$(sh "$BO/codium" 'a b' "it's" </dev/null | tr '\n' '|')
[ "$got" = "enter|dev|--|codium|a b|it's|" ] && ok "wrapper passes arguments through intact" || fail "wrapper args: $got"
$X dev --bin codium --export-path "$BO" --boxed >/dev/null 2>&1
got=$(sh "$BO/codium" x </dev/null | tr '\n' '|'); [ "$got" = "enter|dev|--|boxed-run|codium|x|" ] && ok "--boxed in wrapper" || fail "boxed wrapper: $got"
got=$(script -qec "sh $BO/codium x" /dev/null </dev/null | tr -d '\r' | tr '\n' '|'); [ "$got" = "enter|dev|--tty|true|--interactive|true|--|boxed-run|codium|x|" ] && ok "interactive (tty) path adds --tty/--interactive" || fail "tty wrapper: $got"
printf '#!/bin/sh\necho real git\n' > "$BO/git"; chmod +x "$BO/git"
$X dev --bin git --export-path "$BO" >/dev/null 2>&1 && fail "overwrote a real binary" || { grep -q 'real git' "$BO/git" && ok "existing non-exported command is not overwritten"; }
$X dev --bin 'rm -rf /' --export-path "$BO" >/dev/null 2>&1 && fail "bin with spaces accepted" || ok "bin command with spaces rejected"

# --- list ----------------------------------------------------------------------------------------------
lst=$($X dev --list --export-path "$BO")
echo "$lst" | grep -q '^app  VSCodium (dev)' && echo "$lst" | grep -q '^bin  codium' && ok "--list shows apps and bins" || { echo "$lst"; fail "list"; }

# --- delete ------------------------------------------------------------------------------------------------
$X dev --app codium --delete >/dev/null 2>&1
[ ! -e "$F" ] && [ ! -e "$ICONS/hicolor/256x256/apps/litterbox-dev-vscodium.png" ] && [ ! -e "$ICONS/hicolor/scalable/apps/litterbox-dev-vscodium.svg" ] && ok "--delete removes the launcher and its icons" || fail "delete app"
[ -e "$APPS/litterbox-dev-codium-url-handler.desktop" ] && ok "--delete leaves other exports alone" || fail "delete collateral"
$X dev --app codium --delete >/dev/null 2>&1 && fail "second delete succeeded" || ok "deleting something not exported fails clearly"
[ -e "$APPS/litterbox-dev-codium-url-handler.desktop" ] && ok "failed delete did not touch the similarly named export" || fail "second delete removed codium-url-handler"
out=$($X dev --app url --delete 2>&1) && fail "fuzzy delete succeeded" || { echo "$out" | grep -q 'codium-url-handler' && [ -e "$APPS/litterbox-dev-codium-url-handler.desktop" ] && ok "fuzzy delete refused, hint names the exact export"; }
$X dev --app codium-url-handler --delete >/dev/null 2>&1; [ ! -e "$APPS/litterbox-dev-codium-url-handler.desktop" ] && ok "exact-name delete works" || fail "exact delete"
$X dev --app fake --delete >/dev/null 2>&1; [ "$(cat "$APPS/litterbox-dev-fake.desktop")" = mine ] && ok "--delete never removes an unmarked file" || fail "delete unmarked"
$X dev --bin codium --export-path "$BO" --delete >/dev/null 2>&1; [ ! -e "$BO/codium" ] && ok "--delete --bin removes the wrapper" || fail "delete bin"
$X dev --bin git --export-path "$BO" --delete >/dev/null 2>&1; grep -q 'real git' "$BO/git" && ok "--delete --bin refuses a file it did not create" || fail "delete foreign bin"
$X dev --delete >/dev/null 2>&1 && fail "--delete without target accepted" || ok "--delete without --app/--bin rejected"

[ "$FAILED" = 0 ] && echo "ALL PASSED" || { echo "SOME FAILED"; exit 1; }
