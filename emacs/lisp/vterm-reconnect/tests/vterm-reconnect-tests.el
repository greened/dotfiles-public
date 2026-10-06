;;; vterm-reconnect-tests.el --- Tests for vterm-reconnect -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; Nothing here opens a terminal or runs ssh. `vterm', `vterm-send-string' and,
;; where a case reaches it, `vterm-ssh' are stubbed, and the tests assert what
;; each was asked for. That follows the rule link-selftest.sh set for this repo:
;; test the decision, never perform the effect.
;;
;; vterm is not installed under -Q, so `vterm-mode' is defined here as a plain
;; derived mode. The reconnect cases only need `derived-mode-p' to see it.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'term)
(require 'vterm-reconnect)

(unless (fboundp 'vterm-mode)
  (define-derived-mode vterm-mode fundamental-mode "VTerm"
    "Stand-in for vterm's mode, so `derived-mode-p' can match it."))

(defvar vrt-asked nil
  "Where a stub records the call it was given, newest first.")

(defvar vrt-buffers nil
  "Buffers a case made, killed afterwards if they are still live.")

(defmacro vrt-with-stubs (&rest body)
  "Run BODY with the terminal stubbed and `vrt-asked' reset.
Each stub pushes (WHICH ARG) onto `vrt-asked'. Buffers listed in
`vrt-buffers' are killed afterwards."
  (declare (indent 0))
  `(let ((vrt-asked nil)
         (vrt-buffers nil))
     (unwind-protect
         (cl-letf (((symbol-function 'vterm)
                    (lambda (&optional name)
                      (push (list 'vterm name) vrt-asked)))
                   ((symbol-function 'vterm-send-string)
                    (lambda (string &optional _paste)
                      (push (list 'send string) vrt-asked))))
           ,@body)
       (dolist (b vrt-buffers)
         (when (buffer-live-p b)
           (let ((kill-buffer-query-functions nil))
             (kill-buffer b)))))))

(defun vrt-buffer (name mode)
  "Make a buffer NAME in MODE and remember it for cleanup."
  (let ((b (generate-new-buffer name)))
    (with-current-buffer b (funcall mode))
    (push b vrt-buffers)
    b))

(defmacro vrt-reconnecting (host &rest body)
  "Run BODY after `vterm-reconnect' to HOST, with `vterm-ssh' stubbed."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'vterm-ssh)
              (lambda (h) (push (list 'vterm-ssh h) vrt-asked))))
     (vterm-reconnect ,host)
     ,@body))

;;;; vterm-ssh

(ert-deftest vrt-ssh-names-the-buffer-and-sends-ssh ()
  "A new session is a vterm named after the host, told to ssh there."
  (vrt-with-stubs
    (vterm-ssh "user@box")
    (should (equal (reverse vrt-asked)
                   '((vterm "*user@box*") (send "ssh user@box\n"))))))

(ert-deftest vrt-ssh-does-not-reuse-a-taken-name ()
  "A second session to the same host gets a buffer name of its own."
  (vrt-with-stubs
    (vrt-buffer "*box*" #'fundamental-mode)
    (vterm-ssh "box")
    (should (equal (assq 'vterm vrt-asked) '(vterm "*box*<2>")))))

;;;; vterm-reconnect

(ert-deftest vrt-reconnect-kills-terminals-for-the-host ()
  "A vterm or term buffer naming the host goes, even after a title rename."
  (vrt-with-stubs
    (let ((renamed (vrt-buffer "vterm user@box: ~" #'vterm-mode))
          (original (vrt-buffer "*user@box*" #'vterm-mode))
          (term (vrt-buffer "*user@box-term*" #'term-mode)))
      (vrt-reconnecting "user@box"
        (should-not (buffer-live-p renamed))
        (should-not (buffer-live-p original))
        (should-not (buffer-live-p term))))))

(ert-deftest vrt-reconnect-spares-other-buffers ()
  "A non-terminal buffer naming the host, and another host's vterm, stay."
  (vrt-with-stubs
    (let ((notes (vrt-buffer "user@box notes" #'fundamental-mode))
          (other (vrt-buffer "*user@elsewhere*" #'vterm-mode)))
      (vrt-reconnecting "user@box"
        (should (buffer-live-p notes))
        (should (buffer-live-p other))))))

(ert-deftest vrt-reconnect-matches-the-host-literally ()
  "The host is a literal string, so a dot in it matches only a dot."
  (vrt-with-stubs
    (let ((lookalike (vrt-buffer "*axb*" #'vterm-mode)))
      (vrt-reconnecting "a.b"
        (should (buffer-live-p lookalike))))))

(ert-deftest vrt-reconnect-kills-a-buffer-with-a-live-process ()
  "A live process does not stop the kill or ask about it.
In batch a query would read stdin and fail, and the kill's `ignore-errors'
would leave the buffer alive."
  (vrt-with-stubs
    (let* ((b (vrt-buffer "*user@box*" #'vterm-mode))
           (proc (make-pipe-process :name "vrt-live" :buffer b :noquery nil)))
      (unwind-protect
          (vrt-reconnecting "user@box"
            (should-not (buffer-live-p b)))
        (when (process-live-p proc) (delete-process proc))))))

(ert-deftest vrt-reconnect-opens-a-fresh-session ()
  "After the kill, a new session to the same host opens."
  (vrt-with-stubs
    (vrt-reconnecting "user@box"
      (should (equal vrt-asked '((vterm-ssh "user@box")))))))

;;;; vterm-reconnect-default

(ert-deftest vrt-default-needs-a-host ()
  "With no host configured, the default command refuses."
  (vrt-with-stubs
    (let ((vterm-reconnect-host nil))
      (should-error (vterm-reconnect-default) :type 'user-error)
      (should-not vrt-asked))))

(ert-deftest vrt-default-reconnects-the-configured-host ()
  "With a host configured, the default command reconnects that host."
  (vrt-with-stubs
    (let ((vterm-reconnect-host "user@box"))
      (cl-letf (((symbol-function 'vterm-reconnect)
                 (lambda (h) (push (list 'vterm-reconnect h) vrt-asked))))
        (vterm-reconnect-default))
      (should (equal vrt-asked '((vterm-reconnect "user@box")))))))

(provide 'vterm-reconnect-tests)
;;; vterm-reconnect-tests.el ends here
