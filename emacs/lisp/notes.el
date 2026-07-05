;; Org Mode settings
;; The following lines are always needed.  Choose your own keys.
;; (add-to-list 'auto-mode-alist '("\\.org\\'" . org-mode))
(global-set-key "\C-cl" 'org-store-link)
(global-set-key "\C-ca" 'org-agenda)
;; (global-set-key "\C-cb" 'org-iswitchb)

(add-hook 'org-mode-hook 'turn-on-font-lock)  ; Org buffers only

;; Enable clean mode
(setq org-startup-indented t)
