-- `^id`: a marker on a line so that a link can point at that line, and not only
-- at the note or at the heading above it.
--
-- The case it was built for is a task written down in a meeting note and then
-- referred to from a daily note days later. The heading over it (`# その他, 議論`)
-- held three unrelated tasks, so an anchor naming the heading pointed at all
-- three -- which is to say at none of them.
--
-- Two things have to hold for that to keep working, and both are here. An id has
-- to survive every writer that rewrites the line: ticking the task off appends a
-- stamp, cancelling it wraps the text in a strikethrough, and either one done
-- naively leaves the id somewhere it is no longer read as an id. And an id must
-- never reach the reader: it names the line, it is not part of what the line
-- says, so the task list showing it would be showing noise.

local config = require("fzfkasten.config")
local pickers = require("fzfkasten.pickers")
local tasks = require("fzfkasten.tasks")
local utils = require("fzfkasten.utils")
local t = tasks._test

local home

local function setup(opts)
    home = vim.fn.tempname()
    vim.fn.mkdir(home, "p")
    config.setup(vim.tbl_deep_extend("force", { home = home }, opts or {}))
end

local function cleanup()
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

local function open(path, lineno)
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    vim.api.nvim_win_set_cursor(0, { lineno or 1, 0 })
end

local function line_at(lineno)
    return vim.api.nvim_buf_get_lines(0, lineno - 1, lineno, false)[1]
end

describe("reading an id", function()
    before_each(function() setup() end)
    after_each(cleanup)

    it("finds one at the end of a line", function()
        assert.are.equal("t3k9aa", utils.block_id("- [ ] 案を作る #todo ^t3k9aa"))
    end)

    it("finds one a stamp was appended after", function()
        assert.are.equal("t3k9aa", utils.block_id("- [x] 案 ^t3k9aa done:2026-08-19 10:00"))
    end)

    -- A note about anything numeric writes `x ^2`, and reading that as an id
    -- would put a link target on a line nobody marked.
    it("does not read a one-character exponent as an id", function()
        assert.is_nil(utils.block_id("面積は r ^2 に比例する"))
    end)

    it("needs whitespace in front, so a caret mid-word is not an id", function()
        assert.is_nil(utils.block_id("- [ ] a^bcdef"))
    end)

    it("returns nil for a line carrying none", function()
        assert.is_nil(utils.block_id("- [ ] 案を作る #todo"))
    end)
end)

describe("writing an id", function()
    before_each(function() setup() end)
    after_each(cleanup)

    it("strips one along with the space in front of it", function()
        assert.are.equal("- [ ] 案を作る #todo", utils.strip_block_id("- [ ] 案を作る #todo ^t3k9aa"))
    end)

    it("puts one at the end", function()
        assert.are.equal("- [ ] 案を作る ^t3k9aa", utils.with_block_id("- [ ] 案を作る", "t3k9aa"))
    end)

    -- Otherwise a line rewritten twice ends up with two ids, and rewording it
    -- then breaks whichever link is not the one being followed.
    it("replaces one already there rather than adding a second", function()
        assert.are.equal("- [ ] 案を作る ^new111",
            utils.with_block_id("- [ ] 案を作る ^t3k9aa", "new111"))
    end)

    it("collects the ids in a set of lines", function()
        local ids = utils.block_ids({ "a ^aaa111", "b", "c ^ccc333" })
        assert.is_true(ids["aaa111"])
        assert.is_true(ids["ccc333"])
        assert.is_nil(ids["bbb222"])
    end)
end)

describe("minting an id", function()
    after_each(cleanup)

    it("is as long as the config says, out of the configured alphabet", function()
        setup({ block_id = { length = 4, alphabet = "abc" } })
        local id = utils.new_block_id()
        assert.are.equal(4, #id)
        assert.is_truthy(id:match("^[abc]+$"))
    end)

    it("avoids the ids it is told are taken", function()
        -- One character out of two: with "a" and "b" both spoken for there is
        -- exactly nothing left, so anything but a loop would hand one back.
        setup({ block_id = { length = 1, alphabet = "abc" } })
        local id = utils.new_block_id({ a = true, b = true })
        assert.are.equal("c", id)
    end)
end)

describe("the writers keep the id last", function()
    before_each(function() setup() end)
    after_each(cleanup)

    it("ticking a task off leaves the id past the stamp", function()
        local out = t.toggle_line("- [ ] 案を作る ^t3k9aa")
        assert.is_truthy(out:match("done:"), out)
        assert.is_truthy(out:match("%^t3k9aa$"), out)
    end)

    it("reopening it keeps the id and drops the stamp", function()
        local reopened = t.toggle_line(t.toggle_line("- [ ] 案を作る ^t3k9aa"))
        assert.are.equal("- [ ] 案を作る ^t3k9aa", reopened)
    end)

    -- `~~案を作る ^t3k9aa~~` would read as though the id were part of what was
    -- dropped, and the strikethrough is decoration the id is not inside.
    it("cancelling wraps the text but not the id", function()
        local out = t.cancel_line("- [ ] 案を作る ^t3k9aa")
        assert.is_truthy(out:match("~~案を作る~~"), out)
        assert.is_truthy(out:match("%^t3k9aa$"), out)
    end)

    it("a due date goes before the id", function()
        assert.are.equal("- [ ] 案を作る due:2026-08-20 ^t3k9aa",
            t.due_line("- [ ] 案を作る ^t3k9aa", "2026-08-20"))
    end)

    it("clearing the due date leaves the id where it was", function()
        assert.are.equal("- [ ] 案を作る ^t3k9aa",
            t.due_line("- [ ] 案を作る due:2026-08-20 ^t3k9aa", ""))
    end)

    it("a tag goes before the id", function()
        assert.are.equal("- [ ] 案を作る #todo ^t3k9aa",
            t.tag_line("- [ ] 案を作る ^t3k9aa", "todo"))
    end)

    it("hands a refusal back untouched", function()
        local out, why = t.toggle_line("- [-] 案を作る ^t3k9aa")
        assert.is_nil(out)
        assert.are.equal("cancelled", why)
    end)
end)

describe("the id never reaches the reader", function()
    before_each(function() setup() end)
    after_each(cleanup)

    it("is not part of what a task says", function()
        local text = t.parse_task_text("(A) 案を作る #todo ^t3k9aa", config.options.tasks)
        assert.are.equal("案を作る #todo", text)
    end)

    it("comes off a cancelled task too, strike and all", function()
        local text = t.parse_task_text("~~案を作る~~ cancelled:2026-08-19 ^t3k9aa", config.options.tasks)
        assert.are.equal("案を作る", text)
    end)
end)

describe("yank_block_link", function()
    before_each(function() setup() end)
    after_each(cleanup)

    it("mints an id on the line and leaves a link to it in the registers", function()
        local path = note("2026-08-17 戦略会議 論点.md", {
            "# その他, 議論",
            "- [ ] 案を作る #todo",
        })
        open(path, 2)
        pickers.yank_block_link()

        local id = utils.block_id(line_at(2))
        assert.is_truthy(id)
        assert.are.equal("[[2026-08-17 戦略会議 論点#^" .. id .. "]]", vim.fn.getreg('"'))
        assert.are.equal(vim.fn.getreg('"'), vim.fn.getreg("0"))
    end)

    it("leaves the rest of the line alone", function()
        local path = note("会議.md", { "- [ ] 案を作る #todo" })
        open(path, 1)
        pickers.yank_block_link()
        assert.is_truthy(line_at(1):match("^%- %[ %] 案を作る #todo %^%w+$"), line_at(1))
    end)

    -- Twice is the same link twice, not a second id: two ids on one line is the
    -- state where rewording it breaks one of the two links pointing at it.
    it("reuses an id already on the line", function()
        local path = note("会議.md", { "- [ ] 案を作る ^t3k9aa" })
        open(path, 1)
        pickers.yank_block_link()
        assert.are.equal("- [ ] 案を作る ^t3k9aa", line_at(1))
        assert.are.equal("[[会議#^t3k9aa]]", vim.fn.getreg('"'))
    end)

    it("writes no alias by default", function()
        local path = note("会議.md", { "- [ ] 案を作る #todo" })
        open(path, 1)
        pickers.yank_block_link()
        assert.is_nil(vim.fn.getreg('"'):find("|", 1, true))
    end)

    it("does nothing on a blank line", function()
        local path = note("会議.md", { "- [ ] 案を作る", "" })
        open(path, 2)
        vim.fn.setreg('"', "untouched")
        pickers.yank_block_link()
        assert.are.equal("untouched", vim.fn.getreg('"'))
        assert.are.equal("", line_at(2))
    end)

    it("does nothing in a buffer that is not a note", function()
        vim.cmd("enew")
        vim.api.nvim_buf_set_lines(0, 0, -1, false, { "- [ ] 案を作る" })
        vim.fn.setreg('"', "untouched")
        pickers.yank_block_link()
        assert.are.equal("untouched", vim.fn.getreg('"'))
    end)
end)

describe("yank_block_link with block_id.alias on", function()
    after_each(cleanup)

    -- The tags have to go. The tag search reads every line in the collection,
    -- not only the ones that meant it, so an alias carrying `#todo #qms` would
    -- file the daily note it was pasted into under both.
    it("carries the line's prose but not its tags", function()
        setup({ block_id = { alias = true, alias_max = nil } })
        local path = note("会議.md", { "- [ ] (A) 案を作る #todo #qms" })
        open(path, 1)
        pickers.yank_block_link()
        local id = utils.block_id(line_at(1))
        assert.are.equal("[[会議#^" .. id .. "|(A) 案を作る]]", vim.fn.getreg('"'))
    end)

    -- Counted in characters: cut by byte, a Japanese alias ends mid-glyph.
    it("cuts a long line to alias_max characters", function()
        setup({ block_id = { alias = true, alias_max = 4 } })
        local path = note("会議.md", { "- [ ] 部門部署がないので責任者は人にする" })
        open(path, 1)
        pickers.yank_block_link()
        local alias = vim.fn.getreg('"'):match("|(.*)%]%]$")
        assert.are.equal("部門部署…", alias)
    end)

    it("writes no alias when the line is nothing but tags", function()
        setup({ block_id = { alias = true } })
        local path = note("会議.md", { "- [ ] #todo" })
        open(path, 1)
        pickers.yank_block_link()
        assert.is_nil(vim.fn.getreg('"'):find("|", 1, true))
    end)
end)

describe("following a link to a line", function()
    before_each(function() setup() end)
    after_each(cleanup)

    local function follow(lineno)
        local line = vim.api.nvim_buf_get_lines(0, lineno - 1, lineno, false)[1]
        local start = line:find("%[%[")
        assert(start, "no link on line " .. lineno)
        vim.api.nvim_win_set_cursor(0, { lineno, start + 1 })
        pickers.follow_link()
    end

    local function cursor_line()
        local row = vim.api.nvim_win_get_cursor(0)[1]
        return vim.api.nvim_buf_get_lines(0, row - 1, row, false)[1]
    end

    -- The point of the whole thing: three tasks under one heading, and the link
    -- lands on the one it names rather than on the heading over all three.
    it("puts the cursor on the line the id names", function()
        note("会議.md", {
            "# その他, 議論",
            "- [ ] 商品構成を渡す ^aaa111",
            "- [ ] 輸送形態を検討する ^bbb222",
            "- [ ] 案を作る ^ccc333",
        })
        local daily = note("2026-08-19.md", { "[[会議#^bbb222]] の件" })
        open(daily, 1)
        follow(1)
        assert.are.equal("会議.md", vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t"))
        assert.are.equal("- [ ] 輸送形態を検討する ^bbb222", cursor_line())
    end)

    it("still finds the line after a stamp was appended past the id", function()
        note("会議.md", { "# 議論", "- [x] 案を作る ^ccc333 done:2026-08-19 10:00" })
        local daily = note("2026-08-19.md", { "[[会議#^ccc333]] の件" })
        open(daily, 1)
        follow(1)
        assert.are.equal("- [x] 案を作る ^ccc333 done:2026-08-19 10:00", cursor_line())
    end)

    it("carries the id through an alias", function()
        note("会議.md", { "# 議論", "- [ ] 案を作る ^ccc333" })
        local daily = note("2026-08-19.md", { "[[会議#^ccc333|案を作る]] の件" })
        open(daily, 1)
        follow(1)
        assert.are.equal("- [ ] 案を作る ^ccc333", cursor_line())
    end)

    -- The note still opens: a link whose line was deleted is worth more open at
    -- the top than refused outright, and the warning says which id went missing.
    it("opens the note at the top when no line carries the id", function()
        note("会議.md", { "# 議論", "- [ ] 案を作る" })
        local daily = note("2026-08-19.md", { "[[会議#^ccc333]] の件" })
        open(daily, 1)
        follow(1)
        assert.are.equal("会議.md", vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t"))
        assert.are.equal(1, vim.api.nvim_win_get_cursor(0)[1])
    end)
end)
