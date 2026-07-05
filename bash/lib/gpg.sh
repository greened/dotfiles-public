# -*-sh-*-

# Run gpg-agent, if one is not already running

function setup_gpg {
    if which gpg-agent >/dev/null; then
        GPG_TTY=$(tty)
        export GPG_TTY
        GPG_ENV_FILE="${HOME}/.gnupg/gpg-agent.env"
        if ! pgrep gpg-agent >/dev/null; then
            gpg-agent --daemon --write-env-file "${GPG_ENV_FILE}" >/dev/null
        fi
        if [ -f "${GPG_ENV_FILE}" ]; then
            source "${GPG_ENV_FILE}"
            export GPG_AGENT_INFO
        fi
    fi
}
