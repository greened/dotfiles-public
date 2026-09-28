#!/usr/bin/env bash
# Byte-compile this package warnings-fatal and run its tests.
#
#     ./check.sh
#
# This package decides whether a commit message was APPROVED or dismissed, and
# the two look identical in every other artifact, so it is tested rather than
# trusted. The tests cover the three properties it has to have: it stamps a
# gate, it stamps nothing else, and the stamp is a time rather than a flag.
#
# It also says whether an automated filter rewrote the draft before the gate
# opened. That claim is tested in both directions, because an indicator that
# announces a rewrite on a clean draft is one he stops reading.
#
# $EMACS overrides the binary; on the dev VM, where the packaged Emacs needs a
# hand:
#
#     LD_LIBRARY_PATH=$HOME/.local/lib EMACS=/opt/emacs-29.4/bin/emacs ./check.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
emacs="${EMACS:-emacs}"

# THE FILE SET IS DERIVED, never listed. A hand-written list is a hole rather
# than a style: a file nobody added to it is neither compiled nor run, and the
# check then reads exactly like a clean one. The build driver had the same hole,
# and this package nearly went uncompiled through it.
mapfile -t sources < <(find "$here" -maxdepth 1 -name '*.el' | sort)
mapfile -t tests < <(find "$here/tests" -maxdepth 1 -name '*-tests.el' | sort)
if [ "${#sources[@]}" -eq 0 ] || [ "${#tests[@]}" -eq 0 ]; then
    echo "check: found no sources or no tests, which cannot be right" >&2
    exit 1
fi
echo "== ${#sources[@]} source file(s), ${#tests[@]} test file(s)"

# Compiled in a COPY, never here. The .elc lands beside its source, and this
# directory is one Emacs loads from, so compiling in place would leave a .elc
# newer than its .el and get it loaded in preference -- from a command whose
# only job was to check that the source compiles.
echo "== byte-compile (warnings are errors)"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
cp "${sources[@]}" "$stage/"
staged=()
for f in "${sources[@]}"; do staged+=("$stage/$(basename "$f")"); done
"$emacs" -Q --batch -L "$stage" \
  --eval '(setq byte-compile-error-on-warn t)' \
  -f batch-byte-compile "${staged[@]}"

echo "== tests"
args=(-Q --batch -L "$here" -L "$here/tests")
for f in "${sources[@]}" "${tests[@]}"; do args+=(-l "$f"); done
"$emacs" "${args[@]}" -f ert-run-tests-batch-and-exit
