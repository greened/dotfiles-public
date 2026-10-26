# Emacs, TRAMP and elpaca traps

Each of these was hit and measured. Each entry gives the symptom, the cause
and what to do.

## `with-timeout` did not bound a TRAMP call on Emacs 31.1

**Symptom.** A remote read or write wrapped in `with-timeout` runs to
completion, and the editor is frozen the whole time.

    (let ((default-directory "/ssh:dev-vm:/tmp/"))
      (with-timeout (2 'timed-out)
        (process-file "sleep" nil nil nil "5")))

This returned 0, the exit code of `sleep`, after the full five seconds. It
was measured on Emacs 31.1 with TRAMP 2.8.2.1. A TRAMP `write-region`
behaved the same way.

**Cause.** Not confirmed. A timer runs only where Emacs stops to check for
one, and TRAMP 2.8 seems not to stop there while it waits on the remote
side. On Emacs 27.2 and 29.4 the same read did time out, so test your own
version.

**What to do.** Bound a remote operation from outside. Run `ssh` as a local
async process with `BatchMode=yes` and `ConnectTimeout`, and read the result
in a process sentinel. `commit-gate--spawn-remote` in
`emacs/lisp/commit-gate/commit-gate.el` does this. Before you conclude that
a timer did not fire, check that one fires at all in the same setup: a
one-second `with-timeout` around `(sleep-for 3)` should cut in.

## Reloading a file does not re-run a bound `defvar`

**Symptom.** You change a key binding, `load` the file into a running
Emacs, and the key still runs the old command. Or a new entry in a
package's registry list never appears.

**Cause.** `load` redefines every `defun`, but `defvar` does nothing when
the variable is already bound. A keymap built inside a `defvar` keeps its
old contents, and open buffers hold the old map object.

**What to do.** In the running session, `define-key` the change onto the
existing map, or `setq` the list and anything derived from it.
`(lookup-key foo-mode-map (kbd "A"))` shows the live binding. A fresh Emacs
builds the map from the current source.

## `eval-buffer` in a temp buffer uses dynamic binding

**Symptom.** Code that works from its file fails when you deploy it with
`(with-temp-buffer (insert CODE) (eval-buffer))`. A closure reports
"Symbol's value as variable is void" for a variable it should have
captured.

**Cause.** `eval-buffer` takes lexical binding from a `lexical-binding`
cookie in the buffer's text, and the inserted code carries none. Setting
`lexical-binding` in the buffer does not help. Tested on Emacs 27.2 and
29.4.

**What to do.** Write the code to a file whose first line is
`;; -*- lexical-binding: t -*-` and `load` it, or `(eval FORM t)` each form.

## `syntax-ppss` moves point

**Symptom.** A `re-search-forward` loop that skips matches in comments and
strings never ends, and an accumulator in it grows without bound.

    (with-temp-buffer
      (insert "(use-package magit :ensure t)")
      (goto-char 13)
      (syntax-ppss 1)
      (point))                          ; => 1, not 13

**Cause.** `syntax-ppss` leaves point at the position it was asked about.
In a scan loop that is the start of the match, so the next search matches
the same text again.

**What to do.** Advance from the loop itself, not from what its callees
leave behind:

    (while (re-search-forward REGEXP nil t)
      (let ((start (match-beginning 0))
            (end (match-end 0)))
        (unless (nth 8 (syntax-ppss start))
          ...)
        (goto-char end)))

`tools/lint-packages.el` uses this shape. Run every batch Emacs in a test
under `timeout`, so the next loop that does not advance is a failed test
rather than a dead machine.

## A stale `.elc` and native compilation make a hybrid

**Symptom.** After a pull, a function from the new source runs and reports
that a variable from the same new source is void.

**Cause.** A package installed from a local checkout has its `.el`
symlinked into the build directory, so the `.elc` beside it is only as new
as the last rebuild. With `load-prefer-newer` nil, startup loads the stale
`.elc`. Native compilation then compiles the newer `.el` in the background
and late-loads the result. That swaps in the new functions without
re-running the new top-level forms, so a new `defconst` never binds.

**What to do.** `emacs/emacsrc` sets `load-prefer-newer` to t for this
reason. If you still see a void new variable whose caller exists, suspect a
stale build before a bug in the source, and byte-compile the build
directory's file.

## `spy-on` cannot stub a primitive called from native code

**Symptom.** Buttercup specs that stub a primitive, such as `system-name`,
pass against the source and fail against the installed package.

**Cause.** Calls to a primitive from natively compiled code did not go
through the spy. The same specs passed against interpreted source, and
against a byte-compiled `.elc` without native compilation. Measured on
Emacs 31.1 for the native case.

**What to do.** Test the checkout, not the installed package: `-L .`
prepends, so put it after any setup that adds the build directory. When
stubbed specs fail in one harness only, print `(type-of (symbol-function
'some-pkg-fn))` and `symbol-file` first. A probe that checks a stub must call
through code compiled the same way as the code under test.

## A top-level `require` of an elpaca package from a demanded local package

**Symptom.** One package fails to load at startup, and every
`use-package` block after it in the same file silently does nothing.

**Cause.** elpaca installs and activates its queued packages after init.
A local package loaded with `:demand t` during init that does a top-level
`(require 'some-elpaca-package)` fails, because that package is not on the
load path yet. In the case that was hit, the error also stopped every
block after it in `packages.el`.

**What to do.** Require such a dependency inside the command that needs it,
or order the stanza with `:after`. Built-in libraries and other local
packages already on `load-path` are safe. When you smoke-test a local
package, load it with its elpaca dependencies absent, because stubbing them
hides this bug.

## `:ensure nil` on a package nothing else installs

**Symptom.** A package is declared and configured, and it is never there.
If its stanza is deferred, nothing reports it until the first use.

**Cause.** `:ensure nil` tells elpaca the package is already available, so
nothing fetches it. That is right for a built-in library or a file vendored
in this repo and wrong for anything else. Startup warnings show only the
stanzas that load eagerly.

**What to do.** Ask `locate-library` about every declared package rather
than reading the warnings. `tools/lint-packages.el` flags a stanza that
declares nothing, or says `:ensure nil`, unless `locate-library` finds the
package.

## Homebrew can remove a library Emacs links against

**Symptom.** After a `brew install` of something unrelated, a new Emacs
fails to start with `dyld: Library not loaded`. An Emacs that was already
running keeps working until it restarts.

**Cause.** The install pruned keg-only libraries that the Emacs build links
against but that Homebrew did not record as its dependencies.

**What to do.** List what the binary links against:

    otool -L "$(brew --prefix <emacs-formula>)"/Emacs.app/Contents/MacOS/Emacs

Find the `/opt/homebrew/opt/<formula>/` entries whose file is missing, and
`brew install` each of those formulas. Run the check after any `brew
install`, before Emacs next starts.

## A raw-mode terminal program stops under `start-process`

**Symptom.** A program such as `asciinema rec`, started from Emacs with
`start-process`, produces no output and no error, and never finishes. `ps`
shows it in state `T`.

**Cause.** The program calls `tcsetattr` on its terminal. A shell with no
job control leaves it outside the foreground process group, so the kernel
stops it with `SIGTTOU`. `sh -c` and `tmux new-session -d 'cmd'` have the
same problem.

**What to do.** Give it the shell a person would have. Start a private tmux
server, then type the command into its pane:

    tmux -f /dev/null -L rec new-session -d -s rec -x 100 -y 30
    tmux -f /dev/null -L rec send-keys -t rec 'asciinema rec out.cast' Enter

`-f /dev/null` keeps your own tmux config from interfering. When a child
produces nothing, read its process state before you theorize about
terminals.

A related silent failure: `start-process` reports success for a `sh -c`
whose script has a syntax error. The shell exits before it writes anything,
which looks the same as a hang.
