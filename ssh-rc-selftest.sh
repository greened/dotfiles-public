#!/usr/bin/env bash
# Check ssh/rc and setup_ssh in bash/lib/ssh.sh on a scratch home: the agent
# link moves only off a dead agent, X11 cookies reach xauth, and the link is
# used only inside an ssh session. The owner tests need a second user, so
# they are not covered here.
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"
pids=()
trap 'kill "${pids[@]}" 2>/dev/null; rm -rf "$tmp"' EXIT
pass=0 fail=0
check() {  # name, then the test command
  local name="$1"; shift
  if "$@"; then pass=$((pass + 1)); printf 'ok   %s\n' "$name"
  else fail=$((fail + 1)); printf 'FAIL %s\n' "$name"; fi
}
gone() {  # path, wait a few seconds for it to disappear, or fail the run
  local i
  for i in $(seq 50); do [ -e "$1" ] || return 0; sleep 0.1; done
  echo "$1 is still there" >&2; exit 1
}
agent() {  # path, start a real ssh-agent there and print its pid
  local out
  out="$(ssh-agent -a "$1" -s)" || { echo "cannot start ssh-agent at $1" >&2; exit 1; }
  sed -n 's/^SSH_AGENT_PID=\([0-9]*\);.*/\1/p' <<<"$out"
}
h="$tmp/home"; mkdir -p "$h/.ssh" "$tmp/bin"
link="$h/.ssh/agent-$(hostname -s).sock"
# A stub xauth records what it is fed.
printf '#!/bin/sh\ncat > "%s"\n' "$tmp/xauth.in" > "$tmp/bin/xauth"
chmod +x "$tmp/bin/xauth"
runrc() { HOME="$h" PATH="$tmp/bin:$PATH" sh "$here/ssh/rc"; }

p1="$(agent "$tmp/a1")"; pids+=("$p1")
SSH_AUTH_SOCK="$tmp/a1" DISPLAY= runrc < /dev/null
check 'rc links the first agent' test "$(readlink "$link")" = "$tmp/a1"
p2="$(agent "$tmp/a2")"; pids+=("$p2")
SSH_AUTH_SOCK="$tmp/a2" DISPLAY= runrc < /dev/null
check 'a later session keeps a live link' test "$(readlink "$link")" = "$tmp/a1"
SSH_AUTH_SOCK="$tmp/missing" DISPLAY= runrc < /dev/null
check 'a missing socket leaves the link alone' test "$(readlink "$link")" = "$tmp/a1"
# SIGKILL leaves the socket file behind, which a plain -S test cannot tell
# from a live one.
kill -9 "$p1"; sleep 0.2
SSH_AUTH_SOCK="$tmp/a2" DISPLAY= runrc < /dev/null
check 'a stale socket file lets the link move' test "$(readlink "$link")" = "$tmp/a2"
kill "$p2"; gone "$tmp/a2"
p3="$(agent "$tmp/a3")"; pids+=("$p3")
SSH_AUTH_SOCK="$tmp/a3" DISPLAY= runrc < /dev/null
check 'a removed socket lets the link move' test "$(readlink "$link")" = "$tmp/a3"
# A socket that accepts but never answers, like a forwarded agent whose
# client has gone to sleep, must not hold the session up.
python3 -c 'import socket,sys,time; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(); time.sleep(60)' "$tmp/wedged" &
pids+=($!)
for i in $(seq 50); do [ -S "$tmp/wedged" ] && break; sleep 0.1; done
[ -S "$tmp/wedged" ] || { echo "no wedged socket at $tmp/wedged" >&2; exit 1; }
ln -sfn "$tmp/wedged" "$link"
start=$SECONDS
SSH_AUTH_SOCK="$tmp/a3" DISPLAY= runrc < /dev/null
check 'a wedged agent cannot hold the session' test $((SECONDS - start)) -le 5
check 'a wedged agent lets the link move' test "$(readlink "$link")" = "$tmp/a3"

echo 'MIT-MAGIC-COOKIE-1 abc123' | SSH_AUTH_SOCK= DISPLAY=localhost:10.0 runrc
check 'a localhost display goes to xauth as unix:' \
  test "$(cat "$tmp/xauth.in")" = 'add unix:10.0 MIT-MAGIC-COOKIE-1 abc123'
rm -f "$tmp/xauth.in"
echo 'MIT-MAGIC-COOKIE-1 abc123' | SSH_AUTH_SOCK= DISPLAY=host:3 runrc
check 'another display goes to xauth as is' \
  test "$(cat "$tmp/xauth.in")" = 'add host:3 MIT-MAGIC-COOKIE-1 abc123'
rm -f "$tmp/xauth.in"
SSH_AUTH_SOCK= DISPLAY= runrc < /dev/null
check 'no X11 forwarding runs no xauth' test ! -e "$tmp/xauth.in"

got() {  # connection, print SSH_AUTH_SOCK after setup_ssh, as bashrc runs it
  HOME="$h" SSH_CONNECTION="$1" SSH_AUTH_SOCK=/orig bash -c \
    '. "$1"; setup_ssh; printf %s "$SSH_AUTH_SOCK"' _ "$here/bash/lib/ssh.sh"
}
check 'an ssh session uses the link' test "$(got '1.2.3.4 1 5.6.7.8 22')" = "$link"
check 'a local shell keeps its agent' test "$(got '')" = /orig
kill "$p3"; gone "$tmp/a3"
check 'a dangling link keeps the agent' test "$(got '1.2.3.4 1 5.6.7.8 22')" = /orig
rm -f "$link"
check 'a missing link keeps the agent' test "$(got '1.2.3.4 1 5.6.7.8 22')" = /orig

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
