#!/usr/bin/env bash
# Run the tests for emacsclient.py, the $EDITOR wrapper.
#
#     ./check.sh
#
# Only the command-line decision is covered, and only through `build_args',
# which returns a list and opens nothing.  Running the wrapper itself would
# open a file in the live Emacs, so nothing here does -- the same rule
# link-selftest.sh follows for link.sh.
#
# $PYTHON overrides the interpreter.  unittest is in the standard library, so
# this needs nothing installed.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python="${PYTHON:-python3}"

echo "== tests"
"$python" -m unittest discover -s "$here/tests" -p 'test_*.py' -v
