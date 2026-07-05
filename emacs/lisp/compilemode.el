
; Have compile mode scroll until the first error.
;;(setq compilation-scroll-output 'first-error)
;;(setq compilation-auto-jump-to-first-error 1)

(setq compilation-error-regexp-alist '(clang-include gcc-include gnu))

(defun notify-compilation-result(buffer msg)
  "Notify that the compilation is finished,
close the *compilation* buffer if the compilation is successful,
and set the focus back to Emacs frame"
  (if (string-match "^finished" msg)
    (progn
     ;;(delete-windows-on buffer)
     (tooltip-show "\n Compilation Successful :-) \n "))
    (tooltip-show "\n Compilation Failed :-( \n "))
  (setq current-frame (car (car (cdr (current-frame-configuration)))))
  (select-frame-set-input-focus current-frame)
  )

;; (add-to-list 'compilation-finish-functions
;; 	     'notify-compilation-result)
