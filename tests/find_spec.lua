-- The note finder, and the two ways of typing into it.
--
-- A plain query is fzf's, unchanged: `nvmcfg` finds `nvim/config/init.lua`,
-- ranked the way fzf ranks it. A query beginning with `/` is romaji: `/kaigi`
-- finds 会議.
--
-- The `/` is there because fzf matches literally and cannot be taught about
-- Japanese, so the matching has to happen out here -- which means fzf's own
-- matching is off (`--disabled`) and ordinary typing needs a fuzzy matcher of
-- its own. That one is `vim.fn.matchfuzzy()`, in this process, because
-- everything on this path is paid again on every keystroke. The token is
-- borrowed from fzf-jp-extension, which patches it into fzf itself.
--
-- "the way fzf does" below is the case that pins the swap: `matchfuzzy` replaced
-- a `fzf --filter` per keystroke (4.5ms here, 166ms on WSL2) and has to keep
-- answering what fzf answered for the queries people actually type.
--
-- Matching against headings and not only paths is what makes any of this worth
-- doing: measured against 464 real notes, 32 had any Japanese in the filename
-- while 135 carried it in their headings. Matching paths alone, the filter ran,
-- narrowed, and found almost nothing -- which reads as "romaji does not work
-- here" rather than "romaji has nothing to match on here".

local config = require("fzfkasten.config")
local pickers = require("fzfkasten.pickers")
local romaji = require("fzfkasten.romaji")
local t = pickers._test

local home

local function note(name, lines)
    local full = home .. "/" .. name
    vim.fn.mkdir(vim.fn.fnamemodify(full, ":h"), "p")
    vim.fn.writefile(lines, full)
end

-- What the picker would show for `query`, sorted so a case can say what it
-- found without also pinning fzf's ranking.
local function shown(query)
    local list = t.notes_for_query(t.note_index(), query)
    table.sort(list)
    return list
end

-- Stand in for the migemo, so these cases need neither ttyskk nor kensaku:
-- romaji in, the `\m` regex a backend would have built out.
local BACKEND = {
    name = "stub",
    available = function() return true end,
    rg_regex = function() return nil end,
    regex = function(q)
        local built = {
            kaigi = [[\m\%(kaigi\|かいぎ\|会議\)]],
            tanaka = [[\m\%(tanaka\|たなか\|田中\)]],
        }
        return built[q]
    end,
}

local function setup(opts)
    config.setup(vim.tbl_deep_extend("force",
        { home = home, romaji = { backend = BACKEND } }, opts or {}))
    romaji._test.reset_probe()
end

describe("the note finder", function()
    before_each(function()
        home = vim.fn.tempname()
        vim.fn.mkdir(home, "p")

        note("会議メモ.md", { "# notes" })
        note("1on1 Suzuki.md", { "---", "title: 1on1 Suzuki", "---", "", "# 田中さんと打ち合わせ" })
        note("plan.md", { "# Plan", "", "田中さんに連絡する" })
        note("nvim/config/init.lua.md", { "# Config" })
        note("readme.md", { "# Readme" })
        setup()
    end)

    after_each(function()
        if home then
            vim.fn.delete(home, "rf")
            home = nil
        end
    end)

    it("shows everything before anything is typed", function()
        assert.are.equal(5, #shown(""))
        assert.are.equal(5, #shown(nil))
    end)

    -- Ordinary typing is fzf's, and has to keep being fzf's: a subsequence
    -- across path separators is the thing people actually rely on.
    it("matches a plain query the way fzf does", function()
        assert.are.same({ "nvim/config/init.lua.md" }, shown("nvmcfg"))
    end)

    it("finds nothing for a plain query that matches nothing", function()
        assert.are.same({}, shown("zzzzz"))
    end)

    it("matches romaji after a slash", function()
        assert.are.same({ "会議メモ.md" }, shown("/kaigi"))
    end)

    -- The case the whole thing exists for: nothing in the path is Japanese.
    it("matches a heading when the filename is ASCII", function()
        assert.are.same({ "1on1 Suzuki.md" }, shown("/tanaka"))
    end)

    -- ...but not the body. Otherwise this quietly becomes content search and no
    -- picker is left answering "which note is this".
    it("does not match body text that is not a heading", function()
        assert.is_false(vim.tbl_contains(shown("/tanaka"), "plan.md"))
    end)

    -- Without the slash the same letters are just letters, so a note is not
    -- silently found by a mode you did not ask for.
    it("does not apply romaji to a plain query", function()
        assert.are.same({}, shown("kaigi"))
    end)

    it("matches paths only when headings are turned off", function()
        setup({ romaji = { headings = false } })
        assert.are.same({}, shown("/tanaka"))
        assert.are.same({ "会議メモ.md" }, shown("/kaigi"))
    end)

    -- A bare slash is the start of typing, not a filter that matches nothing.
    it("shows everything for a bare slash", function()
        assert.are.equal(5, #shown("/"))
    end)

    -- The backend is installed but cannot answer -- ttyskk missing its
    -- dictionary, kensaku waiting on denops. Emptying the picker would look
    -- exactly like a filter that found nothing.
    it("falls back to plain matching when the backend cannot answer", function()
        assert.are.same({ "readme.md" }, shown("/readme"))
    end)

    it("lists bare paths, so opening one still works", function()
        local list = shown("/tanaka")
        assert.are.equal(1, vim.fn.filereadable(home .. "/" .. list[1]))
    end)

    -- The list comes from `rg --files` rather than a glob, and rg reads
    -- .gitignore. A collection that ignores a directory of notes -- generated
    -- ones, a vendored archive -- would otherwise find them gone from the finder
    -- the day this changed, with nothing to say why.
    it("lists a note its .gitignore hides", function()
        note(".gitignore", { "generated/" })
        note("generated/報告.md", { "# 田中" })
        assert.is_truthy(vim.tbl_contains(shown(""), "generated/報告.md"))
        -- ...and it is indexed, not merely listed: its heading answers too.
        assert.is_truthy(vim.tbl_contains(shown("/tanaka"), "generated/報告.md"))
    end)

    -- The list is shelled out to now, and a command run in a directory that is
    -- not there raises where a glob simply found nothing. `home` pointing
    -- somewhere absent is a configuration mistake `:checkhealth` names by
    -- itself; opening a picker should not also throw at whoever opened it.
    it("comes up empty when home does not exist, rather than throwing", function()
        setup({ home = home .. "/gone" })
        local ok, list = pcall(t.note_index)
        assert.is_true(ok)
        assert.are.same({}, list)
    end)

    it("survives a note it cannot read", function()
        note("locked.md", { "# 田中" })
        vim.fn.setfperm(home .. "/locked.md", "-w-------")
        local ok, list = pcall(shown, "/tanaka")
        vim.fn.setfperm(home .. "/locked.md", "rw-r--r--")
        assert.is_true(ok)
        assert.is_truthy(vim.tbl_contains(list, "1on1 Suzuki.md"))
    end)
end)

describe("the note finder's header", function()
    before_each(function()
        home = vim.fn.tempname()
        vim.fn.mkdir(home, "p")
    end)

    after_each(function()
        if home then
            vim.fn.delete(home, "rf")
            home = nil
        end
    end)

    -- A key you have to remember is a key you do not use, so the header says
    -- what `/` does, with an example rather than a description of one.
    it("says what the slash does", function()
        setup()
        local header = t.find_header()
        assert.is_truthy(header:find("/", 1, true))
        assert.is_truthy(header:find("kaigi", 1, true))
        assert.is_truthy(header:find("会議", 1, true))
    end)

    -- ...and does not offer it when nothing can honour it.
    it("says nothing when there is no romaji backend", function()
        setup({ romaji = { backend = false } })
        assert.are.equal("", t.find_header())
    end)
end)
