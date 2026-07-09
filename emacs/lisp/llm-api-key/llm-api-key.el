;;; llm-api-key.el --- Resolve LLM provider API keys from pass -*- lexical-binding: t; -*-

;; Copyright (C) 2026 David Greene

;; Author: David Greene (with Claude Code)
;; Maintainer: David Greene
;; Version: 0.1.0
;; Keywords: comm, tools, convenience
;; URL: https://github.com/USER/llm-api-key
;; Package-Requires: ((emacs "27.1"))

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; Resolve an LLM provider's API key from the Unix `pass' store (via the
;; built-in `auth-source-pass').  Map each provider to a pass account; the secret
;; is read from the pass entry "<provider>/<account>/apikey".  This keeps keys out
;; of your init and lets one machine hold several accounts per provider.
;;
;;   (require 'llm-api-key)
;;   (setq llm-api-key-default-account "me@example.com")
;;   (add-to-list 'llm-api-key-accounts '("openai.com" . "work@example.com"))
;;   (llm-api-key "openai.com")   ; => the secret string, or nil
;;
;; Then feed it to whatever wants a key, e.g.:
;;
;;   (setq gptel-api-key (llm-api-key "openai.com"))
;;   (setenv "OPENAI_API_KEY" (llm-api-key "openai.com"))
;;
;; An account entry may also be a function of the provider name returning the
;; account string, for cases where the account is computed.

;;; Code:

(require 'auth-source-pass)

(defgroup llm-api-key nil
  "Resolve LLM provider API keys from the Unix `pass' store."
  :group 'comm
  :prefix "llm-api-key-")

(defcustom llm-api-key-accounts nil
  "Alist mapping an LLM provider name to a pass-store account.
Each value is either an account string or a function of the provider name
returning one.  The pass entry read is \"PROVIDER/ACCOUNT/apikey\"."
  :type '(alist :key-type (string :tag "Provider")
                :value-type (choice (string :tag "Account")
                                    (function :tag "Account function")))
  :group 'llm-api-key)

(defcustom llm-api-key-default-account nil
  "Default pass-store account used when no entry in `llm-api-key-accounts' matches."
  :type '(choice (const :tag "None" nil) string)
  :group 'llm-api-key)

;;;###autoload
(defun llm-api-key (provider)
  "Return the API key for LLM PROVIDER from the pass store, or nil.
PROVIDER is looked up in `llm-api-key-accounts'; the entry may be an account
string or a function of PROVIDER returning one.  Falls back to
`llm-api-key-default-account'.  The secret is read from the pass entry
\"PROVIDER/ACCOUNT/apikey\"."
  (let* ((entry (cdr (assoc provider llm-api-key-accounts)))
         (account (cond ((functionp entry) (funcall entry provider))
                        (entry entry)
                        (llm-api-key-default-account llm-api-key-default-account)
                        (t nil))))
    (when account
      (auth-source-pass-get 'secret (format "%s/%s/apikey" provider account)))))

(provide 'llm-api-key)
;;; llm-api-key.el ends here
