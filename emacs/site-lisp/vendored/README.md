# Vendored Emacs modes

Third-party Emacs Lisp that has **no standalone upstream package**, so it is
vendored here rather than installed via elpaca/MELPA. Each is loaded from a
`(use-package … :ensure nil :load-path …)` block in `../../lisp/packages.el`.

| File | Upstream | Why vendored |
|------|----------|--------------|
| `llvm-mode.el` | [llvm-project](https://github.com/llvm/llvm-project) `llvm/utils/emacs/llvm-mode.el` | Lives inside the llvm-project repo; no MELPA package. |
| `tablegen-mode.el` | [llvm-project](https://github.com/llvm/llvm-project) `llvm/utils/emacs/tablegen-mode.el` | Same as above. |
| `google-c-style.el` | Google (2008); also on MELPA | Kept vendored so the `"Google"` c-style is registered **eagerly at startup**, before overlay styles that inherit from it (e.g. the Cerebras `monolith-c-style`). elpaca loads async at `after-init`, which would be too late. |

## Keeping the LLVM modes current

`llvm-mode.el` and `tablegen-mode.el` change very rarely. Check for upstream
drift periodically:

```sh
./update-from-upstream.sh            # report drift, no writes
./update-from-upstream.sh --update   # pull the changes; then git diff / commit
```
