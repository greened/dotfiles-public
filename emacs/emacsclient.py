#!/usr/bin/env python3
#
# See: https://blog.goldandapager.io/a-better-emacs-remote-editing-workflow/
#

import getpass
import os
from pathlib import Path
import re
import sys
import socket
import subprocess

home = str(Path.home())

emacsclient = '/usr/bin/emacsclient'
emacs_socket = f'{home}/.ssh/emacs-server'

def ssh_running():
  return 'SSH_CLIENT' in os.environ

# ~/.ssh/emacs-server is the right socket in both contexts: locally it's the
# real Emacs server socket (eserver.el), remotely it's the forwarded socket that
# tunnels to that same local Emacs. So always -s it; only the file path differs.
args = [emacsclient, '-s', emacs_socket]

passthrough = sys.argv[1:]            # drop argv[0] (this script)
file = passthrough.pop()              # last arg is the file to open
args += passthrough                   # remaining flags (e.g. -n)

# A path that already carries a TRAMP prefix (e.g. /scp:h:, /ssh:h:, /-:h:) is
# meant to be opened as-is; wrapping it again would double-wrap
# (/scp:h:/-:h:/path) and the far Emacs would treat the inner path as a bogus
# localname.
already_tramp = bool(re.match(r'/[^/]*:', file))

if ssh_running() and not already_tramp:
    # Remote shell: rewrite to a /scp: TRAMP path so the local Emacs opens the
    # file over scp back to this host.
    hostname = socket.gethostname()
    user = getpass.getuser()
    args += [f'/scp:{user}@{hostname}:{file}']
else:
    # Local shell, or an already-TRAMP path: pass it through unchanged.
    args += [file]

print(args)
subprocess.run(args)
