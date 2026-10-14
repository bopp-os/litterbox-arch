#!/bin/sh
# Stubbed behavioural test for boxed-run (dbus-run-session, gnome-keyring-daemon and gsettings are
# replaced by stubs, so this checks our wrapper logic, not the real keyring). Needs `script` (util-linux).
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/litterbox-sandbox-addons/boxed-run"
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin" "$W/home"
ok() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAILED=1; }
FAILED=0

# --- stubs ---------------------------------------------------------------------------------
cat > "$W/bin/dbus-run-session" <<'EOF'
#!/bin/sh
shift   # drop "--"
exec "$@"
EOF
cat > "$W/bin/gnome-keyring-daemon" <<'EOF'
#!/bin/sh
# Mimic an older gnome-keyring that also exports its own ssh agent socket.
case " $* " in
  *" --login "*) cat >/dev/null
                 echo "GNOME_KEYRING_CONTROL=/run/stub/keyring; export GNOME_KEYRING_CONTROL"
                 echo "SSH_AUTH_SOCK=/evil/keyring-ssh.sock; export SSH_AUTH_SOCK" ;;
  *)             echo "GNOME_KEYRING_CONTROL=/run/stub/keyring; export GNOME_KEYRING_CONTROL" ;;
esac
EOF
printf '#!/bin/sh\nexit 0\n' > "$W/bin/gsettings"
cp "$SCRIPT" "$W/bin/boxed-run"
chmod +x "$W/bin/"*
export PATH="$W/bin:$PATH" HOME="$W/home"

run() { boxed-run "$@" </dev/null 2>&1 | tr -d '\r'; }   # stdin is not a tty -> exercises the pty re-exec

# --- usage ---------------------------------------------------------------------------------
out=$(boxed-run 2>&1); rc=$?
[ "$rc" = 1 ] && echo "$out" | grep -q '^Usage: boxed-run' && ok "no args prints usage, exit 1" || fail "usage (rc=$rc)"

# --- SSH_AUTH_SOCK guard -------------------------------------------------------------------
out=$(SSH_AUTH_SOCK=/litterbox/agent.sock run sh -c 'echo "SOCK=[$SSH_AUTH_SOCK]"')
[ "$out" = "SOCK=[/litterbox/agent.sock]" ] && ok "Litterbox SSH_AUTH_SOCK survives gnome-keyring" || fail "guard kept socket: got '$out'"

out=$(env -u SSH_AUTH_SOCK sh -c 'boxed-run sh -c '\''echo "SOCK=[${SSH_AUTH_SOCK-unset}]"'\'' </dev/null 2>&1' | tr -d '\r')
[ "$out" = "SOCK=[unset]" ] && ok "unset stays unset (keyring socket not leaked in)" || fail "guard unset: got '$out'"

# --- argument quoting through the pty re-exec ----------------------------------------------
out=$(run printf '%s|' 'a b' "it's" '$HOME' '"dq"')
[ "$out" = "a b|it's|\$HOME|\"dq\"|" ] && ok "arguments with spaces/quotes/\$ survive the pty re-exec" || fail "quoting: got '$out'"

# --- exit code -----------------------------------------------------------------------------
boxed-run sh -c 'exit 7' </dev/null >/dev/null 2>&1; rc=$?
[ "$rc" = 7 ] && ok "child exit code propagates (7)" || fail "exit code: $rc"

# --- keyring bootstrap ---------------------------------------------------------------------
[ "$(cat "$HOME/.local/share/keyrings/default" 2>/dev/null)" = "login" ] && ok "default keyring alias set to 'login'" || fail "default alias"
echo existing > "$HOME/.local/share/keyrings/default"
run true >/dev/null
[ "$(cat "$HOME/.local/share/keyrings/default")" = "existing" ] && ok "existing default alias is not overwritten" || fail "alias overwritten"

# --- the test is meaningful: strip the guard and the leak must appear -----------------------
sed '/^  if \[ -n "\$lbx_ssh_auth_sock" \]; then$/,/^  fi$/d' "$SCRIPT" > "$W/bin/boxed-run"
chmod +x "$W/bin/boxed-run"
dash -n "$W/bin/boxed-run" 2>/dev/null || sh -n "$W/bin/boxed-run" || fail "control script is not valid sh"
grep -q 'SSH_AUTH_SOCK="\$lbx' "$W/bin/boxed-run" && fail "control still contains the guard"
out=$(SSH_AUTH_SOCK=/litterbox/agent.sock run sh -c 'echo "SOCK=[$SSH_AUTH_SOCK]"')
[ "$out" = "SOCK=[/evil/keyring-ssh.sock]" ] && ok "control: without the guard the keyring socket DOES shadow the agent" || fail "control run: got '$out'"

[ "$FAILED" = 0 ] && echo "ALL PASSED" || { echo "SOME FAILED"; exit 1; }
