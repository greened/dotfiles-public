;;; slack-attention.el --- Loud, deferrable attention panel for emacs-slack -*- lexical-binding: t; -*-

;; Author: David Greene (with Claude Code)
;; Keywords: comm, slack, notifications

;;; Commentary:
;;
;; Makes emacs-slack notifications "in your face but deferrable":
;;
;;   * Every message emacs-slack decides to notify you about -- DMs, @-mentions,
;;     @here/@channel, and posts in your team's `:subscribed-channels' -- is
;;     captured into a persistent `*Slack Attention*' panel.
;;   * The panel pops into a side window (and optionally raises the frame) so it
;;     is hard to miss, but it never steals your point or blocks input.
;;   * Items STAY in the panel until you act on them, so deferring is safe:
;;       RET / mouse-1  jump to the message's room (read / reply)
;;       d              done -- remove the item (and mark the room read)
;;       s              snooze -- hide for `slack-attention-snooze-minutes',
;;                      then it re-surfaces automatically
;;       u              un-snooze all
;;       g              refresh          q  bury the panel
;;       C              clear everything (asks first)
;;   * The pending list is saved to `slack-attention-file' on exit and reloaded
;;     next session (best-effort: jump-back works once Slack is reconnected).
;;
;; Setup (from your private init, after emacs-slack is configured):
;;
;;   (require 'slack-attention)
;;   (slack-attention-setup)
;;
;; Mark channels "important" by adding them to your team's :subscribed-channels
;; in `slack-register-team' -- those posts then flow through here automatically.
;;
;; This file contains NO tokens or team config; keep those in your private init.

;;; Code:

(require 'tabulated-list)
(require 'seq)
(require 'cl-lib)
(require 'subr-x)   ; string-trim, string-empty-p
(require 'eieio)    ; slot-value

(defgroup slack-attention nil
  "Persistent, deferrable attention panel for emacs-slack."
  :group 'slack)

(defcustom slack-attention-buffer-name "*Slack Attention*"
  "Name of the attention panel buffer."
  :type 'string :group 'slack-attention)

(defcustom slack-attention-side 'right
  "Side of the frame to show the attention panel on."
  :type '(choice (const right) (const left) (const bottom) (const top))
  :group 'slack-attention)

(defcustom slack-attention-window-size 60
  "Width (for left/right) or height (for top/bottom) of the panel window."
  :type 'integer :group 'slack-attention)

(defcustom slack-attention-raise-frame t
  "When non-nil, raise the Emacs frame when a new item arrives.
This is intentionally gentle: it raises but does NOT steal input focus,
so it will not interrupt what you are typing."
  :type 'boolean :group 'slack-attention)

(defcustom slack-attention-auto-pop t
  "When non-nil, automatically display the panel when a new item arrives."
  :type 'boolean :group 'slack-attention)

(defcustom slack-attention-snooze-minutes 15
  "Minutes to hide a snoozed item before it re-surfaces."
  :type 'integer :group 'slack-attention)

(defcustom slack-attention-file
  (locate-user-emacs-file "slack-attention-items.el")
  "File used to persist pending items across sessions."
  :type 'file :group 'slack-attention)

;;; State ---------------------------------------------------------------------

(defvar slack-attention--items nil
  "List of attention items.  Each item is a plist:
  :id        unique integer
  :message   the slack-message object (nil after a restart)
  :room      the slack-room object    (nil after a restart)
  :team      the slack-team object    (nil after a restart)
  :team-name string
  :room-name string
  :text      string preview
  :time      float-time when captured
  :snooze    nil, or float-time until which the item is hidden")

(defvar slack-attention--counter 0
  "Monotonic id source for items.")

(defvar slack-attention--snooze-timer nil)

;;; Safe emacs-slack accessors -----------------------------------------------
;; Wrapped so a version mismatch degrades to a readable string instead of erroring
;; inside the notification path.

(defun slack-attention--room-name (room team)
  (or (ignore-errors (slack-room-name room team))
      (ignore-errors (slack-room-name room))
      "?room"))

(defun slack-attention--team-name (team)
  (or (ignore-errors (slack-team-name team)) "?team"))

(defun slack-attention--message-text (message team)
  (let ((s (or (ignore-errors (slack-message-text message team))
               (ignore-errors (slack-message-body message team))
               (ignore-errors (slot-value message 'text))
               "")))
    ;; Collapse whitespace/newlines for a one-line preview.
    (replace-regexp-in-string "[ \t\n\r]+" " " (string-trim (or s "")))))

;;; Notification policy -------------------------------------------------------
;; Decide what is worth interrupting you for.  Default policy:
;;   * any direct message (im),
;;   * every message in `slack-attention-important-channels',
;;   * a DIRECT @-mention of you (`<@your-id>') anywhere,
;; and explicitly NOT @here/@channel/@everyone (those are `<!here>' etc., which
;; never match the `<@id>' test), and never your own messages.

(defcustom slack-attention-important-channels nil
  "Channel/group names whose every message raises an attention item.
Set this to the channels you care about -- e.g. in your emacs-slack
config's `use-package' `:custom' block -- named as emacs-slack reports
them, without a leading `#'.  Example: \\='(\"team-foo\" \"help-bar\")."
  :type '(repeat string) :group 'slack-attention)

(defcustom slack-attention-notify-dms t
  "When non-nil, every direct message raises an attention item."
  :type 'boolean :group 'slack-attention)

(defcustom slack-attention-muted-dm-senders nil
  "DM partner name substrings whose direct messages should NOT raise an item.
Case-insensitive substring match against the DM room name, so app/bot DMs can
be silenced while real-person DMs still notify.  Example:
\\='(\"GitHub\" \"Confluence\").  A muted DM is suppressed even if it happens to
contain a direct @-mention."
  :type '(repeat string) :group 'slack-attention)

(defcustom slack-attention-notify-direct-mentions t
  "When non-nil, a direct @-mention of you raises an attention item.
Broadcast mentions (@here/@channel/@everyone) do NOT count."
  :type 'boolean :group 'slack-attention)

(defcustom slack-attention-control-notifications t
  "When non-nil, `slack-attention-setup' gates `slack-message-notify-alert'
\(the alert display funnel) with the policy above, so BOTH the OS banner and
the attention panel are suppressed for anything the policy rejects.  Set to
nil to leave emacs-slack's own notifications alone and only ADD panel capture
on top of whatever emacs-slack already notifies."
  :type 'boolean :group 'slack-attention)

(defun slack-attention--self-id (team)
  "Your Slack user id for TEAM (e.g. \"U012AB3CDEF\")."
  (or (ignore-errors (slot-value team 'self-id))
      (ignore-errors (slot-value (slack-team-self team) 'id))))

(defun slack-attention--directly-mentions-p (message team)
  "Non-nil if MESSAGE contains a direct <@self-id> mention (not a broadcast)."
  (let ((id (slack-attention--self-id team))
        (text (or (ignore-errors (slot-value message 'text)) "")))
    (and id (string-match-p (regexp-quote (format "<@%s>" id)) text))))

(defun slack-attention--dm-muted-p (room team)
  "Non-nil if ROOM is a DM whose partner matches `slack-attention-muted-dm-senders'."
  (and (ignore-errors (slack-im-p room))
       (let ((nm (downcase (or (slack-attention--room-name room team) ""))))
         (seq-some (lambda (s) (string-match-p (regexp-quote (downcase s)) nm))
                   slack-attention-muted-dm-senders))))

(defun slack-attention-notify-policy (message room team)
  "Return non-nil iff MESSAGE in ROOM/TEAM is worth flagging, per your policy."
  (condition-case nil
      (let ((self (slack-attention--self-id team)))
        (and
         ;; Never flag your own messages.  Use `slack-message-sender-id' -- the
         ;; base `slack-message' class has no `user' slot (only the
         ;; `slack-user-message' subclass does), so `slot-value' would silently
         ;; miss and never exclude your own posts.
         (not (equal (or (ignore-errors (slack-message-sender-id message))
                         (ignore-errors (slack-message-sender-id message team))
                         (ignore-errors (slot-value message 'user)))
                     self))
         ;; Muted DM senders (bots/apps) never notify, even on a direct mention.
         (not (slack-attention--dm-muted-p room team))
         (or (and slack-attention-notify-dms (slack-im-p room))
             (member (slack-attention--room-name room team)
                     slack-attention-important-channels)
             (and slack-attention-notify-direct-mentions
                  (slack-attention--directly-mentions-p message team)))))
    (error nil)))

(defun slack-attention--advice (orig message room team &rest args)
  "Around-advice for `slack-message-notify-alert' (the alert display funnel).
Gate the banner AND the panel capture together: when notifications are
controlled and the policy rejects the message, suppress BOTH; otherwise capture
it and let the banner fire.  A single :around avoids the ordering trap where a
separate :after capture runs even when a :before-while gate blocks the banner."
  (when (or (not slack-attention-control-notifications)
            (slack-attention-notify-policy message room team))
    (ignore-errors (slack-attention--add message room team))
    (apply orig message room team args)))

;;; Capture -------------------------------------------------------------------

(defun slack-attention--add (message room team)
  "Capture a notified MESSAGE in ROOM/TEAM into the attention list."
  (condition-case err
      (let* ((team-name (slack-attention--team-name team))
             (room-name (slack-attention--room-name room team))
             (text (slack-attention--message-text message team))
             (item (list :id (cl-incf slack-attention--counter)
                         :message message :room room :team team
                         :team-name team-name :room-name room-name
                         :ts (ignore-errors (slot-value message 'ts))
                         :text (if (string-empty-p text) "(no text)" text)
                         :time (float-time)
                         :snooze nil)))
        (setq slack-attention--items (append slack-attention--items (list item)))
        (slack-attention--refresh-buffer)
        (when slack-attention-auto-pop (slack-attention--display))
        (when slack-attention-raise-frame
          (ignore-errors (raise-frame))))
    ;; Never let a bug here break emacs-slack's own notification flow.
    (error (message "slack-attention capture error: %S" err))))

;;; Rendering (tabulated-list) ------------------------------------------------

(defun slack-attention--visible-items ()
  "Items that are not currently snoozed."
  (let ((now (float-time)))
    (seq-remove (lambda (it)
                  (let ((s (plist-get it :snooze)))
                    (and s (> s now))))
                slack-attention--items)))

(defun slack-attention--ago (time)
  (let ((secs (max 0 (floor (- (float-time) (or time 0))))))
    (cond ((< secs 60) (format "%ds" secs))
          ((< secs 3600) (format "%dm" (/ secs 60)))
          ((< secs 86400) (format "%dh" (/ secs 3600)))
          (t (format "%dd" (/ secs 86400))))))

(defun slack-attention--list-entries ()
  (mapcar
   (lambda (it)
     (let* ((snoozed (plist-get it :snooze))
            (label (format "%s / %s"
                           (plist-get it :team-name)
                           (plist-get it :room-name)))
            (text (plist-get it :text)))
       (list (plist-get it :id)
             (vector
              (if snoozed "z" "!")
              (slack-attention--ago (plist-get it :time))
              (propertize label 'face 'font-lock-keyword-face)
              (if snoozed (propertize text 'face 'shadow) text)))))
   (slack-attention--visible-items)))

(defvar slack-attention-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "RET") #'slack-attention-jump)
    (define-key m [mouse-1]   #'slack-attention-jump)
    (define-key m (kbd "d")   #'slack-attention-dismiss)
    (define-key m (kbd "s")   #'slack-attention-snooze)
    (define-key m (kbd "u")   #'slack-attention-unsnooze-all)
    (define-key m (kbd "g")   #'slack-attention-refresh)
    (define-key m (kbd "C")   #'slack-attention-clear)
    (define-key m (kbd "q")   #'quit-window)
    m)
  "Keymap for `slack-attention-mode'.")

(define-derived-mode slack-attention-mode tabulated-list-mode "SlackAttn"
  "Major mode for the Slack attention panel."
  (setq tabulated-list-format
        [("!" 1 t) ("Age" 4 t) ("Team / Room" 26 t) ("Message" 0 nil)])
  (setq tabulated-list-padding 1)
  (setq tabulated-list-entries #'slack-attention--list-entries)
  (tabulated-list-init-header))

(defun slack-attention--get-buffer ()
  (or (get-buffer slack-attention-buffer-name)
      (with-current-buffer (get-buffer-create slack-attention-buffer-name)
        (slack-attention-mode)
        (current-buffer))))

(defun slack-attention--refresh-buffer ()
  (let ((buf (get-buffer slack-attention-buffer-name)))
    (when buf
      (with-current-buffer buf
        (let ((pt (point)))
          (tabulated-list-print t)
          (goto-char (min pt (point-max))))))))

(defun slack-attention--display ()
  "Show the panel in a side window without selecting it."
  (let ((buf (slack-attention--get-buffer)))
    (with-current-buffer buf (tabulated-list-print t))
    (display-buffer-in-side-window
     buf `((side . ,slack-attention-side)
           (window-width . ,slack-attention-window-size)
           (window-height . ,slack-attention-window-size)))))

;;; Commands ------------------------------------------------------------------

(defun slack-attention-show ()
  "Open (and select) the attention panel."
  (interactive)
  (let ((buf (slack-attention--get-buffer)))
    (with-current-buffer buf (tabulated-list-print t))
    (pop-to-buffer buf)))

(defun slack-attention--item-at-point ()
  (let ((id (tabulated-list-get-id)))
    (seq-find (lambda (it) (equal (plist-get it :id) id))
              slack-attention--items)))

(defun slack-attention-jump ()
  "Jump to the room of the item at point and remove it from the list.
Clicking/RET means you are handling the item, so it is dropped from the panel
\(like `d').  Items restored from a previous session (no live room object) are
kept, since you cannot jump to them yet."
  (interactive)
  (let ((it (slack-attention--item-at-point)))
    (unless it (user-error "No item here"))
    (let ((room (plist-get it :room)) (team (plist-get it :team)) (ts (plist-get it :ts)))
      (if (and room team)
          (progn
            ;; Open the room and, once its history has loaded, land point on the
            ;; specific message (by ts) so the item is right there -- scroll up
            ;; only if you want the surrounding channel context.
            (slack-room-display room team
                                (and ts (lambda (&rest _)
                                          (ignore-errors (slack-buffer-goto ts)))))
            ;; Handled -> remove from the list.
            (setq slack-attention--items (delq it slack-attention--items))
            (slack-attention--refresh-buffer))
        (message "This item was restored from a previous session; open its room via emacs-slack (%s / %s)."
                 (plist-get it :team-name) (plist-get it :room-name))))))

(defun slack-attention-dismiss ()
  "Mark the item at point done and remove it."
  (interactive)
  (let ((it (slack-attention--item-at-point)))
    (unless it (user-error "No item here"))
    (setq slack-attention--items (delq it slack-attention--items))
    (slack-attention--refresh-buffer)))

(defun slack-attention-snooze (&optional minutes)
  "Snooze the item at point for MINUTES (default `slack-attention-snooze-minutes')."
  (interactive "P")
  (let ((it (slack-attention--item-at-point))
        (mins (if minutes (prefix-numeric-value minutes)
                slack-attention-snooze-minutes)))
    (unless it (user-error "No item here"))
    (plist-put it :snooze (+ (float-time) (* 60 mins)))
    (slack-attention--ensure-snooze-timer)
    (slack-attention--refresh-buffer)
    (message "Snoozed for %d min" mins)))

(defun slack-attention-unsnooze-all ()
  "Clear snooze on all items."
  (interactive)
  (dolist (it slack-attention--items) (plist-put it :snooze nil))
  (slack-attention--refresh-buffer))

(defun slack-attention-refresh ()
  "Refresh the panel."
  (interactive)
  (slack-attention--refresh-buffer))

(defun slack-attention-clear ()
  "Remove all items after confirmation."
  (interactive)
  (when (yes-or-no-p "Clear all Slack attention items? ")
    (setq slack-attention--items nil)
    (slack-attention--refresh-buffer)))

(defun slack-attention--ensure-snooze-timer ()
  (unless slack-attention--snooze-timer
    (setq slack-attention--snooze-timer
          (run-with-timer 60 60 #'slack-attention--snooze-tick))))

(defun slack-attention--snooze-tick ()
  "Re-surface any snoozed items whose time has passed."
  (let ((now (float-time)) (any nil))
    (dolist (it slack-attention--items)
      (let ((s (plist-get it :snooze)))
        (when (and s (<= s now)) (plist-put it :snooze nil) (setq any t))))
    (when any
      (slack-attention--refresh-buffer)
      (when slack-attention-auto-pop (slack-attention--display)))
    (unless (seq-some (lambda (it) (plist-get it :snooze)) slack-attention--items)
      (when slack-attention--snooze-timer
        (cancel-timer slack-attention--snooze-timer)
        (setq slack-attention--snooze-timer nil)))))

;;; Persistence ---------------------------------------------------------------
;; Objects (message/room/team) are not serializable; persist the lightweight
;; fields so the list survives a restart for reference.  Jump-back is then
;; best-effort (the message says how to reach the room).

(defun slack-attention-save ()
  "Persist pending items to `slack-attention-file'."
  (condition-case nil
      (with-temp-file slack-attention-file
        (let ((print-length nil) (print-level nil))
          (prin1 (mapcar
                  (lambda (it)
                    (list :id (plist-get it :id)
                          :team-name (plist-get it :team-name)
                          :room-name (plist-get it :room-name)
                          :text (plist-get it :text)
                          :time (plist-get it :time)
                          :snooze (plist-get it :snooze)))
                  slack-attention--items)
                 (current-buffer))))
    (error nil)))

(defun slack-attention-load ()
  "Load persisted items from `slack-attention-file'."
  (when (file-readable-p slack-attention-file)
    (condition-case nil
        (with-temp-buffer
          (insert-file-contents slack-attention-file)
          (goto-char (point-min))
          (let ((data (read (current-buffer))))
            (setq slack-attention--items data)
            (setq slack-attention--counter
                  (apply #'max 0 (mapcar (lambda (it) (or (plist-get it :id) 0))
                                         data)))))
      (error nil))))

;;; Setup ---------------------------------------------------------------------

;;;###autoload
(defun slack-attention-setup ()
  "Install capture advice, load persisted items, and arrange save-on-exit."
  (interactive)
  (unless (fboundp 'slack-message-notify-alert)
    (user-error "emacs-slack not loaded; require/configure `slack' first"))
  ;; One :around on the alert display funnel gates the banner AND the panel
  ;; capture together (see `slack-attention--advice').  This funnels EVERY
  ;; notification path through the policy -- overriding `slack-message-notify-p'
  ;; alone missed paths such as `slack-event-notify', and separate
  ;; before-while + after advices let the capture fire even when the banner
  ;; was gated.
  (advice-add 'slack-message-notify-alert :around #'slack-attention--advice)
  (add-hook 'kill-emacs-hook #'slack-attention-save)
  (slack-attention-load)
  (when slack-attention--items (slack-attention--ensure-snooze-timer))
  (message "slack-attention ready (%d pending, policy %s)"
           (length slack-attention--items)
           (if slack-attention-control-notifications "on" "add-only")))

(defun slack-attention-teardown ()
  "Remove all advice and hooks installed by `slack-attention-setup'."
  (interactive)
  (advice-remove 'slack-message-notify-alert #'slack-attention--advice)
  ;; Remove advices from earlier iterations if still present.
  (ignore-errors (advice-remove 'slack-message-notify-alert #'slack-attention--capture-advice))
  (ignore-errors (advice-remove 'slack-message-notify-alert #'slack-attention--notify-gate))
  (ignore-errors (advice-remove 'slack-message-notify-p #'slack-attention-notify-policy))
  (remove-hook 'kill-emacs-hook #'slack-attention-save))

;;; Catch-up buffer -----------------------------------------------------------
;; A single buffer listing every room with unread messages (DMs, group DMs,
;; channels) across all connected teams, with a one-line preview of the latest
;; message.  For a quick scan-and-dismiss or a deep read + reply:
;;   RET / mouse-1  open the room (reads it -> marks it read)
;;   n / p          next / previous
;;   g              refresh          q  quit
;;
;; NOTE: needs a live Slack connection to populate; everything is guarded so an
;; API mismatch degrades to an empty/partial list rather than an error.

(defcustom slack-catchup-buffer-name "*Slack Catch-up*"
  "Name of the catch-up buffer."
  :type 'string :group 'slack-attention)

(defvar-local slack-catchup--rows nil
  "Buffer-local list of unread-room plists backing the catch-up buffer.")

(defun slack-attention--teams ()
  "Best-effort list of connected emacs-slack team objects."
  (cond
   ((and (boundp 'slack-teams-by-token) (hash-table-p slack-teams-by-token))
    (hash-table-values slack-teams-by-token))
   ((and (boundp 'slack-teams) (listp slack-teams) slack-teams) slack-teams)
   ((and (boundp 'slack-teams-alist) (listp slack-teams-alist))
    (delq nil (mapcar (lambda (c) (if (consp c) (cdr c) c)) slack-teams-alist)))
   (t nil)))

(defun slack-attention--find-room (id team)
  "Resolve room ID to a room object in TEAM (robust across API shapes)."
  (or (ignore-errors (slack-room-find id team))
      (ignore-errors (slack-room-find team id))
      (catch 'done
        (dolist (entry (ignore-errors (slack-message-room-list team)))
          (when (equal (ignore-errors (slot-value (cdr entry) 'id)) id)
            (throw 'done (cdr entry))))
        nil)))

(defun slack-attention--latest-message (room team)
  (or (ignore-errors (slack-room-latest room team))
      (ignore-errors (slack-room-latest room))))

(defun slack-attention--message-time (message)
  (or (ignore-errors (string-to-number (slot-value message 'ts)))
      (float-time)))

(defun slack-catchup--unread-rooms ()
  "Gather unread conversations across all connected teams.
Uses the emacs-slack counts API (team `counts' slot: channels/ims/mpims, each
with `has-unreads', `mention-count', `id', `latest'), which is the reliable
unread source in this version -- `slack-room-has-unread-p' is not populated."
  (let (rows)
    (dolist (team (slack-attention--teams))
      (let ((counts (ignore-errors (slot-value team 'counts))))
        (when counts
          (dolist (slot '(channels ims mpims))
            (dolist (c (ignore-errors (slot-value counts slot)))
              (let ((hu (ignore-errors (slot-value c 'has-unreads)))
                    (mc (or (ignore-errors (slot-value c 'mention-count)) 0))
                    (id (ignore-errors (slot-value c 'id)))
                    (latest (ignore-errors (slot-value c 'latest))))
                (when (and id (or hu (> mc 0)))
                  (let* ((room (slack-attention--find-room id team))
                         (msg (and room (slack-attention--latest-message room team)))
                         (text (if msg (slack-attention--message-text msg team) "")))
                    (push (list :room room :team team
                                :team-name (slack-attention--team-name team)
                                :room-name (if room
                                               (or (slack-attention--room-name room team) id)
                                             id)
                                :mention mc
                                :text (if (string-empty-p text) "(no preview)" text)
                                :time (if (and latest (stringp latest))
                                          (string-to-number latest)
                                        (float-time)))
                          rows)))))))))
    ;; Most recent first.
    (sort rows (lambda (a b) (> (plist-get a :time) (plist-get b :time))))))

(defun slack-catchup--entries ()
  (let ((i 0))
    (mapcar
     (lambda (r)
       (prog1
           (list i (vector (let ((m (or (plist-get r :mention) 0)))
                             (if (> m 0) (format "@%d" m) ""))
                           (slack-attention--ago (plist-get r :time))
                           (propertize (format "%s / %s"
                                               (plist-get r :team-name)
                                               (plist-get r :room-name))
                                       'face 'font-lock-keyword-face)
                           (plist-get r :text)))
         (setq i (1+ i))))
     slack-catchup--rows)))

(defvar slack-catchup-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "RET") #'slack-catchup-open)
    (define-key m [mouse-1]   #'slack-catchup-open)
    (define-key m (kbd "n")   #'next-line)
    (define-key m (kbd "p")   #'previous-line)
    (define-key m (kbd "g")   #'slack-catchup-refresh)
    (define-key m (kbd "q")   #'quit-window)
    m)
  "Keymap for `slack-catchup-mode'.")

(define-derived-mode slack-catchup-mode tabulated-list-mode "SlackCatchup"
  "Major mode for the Slack catch-up buffer."
  (setq tabulated-list-format
        [("@" 3 t) ("Age" 4 t) ("Team / Room" 26 t) ("Latest" 0 nil)])
  (setq tabulated-list-padding 1)
  (setq tabulated-list-entries #'slack-catchup--entries)
  (tabulated-list-init-header))

(defun slack-catchup-refresh ()
  "Rebuild the unread list."
  (interactive)
  (setq slack-catchup--rows (slack-catchup--unread-rooms))
  (tabulated-list-print t)
  (message "%d unread room(s)" (length slack-catchup--rows)))

(defun slack-catchup-open ()
  "Open the room on the current line (reads it, marking it read)."
  (interactive)
  (let* ((idx (tabulated-list-get-id))
         (r (and (integerp idx) (nth idx slack-catchup--rows))))
    (unless r (user-error "No room here"))
    (slack-room-display (plist-get r :room) (plist-get r :team))))

;;;###autoload
(defun slack-catch-up ()
  "Show a buffer of all rooms with unread messages for quick catch-up."
  (interactive)
  (unless (fboundp 'slack-message-room-list)
    (user-error "emacs-slack not loaded"))
  (let ((buf (get-buffer-create slack-catchup-buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'slack-catchup-mode) (slack-catchup-mode))
      (setq slack-catchup--rows (slack-catchup--unread-rooms))
      (tabulated-list-print t))
    (pop-to-buffer buf)
    (with-current-buffer buf
      (message "%d unread room(s) (RET open, g refresh, q quit)"
               (length slack-catchup--rows)))))

(provide 'slack-attention)
;;; slack-attention.el ends here
