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

echo "== byte-compile (warnings are errors)"
"$emacs" -Q --batch -L "$here" \
  --eval '(setq byte-compile-error-on-warn t)' \
  -f batch-byte-compile "$here/agenda-feeds-ics.el"

echo "== tests"
"$emacs" -Q --batch -L "$here" -L "$here/tests" \
  -l agenda-feeds-ics -l agenda-feeds-ics-tests \
  -f ert-run-tests-batch-and-exit
