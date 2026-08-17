-- The note finder, and the two ways of typing into it.
--
-- A plain query is fzf's, unchanged: `nvmcfg` finds `nvim/config/init.lua`,
-- ranked the way fzf ranks it. A query beginning with `/` is romaji: `/kaigi`
-- finds 会議.
--
-- The `/` is there because fzf matches literally and cannot be taught about
-- Japanese, so a romaji query has to be narrowed outside it. The token is
-- borrowed from fzf-jp-extension, which patches it into fzf itself.
--
-- There are two ways that narrowing happens, and both are here:
--
--   the shell side  fzf runs a script fzfkasten writes, so ordinary typing never
--                   leaves fzf at all. Needs fzf 0.45 and a backend a shell can
--                   run (ttyskk). See "the note finder's shell side".
--   in here         everything else -- kensaku, a backend of your own, an old
--                   fzf. fzf's matching is off (`--disabled`) and every
--                   keystroke asks Neovim, so ordinary typing needs a fuzzy
--                   matcher of its own: `vim.fn.matchfuzzy()`.
--
-- "the way fzf does" below is the case that pins that matcher: it replaced a
-- `fzf --filter` per keystroke (4.5ms here, 166ms on WSL2) and has to keep
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
    t.forget_index()
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

-- The finder hands romaji narrowing to fzf when the backend is a program fzf can
-- run, so that ordinary typing never leaves this process. What fzf then runs is
-- two scripts fzfkasten writes; these cases run them the way fzf would.
describe("the note finder's shell side", function()
    local migemo

    before_each(function()
        home = vim.fn.tempname()
        vim.fn.mkdir(home, "p")
        note("会議メモ.md", { "# notes" })
        note("1on1 Suzuki.md", { "# 田中さんと打ち合わせ" })
        note("readme.md", { "# Readme" })

        -- Stands in for `ttyskk migemo --flavour rg`: romaji in, an rg pattern
        -- out. Anything else answers with the romaji itself, so that probing it
        -- for availability succeeds.
        migemo = home .. "/migemo.sh"
        vim.fn.writefile({
            "#!/bin/sh",
            'for last; do :; done',
            'case "$last" in',
            '  kaigi)  echo "(?:kaigi|かいぎ|会議)" ;;',
            '  tanaka) echo "(?:tanaka|たなか|田中)" ;;',
            '  *)      echo "$last" ;;',
            "esac",
        }, migemo)
        vim.fn.setfperm(migemo, "rwx------")
        setup({ romaji = { backend = "ttyskk", ttyskk = { cmd = migemo } } })
    end)

    after_each(function()
        if home then
            vim.fn.delete(home, "rf")
            home = nil
        end
    end)

    -- What fzf would run for a given query, as fzf runs it.
    local function via_shell(binds, query)
        local script = binds["change"]:match("transform:'(.-)'")
        local decided = vim.fn.systemlist({ script, query })[1] or ""
        local romaji_sh = decided:match("reload:'(.-)'")
        if not romaji_sh then return nil, decided end
        local list = vim.fn.systemlist({ romaji_sh, query })
        table.sort(list)
        return list, decided
    end

    it("takes the shell path when the backend is a program", function()
        local binds = t.shell_binds(t.note_index())
        if not binds then
            return pending("needs rg and fzf 0.45 or newer")
        end
        assert.are.equal("+unbind(change)", binds["start"])
        assert.is_truthy(binds["change"]:match("^transform:"))
        assert.is_truthy(binds["/"]:match("rebind%(change%)"))
    end)

    it("narrows by romaji out there, the way it does in here", function()
        local binds = t.shell_binds(t.note_index())
        if not binds then return pending("needs rg and fzf 0.45 or newer") end

        assert.are.same({ "会議メモ.md" }, (via_shell(binds, "/kaigi")))
        -- The case the headings are indexed for: nothing in the path is Japanese.
        assert.are.same({ "1on1 Suzuki.md" }, (via_shell(binds, "/tanaka")))
    end)

    it("shows every note when the migemo answers nothing", function()
        local binds = t.shell_binds(t.note_index())
        if not binds then return pending("needs rg and fzf 0.45 or newer") end
        -- An empty answer is a backend that cannot answer, not a filter that
        -- found nothing -- so the picker must not empty itself.
        vim.fn.writefile({ "#!/bin/sh", "exit 0" }, migemo)
        vim.fn.setfperm(migemo, "rwx------")
        assert.are.equal(3, #(via_shell(binds, "/kaigi")))
    end)

    -- A slash typed inside a query is a slash: paths are full of them, and the
    -- `/` bind only fires on an empty query.
    it("leaves fzf's own matching alone for a plain query", function()
        local binds = t.shell_binds(t.note_index())
        if not binds then return pending("needs rg and fzf 0.45 or newer") end
        local list, decided = via_shell(binds, "lognote/2026")
        assert.is_nil(list)
        assert.is_truthy(decided:match("unbind%(change%)"))
    end)

    -- kensaku runs on denops and a table of your own is Lua; neither can be run
    -- by fzf, so those keep the live picker.
    it("stays out of the shell for a backend that cannot leave Neovim", function()
        setup() -- the table backend the rest of this file uses
        assert.is_nil(t.shell_binds(t.note_index()))
    end)
end)

-- Reading every note's headings is what opening the finder costs (455ms over 494
-- notes on the WSL2 machine), so they are kept between openings. These are the
-- cases that say what that keeping is allowed to get wrong.
describe("the note finder's heading cache", function()
    before_each(function()
        home = vim.fn.tempname()
        vim.fn.mkdir(home, "p")
        note("plan.md", { "# Plan" })
        setup()
        shown("") -- warm it
    end)

    after_each(function()
        if home then
            vim.fn.delete(home, "rf")
            home = nil
        end
    end)

    -- The file list is walked every time, so this must hold however warm the
    -- cache is: a note written a moment ago has to be findable.
    it("finds a note created since it was warmed", function()
        note("新規.md", { "# 田中" })
        assert.is_truthy(vim.tbl_contains(shown(""), "新規.md"))
        assert.is_truthy(vim.tbl_contains(shown("/tanaka"), "新規.md"))
    end)

    it("stops listing a note that has been deleted", function()
        vim.fn.delete(home .. "/plan.md")
        assert.are.same({}, shown(""))
    end)

    -- What it is allowed to get wrong, said out loud: a heading added by
    -- something that is not this Neovim -- a git pull, another machine, Claude
    -- writing to a note in a pane -- is not seen until the note is written here
    -- or the cache goes stale. The note is still listed; only the heading lags.
    it("does not see a heading added behind its back", function()
        note("plan.md", { "# Plan", "# 田中さん" })
        assert.are.same({}, shown("/tanaka"))
        assert.is_truthy(vim.tbl_contains(shown(""), "plan.md"))
    end)

    it("sees it once the cache has gone stale", function()
        note("plan.md", { "# Plan", "# 田中さん" })
        t.age_index(400)
        assert.are.same({ "plan.md" }, shown("/tanaka"))
    end)

    -- How long that takes is the caller's to set, because what it is worth
    -- depends on what reading the collection costs on the machine.
    it("takes how long to keep them from the configuration", function()
        setup({ find = { headings_stale_after = 60 } })
        shown("")
        note("plan.md", { "# Plan", "# 田中さん" })
        t.age_index(90)
        assert.are.same({ "plan.md" }, shown("/tanaka"))
    end)

    -- ...including not keeping them at all, which is what the finder did before
    -- there was a cache.
    it("reads them every time when told to keep nothing", function()
        setup({ find = { headings_stale_after = 0 } })
        shown("")
        note("plan.md", { "# Plan", "# 田中さん" })
        assert.are.same({ "plan.md" }, shown("/tanaka"))
    end)

    -- ...and immediately when the write is one it could see.
    it("sees a heading written from a buffer in this Neovim", function()
        vim.cmd.edit(home .. "/plan.md")
        vim.api.nvim_buf_set_lines(0, -1, -1, false, { "# 田中さん" })
        vim.cmd.write()
        vim.cmd("bwipeout!")
        assert.are.same({ "plan.md" }, shown("/tanaka"))
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
