# Editing dev-VM files in the laptop's Emacs

Emacs runs on the laptop, and the work happens on a dev VM over ssh. With
this setup, `$EDITOR` on the VM opens the file in the laptop's Emacs. A `git
commit`, a shell or an agent on the VM all edit in the Emacs you are looking
at, and that Emacs reads and writes the VM file over TRAMP.

It needs no third-party package: Emacs's built-in `server` library, TRAMP
and an ssh `RemoteForward` of a unix socket.

Most of the choices below come from one constraint. Emacs is
single-threaded, so any call that waits on a dead or slow network link
freezes the editor.

## The shape

    VM shell: $EDITOR file
      -> emacsclient.py rewrites file to /scp:user@dev-vm:/path/file
      -> emacsclient -s ~/.ssh/emacs-server          (on the VM)
      -> ssh RemoteForward of that socket            (one dedicated tunnel)
      -> ~/.ssh/emacs-server                         (laptop Emacs server)
      -> laptop Emacs opens /scp:user@dev-vm:/path/file over TRAMP

| Part                     | Where                                         |
|--------------------------|-----------------------------------------------|
| Laptop Emacs server      | `server` block in `emacs/lisp/packages.el`    |
| Window placement         | same block, `server-window`                   |
| `$EDITOR` wrapper        | `emacs/emacsclient.py`, set in `bash/lib/emacs.sh` |
| Frame launcher           | `bin/emacs-frame`                             |
| Matching VM emacsclient  | `bin/install-emacsclient`                     |
| Tunnel ssh aliases       | overlay-provided `ssh/config`                 |
| Tunnel supervisor        | overlay-provided Emacs config                 |
| Stale-socket reaper      | overlay-provided script and cron entry        |

The overlay-provided parts name hosts and paths, so they belong in an
overlay, not here. The sections below describe them generically.

## 1. The laptop Emacs server

The laptop Emacs serves on a fixed unix socket, `~/.ssh/emacs-server`,
rather than the default name under `$TMPDIR`:

- A unix socket rather than TCP, because ssh can forward a socket path
  directly and the file permissions do the access control. There is no port
  to pick and no auth file to copy to the VM.
- A fixed path, because the ssh config has to name it, and the default under
  `$TMPDIR` differs between machines.
- No server when `SSH_CLIENT` is set, so an Emacs started inside an ssh
  session never takes the socket.

Only one Emacs can own the socket. A second one skips `server-start` and
runs with no server, so every `emacsclient` call opens its file in the first
one, which may be a daemon nobody is looking at. So the second Emacs shows a
warning that names the socket and the command to attach to its owner. The
test is `server-process`, not `server-running-p`, because `server-running-p`
is also true in the Emacs that owns the socket.

`bin/emacs-frame` is the launcher that avoids the second Emacs. It opens a
frame on the owner with `emacsclient -s ~/.ssh/emacs-server -c -a "" -n`,
and starts a daemon only when nothing owns the socket.

## 2. Where a client's buffer appears

With `server-window` nil, a client's buffer replaces the selected window.
When that window is a vterm you are typing in, the keystrokes land in the
commit message instead of the shell. So `server-window` is a function that
splits the frame's root window, shows the buffer below without selecting
it, and raises the frame. `server-raise-frame` is nil, because raising
through it takes keyboard focus for the whole application.

The window is dedicated, so killing the buffer deletes it and restores the
layout. `server-kill-new-buffers` defaults to t, so `C-x #` kills the
buffer.

A pop-up frame was tried first. On the macOS build it was tried on, the new
frame became the selected frame as soon as it was mapped, which is the same
problem. `no-focus-on-map` and `no-accept-focus` did not change that.

## 3. The `$EDITOR` wrapper

`bash/lib/emacs.sh` sets `EDITOR` and `VISUAL` to `emacs/emacsclient.py`.
The wrapper:

- Always passes `-s ~/.ssh/emacs-server`. That path is the real socket on
  the laptop and the forwarded one on the VM, so one wrapper works on both.
- Rewrites the file argument to `/scp:$USER@$(hostname):<file>` when
  `SSH_CLIENT` is set, because the laptop Emacs cannot see the VM's
  filesystem.
- Leaves `-e` expressions alone, and does not wrap a path that already
  carries a TRAMP prefix.
- Runs without `-n`, so it blocks until the buffer is finished. That is what
  `git commit` needs.
- Finds `emacsclient` on `PATH`, since the binary lives in different places
  on Linux and macOS.

`emacs/tests/test_emacsclient.py` tests the argument rewriting.
`bin/install-emacsclient` builds an `emacsclient` on the VM that matches the
laptop's Emacs version, because an older client garbles a long reply.

## 4. One tunnel owns the forward

Only one ssh session can bind the VM's socket path. So the forward lives on
its own host alias, and nothing else uses that alias. Three aliases for one
host:

    Host dev-vm                # TRAMP, terminals: no forward
      ServerAliveInterval 15
      ServerAliveCountMax 2
      ConnectTimeout 10

    Host dev-vm-tunnel         # the forward, and nothing else
      RemoteForward /home/<user>/.ssh/emacs-server %d/.ssh/emacs-server
      StreamLocalBindUnlink yes
      ExitOnForwardFailure yes
      ServerAliveInterval 15
      ServerAliveCountMax 2
      BatchMode yes
      ConnectTimeout 10
      RequestTTY no

    Host dev-vm-nofwd          # scripted one-offs
      ClearAllForwardings yes

`%d` is the local home directory. Why the settings:

- `ExitOnForwardFailure` belongs on the tunnel alias only. There a failed
  bind means another owner exists, so exiting and retrying is right. On the
  normal alias it would make every connection after the first fail.
- The keepalives and `ConnectTimeout` bound how long a dead or unreachable
  link can hold TRAMP. A TRAMP ssh process over a dead TCP connection never
  sees end of file, and Emacs waits on it.
- `BatchMode`, so ssh never waits on a prompt nobody can see.
- `StreamLocalBindUnlink` asks sshd to remove a leftover socket file before
  the bind. For a remote forward the VM's sshd decides, and it may ignore
  it, which is why the reaper in section 6 exists.

The base `ssh/config` `Include`s the overlays before its own `Host *`
block. ssh keeps the first value it reads, so the overlay's
`ServerAliveInterval 15` wins over the base's 240.

To try the setup by hand, `ssh -N dev-vm-tunnel` in a terminal does the
tunnel's job without reconnects or health checks.

## 5. Emacs supervises the tunnel (overlay-provided)

The laptop Emacs runs the tunnel alias as an async `make-process`. Nothing
waits on the process, so an unreachable VM cannot block the editor.

- A process sentinel reconnects when ssh exits, with exponential backoff
  from 5 seconds to 5 minutes. The backoff resets after a minute of uptime,
  so one blip after hours of health retries promptly.
- Before each reconnect it runs the reaper once on the VM, over the
  no-forward alias, to clear a stale socket that would block the bind.
- A live ssh process does not prove a working forward. Unlinking a socket
  does not close its listener, so ssh can survive with nothing reachable at
  the path. A timer probes the socket every five minutes by running
  `emacsclient -e t` on the VM under `timeout`. Each check probes twice in a
  row. The tunnel restarts after two checks in a row fail, because one probe
  can fail on a network blip or a busy Emacs.

## 6. A reaper for a stale socket (overlay-provided)

When the tunnel dies abruptly, its socket file stays on the VM. With
`ExitOnForwardFailure`, that file makes every reconnect fail. A cron job on
the VM clears it once a minute:

    * * * * * ~/.local/bin/emacs-socket-reap.sh ~/.ssh/emacs-server

The reaper's rules:

- The test is whether `connect(2)` is accepted. A stale file refuses at
  once, and a live forward accepts even when Emacs is busy.
- It waits for repeated refusals over about five minutes before it unlinks
  anything. A late reap only delays the next bind, while unlinking a live
  socket kills the session.
- A `--now` mode probes once and skips the wait. The supervisor uses it just
  before it binds the path itself.
- With no probe tool available, it does nothing. No signal must not read as
  dead.
- The socket path is a required argument. On the laptop the same path is
  Emacs's own live socket, so no default is safe on both machines.

## What was dropped, and why

**habnabit's
[remote-emacsclient](https://github.com/habnabit/remote-emacsclient).** It
runs the server over TCP and adds a `-R` port forward to TRAMP's own ssh
login arguments. It made TRAMP hang, so its stanza in `packages.el` is
commented out. It also put a forward on every TRAMP connection.
`emacs/lisp/remote-emacsclient.el` is the old copy.

**A forward on every connection.** The `RemoteForward` once sat on the
normal host alias, so every ssh connection carried it. Whichever connection
came first owned the socket, the rest logged "remote port forwarding
failed", and the socket died when that session exited.

**A reaper that asked Emacs to answer.** It ran `emacsclient -e t` and
treated no answer as dead. A busy Emacs cannot answer, so a long synchronous
operation looked like a dead socket, and the reaper unlinked live sockets.

**A reaper that checked `ss -xl`.** It skipped the reap while `ss -xl`
listed the path. Unlinking leaves the old listener behind under the same
name, so once that had happened the check stayed true and the reaper could
not reap again.

**A probe that checked the socket file exists.** It passed for a forward
that accepted connections and never answered, so the supervisor's probe asks
for an answer.

## The minimum to copy

Sections 1, 3 and 4 are enough to start: the fixed socket, one tunnel alias
and the wrapper as `$EDITOR`. Sections 5 and 6 keep the forward alive across
disconnects, and you will want them once you depend on it.
