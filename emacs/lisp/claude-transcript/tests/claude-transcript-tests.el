;;; claude-transcript-tests.el --- Tests for claude-transcript -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; Every record here is synthetic. Real transcripts hold private text, so none
;; is ever copied in. Only the last cases start a process, a local `tail' on a
;; temporary file.

;;; Code:

(require 'ert)
(require 'claude-transcript)

(defun ctt-render (json)
  "Render the record in JSON."
  (claude-transcript--render (claude-transcript--parse json)))

(defmacro ctt-with-buffer (&rest body)
  "Run BODY in a fresh transcript buffer, killed afterwards."
  (declare (indent 0))
  `(let ((b (generate-new-buffer "*ctt*")))
     (unwind-protect
         (with-current-buffer b
           (claude-transcript-mode)
           ,@body)
       (kill-buffer b))))

(ert-deftest ctt-partial-lines-wait-for-their-newline ()
  (ctt-with-buffer
   (let ((line "{\"type\":\"user\",\"message\":{\"content\":\"hello\"}}"))
     (claude-transcript--receive b (substring line 0 10))
     (should-not claude-transcript--pending)
     (claude-transcript--receive b (substring line 10 30))
     (should-not claude-transcript--pending)
     (claude-transcript--receive b (concat (substring line 30) "\n{\"ty"))
     (should (= (length claude-transcript--pending) 1))
     (should (equal claude-transcript--partial '("{\"ty")))
     (claude-transcript--flush b)
     (should (string-match-p "^> hello$" (buffer-string))))))

(ert-deftest ctt-line-split-across-many-chunks ()
  (ctt-with-buffer
   (let ((line "{\"type\":\"user\",\"message\":{\"content\":\"many\"}}"))
     (dotimes (i (length line))
       (claude-transcript--receive b (substring line i (1+ i))))
     (should-not claude-transcript--pending)
     (should (= (length claude-transcript--partial) (length line)))
     (claude-transcript--receive b "\n")
     (should-not claude-transcript--partial)
     (should (equal claude-transcript--pending (list "\n> many"))))))

(ert-deftest ctt-user-text ()
  (should (equal (ctt-render "{\"type\":\"user\",\"message\":{\"content\":\"hi\\nthere\"}}")
                 "\n> hi\n> there"))
  (should (equal (ctt-render "{\"type\":\"user\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"hi\"}]}}")
                 "\n> hi")))

(ert-deftest ctt-assistant-text-and-tool-use ()
  (should (equal (ctt-render "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"Done.\"}]}}")
                 "Done."))
  (should (equal (ctt-render "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Bash\",\"input\":{\"description\":\"d\",\"command\":\"git\\n  status\"}}]}}")
                 "  [Bash] git status"))
  ;; No known key, so the first string input stands in.
  (should (equal (ctt-render "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"X\",\"input\":{\"n\":3,\"zed\":\"z\"}}]}}")
                 "  [X] z"))
  (should (equal (ctt-render "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"X\",\"input\":{}}]}}")
                 "  [X]"))
  (should (equal (ctt-render "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"input\":{\"command\":\"ls\"}}]}}")
                 "  [?] ls")))

(ert-deftest ctt-hidden-records ()
  (let ((claude-transcript-show-tool-results nil))
    (dolist (json '("{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"thinking\",\"thinking\":\"t\"}]}}"
                    "{\"type\":\"user\",\"isMeta\":true,\"message\":{\"content\":\"meta\"}}"
                    "{\"type\":\"assistant\",\"isSidechain\":true,\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"sub\"}]}}"
                    "{\"type\":\"attachment\",\"attachment\":{\"type\":\"hook_success\",\"content\":\"c\"}}"
                    "{\"type\":\"system\",\"content\":\"s\"}"
                    "{\"type\":\"mode\",\"mode\":\"normal\"}"
                    "{\"type\":\"user\",\"message\":{\"content\":\"<system-reminder>r</system-reminder>\"}}"
                    "{\"type\":\"user\",\"message\":{\"content\":\"<task-notification>n</task-notification>\"}}"
                    "{\"type\":\"user\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"<command-name>/x</command-name>\"}]}}"
                    "{\"type\":\"user\",\"message\":{\"content\":\"<bash-stdout>secret</bash-stdout>\"}}"
                    "{\"type\":\"user\",\"message\":{\"content\":\"<bash-stderr>secret</bash-stderr>\"}}"
                    "{\"type\":\"user\",\"message\":{\"content\":\"<local-command-stdout>secret</local-command-stdout>\"}}"
                    "{\"type\":\"user\",\"message\":{\"content\":[{\"type\":\"tool_result\",\"content\":\"secret\"}]}}"))
      (should (equal (list json nil) (list json (ctt-render json)))))))

(ert-deftest ctt-compact-summary-is-one-line ()
  (let ((summary (make-string 15000 ?s)))
    (should (equal (ctt-render (format "{\"type\":\"user\",\"isCompactSummary\":true,\"message\":{\"content\":\"%s\"}}" summary))
                   "[compacted]"))))

(ert-deftest ctt-only-harness-tags-hide-text ()
  ;; A tag the person typed, or any tag in an assistant turn, is text.
  (should (equal (ctt-render "{\"type\":\"user\",\"message\":{\"content\":\"<p> why does this render\"}}")
                 "\n> <p> why does this render"))
  (should (equal (ctt-render "{\"type\":\"user\",\"message\":{\"content\":\"<Bash-Stdout>x\"}}")
                 "\n> <Bash-Stdout>x"))
  (should (equal (ctt-render "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"<details>more\"}]}}")
                 "<details>more"))
  (should (equal (ctt-render "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"<task-notification>n\"}]}}")
                 "<task-notification>n")))

(ert-deftest ctt-reminder-is-stripped-from-typed-text ()
  (should (equal (ctt-render "{\"type\":\"user\",\"message\":{\"content\":\"a <system-reminder>r\\nr</system-reminder> b\"}}")
                 "\n> a  b")))

(ert-deftest ctt-tool-results-only-when-asked ()
  (let ((claude-transcript-show-tool-results t))
    (should (equal (ctt-render "{\"type\":\"user\",\"message\":{\"content\":[{\"type\":\"tool_result\",\"content\":\"ok\\nfine\"}]}}")
                   "    => ok fine"))
    (should (equal (ctt-render "{\"type\":\"user\",\"message\":{\"content\":[{\"type\":\"tool_result\",\"content\":[{\"type\":\"text\",\"text\":\"ok\"}]}]}}")
                   "    => ok"))))

(ert-deftest ctt-unknown-and-malformed-are-skipped ()
  (should-not (ctt-render "{\"type\":\"never-seen\",\"x\":1}"))
  (should-not (ctt-render "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"new-block\"}]}}"))
  (should-not (claude-transcript--parse "{\"type\":"))
  (should-not (claude-transcript--parse "42"))
  (should-not (claude-transcript--parse ""))
  ;; A known type in an unexpected shape renders nothing rather than erroring.
  (ctt-with-buffer
   (claude-transcript--receive b "{\"type\":\"user\",\"message\":7}\n")
   (claude-transcript--flush b)
   (should (equal (buffer-string) ""))))

(ert-deftest ctt-tail-errors-show-but-torn-records-do-not ()
  (ctt-with-buffer
   (claude-transcript--receive
    b (concat "tail: error reading 'x': Is a directory\n"
              "{\"type\":\"user\",\"message\":{\"content\":[{\"type\":\"tool_result\",\"content\":\"secret\n"))
   (claude-transcript--flush b)
   (should (equal (buffer-string) "tail: error reading 'x': Is a directory\n"))))

(ert-deftest ctt-open-refuses-a-directory ()
  (let ((before (buffer-list)))
    (should-error (claude-transcript-open temporary-file-directory)
                  :type 'user-error)
    (should (equal (buffer-list) before))))

(ert-deftest ctt-long-lines-are-clipped ()
  (let ((claude-transcript-max-line-length 20)
        (long (make-string 5000 ?a)))
    (should (equal (ctt-render (format "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"%s\\nshort\"}]}}" long))
                   (concat (make-string 20 ?a) "...\nshort")))
    (should (equal (ctt-render (format "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Bash\",\"input\":{\"command\":\"%s\"}}]}}" long))
                   (concat "  [Bash] " (make-string 11 ?a) "...")))))

(ert-deftest ctt-ai-title-names-the-buffer ()
  (should (equal (claude-transcript--buffer-name "abc-123") "*claude: abc-123*"))
  (ctt-with-buffer
   (claude-transcript--receive b "{\"type\":\"ai-title\",\"aiTitle\":\"Fix the build\"}\n")
   (claude-transcript--flush b)
   (should (equal (buffer-name) "*claude: Fix the build*"))
   (should (equal (buffer-string) ""))))

(ert-deftest ctt-follow-toggle ()
  (ctt-with-buffer
   (claude-transcript--receive b "{\"type\":\"user\",\"message\":{\"content\":\"one\"}}\n")
   (claude-transcript--flush b)
   (goto-char (point-min))
   (claude-transcript-toggle-follow)
   (should-not claude-transcript--follow)
   (goto-char (point-min))
   (claude-transcript--receive b "{\"type\":\"user\",\"message\":{\"content\":\"two\"}}\n")
   (claude-transcript--flush b)
   (should (= (point) (point-min)))
   (claude-transcript-toggle-follow)
   (should (= (point) (point-max)))
   (claude-transcript--receive b "{\"type\":\"user\",\"message\":{\"content\":\"three\"}}\n")
   (claude-transcript--flush b)
   (should (= (point) (point-max)))))

(ert-deftest ctt-kill-cancels-the-pending-render ()
  (let ((b (generate-new-buffer "*ctt*")) timer)
    (unwind-protect
        (with-current-buffer b
          (claude-transcript-mode)
          (claude-transcript--receive b "{\"type\":\"user\",\"message\":{\"content\":\"x\"}}\n")
          (setq timer claude-transcript--timer)
          (should (memq timer timer-idle-list))
          (kill-buffer b)
          (should (not (memq timer timer-idle-list))))
      (when (buffer-live-p b) (kill-buffer b))
      (when timer (cancel-timer timer)))))

(ert-deftest ctt-g-restarts-rather-than-reverts ()
  (should (eq (keymap-lookup claude-transcript-mode-map "g")
              #'claude-transcript-restart)))

(defmacro ctt-with-tail (&rest body)
  "Run BODY with `b' tailing a temporary transcript and `file' naming it."
  (declare (indent 0))
  `(let* ((file (make-temp-file "ctt-" nil ".jsonl"
                                "{\"type\":\"user\",\"message\":{\"content\":\"tailed\"}}\n"))
          (claude-transcript-directory temporary-file-directory)
          (b (save-window-excursion (claude-transcript-open file))))
     (unwind-protect
         (progn ,@body)
       (when (buffer-live-p b) (kill-buffer b))
       (delete-file file))))

(defun ctt-wait-for (b pred what)
  "Accept output until PRED holds in B, failing after 5 s with WHAT."
  (with-timeout (5 (ert-fail what))
    (while (not (with-current-buffer b (funcall pred)))
      (accept-process-output nil 0.1))))

(ert-deftest ctt-open-tails-and-kill-stops ()
  (skip-unless (executable-find "tail"))
  (ctt-with-tail
   (let ((proc (get-buffer-process b)))
     (should (equal (buffer-name b)
                    (claude-transcript--buffer-name (file-name-base file))))
     (ctt-wait-for b (lambda () claude-transcript--pending) "no output from tail")
     (claude-transcript--flush b)
     (should (string-match-p "> tailed" (with-current-buffer b (buffer-string))))
     ;; A restart reads the file afresh, so the turn appears once.
     (with-current-buffer b (claude-transcript-restart))
     (should-not (process-live-p proc))
     (setq proc (get-buffer-process b))
     (ctt-wait-for b (lambda () claude-transcript--pending) "no output after restart")
     (claude-transcript--flush b)
     (should (equal (with-current-buffer b (buffer-string)) "\n> tailed\n"))
     (kill-buffer b)
     (should-not (process-live-p proc)))))

(ert-deftest ctt-dead-tail-says-so ()
  (skip-unless (executable-find "tail"))
  (ctt-with-tail
   (kill-process (get-buffer-process b))
   (ctt-wait-for b (lambda () (string-match-p "^\\[tail exited: .+\\]$" (buffer-string)))
                 "no exit notice")
   (with-current-buffer b
     (should (string-match-p " exited" (claude-transcript--lighter))))))

;;; claude-transcript-tests.el ends here
