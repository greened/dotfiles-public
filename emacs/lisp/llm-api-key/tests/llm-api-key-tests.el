;;; llm-api-key-tests.el --- Tests for llm-api-key -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; What is tested is the RESOLUTION: provider -> account -> pass entry.  The
;; store read itself is not, and must not be.  `auth-source-pass-get' is
;; stubbed in every case, so no test reads the real pass store, unlocks a key,
;; or needs one to exist.  That follows the rule link-selftest.sh set for this
;; repo -- test the decision, never perform the effect.
;;
;; The stub records the entry it was asked for, because the entry string IS the
;; decision.  A wrong account silently reads a different key, and the caller
;; cannot tell: both return a plausible secret.
;;
;; No secret literal appears here.  The stub returns an obvious sentinel, so a
;; reader can never mistake this file for a place a key is kept.

;;; Code:

(require 'ert)
(require 'llm-api-key)

(defconst lakt-sentinel "sentinel-value-not-a-key"
  "What the stubbed store returns.  Deliberately not key-shaped.")

(defvar lakt-asked nil
  "The pass entry the stub was last asked for, or nil if it was never called.")

(defmacro lakt-with-store (&rest body)
  "Run BODY with `auth-source-pass-get' stubbed and `lakt-asked' reset.
The stub records its ENTRY argument and returns `lakt-sentinel'."
  (declare (indent 0))
  `(let ((lakt-asked nil))
     (cl-letf (((symbol-function 'auth-source-pass-get)
                (lambda (_what entry)
                  (setq lakt-asked entry)
                  lakt-sentinel)))
       ,@body)))

(ert-deftest lakt-reads-the-account-from-the-alist ()
  "A provider listed in `llm-api-key-accounts' uses that account."
  (lakt-with-store
    (let ((llm-api-key-accounts '(("openai.com" . "work@example.com")))
          (llm-api-key-default-account nil))
      (should (equal (llm-api-key "openai.com") lakt-sentinel))
      (should (equal lakt-asked "openai.com/work@example.com/apikey")))))

(ert-deftest lakt-calls-an-account-function-with-the-provider ()
  "A function entry is called with the provider and supplies the account."
  (lakt-with-store
    (let ((llm-api-key-accounts
           (list (cons "openai.com" (lambda (provider) (concat "acct-" provider)))))
          (llm-api-key-default-account nil))
      (should (equal (llm-api-key "openai.com") lakt-sentinel))
      (should (equal lakt-asked "openai.com/acct-openai.com/apikey")))))

(ert-deftest lakt-falls-back-to-the-default-account ()
  "An unlisted provider uses `llm-api-key-default-account'."
  (lakt-with-store
    (let ((llm-api-key-accounts '(("openai.com" . "work@example.com")))
          (llm-api-key-default-account "me@example.com"))
      (should (equal (llm-api-key "anthropic.com") lakt-sentinel))
      (should (equal lakt-asked "anthropic.com/me@example.com/apikey")))))

(ert-deftest lakt-prefers-the-alist-over-the-default ()
  "A listed provider ignores the default, which is the whole point of the alist."
  (lakt-with-store
    (let ((llm-api-key-accounts '(("openai.com" . "work@example.com")))
          (llm-api-key-default-account "me@example.com"))
      (should (equal (llm-api-key "openai.com") lakt-sentinel))
      (should (equal lakt-asked "openai.com/work@example.com/apikey")))))

(ert-deftest lakt-returns-nil-without-touching-the-store ()
  "No account and no default resolves to nil, and reads nothing.
Asserting `lakt-asked' stays nil is the real check: returning nil after a
pointless store read would pass a value-only test and still be wrong."
  (lakt-with-store
    (let ((llm-api-key-accounts nil)
          (llm-api-key-default-account nil))
      (should-not (llm-api-key "openai.com"))
      (should-not lakt-asked))))

(ert-deftest lakt-an-account-function-returning-nil-reads-nothing ()
  "A function that yields no account is the same as having none."
  (lakt-with-store
    (let ((llm-api-key-accounts (list (cons "openai.com" (lambda (_p) nil))))
          (llm-api-key-default-account nil))
      (should-not (llm-api-key "openai.com"))
      (should-not lakt-asked))))

(ert-deftest lakt-matches-a-provider-exactly ()
  "Lookup is `assoc', so a near-miss provider does not borrow the entry."
  (lakt-with-store
    (let ((llm-api-key-accounts '(("openai.com" . "work@example.com")))
          (llm-api-key-default-account "me@example.com"))
      (should (equal (llm-api-key "api.openai.com") lakt-sentinel))
      (should (equal lakt-asked "api.openai.com/me@example.com/apikey")))))

(ert-deftest lakt-passes-the-store-value-through-unchanged ()
  "Whatever the store returns is the return value; nothing reformats a secret."
  (let ((lakt-asked nil))
    (cl-letf (((symbol-function 'auth-source-pass-get)
               (lambda (_what _entry) "  padded value  ")))
      (let ((llm-api-key-accounts '(("openai.com" . "work@example.com")))
            (llm-api-key-default-account nil))
        (should (equal (llm-api-key "openai.com") "  padded value  "))))))

(ert-deftest lakt-asks-the-store-for-a-secret ()
  "The first argument is the symbol `secret', not a string or a field name."
  (let (what)
    (cl-letf (((symbol-function 'auth-source-pass-get)
               (lambda (w _entry) (setq what w) lakt-sentinel)))
      (let ((llm-api-key-accounts '(("openai.com" . "work@example.com")))
            (llm-api-key-default-account nil))
        (llm-api-key "openai.com")
        (should (eq what 'secret))))))

(provide 'llm-api-key-tests)
;;; llm-api-key-tests.el ends here
