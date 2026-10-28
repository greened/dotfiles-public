;;; try-local-tests.el --- Tests for :try-local in packages.el -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; packages.el does not load in batch, so these tests read the try-local
;; and bootstrap defuns and their defvar out of it and evaluate only those. Run by
;; ../../try-local-selftest.sh.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'seq)
(require 'subr-x)

(defvar local-repos-directory)
(declare-function elpaca-recipe-try-local nil (recipe))
(declare-function elpaca-recipe-try-local--checkout nil (candidate name))
(declare-function elpaca-bootstrap--warn-old-layout nil (dir))
(declare-function elpaca-bootstrap--warn-stale-pin nil (source ref))

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
                             (seq-some (lambda (prefix)
                                         (string-prefix-p
                                          prefix (symbol-name (nth 1 form))))
                                       '("elpaca-recipe-try-local"
                                         "elpaca-bootstrap-"))))
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

(ert-deftest try-local-tests-older-elpaca-repo-name ()
  ;; An elpaca from before the rename has only `elpaca--repo-name'.
  (try-local-tests--with-tree '("projects/quarry/.git")
    (cl-letf (((symbol-function 'elpaca-git--repo-name) nil)
              ((symbol-function 'elpaca--repo-name) #'file-name-nondirectory))
      (should (equal (try-local-tests--resolve root "quarry")
                     (expand-file-name "projects/quarry" root))))))

(ert-deftest try-local-tests-no-repo-name-warns ()
  (try-local-tests--with-tree '("projects/quarry/.git")
    (let (warned)
      (cl-letf (((symbol-function 'elpaca-git--repo-name) nil)
                ((symbol-function 'elpaca--repo-name) nil)
                ((symbol-function 'display-warning)
                 (lambda (type &rest _) (setq warned type))))
        (should-not (try-local-tests--resolve root "quarry"))
        (should (eq warned 'elpaca-try-local))))))

;; A machine bootstrapped by the 0.7 installer still runs that build.
(ert-deftest try-local-tests-old-layout-warns ()
  (try-local-tests--with-tree '("repos/elpaca" "builds/elpaca")
    (let (warned)
      (cl-letf (((symbol-function 'display-warning)
                 (lambda (type &rest _) (setq warned type))))
        (elpaca-bootstrap--warn-old-layout root))
      (should (eq warned 'elpaca)))))

(ert-deftest try-local-tests-new-layout-is-quiet ()
  (try-local-tests--with-tree '("sources/elpaca" "builds/elpaca" "repos.old/elpaca")
    (cl-letf (((symbol-function 'display-warning)
               (lambda (&rest _) (error "warned on the new layout"))))
      (should-not (elpaca-bootstrap--warn-old-layout root)))))

;; A changed pin leaves an existing clone where it was.
(defun try-local-tests--clone-at-two-commits (dir)
  "Make two commits in the git repo DIR, and return their hashes, oldest first.
They are built with plumbing, so no commit hook runs on the fixture."
  (let* ((default-directory dir)
         (process-environment (append '("GIT_AUTHOR_NAME=t" "GIT_AUTHOR_EMAIL=t@t"
                                        "GIT_COMMITTER_NAME=t" "GIT_COMMITTER_EMAIL=t@t")
                                      process-environment))
         (tree (car (process-lines "git" "hash-object" "-w" "-t" "tree" "/dev/null")))
         (old (car (process-lines "git" "commit-tree" tree "-m" "one")))
         (new (car (process-lines "git" "commit-tree" tree "-p" old "-m" "two"))))
    (list old new)))

(defun try-local-tests--check-out (dir hash)
  "Point the detached HEAD of the git repo DIR at HASH."
  (with-temp-file (expand-file-name ".git/HEAD" dir)
    (insert hash "\n")))

(defmacro try-local-tests--warned (&rest body)
  "Run BODY and return the type of the warning it gave, or nil."
  `(let (warned)
     (cl-letf (((symbol-function 'display-warning)
                (lambda (type &rest _) (setq warned type))))
       ,@body)
     warned))

(defmacro try-local-tests--warning-text (&rest body)
  "Run BODY and return the text of the warning it gave, or nil."
  `(let (text)
     (cl-letf (((symbol-function 'display-warning)
                (lambda (_type message &rest _) (setq text message))))
       ,@body)
     text))

(ert-deftest try-local-tests-stale-pin ()
  (try-local-tests--with-tree '("src")
    (let ((src (expand-file-name "src/" root)))
      (call-process "git" nil nil nil "init" "-q" src)
      (pcase-let ((`(,old ,new) (try-local-tests--clone-at-two-commits src)))
        (try-local-tests--check-out src new)
        (should-not (try-local-tests--warned
                     (elpaca-bootstrap--warn-stale-pin src new)))
        (should (eq (try-local-tests--warned
                     (elpaca-bootstrap--warn-stale-pin src old))
                    'elpaca))
        ;; A pin the clone has never fetched is stale too.
        (should (eq (try-local-tests--warned
                     (elpaca-bootstrap--warn-stale-pin
                      src "0123456789abcdef0123456789abcdef01234567"))
                    'elpaca))))))

(ert-deftest try-local-tests-stale-pin-warns-without-git ()
  (try-local-tests--with-tree '("src")
    (let ((exec-path nil))
      (should (string-prefix-p
               "Cannot check"
               (try-local-tests--warning-text
                (elpaca-bootstrap--warn-stale-pin
                 (expand-file-name "src/" root) "HEAD")))))))

(ert-deftest try-local-tests-stale-pin-quiet-before-the-clone ()
  (try-local-tests--with-tree '()
    (should-not (try-local-tests--warned
                 (elpaca-bootstrap--warn-stale-pin
                  (expand-file-name "absent/" root) "HEAD")))))

;;; try-local-tests.el ends here
