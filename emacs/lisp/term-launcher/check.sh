#!/usr/bin/env bash
# Byte-compile term-launcher.el warnings-fatal and run its tests.
#
#     ./check.sh
#
# The tests cover what the package DECIDES -- which command a key gets, which
# host the reconnect default picks, and whether the domain suffix is applied --
# and never open a terminal.  `vterm', `vterm-ssh' and `tramp-term' are stubbed,
# and the keymap cases bind into a fresh map rather than the live one.
#
# The package requires vterm-reconnect, its sibling here, so both directories
# are on the load path.  `vterm' and `tramp-term' are declare-function'd rather
# than required, so neither has to be installed for this to run.
#
# $EMACS overrides the binary; on the dev VM, where the packaged Emacs needs a
# hand:
#
#     LD_LIBRARY_PATH=$HOME/.local/lib EMACS=/opt/emacs-29.4/bin/emacs ./check.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lisp="$(cd "$here/.." && pwd)"
emacs="${EMACS:-emacs}"

# Compiled in a COPY, never here.  The .elc lands beside its source, and this
# directory is one Emacs loads from, so compiling in place would leave a .elc
# newer than its .el and get it loaded in preference -- from a command whose
# only job was to check that the source compiles.
echo "== byte-compile (warnings are errors)"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
cp "$here/term-launcher.el" "$stage/"
"$emacs" -Q --batch -L "$stage" -L "$lisp/vterm-reconnect" \
  --eval '(setq byte-compile-error-on-warn t)' \
  -f batch-byte-compile "$stage/term-launcher.el"

echo "== tests"
"$emacs" -Q --batch -L "$here" -L "$here/tests" -L "$lisp/vterm-reconnect" \
  -l term-launcher -l term-launcher-tests \
  -f ert-run-tests-batch-and-exit
