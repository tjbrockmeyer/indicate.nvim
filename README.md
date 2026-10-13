# Indicate

> This repo is entirely vibe-coded. I cannot be bothered to learn the intricacies of neovim plugin creation.
> Instead, I can simply get the plugin I want in pretty quick time. I don't care what the code looks like.

Keep the pass/fail state of your checks (tests, linters, builds, …) visible
while you edit.

Indicate stores, per repository, a `.indicate` directory with a `config.json`
describing your indicators plus the result, file hash and logs of the last run
of each one. The panel shows a dot per indicator:

| dot | meaning                                       |
| --- | --------------------------------------------- |
| ●   | last run exited `0` (green)                   |
| ●   | last run exited non-zero (red)                |
| ●   | never ran (grey)                              |
| ◐   | currently running (yellow)                    |
| `*` | matched files changed since the last run      |

## Commands

| command     | description                                            |
| ----------- | ------------------------------------------------------ |
| `:Indicate` | Toggle the indicator panel (default keymap `<leader>I`) |

## Configuration

`<repo root>/.indicate/config.json`:

```json
{
  "version": 1,
  "indicators": [
    {
      "name": "unit tests",
      "cwd": ".",
      "command": "go test ./...",
      "files": ["**/*.go", "go.mod"]
    }
  ]
}
```

- `name` – unique name of the indicator, also used for the artifact filenames.
- `cwd` – directory the command runs in, relative to the repository root
  (absolute paths are allowed).
- `command` – shell command, run with `&shell`.
- `files` – glob patterns of the files this check depends on, relative to
  `cwd`. `**` does not match dotfiles, so write `.github/**/*.yml` explicitly.
  Files are found by walking the tree, so `.gitignore`d directories,
  symlinked directories and these directories are never entered: `.git`,
  `.jj`, `.indicate`, `.venv`, `venv`, `node_modules`, `__pycache__`,
  `.mypy_cache`, `.pytest_cache`, `.ruff_cache`, `.tox`, `.gradle`, `.next`,
  `.nuxt`, `.turbo`, `.parcel-cache`, `.cache`. Patterns matching files inside
  them find nothing.

## Usage

`:Indicate` toggles the side panel. When the cwd is not inside a repository
with a `.indicate` directory yet, the panel offers to create one.

| key | action                                          |
| --- | ----------------------------------------------- |
| `r` | run the indicator under the cursor              |
| `R` | run **all** indicators, in parallel processes    |
| `l` | show the logs (live while running)              |
| `n` | create a new indicator with the wizard          |
| `e` | edit the indicator under the cursor             |
| `J` | move the indicator down in `config.json`         |
| `K` | move the indicator up in `config.json`           |
| `q` | close the panel                                 |

- `n` walks through the attributes one at a time (name, cwd, command, glob
  patterns) and adds the new indicator to `config.json`.
- `e` opens the attribute menu of the indicator under the cursor; hovering an
  attribute previews its current value in the pane on the right, `<CR>` edits
  it, `q` quits. Attributes are written back to `config.json` immediately.
- `l` opens the logs of the indicator under the cursor. While it is running
  the window follows the live output of the process; `q` closes it and moves
  the cursor back to the panel.

The panel refreshes itself when files are written, on `FocusGained` and when
the cwd moves to another repository.

## Layout of `.indicate`

```
.indicate/
├── config.json
├── indicate.log          # debug/performance log (`debug` option)
├── hash-cache.json       # cached per-file digests, keyed by size/mtime
└── runs/
    ├── unit_tests-result   # exit code of the last run
    ├── unit_tests-hash     # hash of the matched files at that time
    └── unit_tests-logs     # stdout/stderr of the last run
```

The `.indicate` directory is created at the repository top level
(`git rev-parse --show-toplevel`, falling back to `jj root`, then the cwd) and
is found again by walking up the tree from the cwd.

## Options

```lua
require("indicate").setup({
  panel = { width = 32, hints = true },
  refresh_debounce = 300, -- ms
  max_log_lines = 2000,
  notify_on_run = false,
  debug = true, -- timing log in .indicate/indicate.log
})
```

With `debug` enabled, the operations that can plausibly be slow - walking the
file tree, reading and hashing the matched files, the `git`/`jj` lookups,
rendering the panel, spawning a run - are timed and appended to
`.indicate/indicate.log`, one line per operation. Nested operations are
indented, so a slow outer operation can be traced back to the inner one that
dominates it:

```
2025-06-01 10:00:00 | panel.refresh: 1.20 ms
2025-06-01 10:00:00 |   state.status(unit tests): 0.90 ms
2025-06-01 10:00:00 |     hash.hash: 0.80 ms 1203 file(s)
2025-06-01 10:00:00 |       hash.files: cached (1203 file(s))
```

The matched file list is cached and reused across refreshes, so editing a file
does not walk the tree; it is only re-walked when a directory changes (a file
added, removed or renamed). A write re-hashes just the written file for the
indicators whose patterns match it; the rest of the cached list is reused.
Per-file digests are cached in `.indicate/hash-cache.json`, keyed by size and
mtime, so a new Neovim session only reads the files that changed since the last.

Set `debug = false` to stop writing the log; it is rotated to
`indicate.log.1` once it grows past 2 MiB.
