-- Task collection and picking.
--
-- Tasks are plain markdown checkboxes (`- [ ]` / `- [x]`) written directly in
-- your notes. There is no index, no database and no separate task file: every
-- call re-scans with ripgrep. Anything else that can edit markdown -- a mobile
-- git client, another editor, a script -- therefore stays in sync for free,
-- because the notes *are* the ledger.
--
-- Checkboxes nest. A checkbox indented under another is a subtask of it, and
-- inherits `require_tag` from it: deciding an item is yours is a decision about
-- the whole item, so its steps don't each need tagging. The picker keeps a
-- subtask under the item it belongs to, and a task hanging off a plain bullet
-- carries that bullet along -- a task line read on its own is the context the
-- list otherwise loses.

local fzf = require('fzf-lua')
local config = require('fzfkasten.config')
local utils = require('fzfkasten.utils')
local buffer = require('fzfkasten.buffer')
local romaji = require('fzfkasten.romaji')

local M = {}


-- A broken `tasks.date`/`tasks.filter` hook would otherwise warn once per
-- note (or per task) scanned.
local date_hook_warned = false
local filter_hook_warned = false

-- Lines rewritten in notes on disk, newest last, for `M.undo`.
--
-- Only the paths that write a file are recorded. The ones that edit a buffer
-- are Vim's `u` to undo, and a second undo stack over the same edit would
-- fight it: `u` puts the line back in the buffer, then this would put it back
-- in the file the buffer no longer agrees with.
--
-- Each entry keeps the line as it was and as we left it, so an undo can tell
-- "still as I left it" from "someone has edited this since" and refuse the
-- second rather than overwrite work it knows nothing about.
local history = {}
local HISTORY_MAX = 50

-- `added` marks an entry whose line was appended, not rewritten: it has no
-- `before` to restore, so `M.undo` deletes the line instead of replacing it.
local function remember(path, lineno, before, after, added)
    table.insert(history, { path = path, lineno = lineno, before = before, after = after, added = added })
    if #history > HISTORY_MAX then
        table.remove(history, 1)
    end
end

-- Ask the user's `filter` hook whether to keep a task. A hook that raises
-- keeps the task: dropping tasks because someone's config threw would hide
-- work with nothing to show for it.
local function keep(task)
    local fn = config.options.tasks.filter
    if type(fn) ~= "function" then
        return true
    end
    local ok, verdict = pcall(fn, task)
    if not ok then
        if not filter_hook_warned then
            filter_hook_warned = true
            vim.notify(
                string.format("[Fzfkasten] tasks.filter raised on %s:%d: %s",
                    task.rel, task.lineno, tostring(verdict)),
                vim.log.levels.WARN
            )
        end
        return true
    end
    return verdict ~= false
end

-- Every note under `home`. Used when `patterns.scan` is nil.
local function all_notes()
    local glob = utils.join_path(config.options.home, "**/*." .. config.options.extension)
    return vim.fn.glob(glob, true, true) or {}
end

-- Files worth reading at all: only those containing a checkbox. Everything
-- else (frontmatter opt-out, heading scope, note date) needs line context, so
-- it is decided in Lua on this much smaller set.
--
-- `patterns.scan` is a ripgrep regex, not a Lua pattern, so it cannot be
-- derived from `patterns.open`/`done` -- the two are different languages.
-- Setting it to `false` skips the pre-filter and reads every note instead.
local function candidate_notes()
    local scan = config.options.tasks.patterns.scan
    if not scan then
        return all_notes()
    end
    if vim.fn.executable("rg") == 0 then
        vim.notify(
            "[Fzfkasten] 'rg' (ripgrep) not found; reading every note. "
            .. "Set tasks.patterns.scan = false to silence this.",
            vim.log.levels.WARN
        )
        return all_notes()
    end
    local out = vim.fn.systemlist({
        "rg", "--files-with-matches", "--no-messages",
        "--glob", "*." .. config.options.extension,
        "-e", scan,
        config.options.home,
    })
    -- rg exits 1 when nothing matches; that is not an error for us.
    if vim.v.shell_error > 1 then
        return {}
    end
    return out or {}
end

-- Parse the YAML-ish frontmatter block. Only flat `key: value` pairs are read,
-- which is all the note metadata fzfkasten itself writes.
-- Returns the pairs plus the line the block closes on (0 when there is none),
-- so scanning can start below it.
local function parse_frontmatter(lines)
    if lines[1] ~= "---" then
        return {}, 0
    end
    local fm = {}
    for i = 2, #lines do
        if lines[i] == "---" then
            return fm, i
        end
        local k, v = lines[i]:match("^([%w_-]+):%s*(.-)%s*$")
        if k then
            fm[k] = v
        end
    end
    return {}, 0 -- unterminated: not frontmatter after all
end

-- Fenced code blocks hold examples, not tasks. A note documenting task syntax
-- would otherwise report its own examples as real tasks.
local function fence_delimiter(line)
    return line:match("^%s*(```+)") or line:match("^%s*(~~~+)")
end

-- A note's date, or nil when it doesn't record one.
--
-- Deliberately never falls back to mtime: notes living in a git repo have
-- their mtime rewritten on every checkout, so it says when the file was
-- synced, not when the note was written. Guessing from it would silently
-- drop real tasks out of a `since_days` window.
local function note_date(path, lines, fm)
    local o = config.options.tasks
    if type(o.date) == "function" then
        local ok, d = pcall(o.date, path, lines, fm)
        if ok and type(d) == "string" then
            local matched = d:match("(%d%d%d%d%-%d%d%-%d%d)")
            if matched then
                return matched
            end
        elseif not ok and not date_hook_warned then
            date_hook_warned = true
            vim.notify(
                string.format("[Fzfkasten] tasks.date raised on %s: %s", path, tostring(d)),
                vim.log.levels.WARN
            )
        end
    end

    local from_name = vim.fn.fnamemodify(path, ":t"):match("(%d%d%d%d%-%d%d%-%d%d)")
    if from_name then
        return from_name
    end

    for _, key in ipairs(o.date_keys or {}) do
        local v = fm[key]
        if v then
            local d = v:match("(%d%d%d%d%-%d%d%-%d%d)")
            if d then
                return d
            end
        end
    end
    return nil
end

local function is_falsy(v)
    return v == "false" or v == "no" or v == "off"
end

local function in_ignored_dir(rel)
    for _, dir in ipairs(config.options.tasks.ignore.dirs or {}) do
        if rel == dir or rel:sub(1, #dir + 1) == dir .. "/" then
            return true
        end
    end
    return false
end

local function heading_starts_tasks(text)
    local lowered = text:lower()
    for _, pat in ipairs(config.options.tasks.headings or {}) do
        if lowered:match(pat) then
            return true
        end
    end
    return false
end

-- Which lines of a note can hold a task: below the frontmatter, outside fenced
-- blocks, and -- when `scope` is "headings" -- under a heading that starts a
-- task list. A heading itself never qualifies.
--
-- Shared by `M.collect` and `M.tag` deliberately. Tagging a line the scan
-- skips would write a task that shows up nowhere, and two copies of these
-- rules would drift apart without anyone noticing until a task went missing.
-- @return table set of the 1-indexed line numbers that qualify
local function scannable_lines(lines, fm_end)
    local o = config.options.tasks
    local scannable = {}
    local in_scope = (o.scope ~= "headings")
    local fence = nil
    for lineno = fm_end + 1, #lines do
        local line = lines[lineno]
        local delim = fence_delimiter(line)
        if fence then
            -- Only a delimiter of the same kind, at least as long as the
            -- opening one, closes the block.
            if delim and #delim >= #fence and delim:sub(1, 1) == fence:sub(1, 1) then
                fence = nil
            end
        elseif delim then
            fence = delim
        else
            local heading = line:match("^#+%s+(.*)$")
            if heading then
                if o.scope == "headings" then
                    in_scope = heading_starts_tasks(vim.trim(heading))
                end
            elseif in_scope then
                scannable[lineno] = true
            end
        end
    end
    return scannable
end

-- How deep a list item sits, in display columns. A tab counts as four so a
-- note that mixes tabs and spaces still nests the way it looks like it does.
local function indent_width(line)
    local width = 0
    for ch in (line:match("^[ \t]*") or ""):gmatch(".") do
        width = width + (ch == "\t" and 4 or 1)
    end
    return width
end

-- The text of a list item that is *not* a checkbox, or nil when the line is
-- neither. A bullet holds no task, but tasks nest under it, and it is the
-- context they lose when the picker shows the task line by itself.
--
-- Checkboxes match this shape too, so callers test for one first.
local function bullet_text(line)
    return line:match("^%s*[-*+]%s+(.+)$") or line:match("^%s*%d+[%.%)]%s+(.+)$")
end

local function is_always(rel)
    for _, p in ipairs(config.options.tasks.always or {}) do
        if rel == p then
            return true
        end
    end
    return false
end

-- Does `text` carry `#<tag>`? The frontier stops `#todo` matching `#todos`.
local function has_tag(text, tag)
    return text:find("#" .. vim.pesc(tag) .. "%f[%W]") ~= nil
end

-- Strip the strikethrough a cancelled task wears, or return the text as it
-- came. Only a wrap around the whole text is removed: a `~~` the note's author
-- put there for their own reasons is theirs, not ours to unwrap.
local function unstrike(text, wrap)
    if not wrap or wrap == "" then
        return text
    end
    local inner = text:match("^" .. vim.pesc(wrap) .. "(.*)" .. vim.pesc(wrap) .. "$")
    return inner or text
end

-- Pull `(A)`, `due:YYYY-MM-DD` and the stamps out of the task text.
local function parse_task_text(text, o)
    local priority = text:match(o.patterns.priority)
    if priority then
        text = text:gsub(o.patterns.priority, "", 1)
    end
    local due = text:match(o.patterns.due)

    local done_at
    local stamp = o.done_stamp
    if stamp and stamp.pattern then
        done_at = text:match(stamp.pattern)
        if done_at then
            text = text:gsub(stamp.pattern, "")
        end
    end

    local cancelled_at
    local cancel = o.cancel_stamp
    if cancel and cancel.pattern then
        cancelled_at = text:match(cancel.pattern)
        if cancelled_at then
            text = text:gsub(cancel.pattern, "")
        end
    end
    -- After the stamp, which sits outside the strikethrough.
    text = unstrike(vim.trim(text), o.cancel_strike)

    return vim.trim(text), priority, due, done_at, cancelled_at
end

-- Split a checkbox line into its checkbox ("- [ ] "), the mark inside it, and
-- the text after it -- or nil when the line holds no checkbox.
--
-- `patterns.toggle`'s captures cover the checkbox and nothing else, so the
-- text is whatever follows them. That is the one place the checkbox syntax is
-- pinned down, which is why rewriting a task goes through here.
-- @return table|nil `{ before, mark, after, rest }`; the line is exactly
--   `before .. mark .. after .. rest`, so rewriting the mark is a concat.
local function split_checkbox(line)
    local before, mark, after = line:match(config.options.tasks.patterns.toggle)
    if not before then
        return nil
    end
    return {
        before = before,
        mark = mark,
        after = after,
        rest = line:sub(#before + #mark + #after + 1),
    }
end

-- Flip a checkbox line between open and done, or nil when the line holds no
-- checkbox. A cancelled task is refused rather than silently reopened: `- [-]`
-- is a decision, and there is a command that reverses it.
local function toggle_line(line)
    local o = config.options.tasks
    local cb = split_checkbox(line)
    if cb and cb.mark == o.marks.cancelled then
        return nil, "cancelled"
    end

    local now_done
    local toggled, n = line:gsub(o.patterns.toggle, function(before, m, after)
        now_done = m == o.marks.open
        return before .. (now_done and o.marks.done or o.marks.open) .. after
    end, 1)
    if n == 0 then
        return nil
    end

    local stamp = o.done_stamp
    if stamp and stamp.format and stamp.pattern then
        -- Drop any existing stamp first, so reopening leaves no trace and
        -- completing twice doesn't accumulate them.
        toggled = toggled:gsub(stamp.pattern, "")
        toggled = toggled:gsub("%s+$", "")
        if now_done then
            toggled = toggled .. os.date(stamp.format)
        end
    end
    return toggled
end

-- Cancel a task, or reopen one already cancelled. Returns the rewritten line,
-- or nil plus a reason.
--
-- Cancelling is not completing, so a done task is refused: `- [x]` says the
-- work happened, and dropping it afterwards is a contradiction rather than
-- something to guess at. The line itself always stays -- that it was once a
-- task is the record worth keeping, and deleting it is what loses that.
--
-- The strikethrough goes around the text but inside the priority and the
-- stamp: `priority` is anchored to the start of the text, so `~~(A) foo~~`
-- would hide it, and the cancelling is not itself cancelled.
local function cancel_line(line)
    local o = config.options.tasks
    local cb = split_checkbox(line)
    if not cb then
        return nil, "no checkbox"
    end
    if cb.mark == o.marks.done then
        return nil, "done"
    end

    local lead, text = cb.rest:match("^(%s*)(.-)%s*$")
    if text == "" then
        return nil, "no checkbox"
    end

    -- Keep the priority marker where it is, ahead of anything we wrap.
    local kept = ""
    if text:match(o.patterns.priority) then
        local body = text:gsub(o.patterns.priority, "", 1)
        kept = text:sub(1, #text - #body)
        text = body
    end

    local reopening = cb.mark == o.marks.cancelled
    local stamp = o.cancel_stamp
    if stamp and stamp.pattern then
        text = vim.trim(text:gsub(stamp.pattern, ""))
    end
    text = unstrike(text, o.cancel_strike)

    if not reopening then
        if o.cancel_strike and o.cancel_strike ~= "" then
            text = o.cancel_strike .. text .. o.cancel_strike
        end
        if stamp and stamp.format and stamp.pattern then
            text = text .. os.date(stamp.format)
        end
    end

    local mark = reopening and o.marks.open or o.marks.cancelled
    return cb.before .. mark .. cb.after .. lead .. kept .. text
end

-- Raise a line to a tagged task, or nil when there is nothing to raise it
-- from (blank line) or nothing left to do (already tagged).
--
-- Prose and bare bullets become checkboxes on the way: noticing mid-sentence
-- that a line is yours to do is exactly when you want one keystroke, not
-- three edits. The indent is kept so the line stays where it sits in a list.
local function tag_line(line, tag)
    local o = config.options.tasks
    -- Any checkbox, whatever its mark: asking `open`/`done` instead would read
    -- a cancelled task as prose and bullet it a second time.
    if not split_checkbox(line) then
        local indent, text = line:match("^(%s*)(.-)%s*$")
        -- Strip a bullet the line already has, so promoting it doesn't write
        -- a second one ("- - [ ] x").
        text = text:gsub("^[-*]%s+", "")
        if text == "" then
            return nil
        end
        line = indent .. o.new_checkbox .. text
    end
    if has_tag(line, tag) then
        return nil
    end
    return line:gsub("%s*$", "") .. " #" .. tag
end

-- Build the checkbox line for a freshly captured task, or nil when there is
-- nothing to capture (blank text). The tag goes on so the new task lands in
-- the task list rather than the inbox: capture is a decision to do the thing,
-- and `require_tag` is what that decision looks like on disk.
local function new_task_line(text, tag, due)
    text = vim.trim(text or "")
    if text == "" then
        return nil
    end
    local line = config.options.tasks.new_checkbox .. text
    if tag and not has_tag(line, tag) then
        line = line .. " #" .. tag
    end
    -- Due last, past the text and the tag, the way the notes already write it
    -- (`redraw #todo due:...`). The caller resolves it to ISO first.
    if due and due ~= "" then
        line = line .. " due:" .. due
    end
    return line
end

-- Is `date` an absolute due date we will write? An ISO day, or a day with an
-- ISO HH:MM time. No relative forms, no seconds, no timezone: the writer's
-- output is the on-disk contract, so it stays exactly what `patterns.due`
-- reads back. Calendar validity (no 2026-02-30) is not checked -- the shape is,
-- same as everywhere else the syntax is matched rather than parsed.
local function valid_due(date)
    return date:match("^%d%d%d%d%-%d%d%-%d%d$") ~= nil
        or date:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d$") ~= nil
end

-- Day offsets for the words people reach for. Japanese keys sit alongside the
-- English so `明日` and `tomorrow` both land.
local REL_OFFSETS = {
    today = 0, ["今日"] = 0,
    tomorrow = 1, tom = 1, tmr = 1, ["明日"] = 1, ["あした"] = 1,
    ["明後日"] = 2, ["あさって"] = 2,
}
-- Weekday -> os.date("%w") number (0 = Sunday).
local WEEKDAYS = {
    sun = 0, sunday = 0, ["日"] = 0,
    mon = 1, monday = 1, ["月"] = 1,
    tue = 2, tuesday = 2, ["火"] = 2,
    wed = 3, wednesday = 3, ["水"] = 3,
    thu = 4, thursday = 4, ["木"] = 4,
    fri = 5, friday = 5, ["金"] = 5,
    sat = 6, saturday = 6, ["土"] = 6,
}

-- Turn a due spec into an absolute ISO date, or nil when it isn't one we know.
--
-- Absolute forms pass straight through (whatever `valid_due` accepts); the rest
-- are read relative to `now`: `today`/`tomorrow` (and `明日`), `+3d`/`2w`, and
-- weekday names (`fri`, `金`). A weekday resolves to the nearest day with that
-- name at or after `now`, so on a Tuesday `fri` is this week and `tue` is today.
--
-- `now` is a parameter, defaulting to today, so the relative resolution can be
-- tested against a fixed day rather than whenever the suite happens to run.
local function resolve_due(spec, now)
    spec = vim.trim(spec or "")
    if spec == "" then
        return nil
    end
    if valid_due(spec) then
        return spec
    end
    now = now or os.time()
    local key = spec:lower()
    -- Japanese keys don't lowercase, so try the raw spec for those.
    local off = REL_OFFSETS[key] or REL_OFFSETS[spec]
    if off then
        return os.date("%Y-%m-%d", utils.days_from(now, off))
    end
    local n, unit = key:match("^%+?(%d+)([dw])$")
    if n then
        local mult = unit == "w" and 7 or 1
        return os.date("%Y-%m-%d", utils.days_from(now, tonumber(n) * mult))
    end
    local wd = WEEKDAYS[key] or WEEKDAYS[spec]
    if wd then
        local today_wd = tonumber(os.date("%w", now))
        local delta = (wd - today_wd) % 7
        return os.date("%Y-%m-%d", utils.days_from(now, delta))
    end
    return nil
end

-- Set, replace or clear the `due:` on an open task. Returns the rewritten line,
-- or nil plus a reason.
--
-- A done or cancelled task is refused: a due date is when something still needs
-- doing, which a finished or dropped task no longer does. Refusing keeps the
-- writer from leaving a due date on a line no list would ever surface it from.
--
-- The token goes at the end of the text, past the priority and the tag, so it
-- reads the way the notes already write it (`(A) redraw #todo due:...`). An
-- empty date clears it, leaving no dangling space.
local function due_line(line, date)
    local o = config.options.tasks
    local cb = split_checkbox(line)
    if not cb then
        return nil, "no checkbox"
    end
    if cb.mark ~= o.marks.open then
        return nil, "not open"
    end
    date = date and vim.trim(date) or ""

    -- Strip any existing due, its leading space and all, so setting is
    -- idempotent and clearing leaves the line as if it never had one.
    local stripped = line:gsub("%s*" .. o.patterns.due, ""):gsub("%s+$", "")
    if date == "" then
        return stripped
    end
    if not valid_due(date) then
        return nil, "bad date"
    end
    return stripped .. " due:" .. date
end

-- What a task sorts by: the outermost item it hangs off, or itself when it
-- hangs off nothing. Sorting a subtask on its own priority would scatter the
-- steps of one job across the list, which is exactly the context nesting is
-- there to keep. `root_lineno` is set for every collected task, so its absence
-- marks a task table that never went through `M.collect` (the suite builds
-- some by hand) and falls back to the task's own fields.
local function sort_key(task)
    if task.root_lineno then
        return task.root_priority, task.root_due, task.root_lineno
    end
    return task.priority, task.due, task.lineno
end

-- The orderings the picker cycles through with `<alt-s>`, in that order.
--
--   priority : what you decided matters, then what runs out first.
--   due      : what runs out first, whatever you decided about it.
--   added    : the order they were written down -- note date, then position in
--              the note. Captures append, so within one note this is capture
--              order; across notes it is when the note was written.
--
-- `priority` is first because it is the default, and `<alt-s>` from the last
-- mode comes back to it.
local SORTS = { "priority", "due", "added" }

--- The mode after `sort`, wrapping round. An unknown mode (or nil) is treated
--- as the default, so cycling from a stale value lands somewhere sensible.
--- Public because both the picker and the task list buffer cycle the ordering,
--- and they have to cycle it the same way.
--- @param sort string|nil
--- @return string
function M.next_sort(sort)
    for i, name in ipairs(SORTS) do
        if name == sort then
            return SORTS[i % #SORTS + 1]
        end
    end
    return SORTS[2]
end

-- The keys a task orders by, most significant first. All of them fall back to a
-- sentinel that sorts last, so "no due date" means "not urgent" rather than
-- "first". Everything is taken from the task's root (`sort_key`), which is what
-- keeps a subtask travelling with the item it is a step of.
local function sort_fields(task, sort)
    local priority, due, lineno = sort_key(task)
    if sort == "due" then
        return { due or "9999-99-99", priority or "~", task.path, lineno }
    elseif sort == "added" then
        return { task.date or "9999-99-99", task.path, lineno }
    end
    return { priority or "~", due or "9999-99-99", task.path, lineno }
end

--- Order `tasks` in place.
--- @param tasks table
--- @param sort string|nil one of `SORTS`; anything else means "priority"
--- @param reverse boolean|nil flip the order of the items, not of their steps
local function sort_tasks(tasks, sort, reverse)
    table.sort(tasks, function(a, b)
        local af, bf = sort_fields(a, sort), sort_fields(b, sort)
        for i = 1, #af do
            if af[i] ~= bf[i] then
                local before = af[i] < bf[i]
                if reverse then
                    return not before
                end
                return before
            end
        end
        -- Same item: its subtasks keep the order they are written in, whichever
        -- way the list is pointing. Reversing the steps of a job would make it
        -- unreadable, and the steps are not what you asked to sort.
        return a.lineno < b.lineno
    end)
    return tasks
end

--- Collect tasks from every note under `home`.
--- @param opts table|nil `{ since_days = number|false, done = boolean,
---   cancelled = boolean, inbox = boolean, sort = string, reverse = boolean }`.
---   `since_days = false` disables the date window for this call; `inbox = true`
---   returns the checkboxes `require_tag` leaves out. `done` and `cancelled`
---   each add that state to the result; both are left out otherwise. `sort` is
---   "priority" (the default), "due" or "added", and `reverse` flips it.
--- @return table list of `{ text, done, done_at, cancelled, cancelled_at,
---   priority, due, path, rel, lineno, date, depth, parent, context, children,
---   children_closed, orphaned }`. The last six describe the nesting: `depth`
---   is how many checkboxes this one sits inside, `parent` the task table it
---   sits in (nil at the top), `context` the text of the list item directly
---   above it whatever that is, `children`/`children_closed` count its subtasks
---   and how many are done or cancelled, and `orphaned` marks a subtask whose
---   parent the filters dropped.
function M.collect(opts)
    opts = opts or {}
    local o = config.options.tasks
    local home = config.options.home
    -- `inbox` asks for the complement: checkboxes without the tag.
    local wants_tagged = not opts.inbox

    local since = opts.since_days
    if since == nil then
        since = o.since_days
    end
    local cutoff = since and since ~= false
        and os.date("%Y-%m-%d", utils.days_from(nil, -since)) or nil

    date_hook_warned = false
    filter_hook_warned = false
    local tasks = {}
    for _, path in ipairs(candidate_notes()) do
        local rel = path:sub(#home + 2)
        if not in_ignored_dir(rel) then
            local ok, lines = pcall(vim.fn.readfile, path)
            if ok and lines then
                local fm, fm_end = parse_frontmatter(lines)
                local opted_out = o.ignore.frontmatter_key
                    and is_falsy(fm[o.ignore.frontmatter_key])
                local date = note_date(path, lines, fm)
                -- A note with no date is never aged out: dropping tasks we
                -- can't date would hide them with no way to notice.
                local aged_out = cutoff and date and date < cutoff and not is_always(rel)
                -- With `require_tag`, an old note can still hold tasks you
                -- tagged, so it has to be read; only its untagged checkboxes
                -- age out. Without it, every checkbox is a task and an old
                -- note has nothing left to offer.
                local skip_note = opted_out or (aged_out and not o.require_tag)

                if not skip_note then
                    local scannable = scannable_lines(lines, fm_end)
                    -- The list items still open above the line being read,
                    -- outermost last. A checkbox indented past the one on top
                    -- is nested inside it, which is what makes a subtask a
                    -- subtask -- and how it inherits the tag.
                    local stack = {}
                    for lineno = fm_end + 1, #lines do
                        if scannable[lineno] then
                            local line = lines[lineno]
                            local raw = line:match(o.patterns.open)
                            local done, cancelled = false, false
                            if not raw then
                                raw = line:match(o.patterns.done)
                                done = raw ~= nil
                            end
                            if not raw and o.patterns.cancelled then
                                raw = line:match(o.patterns.cancelled)
                                cancelled = raw ~= nil
                            end
                            local bullet = not raw and bullet_text(line) or nil

                            if raw or bullet then
                                local indent = indent_width(line)
                                -- Close every item this line is a sibling of,
                                -- or has outdented past.
                                while #stack > 0 and stack[#stack].indent >= indent do
                                    table.remove(stack)
                                end
                                local parent = stack[#stack]

                                if not raw then
                                    -- A bullet is never a task and never
                                    -- introduces the tag, but it doesn't break
                                    -- the chain either: it passes down whatever
                                    -- the item above it decided, so a checkbox
                                    -- under a note under a task is still that
                                    -- task's subtask.
                                    table.insert(stack, {
                                        indent = indent,
                                        text = bullet,
                                        tagged = parent ~= nil and parent.tagged or false,
                                        depth = parent and parent.depth or 0,
                                        task = parent and parent.task or nil,
                                        root = parent and parent.root or nil,
                                    })
                                else
                                    local text, priority, due, done_at, cancelled_at =
                                        parse_task_text(raw, o)
                                    local task = {
                                        text = text,
                                        done = done,
                                        done_at = done_at,
                                        cancelled = cancelled,
                                        cancelled_at = cancelled_at,
                                        priority = priority,
                                        due = due,
                                        path = path,
                                        rel = rel,
                                        lineno = lineno,
                                        date = date,
                                        depth = parent and parent.depth or 0,
                                        parent = parent and parent.task or nil,
                                        context = parent and parent.text or nil,
                                    }
                                    -- With `require_tag` set, a checkbox is a
                                    -- task only if tagged; the rest are inbox.
                                    -- A subtask of your task is yours too:
                                    -- tagging the item was the decision, and
                                    -- repeating it on every step of it is
                                    -- bookkeeping with nothing to show for it.
                                    local tagged = not o.require_tag
                                        or has_tag(text, o.require_tag)
                                        or (parent ~= nil and parent.tagged)
                                    -- The outermost item this one hangs off, so
                                    -- `sort_tasks` can keep a subtask under it
                                    -- rather than let its own priority scatter
                                    -- it across the list.
                                    local root = (parent and parent.root) or task
                                    task.root_lineno = root.lineno
                                    task.root_priority = root.priority
                                    task.root_due = root.due
                                    if task.parent then
                                        local p = task.parent
                                        p.children = (p.children or 0) + 1
                                        if done or cancelled then
                                            p.children_closed = (p.children_closed or 0) + 1
                                        end
                                    end
                                    table.insert(stack, {
                                        indent = indent,
                                        text = text,
                                        tagged = tagged,
                                        depth = task.depth + 1,
                                        task = task,
                                        root = root,
                                    })
                                    -- A tagged task never ages out. Tagging it
                                    -- was a decision; expiring it by date would
                                    -- hide work that was explicitly accepted,
                                    -- and it would fall out of the inbox too --
                                    -- invisible in both views. `since_days`
                                    -- bounds the inbox, not your commitments.
                                    if not (aged_out and not tagged)
                                        and tagged == wants_tagged and keep(task) then
                                        table.insert(tasks, task)
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    if not opts.done then
        tasks = vim.tbl_filter(function(t) return not t.done end, tasks)
    end
    -- Cancelled tasks are out of both lists by default: dropping one was the
    -- point. `cancelled = true` is how you go looking for what you dropped.
    if not opts.cancelled then
        tasks = vim.tbl_filter(function(t) return not t.cancelled end, tasks)
    end

    -- A subtask whose parent the filters just dropped -- an open step under a
    -- finished item, an untagged parent in the inbox -- has no row above it to
    -- read the context off. Mark it so the picker spells the parent out inline
    -- instead of indenting it under nothing.
    local shown = {}
    for _, task in ipairs(tasks) do
        shown[task] = true
    end
    for _, task in ipairs(tasks) do
        task.orphaned = task.parent ~= nil and not shown[task.parent]
    end

    sort_tasks(tasks, opts.sort, opts.reverse)

    if type(o.on_collect) == "function" then
        pcall(o.on_collect, tasks)
    end
    return tasks
end

-- Task text as the list shows it: without the `due:` token, which gets its own
-- column, and without `require_tag`, which every task carries anyway -- both
-- would only spend width saying what the list already says.
local function display_text(text)
    local o = config.options.tasks
    text = text:gsub(o.patterns.due, "")
    if o.require_tag then
        text = text:gsub("#" .. vim.pesc(o.require_tag) .. "%f[%W]", "")
    end
    local squeezed = (" " .. text .. " "):gsub("%s+", " ")
    return vim.trim(squeezed)
end

-- How much of a parent bullet an entry spells out before cutting it. Context
-- is prose and runs long; past this it costs more width than it gives back.
local CONTEXT_WIDTH = 40

-- Cut `text` to `width` display columns, marking the cut. Counted in columns
-- rather than characters because the notes are largely Japanese, where one
-- character is two columns wide.
local function truncate(text, width)
    if vim.fn.strdisplaywidth(text) <= width then
        return text
    end
    for i = vim.fn.strchars(text), 1, -1 do
        local cut = vim.fn.strcharpart(text, 0, i)
        if vim.fn.strdisplaywidth(cut) <= width - 1 then
            return cut .. "…"
        end
    end
    return "…"
end

--- How a task reads on one line, without saying which note it came from: the
--- indent that puts a subtask under its parent, the priority, the text, how far
--- along its steps are, the due date, and the context it hangs off.
---
--- A subtask is indented under the item it belongs to, and an item with
--- subtasks shows how many are settled. When the parent isn't in the list --
--- it's a plain bullet, or the filters dropped it -- there is no row above to
--- read the context off, so the parent's text is spelled out on the line.
---
--- Public because the picker and the task list buffer both render it, and a
--- task that read differently in the two would be a task you had to recognise
--- twice.
--- @param task table one entry from `M.collect`
--- @return string
function M.entry_text(task)
    local depth = task.depth or 0
    local nested = depth > 0 and task.parent ~= nil and not task.orphaned
    local lead = nested and (string.rep("  ", depth) .. "↳ ") or ""
    local prefix = task.priority and string.format("(%s) ", task.priority) or ""
    local children = task.children or 0
    local progress = children > 0
        and string.format("  [%d/%d]", task.children_closed or 0, children) or ""
    local due = task.due and string.format("  [due %s]", task.due) or ""
    local context = (not nested) and task.context
        and ("  ← " .. truncate(display_text(task.context), CONTEXT_WIDTH)) or ""
    return lead .. prefix .. display_text(task.text) .. progress .. due .. context
end

-- "rel:lineno: (A) text  [due ...]" -- the same shape show_backlinks uses, so
-- fzf-lua's entry_to_file parses it with `cwd = home`.
local function to_entry(task)
    return string.format("%s:%d: %s", task.rel, task.lineno, M.entry_text(task))
end

--- Flip a single checkbox in a note on disk, keeping any loaded buffer in step.
--- Refuses to touch a file whose buffer has unsaved changes.
--- @param path string absolute path to the note
--- @param lineno number 1-indexed line holding the checkbox
--- @return boolean true when the line was toggled
function M.toggle_at(path, lineno)
    if type(lineno) ~= "number" or lineno < 1 or vim.fn.filereadable(path) == 0 then
        return false
    end

    local bufnr = vim.fn.bufnr(path)
    if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].modified then
        vim.notify("[Fzfkasten] Buffer has unsaved changes: " .. path, vim.log.levels.WARN)
        return false
    end

    local ok, lines = pcall(vim.fn.readfile, path)
    if not ok then
        return false
    end
    local line = lines[lineno]
    if not line then
        return false
    end

    local toggled, why = toggle_line(line)
    if not toggled then
        vim.notify(
            why == "cancelled"
                and "[Fzfkasten] That task is cancelled. Reopen it first."
                or "[Fzfkasten] No checkbox on that line.",
            vim.log.levels.WARN
        )
        return false
    end

    lines[lineno] = toggled
    vim.fn.writefile(lines, path)
    remember(path, lineno, line, toggled)
    if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
        -- Cosmetic, and this may run from fzf's terminal context, so defer it.
        -- Correctness doesn't depend on it: everything re-reads from disk.
        vim.schedule(function()
            pcall(vim.cmd, "checktime " .. bufnr)
        end)
    end
    return true
end

--- Append `require_tag` to a checkbox, promoting an inbox entry to a task.
--- Without it the inbox would be a dead end: you could see what escaped, but
--- only fix it by hand.
--- @param path string absolute path to the note
--- @param lineno number 1-indexed line holding the checkbox
--- @return boolean true when the tag was added
function M.tag_at(path, lineno)
    local tag = config.options.tasks.require_tag
    if not tag then
        vim.notify("[Fzfkasten] tasks.require_tag is not set.", vim.log.levels.WARN)
        return false
    end
    if type(lineno) ~= "number" or lineno < 1 or vim.fn.filereadable(path) == 0 then
        return false
    end

    local bufnr = vim.fn.bufnr(path)
    if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].modified then
        vim.notify("[Fzfkasten] Buffer has unsaved changes: " .. path, vim.log.levels.WARN)
        return false
    end

    local ok, lines = pcall(vim.fn.readfile, path)
    if not ok or not lines[lineno] then
        return false
    end
    local line = lines[lineno]
    if not line:match(config.options.tasks.patterns.open)
        and not line:match(config.options.tasks.patterns.done) then
        vim.notify("[Fzfkasten] No task on that line.", vim.log.levels.WARN)
        return false
    end
    if has_tag(line, tag) then
        return false -- already a task; nothing to do
    end

    lines[lineno] = line:gsub("%s*$", "") .. " #" .. tag
    vim.fn.writefile(lines, path)
    remember(path, lineno, line, lines[lineno])
    if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
        vim.schedule(function()
            pcall(vim.cmd, "checktime " .. bufnr)
        end)
    end
    return true
end

-- The current-line editors below write to the buffer you are in. On a
-- non-modifiable buffer -- the dashboard, a terminal, a help page -- that throws
-- from deep inside nvim_buf_set_lines, so refuse with a word instead. The
-- picker's `_at` writers don't go through here: they write a file by path,
-- never the current buffer.
local function buffer_writable()
    if vim.bo.modifiable and not vim.bo.readonly and vim.bo.buftype == "" then
        return true
    end
    vim.notify("[Fzfkasten] Not an editable note buffer.", vim.log.levels.WARN)
    return false
end

--- Toggle the checkbox on the current line of the current buffer.
function M.toggle()
    if not buffer_writable() then return end
    local lineno = vim.api.nvim_win_get_cursor(0)[1]
    local toggled, why = toggle_line(vim.api.nvim_get_current_line())
    if not toggled then
        vim.notify(
            why == "cancelled"
                and "[Fzfkasten] This task is cancelled. Reopen it first."
                or "[Fzfkasten] No checkbox on this line.",
            vim.log.levels.WARN
        )
        return
    end
    vim.api.nvim_buf_set_lines(0, lineno - 1, lineno, false, { toggled })
end

-- Why `cancel_line` refused, in words. Shared so the buffer and the file paths
-- say the same thing.
local function cancel_refusal(why, here)
    if why == "done" then
        return "[Fzfkasten] That task is done, not dropped. Reopen it first "
            .. "if you meant to cancel it."
    end
    return "[Fzfkasten] No checkbox on " .. (here and "this" or "that") .. " line."
end

-- Why `due_line` refused, in words.
local function due_refusal(why)
    if why == "not open" then
        return "[Fzfkasten] That task isn't open; a due date is for something "
            .. "still to do."
    elseif why == "bad date" then
        return "[Fzfkasten] Expected a date like 2026-07-25 or 2026-07-25T15:00, "
            .. "or a relative one like tomorrow, +3d or fri."
    end
    return "[Fzfkasten] No checkbox on this line."
end

--- Set, replace or clear the due date on the task on the current line. With no
--- argument the due date is cleared; otherwise it may be an absolute ISO date
--- (`2026-07-25`), a date and time (`2026-07-25T15:00`), or a relative form
--- (`tomorrow`, `+3d`, `2w`, `fri`, `金`) resolved to a concrete day.
---
--- Edits the buffer, not the file: this runs while you are writing the note,
--- so it is Vim's `u` that undoes it, like `M.tag`.
--- @param date string|nil the new due date, or nil/"" to clear
function M.set_due(date)
    if not buffer_writable() then return end
    local lineno = vim.api.nvim_win_get_cursor(0)[1]
    local cur = vim.api.nvim_get_current_line()
    -- Resolve a relative spec to ISO before the line surgery, which only knows
    -- absolute dates. An empty spec stays empty so due_line clears the due.
    local spec = date and vim.trim(date) or ""
    local resolved = date
    if spec ~= "" then
        resolved = resolve_due(spec)
        if not resolved then
            vim.notify(due_refusal("bad date"), vim.log.levels.WARN)
            return
        end
    end
    local out, why = due_line(cur, resolved)
    if not out then
        vim.notify(due_refusal(why), vim.log.levels.WARN)
        return
    end
    if out == cur then
        vim.notify(
            (date == nil or vim.trim(date) == "")
                and "[Fzfkasten] No due date to clear."
                or "[Fzfkasten] Due date unchanged.",
            vim.log.levels.INFO
        )
        return
    end
    vim.api.nvim_buf_set_lines(0, lineno - 1, lineno, false, { out })
end

--- Cancel the task on the current line, or reopen it if already cancelled.
function M.cancel()
    if not buffer_writable() then return end
    local lineno = vim.api.nvim_win_get_cursor(0)[1]
    local cancelled, why = cancel_line(vim.api.nvim_get_current_line())
    if not cancelled then
        vim.notify(cancel_refusal(why, true), vim.log.levels.WARN)
        return
    end
    vim.api.nvim_buf_set_lines(0, lineno - 1, lineno, false, { cancelled })
end

--- Cancel a single task in a note on disk, or reopen it if already cancelled.
--- Refuses to touch a file whose buffer has unsaved changes.
--- @param path string absolute path to the note
--- @param lineno number 1-indexed line holding the checkbox
--- @return boolean true when the line was rewritten
function M.cancel_at(path, lineno)
    if type(lineno) ~= "number" or lineno < 1 or vim.fn.filereadable(path) == 0 then
        return false
    end

    local bufnr = vim.fn.bufnr(path)
    if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].modified then
        vim.notify("[Fzfkasten] Buffer has unsaved changes: " .. path, vim.log.levels.WARN)
        return false
    end

    local ok, lines = pcall(vim.fn.readfile, path)
    if not ok or not lines[lineno] then
        return false
    end

    local line = lines[lineno]
    local cancelled, why = cancel_line(line)
    if not cancelled then
        vim.notify(cancel_refusal(why, false), vim.log.levels.WARN)
        return false
    end

    lines[lineno] = cancelled
    vim.fn.writefile(lines, path)
    remember(path, lineno, line, cancelled)
    if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
        vim.schedule(function()
            pcall(vim.cmd, "checktime " .. bufnr)
        end)
    end
    return true
end

--- Tag the current line -- or every line in a range -- as a task, promoting
--- prose and bare bullets to checkboxes on the way.
---
--- Edits the buffer rather than the file, unlike `M.tag_at`: this runs while
--- you are writing the note, so refusing on an unsaved buffer would refuse
--- almost every time it is wanted. The range is what makes an old note full
--- of untagged checkboxes tractable -- select them and tag the lot.
--- @param opts table|nil `{ line1 = number, line2 = number }`, 1-indexed and
---   inclusive; defaults to the cursor line.
function M.tag(opts)
    if not buffer_writable() then return end
    local tag = config.options.tasks.require_tag
    if not tag then
        vim.notify("[Fzfkasten] tasks.require_tag is not set.", vim.log.levels.WARN)
        return
    end
    opts = opts or {}
    local line1 = opts.line1 or vim.api.nvim_win_get_cursor(0)[1]
    local line2 = opts.line2 or line1
    if line2 < line1 then
        line1, line2 = line2, line1
    end

    -- The whole buffer, because whether a line can hold a task depends on what
    -- is above it: the frontmatter, an open fence, the last heading.
    local all = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    line2 = math.min(line2, #all)
    local _, fm_end = parse_frontmatter(all)
    local scannable = scannable_lines(all, fm_end)

    local lines = {}
    local tagged = 0
    for lineno = line1, line2 do
        local line = all[lineno]
        local out = scannable[lineno] and tag_line(line, tag)
        if out then
            line = out
            tagged = tagged + 1
        end
        table.insert(lines, line)
    end
    if tagged == 0 then
        vim.notify(
            line1 == line2
                and "[Fzfkasten] Nothing to tag on this line."
                or "[Fzfkasten] Nothing to tag in that range.",
            vim.log.levels.WARN
        )
        return
    end
    vim.api.nvim_buf_set_lines(0, line1 - 1, line2, false, lines)
end

--- Put back the last task line the picker changed on disk -- the last
--- `<ctrl-x>`, `<ctrl-d>`, `<ctrl-t>` or `<alt-a>`. Repeat to walk back through
--- them. A rewrite is restored to its old text; a capture (`<alt-a>`, which
--- added a line rather than rewriting one) is undone by deleting that line.
---
--- This is not Vim's undo and does not touch it: those keys write the note
--- itself, often without it being open, which is exactly where `u` cannot
--- reach. Edits you make in a buffer are `u`'s to undo, and are not recorded
--- here.
--- @return boolean true when a line was put back
function M.undo()
    local last = history[#history]
    if not last then
        vim.notify("[Fzfkasten] Nothing to undo.", vim.log.levels.INFO)
        return false
    end

    local bufnr = vim.fn.bufnr(last.path)
    if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].modified then
        vim.notify("[Fzfkasten] Buffer has unsaved changes: " .. last.path,
            vim.log.levels.WARN)
        return false
    end

    local ok, lines = pcall(vim.fn.readfile, last.path)
    -- Whatever we were going to undo is not there any more, so drop the entry:
    -- keeping it would only fail the same way on the next undo.
    if not ok or not lines[last.lineno] then
        table.remove(history)
        vim.notify("[Fzfkasten] That note has changed since; nothing put back.",
            vim.log.levels.WARN)
        return false
    end
    -- Someone has edited the line since -- possibly the task moved, possibly
    -- it was rewritten by hand. Their text is worth more than our undo.
    if lines[last.lineno] ~= last.after then
        table.remove(history)
        vim.notify("[Fzfkasten] That line has changed since; left as it is.",
            vim.log.levels.WARN)
        return false
    end

    -- A capture added the line, so undoing it means removing the line; a
    -- rewrite is put back to its old text.
    if last.added then
        table.remove(lines, last.lineno)
    else
        lines[last.lineno] = last.before
    end
    vim.fn.writefile(lines, last.path)
    table.remove(history)
    if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
        vim.schedule(function()
            pcall(vim.cmd, "checktime " .. bufnr)
        end)
    end
    return true
end

-- Where a captured task is written: `capture_note`, or the first `always`
-- entry, as an absolute path -- or nil plus a reason when neither is set.
--
-- Reusing `always[1]` is deliberate: that note is already scanned regardless
-- of `since_days`, so a task captured into it always surfaces. Adding a second
-- setting for the same file would only invite the two to disagree.
local function capture_target()
    local o = config.options.tasks
    local rel = o.capture_note or (o.always or {})[1]
    if not rel then
        return nil, "unset"
    end
    return utils.join_path(config.options.home, rel), rel
end

--- Append a new open task to the capture note (`tasks.capture_note`, or the
--- first `tasks.always` entry). This is the write side of a fixed task list:
--- record a todo from anywhere, no note to open and no decision about where it
--- goes. `require_tag`, if set, is added, so the capture lands in the task list
--- straight away rather than the inbox.
---
--- Recorded for `M.undo` as an addition, so `<alt-u>` right after a capture
--- deletes the line again -- the same key that walks back the picker's other
--- edits, doing here what it can't for a rewrite: removing the line outright.
--- @param text string the task text; the checkbox and tag are added here
--- @param due string|nil an ISO due date to append (already resolved)
--- @return boolean true when the task was written
function M.add(text, due)
    local o = config.options.tasks
    local line = new_task_line(text, o.require_tag, due)
    if not line then
        vim.notify("[Fzfkasten] Nothing to capture.", vim.log.levels.WARN)
        return false
    end

    local path, rel = capture_target()
    if not path then
        vim.notify(
            "[Fzfkasten] No capture note set. Point tasks.capture_note (or the "
            .. "first tasks.always entry) at a note to capture into.",
            vim.log.levels.WARN
        )
        return false
    end

    local bufnr = vim.fn.bufnr(path)
    if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].modified then
        vim.notify("[Fzfkasten] Buffer has unsaved changes: " .. path, vim.log.levels.WARN)
        return false
    end

    local lines = {}
    if vim.fn.filereadable(path) == 1 then
        local ok, read = pcall(vim.fn.readfile, path)
        if not ok then
            vim.notify("[Fzfkasten] Couldn't read capture note: " .. path, vim.log.levels.WARN)
            return false
        end
        lines = read
    else
        -- First capture creates the note. Make its directory the way open_note
        -- does, so a fresh `tasks/active.md` just works with nothing set up.
        local dir = vim.fn.fnamemodify(path, ":h")
        if vim.fn.isdirectory(dir) == 0 then
            vim.fn.mkdir(dir, "p")
        end
    end

    table.insert(lines, line)
    vim.fn.writefile(lines, path)
    remember(path, #lines, nil, line, true)
    if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
        vim.schedule(function()
            pcall(vim.cmd, "checktime " .. bufnr)
        end)
    end
    vim.notify("[Fzfkasten] Captured to " .. rel, vim.log.levels.INFO)
    return true
end

-- Every `#tag` already used across the notes, sorted, with `require_tag` (the
-- one you almost always want) floated to the front. Gathered fresh with rg so
-- a tag coined an hour ago is offered now; falls back to reading notes when rg
-- is absent, like the task scan does.
local function collect_tags()
    local set = {}
    local extension = config.options.extension
    if vim.fn.executable("rg") == 1 then
        local out = vim.fn.systemlist({
            "rg", "--no-filename", "--no-messages", "--no-line-number",
            "-o", "--glob", "*." .. extension,
            "-e", "#[A-Za-z0-9_-]+",
            config.options.home,
        })
        if vim.v.shell_error <= 1 then
            for _, tag in ipairs(out or {}) do
                set[tag] = true
            end
        end
    else
        for _, path in ipairs(all_notes()) do
            local ok, lines = pcall(vim.fn.readfile, path)
            if ok and lines then
                for _, line in ipairs(lines) do
                    for name in line:gmatch("#[%w_-]+") do
                        set[name] = true
                    end
                end
            end
        end
    end

    local rt = config.options.tasks.require_tag
    local front = rt and ("#" .. rt) or nil
    if front then
        set[front] = nil
    end
    local tags = {}
    for tag in pairs(set) do
        table.insert(tags, tag)
    end
    table.sort(tags)
    if front then
        table.insert(tags, 1, front)
    end
    return tags
end

-- Append the `#tag` entries the user picked to `text`, skipping any it already
-- carries. Picker entries come with the `#` on; a `require_tag` pick is
-- harmless since `M.add` adds that one anyway.
local function with_tags(text, picked)
    for _, tag in ipairs(picked or {}) do
        local name = tag:gsub("^#", "")
        if name ~= "" and not has_tag(text, name) then
            text = text .. " #" .. name
        end
    end
    return text
end

-- fzf-lua runs an action's `fn` *before* it closes its window (core.lua calls
-- `fn_selected` then `fzf_win:close`), so a UI opened straight out of an action
-- races the teardown: the new window can be left as an on-screen artifact, and
-- plugins that hook InsertEnter (skkeleton and other IMEs) may fail to attach
-- to it. Opening it on a short timer, past the teardown, avoids both.
local function after_fzf(fn)
    vim.defer_fn(fn, 50)
end

--- Guided capture: ask for the task text, let you pick tags from the ones your
--- notes already use, then a due date (relative forms accepted), and write the
--- result with `M.add`. This is the assisted counterpart to typing a task by
--- hand: the tag list saves you misremembering a tag, and the due step takes
--- `tomorrow`/`+3d`/`fri` so you needn't work out the date.
---
--- Each step is skippable -- no tags, no due -- and an empty task cancels the
--- capture. The two fzf->input hops go through `after_fzf`, so the input opens
--- cleanly after the picker has torn down (see its note); `on_done` runs at the
--- end, and the task picker passes a reopen there so the new task lands in view.
--- @param seed string|nil prefills the task input (the picker seeds its query)
--- @param on_done function|nil called once the capture finishes or is abandoned
function M.capture(seed, on_done)
    on_done = on_done or function() end
    vim.ui.input({ prompt = "New task: ", default = seed or "" }, function(text)
        if not text or vim.trim(text) == "" then
            return -- cancelled: leave the list closed rather than reopen on nothing
        end

        local function finish(picked)
            local body = with_tags(vim.trim(text), picked)
            vim.ui.input({
                prompt = "Due (blank = none, e.g. tomorrow / +3d / fri / 2026-07-25): ",
            }, function(spec)
                local due
                if spec and vim.trim(spec) ~= "" then
                    due = resolve_due(spec)
                    if not due then
                        vim.notify(
                            "[Fzfkasten] Didn't recognise '" .. vim.trim(spec)
                            .. "'; captured without a due date.",
                            vim.log.levels.WARN
                        )
                    end
                end
                M.add(body, due)
                on_done()
            end)
        end

        local tags = collect_tags()
        if #tags == 0 then
            finish({})
            return
        end
        fzf.fzf_exec(tags, vim.tbl_deep_extend("force", config.options.fzf, {
            prompt = "Tags> ",
            fzf_opts = {
                -- `require_tag` sits first and `M.add` adds it anyway, so a bare
                -- <enter> (which takes the highlighted row) just reaffirms it.
                ["--multi"] = "",
                ["--header"] = "<tab> mark extra tags   <enter> confirm   <esc> cancel",
            },
            actions = {
                -- `selected` is the list of ticked tags, or empty on a bare
                -- <enter>. The due step is an input, so it waits for this
                -- picker to close (see `after_fzf`) before opening.
                ['default'] = function(selected)
                    local picked = selected or {}
                    after_fzf(function() finish(picked) end)
                end,
            },
        }))
    end)
end

--- Pick the checkboxes `require_tag` leaves out, for triage. Same picker as
--- `M.pick`; jump to one and tag it to promote it to a task.
--- @param opts table|nil forwarded to `M.collect`
function M.inbox(opts)
    if not config.options.tasks.require_tag then
        vim.notify(
            "[Fzfkasten] The inbox needs tasks.require_tag set; without it "
            .. "every checkbox is already a task.",
            vim.log.levels.WARN
        )
        return
    end
    M.pick(vim.tbl_extend("force", opts or {}, { inbox = true }))
end

--- Pick an open task and jump to it in its source note.
--- `<ctrl-x>` marks the task done in its note and refreshes the list in place.
--- @param opts table|nil forwarded to `M.collect`
function M.pick(opts)
    opts = opts or {}
    if #M.collect(opts) == 0 then
        vim.notify(opts.inbox and "Inbox is empty." or "No open tasks found.",
            vim.log.levels.INFO)
        return
    end

    -- Contents as a function rather than a table so fzf's `reload` can
    -- regenerate them: that keeps the cursor where it is, and the next task
    -- moves up into place. Rebuilding the picker would send it back to the top.
    --
    -- `opts.filter`, when set by `<alt-/>`, is a `\m` Vim regex the romaji backend built
    -- from a romaji query; keep only the tasks whose text it matches so you can
    -- narrow a Japanese list without typing Japanese.
    local function contents(cb)
        for _, task in ipairs(M.collect(opts)) do
            if romaji.matches(task.text, opts.filter) then
                cb(to_entry(task))
            end
        end
        cb()
    end

    local function open(selected)
        if not selected or #selected == 0 then return end
        local entry = fzf.path.entry_to_file(selected[1], { cwd = config.options.home })
        if not entry.path then return end
        buffer.edit(entry.path)
        if entry.line then
            -- Jump to the head of the task line. Entries carry no meaningful
            -- column, and a `:` in the task text (a time like 15:00, a URL)
            -- makes `entry_to_file` read a bogus, out-of-range column that
            -- `nvim_win_set_cursor` rejects -- so ignore `entry.col` entirely.
            local last = vim.api.nvim_buf_line_count(0)
            local line = math.min(entry.line, last)
            vim.api.nvim_win_set_cursor(0, { line, 0 })
        end
    end

    -- The ordering goes in the prompt, not the header: it is state, and it has
    -- to be readable at a glance to tell "nothing urgent" from "sorted by
    -- something else". The default ordering is left unsaid -- a prompt that
    -- always carries a tag is one you stop reading.
    local label = opts.inbox and "Inbox" or "Tasks"
    if (opts.sort and opts.sort ~= SORTS[1]) or opts.reverse then
        label = label .. " (" .. (opts.sort or SORTS[1])
            .. (opts.reverse and ", reversed" or "") .. ")"
    end
    local header = romaji.header_hint(config.options.tasks.require_tag and opts.inbox
        and "<ctrl-t> tag as task   <ctrl-x> mark done   <ctrl-d> cancel   <alt-a> add   <alt-u> undo   <alt-s> sort   <alt-r> reverse"
        or "<ctrl-x> mark done   <ctrl-d> cancel   <alt-a> add   <alt-u> undo   <alt-s> sort   <alt-r> reverse")

    -- Reopen with `changed` merged in, carrying the fzf query over so changing
    -- the order doesn't throw away what you had typed to narrow the list.
    local function reopen(changed, query)
        local next_opts = vim.tbl_extend("force", opts, changed)
        next_opts.query = query
        after_fzf(function() M.pick(next_opts) end)
    end

    fzf.fzf_exec(contents, vim.tbl_deep_extend("force", config.options.fzf, {
        prompt = romaji.prompt(label, opts.filter),
        -- Entries carry paths relative to `home`; without this the previewer
        -- resolves them against Neovim's cwd and fails to stat the note.
        cwd = config.options.home,
        previewer = "builtin",
        fzf_opts = {
            ["--delimiter"] = ":",
            ["--with-nth"] = "3..",
            ["--no-sort"] = "",
            ["--header"] = header,
            -- Restored when the picker reopens itself (a sort change); nil on a
            -- fresh open, which fzf reads as no query.
            ["--query"] = opts.query,
        },
        actions = {
            ['default'] = open,
            -- Promote an inbox entry: tag it, and it moves to the task list.
            ['ctrl-t'] = {
                fn = function(selected)
                    if not selected or #selected == 0 then return end
                    local entry = fzf.path.entry_to_file(selected[1], { cwd = config.options.home })
                    if entry.path and (entry.line or 0) > 0 then
                        M.tag_at(entry.path, entry.line)
                    end
                end,
                reload = true,
            },
            -- `reload` re-runs `contents` in place: fzf keeps the cursor index,
            -- so the task below the one just completed moves up under it and
            -- you can work down the list without losing your place.
            ['ctrl-x'] = {
                fn = function(selected)
                    if not selected or #selected == 0 then return end
                    local entry = fzf.path.entry_to_file(selected[1], { cwd = config.options.home })
                    -- `entry.line` is 0 when the entry carried no line number,
                    -- and 0 is truthy in Lua.
                    if entry.path and (entry.line or 0) > 0 then
                        M.toggle_at(entry.path, entry.line)
                    end
                end,
                reload = true,
            },
            -- Reach for this the moment a keypress lands on the wrong row:
            -- the task is gone from the list and `u` cannot help, because
            -- the note was written, not the buffer.
            ['alt-u'] = {
                fn = function() M.undo() end,
                reload = true,
            },
            -- Drop a task without deleting the line: it leaves the list the
            -- same way a completed one does, and the note still says you
            -- once meant to do it.
            ['ctrl-d'] = {
                fn = function(selected)
                    if not selected or #selected == 0 then return end
                    local entry = fzf.path.entry_to_file(selected[1], { cwd = config.options.home })
                    if entry.path and (entry.line or 0) > 0 then
                        M.cancel_at(entry.path, entry.line)
                    end
                end,
                reload = true,
            },
            -- Capture a new task with the guided input: text, then tags picked
            -- from those your notes already use, then a due date that takes
            -- `tomorrow`/`+3d`/`fri`. `field_index = "{q}"` hands the fzf query
            -- over as the seed, so whatever you had typed prefills the task.
            --
            -- Not `<ctrl-a>`: that is fzf's own "jump to line start" and worth
            -- keeping. This closes the picker (no `reload`), and `M.capture`
            -- reopens it via `on_done` once the task is written, so the new
            -- task lands back in the list -- the query and cursor reset, which
            -- is the cost of stepping out to a real input with completion.
            ['alt-a'] = {
                fn = function(selected)
                    local seed = (selected and selected[1]) or ""
                    -- Wait for this picker to close before opening the input,
                    -- or it races the teardown -- see `after_fzf`.
                    after_fzf(function()
                        -- Reopen without the query: the new task has to be
                        -- visible for the reopen to be worth anything, and
                        -- whatever narrowed the list before probably hides it.
                        local next_opts = vim.tbl_extend("force", opts, {})
                        next_opts.query = nil
                        M.capture(seed, function() M.pick(next_opts) end)
                    end)
                end,
                field_index = "{q}",
            },
            -- Cycle the ordering: priority -> due -> added -> priority. Not a
            -- `reload`, which would re-run `contents` but leave the prompt
            -- claiming the old order; reopening is what keeps the two agreeing.
            -- `field_index = "{q}"` hands the query over so it survives the trip.
            ['alt-s'] = {
                fn = function(selected)
                    reopen({ sort = M.next_sort(opts.sort) }, selected and selected[1])
                end,
                field_index = "{q}",
            },
            -- Flip the order. Independent of which ordering is in force, so
            -- "least urgent first" and "oldest first" are each one more key.
            ['alt-r'] = {
                fn = function(selected)
                    reopen({ reverse = not opts.reverse }, selected and selected[1])
                end,
                field_index = "{q}",
            },
            -- Narrow the list by romaji: the backend turns what you type into a Vim
            -- regex over the task text (matched in `contents`), so `kaigi` finds
            -- 会議. Reopens the picker with the new filter in `opts.filter`.
            ['alt-/'] = romaji.action(function(re)
                local next_opts = vim.tbl_extend("force", opts, {})
                next_opts.filter = re
                -- The romaji query is what narrows now; keeping the fzf query
                -- that seeded it would filter the results a second time, by
                -- romaji they don't contain, and show nothing.
                next_opts.query = nil
                M.pick(next_opts)
            end, opts.filter),
        },
    }))
end

-- Pure helpers exposed for the test suite (tests/tasks_spec.lua). These do the
-- fragile string surgery -- rewriting a mark, wrapping a strike inside a
-- priority, stripping a stamp -- that has regressed before, so they are pinned
-- down by tests. Underscore-prefixed and not part of the public API.
M._test = {
    unstrike = unstrike,
    parse_task_text = parse_task_text,
    split_checkbox = split_checkbox,
    toggle_line = toggle_line,
    cancel_line = cancel_line,
    tag_line = tag_line,
    new_task_line = new_task_line,
    valid_due = valid_due,
    resolve_due = resolve_due,
    due_line = due_line,
    has_tag = has_tag,
    scannable_lines = scannable_lines,
    parse_frontmatter = parse_frontmatter,
    sort_tasks = sort_tasks,
    note_date = note_date,
    -- The undo stack is module state, so a suite that exercises the writers has
    -- to be able to start each case from empty -- otherwise one case's rewrite
    -- is what the next case's undo puts back.
    reset_history = function() history = {} end,
    history_size = function() return #history end,
    HISTORY_MAX = HISTORY_MAX,
    indent_width = indent_width,
    bullet_text = bullet_text,
    next_sort = M.next_sort,
    sort_fields = sort_fields,
    SORTS = SORTS,
    display_text = display_text,
    truncate = truncate,
    to_entry = to_entry,
}

return M
