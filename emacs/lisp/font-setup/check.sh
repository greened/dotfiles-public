#!/usr/bin/env bash
# Byte-compile font-setup.el warnings-fatal and run its tests.
#
#     ./check.sh
#
# The tests cover what the package decides: which action each platform gets
# for a missing font, whether a download is refused and which archive entry
# is installed. `font-setup--run' is stubbed, so nothing here starts curl,
# tar or fc-cache, and nothing is downloaded.
#
# $EMACS overrides the binary. On the dev VM, where the packaged Emacs needs a
# hand:
#
#     LD_LIBRARY_PATH=$HOME/.local/lib EMACS=/opt/emacs-29.4/bin/emacs ./check.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
emacs="${EMACS:-emacs}"

# Compiled in a copy, never here. The .elc lands beside its source, and this
# directory is one Emacs loads from, so a .elc left here would be loaded in
# preference to the source.
echo "== byte-compile (warnings are errors)"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
cp "$here/font-setup.el" "$stage/"
"$emacs" -Q --batch -L "$stage" \
  --eval '(setq byte-compile-error-on-warn t)' \
  -f batch-byte-compile "$stage/font-setup.el"

echo "== tests"
"$emacs" -Q --batch -L "$here" -L "$here/tests" \
  -l font-setup -l font-setup-tests \
  -f ert-run-tests-batch-and-exit
