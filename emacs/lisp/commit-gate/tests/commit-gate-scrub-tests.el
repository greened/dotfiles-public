;;; commit-gate-scrub-tests.el --- Tests for the scrub indicator -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Run with ../check.sh.
;;
;; The indicator makes one claim: the draft in front of him either was rewritten
;; by the filter or was not. A wrong claim in either direction costs more than
;; no indicator, so both directions are tested here:
;;
;;   - a filter run that CHANGED the draft reads as `rewritten', on the backup;
;;   - a filter run that changed nothing reads as `clean', on the state file,
;;     which the filter writes on every run while it keeps a backup only when
;;     there is something to recover;
;;   - a reply a guard threw away reads as `refused', on its own marker, and
;;     the draft is then unfiltered text;
;;   - no filter run at all reads as `absent', which is the state worth
;;     telling him about rather than folding into the ones above.
;;
;; The hash test pins the interop that the ediff branch depends on. The filter
;; records `sha256sum' of the draft, so a reader that hashes differently would
;; always conclude the draft had been edited, and the live comparison would be
;; unreachable code that nothing failed on.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'commit-gate-scrub)

(defconst commit-gate-scrub-t--message "a message\n"
  "The fixture draft. Its digest is pinned below.")

(defconst commit-gate-scrub-t--digest
  "e695449dff919341411d56beff666cad8f9c045c7cea52ccd535446a77aa0635"
  "`sha256sum' of the fixture draft, taken from the tool itself.
Pinned rather than computed here, so this asserts agreement with what the
filter writes instead of agreement with itself.")

(defmacro commit-gate-scrub-t--with-name (name &rest body)
  "Run BODY in a temporary buffer whose `buffer-file-name' is NAME."
  (declare (indent 1))
  `(with-temp-buffer
     (setq buffer-file-name ,name)
     ,@body))

(defmacro commit-gate-scrub-t--with-gate (gate siblings &rest body)
  "Run BODY visiting a fresh gate file bound to GATE.
SIBLINGS is an alist of suffix strings and contents to write beside it, so a
test states the on-disk situation it is about and nothing else. The directory
and the buffer are removed afterwards."
  (declare (indent 2))
  `(let* ((dir (make-temp-file "commit-gate-scrub-t" t))
          (,gate (expand-file-name "CLAUDE_COMMIT_MSG" dir)))
     (unwind-protect
         (progn
           (with-temp-file ,gate
             (insert commit-gate-scrub-t--message))
           (dolist (pair ,siblings)
             (with-temp-file (concat ,gate (car pair))
               (insert (cdr pair))))
           (let ((buffer (find-file-noselect ,gate)))
             (unwind-protect
                 (with-current-buffer buffer ,@body)
               (with-current-buffer buffer (set-buffer-modified-p nil))
               (kill-buffer buffer))))
       (delete-directory dir t))))

(defmacro commit-gate-scrub-t--message-of (&rest body)
  "The last message BODY emitted, as a string.
`current-message' is no help under batch, where the echo area is stderr, so
`message' itself is captured."
  `(let ((said nil))
     (cl-letf (((symbol-function 'message)
                (lambda (format-string &rest args)
                  (setq said (apply #'format format-string args)))))
       ,@body)
     (or said "")))

;;; Where the siblings are

(ert-deftest commit-gate-scrub-names-every-sibling ()
  "The filter owns these names, so a typo here reads as a clean draft."
  (commit-gate-scrub-t--with-name "/tmp/x/.git/CLAUDE_COMMIT_MSG"
    (should (equal (commit-gate-scrub-file 'original)
                   "/tmp/x/.git/CLAUDE_COMMIT_MSG.pre-scrub"))
    (should (equal (commit-gate-scrub-file 'state)
                   "/tmp/x/.git/CLAUDE_COMMIT_MSG.scrub-state"))
    (should (equal (commit-gate-scrub-file 'diff)
                   "/tmp/x/.git/CLAUDE_COMMIT_MSG.scrub-diff"))
    (should (equal (commit-gate-scrub-file 'refused)
                   "/tmp/x/.git/CLAUDE_COMMIT_MSG.scrub-refused"))))

(ert-deftest commit-gate-scrub-keeps-a-remote-prefix ()
  "A gate is usually shown over TRAMP, and the siblings live with the draft."
  (commit-gate-scrub-t--with-name "/ssh:dev:/home/u/r/.git/CLAUDE_COMMIT_MSG"
    (should (equal (commit-gate-scrub-file 'original)
                   "/ssh:dev:/home/u/r/.git/CLAUDE_COMMIT_MSG.pre-scrub"))))

(ert-deftest commit-gate-scrub-names-nothing-for-a-non-gate ()
  "Every entry point is reachable from any buffer he happens to be in."
  (commit-gate-scrub-t--with-name "/tmp/x/notes.txt"
    (should-not (commit-gate-scrub-file 'original))
    (should-not (commit-gate-scrub-probe))))

(ert-deftest commit-gate-scrub-names-nothing-for-an-unknown-kind ()
  "A caller asking for a sibling that does not exist gets nil, not a path
ending in `nil'."
  (commit-gate-scrub-t--with-name "/tmp/x/.git/CLAUDE_COMMIT_MSG"
    (should-not (commit-gate-scrub-file 'rejected))))

;;; What the probe concludes

(ert-deftest commit-gate-scrub-reports-a-rewrite ()
  "The backup is the evidence. The filter keeps one only when there is
something to recover, so its presence means the draft was changed."
  (commit-gate-scrub-t--with-gate gate '((".pre-scrub" . "the old text\n")
                                         (".scrub-state" . "abc")
                                         (".scrub-diff" . "-old\n+new\n"))
    (should (eq (commit-gate-scrub-probe) 'rewritten))))

(ert-deftest commit-gate-scrub-reports-a-clean-run-as-clean ()
  "THE POINT OF THE SEPARATE STATES. A clean run writes the state file and no
backup, so this is what the filter leaving a draft alone looks like on disk.
Reporting it as `absent' would answer the easy half of his question and lose
the half he asked about."
  (commit-gate-scrub-t--with-gate gate '((".scrub-state" . "abc"))
    (should (eq (commit-gate-scrub-probe) 'clean))))

(ert-deftest commit-gate-scrub-reports-a-rewrite-with-no-diff-recorded ()
  "The backup decides, not the diff. A `diff' that failed to record leaves the
draft rewritten all the same, and saying otherwise would hide it."
  (commit-gate-scrub-t--with-gate gate '((".pre-scrub" . "the old text\n"))
    (should (eq (commit-gate-scrub-probe) 'rewritten))))

(ert-deftest commit-gate-scrub-reports-a-refused-reply ()
  "The state that used to read as `absent'. A guard threw the reply away, so
the draft is unfiltered text, which is what he would see with the filter off.
Only the marker tells those apart."
  (commit-gate-scrub-t--with-gate
      gate '((".scrub-refused" . "the reply added a line the draft lacks\n"))
    (should (eq (commit-gate-scrub-probe) 'refused))))

(ert-deftest commit-gate-scrub-prefers-a-rewrite-over-a-later-refusal ()
  "ORDER MATTERS HERE. A refusal recorded after an earlier rewrite means the
last reply was discarded, and the draft is still the earlier rewrite. Reading
this as `refused' would tell him the text is his session's when it is not."
  (commit-gate-scrub-t--with-gate gate '((".pre-scrub" . "the old text\n")
                                         (".scrub-refused" . "a later refusal\n"))
    (should (eq (commit-gate-scrub-probe) 'rewritten))))

(ert-deftest commit-gate-scrub-prefers-a-refusal-over-a-stale-state-file ()
  "A refusal writes no state file, so a state file beside one is from an
earlier run. The refusal is the newer fact."
  (commit-gate-scrub-t--with-gate gate '((".scrub-state" . "abc")
                                         (".scrub-refused" . "implausible\n"))
    (should (eq (commit-gate-scrub-probe) 'refused))))

(ert-deftest commit-gate-scrub-command-reports-the-refusal-reason ()
  "The reason separates a slow model from an attempted injection, so it is
repeated rather than summarised."
  (commit-gate-scrub-t--with-gate
      gate '((".scrub-refused" . "the reply added a line the draft lacks\n"))
    (should (string-match-p "added a line"
                            (commit-gate-scrub-t--message-of
                             (commit-gate-show-scrub-diff))))))

(ert-deftest commit-gate-scrub-reports-absent-with-nothing-recorded ()
  "Nothing on disk means the filter never saw this draft, which is the state
worth telling him about. A leftover diff alone is not evidence of a run."
  (commit-gate-scrub-t--with-gate gate '((".scrub-diff" . "-old\n+new\n"))
    (should (eq (commit-gate-scrub-probe) 'absent)))
  (commit-gate-scrub-t--with-gate gate nil
    (should (eq (commit-gate-scrub-probe) 'absent))))

;;; What the mode line says

(ert-deftest commit-gate-scrub-lighter-says-something-in-every-state ()
  "A state with no text would be indistinguishable from the mode being off."
  (dolist (state '(rewritten refused clean absent))
    (let ((commit-gate-scrub-status state))
      (should-not (string-empty-p (commit-gate-scrub-lighter)))))
  (let ((commit-gate-scrub-status nil))
    (should (equal (commit-gate-scrub-lighter) ""))))

(ert-deftest commit-gate-scrub-lighter-distinguishes-the-states ()
  "Four states, four readings. Two that read alike answer nothing."
  (let ((seen (mapcar (lambda (state)
                        (let ((commit-gate-scrub-status state))
                          (commit-gate-scrub-lighter)))
                      '(rewritten refused clean absent))))
    (should (equal (length (delete-dups (copy-sequence seen))) 4))))

;;; Whether the draft is still the filter's output

(ert-deftest commit-gate-scrub-hash-agrees-with-sha256sum ()
  "The interop the live ediff rests on. The filter records `sha256sum' of the
draft, so a reader that hashed the decoded text instead of the bytes would
conclude every draft had been edited."
  (commit-gate-scrub-t--with-gate gate nil
    (should (equal (commit-gate-scrub--hash gate)
                   commit-gate-scrub-t--digest))))

(ert-deftest commit-gate-scrub-recognises-the-filters-output ()
  "The state file holds this draft's hash, so the draft is untouched."
  (commit-gate-scrub-t--with-gate
      gate (list (cons ".scrub-state" commit-gate-scrub-t--digest))
    (should (commit-gate-scrub-filter-output-p))))

(ert-deftest commit-gate-scrub-rejects-a-draft-that-moved-on ()
  "A hash that does not match means the draft was written or saved after the
scrub, and a live comparison would report that as the filter's work."
  (commit-gate-scrub-t--with-gate gate '((".scrub-state" . "0000"))
    (should-not (commit-gate-scrub-filter-output-p))))

(ert-deftest commit-gate-scrub-rejects-an-edited-buffer ()
  "His unsaved edits are the case this exists for."
  (commit-gate-scrub-t--with-gate
      gate (list (cons ".scrub-state" commit-gate-scrub-t--digest))
    (insert "his own wording\n")
    (should-not (commit-gate-scrub-filter-output-p))))

(ert-deftest commit-gate-scrub-rejects-a-missing-state-file ()
  "Nothing recorded, so nothing is established."
  (commit-gate-scrub-t--with-gate gate '((".pre-scrub" . "old\n"))
    (should-not (commit-gate-scrub-filter-output-p))))

;;; Turning it on

(ert-deftest commit-gate-scrub-mode-probes-when-it-is-turned-on ()
  "The probe runs here and not on redisplay, because a gate is usually a
TRAMP buffer and a mode-line construct runs on every redisplay."
  (commit-gate-scrub-t--with-gate gate '((".pre-scrub" . "old\n")
                                         (".scrub-diff" . "-old\n+new\n"))
    (commit-gate-scrub-mode 1)
    (should (eq commit-gate-scrub-status 'rewritten))))

(ert-deftest commit-gate-scrub-does-not-enable-outside-a-gate ()
  "`find-file-hook' runs for every file he opens."
  (commit-gate-scrub-t--with-name "/tmp/x/notes.txt"
    (commit-gate-scrub-maybe-enable)
    (should-not commit-gate-scrub-mode)))

(ert-deftest commit-gate-scrub-install-does-not-stack ()
  "The configuration is reloaded often."
  (unwind-protect
      (progn
        (remove-hook 'find-file-hook #'commit-gate-scrub-maybe-enable)
        (commit-gate-scrub-install)
        (commit-gate-scrub-install)
        (should (equal (seq-count (lambda (f)
                                    (eq f #'commit-gate-scrub-maybe-enable))
                                  find-file-hook)
                       1)))
    (remove-hook 'find-file-hook #'commit-gate-scrub-maybe-enable)))

;;; The command

(ert-deftest commit-gate-scrub-command-refuses-a-non-gate ()
  "Bound in the gate's own map, but reachable by name from anywhere."
  (commit-gate-scrub-t--with-name "/tmp/x/notes.txt"
    (should-error (commit-gate-show-scrub-diff) :type 'user-error)))

(ert-deftest commit-gate-scrub-command-says-when-nothing-was-scrubbed ()
  "It reports rather than opening an empty comparison."
  (commit-gate-scrub-t--with-gate gate nil
    (should (string-match-p "did not run"
                            (commit-gate-scrub-t--message-of
                             (commit-gate-show-scrub-diff))))))

(ert-deftest commit-gate-scrub-command-says-when-the-filter-changed-nothing ()
  "The clean case is a message, not a diff of two identical texts."
  (commit-gate-scrub-t--with-gate gate '((".scrub-state" . "abc"))
    (should (string-match-p "changed nothing"
                            (commit-gate-scrub-t--message-of
                             (commit-gate-show-scrub-diff))))))

(ert-deftest commit-gate-scrub-command-shows-the-recorded-diff ()
  "After an edit the recorded diff is the only honest answer, so it is what
the command falls back to rather than comparing against the live buffer."
  (commit-gate-scrub-t--with-gate gate '((".pre-scrub" . "old\n")
                                         (".scrub-diff" . "-old\n+new\n"))
    (insert "his own wording\n")
    (unwind-protect
        (progn
          (commit-gate-show-scrub-diff)
          (let ((shown (get-buffer "*commit-gate scrub diff*")))
            (should shown)
            (with-current-buffer shown
              (should buffer-read-only)
              (should (string-match-p "+new" (buffer-string))))))
      (let ((shown (get-buffer "*commit-gate scrub diff*")))
        (when shown (kill-buffer shown))))))

;;; commit-gate-scrub-tests.el ends here
