#!/usr/bin/env bash
# Byte-compile llm-api-key.el warnings-fatal and run its tests.
#
#     ./check.sh
#
# This package decides which pass entry an API key is read from, and a wrong
# account is invisible: it returns a plausible secret for the wrong identity.
# So the tests assert the ENTRY STRING, not just the returned value.
#
# `auth-source-pass-get' is stubbed throughout, so nothing here reads the pass
# store, unlocks a key, or needs one to exist.
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
cp "$here/llm-api-key.el" "$stage/"
"$emacs" -Q --batch -L "$stage" \
  --eval '(setq byte-compile-error-on-warn t)' \
  -f batch-byte-compile "$stage/llm-api-key.el"

echo "== tests"
"$emacs" -Q --batch -L "$here" -L "$here/tests" \
  -l llm-api-key -l llm-api-key-tests \
  -f ert-run-tests-batch-and-exit
