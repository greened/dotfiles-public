;;; term-launcher.el --- Launch terminals to remote hosts with a hydra picker -*- lexical-binding: t; -*-

;; Copyright (C) 2026 David Greene

;; Author: David Greene (with Claude Code)
;; Maintainer: David Greene
;; Version: 0.1.0
;; Keywords: terminals, unix, tools
;; URL: https://github.com/USER/term-launcher
;; Package-Requires: ((emacs "27.1") (vterm "0") (hydra "0") (bind-key "0") (tramp-term "0") (vterm-reconnect "0"))

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; Launch shells on the local host and on remote hosts over ssh -- in either
;; `vterm' or `ansi-term' -- and pick a target from a Hydra.
;;
;; Register targets in `term-launcher-machine-alist' as (HOST KEY) pairs.  Each
;; gets a `C-c <KEY>' binding (a vterm ssh session, or a local vterm for
;; "localhost") and an entry in the `C-c t' hydra.  For each non-localhost HOST,
;; `term-launcher-defterm' also defines `term-launcher-vterm-HOST',
;; `term-launcher-ansi-HOST', and `term-launcher-open-HOST' commands.
;;
;;   (require 'term-launcher)
;;   (add-to-list 'term-launcher-machine-alist '("work-host" "w"))
;;   (term-launcher-defterm "work-host")
;;   (term-launcher-bind-keys term-launcher-machine-alist)
;;
;; Stale forwarded sessions are respawned via the companion `vterm-reconnect'
;; package (C-c R); `term-launcher-bind-keys' points its default reconnect host
;; at the first non-localhost target.

;;; Code:

(require 'vterm-reconnect)
(require 'bind-key)
;; NOTE: `hydra' is required lazily (in `term-launcher-hydra-menu', bound to
;; C-c t) rather than here.  hydra is an elpaca (:ensure t) package loaded
;; asynchronously at after-init, so a top-level (require 'hydra) fails while this
;; package :demand-loads mid-init -- which aborts the whole config load.

(declare-function vterm "vterm" (&optional buffer-name))
(declare-function tramp-term "tramp-term" (&optional host))

(defgroup term-launcher nil
  "Launch terminals to local and remote hosts."
  :group 'processes
  :prefix "term-launcher-")

(defcustom term-launcher-domain nil
  "Optional domain suffix appended to host names for tramp-term hosts.
When nil, the bare host name is used."
  :type '(choice (const nil) string)
  :group 'term-launcher)

(defcustom term-launcher-machine-alist '(("localhost" "l"))
  "Alist of (HOST KEY) terminal targets."
  :type '(repeat (list string string))
  :group 'term-launcher)

;;;###autoload
(defun term-launcher-open-localhost ()
  "Open a local `ansi-term' bash shell."
  (interactive)
  (ansi-term "/bin/bash" "localhost"))

;;;###autoload
(defun term-launcher-vterm-localhost ()
  "Open a local `vterm'."
  (interactive)
  (vterm))

(defun term-launcher-remote-term (new-buffer-name cmd &rest switches)
  "Open an `ansi-term' running CMD with SWITCHES in a buffer named NEW-BUFFER-NAME."
  (let ((name (generate-new-buffer-name (concat "*" new-buffer-name "*"))))
    (setq name (apply #'make-term name cmd nil switches))
    (set-buffer name)
    (term-mode)
    (term-char-mode)
    (term-set-escape-char ?\^x)
    (switch-to-buffer name)))

(defun term-launcher--sync-reconnect-host ()
  "Default `vterm-reconnect-host' to the first non-localhost target, if unset."
  (unless vterm-reconnect-host
    (setq vterm-reconnect-host
          (catch 'h
            (dolist (p term-launcher-machine-alist)
              (unless (string= (nth 0 p) "localhost") (throw 'h (nth 0 p))))))))

;;;###autoload
(defun term-launcher-defterm (host)
  "Define `term-launcher-{ansi,vterm,open}-HOST' commands for HOST."
  (let ((tramp-host (if term-launcher-domain
                        (format "%s.%s" host term-launcher-domain)
                      (format "%s" host))))
    (eval `(defun ,(intern (format "term-launcher-ansi-%s" host)) ()
             (interactive)
             (tramp-term '(,tramp-host))))
    (eval `(defun ,(intern (format "term-launcher-vterm-%s" host)) ()
             (interactive)
             (vterm-ssh ,(format "%s" host))))
    (eval `(defun ,(intern (format "term-launcher-open-%s" host)) ()
             (interactive)
             (,(intern (format "term-launcher-vterm-%s" host)))))))

(defun term-launcher--generate-hydra-heads (name machine-alist)
  "Build Hydra heads (labelled NAME) from MACHINE-ALIST."
  (let ((result '()))
    (dolist (item machine-alist result)
      (let* ((machine (nth 0 item))
             (key (nth 1 item))
             (column (format "%s" name)))
        ;; Hydra head: (KEY FUNC DESC :column COLUMN)
        (setq result (append result
                             `((,key
                                ,(key-binding (kbd (concat "C-c " key)))
                                ,machine
                                :column ,column))))))))

(defun term-launcher--rebuild-hydra (machine-alist)
  "(Re)build the `C-c t' hydra from MACHINE-ALIST.
Run after the keys are bound so each head picks up its `C-c <key>' binding."
  (eval `(defhydra term-launcher-hydra (:color blue :hint nil)
           ,@(term-launcher--generate-hydra-heads "vterm" machine-alist))))

;;;###autoload
(defun term-launcher-bind-keys (machine-alist)
  "Bind `C-c <KEY>' for each target in MACHINE-ALIST, and rebuild the hydra.
Also syncs the `vterm-reconnect' default host to the first non-localhost target."
  (dolist (item machine-alist)
    (let* ((name (nth 0 item))
           (key (nth 1 item)))
      (bind-key (concat "C-c " key)
                (cond
                 ((string= name "localhost")
                  (lambda () (interactive) (term-launcher-vterm-localhost)))
                 (t
                  (lambda () (interactive)
                    (funcall (intern (format "term-launcher-vterm-%s" name)))))))))
  ;; The C-c t hydra is (re)built lazily on first use (see
  ;; `term-launcher-hydra-menu'), so it always reflects the current alist and
  ;; nothing here depends on hydra being loaded.
  (term-launcher--sync-reconnect-host))

;; Define per-host commands + bind keys for the default targets, and bind the
;; `C-c t' hydra.  Overlays add targets and re-run `term-launcher-defterm' /
;; `term-launcher-bind-keys' via `(with-eval-after-load 'term-launcher ...)'.
(dolist (host-pair term-launcher-machine-alist)
  (let ((host (nth 0 host-pair)))
    (unless (string= host "localhost")
      (term-launcher-defterm host))))

;; C-c t builds the hydra on first use (lazily requiring `hydra'), so nothing at
;; load time depends on hydra being available.
(defun term-launcher-hydra-menu ()
  "Open the terminal picker, (re)building it from `term-launcher-machine-alist'."
  (interactive)
  (require 'hydra)
  (term-launcher--rebuild-hydra term-launcher-machine-alist)
  (term-launcher-hydra/body))

(term-launcher-bind-keys term-launcher-machine-alist)

(define-key (current-global-map) (kbd "C-c t") #'term-launcher-hydra-menu)

(provide 'term-launcher)
;;; term-launcher.el ends here
