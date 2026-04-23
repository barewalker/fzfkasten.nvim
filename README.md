# Fzfkasten.nvim

A super lightweight and fast Zettelkasten plugin for Neovim, powered by `fzf-lua`.

## Core Design Principles

- **Dependency:** Relies on `ibhagwan/fzf-lua` and `ripgrep` (rg).
- **Customizable:** All behaviors (tag notation, link format, directory structure) are user-configurable.
- **LazyVim Ready:** Optimized for lazy loading with a separate `setup` function.
- **Extensible:** Includes hooks for integrating external tools like Google Calendar.

## Plugin Status

**Note: This plugin is currently under construction.** While the core features are functional, some advanced behaviors are still being refined.

### Implemented Features
- [x] **Find Notes**: Fast note searching using `fzf-lua` with robust icon handling.
- [x] **Grep Content**: Live grep through your entire Zettelkasten.
- [x] **Daily/Weekly Notes**: Automatic creation from templates with configurable directories.
- [x] **Tag Search**: Search for `#tags` across all notes.
- [x] **Link Insertion**: Interactive link insertion with `[[` trigger.
- [x] **Follow Link**: Jump to the note under the cursor.
- [x] **Backlinks**: Find all notes linking to the current note.
- [x] **Rename Note**: Rename a note and automatically update all internal links.
- [x] **Template Engine**: Simple `{{title}}`, `{{date}}`, and `{{hdate}}` placeholders.
- [x] **External Commands**: Append external data (like `gcalcli`) to daily notes.
- [x] **Fzfkasten Panel**: A central menu for common actions (Open, Backlinks, Rename, Delete).
- [x] **New Templated Notes**: Create new notes from predefined templates with interactive selection.
- [x] **Find Daily Notes**: Interactively find and open existing daily notes.
- [x] **Find Weekly Notes**: Interactively find and open existing weekly notes.
- [x] **Claude Code Integration**: Optional integration with `claudecode.nvim` to send notes/selections to Claude (disabled by default).
- [x] **Link Aliasing**: `[[note|alias]]` syntax is supported across follow link, backlinks, and rename.

### Pending / Under Development
- [ ] Better sanitization and customization for file naming.
- [ ] Expanded template placeholders and logic.
- [ ] Enhanced image preview integration.

## Installation

### LazyVim

```lua
{
  "barewalker/fzfkasten.nvim",
  dependencies = { "ibhagwan/fzf-lua" },
  config = function()
    require("fzfkasten").setup({
      -- Your custom settings go here
    })
  end,
}
```

## Configuration

Here is the default configuration. You can override any of these settings in the `setup` function.

```lua
{
  home = os.getenv("ZETTELKASTEN_HOME") or vim.fn.expand("~/notes"),
  extension = "md",
  patterns = {
    tag = [[#([%w_-]+)]],
    link = [[%[%[(.-)%]%]],
  },
  notes = {
    daily = {
      dir = "daily",
      format = "%Y-%m-%d",
      template = "templates/daily.md",
      use_external_cmd = false,
      external_cmd = "gcalcli agenda --tsv",
    },
    weekly = {
      dir = "weekly",
      format = "%Y-W%V",
      template = "templates/weekly.md",
    },
  },
  transform = {
    insert_link = function(filename)
      return string.format("[[%s]]", filename)
    end,
    new_file_name = function(title)
      return title
    end,
  },
  claude = {
    enabled = false, -- set to true to enable Claude Code integration
  },
  fzf = {
    winopts = {
      height = 0.85,
      width = 0.80,
      preview = { layout = "vertical" },
    },
    files = {
      previewer = "builtin",
    },
  },
}
```

## Usage

Fzfkasten provides several commands for managing your Zettelkasten notes:

*   **`:FzfKastenNewNote`**: Creates a new note. You will be prompted for a title and then presented with an `fzf-lua` picker to select an optional template from your `home/templates` directory. If no template is selected, it defaults to a basic note structure.

*   **`:FzfKastenFindDailyNotes`**: Opens an `fzf-lua` picker to search and open existing daily notes from your `home/daily` directory.

*   **`:FzfKastenFindWeeklyNotes`**: Opens an `fzf-lua` picker to search and open existing weekly notes from your `home/weekly` directory.

*   **`:FzfKastenSearchByTag`**: First presents a list of all unique tags in your Zettelkasten, then displays notes containing the selected tag.

*   **Other existing commands:** (e.g., `:FzfKastenDaily`, `:FzfKastenWeekly`, `:FzfKastenFindNotes`, `:FzfKastenTags`, `:FzfKastenInsert`, etc.)

## Claude Code Integration

Fzfkasten provides optional integration with [claudecode.nvim](https://github.com/coder/claudecode.nvim) to send notes or selections to Claude Code directly from your editor.

### Setup

1. Install `coder/claudecode.nvim` as an additional dependency.
2. Enable the integration in your setup:

```lua
require("fzfkasten").setup({
  claude = {
    enabled = true,
  },
})
```

### Commands

*   **`:FzfKastenClaudeSendBuffer`**: Send the entire current note to Claude as an `@mention`.
*   **`:FzfKastenClaudeSendSelection`**: Send the visual selection to Claude.
*   **`:FzfKastenClaudeToggle`**: Toggle the Claude terminal.

### Example Keymaps

```lua
{ "<leader>kc", "<cmd>FzfKastenClaudeSendBuffer<CR>", desc = "Send note to Claude" },
{ "<leader>kc", "<cmd>FzfKastenClaudeSendSelection<CR>", mode = "v", desc = "Send selection to Claude" },
{ "<leader>kC", "<cmd>FzfKastenClaudeToggle<CR>", desc = "Toggle Claude terminal" },
```

If `claudecode.nvim` is not installed or `claude.enabled` is `false`, the commands will show a warning and do nothing — fzfkasten continues to work normally.

## Google Calendar Integration

To integrate with Google Calendar, you need to have `gcalcli` installed and configured. Then, you can enable it in the setup:

```lua
require("fzfkasten").setup({
  notes = {
    daily = {
      use_external_cmd = true,
    },
  },
})
```

This will append the output of `gcalcli agenda --tsv` to your new daily notes.

## Image Preview

Image preview in the note finder (`find_notes`) depends on your `fzf-lua` configuration. To enable image previews, you need to have a compatible terminal and an image previewer program installed. Please refer to the `fzf-lua` documentation for more details on how to set up image previews.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

