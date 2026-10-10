# Check which shells get vterm's directory-tracking escape in PS1:
# ./prompt-selftest.sh Two failure modes have shipped. With the escape in a
# TRAMP login prompt, TRAMP spins and never connects. Without it under ssh or
# tmux, vterm loses track of the remote directory.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fails=0

# check WANT DESCRIPTION VAR=VALUE...: run setup_emacs in a clean shell with
# only the given environment, expecting the PS1 escape iff WANT is yes.
check() {
  local want="$1" what="$2" got
  shift 2
  got="$(env -i HOME="$HOME" PATH="$PATH" "$@" bash --norc --noprofile -c '
    PS1="\u@\H:\w\$ "
    . "$1/bash/lib/emacs.sh"
    setup_emacs
    case "$PS1" in *vterm_prompt_end*) echo yes ;; *) echo no ;; esac
  ' _ "$here")"
  if [ "$got" = "$want" ]; then
    echo "ok: $what"
  else
    echo "FAIL: $what: expected $want, got $got"
    fails=$((fails + 1))
  fi
}

ssh="SSH_CONNECTION=10.0.0.1 50000 10.0.0.2 22"
tmux="TMUX=/tmp/tmux-1/default,1,0"

check no  "TRAMP login over ssh" TERM=dumb "$ssh"
check no  "TRAMP login from a vterm" TERM=dumb \
  "INSIDE_EMACS=vterm,tramp:2.6.3" "$ssh"
check no  "TRAMP login from elsewhere" TERM=dumb \
  "INSIDE_EMACS=29.4,tramp:2.6.3" "$ssh"
check no  "M-x shell in tmux" TERM=dumb "INSIDE_EMACS=29.4,comint" "$tmux"
check no  "a dumb terminal in tmux" TERM=dumb "$tmux"
check no  "a local terminal outside Emacs" TERM=xterm-256color
check no  "another Emacs terminal in tmux" TERM=xterm-256color \
  "INSIDE_EMACS=29.4,eat" "$tmux"
check yes "a local vterm" TERM=xterm-256color INSIDE_EMACS=vterm
check yes "a vterm TRAMP opened" TERM=xterm-256color \
  "INSIDE_EMACS=vterm,tramp:2.6.3" "$ssh"
check yes "ssh, no Emacs state" TERM=xterm-256color "$ssh"
check yes "a tmux pane" TERM=screen-256color "$tmux" "$ssh"

[ "$fails" -eq 0 ]
