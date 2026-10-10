# -*-sh-*-

function vterm_printf {
    if [ -n "$TMUX" ] && ([ "${TERM%%-*}" = "tmux" ] || [ "${TERM%%-*}" = "screen" ]); then
        # Tell tmux to pass the escape sequences through
        # (Source: http://permalink.gmane.org/gmane.comp.terminal-emulators.tmux.user/1324)
        printf "\ePtmux;\e\e]%s\007\e\\" "$1"
    elif [ "${TERM%%-*}" = "screen" ]; then
        # GNU screen (screen, screen-256color, screen-256color-bce)
        printf "\eP\e]%s\007\e\\" "$1"
    else
        printf "\e]%s\e\\" "$1"
    fi
}

# TRAMP keys connections by host name, so a host that Emacs reaches by an ssh
# alias sets VTERM_TRAMP_HOST to that alias. Otherwise a tracked directory
# opens a second connection.
function vterm_prompt_end {
    vterm_printf "51;A$(whoami)@${VTERM_TRAMP_HOST:-$(hostname)}:$(pwd)"
}

function clear {
    vterm_printf "51;Evterm-clear-scrollback"
    tput clear
}

function vterm_cmd {
    local vterm_elisp
    vterm_elisp=""
    while [ $# -gt 0 ]; do
        vterm_elisp="$vterm_elisp""$(printf '"%s" ' "$(printf "%s" "$1" | sed -e 's|\\|\\\\|g' -e 's|"|\\"|g')")"
        shift
    done
    vterm_printf "51;E$vterm_elisp"
}

function set-eterm-dir {
        echo -e "\033AnSiTu" "$LOGNAME" # $LOGNAME is more portable than using whoami.
echo -e "\033AnSiTc" "$(pwd)"
if [ $(uname) = "SunOS" ]; then
        # The -f option does something else on SunOS and is not needed anyway.
   	hostname_options="";
    else
        hostname_options="-f";
    fi
    echo -e "\033AnSiTh" "$(hostname $hostname_options)" # Using the -f option can cause problems on some OSes.
    history -a # Write history to disk.
}

function setup_emacs {
    # vterm_prompt_end puts an OSC escape in every prompt, which TRAMP's login
    # shell must never see: the default `tramp-shell-prompt-pattern' cannot
    # match it, and TRAMP spins in re_match_2_internal without end. TRAMP logs
    # in with TERM=dumb and M-x shell runs with it, so that test keeps both out.
    #
    # INSIDE_EMACS alone cannot select vterm. It never reaches a shell over
    # ssh, because the VM's sshd does not accept it, nor a tmux pane whose
    # server started outside vterm. So under ssh or tmux emit it anyway. A
    # terminal that does not know the escape ignores it. A vterm that TRAMP
    # opens says `vterm,tramp:...', hence the glob.
    if [[ "$TERM" != dumb ]] &&
       { [[ "$INSIDE_EMACS" = vterm* ]] ||
         [[ -z "$INSIDE_EMACS" && -n "$SSH_CONNECTION$TMUX" ]]; }; then
        #PROMPT_COMMAND='echo -ne "\033]0;\h:\w\007"'
        PS1=$PS1'\[$(vterm_prompt_end)\]'
    fi

    # EDITOR: emacsclient.py wrapper (dispatches on SSH_CLIENT); no -n so it blocks.
    export EDITOR="$(realpath "$(dirname "${BASH_SOURCE[0]}")/../../emacs/emacsclient.py")"
    export VISUAL="$EDITOR"

# Track directory, username, and cwd for remote logons.
#if [ "$TERM" = "eterm-color" -o "$TERM" = "screen" ]; then
#    PROMPT_COMMAND=set-eterm-dir
#fi
}
