# dotfiles

A generic, public base of shell, editor, and terminal configuration, designed to
be composed with private **overlay** repos so that machine-specific, personal,
and work settings live outside this repo.

## The idea: a base plus overlays

This repo is a *base* that anyone can use as-is.  On top of it you layer one or
more **overlay** repos — each a small repo with the same tool subdirectories —
and the base discovers and pulls them in automatically.  The set of overlays you
clone on a given machine *is* that machine's configuration; there is no
per-machine editing of the base.

    ~/lib/dotfiles/                  this repo (the public base)
    ~/lib/dotfiles-overlays/<name>/  overlay repos, cloned per machine

The base globs `~/lib/dotfiles-overlays/*/` and pulls in matching files — it never
names a specific overlay, so nothing private appears here:

| Tool  | How the base pulls overlays in                              |
|-------|-------------------------------------------------------------|
| bash  | sources `*/bash/*.sh`                                        |
| emacs | loads `*/emacs/*.el`                                         |
| ssh   | `Include`s `*/ssh/config`                                    |
| tmux  | `source-file`s `*/tmux/*.conf`                              |
| git   | each overlay's `git/config` is added to `~/.gitconfig.local` |

An overlay can also deploy files the base globs don't cover (mail, news, gdb, …)
and retire obsolete ones, through its own `link.sh` (see below).

## Example

Suppose you want your generic setup everywhere, your personal identity and mail
on every machine you own, and some settings only on your work laptop.  Create
three overlays:

    ~/lib/dotfiles-overlays/
      personal-config/   # public-ish personal choices: editor style, key maps
      personal-secret/   # identity, email/mail, news — private
      work/              # employer identity and tools — private

- `personal-config/git/gitconfig` is your `~/.gitconfig` entry point: it includes
  the generic base and then `~/.gitconfig.local`.
- `personal-secret/git/config` sets your personal name/email; `work/git/config`
  sets your employer email and, because it is applied later, wins on the work
  machine.
- `work/link.sh` might deploy `~/.gdbinit` and a commit template; a home overlay
  might deploy `~/.mbsyncrc` and news files.

Clone only the overlays that apply to a machine — the work overlay stays off your
personal boxes — and everything composes automatically.

## The overlay manifest

Because the base names no overlay, `install.sh` learns *your* overlays from a
private **manifest** — `$DOTFILES_MANIFEST` (default `~/.config/dotfiles/overlays`),
one entry per line:

    # name             url                                              match
    personal-config    git@github.com:you/dotfiles-personal-config.git  always
    personal-secret    git@github.com:you/dotfiles-personal-secret.git  always
    work               git@github.com:you/dotfiles-work.git             *.work.example.com

`match` is `always`, or a shell glob (with `a|b` alternation) tested against the
machine's hostname — so a work overlay lands only on work hosts.  This file lives
outside the public repo, so your overlay names, URLs, and host patterns stay
private.

## Install (fresh machine)

The installer lives in this repo, so fetch it first (and place your manifest):

    git clone git@github.com:greened/dotfiles-public.git ~/lib/dotfiles
    ~/lib/dotfiles/install.sh

or, in one line:

    curl -fsSL https://raw.githubusercontent.com/greened/dotfiles-public/main/install.sh | bash

`install.sh [host-override]` clones the base, selects the overlays whose `match`
applies to this machine, **suggests an apply order and lets you confirm or reorder
it**, clones them, and runs the base `link.sh`.  The chosen order is recorded in
`~/lib/dotfiles-overlays/.order` so re-runs are stable.  Matches against the FQDN
by default; pass a hostname to override.  Re-run any time to update.

Prerequisites: `git`, and a GitHub SSH key (needed to clone private overlays; the
public base alone works without one — a missing overlay just warns and is
skipped).

### SSH identity for private overlays

If the SSH key your machine offers for `github.com` authenticates as a *different*
GitHub account than the one that owns your private overlays, the public base still
clones (any authenticated key can read a public repo) but every private overlay
fails with `ERROR: Repository not found.` — GitHub hides a private repo from the
wrong identity, so it reads as "missing" rather than "denied."

Point git at the right key for the run:

    GIT_SSH_COMMAND="ssh -i ~/.ssh/<your-key> -o IdentitiesOnly=yes" \
      ~/lib/dotfiles/install.sh

`IdentitiesOnly=yes` stops ssh from falling back to the wrong agent key.  The key
must already exist on the machine — copy it over before the first install.  To
make it permanent, add a `github.com` block to `~/.ssh/config` with the matching
`IdentityFile`.

## Deployment model

`~/.bashrc` and `~/.bash_profile` are written as **real files that source** the
repo, so a hostile reset of `~/.bashrc` cannot corrupt the repo — it only
rewrites the throwaway file.  Every other target is a symlink.  `link.sh` backs
up any pre-existing real file before replacing it, and after a full deploy it
reports any symlink still dangling into the dotfiles tree — that means an overlay
`link.sh` is missing coverage (a bug to fix, not something to silently delete).

## Writing an overlay

An overlay is just a repo with the same tool subdirectories (`bash/`, `emacs/`,
`ssh/`, `tmux/`, `git/`).  Clone it into `~/lib/dotfiles-overlays/<name>/` and it
is live on the next shell.  Two things to know:

- **Globbed tools** (bash/emacs/ssh/tmux) need nothing extra — just drop a file
  in the matching subdirectory.
- **Everything else** goes in the overlay's own `link.sh`, which the base runs
  after itself.  It receives helpers via `$DOTFILES_LINK_LIB`, so source that:

      #!/usr/bin/env bash
      set -eu
      . "${DOTFILES_LINK_LIB:?run via the base link.sh}"
      OV="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
      link "$OV/mail/mbsyncrc" "$HOME/.mbsyncrc"   # symlink, backs up any existing
      gclocal_add "$OV/git/config"                 # add to ~/.gitconfig.local
      unlink_managed "$HOME/.obsolete-thing"       # retire a link you no longer ship

Whatever an overlay links, it should keep linking (or `unlink_managed`) so that a
reinstall never leaves a dangling link behind.
