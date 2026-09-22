;;; lint-packages-tests.el --- Tests for the packages.el lint -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Run with ../../lint-packages-selftest.sh.
;;
;; Every fixture is a stanza written inline, never the real packages.el.  That
;; file passes, which says nothing about whether the lint can fail, so each
;; accepted spelling gets a case and so does a stanza that declares nothing.
;;
;; The two resolvable cases name `dired' and `llvm-mode' -- a built-in library
;; and one vendored in this checkout.  Both are on the load path of a bare Emacs
;; once `lp-add-load-path' has run, which is the question the lint asks.
;; `no-such-library-xyzzy' is resolvable nowhere, which is the other answer.

;;; Code:

(require 'ert)
(require 'lint-packages)

;; The lint does this itself.  The fixtures ask the same question of the same
;; libraries, so they need it too.
(lp-add-load-path)

(defun lp-t--stanzas (&rest lines)
  "The stanzas the lint finds in LINES, joined with newlines."
  (with-temp-buffer
    (insert (mapconcat #'identity lines "\n"))
    (lp-stanzas)))

(defun lp-t--names (stanzas)
  "The :name of each stanza in STANZAS."
  (mapcar (lambda (stanza) (plist-get stanza :name)) stanzas))

(defun lp-t--violations (&rest lines)
  "The names of the offending stanzas in LINES, joined with newlines."
  (with-temp-buffer
    (insert (mapconcat #'identity lines "\n"))
    (lp-t--names (lp-violations))))

;;; The accepted spellings

(ert-deftest lp-accepts-ensure-t ()
  "`:ensure t' orders the package, so nothing else need vouch for it."
  (should (equal (lp-t--violations "(use-package magit"
                                   "  :ensure t)")
                 nil)))

(ert-deftest lp-accepts-ensure-nil ()
  "`:ensure nil' says the library is there already."
  (should (equal (lp-t--violations "(use-package gnus"
                                   "  :ensure nil)")
                 nil)))

(ert-deftest lp-accepts-an-explicit-recipe ()
  "A recipe is a list, which a search for `:ensure t' or `:ensure nil' misses."
  (should (equal (lp-t--violations
                  "(use-package quite"
                  "  :ensure (:fetcher github :repo \"greened/quite\"))")
                 nil)))

(ert-deftest lp-accepts-a-recipe-that-is-one-symbol ()
  "`:ensure vlf' orders a package under a name that is not the stanza's."
  (should (equal (lp-t--violations "(use-package vlf-setup"
                                   "  :ensure vlf)")
                 nil)))

(ert-deftest lp-accepts-elpaca-nil ()
  "`:elpaca nil' is the older spelling of `:ensure nil'."
  (should (equal (lp-t--violations "(use-package project"
                                   "  :elpaca nil)")
                 nil)))

(ert-deftest lp-accepts-disabled ()
  "A disabled stanza expands to nothing, so nothing is fetched or run."
  (should (equal (lp-t--violations "(use-package no-such-library-xyzzy"
                                   "  :disabled t)")
                 nil)))

(ert-deftest lp-accepts-a-built-in-library-that-declares-nothing ()
  "A stanza needs no directive when the library needs no fetching."
  (should (equal (lp-t--violations "(use-package dired)") nil)))

(ert-deftest lp-accepts-a-vendored-library-that-declares-nothing ()
  "A file vendored in this checkout resolves the same way a built-in does."
  (should (equal (lp-t--violations "(use-package llvm-mode)") nil)))

(ert-deftest lp-accepts-the-emacs-pseudo-package ()
  "There is no library called `emacs', and the stanza is still correct."
  (should (equal (lp-t--violations "(use-package emacs"
                                   "  :config (setq visible-bell t))")
                 nil)))

(ert-deftest lp-accepts-a-directive-that-follows-other-keywords ()
  "Keyword order is free, so the search must not depend on it."
  (should (equal (lp-t--violations "(use-package magit"
                                   "  :defer t"
                                   "  :bind (\"C-x g\" . magit-status)"
                                   "  :ensure t)")
                 nil)))

;;; The defect

(ert-deftest lp-rejects-a-stanza-that-declares-nothing ()
  "Nothing orders the package.  Deferred, it fails only at the moment of use."
  (should (equal (lp-t--violations "(use-package no-such-library-xyzzy"
                                   "  :defer t)")
                 '(no-such-library-xyzzy))))

(ert-deftest lp-rejects-a-commented-out-directive ()
  "The shape the defect arrives in: the directive is present but inert."
  (should (equal (lp-t--violations "(use-package no-such-library-xyzzy"
                                   "  ;; :straight t"
                                   "  :mode \"\\\\.xyzzy\\\\'\")")
                 '(no-such-library-xyzzy))))

(ert-deftest lp-rejects-each-offender-and-keeps-the-good-ones ()
  "A file reports every offending stanza rather than the first."
  (should (equal (lp-t--violations "(use-package dired)"
                                   "(use-package no-such-library-xyzzy)"
                                   "(use-package magit :ensure t)"
                                   "(use-package other-no-such-library)")
                 '(no-such-library-xyzzy other-no-such-library))))

;;; A directive whose VALUE is a false claim

;; `:ensure nil' and `:elpaca nil' say the library is there already.  A stanza
;; naming a package that is nowhere is making a claim, not giving an
;; instruction, so the claim has to hold.  `bbdb' and `cask' both carried a
;; false one in this repository.

(ert-deftest lp-rejects-a-false-ensure-nil ()
  "Nothing is ordered, and the library is resolvable nowhere."
  (should (equal (lp-t--violations "(use-package no-such-library-xyzzy"
                                   "  :ensure nil)")
                 '(no-such-library-xyzzy))))

(ert-deftest lp-rejects-a-false-elpaca-nil ()
  "The older spelling makes the same claim, so it gets the same check."
  (should (equal (lp-t--violations "(use-package no-such-library-xyzzy"
                                   "  :elpaca nil)")
                 '(no-such-library-xyzzy))))

(ert-deftest lp-rejects-disabled-nil ()
  "`:disabled nil' says the stanza is live, so it still declares nothing."
  (should (equal (lp-t--violations "(use-package no-such-library-xyzzy"
                                   "  :disabled nil)")
                 '(no-such-library-xyzzy))))

(ert-deftest lp-accepts-ensure-nil-on-a-vendored-library ()
  "The claim holds: the file is vendored here and on the load path."
  (should (equal (lp-t--violations "(use-package llvm-mode"
                                   "  :ensure nil)")
                 nil)))

(ert-deftest lp-accepts-ensure-nil-on-the-emacs-pseudo-package ()
  "There is no library called `emacs', so the claim cannot be checked."
  (should (equal (lp-t--violations "(use-package emacs"
                                   "  :ensure nil)")
                 nil)))

(ert-deftest lp-accepts-ensure-t-on-a-library-that-is-nowhere ()
  "`:ensure t' is an instruction to fetch, so there is nothing to verify."
  (should (equal (lp-t--violations "(use-package no-such-library-xyzzy"
                                   "  :ensure t)")
                 nil)))

(ert-deftest lp-reads-a-value-after-a-config-body ()
  "`:config' takes SEVERAL forms, so the pairs `plist-get' assumes are gone.
The value has to be read as the element after the keyword instead."
  (should (equal (lp-t--violations "(use-package no-such-library-xyzzy"
                                   "  :config (setq a 1) (setq b 2)"
                                   "  :ensure nil)")
                 '(no-such-library-xyzzy)))
  (should (equal (lp-t--violations "(use-package no-such-library-xyzzy"
                                   "  :config (setq a 1) (setq b 2)"
                                   "  :ensure t)")
                 nil)))

;;; What the parse has to survive

(ert-deftest lp-ignores-a-commented-out-stanza ()
  "A stanza that is commented out is not configuration."
  (should (equal (lp-t--stanzas ";; (use-package no-such-library-xyzzy)") nil)))

(ert-deftest lp-ignores-a-stanza-inside-a-string ()
  "Nor is one quoted in a string."
  (should (equal (lp-t--stanzas
                  "(setq lp-t-doc \"(use-package no-such-library-xyzzy)\")")
                 nil)))

(ert-deftest lp-ignores-a-name-that-merely-starts-the-same ()
  "`use-package-report' is a function call, not a stanza."
  (should (equal (lp-t--stanzas "(use-package-report)") nil)))

(ert-deftest lp-finds-a-guarded-stanza ()
  "A stanza nested in a `when' is still a stanza."
  (should (equal (lp-t--names (lp-t--stanzas "(when (eq window-system 'w32)"
                                             "  (use-package bbdb-mua"
                                             "    :ensure t))"))
                 '(bbdb-mua))))

(ert-deftest lp-does-not-let-a-nested-directive-vouch-for-its-parent ()
  "The inner `:ensure' belongs to the inner stanza."
  (should (equal (lp-t--violations "(use-package no-such-library-xyzzy"
                                   "  :config"
                                   "  (use-package magit"
                                   "    :ensure t))")
                 '(no-such-library-xyzzy))))

(ert-deftest lp-reports-the-line-of-each-stanza ()
  "The line is the stanza's own, guarded or not."
  (should (equal (mapcar (lambda (stanza) (plist-get stanza :line))
                         (lp-t--stanzas ";; a comment"
                                        ""
                                        "(use-package dired)"
                                        "(when t"
                                        "  (use-package ielm))"))
                 '(3 5))))

;;; The load path the resolution check depends on

(ert-deftest lp-puts-the-checkouts-own-directories-on-the-load-path ()
  "The vendored tree is among them, and every entry is a directory."
  (let ((dirs (lp-load-path-dirs)))
    (should (seq-every-p #'file-directory-p dirs))
    (should (member (expand-file-name "emacs/lisp" lp-root) dirs))
    (should (member (expand-file-name "emacs/site-lisp/vendored" lp-root)
                    dirs))))

;;; lint-packages-tests.el ends here
