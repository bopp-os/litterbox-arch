#!/bin/sh
# Tests for litterbox-assemble, run against upstream Litterbox's real Dockerfile templates (v0.6.5, fetched
# from GitHub: needs network) and the real litterbox-addon for the addon block.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC="$ROOT/litterbox-sandbox-addons"
SCRIPT="$SRC/litterbox-assemble"
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
FAILED=0
ok() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAILED=1; }

TPL="$W/templates"; LBX="$W/lbx"; BIN="$W/bin"; DEFS="$LBX/definitions"
mkdir -p "$TPL" "$BIN" "$W/addons/boxed-run" "$W/home"
for t in cachyos fedora tumbleweed ubuntu-latest; do
  curl -fsSL "https://raw.githubusercontent.com/Gerharddc/litterbox/v0.6.5/litterbox/templates/$t.Dockerfile" -o "$TPL/$t.Dockerfile" || { echo "FAIL: cannot fetch template $t (needs network)"; exit 1; }
done
# The CachyOS CPU-variant templates that litterbox-sandbox's patch adds: upstream's cachyos template with another base image.
sed 's#^FROM .*#FROM ghcr.io/bopp-os/cachyos-docker/cachyos-znver4:latest#' "$TPL/cachyos.Dockerfile" > "$TPL/cachyos-znver4.Dockerfile"
sed 's#^FROM .*#FROM docker.io/cachyos/cachyos-v4:latest#' "$TPL/cachyos.Dockerfile" > "$TPL/cachyos-v4.Dockerfile"
cp "$SRC/boxed-run" "$SRC/boxed-run.packages.arch" "$W/addons/boxed-run/"; mv "$W/addons/boxed-run/boxed-run.packages.arch" "$W/addons/boxed-run/packages.arch"
printf '#!/bin/sh\necho "litterbox $*" >> "%s/litterbox.log"\n' "$W" > "$BIN/litterbox"; chmod +x "$BIN/litterbox"

EXTRA=''
run() { # run ARGS... -> $out, $rc
  out=$(env ${EXTRA:+"$EXTRA"} LITTERBOX_ROOT="$LBX" LITTERBOX_TEMPLATE_DIR="$TPL" LITTERBOX_ADDONS_DIR="$W/addons" \
        LITTERBOX_ADDON="$SRC/litterbox-addon" HOME="$W/home" PATH="$BIN:$PATH" sh "$SCRIPT" "$@" 2>&1); rc=$?
  EXTRA=''
}
clean() { rm -rf "$LBX"; mkdir -p "$DEFS"; : > "$W/litterbox.log"; rm -f "$W/PWN"; }
written() { find "$DEFS" -type f | wc -l | tr -d ' '; }
has() { grep -qxF -- "$2" "$1"; }

# --- defaults: the template, untouched, and the most isolated settings -----------------------------------------------
clean; run web
[ "$rc" = 0 ] && cmp -s "$DEFS/web.Dockerfile" "$TPL/cachyos.Dockerfile" && ok "no packages or addons: the Dockerfile is upstream's template, byte for byte" || { echo "$out"; fail "default dockerfile"; }
ron_ok=1
for line in '(' '    version: 1,' '    support_ping: false,' '    support_tuntap: false,' '    packet_forwarding: false,' '    expose_pipewire: false,' \
            '    keep_groups: false,' '    enable_kvm: false,' '    expose_kfd: false,' '    unconfine_seccomp: false,' '    unconfine_landlock: false,' \
            '    shm_size_gb: None,' '    network_mode: Pasta,' '    custom_podman_args: None,' ')'; do
  has "$DEFS/web.ron" "$line" || { ron_ok=0; echo "missing RON line: $line"; }
done
[ "$ron_ok" = 1 ] && ok "web.ron holds every field of Litterbox's settings, all at the isolated defaults" || fail "default ron"
echo "$out" | grep -q 'Next: litterbox build web' && ! echo "$out" | grep -q 'widen' && ok "tells you the next step; nothing widened, nothing flagged" || { echo "$out"; fail "default message"; }

# --- packages + addons -----------------------------------------------------------------------------------------------------
clean; run dev -p git -p "neovim ripgrep" -p git -a boxed-run
[ "$rc" = 0 ] || { echo "$out"; fail "dev rc=$rc"; }
size=$(wc -c < "$TPL/cachyos.Dockerfile")
[ "$(head -c "$size" "$DEFS/dev.Dockerfile")" = "$(cat "$TPL/cachyos.Dockerfile")" ] && ok "the template text comes first, unchanged" || fail "template prefix"
has "$DEFS/dev.Dockerfile" 'RUN pacman -S --noconfirm --needed git neovim ripgrep' && ok "packages: one RUN line, sorted, duplicates removed" || { tail -8 "$DEFS/dev.Dockerfile"; fail "package line"; }
pk=$(grep -n '^# >>> litterbox-assemble packages >>>$' "$DEFS/dev.Dockerfile" | cut -d: -f1); ad=$(grep -n '^# >>> litterbox-addons >>>$' "$DEFS/dev.Dockerfile" | cut -d: -f1)
[ -n "$pk" ] && [ -n "$ad" ] && [ "$pk" -lt "$ad" ] && ok "packages block, then the addon block (both marked)" || fail "block order ($pk/$ad)"
sh "$SRC/litterbox-addon" remove dev >/dev/null 2>&1 || true
env LITTERBOX_ROOT="$LBX" sh "$SRC/litterbox-addon" remove dev >/dev/null 2>&1
grep -q 'litterbox-addons' "$DEFS/dev.Dockerfile" && has "$DEFS/dev.Dockerfile" 'RUN pacman -S --noconfirm --needed git neovim ripgrep' && fail "litterbox-addon remove did not cleanly remove just its block" || ok "litterbox-addon remove takes out its block and leaves ours (the tools cooperate)"

# --- the other families --------------------------------------------------------------------------------------------------------
clean; run f -t fedora -p htop;          has "$DEFS/f.Dockerfile" 'RUN dnf install -y htop' && ok "fedora: dnf install -y" || { echo "$out"; fail "fedora"; }
clean; run u -t ubuntu-latest -p htop;   has "$DEFS/u.Dockerfile" 'RUN DEBIAN_FRONTEND=noninteractive apt-get install -y htop' && ok "ubuntu: non-interactive apt-get install -y" || { echo "$out"; fail "ubuntu"; }
clean; run t -t tumbleweed -p htop;      has "$DEFS/t.Dockerfile" 'RUN zypper in -y htop' && ok "tumbleweed: zypper in -y (same as upstream's template)" || { echo "$out"; fail "tumbleweed"; }
clean; run u -t ubuntu-latest -a boxed-run
[ "$rc" != 0 ] && echo "$out" | grep -q 'cachyos template only' && [ "$(written)" = 0 ] && ok "addons on a non-Arch template: refused, nothing written" || { echo "$out"; fail "addon on ubuntu"; }

# --- settings ----------------------------------------------------------------------------------------------------------------------
clean; run s -s expose_pipewire=true -s network_mode=PastaBidirectional -s shm_size_gb=8 -s support_ping=true -s support_ping=false
has "$DEFS/s.ron" '    expose_pipewire: true,' && has "$DEFS/s.ron" '    network_mode: PastaBidirectional,' && has "$DEFS/s.ron" '    shm_size_gb: Some(8),' && has "$DEFS/s.ron" '    support_ping: false,' \
  && ok "settings land in the .ron (the last --set for a key wins)" || { cat "$DEFS/s.ron"; fail "settings"; }
echo "$out" | grep -q 'widen what this sandbox can reach: expose_pipewire network_mode=PastaBidirectional' && ok "settings that widen access are listed" || { echo "$out"; fail "widen list"; }
open=$(grep -c '^(' "$DEFS/s.ron"); close=$(grep -c '^)' "$DEFS/s.ron"); [ "$open" = 1 ] && [ "$close" = 1 ] && ok ".ron is one balanced struct" || fail "ron structure"
clean; EXTRA=XDG_RUNTIME_DIR=/nonexistent; run k -s enable_kvm=true
if [ -e /dev/kvm ]; then ! echo "$out" | grep -q 'warning: enable_kvm' && ok "enable_kvm with /dev/kvm present: no warning" || fail "kvm warning"; else echo "$out" | grep -q 'warning: enable_kvm is on but /dev/kvm does not exist' && ok "enable_kvm without /dev/kvm on this host: warned" || { echo "$out"; fail "kvm warning missing"; }; fi

# --- refusals: bad input writes nothing and never executes anything --------------------------------------------------------------
refuse() { # refuse DESC ARGS...
  desc=$1; shift; clean; run "$@"
  if [ "$rc" != 0 ] && [ "$(written)" = 0 ] && [ ! -e "$W/PWN" ]; then ok "refused: $desc"; else echo "$out"; fail "not refused: $desc (rc=$rc, files=$(written))"; fi
}
refuse "unknown template" x -t nope
refuse "template with shell syntax" x -t 'cachyos;ls'
refuse "package with a semicolon" x -p "git;touch $W/PWN"
refuse "package with command substitution" x -p "\$(touch $W/PWN)"
refuse "package with a leading dash" x -p -rf
refuse "unknown setting" x -s bogus=1
refuse "setting without a value" x -s expose_pipewire
refuse "boolean that is not true/false" x -s expose_pipewire=yes
refuse "unknown network mode" x -s network_mode=Bridge
refuse "shm size zero" x -s shm_size_gb=0
refuse "shm size absurd" x -s shm_size_gb=99999
refuse "shm size not a number" x -s shm_size_gb=abc
refuse "custom_podman_args" x -s custom_podman_args=--privileged
refuse "version override" x -s version=2
refuse "setting value with shell syntax" x -s "expose_pipewire=true\$(touch $W/PWN)"
refuse "unknown addon" x -a nosuchaddon
refuse "name with a slash" ../x
refuse "name with a space" "a b"
refuse "unknown option" x --bogus
refuse "two names without --file" a b
clean; run; [ "$rc" != 0 ] && echo "$out" | grep -q '^Usage:' && ok "no arguments prints usage" || fail "usage"
clean; run --help >/dev/null; [ "$rc" = 0 ] && ok "--help exits 0" || fail "help"

# --- existing definitions, --replace -----------------------------------------------------------------------------------------------------
clean; run keep; sum1=$(sha256sum "$DEFS/keep.Dockerfile" | cut -d' ' -f1); run keep -p git
[ "$rc" != 0 ] && echo "$out" | grep -q 'already exists' && [ "$(sha256sum "$DEFS/keep.Dockerfile" | cut -d' ' -f1)" = "$sum1" ] && ok "an existing definition is refused and left alone" || { echo "$out"; fail "existing"; }
run keep -p git --replace
[ "$rc" = 0 ] && has "$DEFS/keep.Dockerfile" 'RUN pacman -S --noconfirm --needed git' && ok "--replace overwrites it" || { echo "$out"; fail "replace"; }
printf '(\n    version: 1,\n    custom_podman_args: Some("--device /dev/foo"),\n)\n' > "$DEFS/keep.ron"
run keep --replace
echo "$out" | grep -q 'custom_podman_args, which are NOT carried over' && ok "--replace warns that custom_podman_args are dropped" || { echo "$out"; fail "replace warning"; }
[ -z "$(find "$DEFS" -name '*.??????' ! -name '*.ron' ! -name '*.Dockerfile')" ] && ok "no temp files left behind" || fail "temp files"

# --- dry run and --build ---------------------------------------------------------------------------------------------------------------------
clean; run d -p git -a boxed-run -s expose_pipewire=true --dry-run
[ "$rc" = 0 ] && [ "$(written)" = 0 ] && echo "$out" | grep -q 'RUN pacman -S --noconfirm --needed git' && echo "$out" | grep -q 'expose_pipewire: true,' && echo "$out" | grep -q 'Dry run: nothing was written' && ok "--dry-run shows the blocks and the .ron and writes nothing" || { echo "$out"; fail "dry run"; }
clean; run b --build
grep -q '^litterbox build b$' "$W/litterbox.log" && ok "--build runs 'litterbox build <name>'" || fail "build not run"
clean; run b --build --dry-run; ! grep -q build "$W/litterbox.log" && ok "--build is ignored on a dry run" || fail "build on dry run"
clean; run b -t nope --build; ! grep -q build "$W/litterbox.log" && ok "--build never runs after an error" || fail "build after error"
clean; run b; ! grep -q build "$W/litterbox.log" && ok "nothing is built unless asked" || fail "unexpected build"

# --- manifests ------------------------------------------------------------------------------------------------------------------------------------
M="$W/boxes.conf"
printf '# my boxes\r\n\r\n[web]\r\ntemplate = cachyos\r\npackages = git   neovim\r\naddons = boxed-run\r\nset.expose_pipewire = true\r\n\r\n; another\r\n[api]\r\ntemplate = fedora\r\npackages = htop\r\nset.network_mode = Host\r\n' > "$M"
clean; run --file "$M"
[ "$rc" = 0 ] && [ -f "$DEFS/web.Dockerfile" ] && [ -f "$DEFS/api.Dockerfile" ] && has "$DEFS/api.Dockerfile" 'RUN dnf install -y htop' && has "$DEFS/web.ron" '    expose_pipewire: true,' && has "$DEFS/api.ron" '    network_mode: Host,' && ok "a manifest creates every section (CRLF, comments and spacing tolerated)" || { echo "$out"; fail "manifest all"; }
clean; run --file "$M" api
[ "$rc" = 0 ] && [ -f "$DEFS/api.Dockerfile" ] && [ ! -e "$DEFS/web.Dockerfile" ] && ok "naming sections creates only those" || fail "manifest select"
clean; run --file "$M" nosuch; [ "$rc" != 0 ] && echo "$out" | grep -q 'no section \[nosuch\]' && ok "an unknown section name is an error" || fail "unknown section"
printf '[good]\npackages = git\n[bad]\nset.network_mode = Bridge\n' > "$W/m2.conf"
clean; run --file "$W/m2.conf"
[ "$rc" != 0 ] && echo "$out" | grep -q 'm2.conf:4: network_mode must be' && [ "$(written)" = 0 ] && ok "an error names the line, and the valid section before it is NOT written" || { echo "$out"; fail "all-or-nothing"; }
printf '[a]\n[a]\n' > "$W/m3.conf"; clean; run --file "$W/m3.conf"; [ "$rc" != 0 ] && echo "$out" | grep -q 'appears twice' && ok "a duplicate section is an error" || fail "duplicate"
printf 'packages = git\n' > "$W/m4.conf"; clean; run --file "$W/m4.conf"; [ "$rc" != 0 ] && echo "$out" | grep -q 'outside of a \[section\]' && ok "a setting outside a section is an error" || fail "outside section"
printf '[a]\ncolour = red\n' > "$W/m5.conf"; clean; run --file "$W/m5.conf"; [ "$rc" != 0 ] && echo "$out" | grep -q "m5.conf:2: unknown key 'colour'" && ok "an unknown key is an error with its line" || fail "unknown key"
printf '[a]\nwhat is this\n' > "$W/m6.conf"; clean; run --file "$W/m6.conf"; [ "$rc" != 0 ] && echo "$out" | grep -q 'cannot parse' && ok "an unparsable line is an error" || fail "unparsable"
printf '# nothing here\n' > "$W/m7.conf"; clean; run --file "$W/m7.conf"; [ "$rc" != 0 ] && echo "$out" | grep -q 'no \[sections\]' && ok "an empty manifest is an error" || fail "empty manifest"
printf '[a]\npackages = git; touch %s/PWN\n' "$W" > "$W/m8.conf"; clean; run --file "$W/m8.conf"; [ "$rc" != 0 ] && [ ! -e "$W/PWN" ] && ok "shell syntax in a manifest is rejected, not executed" || fail "manifest injection"
clean; run --file "$M" -p git; [ "$rc" != 0 ] && echo "$out" | grep -q 'single boxes' && ok "--file cannot be mixed with per-box flags" || fail "file + flags"
clean; run --file "$W/nonexistent.conf"; [ "$rc" != 0 ] && ok "a missing manifest is an error" || fail "missing manifest"

# --- templates ----------------------------------------------------------------------------------------------------------------------------------------
printf 'FROM scratch\n' > "$TPL/weird.Dockerfile"
clean; run --list-templates
echo "$out" | grep -q '^cachyos (arch family, pacman -S --noconfirm)' && echo "$out" | grep -q '^tumbleweed (suse family' && echo "$out" | grep -q '^weird (not supported' && ok "--list-templates shows each template, its family, and flags unknown ones" || { echo "$out"; fail "list templates"; }
rm -f "$TPL/weird.Dockerfile"
echo "$out" | grep -q '^cachyos-znver4 (arch family' && echo "$out" | grep -q '^cachyos-v4 (arch family' && ok "--list-templates: the CachyOS CPU variants are arch family" || { echo "$out"; fail "cpu variants listed"; }
for t in cachyos-znver4 cachyos-v4; do
  clean; run cpu -t $t -p git -a boxed-run
  [ "$rc" = 0 ] && head -n 3 "$DEFS/cpu.Dockerfile" | grep -q "^FROM .*${t#cachyos-}\|^FROM .*cachyos-${t#cachyos-}" && has "$DEFS/cpu.Dockerfile" 'RUN pacman -S --noconfirm --needed git' && has "$DEFS/cpu.Dockerfile" '# >>> litterbox-addons >>>' \
    && ok "$t: its own base image, pacman packages and the addon block" || { echo "$out"; head -n 4 "$DEFS/cpu.Dockerfile"; fail "$t template"; }
done
out=$(env LITTERBOX_TEMPLATE_DIR="$W/none" LITTERBOX_ROOT="$LBX" HOME="$W/home" sh "$SCRIPT" x 2>&1); rc=$?
[ "$rc" != 0 ] && echo "$out" | grep -q 'no templates found' && ok "a missing template directory is a clear error" || fail "missing templates"

[ "$FAILED" = 0 ] && echo "ALL PASSED" || { echo "SOME FAILED"; exit 1; }
