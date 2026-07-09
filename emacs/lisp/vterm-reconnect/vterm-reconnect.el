;;; vterm-reconnect.el --- Respawn a stale ssh vterm in one command -*- lexical-binding: t; -*-

;; Copyright (C) 2026 David Greene

;; Author: David Greene (with Claude Code)
;; Maintainer: David Greene
;; Version: 0.1.0
;; Keywords: terminals, processes, unix
;; URL: https://github.com/USER/vterm-reconnect
;; Package-Requires: ((emacs "27.1") (vterm "0"))

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
;; Open ssh sessions in `vterm', and -- the point of this package -- respawn one
;; that has gone stale in a single command.
;;
;; The motivating case: you keep a long-lived `vterm' ssh'd into a work host, and
;; that connection carries a `RemoteForward' tunnel (e.g. forwarding your local
;; Emacs server port back to the remote so remote `emacsclient' reaches your
;; local Emacs).  When the tunnel's socket dies, the vterm is still "alive" but
;; useless.  `vterm-reconnect' tears down the dead session and starts a fresh
;; one in one keystroke:
;;
;;   (require 'vterm-reconnect)
;;   (setq vterm-reconnect-host "user@host")   ; the host you keep reconnecting
;;   (global-set-key (kbd "C-c R") #'vterm-reconnect-default)
;;
;; Commands:
;;   `vterm-ssh'               open a new vterm and ssh to a host
;;   `vterm-reconnect'         kill any live vterm/term buffer(s) for a host,
;;                             then open a fresh ssh vterm to it
;;   `vterm-reconnect-default' reconnect `vterm-reconnect-host'
;;
;; Run these locally in your Emacs; do not drive `vterm-reconnect' over the very
;; socket it is rebuilding.

;;; Code:

(declare-function vterm "vterm" (&optional buffer-name))
(declare-function vterm-send-string "vterm" (string &optional paste-p))

(defgroup vterm-reconnect nil
  "Respawn a stale ssh vterm in one command."
  :group 'vterm
  :prefix "vterm-reconnect-")

(defcustom vterm-reconnect-host nil
  "Default host for `vterm-reconnect-default'.
A string such as \"user@host\", or nil to be prompted."
  :type '(choice (const :tag "Prompt" nil) string)
  :group 'vterm-reconnect)

;;;###autoload
(defun vterm-ssh (host)
  "Open a new `vterm' named after HOST and ssh into it."
  (interactive "sSSH host: ")
  (let ((name (generate-new-buffer-name (concat "*" host "*"))))
    (vterm name)
    (vterm-send-string (format "ssh %s\n" host))))

;;;###autoload
(defun vterm-reconnect (host)
  "Kill any existing *HOST* vterm buffer(s) and open a fresh ssh vterm to HOST.
Handy when a forwarded connection goes stale (e.g. an Emacs-server
`RemoteForward' whose socket died): one command tears down the dead session and
starts a new one.  Run this locally in Emacs; do not drive it over the very
socket it is rebuilding."
  (interactive (list (or vterm-reconnect-host
                         (read-string "Reconnect host: "))))
  ;; vterm title-tracking (`vterm-buffer-name-string') renames the buffer to
  ;; e.g. "vterm user@host: ~", so match the host as a substring of any
  ;; vterm/term buffer rather than the original "*HOST*" name.
  (dolist (b (buffer-list))
    (let ((n (buffer-name b)))
      (when (and n (string-match-p (regexp-quote host) n)
                 (with-current-buffer b (derived-mode-p 'vterm-mode 'term-mode)))
        (let ((kill-buffer-query-functions nil))   ; don't prompt about the live process
          (ignore-errors (kill-buffer b))))))
  (vterm-ssh host))

;;;###autoload
(defun vterm-reconnect-default ()
  "Reconnect the default forwarding host (see `vterm-reconnect-host')."
  (interactive)
  (unless vterm-reconnect-host
    (user-error "No reconnect host configured (set `vterm-reconnect-host')"))
  (vterm-reconnect vterm-reconnect-host))

(provide 'vterm-reconnect)
;;; vterm-reconnect.el ends here
