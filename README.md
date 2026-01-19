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
- [x] **Find Notes**: Fast note searching using `fzf-lua`.
- [x] **Grep Content**: Live grep through your entire Zettelkasten.
- [x] **Daily/Weekly Notes**: Automatic creation from templates with configurable directories.
- [x] **Tag Search**: Search for `#tags` across all notes.
- [x] **Link Insertion**: Interactive link insertion with `[[` trigger.
- [x] **Follow Link**: Jump to the note under the cursor.
- [x] **Backlinks**: Find all notes linking to the current note.
- [x] **Template Engine**: Simple `{{title}}`, `{{date}}`, and `{{hdate}}` placeholders.
- [x] **External Commands**: Append external data (like `gcalcli`) to daily notes.
- [x] **Fzfkasten Panel**: A central menu for common actions.

### Pending / Under Development
- [ ] Improved link aliasing support (`[[note|alias]]`).
- [ ] Better sanitization and customization for file naming.
- [ ] Expanded template placeholders and logic.
- [ ] Enhanced image preview integration.
- [ ] More robust "Delete Note" flow within the panel.

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

