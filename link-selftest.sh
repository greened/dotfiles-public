#!/usr/bin/env bash
# Check the symlinked-parent guard and unlink_managed in link-lib.sh:
#
#     ./link-selftest.sh
#
# The guard exists because a redirected $HOME once wrote through a symlinked
# parent into the real home and replaced ~/.ssh/config.  That is worth a test,
# and the test has to be able to set up the clobber WITHOUT performing it, so
# it only calls _dot_parent_ok, which decides and prints and never writes.
# Nothing here runs link.sh or install.sh against a fake home: that is the very
# thing that caused the damage.
#
# unlink_managed does remove links, so its cases run on links made here in the
# scratch tree, with $HOME pointing into it.
#
# Cases 3-5 need $HOME to differ from the account's home, so they stub
# _dot_account_home rather than depend on whoever is running this.  Case 0
# covers the real lookup.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/link-lib.sh"

pass=0 fail=0
check() {  # want-rc name -- runs _dot_parent_ok "$dest" with $HOME already set
  local want="$1" name="$2" dest="$3" out rc
  out="$(_dot_parent_ok "$dest" 2>&1)"; rc=$?
  if [ "$rc" = "$want" ]; then
    pass=$((pass + 1)); printf 'ok   %s\n' "$name"
  else
    fail=$((fail + 1))
    printf 'FAIL %s (rc=%s want=%s)\n%s\n' "$name" "$rc" "$want" "$out"
  fi
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# 0. The account lookup finds a home, and agrees with $HOME in a normal shell.
account="$(_dot_account_home)"
if [ -n "$account" ]; then
  pass=$((pass + 1)); printf 'ok   account home resolves (%s)\n' "$account"
else
  fail=$((fail + 1)); printf 'FAIL account home did not resolve\n'
fi

fake="$tmp/home"; mkdir -p "$fake"
elsewhere="$tmp/elsewhere"; mkdir -p "$elsewhere"
mkdir -p "$fake/real" "$fake/inside"
ln -s "$fake/inside" "$fake/link-inside"
ln -s "$elsewhere" "$fake/link-outside"

# 1-2, 6. Parent needs no vouching for: it is $HOME, a real directory, or a
# symlink whose target cannot leave $HOME.  True whether or not $HOME is real.
HOME="$fake" check 0 'parent is $HOME'            "$fake/.gitconfig"
HOME="$fake" check 0 'parent is a real directory' "$fake/real/x"
HOME="$fake" check 0 'parent links inside $HOME'  "$fake/link-inside/x"

# 3. Own home, parent leaves it: the ~/.config-on-a-network-volume arrangement.
_dot_account_home() { printf '%s\n' "$(cd "$fake" && pwd -P)"; }
HOME="$fake" check 0 'own home, parent links out' "$fake/link-outside/x"

# 4-5. $HOME redirected, parent leaves it -- the clobber, and its general form.
# The account home is outside the fake $HOME, as the real one was: $HOME was a
# scratch directory and the symlink pointed back at the home being protected.
account_home="$tmp/account"; mkdir -p "$account_home/.ssh"
_dot_account_home() { printf '%s\n' "$(cd "$account_home" && pwd -P)"; }
ln -s "$account_home/.ssh" "$fake/link-account-ssh"
HOME="$fake" check 1 'redirected home, parent links to account home' \
                     "$fake/link-account-ssh/config"
HOME="$fake" check 1 'redirected home, parent links elsewhere' \
                     "$fake/link-outside/x"

# 7. Account home unreadable: $HOME is unvouched-for, so check it.
_dot_account_home() { printf '\n'; }
HOME="$fake" check 1 'no account home, parent links out' "$fake/link-outside/x"

# unlink_managed: which obsolete links are retired, and which are left alone.
uhome="$tmp/uhome"; mkdir -p "$uhome/dotfiles" "$uhome/lib/dotfiles"
uelse="$tmp/uelse"; mkdir -p "$uelse/dotfiles"
check_unlink() {  # want name dest, where want is gone or kept
  local want="$1" name="$2" dest="$3" got=kept
  HOME="$uhome" unlink_managed "$dest"
  [ -e "$dest" ] || [ -L "$dest" ] || got=gone
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1)); printf 'ok   %s\n' "$name"
  else
    fail=$((fail + 1)); printf 'FAIL %s (%s, want %s)\n' "$name" "$got" "$want"
  fi
}
ln -s "$uhome/lib/dotfiles/x" "$uhome/.lib-link"
check_unlink gone 'unlink: a link into lib/dotfiles' "$uhome/.lib-link"
ln -s "$uhome/dotfiles/news/newsrc-dribble" "$uhome/.newsrc-dribble"
check_unlink gone 'unlink: a link into the old ~/dotfiles' "$uhome/.newsrc-dribble"
ln -s "$uelse/dotfiles/x" "$uhome/.else-link"
check_unlink kept 'unlink: a dotfiles directory outside $HOME' "$uhome/.else-link"
ln -s "$uhome/dotfiles-other/x" "$uhome/.near-link"
check_unlink kept 'unlink: a sibling named like dotfiles' "$uhome/.near-link"
ln -s "$uhome/dotfiles" "$uhome/.whole-link"
check_unlink kept 'unlink: the old checkout itself' "$uhome/.whole-link"
: > "$uhome/.real-file"
check_unlink kept 'unlink: a real file' "$uhome/.real-file"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
