;;; commit-gate.el --- Record that a commit gate was approved -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; A commit agent parks a blocking `emacsclient' on a file named
;; CLAUDE_COMMIT_MSG and waits. `C-x #' means the message is approved.
;; `C-x k' means it is not.
;;
;; Afterwards the two are INDISTINGUISHABLE. `server-kill-new-buffers' is t
;; here, so both leave no buffer behind and both let the client exit 0, and the
;; receipt, its age against HEAD and the staged tree all read the same either
;; way. An agent holding only those signals must either refuse every approval
;; or accept every dismissal.
;;
;; `C-x k' never reaches `server-done' and `C-x #' always does, so an advice
;; there is the one place the difference can be observed. This file is that
;; advice.
;;
;; An accept is recorded twice, and the two records fail differently.
;;
;; THE LOCAL RECORD is written first, and it is written synchronously. It
;; lives under `commit-gate-record-directory' on the machine that runs Emacs,
;; so it needs no network and cannot be lost to one. `commit-gate-accepted-p'
;; reads it back. A reader on another host asks this Emacs over `emacsclient
;; --eval' rather than guess a path, because the naming scheme is internal.
;;
;; THE REMOTE SENTINEL is a file named after the gate, with ".closed" appended.
;; It is the record a reader on the gate's own host can see without asking
;; anybody. For a remote gate it is written by a spawned `ssh', so `C-x #'
;; never waits for it. The process sentinel appends the outcome to the local
;; record, so an approval whose remote write failed reads differently from one
;; that landed.
;;
;; This split replaces a synchronous TRAMP write under `with-timeout'. That
;; budget was decorative. A timer runs only where Emacs stops to check for
;; one, and a TRAMP write does not stop there, so the budget never fired and a
;; bigger one would not have either. The write's real failure mode was never a
;; timeout. Against an unreachable host it raised `remote-file-error', which
;; this file swallows, and that left an accept with no record at all.
;;
;; Four properties it has to have. Each one closes a failure that happened.
;;
;; ATTRIBUTION. `server-done' takes no arguments and acts on the current
;; buffer, so `buffer-file-name' inside the advice is the buffer being
;; finished. A gate in another worktree has a different path and stamps its
;; own records. Without the check the advice fires on every other gate's
;; `C-x #' and reports an approval that never happened.
;;
;; THE BUFFER'S OWN PATH. The sentinel goes beside `buffer-file-name',
;; whatever prefix it carries. A gate opened over TRAMP reads as
;; "/ssh:HOST:/path/CLAUDE_COMMIT_MSG" in the Emacs that shows it, so a bare
;; local path would write the sentinel to the wrong machine.
;;
;; A TIMESTAMP, NOT A FLAG. This advice is permanent, so it is always armed.
;; Any `C-x #' on any CLAUDE_COMMIT_MSG stamps a record, including one that no
;; agent is waiting for. The stamp lets a reader require a record newer than
;; the moment it opened its own gate. A reader that treats mere existence as
;; approval accepts a leftover. `commit-gate-accepted-p' takes a SINCE for
;; exactly this.
;;
;; NO FAULT ESCAPES. Every fault here is swallowed, because an error in an
;; advice on `server-done' would break finishing a buffer for every client. So
;; a reader that finds no record has to ask a person rather than read a
;; refusal. A missing record means UNPROVEN, and it does not mean denied.
;;
;; A near miss is said out loud. A client that parks on CLAUDE_COMMIT_MSG.txt
;; gets a buffer that looks like a gate and records nothing, so every approval
;; there reads as a dismissal. The header line of that buffer says so while he
;; can still act on it.
;;
;; A real gate is labelled too. Its header line names the repository and the
;; two keys. He kills a buffer he cannot identify, and `C-x k' discards the
;; message as quietly as `C-x #' approves it.

;;; Code:

(defgroup commit-gate nil
  "Record that a commit gate was approved."
  :group 'tools)

(defconst commit-gate-file-name "CLAUDE_COMMIT_MSG"
  "The one file name a commit gate is presented under.
Fixed deliberately. Twenty-three gate-file variants once accumulated across
one repository's worktrees, and cleanup cannot be mechanical against that.")

(defconst commit-gate-remote-methods '("ssh" "scp" "sshx" "scpx")
  "The TRAMP methods whose sentinel this package writes over `ssh'.
A gate this Emacs opens carries the `scp' method, because the client builds
the path as \"/scp:USER@HOST:\". Any other method gets no sentinel, and the
local record says so. Guessing an `ssh' target from a method that does not
name one would write the sentinel to the wrong host.")

(defcustom commit-gate-record-directory
  (expand-file-name "commit-gate/" user-emacs-directory)
  "Where the local record of each accepted gate is kept.
Local, because this is the write that cannot fail for want of a network.
One file per gate, named for a digest of the gate's own path, because every
worktree's gate shares one basename."
  :type 'directory
  :group 'commit-gate)

(defun commit-gate-buffer-p (&optional buffer)
  "Whether BUFFER, or the current buffer, is a commit gate."
  (let ((file (buffer-file-name buffer)))
    (and file
         (equal (file-name-nondirectory file) commit-gate-file-name)
         t)))

(defun commit-gate-misnamed-p (&optional buffer)
  "Whether BUFFER, or the current buffer, is named like a gate but is not one.
That is a file whose name starts with `commit-gate-file-name' and is not
exactly it. `C-x #' on such a buffer records no approval."
  (let ((file (buffer-file-name buffer)))
    (and file
         (let ((name (file-name-nondirectory file)))
           (and (string-prefix-p commit-gate-file-name name)
                (not (equal name commit-gate-file-name))))
         t)))

(defun commit-gate-warn-if-misnamed ()
  "Say in the header line that `C-x #' here records no approval.
Does nothing unless the current buffer is `commit-gate-misnamed-p'. Written
for `server-visit-hook', because the harm needs a client that waits."
  (when (commit-gate-misnamed-p)
    (let ((text (format "Not a commit gate. C-x # records no approval, \
because the file is not named %s." commit-gate-file-name)))
      (setq-local header-line-format (propertize text 'face 'warning))
      (message "%s" text))))

(defun commit-gate-repo-label (file)
  "Name the repository of the gate at FILE, or nil when the path names none.
The gate sits in the git directory, so the path alone gives the name. Asking
git would block on a TRAMP gate. A worktree or a submodule is named too."
  (let ((parts (split-string
                (or (file-name-directory (file-local-name file)) "") "/" t))
        prev repo after)
    (while parts
      (let ((part (pop parts)))
        (when (string-suffix-p ".git" part)
          (setq repo (if (equal part ".git")
                         prev
                       (and (string-match "\\`\\.?\\(.+\\)\\.git\\'" part)
                            (match-string 1 part)))
                after parts))
        (setq prev part)))
    (when repo
      (let* ((wt (cadr (member "worktrees" after)))
             (mods (seq-take-while (lambda (p) (not (equal p "worktrees")))
                                   after)))
        (concat repo
                (and (equal (car mods) "modules")
                     (concat ", submodule " (car (last mods))))
                (and wt (concat ", worktree " wt)))))))

(defun commit-gate-show-banner ()
  "Name the repository and the keys in the header line of a gate.
Does nothing unless the current buffer is `commit-gate-buffer-p'. Written
for `server-visit-hook'."
  (when (commit-gate-buffer-p)
    (let* ((repo (ignore-errors (commit-gate-repo-label (buffer-file-name))))
           (text (format "Commit gate%s. C-x # approves. C-x k discards."
                         (if repo (concat " for " repo) ""))))
      ;; A % in the header line is a format code, and a path can hold one.
      (setq-local header-line-format
                  (propertize (string-replace "%" "%%" text) 'face 'success)))))

(defun commit-gate--sentinel-for (file)
  "The sentinel path for the gate at FILE."
  (concat file ".closed"))

(defun commit-gate-sentinel-file (&optional buffer)
  "The sentinel path for BUFFER's gate, or nil when BUFFER is not a gate.
The path sits beside the buffer's own file name, so it keeps the buffer's
host."
  (and (commit-gate-buffer-p buffer)
       (commit-gate--sentinel-for (buffer-file-name buffer))))

(defun commit-gate--record-file (gate)
  "The local record path for the gate at GATE.
The digest is taken over the gate's LOCAL name, so a reader on the gate's own
host derives the same name from the path it already knows. The host is not
in the key, and that is the cost of it. Two hosts that hold the same absolute
path share one record, and no code here separates them. The \"gate\" line
records which spelling the last accept used, for a person reading the file."
  (expand-file-name (concat (secure-hash 'sha256 (file-local-name gate))
                            ".record")
                    commit-gate-record-directory))

(defun commit-gate--write-record (gate stamp)
  "Write the local record of GATE accepted at STAMP.
This truncates, so a fresh accept replaces an older one at the same path."
  (make-directory commit-gate-record-directory t)
  (write-region (format "accepted %s\ngate %s\n" stamp gate)
                nil (commit-gate--record-file gate) nil 'quiet))

(defun commit-gate--record-outcome (gate stamp outcome)
  "Append the sentinel OUTCOME for the accept of GATE at STAMP.
STAMP is on the line because a second accept of the same gate truncates the
record, and the first accept's sentinel can still land after that. Without
it a reader would credit the new accept with the old one's outcome.

The directory is made here as well as on the first write, because a process
sentinel appends long afterwards and nothing holds the directory open."
  (make-directory commit-gate-record-directory t)
  (write-region (format "sentinel %s %s\n" stamp outcome)
                nil (commit-gate--record-file gate) 'append 'quiet))

(defun commit-gate--spawn-remote (gate stamp)
  "Start the sentinel write for the remote GATE, stamped STAMP.
Returns as soon as the process starts, so `C-x #' never waits on the network.
The outcome reaches the local record through the process sentinel."
  (let ((method (file-remote-p gate 'method))
        (user (file-remote-p gate 'user))
        (host (file-remote-p gate 'host)))
    (cond
     ((not (member method commit-gate-remote-methods))
      (commit-gate--record-outcome
       gate stamp (format "skipped, method %s" method)))
     ((null host)
      (commit-gate--record-outcome gate stamp "skipped, no host"))
     (t
      ;; BatchMode, because this process has no terminal. Without it a host
      ;; that wants a password leaves an `ssh' alive until Emacs exits.
      (let ((proc (start-process
                   "commit-gate-sentinel" nil "ssh"
                   "-o" "BatchMode=yes" "-o" "ConnectTimeout=10"
                   (if user (concat user "@" host) host)
                   (format "printf %%s %s > %s"
                           (shell-quote-argument stamp)
                           (shell-quote-argument
                            (file-local-name
                             (commit-gate--sentinel-for gate)))))))
        (set-process-query-on-exit-flag proc nil)
        (set-process-sentinel
         proc
         (lambda (p _event)
           (unless (process-live-p p)
             (ignore-errors
               (commit-gate--record-outcome
                gate stamp
                (if (and (eq (process-status p) 'exit)
                         (zerop (process-exit-status p)))
                    "written"
                  (format "failed, %s %s"
                          (process-status p)
                          (process-exit-status p))))))))
        proc)))))

(defun commit-gate-record-accept (&rest _)
  "Record that the current gate was accepted, and stamp its sentinel.
Does nothing for any other buffer. Written for `:before' advice on
`server-done', which `C-x #' reaches and `C-x k' does not."
  (let ((gate (ignore-errors (and (commit-gate-buffer-p) (buffer-file-name))))
        (stamp (format-time-string "%s")))
    (when gate
      ;; Local first, because it is the record that cannot be lost to a
      ;; network. Each write is guarded on its own, so a failure of one still
      ;; leaves the other.
      (ignore-errors (commit-gate--write-record gate stamp))
      (ignore-errors
        (if (file-remote-p gate)
            (commit-gate--spawn-remote gate stamp)
          (write-region stamp nil (commit-gate--sentinel-for gate) nil 'quiet)
          (commit-gate--record-outcome gate stamp "written"))))))

(defun commit-gate-accepted-p (gate &optional since)
  "The time the gate at GATE was accepted, or nil when there is no record.
GATE is the gate's path, and either spelling works: the one this Emacs used,
or the plain local one a reader on the gate's own host knows.

SINCE is a time in seconds. A record older than it is rejected. Pass the
moment you opened your own gate, because this advice is always armed and an
earlier gate at the same path leaves a record that is not yours.

A nil result means UNPROVEN. It does not mean the message was refused."
  (let ((file (ignore-errors (commit-gate--record-file gate))))
    (and file
         (file-readable-p file)
         (with-temp-buffer
           (insert-file-contents file)
           (goto-char (point-min))
           (and (re-search-forward "^accepted \\([0-9]+\\)$" nil t)
                (let ((stamp (string-to-number (match-string 1))))
                  (and (or (null since) (>= stamp since))
                       stamp)))))))

(defun commit-gate-armed-p ()
  "Whether the accept recorder is installed on `server-done'."
  (and (advice-member-p #'commit-gate-record-accept 'server-done) t))

(defun commit-gate-arm ()
  "Install the accept recorder on `server-done', and the two header lines.
Adding the same function twice does not stack a second copy, so this is safe
to re-run when the configuration is reloaded."
  (advice-add 'server-done :before #'commit-gate-record-accept)
  (add-hook 'server-visit-hook #'commit-gate-warn-if-misnamed)
  (add-hook 'server-visit-hook #'commit-gate-show-banner))

(provide 'commit-gate)

;;; commit-gate.el ends here
