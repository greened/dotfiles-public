;(use-package faces+
;  :ensure t)

;;-bitstream-bitstream vera sans mono-medium-r-*-*-*-120-*-*-*-*-*-*

;; Comment out for windows.
(cond ((eq window-system 'w32)
       (set-face-attribute 'default nil :font "-*-Consolas-medium-r-*-*-*-120-*-*-*-*-*-*"))
      ((eq window-system 'ns)
       ;;(set-face-attribute 'default nil :font "hack nerd font mono-14")
       (set-face-attribute 'default nil :font "jetbrains mono-14")
       )
      (t (set-face-attribute 'default nil :font "bitstream vera sans mono-12")))

(setq-default line-spacing 0)

;; Highlight questionable whitespace
(setq whitespace-style
  '(face empty lines-tail trailing))
;; Highlight 80+ columns
(setq whitespace-line-column 80)
(global-whitespace-mode 1)

(defun font-is-mono-p (font-family)
  ;; with-selected-window
  (let ((wind (selected-window))
        m-width l-width)
   (with-output-to-temp-buffer "asdf"
     (set-window-buffer (selected-window) (current-buffer))
     (text-scale-set 4)
     (insert (propertize "l l l l l" 'face `((:family ,font-family))))
     (goto-char (line-end-position))
     (setq l-width (car (posn-x-y (posn-at-point))))
     (newline)
     (forward-line)
     (insert (propertize "m m m m m" 'face `((:family ,font-family) italic)))
     (goto-char (line-end-position))
     (setq m-width (car (posn-x-y (posn-at-point))))
     (eq l-width m-width))))

(defun compare-monospace-fonts ()
  "Display a list of all monospace font faces."
  (interactive)
  (pop-to-buffer "*Monospace Fonts*")

  (erase-buffer)
  (let ((str "The quick brown fox jumps over the lazy dog ´`''\"\"1lI|¦!Ø0Oo{[()]}.,:; ")
	(font-families (cl-remove-duplicates 
			(sort (font-family-list) 
			      (lambda(x y) (string< (upcase x) (upcase y))))
			:test 'string=)))
    (dolist (ff font-families)
      (when (font-is-mono-p ff)
	(insert
	 (propertize str 'font-lock-face `(:family ,ff))               ff "\n"
	 (propertize str 'font-lock-face `(:family ,ff :slant italic)) ff "\n")))))
