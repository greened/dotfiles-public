#!/usr/bin/env bash
# Deploy the public base into $HOME, then run each overlay's own link script.
# ~/.bashrc and ~/.bash_profile are REAL files that *source* the repo, so a reset
# of ~/.bashrc can't corrupt the repo; everything else is a symlink.  Idempotent:
# backs up pre-existing real files, replaces stale symlinks.  After a full deploy,
# a symlink still dangling into the dotfiles tree is a bug and is reported.
set -eu
PUB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OVERLAYS="$(dirname "$PUB")/dotfiles-overlays"
# The GENERATED overlay manifest, rewritten from scratch below.  Named
# .gitconfig.overlays and not .gitconfig.local because it is a build
# artifact: anything hand-written in it is lost on the next run.
# ~/.gitconfig.local is now the hand-written per-machine file, which this
# script never touches.
export GCOVERLAYS="$HOME/.gitconfig.overlays"
export DOTFILES_LINK_LIB="$PUB/link-lib.sh"
. "$DOTFILES_LINK_LIB"

# --- base files (generic; usable on their own) ---
realsource "$HOME/.bashrc"       "$PUB/bash/bashrc"
realsource "$HOME/.bash_profile" "$PUB/bash/bash_profile"
link "$PUB/emacs/emacsrc"        "$HOME/.emacs"
link "$PUB/emacs/gnusrc"         "$HOME/.gnus"

# MCP stdio transport for the elisp MCP servers, vendored from mcp-server-lib
# (see the header in that file).  It goes to ~/.local/bin rather than being
# sourced, because the MCP clients spawn it as a program: they run on a remote
# host where the elisp package -- and so the packaged copy of this script -- is
# not installed.  Every machine with this repo now has it, instead of the one
# machine where it had been hand-copied.  `link' mkdir -p's the parent, and the
# exec bit comes from the repo file.
link "$PUB/emacs/emacs-mcp-stdio.sh" "$HOME/.local/bin/emacs-mcp-stdio.sh"

# Open a frame on the Emacs that owns the server socket, instead of starting a
# second Emacs that owns nothing.  A program, so it lands in ~/.local/bin like
# the transport above; the macOS Dock bundle below is only a stub that execs it.
link "$PUB/bin/emacs-frame"          "$HOME/.local/bin/emacs-frame"

# The Dock will take nothing but an .app, and a bundle is an awkward thing to
# keep in git, so the bundle here is a stub and all the behaviour lives in
# bin/emacs-frame.  First platform conditional in this file: link.sh also runs
# on Linux dev hosts, where a macOS bundle in ~/Applications is just litter.
# The icon is copied rather than committed -- it belongs to whichever Emacs is
# installed -- and is gitignored.  Update the source path here if Emacs moves.
if [ "$(uname)" = Darwin ]; then
  # The icon goes into the source bundle BEFORE the copy below, or the copy
  # would not carry it.  mkdir -p because git carries no empty directory, so
  # Resources/ does not exist in a fresh clone and the copy would fail there --
  # on exactly the machine this is for.  And warn rather than discard the
  # error: a missing icon is cosmetic, but a copy that fails in silence is how
  # the bundle ends up with the generic icon and nobody can say why.
  icns="/opt/homebrew/opt/emacs-plus@31/Emacs.app/Contents/Resources/Emacs.icns"
  mkdir -p "$PUB/macos/EmacsFrame.app/Contents/Resources"
  if ! cp -f "$icns" "$PUB/macos/EmacsFrame.app/Contents/Resources/Emacs.icns"; then
    echo "   warn: no Emacs icon at $icns -- EmacsFrame.app keeps the generic one" >&2
  fi
  # COPY the bundle; do NOT `link' it.  The Dock will not pin a symlinked .app
  # among the applications -- it files it under persistent-others, the folders
  # section right of the divider, and refuses to move it left.  A copy is cheap
  # to keep current because the bundle is a stub that execs bin/emacs-frame and
  # holds no behaviour of its own.
  #
  # rm -rf rather than _dot_backup: the deployed bundle is a real directory, so
  # _dot_backup would rename it aside and leave one dated copy per run.
  # EmacsFrame.app is a name this repo invented, so the path is ours to replace.
  #
  # _dot_parent_ok still applies, though, and `link' calls it before the backup:
  # it refuses a symlinked parent that leaves $HOME when $HOME is not this
  # account's home.  Skipping it here was an oversight, not a decision.
  _dot_parent_ok "$HOME/Applications/EmacsFrame.app" || exit 1
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/EmacsFrame.app"
  cp -R "$PUB/macos/EmacsFrame.app" "$HOME/Applications/EmacsFrame.app"
fi

link "$PUB/tmux/tmux.conf"       "$HOME/.tmux.conf"
link "$PUB/ssh/config"           "$HOME/.ssh/config"
link "$PUB/gnupg/gpg-agent.conf" "$HOME/.gnupg/gpg-agent.conf"
link "$PUB/dircolors/dir_colors" "$HOME/.dir_colors"
link "$PUB/screen/screenrc"      "$HOME/.screenrc"
link "$PUB/terminfo"             "$HOME/.terminfo"

# --- overlays: start a fresh git include list, then run each overlay's link.sh
# in the order install.sh recorded in .order (later overlays win), falling back
# to a sorted glob.  The base itself names no specific overlay. ---
# Read the order into an array with a while-read loop rather than `mapfile`, which
# is a bash 4+ builtin absent from the bash 3.2 that macOS ships as /bin/bash.
printf '# generated by link.sh from the cloned overlays -- do NOT edit;\n# hand-written machine settings go in ~/.gitconfig.local\n[include]\n' > "$GCOVERLAYS"
overlay_order=()
if [ -r "$OVERLAYS/.order" ]; then
  while IFS= read -r name; do overlay_order+=("$name"); done \
    < <(grep -vE '^[[:space:]]*(#|$)' "$OVERLAYS/.order")
else
  while IFS= read -r name; do overlay_order+=("$name"); done \
    < <(cd "$OVERLAYS" 2>/dev/null && for d in */; do [ -d "$d" ] && printf '%s\n' "${d%/}"; done | sort)
fi
for name in "${overlay_order[@]:-}"; do
  [ -n "$name" ] || continue
  ov="$OVERLAYS/$name"
  if [ -r "$ov/link.sh" ]; then echo ">> linking overlay $name"; bash "$ov/link.sh"; fi
done

# --- verify: after a full deploy nothing should dangle into the dotfiles tree ---
bad=0
while IFS= read -r l; do
  t="$(readlink "$l")"
  case "$t" in
    "$PUB"/*|"$OVERLAYS"/*|*/lib/dotfiles/*|*/lib/dotfiles-overlays/*|lib/dotfiles/*|lib/dotfiles-overlays/*)
      if [ ! -e "$l" ]; then echo "!! STALE LINK (bug): $l -> $t" >&2; bad=$((bad + 1)); fi ;;
  esac
done < <(find "$HOME" -maxdepth 2 -type l 2>/dev/null)
if [ "$bad" -ne 0 ]; then
  echo "!! $bad stale link(s) into the dotfiles tree — an overlay link script is missing coverage" >&2
else
  echo "linked \$HOME -> dotfiles (base + overlays, no stale links)"
fi
