;;; commit-gate.el --- Record that a commit gate was approved -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; A commit agent parks a blocking `emacsclient' on a file named
;; CLAUDE_COMMIT_MSG and waits.  `C-x #' means the message is approved.
;; `C-x k' means it is not.
;;
;; Afterwards the two are INDISTINGUISHABLE.  `server-kill-new-buffers' is t
;; here, so both leave no buffer behind and both let the client exit 0, and the
;; receipt, its age against HEAD and the staged tree all read the same either
;; way.  An agent holding only those signals must either refuse every approval
;; or accept every dismissal.
;;
;; `C-x k' never reaches `server-done' and `C-x #' always does, so an advice
;; there is the one place the difference can be observed.  This file is that
;; advice.
;;
;; Three properties it has to have.  Each one closes a failure that happened.
;;
;; ATTRIBUTION.  `server-done' takes no arguments and acts on the current
;; buffer, so `buffer-file-name' inside the advice is the buffer being
;; finished.  A gate in another worktree has a different path and stamps its
;; own sentinel.  Without the check the advice fires on every other gate's
;; `C-x #' and reports an approval that never happened.
;;
;; THE BUFFER'S OWN PATH.  The sentinel goes beside `buffer-file-name',
;; whatever prefix it carries.  A gate opened over TRAMP reads as
;; "/ssh:HOST:/path/CLAUDE_COMMIT_MSG" in the Emacs that shows it, so a bare
;; local path would write the sentinel to the wrong machine.
;;
;; A TIMESTAMP, NOT A FLAG.  This advice is permanent, so it is always armed.
;; Any `C-x #' on any CLAUDE_COMMIT_MSG stamps a sentinel, including one that
;; no agent is waiting for.  The stamp lets a reader require a sentinel newer
;; than the moment it opened its own gate.  A reader that treats mere existence
;; as approval accepts a leftover.
;;
;; A missing sentinel means UNPROVEN, and it does not mean denied.  Every fault
;; here is swallowed, because an error in an advice on `server-done' would
;; break finishing a buffer for every client.  So a reader that finds no
;; sentinel has to ask a person rather than read a refusal.

;;; Code:

(defconst commit-gate-file-name "CLAUDE_COMMIT_MSG"
  "The one file name a commit gate is presented under.
Fixed deliberately.  Twenty-three gate-file variants once accumulated across
one repository's worktrees, and cleanup cannot be mechanical against that.")

(defconst commit-gate-write-timeout 5
  "Seconds allowed for the sentinel write before it is abandoned.
The write may cross TRAMP to the host the gate lives on.  A lost sentinel
costs an agent one question.  A wedged `C-x #' costs the user their editor,
so the write must not be allowed to block without limit.")

(defun commit-gate-buffer-p (&optional buffer)
  "Whether BUFFER, or the current buffer, is a commit gate."
  (let ((file (buffer-file-name buffer)))
    (and file
         (equal (file-name-nondirectory file) commit-gate-file-name)
         t)))

(defun commit-gate-sentinel-file (&optional buffer)
  "The sentinel path for BUFFER's gate, or nil when BUFFER is not a gate.
The path sits beside the buffer's own file name, so it keeps the buffer's
host."
  (and (commit-gate-buffer-p buffer)
       (concat (buffer-file-name buffer) ".closed")))

(defun commit-gate-record-accept (&rest _)
  "Stamp the current gate's sentinel with the time it was accepted.
Does nothing for any other buffer.  Written for `:before' advice on
`server-done', which `C-x #' reaches and `C-x k' does not."
  (let ((sentinel (ignore-errors (commit-gate-sentinel-file))))
    (when sentinel
      (ignore-errors
        (with-timeout (commit-gate-write-timeout nil)
          (write-region (format-time-string "%s") nil sentinel nil 'quiet))))))

(defun commit-gate-armed-p ()
  "Whether the accept recorder is installed on `server-done'."
  (and (advice-member-p #'commit-gate-record-accept 'server-done) t))

(defun commit-gate-arm ()
  "Install the accept recorder on `server-done'.
Adding the same function twice does not stack a second copy, so this is safe
to re-run when the configuration is reloaded."
  (advice-add 'server-done :before #'commit-gate-record-accept))

(provide 'commit-gate)

;;; commit-gate.el ends here
