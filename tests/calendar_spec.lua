-- The calendar: reading what the command prints, the cache in front of it,
-- and the lines a note gets. None of it runs gcalcli -- `calendar.cmd` is a
-- shell script here that prints a fixture and counts how often it was asked,
-- which is what the cache cases need to see.

local config = require("fzfkasten.config")
local calendar = require("fzfkasten.calendar")
local core = require("fzfkasten.core")

local home, dir, fixture, counter

local TSV = table.concat({
    "id\tstart_date\tstart_time\tend_date\tend_time\ttitle\tlocation",
    "a1\t2026-09-03\t\t2026-09-08\t\tリンテックRTT予備測定\t",
    "b2\t2026-09-07\t12:50\t2026-09-07\t13:30\t会議 / 全体会議\t",
    "c3\t2026-09-08\t13:00\t2026-09-08\t14:00\t会議 / 道場WG\t3F 会議室",
    "d4\t2026-09-08\t\t2026-09-09\t\t味の素予備実験\t",
    "e5\t2026-09-08\t09:00\t2026-09-08\t09:30\t朝会\t",
}, "\n") .. "\n"

local function write(path, text)
    vim.fn.writefile(vim.split(text, "\n", { plain = true }), path)
end

local function setup(opts)
    config.setup(vim.tbl_deep_extend("force", {
        home = home,
        calendar = {
            enabled = true,
            cache = { dir = dir, ttl = 900 },
            cmd = function() return { "sh", "-c", ("echo x >> %s; cat %s"):format(counter, fixture) } end,
        },
    }, opts or {}))
    calendar._test.forget()
end

local function asked()
    local ok, lines = pcall(vim.fn.readfile, counter)
    return ok and #lines or 0
end

describe("calendar.parse_tsv", function()
    before_each(function()
        home = vim.fn.tempname(); vim.fn.mkdir(home, "p")
        dir = home .. "/cache"; fixture = home .. "/agenda.tsv"; counter = home .. "/asked"
        setup()
    end)

    it("reads the columns by the header, whatever their order", function()
        local events = calendar.parse_tsv("title\tstart_date\tstart_time\tend_date\tend_time\n"
            .. "x\t2026-09-08\t13:00\t2026-09-08\t14:00\n")
        assert.are.equal(1, #events)
        assert.are.same({ date = "2026-09-08", start = "13:00", end_date = "2026-09-08", stop = "14:00",
            title = "x", all_day = false, last = "2026-09-08" }, events[1])
    end)

    it("knows an all-day event by its empty time, and ends it on its last day", function()
        local events = calendar.parse_tsv(TSV)
        local span = events[1]
        assert.are.equal("リンテックRTT予備測定", span.title)
        assert.is_true(span.all_day)
        assert.are.equal("2026-09-03", span.date)
        assert.are.equal("2026-09-07", span.last) -- printed as 09-08, exclusive
        local single = events[3]
        assert.are.equal("味の素予備実験", single.title)
        assert.are.equal("2026-09-08", single.last)
    end)

    it("orders by day, all-day first, then time", function()
        local titles = {}
        for _, ev in ipairs(calendar.parse_tsv(TSV)) do titles[#titles + 1] = ev.title end
        assert.are.same({ "リンテックRTT予備測定", "会議 / 全体会議", "味の素予備実験", "朝会", "会議 / 道場WG" }, titles)
    end)

    it("refuses something that is not the TSV", function()
        local events, err = calendar.parse_tsv("Mon Sep 07  12:50  会議\n")
        assert.is_nil(events)
        assert.is_string(err)
    end)

    it("is empty on empty output", function()
        assert.are.same({}, calendar.parse_tsv(""))
    end)
end)

describe("calendar.fetch", function()
    before_each(function()
        home = vim.fn.tempname(); vim.fn.mkdir(home, "p")
        dir = home .. "/cache"; fixture = home .. "/agenda.tsv"; counter = home .. "/asked"
        write(fixture, TSV)
        setup()
    end)

    after_each(function() vim.fn.delete(home, "rf") end)

    it("runs the command once and then answers from memory", function()
        local first = calendar.fetch("2026-09-07", "2026-09-14")
        assert.are.equal(5, #first.events)
        assert.is_false(first.stale)
        calendar.fetch("2026-09-07", "2026-09-14")
        calendar.fetch("2026-09-07", "2026-09-14")
        assert.are.equal(1, asked())
    end)

    it("answers from the file after memory is gone", function()
        calendar.fetch("2026-09-07", "2026-09-14")
        calendar._test.forget()
        local again = calendar.fetch("2026-09-07", "2026-09-14")
        assert.are.equal(5, #again.events)
        assert.are.equal(1, asked())
    end)

    it("asks again when told to refresh, and when the list is old", function()
        calendar.fetch("2026-09-07", "2026-09-14")
        calendar.fetch("2026-09-07", "2026-09-14", { refresh = true })
        assert.are.equal(2, asked())
        setup({ calendar = { cache = { ttl = 0 } } })
        calendar.fetch("2026-09-07", "2026-09-14")
        assert.are.equal(3, asked())
    end)

    it("asks separately for a different range", function()
        calendar.fetch("2026-09-07", "2026-09-14")
        calendar.fetch("2026-09-14", "2026-09-21")
        assert.are.equal(2, asked())
    end)

    -- The same command, failing this time: the fixture it cats is gone. (A
    -- different command would be a different cache entry, with nothing behind it.)
    it("falls back to the last list when the command fails, and says so", function()
        calendar.fetch("2026-09-07", "2026-09-14")
        setup({ calendar = { cache = { ttl = 0 } } })
        vim.fn.delete(fixture)
        local result = calendar.fetch("2026-09-07", "2026-09-14")
        assert.is_true(result.stale)
        assert.are.equal(5, #result.events)
        assert.is_truthy(result.error:find("exited 1: cat:", 1, true))
        assert.are.equal(2, asked())
    end)

    it("has nothing to give when the command fails with no list behind it", function()
        setup({ calendar = { cmd = function() return { "sh", "-c", "exit 1" } end } })
        local result, err = calendar.fetch("2026-09-07", "2026-09-14")
        assert.is_nil(result)
        assert.is_string(err)
    end)

    it("names a command that is not there", function()
        setup({ calendar = { cmd = function() return { "no-such-gcalcli", "agenda" } end } })
        local result, err = calendar.fetch("2026-09-07", "2026-09-14")
        assert.is_nil(result)
        assert.is_truthy(err:find("not on PATH", 1, true))
    end)

    it("does nothing while disabled", function()
        setup({ calendar = { enabled = false } })
        local result, err = calendar.fetch("2026-09-07", "2026-09-14")
        assert.is_nil(result)
        assert.is_truthy(err:find("enabled", 1, true))
        assert.are.equal(0, asked())
    end)

    it("builds the gcalcli command from the name by default", function()
        setup({ calendar = { cmd = false, name = "Hotbiz" } })
        local argv = calendar._test.command("2026-09-07", "2026-09-14")
        assert.are.same({ "gcalcli", "--nocolor", "agenda", "--tsv", "--details", "location",
            "--details", "id", "--calendar", "Hotbiz", "2026-09-07", "2026-09-14" }, argv)
    end)
end)

describe("calendar.span", function()
    local saturday = os.time({ year = 2026, month = 9, day = 12, hour = 12 })

    -- `week.range` is asked with "now"; here the spec is absolute so now is moot.
    it("reads one week the way the week commands do", function()
        local r = calendar.span("2026-W37")
        assert.are.equal("2026-W37", r.label)
        assert.are.equal("2026-09-07", r.from)
        assert.are.equal("2026-09-13", r.to)
    end)

    it("joins two weeks into one range", function()
        local r = calendar.span("2026-W37..2026-W38")
        assert.are.equal("2026-W37..2026-W38", r.label)
        assert.are.equal("2026-09-07", r.from)
        assert.are.equal("2026-09-20", r.to)
    end)

    it("puts the earlier week first whichever way round it was written", function()
        local r = calendar.span("2026-W38..2026-W37")
        assert.are.equal("2026-09-07", r.from)
        assert.are.equal("2026-09-20", r.to)
    end)

    it("collapses a span of one week", function()
        assert.are.equal("2026-W37", calendar.span("2026-W37..2026-W37").label)
    end)

    it("refuses a side it cannot read", function()
        local r, err = calendar.span("2026-W37..soon")
        assert.is_nil(r)
        assert.is_string(err)
    end)
end)

describe("calendar.rows", function()
    local function plain(s) return (s:gsub("\27%[[%d;]*m", "")) end
    local events = calendar.parse_tsv(TSV)

    it("draws the rule before today's first event and dims the days before", function()
        local entries, lookup = calendar.rows(events, "2026-09-08")
        assert.are.equal(6, #entries)
        assert.is_truthy(entries[1]:find("\27[2m", 1, true)) -- 09-07, past
        assert.is_truthy(entries[2]:find("\27[2m", 1, true))
        assert.is_truthy(plain(entries[3]):find("today 09-08 Tue", 1, true))
        assert.is_true(lookup[entries[3]].rule)
        assert.are.equal("2026-09-08", lookup[entries[3]].date)
        assert.is_falsy(entries[4]:find("\27[2m", 1, true)) -- today, plain
        assert.are.equal("味の素予備実験", lookup[entries[4]].title)
    end)

    -- 09-05 has nothing on; the span that began 09-03 is before it, 09-07 after.
    it("draws the rule where today would fall when it has no events", function()
        local entries, lookup = calendar.rows(events, "2026-09-05")
        assert.are.equal(6, #entries)
        assert.are.equal("リンテックRTT予備測定", lookup[entries[1]].title)
        assert.is_true(lookup[entries[2]].rule)
        assert.are.equal("会議 / 全体会議", lookup[entries[3]].title)
    end)

    it("draws the rule last when everything is past", function()
        local entries, lookup = calendar.rows(events, "2026-09-20")
        assert.is_true(lookup[entries[#entries]].rule)
        assert.is_truthy(entries[1]:find("\27[2m", 1, true))
    end)

    it("keeps two identical events apart", function()
        local twice = calendar.parse_tsv("start_date\tstart_time\tend_date\tend_time\ttitle\n"
            .. "2026-09-08\t09:00\t2026-09-08\t09:30\t朝会\n"
            .. "2026-09-08\t09:00\t2026-09-08\t09:30\t朝会\n")
        local entries, lookup = calendar.rows(twice, "2026-09-08")
        assert.are.equal(3, #entries)
        assert.are_not.equal(entries[2], entries[3])
        assert.is_not_nil(lookup[entries[3]])
    end)
end)

describe("the lines a note gets", function()
    before_each(function()
        home = vim.fn.tempname(); vim.fn.mkdir(home, "p")
        dir = home .. "/cache"; fixture = home .. "/agenda.tsv"; counter = home .. "/asked"
        write(fixture, TSV)
        setup()
    end)

    after_each(function() vim.fn.delete(home, "rf") end)

    local function on(y, m, d)
        return os.time({ year = y, month = m, day = d, hour = 12 })
    end

    it("lists a day, the spanning all-day event included, with its span", function()
        assert.are.same({
            "- all day (09-03..09-07)  リンテックRTT予備測定",
            "- 12:50-13:30  会議 / 全体会議",
        }, calendar.day_lines(on(2026, 9, 7)))
        assert.are.same({
            "- all day  味の素予備実験",
            "- 09:00-09:30  朝会",
            "- 13:00-14:00  会議 / 道場WG  @3F 会議室",
        }, calendar.day_lines(on(2026, 9, 8)))
        assert.are.same({}, calendar.day_lines(on(2026, 9, 10)))
    end)

    it("groups a range by day, leaving empty days out, and counts each event once", function()
        local lines, count = calendar.range_lines("2026-09-07", "2026-09-13")
        assert.are.equal(5, count)
        assert.are.same({
            "09-07 Mon",
            "- all day (09-03..09-07)  リンテックRTT予備測定",
            "- 12:50-13:30  会議 / 全体会議",
            "09-08 Tue",
            "- all day  味の素予備実験",
            "- 09:00-09:30  朝会",
            "- 13:00-14:00  会議 / 道場WG  @3F 会議室",
        }, lines)
    end)

    it("uses calendar.format and calendar.bullet when given", function()
        setup({ calendar = { bullet = "* ", format = function(ev) return ev.title end } })
        assert.are.same({ "* リンテックRTT予備測定", "* 会議 / 全体会議" }, calendar.day_lines(on(2026, 9, 7)))
    end)

    it("says why when there is nothing to show", function()
        setup({ calendar = { cmd = function() return { "sh", "-c", "exit 1" } end } })
        local lines = calendar.day_lines(on(2026, 9, 7))
        assert.are.equal(1, #lines)
        assert.is_truthy(lines[1]:find("calendar unavailable", 1, true))
    end)

    it("fills {{agenda}} and {{agenda_week}} in a template, and only then asks", function()
        vim.fn.mkdir(home .. "/templates", "p")
        write(home .. "/templates/plain.md", "# {{title}}\n")
        write(home .. "/templates/day.md", "# {{title}}\n\n## Agenda\n{{agenda}}\n")
        write(home .. "/templates/week.md", "# {{title}}\n\n{{agenda_week}}\n")

        core.load_template("plain.md", "t", on(2026, 9, 8))
        assert.are.equal(0, asked())

        local day = core.load_template("day.md", "t", on(2026, 9, 8))
        assert.is_truthy(day:find("## Agenda\n- all day  味の素予備実験\n- 09:00-09:30  朝会\n", 1, true))

        local week = core.load_template("week.md", "t", on(2026, 9, 10))
        assert.is_truthy(week:find("09-07 Mon\n- all day (09-03..09-07)", 1, true))
        assert.is_truthy(week:find("09-08 Tue\n", 1, true))
    end)
end)

describe("the digest's weeks ahead", function()
    before_each(function()
        home = vim.fn.tempname(); vim.fn.mkdir(home, "p")
        dir = home .. "/cache"; fixture = home .. "/agenda.tsv"; counter = home .. "/asked"
        write(fixture, TSV .. "f6\t2026-09-15\t10:00\t2026-09-15\t11:00\t来週の会議\t\n")
        setup({ notes = { daily = { dir = "daily", template = nil } } })
        vim.fn.mkdir(home .. "/daily", "p")
        vim.fn.writefile({ "# Day" }, home .. "/daily/2026-09-08.md")
    end)

    after_each(function() vim.fn.delete(home, "rf") end)

    it("keeps the week's calendar and the next week's apart", function()
        local week = require("fzfkasten.week")
        local range = week.range("", os.time({ year = 2026, month = 9, day = 12, hour = 12 }))
        local text = table.concat(week.digest_lines(range, week.notes(range), { ahead = 1, tasks = false }), "\n")
        local this = text:find("## Calendar (5)", 1, true)
        local next_ = text:find("## Coming up (1)  2026-09-14 to 2026-09-20\n\n09-15 Tue\n- 10:00-11:00  来週の会議", 1, true)
        assert.is_number(this)
        assert.is_number(next_)
        assert.is_true(this < text:find("## 09-08 Tue", 1, true))
        assert.is_true(next_ > text:find("## 09-08 Tue", 1, true))
    end)
end)
