;;; commit-gate-tests.el --- Tests for the commit-gate accept recorder -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:
;;
;; Run with ../check.sh.
;;
;; This file is the one place that can tell an approved commit message from a
;; dismissed one, so each of its properties gets a test that fails when the
;; property is absent:
;;
;;   - it stamps a sentinel for a gate buffer;
;;   - it writes a local record, and `commit-gate-accepted-p' reads it back;
;;   - it stamps NOTHING for any other buffer, which is attribution;
;;   - the record holds a time rather than a flag, so a reader can reject a
;;     leftover from an earlier gate.
;;
;; The path tests set `buffer-file-name' directly instead of visiting a file.
;; A gate shown over TRAMP carries a remote prefix, and asserting that the
;; prefix survives must not need a host to connect to.
;;
;; Every test that records an accept binds `commit-gate-record-directory' to a
;; temporary directory. The default sits inside `user-emacs-directory', and a
;; test run must not write there.

;;; Code:

(require 'ert)
(require 'server)
(require 'commit-gate)

(defmacro commit-gate-t--with-name (name &rest body)
  "Run BODY in a temporary buffer whose `buffer-file-name' is NAME."
  (declare (indent 1))
  `(with-temp-buffer
     (setq buffer-file-name ,name)
     ,@body))

(defmacro commit-gate-t--in-dir (dir &rest body)
  "Run BODY with DIR bound to a fresh directory, removed afterwards.
The local record directory is redirected under DIR for the same extent, so a
test never writes into `user-emacs-directory'."
  (declare (indent 1))
  `(let* ((,dir (make-temp-file "commit-gate-t" t))
          (commit-gate-record-directory (expand-file-name "records" ,dir)))
     (unwind-protect (progn ,@body)
       (delete-directory ,dir t))))

;;; Which buffers are gates

(ert-deftest commit-gate-recognises-a-gate-buffer ()
  "The name is exact, and it is the only thing that marks a gate."
  (commit-gate-t--with-name "/tmp/x/.git/CLAUDE_COMMIT_MSG"
    (should (commit-gate-buffer-p))))

(ert-deftest commit-gate-rejects-another-file-in-the-same-directory ()
  "A gate's siblings are not gates. `.stripped' is written by the agent."
  (commit-gate-t--with-name "/tmp/x/.git/CLAUDE_COMMIT_MSG.stripped"
    (should-not (commit-gate-buffer-p)))
  (commit-gate-t--with-name "/tmp/x/.git/COMMIT_EDITMSG"
    (should-not (commit-gate-buffer-p))))

(ert-deftest commit-gate-rejects-a-buffer-with-no-file ()
  "Most buffers he finishes have no file at all."
  (with-temp-buffer
    (should-not (commit-gate-buffer-p))))

;;; Where the sentinel goes

(ert-deftest commit-gate-puts-the-sentinel-beside-the-gate ()
  "The reader looks for exactly this name."
  (commit-gate-t--with-name "/tmp/x/.git/CLAUDE_COMMIT_MSG"
    (should (equal (commit-gate-sentinel-file)
                   "/tmp/x/.git/CLAUDE_COMMIT_MSG.closed"))))

(ert-deftest commit-gate-keeps-a-remote-prefix ()
  "A gate opened over TRAMP must not stamp its sentinel on this machine.
This is the correction that mattered: an earlier version of the contract
compared a bare local path, never matched, and so recorded nothing."
  (commit-gate-t--with-name "/ssh:dev:/home/u/r/.git/CLAUDE_COMMIT_MSG"
    (should (equal (commit-gate-sentinel-file)
                   "/ssh:dev:/home/u/r/.git/CLAUDE_COMMIT_MSG.closed"))))

(ert-deftest commit-gate-has-no-sentinel-for-a-non-gate ()
  "Nothing to stamp, so nothing is named."
  (commit-gate-t--with-name "/tmp/x/notes.txt"
    (should-not (commit-gate-sentinel-file))))

;;; What the recorder does

(ert-deftest commit-gate-stamps-a-gate-it-is-called-on ()
  "The whole point: an accept leaves a mark that a kill cannot leave."
  (commit-gate-t--in-dir dir
    (let ((gate (expand-file-name "CLAUDE_COMMIT_MSG" dir)))
      (with-temp-file gate (insert "a message\n"))
      (with-current-buffer (find-file-noselect gate)
        (unwind-protect
            (progn
              (commit-gate-record-accept)
              (should (file-exists-p (concat gate ".closed"))))
          (kill-buffer))))))

(ert-deftest commit-gate-stamps-a-time-and-not-a-flag ()
  "A reader has to reject a sentinel older than its own gate, so the
sentinel has to say WHEN. An always-armed advice stamps leftovers."
  (commit-gate-t--in-dir dir
    (let ((gate (expand-file-name "CLAUDE_COMMIT_MSG" dir))
          (before (float-time)))
      (with-temp-file gate (insert "a message\n"))
      (with-current-buffer (find-file-noselect gate)
        (unwind-protect (commit-gate-record-accept) (kill-buffer)))
      (with-temp-buffer
        (insert-file-contents (concat gate ".closed"))
        (let ((stamp (string-to-number (string-trim (buffer-string)))))
          (should (> stamp 0))
          (should (>= stamp (1- (floor before))))
          (should (<= stamp (+ (floor (float-time)) 1))))))))

(ert-deftest commit-gate-stamps-nothing-for-another-buffer ()
  "Attribution. `server-done' fires for whichever buffer he finished, so
without this the advice reports an approval of a gate nobody looked at."
  (commit-gate-t--in-dir dir
    (let ((other (expand-file-name "notes.txt" dir)))
      (with-temp-file other (insert "unrelated\n"))
      (with-current-buffer (find-file-noselect other)
        (unwind-protect (commit-gate-record-accept) (kill-buffer)))
      (should (equal (directory-files dir nil "closed\\'") nil)))))

(ert-deftest commit-gate-survives-a-buffer-with-no-file ()
  "An error here would break finishing a buffer for every client."
  (with-temp-buffer
    (should-not (commit-gate-record-accept))))

;;; The local record

(ert-deftest commit-gate-writes-a-local-record ()
  "The local record is the half that needs no network, so it is the one a
reader can rely on. The sentinel can be lost and this cannot."
  (commit-gate-t--in-dir dir
    (let ((gate (expand-file-name "CLAUDE_COMMIT_MSG" dir))
          (before (floor (float-time))))
      (with-temp-file gate (insert "a message\n"))
      (with-current-buffer (find-file-noselect gate)
        (unwind-protect (commit-gate-record-accept) (kill-buffer)))
      (let ((stamp (commit-gate-accepted-p gate)))
        (should stamp)
        (should (>= stamp (1- before)))))))

(ert-deftest commit-gate-record-notes-the-sentinel-outcome ()
  "An approval whose sentinel write failed must not read like one that
landed, so the outcome goes in the record rather than nowhere."
  (commit-gate-t--in-dir dir
    (let ((gate (expand-file-name "CLAUDE_COMMIT_MSG" dir)))
      (with-temp-file gate (insert "a message\n"))
      (with-current-buffer (find-file-noselect gate)
        (unwind-protect (commit-gate-record-accept) (kill-buffer)))
      (with-temp-buffer
        (insert-file-contents (commit-gate--record-file gate))
        (goto-char (point-min))
        (should (re-search-forward "^sentinel [0-9]+ written$" nil t))))))

(ert-deftest commit-gate-outcome-names-the-accept-it-belongs-to ()
  "A gate re-run after a close that stamped nothing is the case this
protects. The second accept truncates the record, the first accept's
sentinel can still land after that, and the stamp is what stops a reader
crediting the second accept with the first one's outcome."
  (commit-gate-t--in-dir dir
    (let ((gate (expand-file-name "CLAUDE_COMMIT_MSG" dir)))
      (commit-gate--write-record gate "1000")
      (commit-gate--record-outcome gate "1000" "failed, exit 7")
      (commit-gate--write-record gate "2000")
      (commit-gate--record-outcome gate "1000" "failed, exit 7")
      (with-temp-buffer
        (insert-file-contents (commit-gate--record-file gate))
        (goto-char (point-min))
        (should (re-search-forward "^accepted 2000$" nil t))
        (goto-char (point-min))
        (should (re-search-forward "^sentinel 1000 failed, exit 7$" nil t))
        (goto-char (point-min))
        (should-not (re-search-forward "^sentinel 2000 " nil t))))))

(ert-deftest commit-gate-record-keeps-the-gates-own-path ()
  "The key drops the host, so the record itself has to carry the full name
a reader can compare against."
  (commit-gate-t--in-dir _dir
    (let ((gate "/scp:u@dev:/home/u/r/.git/CLAUDE_COMMIT_MSG"))
      (commit-gate--write-record gate "1000")
      (with-temp-buffer
        (insert-file-contents (commit-gate--record-file gate))
        (goto-char (point-min))
        (should (re-search-forward (concat "^gate " (regexp-quote gate) "$")
                                   nil t))))))

(ert-deftest commit-gate-reads-a-record-back-by-its-local-path ()
  "The gate is remote to this Emacs and local to the host that holds it, and
both have to reach the same record. The key is the local name for that
reason. A reader on that host knows the path and not the TRAMP spelling."
  (commit-gate-t--in-dir _dir
    (commit-gate--write-record "/scp:u@dev:/home/u/r/.git/CLAUDE_COMMIT_MSG"
                               "1000")
    (should (equal (commit-gate-accepted-p "/home/u/r/.git/CLAUDE_COMMIT_MSG")
                   1000))))

(ert-deftest commit-gate-accepted-p-rejects-a-record-older-than-since ()
  "This advice is always armed, so an earlier gate at the same path leaves a
record. A reader that ignores the time accepts somebody else's approval."
  (commit-gate-t--in-dir dir
    (let ((gate (expand-file-name "CLAUDE_COMMIT_MSG" dir)))
      (commit-gate--write-record gate "1000")
      (should (equal (commit-gate-accepted-p gate 999) 1000))
      (should (equal (commit-gate-accepted-p gate 1000) 1000))
      (should-not (commit-gate-accepted-p gate 1001)))))

(ert-deftest commit-gate-accepted-p-is-nil-with-no-record ()
  "Nil means UNPROVEN. It is the answer that sends a reader to ask a person,
so it must not be reachable by accident from a malformed record either."
  (commit-gate-t--in-dir dir
    (let ((gate (expand-file-name "CLAUDE_COMMIT_MSG" dir)))
      (should-not (commit-gate-accepted-p gate))
      (make-directory commit-gate-record-directory t)
      (write-region "gate somewhere\n" nil (commit-gate--record-file gate)
                    nil 'quiet)
      (should-not (commit-gate-accepted-p gate)))))

;;; The remote sentinel

(ert-deftest commit-gate-skips-a-method-that-names-no-ssh-target ()
  "An `ssh' target guessed from a method that does not name one writes the
sentinel to the wrong host. Skipping is recorded, because a silent skip is
the failure this package exists to remove."
  (commit-gate-t--in-dir _dir
    (let ((gate "/sudo:root@localhost:/r/.git/CLAUDE_COMMIT_MSG"))
      (commit-gate--write-record gate "1000")
      (should-not (processp (commit-gate--spawn-remote gate "1000")))
      (with-temp-buffer
        (insert-file-contents (commit-gate--record-file gate))
        (goto-char (point-min))
        (should (re-search-forward "^sentinel 1000 skipped, method sudo$"
                                   nil t))))))

;; The remaining remote tests run the real spawn against an `ssh' shim on
;; `exec-path'. A shim rather than a host, because the suite has to pass with
;; no network and no key, and because the thing most likely to be wrong is the
;; argv. The shim runs the command it was handed through `sh', so a quoting
;; fault in the path or the stamp fails here exactly as it would on a host.
(defmacro commit-gate-t--with-ssh-shim (dir argv &rest body)
  "Run BODY with an `ssh' shim first on `exec-path', under a fresh DIR.
The shim appends its own arguments to the file ARGV, one to a line, then runs
its last argument through `sh'. It exits 7 when the target user is \"fail\",
and it sleeps first when the target user is \"slow\"."
  (declare (indent 2))
  `(commit-gate-t--in-dir ,dir
     (let ((,argv (expand-file-name "argv" ,dir))
           (bin (expand-file-name "bin" ,dir)))
       (make-directory bin t)
       (with-temp-file (expand-file-name "ssh" bin)
         (insert "#!/bin/sh\n"
                 "for a; do printf '%s\\n' \"$a\" >> \""
                 ,argv
                 "\"; last=$a; done\n"
                 "case \" $* \" in *\" slow@\"*) sleep 5 ;; esac\n"
                 "case \" $* \" in *\" fail@\"*) exit 7 ;; esac\n"
                 "sh -c \"$last\"\n"))
       (set-file-modes (expand-file-name "ssh" bin) #o755)
       (let ((exec-path (cons bin exec-path)))
         ,@body))))

(defun commit-gate-t--settle (proc)
  "Wait for PROC to exit and for its sentinel to run."
  (with-timeout (10 (error "the ssh shim did not finish"))
    (while (process-live-p proc)
      (accept-process-output proc 0.05))
    (accept-process-output nil 0.1)))

(ert-deftest commit-gate-spawns-ssh-with-the-target-and-the-remote-path ()
  "The gate is remote, so the sentinel has to land on the gate's host and
nowhere else. The target and the path are the two things that decide that."
  (commit-gate-t--with-ssh-shim dir argv
    (let* ((sentinel (expand-file-name "CLAUDE_COMMIT_MSG.closed" dir))
           (gate (concat "/scp:u@dev:" (expand-file-name "CLAUDE_COMMIT_MSG"
                                                         dir))))
      (commit-gate--write-record gate "1000")
      (commit-gate-t--settle (commit-gate--spawn-remote gate "1000"))
      (should (member "u@dev" (with-temp-buffer
                                (insert-file-contents argv)
                                (split-string (buffer-string) "\n" t))))
      (should (file-exists-p sentinel))
      (with-temp-buffer
        (insert-file-contents sentinel)
        (should (equal (string-trim (buffer-string)) "1000"))))))

(ert-deftest commit-gate-spawns-ssh-in-batch-mode ()
  "This process has no terminal. Without BatchMode a host that wants a
password leaves an `ssh' alive until Emacs exits."
  (commit-gate-t--with-ssh-shim dir argv
    (let ((gate (concat "/scp:u@dev:" (expand-file-name "CLAUDE_COMMIT_MSG"
                                                        dir))))
      (commit-gate--write-record gate "1000")
      (commit-gate-t--settle (commit-gate--spawn-remote gate "1000"))
      (with-temp-buffer
        (insert-file-contents argv)
        (goto-char (point-min))
        (should (re-search-forward "^BatchMode=yes$" nil t))))))

(ert-deftest commit-gate-quotes-a-path-with-a-space ()
  "The remote command is parsed by a shell on the far side, so an unquoted
path with a space would truncate the sentinel's name and write the wrong
file."
  (commit-gate-t--with-ssh-shim dir argv
    (let* ((name "a dir")
           (sub (expand-file-name name dir))
           (gate (progn (make-directory sub t)
                        (concat "/scp:u@dev:"
                                (expand-file-name "CLAUDE_COMMIT_MSG" sub)))))
      (commit-gate--write-record gate "1000")
      (commit-gate-t--settle (commit-gate--spawn-remote gate "1000"))
      (should (file-exists-p (expand-file-name "CLAUDE_COMMIT_MSG.closed"
                                               sub))))))

(ert-deftest commit-gate-records-a-failed-sentinel-write ()
  "This is the whole reason the local record exists. A sentinel that never
lands leaves the gate's host with nothing, so the record is the only thing
that separates a failed write from a refusal."
  (commit-gate-t--with-ssh-shim dir argv
    (let ((gate (concat "/scp:fail@dev:" (expand-file-name "CLAUDE_COMMIT_MSG"
                                                           dir))))
      (commit-gate--write-record gate "1000")
      (commit-gate-t--settle (commit-gate--spawn-remote gate "1000"))
      (should-not (file-exists-p (expand-file-name "CLAUDE_COMMIT_MSG.closed"
                                                   dir)))
      (with-temp-buffer
        (insert-file-contents (commit-gate--record-file gate))
        (goto-char (point-min))
        (should (re-search-forward "^sentinel 1000 failed, exit 7$" nil t))))))

(ert-deftest commit-gate-accepts-a-remote-gate-without-waiting ()
  "`C-x #' must not be held by the network. The shim here outlasts the
assertions by a wide margin, so a write that still finished before the accept
returned is a synchronous one."
  (commit-gate-t--with-ssh-shim dir _argv
    (let* ((gate (concat "/scp:slow@dev:"
                         (expand-file-name "CLAUDE_COMMIT_MSG" dir)))
           (proc (commit-gate-t--with-name gate
                   (commit-gate-record-accept)
                   (get-process "commit-gate-sentinel"))))
      (unwind-protect
          (progn
            (should (process-live-p proc))
            (should (commit-gate-accepted-p gate)))
        (delete-process proc)))))

;;; A name that nearly matches

(ert-deftest commit-gate-flags-a-near-miss ()
  "A suffix on the name is the case that once lost every approval."
  (commit-gate-t--with-name "/tmp/x/.git/CLAUDE_COMMIT_MSG.txt"
    (should (commit-gate-misnamed-p))))

(ert-deftest commit-gate-does-not-flag-a-gate-or-a-stranger ()
  "The real gate is not a near miss, and neither is an unrelated file."
  (commit-gate-t--with-name "/tmp/x/.git/CLAUDE_COMMIT_MSG"
    (should-not (commit-gate-misnamed-p)))
  (commit-gate-t--with-name "/tmp/x/.git/COMMIT_EDITMSG"
    (should-not (commit-gate-misnamed-p)))
  (with-temp-buffer
    (should-not (commit-gate-misnamed-p))))

(ert-deftest commit-gate-warns-in-the-header-of-a-near-miss ()
  "The warning has to be where he looks before he presses `C-x #'."
  (commit-gate-t--with-name "/tmp/x/.git/CLAUDE_COMMIT_MSG.txt"
    (let ((inhibit-message t))
      (commit-gate-warn-if-misnamed))
    (should (stringp header-line-format))
    (should (string-match-p "records no approval" header-line-format))))

(ert-deftest commit-gate-leaves-a-real-gate-header-alone ()
  "A warning on every gate would be one he learns to ignore."
  (commit-gate-t--with-name "/tmp/x/.git/CLAUDE_COMMIT_MSG"
    (commit-gate-warn-if-misnamed)
    (should-not (local-variable-p 'header-line-format))))

;;; The banner on a real gate

(ert-deftest commit-gate-labels-each-git-dir-shape ()
  "The main checkout, a worktree, a `git dev' repo and a submodule."
  (should (equal (commit-gate-repo-label "/h/dotfiles/.git/CLAUDE_COMMIT_MSG")
                 "dotfiles"))
  (should (equal (commit-gate-repo-label
                  "/h/dotfiles/.git/worktrees/wt/CLAUDE_COMMIT_MSG")
                 "dotfiles, worktree wt"))
  (should (equal (commit-gate-repo-label
                  "/h/prevue/.prevue.git/worktrees/wt/CLAUDE_COMMIT_MSG")
                 "prevue, worktree wt"))
  (should (equal (commit-gate-repo-label "/h/srv/core.git/CLAUDE_COMMIT_MSG")
                 "core"))
  (should (equal (commit-gate-repo-label
                  "/h/mono/.git/modules/a/modules/llvm/CLAUDE_COMMIT_MSG")
                 "mono, submodule llvm"))
  (should (equal (commit-gate-repo-label
                  "/h/mono/.git/modules/llvm/worktrees/wt/CLAUDE_COMMIT_MSG")
                 "mono, submodule llvm, worktree wt"))
  (should (equal (commit-gate-repo-label
                  "/scp:u@vm:/h/dotfiles/.git/CLAUDE_COMMIT_MSG")
                 "dotfiles"))
  (should-not (commit-gate-repo-label "/tmp/CLAUDE_COMMIT_MSG"))
  (should-not (commit-gate-repo-label "CLAUDE_COMMIT_MSG")))

(ert-deftest commit-gate-banner-names-the-repo-and-both-keys ()
  "The two keys are one apart and do opposite things, so both are named."
  (commit-gate-t--with-name "/h/dotfiles/.git/worktrees/wt/CLAUDE_COMMIT_MSG"
    (commit-gate-show-banner)
    (should (string-match-p "dotfiles, worktree wt" header-line-format))
    (should (string-match-p "C-x # approves" header-line-format))
    (should (string-match-p "C-x k discards" header-line-format))))

(ert-deftest commit-gate-banner-shows-a-percent-sign-as-written ()
  "A bare % in the header line is a format code and would be eaten.
`format-mode-line' renders nothing in batch, so this reads the escape."
  (commit-gate-t--with-name "/h/50%off/.git/CLAUDE_COMMIT_MSG"
    (commit-gate-show-banner)
    (should (string-match-p "for 50%%off\\." header-line-format))))

(ert-deftest commit-gate-banner-still-labels-a-gate-outside-a-repo ()
  "The keys matter more than the name, so a nameless gate keeps them."
  (commit-gate-t--with-name "/tmp/CLAUDE_COMMIT_MSG"
    (commit-gate-show-banner)
    (should (string-match-p "\\`Commit gate\\. C-x # approves"
                            header-line-format))))

(ert-deftest commit-gate-banner-skips-a-near-miss-and-a-stranger ()
  "A near miss keeps its warning, and other files keep their header."
  (commit-gate-t--with-name "/h/x/.git/CLAUDE_COMMIT_MSG.txt"
    (commit-gate-show-banner)
    (should-not (local-variable-p 'header-line-format)))
  (commit-gate-t--with-name "/h/x/.git/COMMIT_EDITMSG"
    (commit-gate-show-banner)
    (should-not (local-variable-p 'header-line-format)))
  (with-temp-buffer
    (commit-gate-show-banner)
    (should-not (local-variable-p 'header-line-format))))

;;; Arming it

(ert-deftest commit-gate-arms-and-reports-itself ()
  "The reader probes for this before trusting any sentinel."
  (unwind-protect
      (progn
        (advice-remove 'server-done #'commit-gate-record-accept)
        (should-not (commit-gate-armed-p))
        (commit-gate-arm)
        (should (commit-gate-armed-p)))
    (advice-remove 'server-done #'commit-gate-record-accept)))

(ert-deftest commit-gate-arming-twice-does-not-stack ()
  "The configuration is reloaded often, and a doubled advice would stamp
twice and make the count meaningless. Measured rather than assumed."
  (unwind-protect
      (progn
        (advice-remove 'server-done #'commit-gate-record-accept)
        (commit-gate-arm)
        (commit-gate-arm)
        (let ((n 0))
          (advice-mapc (lambda (f _p)
                         (when (eq f #'commit-gate-record-accept)
                           (setq n (1+ n))))
                       'server-done)
          (should (equal n 1))))
    (advice-remove 'server-done #'commit-gate-record-accept)))

(ert-deftest commit-gate-arming-installs-both-header-lines ()
  "Once each, however often the configuration is reloaded."
  (let ((server-visit-hook nil))
    (unwind-protect
        (progn
          (commit-gate-arm)
          (commit-gate-arm)
          (should (equal (sort (copy-sequence server-visit-hook) #'string<)
                         '(commit-gate-show-banner
                           commit-gate-warn-if-misnamed))))
      (advice-remove 'server-done #'commit-gate-record-accept))))

;;; commit-gate-tests.el ends here
