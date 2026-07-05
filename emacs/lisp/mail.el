(add-to-list 'load-path "/usr/local/share/emacs/site-lisp/notmuch")

(require 'notmuch)


;; Available SMTP accounts.  Populated by private overlays.
;;
;; Each component of smtp-accounts has the form
;;
;;  (protocol  "adres_matched_in_From_field@foo.com"  "protocol.foo.com"  "port"  "user@foo.com" "password" "key" "cert")
;;
;; where KEY and CERT are optional. Setting PASSWORD to NIL will make
;; SMTPMAIL-SEND-IT prompt for a password before sending every
;; message. (More secure, more bugging.)
(defvar smtp-accounts nil
  "SMTP accounts used by `change-smtp'.  Overlays populate this.")

;; Accounts and associations for smtpmail-multi.  Populated by overlays.
(defvar smtpmail-multi-accounts nil)
(defvar smtpmail-multi-associations nil)

;; Set up TLS for mail.
(setq starttls-use-gnutls t
      starttls-gnutls-program "gnutls-cli"
      starttls-extra-arguments `("--tofu"))

;; Default smtpmail.el configurations.  Identity (name/address) is set by
;; a private overlay.

;; (setq send-mail-function 'smtpmail-send-it
;;      message-send-mail-function 'smtpmail-send-it
(setq send-mail-function 'smtpmail-multi-send-it
      message-send-mail-function 'smtpmail-multi-send-it
      mail-from-style `angles
      smtpmail-debug-info t
      smtpmail-debug-verb t)

(defun set-smtp (mech address server port user password)
  "Set related SMTP variables for supplied parameters."
  (setq smtpmail-smtp-server server
	;smtp-server server
	smtpmail-smtp-service port
	smtpmail-auth-credentials (list (list server port user password))
;	smtpmail-auth-credentials (expand-file-name "~/.authinfo.gpg")
	smtpmail-auth-supported (list mech)
	smtpmail-starttls-credentials nil
        smtpmail-mail-address address)
  (message "Setting SMTP server to `%s:%s' as `%s' for user `%s'."
	   server port address user))

(defun set-smtp-ssl (address server port type user password  &optional key cert)
  "Set related SMTP and SSL variables for supplied parameters."
  (setq starttls-use-gnutls t
	starttls-gnutls-program "gnutls-cli"
	smtpmail-smtp-server server
	;smtp-server server
	smtpmail-smtp-service port
        smtpmail-debug-verb t
        smtpmail-debug-info t
        smtpmail-local-domain nil
        ;smtpmail-stream-type type
	smtpmail-auth-credentials (list (list server port user password))
;	smtpmail-auth-credentials (expand-file-name "~/.authinfo.gpg")
	smtpmail-starttls-credentials (list (list server port key cert))
;	smtpmail-starttls-credentials (expand-file-name "~/.authinfo.gpg")
        smtpmail-mail-address address)
  (message
   "Setting SMTP server to `%s:%s' as `%s' for user `%s'. (SSL enabled.)"
   server port address user))

(defun change-smtp ()
  "Change the SMTP server according to the current from line."
  (save-excursion
    (loop with from = (save-restriction
			(message-narrow-to-headers)
			(message-fetch-field "from"))
	  for (auth-mech address . auth-spec) in smtp-accounts
	  when (string-match address from)
	  do (cond
	      ((memq auth-mech '(cram-md5 plain login))
	       (return (apply 'set-smtp (cons auth-mech (cons address auth-spec)))))
	      ((eql auth-mech 'ssl)
	       (return (apply 'set-smtp-ssl (cons address auth-spec))))
	      (t (error "Unrecognized SMTP auth. mechanism: `%s'." auth-mech)))
	  finally (error "Cannot infer SMTP information."))))

;; ;(setq smtpmail-debug-info 1)

;; Support Outlook .ics attachments
;; From http://permalink.gmane.org/gmane.emacs.gnus.general/82734

(setq mm-inlined-types '())
(setq mm-inline-media-tests '())

;; Outline sometimes makes the message body an attachment.
(add-to-list 'mm-inlined-types "text/plain")
(add-to-list 'mm-inline-media-tests '("text/plain" mm-inline-text identity))
(add-to-list 'mm-automatic-display "text/plain")

(add-to-list 'mm-inlined-types "text/html")
(add-to-list 'mm-inline-media-tests '("text/html" mm-inline-text-html identity))
(add-to-list 'mm-automatic-display "text/html")

(add-to-list 'mm-inlined-types "text/calendar")
(add-to-list 'mm-inline-media-tests '("text/calendar" mm-inline-text-calendar identity))
(add-to-list 'mm-automatic-display "text/calendar")

;; (add-to-list 'mm-attachment-override-types "image/.*")

(defun format-text-calendar-for-display (element)
  "Format a text/calendar element parsed by icalendar--read-element into text"
  (let ((fields '(LOCATION ORGANIZER DESCRIPTION))
        (fieldformat "%-11s %s\n")
        (content "")
        (first-date "")
        (last-date "")
        (title ""))
    (dolist (event (icalendar--all-events element))
      (let* ((zone-map (icalendar--convert-all-timezones element))
             (dtstart-zone (icalendar--find-time-zone (icalendar--get-event-property-attributes event
'DTSTART) zone-map))
             (dtstart (icalendar--decode-isodatetime (icalendar--get-event-property event 'DTSTART) nil dtstart-zone))
             (dtend-zone (icalendar--find-time-zone (icalendar--get-event-property-attributes event 'DTEND) zone-map))
             (dtend   (icalendar--decode-isodatetime (icalendar--get-event-property event 'DTEND) nil dtend-zone))
             (datestring (concat (icalendar--datetime-to-iso-date dtstart "-") " "
                                 (icalendar--datetime-to-colontime dtstart) "-"
                                 (icalendar--datetime-to-colontime dtend))))
        (when (string-equal first-date "")
          (setq first-date datestring))
        (setq last-date datestring)
        (dolist (field fields)
          (let ((propertyvalue (mapconcat (lambda (property)
                                            (icalendar--convert-string-for-import property)
                                            (replace-regexp-in-string "\\\\n" "\n"
                                                                      (replace-regexp-in-string "^MAILTO:" "" property)))
                                          (icalendar--get-event-properties event field) " ")))
            (when (not (string-equal propertyvalue ""))
              (setq content (concat content (format fieldformat field (replace-regexp-in-string "\\\\ " "" propertyvalue)))))))))
    (setq content (replace-regexp-in-string "\n\n$" "" content))
    (setq title (if (string-equal first-date last-date) first-date (concat first-date " ... " last-date)))
    (list content title)))

(defun mm-inline-text-calendar (handle)
  (let ((text ""))
    (with-temp-buffer
      (mm-insert-part handle)
      (save-window-excursion
        (setq info (mapcar (lambda (s) (mm-decode-string s "utf-8"))
                           (format-text-calendar-for-display (icalendar--read-element nil nil))))))
    (let ((start (point)))
      (mm-insert-inline handle "\n")
      (mm-insert-inline handle (car info))
      (mm-insert-inline handle "\n")
      (goto-char start)
      (when (search-forward "DESCRIPTION " nil t)
        (replace-match "" nil t)
        (beginning-of-line)
        (fill-region (point) (point-max)))
      (boxquote-region start (point-max)))
    (boxquote-title (car (cdr info)))
    (mm-insert-inline handle "\n")))

; Temporary fix for emacs-snapshot.
(defun gnus-nnir-group-p (group)
  "Say whether GROUP is nnir or not."
  (if (gnus-group-prefixed-p group)
      (eq 'nnir (car (gnus-find-method-for-group group)))
    (and group (string-match "^nnir" group))))

;; Make sure HTML e-mail is readable on a dark background.
(setq shr-color-visible-luminance-min 80)
