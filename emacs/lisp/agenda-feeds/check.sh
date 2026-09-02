#!/usr/bin/env bash
# Byte-compile agenda-feeds-ics.el warnings-fatal and run its tests.
#
#     ./check.sh
#
# Only the iCalendar reader is covered.  It is the part with the arithmetic --
# recurrence expansion, zones, window edges -- and the part that can be tested
# without a network, a calendar server, or the rest of the package's
# dependencies.  The feed generators are thin by comparison and are exercised
# by using them.
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
cp "$here/agenda-feeds-ics.el" "$stage/"
"$emacs" -Q --batch -L "$stage" \
  --eval '(setq byte-compile-error-on-warn t)' \
  -f batch-byte-compile "$stage/agenda-feeds-ics.el"

echo "== tests"
"$emacs" -Q --batch -L "$here" -L "$here/tests" \
  -l agenda-feeds-ics -l agenda-feeds-ics-tests \
  -f ert-run-tests-batch-and-exit
