-- Narrowing the note finder by romaji, and what the filter is matched against.
--
-- Matching filenames alone is what a note finder obviously does, and for a
-- Japanese collection it is nearly useless: the notes are written in Japanese
-- but filed under ASCII names. Measured against a real collection of 464 notes,
-- 32 had any Japanese in the filename; 135 carried it in their headings. So the
-- filter ran, narrowed, and found almost nothing -- which reads as "romaji does
-- not work here" rather than "romaji has nothing to match on here".
--
-- Headings and not the whole body, because this picker is for finding a note.
-- Searching bodies is `:FzfKastenSearchContent`.

local config = require("fzfkasten.config")
local pickers = require("fzfkasten.pickers")
local fzf = require("fzf-lua")

local home

local function note(name, lines)
    local full = home .. "/" .. name
    vim.fn.mkdir(vim.fn.fnamemodify(full, ":h"), "p")
    vim.fn.writefile(lines, full)
end

-- Run the picker and return what it would have shown. `nil` for `list` means
-- the unfiltered branch ran (`fzf.files`), which searches nothing itself.
local function shown(fn, filter)
    local seen = {}
    local files, fzf_exec = fzf.files, fzf.fzf_exec
    fzf.files = function(opts) seen.opts, seen.list = opts, nil end
    fzf.fzf_exec = function(list, opts) seen.opts, seen.list = opts, list end
    pcall(fn, filter)
    fzf.files, fzf.fzf_exec = files, fzf_exec
    if seen.list then table.sort(seen.list) end
    return seen.list, seen.opts
end

-- `\m` regexes standing in for what a migemo would build, so these cases do not
-- need ttyskk or kensaku installed.
local KAIGI = [[\m\%(kaigi\|かいぎ\|会議\)]]
local TANAKA = [[\m\%(tanaka\|たなか\|田中\)]]

describe("find_notes: romaji narrowing", function()
    before_each(function()
        home = vim.fn.tempname()
        vim.fn.mkdir(home, "p")
        config.setup({ home = home, romaji = { backend = false } })

        -- Japanese in the name.
        note("会議メモ.md", { "# notes" })
        -- ASCII name, Japanese heading -- the common case.
        note("1on1 Suzuki.md", { "---", "title: 1on1 Suzuki", "---", "", "# 田中さんと打ち合わせ" })
        -- Japanese in the body but not in a heading.
        note("plan.md", { "# Plan", "", "田中さんに連絡する" })
        -- Neither.
        note("readme.md", { "# Readme" })
    end)

    after_each(function()
        if home then
            vim.fn.delete(home, "rf")
            home = nil
        end
    end)

    it("lists everything through fzf.files when there is no filter", function()
        local list, opts = shown(pickers.find_notes, nil)
        assert.is_nil(list)
        assert.are.equal(home, opts.cwd)
    end)

    it("matches a note by its filename", function()
        assert.are.same({ "会議メモ.md" }, shown(pickers.find_notes, KAIGI))
    end)

    -- The case the whole thing exists for: nothing in the path is Japanese, and
    -- before this the note was unreachable by romaji.
    it("matches a note by a heading when its filename is ASCII", function()
        assert.are.same({ "1on1 Suzuki.md" }, shown(pickers.find_notes, TANAKA))
    end)

    -- ...but not by its body. Otherwise this quietly becomes content search,
    -- and there would be no picker left that answers "which note is this".
    it("does not match body text that is not a heading", function()
        local list = shown(pickers.find_notes, TANAKA)
        assert.is_false(vim.tbl_contains(list, "plan.md"), "plan.md matched on its body")
    end)

    it("leaves out what matches nothing", function()
        local list = shown(pickers.find_notes, KAIGI)
        assert.is_false(vim.tbl_contains(list, "readme.md"))
    end)

    it("matches paths only when headings are turned off", function()
        config.setup({ home = home, romaji = { backend = false, headings = false } })
        assert.are.same({}, shown(pickers.find_notes, TANAKA))
        assert.are.same({ "会議メモ.md" }, shown(pickers.find_notes, KAIGI))
    end)

    it("says the list is filtered", function()
        local _, opts = shown(pickers.find_notes, KAIGI)
        assert.are.equal("Notes (romaji)> ", opts.prompt)
    end)

    -- Entries have to stay bare paths relative to `home`: that is what the
    -- action resolves and what the builtin previewer reads.
    it("lists bare paths, so opening one still works", function()
        local list = shown(pickers.find_notes, TANAKA)
        assert.are.equal(1, vim.fn.filereadable(home .. "/" .. list[1]))
    end)

    it("survives a note it cannot read", function()
        note("locked.md", { "# 田中" })
        vim.fn.setfperm(home .. "/locked.md", "-w-------")
        local ok, list = pcall(shown, pickers.find_notes, TANAKA)
        vim.fn.setfperm(home .. "/locked.md", "rw-r--r--")
        assert.is_true(ok)
        assert.is_truthy(vim.tbl_contains(list, "1on1 Suzuki.md"))
    end)
end)

describe("insert_link: romaji narrowing", function()
    before_each(function()
        home = vim.fn.tempname()
        vim.fn.mkdir(home, "p")
        config.setup({ home = home, romaji = { backend = false } })
        note("1on1 Suzuki.md", { "# 田中さんと打ち合わせ" })
        note("readme.md", { "# Readme" })
    end)

    after_each(function()
        if home then
            vim.fn.delete(home, "rf")
            home = nil
        end
    end)

    -- Inserting a link asks the same question as finding a note, so it has to
    -- get the same answer; a note you can find and cannot link to is worse than
    -- one you can do neither with.
    it("finds the same notes the finder does", function()
        assert.are.same({ "1on1 Suzuki.md" }, shown(pickers.insert_link, TANAKA))
    end)

    it("lists everything through fzf.files when there is no filter", function()
        assert.is_nil(shown(pickers.insert_link, nil))
    end)
end)
