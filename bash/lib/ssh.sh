# -*-sh-*-

# Run ssh-agent, if one is not already running
function start_agent {
   #echo "Initialising new SSH agent..."
   /usr/bin/ssh-agent -t 14400 | sed 's/^echo/#echo/' > "${SSH_ENV}"
   #echo succeeded
   chmod 600 "${SSH_ENV}"
   . "${SSH_ENV}" >/dev/null
   /usr/bin/ssh-add;
}

# Use the agent link that ~/.ssh/rc keeps pointed at a live forwarded
# agent. ssh/rc in the dotfiles explains why. Only inside an ssh session, so
# a local agent (the Mac's launchd one) is left alone. The owner test stops a
# dangling link from reaching a socket another user made at the old path.
function use_agent_link {
    local link="${HOME}/.ssh/agent-${HOSTNAME%%.*}.sock"
    if [[ -n "${SSH_CONNECTION}" && -S "${link}" && -O "${link}" ]]; then
        export SSH_AUTH_SOCK="${link}"
    fi
}

function setup_ssh {
    use_agent_link

    if [[ -z "${LOGIN_SHELL}" ]]; then
        return
    fi

    return

    SSH_ENV="${HOME}/.ssh/environment"

    # Source SSH settings, if applicable
    if [ -f "${SSH_ENV}" ]; then
        . "${SSH_ENV}" >/dev/null
        #ps ${SSH_AGENT_PID} doesn't work under cywgin
        ps -ef | grep ${SSH_AGENT_PID} | grep ssh-agent$ >/dev/null || {
            start_agent;
        }
        # if our ssh-added identity has expired (see -t option to ssh-agent)
        # then we need to re-add it
        if ! /usr/bin/ssh-add -l >/dev/null; then
            /usr/bin/ssh-add;
        fi
    else
        # no ssh-agent running at the moment
        start_agent;
    fi

    eval `ssh-agent -s`
}
