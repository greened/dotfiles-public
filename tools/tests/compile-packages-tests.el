;;; compile-packages-tests.el --- Tests for the local-package build -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Run with ../../compile-packages-selftest.sh.
;;
;; What is tested is the DECISION -- which directories count as packages --
;; and not the compile itself.  A build is slow, needs the fetched package
;; set, and its result is already the thing `check.sh build' reports.  Which
;; directories it was ever going to look at is the part that used to be a
;; hand-written list, and the part whose failure is silent.
;;
;; Most cases run against a fixture tree, so a case can add a directory
;; without touching the checkout.  One runs against the real `cp-root': the
;; derived set must be exactly the five packages the hand-written list used to
;; name.  That one is the oracle -- it is what says the derivation did not
;; quietly change what gets built.

;;; Code:

(require 'ert)
(require 'compile-packages)

(defun cp-t--tree (&rest specs)
  "Build a fixture checkout and return its root.
Each SPEC is (RELATIVE-PATH . CONTENT).  A path ending in a slash is a
directory."
  (let ((root (make-temp-file "cp-t" t)))
    (make-directory (expand-file-name "emacs/lisp" root) t)
    (dolist (spec specs)
      (let ((path (expand-file-name (car spec) root)))
        (if (string-suffix-p "/" (car spec))
            (make-directory path t)
          (make-directory (file-name-directory path) t)
          (with-temp-file path (insert (or (cdr spec) ""))))))
    root))

(defmacro cp-t--with-tree (root specs &rest body)
  "Bind `cp-root' to a fixture built from SPECS, as ROOT, and run BODY."
  (declare (indent 2))
  `(let* ((,root (apply #'cp-t--tree ,specs))
          (cp-root ,root))
     (unwind-protect (progn ,@body)
       (delete-directory ,root t))))

;;; Which directories are candidates

(ert-deftest cp-finds-a-directory-holding-elisp ()
  "The ordinary case, and the one a hand-written list had to be told about."
  (cp-t--with-tree root '(("emacs/lisp/widget/widget.el" . ";; a package"))
    (should (equal (cp-candidate-dirs) '("widget")))))

(ert-deftest cp-finds-a-directory-added-with-no-other-change ()
  "This is the whole fix.  A new package is built without editing anything,
because the previous behaviour reported NEITHER a compile nor a skip for a
directory nobody had listed."
  (cp-t--with-tree root '(("emacs/lisp/one/one.el" . "")
                          ("emacs/lisp/two/two.el" . ""))
    (should (equal (cp-candidate-dirs) '("one" "two")))))

(ert-deftest cp-ignores-a-directory-with-no-elisp ()
  "A data or documentation directory is not a package."
  (cp-t--with-tree root '(("emacs/lisp/docs/README.md" . "notes"))
    (should (equal (cp-candidate-dirs) nil))))

(ert-deftest cp-ignores-a-directory-holding-only-tests ()
  "`cp-package-files' drops test files, so such a directory compiles
nothing and is not a package."
  (cp-t--with-tree root '(("emacs/lisp/odd/odd-tests.el" . ""))
    (should (equal (cp-candidate-dirs) nil))))

(ert-deftest cp-ignores-a-flat-configuration-file ()
  "emacs/lisp also holds configuration, which assumes a live session and the
whole fetched package set.  Scanning for DIRECTORIES excludes it, so there is
no second list to keep in step."
  (cp-t--with-tree root '(("emacs/lisp/packages.el" . ";; configuration")
                          ("emacs/lisp/real/real.el" . ""))
    (should (equal (cp-candidate-dirs) '("real")))))

;;; Exclusions

(ert-deftest cp-drops-an-excluded-directory-but-still-sees-it ()
  "An excluded directory stays a CANDIDATE, so the run can report it.  That
is the difference between a documented exclusion and a silent omission."
  (cp-t--with-tree root '(("emacs/lisp/themes/themes.el" . "")
                          ("emacs/lisp/kept/kept.el" . ""))
    (should (equal (cp-candidate-dirs) '("kept" "themes")))
    (should (equal (cp-packages) '("kept")))))

(ert-deftest cp-every-exclusion-states-a-reason ()
  "The reason is printed on every run, so it must not be empty."
  (dolist (entry cp-excluded)
    (should (stringp (car entry)))
    (should (stringp (cdr entry)))
    (should (> (length (cdr entry)) 0))))

;;; Which files inside a package compile

(ert-deftest cp-package-files-excludes-tests ()
  "Both spellings, since the tree uses one and the regexp allows either."
  (cp-t--with-tree root '(("emacs/lisp/p/p.el" . "")
                          ("emacs/lisp/p/p-test.el" . "")
                          ("emacs/lisp/p/p-tests.el" . ""))
    (should (equal (mapcar #'file-name-nondirectory
                           (cp-package-files
                            (expand-file-name "emacs/lisp/p" cp-root)))
                   '("p.el")))))

;;; The oracle: the real tree

(ert-deftest cp-derivation-matches-the-list-it-replaced ()
  "The five names the hand-written list carried, and `themes' excluded.
If this fails, the derivation changed WHAT GETS BUILT, which is the one
outcome a refactor of the input set must not have."
  (should (equal (cp-packages)
                 '("agenda-feeds" "commit-gate" "llm-api-key" "term-launcher"
                   "vterm-reconnect")))
  (should (member "themes" (cp-candidate-dirs)))
  (should-not (member "themes" (cp-packages))))

;;; compile-packages-tests.el ends here
