;; (use-package auth-source-pass
;;   :ensure t
;;   :config
;;   (auth-source-pass-enable))

; From https://www.emacswiki.org/emacs/GnusEncryptedAuthInfo
;(setq epa-file-cache-passphrase-for-symmetric-encryption t)

; From https://www.emacswiki.org/emacs/EasyPG
;; (defadvice epg--start (around advice-epg-disable-agent disable)
;;       "Don't allow epg--start to use gpg-agent in plain text
;;     terminals."
;;       (if (display-graphic-p)
;;           ad-do-it
;;         (let ((agent (getenv "GPG_AGENT_INFO")))
;;           (setenv "GPG_AGENT_INFO" nil) ; give us a usable text password prompt
;;           ad-do-it
;;           (setenv "GPG_AGENT_INFO" agent))))

;; (ad-enable-advice 'epg--start 'around 'advice-epg-disable-agent)
;; (ad-activate 'epg--start)
