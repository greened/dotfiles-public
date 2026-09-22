;;; lint-packages.el --- Lint packages.el for a missing :ensure -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; A test of emacs/lisp/packages.el, run by ../lint-packages-selftest.sh.  That
;; file is deliberately not byte-compiled -- see compile-packages.el for why --
;; so a lint is what covers it.
;;
;; Every `use-package' stanza has to say what elpaca is to do about the package:
;;
;;     :ensure t            fetch it
;;     :ensure (RECIPE)     fetch it, with an explicit recipe
;;     :ensure nil          already available: built in, or vendored here
;;     :elpaca nil          an older spelling of the same thing
;;     :disabled t          the stanza expands to nothing, so nothing is fetched
;;
;; A stanza carrying none of those is never ordered, and a deferred one then
;; fails at the moment of use rather than at startup.
;;
;; Two things here that a regex over the same text gets wrong.  Each stanza is
;; parsed with `read' and classified by the keywords at the top level of its
;; argument list, so an explicit recipe counts and a nested stanza's own
;; `:ensure' does not vouch for its parent.  And a stanza that declares nothing
;; is excused only when `locate-library' finds it: under `emacs -Q --batch' the
;; load path holds the built-in libraries and none of the fetched ones, which is
;; the distinction wanted.  `lp-add-load-path' adds the checkout's own elisp
;; directories, so vendoring a new file needs no change here.

;;; Code:

(require 'seq)

(defvar lp-root
  (expand-file-name ".." (file-name-directory
                          (or load-file-name buffer-file-name)))
  "The dotfiles checkout this lint belongs to.")

(defconst lp-declarations '(:ensure :elpaca :disabled)
  "The keywords by which a stanza declares what is to be fetched.")

(defconst lp-lisp-globs '("emacs/lisp" "emacs/lisp/*" "emacs/site-lisp/*")
  "Globs for the checkout's own elisp directories, relative to `lp-root'.")

(defconst lp-pseudo-packages '(emacs)
  "Stanza names that are not libraries.
`(use-package emacs ...)' is the conventional way to group plain settings, so
`locate-library' cannot vouch for it and never will.")

(defun lp-packages-file ()
  "The configuration file this lints."
  (expand-file-name "emacs/lisp/packages.el" lp-root))

(defun lp-load-path-dirs (&optional root)
  "The checkout's own elisp directories, under ROOT or `lp-root'."
  (seq-filter #'file-directory-p
              (mapcan (lambda (glob)
                        (file-expand-wildcards
                         (expand-file-name glob (or root lp-root))))
                      lp-lisp-globs)))

(defun lp-add-load-path (&optional root)
  "Put the checkout's own elisp directories, under ROOT, on `load-path'.
A library vendored here then resolves, the same as a built-in one."
  (dolist (dir (lp-load-path-dirs root))
    (add-to-list 'load-path dir)))

(defun lp-stanzas ()
  "Every `use-package' stanza in the current buffer, outermost first.
Each is a plist of :name, :line and :form.  A stanza guarded by a `when' is
one of these too.  One inside a comment or a string is not."
  (let (out)
    (with-syntax-table emacs-lisp-mode-syntax-table
      (save-excursion
        (goto-char (point-min))
        (while (re-search-forward "(use-package\\_>" nil t)
          ;; The next search starts from a position this loop holds itself.
          ;; `syntax-ppss' leaves point at the position it was asked about, so
          ;; point is no longer past the match once the comment check has run,
          ;; and a loop that trusted it matched the same stanza forever.
          (let ((start (match-beginning 0))
                (end (match-end 0)))
            (unless (nth 8 (syntax-ppss start))
              (let ((form (save-excursion
                            (goto-char start)
                            (read (current-buffer)))))
                (push (list :name (cadr form)
                            :line (line-number-at-pos start)
                            :form form)
                      out)))
            (goto-char end)))))
    (nreverse out)))

(defun lp-declares-p (form)
  "Whether FORM carries one of `lp-declarations'.
Only the keywords at the top level of the argument list count, so a stanza
nested in another one's `:config' does not vouch for its parent."
  (let ((args (cddr form)))
    (and (seq-some (lambda (keyword) (memq keyword args)) lp-declarations) t)))

(defun lp-resolvable-p (name)
  "Whether NAME is a library this Emacs can load without fetching it."
  (and (symbolp name) name (locate-library (symbol-name name)) t))

(defun lp-stanza-ok-p (stanza)
  "Whether STANZA says what is to happen about fetching its package."
  (let ((name (plist-get stanza :name)))
    (or (lp-declares-p (plist-get stanza :form))
        (and (memq name lp-pseudo-packages) t)
        (lp-resolvable-p name))))

(defun lp-violations ()
  "The stanzas in the current buffer that declare nothing."
  (seq-remove #'lp-stanza-ok-p (lp-stanzas)))

(defun lp-main (&optional file)
  "Report every undeclared stanza in FILE, and exit non-zero if there is one.
FILE defaults to the checkout's own packages.el."
  (let ((file (or file (lp-packages-file)))
        stanzas bad)
    (lp-add-load-path)
    (with-temp-buffer
      (insert-file-contents file)
      (setq stanzas (lp-stanzas))
      (setq bad (seq-remove #'lp-stanza-ok-p stanzas)))
    (dolist (stanza bad)
      (princ (format "%s:%d: %s carries no %s, and is not already available\n"
                     file (plist-get stanza :line) (plist-get stanza :name)
                     (mapconcat #'symbol-name lp-declarations " or "))))
    (princ (format "%s: %d stanza(s), %d undeclared\n"
                   (file-name-nondirectory file) (length stanzas) (length bad)))
    (kill-emacs (if bad 1 0))))

(provide 'lint-packages)

;;; lint-packages.el ends here
