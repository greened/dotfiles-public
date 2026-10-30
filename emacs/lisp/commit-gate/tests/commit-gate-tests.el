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
;; In a run directory the sentinel holds the run's nonce instead. It is read
;; when the buffer opens, and a malformed one refuses the approval.
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

(defmacro commit-gate-t--visit (gate &rest body)
  "Run BODY in a buffer visiting GATE, with its nonce read as on open."
  (declare (indent 1))
  `(with-current-buffer (find-file-noselect ,gate)
     (unwind-protect
         (progn (commit-gate-capture-nonce) ,@body)
       (set-buffer-modified-p nil)
       (kill-buffer))))

(defconst commit-gate-t--nonce-a "0123456789abcdef0123456789abcdef"
  "A well-formed nonce.")

(defconst commit-gate-t--nonce-b "fedcba9876543210fedcba9876543210"
  "A second well-formed nonce, for a later run.")

(defun commit-gate-t--run-dir (dir nonce &optional text)
  "Make a commit-land run directory under DIR for NONCE and return its gate.
The `.nonce' file holds TEXT when given, else NONCE and a newline."
  (let ((run (expand-file-name (concat ".git/claude-land/" nonce "/") dir)))
    (make-directory run t)
    (with-temp-file (expand-file-name ".nonce" run)
      (insert (or text (concat nonce "\n"))))
    (let ((gate (expand-file-name "CLAUDE_COMMIT_MSG" run)))
      (with-temp-file gate (insert "a message\n"))
      gate)))

(defun commit-gate-t--contents (file)
  "FILE's contents as a string."
  (with-temp-buffer (insert-file-contents file) (buffer-string)))

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
      (commit-gate-t--visit gate
        (commit-gate-record-accept)
        (should (file-exists-p (concat gate ".closed")))))))

(ert-deftest commit-gate-stamps-a-time-and-not-a-flag ()
  "A reader has to reject a sentinel older than its own gate, so the
sentinel has to say WHEN. An always-armed advice stamps leftovers."
  (commit-gate-t--in-dir dir
    (let ((gate (expand-file-name "CLAUDE_COMMIT_MSG" dir))
          (before (float-time)))
      (with-temp-file gate (insert "a message\n"))
      (commit-gate-t--visit gate (commit-gate-record-accept))
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
      (commit-gate-t--visit gate (commit-gate-record-accept))
      (let ((stamp (commit-gate-accepted-p gate)))
        (should stamp)
        (should (>= stamp (1- before)))))))

(ert-deftest commit-gate-record-notes-the-sentinel-outcome ()
  "An approval whose sentinel write failed must not read like one that
landed, so the outcome goes in the record rather than nowhere."
  (commit-gate-t--in-dir dir
    (let ((gate (expand-file-name "CLAUDE_COMMIT_MSG" dir)))
      (with-temp-file gate (insert "a message\n"))
      (commit-gate-t--visit gate (commit-gate-record-accept))
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

;;; The run nonce

(ert-deftest commit-gate-reads-the-nonce-at-open-and-writes-it-on-accept ()
  "The sentinel names the run it approves, in the run's own directory."
  (commit-gate-t--in-dir dir
    (let* ((gate (commit-gate-t--run-dir dir commit-gate-t--nonce-a))
           (run (file-name-directory gate)))
      (commit-gate-t--visit gate
        (should (equal commit-gate-nonce (cons 'nonce commit-gate-t--nonce-a)))
        (should (equal (commit-gate-sentinel-file)
                       (expand-file-name ".closed" run)))
        (commit-gate-record-accept))
      (should (equal (commit-gate-t--contents (expand-file-name ".closed" run))
                     commit-gate-t--nonce-a))
      (should-not (file-exists-p (concat gate ".closed")))
      (should (string-match-p
               (concat "^nonce " commit-gate-t--nonce-a "$")
               (commit-gate-t--contents (commit-gate--record-file gate)))))))

(ert-deftest commit-gate-an-older-buffer-keeps-its-own-nonce ()
  "A buffer open before a second run must not approve that run. Neither a
rewritten `.nonce', a revert nor a second visit changes what it writes."
  (commit-gate-t--in-dir dir
    (let* ((gate (commit-gate-t--run-dir dir commit-gate-t--nonce-a))
           (run (file-name-directory gate)))
      (commit-gate-t--visit gate
        (with-temp-file (expand-file-name ".nonce" run)
          (insert commit-gate-t--nonce-b "\n"))
        (revert-buffer t t)
        (commit-gate-capture-nonce)
        (should (equal commit-gate-nonce (cons 'nonce commit-gate-t--nonce-a)))
        (commit-gate-record-accept))
      (should (equal (commit-gate-t--contents (expand-file-name ".closed" run))
                     commit-gate-t--nonce-a)))))

(ert-deftest commit-gate-falls-back-to-the-epoch-without-a-nonce ()
  "An older commit-land writes no `.nonce' and waits on `<msg>.closed'."
  (commit-gate-t--in-dir dir
    (let ((gate (expand-file-name "CLAUDE_COMMIT_MSG" dir))
          (before (floor (float-time))))
      (with-temp-file gate (insert "a message\n"))
      (commit-gate-t--visit gate
        (should (eq commit-gate-nonce 'absent))
        (commit-gate-record-accept))
      (should-not (file-exists-p (expand-file-name ".closed" dir)))
      (should (>= (string-to-number
                   (commit-gate-t--contents (concat gate ".closed")))
                  (1- before))))))

(ert-deftest commit-gate-refuses-a-malformed-nonce ()
  "No sentinel and no record, and the refusal says what is wrong and how to
proceed."
  (dolist (text (list (upcase commit-gate-t--nonce-a)
                      (substring commit-gate-t--nonce-a 1)
                      (concat commit-gate-t--nonce-a "\nextra\n")
                      ""))
    (commit-gate-t--in-dir dir
      (let* ((gate (commit-gate-t--run-dir dir commit-gate-t--nonce-a text))
             (run (file-name-directory gate)))
        (commit-gate-t--visit gate
          (let ((err (should-error (commit-gate-record-accept)
                                   :type 'user-error)))
            (should (string-match-p "\\.nonce is malformed" (cadr err)))
            (should (string-match-p "C-x k to discard" (cadr err)))
            (should (string-match-p "rerun commit-land" (cadr err))))
          (should (string-prefix-p "Not approved. .nonce is malformed"
                                   header-line-format))
          (should (string-suffix-p
                   (concat (expand-file-name ".nonce" run) ".")
                   (string-replace "%%" "%" header-line-format))))
        (should-not (file-exists-p (expand-file-name ".closed" run)))
        (should-not (file-exists-p (concat gate ".closed")))
        (should-not (commit-gate-accepted-p gate))))))

(ert-deftest commit-gate-refuses-a-gate-whose-nonce-was-never-read ()
  "Reading at `C-x #' instead would let an old buffer take a newer nonce."
  (commit-gate-t--in-dir dir
    (let ((gate (commit-gate-t--run-dir dir commit-gate-t--nonce-a)))
      (with-current-buffer (find-file-noselect gate)
        (unwind-protect
            (let ((err (should-error (commit-gate-record-accept)
                                     :type 'user-error)))
              (should (string-match-p "no nonce was read" (cadr err)))
              (should (string-match-p "rerun commit-land" (cadr err))))
          (kill-buffer)))
      (should-not (file-exists-p
                   (expand-file-name ".closed" (file-name-directory gate)))))))

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
and it sleeps first when the target user is \"slow\". For \"warn\" it
writes an ssh warning to stderr first. For \"down\" it exits 255, as ssh does
on a failed connection, while the file `down' exists in DIR."
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
                 "case \" $* \" in *\" warn@\"*) echo 'X11 forwarding "
                 "request failed on channel 0' >&2 ;; esac\n"
                 "case \" $* \" in *\" down@\"*) [ -e \""
                 (expand-file-name "down" ,dir)
                 "\" ] && exit 255 ;; esac\n"
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
                   (setq commit-gate-nonce 'absent)
                   (commit-gate-record-accept)
                   (get-process "commit-gate-sentinel"))))
      (unwind-protect
          (progn
            (should (process-live-p proc))
            (should (commit-gate-accepted-p gate)))
        (delete-process proc)))))

(defun commit-gate-t--remote-capture (gate)
  "Read GATE's nonce over the shim, wait for it, and return the state."
  (commit-gate-t--with-name gate
    (commit-gate-capture-nonce)
    (should (eq commit-gate-nonce 'pending))
    (commit-gate-t--settle (get-process "commit-gate-nonce"))
    commit-gate-nonce))

(ert-deftest commit-gate-reads-a-remote-nonce-without-waiting ()
  "The read goes over `ssh' like the write, so opening a gate never blocks
on TRAMP. A missing file and a failed connection read differently."
  (commit-gate-t--with-ssh-shim dir _argv
    (let ((gate (commit-gate-t--run-dir dir commit-gate-t--nonce-a)))
      (should (equal (commit-gate-t--remote-capture (concat "/scp:u@dev:" gate))
                     (cons 'nonce commit-gate-t--nonce-a)))
      (should (eq (car (commit-gate-t--remote-capture
                        (concat "/scp:fail@dev:" gate)))
                  'refused))
      (delete-file (expand-file-name ".nonce" (file-name-directory gate)))
      (should (eq (commit-gate-t--remote-capture (concat "/scp:u@dev:" gate))
                  'absent)))))

(ert-deftest commit-gate-keeps-ssh-stderr-out-of-a-remote-nonce ()
  "An ssh warning on stderr does not reach the nonce parser."
  (commit-gate-t--with-ssh-shim dir _argv
    (let ((gate (commit-gate-t--run-dir dir commit-gate-t--nonce-a)))
      (should (equal (commit-gate-t--remote-capture
                      (concat "/scp:warn@dev:" gate))
                     (cons 'nonce commit-gate-t--nonce-a))))))

(ert-deftest commit-gate-retries-a-nonce-read-that-could-not-connect ()
  "A failed connection is transient, so `C-x #' reads the nonce again and the
next press approves. The reason leads the header line and the path ends it."
  (commit-gate-t--with-ssh-shim dir _argv
    (let* ((local (commit-gate-t--run-dir dir commit-gate-t--nonce-a))
           (gate (concat "/scp:down@dev:" local))
           (nonce-file (concat (file-name-directory gate) ".nonce"))
           (down (expand-file-name "down" dir)))
      (write-region "" nil down)
      (commit-gate-t--with-name gate
        (commit-gate-capture-nonce)
        (commit-gate-t--settle (get-process "commit-gate-nonce"))
        (should (eq (car-safe commit-gate-nonce) 'retry))
        (should (equal (cddr commit-gate-nonce) nonce-file))
        (delete-file down)
        (let ((err (should-error (commit-gate-record-accept)
                                 :type 'user-error)))
          (should (string-match-p "exit 255" (cadr err)))
          (should (string-match-p "C-x # again" (cadr err))))
        (should (string-prefix-p "Not approved. ssh could not reach"
                                 header-line-format))
        (should (string-suffix-p (concat nonce-file ".")
                                 (string-replace "%%" "%" header-line-format)))
        (should (eq commit-gate-nonce 'pending))
        (commit-gate-t--settle (get-process "commit-gate-nonce"))
        (should (equal commit-gate-nonce (cons 'nonce commit-gate-t--nonce-a)))
        (commit-gate-t--settle (commit-gate-record-accept)))
      (should (equal (commit-gate-t--contents
                      (expand-file-name ".closed" (file-name-directory local)))
                     commit-gate-t--nonce-a)))))

(ert-deftest commit-gate-refuses-a-retry-whose-run-has-ended ()
  "commit-land removes the run directory when it gives up, so a repeated read
that finds no nonce must refuse rather than approve with the epoch."
  (commit-gate-t--with-ssh-shim dir _argv
    (let* ((local (commit-gate-t--run-dir dir commit-gate-t--nonce-a))
           (gate (concat "/scp:down@dev:" local))
           (down (expand-file-name "down" dir)))
      (write-region "" nil down)
      (commit-gate-t--with-name gate
        (commit-gate-capture-nonce)
        (commit-gate-t--settle (get-process "commit-gate-nonce"))
        (should (eq (car-safe commit-gate-nonce) 'retry))
        (delete-file down)
        (delete-directory (file-name-directory local) t)
        (should-error (commit-gate-record-accept) :type 'user-error)
        (commit-gate-t--settle (get-process "commit-gate-nonce"))
        (should (equal commit-gate-nonce
                       (cons 'refused ".nonce is gone, so its run has ended")))
        (should-error (commit-gate-record-accept) :type 'user-error)
        (should (string-prefix-p "Not approved. .nonce is gone"
                                 header-line-format)))
      (should-not (commit-gate-accepted-p gate))
      (should-not (file-exists-p (concat local ".closed"))))))

(ert-deftest commit-gate-reports-a-retry-that-could-not-start ()
  "When the repeated read cannot be spawned, the header line gives that
refusal and does not promise a read that is not running."
  (commit-gate-t--with-ssh-shim dir _argv
    (let* ((local (commit-gate-t--run-dir dir commit-gate-t--nonce-a))
           (gate (concat "/scp:down@dev:" local))
           (down (expand-file-name "down" dir)))
      (write-region "" nil down)
      (commit-gate-t--with-name gate
        (commit-gate-capture-nonce)
        (commit-gate-t--settle (get-process "commit-gate-nonce"))
        (should (eq (car-safe commit-gate-nonce) 'retry))
        (let ((exec-path (list (expand-file-name "no-such-dir" dir))))
          (let ((err (should-error (commit-gate-record-accept)
                                   :type 'user-error)))
            (should-not (string-match-p "being read again" (cadr err)))))
        (should (equal commit-gate-nonce
                       (cons 'refused ".nonce could not be read")))
        (should (string-prefix-p "Not approved. .nonce could not be read"
                                 header-line-format))
        (should-not (get-process "commit-gate-nonce")))
      (should-not (commit-gate-accepted-p gate)))))

(ert-deftest commit-gate-does-not-retry-a-nonce-read-that-failed-remotely ()
  "Only a failed connection is retried. Any other failure stays a refusal."
  (commit-gate-t--with-ssh-shim dir _argv
    (let ((gate (concat "/scp:fail@dev:"
                        (commit-gate-t--run-dir dir commit-gate-t--nonce-a))))
      (commit-gate-t--with-name gate
        (commit-gate-capture-nonce)
        (commit-gate-t--settle (get-process "commit-gate-nonce"))
        (let ((state commit-gate-nonce))
          (should (eq (car-safe state) 'refused))
          (should-error (commit-gate-record-accept) :type 'user-error)
          (should (equal commit-gate-nonce state))
          (should-not (get-process "commit-gate-nonce")))))))

(ert-deftest commit-gate-refuses-a-remote-gate-still-reading ()
  "A pending read has no nonce to write yet, so `C-x #' says to retry."
  (commit-gate-t--with-name "/scp:u@dev:/r/.git/claude-land/n/CLAUDE_COMMIT_MSG"
    (setq commit-gate-nonce 'pending)
    (let ((err (should-error (commit-gate-record-accept) :type 'user-error)))
      (should (string-match-p "still being read" (cadr err)))
      (should (string-match-p "C-x # again" (cadr err))))))

(ert-deftest commit-gate-writes-a-remote-nonce-to-the-run-directory ()
  "The remote write carries the nonce to `.closed' beside the gate."
  (commit-gate-t--with-ssh-shim dir _argv
    (let* ((local (commit-gate-t--run-dir dir commit-gate-t--nonce-a))
           (gate (concat "/scp:u@dev:" local))
           (closed (expand-file-name ".closed" (file-name-directory local))))
      (commit-gate--write-record gate "1000" commit-gate-t--nonce-a)
      (commit-gate-t--settle
       (commit-gate--spawn-remote gate "1000" commit-gate-t--nonce-a))
      (should (equal (commit-gate-t--contents closed) commit-gate-t--nonce-a))
      (should-not (file-exists-p (concat closed ".tmp"))))))

;;; Accepting a claim

;; The ids are from sha256sum, so a fault in the id rule cannot hide behind
;; the same fault in the test.
(defconst commit-gate-t--claim-a "David wanted it for his own reasons."
  "A claim the diff neither shows nor contradicts.")
(defconst commit-gate-t--id-a "ff851277bfb974d6"
  "The id of `commit-gate-t--claim-a'.")
(defconst commit-gate-t--claim-b "The cache is cold on the first run."
  "A second such claim.")
(defconst commit-gate-t--id-b "bed67787c60bb632"
  "The id of `commit-gate-t--claim-b'.")

(defun commit-gate-t--claim (id text)
  "The claim line commit-land writes for TEXT with ID."
  (format "# claim-unsupported %s %s\n" id text))

(defun commit-gate-t--gate-text (message &rest claim-lines)
  "A gate holding MESSAGE above the scissors and CLAIM-LINES below it."
  (concat message
          commit-gate-scissors "\n"
          "# Do not modify or remove the line above.\n"
          "# Everything below it is the staged diff, for review only.\n"
          (if claim-lines
              (concat "#\n# The diff neither shows nor contradicts these claims.\n"
                      (apply #'concat claim-lines)
                      "#\n")
            "")
          "diff --git a/f b/f\n"))

(defun commit-gate-t--claim-gate (dir text)
  "A run directory gate under DIR for `commit-gate-t--nonce-a' holding TEXT."
  (let ((gate (commit-gate-t--run-dir dir commit-gate-t--nonce-a)))
    (with-temp-file gate (insert text))
    gate))

(defun commit-gate-t--closed (gate)
  "The contents of the `.closed' beside GATE, read as raw bytes."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally
     (expand-file-name ".closed" (file-name-directory gate)))
    (buffer-string)))

(defmacro commit-gate-t--answering (answer &rest body)
  "Run BODY with every typed answer ANSWER, quietly.
His `yes-or-no-p' takes one key, so the gate must not ask through it."
  (declare (indent 1))
  `(let ((inhibit-message t))
     (cl-letf (((symbol-function 'read-string) (lambda (&rest _) ,answer))
               ((symbol-function 'yes-or-no-p)
                (lambda (_p) (error "asked through yes-or-no-p"))))
       ,@body)))

(defun commit-gate-t--goto-claim (text)
  "Move point onto the claim line for TEXT below the scissors."
  (goto-char (point-max))
  (search-backward (concat " " text)))

(defun commit-gate-t--accepted-marks ()
  "The accepted claim marks in the current buffer."
  (seq-filter (lambda (ov) (overlay-get ov 'commit-gate-claim))
              (overlays-in (point-min) (point-max))))

(ert-deftest commit-gate-reads-claims-only-below-the-last-scissors ()
  "The message half is David's text, so a claim line there, or a copy of the
scissors line with a claim after it, is never a claim."
  (commit-gate-t--with-name "/tmp/x/.git/CLAUDE_COMMIT_MSG"
    (insert "Subject\n\n"
            (commit-gate-t--claim commit-gate-t--id-b commit-gate-t--claim-b)
            commit-gate-scissors "\n"
            (commit-gate-t--claim commit-gate-t--id-b commit-gate-t--claim-b)
            (commit-gate-t--gate-text
             "" (commit-gate-t--claim commit-gate-t--id-a
                                      commit-gate-t--claim-a)))
    (should (equal (mapcar (lambda (c) (list (nth 0 c) (nth 1 c) (nth 2 c)))
                           (commit-gate--claims))
                   (list (list commit-gate-t--id-a commit-gate-t--claim-a t))))))

(ert-deftest commit-gate-reads-no-claims-without-a-scissors-line ()
  "A claim line with no scissors below it is all message."
  (commit-gate-t--with-name "/tmp/x/.git/CLAUDE_COMMIT_MSG"
    (insert (commit-gate-t--claim commit-gate-t--id-a commit-gate-t--claim-a))
    (should-not (commit-gate--claims))))

(ert-deftest commit-gate-claim-id-is-the-sha256-of-the-utf-8-text ()
  "The rule commit-land uses, including for a character outside ASCII."
  (should (equal (commit-gate--claim-id commit-gate-t--claim-a)
                 commit-gate-t--id-a))
  (should (equal (commit-gate--claim-id "The naïve path was slower.")
                 "689dc2163752358a")))

(ert-deftest commit-gate-cannot-accept-a-claim-whose-id-does-not-match ()
  "A mismatch means the line was edited, so it is refused before he is asked."
  (commit-gate-t--in-dir dir
    (let ((gate (commit-gate-t--claim-gate
                 dir (commit-gate-t--gate-text
                      "Subject\n"
                      (commit-gate-t--claim commit-gate-t--id-a
                                            commit-gate-t--claim-b)))))
      (commit-gate-t--visit gate
        (should-not (nth 2 (car (commit-gate--claims))))
        (commit-gate-t--goto-claim commit-gate-t--claim-b)
        (cl-letf (((symbol-function 'read-string)
                   (lambda (&rest _) (error "asked about an edited claim"))))
          (let ((err (should-error (commit-gate-accept-claim)
                                   :type 'user-error)))
            (should (string-match-p "was edited" (cadr err)))))
        (should-not commit-gate--accepted-claims)
        (commit-gate-record-accept))
      (should (equal (commit-gate-t--closed gate) commit-gate-t--nonce-a)))))

(ert-deftest commit-gate-stamp-line-one-is-the-bare-nonce ()
  "commit-land matches line one against the run's nonce exactly."
  (commit-gate-t--in-dir dir
    (let ((gate (commit-gate-t--claim-gate
                 dir (commit-gate-t--gate-text
                      "Subject\n"
                      (commit-gate-t--claim commit-gate-t--id-a
                                            commit-gate-t--claim-a)))))
      (commit-gate-t--visit gate
        (commit-gate-t--goto-claim commit-gate-t--claim-a)
        (commit-gate-t--answering "yes" (commit-gate-accept-claim))
        (commit-gate-record-accept))
      (should (equal (car (split-string (commit-gate-t--closed gate) "\n"))
                     commit-gate-t--nonce-a)))))

(ert-deftest commit-gate-no-accepts-writes-the-old-stamp-locally ()
  "A gate that lists claims but has none accepted writes the bare nonce with
no newline."
  (commit-gate-t--in-dir dir
    (let ((gate (commit-gate-t--claim-gate
                 dir (commit-gate-t--gate-text
                      "Subject\n"
                      (commit-gate-t--claim commit-gate-t--id-a
                                            commit-gate-t--claim-a)))))
      (commit-gate-t--visit gate (commit-gate-record-accept))
      (should (equal (commit-gate-t--closed gate) commit-gate-t--nonce-a)))))

(ert-deftest commit-gate-one-accept-writes-an-accept-line-locally ()
  "The id written is the one recomputed from the claim's text."
  (commit-gate-t--in-dir dir
    (let ((gate (commit-gate-t--claim-gate
                 dir (commit-gate-t--gate-text
                      "Subject\n"
                      (commit-gate-t--claim commit-gate-t--id-a
                                            commit-gate-t--claim-a)
                      (commit-gate-t--claim commit-gate-t--id-b
                                            commit-gate-t--claim-b)))))
      (commit-gate-t--visit gate
        (commit-gate-t--goto-claim commit-gate-t--claim-a)
        (commit-gate-t--answering "yes" (commit-gate-accept-claim))
        (commit-gate-record-accept))
      (should (equal (commit-gate-t--closed gate)
                     (concat commit-gate-t--nonce-a "\naccept "
                             commit-gate-t--id-a "\n")))
      (should-not (file-exists-p
                   (expand-file-name ".closed.tmp"
                                     (file-name-directory gate)))))))

(defun commit-gate-t--remote-accept (dir accept)
  "Approve a remote gate under DIR over the shim, accepting the first claim
when ACCEPT is non-nil, and return the stamp written."
  (let* ((local (commit-gate-t--claim-gate
                 dir (commit-gate-t--gate-text
                      "Subject\n"
                      (commit-gate-t--claim commit-gate-t--id-a
                                            commit-gate-t--claim-a)))))
    (commit-gate-t--with-name (concat "/scp:u@dev:" local)
      (insert-file-contents local)
      (setq commit-gate-nonce (cons 'nonce commit-gate-t--nonce-a))
      (when accept
        (commit-gate-t--goto-claim commit-gate-t--claim-a)
        (commit-gate-t--answering "yes" (commit-gate-accept-claim)))
      (commit-gate-record-accept)
      (commit-gate-t--settle (get-process "commit-gate-sentinel")))
    (should-not (file-exists-p
                 (expand-file-name ".closed.tmp" (file-name-directory local))))
    (commit-gate-t--closed local)))

(ert-deftest commit-gate-no-accepts-writes-the-old-stamp-remotely ()
  "The remote write is byte for byte the bare nonce when nothing is accepted."
  (commit-gate-t--with-ssh-shim dir _argv
    (should (equal (commit-gate-t--remote-accept dir nil)
                   commit-gate-t--nonce-a))))

(ert-deftest commit-gate-one-accept-writes-an-accept-line-remotely ()
  "The multi-line payload survives the far side's shell intact."
  (commit-gate-t--with-ssh-shim dir _argv
    (should (equal (commit-gate-t--remote-accept dir t)
                   (concat commit-gate-t--nonce-a "\naccept "
                           commit-gate-t--id-a "\n")))))

(ert-deftest commit-gate-accepting-an-accepted-claim-unaccepts-it ()
  "A second C-c C-a takes the accept back, and a third records it once."
  (commit-gate-t--in-dir dir
    (let ((gate (commit-gate-t--claim-gate
                 dir (commit-gate-t--gate-text
                      "Subject\n"
                      (commit-gate-t--claim commit-gate-t--id-a
                                            commit-gate-t--claim-a)))))
      (commit-gate-t--visit gate
        (commit-gate-show-claims)
        (commit-gate-show-banner)
        (commit-gate-t--goto-claim commit-gate-t--claim-a)
        (commit-gate-t--answering "yes"
          (commit-gate-accept-claim))
        (should (equal commit-gate--accepted-claims
                       (list commit-gate-t--id-a)))
        (should (commit-gate-t--accepted-marks))
        ;; Unaccepting drops an accept, so it must not ask.
        (cl-letf (((symbol-function 'read-string)
                   (lambda (&rest _) (error "asked to unaccept")))
                  (inhibit-message t))
          (commit-gate-accept-claim))
        (should-not commit-gate--accepted-claims)
        (should-not (commit-gate-t--accepted-marks))
        (should (string-match-p "0 of 1 listed claims accepted"
                                header-line-format))
        (commit-gate-t--answering "yes"
          (commit-gate-accept-claim))
        (should (equal commit-gate--accepted-claims
                       (list commit-gate-t--id-a)))
        (commit-gate-record-accept))
      (should (equal (commit-gate-t--closed gate)
                     (concat commit-gate-t--nonce-a "\naccept "
                             commit-gate-t--id-a "\n"))))))

(ert-deftest commit-gate-accept-with-no-claim-lines-writes-nothing ()
  "There is nothing to ask about, so he is not asked and no stamp appears.
The approval then writes the bare nonce."
  (commit-gate-t--in-dir dir
    (let* ((gate (commit-gate-t--claim-gate
                  dir (commit-gate-t--gate-text "Subject\n")))
           (closed (expand-file-name ".closed" (file-name-directory gate))))
      (commit-gate-t--visit gate
        (cl-letf (((symbol-function 'read-string)
                   (lambda (&rest _) (error "asked with no claims"))))
          (let ((inhibit-message t))
            (should (equal (commit-gate-accept-claim)
                           "This gate lists no claims to accept."))))
        (should-not commit-gate--accepted-claims)
        (should-not (file-exists-p closed))
        (commit-gate-record-accept))
      (should (equal (commit-gate-t--closed gate) commit-gate-t--nonce-a)))))

(defun commit-gate-t--decline-with (answer)
  "Answer ANSWER to the accept prompt, and check the claim stays unaccepted."
  (commit-gate-t--in-dir dir
    (let ((gate (commit-gate-t--claim-gate
                 dir (commit-gate-t--gate-text
                      "Subject\n"
                      (commit-gate-t--claim commit-gate-t--id-a
                                            commit-gate-t--claim-a)))))
      (commit-gate-t--visit gate
        (commit-gate-t--goto-claim commit-gate-t--claim-a)
        (commit-gate-t--answering answer (commit-gate-accept-claim))
        (should-not commit-gate--accepted-claims)
        (commit-gate-record-accept))
      (should (equal (commit-gate-t--closed gate) commit-gate-t--nonce-a)))))

;; Anything but yes typed in full leaves the claim unaccepted.
(ert-deftest commit-gate-declined-accept-no ()
  "A plain no."
  (commit-gate-t--decline-with "no"))

(ert-deftest commit-gate-declined-accept-y ()
  "A single y is what his one-key `yes-or-no-p' would have taken."
  (commit-gate-t--decline-with "y"))

(ert-deftest commit-gate-declined-accept-empty ()
  "Return alone."
  (commit-gate-t--decline-with ""))

(ert-deftest commit-gate-declined-accept-yes-please ()
  "Trailing text after yes."
  (commit-gate-t--decline-with "yes please"))

(ert-deftest commit-gate-declined-accept-leading-space ()
  "A space before yes."
  (commit-gate-t--decline-with " yes"))

(ert-deftest commit-gate-declined-accept-upper-case ()
  "YES in capitals."
  (commit-gate-t--decline-with "YES"))

(ert-deftest commit-gate-asks-which-claim-off-a-claim-line ()
  "Off a claim line the claim is chosen by its text, and the prompt shows it."
  (commit-gate-t--in-dir dir
    (let ((gate (commit-gate-t--claim-gate
                 dir (commit-gate-t--gate-text
                      "Subject\n"
                      (commit-gate-t--claim commit-gate-t--id-a
                                            commit-gate-t--claim-a)
                      (commit-gate-t--claim commit-gate-t--id-b
                                            commit-gate-t--claim-b))))
          (asked nil))
      (commit-gate-t--visit gate
        (goto-char (point-min))
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (_p coll &rest _)
                     (should (equal coll (list commit-gate-t--claim-a
                                               commit-gate-t--claim-b)))
                     commit-gate-t--claim-b))
                  ((symbol-function 'read-string)
                   (lambda (p &rest _) (setq asked p) "yes")))
          (let ((inhibit-message t))
            (commit-gate-accept-claim)))
        (should (string-match-p (regexp-quote commit-gate-t--claim-b) asked))
        (should (equal commit-gate--accepted-claims
                       (list commit-gate-t--id-b)))))))

(ert-deftest commit-gate-epoch-gate-cannot-accept-a-claim ()
  "An epoch stamp carries no accept lines, so the accept is refused."
  (commit-gate-t--in-dir dir
    (let ((gate (expand-file-name "CLAUDE_COMMIT_MSG" dir)))
      (with-temp-file gate
        (insert (commit-gate-t--gate-text
                 "Subject\n"
                 (commit-gate-t--claim commit-gate-t--id-a
                                       commit-gate-t--claim-a))))
      (commit-gate-t--visit gate
        (should (eq commit-gate-nonce 'absent))
        (commit-gate-t--goto-claim commit-gate-t--claim-a)
        (commit-gate-t--answering "yes"
          (should-error (commit-gate-accept-claim) :type 'user-error))
        (should-not commit-gate--accepted-claims)))))

(ert-deftest commit-gate-banner-counts-accepted-claims-and-marks-them ()
  "The banner says how many are accepted and that the rest refuse, and the
accepted line is marked."
  (commit-gate-t--in-dir dir
    (let ((gate (commit-gate-t--claim-gate
                 dir (commit-gate-t--gate-text
                      "Subject\n"
                      (commit-gate-t--claim commit-gate-t--id-a
                                            commit-gate-t--claim-a)
                      (commit-gate-t--claim commit-gate-t--id-b
                                            commit-gate-t--claim-b)))))
      (commit-gate-t--visit gate
        (commit-gate-show-banner)
        (commit-gate-show-claims)
        (should commit-gate-claims-mode)
        (should (eq (key-binding (kbd "C-c C-a")) #'commit-gate-accept-claim))
        (should (string-match-p "0 of 2 listed claims accepted"
                                header-line-format))
        (should (string-match-p "unaccepted refuses the landing"
                                header-line-format))
        (commit-gate-t--goto-claim commit-gate-t--claim-a)
        (commit-gate-t--answering "yes" (commit-gate-accept-claim))
        (should (string-match-p "1 of 2 listed claims accepted"
                                header-line-format))
        (should (seq-some (lambda (ov) (overlay-get ov 'commit-gate-claim))
                          (overlays-at (point))))))))

(ert-deftest commit-gate-hashes-the-bytes-a-latin-1-read-holds ()
  "A raw byte in the diff makes Emacs read the gate as Latin-1. The id is
still the verifier's, the SHA-256 of the claim's UTF-8 text."
  (commit-gate-t--in-dir dir
    (let ((gate (commit-gate-t--run-dir dir commit-gate-t--nonce-a))
          (text "The naïve path was slower.")
          (id "689dc2163752358a"))
      (let ((coding-system-for-write 'no-conversion))
        (write-region
         (concat (encode-coding-string
                  (commit-gate-t--gate-text
                   "Subject\n" (commit-gate-t--claim id text))
                  'utf-8-unix)
                 "+a raw \xff\xfe byte\n")
         nil gate nil 'quiet))
      (commit-gate-t--visit gate
        (let ((claim (car (commit-gate--claims))))
          (should (equal (car claim) id))
          (should (nth 2 claim)))
        (goto-char (point-max))
        (re-search-backward "^# claim-unsupported ")
        (commit-gate-t--answering "yes" (commit-gate-accept-claim))
        (should (equal commit-gate--accepted-claims (list id)))
        (commit-gate-record-accept))
      (should (equal (commit-gate-t--closed gate)
                     (concat commit-gate-t--nonce-a "\naccept " id "\n"))))))

(defun commit-gate-t--accept-then (change)
  "Accept claim A, run CHANGE on its line, approve, and return the stamp."
  (commit-gate-t--in-dir dir
    (let ((gate (commit-gate-t--claim-gate
                 dir (commit-gate-t--gate-text
                      "Subject\n"
                      (commit-gate-t--claim commit-gate-t--id-a
                                            commit-gate-t--claim-a)))))
      (commit-gate-t--visit gate
        (commit-gate-t--goto-claim commit-gate-t--claim-a)
        (commit-gate-t--answering "yes" (commit-gate-accept-claim))
        (should (equal commit-gate--accepted-claims
                       (list commit-gate-t--id-a)))
        (beginning-of-line)
        (funcall change)
        (commit-gate-record-accept))
      (commit-gate-t--closed gate))))

(ert-deftest commit-gate-an-accepted-claim-edited-is-not-written ()
  "The stamp names only a claim whose line still stands as accepted."
  (should (equal (commit-gate-t--accept-then
                  (lambda ()
                    (search-forward "reasons")
                    (replace-match "motives")))
                 commit-gate-t--nonce-a)))

(ert-deftest commit-gate-an-accepted-claim-cut-is-not-written ()
  "A cut line is no longer a claim to accept."
  (should (equal (commit-gate-t--accept-then
                  (lambda ()
                    (delete-region (line-beginning-position)
                                   (line-beginning-position 2))))
                 commit-gate-t--nonce-a)))

(ert-deftest commit-gate-a-second-scissors-below-the-claims-drops-them ()
  "Only the last scissors line counts, so claims above a new one are gone
from the banner and the stamp."
  (commit-gate-t--in-dir dir
    (let ((gate (commit-gate-t--claim-gate
                 dir (commit-gate-t--gate-text
                      "Subject\n"
                      (commit-gate-t--claim commit-gate-t--id-a
                                            commit-gate-t--claim-a)))))
      (commit-gate-t--visit gate
        (commit-gate-show-banner)
        (commit-gate-show-claims)
        (commit-gate-t--goto-claim commit-gate-t--claim-a)
        (commit-gate-t--answering "yes" (commit-gate-accept-claim))
        (should (string-match-p "1 of 1 listed claims accepted"
                                header-line-format))
        (goto-char (point-max))
        (insert commit-gate-scissors "\n")
        (should-not (string-match-p "claims" header-line-format))
        (should-not (commit-gate-t--accepted-marks))
        (commit-gate-record-accept))
      (should (equal (commit-gate-t--closed gate) commit-gate-t--nonce-a)))))

(ert-deftest commit-gate-a-dos-coded-gate-writes-no-crlf ()
  "verify-claims refuses any line but `accept ID', and a CR is part of one."
  (commit-gate-t--in-dir dir
    (let ((gate (commit-gate-t--claim-gate
                 dir (commit-gate-t--gate-text
                      "Subject\n"
                      (commit-gate-t--claim commit-gate-t--id-a
                                            commit-gate-t--claim-a)))))
      (commit-gate-t--visit gate
        (setq buffer-file-coding-system 'undecided-dos)
        (commit-gate-t--goto-claim commit-gate-t--claim-a)
        (commit-gate-t--answering "yes" (commit-gate-accept-claim))
        (commit-gate-record-accept))
      (should (equal (commit-gate-t--closed gate)
                     (concat commit-gate-t--nonce-a "\naccept "
                             commit-gate-t--id-a "\n"))))))

(ert-deftest commit-gate-banner-and-marks-follow-an-edit ()
  "Breaking or cutting a claim line updates the count and the mark without
another C-c C-a."
  (commit-gate-t--in-dir dir
    (let ((gate (commit-gate-t--claim-gate
                 dir (commit-gate-t--gate-text
                      "Subject\n"
                      (commit-gate-t--claim commit-gate-t--id-a
                                            commit-gate-t--claim-a)
                      (commit-gate-t--claim commit-gate-t--id-b
                                            commit-gate-t--claim-b)))))
      (commit-gate-t--visit gate
        (commit-gate-show-banner)
        (commit-gate-show-claims)
        (should (memq #'commit-gate--refresh-claims after-change-functions))
        (should-not (memq #'commit-gate--refresh-claims
                          (default-value 'after-change-functions)))
        (commit-gate-t--goto-claim commit-gate-t--claim-a)
        (commit-gate-t--answering "yes" (commit-gate-accept-claim))
        (should (string-match-p "1 of 2 listed claims accepted"
                                header-line-format))
        (search-forward "reasons")
        (replace-match "motives")
        (should (string-match-p "0 of 2 listed claims accepted"
                                header-line-format))
        (should-not (seq-some (lambda (ov) (overlay-get ov 'commit-gate-claim))
                              (overlays-in (point-min) (point-max))))
        (commit-gate-t--goto-claim commit-gate-t--claim-b)
        (delete-region (line-beginning-position) (line-beginning-position 2))
        (should (string-match-p "0 of 1 listed claims accepted"
                                header-line-format))
        ;; An editing command may read the match data after its own change.
        (goto-char (point-min))
        (should (re-search-forward "\\(Sub\\)ject" nil t))
        (insert "!")
        (should (equal (match-string 1) "Sub"))
        (commit-gate-claims-mode -1)
        (should-not (memq #'commit-gate--refresh-claims
                          after-change-functions))))))

(ert-deftest commit-gate-typing-in-the-message-skips-the-diff-scan ()
  "Only an edit at or below the last scissors line reads the claims again,
and cutting that line counts as one."
  (commit-gate-t--in-dir dir
    (let ((gate (commit-gate-t--claim-gate
                 dir (commit-gate-t--gate-text
                      "Subject\n"
                      (commit-gate-t--claim commit-gate-t--id-a
                                            commit-gate-t--claim-a))))
          (scans 0))
      (commit-gate-t--visit gate
        (commit-gate-show-banner)
        (commit-gate-show-claims)
        (let ((parse (symbol-function 'commit-gate--claims)))
          (cl-letf (((symbol-function 'commit-gate--claims)
                     (lambda () (setq scans (1+ scans)) (funcall parse))))
            (goto-char (point-min))
            (insert "x")
            (should (= scans 0))
            (search-forward commit-gate-scissors)
            (delete-region (line-beginning-position)
                           (line-beginning-position 2))
            (should (> scans 0))))
        (should-not (string-match-p "claims" header-line-format))))))

(ert-deftest commit-gate-a-failing-refresh-never-reaches-the-edit ()
  "An error while redrawing must not stop his typing, nor drop the hook."
  (commit-gate-t--in-dir dir
    (let ((gate (commit-gate-t--claim-gate
                 dir (commit-gate-t--gate-text
                      "Subject\n"
                      (commit-gate-t--claim commit-gate-t--id-a
                                            commit-gate-t--claim-a)))))
      (commit-gate-t--visit gate
        (commit-gate-show-claims)
        (cl-letf (((symbol-function 'commit-gate--claims)
                   (lambda () (error "Parse failed"))))
          (goto-char (point-min))
          (insert "x"))
        (should (memq #'commit-gate--refresh-claims after-change-functions))
        (should (equal (buffer-substring (point-min) (1+ (point-min))) "x"))))))

(ert-deftest commit-gate-accepting-after-a-refusal-keeps-the-reason ()
  "The header line still says why C-x # was refused, beside the count."
  (commit-gate-t--in-dir dir
    (let ((gate (commit-gate-t--run-dir dir commit-gate-t--nonce-a "bad\n")))
      (with-temp-file gate
        (insert (commit-gate-t--gate-text
                 "Subject\n"
                 (commit-gate-t--claim commit-gate-t--id-a
                                       commit-gate-t--claim-a))))
      (commit-gate-t--visit gate
        (commit-gate-show-banner)
        (commit-gate-show-claims)
        (should-error (commit-gate-record-accept) :type 'user-error)
        (should (string-prefix-p "Not approved. .nonce is malformed"
                                 header-line-format))
        (should (string-match-p "0 of 1 listed claims accepted"
                                header-line-format))
        ;; As a repeated read could leave it, so the accept is allowed.
        (setq commit-gate-nonce (cons 'nonce commit-gate-t--nonce-a))
        (commit-gate-t--goto-claim commit-gate-t--claim-a)
        (commit-gate-t--answering "yes" (commit-gate-accept-claim))
        (should (string-prefix-p "Not approved. .nonce is malformed"
                                 header-line-format))
        (should (string-match-p "1 of 1 listed claims accepted"
                                header-line-format))
        (should (eq (get-text-property 0 'face header-line-format)
                    'warning))))))

(defmacro commit-gate-t--with-an-accepted-claim (&rest body)
  "Run BODY in a gate with claim A accepted and marked."
  (declare (indent 0))
  `(commit-gate-t--in-dir dir
     (let ((gate (commit-gate-t--claim-gate
                  dir (commit-gate-t--gate-text
                       "Subject\n"
                       (commit-gate-t--claim commit-gate-t--id-a
                                             commit-gate-t--claim-a)))))
       (commit-gate-t--visit gate
         (commit-gate-show-claims)
         (commit-gate-t--goto-claim commit-gate-t--claim-a)
         (commit-gate-t--answering "yes" (commit-gate-accept-claim))
         (should (commit-gate-t--accepted-marks))
         ,@body))))

(ert-deftest commit-gate-a-major-mode-change-leaves-no-accepted-mark ()
  "The change drops the accepts, so a mark left behind would lie."
  (commit-gate-t--with-an-accepted-claim
    (text-mode)
    (should-not commit-gate--accepted-claims)
    (should-not (commit-gate-t--accepted-marks))))

(ert-deftest commit-gate-a-revert-leaves-no-accepted-mark ()
  "A revert drops the accepts, so a mark left behind would lie."
  (commit-gate-t--with-an-accepted-claim
    (revert-buffer t t)
    (should-not commit-gate--accepted-claims)
    (should-not (commit-gate-t--accepted-marks))
    ;; The revert reruns the major mode, which would leave C-c C-a unbound.
    (should commit-gate-claims-mode)
    (should (eq (key-binding (kbd "C-c C-a")) #'commit-gate-accept-claim))
    (should (memq #'commit-gate--refresh-claims after-change-functions))
    (should (string-match-p "0 of 1 listed claims accepted"
                            header-line-format))))

(ert-deftest commit-gate-a-revert-that-keeps-the-modes-drops-the-accepts ()
  "Auto-revert keeps the modes, so the accepts must not outlive it."
  (commit-gate-t--with-an-accepted-claim
    (revert-buffer t t t)
    (should-not commit-gate--accepted-claims)
    (should-not (commit-gate-t--accepted-marks))
    (should (string-match-p "0 of 1 listed claims accepted"
                            header-line-format))))

(ert-deftest commit-gate-turning-the-claims-mode-off-leaves-no-accepted-mark ()
  "With the mode off nothing keeps the marks in step with the accepts."
  (commit-gate-t--with-an-accepted-claim
    (commit-gate-claims-mode -1)
    (should-not (commit-gate-t--accepted-marks))))

(ert-deftest commit-gate-banner-omits-claims-when-none-are-listed ()
  "A gate with no claims keeps the plain banner."
  (commit-gate-t--with-name "/tmp/x/.git/CLAUDE_COMMIT_MSG"
    (insert (commit-gate-t--gate-text "Subject\n"))
    (commit-gate-show-banner)
    (should-not (string-match-p "claims" header-line-format))))

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
  (should (equal (commit-gate-repo-label
                  "/h/dotfiles/.git/claude-land/0a1b/CLAUDE_COMMIT_MSG")
                 "dotfiles"))
  (should (equal (commit-gate-repo-label
                  "/h/dotfiles/.git/worktrees/wt/claude-land/0a1b/CLAUDE_COMMIT_MSG")
                 "dotfiles, worktree wt"))
  (should (equal (commit-gate-repo-label
                  "/h/mono/.git/modules/llvm/claude-land/0a1b/CLAUDE_COMMIT_MSG")
                 "mono, submodule llvm"))
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

;;; Saying what was approved

(ert-deftest commit-gate-accept-holds-the-approval-message ()
  "The repo and subject are read before the gate closes."
  (commit-gate-t--in-dir dir
    (let* ((git (expand-file-name "r/.git/" dir))
           (gate (expand-file-name "CLAUDE_COMMIT_MSG" git))
           (commit-gate--pending-announcement nil))
      (make-directory git t)
      (with-temp-file gate (insert "\nemacs: fix the thing\n\nBody.\n"))
      (commit-gate-t--visit gate (commit-gate-record-accept))
      (should (equal (cdr commit-gate--pending-announcement)
                     '("r" "emacs: fix the thing"))))))

(ert-deftest commit-gate-refused-accept-holds-no-message ()
  "A refusal stays in the header line, so no message may say approved."
  (commit-gate-t--in-dir dir
    (let ((gate (commit-gate-t--run-dir dir commit-gate-t--nonce-a "junk\n"))
          (commit-gate--pending-announcement '(stale "x" "y")))
      (commit-gate-t--visit gate
        (should-error (commit-gate-record-accept) :type 'user-error))
      (should-not commit-gate--pending-announcement))))

(ert-deftest commit-gate-another-buffer-clears-a-held-message ()
  "A quit at the save prompt leaves a message held. The next finish of any
other buffer must not announce it."
  (let ((commit-gate--pending-announcement '(stale "x" "y")))
    (with-temp-buffer (commit-gate-record-accept))
    (should-not commit-gate--pending-announcement)))

(ert-deftest commit-gate-announces-after-server-edit-only ()
  "The message comes after `server-edit' returns, and only once."
  (let ((commit-gate--pending-announcement nil)
        (said nil))
    (cl-letf (((symbol-function 'commit-gate-announce-approval)
               (lambda (&rest args) (setq said args))))
      (setq commit-gate--pending-announcement '(b "r" "s"))
      (commit-gate-announce-pending)
      (should (equal said '(b "r" "s")))
      (should-not commit-gate--pending-announcement)
      (setq said nil)
      (commit-gate-announce-pending)
      (should-not said))))

(ert-deftest commit-gate-announces-the-approval ()
  "With an ordinary buffer showing, it names only the approved gate."
  (with-temp-buffer
    (let ((approved (current-buffer)))
      (with-temp-buffer
        (set-window-buffer (selected-window) (current-buffer))
        (should (equal (commit-gate-announce-approval
                        approved "dotfiles" "emacs: fix it")
                       "Approved the commit for dotfiles: emacs: fix it."))
        (should (equal (commit-gate-announce-approval approved nil "Fix it.")
                       "Approved the commit: Fix it."))))))

(ert-deftest commit-gate-announces-another-gate-showing ()
  "When the buffer shown next is a second gate, the message says so."
  (with-temp-buffer
    (let ((approved (current-buffer)))
      (commit-gate-t--with-name "/h/prevue/.git/worktrees/wt/CLAUDE_COMMIT_MSG"
        (set-window-buffer (selected-window) (current-buffer))
        (should (equal (commit-gate-announce-approval approved "dotfiles" "s")
                       "Approved the commit for dotfiles: s. This is another \
commit gate, for prevue, worktree wt."))))))

(ert-deftest commit-gate-does-not-call-the-approved-gate-another ()
  "A gate still showing after its own approval is not a second gate."
  (commit-gate-t--with-name "/h/dotfiles/.git/CLAUDE_COMMIT_MSG"
    (set-window-buffer (selected-window) (current-buffer))
    (should (equal (commit-gate-announce-approval (current-buffer) nil nil)
                   "Approved the commit."))))

;;; Arming it

(ert-deftest commit-gate-arms-and-reports-itself ()
  "The reader probes for this before trusting any sentinel."
  (let ((server-visit-hook nil) (find-file-hook nil))
    (unwind-protect
        (progn
          (advice-remove 'server-done #'commit-gate-record-accept)
          (should-not (commit-gate-armed-p))
          (commit-gate-arm)
          (should (commit-gate-armed-p)))
      (advice-remove 'server-done #'commit-gate-record-accept)
      (advice-remove 'server-edit #'commit-gate-announce-pending))))

(ert-deftest commit-gate-arming-twice-does-not-stack ()
  "The configuration is reloaded often, and a doubled advice would stamp
twice and make the count meaningless. Measured rather than assumed."
  (let ((server-visit-hook nil) (find-file-hook nil))
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
      (advice-remove 'server-done #'commit-gate-record-accept)
      (advice-remove 'server-edit #'commit-gate-announce-pending))))

(ert-deftest commit-gate-arming-installs-both-header-lines ()
  "Once each, however often the configuration is reloaded, and the nonce
read on both hooks that can open a gate. The claim keys come on with them."
  (let ((server-visit-hook nil) (find-file-hook nil))
    (unwind-protect
        (progn
          (commit-gate-arm)
          (commit-gate-arm)
          (should (equal (sort (copy-sequence server-visit-hook) #'string<)
                         '(commit-gate-capture-nonce
                           commit-gate-show-banner
                           commit-gate-show-claims
                           commit-gate-warn-if-misnamed)))
          (should (equal find-file-hook '(commit-gate-capture-nonce))))
      (advice-remove 'server-done #'commit-gate-record-accept)
      (advice-remove 'server-edit #'commit-gate-announce-pending))))

;;; commit-gate-tests.el ends here
