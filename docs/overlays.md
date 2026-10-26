# Overlays in depth

The README introduces overlays. This is the reference: how `install.sh`
picks them, what each tool reads from them, in what order, and what kind of
content belongs in which overlay.

## Selection: the manifest and host patterns

`install.sh` reads the overlay manifest, `$DOTFILES_MANIFEST` (default
`~/.config/dotfiles/overlays`). Each line is `name url [match]`. A line
whose first word starts with `#` is a comment.

- `match` is `always`, a shell glob tested against the host name, or several
  globs joined with `|`. A plain glob held in a variable cannot alternate,
  so `install.sh` splits on `|` and tests each glob in turn.
- The host name is `hostname -f`, or the first argument to `install.sh` when
  one is given.
- An omitted `match` means `always`.

With no manifest, `install.sh` writes a commented template and fetches no
overlays. The manifest lives outside every repo, so overlay names, URLs and
host patterns stay private.

The selected overlays are listed in manifest order as a suggested apply
order. On a terminal you can accept it or type a new order by number.
`install.sh` then clones or fast-forwards each overlay into
`~/lib/dotfiles-overlays/<name>/`, writes the names of the overlays it has a
clone of to `~/lib/dotfiles-overlays/.order`, and runs the base `link.sh`.
An overlay that fails to clone warns and is skipped. One whose pull fails
warns and keeps its old clone. Only the base is required.

## What each tool reads from an overlay

The base names no overlay. Each tool finds overlays by a glob, or through
`.order`.

| Tool          | Reads                                    | Order          |
|---------------|------------------------------------------|----------------|
| bash          | `*/bash/*.sh`, from `bash/bashrc`        | glob           |
| Emacs         | `*/emacs/*.el`, from `emacs/emacsrc`     | glob           |
| ssh           | `*/ssh/config`, from `ssh/config`        | glob           |
| tmux          | `*/tmux/*.conf`, from `tmux/tmux.conf`   | glob           |
| `link.sh`     | each overlay's `link.sh`                 | `.order`       |
| git           | paths an overlay's `link.sh` registers   | `.order`       |
| `repo-sync`   | `*/repo-sync/repos.list`                 | `.order`       |
| `check.sh`    | `*/check.sh`, run as `check.sh test`     | glob           |

`.order` governs only the rows that say so. The globbed tools expand the
glob themselves, so their order is the glob's order by overlay name, and
`.order` does not change it. bash sorts a glob by the locale's collation.
`file-expand-wildcards` sorts in `string<` order. The two can differ for
names that differ in case or punctuation. `link.sh` and `repo-sync` fall
back to the sorted directory list when `.order` is missing.

The Claude Code config does not read overlays. It has its own manifest and
its own repos under `~/.claude` (see the README).

## Precedence, tool by tool

The base always loads first, and an overlay layers on top of it. How "on
top" works differs per tool.

- **bash.** Overlay files are sourced partway through `bashrc`, after the
  path helpers and before the prompt. A later assignment wins, so an
  overlay can override anything the base set before the glob.
- **Emacs.** Overlays load after the whole base configuration. Each `load`
  is wrapped in `condition-case`, so one overlay that errors is skipped with
  a warning instead of aborting the rest. The base defines the variables
  that overlays extend, such as the list of IMAP inboxes, so an overlay can
  append to them.
- **ssh.** The `Include` comes before the base's `Host *` block, and ssh
  keeps the first value it reads for an option. So an overlay's `Host`
  entries win over the base defaults.
- **tmux.** `source-file -q` runs at the end of `tmux.conf`, so an overlay
  setting overrides the base. `-q` suppresses the error on a machine with
  no overlay files.
- **git.** See the next section.
- **Files an overlay deploys.** Each overlay's `link.sh` runs in `.order`.
  Two overlays that link the same target leave the later one's link.

## How git config composes

The base does not deploy `~/.gitconfig`. It ships `git/gitconfig`, a
generic fragment, and leaves the entry point to an overlay. That keeps the
choice of identity out of the public repo.

`link.sh` rewrites `~/.gitconfig.overlays` from scratch on every run. An
overlay adds itself with `gcoverlays_add "$OV/git/config"` in its own
`link.sh`, which appends one `path =` line. Overlays run in `.order`, so the
lines follow it.

The entry point a personal-config overlay deploys as `~/.gitconfig` then
includes, top to bottom:

1. the base `git/gitconfig`
2. its own settings, such as a personal identity by `includeIf "gitdir:"`
3. the generated `~/.gitconfig.overlays`
4. `~/.gitconfig.local`, hand-written and true of one machine only

Git config is last value wins, so a setting in a work overlay listed after
the personal ones overrides theirs. `~/.gitconfig.local` wins over the rest
of the global config. `link.sh` never writes it, and git skips a missing
include.

## Three overlays and what goes in each

The README's example uses three overlays. Each is its own repo, and its
visibility decides what may go in it.

**personal-config.** Your choices that are safe to publish: the git entry
point, the global git hook chain, editor settings, key maps and the like.
It runs on every machine you own. It holds no secrets and nothing that
names an employer.

**personal-secret.** Private and personal: your name and email, mail and
news setup and anything that identifies you or your accounts. It also
runs on every machine you own, but its remote is private.

**work.** Private and employer-specific: the work identity, internal hosts
and ssh aliases, work tools, and anything that names the employer. Its
manifest `match` limits it to work hosts, and a personal machine never
clones it.

A setting that is true of one machine only goes in `~/.gitconfig.local` or
the tool's own local file, not in any overlay.

## The trust boundary

A repo's visibility is its trust boundary. The base and a public overlay are
authored public. Nothing is ever filtered out of a private repo to make a
public one, because filtering is how secrets escape.

References run one way. A private overlay may name the base and the paths it
deploys. The base names no overlay at all. A public overlay should name no
private one.

When a public overlay needs private data, it reads it through a deployed
path and never through the overlay that provides it. For example, the hook
chain in personal-config reads its term lists from `~/.config`, and the work
overlay's `link.sh` links them there. personal-config's `link.sh` chmods
those paths to 600 when they exist, without knowing which overlay provided
them. On a machine with no work overlay the files are absent and nothing is
said.

## Writing an overlay's `link.sh`

The README gives the template. Three helpers from `link-lib.sh` do the
work:

- `link SRC DEST` replaces a symlink, moves a real file aside as
  `DEST.pre-dotfiles.<epoch>`, and creates the parent directory.
- `unlink_managed DEST` removes `DEST` only if it is a symlink into a
  dotfiles tree, so a retired link goes and a real file stays.
- `gcoverlays_add FILE` registers a git config fragment.

After every overlay has run, `link.sh` reports a symlink in `$HOME`, or in a
directory it linked into, that still dangles into a dotfiles tree. That
means an overlay stopped shipping a file without retiring its link, and it
is a bug in that overlay.

An overlay that has tests ships an executable `check.sh`. The base
`check.sh` runs `check.sh test` in each overlay it finds.
