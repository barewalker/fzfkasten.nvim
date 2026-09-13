-- The week view: which week a spec names, which notes fall in it, and what the
-- digest says about each. The calendar cases pin the ISO rules -- a week
-- starts on Monday and week 1 holds January 4th -- which are the two places a
-- "this week" built by hand goes wrong, and the year boundary where they
-- disagree with `%Y`.

local config = require("fzfkasten.config")
local week = require("fzfkasten.week")

local home

local function note(name, lines)
    local full = home .. "/" .. name
    vim.fn.mkdir(vim.fn.fnamemodify(full, ":h"), "p")
    vim.fn.writefile(lines, full)
end

local function on(year, month, day, hour)
    return os.time({ year = year, month = month, day = day, hour = hour or 12, min = 0, sec = 0 })
end

local function setup(opts)
    config.setup(vim.tbl_deep_extend("force", { home = home }, opts or {}))
end

describe("week.range", function()
    -- 2026-09-12 is a Saturday; its week is 2026-W37, Mon 09-07 to Sun 09-13.
    local saturday = on(2026, 9, 12)

    it("is this week with no spec", function()
        local r = week.range(nil, saturday)
        assert.are.equal("2026-W37", r.label)
        assert.are.equal("2026-09-07", r.from)
        assert.are.equal("2026-09-13", r.to)
    end)

    it("starts on Monday even when now is a Sunday", function()
        local r = week.range("", on(2026, 9, 13))
        assert.are.equal("2026-09-07", r.from)
        assert.are.equal("2026-09-13", r.to)
    end)

    it("counts weeks back and forward", function()
        assert.are.equal("2026-08-31", week.range("-1", saturday).from)
        assert.are.equal("2026-08-24", week.range("-2", saturday).from)
        assert.are.equal("2026-09-14", week.range("1", saturday).from)
        assert.are.equal("2026-09-07", week.range("0", saturday).from)
    end)

    it("reads an ISO week in any of its spellings", function()
        for _, spec in ipairs({ "2026-W37", "2026-w37", "2026W37", " 2026-W37 " }) do
            local r = week.range(spec, on(2000, 1, 1))
            assert.are.equal("2026-09-07", r.from, spec)
            assert.are.equal("2026-W37", r.label, spec)
        end
    end)

    it("reads a date as the week it falls in", function()
        local r = week.range("2026-09-10", on(2000, 1, 1))
        assert.are.equal("2026-09-07", r.from)
        assert.are.equal("2026-09-13", r.to)
    end)

    -- Week 1 is the week with January 4th in it, so it can start in December
    -- and the last week of a year can run into January.
    it("places week 1 by January 4th", function()
        -- 2027-01-04 is a Monday.
        assert.are.equal("2027-01-04", week.range("2027-W01").from)
        -- 2026-01-04 is a Sunday: week 1 began the previous Monday, in 2025.
        assert.are.equal("2025-12-29", week.range("2026-W01").from)
        -- 2021-01-04 is a Monday; the week before it is 2020-W53.
        assert.are.equal("2020-12-28", week.range("2020-W53").from)
    end)

    it("labels a December day by its ISO year", function()
        local r = week.range("2025-12-31", on(2000, 1, 1))
        assert.are.equal("2026-W01", r.label)
        assert.are.equal("2025-12-29", r.from)
    end)

    it("refuses what it cannot read", function()
        local r, err = week.range("last week")
        assert.is_nil(r)
        assert.is_string(err)
        r, err = week.range("2026-W60")
        assert.is_nil(r)
        assert.is_string(err)
    end)
end)

describe("week.notes", function()
    before_each(function()
        home = vim.fn.tempname()
        vim.fn.mkdir(home, "p")
        setup()
    end)

    after_each(function()
        vim.fn.delete(home, "rf")
    end)

    local function rels(spec)
        local found = {}
        for _, n in ipairs(week.notes(week.range(spec, on(2026, 9, 12)))) do
            found[#found + 1] = n.rel
        end
        return found
    end

    it("dates a note by its filename, then its frontmatter", function()
        note("daily/2026-09-08.md", { "# Tue" })
        note("topics/lathe.md", { "---", "date: 2026-09-10", "---", "# Lathe" })
        note("topics/old.md", { "---", "created: 2026-08-01 09:00", "---", "# Old" })
        note("topics/undated.md", { "# No date anywhere" })
        assert.are.same({ "daily/2026-09-08.md", "topics/lathe.md" }, rels(""))
        assert.are.same({}, rels("-1"))
    end)

    it("orders by date, then path", function()
        note("b/2026-09-09.md", { "" })
        note("a/2026-09-09.md", { "" })
        note("z/2026-09-07.md", { "" })
        assert.are.same({ "z/2026-09-07.md", "a/2026-09-09.md", "b/2026-09-09.md" }, rels(""))
    end)

    it("takes Monday and Sunday, and not the days either side", function()
        note("2026-09-06.md", { "" })
        note("2026-09-07.md", { "" })
        note("2026-09-13.md", { "" })
        note("2026-09-14.md", { "" })
        assert.are.same({ "2026-09-07.md", "2026-09-13.md" }, rels(""))
    end)

    it("leaves the ignored directories out", function()
        note("templates/daily.md", { "---", "date: 2026-09-10", "---" })
        note("daily/2026-09-10.md", { "" })
        assert.are.same({ "daily/2026-09-10.md" }, rels(""))
    end)

    it("leaves the week's own weekly note out", function()
        note("weekly/2026-W37.md", { "---", "date: 2026-09-07", "---", "# Review" })
        note("weekly/2026-W36.md", { "---", "date: 2026-09-07", "---", "# Misdated" })
        note("daily/2026-09-10.md", { "" })
        assert.are.same({ "weekly/2026-W36.md", "daily/2026-09-10.md" }, rels(""))
    end)

    it("leaves out notes whose path matches an ignore pattern", function()
        setup({ week = { ignore_patterns = { "%.materials%.md$" } } })
        note("lognote/2026-W37.materials.md", { "---", "date: 2026-09-07", "---", "# Materials" })
        note("lognote/2026-09-10.md", { "" })
        assert.are.same({ "lognote/2026-09-10.md" }, rels(""))
    end)

    it("does not read a date: line in the body as frontmatter", function()
        note("topics/plan.md", { "# Plan", "", "date: 2026-09-10" })
        assert.are.same({}, rels(""))
    end)

    it("honours a tasks.date hook", function()
        setup({ tasks = { date = function(_, lines)
            for _, l in ipairs(lines) do
                local d = l:match("^%*%*Created%*%*: (%d%d%d%d%-%d%d%-%d%d)")
                if d then return d end
            end
        end } })
        note("topics/hooked.md", { "# Hooked", "", "**Created**: 2026-09-11" })
        assert.are.same({ "topics/hooked.md" }, rels(""))
    end)

    it("gives the same answer with and without ripgrep", function()
        note("daily/2026-09-08.md", { "# Tue" })
        note("topics/lathe.md", { "---", "title: x", "date: 2026-09-10", "---", "# Lathe" })
        note("topics/plan.md", { "# Plan", "", "date: 2026-09-10" })
        local with = rels("")
        local fms = week._test.frontmatters()
        assert.is_not_nil(fms, "rg is needed for this case")
        assert.are.same({ "---", "title: x", "date: 2026-09-10", "---", "" }, fms["topics/lathe.md"])
        assert.is_nil(fms["topics/plan.md"])
        assert.are.same({ "daily/2026-09-08.md", "topics/lathe.md" }, with)
    end)
end)

describe("week.summarise", function()
    it("takes a leading H1 as the title and bullets the rest", function()
        local title, outline, excerpt, more = week.summarise({
            "---", "date: 2026-09-10", "---",
            "# Lathe",
            "",
            "First para.",
            "## Setup",
            "### Chuck",
            "Second.",
        }, 8)
        assert.are.equal("Lathe", title)
        assert.are.same({ "- Setup", "  - Chuck" }, outline)
        assert.are.same({ "First para.", "Second." }, excerpt)
        assert.is_false(more)
    end)

    it("keeps an H1 that is not first in the outline", function()
        local title, outline = week.summarise({ "intro", "# Late" }, 8)
        assert.is_nil(title)
        assert.are.same({ "- Late" }, outline)
    end)

    -- A daily note is sections all the way down: `# Commute`, `## outward`,
    -- `# Log`. Taking the first as the title would leave `outward` indented
    -- under nothing.
    it("treats several H1s as sections, not a title", function()
        local title, outline = week.summarise({ "# Commute", "## outward", "# Log" }, 8)
        assert.is_nil(title)
        assert.are.same({ "- Commute", "  - outward", "- Log" }, outline)
    end)

    it("stops quoting at the limit and says there is more", function()
        local _, _, excerpt, more = week.summarise({ "a", "b", "c" }, 2)
        assert.are.same({ "a", "b" }, excerpt)
        assert.is_true(more)
    end)

    it("does not read a # inside a fence as a heading", function()
        local _, outline, excerpt = week.summarise({ "```sh", "# comment", "```", "## Real" }, 8)
        assert.are.same({ "- Real" }, outline)
        assert.are.same({ "```sh", "# comment", "```" }, excerpt)
    end)
end)

describe("week.digest_lines", function()
    before_each(function()
        home = vim.fn.tempname()
        vim.fn.mkdir(home, "p")
        setup()
    end)

    after_each(function()
        vim.fn.delete(home, "rf")
    end)

    it("lays the week out with a section per note and the tasks it finished", function()
        note("daily/2026-09-08.md", {
            "# 2026-09-08",
            "- [x] ship it done:2026-09-08 10:00",
            "- [ ] follow up",
        })
        note("topics/lathe.md", { "---", "date: 2026-09-10", "---", "# Lathe", "", "Bought one." })
        note("topics/old.md", { "- [x] long ago done:2026-01-01 10:00", "- [ ] not this week" })

        local range = week.range("", on(2026, 9, 12))
        local lines, sections = week.digest_lines(range, week.notes(range))
        local text = table.concat(lines, "\n")

        assert.are.equal("# 2026-W37  2026-09-07 to 2026-09-13", lines[1])
        assert.are.equal("2 notes, [[2026-W37]]", lines[3])
        assert.is_truthy(text:find("## 09-08 Tue  [[2026-09-08]]", 1, true))
        assert.is_truthy(text:find("## 09-10 Thu  [[lathe]] -- Lathe", 1, true))
        assert.is_truthy(text:find("> Bought one.", 1, true))
        assert.is_truthy(text:find("## Finished this week (1)\n\n- ✓ ship it  ([[2026-09-08]])", 1, true))
        assert.is_truthy(text:find("## Still open in this week's notes (1)\n\n- ☐ follow up  ([[2026-09-08]])", 1, true))
        assert.is_falsy(text:find("long ago", 1, true))
        assert.is_falsy(text:find("not this week", 1, true))

        -- Each section heading knows its note.
        local seen = {}
        for row, n in pairs(sections) do
            assert.is_truthy(lines[row]:match("^## "))
            seen[n.rel] = true
        end
        assert.are.same({ ["daily/2026-09-08.md"] = true, ["topics/lathe.md"] = true }, seen)
    end)

    it("closes with the weeks ahead: their calendar and the tasks due in them", function()
        note("tasks/active.md", {
            "- [ ] next week due:2026-09-16",
            "- [ ] later due:2026-10-30",
            "- [ ] this week due:2026-09-10",
            "- [x] done due:2026-09-15 done:2026-09-08 10:00",
        })
        note("daily/2026-09-08.md", { "# Day" })
        local range = week.range("", on(2026, 9, 12))
        local lines = week.digest_lines(range, week.notes(range), { ahead = 1 })
        local text = table.concat(lines, "\n")
        assert.is_truthy(text:find("## Due 2026-09-14 to 2026-09-20 (1)\n\n- ☐ next week due:2026-09-16  ([[active]])", 1, true))
        assert.is_falsy(text:find("later", 1, true))
        -- The week's own section comes first, the ahead one last.
        assert.is_true(text:find("## 09-08 Tue", 1, true) < text:find("## Due", 1, true))

        local two = table.concat(week.digest_lines(range, week.notes(range), { ahead = 2 }), "\n")
        assert.is_truthy(two:find("## Due 2026-09-14 to 2026-09-27 (1)", 1, true))
        local none = table.concat(week.digest_lines(range, week.notes(range), { ahead = 0 }), "\n")
        assert.is_falsy(none:find("## Due", 1, true))
    end)

    it("gives each source a section, and a failing one a line", function()
        note("daily/2026-09-08.md", { "# Day" })
        local range = week.range("", on(2026, 9, 12))
        local seen
        local lines = week.digest_lines(range, week.notes(range), {
            tasks = false,
            sources = {
                { label = "Mail", fn = function(r, a)
                    seen = { r.from, r.to, a.from, a.to }
                    return { "- from A: hello", "- from B: world", "" }
                end },
                { label = "Tracker", fn = function() return "one\ntwo" end },
                { label = "Broken", fn = function() error("no socket") end },
                { label = "Wrong", fn = 42 },
            },
        })
        local text = table.concat(lines, "\n")
        assert.are.same({ "2026-09-07", "2026-09-13", "2026-09-14", "2026-09-20" }, seen)
        assert.is_truthy(text:find("## Mail\n\n- from A: hello\n- from B: world\n\n## Tracker\n\none\ntwo\n", 1, true))
        assert.is_truthy(text:find("## Broken\n\n(unavailable: ", 1, true))
        assert.is_truthy(text:find("no socket", 1, true))
        assert.is_truthy(text:find("## Wrong\n\n(unavailable: `fn` is not a function)", 1, true))
    end)

    it("links a task to its line when it carries an id, and to its note otherwise", function()
        note("tasks/active.md", {
            "- [x] with id #todo done:2026-09-08 10:00 ^k7q2aa",
            "- [x] without #todo done:2026-09-08 11:00",
        })
        note("daily/2026-09-08.md", { "# Day" })
        local range = week.range("", on(2026, 9, 12))
        local text = table.concat(week.digest_lines(range, week.notes(range)), "\n")
        assert.is_truthy(text:find("- ✓ with id #todo  ([[active#^k7q2aa]])", 1, true))
        assert.is_truthy(text:find("- ✓ without #todo  ([[active]])", 1, true))
    end)

    -- The digest gets pasted into the weekly note, which is scanned like any
    -- other: its task lines must not read as tasks there.
    it("writes task lines the scanner does not read as tasks", function()
        note("tasks/active.md", { "- [ ] open one #todo ^aa1111", "- [x] done one #todo done:2026-09-08 10:00 ^bb2222" })
        note("daily/2026-09-08.md", { "# Day", "- [ ] in the daily #todo" })
        local range = week.range("", on(2026, 9, 12))
        local lines = week.digest_lines(range, week.notes(range))
        note("weekly/2026-W37.md", lines)
        local found = 0
        for _, t in ipairs(require("fzfkasten.tasks").collect({ done = true, since_days = false })) do
            if t.rel == "weekly/2026-W37.md" then found = found + 1 end
        end
        assert.are.equal(0, found)
        assert.is_truthy(table.concat(lines, "\n"):find("- ☐ in the daily #todo  ([[2026-09-08]])", 1, true))
    end)

    it("can leave the tasks out and quote nothing", function()
        note("daily/2026-09-08.md", { "# Day", "- [x] done done:2026-09-08 10:00", "prose" })
        local range = week.range("", on(2026, 9, 12))
        local lines = week.digest_lines(range, week.notes(range), { tasks = false, lines = 0 })
        local text = table.concat(lines, "\n")
        assert.is_falsy(text:find("Finished", 1, true))
        assert.is_falsy(text:find("> ", 1, true))
    end)
end)

describe("the digest's folds", function()
    before_each(function()
        home = vim.fn.tempname()
        vim.fn.mkdir(home, "p")
        setup()
    end)

    after_each(function() vim.fn.delete(home, "rf") end)

    it("starts a fold at each ##, deeper per #, none at the title", function()
        vim.cmd("enew")
        vim.api.nvim_buf_set_lines(0, 0, -1, false, {
            "# 2026-W37", "", "2 notes", "", "## 09-08 Tue  [[a]]", "- Setup", "### deeper", "> quoted", "## 09-09 Wed  [[b]]",
        })
        local levels = {}
        for i = 1, 9 do levels[i] = week.foldexpr(i) end
        assert.are.same({ "0", "=", "=", "=", ">1", "=", ">2", "=", ">1" }, levels)
        vim.cmd("bwipeout!")
    end)

    -- A window that folded a note by `manual` (what nvim-ufo leaves behind)
    -- must fold the digest by its headings all the same.
    it("folds the digest by headings whatever the window was doing", function()
        note("daily/2026-09-08.md", { "# Day", "", "## One", "a", "b", "## Two", "c" })
        vim.wo.foldmethod = "manual"
        week.digest("2026-W37")
        assert.are.equal("expr", vim.wo.foldmethod)
        assert.is_truthy(vim.wo.foldexpr:find("fzfkasten.week", 1, true))
        local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
        local heading
        for i, l in ipairs(lines) do
            if l:match("^## 09%-08") then heading = i end
        end
        assert.is_number(heading)
        assert.are.equal(1, vim.fn.foldlevel(heading))
        -- Closed with zc, the section is one line; the next section is not in it.
        vim.api.nvim_win_set_cursor(0, { heading, 0 })
        vim.cmd("normal! zc")
        assert.are.equal(heading, vim.fn.foldclosed(heading))
        assert.is_true(vim.fn.foldclosedend(heading) > heading)
        assert.are.equal(-1, vim.fn.foldclosed(vim.fn.foldclosedend(heading) + 1))
        vim.cmd("bwipeout!")
    end)
end)
