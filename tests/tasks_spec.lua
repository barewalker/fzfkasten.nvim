-- Characterisation tests for the fragile string surgery in tasks.lua.
--
-- Every case here is a behaviour that was verified by hand and has regressed at
-- least once: the strike wrapping inside the priority, a cancelled line being
-- bulleted a second time, a reopened task keeping its stamp. They exist so the
-- next change to this file fails loudly instead of quietly rewriting notes
-- wrong. Stamped output (done:/cancelled:) is asserted by pattern, since the
-- date is today's.

local config = require("fzfkasten.config")
local tasks = require("fzfkasten.tasks")
local t = tasks._test

-- Defaults are enough for most cases; require_tag is set where the inbox split
-- matters. Reset before each so one test's setup can't leak into the next.
local function setup(opts)
    config.setup(vim.tbl_deep_extend("force", { home = "/tmp/fzfkasten-test" }, opts or {}))
end

describe("split_checkbox", function()
    before_each(function() setup() end)

    it("splits an open checkbox into checkbox, mark and text", function()
        local cb = t.split_checkbox("- [ ] foo")
        assert.are.same({ before = "- [", mark = " ", after = "]", rest = " foo" }, cb)
    end)

    it("reads the mark of a done and a cancelled box", function()
        assert.are.equal("x", t.split_checkbox("- [x] foo").mark)
        assert.are.equal("-", t.split_checkbox("- [-] foo").mark)
    end)

    it("keeps the indent in `before`", function()
        assert.are.equal("  - [", t.split_checkbox("  - [ ] foo").before)
    end)

    it("accepts a `*` bullet", function()
        assert.is_not_nil(t.split_checkbox("* [ ] foo"))
    end)

    it("is nil on prose and on a bare bullet", function()
        assert.is_nil(t.split_checkbox("just prose"))
        assert.is_nil(t.split_checkbox("- a bullet, no box"))
    end)
end)

describe("toggle_line", function()
    before_each(function() setup() end)

    it("opens to done and stamps when", function()
        local out = t.toggle_line("- [ ] foo")
        assert.is_truthy(out:match("^%- %[x%] foo done:%d%d%d%d%-%d%d%-%d%d %d%d:%d%d$"))
    end)

    it("reopens to open and drops the stamp with no residue", function()
        assert.are.equal("- [ ] foo", t.toggle_line("- [x] foo done:2026-07-17 10:00"))
    end)

    it("refuses a cancelled task rather than silently reopening it", function()
        local out, why = t.toggle_line("- [-] foo")
        assert.is_nil(out)
        assert.are.equal("cancelled", why)
    end)

    it("is nil when there is no checkbox", function()
        assert.is_nil(t.toggle_line("no checkbox here"))
    end)

    it("does not accumulate stamps across a reopen then complete", function()
        local done = t.toggle_line("- [ ] foo")
        local reopened = t.toggle_line(done)
        assert.are.equal("- [ ] foo", reopened)
    end)
end)

describe("cancel_line", function()
    before_each(function() setup() end)

    it("cancels an open task: mark, strike and stamp", function()
        local out = t.cancel_line("- [ ] foo")
        assert.is_truthy(out:match("^%- %[%-%] ~~foo~~ cancelled:%d%d%d%d%-%d%d%-%d%d$"))
    end)

    it("wraps the strike inside the priority, so cancelling isn't itself hidden", function()
        local out = t.cancel_line("- [ ] (A) foo")
        assert.is_truthy(out:match("^%- %[%-%] %(A%) ~~foo~~ cancelled:%d%d%d%d%-%d%d%-%d%d$"))
    end)

    it("reopens a cancelled task, removing strike and stamp", function()
        assert.are.equal("- [ ] foo", t.cancel_line("- [-] ~~foo~~ cancelled:2026-07-17"))
    end)

    it("reopening keeps the priority in front", function()
        assert.are.equal("- [ ] (A) foo",
            t.cancel_line("- [-] (A) ~~foo~~ cancelled:2026-07-17"))
    end)

    it("refuses a done task -- dropping what you finished is a contradiction", function()
        local out, why = t.cancel_line("- [x] foo")
        assert.is_nil(out)
        assert.are.equal("done", why)
    end)

    it("is nil on a line with no checkbox", function()
        local out, why = t.cancel_line("just prose")
        assert.is_nil(out)
        assert.are.equal("no checkbox", why)
    end)

    it("treats an empty checkbox as nothing to cancel", function()
        local out, why = t.cancel_line("- [ ]   ")
        assert.is_nil(out)
        assert.are.equal("no checkbox", why)
    end)
end)

describe("tag_line", function()
    before_each(function() setup({ tasks = { require_tag = "todo" } }) end)

    it("promotes prose to a tagged checkbox", function()
        assert.are.equal("- [ ] buy milk #todo", t.tag_line("buy milk", "todo"))
    end)

    it("promotes a bare bullet without doubling it", function()
        assert.are.equal("- [ ] buy milk #todo", t.tag_line("- buy milk", "todo"))
    end)

    it("tags an existing open checkbox in place", function()
        assert.are.equal("- [ ] foo #todo", t.tag_line("- [ ] foo", "todo"))
    end)

    it("tags a cancelled task without bulleting it a second time", function()
        assert.are.equal("- [-] ~~foo~~ cancelled:2026-07-17 #todo",
            t.tag_line("- [-] ~~foo~~ cancelled:2026-07-17", "todo"))
    end)

    it("keeps the indent of an indented bullet", function()
        assert.are.equal("  - [ ] foo #todo", t.tag_line("  - foo", "todo"))
    end)

    it("is nil when already tagged", function()
        assert.is_nil(t.tag_line("- [ ] foo #todo", "todo"))
    end)

    it("is nil on a blank or whitespace-only line", function()
        assert.is_nil(t.tag_line("", "todo"))
        assert.is_nil(t.tag_line("   ", "todo"))
    end)
end)

describe("valid_due", function()
    it("accepts an ISO day and an ISO day+time", function()
        assert.is_true(t.valid_due("2026-07-25"))
        assert.is_true(t.valid_due("2026-07-25T15:00"))
    end)

    it("rejects relative forms, seconds, a timezone and a space separator", function()
        assert.is_false(t.valid_due("+7d"))
        assert.is_false(t.valid_due("fri"))
        assert.is_false(t.valid_due("2026-07-25 15:00"))
        assert.is_false(t.valid_due("2026-07-25T15:00:00"))
        assert.is_false(t.valid_due("2026-07-25T15:00Z"))
    end)
end)

describe("due_line", function()
    before_each(function() setup({ tasks = { require_tag = "todo" } }) end)

    it("appends a due to an open task, after the text", function()
        assert.are.equal("- [ ] foo #todo due:2026-07-25",
            t.due_line("- [ ] foo #todo", "2026-07-25"))
    end)

    it("keeps a day+time due verbatim", function()
        assert.are.equal("- [ ] foo due:2026-07-25T15:00",
            t.due_line("- [ ] foo", "2026-07-25T15:00"))
    end)

    it("replaces an existing due rather than writing a second one", function()
        assert.are.equal("- [ ] foo #todo due:2026-07-25",
            t.due_line("- [ ] foo #todo due:2026-07-20", "2026-07-25"))
    end)

    it("clears the due when given no date, leaving no dangling space", function()
        assert.are.equal("- [ ] foo #todo",
            t.due_line("- [ ] foo #todo due:2026-07-20", ""))
    end)

    it("leaves the priority in front of the due", function()
        assert.are.equal("- [ ] (A) foo due:2026-07-25",
            t.due_line("- [ ] (A) foo", "2026-07-25"))
    end)

    it("refuses a done or a cancelled task", function()
        local d, dw = t.due_line("- [x] foo", "2026-07-25")
        assert.is_nil(d)
        assert.are.equal("not open", dw)
        local c, cw = t.due_line("- [-] ~~foo~~ cancelled:2026-07-17", "2026-07-25")
        assert.is_nil(c)
        assert.are.equal("not open", cw)
    end)

    it("refuses a malformed date", function()
        local out, why = t.due_line("- [ ] foo", "next friday")
        assert.is_nil(out)
        assert.are.equal("bad date", why)
    end)

    it("is nil on a line with no checkbox", function()
        local out, why = t.due_line("just prose", "2026-07-25")
        assert.is_nil(out)
        assert.are.equal("no checkbox", why)
    end)
end)

describe("has_tag", function()
    it("matches a whole tag but not a longer one", function()
        assert.is_true(t.has_tag("do the thing #todo", "todo"))
        assert.is_false(t.has_tag("do the thing #todos", "todo"))
        assert.is_false(t.has_tag("no tag at all", "todo"))
    end)
end)

describe("unstrike", function()
    it("removes a full wrap only", function()
        assert.are.equal("foo", t.unstrike("~~foo~~", "~~"))
        assert.are.equal("~~foo", t.unstrike("~~foo", "~~"))
        assert.are.equal("foo", t.unstrike("foo", "~~"))
    end)

    it("returns the text untouched when the wrap is empty or false", function()
        assert.are.equal("~~foo~~", t.unstrike("~~foo~~", ""))
        assert.are.equal("~~foo~~", t.unstrike("~~foo~~", false))
    end)
end)

describe("parse_task_text", function()
    before_each(function() setup() end)

    it("pulls out priority and due (due stays in text, stripped only at display)", function()
        local text, priority, due = t.parse_task_text("(A) foo due:2026-07-25", config.options.tasks)
        assert.are.equal("A", priority)
        assert.are.equal("2026-07-25", due)
        assert.is_truthy(text:match("foo"))
    end)

    it("captures a due date with a time", function()
        local _, _, due = t.parse_task_text("foo due:2026-07-25T15:00", config.options.tasks)
        assert.are.equal("2026-07-25T15:00", due)
    end)

    it("strips a cancelled strike and stamp, returning the bare text and date", function()
        local text, _, _, _, cancelled_at =
            t.parse_task_text("~~foo~~ cancelled:2026-07-17", config.options.tasks)
        assert.are.equal("foo", text)
        assert.are.equal("2026-07-17", cancelled_at)
    end)

    it("strips a done stamp and reports done_at", function()
        local text, _, _, done_at =
            t.parse_task_text("foo done:2026-07-17 10:00", config.options.tasks)
        assert.are.equal("foo", text)
        assert.are.equal("2026-07-17 10:00", done_at)
    end)
end)

describe("parse_frontmatter", function()
    it("reads flat key: value pairs and reports the closing line", function()
        local fm, fm_end = t.parse_frontmatter({ "---", "title: X", "date: 2026-01-01", "---", "body" })
        assert.are.equal("X", fm.title)
        assert.are.equal("2026-01-01", fm.date)
        assert.are.equal(4, fm_end)
    end)

    it("reports no block when the note doesn't open with one", function()
        local fm, fm_end = t.parse_frontmatter({ "body", "more" })
        assert.are.same({}, fm)
        assert.are.equal(0, fm_end)
    end)

    it("treats an unterminated block as no frontmatter", function()
        local fm, fm_end = t.parse_frontmatter({ "---", "title: X", "no close" })
        assert.are.same({}, fm)
        assert.are.equal(0, fm_end)
    end)
end)

describe("scannable_lines", function()
    it("scope=all: skips frontmatter and fenced blocks", function()
        setup()
        local lines = { "---", "t: x", "---", "- [ ] a", "```", "- [ ] b", "```", "- [ ] c" }
        local s = t.scannable_lines(lines, 3)
        assert.is_true(s[4])
        assert.is_nil(s[6]) -- inside the fence
        assert.is_true(s[8])
    end)

    it("scope=headings: only under a heading that starts a task list", function()
        setup({ tasks = { scope = "headings" } })
        local lines = { "# Notes", "- [ ] loose", "## Tasks", "- [ ] real" }
        local s = t.scannable_lines(lines, 0)
        assert.is_nil(s[2]) -- under a non-task heading
        assert.is_true(s[4]) -- under "Tasks"
    end)
end)

describe("sort_tasks", function()
    before_each(function() setup() end)

    it("orders by priority, then due, then path, then line", function()
        local a = { priority = nil, due = "2026-07-25", path = "b", lineno = 1 }
        local b = { priority = "A", due = nil, path = "z", lineno = 9 }
        local c = { priority = nil, due = nil, path = "a", lineno = 1 }
        local d = { priority = nil, due = "2026-07-20", path = "a", lineno = 2 }
        local sorted = t.sort_tasks({ a, b, c, d })
        assert.are.same({ b, d, a, c }, sorted)
    end)
end)

describe("note_date", function()
    before_each(function() setup() end)

    it("reads the date from the filename first", function()
        assert.are.equal("2026-01-15", t.note_date("/x/2026-01-15-standup.md", {}, {}))
    end)

    it("falls back to a frontmatter date key", function()
        assert.are.equal("2026-02-01", t.note_date("/x/standup.md", {}, { date = "2026-02-01" }))
    end)

    it("is nil when the note records no date", function()
        assert.is_nil(t.note_date("/x/standup.md", {}, {}))
    end)
end)
