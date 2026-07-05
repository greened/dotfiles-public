;; ---------------------------------------------------------------------
;;; Keybindings
;; (if (equal (getenv "HOSTTYPE") "sun4")
;;     (load-library "sun4-keys"))

;; Translate keypad ups and downs
(define-key function-key-map [M-kp-up] [M-up])
(define-key function-key-map [M-kp-down] [M-down])
(define-key function-key-map [C-kp-up] [C-up])
(define-key function-key-map [C-kp-down] [C-down])

;; the following rebinds control-x control-b to the buffer-menu
;; command rather than the list-buffers command.  The buffer-menu
;; command not only lists the buffers, but selects the *buffer list*
;; for editing.
(define-key ctl-x-map "\C-b" 'buffer-menu)
(define-key ctl-x-map "\C-x" 'view-file)

(define-key esc-map "r" 'query-replace) ; ESC r/M-r

;; personal keybindings that use the c-c map (the `mode-specific-map'
;; is the map bound to `C-c')
;;(define-key mode-specific-map "l" 'goto-line)
;;(define-key mode-specific-map "w" 'what-line)
;;(define-key mode-specific-map "d" 'insert-date-at-point)
;;(define-key mode-specific-map "c" 'compile)
;;(define-key mode-specific-map "m" 'recompile)
;;(define-key mode-specific-map "q" 'comment-out-region) ; fn is loaded later


					; define key for copy
;;(global-set-key [?\C-.] 'kill-ring-save)
; Set sane keys on MacOS
(setq ns-function-modifier 'control)
(setq ns-control-modifier 'control)
(setq ns-option-modifier 'meta)
(setq ns-command-modifier 'meta)
