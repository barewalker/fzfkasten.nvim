local M = {}

M.defaults = {
 -- 優先順位: 環境変数 > デフォルト値 (~/notes)
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
  },
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
   -- Set to nil to disable the mechanism.
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
   scan = [[^\s*[-*]\s+\[[ xX]\]\s+]],
   open = "^%s*[-*]%s+%[ %]%s+(.+)$",
   done = "^%s*[-*]%s+%[[xX]%]%s+(.+)$",
   -- Captures (before)(mark)(after) around a checkbox's mark, for toggling.
   toggle = "^(%s*[-*]%s+%[)([ xX])(%])",
   priority = "^%((%u)%)%s+",
   due = "due:(%d%d%d%d%-%d%d%-%d%d)",
  },
  -- What the `toggle` pattern's mark capture is replaced with.
  marks = { open = " ", done = "x" },
  -- When set (e.g. "todo"), only checkboxes carrying `#<require_tag>` count as
  -- tasks. Everything else becomes the inbox (`:FzfKastenTaskInbox`), so
  -- checkboxes you never meant as your own -- other people's action items in
  -- meeting minutes, acceptance criteria -- stay out of the list without
  -- disappearing. nil means every checkbox is a task.
  require_tag = nil,
  -- Written when a task is completed and removed when it is reopened, so you
  -- can answer "what did I finish last week". `format` is an os.date format;
  -- `pattern` must match what `format` writes (its capture becomes
  -- `task.done_at`) so the stamp can be stripped again. nil writes nothing.
  --
  -- The checkbox stays the single source of truth for done-ness -- the stamp
  -- only records when. Keeping state in a tag instead would desync the moment
  -- another editor ticks the box without knowing about the tag.
  done_stamp = {
   format = " done:%Y-%m-%d %H:%M",
   pattern = "%s*done:(%d%d%d%d%-%d%d%-%d%d %d%d:%d%d)",
  },
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
 },
 fzf = {
  winopts = {
   height = 0.85,
   width = 0.80,
   preview = { layout = "vertical" },
  },
  fzf_opts = {
    ["--bind"] = "ctrl-h:backward-delete-char",
  },
  files = {
   previewer = "builtin",
  },
 },
}

M.options = vim.tbl_deep_extend("force", M.defaults, {})

function M.setup(user_opts)
 -- M.defaults と user_opts をマージ
 M.options = vim.tbl_deep_extend("force", M.defaults, user_opts or {})

 -- パスの展開 (~ をフルパスに変換)
 M.options.home = vim.fn.expand(M.options.home)

 -- 未設定時のバリデーション
 if M.options.home == "" then
  vim.notify("[Fzfkasten] 'home' directory is not configured!", vim.log.levels.ERROR)
  return
 end
end

return M