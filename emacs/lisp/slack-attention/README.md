# slack-attention.el

Loud-but-deferrable Slack notifications and a fast unread catch-up buffer for
[emacs-slack](https://github.com/yuya373/emacs-slack).

Two independent tools:

1. **Attention panel** — the messages that matter interrupt you (side window +
   gentle frame raise + your existing OS banner) and *stay* in a persistent
   `*Slack Attention*` list until you act, so deferring never loses anything.
2. **Catch-up buffer** — `M-x slack-catch-up`: one buffer of every conversation
   with unreads, for a quick scan-and-dismiss or a deeper read + reply.

The file contains **no tokens or team config** — those stay in your private init.

---

## Setup

This is a **local-but-shareable** package: a self-contained, publishable package
that currently lives inside dotfiles. Its own `use-package` block owns loading it
(via `:load-path`), so it behaves exactly like a fetched package and does not
depend on any global `load-path` setup. The *enablement* lives next to your
emacs-slack config, because the important-channel list is context-specific —
i.e. in your private/context overlay (e.g. `dotfiles-overlays/<context>/emacs/…`),
right after the `(use-package slack …)` block:

```elisp
(use-package slack-attention
  :ensure nil                           ; local package; do not let elpaca fetch
  ;; Lambda (not a bare form): use-package treats a list as a list-of-paths.
  :load-path (lambda () (list (expand-file-name "lisp/slack-attention" emacs-root)))
  :after slack                          ; load + configure once emacs-slack is up
  :custom
  (slack-attention-important-channels
   '("team-foo" "help-bar"))          ; your important channels (names, no '#')
  :bind (("C-c s a" . slack-attention-show)   ; attention panel
         ("C-c s u" . slack-catch-up))        ; unread catch-up
  :config
  (slack-attention-setup))
```

### Extracting to its own repo later

Because the block above is self-contained, publishing this directory as a
standalone repo is a one-line swap — replace the `:ensure nil` + `:load-path`
lines with an elpaca recipe, and nothing else in the block changes:

```elisp
  :ensure (slack-attention :host github :repo "USER/slack-attention")
```

Notes:

* **`:ensure nil`** is required — your config sets `elpaca-use-package-always-ensure`,
  so without it elpaca would try to fetch a recipe for this local package.
* **`:load-path`** points at this directory relative to `emacs-root` (defined in
  `emacsrc`), so the package is found without any global `add-path`.
* **`:after slack`** defers loading and `:config` until emacs-slack is up, so it
  works regardless of where/when `slack` itself is configured.
* `slack-attention-setup` installs the capture/notification advice, loads any
  items persisted from your last session, and saves them on exit. `M-x
  slack-attention-teardown` removes all advice and hooks.

If you prefer not to use `use-package`, the equivalent is:

```elisp
(add-to-list 'load-path (expand-file-name "lisp/slack-attention" emacs-root))
(with-eval-after-load 'slack
  (require 'slack-attention)
  (slack-attention-setup))
```

---

## What interrupts you (the notification policy)

By default an item is raised (and the OS banner fires) only for:

* **any direct message** to you,
* **every message** in your important channels
  (`slack-attention-important-channels`), and
* a **direct `@`-mention of you** anywhere.

It deliberately does **not** fire for `@here` / `@channel` / `@everyone`
(those are broadcasts, not direct mentions), and never for your own messages.

This policy drives **both** the OS banner and the panel: `slack-attention-setup`
overrides emacs-slack's `slack-message-notify-p` with `slack-attention-notify-policy`.
To instead keep emacs-slack's own notification decision and only *add* the panel
on top, set `slack-attention-control-notifications` to nil before setup.

Your important channels default to:

```elisp
(setq slack-attention-important-channels
      '("team-foo" "help-bar"))          ; your important channels (names, no '#')
```

Names are as emacs-slack reports them, **without** a leading `#`. Edit that list
(or `M-x customize-group RET slack-attention`) to change what counts as important.

---

## Attention panel (`*Slack Attention*`)

`C-c s a` (or `M-x slack-attention-show`). Newest-relevant items accumulate here
and persist across restarts.

| Key            | Action                                                        |
|----------------|---------------------------------------------------------------|
| `RET` / `mouse-1` | Open the room, land point on this exact message, and remove the item from the list (you're handling it). Scroll up for channel context if you want it. |
| `d`            | Done — remove the item (without jumping)                       |
| `s`            | Snooze `slack-attention-snooze-minutes` (default 15), then it re-surfaces automatically |
| `C-u N s`      | Snooze for N minutes                                           |
| `u`            | Un-snooze everything                                           |
| `g`            | Refresh                                                        |
| `C`            | Clear all (asks first)                                         |
| `q`            | Bury the panel (items are kept)                                |

**Deferring is safe**: leaving an item in the panel (or snoozing it) keeps it —
it's still there when you come back, and survives an Emacs restart. After a
restart, jump-back works once Slack has reconnected; if an item can't resolve its
room yet, the panel tells you which team/room to open.

The panel pops as a side window and gently raises the frame (no focus stealing).
Tune with `slack-attention-side`, `slack-attention-window-size`,
`slack-attention-raise-frame`, `slack-attention-auto-pop`.

---

## Catch-up buffer (`*Slack Catch-up*`)

`C-c s u` (or `M-x slack-catch-up`). Lists every conversation with unreads
(DMs, group DMs, channels) across all connected teams, newest first, with the
latest-message preview. The `@N` column flags N direct mentions waiting there.

| Key            | Action                                    |
|----------------|-------------------------------------------|
| `RET` / `mouse-1` | Open the room (reading it marks it read) |
| `n` / `p`      | Next / previous                           |
| `g`            | Refresh                                   |
| `q`            | Quit                                      |

Unread state comes from emacs-slack's counts API (the team's `counts` slot), not
the (unpopulated) `slack-room-has-unread-p`, so it reflects real server-side
unread/mention counts.

---

## Customization summary

`M-x customize-group RET slack-attention`, or set before/after `slack-attention-setup`:

| Variable | Default | Meaning |
|----------|---------|---------|
| `slack-attention-important-channels` | your 5 channels | Channels whose every message is flagged |
| `slack-attention-notify-dms` | `t` | Flag all DMs |
| `slack-attention-muted-dm-senders` | `nil` | DM partner name substrings to silence (e.g. bot/app DMs like GitHub, Confluence) |
| `slack-attention-notify-direct-mentions` | `t` | Flag direct `@you` mentions |
| `slack-attention-control-notifications` | `t` | Override `slack-message-notify-p` (policy drives banner too) |
| `slack-attention-snooze-minutes` | `15` | Default snooze length |
| `slack-attention-side` | `right` | Panel side |
| `slack-attention-window-size` | `60` | Panel width/height |
| `slack-attention-raise-frame` | `t` | Raise frame on new item |
| `slack-attention-auto-pop` | `t` | Auto-show panel on new item |
| `slack-attention-file` | `~/.emacs.d/slack-attention-items.el` | Persistence file |

---

## Notes / limitations

* **Verified live** against your team: DM detection, channel matching, and the
  direct-vs-broadcast mention distinction (`<@your-id>` matches; `<!here>` /
  `<!channel>` do not) all pass. Catch-up runs error-free (there were simply 0
  unreads when it was tested).
* Catch-up previews are best-effort: if a room's latest message hasn't been
  fetched into Emacs yet, the preview shows `(no preview)` — opening the room
  loads it.
* Possible enhancements (ask if you want them): land exactly on the mentioned
  message (not just the room), a dedicated "deferred" section, desktop-banner
  wording tuned per category.
