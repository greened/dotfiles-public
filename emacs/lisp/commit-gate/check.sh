#!/usr/bin/env bash
# Byte-compile commit-gate.el warnings-fatal and run its tests.
#
#     ./check.sh
#
# This package decides whether a commit message was APPROVED or dismissed, and
# the two look identical in every other artifact, so it is tested rather than
# trusted.  The tests cover the three properties it has to have: it stamps a
# gate, it stamps nothing else, and the stamp is a time rather than a flag.
#
# $EMACS overrides the binary; on the dev VM, where the packaged Emacs needs a
# hand:
#
#     LD_LIBRARY_PATH=$HOME/.local/lib EMACS=/opt/emacs-29.4/bin/emacs ./check.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
emacs="${EMACS:-emacs}"

# Compiled in a COPY, never here.  The .elc lands beside its source, and this
# directory is one Emacs loads from, so compiling in place would leave a .elc
# newer than its .el and get it loaded in preference -- from a command whose
# only job was to check that the source compiles.
echo "== byte-compile (warnings are errors)"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
cp "$here/commit-gate.el" "$stage/"
"$emacs" -Q --batch -L "$stage" \
  --eval '(setq byte-compile-error-on-warn t)' \
  -f batch-byte-compile "$stage/commit-gate.el"

echo "== tests"
"$emacs" -Q --batch -L "$here" -L "$here/tests" \
  -l commit-gate -l commit-gate-tests \
  -f ert-run-tests-batch-and-exit
