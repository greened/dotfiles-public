; try to improve slow performance on windows.
(setq w32-get-true-file-attributes nil)

;; ---------------------------------------------------------------------
;;; all sorts of options
(setq require-final-newline nil	; ask user to add a newline at the end

      ;;      next-line-add-newlines nil	; don't add newlines past end-of-buffer

      find-file-existing-other-name t ; check if file is open with another
					; name in another buffer

      ;;      make-backup-files nil		; shut off *~ files

      ;;      inhibit-startup-message t         ; inhibits the initial startup message

      ;;      c-recognize-knr-p nil		; speeds up `cc-mode' somewhat

      search-highlight t	   ; incremental search highlights the
					; current match

      query-replace-highlight t         ; highlight words during query
					; replacement

      track-eol t		     ; vertical motion starting at end
					; of line keeps to ends of lines.

      sentence-end-double-space t   ; break a line even after a period

      display-time-24hr-format nil)   ; display time with am/pm suffix

;;(if (fboundp 'set-scroll-bar-mode)
;;    (set-scroll-bar-mode 'right))	; put scrollbar on right for Emacs 20.x

;;(setq scroll-bar-mode 'right)	; put scrollbar on right for Emacs 20.x

(setq-default default-justification
	      'left)		 ; The requested kind of justification
					; is done whenever lines are filled.

;; ---------------------------------------------------------------------

(setq frame-title-format "%f")

;; Default mode is text-mode
(setq-default default-major-mode 'text-mode)

;;; regular expression for temp files - it's really very simple
(setq server-temp-file-regexp
      "\\(.*/tmp/.*\\|\\(.*/\\)?\.\\(article\\|letter\\)\\)$")
;; ---------------------------------------------------------------------

;; Turn off annoying beeps
(setq visible-bell t)

;; Format the frame title so we know where we are
(setq frame-title-format (list "emacs@" (getenv "HOST") " - %b [%f]"))

;; Do not auto-save
(setq auto-save-default nil)

;; Inline images
;; (add-to-list 'mm-attachment-override-types "image/.*")

;; Don't start a browser for text/html only mails
(setq mm-automatic-display
      '("text/plain" "text/enriched" "text/richtext"
	"image/.*" "message/delivery-status" "multipart/.*" "message/rfc822"
	"text/x-patch" "application/pgp-signature" "application/emacs-lisp"))
