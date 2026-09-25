;;; term-launcher-tests.el --- Tests for term-launcher -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; Nothing here opens a terminal.  `vterm', `vterm-ssh' and `tramp-term' are
;; stubbed in every case that would reach one, and the tests assert the HOST
;; each was asked for.  That follows the rule link-selftest.sh set for this
;; repo -- test the decision, never perform the effect.
;;
;; The keymap cases bind into a fresh keymap, never the live
;; `term-launcher-command-map', so running the suite cannot change what `C-c t'
;; does in the Emacs that runs it.
;;
;; `term-launcher-defterm' interns real commands, which is its job, so each of
;; those cases uses a host name of its own.  They are NOT uninterned afterwards,
;; and that is deliberate: uninterning leaves this file's own quoted symbols
;; pointing at the old object, so the next case silently calls the previous
;; case's definition.  A throwaway batch Emacs can afford the symbols.

;;; Code:

(require 'ert)
(require 'term-launcher)

(defvar tlt-asked nil
  "Where a stubbed launcher records the argument it was given.")

(defmacro tlt-with-launchers (&rest body)
  "Run BODY with the terminal launchers stubbed and `tlt-asked' reset.
Each stub pushes the two-element list (WHICH ARG) onto `tlt-asked', newest
first.  Wrapping the argument keeps the record readable whatever its type:
`vterm-ssh' is passed a host string, `tramp-term' a one-element list."
  (declare (indent 0))
  `(let ((tlt-asked nil))
     (cl-letf (((symbol-function 'vterm-ssh)
                (lambda (host) (push (list 'vterm-ssh host) tlt-asked)))
               ((symbol-function 'tramp-term)
                (lambda (host) (push (list 'tramp-term host) tlt-asked)))
               ((symbol-function 'vterm)
                (lambda (&optional name) (push (list 'vterm name) tlt-asked))))
       ,@body)))

(defun tlt-arg (which)
  "The argument the stubbed WHICH was last given, or nil if it was never called."
  (cadr (assq which tlt-asked)))

(defmacro tlt-with-defterm (host &rest body)
  "Define the commands for HOST, then run BODY.
HOST must be unique to the calling test; see the Commentary on why nothing is
uninterned afterwards."
  (declare (indent 1))
  `(progn (term-launcher-defterm ,host) ,@body))


;;; term-launcher--target-command: which command a key gets bound to.

(ert-deftest tlt-localhost-resolves-to-a-command-that-already-exists ()
  "\"localhost\" resolves to a command the package itself defines.

`term-launcher-defterm' is never run for localhost, so the binding would be
dead if the name did not match the defun in the source.  Asserting `commandp'
is what catches that; asserting the SYMBOL cannot, because the general path
interns the very same symbol for this host."
  (let ((cmd (term-launcher--target-command "localhost")))
    (should (fboundp cmd))
    (should (commandp cmd))))

(ert-deftest tlt-a-remote-host-gets-its-own-command ()
  "Any other host maps to `term-launcher-vterm-HOST'."
  (should (eq (term-launcher--target-command "boxnever")
              'term-launcher-vterm-boxnever)))

(ert-deftest tlt-a-remote-command-does-not-exist-until-defterm-runs ()
  "The remote name is only interned, so `defterm' is what makes it callable.
This is the asymmetry with localhost, and the reason the localhost case is
worth a test at all."
  (should-not (fboundp (term-launcher--target-command "boxundefined"))))

(ert-deftest tlt-localhost-is-matched-exactly ()
  "A host merely starting with \"localhost\" is still a remote target."
  (should (eq (term-launcher--target-command "localhost.example")
              'term-launcher-vterm-localhost.example)))


;;; term-launcher--sync-reconnect-host: picking the default reconnect host.

(ert-deftest tlt-sync-picks-the-first-non-localhost-target ()
  "localhost is skipped, and the first remaining target wins."
  (let ((term-launcher-machine-alist '(("localhost" "l") ("box" "b") ("two" "t")))
        (vterm-reconnect-host nil))
    (term-launcher--sync-reconnect-host)
    (should (equal vterm-reconnect-host "box"))))

(ert-deftest tlt-sync-leaves-a-configured-host-alone ()
  "An already-set host is a user's choice, so syncing must not overwrite it."
  (let ((term-launcher-machine-alist '(("localhost" "l") ("box" "b")))
        (vterm-reconnect-host "chosen"))
    (term-launcher--sync-reconnect-host)
    (should (equal vterm-reconnect-host "chosen"))))

(ert-deftest tlt-sync-yields-nil-when-every-target-is-local ()
  "With no remote target there is nothing to reconnect to."
  (let ((term-launcher-machine-alist '(("localhost" "l")))
        (vterm-reconnect-host nil))
    (term-launcher--sync-reconnect-host)
    (should-not vterm-reconnect-host)))


;;; term-launcher-defterm: the three per-host commands.

(ert-deftest tlt-defterm-defines-three-commands ()
  "Each host gets an ansi, a vterm and an open command, all interactive."
  (tlt-with-defterm "boxdefs"
    (dolist (kind '("ansi" "vterm" "open"))
      (let ((sym (intern (format "term-launcher-%s-boxdefs" kind))))
        (should (fboundp sym))
        (should (commandp sym))))))

(ert-deftest tlt-defterm-vterm-command-uses-the-bare-host ()
  "The vterm command ssh's to the bare name, because ssh resolves it."
  (tlt-with-launchers
    (let ((term-launcher-domain "example.com"))
      (tlt-with-defterm "boxvterm"
        (funcall 'term-launcher-vterm-boxvterm)))
    (should (equal (tlt-arg 'vterm-ssh) "boxvterm"))))

(ert-deftest tlt-defterm-ansi-command-applies-the-domain ()
  "The tramp command gets the qualified name, which tramp needs.
This asymmetry with the vterm command is deliberate, so it is pinned here."
  (tlt-with-launchers
    (let ((term-launcher-domain "example.com"))
      (tlt-with-defterm "boxdomain"
        (funcall 'term-launcher-ansi-boxdomain)))
    (should (equal (tlt-arg 'tramp-term) '("boxdomain.example.com")))))

(ert-deftest tlt-defterm-ansi-command-omits-an-unset-domain ()
  "With no domain configured the bare host is used, with no trailing dot."
  (tlt-with-launchers
    (let ((term-launcher-domain nil))
      (tlt-with-defterm "boxnodomain"
        (funcall 'term-launcher-ansi-boxnodomain)))
    (should (equal (tlt-arg 'tramp-term) '("boxnodomain")))))

(ert-deftest tlt-defterm-captures-the-domain-at-definition-time ()
  "The domain is baked in when the command is defined, not read when it runs.
Recording this because it is the surprising half: changing
`term-launcher-domain' afterwards does not move an existing command."
  (tlt-with-launchers
    (let ((term-launcher-domain "first.example"))
      (tlt-with-defterm "boxcapture"
        (let ((term-launcher-domain "second.example"))
          (funcall 'term-launcher-ansi-boxcapture))))
    (should (equal (tlt-arg 'tramp-term) '("boxcapture.first.example")))))


;;; term-launcher-bind-keys: what lands in the keymap.

(ert-deftest tlt-bind-keys-binds-each-target-to-its-key ()
  "Every (HOST KEY) pair reaches the map under its own key."
  (let ((term-launcher-command-map (make-sparse-keymap))
        (vterm-reconnect-host "pinned"))
    (term-launcher-bind-keys '(("localhost" "l") ("box" "b")))
    (should (eq (lookup-key term-launcher-command-map (kbd "l"))
                #'term-launcher-vterm-localhost))
    (should (eq (lookup-key term-launcher-command-map (kbd "b"))
                'term-launcher-vterm-box))))

(ert-deftest tlt-bind-keys-binds-the-named-command-not-a-global-lookup ()
  "The binding is the target's own command, whatever else holds that key.

This is the recorded bug: resolving the command through a global binding let an
unrelated package that had taken the same key become the target."
  (let ((term-launcher-command-map (make-sparse-keymap))
        (vterm-reconnect-host "pinned")
        (global-map (make-sparse-keymap)))
    (define-key global-map (kbd "b") #'ignore)
    (term-launcher-bind-keys '(("box" "b")))
    (should (eq (lookup-key term-launcher-command-map (kbd "b"))
                'term-launcher-vterm-box))))

(ert-deftest tlt-bind-keys-leaves-an-unrelated-binding-in-place ()
  "Binding is additive, so a key the user added to the map survives."
  (let ((term-launcher-command-map (make-sparse-keymap))
        (vterm-reconnect-host "pinned"))
    (define-key term-launcher-command-map (kbd "z") #'ignore)
    (term-launcher-bind-keys '(("box" "b")))
    (should (eq (lookup-key term-launcher-command-map (kbd "z")) #'ignore))))

(ert-deftest tlt-bind-keys-syncs-the-reconnect-host ()
  "Binding also points `vterm-reconnect' at the first remote target."
  (let ((term-launcher-command-map (make-sparse-keymap))
        (term-launcher-machine-alist '(("localhost" "l") ("box" "b")))
        (vterm-reconnect-host nil))
    (term-launcher-bind-keys term-launcher-machine-alist)
    (should (equal vterm-reconnect-host "box"))))

(ert-deftest tlt-bind-keys-syncs-from-the-variable-not-its-argument ()
  "CURRENT BEHAVIOUR, pinned because it is probably not intended.

`term-launcher-bind-keys' binds the keys it is GIVEN, but its sync step reads
the global `term-launcher-machine-alist' instead.  Call it with an alist that
is not the variable's value and the two disagree: the key binds to \"box\",
while the reconnect host comes from the variable.

Change the function and this test fails, which is the point -- it should fail
loudly rather than let the inconsistency move unnoticed."
  (let ((term-launcher-command-map (make-sparse-keymap))
        (term-launcher-machine-alist '(("other" "o")))
        (vterm-reconnect-host nil))
    (term-launcher-bind-keys '(("box" "b")))
    (should (eq (lookup-key term-launcher-command-map (kbd "b"))
                'term-launcher-vterm-box))
    (should (equal vterm-reconnect-host "other"))))

(provide 'term-launcher-tests)
;;; term-launcher-tests.el ends here
