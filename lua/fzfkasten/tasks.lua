-- Task collection and picking.
--
-- Tasks are plain markdown checkboxes (`- [ ]` / `- [x]`) written directly in
-- your notes. There is no index, no database and no separate task file: every
-- call re-scans with ripgrep. Anything else that can edit markdown -- a mobile
-- git client, another editor, a script -- therefore stays in sync for free,
-- because the notes *are* the ledger.

local fzf = require('fzf-lua')
local config = require('fzfkasten.config')
local utils = require('fzfkasten.utils')
local buffer = require('fzfkasten.buffer')

local M = {}

local DAY = 86400

-- A broken `tasks.date`/`tasks.filter` hook would otherwise warn once per
-- note (or per task) scanned.
local date_hook_warned = false
local filter_hook_warned = false

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

-- Pull `(A)`, `due:YYYY-MM-DD` and the completion stamp out of the task text.
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
    return vim.trim(text), priority, due, done_at
end

-- Flip a checkbox line, or nil when the line holds no checkbox. Driven by
-- `patterns.toggle` (captures before/mark/after) and `marks`, so a user who
-- redefines the checkbox syntax keeps toggling.
local function toggle_line(line)
    local o = config.options.tasks
    local now_done
    local toggled, n = line:gsub(o.patterns.toggle, function(before, mark, after)
        now_done = mark == o.marks.open
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

local function sort_tasks(tasks)
    table.sort(tasks, function(a, b)
        -- Prioritised first, then most urgent, then stable by location.
        local ap, bp = a.priority or "~", b.priority or "~"
        if ap ~= bp then
            return ap < bp
        end
        local ad, bd = a.due or "9999-99-99", b.due or "9999-99-99"
        if ad ~= bd then
            return ad < bd
        end
        if a.path ~= b.path then
            return a.path < b.path
        end
        return a.lineno < b.lineno
    end)
    return tasks
end

--- Collect tasks from every note under `home`.
--- @param opts table|nil `{ since_days = number|false, done = boolean,
---   inbox = boolean }`. `since_days = false` disables the date window for this
---   call; `inbox = true` returns the checkboxes `require_tag` leaves out.
--- @return table list of
---   `{ text, done, done_at, priority, due, path, rel, lineno, date }`
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
    local cutoff = since and since ~= false and os.date("%Y-%m-%d", os.time() - since * DAY) or nil

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
                local too_old = cutoff and date and date < cutoff and not is_always(rel)

                if not opted_out and not too_old then
                    local in_scope = (o.scope ~= "headings")
                    local fence = nil
                    for lineno = fm_end + 1, #lines do
                        local line = lines[lineno]
                        local delim = fence_delimiter(line)
                        if fence then
                            -- Only a delimiter of the same kind, at least as
                            -- long as the opening one, closes the block.
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
                                local raw = line:match(o.patterns.open)
                                local done = false
                                if not raw then
                                    raw = line:match(o.patterns.done)
                                    done = raw ~= nil
                                end
                                if raw then
                                    local text, priority, due, done_at = parse_task_text(raw, o)
                                    local task = {
                                        text = text,
                                        done = done,
                                        done_at = done_at,
                                        priority = priority,
                                        due = due,
                                        path = path,
                                        rel = rel,
                                        lineno = lineno,
                                        date = date,
                                    }
                                    -- With `require_tag` set, a checkbox is a
                                    -- task only if tagged; the rest are inbox.
                                    local tagged = not o.require_tag or has_tag(text, o.require_tag)
                                    if tagged == wants_tagged and keep(task) then
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
    sort_tasks(tasks)

    if type(o.on_collect) == "function" then
        pcall(o.on_collect, tasks)
    end
    return tasks
end

-- "rel:lineno: (A) text  [due ...]" -- the same shape show_backlinks uses, so
-- fzf-lua's entry_to_file parses it with `cwd = home`.
local function to_entry(task)
    local o = config.options.tasks
    local prefix = task.priority and string.format("(%s) ", task.priority) or ""
    local text = task.text:gsub(o.patterns.due, "")
    -- Every task carries `require_tag`, so showing it wastes width.
    if o.require_tag then
        text = text:gsub("#" .. vim.pesc(o.require_tag) .. "%f[%W]", "")
    end
    text = " " .. text .. " "
    text = text:gsub("%s+", " ")
    local due = task.due and string.format("  [due %s]", task.due) or ""
    return string.format("%s:%d: %s%s%s", task.rel, task.lineno, prefix, vim.trim(text), due)
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

    local toggled = toggle_line(line)
    if not toggled then
        vim.notify("[Fzfkasten] No checkbox on that line.", vim.log.levels.WARN)
        return false
    end

    lines[lineno] = toggled
    vim.fn.writefile(lines, path)
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
    if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
        vim.schedule(function()
            pcall(vim.cmd, "checktime " .. bufnr)
        end)
    end
    return true
end

--- Toggle the checkbox on the current line of the current buffer.
function M.toggle()
    local lineno = vim.api.nvim_win_get_cursor(0)[1]
    local toggled = toggle_line(vim.api.nvim_get_current_line())
    if not toggled then
        vim.notify("[Fzfkasten] No checkbox on this line.", vim.log.levels.WARN)
        return
    end
    vim.api.nvim_buf_set_lines(0, lineno - 1, lineno, false, { toggled })
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
    local function contents(cb)
        for _, task in ipairs(M.collect(opts)) do
            cb(to_entry(task))
        end
        cb()
    end

    local function open(selected)
        if not selected or #selected == 0 then return end
        local entry = fzf.path.entry_to_file(selected[1], { cwd = config.options.home })
        if not entry.path then return end
        buffer.edit(entry.path)
        if entry.line then
            vim.api.nvim_win_set_cursor(0, { entry.line, (entry.col or 1) - 1 })
        end
    end

    fzf.fzf_exec(contents, vim.tbl_deep_extend("force", config.options.fzf, {
        prompt = opts.inbox and "Inbox> " or "Tasks> ",
        -- Entries carry paths relative to `home`; without this the previewer
        -- resolves them against Neovim's cwd and fails to stat the note.
        cwd = config.options.home,
        previewer = "builtin",
        fzf_opts = {
            ["--delimiter"] = ":",
            ["--with-nth"] = "3..",
            ["--no-sort"] = "",
            ["--header"] = config.options.tasks.require_tag
                and (opts.inbox
                    and ("<ctrl-t> tag as task   <ctrl-x> mark done")
                    or "<ctrl-x> mark done")
                or "<ctrl-x> mark done",
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
        },
    }))
end

return M
