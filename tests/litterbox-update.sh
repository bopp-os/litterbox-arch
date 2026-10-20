#!/bin/sh
# Tests for litterbox-update. The stub `litterbox` behaves like the real one where it matters: it joins the
# words after `--` with single spaces, WITHOUT quoting, and lets a shell re-parse the result (lbx-init does
# `$SHELL -l -c "<command> <args...>"`). The "container" has a fixture os-release and fake package managers
# that only log what they were asked to do.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/litterbox-sandbox-addons/litterbox-update"
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
FAILED=0
ok() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAILED=1; }

BIN="$W/bin"; FIX="$W/container-path"; OSREL="$W/os-release"; PM_LOG="$W/pm.log"; LBXLOG="$W/litterbox.log"
mkdir -p "$BIN" "$FIX" "$W/home/Litterbox/definitions" "$W/fishhome"
FISH_HOME="$W/fishhome"; export FISH_HOME
ln -s "$(command -v grep)" "$FIX/grep"
ln -s /bin/sh "$FIX/sh"        # a real container has sh on its PATH

cat > "$BIN/litterbox" <<'EOF'
#!/bin/sh
echo "litterbox $*" >> "$LBXLOG"
[ "$1" = enter ] || exit 2
name=$2; shift 2
while [ $# -gt 0 ]; do
  case $1 in
    --root) ;;
    --tty|--interactive) shift ;;
    --) shift; break ;;
  esac
  shift
done
[ "$name" != missing ] || { echo "No container found for 'missing'" >&2; exit 1; }
line=''
for a in "$@"; do line="$line $a"; done          # joined with single spaces, no quoting
line=$(printf '%s' "$line" | sed "s|/etc/os-release|$OSREL|g")
if [ "${CONTAINER_SHELL:-sh}" = fish ]; then
  exec env -i PATH="$FIX" HOME="$FISH_HOME" PM_LOG="$PM_LOG" FAKE_PM_RC="${FAKE_PM_RC:-}" FAKE_PACMAN_SANDBOX="${FAKE_PACMAN_SANDBOX:-}" "$FISH" -l -c "$line"
fi
exec env -i PATH="$FIX" PM_LOG="$PM_LOG" FAKE_PM_RC="${FAKE_PM_RC:-}" FAKE_PACMAN_SANDBOX="${FAKE_PACMAN_SANDBOX:-}" /bin/sh -c "$line"
EOF
chmod +x "$BIN/litterbox"

mk_pm() { # a fake package manager that logs its arguments
  cat > "$FIX/$1" <<EOF
#!/bin/sh
if [ "\$1" = --help ]; then
  echo "usage: $1 <operation> [...]"
  exit 0
fi
if [ "\$1" = -S ] && [ "\$2" = --help ]; then # like real pacman, the sandbox options are only listed here
  echo "usage: $1 {-S --sync} [options] [package(s)]"
  # FAKE_PACMAN_SANDBOX: 1 = pacman 7.0 (--disable-sandbox), 2 = pacman 7.1 (also --disable-sandbox-network)
  [ -z "\${FAKE_PACMAN_SANDBOX:-}" ] || echo "      --disable-sandbox"
  [ "\${FAKE_PACMAN_SANDBOX:-}" != 2 ] || echo "      --disable-sandbox-network"
  exit 0
fi
echo "$1 \$*\${DEBIAN_FRONTEND:+ DEBIAN_FRONTEND=\$DEBIAN_FRONTEND}" >> "\$PM_LOG"
exit "\${FAKE_PM_RC:-0}"
EOF
  chmod +x "$FIX/$1"
}
container() { # container 'os-release text' pm...
  printf '%s\n' "$1" > "$OSREL"; shift
  for p in pacman apt-get dnf dnf5 zypper; do rm -f "$FIX/$p"; done
  for p in "$@"; do mk_pm "$p"; done
  : > "$PM_LOG"; : > "$LBXLOG"
}
# EXTRA holds one VAR=value for the next run only (a plain `VAR=x function` leaks in POSIX-mode bash).
EXTRA=''
run_update() {
  out=$(env ${EXTRA:+"$EXTRA"} PATH="$BIN:$PATH" LBXLOG="$LBXLOG" OSREL="$OSREL" PM_LOG="$PM_LOG" FIX="$FIX" HOME="$W/home" \
        sh "$SCRIPT" "$@" 2>&1); rc=$?
  EXTRA=''
}
pm_log_is() { [ "$(cat "$PM_LOG")" = "$1" ]; }
final_call() { grep -c "^litterbox enter $1 --root -- sh -c '$2'\$" "$LBXLOG"; }

OS_CACHY='NAME="CachyOS Linux"
ID=cachyos
ID_LIKE=arch
VERSION_ID=20251001'

# --- every supported family ------------------------------------------------------------------------------------------
container "$OS_CACHY" pacman; run_update dev
[ "$rc" = 0 ] && pm_log_is "pacman -Syu --noconfirm" && ok "CachyOS: pacman -Syu --noconfirm" || { echo "$out"; fail "cachyos (rc=$rc)"; }
[ "$(final_call dev "pacman -Syu --noconfirm")" = 1 ] && ok "sent as one argument: sh -c '...' via litterbox enter dev --root --" || { cat "$LBXLOG"; fail "call shape"; }
echo "$out" | grep -q '==> dev: cachyos 20251001 -> pacman (arch family)' && ok "reports what it detected" || { echo "$out"; fail "report line"; }

container 'ID=arch' pacman; run_update dev
pm_log_is "pacman -Syu --noconfirm" && ok "Arch (no ID_LIKE)" || fail "arch"

container 'ID=ubuntu
ID_LIKE=debian
VERSION_ID="24.04"' apt-get; run_update dev
[ "$(cat "$PM_LOG")" = "apt-get update DEBIAN_FRONTEND=noninteractive
apt-get -y upgrade DEBIAN_FRONTEND=noninteractive" ] && ok "Ubuntu: apt-get update, then apt-get -y upgrade, both non-interactive" || { cat "$PM_LOG"; fail "ubuntu"; }
grep -q "^litterbox enter dev --root -- sh -c 'export DEBIAN_FRONTEND=noninteractive; apt-get update && apt-get -y upgrade'$" "$LBXLOG" && ok "apt command line reaches the container intact" || { cat "$LBXLOG"; fail "apt call shape"; }

container 'ID=debian' apt-get; run_update dev
grep -q '^apt-get -y upgrade' "$PM_LOG" && ok "Debian" || fail "debian"

container 'ID=fedora
VERSION_ID=42' dnf; run_update dev
pm_log_is "dnf -y upgrade --refresh" && ok "Fedora: dnf -y upgrade --refresh" || { cat "$PM_LOG"; fail "fedora"; }
container 'ID=fedora' dnf dnf5; run_update dev
pm_log_is "dnf -y upgrade --refresh" && ok "Fedora with both dnf and dnf5 prefers dnf" || fail "dnf preference"
container 'ID=fedora' dnf5; run_update dev
pm_log_is "dnf5 -y upgrade --refresh" && ok "Fedora with only dnf5 uses dnf5" || fail "dnf5"
container 'ID="rocky"
ID_LIKE="rhel centos fedora"' dnf; run_update dev
pm_log_is "dnf -y upgrade --refresh" && ok "Rocky (quoted ID, ID_LIKE list) is the Fedora family" || fail "rocky"

container 'ID="opensuse-tumbleweed"
ID_LIKE="opensuse suse"' zypper; run_update dev
[ "$(cat "$PM_LOG")" = "zypper --non-interactive refresh
zypper --non-interactive dup" ] && ok "Tumbleweed: refresh, then dup" || { cat "$PM_LOG"; fail "tumbleweed"; }
container 'ID="opensuse-leap"
ID_LIKE="suse opensuse"
VERSION_ID="15.6"' zypper; run_update dev
[ "$(cat "$PM_LOG")" = "zypper --non-interactive refresh
zypper --non-interactive up" ] && ok "Leap: refresh, then up (not dup)" || { cat "$PM_LOG"; fail "leap"; }

container 'ID="CachyOS"' pacman; run_update dev
pm_log_is "pacman -Syu --noconfirm" && ok "mixed-case quoted ID is recognised" || fail "case folding"

# --- fallbacks and refusals --------------------------------------------------------------------------------------------------
container 'ID=weirdos' apt-get; run_update dev
echo "$out" | grep -q "not recognised" && grep -q '^apt-get -y upgrade' "$PM_LOG" && ok "unknown distribution: falls back to the package manager it finds" || { echo "$out"; fail "fallback"; }
container 'ID=weirdos'; run_update dev
[ "$rc" = 1 ] && echo "$out" | grep -q 'no supported package manager' && [ "$(wc -l < "$LBXLOG")" = 1 ] && ok "no package manager at all: error, and no update attempted" || { echo "$out"; fail "no pm"; }
container 'ID=ubuntu' pacman; run_update dev
[ "$rc" = 1 ] && echo "$out" | grep -q 'debian-family system' && [ ! -s "$PM_LOG" ] && ok "known family without its package manager: error, never guesses another" || { echo "$out"; fail "family mismatch"; }

# --- hostile os-release ---------------------------------------------------------------------------------------------------------
container 'ID=$(touch '"$W"'/PWN)
ID_LIKE=arch; touch '"$W"'/PWN2' pacman; run_update dev
[ ! -e "$W/PWN" ] && [ ! -e "$W/PWN2" ] && ok "shell syntax in os-release is never executed" || fail "os-release was executed"
pm_log_is "pacman -Syu --noconfirm" && ok "...and only a fixed command from the table runs" || { cat "$PM_LOG"; fail "hostile run"; }
container "ID=arch$(printf '\033[31m')$(printf 'x%.0s' $(seq 1 300))" pacman; run_update dev
echo "$out" | grep -q "$(printf '\033')" && fail "control characters reached the terminal" || ok "control characters are stripped before printing"
[ "$(echo "$out" | grep -c 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx')" = 0 ] && ok "overlong values are cut" || fail "long value"

# --- dry run, options --------------------------------------------------------------------------------------------------------------
container "$OS_CACHY" pacman; run_update --dry-run dev
[ "$rc" = 0 ] && [ ! -s "$PM_LOG" ] && echo "$out" | grep -q 'would run as root: pacman -Syu --noconfirm' && [ "$(wc -l < "$LBXLOG")" = 1 ] && ok "--dry-run looks, prints, changes nothing" || { echo "$out"; fail "dry run"; }

container "$OS_CACHY" pacman; EXTRA=FAKE_PACMAN_SANDBOX=1; run_update --no-sandbox dev
pm_log_is "pacman -Syu --noconfirm --disable-sandbox" && ok "--no-sandbox adds --disable-sandbox when pacman supports it" || { cat "$PM_LOG"; fail "no-sandbox"; }
container "$OS_CACHY" pacman; EXTRA=FAKE_PACMAN_SANDBOX=2; run_update dev
pm_log_is "pacman -Syu --noconfirm --disable-sandbox-network" && ok "pacman 7.1: --disable-sandbox-network is added so hooks run in a rootless box" || { cat "$PM_LOG"; fail "sandbox network"; }
container "$OS_CACHY" pacman; EXTRA=FAKE_PACMAN_SANDBOX=1; run_update dev
pm_log_is "pacman -Syu --noconfirm" && ok "pacman 7.0: no --disable-sandbox-network (it does not have it)" || { cat "$PM_LOG"; fail "sandbox network 7.0"; }
container "$OS_CACHY" pacman; EXTRA=FAKE_PACMAN_SANDBOX=2; run_update --no-sandbox dev
pm_log_is "pacman -Syu --noconfirm --disable-sandbox --disable-sandbox-network" && ok "pacman 7.1 with --no-sandbox gets both options" || { cat "$PM_LOG"; fail "no-sandbox 7.1"; }
container "$OS_CACHY" pacman; run_update --no-sandbox dev
[ "$rc" = 1 ] && echo "$out" | grep -q 'no --disable-sandbox option' && [ ! -s "$PM_LOG" ] && ok "--no-sandbox is refused when pacman does not support it" || fail "no-sandbox unsupported"
container 'ID=ubuntu' apt-get; run_update --no-sandbox dev
echo "$out" | grep -q 'only applies to pacman' && grep -q 'apt-get -y upgrade' "$PM_LOG" && ok "--no-sandbox on apt is ignored with a note" || fail "no-sandbox on apt"

# --- failures and several Litterboxes ------------------------------------------------------------------------------------------------
container "$OS_CACHY" pacman; EXTRA=FAKE_PM_RC=3; run_update dev
[ "$rc" = 1 ] && echo "$out" | grep -q "the update in 'dev' failed" && ok "a failing update gives a non-zero exit and says so" || { echo "$out"; fail "failure propagation"; }
container "$OS_CACHY" pacman; run_update missing dev
[ "$rc" = 1 ] && grep -q '^pacman -Syu' "$PM_LOG" && echo "$out" | grep -q 'failed for: missing' && ok "one broken Litterbox does not stop the others" || { echo "$out"; fail "multi"; }
printf 'FROM x\n' > "$W/home/Litterbox/definitions/alpha.Dockerfile"; printf 'FROM y\n' > "$W/home/Litterbox/definitions/beta.Dockerfile"; echo junk > "$W/home/Litterbox/definitions/notes.txt"
container "$OS_CACHY" pacman; run_update --all
[ "$rc" = 0 ] && [ "$(grep -c '^pacman -Syu' "$PM_LOG")" = 2 ] && grep -q 'enter alpha --root' "$LBXLOG" && grep -q 'enter beta --root' "$LBXLOG" && ok "--all updates every defined Litterbox (and ignores other files)" || { echo "$out"; fail "--all"; }
run_update --all dev; [ "$rc" != 0 ] && ok "--all together with names is refused" || fail "--all + names"

# --- input checks --------------------------------------------------------------------------------------------------------------------------
for bad in '../x' 'a b' '.hidden' 'x;ls' '$(id)'; do
  container "$OS_CACHY" pacman; run_update "$bad"
  [ "$rc" != 0 ] && [ ! -s "$LBXLOG" ] && ok "name '$bad' is rejected before anything runs" || fail "accepted name '$bad'"
done
run_update; [ "$rc" = 1 ] && echo "$out" | grep -q '^Usage:' && ok "no arguments prints usage" || fail "usage"
run_update --help >/dev/null; [ "$rc" = 0 ] && ok "--help exits 0" || fail "help"
run_update --bogus dev; [ "$rc" != 0 ] && ok "unknown option is refused" || fail "unknown option"
out=$(env PATH="/usr/bin:/bin" HOME="$W/home" sh "$SCRIPT" dev 2>&1); rc=$?
[ "$rc" != 0 ] && echo "$out" | grep -q 'litterbox is not installed' && ok "missing litterbox is a clear error" || fail "missing litterbox"

# --- the container shell must never see backslashes or stray quotes ------------------------------------------------------------------------
container "$OS_CACHY" pacman; run_update dev
container 'ID=ubuntu' apt-get; run_update dev
container 'ID=opensuse-tumbleweed' zypper; run_update dev
cat "$LBXLOG" > "$W/all-calls.log"
container 'ID=fedora' dnf; run_update dev
cat "$LBXLOG" >> "$W/all-calls.log"
if grep -q '\\' "$W/all-calls.log"; then fail "a backslash was sent to the container shell"; else ok "no call contains a backslash (safe for bash and fish)"; fi
bad=$(grep -E "^litterbox enter dev --root -- " "$W/all-calls.log" | grep -v -E "^litterbox enter dev --root -- sh -c '[^']*'\$" || true)
[ -z "$bad" ] && ok "every call is exactly: sh -c '<script without quotes>'" || { echo "$bad"; fail "call shape"; }

# Every default Litterbox template makes fish the login shell, so run the key families through real fish too.
FISH=${FISH:-$(command -v fish || true)}
if [ -n "$FISH" ] && [ -x "$FISH" ]; then
  export FISH
  container "$OS_CACHY" pacman; EXTRA=CONTAINER_SHELL=fish; run_update dev
  [ "$rc" = 0 ] && pm_log_is "pacman -Syu --noconfirm" && ok "fish login shell: Arch family (pacman)" || { echo "$out"; fail "fish pacman"; }
  container 'ID=ubuntu' apt-get; EXTRA=CONTAINER_SHELL=fish; run_update dev
  [ "$rc" = 0 ] && [ "$(cat "$PM_LOG")" = "apt-get update DEBIAN_FRONTEND=noninteractive
apt-get -y upgrade DEBIAN_FRONTEND=noninteractive" ] && ok "fish login shell: Debian family (export; a && b)" || { echo "$out"; cat "$PM_LOG"; fail "fish apt"; }
  container 'ID=fedora' dnf; EXTRA=CONTAINER_SHELL=fish; run_update dev
  [ "$rc" = 0 ] && pm_log_is "dnf -y upgrade --refresh" && ok "fish login shell: Fedora family (dnf)" || { echo "$out"; fail "fish dnf"; }
  container 'ID=opensuse-tumbleweed' zypper; EXTRA=CONTAINER_SHELL=fish; run_update dev
  [ "$rc" = 0 ] && [ "$(cat "$PM_LOG")" = "zypper --non-interactive refresh
zypper --non-interactive dup" ] && ok "fish login shell: openSUSE (a && b)" || { echo "$out"; cat "$PM_LOG"; fail "fish zypper"; }
  container 'ID=weirdos' pacman; EXTRA=CONTAINER_SHELL=fish; run_update --no-sandbox dev
  [ "$rc" = 1 ] && echo "$out" | grep -q 'no --disable-sandbox option' && ok "fish login shell: the probe itself ran under fish and reported what pacman supports" || { echo "$out"; fail "fish probe"; }
else
  echo "SKIP: no fish available (set FISH=/path/to/fish): the fish login shell was not exercised"
fi

[ "$FAILED" = 0 ] && echo "ALL PASSED" || { echo "SOME FAILED"; exit 1; }
