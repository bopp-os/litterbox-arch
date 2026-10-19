# bash completion for litterbox and the litterbox-sandbox-addons tools
# (litterbox-addon, litterbox-export, litterbox-update, litterbox-prune, litterbox-assemble).
#
# Litterbox names come from ~/Litterbox/definitions (or $LITTERBOX_ROOT), addon names from
# /usr/share/litterbox-sandbox-addons (or $LITTERBOX_ADDONS_DIR). Only plain names are offered.
# Needs only bash itself: no bash-completion library.

_litterbox_tools_names() {
  local root=${LITTERBOX_ROOT:-$HOME/Litterbox} f
  for f in "$root"/definitions/*.Dockerfile; do
    [[ -f $f ]] || continue
    f=${f##*/}
    f=${f%.Dockerfile}
    if [[ $f =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then printf '%s\n' "$f"; fi
  done
}

_litterbox_tools_templates() {
  local dir=${LITTERBOX_TEMPLATE_DIR:-/usr/share/litterbox-sandbox/templates} f
  for f in "$dir"/*.Dockerfile; do
    [[ -f $f ]] || continue
    f=${f##*/}
    printf '%s\n' "${f%.Dockerfile}"
  done
}

_litterbox_tools_addons() {
  local dir=${LITTERBOX_ADDONS_DIR:-/usr/share/litterbox-sandbox-addons} d
  for d in "$dir"/*/; do
    [[ -d $d ]] || continue
    d=${d%/}
    printf '%s\n' "${d##*/}"
  done
}

# _litterbox_tools_reply WORDS: set COMPREPLY to the words that start with the current word
_litterbox_tools_reply() {
  local cur=${COMP_WORDS[COMP_CWORD]}
  mapfile -t COMPREPLY < <(compgen -W "$1" -- "$cur")
}

# true if any of the words typed so far (after the command) equals one of the arguments
_litterbox_tools_seen() {
  local w i
  for ((i = 1; i < COMP_CWORD; i++)); do
    for w in "$@"; do
      [[ ${COMP_WORDS[i]} == "$w" ]] && return 0
    done
  done
  return 1
}

# true after a literal "--": the rest is a command for the container, which we cannot complete
_litterbox_tools_after_dashes() { _litterbox_tools_seen --; }

_litterbox_tools_default() { compopt -o default 2>/dev/null || true; COMPREPLY=(); }

_litterbox_cmd() {
  local cur=${COMP_WORDS[COMP_CWORD]} sub=${COMP_WORDS[1]:-}
  if ((COMP_CWORD == 1)); then
    _litterbox_tools_reply "define def build enter delete del rm device dev list ls keys help --help --version"
    return
  fi
  _litterbox_tools_after_dashes && { _litterbox_tools_default; return; }
  case $sub in
    build | delete | del | rm)
      if ((COMP_CWORD == 2)); then _litterbox_tools_reply "$(_litterbox_tools_names)"; else COMPREPLY=(); fi ;;
    enter)
      if [[ $cur == -* ]]; then
        _litterbox_tools_reply "--root --tty --interactive --workdir --wait -t -i -w"
      elif ((COMP_CWORD == 2)); then
        _litterbox_tools_reply "$(_litterbox_tools_names)"
      else
        _litterbox_tools_default
      fi ;;
    device | dev)
      if ((COMP_CWORD == 2)); then _litterbox_tools_reply "$(_litterbox_tools_names)"; else _litterbox_tools_default; fi ;;
    keys)
      if ((COMP_CWORD == 2)); then
        _litterbox_tools_reply "generate attach detach delete import export list print change-password"
      elif [[ ${COMP_WORDS[2]} == attach ]] && ((COMP_CWORD == 4)); then
        _litterbox_tools_reply "$(_litterbox_tools_names)"
      else
        COMPREPLY=()
      fi ;;
    *) COMPREPLY=() ;;
  esac
}

_litterbox_addon_cmd() {
  case $COMP_CWORD in
    1) _litterbox_tools_reply "list install remove help --help" ;;
    2) case ${COMP_WORDS[1]} in
         install | remove) _litterbox_tools_reply "$(_litterbox_tools_names)" ;;
         *) COMPREPLY=() ;;
       esac ;;
    *) if [[ ${COMP_WORDS[1]} == install ]]; then _litterbox_tools_reply "$(_litterbox_tools_addons)"; else COMPREPLY=(); fi ;;
  esac
}

_litterbox_export_cmd() {
  local cur=${COMP_WORDS[COMP_CWORD]} prev=${COMP_WORDS[COMP_CWORD - 1]}
  if ((COMP_CWORD == 1)); then
    _litterbox_tools_reply "$(_litterbox_tools_names) --help"
    return
  fi
  _litterbox_tools_after_dashes && { COMPREPLY=(); return; }
  case $prev in
    --export-path) mapfile -t COMPREPLY < <(compgen -d -- "$cur"); compopt -o filenames 2>/dev/null || true; return ;;
    --app | --bin | --wrap | --scheme) COMPREPLY=(); return ;;
  esac
  _litterbox_tools_reply "--app --bin --list --shell --exec --tty --boxed --wrap --scheme --url-handler --delete --export-path --help"
}

_litterbox_update_cmd() {
  local cur=${COMP_WORDS[COMP_CWORD]}
  if [[ $cur == -* ]]; then
    _litterbox_tools_reply "--dry-run -n --no-sandbox --all --help"
  elif _litterbox_tools_seen --all; then
    COMPREPLY=()
  else
    _litterbox_tools_reply "$(_litterbox_tools_names)"
  fi
}

_litterbox_prune_cmd() {
  local cur=${COMP_WORDS[COMP_CWORD]}
  if [[ $cur == -* ]]; then
    _litterbox_tools_reply "--yes -y --help"
  else
    _litterbox_tools_reply "$(_litterbox_tools_names)"
  fi
}

_litterbox_assemble_cmd() {
  local cur=${COMP_WORDS[COMP_CWORD]} prev=${COMP_WORDS[COMP_CWORD - 1]} key=''
  # '=' is a word break in bash, so "--set key=va" arrives as: --set key = va
  if [[ $prev == = && $COMP_CWORD -ge 3 ]]; then
    key=${COMP_WORDS[COMP_CWORD - 2]}
    case $key in
      network_mode) _litterbox_tools_reply "Pasta PastaHostToContainer PastaContainerToHost PastaBidirectional Host"; return ;;
      shm_size_gb) _litterbox_tools_reply "none 1 2 4 8 16"; return ;;
      *) _litterbox_tools_reply "true false"; return ;;
    esac
  fi
  if [[ $prev == = ]]; then
    _litterbox_tools_reply "true false"
    return
  fi
  case $prev in
    -t | --template) _litterbox_tools_reply "$(_litterbox_tools_templates)"; return ;;
    -a | --addon) _litterbox_tools_reply "$(_litterbox_tools_addons)"; return ;;
    -s | --set)
      _litterbox_tools_reply "support_ping support_tuntap packet_forwarding expose_pipewire keep_groups enable_kvm expose_kfd unconfine_seccomp unconfine_landlock shm_size_gb network_mode"
      compopt -o nospace 2>/dev/null || true
      return ;;
    -f | --file | -A | --append | -V | --volume) compopt -o default 2>/dev/null || true; COMPREPLY=(); return ;;
    -p | --package) COMPREPLY=(); return ;;
  esac
  if [[ $cur == -* ]]; then
    _litterbox_tools_reply "--template --package --addon --set --file --append --volume --replace --dry-run --build --list-templates --help -t -p -a -s -f -A -V -n -h"
  else
    COMPREPLY=()
  fi
}

complete -F _litterbox_cmd litterbox
complete -F _litterbox_addon_cmd litterbox-addon
complete -F _litterbox_export_cmd litterbox-export
complete -F _litterbox_update_cmd litterbox-update
complete -F _litterbox_prune_cmd litterbox-prune
complete -F _litterbox_assemble_cmd litterbox-assemble
