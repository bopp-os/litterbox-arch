# fish completion for litterbox and the litterbox-sandbox-addons tools
# (litterbox-addon, litterbox-export, litterbox-update, litterbox-prune, litterbox-assemble).
#
# Litterbox names come from ~/Litterbox/definitions (or $LITTERBOX_ROOT), addon names from
# /usr/share/litterbox-sandbox-addons (or $LITTERBOX_ADDONS_DIR), templates from
# /usr/share/litterbox-sandbox/templates (or $LITTERBOX_TEMPLATE_DIR). Only plain names are offered.

function __litterbox_names
    set -l root $HOME/Litterbox
    set -q LITTERBOX_ROOT; and set root $LITTERBOX_ROOT
    command ls -1 $root/definitions 2>/dev/null | string match -r -- '^[A-Za-z0-9][A-Za-z0-9._-]*(?=\.Dockerfile$)'
end

function __litterbox_addon_names
    set -l dir /usr/share/litterbox-sandbox-addons
    set -q LITTERBOX_ADDONS_DIR; and set dir $LITTERBOX_ADDONS_DIR
    for d in (command ls -1 $dir 2>/dev/null)
        test -d $dir/$d; and echo $d
    end
end

function __litterbox_template_names
    set -l dir /usr/share/litterbox-sandbox/templates
    set -q LITTERBOX_TEMPLATE_DIR; and set dir $LITTERBOX_TEMPLATE_DIR
    command ls -1 $dir 2>/dev/null | string replace -r -- '\.Dockerfile$' '' | string match -r -- '^[a-z0-9-]+$'
end

function __litterbox_settings
    for k in support_ping support_tuntap packet_forwarding expose_pipewire keep_groups enable_kvm expose_kfd unconfine_seccomp unconfine_landlock
        echo $k=true
        echo $k=false
    end
    for m in Pasta PastaHostToContainer PastaContainerToHost PastaBidirectional Host
        echo network_mode=$m
    end
    echo shm_size_gb=none
end

# true while no argument has been typed after the command yet (the Litterbox name comes first)
function __litterbox_first_arg
    test (count (commandline -opc)) -eq 1
end

# litterbox-addon <list|install|remove|help> [name] [addon...]
function __litterbox_addon_wants
    set -l t (commandline -opc)
    set -e t[1]
    switch $argv[1]
        case sub
            test (count $t) -eq 0
        case names
            test (count $t) -eq 1; and contains -- $t[1] install remove
        case addons
            test (count $t) -ge 2; and test $t[1] = install
    end
end

# ---- litterbox itself ---------------------------------------------------------------------------------
complete -c litterbox -f
complete -c litterbox -n __fish_use_subcommand -a 'define def build enter delete del rm device dev list ls keys help'
complete -c litterbox -n '__fish_seen_subcommand_from build delete del rm enter device dev' -a '(__litterbox_names)'
complete -c litterbox -n '__fish_seen_subcommand_from enter' -l root -d 'Run as root instead of dropping privileges'
complete -c litterbox -n '__fish_seen_subcommand_from enter' -s t -l tty -x -a 'true false' -d 'Allocate a pseudo-TTY'
complete -c litterbox -n '__fish_seen_subcommand_from enter' -s i -l interactive -x -a 'true false' -d 'Keep STDIN open'
complete -c litterbox -n '__fish_seen_subcommand_from enter' -s w -l workdir -r -d 'Working directory inside the container'
complete -c litterbox -n '__fish_seen_subcommand_from enter' -l wait -x -a 'foreground background kill' -d 'What to do with background processes'
complete -c litterbox -n '__fish_seen_subcommand_from keys' -a 'generate attach detach delete import export list print change-password'

# ---- litterbox-addon ----------------------------------------------------------------------------------
complete -c litterbox-addon -f
complete -c litterbox-addon -n '__litterbox_addon_wants sub' -a 'list install remove help'
complete -c litterbox-addon -n '__litterbox_addon_wants names' -a '(__litterbox_names)'
complete -c litterbox-addon -n '__litterbox_addon_wants addons' -a '(__litterbox_addon_names)'

# ---- litterbox-export ---------------------------------------------------------------------------------
complete -c litterbox-export -f
complete -c litterbox-export -n __litterbox_first_arg -a '(__litterbox_names)'
complete -c litterbox-export -l app -x -d 'Add an app from the Litterbox to the menu'
complete -c litterbox-export -l bin -x -d 'Create a host command for a program in the Litterbox'
complete -c litterbox-export -l list -d 'Show what is exported'
complete -c litterbox-export -l shell -d 'Add a menu entry that opens a terminal in the Litterbox'
complete -c litterbox-export -l exec -d 'Run a command in the Litterbox with safely quoted arguments'
complete -c litterbox-export -l tty -d 'With --exec: allocate a tty'
complete -c litterbox-export -l boxed -d 'Run through boxed-run (D-Bus session + keyring)'
complete -c litterbox-export -l wrap -x -d 'Run through this command inside the Litterbox'
complete -c litterbox-export -l scheme -x -d 'Also handle URLs of this scheme'
complete -c litterbox-export -l url-handler -d 'Register as the default handler for its URL schemes'
complete -c litterbox-export -l delete -d 'Remove what was exported'
complete -c litterbox-export -l export-path -x -a '(__fish_complete_directories)' -d 'Where --bin puts the command'
complete -c litterbox-export -s h -l help -d 'Show help'

# ---- litterbox-update ---------------------------------------------------------------------------------
complete -c litterbox-update -f -a '(__litterbox_names)'
complete -c litterbox-update -s n -l dry-run -d 'Only show what would run'
complete -c litterbox-update -l no-sandbox -d 'pacman: add --disable-sandbox'
complete -c litterbox-update -l all -d 'Every Litterbox with a definition'
complete -c litterbox-update -s h -l help -d 'Show help'

# ---- litterbox-prune ----------------------------------------------------------------------------------
complete -c litterbox-prune -f -a '(__litterbox_names)'
complete -c litterbox-prune -s y -l yes -d 'Actually remove the images'
complete -c litterbox-prune -s h -l help -d 'Show help'

# ---- litterbox-assemble -------------------------------------------------------------------------------
complete -c litterbox-assemble -f
complete -c litterbox-assemble -s t -l template -x -a '(__litterbox_template_names)' -d 'Dockerfile template'
complete -c litterbox-assemble -s p -l package -x -d 'Extra package to install'
complete -c litterbox-assemble -s a -l addon -x -a '(__litterbox_addon_names)' -d 'Add a litterbox-addon addon'
complete -c litterbox-assemble -s s -l set -x -a '(__litterbox_settings)' -d 'A setting for the .ron file'
complete -c litterbox-assemble -s f -l file -r -d 'Read boxes from a manifest'
complete -c litterbox-assemble -s A -l append -r -d 'Append a Dockerfile fragment'
complete -c litterbox-assemble -s V -l volume -r -d 'A bind mount SRC:DST[:ro|rw]'
complete -c litterbox-assemble -l replace -d 'Overwrite an existing definition'
complete -c litterbox-assemble -s n -l dry-run -d 'Show what would be written'
complete -c litterbox-assemble -l build -d 'Run litterbox build afterwards'
complete -c litterbox-assemble -l list-templates -d 'Show the available templates'
complete -c litterbox-assemble -s h -l help -d 'Show help'
