-- The task list buffer: what it draws, and that its keys reach the notes.
--
-- The point of this buffer is that the actions are plain unmodified letters and
-- everything else is Vim's, so the cases below press the letters rather than
-- calling the functions -- a mapping that silently failed to attach would
-- otherwise pass.

local config = require("fzfkasten.config")
local tasklist = require("fzfkasten.tasklist")

local home

local function setup(opts)
    home = vim.fn.tempname()
    vim.fn.mkdir(home, "p")
    config.setup(vim.tbl_deep_extend("force", {
        home = home,
        tasks = { require_tag = "todo" },
    }, opts or {}))
    tasklist._test.reset()
end

local function note(name, lines)
    vim.fn.writefile(lines, home .. "/" .. name)
end

local function read(name)
    return vim.fn.readfile(home .. "/" .. name)
end

local function lines()
    return vim.api.nvim_buf_get_lines(0, 0, -1, false)
end

local function press(key)
    vim.api.nvim_feedkeys(vim.keycode(key), "x", false)
end

-- Put the cursor on the row whose text contains `needle`.
--
-- `nvim_win_set_cursor` schedules CursorMoved rather than firing it, and a
-- headless run never reaches the loop iteration that would, so the preview
-- would never update here. Firing it explicitly still goes through the autocmd
-- the list registers, so what is under test is the real callback.
local function goto_row(needle)
    for i, line in ipairs(lines()) do
        if line:find(needle, 1, true) then
            vim.api.nvim_win_set_cursor(0, { i, 0 })
            local bufnr = tasklist._test.bufnr()
            if bufnr then
                vim.api.nvim_exec_autocmds("CursorMoved", { buffer = bufnr })
            end
            return i
        end
    end
    error("no row matching " .. needle)
end

-- Plenary's busted only takes `after_each` inside a `describe` (it appends to
-- `current_after_each[#current_description]`, which is nil at the top level),
-- so each block registers this itself.
local function cleanup()
    tasklist._test.reset()
    if home then vim.fn.delete(home, "rf") end
end

describe("tasklist: drawing", function()
    after_each(cleanup)

    it("heads the list with what it is showing and how many", function()
        setup()
        note("n.md", { "- [ ] alpha #todo", "- [ ] beta #todo" })
        tasklist.open()
        assert.are.equal("Tasks — 2   ·   priority", lines()[1])
        assert.are.equal("", lines()[2])
    end)

    -- Listed, so a bufferline shows it as a tab and you switch back to it like
    -- any open file. Having to reopen a view you keep glancing at is the
    -- friction this removes.
    it("sits in the buffer list, so a bufferline shows it", function()
        setup()
        note("n.md", { "- [ ] alpha #todo" })
        tasklist.open()
        assert.is_true(vim.bo.buflisted)
        local listed = vim.tbl_map(function(b) return b.bufnr end,
            vim.fn.getbufinfo({ buflisted = 1 }))
        assert.is_true(vim.tbl_contains(listed, tasklist._test.bufnr()))
    end)

    it("stays out of the buffer list when listed = false", function()
        setup({ tasks = { list = { listed = false } } })
        note("n.md", { "- [ ] alpha #todo" })
        tasklist.open()
        assert.is_false(vim.bo.buflisted)
    end)

    it("is a scratch buffer you cannot type into", function()
        setup()
        note("n.md", { "- [ ] alpha #todo" })
        tasklist.open()
        assert.are.equal("nofile", vim.bo.buftype)
        assert.is_false(vim.bo.modifiable)
        assert.are.equal("fzfkasten-tasks", vim.bo.filetype)
    end)

    it("draws subtasks under their parent, with its progress", function()
        setup()
        note("n.md", {
            "- [ ] parent #todo",
            "  - [x] step one",
            "  - [ ] step two",
        })
        tasklist.open()
        assert.are.equal("parent  [1/2]", lines()[3])
        assert.are.equal("  ↳ step two", lines()[4])
    end)

    it("says so rather than drawing an empty list", function()
        setup()
        note("n.md", { "- [x] all done #todo" })
        tasklist.open()
        assert.are.equal("  No open tasks.", lines()[3])
    end)

    -- Every action reads the task off the cursor's row, so a heading or a blank
    -- line has to map to nothing at all.
    it("maps only task rows, not the heading or the blank", function()
        setup()
        note("n.md", { "- [ ] alpha #todo" })
        tasklist.open()
        local rows = tasklist._test.rows()
        assert.is_nil(rows[1])
        assert.is_nil(rows[2])
        assert.are.equal("alpha #todo", rows[3].text)
    end)
end)

describe("tasklist: keys reach the notes", function()
    after_each(cleanup)

    before_each(function()
        setup()
        note("n.md", { "- [ ] alpha #todo", "- [ ] beta #todo" })
        tasklist.open()
    end)

    it("x ticks the task off in its note", function()
        goto_row("alpha")
        press("x")
        assert.is_truthy(read("n.md")[1]:match("^%- %[x%] alpha #todo done:"))
    end)

    it("u puts back what x wrote", function()
        goto_row("alpha")
        press("x")
        press("u")
        assert.are.equal("- [ ] alpha #todo", read("n.md")[1])
    end)

    it("c drops the task but keeps the line", function()
        goto_row("beta")
        press("c")
        -- The tag is part of the task's text, so it goes inside the strike.
        assert.is_truthy(read("n.md")[2]:match("^%- %[%-%] ~~beta #todo~~ cancelled:"))
    end)

    it("the list redraws itself after an action", function()
        goto_row("alpha")
        press("x")
        assert.are.equal("Tasks — 1   ·   priority", lines()[1])
    end)

    -- Complete one and the next moves up under the cursor, so a run of them is
    -- one keypress each. This is the picker's reload behaviour, kept.
    it("keeps the cursor on its row so the next task moves under it", function()
        local row = goto_row("alpha")
        press("x")
        assert.are.equal(row, vim.api.nvim_win_get_cursor(0)[1])
        assert.is_truthy(lines()[row]:find("beta", 1, true))
    end)

    it("does nothing on the heading row", function()
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        press("x")
        assert.are.equal("- [ ] alpha #todo", read("n.md")[1])
    end)
end)

describe("tasklist: changing the view", function()
    after_each(cleanup)

    before_each(function()
        setup()
        note("n.md", { "- [ ] (C) late #todo due:2026-08-01", "- [ ] (A) urgent #todo" })
        tasklist.open()
    end)

    it("s cycles the ordering", function()
        assert.is_truthy(lines()[1]:find("priority", 1, true))
        press("s")
        assert.is_truthy(lines()[1]:find("due", 1, true))
        press("s")
        assert.is_truthy(lines()[1]:find("added", 1, true))
    end)

    it("S reverses it, and the heading says so", function()
        press("S")
        assert.is_truthy(lines()[1]:find("reversed", 1, true))
        assert.is_truthy(lines()[3]:find("late", 1, true))
    end)

    it("i switches to the inbox and back", function()
        note("n.md", { "- [ ] (A) urgent #todo", "- [ ] untagged" })
        press("r")
        press("i")
        assert.is_truthy(lines()[1]:find("Inbox", 1, true))
        assert.is_truthy(lines()[3]:find("untagged", 1, true))
        press("i")
        assert.is_truthy(lines()[1]:find("Tasks", 1, true))
    end)

    it("r re-scans, picking up a note edited behind its back", function()
        note("n.md", { "- [ ] (A) urgent #todo", "- [ ] (B) new one #todo" })
        press("r")
        assert.are.equal("Tasks — 2   ·   priority", lines()[1])
    end)
end)

describe("tasklist: configuration", function()
    after_each(cleanup)

    it("leaves a key to Vim when it is set to false", function()
        setup({ tasks = { list = { keys = { done = false } } } })
        note("n.md", { "- [ ] alpha #todo" })
        tasklist.open()
        local mapped = {}
        for _, m in ipairs(vim.api.nvim_buf_get_keymap(0, "n")) do
            mapped[m.lhs] = true
        end
        assert.is_nil(mapped["x"])
        assert.is_true(mapped["c"])
    end)

    it("takes a different key for an action", function()
        setup({ tasks = { list = { keys = { done = "d" } } } })
        note("n.md", { "- [ ] alpha #todo" })
        tasklist.open()
        goto_row("alpha")
        press("d")
        assert.is_truthy(read("n.md")[1]:match("^%- %[x%]"))
    end)

    -- A split has to leave the window you were reading in, so <enter> has
    -- somewhere to put the note that isn't the list.
    -- Counted with the preview off, so the number is about `open` alone.
    it("open = vsplit leaves the window you came from", function()
        setup({ tasks = { list = { open = "vsplit", preview = { enabled = false } } } })
        note("n.md", { "- [ ] alpha #todo" })
        local before = #vim.api.nvim_tabpage_list_wins(0)
        tasklist.open()
        assert.are.equal(before + 1, #vim.api.nvim_tabpage_list_wins(0))
        vim.cmd("only")
    end)

    -- Reopening is how you come back to the list. Coming back to something you
    -- are already looking at must not split the screen onto the same buffer.
    it("focuses the list instead of opening a second window onto it", function()
        setup({ tasks = { list = { open = "vsplit", preview = { enabled = false } } } })
        note("n.md", { "- [ ] alpha #todo" })
        tasklist.open()
        local wins = #vim.api.nvim_tabpage_list_wins(0)
        vim.cmd("wincmd p")
        tasklist.open()
        assert.are.equal(wins, #vim.api.nvim_tabpage_list_wins(0))
        assert.are.equal(tasklist._test.bufnr(), vim.api.nvim_get_current_buf())
        vim.cmd("only")
    end)

    -- ...and pressing it from the list itself must not make the list its own
    -- origin, or the next <enter> would open the note over the list.
    it("keeps <enter> off the list when reopened from the list", function()
        setup({ tasks = { list = { open = "vsplit", preview = { enabled = false } } } })
        note("n.md", { "- [ ] alpha #todo" })
        tasklist.open()
        local list_win = vim.api.nvim_get_current_win()
        tasklist.open()
        goto_row("alpha")
        press("<CR>")
        assert.are.equal(home .. "/n.md", vim.api.nvim_buf_get_name(0))
        assert.are_not.equal(list_win, vim.api.nvim_get_current_win())
        assert.are.equal(tasklist._test.bufnr(), vim.api.nvim_win_get_buf(list_win))
        vim.cmd("only")
    end)

    it("open = full takes the current window", function()
        setup({ tasks = { list = { open = "full", preview = { enabled = false } } } })
        note("n.md", { "- [ ] alpha #todo" })
        local before = #vim.api.nvim_tabpage_list_wins(0)
        tasklist.open()
        assert.are.equal(before, #vim.api.nvim_tabpage_list_wins(0))
    end)
end)

describe("tasklist: preview", function()
    after_each(function()
        cleanup()
        vim.cmd("only")
    end)

    local function preview_lines()
        local p = tasklist._test.preview()
        return vim.api.nvim_buf_get_lines(p.buf, 0, -1, false)
    end

    before_each(function()
        setup({ tasks = { list = { open = "full" } } })
        note("n.md", {
            "# Heading",
            "",
            "- context above",
            "  - [ ] alpha #todo",
            "- [ ] beta #todo",
        })
        tasklist.open()
    end)

    it("opens a split under the list", function()
        local p = tasklist._test.preview()
        assert.is_true(vim.api.nvim_win_is_valid(p.win))
        assert.are_not.equal(p.win, vim.api.nvim_get_current_win())
    end)

    it("shows the note the task under the cursor came from", function()
        goto_row("alpha")
        assert.are.same({
            "# Heading", "", "- context above",
            "  - [ ] alpha #todo", "- [ ] beta #todo",
        }, preview_lines())
    end)

    it("puts the cursor on the task's own line", function()
        goto_row("alpha")
        local p = tasklist._test.preview()
        assert.are.equal(4, vim.api.nvim_win_get_cursor(p.win)[1])
        goto_row("beta")
        assert.are.equal(5, vim.api.nvim_win_get_cursor(p.win)[1])
    end)

    -- Editing a note without saving leaves the file behind; a preview reading
    -- disk would then describe the line you are about to act on wrongly.
    it("reads a loaded buffer rather than the stale file", function()
        -- Loaded and edited but never written -- exactly the state the file on
        -- disk is behind in. Loaded without displaying it, so the list keeps
        -- its window.
        local bufnr = vim.fn.bufadd(home .. "/n.md")
        vim.fn.bufload(bufnr)
        vim.api.nvim_buf_set_lines(bufnr, 4, 5, false, { "- [ ] beta edited #todo" })
        goto_row("beta")
        assert.are.equal("- [ ] beta edited #todo", preview_lines()[5])
        vim.cmd("bwipeout! " .. bufnr)
    end)

    it("P closes the preview and opens it again", function()
        press("P")
        assert.is_nil(tasklist._test.preview().win)
        press("P")
        assert.is_true(vim.api.nvim_win_is_valid(tasklist._test.preview().win))
    end)

    it("p steps into the preview, and q comes back", function()
        press("p")
        assert.are.equal(tasklist._test.preview().win, vim.api.nvim_get_current_win())
        press("q")
        assert.are.equal(tasklist._test.bufnr(), vim.api.nvim_get_current_buf())
    end)

    -- The scroll keys act on the preview without the list losing focus, which
    -- is the whole reason they exist rather than just stepping in with `p`.
    it("<c-e> scrolls the preview and leaves the cursor in the list", function()
        note("long.md", vim.fn["repeat"]({ "- [ ] filler" }, 200))
        goto_row("alpha")
        local p = tasklist._test.preview()
        local before = vim.api.nvim_win_call(p.win, function() return vim.fn.line("w0") end)
        press("<C-e>")
        local after = vim.api.nvim_win_call(p.win, function() return vim.fn.line("w0") end)
        assert.is_true(after > before)
        assert.are.equal(tasklist._test.bufnr(), vim.api.nvim_get_current_buf())
    end)

    -- All three of Vim's scroll pairs point at the preview, so the rule is one
    -- line rather than "some keys scroll the list, some the preview".
    it("every scroll pair moves the preview, not the list", function()
        note("long.md", vim.fn["repeat"]({ "- [ ] filler #todo" }, 400))
        press("r")
        -- A row from the long note: previewing a two-line one leaves nothing to
        -- scroll, and every assertion below would pass for the wrong reason.
        goto_row("filler")
        local p = tasklist._test.preview()
        local function top()
            return vim.api.nvim_win_call(p.win, function() return vim.fn.line("w0") end)
        end
        local list_top = vim.fn.line("w0")
        for _, key in ipairs({ "<C-d>", "<C-f>", "<C-e>" }) do
            local before = top()
            press(key)
            assert.is_true(top() > before, key .. " did not scroll the preview down")
        end
        for _, key in ipairs({ "<C-u>", "<C-b>", "<C-y>" }) do
            local before = top()
            press(key)
            assert.is_true(top() < before, key .. " did not scroll the preview up")
        end
        -- ...and the list stayed where it was throughout.
        assert.are.equal(list_top, vim.fn.line("w0"))
        assert.are.equal(tasklist._test.bufnr(), vim.api.nvim_get_current_buf())
    end)

    -- With no preview up, swallowing the key to report the obvious would take
    -- the scrolling away and give nothing back.
    it("falls through to Vim when there is no preview", function()
        note("long.md", vim.fn["repeat"]({ "- [ ] filler #todo" }, 400))
        press("r")
        press("P")
        assert.is_nil(tasklist._test.preview().win)
        local before = vim.fn.line("w0")
        press("<C-d>")
        assert.is_true(vim.fn.line("w0") > before)
    end)

    it("takes a different key for stepping back out", function()
        setup({ tasks = { list = { open = "full", keys = { preview_back = "<Esc>" } } } })
        note("n.md", { "- [ ] alpha #todo" })
        tasklist.open()
        press("p")
        assert.are.equal(tasklist._test.preview().win, vim.api.nvim_get_current_win())
        press("<Esc>")
        assert.are.equal(tasklist._test.bufnr(), vim.api.nvim_get_current_buf())
    end)

    it("closes with the list", function()
        press("q")
        assert.is_nil(tasklist._test.preview().win)
    end)

    -- The split belongs to the list, not to the window it sits under. Switch
    -- that window to anything else and a preview of a note nobody is pointing
    -- at any more would be left behind.
    local function preview_gone()
        return vim.wait(200, function() return tasklist._test.preview().win == nil end)
    end

    it("goes away when the window shows another buffer", function()
        vim.cmd("enew")
        assert.is_true(preview_gone())
    end)

    it("goes away when <enter> opens the note over the list", function()
        goto_row("alpha")
        press("<CR>")
        assert.are.equal(home .. "/n.md", vim.api.nvim_buf_get_name(0))
        assert.is_true(preview_gone())
    end)

    it("stays while you step into it", function()
        press("p")
        assert.is_false(preview_gone())
        assert.is_true(vim.api.nvim_win_is_valid(tasklist._test.preview().win))
    end)

    -- Switching back from the bufferline never goes through M.open, so the
    -- preview has to be restored by the buffer being shown again -- otherwise
    -- the ordinary way back gives you a list with no preview.
    it("comes back when the buffer is switched to, not just reopened", function()
        local list_buf = tasklist._test.bufnr()
        vim.cmd("enew")
        assert.is_true(preview_gone())
        vim.cmd("buffer " .. list_buf)
        vim.wait(200, function() return tasklist._test.preview().win ~= nil end)
        assert.is_true(vim.api.nvim_win_is_valid(tasklist._test.preview().win))
        assert.are.equal(list_buf, vim.api.nvim_get_current_buf())
    end)

    it("re-scans the notes when switched back to", function()
        local list_buf = tasklist._test.bufnr()
        vim.cmd("enew")
        note("n.md", { "- [ ] alpha #todo", "- [ ] beta #todo", "- [ ] gamma #todo" })
        vim.cmd("buffer " .. list_buf)
        assert.are.equal("Tasks — 3   ·   priority", lines()[1])
    end)

    it("comes back when the list is reopened", function()
        vim.cmd("enew")
        assert.is_true(preview_gone())
        tasklist.open()
        assert.is_true(vim.api.nvim_win_is_valid(tasklist._test.preview().win))
    end)
end)
