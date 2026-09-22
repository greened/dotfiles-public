;;; commit-gate-tests.el --- Tests for the commit-gate accept recorder -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Run with ../check.sh.
;;
;; This file is the one place that can tell an approved commit message from a
;; dismissed one, so each of its three properties gets a test that fails when
;; the property is absent:
;;
;;   - it stamps a sentinel for a gate buffer;
;;   - it stamps NOTHING for any other buffer, which is attribution;
;;   - the sentinel holds a time rather than a flag, so a reader can reject a
;;     leftover from an earlier gate.
;;
;; The path tests set `buffer-file-name' directly instead of visiting a file.
;; A gate shown over TRAMP carries a remote prefix, and asserting that the
;; prefix survives must not need a host to connect to.

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
  "Run BODY with DIR bound to a fresh directory, removed afterwards."
  (declare (indent 1))
  `(let ((,dir (make-temp-file "commit-gate-t" t)))
     (unwind-protect (progn ,@body)
       (delete-directory ,dir t))))

;;; Which buffers are gates

(ert-deftest commit-gate-recognises-a-gate-buffer ()
  "The name is exact, and it is the only thing that marks a gate."
  (commit-gate-t--with-name "/tmp/x/.git/CLAUDE_COMMIT_MSG"
    (should (commit-gate-buffer-p))))

(ert-deftest commit-gate-rejects-another-file-in-the-same-directory ()
  "A gate's siblings are not gates.  `.stripped' is written by the agent."
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
sentinel has to say WHEN.  An always-armed advice stamps leftovers."
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
  "Attribution.  `server-done' fires for whichever buffer he finished, so
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
twice and make the count meaningless.  Measured rather than assumed."
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

;;; commit-gate-tests.el ends here
