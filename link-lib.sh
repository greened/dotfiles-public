# Shared link helpers for the dotfiles base and its overlays.  Sourced, not run;
# callers set $GCLOCAL before using gclocal_add.

_dot_backup() {  # dest — replace an existing symlink, back up a real file
  local dest="$1"
  if [ -L "$dest" ]; then rm -f "$dest"
  elif [ -e "$dest" ]; then mv "$dest" "$dest.pre-dotfiles.$(date +%s)"; fi
}

link() {  # src dest — symlink dest -> src (backs up / replaces whatever is there)
  local src="$1" dest="$2"
  [ -e "$src" ] || { echo "   warn: missing $src (skip $(basename "$dest"))" >&2; return 0; }
  _dot_backup "$dest"
  mkdir -p "$(dirname "$dest")"
  ln -sfn "$src" "$dest"
}

realsource() {  # dest repofile — write dest as a real file that sources repofile
  local dest="$1" repofile="$2"
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
