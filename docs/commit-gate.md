# The commit gate

The commit gate makes sure a human approves each commit an AI agent makes in
a guarded clone. The agent proposes a message. The human reads it in their
own Emacs, edits it if they like, and approves it with `C-x #` or discards
it with `C-x k`. Git hooks then refuse an agent's branch update that brings
in new content with no approval behind it.

## Where each half lives

| Half                          | Where                                       |
|-------------------------------|---------------------------------------------|
| Recording an approval         | `emacs/lisp/commit-gate/commit-gate.el`     |
| Saying a filter rewrote it    | `emacs/lisp/commit-gate/commit-gate-scrub.el` |
| Arming both                   | `commit-gate` block in `emacs/lisp/packages.el` |
| The commit-time git hooks     | overlay-provided `git/hooks/commit-gate.sh` |
| Their tests                   | overlay-provided `commit-gate-selftest.sh`  |
| A summary of the log          | overlay-provided `commit-gate-rollup`       |

The Emacs half is in this public base. The hook half ships in the
personal-config overlay, beside the global hook chain that sources it. The
agent's landing script, which opens the gate and runs `git commit`, lives in
the agent's own config and in neither repo. The code comments call it
`commit-land`.

The gate builds on the setup in [remote-emacsclient.md](remote-emacsclient.md),
so an agent on a dev VM can open the message in the laptop's Emacs.

## The flow

1. The landing script makes a run directory under the git dir,
   `claude-land/<nonce>/`, with a `.nonce` file and the message in a file
   named `CLAUDE_COMMIT_MSG`.
2. It opens that file with a blocking `emacsclient` and waits.
3. When Emacs visits the buffer, `commit-gate` reads `.nonce` and labels the
   header line with the repository and the two keys.
4. The human edits and presses `C-x #`. An advice on `server-done` records
   the approval, and the client exits.
5. The landing script finds `.closed` in the run directory holding its own
   nonce. It writes a commit record into `<git-dir>/claude-approvals/` and
   commits.
6. The git hooks match the commit against that record and let the branch
   move.

## Why a client exit is not enough

The client exits 0 after `C-x #` and after `C-x k` alike.
`server-kill-new-buffers` defaults to t, so both leave no buffer behind. A
forwarded socket that drops mid-gate ends the client too. So an exit says the
gate closed, not that anyone approved it.

`C-x #` reaches `server-done` and `C-x k` does not. The advice on
`server-done` is the one place the difference shows, so that advice writes
the evidence.

## What an approval writes

An accept writes two records, and they fail differently.

- **The local record** is written first and synchronously, in `commit-gate/`
  under `user-emacs-directory`. It is named for a SHA-256 of the gate's
  local path, because every worktree's gate shares one basename. It needs no
  network. `commit-gate-accepted-p` reads it back.
- **The sentinel** is `.closed` beside the gate, holding the run's nonce.
  For a gate opened over TRAMP with an ssh or scp method, a spawned `ssh`
  writes it, so `C-x #` never waits on the network. The process sentinel
  appends the outcome to the local record, so a remote write that failed
  reads differently from one that landed.

This split replaced a TRAMP write under `with-timeout`. The timeout never
fired, because a TRAMP write does not stop where Emacs runs timers.
See [emacs-traps.md](emacs-traps.md).

## Why a nonce and not a flag

The advice is armed when the configuration loads and is never removed.
Removing it would disarm every later gate on the machine, and silently: the
next agent would refuse a real approval, which looks like the gate working.

An advice that is always armed stamps any `C-x #` on any `CLAUDE_COMMIT_MSG`,
including one no agent is waiting for. So the sentinel has to name the run
it approves. The nonce is read when the buffer is visited, so a buffer that
outlives its run cannot pick up a later run's nonce.

A gate whose nonce is unreadable, malformed or still being read stops
`C-x #` with a `user-error` and a header line that says how to proceed.
Every other fault in the writes is swallowed, because an error in an advice
on `server-done` would break finishing a buffer for every client. So a missing record means
unproven, not denied.

A landing script that writes no `.nonce` gets the older behavior: the
sentinel is the epoch at `CLAUDE_COMMIT_MSG.closed`, and the reader requires
a stamp no older than its own gate.

## Two warnings in the buffer

A file named like a gate but not exactly `CLAUDE_COMMIT_MSG`, such as
`CLAUDE_COMMIT_MSG.txt`, records nothing on `C-x #`. Its header line says
so while there is still time to act.

A filter may rewrite the draft before the gate opens. `commit-gate-scrub`
shows in the mode line whether it did: `scrub:rewritten`, `scrub:refused`,
`scrub:clean` or `scrub:none`. `commit-gate-show-scrub-diff` shows what it
changed. The filter itself is not in either repo.

## The git hooks (overlay-provided)

The global hook chain sources `commit-gate.sh` from five hooks. It judges
only a caller with `CLAUDECODE` or `CLAUDE_CODE_SESSION_ID` set, and only in
a guarded clone. A clone is guarded when it has a network remote, a remote
that uses a transport helper or an unknown scheme, or a local remote that
leads to a guarded clone, and no exemption covers it. Anything it cannot
resolve counts as guarded.

- **reference-transaction** decides. A branch or detached `HEAD` update
  passes when a commit record or a move record approves it, or when it
  brings in nothing new: it moves back to an ancestor, or a local branch or
  a published remote-tracking ref already has the commit. A detached `HEAD`
  also passes while a rebase operation the landing tooling started is live.
  Anything else is refused with a line that says how to proceed. A matched
  record is deleted once the update commits, so one approval lands one
  commit.
- **prepare-commit-msg** checks early, before the editor opens, that a
  commit record names the branch, its tip and the staged tree.
- **commit-msg** refuses when the repo's own `commit-msg` hook, or the
  chain's AI trailer strip, would change the approved message.
- **pre-push** refuses a push of a commit no local branch has.
- **post-checkout** sets a guarded clone's `core.hooksPath` to the chain
  when the clone has none.

A commit record names the ref, its old value, the parent, the tree and a
hash of the stripspaced message. So an approval covers that exact commit. A
pre-commit hook that restages files changes the tree, and the record no
longer matches.

`commitgate.mode` in the global git config is `off`, `warn` or `enforce`.
Unset or malformed reads as `enforce`, so a typo cannot switch it off. A
repo's own config cannot change the mode, but `commitgate.guard = false` in
a clone's own config exempts that clone.

This is an accident guard, not a security boundary. The agent can write the
git dir, so a forged record is out of scope.

## The decision log

Each guarded decision appends one tab-separated line to
`~/.local/state/commitgate/decisions.log`:

| Column | Holds                                                    |
|--------|----------------------------------------------------------|
| 1      | UTC time, ISO 8601                                       |
| 2      | the repository's top level                               |
| 3      | the ref                                                  |
| 4      | the new sha, or `-` from the message hooks               |
| 5      | the caller, always `claude`                              |
| 6      | the decision: `pass`, `warn` or `refuse`                 |
| 7      | the reason                                               |
| 8      | the git operation, such as `rebase (pick)`, or `-`       |

The message is never written, only the ref and the sha. The operation is the
verb of `GIT_REFLOG_ACTION` and an optional one-word step, because `git
pull` puts its arguments there and a URL can carry a token. It comes last so
older rows keep their columns.

`commit-gate-rollup` counts the log by decision and reason class, and under
each class by operation. `--warn` keeps the rows enforce mode would have
stopped.

## Tests

`emacs/lisp/commit-gate/check.sh` byte-compiles the package with warnings as
errors and runs its tests. The overlay's `commit-gate-selftest.sh` runs the
hooks against scratch repos under a temporary `HOME`.
