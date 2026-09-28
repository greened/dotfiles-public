;;; commit-gate-scrub.el --- Say whether a filter rewrote this draft -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; A hook runs an automated slop filter over a commit message before the gate
;; opens, and the filter may rewrite the draft in place. So the text in a gate
;; buffer is not always the text the session wrote. Nothing in the buffer said
;; so, because the filter reports to stderr, which reaches the session and not
;; the person reading the draft. He learned it from the session's report, which
;; is a promise rather than evidence.
;;
;; This file answers two questions in the buffer itself. The mode line answers
;; "was this rewritten" with no keystroke. `commit-gate-show-scrub-diff'
;; answers "what did it change".
;;
;; THE FILTER LEAVES FOUR SIBLINGS beside the draft, and each one answers a
;; different question:
;;
;;   .pre-scrub      the draft as the session wrote it, kept only on a rewrite
;;   .scrub-state    the hash of the text it produced, on every accepted run
;;   .scrub-diff     the change it made, captured when it ran
;;   .scrub-refused  why a guard threw its reply away, when one did
;;
;; So the questions come apart cleanly. `.scrub-state' says a run COMPLETED.
;; `.pre-scrub' says it CHANGED something, and it is the recovery copy, which is
;; why it exists only when there is something to recover. `.scrub-refused' says
;; it produced something and a guard rejected it.
;;
;; FOUR STATES, because folding any two of them loses the answer. "It left the
;; draft alone" and "it never saw the draft" differ in whether there is a gap.
;; "Its reply was refused" differs from both again: the draft is unfiltered
;; text, which is what the reader would see with the filter switched off, so
;; only the marker tells the two apart. That state stopped being rare the day a
;; guard started catching a reply that had gained content.
;;
;; THE RECORDED DIFF IS PREFERRED OVER A LIVE ONE. Once he edits the buffer, a
;; comparison against `.pre-scrub' answers "how does this differ from what the
;; session wrote", which mixes his own edits in with the filter's. The recorded
;; diff keeps answering the narrower question. So the live ediff is offered
;; only while the draft on disk still hashes to what the filter recorded, and
;; the recorded diff is the fallback whenever that cannot be established.
;;
;; THE PROBE RUNS ONCE, AND NEVER IN THE MODE LINE. A gate is usually a TRAMP
;; buffer and a mode-line construct is evaluated on every redisplay, so a
;; `file-exists-p' there would put a remote stat on the redisplay path. The
;; state is read when the buffer is visited, where Emacs is already talking to
;; that host to read the draft, and cached in a buffer-local variable that the
;; lighter reads.
;;
;; RECOVERY IS NOT HERE. `scrub-draft.sh --restore' puts the original back from
;; any shell, with no Emacs and no session involved. This file is the signal.

;;; Code:

(require 'commit-gate)
(require 'diff-mode)
(require 'subr-x)

(declare-function ediff-files "ediff" (file-a file-b &optional startup-hooks))

(defconst commit-gate-scrub-suffixes
  '((original . ".pre-scrub")
    (state    . ".scrub-state")
    (diff     . ".scrub-diff")
    (refused  . ".scrub-refused"))
  "The sibling files the draft filter leaves beside a gate.
The filter owns these names. They are stated once here so that a change
upstream has one place to land rather than three call sites to find.")

(defconst commit-gate-scrub-lighters
  '((rewritten . " scrub:rewritten")
    (refused   . " scrub:refused")
    (clean     . " scrub:clean")
    (absent    . " scrub:none"))
  "Mode-line text for each state the probe can report.
Every state says something. A state with nothing to show would be
indistinguishable from the indicator being off, and whether the draft was
rewritten would go back to needing a question.")

(defvar-local commit-gate-scrub-status nil
  "What the filter did to this draft.
One of `rewritten', `refused', `clean' or `absent', as
`commit-gate-scrub-probe' defines them. Probed once, when the indicator is
turned on. nil means never probed.")

(defun commit-gate-scrub-file (kind &optional buffer)
  "The KIND sibling of BUFFER's gate, or nil when BUFFER is not a gate.
KIND is a key of `commit-gate-scrub-suffixes'. The path keeps the buffer's
own prefix, so a gate shown over TRAMP names files on the host that holds the
draft rather than on the one showing it."
  (let ((suffix (cdr (assq kind commit-gate-scrub-suffixes))))
    (and suffix
         (commit-gate-buffer-p buffer)
         (concat (buffer-file-name buffer) suffix))))

(defun commit-gate-scrub--nonempty-p (file)
  "Whether FILE exists and holds anything.
`diff' writes an empty file when its two sides match, so size is what
separates a filter run that changed the draft from one that did not."
  (let ((attrs (and file (ignore-errors (file-attributes file)))))
    (and attrs (> (file-attribute-size attrs) 0))))

(defun commit-gate-scrub-probe (&optional buffer)
  "What the filter did to BUFFER's draft, judged by its siblings on disk.
Returns one of four states, or nil when BUFFER is not a gate at all:

  `rewritten'  the filter changed the draft, and the backup holds the original
  `refused'    it ran, produced something, and a guard threw the reply away
  `clean'      it ran and left the draft alone
  `absent'     it did not run

Each file answers one question. The state file says a run COMPLETED, the
backup says it CHANGED something, and the refusal marker says a reply was
rejected. The filter keeps a backup only when there is something to recover,
and it clears the refusal marker on any run it accepts.

`rewritten' is tested first, because it is the one that describes the TEXT in
front of the reader. A refusal recorded after an earlier rewrite says the last
reply was thrown away, and the draft is still the earlier rewrite rather than
the original.

Every fault reads as `absent'. An unreadable sibling is not evidence of a
rewrite, and claiming one that did not happen would spend the credibility the
indicator exists to have."
  (let ((original (commit-gate-scrub-file 'original buffer))
        (refused (commit-gate-scrub-file 'refused buffer))
        (state (commit-gate-scrub-file 'state buffer)))
    (when original
      (or (ignore-errors
            (cond
             ((file-exists-p original) 'rewritten)
             ((file-exists-p refused) 'refused)
             ((file-exists-p state) 'clean)
             (t 'absent)))
          'absent))))

(defun commit-gate-scrub-lighter ()
  "Mode-line text for this buffer's scrub state.
Reads the cached state and nothing else. This runs on every redisplay, and a
gate is usually a TRAMP buffer, so it must never touch the disk."
  (or (cdr (assq commit-gate-scrub-status commit-gate-scrub-lighters)) ""))

(defun commit-gate-scrub--hash (file)
  "The SHA-256 of FILE's bytes, or nil when it cannot be read.
Read literally and hashed as bytes, so this agrees with the `sha256sum' the
filter recorded rather than depending on how Emacs would decode the text."
  (ignore-errors
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert-file-contents-literally file)
      (secure-hash 'sha256 (buffer-string)))))

(defun commit-gate-scrub--first-line (file)
  "The single line FILE holds, trimmed, or nil when it holds nothing usable.
Two of the siblings are one short line: a hash, or the reason a reply was
refused."
  (let ((text (ignore-errors
                (with-temp-buffer
                  (insert-file-contents file)
                  (string-trim (buffer-string))))))
    (and text (not (string-empty-p text)) text)))

(defun commit-gate-scrub-filter-output-p (&optional buffer)
  "Whether BUFFER's draft on disk is still exactly what the filter produced.
True only when the buffer has no unsaved edits and the file hashes to what the
filter recorded. Anything else reads as false, which is the safe direction:
it sends the reader to the recorded diff rather than to a live comparison that
would report his own edits as the filter's."
  (with-current-buffer (or buffer (current-buffer))
    (let ((state (commit-gate-scrub-file 'state))
          (file (buffer-file-name)))
      (and state file
           (not (buffer-modified-p))
           (let ((recorded (commit-gate-scrub--first-line state)))
             (and recorded (equal recorded (commit-gate-scrub--hash file))))))))

(defun commit-gate-scrub--show-recorded (diff)
  "Display DIFF, the change the filter recorded, in a read-only buffer."
  (unless (commit-gate-scrub--nonempty-p diff)
    (user-error "commit-gate: no recorded diff beside this draft"))
  (let ((buffer (get-buffer-create "*commit-gate scrub diff*")))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert-file-contents diff)
        (diff-mode)
        (goto-char (point-min)))
      (setq buffer-read-only t))
    ;; `display-buffer', so the gate keeps the selected window. Point in the
    ;; draft is where he is working, and a gate that moves it has already cost
    ;; him keystrokes once.
    (display-buffer buffer)))

(defun commit-gate-show-scrub-diff (&optional recorded)
  "Show what the draft filter changed in this commit gate.
With a prefix argument RECORDED, or once the draft on disk is no longer the
filter's output, show the diff the filter recorded when it ran. Otherwise
ediff the recorded original against the draft, which is the same comparison
while the draft is untouched and is the side-by-side form he reviews in.

After an edit the recorded diff is the only honest answer. A live comparison
then reports his own edits as the filter's."
  (interactive "P")
  (unless (commit-gate-buffer-p)
    (user-error "Not a commit gate"))
  (unless commit-gate-scrub-status
    (setq commit-gate-scrub-status (commit-gate-scrub-probe)))
  (let ((original (commit-gate-scrub-file 'original))
        (diff (commit-gate-scrub-file 'diff)))
    (pcase commit-gate-scrub-status
      ('absent
       (message "commit-gate: the filter did not run on this draft"))
      ('clean
       (message "commit-gate: the filter ran and changed nothing"))
      ('refused
       ;; The reason is worth repeating rather than summarising. One of the
       ;; guards exists because a reply once carried content the draft never
       ;; had, and knowing WHICH guard fired is the difference between a slow
       ;; model and an attempted injection.
       (message "commit-gate: the filter's reply was refused: %s"
                (or (commit-gate-scrub--first-line
                     (commit-gate-scrub-file 'refused))
                    "no reason recorded")))
      (_
       (if (or recorded (not (commit-gate-scrub-filter-output-p)))
           (commit-gate-scrub--show-recorded diff)
         (ediff-files original (buffer-file-name)))))))

(defvar commit-gate-scrub-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-s") #'commit-gate-show-scrub-diff)
    map)
  "Keymap for `commit-gate-scrub-mode'.")

(define-minor-mode commit-gate-scrub-mode
  "Show whether an automated filter rewrote this commit gate's draft.
The state is probed when the mode is turned on rather than on redisplay,
because a gate is usually a TRAMP buffer."
  :init-value nil
  :lighter (:eval (commit-gate-scrub-lighter))
  :keymap commit-gate-scrub-mode-map
  (when commit-gate-scrub-mode
    (setq commit-gate-scrub-status (commit-gate-scrub-probe))))

(defun commit-gate-scrub-maybe-enable ()
  "Turn on `commit-gate-scrub-mode' when this buffer is a gate.
For `find-file-hook'. An `emacsclient' open runs that hook, so a gate carries
the indicator without the agent that opened it asking for one."
  (when (commit-gate-buffer-p)
    (commit-gate-scrub-mode 1)))

(defun commit-gate-scrub-install ()
  "Arm the indicator for every gate this Emacs opens.
Adding the same function to a hook twice does not stack it, so this is safe to
re-run when the configuration is reloaded."
  (add-hook 'find-file-hook #'commit-gate-scrub-maybe-enable))

(provide 'commit-gate-scrub)

;;; commit-gate-scrub.el ends here
