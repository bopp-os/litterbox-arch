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
cat > "$W/bin/litterbox" <<'EOF'
#!/bin/sh
# Emulates `litterbox enter`: joins the words after -- with single spaces and NO quoting (lbx-init does this
# and hands the string to the login shell), lets a shell re-parse them, then prints "enter NAME[ tty]"
# followed by the words that shell produced, one per line.
[ "$1" = enter ] || exit 2
name=$2; shift 2
tty=''
while [ $# -gt 0 ]; do
  case $1 in
    --tty) tty=' tty'; shift 2 ;;
    --interactive) shift 2 ;;
    --root) shift ;;
    --) shift; break ;;
    *) shift ;;
  esac
done
line=''
for a in "$@"; do line="$line $a"; done
printf 'enter %s%s\n' "$name" "$tty"
if [ "${CONTAINER_SHELL:-sh}" = fish ]; then
  exec "$FISH" -l -c "printf '%s\\n' $line"
fi
sh -c "set -- $line; for w in \"\$@\"; do printf '%s\\n' \"\$w\"; done"
EOF
chmod +x "$W/bin/"*
export PATH="$W/bin:$PATH" HOME="$W/home"
unset XDG_DATA_HOME
X="sh $SCRIPT"
APPS="$HOME/.local/share/applications"; ICONS="$HOME/.local/share/icons"
SELF="$SCRIPT"   # launchers call litterbox-export itself

# --- app export ------------------------------------------------------------------------------------
$X dev --app codium >/dev/null 2>&1 || fail "export codium failed"
F="$APPS/litterbox-dev-codium.desktop"
[ -f "$F" ] && ok "desktop file written" || fail "no desktop file"
has "$F" "Name=VSCodium (dev)" && ok "Name gets the litterbox suffix" || fail "Name"
has "$F" "Exec=$SELF dev --exec -- /usr/bin/codium --unity-launch %F" && ok "Exec runs through 'litterbox-export dev --exec --' with original args and field codes" || { grep '^Exec' "$F"; fail "Exec"; }
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
has "$F" "Exec=$SELF dev --exec -- boxed-run /usr/bin/codium --unity-launch %F" && ok "--boxed inserts boxed-run" || fail "--boxed"
$X dev --app codium --wrap 'a b' >/dev/null 2>&1 && fail "--wrap with a space accepted" || ok "--wrap with a space rejected"
$X dev --app codium --wrap '$(touch pwned)' >/dev/null 2>&1 && fail "--wrap with shell syntax accepted" || ok "--wrap with shell syntax rejected"
[ -e pwned ] && fail "command injection executed"

# terminal app, pixmap + absolute icons
$X dev --app htop >/dev/null 2>&1
has "$APPS/litterbox-dev-htop.desktop" "Exec=$SELF dev --exec --tty -- htop" && has "$APPS/litterbox-dev-htop.desktop" "Terminal=true" && ok "Terminal=true apps get tty flags" || fail "terminal app"
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
[ "$got" = "enter dev|codium|a b|it's|" ] && ok "wrapper passes arguments through intact" || fail "wrapper args: $got"
$X dev --bin codium --export-path "$BO" --boxed >/dev/null 2>&1
got=$(sh "$BO/codium" x </dev/null | tr '\n' '|'); [ "$got" = "enter dev|boxed-run|codium|x|" ] && ok "--boxed in wrapper" || fail "boxed wrapper: $got"
got=$(script -qec "sh $BO/codium x" /dev/null </dev/null | tr -d '\r' | tr '\n' '|'); [ "$got" = "enter dev tty|boxed-run|codium|x|" ] && ok "interactive (tty) path adds --tty/--interactive" || fail "tty wrapper: $got"
printf '#!/bin/sh\necho real git\n' > "$BO/git"; chmod +x "$BO/git"
$X dev --bin git --export-path "$BO" >/dev/null 2>&1 && fail "overwrote a real binary" || { grep -q 'real git' "$BO/git" && ok "existing non-exported command is not overwritten"; }
$X dev --bin 'rm -rf /' --export-path "$BO" >/dev/null 2>&1 && fail "bin with spaces accepted" || ok "bin command with spaces rejected"


# --- --exec: every argument reaches the container shell exactly as given -----------------------------------------
# (the stub re-parses the joined string like lbx-init's login shell does, so unquoted metacharacters would bite)
PWN="$W/PWN"
check_args() { # check_args DESCRIPTION ARG...
  desc=$1; shift
  want="enter dev|cmd"; for a in "$@"; do want="$want|$a"; done; want="$want|"
  got=$($X dev --exec -- cmd "$@" 2>&1 | tr '\n' '|')
  [ "$got" = "$want" ] && ok "--exec keeps $desc intact (${CONTAINER_SHELL:-sh})" || { echo "want: $want"; echo "got:  $got"; fail "--exec mangled $desc (${CONTAINER_SHELL:-sh})"; }
}
args_matrix() {
check_args "spaces" 'a b'
check_args "single quotes" "it's" "a'b'c"
check_args "double quotes" 'say "hi"'
check_args "command substitution" "\$(touch $PWN)"
check_args "backticks" "\`touch $PWN\`"
check_args "semicolons and ampersands" "x;touch $PWN" "x&touch $PWN" 'a|b' 'a&&b'
check_args "globs, tilde, hash, bang" '*' '~' '#c' '!!' '$HOME'
check_args "an OAuth-style callback URL" 'claude://login/callback?code=1&state=2%203#frag'
check_args "empty and option-like arguments" '' '-n' '--k=v with space'
check_args "redirects, parens, brackets, braces" '>out' '<in' '2>&1' '(x)' '[a]' '{a,b}' '%self'
[ ! -e "$PWN" ] && ok "no argument was ever executed by the container shell (${CONTAINER_SHELL:-sh})" || fail "an argument was executed (${CONTAINER_SHELL:-sh})"
rm -f "$PWN"
}
args_matrix
# Every default Litterbox template makes fish the login shell, so check the same matrix against real fish too.
FISH=${FISH:-$(command -v fish || true)}
if [ -n "$FISH" ] && [ -x "$FISH" ]; then
  export FISH CONTAINER_SHELL=fish
  args_matrix
  unset CONTAINER_SHELL
else
  echo "SKIP: no fish available (set FISH=/path/to/fish): the fish login shell was not exercised"
fi

out=$($X dev --exec -- cmd 'a\b' 2>&1); rc=$?
[ "$rc" != 0 ] && echo "$out" | grep -q 'backslash' && ! echo "$out" | grep -q '^enter dev' && ok "an argument with a backslash is refused, nothing is run" || { echo "$out"; fail "backslash"; }
nlarg=$(printf 'a\nb')
out=$($X dev --exec -- cmd "$nlarg" 2>&1); rc=$?
[ "$rc" != 0 ] && echo "$out" | grep -q 'newline' && ! echo "$out" | grep -q '^enter dev' && ok "an argument with a newline is refused, nothing is run" || { echo "$out"; fail "newline"; }
got=$($X dev --exec --tty -- htop | tr '\n' '|'); [ "$got" = "enter dev tty|htop|" ] && ok "--exec --tty adds the tty flags" || fail "exec tty: $got"
$X dev --exec >/dev/null 2>&1 && fail "--exec without a command accepted" || ok "--exec needs a command"
$X dev --exec --delete -- x >/dev/null 2>&1 && fail "--exec --delete accepted" || ok "--exec rejects other modes' flags"
$X dev --tty >/dev/null 2>&1 && fail "--tty alone accepted" || ok "--tty only applies to --exec"
$X dev --app codium -- foo >/dev/null 2>&1 && fail "arguments after -- accepted for --app" || ok "arguments after -- are only for --exec"

# An exported launcher, run the way a desktop would: substitute the field code, execute the Exec line.
$X dev --app codium --boxed >/dev/null 2>&1
execline=$(sed -n 's/^Exec=//p' "$F")
hostile="claude://cb?code=1&state=2;touch $PWN\$(touch $PWN)"
set -f; set -- $execline; set +f
launched=$(for t in "$@"; do [ "$t" = %F ] && printf '%s\0' "$hostile" || printf '%s\0' "$t"; done | xargs -0 sh -c '"$@"' _ | tr '\n' '|')
[ "$launched" = "enter dev|boxed-run|/usr/bin/codium|--unity-launch|$hostile|" ] && ok "exported launcher: a hostile URL in %F arrives as a single intact argument" || { echo "got: $launched"; fail "launcher with hostile URL"; }
[ ! -e "$PWN" ] && ok "...and nothing in it was executed" || fail "launcher executed the URL"

# --- list ----------------------------------------------------------------------------------------------
lst=$($X dev --list --export-path "$BO")
echo "$lst" | grep -q '^app  *VSCodium (dev)' && echo "$lst" | grep -q '^bin  *codium' && ok "--list shows apps and bins" || { echo "$lst"; fail "list"; }

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


# --- --shell: a menu entry that opens a terminal inside the Litterbox -------------------------------------------------
LBPATH="$W/bin/litterbox"
SH="$APPS/litterbox-dev-_shell.desktop"
$X dev --shell >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && [ -f "$SH" ] && ok "--shell writes a terminal entry" || fail "--shell rc=$rc"
has "$SH" "Exec=$LBPATH enter dev" && has "$SH" "Terminal=true" && has "$SH" "Type=Application" && ok "it runs 'litterbox enter dev' in a terminal (no command: the login shell gets a tty)" || { cat "$SH"; fail "shell entry content"; }
has "$SH" "Name=Litterbox shell: dev" && has "$SH" "Icon=utilities-terminal" && has "$SH" "X-Litterbox-Export=dev" && has "$SH" "X-Litterbox-Source=@shell" && ok "named, iconed and marked as ours" || fail "shell entry metadata"
sumA=$(sha256sum "$SH" | cut -d' ' -f1); $X dev --shell >/dev/null 2>&1; [ "$sumA" = "$(sha256sum "$SH" | cut -d' ' -f1)" ] && ok "--shell is idempotent" || fail "shell idempotent"
lst=$($X dev --list --export-path "$BO")
echo "$lst" | grep -q '^shell  *Litterbox shell: dev' && ok "--list shows it as a shell entry" || { echo "$lst"; fail "list shell"; }
$X dev --shell --wrap x >/dev/null 2>&1 && fail "--shell with --wrap accepted" || ok "--shell rejects --wrap/--boxed"
$X dev --shell --boxed >/dev/null 2>&1 && fail "--shell with --boxed accepted" || ok "--shell rejects --boxed"
$X dev --shell --app codium >/dev/null 2>&1 && fail "--shell with --app accepted" || ok "--shell cannot be combined with another mode"
$X dev --shell --url-handler >/dev/null 2>&1 && fail "--shell with --url-handler accepted" || ok "--shell rejects --url-handler"
$X '../x' --shell >/dev/null 2>&1 && fail "bad name accepted for --shell" || ok "--shell validates the Litterbox name"
printf 'mine\n' > "$APPS/litterbox-other-_shell.desktop"
$X other --shell >/dev/null 2>&1 && fail "--shell overwrote a foreign file" || { [ "$(cat "$APPS/litterbox-other-_shell.desktop")" = mine ] && ok "--shell never overwrites a file it did not create"; }
$X other --shell --delete >/dev/null 2>&1 && fail "--shell --delete removed a foreign file" || { [ "$(cat "$APPS/litterbox-other-_shell.desktop")" = mine ] && ok "--shell --delete never removes a file it did not create"; }
$X dev --shell --delete >/dev/null 2>&1; [ ! -e "$SH" ] && ok "--shell --delete removes the entry" || fail "shell delete"
$X dev --shell --delete >/dev/null 2>&1 && fail "second --shell --delete succeeded" || ok "deleting a missing terminal entry fails clearly"

[ "$FAILED" = 0 ] && echo "ALL PASSED" || { echo "SOME FAILED"; exit 1; }
