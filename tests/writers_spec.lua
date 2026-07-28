-- The note-writing paths, and above all their refusals.
--
-- tasks_spec covers the string surgery and tasklist_spec drives the happy paths
-- through the keys. What neither covers is the code that decides *not* to write:
-- a buffer with unsaved changes, a line someone has edited since, a note that
-- has moved. That code is the only thing standing between a mis-press and a
-- lost line, and it fails silently when it fails -- you find out when the note
-- is already wrong.
--
-- So every refusal here asserts two things: that the call reported failure, and
-- that the file on disk is byte-for-byte what it was. The second is the one
-- that matters; a function can return false and still have written.

local config = require("fzfkasten.config")
local tasks = require("fzfkasten.tasks")

local home

local function setup(opts)
    home = vim.fn.tempname()
    vim.fn.mkdir(home, "p")
    config.setup(vim.tbl_deep_extend("force", {
        home = home,
        tasks = { require_tag = "todo", capture_note = "tasks/active.md" },
    }, opts or {}))
    tasks._test.reset_history()
end

local function cleanup()
    -- Wipe any note buffers a case opened, or the next case inherits them as
    -- "modified" and every writer refuses for the wrong reason.
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
        local name = vim.api.nvim_buf_get_name(b)
        if home and name:find(home, 1, true) == 1 then
            pcall(vim.api.nvim_buf_delete, b, { force = true })
        end
    end
    if home then vim.fn.delete(home, "rf") end
end

local function path(name)
    return home .. "/" .. name
end

local function note(name, lines)
    local full = path(name)
    vim.fn.mkdir(vim.fn.fnamemodify(full, ":h"), "p")
    vim.fn.writefile(lines, full)
    return full
end

local function read(name)
    return vim.fn.readfile(path(name))
end

-- Load a note into a buffer and dirty it without writing, which is the state
-- every writer is supposed to refuse to touch.
local function open_unsaved(name)
    local bufnr = vim.fn.bufadd(path(name))
    vim.fn.bufload(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { "- [ ] edited in the buffer #todo" })
    assert.is_true(vim.bo[bufnr].modified)
    return bufnr
end

describe("writers: refusing an unsaved buffer", function()
    after_each(cleanup)

    local WRITERS = {
        {
            name = "toggle_at",
            call = function() return tasks.toggle_at(path("n.md"), 1) end,
        },
        {
            name = "cancel_at",
            call = function() return tasks.cancel_at(path("n.md"), 1) end,
        },
        {
            name = "tag_at",
            call = function() return tasks.tag_at(path("n.md"), 2) end,
        },
    }

    for _, writer in ipairs(WRITERS) do
        it(writer.name .. " leaves the file alone", function()
            setup()
            note("n.md", { "- [ ] alpha #todo", "- [ ] untagged" })
            local before = read("n.md")
            open_unsaved("n.md")

            assert.is_false(writer.call())
            assert.are.same(before, read("n.md"))
        end)
    end

    it("add leaves the capture note alone", function()
        setup()
        note("tasks/active.md", { "- [ ] alpha #todo" })
        local before = read("tasks/active.md")
        open_unsaved("tasks/active.md")

        assert.is_false(tasks.add("something new"))
        assert.are.same(before, read("tasks/active.md"))
    end)

    it("undo leaves the file alone", function()
        setup()
        note("n.md", { "- [ ] alpha #todo" })
        assert.is_true(tasks.toggle_at(path("n.md"), 1))
        local after_toggle = read("n.md")
        open_unsaved("n.md")

        assert.is_false(tasks.undo())
        assert.are.same(after_toggle, read("n.md"))
    end)
end)

describe("writers: refusing a line that isn't there", function()
    after_each(cleanup)

    it("toggle_at refuses a missing file", function()
        setup()
        assert.is_false(tasks.toggle_at(path("nope.md"), 1))
    end)

    it("toggle_at refuses a line past the end", function()
        setup()
        note("n.md", { "- [ ] alpha #todo" })
        local before = read("n.md")
        assert.is_false(tasks.toggle_at(path("n.md"), 99))
        assert.are.same(before, read("n.md"))
    end)

    it("toggle_at refuses a line with no checkbox", function()
        setup()
        note("n.md", { "just prose" })
        local before = read("n.md")
        assert.is_false(tasks.toggle_at(path("n.md"), 1))
        assert.are.same(before, read("n.md"))
    end)

    -- `- [-]` is a decision, and there is a command that reverses it. Quietly
    -- reopening it here would undo that decision without being asked.
    it("toggle_at refuses a cancelled task", function()
        setup()
        note("n.md", { "- [-] ~~alpha #todo~~ cancelled:2026-07-20" })
        local before = read("n.md")
        assert.is_false(tasks.toggle_at(path("n.md"), 1))
        assert.are.same(before, read("n.md"))
    end)

    -- Dropping a task you finished is a contradiction, not something to guess at.
    it("cancel_at refuses a done task", function()
        setup()
        note("n.md", { "- [x] alpha #todo done:2026-07-20 10:00" })
        local before = read("n.md")
        assert.is_false(tasks.cancel_at(path("n.md"), 1))
        assert.are.same(before, read("n.md"))
    end)

    it("tag_at refuses a line that is not a task", function()
        setup()
        note("n.md", { "just prose" })
        local before = read("n.md")
        assert.is_false(tasks.tag_at(path("n.md"), 1))
        assert.are.same(before, read("n.md"))
    end)

    it("tag_at does nothing when the tag is already there", function()
        setup()
        note("n.md", { "- [ ] alpha #todo" })
        local before = read("n.md")
        assert.is_false(tasks.tag_at(path("n.md"), 1))
        assert.are.same(before, read("n.md"))
    end)

    it("tag_at refuses when require_tag is not set", function()
        setup({ tasks = { require_tag = false } })
        note("n.md", { "- [ ] alpha" })
        local before = read("n.md")
        assert.is_false(tasks.tag_at(path("n.md"), 1))
        assert.are.same(before, read("n.md"))
    end)
end)

describe("undo", function()
    after_each(cleanup)

    it("says so when there is nothing to undo", function()
        setup()
        assert.is_false(tasks.undo())
    end)

    it("puts a rewritten line back exactly", function()
        setup()
        note("n.md", { "- [ ] alpha #todo", "- [ ] beta #todo" })
        local before = read("n.md")
        assert.is_true(tasks.toggle_at(path("n.md"), 1))
        assert.are_not.same(before, read("n.md"))

        assert.is_true(tasks.undo())
        assert.are.same(before, read("n.md"))
    end)

    -- A capture added a line rather than rewriting one, so undoing it has to
    -- remove the line -- there is no earlier text to restore.
    it("deletes a captured line rather than restoring text", function()
        setup()
        note("tasks/active.md", { "- [ ] alpha #todo" })
        local before = read("tasks/active.md")
        assert.is_true(tasks.add("something new"))
        assert.are.equal(2, #read("tasks/active.md"))

        assert.is_true(tasks.undo())
        assert.are.same(before, read("tasks/active.md"))
    end)

    it("walks back through several edits, newest first", function()
        setup()
        note("n.md", { "- [ ] alpha #todo", "- [ ] beta #todo" })
        local before = read("n.md")
        assert.is_true(tasks.toggle_at(path("n.md"), 1))
        assert.is_true(tasks.toggle_at(path("n.md"), 2))

        assert.is_true(tasks.undo())
        assert.is_truthy(read("n.md")[1]:match("^%- %[x%]"))
        assert.is_truthy(read("n.md")[2]:match("^%- %[ %]"))
        assert.is_true(tasks.undo())
        assert.are.same(before, read("n.md"))
    end)

    -- Someone has edited that line since -- by hand, or the task moved. Their
    -- text is worth more than our undo, so the entry is dropped rather than
    -- applied, and the next undo reaches the one before it.
    it("refuses a line edited since, and drops the entry", function()
        setup()
        note("n.md", { "- [ ] alpha #todo", "- [ ] beta #todo" })
        assert.is_true(tasks.toggle_at(path("n.md"), 1))
        assert.is_true(tasks.toggle_at(path("n.md"), 2))

        local meddled = read("n.md")
        meddled[2] = "- [x] beta rewritten by hand #todo"
        vim.fn.writefile(meddled, path("n.md"))

        assert.is_false(tasks.undo())
        assert.are.same(meddled, read("n.md"))

        -- The refused entry is gone, so this reaches the edit before it.
        assert.is_true(tasks.undo())
        assert.is_truthy(read("n.md")[1]:match("^%- %[ %] alpha"))
        assert.are.equal("- [x] beta rewritten by hand #todo", read("n.md")[2])
    end)

    it("refuses when the note has lost the line entirely", function()
        setup()
        note("n.md", { "- [ ] alpha #todo", "- [ ] beta #todo" })
        assert.is_true(tasks.toggle_at(path("n.md"), 2))
        vim.fn.writefile({ "- [ ] alpha #todo" }, path("n.md"))

        assert.is_false(tasks.undo())
        assert.are.same({ "- [ ] alpha #todo" }, read("n.md"))
    end)

    it("refuses when the note is gone, without erroring", function()
        setup()
        note("n.md", { "- [ ] alpha #todo" })
        assert.is_true(tasks.toggle_at(path("n.md"), 1))
        vim.fn.delete(path("n.md"))

        assert.has_no.errors(function() tasks.undo() end)
    end)

    -- The stack is bounded, so a long session cannot grow it without limit.
    -- What that costs is the oldest edits: past the cap they are not coming
    -- back, which is worth knowing rather than discovering.
    -- The cap is written out here rather than read from the module. Taking the
    -- expected number from the code under test would make this pass for any
    -- value it happened to hold, including one that never discards anything --
    -- which is exactly the change worth catching.
    it("keeps only the last 50 edits", function()
        setup()
        local max = 50
        assert.are.equal(max, tasks._test.HISTORY_MAX)
        local lines = {}
        for i = 1, max + 5 do
            lines[i] = "- [ ] task " .. i .. " #todo"
        end
        note("n.md", lines)
        for i = 1, max + 5 do
            assert.is_true(tasks.toggle_at(path("n.md"), i))
        end
        assert.are.equal(max, tasks._test.history_size())

        local undone = 0
        while tasks.undo() do
            undone = undone + 1
        end
        assert.are.equal(max, undone)
        -- The five oldest were pushed off the stack and stayed done.
        for i = 1, 5 do
            assert.is_truthy(read("n.md")[i]:match("^%- %[x%]"), "line " .. i .. " came back")
        end
        for i = 6, max + 5 do
            assert.is_truthy(read("n.md")[i]:match("^%- %[ %]"), "line " .. i .. " did not come back")
        end
    end)
end)

describe("add", function()
    after_each(cleanup)

    -- First capture into a fresh vault: neither the note nor its directory
    -- exists, and having to create them by hand would defeat "record it from
    -- anywhere without thinking about where it goes".
    it("creates the capture note and its directory", function()
        setup()
        assert.are.equal(0, vim.fn.isdirectory(home .. "/tasks"))

        assert.is_true(tasks.add("first ever task"))
        assert.are.same({ "- [ ] first ever task #todo" }, read("tasks/active.md"))
    end)

    it("appends the due date the caller resolved", function()
        setup()
        assert.is_true(tasks.add("something", "2026-08-01"))
        assert.are.equal("- [ ] something #todo due:2026-08-01", read("tasks/active.md")[1])
    end)

    it("refuses blank text without creating anything", function()
        setup()
        assert.is_false(tasks.add("   "))
        assert.are.equal(0, vim.fn.filereadable(path("tasks/active.md")))
    end)

    it("refuses when no capture note is configured", function()
        setup({ tasks = { capture_note = false, always = {} } })
        assert.is_false(tasks.add("something"))
    end)

    -- `always[1]` is already scanned regardless of since_days, so a capture
    -- into it always surfaces; a second setting for the same file would only
    -- invite the two to disagree.
    it("falls back to the first always entry", function()
        setup({ tasks = { capture_note = false, always = { "tasks/standing.md" } } })
        assert.is_true(tasks.add("something"))
        assert.are.same({ "- [ ] something #todo" }, read("tasks/standing.md"))
    end)
end)
