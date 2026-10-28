# -*-sh-*-

# gpg 2.1 and later start gpg-agent on demand, so only tell pinentry which
# terminal to use. Call this from interactive shells only.

function setup_gpg {
    GPG_TTY=$(tty)
    export GPG_TTY
}
