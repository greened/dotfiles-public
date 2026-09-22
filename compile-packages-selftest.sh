#!/usr/bin/env bash
# Check the local-package build driver in tools/compile-packages.el:
#
#     ./compile-packages-selftest.sh
#
# What this covers is WHICH DIRECTORIES the build considers a package, not the
# compile itself.  That set used to be written out by hand, and a directory
# nobody added produced no output at all -- not a compile, not a skip -- so the
# run read as clean while a package went unchecked.  The set is derived from
# the tree now, and these cases hold it to what the list used to name.
#
# $EMACS overrides the binary; on the dev VM, where the packaged Emacs needs a
# hand:
#
#     LD_LIBRARY_PATH=$HOME/.local/lib EMACS=/opt/emacs-29.4/bin/emacs ./compile-packages-selftest.sh
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
emacs="${EMACS:-emacs}"

# Every Emacs below is bounded, so a loop that cannot advance is a failed test
# rather than a dead machine.  GNU coreutils' `timeout' is absent from a base
# macOS, so it is used when present.
bound=""
for candidate in timeout gtimeout; do
  if command -v "$candidate" >/dev/null 2>&1; then bound="$candidate"; break; fi
done

emacs_run() {  # ARGS... -- run $emacs on ARGS, under the bound when there is one
  if [ -n "$bound" ]; then "$bound" 120 "$emacs" "$@"; else "$emacs" "$@"; fi
}

pass=0 fail=0
check() {  # want-rc name cmd... -- runs cmd and compares its exit status
  local want="$1" name="$2"; shift 2
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  if [ "$rc" = "$want" ]; then
    pass=$((pass + 1)); printf 'ok   %s\n' "$name"
  else
    fail=$((fail + 1))
    printf 'FAIL %s (rc=%s want=%s)\n%s\n' "$name" "$rc" "$want" "$out"
  fi
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Compiled in a copy, never in tools/: the .elc lands beside its source, and
# the tests below put that directory on the load path, so a stale one would be
# loaded in preference to the source it was meant to check.
stage="$tmp/stage"; mkdir -p "$stage"
cp "$here/tools/compile-packages.el" "$stage/"
check 0 'the driver byte-compiles, warnings fatal' \
      emacs_run -Q --batch -L "$stage" \
      --eval '(setq byte-compile-error-on-warn t)' \
      -f batch-byte-compile "$stage/compile-packages.el"

check 0 'the package set agrees with its fixtures' \
      emacs_run -Q --batch -L "$here/tools" -L "$here/tools/tests" \
      -l compile-packages -l compile-packages-tests \
      -f ert-run-tests-batch-and-exit

# Loading the driver must NOT run a build.  It used to call `cp-main' at the
# end of the file, which is why the tests above could not exist: loading it
# compiled the whole tree and then called `kill-emacs'.
check 0 'loading the driver builds nothing' \
      emacs_run -Q --batch -L "$here/tools" -l compile-packages \
      --eval '(princ "loaded\n")'

# The set the real checkout derives, printed because it is what moves when a
# package is added.
out="$(emacs_run -Q --batch -L "$here/tools" -l compile-packages \
        --eval '(princ (format "packages: %s\nexcluded: %s\n"
                               (string-join (cp-packages) " ")
                               (string-join (mapcar (function car) cp-excluded) " ")))' 2>&1)"
printf '%s\n' "$out"
if printf '%s\n' "$out" | grep -q 'excluded: themes'; then
  pass=$((pass + 1)); printf 'ok   the checkout names its exclusion\n'
else
  fail=$((fail + 1)); printf 'FAIL the exclusion is not reported\n'
fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
