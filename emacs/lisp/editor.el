;(require 'smart-tab)
;(global-smart-tab-mode 0)

(setq bidi-paragraph-direction 'left-to-right)

(if (version<= "27.1" emacs-version)
    (setq bidi-inhibit-bpa t))

(if (version<= "27.1" emacs-version)
    (global-so-long-mode 1))
