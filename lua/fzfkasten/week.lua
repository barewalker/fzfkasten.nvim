-- A week of the collection, for looking back over it.
--
-- A weekly review starts with "what did I write this week", and nothing here
-- answered that. The finder ranks by name, the log picker walks the journal
-- by date but only the journal, and a note filed under a topic is dated by
-- its frontmatter, which no picker read. So: the notes dated within one ISO
-- week, as a picker (`:FzfKastenWeekNotes`) and as one buffer that lays them
-- out (`:FzfKastenWeekDigest`) -- outline, opening lines, and the tasks the
-- week finished -- to be read down, pruned, and pasted into the weekly note
-- or handed to the Claude pane.
--
-- A note is dated the way the task scanner dates it: the filename, then the
-- frontmatter keys in `tasks.date_keys`, never mtime, which git rewrites on
-- every checkout. The frontmatter of the whole collection is read in one
-- ripgrep pass rather than a `readfile` per note -- 20ms here against 3.5
-- seconds on WSL2, the same number the note finder was built around.
local config = require('fzfkasten.config')
local utils = require('fzfkasten.utils')
local buffer = require('fzfkasten.buffer')

local M = {}

local function options()
    return config.options.week or {}
end

local function notify(msg, level)
    vim.notify("[Fzfkasten] " .. msg, level or vim.log.levels.INFO)
end

-- Weeks -----------------------------------------------------------------------

-- Days back from `t` to the Monday of its week. `%w` is 0 on Sunday, and an
-- ISO week starts on Monday, so Sunday is six days into it, not none.
local function days_since_monday(t)
    return (tonumber(os.date("%w", t)) + 6) % 7
end

--- The Monday of the ISO week `t` falls in, at midday.
local function monday_of(t)
    return utils.days_from(t, -days_since_monday(t))
end

--- The Monday of ISO week `week` of ISO year `year`, at midday.
---
--- Week 1 is the week with January 4th in it -- the ISO definition -- so its
--- Monday is found from there, and the others are whole weeks on. Calendar
--- steps, not seconds, for the reason `days_from` gives.
local function iso_week_monday(year, week)
    local jan4 = os.time({ year = year, month = 1, day = 4, hour = 12, min = 0, sec = 0 })
    return utils.days_from(jan4, -days_since_monday(jan4) + (week - 1) * 7)
end

--- The week `spec` names, or nil and why not.
---
--- `spec` is one of: nothing (this week); an integer, counted in weeks from
--- this one (`-1` is last week -- the usual one on a Monday); an ISO week
--- (`2026-W37`, `2026-w37`, `2026W37`); a date (`2026-09-10`, the week that
--- day falls in).
--- @param spec string|nil
--- @param now integer|nil timestamp standing for "now"
--- @return table|nil range `{ label, from, to, monday }`; `from`/`to` are
---   "YYYY-MM-DD", Monday and Sunday, `label` the ISO week "YYYY-Www"
--- @return string|nil err
function M.range(spec, now)
    now = now or os.time()
    spec = vim.trim(spec or "")

    local monday
    if spec == "" then
        monday = monday_of(now)
    elseif spec:match("^[-+]?%d+$") then
        monday = monday_of(utils.days_from(now, tonumber(spec) * 7))
    else
        local year, week = spec:match("^(%d%d%d%d)%-?[Ww](%d%d?)$")
        if year then
            week = tonumber(week)
            if week < 1 or week > 53 then
                return nil, "There is no week " .. week .. "."
            end
            monday = iso_week_monday(tonumber(year), week)
        else
            local y, m, d = spec:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
            if not y then
                return nil, ("Expected a week like 2026-W37, a date like 2026-09-10, "
                    .. "or -1 for last week; got %q."):format(spec)
            end
            monday = monday_of(os.time({
                year = tonumber(y), month = tonumber(m), day = tonumber(d),
                hour = 12, min = 0, sec = 0,
            }))
        end
    end

    return {
        label = os.date("%G-W%V", monday),
        from = os.date("%Y-%m-%d", monday),
        to = os.date("%Y-%m-%d", utils.days_from(monday, 6)),
        monday = monday,
    }
end

-- Notes -----------------------------------------------------------------------

local function ignored(rel)
    for _, dir in ipairs(options().ignore_dirs or {}) do
        if rel == dir or rel:sub(1, #dir + 1) == dir .. "/" then
            return true
        end
    end
    return false
end

--- The frontmatter block of every note that opens with one, keyed by path
--- relative to `home`, as lines -- or nil when ripgrep could not answer.
---
--- One process over the collection. Multiline mode reads each file as one
--- buffer, so `\A---` is "starts with a fence" and the lazy `.*?` stops at the
--- first closing one. `--json` because a match spans lines and the plain output
--- would prefix every one of them; here each match is one object, path and
--- text together, with nothing to disambiguate.
--- @return table<string, string[]>|nil
local function frontmatters()
    if vim.fn.executable("rg") ~= 1 then return nil end
    local ok, handle = pcall(vim.system, {
        "rg", "--json", "--multiline", "--no-messages", "--no-ignore-vcs",
        "--max-count", "1", "--glob", "*." .. config.options.extension,
        "-e", [[\A---\n(?s:.*?)\n---(?:\n|\z)]],
    }, { cwd = config.options.home, text = true })
    if not ok then return nil end
    local rg = handle:wait()
    if rg.code > 1 then return nil end

    local by_rel = {}
    for _, line in ipairs(vim.split(rg.stdout or "", "\n", { plain = true })) do
        if line ~= "" then
            local decoded, obj = pcall(vim.json.decode, line)
            if decoded and type(obj) == "table" and obj.type == "match" then
                local data = obj.data or {}
                local path = data.path and data.path.text
                local text = data.lines and data.lines.text
                if path and text then
                    by_rel[(path:gsub("^%./", ""))] = vim.split(text, "\n", { plain = true })
                end
            end
        end
    end
    return by_rel
end

--- The notes dated within `range`, earliest first.
---
--- A note with no date is not in any week; there is nothing to place it by.
--- Dates come from `tasks.date_of`, so a `tasks.date` hook of yours is honoured
--- here too -- at the price of reading every note, since the hook is asked
--- first, wants lines, and can look anywhere in them.
---
--- The week's own weekly note is left out. It is dated into its week -- its
--- template writes Monday's date -- but it is what the review is written into,
--- not what it is written from, and a digest quoting last week's review back
--- is the one section that is never material.
--- @param range table from `M.range`
--- @return table[] `{ rel, path, name, date }`
function M.notes(range)
    local tasks = require('fzfkasten.tasks')
    local home = config.options.home
    local hook = type(config.options.tasks.date) == "function"
    local heads = (not hook) and frontmatters() or nil
    local weekly = M.weekly_rel(range)

    local found = {}
    for _, rel in ipairs(require('fzfkasten.pickers').all_notes()) do
        if not ignored(rel) and rel ~= weekly then
            local path = utils.join_path(home, rel)
            local lines
            if heads then
                lines = heads[rel] or {}
            else
                -- No rg, or a hook that reads the body: the file itself. The
                -- frontmatter is at the top, so without a hook the head is
                -- enough, and the hook gets the whole note.
                local ok, read
                if hook then
                    ok, read = pcall(vim.fn.readfile, path)
                else
                    ok, read = pcall(vim.fn.readfile, path, "", 100)
                end
                lines = ok and read or {}
            end
            local date = tasks.date_of(path, lines)
            if date and date >= range.from and date <= range.to then
                found[#found + 1] = {
                    rel = rel, path = path, date = date,
                    name = utils.note_name(rel),
                }
            end
        end
    end

    table.sort(found, function(a, b)
        if a.date ~= b.date then return a.date < b.date end
        return a.rel < b.rel
    end)
    return found
end

--- The weekly note of `range`, relative to `home`: where the review goes.
--- @param range table from `M.range`
--- @return string rel
function M.weekly_rel(range)
    local weekly = config.options.notes.weekly
    local name = config.options.transform.new_file_name(os.date(weekly.format, range.monday))
    return utils.join_path(weekly.dir, name .. "." .. config.options.extension)
end

--- "09-10 Thu" for a "YYYY-MM-DD".
local function day_label(date)
    local y, m, d = date:match("^(%d+)%-(%d+)%-(%d+)$")
    local t = os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 })
    return os.date("%m-%d %a", t)
end

local function nothing_dated(range)
    notify(("No notes dated %s (%s to %s)."):format(range.label, range.from, range.to))
end

-- The picker ------------------------------------------------------------------

--- The notes of a week, previewed. `<enter>` opens one; `<ctrl-d>` opens the
--- digest of the same week instead.
--- @param spec string|nil see `M.range`
function M.pick(spec)
    local range, err = M.range(spec)
    if not range then return notify(err, vim.log.levels.ERROR) end
    local notes = M.notes(range)
    if #notes == 0 then return nothing_dated(range) end

    -- "<rel>:1: <label>" so the builtin previewer (cwd = home) shows the note,
    -- as the log picker's entries do; `--with-nth 3..` hides the path.
    local entries, lookup = {}, {}
    for _, n in ipairs(notes) do
        local shown = n.rel:gsub("%." .. vim.pesc(config.options.extension) .. "$", "")
        local entry = ("%s:1: %s  %s"):format(n.rel, day_label(n.date), shown)
        entries[#entries + 1] = entry
        lookup[entry] = n
    end

    local fzf = require('fzf-lua')
    fzf.fzf_exec(entries, vim.tbl_deep_extend("force", config.options.fzf, {
        prompt = range.label .. "> ",
        cwd = config.options.home,
        previewer = "builtin",
        fzf_opts = {
            ["--delimiter"] = ":",
            ["--with-nth"] = "3..",
            ["--no-sort"] = "",
            ["--header"] = ("%s to %s  |  <ctrl-d> digest"):format(range.from, range.to),
        },
        actions = {
            ['default'] = function(selected)
                local n = selected and lookup[selected[1]]
                if n then buffer.edit(n.path) end
            end,
            ['ctrl-d'] = function()
                vim.schedule(function() M.digest(spec) end)
            end,
        },
    }))
end

-- The digest ------------------------------------------------------------------

-- Where a note's body starts: past the frontmatter, when it opens with one.
local function body_start(lines)
    if lines[1] ~= "---" then return 1 end
    for i = 2, #lines do
        if lines[i] == "---" then return i + 1 end
    end
    return 1 -- unterminated: not frontmatter after all
end

local function fence_delimiter(line)
    return line:match("^%s*(```+)") or line:match("^%s*(~~~+)")
end

--- What the digest says about one note: its title, an outline of its headings,
--- and its first `quote` body lines.
---
--- The headings are bulleted rather than kept as headings, which would cut the
--- digest's own structure to pieces; the body lines are quoted, so a note that
--- opens with a list or a fence does the same. A `# Title` that opens the note
--- and is its only `#` is the title, and not the first heading of the outline,
--- where it would be a one-item outline saying what the section heading
--- already says. A note with several `#` headings has sections, not a title,
--- and all of them are kept -- pulling the first out would leave its `##`
--- children hanging under nothing.
--- @param lines string[] the note
--- @param quote integer how many body lines
--- @return string|nil title, string[] outline, string[] excerpt, boolean more
function M.summarise(lines, quote)
    local title, headings, excerpt = nil, {}, {}
    local more, in_fence = false, nil
    local first_content, opens_with_h1, h1s = true, false, 0

    for i = body_start(lines), #lines do
        local line = lines[i]
        local fence = fence_delimiter(line)
        if fence then
            if not in_fence then
                in_fence = fence
            elseif line:match("^%s*" .. in_fence) then
                in_fence = nil
            end
        end

        local hashes, text = line:match("^(#+)%s+(.-)%s*$")
        if hashes and not in_fence and text ~= "" then
            if #hashes == 1 then
                h1s = h1s + 1
                opens_with_h1 = opens_with_h1 or first_content
            end
            headings[#headings + 1] = { level = #hashes, text = text }
            first_content = false
        elseif line:match("%S") then
            first_content = false
            if #excerpt < quote then
                excerpt[#excerpt + 1] = line
            else
                more = true
            end
        end
    end

    if opens_with_h1 and h1s == 1 then
        title = table.remove(headings, 1).text
    end

    -- Indented from the shallowest heading the note has, not from `#`: under a
    -- `# Title` the `##` sections are the top of the outline, and a note that
    -- goes straight to `##` should not read as one indented for no reason.
    local top = math.huge
    for _, h in ipairs(headings) do top = math.min(top, h.level) end
    local outline = {}
    for _, h in ipairs(headings) do
        outline[#outline + 1] = string.rep("  ", h.level - top) .. "- " .. h.text
    end
    return title, outline, excerpt, more
end

local function labels()
    local l = (options().digest or {}).labels or {}
    return {
        notes = l.notes or "%d notes",
        calendar = l.calendar or "Calendar",
        finished = l.finished or "Finished this week",
        open = l.open or "Still open in this week's notes",
        ahead = l.ahead or "Coming up",
        due = l.due or "Due",
        unavailable = l.unavailable or "unavailable",
    }
end

--- The weeks after `range`: from the day after its Sunday, `weeks` weeks on.
--- @param range table from `M.range`
--- @param weeks integer
--- @return table `{ from, to, label }`, both "YYYY-MM-DD"
function M.ahead_of(range, weeks)
    local from = utils.days_from(range.monday, 7)
    local to = utils.days_from(range.monday, 7 * weeks + 6)
    return {
        from = os.date("%Y-%m-%d", from),
        to = os.date("%Y-%m-%d", to),
        label = weeks == 1 and os.date("%G-W%V", from)
            or (os.date("%G-W%V", from) .. ".." .. os.date("%G-W%V", to)),
    }
end

--- What one of `week.digest.sources` says for `range`, as lines -- or one
--- line saying why it could not. A source is somebody else's program (a
--- mail index, a ticket tracker) reached through a function of yours, and a
--- source that is down must not take the digest down with it.
--- @param source table `{ label = string, fn = function(range, ahead) -> string[] }`
--- @return string[]
local function source_lines(source, range, ahead)
    local l = labels()
    if type(source.fn) ~= "function" then
        return { ("(%s: `fn` is not a function)"):format(l.unavailable) }
    end
    local ok, lines = pcall(source.fn, range, ahead)
    if not ok then
        return { ("(%s: %s)"):format(l.unavailable, tostring(lines)) }
    end
    if type(lines) == "string" then
        lines = vim.split(lines, "\n", { plain = true })
    end
    if type(lines) ~= "table" then
        return { ("(%s: returned %s)"):format(l.unavailable, type(lines)) }
    end
    -- Trailing blank lines are the source's, not the digest's.
    while #lines > 0 and vim.trim(lines[#lines]) == "" do lines[#lines] = nil end
    return lines
end

--- The digest as lines, and which note each section is about.
--- @param range table from `M.range`
--- @param notes table[] from `M.notes`
--- @param opts table|nil `{ lines = integer, tasks = boolean, calendar = boolean,
---   ahead = integer, sources = table[] }`, defaulting to `week.digest`
--- @return string[] lines
--- @return table<integer, table> sections line number (1-based) of each note's
---   heading -> that note
function M.digest_lines(range, notes, opts)
    local o = vim.tbl_extend("force", options().digest or {}, opts or {})
    local quote = tonumber(o.lines) or 8
    local l = labels()
    local weekly = config.options.notes.weekly
    local weekly_name = config.options.transform.new_file_name(os.date(weekly.format, range.monday))

    local weeks_ahead = tonumber(o.ahead) or 0
    local ahead = weeks_ahead > 0 and M.ahead_of(range, weeks_ahead) or nil

    local out, sections = {}, {}
    local function put(line) out[#out + 1] = line end
    local function section(title, rows)
        put("")
        put("## " .. title)
        put("")
        for _, row in ipairs(rows) do put(row) end
    end

    put(("# %s  %s to %s"):format(range.label, range.from, range.to))
    put("")
    put(("%s, [[%s]]"):format(l.notes:format(#notes), weekly_name))

    -- The calendar first: it is the frame the notes were written inside, and
    -- a review reads "what was planned" before "what was written".
    local calendar = require('fzfkasten.calendar')
    if o.calendar ~= false and calendar.enabled() then
        local rows, count = calendar.range_lines(range.from, range.to)
        put("")
        put(("## %s (%d)"):format(l.calendar, count))
        put("")
        for _, row in ipairs(rows) do put(row) end
    end

    local in_week = {}
    for _, n in ipairs(notes) do
        in_week[n.rel] = true
        local ok, lines = pcall(vim.fn.readfile, n.path)
        local title, outline, excerpt, more = M.summarise(ok and lines or {}, quote)

        put("")
        local heading = ("## %s  [[%s]]"):format(day_label(n.date), n.name)
        if title and title ~= n.name then
            heading = heading .. " -- " .. title
        end
        put(heading)
        sections[#out] = n

        if #outline > 0 then
            put("")
            for _, row in ipairs(outline) do put(row) end
        end
        if #excerpt > 0 then
            put("")
            for _, row in ipairs(excerpt) do put("> " .. row) end
            if more then put("> …") end
        end
    end

    local function task_line(t, mark)
        local text = t.priority and ("(%s) %s"):format(t.priority, t.text) or t.text
        return ("- [%s] %s  ([[%s]])"):format(mark, text, utils.note_name(t.rel))
    end

    local due_ahead = {}
    if o.tasks ~= false then
        local tasks = require('fzfkasten.tasks')
        local all = tasks.collect({ done = true, since_days = false, sort = "added" })
        local finished, open = {}, {}
        for _, t in ipairs(all) do
            local day = t.done_at and t.done_at:sub(1, 10)
            if t.done and day and day >= range.from and day <= range.to then
                finished[#finished + 1] = t
            elseif not t.done and not t.cancelled then
                if in_week[t.rel] then
                    open[#open + 1] = t
                end
                local due = t.due and t.due:sub(1, 10)
                if ahead and due and due >= ahead.from and due <= ahead.to then
                    due_ahead[#due_ahead + 1] = t
                end
            end
        end
        table.sort(finished, function(a, b) return a.done_at < b.done_at end)
        table.sort(due_ahead, function(a, b) return a.due < b.due end)

        if #finished > 0 then
            local rows = {}
            for _, t in ipairs(finished) do rows[#rows + 1] = task_line(t, "x") end
            section(("%s (%d)"):format(l.finished, #finished), rows)
        end
        if #open > 0 then
            local rows = {}
            for _, t in ipairs(open) do rows[#rows + 1] = task_line(t, " ") end
            section(("%s (%d)"):format(l.open, #open), rows)
        end
    end

    -- Somebody else's records of the week: a mail index, a tracker. Each is a
    -- section of its own, in the order given.
    for _, source in ipairs(o.sources or {}) do
        if type(source) == "table" then
            section(source.label or "?", source_lines(source, range, ahead))
        end
    end

    -- Then what is coming: the review ends by looking forward, and the next
    -- weeks' calendar and the tasks falling due in them are what it looks at.
    -- Kept apart from the week's own sections so that "what happened" and
    -- "what is next" are never read as one list.
    if ahead then
        if o.calendar ~= false and calendar.enabled() then
            local rows, count = calendar.range_lines(ahead.from, ahead.to)
            section(("%s (%d)  %s to %s"):format(l.ahead, count, ahead.from, ahead.to), rows)
        end
        if #due_ahead > 0 then
            local rows = {}
            -- The task's text still carries its `due:` token, which says when.
            for _, t in ipairs(due_ahead) do rows[#rows + 1] = task_line(t, " ") end
            section(("%s %s to %s (%d)"):format(l.due, ahead.from, ahead.to, #due_ahead), rows)
        end
    end

    return out, sections
end

-- The note the cursor's section is about, looking up from the cursor.
local function section_at(sections, row)
    for i = row, 1, -1 do
        if sections[i] then return sections[i] end
    end
    return nil
end

local function open_window(where)
    if where == "split" then
        vim.cmd("split")
    elseif where == "vsplit" then
        vim.cmd("vsplit")
    elseif where == "tab" then
        vim.cmd("tabnew")
    end
end

--- The fold level of a digest line: a fold starts at each `##`, nested one
--- deeper per extra `#`; the `#` title at the top is no fold, since it would
--- be the whole buffer. Everything else continues the fold above it.
---
--- The digest's own, rather than the treesitter one, because of what the
--- buffer is: a scratch buffer (`buftype=nofile`), and nvim-ufo, which many
--- markdown setups run, refuses to ask treesitter about a nofile buffer and
--- folds it by indent instead -- so `zc` on a heading found no fold at all.
--- Headings are the digest's whole structure, and folding them needs no
--- parser.
--- @param lnum integer|nil the line; `v:lnum` when called as 'foldexpr'
--- @return string
function M.foldexpr(lnum)
    lnum = lnum or vim.v.lnum
    local line = vim.api.nvim_buf_get_lines(0, lnum - 1, lnum, false)[1] or ""
    local hashes = line:match("^(#+)%s")
    if hashes then
        local level = #hashes - 1
        return level > 0 and (">" .. level) or "0"
    end
    return "="
end

-- Fold the window showing `buf` by the digest's headings, whatever the
-- window was folding by before. Window options travel with the window, not
-- the buffer: a window that showed a note nvim-ufo had attached to is left on
-- `foldmethod=manual`, and the digest shown in it next inherits that. So it
-- is set on every BufWinEnter of the digest, not once -- and ufo is told to
-- leave the buffer alone, or it puts `manual` back.
local function fold_by_headings(buf)
    local ok, ufo = pcall(require, 'ufo')
    if ok and type(ufo.detach) == "function" then
        pcall(ufo.detach, buf)
    end
    local function apply()
        local win = vim.api.nvim_get_current_win()
        if vim.api.nvim_win_get_buf(win) ~= buf then return end
        vim.wo[win].foldmethod = "expr"
        vim.wo[win].foldexpr = "v:lua.require'fzfkasten.week'.foldexpr()"
        vim.wo[win].foldenable = true
        -- Open to begin with: the digest is read down first and folded to
        -- taste, and a buffer that opens as a list of closed headings has
        -- hidden what it was opened for.
        vim.wo[win].foldlevel = 99
    end
    apply()
    vim.api.nvim_create_autocmd("BufWinEnter", {
        buffer = buf,
        group = vim.api.nvim_create_augroup("fzfkasten_week_folds_" .. buf, { clear = true }),
        callback = apply,
    })
end

--- Lay the week out in a buffer.
---
--- A scratch buffer, named for the week and reused when it is already around,
--- and left writable: it is a draft of the review as much as a view of the
--- notes, and pruning it in place before it is pasted on is the point. It is
--- an fzfkasten buffer (`vim.b.fzfkasten`), so `:FzfKastenClaudeSendBuffer`
--- pastes it whole. `<enter>` opens the note under the cursor's section; `q`
--- closes. It folds by its headings (`zc` on a `##` folds that note's
--- section), by a foldexpr of its own -- see `foldexpr`.
--- @param spec string|nil see `M.range`
function M.digest(spec)
    local range, err = M.range(spec)
    if not range then return notify(err, vim.log.levels.ERROR) end
    local notes = M.notes(range)
    if #notes == 0 then return nothing_dated(range) end

    local lines, sections = M.digest_lines(range, notes)
    local name = "fzfkasten://week/" .. range.label

    local buf = vim.fn.bufnr(name)
    if buf == -1 or not vim.api.nvim_buf_is_loaded(buf) then
        buf = vim.api.nvim_create_buf(true, true)
        pcall(vim.api.nvim_buf_set_name, buf, name)
        vim.bo[buf].buftype = "nofile"
        vim.bo[buf].swapfile = false
        vim.bo[buf].filetype = "markdown"
        buffer.mark(buf)
    end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modified = false
    vim.b[buf].fzfkasten_week = range.label

    open_window((options().digest or {}).open)
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    fold_by_headings(buf)

    vim.keymap.set("n", "<CR>", function()
        local n = section_at(sections, vim.api.nvim_win_get_cursor(0)[1])
        if n then buffer.edit(n.path) end
    end, { buffer = buf, desc = "Fzfkasten: open this section's note" })
    vim.keymap.set("n", "q", function()
        pcall(vim.cmd, "bdelete " .. buf)
    end, { buffer = buf, desc = "Fzfkasten: close the digest" })
end

-- Exposed for the tests: the calendar and the summary are where the edge cases
-- are, and neither needs a window to be checked.
M._test = {
    iso_week_monday = iso_week_monday,
    monday_of = monday_of,
    frontmatters = frontmatters,
    body_start = body_start,
}

return M
