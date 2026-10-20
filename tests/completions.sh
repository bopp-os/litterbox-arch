#!/bin/sh
# Tests for the shell completions. bash always; fish when a fish binary is available (set FISH=/path/to/fish
# or have it on PATH); zsh is only syntax-checked if present. Fixtures stand in for ~/Litterbox, the addons
# directory and the template directory.
set -u
# The expected lists are in byte order (--help before dev); a UTF-8 locale's sort ignores the dashes
export LC_ALL=C
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC="$ROOT/litterbox-sandbox-addons"
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
FAILED=0
ok() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAILED=1; }

mkdir -p "$W/home/Litterbox/definitions" "$W/addons/boxed-run" "$W/addons/other" "$W/templates" "$W/fishhome"
for n in dev work; do : > "$W/home/Litterbox/definitions/$n.Dockerfile"; done
: > "$W/home/Litterbox/definitions/bad name.Dockerfile"     # not a plain name: must never be offered
: > "$W/home/Litterbox/definitions/-dash.Dockerfile"        # starts with a dash: must never be offered
: > "$W/home/Litterbox/definitions/notes.txt"
: > "$W/addons/not-a-dir"
: > "$W/templates/cachyos.Dockerfile"; : > "$W/templates/fedora.Dockerfile"
export HOME="$W/home" LITTERBOX_ROOT="$W/home/Litterbox" LITTERBOX_ADDONS_DIR="$W/addons" LITTERBOX_TEMPLATE_DIR="$W/templates"

# ---- bash ------------------------------------------------------------------------------------------------------------
bash -n "$SRC/litterbox-tools.bash" && ok "bash completion file parses" || fail "bash syntax"

bcomp() { # bcomp 'typed line' -> the completions bash would offer, sorted, space separated
  bash -c '
    source "$1"; line=$2
    words=($line); [[ $line == *" " ]] && words+=("")
    COMP_WORDS=("${words[@]}"); COMP_CWORD=$((${#words[@]} - 1))
    fn=$(complete -p "${words[0]}" | sed -n "s/.*-F \([^ ]*\) .*/\1/p")
    "$fn"; printf "%s\n" "${COMPREPLY[@]}" | sort | tr "\n" " " | sed "s/ $//"
  ' _ "$SRC/litterbox-tools.bash" "$1" 2>/dev/null
}
expect_b() { # expect_b 'line' 'expected replies'
  got=$(bcomp "$1")
  if [ "$got" = "$2" ]; then ok "bash: '$1' -> ${2:-nothing}"; else echo "   got: [$got]"; echo "  want: [$2]"; fail "bash: '$1'"; fi
}
expect_b 'litterbox-update ' 'dev work'
expect_b 'litterbox-update d' 'dev'
expect_b 'litterbox-update --' '--all --dry-run --help --no-sandbox'
expect_b 'litterbox-update --all ' ''
expect_b 'litterbox-prune ' 'dev work'
expect_b 'litterbox-prune --y' '--yes'
expect_b 'litterbox-addon ' '--help help install list remove'
expect_b 'litterbox-addon i' 'install'
expect_b 'litterbox-addon install ' 'dev work'
expect_b 'litterbox-addon remove w' 'work'
expect_b 'litterbox-addon install dev ' 'boxed-run other'
expect_b 'litterbox-addon install dev b' 'boxed-run'
expect_b 'litterbox-addon list ' ''
expect_b 'litterbox-export ' '--help dev work'
expect_b 'litterbox-export dev --s' '--scheme --shell'
expect_b 'litterbox-export dev --app ' ''
expect_b 'litterbox-export dev --exec -- ' ''
expect_b 'litterbox-assemble -t ' 'cachyos fedora'
expect_b 'litterbox-assemble --template f' 'fedora'
expect_b 'litterbox-assemble -a ' 'boxed-run other'
expect_b 'litterbox-assemble -s expose' 'expose_kfd expose_pipewire'
expect_b 'litterbox-assemble --' '--addon --append --build --dry-run --file --help --list-templates --package --replace --set --template --volume'
expect_b 'litterbox ' '--help --version build def define del delete dev device enter help keys list ls rm'
expect_b 'litterbox enter ' 'dev work'
expect_b 'litterbox enter dev --r' '--root'
expect_b 'litterbox enter dev -- ' ''
expect_b 'litterbox build w' 'work'
expect_b 'litterbox keys ' 'attach change-password delete detach export generate import list print'
expect_b 'litterbox keys attach mykey ' 'dev work'

# '=' is a word break in bash: "--set network_mode=Pa" arrives as three words
got=$(bash -c 'source "$1"; COMP_WORDS=(litterbox-assemble -s network_mode = Pa); COMP_CWORD=4; _litterbox_assemble_cmd; printf "%s\n" "${COMPREPLY[@]}" | sort | tr "\n" " "' _ "$SRC/litterbox-tools.bash" 2>/dev/null)
[ "$got" = "Pasta PastaBidirectional PastaContainerToHost PastaHostToContainer " ] && ok "bash: '--set network_mode=Pa' -> the network modes" || { echo "got [$got]"; fail "bash network_mode values"; }
got=$(bash -c 'source "$1"; COMP_WORDS=(litterbox-assemble -s expose_pipewire = t); COMP_CWORD=4; _litterbox_assemble_cmd; printf "%s\n" "${COMPREPLY[@]}"' _ "$SRC/litterbox-tools.bash" 2>/dev/null)
[ "$got" = "true" ] && ok "bash: '--set expose_pipewire=t' -> true" || { echo "got [$got]"; fail "bash bool values"; }

# nothing is ever executed or written by completing
got=$(bcomp 'litterbox-update ')
case $got in *"bad name"*|*-dash*|*notes*) fail "bash offered a name that is not a plain Litterbox name: $got" ;; *) ok "bash: names with spaces, leading dashes and other files are never offered" ;; esac

# ---- fish ------------------------------------------------------------------------------------------------------------
FISH=${FISH:-$(command -v fish || true)}
if [ -n "$FISH" ] && [ -x "$FISH" ]; then
  fc() { # fc 'typed line' -> completions fish would offer (descriptions stripped), sorted, space separated
    env HOME="$W/fishhome" "$FISH" --no-config -c "source '$SRC/litterbox-tools.fish'; complete -C '$1'" 2>/dev/null | cut -f1 | sort | tr '\n' ' ' | sed 's/ $//'
  }
  "$FISH" --no-execute "$SRC/litterbox-tools.fish" && ok "fish completion file parses (fish --no-execute)" || fail "fish syntax"
  expect_f() { got=$(fc "$1"); if [ "$got" = "$2" ]; then ok "fish: '$1' -> ${2:-nothing}"; else echo "   got: [$got]"; echo "  want: [$2]"; fail "fish: '$1'"; fi; }
  expect_f 'litterbox-update ' 'dev work'
  expect_f 'litterbox-update --' '--all --dry-run --help --no-sandbox'
  expect_f 'litterbox-prune ' 'dev work'
  expect_f 'litterbox-prune --y' '--yes'
  expect_f 'litterbox-addon ' 'help install list remove'
  expect_f 'litterbox-addon install ' 'dev work'
  expect_f 'litterbox-addon install dev ' 'boxed-run other'
  expect_f 'litterbox-addon list ' ''
  expect_f 'litterbox-export ' 'dev work'
  expect_f 'litterbox-export dev --sh' '--shell'
  expect_f 'litterbox-assemble -t ' 'cachyos fedora'
  expect_f 'litterbox-assemble -a ' 'boxed-run other'
  expect_f 'litterbox-assemble -s network_mode=P' 'network_mode=Pasta network_mode=PastaBidirectional network_mode=PastaContainerToHost network_mode=PastaHostToContainer'
  expect_f 'litterbox enter ' 'dev work'
  expect_f 'litterbox enter --r' '--root'
  expect_f 'litterbox keys ' 'attach change-password delete detach export generate import list print'
  got=$(fc 'litterbox-update '); case $got in *"bad name"*|*-dash*|*notes*) fail "fish offered a non-plain name: $got" ;; *) ok "fish: non-plain names are never offered" ;; esac
else
  echo "SKIP: no fish available (set FISH=/path/to/fish): fish completions were not exercised"
fi

# ---- zsh ----------------------------------------------------------------------------------------------------------------
if command -v zsh >/dev/null 2>&1; then
  zsh -n "$SRC/_litterbox-tools" && ok "zsh completion file parses (zsh -n)" || fail "zsh syntax"
else
  echo "SKIP: zsh is not installed: the zsh completion file is untested"
fi

[ "$FAILED" = 0 ] && echo "ALL PASSED" || { echo "SOME FAILED"; exit 1; }
