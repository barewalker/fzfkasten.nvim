local M = {}

M.defaults = {
 -- The environment wins over the default, so a collection can be pointed at
 -- without touching setup().
 home = os.getenv("ZETTELKASTEN_HOME") or vim.fn.expand("~/notes"),
 extension = "md",
 hdate_format = "%B %d, %Y",
 new_note_template = nil,
 -- Behaviour of follow_link / goto_link when following [[wikilinks]].
 follow_link = {
   -- When the link target doesn't exist anywhere under `home`, create it
   -- (in the home root) from a template instead of just warning.
   create_nonexisting = false,
   -- Template used when creating a non-existing note. Falls back to
   -- `new_note_template` when nil.
   new_note_template = nil,
 },
   -- `<alt-/>` in the pickers: type `kaigi`, match 会議. Needs a migemo -- a
   -- romaji-to-regex converter that reaches the kanji too, not just the kana.
   romaji = {
     -- "auto" tries ttyskk first, then kensaku.vim. Name one ("ttyskk" /
     -- "kensaku") to pin it, `false` to turn <alt-/> off, or pass a table of
     -- your own with available()/regex()/rg_regex().
     --
     -- ttyskk first because it costs nothing beyond itself: `ttyskk migemo`
     -- reads the SKK dictionaries already on the machine, in about 30ms.
     -- kensaku.vim runs on denops, so it brings Deno and a 2.1MB dictionary
     -- download with it. Both answer the same question.
     backend = "auto",
     -- Whether the note finder and link insertion also match a note's own
     -- headings, not just its path. Collections are often written in Japanese
     -- but filed under ASCII names, and matching paths alone then looks broken:
     -- the filter runs, narrows, and finds almost nothing. Set false to match
     -- paths only. (The body is not searched here -- that is SearchContent.)
     headings = true,
     ttyskk = {
       cmd = "ttyskk",
       -- Cap on dictionary candidates, passed through as `--limit`. nil leaves
       -- ttyskk's own default, which is what the pattern length was tuned for.
       limit = nil,
       -- This runs in front of the user, so a hung migemo must not be a hung
       -- Neovim. Milliseconds.
       timeout = 5000,
     },
   },
   find = {
     -- How long the note finder keeps the headings it has read, in seconds.
     --
     -- Reading them is what opening the finder costs: 462ms over 495 notes on a
     -- WSL2 laptop against 42ms once they are cached, and 14ms / 6ms on a Linux
     -- filesystem. So they are kept, and only notes never seen before are read.
     --
     -- What that trades away is a heading edited by something that is not this
     -- Neovim -- a git pull, another machine, an agent writing to a note in a
     -- pane. The file *list* is walked every time, so a new note is never
     -- missed; it is the heading text of a note already read that can lag, and
     -- at worst a romaji query does not reach a heading it should. Writing the
     -- note in this Neovim drops it from the cache at once, whatever this says.
     --
     -- Raise it on a machine where reading the collection is expensive; set it
     -- to 0 to read the headings on every open, as the finder used to.
     headings_stale_after = 300,
   },
   -- A `^id` at the end of a line, so a link can point at that line rather than
   -- only at the note or the heading above it: `[[note#^t3k9]]`.
   --
   -- Kept apart from tags, sigil and all. `#qms` classifies -- it is worth
   -- carrying on every line about the quality office, and a search for it is
   -- meant to return all of them. `^t3k9` identifies, and is worth nothing the
   -- moment a second line carries it. One sigil for both would put the two
   -- kinds of answer in the same result list.
   block_id = {
     -- How many characters `:FzfKastenYankLink` mints. Six out of 36 is 2.2
     -- billion, which no collection is going to exhaust.
     length = 6,
     -- What they are minted from. Lowercase only, so two ids are never the
     -- same id told apart by case in a search that ignores it.
     alphabet = "abcdefghijklmnopqrstuvwxyz0123456789",
     -- Carry the line's own text into the link as an alias:
     -- `[[note#^t3k9|(A) プロセスの輪切り…]]`. Off because a task line runs
     -- long, and the link is usually pasted where the surrounding prose
     -- already says what it refers to. The tags are dropped from the alias
     -- either way -- see `pickers.link_alias`.
     alias = false,
     -- Cut the alias to this many characters, an ellipsis standing for the
     -- rest. Counted in characters, not bytes, so a Japanese line is cut where
     -- it looks like it is. nil writes the text whole. Only read when `alias`
     -- is on.
     alias_max = 40,
   },
   patterns = {
     tag = [[#([%w_-]+)]],
     link = [=[%[%[(.-)%]%]]=],
   }, notes = {
  daily = {
   dir = "daily",
   format = "%Y-%m-%d",
   template = "daily.md",
   use_external_cmd = false,
   external_cmd = "gcalcli agenda --tsv",
   fzf_opts = {},
   -- How many days back the date picker should offer (used by pick_daily_date).
   lookback_days = 30,
  },
  weekly = {
   dir = "weekly",
   format = "%Y-W%V",
   template = "weekly.md",
   fzf_opts = {},
   -- How many weeks back the log picker (FzfKastenLog) lists, alongside
   -- `daily.lookback_days` days.
   lookback_weeks = 8,
  },
 },
 -- The collection read as a graph: `:FzfKastenLinkTree` (what this note is
 -- joined to), `:FzfKastenOrphans`, `:FzfKastenDeadLinks`, `:FzfKastenHubs`.
 -- Nothing is indexed or cached -- the walk is about 40ms over 500 notes.
 graph = {
  -- How many links out `:FzfKastenLinkTree` walks from the note you are in.
  -- 1 is that note's own links and backlinks; 2 adds theirs, which is where a
  -- connection you had forgotten tends to turn up. Past 3 the tree is taller
  -- than the window and stops being a shape you can take in. `:FzfKastenLinkTree 3`
  -- overrides it for one call.
  depth = 2,
  -- Directories (relative to `home`) left out of the graph entirely. Templates
  -- are not notes: their `[[{{title}}]]` placeholders would be dead links, and
  -- the templates themselves would sit in the orphan list forever.
  ignore_dirs = { "templates" },
 },
 -- Tasks are plain markdown checkboxes inside your notes -- there is no index
 -- and no separate task file, so any other markdown editor (including mobile
 -- git clients) can tick a box and fzfkasten will see it on the next scan.
 tasks = {
  -- What counts as a task.
  --   "all"      : every checkbox in a note.
  --   "headings" : only checkboxes below a heading matching `headings` below.
  -- Use "headings" when your notes use checkboxes for things that aren't
  -- tasks (spec acceptance criteria, packing lists, ...) and you'd rather
  -- opt in per section than opt out per note.
  scope = "all",
  -- Lua patterns matched against lowercased heading text (scope = "headings").
  headings = { "^tasks?%f[%A]", "^to%-?dos?%f[%A]", "^タスク", "^やること" },
  ignore = {
   -- Frontmatter key that opts a whole note out when falsy (`tasks: false`).
   -- Set to `false` to disable the mechanism -- not nil, which setup() would
   -- merge away, leaving this default in place.
   frontmatter_key = "tasks",
   -- Directories (relative to `home`) skipped entirely.
   dirs = { "templates" },
  },
  -- Ignore checkboxes in notes older than this many days; nil scans
  -- everything. Notes whose date can't be determined are never aged out --
  -- see `date_keys` / `date`. With `require_tag` set this bounds the inbox
  -- only: a tagged task never ages out, since expiring your own decision
  -- would drop it from the task list and the inbox both.
  since_days = nil,
  -- A note's date is read from its filename, then these frontmatter keys.
  -- mtime is deliberately not used: git rewrites it on checkout, so it says
  -- when the file synced, not when the note was written.
  date_keys = { "date", "created" },
  -- Optional function(path, lines, frontmatter) -> "YYYY-MM-DD"|nil, tried
  -- before the above. For dates kept somewhere else, e.g. a body line like
  -- "**Created**: 2026-04-30".
  date = nil,
  -- Notes (relative to `home`) always scanned regardless of `since_days` --
  -- e.g. a standing task list that isn't tied to any date.
  always = {},
  patterns = {
   -- A ripgrep regex (NOT a Lua pattern) narrowing which notes are read at
   -- all. It cannot be derived from `open`/`done` below -- different regex
   -- languages -- so redefine it alongside them, keeping it a superset of
   -- both. Set to `false` to skip the pre-filter and read every note: slower
   -- on large collections, but always agrees with `open`/`done`.
   -- (`false`, not `nil`: setup() merges over the defaults, so a nil here
   -- just leaves this default in place.)
   scan = [[^\s*[-*]\s+\[[ xX-]\]\s+]],
   open = "^%s*[-*]%s+%[ %]%s+(.+)$",
   done = "^%s*[-*]%s+%[[xX]%]%s+(.+)$",
   -- A task you dropped. Kept out of every list, but still in the note: the
   -- line is the only record that you ever meant to do it.
   cancelled = "^%s*[-*]%s+%[%-%]%s+(.+)$",
   -- Captures (before)(mark)(after) around a checkbox's mark. Used to rewrite
   -- the mark, and to find where the task text starts -- so the captures have
   -- to cover the checkbox exactly, leaving the text to follow them. Its mark
   -- class must admit every mark in `marks`.
   toggle = "^(%s*[-*]%s+%[)([ xX-])(%])",
   priority = "^%((%u)%)%s+",
   -- A due date: an ISO day, optionally with a `T`HH:MM time (no space, so it
   -- stays one whitespace-free token that can sit anywhere in the line). The
   -- `[T%d:]*` tail captures the optional time; it is empty for a bare day.
   due = "due:(%d%d%d%d%-%d%d%-%d%d[T%d:]*)",
  },
  -- What the `toggle` pattern's mark capture is replaced with.
  marks = { open = " ", done = "x", cancelled = "-" },
  -- Written in front of a line that `task_tag` promotes to a checkbox. A
  -- literal, not a pattern: `patterns.open` is a regex and several strings
  -- match it, so the one to write can't be derived from it.
  new_checkbox = "- [ ] ",
  -- Where `:FzfKastenTaskAdd` appends a freshly captured task: a single note,
  -- relative to `home`. One fixed destination is the point -- recording a
  -- todo is then one keystroke with no decision about where it lands, and you
  -- triage it later. nil falls back to the first `always` entry (your
  -- standing list, so the capture is always scanned); if that is empty too,
  -- capture has nowhere to go and says so rather than guessing.
  capture_note = nil,
  -- `:FzfKastenTaskList` -- the same task list as a buffer you work in with
  -- Vim keys, for when you are getting through the list rather than looking
  -- one task up. The picker cannot offer that: fzf's prompt owns every
  -- unmodified key, so `j`/`k`/`/`/`gg` are unavailable there whatever they
  -- are rebound to. Here nothing is mapped except the actions below.
  list = {
   -- Keep the list in the buffer list, so it shows in a bufferline/tabline as
   -- a tab and you switch back to it the way you switch to any open file. The
   -- alternative is having to reopen it every time, which for a view you keep
   -- glancing at is a keystroke too many. Set false to keep it out of the way.
   listed = true,
   -- Where it opens.
   --   "full"   : takes the current window; `<enter>` opens the note in place
   --              and `<c-o>` comes back.
   --   "split"  : above what you were reading, which stays put -- `<enter>`
   --   "vsplit" : opens the note there, so the list stays on screen.
   --   "tab"    : its own tab.
   open = "full",
   -- Hang each task's note and line off the right edge as virtual text: there
   -- when you want it, never in the way of the task, never yanked with it.
   source = true,
   -- A split under the list showing the task's note around its line, following
   -- the cursor. It is an ordinary window, so stepping into it (`p`) gives you
   -- every Vim key -- which is why there is no scroll vocabulary to learn here
   -- beyond pointing the usual ones at it.
   preview = {
    enabled = true,
    -- A fraction of the list window below 1, a line count at or above it.
    height = 0.5,
   },
   -- Buffer-local normal-mode keys. Unmodified letters on purpose -- the whole
   -- point of the buffer is that everything else is Vim's. `x`/`c`/`a`/`u`
   -- read as delete/change/append/undo, which is most of what they do.
   --
   -- Each entry is a key, a list of keys (all bound to that action), or
   -- `false` to leave the key to Vim.
   keys = {
    open = "<CR>",   -- open the note at this task
    done = "x",      -- tick it off
    cancel = "c",    -- drop it, keeping the line
    tag = "t",       -- add require_tag (promotes an inbox entry)
    add = "a",       -- capture a new task
    undo = "u",      -- put back the last line an action rewrote
    sort = "s",      -- cycle priority -> due -> added
    reverse = "S",   -- flip the order
    inbox = "i",     -- switch between the task list and the inbox
    refresh = "r",   -- re-scan the notes
    close = "q",
    -- The preview. All three of Vim's scroll pairs are pointed at the split
    -- below, so the rule is one line: scrolling is the preview, the list moves
    -- by cursor. They do there exactly what they do to any window in Vim, so
    -- there is nothing new to remember -- and `<c-d>`/`<c-u>`, the pair hands
    -- actually reach for, lands where you are looking. With no preview up they
    -- fall through to Vim's own behaviour on the list.
    -- `p` steps into the preview, where the rest of Vim (`gg`, `/`) applies as
    -- usual and `preview_back` comes out again.
    preview = "p",
    preview_toggle = "P",
    -- Pressed inside the preview window. Not `q`, which closes the list: one
    -- key doing "leave this window" in one place and "close the whole thing"
    -- in another is a coin toss you have to make every time.
    preview_back = { "<Esc>", "<C-q>" },
    preview_half_page_down = "<C-d>",
    preview_half_page_up = "<C-u>",
    preview_page_down = "<C-f>",
    preview_page_up = "<C-b>",
    preview_down = "<C-e>",
    preview_up = "<C-y>",
   },
  },
  -- When set (e.g. "todo"), only checkboxes carrying `#<require_tag>` count as
  -- tasks. Everything else becomes the inbox (`:FzfKastenTaskInbox`), so
  -- checkboxes you never meant as your own -- other people's action items in
  -- meeting minutes, acceptance criteria -- stay out of the list without
  -- disappearing. nil means every checkbox is a task.
  require_tag = nil,
  -- Written when a task is completed and removed when it is reopened, so you
  -- can answer "what did I finish last week". `format` is an os.date format;
  -- `pattern` must match what `format` writes (its capture becomes
  -- `task.done_at`) so the stamp can be stripped again. `false` writes
  -- nothing -- not nil, which setup() would merge away.
  --
  -- The checkbox stays the single source of truth for done-ness -- the stamp
  -- only records when. Keeping state in a tag instead would desync the moment
  -- another editor ticks the box without knowing about the tag.
  done_stamp = {
   format = " done:%Y-%m-%d %H:%M",
   pattern = "%s*done:(%d%d%d%d%-%d%d%-%d%d %d%d:%d%d)",
  },
  -- The same, for a task you dropped (its capture becomes
  -- `task.cancelled_at`). Deliberately not `done_stamp`: dropping a task is
  -- not finishing it, and a cancelled task in "what did I finish last week"
  -- would be a lie. `false` writes nothing -- not nil, which setup() would
  -- merge away, leaving this default in place.
  cancel_stamp = {
   format = " cancelled:%Y-%m-%d",
   pattern = "%s*cancelled:(%d%d%d%d%-%d%d%-%d%d)",
  },
  -- Wrapped around the text of a cancelled task, and removed when it is
  -- reopened. Decoration, never state: `marks.cancelled` alone says whether a
  -- task is cancelled, and if the two disagree the mark wins. It earns its
  -- place because `[-]` is not a checkbox to GitHub or a phone's markdown
  -- viewer, which render it as literal text -- struck-through text still
  -- reads as dropped anywhere the note is read. `false` writes nothing.
  cancel_strike = "~~",
  -- function(task) -> boolean, called for every task found; return false to
  -- drop it. The task is fully parsed by now (text, done, priority, due, rel,
  -- lineno, date), so this is where conventions fzfkasten can't know about
  -- live -- most often "whose task is this?", since meeting notes tend to
  -- record action items for other people too.
  filter = nil,
  -- function(tasks) called after each collect. Hook for exporting elsewhere
  -- (an aggregated index note, todo.txt, an external tracker, ...).
  on_collect = nil,
 },
 transform = {
  insert_link = function(filename)
   return string.format("[[%s]]", filename)
  end,
  new_file_name = function(title)
   return title
  end,
  -- Sanitize a title into a filesystem-safe filename (without extension).
  -- Default: strip characters unsafe on common filesystems, trim whitespace,
  -- collapse internal whitespace, and remove leading/trailing dots.
  -- Preserves unicode (CJK, emoji, accented characters, etc.) by design —
  -- override this if you want ASCII-only names or slug-style kebab-case.
  sanitize_filename = function(title)
   local s = title or ""
   s = s:gsub('[/\\:*?"<>|%c]', "")
   s = s:gsub("^%s+", ""):gsub("%s+$", "")
   s = s:gsub("%s+", " ")
   s = s:gsub("^%.+", ""):gsub("%.+$", "")
   return s
  end,
 },
 -- Extra template placeholders merged with the built-ins (title, date,
 -- hdate, year, month, day, week, time). Values may be strings or
 -- functions; functions receive the current note title and must return
 -- a string. User-supplied keys override built-ins of the same name.
 template_placeholders = {},
 -- Tweaks applied to note buffers that fzfkasten itself opens. Every such
 -- buffer gets `vim.b.fzfkasten = true` regardless of these flags, so you can
 -- gate your own autocmds on it. The opt-outs below are on by default because
 -- LSP diagnostics / autoformat tend to be noisy on prose notes.
 note_buffer = {
  -- Disable diagnostics for the buffer (vim.diagnostic.enable(false, ...)).
  disable_diagnostics = true,
  -- Set conform.nvim's `disable_autoformat` plus a few generic "format on
  -- save" flags (autoformat, format_on_save) so common setups skip the buffer.
  disable_format = true,
  -- Optional extra hook: function(bufnr) called after marking the buffer.
  on_open = nil,
 },
 claude = {
  enabled = false,
  -- Claude Code runs in a pane of a terminal multiplexer, and that is where
  -- notes and prompts are sent -- by typing into it, the way you would.
  pane = {
   -- Which multiplexer's CLI does the typing: "herdr" or "tmux".
   via = "herdr",
   -- The pane to send to: a herdr pane id or agent name ("w1:p2", "claude"),
   -- or a tmux target ("%3", "notes:1.2"). Left unset, the panes are listed
   -- and you pick one, which is then remembered until nvim is closed.
   target = nil,
   -- ssh host the pane is on. Unset means this machine. With it set, the CLI
   -- runs over there -- so `cmd` may need to be an absolute path, since a
   -- non-interactive ssh gets a shorter PATH than your shell does.
   host = nil,
   -- The multiplexer's executable. Defaults to `via`.
   cmd = nil,
   -- Send the text as a paste (wrapped in the terminal's bracketed-paste
   -- markers) rather than as typing. Keeps a prompt with newlines in it from
   -- being submitted a line at a time, and keeps anything that reads keystrokes
   -- on the way in from interpreting the characters. Turn off only for a
   -- receiver that doesn't understand a paste.
   paste = true,
   -- A buffer with no file behind it (the task list, a preview) is sent by
   -- pasting what it shows, since there is nothing for the pane to read. This
   -- caps how much: past it, send a selection instead, or raise this.
   max_lines = 500,
   -- Where `home` is on the `host` machine, when the two differ. Notes are
   -- named to Claude by their path over there, and the collection is expected
   -- to be the same one -- the same git clone, kept in step (see below).
   root = nil,
  },
  -- Named prompts sent to the pane with `:FzfKastenClaudePrompt <name>`.
  -- Each entry:
  --   text   : the string typed into the pane (required).
  --   note   : "weekly" | "daily" | "current" (or nil) -- the note the prompt
  --            is about, named in the text so Claude reads it as context.
  --            weekly/daily are opened first (created from their template if
  --            missing), "current" is the note you are in, nil names none.
  --   submit : send a trailing Return so Claude runs it now (default true).
  -- e.g. retro = { note = "weekly", text = "/my-weekly-retro" }
  prompts = {},
 },
 -- Passed through to fzf-lua for every picker fzfkasten opens, so anything
 -- fzf-lua takes can go here: `winopts`, `fzf_opts`, `previewer`, and `keymap`.
 --
 -- Keys belong in `keymap.fzf` (fzf's own keys) or `keymap.builtin` (the ones
 -- Neovim handles) and *not* in `fzf_opts["--bind"]`, which fzf-lua overwrites
 -- with whatever it builds from `keymap` -- a bind written there is silently
 -- dropped. `ctrl-h:backward-delete-char` used to be here, doing nothing; fzf
 -- binds ctrl-h to backward-delete-char itself anyway.
 --
 -- fzf-lua merges these over its own defaults per key, so naming one key keeps
 -- the rest -- and keeps the binds the note finder adds for `/kaigi`.
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

M.options = vim.tbl_deep_extend("force", M.defaults, {})

-- Has `setup()` run? `M.options` starts as a copy of the defaults, so nothing
-- about it can tell "configured with nothing" from "never configured" -- and
-- the difference matters, because the default `home` is a guess. `:checkhealth`
-- reads this to say which of the two you are looking at.
M.configured = false

function M.setup(user_opts)
 -- Deep so a user table naming one field of a nested option keeps the rest.
 M.options = vim.tbl_deep_extend("force", M.defaults, user_opts or {})
 M.configured = true

 -- `~` is written by hand and read by every other module, so expand it once.
 M.options.home = vim.fn.expand(M.options.home)

 if M.options.home == "" then
  vim.notify("[Fzfkasten] 'home' directory is not configured!", vim.log.levels.ERROR)
  return
 end
end

return M