#!/usr/bin/env bash
# Check how install.sh fetches overlays: a missing one is cloned as a git dev
# umbrella, an existing flat clone or umbrella is fast-forwarded, and anything
# it cannot use is left alone with a warning.
#
#     ./install-selftest.sh
#
# $HOME is not moved. install.sh's own paths, its manifests, DOTFILES_LIB and
# CLAUDE_HOME, point into a scratch tree, and the scratch base's link.sh is a
# stub. Git still reads the user's global config. Git runs no
# hooks here, since the user's hooks judge real repos and log to the real
# home. The remotes are local bare repos, so it needs no network. It needs git
# dev, as install.sh does, and fails rather than skips without it.
set -uo pipefail

export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null
# An inherited repo would take the fixture's ref moves instead of its remotes.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY
if [ "$(git config core.hooksPath)" != /dev/null ]; then
  echo "FAIL git ignored the hooks override, which needs git 2.31 or later"; exit 1
fi

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

pass=0 fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }
expect() {  # NAME CMD...: passes when CMD succeeds
  local name="$1"; shift
  if "$@"; then ok "$name"; else bad "$name"; fi
}
has() { grep -qF -- "$2" "$1"; }
lacks() { ! grep -qF -- "$2" "$1"; }

help="$(git dev clone --help 2>/dev/null)" || help=
case "$help" in
  *--worktree*) ;;
  *) echo "FAIL git dev clone --worktree (git-project) is not installed"; exit 1 ;;
esac

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cd "$tmp" || exit 1

# Every remote is a bare copy of this repo's main.
R="$tmp/remotes"; mkdir -p "$R"
git clone -q --bare --single-branch -b main "$here" "$R/base.git" || exit 1
seed_tip="$(git -C "$R/base.git" rev-parse main)"

# ovA and ovC start one commit behind, so the second run has something to
# fast-forward. ovB has only master.
for n in ovA ovB ovC ovE; do
  git clone -q --bare "file://$R/base.git" "$R/dotfiles-$n.git" || exit 1
done
for n in ovA ovC; do git -C "$R/dotfiles-$n.git" update-ref refs/heads/main main~1 || exit 1; done
git -C "$R/dotfiles-ovB.git" branch -m main master || exit 1
git -C "$R/dotfiles-ovB.git" symbolic-ref HEAD refs/heads/master || exit 1

# make_lib DIR: a DOTFILES_LIB with the base already cloned. Its link.sh is a
# stub, and its overlays.sh, which install.sh sources, is this tree's. Both
# stay out of the base's own fast-forward.
make_lib() {
  local b="$1/dotfiles"
  mkdir -p "$1/dotfiles-overlays"
  git clone -q "file://$R/base.git" "$b" || exit 1
  printf '#!/bin/sh\necho "   (stub link.sh)"\n' > "$b/link.sh"
  cp "$here/bash/lib/overlays.sh" "$b/bash/lib/overlays.sh"
  git -C "$b" update-index --skip-worktree link.sh bash/lib/overlays.sh || exit 1
}

L="$tmp/lib"; O="$L/dotfiles-overlays"
make_lib "$L"
git clone -q "file://$R/dotfiles-ovC.git" "$O/ovC" || exit 1  # an existing flat clone
mkdir -p "$O/ovD"; echo keep > "$O/ovD/keep"                   # a directory with no checkout
ln -s "$tmp/nowhere" "$O/ovS"                                  # a dangling symlink

# install.sh runs from inside a repo whose config must not change.
git init -q "$tmp/cwdrepo"
cp "$tmp/cwdrepo/.git/config" "$tmp/cwdrepo.config"

M="$tmp/overlays"
cat > "$M" <<EOF
ovA  file://$R/dotfiles-ovA.git  always
ovB  file://$R/dotfiles-ovB.git  always
ovC  file://$R/dotfiles-ovC.git  always
ovD  file://$R/dotfiles-ovD.git  always
ovX  file://$R/nonexistent.git   always
ovS  file://$R/nonexistent.git   always
EOF

# run LOG [VAR=VALUE...]: install.sh against LIB ($L unless overridden),
# with no stdin. Sets rc.
run() {
  local log="$1"; shift
  ( cd "$tmp/cwdrepo" && env DOTFILES_LIB="$L" DOTFILES_MANIFEST="$M" \
      DOTFILES_CLAUDE_MANIFEST="$tmp/claude-manifest" CLAUDE_HOME="$tmp/claude" \
      "$@" bash "$here/install.sh" test.host </dev/null ) >"$log" 2>&1
  rc=$?
}
order_is() { [ "$(tr '\n' ' ' < "${2:-$O}/.order")" = "$1" ]; }  # WANT [OVERLAYS]
tracks() { git -C "$1" rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1; }
one_behind() {
  [ "$(git -C "$1" rev-parse HEAD)" = "$(git -C "$R/base.git" rev-parse main~1)" ]
}
at_tip() { [ "$(git -C "$1" rev-parse HEAD)" = "$seed_tip" ]; }
show_log() { [ "$fail" -eq "$1" ] || sed 's/^/     | /' "$2"; }

# 1. Fresh clones.
f0=$fail
run "$tmp/run1.log"
expect 'run 1 succeeds' [ "$rc" -eq 0 ]
expect 'a missing overlay is cloned as an umbrella' \
       [ "$(git -C "$O/ovA/main" rev-parse --is-inside-work-tree 2>/dev/null)" = true ]
expect 'the umbrella main tracks its remote' tracks "$O/ovA/main"
expect 'run 1 leaves ovA one behind' one_behind "$O/ovA/main"
expect 'run 1 leaves ovC one behind' one_behind "$O/ovC"
expect 'an overlay with no main branch gets a rename hint' \
       has "$tmp/run1.log" 'ovB has no main branch'
expect 'a fresh clone hint names the worktree to move' \
       has "$tmp/run1.log" '/ovB/master main'
expect '.order lists only the overlays with a checkout' order_is 'ovA ovC '
expect 'a directory with no checkout is left as it was' \
       [ "$(ls -A "$O/ovD")" = keep ]
expect 'it warns about the directory' \
       has "$tmp/run1.log" 'ovD exists but holds no checkout'
expect 'a dangling symlink is kept' [ -L "$O/ovS" ]
expect 'it warns about the symlink' \
       has "$tmp/run1.log" 'ovS exists but holds no checkout'
expect 'an unreachable overlay leaves nothing behind' [ ! -e "$O/ovX" ]
expect 'it warns that the overlay could not be fetched' \
       has "$tmp/run1.log" 'could not fetch ovX, skipping.'
expect 'the repo install.sh runs from keeps its config' \
       cmp -s "$tmp/cwdrepo/.git/config" "$tmp/cwdrepo.config"
show_log "$f0" "$tmp/run1.log"

# 2. The remotes moved.
f0=$fail
for n in ovA ovC; do
  git -C "$R/dotfiles-$n.git" update-ref refs/heads/main "$seed_tip" || exit 1
done
run "$tmp/run2.log"
expect 'run 2 succeeds' [ "$rc" -eq 0 ]
expect 'an umbrella fast-forwards' at_tip "$O/ovA/main"
expect 'a flat clone fast-forwards' at_tip "$O/ovC"
expect 'an umbrella with no main still gets the rename hint' \
       has "$tmp/run2.log" 'ovB has no main branch'
expect 'an existing umbrella hint does not guess the worktree' \
       lacks "$tmp/run2.log" '/ovB/master main'
expect 'an umbrella with no main is not fetched as a flat clone' \
       lacks "$tmp/run2.log" 'could not fetch ovB'
expect '.order is unchanged' order_is 'ovA ovC '
show_log "$f0" "$tmp/run2.log"

# 3. git dev is missing but nothing needs a clone, so the install goes on. The
# PATH keeps git, bash and the system tools but not git dev. ovX goes, since it
# would need a clone. ovN is added with no URL.
f0=$fail
grep -v '^ovX ' "$M" > "$M.new" && mv "$M.new" "$M"
echo "ovN" >> "$M"
mkdir -p "$tmp/nogitdev"
ln -s "$(command -v git)" "$tmp/nogitdev/git"
ln -s "$(command -v bash)" "$tmp/nogitdev/bash"
nogitdev="$tmp/nogitdev:/usr/bin:/bin"
case "$(PATH="$nogitdev" git dev clone --help 2>/dev/null)" in
  *--worktree*) echo "FAIL git dev is still found on the PATH meant to lack it"; exit 1 ;;
esac
run "$tmp/run3.log" PATH="$nogitdev"
expect 'run 3 succeeds' [ "$rc" -eq 0 ]
expect 'it does not ask for git dev' lacks "$tmp/run3.log" 'cannot clone overlay'
expect 'an overlay with no URL is skipped' has "$tmp/run3.log" 'skip ovN (no URL)'
expect '.order is rewritten as before' order_is 'ovA ovC '
show_log "$f0" "$tmp/run3.log"

# 4. git dev is still missing and ovE needs a clone.
f0=$fail
echo "ovE  file://$R/dotfiles-ovE.git  always" >> "$M"
cp "$O/.order" "$tmp/order.before"
run "$tmp/run4.log" PATH="$nogitdev"
expect 'run 4 stops' [ "$rc" -ne 0 ]
expect 'it names the overlay it cannot clone' \
       has "$tmp/run4.log" 'cannot clone overlay ovE'
expect 'it says how to install git dev' \
       has "$tmp/run4.log" 'uv tool install git-project'
expect 'nothing is cloned' [ ! -e "$O/ovE" ]
expect '.order is not rewritten' cmp -s "$O/.order" "$tmp/order.before"
show_log "$f0" "$tmp/run4.log"

# 5. git dev is back.
f0=$fail
run "$tmp/run5.log"
expect 'run 5 succeeds' [ "$rc" -eq 0 ]
expect 'the new overlay is cloned' [ -e "$O/ovE/main/.git" ]
expect 'it is appended to .order' order_is 'ovA ovC ovE '
show_log "$f0" "$tmp/run5.log"

# 6. The overlay directory is inside a git repo, where git dev would write
# its project defaults.
f0=$fail
git init -q "$tmp/inrepo"
L2="$tmp/inrepo/lib"
make_lib "$L2"
git clone -q "file://$R/dotfiles-ovC.git" "$L2/dotfiles-overlays/ovC" || exit 1
run "$tmp/run6.log" DOTFILES_LIB="$L2"
expect 'run 6 succeeds' [ "$rc" -eq 0 ]
expect 'it warns that the parent is inside a repo' \
       has "$tmp/run6.log" 'is inside a git repo'
expect 'nothing is cloned there' [ ! -e "$L2/dotfiles-overlays/ovA" ]
expect 'an existing flat clone there is still used' \
       order_is 'ovC ' "$L2/dotfiles-overlays"
show_log "$f0" "$tmp/run6.log"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
