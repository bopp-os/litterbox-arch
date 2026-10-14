#!/bin/sh
# URL-handler tests for litterbox-export (stub podman + stub xdg-mime that writes mimeapps.list like xdg-utils).
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/litterbox-sandbox-addons/litterbox-export"
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin" "$W/xbin" "$W/home" "$W/rootfs"
FAILED=0
ok() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAILED=1; }
has() { grep -qxF -- "$2" "$1"; }

R=$W/rootfs; A=$R/usr/share/applications
mkdir -p "$A"
printf '[Desktop Entry]\nType=Application\nName=Claude\nExec=/usr/bin/claude-desktop %%u\nMimeType=x-scheme-handler/claude;\nIcon=claude\n' > "$A/claude-desktop.desktop"
printf '[Desktop Entry]\nType=Application\nName=NoScheme\nExec=/usr/bin/noscheme\n' > "$A/noscheme.desktop"
printf '[Desktop Entry]\nType=Application\nName=FilesOnly\nExec=/usr/bin/files %%F\nMimeType=text/plain;x-scheme-handler/fileonly;\n' > "$A/filesonly.desktop"
printf '[Desktop Entry]\nType=Application\nName=Browser\nExec=/usr/bin/browser %%U\nMimeType=text/html;x-scheme-handler/http;x-scheme-handler/https;x-scheme-handler/browsercustom;\n' > "$A/browser.desktop"
printf '[Desktop Entry]\nType=Application\nName=NoSemi\nExec=/usr/bin/nosemi %%U\nMimeType=x-scheme-handler/nosemi\n' > "$A/nosemi.desktop"

cat > "$W/bin/podman" <<EOF
#!/bin/sh
ROOTFS="$R"
case "\$1" in
  ps) case "\$*" in *label=work.litterbox.name=dev*) echo cid123abc ;; esac ;;
  cp) src=\${2#*:}; [ "\$3" = - ] || exit 1
      [ -e "\$ROOTFS\$src" ] || { echo "Error: no such path" >&2; exit 125; }
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
sh -c "set -- $line; for w in \"\$@\"; do printf '%s\\n' \"\$w\"; done"
EOF
# xdg-mime lives in xbin so one test can run without it. Like xdg-utils it writes mimeapps.list.
cat > "$W/xbin/xdg-mime" <<'EOF'
#!/bin/sh
[ "$1" = default ] || exit 1
f="${XDG_CONFIG_HOME:-$HOME/.config}/mimeapps.list"; mkdir -p "$(dirname "$f")"; [ -f "$f" ] || printf '[Default Applications]\n' > "$f"
grep -q '^\[Default Applications\]' "$f" || printf '[Default Applications]\n' >> "$f"
grep -v "^$3=" "$f" > "$f.new" || true
awk -v l="$3=$2" '{print} /^\[Default Applications\]/{print l}' "$f.new" > "$f"; rm -f "$f.new"
EOF
chmod +x "$W/bin/"* "$W/xbin/"*
export HOME="$W/home" PATH="$W/bin:$PATH"
unset XDG_DATA_HOME XDG_CONFIG_HOME
command -v xdg-mime >/dev/null 2>&1 && echo "NOTE: a real xdg-mime exists on PATH; the 'no xdg-mime' check below is skipped" && REAL_XDG=1 || REAL_XDG=0
XPATH="$W/xbin:$PATH"
X="sh $SCRIPT"
APPS="$HOME/.local/share/applications"; MA="$HOME/.config/mimeapps.list"
C="$APPS/litterbox-dev-claude-desktop.desktop"

# 1. declared scheme is carried over; nothing registered without --url-handler
out=$(PATH=$XPATH $X dev --app claude-desktop 2>&1)
has "$C" "MimeType=x-scheme-handler/claude;" && ok "declared scheme kept in MimeType" || fail "mime kept"
grep -q '^Exec=.* /usr/bin/claude-desktop %u$' "$C" && ok "%u kept in Exec so the URL is passed" || fail "%u"
[ ! -e "$MA" ] && ok "nothing registered without --url-handler" || fail "registered by default"
echo "$out" | grep -q 'URL schemes in this launcher: claude' && echo "$out" | grep -q -- '--url-handler' && ok "output names the scheme and the flag" || { echo "$out"; fail "hint"; }

# 2. --url-handler registers
PATH=$XPATH $X dev --app claude-desktop --url-handler >/dev/null 2>&1
has "$MA" "x-scheme-handler/claude=litterbox-dev-claude-desktop.desktop" && ok "--url-handler registers x-scheme-handler/claude" || { cat "$MA"; fail "register"; }

# 3. delete unregisters, keeps everything else
printf '[Default Applications]\ntext/html=firefox.desktop;\nx-scheme-handler/claude=litterbox-dev-claude-desktop.desktop;other.desktop;\n\n[Added Associations]\nx-scheme-handler/claude=litterbox-dev-claude-desktop.desktop;\nfoo/bar=baz.desktop;\n' > "$MA"
PATH=$XPATH $X dev --app claude-desktop --delete >/dev/null 2>&1
[ ! -e "$C" ] && has "$MA" "x-scheme-handler/claude=other.desktop;" && has "$MA" "text/html=firefox.desktop;" && has "$MA" "foo/bar=baz.desktop;" && ok "delete removes only our entry from [Default Applications]" || { cat "$MA"; fail "unregister"; }
# the [Added Associations] copy is not in [Default Applications], so it is deliberately left alone
has "$MA" "x-scheme-handler/claude=litterbox-dev-claude-desktop.desktop;" && ok "[Added Associations] untouched" || fail "added assoc"

# 3b. default pointing elsewhere -> mimeapps.list byte-identical after delete
PATH=$XPATH $X dev --app claude-desktop >/dev/null 2>&1
printf '[Default Applications]\nx-scheme-handler/claude=someone-else.desktop;\n' > "$MA"; before=$(sha256sum "$MA" | cut -d' ' -f1)
PATH=$XPATH $X dev --app claude-desktop --delete >/dev/null 2>&1
[ "$before" = "$(sha256sum "$MA" | cut -d' ' -f1)" ] && ok "delete leaves a default that points at another app untouched" || fail "touched foreign default"
leaked=$(find "$HOME/.config" -name 'mimeapps.list.*')
[ -z "$leaked" ] && ok "no temp files left behind" || fail "temp file left behind: $leaked"

# 4. --scheme on an app that declares none: MimeType added, %U appended
rm -f "$MA"
PATH=$XPATH $X dev --app noscheme --scheme myapp --url-handler >/dev/null 2>&1
N="$APPS/litterbox-dev-noscheme.desktop"
has "$N" "MimeType=x-scheme-handler/myapp;" && grep -q '^Exec=.* /usr/bin/noscheme %U$' "$N" && ok "--scheme adds MimeType and appends %U" || { grep -E '^(Exec|MimeType)' "$N"; fail "--scheme"; }
has "$MA" "x-scheme-handler/myapp=litterbox-dev-noscheme.desktop" && ok "--scheme + --url-handler registers it" || fail "scheme register"

# 5. --scheme for an already declared scheme does not duplicate; repeatable
PATH=$XPATH $X dev --app claude-desktop --scheme claude --scheme second >/dev/null 2>&1
has "$C" "MimeType=x-scheme-handler/claude;x-scheme-handler/second;" && ok "no duplicate scheme, repeatable --scheme" || { grep MimeType "$C"; fail "dup"; }
# 5b. missing trailing semicolon is normalised
PATH=$XPATH $X dev --app nosemi --scheme extra >/dev/null 2>&1
has "$APPS/litterbox-dev-nosemi.desktop" "MimeType=x-scheme-handler/nosemi;x-scheme-handler/extra;" && ok "MimeType without trailing ';' normalised" || fail "semicolon"

# 6. file-only Exec cannot take URLs: scheme dropped, other MIME kept, warning shown
out=$(PATH=$XPATH $X dev --app filesonly --url-handler 2>&1)
F="$APPS/litterbox-dev-filesonly.desktop"
has "$F" "MimeType=text/plain;" && ! grep -q 'x-scheme-handler' "$F" && echo "$out" | grep -q 'only accepts files' && ok "file-only app does not claim URL schemes" || { echo "$out"; grep MimeType "$F"; fail "files-only"; }
! grep -q fileonly "$MA" && ok "file-only scheme not registered" || fail "fileonly registered"

# 7. browser-level schemes are never registered
out=$(PATH=$XPATH $X dev --app browser --url-handler 2>&1)
echo "$out" | grep -q 'Skipped http://' && echo "$out" | grep -q 'Skipped https://' && ok "http/https skipped with an explanation" || { echo "$out"; fail "skip msg"; }
! grep -qE '^x-scheme-handler/https?=' "$MA" && has "$MA" "x-scheme-handler/browsercustom=litterbox-dev-browser.desktop" && ok "only the non-browser scheme was registered" || { cat "$MA"; fail "browser registration"; }

# 8. no xdg-mime: the launcher is still written, with a warning, exit 0
if [ "$REAL_XDG" = 0 ]; then
  out=$($X dev --app claude-desktop --url-handler 2>&1); rc=$?
  [ "$rc" = 0 ] && [ -f "$C" ] && echo "$out" | grep -q 'xdg-mime not found' && ok "missing xdg-mime is a warning, launcher still written" || { echo "rc=$rc $out"; fail "no xdg-mime"; }
else
  echo "SKIP: missing-xdg-mime check (real xdg-mime is installed)"
fi

# 9. validation
for bad in 'Bad' 'a b' '1x' 'x;y' 'x/y' ''; do
  $X dev --app claude-desktop --scheme "$bad" >/dev/null 2>&1 && fail "scheme '$bad' accepted" || ok "scheme '$bad' rejected"
done
$X dev --bin foo --scheme x >/dev/null 2>&1 && fail "--scheme allowed with --bin" || ok "--scheme rejected with --bin"
$X dev --list --url-handler >/dev/null 2>&1 && fail "--url-handler allowed with --list" || ok "--url-handler rejected with --list"


# 10. A real OAuth callback must survive the trip into the sandbox. The launcher goes through litterbox-export --exec,
#     because Litterbox itself joins arguments with plain spaces and the container's shell re-parses them: a bare
#     "claude://cb?code=1&state=2" would be cut at the "&", and a hostile link could run commands.
PATH=$XPATH $X dev --app claude-desktop --boxed >/dev/null 2>&1
execline=$(sed -n 's/^Exec=//p' "$C")
url="claude://login/callback?code=abc&state=xyz%20q;touch $W/PWN\$(touch $W/PWN)"
set -f; set -- $execline; set +f
launched=$(for t in "$@"; do [ "$t" = %u ] && printf '%s\0' "$url" || printf '%s\0' "$t"; done | xargs -0 sh -c '"$@"' _ | tr '\n' '|')
[ "$launched" = "enter dev|boxed-run|/usr/bin/claude-desktop|$url|" ] && ok "OAuth-style URL reaches the app as one intact argument" || { echo "got: $launched"; fail "oauth url"; }
[ ! -e "$W/PWN" ] && ok "a hostile URL is not executed by the container shell" || fail "URL was executed"

[ "$FAILED" = 0 ] && echo "ALL PASSED" || { echo "SOME FAILED"; exit 1; }
