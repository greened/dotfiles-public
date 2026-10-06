;;; try-local-tests.el --- Tests for :try-local in packages.el -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; packages.el does not load in batch, so these tests read the try-local
;; defuns and their defvar out of it and evaluate only those. Run by
;; ../../try-local-selftest.sh.

;;; Code:

(require 'ert)
(require 'seq)
(require 'subr-x)

(defvar local-repos-directory)
(declare-function elpaca-recipe-try-local nil (recipe))
(declare-function elpaca-recipe-try-local--checkout nil (candidate name))

(defconst try-local-tests--packages
  (expand-file-name "../../emacs/lisp/packages.el"
                    (file-name-directory
                     (or load-file-name buffer-file-name))))

(defun try-local-tests--load ()
  "Evaluate the try-local forms from packages.el, and return their names."
  (let (names)
    (with-temp-buffer
      (insert-file-contents try-local-tests--packages)
      (condition-case nil
          (while t
            (let ((form (read (current-buffer))))
              (when (or (and (eq (car-safe form) 'defvar)
                             (eq (nth 1 form) 'local-repos-directory))
                        (and (eq (car-safe form) 'defun)
                             (string-prefix-p "elpaca-recipe-try-local"
                                              (symbol-name (nth 1 form)))))
                (eval form t)
                (push (nth 1 form) names))))
        (end-of-file nil)))
    names))

(defconst try-local-tests--names (try-local-tests--load))

;; The real one is in elpaca, which is not loaded here.
(defun elpaca-git--repo-name (repo)
  (file-name-nondirectory repo))

(defmacro try-local-tests--with-tree (dirs &rest body)
  "Make DIRS under a temp root, bind `root' to it and run BODY."
  (declare (indent 1))
  `(let ((root (file-name-as-directory (make-temp-file "try-local" t))))
     (unwind-protect
         (progn
           (dolist (dir ,dirs)
             (make-directory (expand-file-name dir root) t))
           ,@body)
       (delete-directory root t))))

(defun try-local-tests--resolve (root name)
  (let ((local-repos-directory (list (expand-file-name "projects" root)
                                     (expand-file-name "src" root))))
    (plist-get (elpaca-recipe-try-local
                (list :try-local t :repo (concat "greened/" name)))
               :repo)))

(ert-deftest try-local-tests-found-the-forms ()
  (should (memq 'local-repos-directory try-local-tests--names))
  (should (memq 'elpaca-recipe-try-local try-local-tests--names))
  (should (memq 'elpaca-recipe-try-local--checkout try-local-tests--names)))

(ert-deftest try-local-tests-flat-clone ()
  (try-local-tests--with-tree '("projects/quarry/.git")
    (should (equal (try-local-tests--resolve root "quarry")
                   (expand-file-name "projects/quarry" root)))))

(ert-deftest try-local-tests-umbrella-main ()
  (try-local-tests--with-tree '("projects/gazette/.gazette.git"
                                "projects/gazette/main"
                                "projects/gazette/master")
    (should (equal (try-local-tests--resolve root "gazette")
                   (expand-file-name "projects/gazette/main" root)))))

(ert-deftest try-local-tests-umbrella-master ()
  (try-local-tests--with-tree '("projects/quite/.quite.git"
                                "projects/quite/master")
    (should (equal (try-local-tests--resolve root "quite")
                   (expand-file-name "projects/quite/master" root)))))

(ert-deftest try-local-tests-umbrella-without-default-worktree ()
  ;; An umbrella with no main or master falls through to the next directory.
  (try-local-tests--with-tree '("projects/prevue/.prevue.git"
                                "projects/prevue/topic"
                                "src/prevue")
    (should (equal (try-local-tests--resolve root "prevue")
                   (expand-file-name "src/prevue" root)))))

(ert-deftest try-local-tests-absent ()
  (try-local-tests--with-tree '("projects")
    (should-not (try-local-tests--resolve root "gaffer"))))

(ert-deftest try-local-tests-off-without-keyword ()
  (try-local-tests--with-tree '("projects/quarry")
    (let ((local-repos-directory (list (expand-file-name "projects" root))))
      (should-not (elpaca-recipe-try-local '(:repo "greened/quarry"))))))

;;; try-local-tests.el ends here
