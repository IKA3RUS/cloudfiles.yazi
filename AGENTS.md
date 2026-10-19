# AGENTS.md

Internals for anyone changing this plugin. `README.md` is for users; keep it
at the level of other popular yazi plugins and put internals here.

## Overview

A single-file yazi plugin (`main.lua`, yazi 26.9.1+, macOS only) for File
Provider placeholders: files whose BSD flags include `dataless`
(`stat -f %Sf` → `compressed,dataless`). Reading even one byte makes macOS
download the whole file and block until it arrives. Metadata calls (`stat`,
`fs.cha`) never download.

### Core idea

Placeholders get the MIME type `cloud/placeholder`. Yazi's stock fetcher runs
`file --mime-type` on every visible file, which reads (downloads) it, and
previewers/preloaders match on MIME. A MIME type nothing else matches keeps
every built-in and third-party previewer away from placeholders while local
files stay completely stock.

### Entry points

- `fetch`: replaces `mime.local` for the configured paths. One batched
  `stat` call; placeholders get `cloud/placeholder`, the rest are forwarded
  to `mime.local`.
- `setup`: adds the list marker (`Linemode`) and the counter (`Status`).
- `entry` (Enter/`o`/`O`): no placeholders among the targets → plain `open`.
  Otherwise download with `head -c1`, then `refresh` the MIME types and
  `open` everything that landed.
- `peek`: the placeholder card. If the file has become local, it calls
  `refresh` and yazi re-peeks with the normal previewer.

## Rules that must hold

- **Only path strings cross `ya.sync` and `ya.emit`.** Url userdata passed in
  is moved and the caller's copy is destroyed (`userdata has been destructed`).
  Make a fresh `Url(p)` right before each emit.
- **`fetch` must report every file it was given**, or yazi retries them.
- **Never read a placeholder outside `entry`.** That includes `file`, `head`,
  previews and preloads.
- **`PARALLEL` is global.** Slots are shared state (`take_slot`/`free_slot`),
  not per press.
- **Notify only on final failure** (title "Uh Oh!"). Progress is shown by the
  markers and the counter.

## Edge cases

### Yazi (26.9.1)

- **Errors in `entry` are silent.** The task just sits at "1 left". Debug
  with `ya.err` and `pcall`. Log: `~/.local/state/yazi/yazi.log`.
- **URL globs containing `/` use literal separators.** `*` doesn't cross `/`,
  so write `**/Library/CloudStorage/**`.
- **`mime.local`'s `match_mimetype` needs the trailing newline.** Split
  `file` output with `[^\n]*\n`.
- **The Linemode is drawn over the row style.** On a reversed hovered row
  (`th.indicator.current`), a plain `fg` marker becomes a colored block.
  `marker()` pre-swaps fg/bg so the reversal swaps them back.
- **Linemode order:** `solo` (the date etc.) is at 1000, so the marker's
  default of 500 puts it before the date.

### macOS and sync apps

- **Multi-path `stat` skips unreadable paths**, so output lines stop lining
  up with the arguments. `dataless()` checks the exit status and falls back
  to one call per path.
- **SeaDrive refuses downloads in a folder that just changed on the server.**
  The parent folder's listing fails (`NSFileProviderErrorDomain -2005`) and
  `head` exits 1 after about 0.5 s; it works seconds later, hence
  `RETRY_WAIT`. Inspect with
  `/usr/bin/log show --last 10m --predicate 'process == "fileproviderd"'`
  (plain `log` is a zsh builtin).
- **A stalled provider blocks `head` forever.** There is no timeout, so the
  marker stays on "downloading".
- **Local → placeholder ("Remove Download") is unverified.** It changes ctime,
  which is part of yazi's fetch-cache signature, but whether yazi's watcher
  reports flag-only changes is untested. The README tells users to restart.

### Terminal rendering

- **Ghostty draws a Nerd Font icon two cells wide only if the next cell is
  blank.** Themes may put `indicator.padding` (e.g. `█`) right after the
  linemode, so every marker carries its own trailing space.
- **A terminal can't report its font,** so Nerd Font use is a setting
  (`nerd_font = false` → ○/◐).

## Testing

There are no automated tests. Run a real yazi with an isolated config:
`YAZI_CONFIG_HOME` pointing at a temp dir containing the README snippets and
`plugins/cloudfiles.yazi` symlinked to this repo, driven through tmux
(`send-keys`, then `capture-pane -e` to see styles).

- **Real placeholders can't be created by hand.** Put fake `stat`/`head`
  scripts first on `PATH`:
  - `stat` reports `dataless` for files under a folder whose path contains
    `Library/CloudStorage`, until a marker file exists.
  - `head` sleeps, then creates the marker. Name patterns can make it fail
    always or only on the first tries.
  - An opener like `echo OPENED %s >> log` shows what `open` received.
- **Things to check:**
  - Browsing downloads nothing: compare `stat -f %Sf` before and after.
  - Never more than `PARALLEL` `head` processes, even across several presses.
  - A failed file keeps its cloud marker while the rest still open.
  - Pressing twice downloads once.

API reference: the yazi source at the matching tag, mainly
`yazi-plugin/preset/{plugins,components}/`.

## Conventions

- Code style follows yazi's presets: tabs, double quotes, and comments that
  explain why, not what.
- `ya pkg` installs `main.lua`, `README.md`, `LICENSE`, kebab-case `*.lua`
  files and everything in a top-level `assets/` folder. Keep repo-only files
  (this file, `CLAUDE.md`, the README screenshot in `.github/`) out of
  `assets/`.
- Update the README's "Tested on" section and AI attribution when either
  changes.
- The AI attribution is the toolkit's abbreviated-statement HTML from
  https://aiattribution.github.io/create-attribution, pasted unchanged after
  one plain sentence. GitHub strips the icons (inline `<svg>`), leaving a
  plain link; that is intended. When the answers change (e.g. `Nr` → `R`),
  paste the new HTML.
