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
- [x] **Backlinks**: Find all notes linking to the current note. `[[note]]`, `[[note|alias]]` and `[[note#heading]]` all count as links to `note`; only whole names match, so `[[note-old]]` is not one.
- [x] **Rename Note**: Rename a note and retarget every link to it — see [Renaming](#renaming-a-note).
- [x] **Template Engine**: Simple `{{title}}`, `{{date}}`, and `{{hdate}}` placeholders.
- [x] **External Commands**: Append external data (like `gcalcli`) to daily notes.
- [x] **Fzfkasten Panel**: A central menu for common actions (Open, Backlinks, Rename, Delete).
- [x] **New Templated Notes**: Create new notes from predefined templates with interactive selection.
- [x] **Log picker**: One picker (`:FzfKastenLog`) over recent days and weeks — existing notes preview and open, missing dates are created from a template, all in one place.
- [x] **Claude Code Integration**: Optional integration with `claudecode.nvim` to send notes/selections to Claude (disabled by default).
- [x] **Link Aliasing**: `[[note|alias]]` syntax is supported across follow link, backlinks, and rename. Anchors (`[[note#heading]]`) too, and all three read them alike.
- [x] **Filename Sanitization**: Unicode-safe default (preserves CJK) with a user-overridable `transform.sanitize_filename` hook.
- [x] **Template Placeholders**: Built-in `{{title}} {{date}} {{hdate}} {{year}} {{month}} {{day}} {{week}} {{time}}` plus user-defined entries via `template_placeholders` (string or function values).
- [x] **Image Preview**: Delegated to `fzf-lua`'s previewer; see the [Image Preview](#image-preview) section for configuration.
- [x] **Tasks**: Collect `- [ ]` checkboxes across every note, jump to the one you pick, and tick it off without leaving the picker. Mark which checkboxes are yours with a tag, and triage the rest from an inbox. No index, no task file — see [Tasks](#tasks).

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

*   **`:FzfKastenLog`**: One picker for the whole journal. Lists the recent days (`daily.lookback_days`) and weeks (`weekly.lookback_weeks`), each marked ✓ when its note already exists. Existing notes preview and open; a date or week with no note yet is created from its template on select — so browsing old notes and filling in a missed day are the same action. `<ctrl-x>` enters a date by hand for anything older than the window. (`:FzfKastenPickDailyDate` is a kept alias.)

*   **`:FzfKastenFindDailyNotes`** / **`:FzfKastenFindWeeklyNotes`**: Open an `fzf-lua` picker over just the existing daily / weekly notes. `:FzfKastenLog` covers both with a preview and the ability to create, so these are mostly superseded, but they remain for browsing a single kind.

*   **`:FzfKastenSearchByTag`**: First presents a list of all unique tags in your Zettelkasten, then displays notes containing the selected tag.

*   **`:FzfKastenFollowLink`**: Follow a `[[wikilink]]`. If the cursor is on a link, it opens that link directly; otherwise it lists every link in the buffer in an `fzf-lua` picker. Targets are resolved recursively across sub-directories (so links to notes in e.g. `lognote/` resolve too). When several notes share the name, you get a picker to choose; when none exist, the link is created from a template if `follow_link.create_nonexisting` is enabled (see below).

*   **`:FzfKastenGotoLink`**: Like `:FzfKastenFollowLink` but cursor-only — follows the link under the cursor, and falls back to Vim's native `gf` when the cursor isn't on a link. Designed to be mapped to `gf` so the habit of pressing `gf` "just works":

    ```lua
    -- in a markdown ftplugin, or with an ft filter:
    { "gf", "<cmd>FzfKastenGotoLink<CR>", ft = "markdown", desc = "Follow wikilink / gf" }
    ```

*   **`:FzfKastenTasks`**: Lists every open `- [ ]` checkbox across your notes. Pick one to jump to that line in its note; press `<ctrl-x>` to mark it done in the note itself. See [Tasks](#tasks).

*   **`:FzfKastenTaskToggle`**: Toggles the checkbox on the current line between `- [ ]` and `- [x]`, stamping the completion time.

*   **`:FzfKastenTaskAdd [text]`**: Captures a new task to a single fixed note (`tasks.capture_note`, or your first `tasks.always` entry), no note to open and no decision about where it goes. With no argument it prompts. See [Tasks](#tasks).

*   **`:FzfKastenTaskInbox`**: Lists the checkboxes that `tasks.require_tag` leaves out, so you can triage them. See [Tasks](#tasks).

*   **`:FzfKastenTaskTag`**: Tags the current line as a task, turning prose or a bare bullet into a checkbox on the way. Takes a range, so a visual selection is tagged in one go. See [Tasks](#tasks).

*   **`:FzfKastenTaskCancel`**: Drops the task on the current line — out of the lists, still in the note — or reopens it if it is already dropped. See [Tasks](#tasks).

*   **`:FzfKastenTaskUndo`**: Puts back the last task line the picker rewrote. Repeat to walk back through them. See [Tasks](#tasks).

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

Priority `(A)` and a due date are optional; tasks sort by priority, then by due date. Checkboxes inside fenced code blocks and frontmatter are ignored, so a note documenting this syntax won't report its own examples as tasks.

A due date is `due:YYYY-MM-DD`, or `due:YYYY-MM-DDTHH:MM` when a time matters — ISO 8601, no space, so it stays one token you can drop anywhere in the line. Type it by hand, or let `:FzfKastenTaskDue` write it for you: `:FzfKastenTaskDue 2026-07-25` sets (or replaces) the due date on the current task, `:FzfKastenTaskDue 2026-07-25T15:00` adds a time, and `:FzfKastenTaskDue` with no argument clears it. It also takes a relative spec and works out the day: `tomorrow` (or `明日`), `+3d`, `2w`, a weekday name (`fri`, `金`, resolved to the nearest such day at or after today). What lands in the note is always the absolute date, though — the note is the ledger, and a bare `due:2026-07-25` reads the same in every editor and on your phone. The `<alt-a>` capture asks for a due the same way.

| Key | Action |
|---|---|
| `<enter>` | Open the note at the task's line |
| `<ctrl-x>` | Mark done in the note; the list refreshes in place |
| `<ctrl-d>` | Drop the task: out of the list, still in the note |
| `<ctrl-t>` | Add `require_tag`, promoting an inbox entry to a task |
| `<alt-a>` | Capture a new task with a guided input: text (seeded from what you typed), tags picked from those your notes already use, then a due date. Writes to the capture note and reopens the list |
| `<alt-/>` | Narrow the list by romaji: `kaigi` finds 会議. Needs [kensaku.vim](https://github.com/lambdalisue/kensaku.vim); empty input clears it |
| `<alt-u>` | Put back the last line any of these rewrote |
| `<alt-s>` | Cycle the ordering: priority → due → added → priority |
| `<alt-r>` | Reverse whichever ordering is in force |

### The list as a buffer — `:FzfKastenTaskList`

The picker is the right tool for **finding one task**: you type, you press enter, and its `<ctrl->`/`<alt->` bindings never come up. It is the wrong tool for **working down a list**, where you want `j`, `k`, `/`, `gg` and everything else you already know — and cannot have them, because fzf's prompt owns every unmodified key. No rebinding fixes that; the input field is the reason.

So `:FzfKastenTaskList` draws the same tasks into an ordinary scratch buffer, where the only keys defined are the actions:

```
Tasks — 14   ·   priority

(A) 月報7月分  [due 2026-07-27]                          tasks/active.md:32
(A) phi0.3mm プローブの作製  [0/1]  [due 2026-07-31]     tasks/active.md:26
  ↳ (A) 図面作製、出図                                   tasks/active.md:27
(B) 渋谷光学の精密ミクロメータ校正  [due 2026-07-24]     tasks/active.md:25
```

| Key | Action |
|---|---|
| `<enter>` | Open the note at this task |
| `x` | Tick it off |
| `c` | Drop it, keeping the line |
| `t` | Add `require_tag` — promotes an inbox entry |
| `a` | Capture a new task |
| `u` | Put back the last line an action rewrote |
| `s` / `S` | Cycle the ordering / reverse it |
| `i` | Switch between the task list and the inbox |
| `r` | Re-scan the notes |
| `q` | Close |
| `p` | Go into the preview; `<esc>` or `<c-q>` comes back |
| `P` | Show or hide the preview |
| `<c-d>` / `<c-u>` | Scroll the preview half a screen |
| `<c-f>` / `<c-b>` | Scroll the preview a page |
| `<c-e>` / `<c-y>` | Scroll the preview a line |

Everything else is Vim's, untouched: `j`, `k`, `gg`, `G`, `/`, `n`, `{`, `}`, `<c-d>`, `<c-u>`. No modifier is needed for anything, which is the point — `x`, `c`, `a`, `u` read as delete, change, append, undo, so there is almost nothing to learn.

**It is a listed buffer**, so a bufferline shows it as a tab and you switch back to it the way you switch to any open file — `<s-h>`/`<s-l>`, `:b`, `<c-^>`. That matters more than it sounds: a list you glance at all day should not need a keystroke to summon each time. Switching back re-scans the notes and puts the preview back, so what you return to is the current state, not the state you left. Set `list.listed = false` to keep it out of the buffer list.

**The buffer is never written and is not the ledger** — the notes still are. Every action goes through the same writers the picker uses, and the buffer is redrawn from disk afterwards. Close it and nothing is lost. Complete a task and the next moves up under the cursor, so a run of them is one keypress each.

#### The preview

Under the list is a split showing the task's note around its line, centred on it and following the cursor:

```
Tasks — 14   ·   priority
フック・分銅皿の取付が可能な治具の作製  ← ロック時に半球の引き剥しに…
────────────────────────────────────────────────────────────
  134  # How to assess the gripping-force to hold the holder
  136  - 入荷したらまずは摺動面の表面観察を行う
  138  - ロック時に半球の引き剥しにどの程度の力が必要なのかを評価する
▶ 139    - [ ] フック・分銅皿の取付が可能な治具の作製 #todo
  140  - 設定した位置に任意の荷重を印加可能な仕組み
```

**It is an ordinary window, which is the whole design.** `p` goes into it and every Vim key works there — `j`, `gg`, `/`, `<c-d>`, `<c-w>p` — because nothing has been reimplemented. `<esc>` or `<c-q>` comes back to the list; deliberately not `q`, which closes the list, since one key meaning "leave this window" in one place and "close the whole thing" in another is a coin toss you make every time.

Without leaving the list, **all three of Vim's scroll pairs are pointed at it** — `<c-d>`/`<c-u>` by half a screen, `<c-f>`/`<c-b>` by a page, `<c-e>`/`<c-y>` by a line. They mean exactly what they mean anywhere in Vim; only the window they act on is different, so there is no scroll vocabulary to learn.

Pointing *all* of them there makes the rule one line — **scrolling is the preview, the list moves by cursor** — instead of some keys going one way and some the other. They are free to reuse because you move through the list with `j`/`k`, `gg`, `G` and `/`, not by scrolling it; and with no preview up they fall through to what Vim would have done to the list anyway.

The preview reads a **loaded buffer** in preference to the file, so a note you have open and edited but not written previews as it actually is, not as the file on disk is lagging behind it.

It belongs to the list rather than to the window it sits under, so it goes away the moment the list does — `<enter>` onto a note, a walk back through the jumplist, `:bnext`, closing the window. What it will not do is close while you are reading it: stepping in with `p` leaves the list on screen, and that is what it checks.

```lua
tasks = {
  list = {
    open = "full",   -- or "split" / "vsplit" / "tab"
    listed = true,   -- keep it in the buffer list, so a bufferline shows it
    source = true,   -- the note:line, right-aligned as virtual text
    preview = {
      enabled = true,
      height = 0.5,  -- a fraction of the list window below 1, a line count above
    },
    -- Every key is configurable, the preview's included. Each entry is a key,
    -- a list of keys (all bound to that action), or false to leave it to Vim.
    keys = {
      done = "x", cancel = "c", sort = "s",
      preview = "p", preview_toggle = "P",
      preview_back = { "<Esc>", "<C-q>" },   -- pressed inside the preview window
      preview_half_page_down = "<C-d>", preview_half_page_up = "<C-u>",
      preview_page_down = "<C-f>",      preview_page_up = "<C-b>",
      preview_down = "<C-e>",           preview_up = "<C-y>",
    },
  },
}
```

`open = "full"` takes the current window, so `<enter>` opens the note in place and `<c-o>` comes back. The split variants leave the window you were reading in, and `<enter>` opens the note *there* — so the list stays on screen beside it.

### Ordering the list

The list opens ordered by priority, then by due date — what you flagged, then what runs out. `<alt-s>` cycles that to two other orderings, and `<alt-r>` flips whichever one is in force:

| Ordering | Reads as |
|---|---|
| `priority` | What you decided matters, then what runs out first. The default |
| `due` | What runs out first, whatever you decided about it |
| `added` | The order they were written down: the note's date, then position in the note. Captures append, so within one note this is capture order |

A task with no due date sorts **last** under `due`, not first — no due date means "not urgent", and a sentinel that sorted first would let undated tasks drown the ones that actually run out. The same goes for a note with no date under `added`.

The ordering shows in the prompt (`Tasks (due, reversed)> `) so a short list reads as "ordered differently" rather than "all there is". The default ordering is left unsaid: a prompt that always carries a tag is one you stop reading.

Changing the order reopens the picker, carrying your query over — the entries move, what you typed to narrow them doesn't. Reversing points the list the other way; it does **not** scramble the steps of a job, which stay in the order they are written under the item they belong to.

### Subtasks, and the context a task line loses

A job with steps is written the way you'd write it anyway — a checkbox indented under another:

```markdown
- [ ] (A) make the phi0.3mm probe #todo due:2026-07-31
  - [x] draw it up and release the drawing
  - [ ] send it out for machining
```

**A checkbox nested under a task is a task too, and inherits `require_tag` from it.** Deciding an item is yours is a decision about the whole item; re-tagging every step of it is bookkeeping with nothing to show for it. Inheritance only ever flows down from a checkbox that carries the tag, so a meeting note's action items for other people — nested checkboxes just the same — stay out of the list exactly as before.

The list keeps a subtask under the item it belongs to, and says how far along that item is:

```
- [ ] (A) make the phi0.3mm probe  [1/2]  [due 2026-07-31]
    ↳ send it out for machining
```

Subtasks sort with their parent rather than on their own priority — a `(A)` step of a `(C)` job stays where it can be read as a step, instead of being scattered to the top of the list on its own.

**A task also carries the line it hangs off, when there is no parent row above it to read that from:**

```
- [ ] how hard is it to pull the holder off
  - [ ] build a jig that takes the hook and the weight pan #todo
```

```
build a jig that takes the hook and the weight pan  ← how hard is it to pull the holder off
```

That happens when the line above is a plain bullet (no checkbox, so nothing to indent under), or when the parent task was filtered out of the view — an open step under a finished item, say. Either way the task line stops being a fragment you have to open the note to understand. The same context shows up in the inbox, where a checkbox is most likely to be missing the words that made it make sense.

If your notes are written in Japanese, fzf's own filter needs you to type Japanese to match them. **`<alt-/>` lets you narrow by romaji instead**: it asks for a query (seeded from whatever you had typed), hands it to [kensaku.vim](https://github.com/lambdalisue/kensaku.vim) to build a matcher, and reopens the picker showing only what matches — so `kaigi` surfaces 会議 without leaving your keyboard's Latin layout. Empty input clears the filter; the prompt gains `(romaji)` while one is active. The key only appears when kensaku is installed — it is an optional dependency, not required.

The same `<alt-/>` works across fzfkasten, not just the task list: it narrows the note finder (`:FzfKastenFindNotes`) and link insertion (`:FzfKastenInsert`) by note title, and drives a romaji **content search** in `:FzfKastenSearchContent` — that last one is where it pays off most, since note bodies are mostly Japanese while filenames often are not.

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
    frontmatter_key = "tasks",  -- `tasks: false` opts a note out; false disables
    dirs = { "templates" },     -- directories (relative to `home`) never scanned
  },
  -- Skip notes older than N days; nil scans everything.
  since_days = nil,
  always = {},  -- notes always scanned regardless of `since_days`
  capture_note = nil,  -- where :FzfKastenTaskAdd appends; nil = first `always` entry
  date_keys = { "date", "created" },  -- frontmatter keys holding a note's date
  date = nil,  -- function(path, lines, frontmatter) -> "YYYY-MM-DD"|nil
  patterns = {
    -- A ripgrep regex (not a Lua pattern), see "Redefining the syntax" below.
    scan = [[^\s*[-*]\s+\[[ xX-]\]\s+]],
    open = "^%s*[-*]%s+%[ %]%s+(.+)$",
    done = "^%s*[-*]%s+%[[xX]%]%s+(.+)$",
    cancelled = "^%s*[-*]%s+%[%-%]%s+(.+)$",
    toggle = "^(%s*[-*]%s+%[)([ xX-])(%])",  -- captures (before)(mark)(after)
    priority = "^%((%u)%)%s+",
    due = "due:(%d%d%d%d%-%d%d%-%d%d[T%d:]*)",  -- ISO day, optional THH:MM
  },
  marks = { open = " ", done = "x", cancelled = "-" },  -- what `toggle` writes
  new_checkbox = "- [ ] ",  -- literal `:FzfKastenTaskTag` puts in front of prose
  require_tag = nil,  -- e.g. "todo": only #todo checkboxes are tasks
  done_stamp = {      -- written on completion, removed on reopen; false disables
    format = " done:%Y-%m-%d %H:%M",
    pattern = "%s*done:(%d%d%d%d%-%d%d%-%d%d %d%d:%d%d)",
  },
  cancel_stamp = {    -- the same, for a task you dropped; false disables
    format = " cancelled:%Y-%m-%d",
    pattern = "%s*cancelled:(%d%d%d%d%-%d%d%-%d%d)",
  },
  cancel_strike = "~~",  -- wrapped around a cancelled task's text; false disables
  filter = nil,  -- function(task) -> boolean; false drops the task
  on_collect = nil,  -- function(tasks) called after each collect
}
```

### Whose task is it? — `require_tag` and the inbox

Not every checkbox in your notes is a job for you. Meeting minutes record action items for other people; a spec's acceptance criteria are checkboxes that are nobody's task. `require_tag` settles it by asking you to say so:

```lua
tasks = { require_tag = "todo" }   -- only `- [ ] ... #todo` is a task of mine
```

```markdown
## Minutes
- [ ] revise the manual (Alice)      → not mine, never in my list
- [ ] send the quote #todo           → mine
```

Tagging is a decision, not bookkeeping: writing `#todo` is the moment you accept the work. That is why the tag beats guessing from shape — "parenthesis means owner" looks tempting until you meet `- [ ] (A) ship it`, `- [ ] fix the workflow (repairs)` and `- [ ] submit (due May)`, all parentheses and none an owner.

The obvious risk is forgetting the tag, so nothing is thrown away for lacking one. **`:FzfKastenTaskInbox` lists exactly the checkboxes `require_tag` left out.** Triage there with `<ctrl-t>`: the entry is tagged in its note and moves straight to the task list, cursor still in place, so a run of them takes one keypress each. An untagged task is waiting, not lost — which is what makes it safe to require the tag at all.

The inbox catches what you missed, but the cheaper moment is while you are still writing. **`:FzfKastenTaskTag` raises the line under the cursor to a task**, and it starts from wherever the line already is:

```markdown
send the quote           → - [ ] send the quote #todo
- send the quote         → - [ ] send the quote #todo
- [ ] send the quote     → - [ ] send the quote #todo
```

Realising mid-sentence that a line is yours to do is the moment to say so, and prose is where that realisation lands — so the command bullets it, boxes it and tags it in one keystroke rather than three edits. It takes a range, which is what makes an old note tractable: select the meeting minutes you never triaged and `:'<,'>FzfKastenTaskTag` the lot.

It edits the buffer, not the file, so it works mid-edit on unsaved text — unlike the inbox's `<ctrl-t>`, which reaches into a note you may not have open. What it will not do is write a task the list would never show: headings, frontmatter, fenced examples and (under `scope = "headings"`) anything outside a task section are left alone, because the same rules that decide what `:FzfKastenTasks` scans decide what this tags. A key that silently writes an invisible task would be worse than no key.

A tag you have to remember is a tag you will forget, so put it in the template you already type. With [LuaSnip](https://github.com/L3MON4D3/LuaSnip), a checkbox snippet that emits the tag costs nothing at the keyboard:

```lua
s("todo", fmt("- [ ] <> #todo", { i(0) }, { delimiters = "<>" }))
```

Leave `require_tag` unset and every checkbox is a task, with no inbox to keep.

For anything the tag can't express, `filter` runs on every task with everything parsed, so it can key off `due`, `priority`, `rel`, `date` or `done`. Return `false` to drop; anything else keeps. A `filter` that raises keeps the task and warns once — losing work to a config error would be the worse failure.

### Recording when you finished

`done_stamp` writes the time into the line as a task is completed, and removes it if the task is reopened:

```markdown
- [ ] send the quote #todo @work due:2026-07-20
      ↓ <ctrl-x> in the picker, or :FzfKastenTaskToggle on the line
- [x] send the quote #todo @work due:2026-07-20 done:2026-07-16 14:32
```

`format` is an `os.date` format and `pattern` must match what it writes, capturing the timestamp — that capture becomes `task.done_at`, and it is how the stamp gets stripped again. Set `done_stamp = false` to write nothing.

The stamp records *when*, never *whether*: **the checkbox stays the only source of done-ness.** It is tempting to keep the state in a tag instead — `#todo` becoming `#done` — but any other editor ticking the box knows nothing about your tags, and then the box says done while the tag says open, with no way to tell which is right. One state, one place.

### Dropping a task

Not everything you accept gets done; some of it stops being worth doing. Deleting the line would be the obvious move and the wrong one — that a job was once on your list is a fact about the project, and it is the only trace that you thought about it at all. `<ctrl-d>` in the picker, or `:FzfKastenTaskCancel` on the line, drops a task without losing it:

```markdown
- [ ] (A) redraw the figures #todo due:2026-07-20
      ↓
- [-] (A) ~~redraw the figures #todo due:2026-07-20~~ cancelled:2026-07-17
```

It leaves the task list the same way a completed one does, and the same command puts it back. Ask for it with `collect({ cancelled = true })` when you want to know what you dropped.

**A dropped task is not a finished one, so it does not become `- [x]`.** That would put it in "what did I finish last week", which is a lie your own notes would tell you later; `cancel_stamp` is separate from `done_stamp` for the same reason. Cancelling something already done is refused rather than guessed at, since the two claims contradict each other.

The strikethrough is decoration, and the mark is the state — `marks.cancelled` alone decides, and if a stray `~~` disagrees the mark wins. It is there because `[-]` is not a checkbox to GitHub or a phone's markdown viewer, which show it as literal text; struck-through text still reads as dropped wherever the note is read, which matters when the notes are synced and read outside Neovim. Set `cancel_strike = false` for the mark alone — `false` rather than `nil`, for the reason described under [Redefining the syntax](#redefining-the-syntax).

Note where the wrap sits: **inside the priority, outside the stamp.** `patterns.priority` is anchored to the start of the task's text, so `~~(A) redraw~~` would hide the `(A)` for as long as the task stayed cancelled — and the cancelling is not itself cancelled, so the stamp stays out of the strike too.

### Undoing a keypress in the picker

`<ctrl-x>` on the wrong row is easy: the task is done, the list refreshes, and the row you meant is now where your cursor is. **`<alt-u>` puts the line back**, once per keypress, walking back through `<ctrl-x>`, `<ctrl-d>` and `<ctrl-t>` alike. `:FzfKastenTaskUndo` does the same after you have closed the picker.

**Vim's `u` cannot do this, and looks like it can.** The picker writes the note, not a buffer — usually a note you don't even have open. When you do have it open, `u` rolls the buffer back and leaves the note on disk as it was, so the task list still shows it done, the buffer now disagrees with the file, and nothing says why. That gap is what this key is for.

Edits you make in a note yourself — `:FzfKastenTaskToggle`, `:FzfKastenTaskCancel`, `:FzfKastenTaskTag` — are `u`'s to undo, as any edit is, and are deliberately not recorded here. Two undo stacks over one edit would fight: `u` would put the line back in the buffer and this would put it back in the file the buffer no longer agrees with.

An undo that would overwrite an edit made since is refused rather than forced through. If the line has changed — by hand, from your phone, by anything — it says so and leaves it alone; your text is worth more than the undo.

To review what you finished, ask for completed tasks and read their stamps:

```lua
local done = require("fzfkasten").collect_tasks({ done = true })
```

### Redefining the syntax

`patterns` and `marks` between them define what a task looks like, and all of it is yours to change. Three of the patterns work together and have to agree:

- `scan` finds which notes are worth reading. It is a **ripgrep regex**, not a Lua pattern — the two are different languages, so it can't be derived from `open`/`done` for you. Keep it a superset of both, or set it to `false` to skip the pre-filter and read every note (slower, but it can't disagree with anything).
- `open`, `done` and `cancelled` decide what each line is, and capture the task's text.
- `toggle` captures `(before)(mark)(after)` around the mark, and `marks` says what to write into it. Its mark class has to admit every mark in `marks`, or the states it leaves out become unreachable. It also pins down where the checkbox ends and the text starts, which is how a task gets rewritten in place.

`new_checkbox` has to be redefined alongside them for the same reason `scan` does: it is the literal `:FzfKastenTaskTag` writes in front of prose, and a pattern matches many strings without saying which one to produce.

Taken together, they let you use a different notation end to end:

```lua
tasks = {
  patterns = {
    scan = [[^\s*[-*]\s+\([ xX-]\)\s+]],     -- ripgrep regex
    open = "^%s*[-*]%s+%( %)%s+(.+)$",       -- - ( ) buy milk
    done = "^%s*[-*]%s+%([xX]%)%s+(.+)$",    -- - (x) buy milk
    cancelled = "^%s*[-*]%s+%(%-%)%s+(.+)$", -- - (-) buy milk
    toggle = "^(%s*[-*]%s+%()([ xX-])(%))",
    priority = "^%[(%u)%]%s+",               -- - ( ) [A] buy milk
    due = "due:(%d%d%d%d%-%d%d%-%d%d[T%d:]*)",
  },
  marks = { open = " ", done = "x", cancelled = "-" },
  new_checkbox = "- ( ) ",                   -- what `:FzfKastenTaskTag` writes
}
```

Note `scan = false` rather than `nil`: `setup()` merges your table over the defaults, so a `nil` leaves the default in place. The same applies to any other option you want to switch off.

`since_days` earns its keep once your notes are a few years deep: old notes carry checkboxes you'll never revisit, and they drown the ones you will. Pair it with `always` for a standing list that shouldn't age out:

```lua
tasks = { since_days = 60, always = { "tasks/active.md" } }
```

That same standing note is the natural target for **`:FzfKastenTaskAdd`**, which captures a new task to one fixed place — no note to open, no "does this belong to today?" to answer. It defaults to your first `always` entry, so the note you already keep always-scanned is where captures land and where they surface; set `capture_note` to point somewhere else. Bind it to a key and one press then a line is the whole capture; triage later with the inbox. If `require_tag` is set, the tag is added for you, so a capture is a task straight away rather than an inbox entry. The same capture is a keypress away from inside `:FzfKastenTasks` itself: press `<alt-a>` and a guided input takes the task text (seeded from whatever you had typed to filter), lets you pick tags from the ones your notes already use, and asks for a due date — so noticing a new task while working the list doesn't mean leaving it. (`<alt-a>`, not `<ctrl-a>`, which stays fzf's own jump-to-line-start.)

**With `require_tag` set, `since_days` bounds the inbox only — a tagged task never ages out.** Tagging it was a decision, and expiring that by date would drop it from the task list *and* from the inbox, leaving it in neither. `since_days` is there to keep old untriaged checkboxes from drowning the inbox, not to overrule you.

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
    -- Named prompts you can fire into the Claude terminal by name.
    prompts = {
      -- Open (or create) this week's weekly note, then type "/my-weekly-retro"
      -- into Claude and submit it -- e.g. to run one of your own skills.
      retro = { note = "weekly", text = "/my-weekly-retro" },
    },
  },
})
```

### Commands

*   **`:FzfKastenClaudeSendBuffer`**: Send the entire current note to Claude as an `@mention`.
*   **`:FzfKastenClaudeSendSelection`**: Send the visual selection to Claude.
*   **`:FzfKastenClaudeToggle`**: Toggle the Claude terminal.
*   **`:FzfKastenClaudePrompt <name>`**: Send a prompt registered in `claude.prompts`
    to the Claude terminal (starting it if needed). The prompt's `note` is opened
    first so Claude has it as context. `<Tab>` completes the configured names.

### Configured prompts

Each entry under `claude.prompts` is a named string you send with
`:FzfKastenClaudePrompt <name>`:

| Field    | Meaning                                                                                         |
| -------- | ----------------------------------------------------------------------------------------------- |
| `text`   | The string typed into the Claude terminal (required).                                            |
| `note`   | `"weekly"` \| `"daily"` \| `"current"` (or omit) -- a note opened, and created from its template if missing, before the text is sent, so Claude reads it as context. `"current"`/omitted opens nothing. |
| `submit` | Send a trailing `<CR>` so Claude runs it immediately. Defaults to `true`.                        |

This is deliberately generic: register whatever prompt (a slash command, a
question, a canned instruction) suits your workflow. With no `prompts`
configured the command simply lists that none are set.

### Example Keymaps

```lua
{ "<leader>kc", "<cmd>FzfKastenClaudeSendBuffer<CR>", desc = "Send note to Claude" },
{ "<leader>kc", "<cmd>FzfKastenClaudeSendSelection<CR>", mode = "v", desc = "Send selection to Claude" },
{ "<leader>kC", "<cmd>FzfKastenClaudeToggle<CR>", desc = "Toggle Claude terminal" },
{ "<leader>kr", "<cmd>FzfKastenClaudePrompt retro<CR>", desc = "Send retro prompt to Claude" },
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

## Development

The task engine rewrites checkboxes in your notes in place — wrapping a strike
inside a priority, stamping a completion, stripping it again on reopen. That
string surgery is easy to get subtly wrong, so its pure helpers are pinned down
by a test suite under `tests/`, run with
[plenary.nvim](https://github.com/nvim-lua/plenary.nvim)'s busted harness.

Run it headlessly (needs `plenary.nvim` and `fzf-lua` installed wherever your
plugin manager keeps them):

```sh
nvim --headless --noplugin -u tests/minimal_init.lua \
  -c "PlenaryBustedDirectory tests/ { minimal_init = 'tests/minimal_init.lua' }"
```

or, with `make` available, simply `make test`. A green run exits 0; a failing
assertion prints the file, line and diff and exits 1.

**CI runs the same suite from a clean checkout** on Neovim stable and nightly
(`.github/workflows/test.yml`). That the tests pass in a working copy says
nothing about them passing for anyone who clones the repo — a `.gitignore`
pattern once swallowed `tests/minimal_init.lua`, and the suite could not run at
all from a clone, silently.

What the suite covers, and why in that order:

| Spec | Covers |
|---|---|
| `tasks_spec` | The string surgery — rewriting a mark, wrapping a strike inside a priority, stripping a stamp — plus nesting and the orderings |
| `writers_spec` | The paths that decide **not** to write: an unsaved buffer, a line edited since, a note that moved. Every refusal asserts the file is byte-for-byte unchanged |
| `tasklist_spec` | The task list buffer end to end, pressing the keys rather than calling the functions, so a mapping that failed to attach cannot pass |
| `health_spec` | `:checkhealth` in the states worth reporting — no notes directory, a missing template, nowhere to capture to |

`writers_spec` is the one that earns its keep. Everything else fails loudly; that
code fails silently, and it is all that stands between a mis-press and a lost
line.

When a new test passes first time, break the thing it covers and check it goes
red. Three of these did not at first — one read its expected value out of the
module it was testing, so it passed for any value that module held.

## Renaming a note

`:FzfKastenRenameNote` moves the note and retargets every link to it across the
collection. All four link shapes come through:

| Before | After |
|---|---|
| `[[old]]` | `[[new]]` |
| `[[old\|alias]]` | `[[new\|alias]]` |
| `[[old#heading]]` | `[[new#heading]]` |
| `[[old#heading\|alias]]` | `[[new#heading\|alias]]` |

The anchor and the alias are carried across untouched: renaming a note moves
neither the headings inside it nor the words you chose to call it by. Only whole
names match, so `[[old-notes]]` is not a link to `old`, and `[[#top]]` — an
anchor within the same note, with no name — belongs to nobody.

**Following an anchored link puts the cursor on that heading.** `[[note#Results]]`
opens the note at its `## Results`, matched on the heading's own text rather
than a slug — that is what the link says, and you write it by reading the note,
not by guessing how its headings would be encoded. Capitalisation is ignored,
since a heading is prose and nobody recalls it. A heading that is not there
opens the note anyway and says so, because landing at the top otherwise looks
like it worked.

This is the widest write in the plugin, so two things about how it goes about
it are worth knowing:

- **The file moves first.** Rewriting the links and then failing to move would
  point every one of them at a name that does not exist — a whole collection
  broken by a rename that never happened. A failure at the move changes nothing
  at all.
- **A note you have open with unsaved changes is edited in its buffer**, not on
  disk. Writing the file underneath it would be overwritten by your next `:w`,
  leaving that one note pointing at the old name, silently. Your `:w` now
  carries both your edits and the new links.

It says how many notes it touched, since it rewrites files you do not have open.

## Health check

`:checkhealth fzfkasten` reports what fzfkasten needs from outside itself: the
notes directory, `fzf-lua` and the `fzf` binary, `ripgrep`, the templates you
pointed it at, and where captured tasks will land. Those failures otherwise
surface as a picker that opens empty or a command that quietly does nothing,
which says nothing about which of them it was.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

