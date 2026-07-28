-- Following a `[[wikilink]]`, and what an anchor does to that.
--
-- The anchor has to come off before anything looks for the note. Left on, the
-- name is "note#heading", which matches no file -- and with
-- `follow_link.create_nonexisting` set, following your own anchored link opened
-- a *new* note called `note#heading`, template and all, one `:w` from being
-- real. That is the case these exist for.

local config = require("fzfkasten.config")
local pickers = require("fzfkasten.pickers")
local utils = require("fzfkasten.utils")

local home

local function setup(opts)
    home = vim.fn.tempname()
    vim.fn.mkdir(home, "p")
    config.setup(vim.tbl_deep_extend("force", { home = home }, opts or {}))
end

local function cleanup()
    -- Wiped rather than deleted: a buffer remembers where its cursor was, so
    -- one case's jump would be the next case's starting position.
    pcall(vim.cmd, "silent! %bwipeout!")
    if home then
        vim.fn.delete(home, "rf")
        home = nil
    end
end

local function note(name, lines)
    local full = home .. "/" .. name
    vim.fn.mkdir(vim.fn.fnamemodify(full, ":h"), "p")
    vim.fn.writefile(lines, full)
    return full
end

-- Put the cursor inside the link on `lineno` of the open buffer and follow it.
local function follow(lineno)
    local line = vim.api.nvim_buf_get_lines(0, lineno - 1, lineno, false)[1]
    local start = line:find("%[%[")
    assert(start, "no link on line " .. lineno)
    vim.api.nvim_win_set_cursor(0, { lineno, start + 1 })
    pickers.follow_link()
end

local function opened()
    return vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t")
end

local function cursor_line()
    local row = vim.api.nvim_win_get_cursor(0)[1]
    return vim.api.nvim_buf_get_lines(0, row - 1, row, false)[1]
end

describe("split_link", function()
    it("reads a bare name", function()
        assert.are.same({ "note", nil, nil }, { utils.split_link("note") })
    end)

    it("reads an anchor", function()
        assert.are.same({ "note", "見出し", nil }, { utils.split_link("note#見出し") })
    end)

    it("reads an alias", function()
        assert.are.same({ "note", nil, "呼び名" }, { utils.split_link("note|呼び名") })
    end)

    it("reads all three", function()
        assert.are.same({ "note", "見出し", "呼び名" }, { utils.split_link("note#見出し|呼び名") })
    end)

    -- The alias is split off first, so a `#` inside it stays in the alias.
    it("leaves a # inside an alias alone", function()
        assert.are.same({ "note", nil, "see #3" }, { utils.split_link("note|see #3") })
    end)

    -- ...and the anchor is everything after the first `#`, so a heading that
    -- contains one survives.
    it("keeps a # inside a heading", function()
        assert.are.same({ "note", "Q#A", nil }, { utils.split_link("note#Q#A") })
    end)

    it("reads an anchor with no name as a link within the same note", function()
        assert.are.same({ "", "top", nil }, { utils.split_link("#top") })
    end)
end)

describe("follow_link: anchors", function()
    after_each(cleanup)

    before_each(function()
        setup({ follow_link = { create_nonexisting = true } })
        note("note.md", { "# 本体", "", "本文", "", "## 見出し", "", "ここが目的地", "", "## 別の節" })
        note("from.md", {
            "A [[note#見出し]] へ",
            "B [[note]] へ",
            "C [[note#無い見出し]] へ",
            "D [[note#見出し|別名]] へ",
            "E [[note#見出し ]] へ",
        })
    end)

    -- The bug this suite exists for: with create_nonexisting set, the anchor
    -- was part of the name, nothing matched, and a note called "note#見出し"
    -- was conjured up instead of the one you were pointing at.
    it("opens the note itself, not one named after the anchor", function()
        vim.cmd("edit " .. home .. "/from.md")
        follow(1)
        assert.are.equal("note.md", opened())
    end)

    it("puts the cursor on the heading", function()
        vim.cmd("edit " .. home .. "/from.md")
        follow(1)
        assert.are.equal("## 見出し", cursor_line())
    end)

    it("carries the anchor through an alias too", function()
        vim.cmd("edit " .. home .. "/from.md")
        follow(4)
        assert.are.equal("note.md", opened())
        assert.are.equal("## 見出し", cursor_line())
    end)

    it("leaves the cursor at the top when the link has no anchor", function()
        vim.cmd("edit " .. home .. "/from.md")
        follow(2)
        assert.are.equal("note.md", opened())
        assert.are.equal("# 本体", cursor_line())
    end)

    -- A heading that is not there still opens the note -- the link was about
    -- that note -- but says so, since landing at the top looks like it worked.
    it("opens the note anyway when the heading is missing", function()
        vim.cmd("edit " .. home .. "/from.md")
        follow(3)
        assert.are.equal("note.md", opened())
        assert.are.equal("# 本体", cursor_line())
    end)

    it("ignores whitespace around the anchor", function()
        vim.cmd("edit " .. home .. "/from.md")
        follow(5)
        assert.are.equal("## 見出し", cursor_line())
    end)

    it("matches a heading whatever its capitalisation", function()
        note("caps.md", { "# Top", "", "## Results and Notes" })
        note("tocaps.md", { "see [[caps#results AND notes]]" })
        vim.cmd("edit " .. home .. "/tocaps.md")
        follow(1)
        assert.are.equal("caps.md", opened())
        assert.are.equal("## Results and Notes", cursor_line())
    end)

    -- Nothing under the cursor is not a link to nowhere; it is not a link.
    it("creates nothing for an anchor with no name", function()
        note("selfref.md", { "see [[#見出し]]" })
        vim.cmd("edit " .. home .. "/selfref.md")
        follow(1)
        assert.are.equal("selfref.md", opened())
        assert.are.equal(0, vim.fn.filereadable(home .. "/#見出し.md"))
    end)
end)
