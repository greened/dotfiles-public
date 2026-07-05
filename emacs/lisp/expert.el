;; ---------------------------------------------------------------------
;; disable some novice confirmation features

					; Enable these commands 
(put 'upcase-region 'disabled nil)
(put 'downcase-region 'disabled nil)
(put 'eval-expression 'disabled nil)
(put 'erase-buffer 'disabled nil)
(put 'narrow-to-region 'disabled nil)
(put 'narrow-to-page 'disabled nil)
(put 'set-goal-column 'disabled nil)

(fset 'yes-or-no-p 'y-or-n-p)
(setq disabled-command-hook nil)
(setq dired-no-confirm
      '(byte-compile chgrp chmod chown compress copy delete hardlink
		     load move print shell symlink uncompress))
(define-key query-replace-map [return] 'act)
(define-key query-replace-map "\C-m" 'act)

(cond ( ( >= emacs-major-version 21 )
	(menu-bar-mode 0)          ;; Disable non-GUI menus
	(tool-bar-mode 0)          ;; Disable iconic tool bar
	(tooltip-mode 0)           ;; Disable iconic tool tips
	) )
