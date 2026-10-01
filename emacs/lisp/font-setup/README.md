# font-setup

Use the same fonts on macOS and Linux, so Powerline arrows and Nerd Font icons
line up in terminals inside Emacs. tmux drawn in a vterm buffer is the case it
was written for.

## What it does

The default face gets JetBrains Mono. The Nerd Font code points go to Symbols
Nerd Font Mono in the default fontset, so frames that a daemon makes later get
them too. The ranges are the Private Use Area (`U+E000` to `U+F8FF`) and the
Nerd Fonts v3 Material Design icons (`U+F0001` to `U+F1AF0`). A font is used
only if `find-font` finds it.

There is no `face-font-rescale-alist` entry. The Mono variant of the symbols
font is drawn to fit one cell, so it needs no rescaling.

```elisp
(require 'font-setup)
(setq font-setup-default-height 120)   ; optional, in 1/10 pt
(font-setup-enable)
```

`font-setup-enable` does nothing in batch mode. In a daemon it waits for the
first graphical frame. The check runs once per session.

## When a font is missing

- **Debian forky or sid** (read from `VERSION_CODENAME` in `/etc/os-release`):
  a warning tells you to run `sudo apt install fonts-nerd-symbols`. Nothing is
  installed for you.
- **Debian trixie or earlier, another Linux or macOS:** once Emacs is idle it
  asks whether to download the font. It asks on a graphical frame only, and
  waits for the next one if that frame was closed. On yes it downloads the Nerd Fonts 3.5.1
  `NerdFontsSymbolsOnly.tar.xz` with curl in the background, checks its sha256
  and refuses the archive on a mismatch. It installs only
  `SymbolsNerdFontMono-Regular.ttf`, into `~/.local/share/fonts` on Linux or
  `~/Library/Fonts` on macOS. On Linux it runs `fc-cache`. Then it applies the
  fonts again. On macOS you may need to restart Emacs before the icons show.
- **JetBrains Mono missing on Debian:** the same warning also names
  `fonts-jetbrains-mono`.

A no is recorded in `~/.emacs.d/font-setup-declined` (the
`font-setup-declined-file` option), and the question is not asked again. To be
asked again, delete that file. To install at any time, run
`M-x font-setup-install-symbols`.

## Options

Every font name, range and download detail is an option in the `font-setup`
group:

- `font-setup-default-family`, `font-setup-default-height`
- `font-setup-symbols-family`, `font-setup-symbols-ranges`
- `font-setup-apt-codenames`, `font-setup-default-apt-package`,
  `font-setup-symbols-apt-package`
- `font-setup-nerd-fonts-version`, `font-setup-download-url`,
  `font-setup-download-sha256`, `font-setup-download-member`,
  `font-setup-download-max-time`
- `font-setup-install-directory`, `font-setup-declined-file`

To move to a new Nerd Fonts release, change the version and the sha256
together. The release page on GitHub lists the digest of each asset.

## Setup

This is a local package that lives inside dotfiles. Its `use-package` block
loads it through `:load-path`:

```elisp
(use-package font-setup
  :ensure nil
  :load-path (lambda () (list (expand-file-name "lisp/font-setup" emacs-root)))
  :if (memq system-type '(darwin gnu/linux))
  :demand t
  :config
  (font-setup-enable))
```

## Tests

    ./check.sh

The tests cover the decisions: which action each platform gets, whether an
archive is refused and which entry is installed. They never start curl, tar
or fc-cache, and they never download anything.
