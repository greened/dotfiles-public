#!/usr/bin/env python3
#
# See: https://blog.goldandapager.io/a-better-emacs-remote-editing-workflow/
#

import getpass
import os
from pathlib import Path
import re
import shutil
import sys
import socket
import subprocess


def default_emacsclient():
  # Discover the client on PATH rather than hard-coding a path: it lives at
  # /usr/bin/emacsclient on the VM but /opt/homebrew/bin/emacsclient on the Mac,
  # and this wrapper runs on whichever host invokes $EDITOR.
  return shutil.which('emacsclient') or '/usr/bin/emacsclient'


def default_socket():
  # ~/.ssh/emacs-server is the right socket in both contexts: locally it's the
  # real Emacs server socket (eserver.el), remotely it's the forwarded socket
  # that tunnels to that same local Emacs. So always -s it; only the file path
  # differs.
  return f'{Path.home()}/.ssh/emacs-server'


def ssh_running():
  return 'SSH_CLIENT' in os.environ


def build_args(passthrough, emacsclient, socket_path, ssh, hostname, user):
  """The emacsclient command line for one invocation.

  Pure: it decides and returns, and it opens nothing.  The selftest calls this
  rather than the script, which is the repo's rule -- test the decision, never
  perform the effect.  `main' holds the effect.

  PASSTHROUGH is argv with the script name already dropped.  SSH says whether
  this is a remote shell; HOSTNAME and USER name this host for the TRAMP path,
  and go unread when SSH is false.
  """
  args = [emacsclient, '-s', socket_path]

  # This wrapper is for the single-file `$EDITOR <file>` open path. With -e/--eval
  # the trailing args are elisp forms, not files, so pass the whole command
  # through untouched -- never mistake an expression for a path to rewrite.
  if any(a in ('-e', '--eval') or a.startswith('--eval=') for a in passthrough):
    return args + list(passthrough)

  rest = list(passthrough)
  file = rest.pop()                   # last arg is the file to open
  args += rest                        # remaining flags (e.g. -n)

  # A path that already carries a TRAMP prefix (e.g. /scp:h:, /ssh:h:, /-:h:)
  # is meant to be opened as-is; wrapping it again would double-wrap
  # (/scp:h:/-:h:/path) and the far Emacs would treat the inner path as a
  # bogus localname.
  already_tramp = bool(re.match(r'/[^/]*:', file))

  if ssh and not already_tramp:
    # Remote shell: rewrite to a /scp: TRAMP path so the local Emacs opens
    # the file over scp back to this host.
    return args + [f'/scp:{user}@{hostname}:{file}']

  # Local shell, or an already-TRAMP path: pass it through unchanged.
  return args + [file]


def main(argv):
  args = build_args(argv[1:],          # drop argv[0] (this script)
                    default_emacsclient(),
                    default_socket(),
                    ssh_running(),
                    socket.gethostname(),
                    getpass.getuser())
  print(args)
  subprocess.run(args)


if __name__ == '__main__':
  main(sys.argv)
