# vterm-reconnect

Open ssh sessions in [`vterm`](https://github.com/akermu/emacs-libvterm), and —
the point of this package — respawn one that has gone **stale** in a single
command.

## The problem it solves

You keep a long-lived `vterm` ssh'd into a work host, and that connection carries
a `RemoteForward` tunnel — e.g. forwarding your local Emacs server port back to
the remote so remote `emacsclient` opens files in your local Emacs. When the
tunnel's socket dies, the vterm is still "alive" but useless: the shell responds,
but the forward is gone.

`vterm-reconnect` tears down the dead session and starts a fresh one in one
keystroke, matching the host as a substring of any vterm/term buffer name (so it
still finds the buffer after vterm's title-tracking has renamed it).

## Commands

| Command                   | What it does                                              |
|---------------------------|-----------------------------------------------------------|
| `vterm-ssh`               | Open a new vterm and ssh to a host                        |
| `vterm-reconnect`         | Kill any live vterm/term buffer(s) for a host, then respawn a fresh ssh vterm |
| `vterm-reconnect-default` | Reconnect `vterm-reconnect-host`                          |

Run these locally in your Emacs; do **not** drive `vterm-reconnect` over the very
socket it is rebuilding.

## Setup

This is a **local-but-shareable** package: a self-contained, publishable package
that currently lives inside dotfiles. Its own `use-package` block owns loading it
(via `:load-path`), so it behaves exactly like a fetched package and does not
depend on any global `load-path` setup.

```elisp
(use-package vterm-reconnect
  :ensure nil                           ; local package; do not let elpaca fetch
  ;; Lambda (not a bare form): use-package treats a list as a list-of-paths.
  :load-path (lambda () (list (expand-file-name "lisp/vterm-reconnect" emacs-root)))
  :after vterm
  :custom (vterm-reconnect-host "user@host")   ; the host you keep reconnecting
  :bind ("C-c R" . vterm-reconnect-default))
```

`vterm-reconnect-host` is the host `vterm-reconnect-default` targets; leave it nil
to be prompted.

### Extracting to its own repo later

Because the block above is self-contained, publishing this directory as a
standalone repo is a one-line swap — replace the `:ensure nil` + `:load-path`
lines with an elpaca recipe, and nothing else in the block changes:

```elisp
  :ensure (vterm-reconnect :host github :repo "USER/vterm-reconnect")
```
