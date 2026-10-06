#!/usr/bin/env bash
# Byte-compile vterm-reconnect.el warnings-fatal and run its tests.
#
#     ./check.sh
#
# The tests cover what the package decides: which buffers a reconnect kills,
# and what a new session is named and sent. They never open a terminal.
# `vterm' and `vterm-send-string' are declare-function'd rather than required,
# so vterm does not have to be installed for this to run.
#
# $EMACS overrides the binary. On the dev VM the packaged Emacs needs a hand:
#
#     LD_LIBRARY_PATH=$HOME/.local/lib EMACS=/opt/emacs-29.4/bin/emacs ./check.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
emacs="${EMACS:-emacs}"

# Compiled in a copy, never here. A .elc beside its source would be newer than
# the .el, and Emacs would load it in preference.
echo "== byte-compile (warnings are errors)"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
cp "$here/vterm-reconnect.el" "$stage/"
"$emacs" -Q --batch -L "$stage" \
  --eval '(setq byte-compile-error-on-warn t)' \
  -f batch-byte-compile "$stage/vterm-reconnect.el"

echo "== tests"
"$emacs" -Q --batch -L "$here" -L "$here/tests" \
  -l vterm-reconnect -l vterm-reconnect-tests \
  -f ert-run-tests-batch-and-exit
