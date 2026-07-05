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

function vterm_prompt_end {
    vterm_printf "51;A$(whoami)@$(hostname):$(pwd)"
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
    # Allow passing of vterm state through ssh.
    if [[ -n "${LC_INSIDE_EMACS}" ]]; then
        export INSIDE_EMACS="${LC_INSIDE_EMACS}"
    elif [[ -n "${INSIDE_EMACS}" ]]; then
        export LC_INSIDE_EMACS="${INSIDE_EMACS}"
    fi

    #if [[ "$INSIDE_EMACS" = 'vterm' ]]; then

    #PROMPT_COMMAND='echo -ne "\033]0;\h:\w\007"'
    PS1=$PS1'\[$(vterm_prompt_end)\]'
    #fi

    export remote_emacs_auth="$HOME/.emacs.d/remote-server"
    # EDITOR: emacsclient.py wrapper (dispatches on SSH_CLIENT); no -n so it blocks.
    export EDITOR="$HOME/lib/dotfiles/emacs/emacsclient.py"
    export VISUAL="$EDITOR"

    export EMACS_SERVER_SOCK="${HOME}/emacs.d/server/server"
    #alias ssh="ssh -R ~/.ssh/emacs-server:$EMACS_SERVER_SOCK"

# Track directory, username, and cwd for remote logons.
#if [ "$TERM" = "eterm-color" -o "$TERM" = "screen" ]; then
#    PROMPT_COMMAND=set-eterm-dir
#fi
}
