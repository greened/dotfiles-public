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
                    (funcall (intern (format "term-vterm-%s" name))))))))))

(terminal-bind-keys my-term-machine-alist)

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

(setq terminal-build-hydra-heads
      (terminal-generate-hydra-heads "vterm"
                                     my-term-machine-alist))

;; Create build hydra.
(eval `(defhydra terminal-hydra-build (:color blue :hint nil)
         ,@(append
            terminal-build-hydra-heads)))

(define-key (current-global-map) (kbd "C-c t") (lambda () (interactive) (terminal-hydra-build/body)))
