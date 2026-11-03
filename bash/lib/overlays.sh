# -*-sh-*-

# dir: print the checkout of the overlay at dir: its main worktree when dir
# is a git-project umbrella, otherwise dir itself.
dot_overlay_checkout() {
  if [ -e "$1/main/.git" ]; then printf '%s\n' "$1/main"; else printf '%s\n' "$1"; fi
}
