#!/usr/bin/env bash
# Check (or refresh) the vendored LLVM Emacs modes against upstream.
#
# llvm-mode.el and tablegen-mode.el live in the llvm-project repo under
# llvm/utils/emacs/ and have no standalone MELPA package, so we vendor them
# here.  They change very rarely; run this occasionally to detect drift.
#
#   ./update-from-upstream.sh            # check only: report drift, no writes
#   ./update-from-upstream.sh --update   # overwrite the vendored copies
#
# After --update, review with `git diff` and commit if the changes look right.
#
# (google-c-style.el is also vendored here but is not tracked by this script:
#  it is a stable 2008 Google file kept vendored for load-order reasons.)
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
base="https://raw.githubusercontent.com/llvm/llvm-project/main/llvm/utils/emacs"
files=(llvm-mode.el tablegen-mode.el)

update=0
[[ "${1:-}" == "--update" ]] && update=1

drift=0
for f in "${files[@]}"; do
  tmp="$(mktemp)"
  if ! curl -fsSL "$base/$f" -o "$tmp"; then
    echo "$f: FAILED to fetch from upstream" >&2
    rm -f "$tmp"
    continue
  fi
  if diff -q "$tmp" "$dir/$f" >/dev/null 2>&1; then
    echo "$f: up to date"
  else
    drift=1
    if (( update )); then
      cp "$tmp" "$dir/$f"
      echo "$f: UPDATED"
    else
      echo "$f: DRIFT from upstream:"
      diff -u "$dir/$f" "$tmp" || true
    fi
  fi
  rm -f "$tmp"
done

if (( drift )) && (( ! update )); then
  echo
  echo "Upstream changed. Re-run with --update to vendor the changes, then git diff / commit."
fi
exit 0
