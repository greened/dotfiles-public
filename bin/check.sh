#!/usr/bin/env bash
# Run the tests for the programs in bin/.
#
#     ./bin/check.sh
#
# The repo-sync tests build scratch repos in a temp dir and play the mac with
# a local subprocess, so nothing here reaches a real Emacs socket or remote.
#
# $PYTHON overrides the interpreter. unittest is in the standard library, so
# this needs nothing installed.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python="${PYTHON:-python3}"

echo "== tests"
"$python" -m unittest discover -s "$here/tests" -p 'test_*.py' -v
