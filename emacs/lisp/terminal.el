;; -*- lexical-binding: t -*-

;(defun track-shell-directory/procfs ()
;  (shell-dirtrack-mode 0)
;  (add-hook 'comint-preoutput-filter-functions
;	    (lambda (str)
;	      (prog1 str
;		(when (string-match comint-prompt-regexp str)
;		  (cd (file-symlink-p
;		       (format "/proc/%s/cwd" (process-id
;					       (get-buffer-process
;						(current-buffer)))))))))
;	    nil t))

;(add-hook 'shell-mode-hook 'track-shell-directory/procfs)


;; desktop-files-not-to-save defaults to "\\(^/[^/:]*:\\|(ftp)$\\)"
;; but that breaks tramp saving tramp dired (and tramp files?).
;; Basically, save everything. This could slow down startup.
(setq desktop-files-not-to-save "^$")

; Make emacsclient work remotely.
;(require 'remote-emacsclient)
;(update-tramp-emacs-server-port-forward tramp-default-method)

;; Overlay-settable configuration.  Private overlays populate these to add
;; remote hosts and, optionally, a domain suffix for tramp-term hosts.
(defvar my-term-domain nil
  "Optional domain suffix appended to host names in `defterm' tramp-term.
When nil, the bare host name is used.")

(defvar my-term-machine-alist '(("localhost" "l"))
  "Alist of (HOST KEY) terminal targets.  Overlays add entries.")

(defun open-localhost ()
  (interactive)
  (ansi-term "/bin/bash" "localhost"))

(defun vterm-localhost ()
  (interactive)
  (vterm))

;; Use this for remote so I can specify command line arguments
(defun remote-term (new-buffer-name cmd &rest switches)
  (setq term-ansi-buffer-name (concat "*" new-buffer-name "*"))
  (setq term-ansi-buffer-name (generate-new-buffer-name term-ansi-buffer-name))
  (setq term-ansi-buffer-name (apply 'make-term term-ansi-buffer-name cmd nil switches))
  (set-buffer term-ansi-buffer-name)
  (term-mode)
  (term-char-mode)
  (term-set-escape-char ?\^x)
  (switch-to-buffer term-ansi-buffer-name))

(defun vterm-ssh (host)
  (setq term-vterm-buffer-name (concat "*" host "*"))
  (setq term-vterm-buffer-name (generate-new-buffer-name term-vterm-buffer-name))
  (vterm term-vterm-buffer-name)
  (vterm-send-string (format "ssh %s\n" host)))

(defvar my-term-reconnect-host nil
  "Host for `vterm-reconnect-default'.
When nil, the first non-localhost entry in `my-term-machine-alist' is used.")

(defun my-term--default-reconnect-host ()
  "The host `vterm-reconnect-default' targets."
  (or my-term-reconnect-host
      (catch 'h
        (dolist (p my-term-machine-alist)
          (unless (string= (nth 0 p) "localhost") (throw 'h (nth 0 p)))))))

(defun vterm-reconnect (host)
  "Kill any existing *HOST* vterm buffer(s) and open a fresh ssh vterm to HOST.
Handy when a forwarded connection goes stale (e.g. an Emacs-server
`RemoteForward' whose socket died): one command tears down the dead session and
starts a new one.  Run this locally in Emacs; do not drive it over the very
socket it is rebuilding."
  (interactive (list (or (my-term--default-reconnect-host)
                         (read-string "Reconnect host: "))))
  ;; vterm title-tracking (`vterm-buffer-name-string') renames the buffer to
  ;; e.g. "vterm dgreene@dgreene-vm.cerebras.aws: ~", so match the host as a
  ;; substring of any vterm/term buffer rather than the original "*HOST*" name.
  (dolist (b (buffer-list))
    (let ((n (buffer-name b)))
      (when (and n (string-match-p (regexp-quote host) n)
                 (with-current-buffer b (derived-mode-p 'vterm-mode 'term-mode)))
        (let ((kill-buffer-query-functions nil))   ; don't prompt about the live process
          (ignore-errors (kill-buffer b))))))
  (vterm-ssh host))

(defun vterm-reconnect-default ()
  "Reconnect the default forwarding host (see `my-term-reconnect-host')."
  (interactive)
  (let ((host (my-term--default-reconnect-host)))
    (unless host (user-error "No reconnect host configured (set `my-term-reconnect-host')"))
    (vterm-reconnect host)))

(defun defterm (host)
  (let ((tramp-host (if my-term-domain
                        (format "%s.%s" host my-term-domain)
                      (format "%s" host))))
    (eval `(defun ,(intern (format "term-ansi-%s" host)) ()
             (interactive)
             (tramp-term '(,tramp-host))))
    (eval `(defun ,(intern (format "term-vterm-%s" host)) ()
             (interactive)
             (vterm-ssh ,(format "%s" host))))
    (eval `(defun ,(intern (format "open-%s" host)) ()
             (interactive)
             (,(intern (format "term-vterm-%s" host)))))))

(dolist (host-pair my-term-machine-alist)
  (let ((host (nth 0 host-pair)))
    (when (not (string= host "localhost"))
      (defterm host))))

(defun terminal-generate-hydra-heads (name machine-alist)
  (let ((result '()))
    (dolist (item machine-alist result)
      (let* ((machine (nth 0 item))
             (key (nth 1 item))
             (column (format "%s" name)))
        ;; Hydra head: (KEY FUNC DESC :column COLUMN)
        (setq result (append result
                             `((,key
                                ,(key-binding
                                  (kbd (concat "C-c " key)))
                                ,machine
                                :column
                                ,column))))))))

(defun terminal-rebuild-hydra (machine-alist)
  "(Re)build the `C-c t' terminal hydra from MACHINE-ALIST.
Run after the keys are bound so each head picks up its `C-c <key>' binding."
  (eval `(defhydra terminal-hydra-build (:color blue :hint nil)
           ,@(terminal-generate-hydra-heads "vterm" machine-alist))))

(defun terminal-bind-keys (machine-alist)
  (dolist (item machine-alist)
    (let* ((name (nth 0 item))
           (key (nth 1 item)))
      (bind-key (concat "C-c " key)
                (cond
                 ((string= name "localhost")
                  (lambda ()
                   (interactive)
                   (vterm-localhost)))
                 (t
                  (lambda ()
                    (interactive)
                    (funcall (intern (format "term-vterm-%s" name)))))))))
  ;; Rebuild the hydra too, so an overlay that adds hosts and re-runs this gets
  ;; them in `C-c t', not just the direct `C-c <key>' binding.
  (terminal-rebuild-hydra machine-alist))

(terminal-bind-keys my-term-machine-alist)

(define-key (current-global-map) (kbd "C-c t") (lambda () (interactive) (terminal-hydra-build/body)))

;; Reconnect the default forwarding host (kills its stale vterm, opens a fresh
;; one).  Invoke locally when a forwarded socket has gone stale.
(define-key (current-global-map) (kbd "C-c R") #'vterm-reconnect-default)

;; Provide the feature so overlays can register terminals with
;; `(with-eval-after-load 'terminal ...)' — without this, that hook never fires
;; (the base loads this file but the symbol form waits on `featurep').
(provide 'terminal)
