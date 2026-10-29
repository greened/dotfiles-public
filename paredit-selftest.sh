#!/usr/bin/env bash
# Check that RET evaluates in M-: with paredit on:
#
#     ./paredit-selftest.sh
#
# $EMACS overrides the binary. On the dev VM, where the packaged Emacs needs a
# hand:
#
#     LD_LIBRARY_PATH=$HOME/.local/lib EMACS=/opt/emacs-29.4/bin/emacs ./paredit-selftest.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
emacs="${EMACS:-emacs}"

# The tests read packages.el form by form, and a read loop that fails to
# advance spins without limit. A bound turns that into a failed test. GNU
# coreutils' `timeout' is absent from a base macOS, so it is used when present.
bound=""
for candidate in timeout gtimeout; do
  if command -v "$candidate" >/dev/null 2>&1; then bound="$candidate"; break; fi
done

emacs_run() {  # ARGS...: run $emacs on ARGS, under the bound when there is one
  if [ -n "$bound" ]; then "$bound" 120 "$emacs" "$@"; else "$emacs" "$@"; fi
}

# Compiled in a copy, so no .elc lands beside the source and shadows it.
echo "== byte-compile the tests (warnings are errors)"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
cp "$here/tools/tests/paredit-tests.el" "$stage/"
emacs_run -Q --batch --eval '(setq byte-compile-error-on-warn t)' \
  -f batch-byte-compile "$stage/paredit-tests.el"

echo "== tests"
emacs_run -Q --batch -L "$here/tools/tests" -l paredit-tests \
  -f ert-run-tests-batch-and-exit
