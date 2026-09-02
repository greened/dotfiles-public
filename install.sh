#!/usr/bin/env bash
# Install or update the overlay dotfiles layout.  Generic: this public base names
# no specific overlay or host.  Overlays come from a private MANIFEST you provide:
#   $DOTFILES_MANIFEST  (default ~/.config/dotfiles/overlays)
# one "name url match" per line, where match is 'always' or a shell glob tested
# against this machine's hostname (e.g. *.example.com, or a|b alternation).  Lines
# starting with # are ignored.  install.sh clones the base, selects the overlays
# whose match applies here, lets you confirm their apply order, clones them, and
# runs the base link.sh.  Then, if a Claude-config manifest exists
# ($DOTFILES_CLAUDE_MANIFEST, default ~/.config/dotfiles/claude), it applies the
# same base+overlays idea to ~/.claude — cloning your Claude repos and running
# each one's link step.  Idempotent.
# Usage: install.sh [host-override]   (default: this machine's FQDN)
#
# Fresh machine (the script lives in the repo, so fetch it first; put your overlay
# manifest at ~/.config/dotfiles/overlays):
#   git clone git@github.com:greened/dotfiles-public.git ~/lib/dotfiles \
#     && ~/lib/dotfiles/install.sh
# or, once the repo is public:
#   curl -fsSL https://raw.githubusercontent.com/greened/dotfiles-public/main/install.sh | bash
# Prerequisites: git, and a GitHub SSH key (required for private overlays).
set -euo pipefail

PUBLIC_URL="git@github.com:greened/dotfiles-public.git"
LIB="${DOTFILES_LIB:-$HOME/lib}"; PUB="$LIB/dotfiles"; OVERLAYS="$LIB/dotfiles-overlays"
MANIFEST="${DOTFILES_MANIFEST:-$HOME/.config/dotfiles/overlays}"

host="${1:-$(hostname -f 2>/dev/null || hostname)}"
echo ">> host: $host"

# get URL DIR [required] — clone if absent, else fast-forward pull.  A failure
# aborts only for a "required" repo (the base); an overlay that can't be fetched
# (e.g. no SSH key yet) just warns, so a partial install still succeeds.
get() {
  local url="$1" dir="$2" required="${3:-}" rc=0
  [ -n "$url" ] || { echo "   skip $(basename "$dir") (no URL)"; return 0; }
  if [ -d "$dir/.git" ]; then git -C "$dir" pull --ff-only || rc=$?
  else git clone "$url" "$dir" || { rc=$?; rm -rf "$dir"; }; fi
  if [ "$rc" -ne 0 ]; then
    if [ "$required" = required ]; then echo "!! failed to fetch required $(basename "$dir") — aborting" >&2; return "$rc"; fi
    echo "   warn: could not fetch $(basename "$dir") — skipping" >&2
  fi
  return 0
}

mkdir -p "$LIB" "$OVERLAYS"
get "$PUBLIC_URL" "$PUB" required

# --- overlays from the private manifest --------------------------------------
if [ ! -r "$MANIFEST" ]; then
  # Scaffold a commented template so a fresh machine has a starting point.  The
  # public base names no private overlays, so the examples are placeholders you
  # replace with your own repos.
  echo ">> no overlay manifest at $MANIFEST — scaffolding a template."
  mkdir -p "$(dirname "$MANIFEST")"
  cat > "$MANIFEST" <<'EOF'
# Private dotfiles overlay manifest — read by install.sh.
# One entry per line:  name  url  [match]
#   name   directory under ~/lib/dotfiles-overlays to clone the overlay into
#   url    git remote to clone/pull
#   match  'always', or a shell glob (a|b alternation ok) tested against this
#          machine's FQDN; omit to default to 'always'
# Lines starting with # are ignored.  Replace the examples with your overlays
# and re-run install.sh.
#
# personal   git@github.com:you/dotfiles-personal.git   always
# work       git@github.com:you/dotfiles-work.git        *.corp.example.com
EOF
  echo "   edit it to add your overlays, then re-run install.sh — base only for now."
else
  # Select overlays whose match is 'always' or a glob matching this host.
  entries=()   # each: "name|url"
  while read -r name url match _; do
    case "$name" in ''|\#*) continue ;; esac
    match="${match:-always}"
    if [ "$match" = always ]; then
      entries+=("$name|$url")
    else
      # match may hold |-separated globs; test each one (case/[[ can't alternate
      # a pattern that comes from a variable, so split it ourselves).
      IFS='|' read -ra globs <<< "$match"
      for g in "${globs[@]}"; do
        if [[ "$host" == $g ]]; then entries+=("$name|$url"); break; fi
      done
    fi
  done < "$MANIFEST"

  if [ "${#entries[@]}" -gt 0 ]; then
    echo ">> overlays for '$host' (suggested apply order — later overlays win):"
    i=1; for e in "${entries[@]}"; do echo "     $i) ${e%%|*}"; i=$((i + 1)); done
    if [ -t 0 ]; then
      read -r -p ">> accept this order?  [Enter]=yes, or list numbers (e.g. '2 1 3'): " reply || reply=""
      if [ -n "$reply" ]; then
        reordered=()
        for idx in $reply; do
          if [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -ge 1 ] && [ "$idx" -le "${#entries[@]}" ]; then
            reordered+=("${entries[$((idx - 1))]}")
          else echo "   ignoring invalid entry: $idx" >&2; fi
        done
        [ "${#reordered[@]}" -gt 0 ] && entries=("${reordered[@]}")
      fi
    else
      echo "   (non-interactive: using suggested order)"
    fi

    # Clone each, and record the apply order for link.sh (the base names nothing).
    : > "$OVERLAYS/.order"
    for e in "${entries[@]}"; do
      name="${e%%|*}"; url="${e#*|}"
      get "$url" "$OVERLAYS/$name"
      [ -d "$OVERLAYS/$name/.git" ] && printf '%s\n' "$name" >> "$OVERLAYS/.order"
    done
  fi
fi

bash "$PUB/link.sh"

# --- Claude Code config from a private manifest ------------------------------
# The same base+overlays idea as the dotfiles overlays above, applied to
# ~/.claude: a LIST of repos, each cloned under $CLAUDE_HOME and linked into
# ~/.claude by its own link step.  This is where the public/private split lives:
# list a PUBLIC base repo first (genuinely shareable skills/agents), then PRIVATE
# overlays (work, personal) after it.  Each repo is its own trust
# boundary -- the public repo is authored public, never filtered from a private
# one -- and the link step composes them all flat into ~/.claude, so the tiers
# coexist at runtime while living in separate repos.  The public dotfiles base
# names none of them; your list lives in the manifest.  Optional: no manifest =>
# this phase is skipped.
CLAUDE_MANIFEST="${DOTFILES_CLAUDE_MANIFEST:-$HOME/.config/dotfiles/claude}"
CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
if [ ! -r "$CLAUDE_MANIFEST" ]; then
  echo ">> no Claude-config manifest at $CLAUDE_MANIFEST — scaffolding a template."
  mkdir -p "$(dirname "$CLAUDE_MANIFEST")"
  cat > "$CLAUDE_MANIFEST" <<'EOF'
# Claude Code config repos — read by install.sh (optional; delete to skip).
# One entry per line:  name  url  [link]
#   name   directory under ~/.claude to clone into
#   url    git remote to clone/pull
#   link   script (relative to the repo) run after fetch to symlink the repo
#          into ~/.claude; default bin/relink.sh.  '-' or 'none' = clone only.
# Lines starting with # are ignored.  List a PUBLIC base first, then PRIVATE
# overlays — later entries layer on top.  Each repo is its own trust boundary
# (the public one is safe to publish); the link step composes them flat into
# ~/.claude, so public / work / personal skills coexist in separate repos.
#
# claude-public    git@github.com:you/claude-public.git    bin/relink.sh
# skills-personal  git@github.com:you/skills-personal.git   bin/relink.sh
EOF
  echo "   edit it to add your Claude repos, then re-run install.sh — skipping for now."
else
  mkdir -p "$CLAUDE_HOME"
  while read -r name url link _; do
    case "$name" in ''|\#*) continue ;; esac
    [ -n "$url" ] || { echo "   skip claude/$name (no URL)"; continue; }
    get "$url" "$CLAUDE_HOME/$name"
    [ -d "$CLAUDE_HOME/$name/.git" ] || continue
    case "$link" in
      ''|bin/relink.sh) link=bin/relink.sh ;;
      -|none) echo "   claude/$name: cloned (no link step)"; continue ;;
    esac
    if [ -r "$CLAUDE_HOME/$name/$link" ]; then
      echo ">> linking claude/$name ($link)"
      ( cd "$CLAUDE_HOME/$name" && bash "$link" ) || echo "   warn: link step failed for $name" >&2
    else
      echo "   warn: claude/$name has no link step at $link — cloned only" >&2
    fi
  done < "$CLAUDE_MANIFEST"
fi

echo ">> done — open a new shell."
