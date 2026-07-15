# Fzfkasten.nvim

A super lightweight and fast Zettelkasten plugin for Neovim, powered by `fzf-lua`.

## Core Design Principles

- **Dependency:** Relies on `ibhagwan/fzf-lua` and `ripgrep` (rg).
- **Customizable:** All behaviors (tag notation, link format, directory structure) are user-configurable.
- **LazyVim Ready:** Optimized for lazy loading with a separate `setup` function.
- **Extensible:** Includes hooks for integrating external tools like Google Calendar.

## Plugin Status

**Status: Beta.** All planned features are implemented and in daily use, but the API may still shift based on feedback and edge cases encountered in real-world usage.

### Implemented Features
- [x] **Find Notes**: Fast note searching using `fzf-lua` with robust icon handling.
- [x] **Grep Content**: Live grep through your entire Zettelkasten.
- [x] **Daily/Weekly Notes**: Automatic creation from templates with configurable directories.
- [x] **Tag Search**: Search for `#tags` across all notes.
- [x] **Link Insertion**: Interactive link insertion with `[[` trigger.
- [x] **Follow Link**: Jump to the link under the cursor (or pick from all links in the buffer). Resolves notes recursively across sub-directories, and can create missing notes from a template. Mappable to `gf` with a native-`gf` fallback.
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
- [x] **Filename Sanitization**: Unicode-safe default (preserves CJK) with a user-overridable `transform.sanitize_filename` hook.
- [x] **Template Placeholders**: Built-in `{{title}} {{date}} {{hdate}} {{year}} {{month}} {{day}} {{week}} {{time}}` plus user-defined entries via `template_placeholders` (string or function values).
- [x] **Image Preview**: Delegated to `fzf-lua`'s previewer; see the [Image Preview](#image-preview) section for configuration.
- [x] **Tasks**: Collect `- [ ]` checkboxes across every note, jump to the one you pick, and tick it off without leaving the picker. No index, no task file — see [Tasks](#tasks).

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
    -- Strips filesystem-unsafe characters (/\:*?"<>| and controls),
    -- trims and collapses whitespace, and removes leading/trailing dots.
    -- Unicode (CJK, emoji, accented) is preserved; override for ASCII-only
    -- or slug-style names.
    sanitize_filename = function(title)
      local s = title or ""
      s = s:gsub('[/\\:*?"<>|%c]', "")
      s = s:gsub("^%s+", ""):gsub("%s+$", "")
      s = s:gsub("%s+", " ")
      s = s:gsub("^%.+", ""):gsub("%.+$", "")
      return s
    end,
  },
  -- Extra placeholders merged on top of the built-ins. Values may be
  -- strings or functions receiving the note title.
  template_placeholders = {
    -- author = "barewalker",
    -- uuid = function() return vim.fn.system("uuidgen"):gsub("%s+$", "") end,
  },
  -- Tweaks applied to note buffers that fzfkasten itself opens (pickers,
  -- daily/weekly, follow-link, new note, etc.). See "Note buffer behaviour".
  note_buffer = {
    disable_diagnostics = true, -- turn off vim.diagnostic for the buffer
    disable_format = true,      -- set disable_autoformat / autoformat / format_on_save
    on_open = nil,              -- optional function(bufnr) for extra tweaks
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

## Note buffer behaviour

LSP diagnostics and autoformat are often noisy on prose. Every note buffer that
fzfkasten **itself** opens (via the pickers, daily/weekly notes, follow-link,
new note, rename, …) is therefore set up so that, by default:

- **diagnostics are disabled** for that buffer (`vim.diagnostic.enable(false, …)`), and
- **autoformat is disabled** — fzfkasten sets `vim.b.disable_autoformat = true`
  (honoured by [conform.nvim](https://github.com/stevearc/conform.nvim)) plus the
  generic `vim.b.autoformat` / `vim.b.format_on_save` flags.

This only affects buffers opened *through* fzfkasten — notes you open by other
means (`:edit`, netrw, another picker) are left untouched.

Turn either off in `setup`:

```lua
require("fzfkasten").setup({
  note_buffer = {
    disable_diagnostics = false, -- keep diagnostics on
    disable_format = false,      -- keep autoformat on
  },
})
```

### Custom format/diagnostic setups

Every fzfkasten-opened note buffer also gets a marker, `vim.b.fzfkasten = true`,
regardless of the flags above. If your format-on-save is a bespoke
`BufWritePre` autocmd (e.g. calling `vim.lsp.buf.format()` directly), gate it on
that marker:

```lua
vim.api.nvim_create_autocmd("BufWritePre", {
  callback = function(args)
    if vim.b[args.buf].fzfkasten then return end -- skip fzfkasten notes
    vim.lsp.buf.format()
  end,
})
```

For anything more involved, use the `on_open` hook, which receives the buffer
number after it has been marked:

```lua
note_buffer = {
  on_open = function(bufnr)
    vim.bo[bufnr].spell = true
  end,
},
```

## Usage

Fzfkasten provides several commands for managing your Zettelkasten notes:

*   **`:FzfKastenNewNote`**: Creates a new note. You will be prompted for a title and then presented with an `fzf-lua` picker to select an optional template from your `home/templates` directory. If no template is selected, it defaults to a basic note structure.

*   **`:FzfKastenFindDailyNotes`**: Opens an `fzf-lua` picker to search and open existing daily notes from your `home/daily` directory.

*   **`:FzfKastenFindWeeklyNotes`**: Opens an `fzf-lua` picker to search and open existing weekly notes from your `home/weekly` directory.

*   **`:FzfKastenSearchByTag`**: First presents a list of all unique tags in your Zettelkasten, then displays notes containing the selected tag.

*   **`:FzfKastenFollowLink`**: Follow a `[[wikilink]]`. If the cursor is on a link, it opens that link directly; otherwise it lists every link in the buffer in an `fzf-lua` picker. Targets are resolved recursively across sub-directories (so links to notes in e.g. `lognote/` resolve too). When several notes share the name, you get a picker to choose; when none exist, the link is created from a template if `follow_link.create_nonexisting` is enabled (see below).

*   **`:FzfKastenGotoLink`**: Like `:FzfKastenFollowLink` but cursor-only — follows the link under the cursor, and falls back to Vim's native `gf` when the cursor isn't on a link. Designed to be mapped to `gf` so the habit of pressing `gf` "just works":

    ```lua
    -- in a markdown ftplugin, or with an ft filter:
    { "gf", "<cmd>FzfKastenGotoLink<CR>", ft = "markdown", desc = "Follow wikilink / gf" }
    ```

*   **`:FzfKastenTasks`**: Lists every open `- [ ]` checkbox across your notes. Pick one to jump to that line in its note; press `<ctrl-x>` to mark it done in the note itself. See [Tasks](#tasks).

*   **`:FzfKastenTaskToggle`**: Toggles the checkbox on the current line between `- [ ]` and `- [x]`.

*   **Other existing commands:** (e.g., `:FzfKastenDaily`, `:FzfKastenWeekly`, `:FzfKastenFindNotes`, `:FzfKastenTags`, `:FzfKastenInsert`, etc.)

### Following links to non-existing notes

By default, following a link whose note doesn't exist anywhere under `home` just warns. To create it from a template instead (telekasten's `follow_creates_nonexisting` behaviour):

```lua
require("fzfkasten").setup({
  follow_link = {
    create_nonexisting = true,      -- create the note (in home root) when missing
    new_note_template = nil,        -- template to use; falls back to `new_note_template`
  },
})
```

## Tasks

Tasks are plain markdown checkboxes written wherever they were born — in the meeting note, in today's daily, mid-paragraph. There is no task file to maintain and no index to rebuild: `:FzfKastenTasks` re-scans with `ripgrep` on every call (a few milliseconds for a few hundred notes).

That property matters more than it looks. Because the notes *are* the ledger, anything else that can edit markdown joins in for free — a mobile git client, another editor, a script. Tick a box on your phone, and the next scan sees it. Nothing to sync, nothing to teach.

```markdown
# Tasks
- [ ] (A) review the tech report due:2026-07-17
- [ ] get a quotation
- [x] already done
```

Priority `(A)` and `due:YYYY-MM-DD` are optional; tasks sort by priority, then by due date. Checkboxes inside fenced code blocks and frontmatter are ignored, so a note documenting this syntax won't report its own examples as tasks.

| Key | Action |
|---|---|
| `<enter>` | Open the note at the task's line |
| `<ctrl-x>` | Mark done in the note, then reopen the picker |

### Choosing what counts as a task

By default *every* checkbox is a task. If you also use checkboxes for things that aren't tasks — acceptance criteria in a spec, a packing list — you have two ways out, and they suit different habits.

Opt out per note, with `tasks: false` in its frontmatter:

```markdown
---
title: Deployment spec
tasks: false
---
## Acceptance criteria
- [ ] clone works        # not a task
```

Or opt in per section, by only collecting below task headings:

```lua
require("fzfkasten").setup({
  tasks = { scope = "headings" },  -- only checkboxes under "# Tasks", "# ToDo", ...
})
```

Prefer `tasks: false` when the non-tasks cluster in a few notes, and `scope = "headings"` when they're scattered. Note that `scope = "headings"` asks you to move a checkbox under a heading before it counts — a small copying step, which is exactly the kind of friction that kills task systems. Reach for it only if the opt-out isn't enough.

### Configuration

```lua
tasks = {
  scope = "all",  -- "all" | "headings"
  -- Lua patterns matched against lowercased heading text (scope = "headings").
  headings = { "^tasks?%f[%A]", "^to%-?dos?%f[%A]", "^タスク", "^やること" },
  ignore = {
    frontmatter_key = "tasks",  -- `tasks: false` opts a note out; nil disables
    dirs = { "templates" },     -- directories (relative to `home`) never scanned
  },
  -- Skip notes older than N days; nil scans everything.
  since_days = nil,
  always = {},  -- notes always scanned regardless of `since_days`
  date_keys = { "date", "created" },  -- frontmatter keys holding a note's date
  date = nil,  -- function(path, lines, frontmatter) -> "YYYY-MM-DD"|nil
  patterns = {
    -- A ripgrep regex (not a Lua pattern), see "Redefining the syntax" below.
    scan = [[^\s*[-*]\s+\[[ xX]\]\s+]],
    open = "^%s*[-*]%s+%[ %]%s+(.+)$",
    done = "^%s*[-*]%s+%[[xX]%]%s+(.+)$",
    toggle = "^(%s*[-*]%s+%[)([ xX])(%])",  -- captures (before)(mark)(after)
    priority = "^%((%u)%)%s+",
    due = "due:(%d%d%d%d%-%d%d%-%d%d)",
  },
  marks = { open = " ", done = "x" },  -- what `toggle` writes into the mark
  on_collect = nil,  -- function(tasks) called after each collect
}
```

### Redefining the syntax

`patterns` and `marks` between them define what a task looks like, and all of it is yours to change. Three of the patterns work together and have to agree:

- `scan` finds which notes are worth reading. It is a **ripgrep regex**, not a Lua pattern — the two are different languages, so it can't be derived from `open`/`done` for you. Keep it a superset of both, or set it to `false` to skip the pre-filter and read every note (slower, but it can't disagree with anything).
- `open` and `done` decide what each line is, and capture the task's text.
- `toggle` captures `(before)(mark)(after)` around the mark, and `marks` says what to write into it.

Taken together, they let you use a different notation end to end:

```lua
tasks = {
  patterns = {
    scan = [[^\s*[-*]\s+\([ xX]\)\s+]],      -- ripgrep regex
    open = "^%s*[-*]%s+%( %)%s+(.+)$",       -- - ( ) buy milk
    done = "^%s*[-*]%s+%([xX]%)%s+(.+)$",    -- - (x) buy milk
    toggle = "^(%s*[-*]%s+%()([ xX])(%))",
    priority = "^%[(%u)%]%s+",               -- - ( ) [A] buy milk
    due = "due:(%d%d%d%d%-%d%d%-%d%d)",
  },
}
```

Note `scan = false` rather than `nil`: `setup()` merges your table over the defaults, so a `nil` leaves the default in place. The same applies to any other option you want to switch off.

`since_days` earns its keep once your notes are a few years deep: old notes carry tasks you'll never revisit, and they drown the ones you will. Pair it with `always` for a standing list that shouldn't age out:

```lua
tasks = { since_days = 60, always = { "tasks/active.md" } }
```

### How a note is dated

`since_days` needs to know when a note is from. Fzfkasten reads that from the filename (`2026-07-15.md`), then from the frontmatter keys in `date_keys`.

It never falls back to mtime. In a git-backed Zettelkasten — which is the point of syncing notes to your phone — every checkout rewrites mtime, so it records when the file arrived, not when the note was written. A `since_days` window built on it would drop real tasks on days you changed nothing.

**A note whose date can't be determined is never aged out.** Its tasks always show. Failing open is deliberate: an extra task in the list is a nuisance you can see, while a silently hidden one is a task you simply lose. Use `tasks: false` to quiet an undated note you don't want.

If your notes keep the date somewhere else, `date` reads it:

```lua
tasks = {
  -- e.g. a "**Created**: 2026-04-30" line near the top of the body
  date = function(path, lines, frontmatter)
    for i = 1, math.min(10, #lines) do
      local d = lines[i]:match("^%*%*Created%*%*:%s*(%d%d%d%d%-%d%d%-%d%d)")
      if d then return d end
    end
  end,
}
```

It runs before the filename and frontmatter; return `nil` to fall through to them.

### Exporting elsewhere

`on_collect` receives the task list after each scan. The picker only exists inside Neovim, so this is the hook for getting the same list somewhere else — an aggregated index note you can read on your phone, a `todo.txt`, an external tracker:

```lua
tasks = {
  on_collect = function(tasks)
    local lines = { "# Open tasks", "" }
    for _, t in ipairs(tasks) do
      local note = vim.fn.fnamemodify(t.path, ":t:r")
      table.insert(lines, string.format("- [[%s]] — %s", note, t.text))
    end
    vim.fn.writefile(lines, vim.fn.expand("~/notes/tasks/OPEN.md"))
  end,
}
```

Write the export without checkboxes, as above. A generated file is a *view*: a box in it invites a tick that the next scan will overwrite.

Each task is `{ text, done, priority, due, path, rel, lineno, date }`. `require("fzfkasten").collect_tasks(opts)` returns the same list directly, and `require("fzfkasten.tasks").toggle_at(path, lineno)` flips one checkbox on disk.

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

Image rendering in the note finder (`find_notes`) is delegated to `fzf-lua`, so any previewer it supports works here — fzfkasten just passes `fzf.files` through to it. Point `fzf.files.previewer` at your chosen backend:

```lua
require("fzfkasten").setup({
  fzf = {
    files = {
      -- "builtin" uses fzf-lua's native previewer (text + basic image support
      -- in terminals that can render images inline, e.g. Kitty, WezTerm).
      -- Swap for a custom previewer like "bat", or a user-defined one that
      -- shells out to `chafa`, `viu`, or `ueberzug` for richer image preview.
      previewer = "builtin",
    },
  },
})
```

**Requirements for inline image preview:**

- A terminal that can render images (Kitty, WezTerm, Ghostty, iTerm2, or any terminal with `ueberzug`/`chafa`).
- `fzf-lua`'s image-preview config set up — see [fzf-lua's previewer docs](https://github.com/ibhagwan/fzf-lua#previewers) for defining custom previewers.

Plain-text preview (Markdown syntax highlighting) works out of the box with `previewer = "builtin"` and requires no extra setup.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

