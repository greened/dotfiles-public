;;; commit-gate.el --- Record that a commit gate was approved -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: AGPL-3.0-or-later

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
;; THE RUN'S NONCE, NOT A FLAG. This advice is permanent, so it is always
;; armed. Any `C-x #' on any CLAUDE_COMMIT_MSG stamps a record, including one
;; that no agent is waiting for. So the sentinel has to name the run it
;; approves. commit-land puts each run in its own directory with a `.nonce'
;; file, and the gate writes that nonce to `.closed' beside it. The nonce is
;; read when the buffer is visited. A buffer that outlives its run must not
;; pick up a later run's nonce at `C-x #'. The one read repeated is one whose
;; ssh could not connect, and `C-x #' repeats it from the same run directory.
;; commit-land names that directory for its nonce, so the read can only find
;; the same run's nonce.
;;
;; An older commit-land writes no `.nonce'. Then the sentinel is the epoch
;; at `<msg>.closed', as before, and a reader requires a stamp newer than its
;; own gate. `commit-gate-accepted-p' takes a SINCE for exactly this.
;;
;; NO FAULT ESCAPES, BUT A BAD NONCE REFUSES. Every fault in the writes is
;; swallowed, because an error in an advice on `server-done' would break
;; finishing a buffer for every client. So a reader that finds no record has
;; to ask a person rather than read a refusal. A missing record means
;; UNPROVEN, and it does not mean denied. The one deliberate error is a
;; `user-error' on a gate whose nonce cannot approve. It stops
;; `C-x #' there and says how to proceed, because approving with a wrong
;; nonce would only fail later, out of sight.
;;
;; A near miss is said out loud. A client that parks on CLAUDE_COMMIT_MSG.txt
;; gets a buffer that looks like a gate and records nothing, so every approval
;; there reads as a dismissal. The header line of that buffer says so while he
;; can still act on it.
;;
;; A real gate is labelled too. Its header line names the repository and the
;; two keys. He kills a buffer he cannot identify, and `C-x k' discards the
;; message as quietly as `C-x #' approves it.
;;
;; commit-land may list claims below the scissors line that the diff neither
;; shows nor contradicts. `C-c C-a' accepts one after asking, and on a claim
;; already accepted it unaccepts it. `C-x #' then writes an `accept ID' line
;; for each accepted claim after the nonce. The id is checked against the
;; claim's text, so an edited line cannot be accepted.

;;; Code:

(defgroup commit-gate nil
  "Record that a commit gate was approved."
  :group 'tools)

(defconst commit-gate-file-name "CLAUDE_COMMIT_MSG"
  "The one file name a commit gate is presented under.
Fixed deliberately. Twenty-three gate-file variants once accumulated across
one repository's worktrees, and cleanup cannot be mechanical against that.")

(defconst commit-gate-land-directory-name "claude-land"
  "The directory under the git dir that holds one subdirectory per run.
commit-land names each subdirectory for the run's nonce.")

(defconst commit-gate-nonce-file-name ".nonce"
  "The file beside a gate that holds its run's nonce.")

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

(defvar-local commit-gate-nonce nil
  "This gate's run nonce, read when the buffer was visited.
One of:

  nil                never read, because the buffer was not visited as a gate
  `pending'          a remote read is still running
  `absent'           no `.nonce' beside the gate, so the epoch is written
  (nonce . STRING)   the nonce `C-x #' writes to `.closed'
  (retry WHY . FILE) ssh could not connect, so `C-x #' reads FILE again
  (refused . WHY)    unreadable or malformed, so `C-x #' refuses

Set only from nil, from `pending' by the read that set it, or from `retry'
by `C-x #', so a later visit cannot replace it.")
;; Permanent, because a revert or a major mode change would otherwise drop
;; the value and the buffer could not be matched to its run.
(put 'commit-gate-nonce 'permanent-local t)

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
    ;; A run directory under the git dir would read as a submodule name.
    (let ((n (length parts)))
      (when (and (>= n 2)
                 (equal (nth (- n 2) parts) commit-gate-land-directory-name))
        (setq parts (butlast parts 2))))
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

(defvar-local commit-gate--refused nil
  "Why the last `C-x #' in this gate was refused, or nil.
The banner keeps it in view, so accepting a claim cannot hide it.")

(defun commit-gate-show-banner ()
  "Name the repository and the keys in the header line of a gate.
Does nothing unless the current buffer is `commit-gate-buffer-p'. Written
for `server-visit-hook'."
  (when (commit-gate-buffer-p)
    (commit-gate--draw-banner (ignore-errors (commit-gate--claims)))))

(defun commit-gate--draw-banner (claims)
  "Set the header line of a gate that lists CLAIMS."
  (let* ((why commit-gate--refused)
         (repo (ignore-errors (commit-gate-repo-label (buffer-file-name))))
         (text (concat
                  (if why
                      (concat "Not approved. " why ".")
                    (format "Commit gate%s. C-x # approves. C-x k discards."
                            (if repo (concat " for " repo) "")))
                  (and claims
                       (format " %d of %d listed claims accepted with C-c C-a. \
A claim left in the message unaccepted refuses the landing."
                               (length (commit-gate--accepted-ids claims))
                               (length claims))))))
    ;; A % in the header line is a format code, and a path can hold one.
    (setq-local header-line-format
                (propertize (string-replace "%" "%%" text)
                            'face (if why 'warning 'success)))))

;;; Claims David may accept

(defconst commit-gate-scissors
  "# ------------------------ >8 ------------------------"
  "The line commit-land puts above the diff half of a gate.")

(defvar-local commit-gate--accepted-claims nil
  "The ids of the claims accepted in this gate with `C-c C-a', oldest first.")

(defun commit-gate--claim-id (text &optional coding)
  "The id commit-land gives the claim TEXT, read from a file in CODING.
CODING defaults to UTF-8. The id is the SHA-256 of the claim's UTF-8 bytes.
Encoding TEXT back in the coding the file was read with gives the bytes the
file held, for any coding that round-trips. One that does not gives another
id, so the claim cannot be accepted."
  (substring (secure-hash 'sha256
                          (encode-coding-string text (or coding 'utf-8-unix) t))
             0 16))

(defun commit-gate--file-coding ()
  "The coding system that turns this buffer's text back into its file's bytes.
A raw byte elsewhere in the diff makes Emacs read the whole file as Latin-1,
and then UTF-8 would hash other bytes than the file held."
  (let ((cs (and buffer-file-coding-system
                 (coding-system-change-eol-conversion
                  buffer-file-coding-system 'unix))))
    (if (or (null cs) (eq (coding-system-type cs) 'undecided))
        'utf-8-unix
      cs)))

(defvar-local commit-gate--scissors nil
  "A marker at the scissors line the claims were last read below.")

(defun commit-gate--claims ()
  "The claim lines below the last scissors line, as (ID TEXT VALID BEG END).
VALID is nil when ID is not the id of TEXT, because the line was edited.
The message half is David's text, so nothing above the scissors is read."
  (save-excursion
    (save-restriction
      (widen)
      (goto-char (point-max))
      (let ((case-fold-search nil)
            (coding (commit-gate--file-coding))
            claims)
        (if (not (re-search-backward
                  (concat "^" (regexp-quote commit-gate-scissors) "$") nil t))
            (and commit-gate--scissors (set-marker commit-gate--scissors nil))
          (set-marker (or commit-gate--scissors
                          (setq commit-gate--scissors (make-marker)))
                      (point))
          (forward-line 1)
          (while (re-search-forward
                  "^# claim-unsupported \\([0-9a-f]\\{16\\}\\) \\(.*\\)$" nil t)
            (let ((id (match-string-no-properties 1))
                  (text (match-string-no-properties 2)))
              (push (list id text (equal id (commit-gate--claim-id text coding))
                          (match-beginning 0) (match-end 0))
                    claims))))
        (nreverse claims)))))

(defun commit-gate--accepted-ids (claims)
  "The accepted ids that still name a valid line in CLAIMS, in accept order."
  (seq-filter (lambda (id)
                (seq-some (lambda (c) (and (nth 2 c) (equal (car c) id)))
                          claims))
              commit-gate--accepted-claims))

(defun commit-gate--clear-marks ()
  "Remove every accepted claim mark from the buffer."
  (save-restriction
    (widen)
    (remove-overlays (point-min) (point-max) 'commit-gate-claim t)))

(defun commit-gate--mark-claims (claims)
  "Mark each accepted line of CLAIMS, and clear the marks of any other."
  (commit-gate--clear-marks)
  (let ((ids (commit-gate--accepted-ids claims)))
    (dolist (c claims)
      (when (and (nth 2 c) (member (car c) ids))
        (let ((ov (make-overlay (nth 3 c) (nth 4 c))))
          (overlay-put ov 'commit-gate-claim t)
          (overlay-put ov 'face 'success)
          (overlay-put ov 'after-string
                       (propertize "  [accepted]" 'face 'success)))))))

(defun commit-gate--pick-claim (claims)
  "The claim in CLAIMS on point's line, or the one chosen from a list."
  (or (seq-find (lambda (c) (<= (nth 3 c) (point) (nth 4 c))) claims)
      (let ((choice (completing-read "Accept or unaccept which claim? "
                                     (mapcar #'cadr claims) nil t)))
        (seq-find (lambda (c) (equal (cadr c) choice)) claims))))

(defun commit-gate-accept-claim ()
  "Accept one UNSUPPORTED claim the gate lists, after asking.
The claim is the one on point's line, or one chosen from the list. Its id
goes into the gate's stamp when `C-x #' approves. On a claim already
accepted, unaccept it."
  (interactive)
  (unless (commit-gate-buffer-p)
    (user-error "Not a commit gate"))
  (let ((claims (commit-gate--claims)))
    (cond
     ((null claims)
      (message "This gate lists no claims to accept."))
     ((eq commit-gate-nonce 'absent)
      ;; Only a run directory's stamp can carry an accept.
      (user-error "This gate has no run nonce, so it cannot accept a claim"))
     (t
      (let ((c (commit-gate--pick-claim claims)))
        (cond
         ((null c) (user-error "No claim chosen"))
         ((not (nth 2 c))
          (user-error "This claim line was edited, so its id does not match \
its text. Cut the claim from the message, or C-x k and rerun commit-land"))
         ;; Unaccepting needs no typed yes: it only drops an accept.
         ((member (car c) commit-gate--accepted-claims)
          (setq commit-gate--accepted-claims
                (delete (car c) commit-gate--accepted-claims))
          (commit-gate--mark-claims claims)
          (commit-gate--draw-banner claims)
          (message "Unaccepted."))
         ;; Typed out in full, because his `yes-or-no-p' takes one key.
         ((equal (read-string
                  (format "Accept this claim? %s\nType yes to accept it: "
                          (cadr c)))
                 "yes")
          (setq commit-gate--accepted-claims
                (append commit-gate--accepted-claims (list (car c))))
          (commit-gate--mark-claims claims)
          (commit-gate--draw-banner claims)
          (message "Accepted. C-x # writes it with the approval."))
         (t (message "Not accepted."))))))))

(defvar commit-gate-claims-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-a") #'commit-gate-accept-claim)
    map)
  "Keys for a commit gate buffer.")

(defun commit-gate--refresh-claims (_beg end _len)
  "Redraw the claim marks and the banner count after an edit ending at END.
Written for `after-change-functions', so no error may reach his editing."
  (save-match-data
    (let ((m commit-gate--scissors))
      ;; An edit above an intact last scissors line cannot change the
      ;; claims, so typing in the message skips the scan of the diff.
      (unless (ignore-errors
                (and (marker-position m)
                     (< end m)
                     (save-excursion
                       (goto-char m)
                       (and (bolp)
                            (looking-at (concat (regexp-quote
                                                 commit-gate-scissors)
                                                "$"))))))
        (let ((claims (ignore-errors (commit-gate--claims))))
          (ignore-errors (commit-gate--mark-claims claims))
          (ignore-errors (commit-gate--draw-banner claims)))))))

(define-minor-mode commit-gate-claims-mode
  "Accept a claim the commit gate lists with \\[commit-gate-accept-claim]."
  :lighter nil
  :keymap commit-gate-claims-mode-map
  (if commit-gate-claims-mode
      (progn
        (add-hook 'after-change-functions #'commit-gate--refresh-claims nil t)
        ;; A new major mode, as a revert sets, drops the accepts but not
        ;; the marks.
        (add-hook 'change-major-mode-hook #'commit-gate--clear-marks nil t)
        (add-hook 'after-revert-hook #'commit-gate--restore-after-revert nil t))
    (remove-hook 'after-change-functions #'commit-gate--refresh-claims t)
    (remove-hook 'change-major-mode-hook #'commit-gate--clear-marks t)
    (remove-hook 'after-revert-hook #'commit-gate--restore-after-revert t)
    (commit-gate--clear-marks)))

(defun commit-gate--restore-after-revert ()
  "Turn the claims mode and the banner back on after a revert.
The major mode a revert sets drops both. The accepts stay dropped."
  (when (commit-gate-buffer-p)
    (commit-gate-show-claims)
    (commit-gate-show-banner)))
;; Kept through the major mode change, because that change is what it repairs.
(put 'commit-gate--restore-after-revert 'permanent-local-hook t)

(defun commit-gate-show-claims ()
  "Turn on `commit-gate-claims-mode' in a gate and mark accepted claims.
Does nothing unless the current buffer is `commit-gate-buffer-p'. Written
for `server-visit-hook'."
  (when (commit-gate-buffer-p)
    (commit-gate-claims-mode 1)
    (ignore-errors (commit-gate--mark-claims (commit-gate--claims)))))

(defun commit-gate--sentinel-text (stamp nonce accepts)
  "What the sentinel holds for the accept at STAMP of the run NONCE.
With a nonce, the nonce and then one `accept ID' line per id in ACCEPTS.
With none accepted it is the bare nonce. Without a nonce it is STAMP, since
an epoch stamp never carries an accept."
  (cond
   ((null nonce) stamp)
   ((null accepts) nonce)
   (t (concat nonce
              (mapconcat (lambda (id) (concat "\naccept " id)) accepts "")
              "\n"))))

(defun commit-gate--sentinel-for (file &optional nonce)
  "The sentinel path for the gate at FILE.
With NONCE it is `.closed' in FILE's directory, where commit-land looks for
the nonce. Without it, the older `<msg>.closed'."
  (if nonce
      (concat (file-name-directory file) ".closed")
    (concat file ".closed")))

(defun commit-gate-sentinel-file (&optional buffer)
  "The sentinel path for BUFFER's gate, or nil when BUFFER is not a gate.
The path sits beside the buffer's own file name, so it keeps the buffer's
host."
  (and (commit-gate-buffer-p buffer)
       (commit-gate--sentinel-for
        (buffer-file-name buffer)
        (let ((state (buffer-local-value 'commit-gate-nonce
                                         (or buffer (current-buffer)))))
          (and (eq (car-safe state) 'nonce) (cdr state))))))

(defun commit-gate--nonce-file (gate)
  "The `.nonce' file beside the gate at GATE."
  (concat (file-name-directory gate) commit-gate-nonce-file-name))

(defun commit-gate--parse-nonce (text)
  "The nonce state for TEXT, read from a `.nonce' file.
TEXT may end in one newline and must otherwise be exactly 32 lowercase hex
characters, the shape commit-land writes. The text is not repeated in a
refusal, because a malformed file can hold anything. No refusal names the
file either, because the header line shows the path after the reason."
  (let ((case-fold-search nil))
    (if (string-match "\\`\\([0-9a-f]\\{32\\}\\)\n?\\'" text)
        (cons 'nonce (match-string 1 text))
      (cons 'refused
            ".nonce is malformed, it must hold 32 lowercase hex characters"))))

(defun commit-gate--read-local-nonce (file)
  "The nonce state for the local `.nonce' file FILE."
  (condition-case err
      (if (not (file-exists-p file))
          'absent
        (with-temp-buffer
          (set-buffer-multibyte nil)
          ;; Bounded, because a valid nonce is short and the file is not ours.
          (insert-file-contents-literally file nil 0 256)
          (commit-gate--parse-nonce (buffer-string))))
    (error (cons 'refused (format ".nonce is unreadable (%s)"
                                  (error-message-string err))))))

(defun commit-gate--nonce-read-result (proc out file retry)
  "The nonce state from the finished remote read PROC of FILE, given OUT.
RETRY is non-nil when PROC repeats a read that could not connect."
  (let ((code (process-exit-status proc)))
    (cond
     ((not (eq (process-status proc) 'exit))
      (cons 'refused "reading .nonce was cut off"))
     ;; On a repeat, a missing nonce may be a run commit-land has since
     ;; removed, and reading it as `absent' would approve with the epoch.
     ((and retry (eq code 3))
      (cons 'refused ".nonce is gone, so its run has ended"))
     ((eq code 3) 'absent)
     ((zerop code) (commit-gate--parse-nonce out))
     ;; ssh itself exits 255 when the connection fails, which is worth
     ;; another try. Any other code came from the far side.
     ((eq code 255)
      (cons 'retry (cons "ssh could not reach the host to read .nonce (exit 255)"
                         file)))
     (t (cons 'refused (format ".nonce is unreadable (ssh exit %s)" code))))))

(defun commit-gate--spawn-nonce-read (buffer file &optional retry)
  "Read the remote `.nonce' FILE for BUFFER without waiting on the network.
The result lands in BUFFER's `commit-gate-nonce' when the process ends.
RETRY is non-nil when this repeats a read that could not connect."
  (let ((method (file-remote-p file 'method))
        (user (file-remote-p file 'user))
        (host (file-remote-p file 'host))
        (local (file-local-name file))
        (out ""))
    (if (not (and host (member method commit-gate-remote-methods)))
        (cons 'refused (format ".nonce cannot be read over the TRAMP method %s"
                               method))
      ;; Exit 3 says the file is absent, which is an older commit-land rather
      ;; than a fault, so it must not read as a failed connection.
      (make-process
       :name "commit-gate-nonce"
       :connection-type 'pipe
       :noquery t
       ;; Stderr goes to its own buffer, because an ssh warning mixed into the
       ;; output reads as a malformed nonce.
       :stderr (with-current-buffer
                   (get-buffer-create " *commit-gate-nonce-stderr*")
                 (erase-buffer)
                 (current-buffer))
       :command
       (list "ssh" "-o" "BatchMode=yes" "-o" "ConnectTimeout=10"
             (if user (concat user "@" host) host)
             (format "if [ -e %s ]; then cat -- %s; else exit 3; fi"
                     (shell-quote-argument local)
                     (shell-quote-argument local)))
       :filter
       (lambda (_p chunk)
         (when (< (length out) 256)
           (setq out (concat out chunk))))
       :sentinel
       (lambda (p _event)
         (unless (process-live-p p)
           (ignore-errors
             (when (and (buffer-live-p buffer)
                        (eq (buffer-local-value 'commit-gate-nonce buffer)
                            'pending))
               (with-current-buffer buffer
                 (setq commit-gate-nonce
                       (commit-gate--nonce-read-result p out file retry))))))))
      'pending)))

(defun commit-gate-capture-nonce ()
  "Read this gate's run nonce into `commit-gate-nonce', once.
Does nothing unless the current buffer is a gate whose nonce was never read.
Written for `find-file-hook' and `server-visit-hook'. The second catches a
gate buffer that was already open when the hooks were armed."
  (when (and (commit-gate-buffer-p) (null commit-gate-nonce))
    (let ((file (commit-gate--nonce-file (buffer-file-name))))
      (setq commit-gate-nonce
            (or (ignore-errors
                  (if (file-remote-p file)
                      (commit-gate--spawn-nonce-read (current-buffer) file)
                    (commit-gate--read-local-nonce file)))
                (cons 'refused ".nonce could not be read"))))))

(defun commit-gate--retry-nonce ()
  "Read this gate's remote nonce again after a read that could not connect.
Does nothing unless `commit-gate-nonce' is a `retry' state."
  (when (eq (car-safe commit-gate-nonce) 'retry)
    ;; The run directory path is captured with the state, so the repeat
    ;; reads the same run directory whatever the buffer is visiting now.
    (let ((file (cddr commit-gate-nonce)))
      (setq commit-gate-nonce
            (or (ignore-errors
                  (commit-gate--spawn-nonce-read (current-buffer) file t))
                (cons 'refused ".nonce could not be read"))))))

(defun commit-gate--refusal (state &optional file)
  "Why STATE cannot approve, or nil when it can.
FILE is the `.nonce' path, named last so the reason and the keys come first."
  (let ((from (if file (format ". The nonce is read from %s" file) "")))
    (pcase state
      ('nil "no nonce was read when this gate was opened, so it cannot be \
matched to its run. Press C-x k to discard it, then rerun commit-land")
      ('pending "this gate's nonce is still being read from its host. Press \
C-x # again in a moment, or C-x k to discard")
      (`(retry ,why . ,_)
       (concat why ". It is being read again. Press C-x # again in a moment, \
or C-x k to discard" from))
      (`(refused . ,why)
       (concat why ". Press C-x k to discard this gate, then rerun commit-land \
so it writes a fresh nonce" from)))))

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

(defun commit-gate--write-record (gate stamp &optional nonce)
  "Write the local record of GATE accepted at STAMP, for the run NONCE.
This truncates, so a fresh accept replaces an older one at the same path."
  (make-directory commit-gate-record-directory t)
  (write-region (format "accepted %s\ngate %s\n%s" stamp gate
                        (if nonce (format "nonce %s\n" nonce) ""))
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

(defun commit-gate--spawn-remote (gate stamp &optional nonce accepts)
  "Start the sentinel write for the remote GATE, stamped STAMP.
With NONCE the sentinel holds the nonce and the ids in ACCEPTS, and STAMP
only names the outcome line. Returns as soon as the process starts, so
`C-x #' never waits on the network. The outcome reaches the local record
through the process sentinel."
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
                   ;; Renamed into place, so a reader polling for the
                   ;; sentinel never sees half of it.
                   (let ((target (file-local-name
                                  (commit-gate--sentinel-for gate nonce))))
                     (format "printf %%s %s > %s && mv -f %s %s"
                             (shell-quote-argument
                              (commit-gate--sentinel-text stamp nonce accepts))
                             (shell-quote-argument (concat target ".tmp"))
                             (shell-quote-argument (concat target ".tmp"))
                             (shell-quote-argument target))))))
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

(defun commit-gate--write-local-sentinel (file text)
  "Write TEXT to the local sentinel FILE, renamed into place.
A reader polling for the sentinel must never see half of it."
  (let ((tmp (concat file ".tmp"))
        ;; A gate read with DOS line ends would otherwise write CRLF.
        (coding-system-for-write 'no-conversion))
    (write-region text nil tmp nil 'quiet)
    (rename-file tmp file t)))

(defvar commit-gate--pending-announcement nil
  "The gate `server-done' just approved, as (BUFFER REPO SUBJECT), or nil.")

(defun commit-gate-record-accept (&rest _)
  "Record that the current gate was accepted, and stamp its sentinel.
Does nothing for any other buffer. Written for `:before' advice on
`server-done', which `C-x #' reaches and `C-x k' does not.

Signals a `user-error' for a gate whose nonce cannot approve, which stops
`C-x #' and leaves the gate open with the reason in its header line."
  (setq commit-gate--pending-announcement nil)
  (let* ((gate (ignore-errors (and (commit-gate-buffer-p) (buffer-file-name))))
         (state (and gate commit-gate-nonce))
         (nonce (and (eq (car-safe state) 'nonce) (cdr state)))
         (stamp (format-time-string "%s"))
         (accepts (and nonce (ignore-errors
                               (commit-gate--accepted-ids
                                (commit-gate--claims))))))
    (when gate
      ;; The repeat runs before the reason is built, so a spawn that fails
      ;; reports its refusal and never promises a read that is not running.
      (commit-gate--retry-nonce)
      (let* ((now commit-gate-nonce)
             (shown (if (and (eq (car-safe state) 'retry) (eq now 'pending))
                        state
                      now))
             (why (and (not nonce) (not (eq now 'absent))
                       (commit-gate--refusal shown
                                             (commit-gate--nonce-file gate)))))
        (when why
          (setq commit-gate--refused why)
          (commit-gate-show-banner)
          (user-error "Commit gate not approved: %s" why)))
      ;; Local first, because it is the record that cannot be lost to a
      ;; network. Each write is guarded on its own, so a failure of one still
      ;; leaves the other.
      (ignore-errors (commit-gate--write-record gate stamp nonce))
      (ignore-errors
        (if (file-remote-p gate)
            (commit-gate--spawn-remote gate stamp nonce accepts)
          (commit-gate--write-local-sentinel
           (commit-gate--sentinel-for gate nonce)
           (commit-gate--sentinel-text stamp nonce accepts))
          (commit-gate--record-outcome gate stamp "written")))
      (setq commit-gate--pending-announcement
            (list (current-buffer)
                  (ignore-errors (commit-gate-repo-label gate))
                  (ignore-errors (commit-gate--subject)))))))

(defun commit-gate-announce-pending (&rest _)
  "Announce the gate the last `server-done' approved, if any.
Written for `:after' advice on `server-edit'. A quit at the save prompt
skips it, so nothing says approved for a client still waiting."
  (let ((pending commit-gate--pending-announcement))
    (setq commit-gate--pending-announcement nil)
    (when pending
      (ignore-errors (apply #'commit-gate-announce-approval pending)))))

(defun commit-gate--subject ()
  "The first non-blank line of the current buffer, or nil."
  (save-excursion
    (goto-char (point-min))
    (and (re-search-forward "^[ \t]*\\([^ \t\n].*\\)$" nil t)
         (match-string-no-properties 1))))

(defun commit-gate-announce-approval (approved repo subject)
  "Say which gate was approved, and whether the buffer now shown is another.
APPROVED is the gate's buffer, and REPO and SUBJECT name it. Two gates in a
row with near-identical subjects otherwise read as one. Returns the message."
  (let* ((next (window-buffer (selected-window)))
         (another (and (not (eq next approved))
                       (commit-gate-buffer-p next)))
         (next-repo (and another
                         (ignore-errors
                           (commit-gate-repo-label (buffer-file-name next))))))
    (message "%s"
             (concat "Approved the commit"
                     (and repo (concat " for " repo))
                     (and subject (concat ": " subject))
                     (and (not (and subject (string-match-p "[.!?]\\'" subject)))
                          ".")
                     (and another
                          (concat " This is another commit gate"
                                  (and next-repo (concat ", for " next-repo))
                                  "."))))))

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
  "Install the recorder, its message, the nonce read and both header lines.
It also turns on `commit-gate-claims-mode' in each gate.
Adding the same function twice does not stack a second copy, so this is safe
to re-run when the configuration is reloaded."
  (advice-add 'server-done :before #'commit-gate-record-accept)
  (advice-add 'server-edit :after #'commit-gate-announce-pending)
  (add-hook 'find-file-hook #'commit-gate-capture-nonce)
  (add-hook 'server-visit-hook #'commit-gate-capture-nonce)
  (add-hook 'server-visit-hook #'commit-gate-warn-if-misnamed)
  (add-hook 'server-visit-hook #'commit-gate-show-banner)
  (add-hook 'server-visit-hook #'commit-gate-show-claims))

(provide 'commit-gate)

;;; commit-gate.el ends here
