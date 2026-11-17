-- `![[note#^id]]`: the lines a link points at, drawn under the link.
--
-- What has to hold: the anchor picks the lines it says (and no line number is
-- involved, so they are still the right lines after the note is edited), and
-- what is drawn follows the other note -- edited in a buffer here, or rewritten
-- on disk by something else.

local config = require("fzfkasten.config")
local embed = require("fzfkasten.embed")
local pickers = require("fzfkasten.pickers")

local home

local function setup(opts)
    home = vim.fn.resolve(vim.fn.tempname())
    vim.fn.mkdir(home, "p")
    embed._test.index.by_name = nil
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

-- What is drawn under each line of the current buffer, bar taken off:
-- { [lineno] = { "text", ... } }.
local function drawn()
    local out = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(0, embed._test.ns, 0, -1, { details = true })) do
        local texts = {}
        for _, virt in ipairs(m[4].virt_lines or {}) do
            local text = ""
            for i = 2, #virt do
                text = text .. virt[i][1]
            end
            texts[#texts + 1] = text
        end
        out[m[2] + 1] = texts
    end
    return out
end

-- Refresh, and wait for the listing of notes the first one asks for.
local function shown(lineno, want)
    embed.refresh()
    local got
    vim.wait(2000, function()
        got = drawn()[lineno]
        return vim.deep_equal(got, want)
    end, 20)
    return got
end

local MINUTES = {
    "---",
    "title: minutes",
    "---",
    "# Minutes",
    "",
    "## Budget",
    "",
    "The figure is 120. ^fig001",
    "",
    "- [ ] draft the proposal #todo ^t3k9aa",
    "    - ask finance first",
    "",
    "    - and legal",
    "- [ ] book the room ^room01",
    "",
    "### Detail",
    "",
    "```",
    "## not a heading",
    "```",
    "more detail",
    "",
    "## Other business",
    "",
    "nothing",
}

describe("embed.targets", function()
    it("reads what stands between ![[ and ]]", function()
        assert.are.same({ "a#^x1", "b#Results|alias" }, embed.targets("see ![[a#^x1]] and ![[b#Results|alias]]"))
    end)

    it("leaves a plain link, a picture and inline code alone", function()
        assert.are.same({}, embed.targets("[[a]] ![](pic.png) `![[a]]`"))
    end)
end)

describe("embed.extract", function()
    local function lines_of(anchor)
        local from, to = embed.extract(MINUTES, anchor)
        if not from then
            return nil, to
        end
        return vim.list_slice(MINUTES, from, to)
    end

    it("takes a single line by its id", function()
        assert.are.same({ "The figure is 120. ^fig001" }, lines_of("^fig001"))
    end)

    it("takes a list item with what is nested under it", function()
        assert.are.same({
            "- [ ] draft the proposal #todo ^t3k9aa",
            "    - ask finance first",
            "",
            "    - and legal",
        }, lines_of("^t3k9aa"))
    end)

    it("takes everything between two ids, written either way round", function()
        local want = vim.list_slice(MINUTES, 8, 14)
        assert.are.same(want, lines_of("^fig001..^room01"))
        assert.are.same(want, lines_of("^room01..^fig001"))
        assert.are.same(want, lines_of("^fig001..room01"))
    end)

    it("takes a section down to the next heading of its level", function()
        local got = lines_of("budget")
        assert.are.equal("## Budget", got[1])
        -- The subsection belongs to it; a `##` inside a fence ends nothing.
        assert.are.equal("more detail", got[#got])
    end)

    it("takes the note without its frontmatter", function()
        local got = lines_of(nil)
        assert.are.equal("# Minutes", got[1])
        assert.are.equal("nothing", got[#got])
    end)

    it("says what is missing", function()
        assert.are.same({ nil, "No line '^nope' in" }, { lines_of("^nope") })
        assert.are.same({ nil, "No line '^nope' in" }, { lines_of("^fig001..^nope") })
        assert.are.same({ nil, "No heading 'Nope' in" }, { lines_of("Nope") })
    end)
end)

describe("embed.wrap", function()
    it("leaves a line that fits", function()
        assert.are.same({ "short" }, embed.wrap("short", 40))
    end)

    it("cuts by cells, so wide characters are counted as two", function()
        local got = embed.wrap(string.rep("会", 25), 20)
        assert.are.same({ string.rep("会", 10), string.rep("会", 10), string.rep("会", 5) }, got)
    end)

    it("keeps the indent on the lines it adds", function()
        local got = embed.wrap("  - " .. string.rep("a", 30), 20)
        assert.are.equal("  ", got[2]:match("^ *"))
        assert.are.equal("  - " .. string.rep("a", 30), got[1] .. got[2]:sub(3))
    end)
end)

describe("an embed in a note", function()
    before_each(function() setup() end)
    after_each(cleanup)

    it("shows the lines under the link, without the id", function()
        note("minutes.md", MINUTES)
        vim.cmd("edit " .. note("daily.md", { "# Today", "![[minutes#^t3k9aa]]", "after" }))
        assert.are.same({
            "- [ ] draft the proposal #todo",
            "    - ask finance first",
            "",
            "    - and legal",
        }, shown(2, {
            "- [ ] draft the proposal #todo",
            "    - ask finance first",
            "",
            "    - and legal",
        }))
        -- Nothing was written into the note.
        assert.are.same({ "# Today", "![[minutes#^t3k9aa]]", "after" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
    end)

    it("follows the other note when it is rewritten on disk", function()
        local src = note("minutes.md", MINUTES)
        vim.cmd("edit " .. note("daily.md", { "![[minutes#^fig001]]" }))
        assert.are.same({ "The figure is 120." }, shown(1, { "The figure is 120." }))

        vim.fn.writefile({ "moved down", "The figure is 135. ^fig001" }, src)
        assert.are.same({ "The figure is 135." }, shown(1, { "The figure is 135." }))
    end)

    it("follows the other note as it is edited here, before it is saved", function()
        local src = note("minutes.md", MINUTES)
        local daily = note("daily.md", { "![[minutes#^fig001]]" })
        vim.cmd("edit " .. daily)
        assert.are.same({ "The figure is 120." }, shown(1, { "The figure is 120." }))

        vim.cmd("split " .. src)
        vim.api.nvim_buf_set_lines(0, 7, 8, false, { "The figure is 150. ^fig001" })
        vim.cmd("wincmd p")
        assert.are.same({ "The figure is 150." }, shown(1, { "The figure is 150." }))
    end)

    it("cuts a long quote and says how much was left out", function()
        cleanup()
        setup({ embed = { max_lines = 2 } })
        note("minutes.md", MINUTES)
        vim.cmd("edit " .. note("daily.md", { "![[minutes#Budget]]" }))
        local want = { "## Budget", "", "… 14 more lines" }
        assert.are.same(want, shown(1, want))
    end)

    it("says so when the note or the line is not there", function()
        note("minutes.md", MINUTES)
        vim.cmd("edit " .. note("daily.md", { "![[nowhere]]", "![[minutes#^gone00]]" }))
        assert.are.same({ "No note 'nowhere'" }, shown(1, { "No note 'nowhere'" }))
        assert.are.same({ "No line '^gone00' in 'minutes'" }, drawn()[2])
    end)

    it("quotes from the note it is in when no note is named", function()
        vim.cmd("edit " .. note("daily.md", { "![[#Plan]]", "", "## Plan", "ship it" }))
        assert.are.same({ "## Plan", "ship it" }, shown(1, { "## Plan", "ship it" }))
    end)

    it("draws nothing for an embed inside a fence", function()
        note("minutes.md", MINUTES)
        vim.cmd("edit " .. note("daily.md", { "```", "![[minutes#^fig001]]", "```", "![[minutes#^fig001]]" }))
        assert.are.same({ "The figure is 120." }, shown(4, { "The figure is 120." }))
        assert.is_nil(drawn()[2])
    end)
end)

describe("embed.highlight", function()
    -- Neovim ships the markdown parser from 0.10; without it there is nothing
    -- to colour with and the quote is drawn plain.
    local has_parser = pcall(vim.treesitter.get_string_parser, "x", "markdown")

    it("colours a quote as markdown, inline constructs and fenced code included", function()
        if not has_parser then
            return
        end
        local marks = embed.highlight({ "## Budget", "see *this* and #todo", "```lua", "local x = 1", "```" })
        assert.is_truthy(marks[1][4]:match("^@markup%.heading"))
        assert.is_nil(marks[2][1])
        assert.is_truthy(marks[2][6]:match("^@markup%.italic"))
        assert.is_truthy(marks[4][1]:match("%.lua$") or marks[4][1]:match("^@markup%.raw"))
    end)

    it("draws the colours, cut where the line is wrapped", function()
        if not has_parser then
            return
        end
        cleanup()
        setup()
        note("minutes.md", { "## Budget ^head01", "plain #todo" })
        vim.cmd("edit " .. note("daily.md", { "![[minutes#^head01..^head01]]", "![[minutes]]" }))
        shown(1, { "## Budget" })
        local m = vim.api.nvim_buf_get_extmarks(0, embed._test.ns, 0, -1, { details = true })
        local heading = m[1][4].virt_lines[1]
        assert.are.same("FzfkastenEmbed", heading[#heading][2][1])
        assert.is_truthy(heading[#heading][2][2]:match("^@markup%.heading"))
        -- A tag is coloured as it is in the note it came from.
        local tagged = m[2][4].virt_lines[2]
        assert.are.same({ "#todo", { "FzfkastenEmbed", "FzfkastenNoteTag" } }, tagged[#tagged])
        cleanup()
    end)
end)

describe("yanking an embed", function()
    before_each(function() setup() end)
    after_each(cleanup)

    it("names one line by its id, minting it", function()
        vim.cmd("edit " .. note("minutes.md", { "first", "second" }))
        pickers.yank_block_embed(2, 2)
        local id = vim.api.nvim_buf_get_lines(0, 1, 2, false)[1]:match("%^(%w+)$")
        assert.is_truthy(id)
        assert.are.equal("![[minutes#^" .. id .. "]]", vim.fn.getreg('"'))
    end)

    it("names several lines by the ids at their ends, stepping over blank ends", function()
        vim.cmd("edit " .. note("minutes.md", { "first ^aaaaaa", "second", "third", "" }))
        pickers.yank_block_embed(1, 4)
        local id = vim.api.nvim_buf_get_lines(0, 2, 3, false)[1]:match("%^(%w+)$")
        assert.is_truthy(id)
        assert.are.equal("![[minutes#^aaaaaa..^" .. id .. "]]", vim.fn.getreg('"'))
    end)
end)
