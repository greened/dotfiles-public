# Shared link helpers for the dotfiles base and its overlays.  Sourced, not run;
# callers set $GCLOCAL before using gclocal_add.

_dot_backup() {  # dest — replace an existing symlink, back up a real file
  local dest="$1"
  if [ -L "$dest" ]; then rm -f "$dest"
  elif [ -e "$dest" ]; then mv "$dest" "$dest.pre-dotfiles.$(date +%s)"; fi
}

# dest — fail if dest's parent directory is a symlink pointing outside $HOME.
#
# `mkdir -p` and `ln` both FOLLOW a symlinked parent, so deploying e.g.
# ~/.ssh/config while ~/.ssh is a symlink writes into whatever that points at
# rather than into the home we were asked to deploy into.  That is not
# hypothetical: running this with $HOME redirected to a scratch directory whose
# .ssh symlinks back to the real one silently replaced the real ~/.ssh/config.
# Deploying into someone else's home is never what was meant, so fail closed and
# say which link and which directory.
#
# The fault there was the REDIRECTED $HOME, though, not the symlink: escaping
# $HOME only does damage when $HOME is not where this account lives.  Deploying
# into your own home, a symlinked parent is your own arrangement and may point
# wherever you keep things -- ~/.config on a network volume is ordinary, and
# refusing it would be a guard that blocks the install it was added to protect.
# So the check applies when $HOME differs from the account's home, and also when
# the account's home cannot be read, which leaves $HOME unvouched-for.
#
# $HOME itself is never inspected: a symlinked home (/home/x -> /var/home/x) is
# normal, and both sides are compared resolved.
_dot_account_home() {
  local h
  h="$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f6)" || h=''
  [ -n "$h" ] || h="$(eval echo "~$(id -un)" 2>/dev/null)"
  case "$h" in
    /*) (cd "$h" 2>/dev/null && pwd -P) ;;
  esac
}

_dot_parent_ok() {
  local dest="$1" parent real_parent real_home account_home
  parent="$(dirname "$dest")"
  [ "$parent" = "$HOME" ] && return 0
  [ -L "$parent" ] || return 0
  real_home="$(cd "$HOME" 2>/dev/null && pwd -P)" || return 0
  account_home="$(_dot_account_home)"
  [ -n "$account_home" ] && [ "$real_home" = "$account_home" ] && return 0
  real_parent="$(cd "$parent" 2>/dev/null && pwd -P)" || return 0
  case "$real_parent" in
    "$real_home"|"$real_home"/*) return 0 ;;
  esac
  echo "!! refusing $dest: \$HOME is $real_home, but this account's home is" >&2
  echo "   ${account_home:-unreadable}, and parent $parent is a symlink to" >&2
  echo "   $real_parent -- outside \$HOME.  Writing there would modify a home" >&2
  echo "   you did not ask to deploy into.  Point \$HOME at the tree you mean," >&2
  echo "   or make the parent a real directory." >&2
  return 1
}

link() {  # src dest — symlink dest -> src (backs up / replaces whatever is there)
  local src="$1" dest="$2"
  [ -e "$src" ] || { echo "   warn: missing $src (skip $(basename "$dest"))" >&2; return 0; }
  _dot_parent_ok "$dest" || return 1
  _dot_backup "$dest"
  mkdir -p "$(dirname "$dest")"
  ln -sfn "$src" "$dest"
}

realsource() {  # dest repofile — write dest as a real file that sources repofile
  local dest="$1" repofile="$2"
  _dot_parent_ok "$dest" || return 1
  _dot_backup "$dest"
  printf '# managed: source the dotfiles base\n[ -r "%s" ] && . "%s"\n' "$repofile" "$repofile" > "$dest"
}

unlink_managed() {  # dest — retire an obsolete link, but ONLY if it is a symlink
  # into the dotfiles tree (one a prior install made); never touch a real file.
  local dest="$1" t
  [ -L "$dest" ] || return 0
  t="$(readlink "$dest")"
  case "$t" in
    */lib/dotfiles/*|*/lib/dotfiles-overlays/*|lib/dotfiles/*|lib/dotfiles-overlays/*) rm -f "$dest" ;;
  esac
}

gclocal_add() {  # gitconfig-fragment — append an include line to $GCLOCAL
  local cfg="$1"
  [ -r "$cfg" ] || return 0
  [ -n "${GCLOCAL:-}" ] || return 0
  printf '\tpath = %s\n' "$cfg" >> "$GCLOCAL"
}
