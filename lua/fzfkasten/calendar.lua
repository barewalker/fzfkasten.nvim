-- A calendar, read through a command that lists its events.
--
-- What a note is about is often what was on the calendar that day: the
-- meeting the minutes are of, the visit the daily records. Nothing here
-- talks to a calendar service -- that takes an account, a consent screen and
-- a token, none of which belong in an editor plugin. A command does the
-- talking, gcalcli by default, and this reads what it prints: a header naming
-- the columns, then one event per line. Anything that prints the same shape
-- (or a `parse` of your own for one that does not) stands in for it.
--
-- The list is kept, on disk and in memory, for `cache.ttl` seconds. A gcalcli
-- call is about 0.6s of network; creating a daily note from its template, or
-- laying a week out, must not pay that every time. When the command fails the
-- last list is used whatever its age, and says so: a stale agenda you can
-- see the date of beats an empty one that looks like a free day.
local config = require('fzfkasten.config')
local utils = require('fzfkasten.utils')

local M = {}

local function options()
    return config.options.calendar or {}
end

local function labels()
    local l = options().labels or {}
    return {
        all_day = l.all_day or "all day",
        unavailable = l.unavailable or "calendar unavailable",
    }
end

function M.enabled()
    return options().enabled == true
end

--- Midday of "YYYY-MM-DD", as a timestamp.
local function time_of(date)
    local y, m, d = date:match("^(%d+)%-(%d+)%-(%d+)$")
    return os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12, min = 0, sec = 0 })
end

local function day_after(date)
    return os.date("%Y-%m-%d", utils.days_from(time_of(date), 1))
end

-- The command --------------------------------------------------------------

--- The argv that lists the events from `from` up to but not including `to`.
--- @return string[]
local function command(from, to)
    local o = options()
    if type(o.cmd) == "function" then
        return o.cmd(from, to, o.name)
    end
    -- `--details` takes one value per flag. location and id are asked for
    -- every time so the columns are there whether or not anything reads them;
    -- the parse goes by the header, so more columns never hurt.
    local argv = { o.gcalcli or "gcalcli", "--nocolor", "agenda", "--tsv",
        "--details", "location", "--details", "id" }
    local names = o.name
    if type(names) == "string" then names = { names } end
    for _, name in ipairs(names or {}) do
        vim.list_extend(argv, { "--calendar", name })
    end
    vim.list_extend(argv, { from, to })
    return argv
end

-- Parsing ------------------------------------------------------------------

local function sort_events(events)
    table.sort(events, function(a, b)
        if a.date ~= b.date then return a.date < b.date end
        -- All-day first: they are the shape of the day, the timed ones sit
        -- inside it.
        if a.all_day ~= b.all_day then return a.all_day end
        if (a.start or "") ~= (b.start or "") then return (a.start or "") < (b.start or "") end
        return a.title < b.title
    end)
    return events
end

--- gcalcli's `agenda --tsv`, read by its header.
---
--- An all-day event that spans days is printed the way Google stores it, with
--- an end date that is the day *after* the last one -- exclusive, like a
--- range. `last` here is the last day the event is on, which is what "is
--- this on Tuesday" needs to compare against.
--- @param text string
--- @return table[]|nil events, string|nil err
function M.parse_tsv(text)
    local lines = vim.split(text or "", "\n", { plain = true })
    local header = lines[1]
    if not header or header == "" then
        return {}
    end
    local cols = {}
    for i, name in ipairs(vim.split(header, "\t", { plain = true })) do
        cols[name] = i
    end
    if not cols.start_date or not cols.title then
        return nil, "not a gcalcli TSV (no start_date/title columns)"
    end

    local events = {}
    for i = 2, #lines do
        local line = lines[i]
        if line ~= "" then
            local fields = vim.split(line, "\t", { plain = true })
            local function col(name)
                local at = cols[name]
                local v = at and fields[at]
                if v == nil or v == "" then return nil end
                return v
            end
            local ev = {
                date = col("start_date"),
                start = col("start_time"),
                end_date = col("end_date"),
                stop = col("end_time"),
                title = col("title") or "",
                location = col("location"),
                id = col("id"),
                calendar = col("calendar"),
            }
            if ev.date and ev.date:match("^%d%d%d%d%-%d%d%-%d%d$") then
                ev.all_day = ev.start == nil
                if ev.all_day and ev.end_date and ev.end_date > ev.date then
                    ev.last = os.date("%Y-%m-%d", utils.days_from(time_of(ev.end_date), -1))
                else
                    ev.last = ev.end_date or ev.date
                end
                if ev.last < ev.date then ev.last = ev.date end
                events[#events + 1] = ev
            end
        end
    end
    return sort_events(events)
end

--- What the command printed, as events: `calendar.parse` when set, else the
--- gcalcli TSV.
--- @return table[]|nil events, string|nil err
function M.parse(text)
    local o = options()
    if type(o.parse) == "function" then
        local ok, events = pcall(o.parse, text)
        if not ok then return nil, "calendar.parse raised: " .. tostring(events) end
        if type(events) ~= "table" then return nil, "calendar.parse did not return a list" end
        for _, ev in ipairs(events) do
            ev.all_day = ev.all_day == nil and ev.start == nil or ev.all_day
            ev.last = ev.last or ev.end_date or ev.date
        end
        return sort_events(events)
    end
    return M.parse_tsv(text)
end

-- Fetching -----------------------------------------------------------------

-- Lists already fetched this session, keyed by the command that fetched them.
local memory = {}

local function cache_dir()
    local dir = (options().cache or {}).dir
    if dir and dir ~= "" then return vim.fn.expand(dir) end
    return vim.fn.stdpath("cache") .. "/fzfkasten/calendar"
end

local function cache_file(key)
    return cache_dir() .. "/" .. vim.fn.sha256(key):sub(1, 16) .. ".tsv"
end

local function read_cached(file)
    local ok, lines = pcall(vim.fn.readfile, file)
    if not ok then return nil end
    return M.parse(table.concat(lines, "\n"))
end

--- The events from `from` up to but not including `to`.
---
--- Served from memory, then from the file the last run wrote, when either is
--- younger than `cache.ttl`; otherwise the command is run. A failed run falls
--- back to the file whatever its age, and the result says so (`stale`, with
--- the `error` that caused it), so the caller can show the fetch time rather
--- than pass an old list off as today's.
--- @param from string "YYYY-MM-DD"
--- @param to string "YYYY-MM-DD", exclusive
--- @param opts table|nil `{ refresh = true }` to ignore the cache
--- @return table|nil result `{ events, at = timestamp, stale = boolean, error = string|nil }`
--- @return string|nil err when there is nothing to show at all
function M.fetch(from, to, opts)
    opts = opts or {}
    local o = options()
    if not M.enabled() then
        return nil, "calendar.enabled is false"
    end

    local argv = command(from, to)
    if type(argv) ~= "table" or #argv == 0 then
        return nil, "calendar.cmd returned no command"
    end
    -- Keyed by the range as well as the command: a `cmd` of your own that
    -- reads the range from somewhere other than its arguments must not be
    -- answered for one week with another's list.
    local key = from .. "\0" .. to .. "\0" .. table.concat(argv, "\0")
    local ttl = tonumber((o.cache or {}).ttl) or 900
    local now = os.time()

    local held = memory[key]
    if held and not opts.refresh and not held.stale and now - held.at < ttl then
        return held
    end

    local file = cache_file(key)
    local written = vim.fn.getftime(file)
    if not opts.refresh and written > 0 and now - written < ttl then
        local events = read_cached(file)
        if events then
            memory[key] = { events = events, at = written, stale = false }
            return memory[key]
        end
    end

    local why
    if vim.fn.executable(argv[1]) ~= 1 then
        why = argv[1] .. " is not on PATH"
    else
        local ok, handle = pcall(vim.system, argv, { text = true })
        if not ok then
            why = tostring(handle)
        else
            local run = handle:wait(tonumber(o.timeout) or 15000)
            if run.code == 124 then
                why = argv[1] .. " did not answer in time"
            elseif run.code ~= 0 then
                local first = vim.split(run.stderr or "", "\n", { plain = true })[1]
                why = ("%s exited %d%s"):format(argv[1], run.code,
                    first and first ~= "" and (": " .. first) or "")
            else
                local events, err = M.parse(run.stdout or "")
                if events then
                    pcall(vim.fn.mkdir, cache_dir(), "p")
                    pcall(vim.fn.writefile, vim.split(run.stdout or "", "\n", { plain = true }), file)
                    memory[key] = { events = events, at = now, stale = false }
                    return memory[key]
                end
                why = err
            end
        end
    end

    -- The command could not answer. The last list that did is better than
    -- nothing, as long as it is marked as what it is.
    if written > 0 then
        local events = read_cached(file)
        if events then
            memory[key] = { events = events, at = written, stale = true, error = why }
            return memory[key]
        end
    end
    return nil, why
end

-- Reading a list -----------------------------------------------------------

--- The events on `day`, in order.
function M.on_day(events, day)
    local out = {}
    for _, ev in ipairs(events or {}) do
        if ev.date <= day and day <= ev.last then
            out[#out + 1] = ev
        end
    end
    return out
end

--- One event as a line: "13:00-14:00  title  @location", "all day  title",
--- or whatever `calendar.format` says.
--- @param ev table
--- @param day string|nil the day it is being shown on
--- @return string
function M.format(ev, day)
    local o = options()
    if type(o.format) == "function" then
        local ok, line = pcall(o.format, ev, day)
        if ok and type(line) == "string" then return line end
    end
    local when
    if ev.all_day then
        when = labels().all_day
        if ev.last and ev.last > ev.date then
            when = ("%s (%s..%s)"):format(when, ev.date:sub(6), ev.last:sub(6))
        end
    else
        when = ev.start .. (ev.stop and ("-" .. ev.stop) or "")
    end
    local line = when .. "  " .. ev.title
    if ev.location then
        line = line .. "  @" .. ev.location
    end
    return line
end

--- "as of 09-13 07:20" for a stale result, "" for a fresh one.
local function staleness(result)
    if not result.stale then return "" end
    return (" (%s; as of %s)"):format(result.error or "stale", os.date("%m-%d %H:%M", result.at))
end

--- The day's events as lines for a note: `bullet` in front of each, or one
--- line saying why there are none to show.
--- @param time integer|nil timestamp in the day; now by default
--- @return string[] lines
function M.day_lines(time)
    local day = os.date("%Y-%m-%d", time or os.time())
    local bullet = options().bullet or "- "
    local result, err = M.fetch(day, day_after(day))
    if not result then
        return { bullet .. ("(%s: %s)"):format(labels().unavailable, err) }
    end
    local out = {}
    for _, ev in ipairs(M.on_day(result.events, day)) do
        out[#out + 1] = bullet .. M.format(ev, day)
    end
    if result.stale then
        out[#out + 1] = bullet .. ("(%s%s)"):format(labels().unavailable, staleness(result))
    end
    return out
end

--- The events from `from` to `to` (both inclusive), grouped under a line per
--- day. Days with nothing on are left out.
--- @param from string "YYYY-MM-DD"
--- @param to string "YYYY-MM-DD"
--- @return string[] lines, integer count of events, table|nil result
function M.range_lines(from, to)
    local bullet = options().bullet or "- "
    local result, err = M.fetch(from, day_after(to))
    if not result then
        return { bullet .. ("(%s: %s)"):format(labels().unavailable, err) }, 0, nil
    end
    local out, count, seen = {}, 0, {}
    local t = time_of(from)
    local stop = time_of(to)
    while t <= stop do
        local day = os.date("%Y-%m-%d", t)
        local on = M.on_day(result.events, day)
        if #on > 0 then
            out[#out + 1] = os.date("%m-%d %a", t)
            for _, ev in ipairs(on) do
                out[#out + 1] = bullet .. M.format(ev, day)
                local id = ev.id or (ev.date .. ev.title)
                if not seen[id] then
                    seen[id] = true
                    count = count + 1
                end
            end
        end
        t = utils.days_from(t, 1)
    end
    if result.stale then
        out[#out + 1] = ("(%s%s)"):format(labels().unavailable, staleness(result))
    end
    return out, count, result
end

--- `{{agenda}}`: the day's events, joined for a template.
function M.agenda_text(time)
    return table.concat(M.day_lines(time), "\n")
end

--- `{{agenda_week}}`: the week's events, joined for a template.
function M.week_text(time)
    local range = require('fzfkasten.week').range("", time)
    local lines = M.range_lines(range.from, range.to)
    return table.concat(lines, "\n")
end

-- The picker ---------------------------------------------------------------

local DIM, RESET = "\27[2m", "\27[0m"

--- The picker's rows for `events`, with a line drawn where `today` falls.
---
--- The list is a week or more of days and the eye needs to find today in it
--- before it can read anything else -- so a rule is drawn there, the days
--- before it are dimmed, and the rule is where today's events start (or
--- where they would, on a day with none). The rule is a row like the others;
--- selecting it opens today's daily note. Rows are unique strings, since fzf
--- hands back text and two events can read the same.
--- @param events table[] sorted, as `fetch` returns them
--- @param today string "YYYY-MM-DD"
--- @return string[] entries, table<string, table> lookup row -> event (the
---   rule maps to `{ date = today, rule = true }`)
function M.rows(events, today)
    local entries, lookup = {}, {}
    local function add(entry, ev)
        while lookup[entry] do entry = entry .. " " end
        entries[#entries + 1] = entry
        lookup[entry] = ev
    end
    local rule = ("%s today %s %s"):format(string.rep("─", 8),
        os.date("%m-%d %a", time_of(today)), string.rep("─", 24))
    local drawn = false
    for _, ev in ipairs(events) do
        if not drawn and ev.date >= today then
            add(rule, { date = today, rule = true })
            drawn = true
        end
        local text = ("%s  %s"):format(os.date("%m-%d %a", time_of(ev.date)), M.format(ev, ev.date))
        if ev.date < today then text = DIM .. text .. RESET end
        add(text, ev)
    end
    if not drawn then
        -- Every event is in the past: today is after all of them.
        add(rule, { date = today, rule = true })
    end
    return entries, lookup
end

--- The weeks `spec` names, as one range: a single week the way `week.range`
--- reads it, or two of them joined by `..` -- `0..1` is this week and next,
--- `-1..0` last week and this, `2026-W37..2026-W39` three named ones. Either
--- side may be empty for this week (`..1`).
--- @param spec string|nil
--- @return table|nil `{ label, from, to }`, string|nil err
function M.span(spec)
    local week = require('fzfkasten.week')
    spec = vim.trim(spec or "")
    local first, second = spec:match("^(.-)%.%.(.-)$")
    if not first then
        return week.range(spec)
    end
    local a, err = week.range(first)
    if not a then return nil, err end
    local b
    b, err = week.range(second)
    if not b then return nil, err end
    if b.monday < a.monday then a, b = b, a end
    if a.label == b.label then return a end
    return { label = a.label .. ".." .. b.label, from = a.from, to = b.to, monday = a.monday }
end

--- The events of a week or a span of weeks, one row each. `<enter>` opens
--- the daily note of the event's day (created from its template when
--- missing); `<alt-i>` puts the event's line into the buffer you came from;
--- `<ctrl-r>` fetches again.
--- @param spec string|nil the week(s), as `M.span` reads it
--- @param opts table|nil `{ refresh = true }`
function M.pick(spec, opts)
    opts = opts or {}
    local range, err = M.span(spec)
    if not range then
        return vim.notify("[Fzfkasten] " .. err, vim.log.levels.ERROR)
    end
    local result, why = M.fetch(range.from, day_after(range.to), { refresh = opts.refresh })
    if not result then
        return vim.notify("[Fzfkasten] " .. labels().unavailable .. ": " .. why, vim.log.levels.WARN)
    end
    if #result.events == 0 then
        return vim.notify(("[Fzfkasten] Nothing on the calendar %s (%s to %s)%s."):format(
            range.label, range.from, range.to, staleness(result)), vim.log.levels.INFO)
    end

    local entries, lookup = M.rows(result.events, os.date("%Y-%m-%d"))

    local fzf = require('fzf-lua')
    fzf.fzf_exec(entries, vim.tbl_deep_extend("force", config.options.fzf, {
        prompt = range.label .. " agenda> ",
        previewer = false,
        fzf_opts = {
            ["--no-sort"] = "",
            ["--header"] = ("%s to %s%s  |  <enter> daily note, <alt-i> insert, <ctrl-r> refetch"):format(
                range.from, range.to, staleness(result)),
        },
        actions = {
            ['default'] = function(selected)
                local ev = selected and lookup[selected[1]]
                if ev then
                    -- The today line is a row too; it opens today's note.
                    require('fzfkasten.core').open_note("daily", time_of(ev.date))
                end
            end,
            ['alt-i'] = function(selected)
                local lines = {}
                for _, row in ipairs(selected or {}) do
                    local ev = lookup[row]
                    if ev and not ev.rule then
                        lines[#lines + 1] = (options().bullet or "- ") .. M.format(ev, ev.date)
                    end
                end
                if #lines > 0 then
                    vim.api.nvim_put(lines, "l", true, true)
                end
            end,
            ['ctrl-r'] = function()
                vim.schedule(function() M.pick(spec, { refresh = true }) end)
            end,
        },
    }))
end

-- For the tests: the command that would run, and a way to start each case
-- with nothing remembered from the last.
M._test = {
    command = command,
    cache_file = cache_file,
    forget = function() memory = {} end,
    time_of = time_of,
}

return M
