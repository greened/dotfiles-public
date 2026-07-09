# llm-api-key

Resolve an LLM provider's API key from the Unix [`pass`](https://www.passwordstore.org/)
store, via Emacs' built-in `auth-source-pass`. Keeps API keys out of your init
and lets one machine hold several accounts per provider.

## How it works

Map each provider to a pass account. The secret is read from the pass entry
`<provider>/<account>/apikey`. For example, with account `work@example.com` for
`openai.com`, the key comes from `pass openai.com/work@example.com/apikey`.

```elisp
(require 'llm-api-key)
(setq llm-api-key-default-account "me@example.com")
(add-to-list 'llm-api-key-accounts '("openai.com" . "work@example.com"))

(llm-api-key "openai.com")   ; => the secret string, or nil
```

Feed the result to whatever wants a key:

```elisp
(setq gptel-api-key (llm-api-key "openai.com"))
(setenv "OPENAI_API_KEY" (llm-api-key "openai.com"))
```

- `llm-api-key-accounts` — alist of `(PROVIDER . ACCOUNT)`. `ACCOUNT` may be a
  string, or a function of the provider name returning the account string.
- `llm-api-key-default-account` — used when no provider-specific entry matches.

## Setup

This is a **local-but-shareable** package: a self-contained, publishable package
that currently lives inside dotfiles. Its own `use-package` block owns loading it
(via `:load-path`), so it behaves exactly like a fetched package and does not
depend on any global `load-path` setup.

```elisp
(use-package llm-api-key
  :ensure nil                           ; local package; do not let elpaca fetch
  ;; Lambda (not a bare form): use-package treats a list as a list-of-paths.
  :load-path (lambda () (list (expand-file-name "lisp/llm-api-key" emacs-root)))
  :demand t)                            ; so `llm-api-key-accounts' exists before
                                        ; anything `add-to-list's into it
```

`:demand t` matters here: the accounts alist is typically populated with
`add-to-list` from context-specific config, which requires the variable to be
bound first.

### Extracting to its own repo later

Because the block above is self-contained, publishing this directory as a
standalone repo is a one-line swap — replace the `:ensure nil` + `:load-path`
lines with an elpaca recipe, and nothing else in the block changes:

```elisp
  :ensure (llm-api-key :host github :repo "USER/llm-api-key")
```
