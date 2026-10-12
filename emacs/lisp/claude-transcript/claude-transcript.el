;;; claude-transcript.el --- Tail a Claude Code session transcript -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: AGPL-3.0-or-later
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:
;;
;; `claude-transcript-open' tails a session's JSONL file into a read-only
;; buffer, to read beside the terminal that runs the session. It shows what
;; was typed, what the assistant wrote, and one line per tool call. Thinking,
;; reminders, meta turns, harness-tagged user turns, bookkeeping and subagents
;; are hidden, and so are tool results unless
;; `claude-transcript-show-tool-results' is set, because they can hold secrets.
;; A compact summary shows as a single `[compacted]' line.
;;
;; The record schema is not a documented API, so anything unrecognised is
;; skipped rather than reported. An error from `tail' itself is shown.

;;; Code:

(require 'seq)
(require 'subr-x)

(defgroup claude-transcript nil
  "Tail a Claude Code session transcript."
  :group 'tools
  :prefix "claude-transcript-")

(defcustom claude-transcript-directory "~/.claude/projects/"
  "Where the file prompt starts, on the host of `default-directory'."
  :type 'directory)

(defcustom claude-transcript-initial-lines 2000
  "How many existing records to read before following new ones."
  :type 'natnum)

(defcustom claude-transcript-max-line-length 300
  "Rendered lines longer than this are cut short."
  :type 'natnum)

(defcustom claude-transcript-show-tool-results nil
  "When non-nil, show a line of each tool result."
  :type 'boolean)

(defcustom claude-transcript-render-delay 0.2
  "Idle seconds before newly read records are inserted."
  :type 'number)

(defvar-local claude-transcript--partial nil
  "Chunks of the unterminated last line, newest first.")
(defvar-local claude-transcript--pending nil
  "Rendered strings waiting to be inserted, newest first.")
(defvar-local claude-transcript--timer nil)
(defvar-local claude-transcript--follow t
  "Non-nil means point follows new output.")
(defvar-local claude-transcript--exited nil
  "Non-nil once the tail process has died.")
(defvar-local claude-transcript--file nil
  "The transcript file this buffer tails.")

(defconst claude-transcript--harness-regexp
  (concat "\\`<"
          (regexp-opt '("task-notification" "command-name" "command-message"
                        "command-args" "local-command-stdout"
                        "local-command-caveat" "bash-input" "bash-stdout"
                        "bash-stderr" "fork-boilerplate"))
          ">")
  "Matches a user turn the harness wrote rather than the person typing.")

(defun claude-transcript--clip (line)
  "LINE, cut to `claude-transcript-max-line-length'."
  (if (> (length line) claude-transcript-max-line-length)
      (concat (substring line 0 claude-transcript-max-line-length) "...")
    line))

(defun claude-transcript--strip-reminders (text)
  "TEXT without its system-reminder blocks."
  ;; A search loop rather than a regexp: a lazy multi-line match over a
  ;; large record can overflow the regexp stack.
  (let ((open "<system-reminder>") (close "</system-reminder>") (start 0) out)
    (while-let ((beg (string-search open text start)))
      (push (substring text start beg) out)
      (let ((end (string-search close text beg)))
        (setq start (if end (+ end (length close)) (length text)))))
    (push (substring text start) out)
    (string-trim (apply #'concat (nreverse out)))))

(defun claude-transcript--harness-p (text)
  "Non-nil if user TEXT opens with a harness tag."
  (let ((case-fold-search nil))
    (string-match-p claude-transcript--harness-regexp text)))

(defun claude-transcript--lines (text prefix)
  "TEXT as clipped lines, each starting with PREFIX."
  (mapconcat (lambda (l) (claude-transcript--clip (concat prefix l)))
             (split-string text "\n") "\n"))

(defun claude-transcript--one-line (s)
  "The start of S collapsed onto one line."
  ;; Only the start survives the clip, so a huge input is cut before the
  ;; regexp pass rather than after.
  (let ((s (substring s 0 (min (length s)
                               (* 2 claude-transcript-max-line-length)))))
    (string-trim (replace-regexp-in-string "[ \t\r\n]+" " " s))))

(defconst claude-transcript--argument-keys
  '(command file_path pattern url query description prompt skill)
  "Tool inputs tried in order for a tool call's one-line summary.")

(defun claude-transcript--tool-use (block)
  "A one-line summary of tool_use BLOCK."
  (let* ((input (alist-get 'input block))
         (input (and (listp input) input))
         (arg (or (seq-some (lambda (k)
                              (let ((v (alist-get k input)))
                                (and (stringp v) v)))
                            claude-transcript--argument-keys)
                  (seq-some (lambda (kv) (and (consp kv) (stringp (cdr kv))
                                              (cdr kv)))
                            input)
                  "")))
    (propertize (claude-transcript--clip
                 (string-trim-right
                  (format "  [%s] %s" (let ((n (alist-get 'name block)))
                                        (if (stringp n) n "?"))
                          (claude-transcript--one-line arg))))
                'face 'shadow)))

(defun claude-transcript--tool-result (block)
  "A one-line summary of tool_result BLOCK."
  (let ((c (alist-get 'content block)))
    (propertize
     (claude-transcript--clip
      (concat "    => "
              (claude-transcript--one-line
               (if (stringp c) c
                 (mapconcat (lambda (b) (or (and (listp b) (alist-get 'text b)) ""))
                            (and (listp c) c) " ")))))
     'face 'shadow)))

(defun claude-transcript--block (block user)
  "Render content BLOCK, or nil to hide it. USER is non-nil in a user turn."
  (pcase (alist-get 'type block)
    ("text" (claude-transcript--text-turn (alist-get 'text block) user))
    ("tool_use" (claude-transcript--tool-use block))
    ("tool_result" (and claude-transcript-show-tool-results
                        (claude-transcript--tool-result block)))))

(defun claude-transcript--text-turn (text user)
  "TEXT rendered for a user turn when USER, else an assistant turn."
  (when (stringp text)
    (let ((text (claude-transcript--strip-reminders text)))
      (cond ((string-empty-p text) nil)
            ((not user) (claude-transcript--lines text ""))
            ;; Hidden rather than shown: some of these tags carry command
            ;; output, with the same secret risk as a tool result.
            ((claude-transcript--harness-p text) nil)
            (t (concat "\n" (propertize (claude-transcript--lines text "> ")
                                        'face 'bold)))))))

(defun claude-transcript--render (record)
  "RECORD as a string to insert, or nil if it is hidden."
  (let ((type (alist-get 'type record))
        (content (alist-get 'content (alist-get 'message record))))
    (when (and (member type '("user" "assistant"))
               (not (alist-get 'isMeta record))
               (not (alist-get 'isSidechain record)))
      (let ((user (equal type "user")))
        (cond
         ((alist-get 'isCompactSummary record)
          (propertize "[compacted]" 'face 'shadow))
         ((stringp content)
          (claude-transcript--text-turn content user))
         (t
          (when-let ((parts (delq nil (mapcar (lambda (b)
                                                (claude-transcript--block b user))
                                              (and (listp content) content)))))
            (string-join parts "\n"))))))))

(defun claude-transcript--parse (line)
  "LINE parsed as a JSON object, or nil if it is not one."
  (let ((r (condition-case nil
               (json-parse-string line :object-type 'alist :array-type 'list
                                  :null-object nil :false-object nil)
             (json-error nil))))
    (and (consp r) r)))

(defun claude-transcript--buffer-name (id)
  "The buffer name for session title or id ID."
  (format "*claude: %s*" id))

(defun claude-transcript--line (line)
  "Handle complete LINE: rename the buffer or queue its rendered text."
  (if-let ((r (claude-transcript--parse line)))
      (if (equal (alist-get 'type r) "ai-title")
          (when-let ((title (alist-get 'aiTitle r))
                     ((stringp title))
                     (name (claude-transcript--buffer-name title)))
            (unless (equal name (buffer-name))
              (rename-buffer name t)))
        ;; Queue the string, not the record: a record can be many KB.
        (when-let ((s (ignore-errors (claude-transcript--render r))))
          (push s claude-transcript--pending)))
    ;; The pipe merges tail's stderr into stdout, but this shows only
    ;; tail's own lines: a torn record could contain a tool result.
    (when (string-prefix-p "tail: " line)
      (push (propertize (claude-transcript--clip line) 'face 'warning)
            claude-transcript--pending))))

(defun claude-transcript--receive (buffer chunk)
  "Handle the complete lines of CHUNK for BUFFER and schedule an insert."
  (with-current-buffer buffer
    ;; Search only the new chunk and join the held chunks once, so a long
    ;; line read in many pieces costs linear time.
    (if-let ((nl (string-search "\n" chunk)))
        (let ((first (apply #'concat (nreverse (cons (substring chunk 0 nl)
                                                     claude-transcript--partial))))
              (rest (split-string (substring chunk (1+ nl)) "\n")))
          (let ((tail (car (last rest))))
            (setq claude-transcript--partial
                  (and (not (string-empty-p tail)) (list tail))))
          (dolist (line (cons first (butlast rest)))
            (claude-transcript--line line)))
      (push chunk claude-transcript--partial))
    (when (and claude-transcript--pending (not claude-transcript--timer))
      (setq claude-transcript--timer
            (run-with-idle-timer claude-transcript-render-delay nil
                                 #'claude-transcript--flush buffer)))))

(defun claude-transcript--filter (proc chunk)
  "Process filter: hand CHUNK from PROC to its buffer."
  (when (buffer-live-p (process-buffer proc))
    (claude-transcript--receive (process-buffer proc) chunk)))

(defun claude-transcript--insert (s)
  "Insert S and a newline at the end of the buffer, following if asked."
  (let ((inhibit-read-only t))
    (save-excursion
      (goto-char (point-max))
      (insert s "\n")))
  (when claude-transcript--follow
    (goto-char (point-max))
    (dolist (w (get-buffer-window-list (current-buffer) nil t))
      (set-window-point w (point-max)))))

(defun claude-transcript--flush (buffer)
  "Insert BUFFER's queued text at its end."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when claude-transcript--timer
        (cancel-timer claude-transcript--timer)
        (setq claude-transcript--timer nil))
      (let ((strings (nreverse claude-transcript--pending)))
        (setq claude-transcript--pending nil)
        (when strings
          (claude-transcript--insert (string-join strings "\n")))))))

(defun claude-transcript--sentinel (proc event)
  "Say in PROC's buffer that the tail died, with EVENT."
  (let ((buffer (process-buffer proc)))
    (when (and (buffer-live-p buffer)
               (memq (process-status proc) '(exit signal)))
      (with-current-buffer buffer
        (claude-transcript--flush buffer)
        (setq claude-transcript--exited t)
        (claude-transcript--insert
         (propertize (format "[tail exited: %s]" (string-trim event))
                     'face 'warning))
        (force-mode-line-update)))))

(defun claude-transcript--start ()
  "Tail `claude-transcript--file' into the current buffer."
  ;; A pipe, not a pty: a pty rewrites newlines and can echo.
  (let* ((process-connection-type nil)
         (proc (start-file-process
                "claude-transcript" (current-buffer) "tail" "-n"
                (number-to-string claude-transcript-initial-lines)
                "-F" (file-local-name claude-transcript--file))))
    (set-process-coding-system proc 'utf-8-unix 'utf-8-unix)
    (set-process-query-on-exit-flag proc nil)
    (set-process-filter proc #'claude-transcript--filter)
    (set-process-sentinel proc #'claude-transcript--sentinel)))

(defun claude-transcript--stop ()
  "Stop the tail and the pending render."
  (when claude-transcript--timer
    (cancel-timer claude-transcript--timer)
    (setq claude-transcript--timer nil))
  (when-let ((proc (get-buffer-process (current-buffer))))
    ;; A deliberate stop is not a death to report.
    (set-process-sentinel proc #'ignore)
    (delete-process proc)))

(defun claude-transcript-restart ()
  "Clear the buffer and tail the transcript again."
  (interactive)
  (claude-transcript--stop)
  (let ((inhibit-read-only t))
    (erase-buffer))
  (setq claude-transcript--partial nil
        claude-transcript--pending nil
        claude-transcript--exited nil)
  (claude-transcript--start)
  (force-mode-line-update))

(defun claude-transcript-toggle-follow ()
  "Toggle whether point follows new output."
  (interactive)
  (setq claude-transcript--follow (not claude-transcript--follow))
  (when claude-transcript--follow
    (goto-char (point-max)))
  (force-mode-line-update)
  (message "Follow %s" (if claude-transcript--follow "on" "off")))

(defun claude-transcript--lighter ()
  "The mode-line state after the mode name."
  (concat (if claude-transcript--exited " exited" "")
          (if claude-transcript--follow " follow" "")))

(defvar-keymap claude-transcript-mode-map
  :parent special-mode-map
  "f" #'claude-transcript-toggle-follow
  ;; Shadows `revert-buffer' from `special-mode-map', which cannot restore
  ;; this buffer.
  "g" #'claude-transcript-restart)

(define-derived-mode claude-transcript-mode special-mode
  '("Transcript" (:eval (claude-transcript--lighter)))
  "Read-only view of a Claude Code session transcript."
  (setq truncate-lines t)
  (add-hook 'kill-buffer-hook #'claude-transcript--stop nil t))

;;;###autoload
(defun claude-transcript-open (file)
  "Tail the session transcript FILE into a read-only buffer.
A remote FILE is tailed on its own host."
  (interactive
   (list (read-file-name "Transcript: "
                         (concat (or (file-remote-p default-directory) "")
                                 claude-transcript-directory)
                         nil t)))
  (when (file-directory-p file)
    (user-error "Pick a transcript file, not the directory %s" file))
  (let* ((file (expand-file-name file))
         (buffer (generate-new-buffer
                  (claude-transcript--buffer-name
                   (file-name-base file)))))
    (with-current-buffer buffer
      (claude-transcript-mode)
      (setq default-directory (file-name-directory file)
            claude-transcript--file file)
      (claude-transcript--start))
    (pop-to-buffer buffer)))

(provide 'claude-transcript)
;;; claude-transcript.el ends here
