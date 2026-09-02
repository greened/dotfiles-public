#!/usr/bin/env bash
# Build and test this checkout.
#
#     ./check.sh          # build, then test
#     ./check.sh build    # byte-compile the local elisp packages
#     ./check.sh test     # run the selftests
#
# Split because gaffer drives `build' and `test' as separate steps and records
# each result on the work item.  Run by hand it is the same two things.
#
# "Build" is real work here, which is easy to assume it is not: the local
# packages under emacs/lisp are byte-compiled with warnings as errors, and that
# has already caught a live error the tests did not.  What it does NOT compile
# is the flat configuration in emacs/lisp -- see tools/compile-packages.el for
# why, and for what it reports as skipped.
#
# $EMACS overrides the binary; on the dev VM, where the packaged Emacs needs a
# hand:
#
#     LD_LIBRARY_PATH=$HOME/.local/lib EMACS=/opt/emacs-29.4/bin/emacs ./check.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
emacs="${EMACS:-emacs}"
what="${1:-all}"

do_build() {
  echo "== build: byte-compile the local packages (warnings are errors)"
  "$emacs" -Q --batch -l "$here/tools/compile-packages.el"
}

do_test() {
  # Each selftest is its own script and stays runnable on its own; this only
  # decides the order and fails the run on the first one that fails.
  echo "== test: link guard"
  "$here/link-selftest.sh"
  echo
  echo "== test: agenda-feeds iCalendar reader"
  EMACS="$emacs" "$here/emacs/lisp/agenda-feeds/check.sh"
}

case "$what" in
  build) do_build ;;
  test)  do_test ;;
  all)   do_build; echo; do_test ;;
  *) echo "usage: $(basename "$0") [build|test]" >&2; exit 2 ;;
esac
