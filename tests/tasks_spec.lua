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

describe("new_task_line", function()
    it("builds a bare checkbox when no tag is required", function()
        setup()
        assert.are.equal("- [ ] buy milk", t.new_task_line("buy milk", nil))
    end)

    it("appends the require_tag so the capture lands in the task list", function()
        setup({ tasks = { require_tag = "todo" } })
        assert.are.equal("- [ ] buy milk #todo", t.new_task_line("buy milk", "todo"))
    end)

    it("does not double a tag the text already carries", function()
        setup({ tasks = { require_tag = "todo" } })
        assert.are.equal("- [ ] buy milk #todo", t.new_task_line("buy milk #todo", "todo"))
    end)

    it("trims surrounding whitespace off the text", function()
        setup()
        assert.are.equal("- [ ] buy milk", t.new_task_line("  buy milk  ", nil))
    end)

    it("is nil on blank or whitespace-only text", function()
        setup()
        assert.is_nil(t.new_task_line("", nil))
        assert.is_nil(t.new_task_line("   ", "todo"))
        assert.is_nil(t.new_task_line(nil, nil))
    end)

    it("honours a custom new_checkbox literal", function()
        setup({ tasks = { new_checkbox = "* [ ] " } })
        assert.are.equal("* [ ] buy milk", t.new_task_line("buy milk", nil))
    end)

    it("appends a due date last, past the text and tag", function()
        setup({ tasks = { require_tag = "todo" } })
        assert.are.equal("- [ ] buy milk #todo due:2026-07-25",
            t.new_task_line("buy milk", "todo", "2026-07-25"))
    end)

    it("omits the due when it is nil or empty", function()
        setup()
        assert.are.equal("- [ ] buy milk", t.new_task_line("buy milk", nil, nil))
        assert.are.equal("- [ ] buy milk", t.new_task_line("buy milk", nil, ""))
    end)
end)

describe("resolve_due", function()
    -- A fixed Wednesday, so the relative forms resolve to known days.
    local now = os.time({ year = 2026, month = 7, day = 22, hour = 12, min = 0, sec = 0 })

    it("passes an absolute ISO day and day+time through untouched", function()
        assert.are.equal("2026-07-25", t.resolve_due("2026-07-25", now))
        assert.are.equal("2026-07-25T15:00", t.resolve_due("2026-07-25T15:00", now))
    end)

    it("resolves today and tomorrow, in English and Japanese", function()
        assert.are.equal("2026-07-22", t.resolve_due("today", now))
        assert.are.equal("2026-07-23", t.resolve_due("tomorrow", now))
        assert.are.equal("2026-07-23", t.resolve_due("明日", now))
        assert.are.equal("2026-07-24", t.resolve_due("明後日", now))
    end)

    it("resolves +Nd and Nw offsets", function()
        assert.are.equal("2026-07-25", t.resolve_due("+3d", now))
        assert.are.equal("2026-07-25", t.resolve_due("3d", now))
        assert.are.equal("2026-08-05", t.resolve_due("2w", now))
    end)

    it("resolves a weekday to the nearest day at or after now", function()
        -- now is a Wednesday.
        assert.are.equal("2026-07-22", t.resolve_due("wed", now)) -- today
        assert.are.equal("2026-07-24", t.resolve_due("fri", now)) -- this week
        assert.are.equal("2026-07-27", t.resolve_due("mon", now)) -- next week
        assert.are.equal("2026-07-24", t.resolve_due("金", now))
    end)

    it("is nil on a blank spec and on one it doesn't recognise", function()
        assert.is_nil(t.resolve_due("", now))
        assert.is_nil(t.resolve_due(nil, now))
        assert.is_nil(t.resolve_due("someday", now))
        assert.is_nil(t.resolve_due("2026-13-40nonsense", now))
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

describe("indent_width", function()
    it("counts spaces, and a tab as four columns", function()
        assert.are.equal(0, t.indent_width("- [ ] a"))
        assert.are.equal(2, t.indent_width("  - [ ] a"))
        assert.are.equal(4, t.indent_width("\t- [ ] a"))
        assert.are.equal(6, t.indent_width("\t  - [ ] a"))
    end)
end)

describe("bullet_text", function()
    it("reads a plain list item, ordered or not", function()
        assert.are.equal("context", t.bullet_text("- context"))
        assert.are.equal("context", t.bullet_text("  * context"))
        assert.are.equal("step one", t.bullet_text("    1. step one"))
    end)

    it("is nil for prose and headings", function()
        assert.is_nil(t.bullet_text("just a line"))
        assert.is_nil(t.bullet_text("# heading"))
    end)

    -- Checkboxes match the bullet shape too, so collect() tests for a checkbox
    -- first; this pins that the overlap is real and not an accident.
    it("also matches a checkbox, which callers rule out first", function()
        assert.are.equal("[ ] a", t.bullet_text("- [ ] a"))
    end)
end)

describe("truncate", function()
    it("leaves text that fits", function()
        assert.are.equal("short", t.truncate("short", 40))
    end)

    it("cuts by display column, not character, and marks the cut", function()
        -- Each of these is two columns wide, so eight of them fill 16 columns.
        local out = t.truncate("あいうえおかきくけこ", 10)
        assert.is_true(vim.fn.strdisplaywidth(out) <= 10)
        assert.are.equal("…", out:sub(-3))
    end)
end)

-- Nesting is the one behaviour here that needs files on disk: the ancestor
-- stack is built while scanning a note, so there is no pure helper to poke at.
describe("collect: nested tasks", function()
    local home

    local function note(name, lines)
        vim.fn.writefile(lines, home .. "/" .. name)
    end

    before_each(function()
        home = vim.fn.tempname()
        vim.fn.mkdir(home, "p")
        setup({ home = home, tasks = { require_tag = "todo" } })
    end)

    after_each(function()
        vim.fn.delete(home, "rf")
    end)

    it("gives a subtask its parent's tag", function()
        note("n.md", {
            "- [ ] parent #todo",
            "  - [ ] child",
        })
        local out = tasks.collect()
        assert.are.equal(2, #out)
        assert.are.equal("parent #todo", out[1].text)
        assert.are.equal("child", out[2].text)
        assert.are.equal(0, out[1].depth)
        assert.are.equal(1, out[2].depth)
        assert.are.equal(out[1], out[2].parent)
    end)

    it("carries the tag down through a plain bullet", function()
        note("n.md", {
            "- [ ] parent #todo",
            "  - a note about it",
            "    - [ ] child",
        })
        local out = tasks.collect()
        assert.are.equal(2, #out)
        assert.are.equal("child", out[2].text)
        -- The bullet is context, not a level: the child is still the parent's.
        assert.are.equal(out[1], out[2].parent)
        assert.are.equal("a note about it", out[2].context)
    end)

    -- The whole point of require_tag: a meeting note's action items for other
    -- people are nested checkboxes too, and must stay out of the task list.
    it("does not invent a tag the parent never had", function()
        note("n.md", {
            "- [ ] someone else's item",
            "  - [ ] their step",
        })
        assert.are.equal(0, #tasks.collect())
        assert.are.equal(2, #tasks.collect({ inbox = true }))
    end)

    it("keeps an inherited subtask out of the inbox", function()
        note("n.md", {
            "- [ ] parent #todo",
            "  - [ ] child",
        })
        assert.are.equal(0, #tasks.collect({ inbox = true }))
    end)

    it("counts a parent's subtasks and how many are settled", function()
        note("n.md", {
            "- [ ] parent #todo",
            "  - [x] done step",
            "  - [-] ~~dropped step~~",
            "  - [ ] open step",
        })
        local out = tasks.collect()
        assert.are.equal(3, out[1].children)
        assert.are.equal(2, out[1].children_closed)
    end)

    it("records the bullet above a task that tagged itself", function()
        note("n.md", {
            "- how hard is it to pull the holder off",
            "  - [ ] build the jig #todo",
        })
        local out = tasks.collect()
        assert.are.equal(1, #out)
        assert.are.equal("how hard is it to pull the holder off", out[1].context)
        assert.is_nil(out[1].parent)
    end)

    it("marks a subtask whose parent the filters dropped", function()
        note("n.md", {
            "- [x] parent #todo",
            "  - [ ] child",
        })
        local out = tasks.collect()
        assert.are.equal(1, #out)
        assert.are.equal("child", out[1].text)
        assert.is_true(out[1].orphaned)
    end)

    it("outdenting closes the parent", function()
        note("n.md", {
            "- [ ] parent #todo",
            "  - [ ] child",
            "- [ ] sibling #todo",
        })
        local out = tasks.collect()
        assert.are.equal(3, #out)
        local sibling = vim.tbl_filter(function(x) return x.text == "sibling #todo" end, out)[1]
        assert.are.equal(0, sibling.depth)
        assert.is_nil(sibling.parent)
    end)

    -- Sorting a subtask on its own priority would scatter the steps of one job
    -- across the list; they belong under the item they are steps of.
    it("keeps subtasks under their parent whatever their own priority", function()
        note("n.md", {
            "- [ ] (C) late job #todo",
            "  - [ ] (A) urgent step",
            "- [ ] (B) other job #todo",
        })
        local out = tasks.collect()
        -- The priority is parsed out of the text into its own field, so it is
        -- gone from what is compared here; `sorted` below asserts it was read.
        local texts = vim.tbl_map(function(x) return x.text end, out)
        assert.are.same({ "other job #todo", "late job #todo", "urgent step" }, texts)
        local sorted = vim.tbl_map(function(x) return x.priority end, out)
        assert.are.same({ "B", "C", "A" }, sorted)
    end)
end)

describe("to_entry", function()
    before_each(function() setup({ tasks = { require_tag = "todo" } }) end)

    it("indents a subtask under its parent", function()
        local parent = { rel = "n.md", lineno = 1, text = "parent #todo", depth = 0 }
        local child = { rel = "n.md", lineno = 2, text = "child", depth = 1, parent = parent }
        assert.are.equal("n.md:2:   ↳ child", t.to_entry(child))
    end)

    it("shows how many subtasks are settled", function()
        local task = { rel = "n.md", lineno = 1, text = "job #todo",
            children = 2, children_closed = 1 }
        assert.are.equal("n.md:1: job  [1/2]", t.to_entry(task))
    end)

    it("spells out the context when there is no parent row above", function()
        local task = { rel = "n.md", lineno = 2, text = "build the jig #todo",
            depth = 1, context = "how hard is it to pull off" }
        assert.are.equal("n.md:2: build the jig  ← how hard is it to pull off",
            t.to_entry(task))
    end)

    it("spells out the parent of an orphaned subtask instead of indenting it", function()
        local parent = { rel = "n.md", lineno = 1, text = "parent #todo" }
        local task = { rel = "n.md", lineno = 2, text = "child", depth = 1,
            parent = parent, context = "parent #todo", orphaned = true }
        assert.are.equal("n.md:2: child  ← parent", t.to_entry(task))
    end)
end)

describe("next_sort", function()
    it("cycles through the modes and wraps back to the default", function()
        assert.are.equal("due", t.next_sort("priority"))
        assert.are.equal("added", t.next_sort("due"))
        assert.are.equal("priority", t.next_sort("added"))
    end)

    it("moves off the default when the mode is unset or unknown", function()
        assert.are.equal("due", t.next_sort(nil))
        assert.are.equal("due", t.next_sort("nonsense"))
    end)
end)

describe("sort_tasks: modes", function()
    before_each(function() setup() end)

    -- Named for what each one is: `urgent` has the nearer due date but no
    -- priority, `flagged` the priority but no due, `oldest` neither but the
    -- earliest note.
    local function fixture()
        return {
            urgent = { due = "2026-07-20", path = "b.md", lineno = 2, date = "2026-07-10" },
            flagged = { priority = "A", path = "c.md", lineno = 3, date = "2026-07-11" },
            oldest = { path = "a.md", lineno = 1, date = "2026-07-01" },
        }
    end

    it("priority: what you flagged first, then what runs out first", function()
        local f = fixture()
        assert.are.same({ f.flagged, f.urgent, f.oldest },
            t.sort_tasks({ f.oldest, f.urgent, f.flagged }, "priority"))
    end)

    it("due: what runs out first, whatever you flagged", function()
        local f = fixture()
        assert.are.same({ f.urgent, f.flagged, f.oldest },
            t.sort_tasks({ f.oldest, f.urgent, f.flagged }, "due"))
    end)

    it("added: the order they were written down", function()
        local f = fixture()
        assert.are.same({ f.oldest, f.urgent, f.flagged },
            t.sort_tasks({ f.flagged, f.urgent, f.oldest }, "added"))
    end)

    it("reverse flips whichever mode is in force", function()
        local f = fixture()
        assert.are.same({ f.oldest, f.urgent, f.flagged },
            t.sort_tasks({ f.oldest, f.urgent, f.flagged }, "priority", true))
        assert.are.same({ f.flagged, f.urgent, f.oldest },
            t.sort_tasks({ f.flagged, f.urgent, f.oldest }, "added", true))
    end)

    -- A missing due date means "not urgent", not "top of the list" -- the
    -- sentinel has to sort last, or every undated task would drown the ones
    -- that actually run out.
    it("sorts a task with no due date last", function()
        local dated = { due = "2026-07-20", path = "a.md", lineno = 1 }
        local undated = { path = "a.md", lineno = 2 }
        assert.are.same({ dated, undated }, t.sort_tasks({ undated, dated }, "due"))
    end)

    it("defaults to priority when the mode is unknown", function()
        local f = fixture()
        assert.are.same(t.sort_tasks({ f.oldest, f.urgent, f.flagged }, "priority"),
            t.sort_tasks({ f.oldest, f.urgent, f.flagged }, "nonsense"))
    end)
end)

describe("collect: sorting a nested list", function()
    local home

    before_each(function()
        home = vim.fn.tempname()
        vim.fn.mkdir(home, "p")
        setup({ home = home, tasks = { require_tag = "todo" } })
        vim.fn.writefile({
            "---", "date: 2026-07-01", "---",
            "- [ ] (C) late job #todo",
            "  - [ ] first step",
            "  - [ ] second step",
            "- [ ] (A) urgent job #todo",
        }, home .. "/n.md")
    end)

    after_each(function() vim.fn.delete(home, "rf") end)

    local function texts(opts)
        return vim.tbl_map(function(x) return x.text end, tasks.collect(opts))
    end

    it("keeps steps under their job in every mode", function()
        assert.are.same({ "urgent job #todo", "late job #todo", "first step", "second step" },
            texts({ sort = "priority" }))
        assert.are.same({ "late job #todo", "first step", "second step", "urgent job #todo" },
            texts({ sort = "added" }))
    end)

    -- Reversing points the list the other way; it does not scramble the steps
    -- of a job, which are written in the order they are meant to be done.
    it("reverses the jobs but not the steps within one", function()
        assert.are.same({ "late job #todo", "first step", "second step", "urgent job #todo" },
            texts({ sort = "priority", reverse = true }))
    end)
end)
