# diffedit.nvim

Edit `.diff` / patch files as real documents. Instead of deleting and re-typing
lines, you edit `+` / `-` prefixed lines directly; diffedit keeps the `@@`
hunk counts in sync, flags broken structure, and highlights the reconstructed
code with treesitter.

https://github.com/djakidjo/diffedit.nvim

The gap this fills: git's own `git add -p` has an editor mode, but there is no
standalone, validated `.diff` editor. Existing plugins either only recompute
`@@` inside a `git add -p` temp buffer (`rehunk.nvim`), only apply patches to
lazy.nvim packages (`patchr.nvim`, `lazy-patcher.nvim`), or only visualize
diffs (`patchview.nvim`, `jj-diff-stage.nvim`).

## Features

- **Auto-recalculated hunk headers** — `@@ -12,5 +12,6 @@ tail` is recomputed
  from the actual body lines on write (and via `:DiffRecalc`). Idempotent.
- **`o` / `O` on `+`/`-` lines** — inserts a new line with the same prefix and
  indent, so adding a line means `o` + type, not `O` + `+` + delete.
  Outside `+`/`-` lines the default behavior is preserved.
- **Validation** via `vim.diagnostic`:
  - `ERROR` — body line outside of any hunk header (broken structure),
  - `WARN` — hunk `old`/`new` counts differ from the actual body.
- **Treesitter highlighting** — the target file is reconstructed from ` ` and
  `+` lines, parsed in a scratch buffer, and the captures are copied back as
  extmarks (e.g. `@keyword.lua`, `@number.lua`).
- **`:DiffApply`** — `git apply --recount` on the current buffer (tolerant of
  stale hunk numbers). Runs in the git worktree root.
- **`:DiffShow`** — opens the target file side-by-side (or `git show HEAD:path`
  when it is not on disk).

## Requirements

- Neovim 0.11+
- treesitter parsers for the languages you edit diffs of (optional, for
  highlighting)

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "djakidjo/diffedit.nvim",
  ft = "diff",
  config = function()
    require("diffedit").setup()
  end,
}
```

## Usage

Open a `.diff` file. It is picked up automatically (FileType `diff`):

- `o` on a `+` line — new added line below with the same indent
- `O` on a `-` line — new removed line above with the same indent
- `:w` — recalculates `@@` counts, re-validates, re-highlights

Commands:

| Command        | Effect                                             |
| -------------- | -------------------------------------------------- |
| `:DiffRecalc`  | Recompute `@@` counts from the body lines          |
| `:DiffCheck`   | Run validation and report via `vim.diagnostic`     |
| `:DiffApply`   | `git apply --recount` the current buffer           |
| `:DiffShow`    | Open the target file in a vsplit                   |

## Options

```lua
require("diffedit").setup({
  -- Enable treesitter-based code highlighting
  hl_code = true,
  -- Build the highlight group from a capture + language
  hl_group = function(capture, lang)
    return "@" .. capture .. "." .. lang
  end,
})
```

## Limitations

- Highlighting works for single-file diffs only (exactly one `+++` line).
- Applying to the worktree requires the diff to be in a git repository.

## Similar plugins

- `jetm/rehunk.nvim` — hunk count fixups, only in the `git add -p` editor buffer
- `nhu/patchr.nvim`, `one-d-wide/lazy-patcher.nvim` — patches for lazy.nvim
- `sminrana/nvim-filediff`, `moha-abdi/patchview.nvim` — diff viewing only
