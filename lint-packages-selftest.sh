#!/usr/bin/env bash
# Check the missing-:ensure lint in tools/lint-packages.el:
#
#     ./lint-packages-selftest.sh
#
# Three things, and the middle one is the point.  The classifier is asserted
# against inline fixtures, then the lint is run over a file that is broken, and
# only then over the checkout's own packages.el.  That file passes, so on its
# own it would not show that the lint can fail at all.
#
# $EMACS overrides the binary; on the dev VM, where the packaged Emacs needs a
# hand:
#
#     LD_LIBRARY_PATH=$HOME/.local/lib EMACS=/opt/emacs-29.4/bin/emacs ./lint-packages-selftest.sh
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
emacs="${EMACS:-emacs}"

# Every Emacs below is bounded.  A parse loop that fails to advance spins and
# grows its result without limit, and the first run of this suite took the
# machine down that way.  A bound turns that into a failed test.  GNU
# coreutils' `timeout' is absent from a base macOS, so it is used when present.
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

lint() {  # [FILE] -- lint FILE, or the checkout's own packages.el
  emacs_run -Q --batch -L "$here/tools" -l lint-packages \
            --eval '(lp-main (car command-line-args-left))' "$@"
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Compiled in a copy, never in tools/: the .elc lands beside its source, and
# `lint' below puts that directory on the load path, so a stale one would be
# loaded in preference to the source it was meant to check.
stage="$tmp/stage"; mkdir -p "$stage"
cp "$here/tools/lint-packages.el" "$stage/"
check 0 'the lint byte-compiles, warnings fatal' \
      emacs_run -Q --batch -L "$stage" \
      --eval '(setq byte-compile-error-on-warn t)' \
      -f batch-byte-compile "$stage/lint-packages.el"

check 0 'the classifier agrees with its fixtures' \
      emacs_run -Q --batch -L "$here/tools" -L "$here/tools/tests" \
      -l lint-packages -l lint-packages-tests \
      -f ert-run-tests-batch-and-exit

# A file that is broken, so the lint is known to be able to fail.  This is the
# shape the defect arrives in: a commented-out directive and a deferred stanza,
# which produces no startup error at all.
bad="$tmp/bad.el"
cat >"$bad" <<'EOF'
(use-package no-such-library-xyzzy
  ;; :straight t
  :defer t)
EOF
check 1 'a stanza that declares nothing fails the lint' lint "$bad"
# The report is captured before it is matched.  `lint' exits non-zero here by
# design, and under `pipefail' that status, not the match, is what a pipe
# straight into `grep' reports.
report="$(lint "$bad" 2>&1)"
if printf '%s\n' "$report" | grep -q 'bad\.el:1:.*no-such-library-xyzzy'; then
  pass=$((pass + 1)); printf 'ok   the report names the stanza and its line\n'
else
  fail=$((fail + 1)); printf 'FAIL the report does not name the stanza\n'
fi

# The checkout's own file.  Its summary is printed, since the stanza count is
# what moves when a package is added.
out="$(lint "$here/emacs/lisp/packages.el" 2>&1)"; rc=$?
printf '%s\n' "$out"
if [ "$rc" -eq 0 ]; then
  pass=$((pass + 1)); printf 'ok   the checkout has no undeclared stanza\n'
else
  fail=$((fail + 1)); printf 'FAIL the checkout has an undeclared stanza\n'
fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
