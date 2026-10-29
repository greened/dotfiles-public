;;; paredit-tests.el --- Tests for paredit in M-: -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; packages.el does not load in batch, so these tests read
;; `dag/paredit-eval-expression' out of it and run it against a stand-in
;; paredit. Run by ../../paredit-selftest.sh.

;;; Code:

(require 'ert)

(declare-function dag/paredit-eval-expression nil ())

(defconst paredit-tests--packages
  (expand-file-name "../../emacs/lisp/packages.el"
                    (file-name-directory
                     (or load-file-name buffer-file-name))))

(defvar paredit-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'newline)
    (define-key map (kbd "(") #'ignore)
    map)
  "A stand-in for paredit's map, which binds RET to insert a newline.")

(define-minor-mode paredit-mode
  "A stand-in for paredit."
  :keymap paredit-mode-map)

(defun paredit-tests--load ()
  "Evaluate `dag/paredit-eval-expression' from packages.el."
  (with-temp-buffer
    (insert-file-contents paredit-tests--packages)
    (condition-case nil
        (while t
          (let ((form (read (current-buffer))))
            (when (and (eq (car-safe form) 'defun)
                       (eq (nth 1 form) 'dag/paredit-eval-expression))
              (eval form t))))
      (end-of-file nil)))
  (unless (fboundp 'dag/paredit-eval-expression)
    (error "No dag/paredit-eval-expression in %s" paredit-tests--packages)))

(defmacro paredit-tests--in-minibuffer (&rest body)
  "Run BODY in a buffer keyed like the `M-:' minibuffer."
  `(with-temp-buffer
     (use-local-map read-expression-map)
     ,@body))

(ert-deftest paredit-tests-stand-in-takes-ret ()
  "Plain paredit in `M-:' takes RET, which is the bug being fixed."
  (paredit-tests--in-minibuffer
   (paredit-mode 1)
   (should (eq (key-binding (kbd "RET")) #'newline))))

(ert-deftest paredit-tests-ret-evaluates ()
  "RET in `M-:' keeps the minibuffer's own binding."
  (paredit-tests--load)
  (paredit-tests--in-minibuffer
   (dag/paredit-eval-expression)
   (should paredit-mode)
   (should (eq (key-binding (kbd "RET"))
               (lookup-key read-expression-map (kbd "RET"))))))

(ert-deftest paredit-tests-other-keys-stay-paredit ()
  "Paredit's other keys still apply in `M-:'."
  (paredit-tests--load)
  (paredit-tests--in-minibuffer
   (dag/paredit-eval-expression)
   (should (eq (key-binding (kbd "(")) #'ignore))))

(provide 'paredit-tests)

;;; paredit-tests.el ends here
