;;; Centralized file extension support for added packages. Uses the
;;; funcky `lambda' fn to prevent double entries (not that it makes a
;;; difference, but, hey, it is cool :-)
(mapcar (function (lambda (x) (add-to-list 'auto-mode-alist x)))
	'(("\\.C\\'"   . c++-mode)
	  ("\\.cc\\'"  . c++-mode)
	  ("\\.cpp\\'" . c++-mode)
	  ("\\.hh\\'"  . c++-mode)
	  ("\\.c\\'"   . c-mode)
	  ("\\.h\\'"   . c-mode)
	  ("\\.m\\'"   . objc-mode)
	  ("\\.html\\'". html-helper-mode)
	  ("\\.mak\\'" . makefile-mode)
	  ("\\.java\\'". java-mode)
	  ;;	  ("\\.fvwm.*rc\\'" . fvwm-mode)
	  ("Makefile"  . makefile-mode)
	  ("makefile"  . makefile-mode)))

(add-to-list 'interpreter-mode-alist '("sh"  . sh-mode))
(add-to-list 'interpreter-mode-alist '("csh" . csh-mode))

;; ---------------------------------------------------------------------
;; shell script editing modes
(autoload 'sh-mode "sh-script" "Generic Shell script editing mode" t)
