;;; term-launcher.el --- Launch terminals to remote hosts from a C-c t prefix -*- lexical-binding: t; -*-

;; Copyright (C) 2026 David Greene

;; Author: David Greene (with Claude Code)
;; Maintainer: David Greene
;; Version: 0.1.0
;; Keywords: terminals, unix, tools
;; URL: https://github.com/USER/term-launcher
;; Package-Requires: ((emacs "27.1") (vterm "0") (tramp-term "0") (vterm-reconnect "0"))

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
;; Launch shells on the local host and on remote hosts over ssh, in either
;; `vterm' or `ansi-term', from a `C-c t' prefix.
;;
;; Register targets in `term-launcher-machine-alist' as (HOST KEY) pairs.  Each
;; gets a `C-c t <KEY>' binding: a vterm ssh session, or a local vterm for
;; "localhost".  With `which-key' enabled, `C-c t' then a pause lists them.  For
;; each non-localhost HOST, `term-launcher-defterm' also defines
;; `term-launcher-vterm-HOST', `term-launcher-ansi-HOST', and
;; `term-launcher-open-HOST' commands.
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

(require 'term)             ; ansi-term, term-mode, term-char-mode
(require 'vterm-reconnect)

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
  "Open an `ansi-term' running CMD with SWITCHES.
The buffer is named NEW-BUFFER-NAME."
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

;; A prefix key IS a key whose binding is a keymap, so this one map is what
;; makes `C-c t' a prefix; no minor mode is needed to own it.  Targets live
;; under the prefix (`C-c t l') rather than at top level (`C-c l'), which is
;; what keeps them clear of the crowded global `C-c <letter>' space -- org
;; claims `C-c l' for `org-store-link' from its deferred :config, so a
;; top-level binding here lost the moment an org file was opened.
;;
;; `defvar', so reloading this file leaves an existing map (and anything the
;; user added to it) in place; `term-launcher-bind-keys' then defines onto the
;; live map.
(defvar term-launcher-command-map (make-sparse-keymap "term-launcher")
  "Keymap for terminal targets, bound to the `C-c t' prefix.
Each target in `term-launcher-machine-alist' gets its KEY here.")

(defun term-launcher--target-command (host)
  "The command symbol opening a vterm on HOST.
`term-launcher-defterm' defines these for remote hosts; localhost has its own."
  (if (string= host "localhost")
      #'term-launcher-vterm-localhost
    (intern (format "term-launcher-vterm-%s" host))))

;;;###autoload
(defun term-launcher-bind-keys (machine-alist)
  "Bind each target in MACHINE-ALIST to its KEY in `term-launcher-command-map'.
Also syncs the `vterm-reconnect' default host to the first non-localhost target.

Binds the target's named command directly.  It deliberately does NOT look the
command up from a global binding: doing that let an unrelated package that had
taken the same `C-c <key>' silently become the target's command."
  (dolist (item machine-alist)
    (let ((host (nth 0 item))
          (key (nth 1 item)))
      (define-key term-launcher-command-map (kbd key)
                  (term-launcher--target-command host))))
  (term-launcher--sync-reconnect-host))

;; Define per-host commands + bind keys for the default targets.  Overlays add
;; targets and re-run `term-launcher-defterm' / `term-launcher-bind-keys' via
;; `(with-eval-after-load 'term-launcher ...)'.
(dolist (host-pair term-launcher-machine-alist)
  (let ((host (nth 0 host-pair)))
    (unless (string= host "localhost")
      (term-launcher-defterm host))))

(term-launcher-bind-keys term-launcher-machine-alist)

;; Binding the map itself is what makes `C-c t' a prefix.  With `which-key' on,
;; `C-c t' then a pause lists the targets by command name, which is what the
;; picker menu used to be for.
(define-key (current-global-map) (kbd "C-c t") term-launcher-command-map)

(provide 'term-launcher)
;;; term-launcher.el ends here
