-- `:FzfKastenRecent` and `:FzfKastenLinkToDaily`: the one picker that orders
-- by mtime, and the one command that writes into two buffers at once.

local config = require("fzfkasten.config")
local pickers = require("fzfkasten.pickers")
local utils = require("fzfkasten.utils")

local home

local function note(name, lines, age)
    local full = home .. "/" .. name
    vim.fn.mkdir(vim.fn.fnamemodify(full, ":h"), "p")
    vim.fn.writefile(lines, full)
    if age then
        -- `touch -d` sets mtime; seconds back from now keeps it monotonic.
        vim.fn.system({ "touch", "-d", ("@%d"):format(os.time() - age), full })
    end
    return full
end

local function setup(opts)
    config.setup(vim.tbl_deep_extend("force", {
        home = home,
        notes = { daily = { dir = "daily", format = "%Y-%m-%d", template = nil } },
    }, opts or {}))
end

describe("recent_notes", function()
    before_each(function()
        home = vim.fn.tempname(); vim.fn.mkdir(home, "p")
        setup()
    end)
    after_each(function() vim.fn.delete(home, "rf") end)

    it("orders by mtime, newest first", function()
        note("old.md", { "" }, 300)
        note("new.md", { "" }, 10)
        note("sub/mid.md", { "" }, 100)
        local rels = {}
        for _, n in ipairs(pickers.recent_notes()) do rels[#rels + 1] = n.rel end
        assert.are.same({ "new.md", "sub/mid.md", "old.md" }, rels)
    end)

    it("stops at the limit and leaves the ignored directories out", function()
        note("templates/daily.md", { "" }, 1)
        note("a.md", { "" }, 20)
        note("b.md", { "" }, 30)
        note("c.md", { "" }, 40)
        local rels = {}
        for _, n in ipairs(pickers.recent_notes(2)) do rels[#rels + 1] = n.rel end
        assert.are.same({ "a.md", "b.md" }, rels)
    end)
end)

describe("link_to_daily", function()
    local today

    before_each(function()
        home = vim.fn.tempname(); vim.fn.mkdir(home, "p")
        setup()
        today = home .. "/daily/" .. os.date("%Y-%m-%d") .. ".md"
        vim.cmd("silent %bwipeout!")
    end)
    after_each(function() vim.fn.delete(home, "rf") end)

    local function open(path)
        vim.cmd("edit " .. vim.fn.fnameescape(path))
        return vim.api.nvim_get_current_buf()
    end

    it("mints the id here and appends the link to the daily on disk", function()
        note("daily/" .. os.date("%Y-%m-%d") .. ".md", { "# today", "" })
        local src = note("minutes.md", { "# Minutes", "- decide the thing" })
        open(src)
        vim.api.nvim_win_set_cursor(0, { 2, 0 })
        pickers.link_to_daily()

        local here = vim.api.nvim_buf_get_lines(0, 1, 2, false)[1]
        local id = utils.block_id(here)
        assert.is_string(id)
        local daily = vim.fn.readfile(today)
        assert.are.equal("- [[minutes#^" .. id .. "]]", daily[#daily])
        assert.are.equal("[[minutes#^" .. id .. "]]", vim.fn.getreg('"'))
    end)

    it("writes after the cursor of the daily's window when it is on screen", function()
        local daily = note("daily/" .. os.date("%Y-%m-%d") .. ".md", { "# today", "first", "last" })
        local src = note("minutes.md", { "a line" })
        local dbuf = open(daily)
        vim.api.nvim_win_set_cursor(0, { 2, 0 })
        vim.cmd("vsplit")
        open(src)
        pickers.link_to_daily()

        local lines = vim.api.nvim_buf_get_lines(dbuf, 0, -1, false)
        assert.are.equal(4, #lines)
        assert.is_truthy(lines[3]:match("^%- %[%[minutes#%^%w+%]%]$"))
        assert.are.equal("last", lines[4])
        assert.is_true(vim.bo[dbuf].modified) -- through the buffer, not the file
        vim.cmd("only")
    end)

    it("creates today's daily when there is none", function()
        local src = note("minutes.md", { "a line" })
        open(src)
        pickers.link_to_daily()
        assert.are.equal(1, vim.fn.filereadable(today))
        local lines = vim.fn.readfile(today)
        assert.are.equal("# " .. os.date("%Y-%m-%d"), lines[1])
        assert.is_truthy(lines[#lines]:match("^%- %[%[minutes#%^"))
    end)

    it("reuses an id the line already carries", function()
        note("daily/" .. os.date("%Y-%m-%d") .. ".md", { "# today" })
        local src = note("minutes.md", { "a line ^abc123" })
        open(src)
        pickers.link_to_daily()
        pickers.link_to_daily()
        assert.are.equal("a line ^abc123", vim.api.nvim_buf_get_lines(0, 0, 1, false)[1])
        local daily = vim.fn.readfile(today)
        assert.are.equal("- [[minutes#^abc123]]", daily[2])
        assert.are.equal("- [[minutes#^abc123]]", daily[3])
    end)

    it("refuses a buffer that is not a note", function()
        vim.cmd("enew")
        vim.api.nvim_buf_set_lines(0, 0, -1, false, { "scratch" })
        pickers.link_to_daily()
        assert.are.equal(0, vim.fn.filereadable(today))
    end)
end)
