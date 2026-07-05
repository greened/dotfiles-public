(defun browse-url-mac-chrome (url &optional _new-window)
  "Open URL in Google Chrome.  I use AppleScript to do several things:
  1. I tell Chrome to come to the front. If Chrome wasn't launched, this will also launch it.
  2. If Chrome has no windows open, I tell it to create one.
  3. If Chrome has a tab showing URL, I tell it to reload the tab, make that tab the active tab in its window, and bring its window to the front.
  4. If Chrome has no tab showing URL, I tell Chrome to make a new tab (in the front window) showing URL."
  (when (symbolp url)
    ; User passed a symbol instead of a string.  Use the symbol name.
    (setq url (symbol-name url)))
  (do-applescript (format "
tell application \"Google Chrome\"
        activate
        set theUrl to %S

        if (count every window) = 0 then
                make new window
        end if

        set found to false
        set theTabIndex to -1
        repeat with theWindow in every window
                set theTabIndex to 0
                repeat with theTab in every tab of theWindow
                        set theTabIndex to theTabIndex + 1
                        if theTab's URL = theUrl then
                                set found to true
                                exit
                        end if
                end repeat

                if found then
                        exit repeat
                end if
        end repeat

        if found then
                tell theTab to reload
                set theWindow's active tab index to theTabIndex
                set index of theWindow to 1
        else
                tell window 1 to make new tab with properties {URL:theUrl}
        end if
end tell
  " url)))

;; (defun browse-url-mac-chrome (url &optional _new-window)
;;   "Browse URL in Chrome.

;; Chrome protocol URL such as chrome://newtab is supported,
;; unlike `browse-url-default-macosx-browser'."
;;   (interactive (browse-url-interactive-arg "URL: "))
;;   (do-applescript
;;    (mapconcat
;;     #'identity
;;     ;; https://apple.stackexchange.com/a/271709/132365
;;     `("set myLink to \"" ,url "\""
;;       "tell application \"Google Chrome\""
;;       "    activate"
;;       "    tell front window to make new tab at after (get active tab) with properties {URL:myLink}"
;;       "end tell")
;;     "\n")))

(cond
 ((memq window-system '(mac ns))
  (setq browse-url-browser-function 'browse-url-mac-chrome))
 (t
  (setq browse-url-browser-function 'w3m-browse-url)))

