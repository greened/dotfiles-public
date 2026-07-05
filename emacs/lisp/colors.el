;; Old Emacs 23 colorizer

;;(require 'color-theme-autoloads "color-theme-autoloads")

;;(require 'zenburn)

;;(eval-after-load "color-theme"
;;  '(progn
;;     (color-theme-initialize)
;;     (color-theme-hober)))

;; New Emacs 24 colorizer

(add-to-list 'custom-theme-load-path
	     (concat emacs-root "/site-lisp/themes/hober2-theme"))
(load-theme `hober2 t)
