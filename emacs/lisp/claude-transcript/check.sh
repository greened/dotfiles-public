#!/usr/bin/env bash
# Byte-compile claude-transcript.el warnings-fatal and run its tests.
#
#     ./check.sh
#
# The tests cover what the reader shows and hides, how it joins lines split
# across reads, that killing the buffer stops the tail and its pending render,
# and that a dead tail says so. Every record they use is synthetic.
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
cp "$here/claude-transcript.el" "$stage/"
"$emacs" -Q --batch -L "$stage" \
  --eval '(setq byte-compile-error-on-warn t)' \
  -f batch-byte-compile "$stage/claude-transcript.el"

echo "== tests"
"$emacs" -Q --batch -L "$here" -L "$here/tests" \
  -l claude-transcript -l claude-transcript-tests \
  -f ert-run-tests-batch-and-exit
