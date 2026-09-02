;;; compile-packages.el --- Byte-compile the local elisp packages -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; The build half of ../check.sh.  Byte-compiles each local package under
;; emacs/lisp/ with warnings as errors, and says which it could not.
;;
;; Only the LOCAL PACKAGES are compiled, named one by one below rather than
;; globbed.  emacs/lisp also holds flat configuration files, which are not
;; packages: they assume the whole fetched package set and a live session, so
;; compiling them would report failures that mean nothing.  A glob would also
;; drag in emacs/lisp/themes, which wants `color-theme' -- abandoned upstream
;; and deliberately not installed.
;;
;; A package whose dependency is absent is SKIPPED rather than failed, and the
;; missing library is named.  That is the difference between this running on the
;; build host (the Mac, where elpaca has fetched everything) and on a machine
;; with a bare Emacs: the same command works on both, and reports what it did
;; not check instead of quietly reporting success.  Skips do not affect the exit
;; status; a compile failure does.

;;; Code:

(require 'seq)
(require 'subr-x)
;; Loaded up front so `byte-compile-error-on-warn' is a declared special
;; variable before it is bound below.  Without this, under lexical binding the
;; `let' creates a LEXICAL variable the compiler never consults, and warnings
;; would quietly stop being errors -- the build would pass on a file it should
;; have rejected.
(require 'bytecomp)

(defvar cp-root
  (expand-file-name ".." (file-name-directory
                          (or load-file-name buffer-file-name)))
  "The dotfiles checkout this driver belongs to.")

(defconst cp-packages
  '("agenda-feeds" "term-launcher" "vterm-reconnect" "llm-api-key")
  "Local package directories under emacs/lisp, relative to it.")

(defun cp-lisp-dir ()
  "The emacs/lisp directory."
  (expand-file-name "emacs/lisp" cp-root))

(defun cp-package-files (dir)
  "The .el files in DIR, tests excluded."
  (seq-remove (lambda (f) (string-match-p "-tests?\\.el\\'" f))
              (directory-files dir t "\\.el\\'")))

(defun cp-requires (files)
  "External libraries required by FILES, as symbols.
Only top-level `(require 'foo)' forms are read, which is what a byte-compile
actually needs resolved."
  (let (out)
    (dolist (file files)
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (while (re-search-forward "^(require '\\([^ )\n]+\\)" nil t)
          (push (intern (match-string 1)) out))))
    (delete-dups (nreverse out))))

(defun cp-elpaca-dirs ()
  "Every elpaca build directory on this machine, or nil.
The build host has the fetched packages; a bare Emacs does not, and that is
the case the skip path exists for."
  (let ((builds (expand-file-name "~/.emacs.d/elpaca/builds")))
    (when (file-directory-p builds)
      (seq-filter #'file-directory-p (directory-files builds t "\\`[^.]")))))

(defun cp-main ()
  "Compile every local package, and exit non-zero if any failed."
  (let ((lisp (cp-lisp-dir))
        (compiled 0) (failed nil) (skipped nil))
    (dolist (d (cp-elpaca-dirs)) (add-to-list 'load-path d))
    (dolist (name cp-packages)
      (add-to-list 'load-path (expand-file-name name lisp)))
    (dolist (name cp-packages)
      (let* ((dir (expand-file-name name lisp))
             (files (and (file-directory-p dir) (cp-package-files dir))))
        (cond
         ((null files) (push (cons name "no .el files") skipped))
         (t
          ;; A require of a sibling file in the same package resolves through
          ;; load-path above, so only genuinely external names can be missing.
          (let ((missing (seq-remove #'locate-library
                                     (mapcar #'symbol-name
                                             (cp-requires files)))))
            (if missing
                (push (cons name (string-join missing ", ")) skipped)
              ;; Compile a COPY, never the checkout.  `byte-compile-file'
              ;; writes the .elc beside its source, and this tree is the one
              ;; Emacs loads from, so compiling in place would leave a .elc
              ;; that is newer than its .el and gets loaded in preference to
              ;; it -- the stale-.elc trap, from a command whose only job was
              ;; to check that the source compiles.
              (let* ((stage (make-temp-file (concat "cp-" name "-") t))
                     (byte-compile-error-on-warn t))
                (unwind-protect
                    (progn
                      (add-to-list 'load-path stage)
                      (dolist (file files)
                        (copy-file file (expand-file-name
                                         (file-name-nondirectory file) stage)
                                   t))
                      (dolist (file files)
                        (if (byte-compile-file
                             (expand-file-name (file-name-nondirectory file)
                                               stage))
                            (setq compiled (1+ compiled))
                          (push (file-name-nondirectory file) failed))))
                  (setq load-path (delete stage load-path))
                  (delete-directory stage t)))))))))
    (princ (format "\ncompiled %d file(s)\n" compiled))
    (when skipped
      (princ "skipped:\n")
      (dolist (s (reverse skipped))
        (princ (format "  %-16s missing %s\n" (car s) (cdr s)))))
    (when failed
      (princ "FAILED:\n")
      (dolist (f (reverse failed)) (princ (format "  %s\n" f))))
    (kill-emacs (if failed 1 0))))

(cp-main)

;;; compile-packages.el ends here
