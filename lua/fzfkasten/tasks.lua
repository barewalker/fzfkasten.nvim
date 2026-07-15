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

-- A broken `tasks.date` hook would otherwise warn once per note scanned.
local date_hook_warned = false

-- Files worth reading at all: only those containing a checkbox. Everything
-- else (frontmatter opt-out, heading scope, note date) needs line context, so
-- it is decided in Lua on this much smaller set.
local function files_with_checkboxes()
    if vim.fn.executable("rg") == 0 then
        vim.notify("[Fzfkasten] 'rg' (ripgrep) is required for tasks.", vim.log.levels.ERROR)
        return {}
    end
    local out = vim.fn.systemlist({
        "rg", "--files-with-matches", "--no-messages",
        "--glob", "*." .. config.options.extension,
        "-e", [[^\s*[-*]\s+\[[ xX]\]\s+]],
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

-- Pull `(A)` and `due:YYYY-MM-DD` out of the task text.
local function parse_task_text(text, pats)
    local priority = text:match(pats.priority)
    if priority then
        text = text:gsub(pats.priority, "", 1)
    end
    local due = text:match(pats.due)
    return vim.trim(text), priority, due
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
--- @param opts table|nil `{ since_days = number|false, done = boolean }`.
---   `since_days = false` disables the date window for this call.
--- @return table list of `{ text, done, priority, due, path, rel, lineno, date }`
function M.collect(opts)
    opts = opts or {}
    local o = config.options.tasks
    local home = config.options.home

    local since = opts.since_days
    if since == nil then
        since = o.since_days
    end
    local cutoff = since and since ~= false and os.date("%Y-%m-%d", os.time() - since * DAY) or nil

    date_hook_warned = false
    local tasks = {}
    for _, path in ipairs(files_with_checkboxes()) do
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
                                    local text, priority, due = parse_task_text(raw, o.patterns)
                                    table.insert(tasks, {
                                        text = text,
                                        done = done,
                                        priority = priority,
                                        due = due,
                                        path = path,
                                        rel = rel,
                                        lineno = lineno,
                                        date = date,
                                    })
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
    local prefix = task.priority and string.format("(%s) ", task.priority) or ""
    local text = task.text:gsub(config.options.tasks.patterns.due, "")
    local due = task.due and string.format("  [due %s]", task.due) or ""
    return string.format("%s:%d: %s%s%s", task.rel, task.lineno, prefix, vim.trim(text), due)
end

--- Flip a single checkbox in a note on disk, keeping any loaded buffer in step.
--- Refuses to touch a file whose buffer has unsaved changes.
--- @param path string absolute path to the note
--- @param lineno number 1-indexed line holding the checkbox
--- @return boolean true when the line was toggled
function M.toggle_at(path, lineno)
    local bufnr = vim.fn.bufnr(path)
    if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].modified then
        vim.notify("[Fzfkasten] Buffer has unsaved changes: " .. path, vim.log.levels.WARN)
        return false
    end

    local lines = vim.fn.readfile(path)
    local line = lines[lineno]
    if not line then
        return false
    end

    local toggled = line:gsub("^(%s*[-*]%s+%[)([ xX])(%])", function(head, mark, tail)
        return head .. (mark == " " and "x" or " ") .. tail
    end, 1)
    if toggled == line then
        vim.notify("[Fzfkasten] No checkbox on that line.", vim.log.levels.WARN)
        return false
    end

    lines[lineno] = toggled
    vim.fn.writefile(lines, path)
    if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
        vim.cmd("checktime " .. bufnr)
    end
    return true
end

--- Toggle the checkbox on the current line of the current buffer.
function M.toggle()
    local lineno = vim.api.nvim_win_get_cursor(0)[1]
    local line = vim.api.nvim_get_current_line()
    local toggled = line:gsub("^(%s*[-*]%s+%[)([ xX])(%])", function(head, mark, tail)
        return head .. (mark == " " and "x" or " ") .. tail
    end, 1)
    if toggled == line then
        vim.notify("[Fzfkasten] No checkbox on this line.", vim.log.levels.WARN)
        return
    end
    vim.api.nvim_buf_set_lines(0, lineno - 1, lineno, false, { toggled })
end

--- Pick an open task and jump to it in its source note.
--- `<ctrl-x>` marks the task done in the note and reopens the picker.
--- @param opts table|nil forwarded to `M.collect`
function M.pick(opts)
    opts = opts or {}
    local tasks = M.collect(opts)
    if #tasks == 0 then
        vim.notify("No open tasks found.", vim.log.levels.INFO)
        return
    end

    local entries = {}
    local by_entry = {}
    for _, task in ipairs(tasks) do
        local entry = to_entry(task)
        table.insert(entries, entry)
        by_entry[entry] = task
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

    fzf.fzf_exec(entries, vim.tbl_deep_extend("force", config.options.fzf, {
        prompt = "Tasks> ",
        -- Entries carry paths relative to `home`; without this the previewer
        -- resolves them against Neovim's cwd and fails to stat the note.
        cwd = config.options.home,
        previewer = "builtin",
        fzf_opts = {
            ["--delimiter"] = ":",
            ["--with-nth"] = "3..",
            ["--no-sort"] = "",
            ["--header"] = "<ctrl-x> mark done",
        },
        actions = {
            ['default'] = open,
            ['ctrl-x'] = function(selected)
                if not selected or #selected == 0 then return end
                local task = by_entry[selected[1]]
                if not task then return end
                if M.toggle_at(task.path, task.lineno) then
                    vim.notify("Done: " .. task.text, vim.log.levels.INFO)
                    vim.schedule(function() M.pick(opts) end)
                end
            end,
        },
    }))
end

return M
