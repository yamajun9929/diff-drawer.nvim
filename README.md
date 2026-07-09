# diff-drawer.nvim

Git change explorer for Neovim, built on the same Snacks picker UI used by
LazyVim's `Snacks.explorer`.

The intent is "Cmd-B explorer, but only Git changes":

- changed files are shown in the same left sidebar layout
- paths are rendered as a tree with the same icons, colors, and status markers
- `<CR>`/`l` opens an editable vimdiff: left side is the Git baseline, right
  side is the working-tree file
- `o` opens the working-tree file
- `s`/`u` stage and unstage
- `x` discards unstaged changes with confirmation

## Requirements

- Neovim 0.10+
- Git
- [snacks.nvim](https://github.com/folke/snacks.nvim)

## Installation

With lazy.nvim:

```lua
{
  "yamajun9929/diff-drawer.nvim",
  dependencies = { "folke/snacks.nvim" },
  config = function()
    require("diff_drawer").setup()
  end,
  keys = {
    {
      "<leader>gS",
      function()
        require("diff_drawer").toggle()
      end,
      desc = "Git change explorer",
    },
  },
}
```

To try it once without installing:

```sh
nvim +'set runtimepath+=~/projects/diff-drawer.nvim' \
  +'runtime plugin/diff-drawer.lua' \
  +'DiffDrawer'
```

## Commands

- `:DiffDrawer` toggles the sidebar
- `:DiffDrawerOpen` opens it
- `:DiffDrawerClose` closes it and its diff windows
- `:DiffDrawerRefresh` refreshes Git status
- `:DiffDrawerStageAll` stages all changes
- `:DiffDrawerUnstageAll` unstages all changes
- `:DiffDrawerToggleLayout` switches tree/list layout

## Default Keys

Inside the sidebar:

| Key | Action |
| --- | --- |
| `<CR>` / `l` | Open/collapse directory, open editable file diff |
| `o` | Open working-tree file |
| `s` | Stage selected file |
| `u` | Unstage selected file |
| `S` | Stage all |
| `U` | Unstage all |
| `x` | Discard selected unstaged change |
| `r` | Refresh |
| `h` | Collapse directory |
| `/` | Move focus to search, matching Snacks picker behavior |
| `<Esc>` | Close/cancel, matching Snacks picker behavior |

Discard uses `git restore --worktree` for tracked files and `git clean -fd` for
untracked files, after confirmation. Unlike VS Code, this does not move files to
the OS Trash.

## Configuration

```lua
require("diff_drawer").setup({
  git_executable = "git",
  snacks = {
    -- Passed into the Snacks picker setup used by this plugin.
    layout = { preset = "sidebar" },
    title = "Git Changes",
  },
})
```

## Notes

- File rendering intentionally follows Snacks explorer rather than Diffview's
  file panel.
- In diff view, edit the right pane and save normally. The left pane is a
  scratch baseline buffer.
- The picker shows each changed path once with its porcelain Git status.
- A file with both staged and unstaged changes can be staged with `s`; use `u`
  to unstage the staged part.
- Discard only applies to unstaged changes. Unstage first if you want to discard
  a staged change.

## License

MIT. See [LICENSE](LICENSE).

This plugin depends on [snacks.nvim](https://github.com/folke/snacks.nvim),
which is licensed under Apache-2.0. Snacks is not vendored in this repository.

Git is a trademark of Software Freedom Conservancy. This project is not
affiliated with the Git Project, Software Freedom Conservancy, Microsoft,
Visual Studio Code, Diffview, or snacks.nvim.
