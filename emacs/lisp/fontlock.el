;; Font lock
;;(add-hook 'font-lock-mode-hook 'turn-on-lazy-lock)
(setq font-lock-maximum-decoration t)
(if (fboundp 'global-font-lock-mode)
    (global-font-lock-mode t)
)

;; rainbow identifiers and braces!
;;
;; https://github.com/Fanael/rainbow-identifiers
;;   alternative: color-identifiers
;;   https://github.com/ankurdave/color-identifiers-mode
;; https://github.com/jlr/rainbow-delimiters
;; http://amitp.blogspot.com/2014/04/emacs-rainbow-identifiers.html
;; https://medium.com/p/3a6db2743a1e/
;(add-hook 'prog-mode-hook 'rainbow-identifiers-mode)
;(add-hook 'prog-mode-hook 'rainbow-delimiters-mode)
