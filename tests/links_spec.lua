-- Reading a `[[link]]`: the one under the cursor, and the ones pointing back.
--
-- Both are byte-oriented in a collection that is mostly Japanese, so the cases
-- below put multibyte text on either side of the brackets: a column counted in
-- characters where bytes were meant lands mid-glyph, and the link under the
-- cursor becomes no link at all.
--
-- The backlink walk is here for a second reason. `[[note#見出し]]` is a link to
-- `note`, and following and renaming both learned that; the backlink list had
-- not, so an anchored link left no trace on the note it pointed at -- and the
-- list says "No backlinks found", which is what a note nobody links to says.

local config = require("fzfkasten.config")
local pickers = require("fzfkasten.pickers")
local t = pickers._test

local home

local function setup()
    home = vim.fn.tempname()
    vim.fn.mkdir(home, "p")
    config.setup({ home = home })
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

describe("link_under_cursor", function()
    before_each(function()
        vim.cmd("enew!")
    end)

    after_each(function()
        pcall(vim.cmd, "silent! %bwipeout!")
    end)

    -- `col` is a 1-based *byte* column, the same thing Vim's `col('.')` reports.
    local function at(line, col)
        vim.api.nvim_buf_set_lines(0, 0, -1, false, { line })
        vim.api.nvim_win_set_cursor(0, { 1, col - 1 })
        return t.link_under_cursor()
    end

    it("reads the link the cursor is inside", function()
        assert.are.equal("note", at("see [[note]] here", 8))
    end)

    -- The brackets are part of the link: `gf` with the cursor on the first `[`
    -- has to follow it, since that is where you land coming from the left.
    it("counts the brackets as part of the link", function()
        assert.are.equal("note", at("see [[note]] here", 5))
        assert.are.equal("note", at("see [[note]] here", 12))
    end)

    it("finds nothing outside the brackets", function()
        assert.is_nil(at("see [[note]] here", 4))
        assert.is_nil(at("see [[note]] here", 13))
    end)

    it("finds nothing on a line with no link", function()
        assert.is_nil(at("just some prose", 5))
    end)

    -- Pins the loop that steps past a match: reading only the first link on the
    -- line would answer "a" wherever the cursor was.
    it("picks the link the cursor is in, not the first on the line", function()
        local line = "[[a]] and [[b]]"
        assert.are.equal("a", at(line, 3))
        assert.are.equal("b", at(line, 13))
        assert.is_nil(at(line, 7))
    end)

    it("hands back the anchor and alias untouched", function()
        assert.are.equal("note#見出し|別名", at("see [[note#見出し|別名]] here", 8))
    end)

    -- Where a character column and a byte column disagree. "会議録の話 " is 5
    -- CJK characters plus a space: 6 characters, 16 bytes. Byte 17 is the `[`;
    -- character 7 is also the `[`, but byte 7 is the middle of 議.
    it("counts columns in bytes, not characters", function()
        local line = "会議録の話 [[note]] を読む"
        assert.are.equal("note", at(line, 17))
        assert.is_nil(at(line, 7))
    end)

    it("reads a link whose name is multibyte", function()
        local line = "きょうは [[会議録#議事]] を見た"
        -- "きょうは " is 4 kana (12 bytes) plus a space: the `[` is byte 14.
        assert.are.equal("会議録#議事", at(line, 16))
    end)

    -- "[[]]" is matched but empty, and the callers treat an empty name as no
    -- link -- so it must come back as "" rather than as nil, which would send
    -- `follow_link` to its whole-buffer picker instead of doing nothing.
    it("reads an empty link as an empty name", function()
        assert.are.equal("", at("an empty [[]] link", 11))
    end)
end)

describe("collect_backlinks", function()
    before_each(setup)
    after_each(cleanup)

    local function entries(filepath)
        local found = t.collect_backlinks(filepath)
        return found or {}
    end

    -- Just the file names, so a case can say what it found without repeating
    -- line numbers and text it does not care about.
    local function sources(filepath)
        local names = {}
        for _, entry in ipairs(entries(filepath)) do
            names[#names + 1] = entry:match("^(.-):%d+: ")
        end
        table.sort(names)
        return names
    end

    it("finds a plain link", function()
        local target = note("note.md", { "# 本体" })
        note("from.md", { "see [[note]]" })
        assert.are.same({ "from.md" }, sources(target))
    end)

    it("finds a link with an alias", function()
        local target = note("note.md", { "# 本体" })
        note("from.md", { "see [[note|別名]]" })
        assert.are.same({ "from.md" }, sources(target))
    end)

    -- The bug these exist for: an anchored link is a link to the note, and the
    -- note showed no sign of it.
    it("finds a link with an anchor", function()
        local target = note("note.md", { "# 本体", "## 見出し" })
        note("from.md", { "see [[note#見出し]]" })
        assert.are.same({ "from.md" }, sources(target))
    end)

    it("finds a link with both an anchor and an alias", function()
        local target = note("note.md", { "# 本体" })
        note("from.md", { "see [[note#見出し|別名]]" })
        assert.are.same({ "from.md" }, sources(target))
    end)

    -- ...and does not become a substring search on the way.
    it("does not match a note whose name merely starts the same", function()
        local target = note("note.md", { "# 本体" })
        note("from.md", { "see [[note-old]] and [[notebook]] and [[my note]]" })
        assert.are.same({}, sources(target))
    end)

    it("ignores the note's own links to itself", function()
        local target = note("note.md", { "# 本体", "see [[note]]" })
        note("from.md", { "see [[note]]" })
        assert.are.same({ "from.md" }, sources(target))
    end)

    -- The same file spelt another way is still the same file, and a collection
    -- reached through a symlink is the ordinary way that happens -- a notes
    -- directory that lives in a synced folder, say. Which side carries the
    -- symlink depends on how the note was opened, so both are here: listing a
    -- note as linking to itself is the visible symptom either way.
    local function symlinked(target)
        local link = vim.fn.tempname()
        vim.fn.system({ "ln", "-s", target, link })
        if vim.v.shell_error ~= 0 then
            print("cannot create a symlink here; skipping")
            return nil
        end
        return link
    end

    it("ignores itself when handed a path through a symlink", function()
        note("note.md", { "# 本体", "see [[note]]" })
        note("from.md", { "see [[note]]" })
        local link = symlinked(home)
        if not link then return end
        assert.are.same({ "from.md" }, sources(link .. "/note.md"))
        vim.fn.delete(link)
    end)

    it("ignores itself when the notes directory is itself a symlink", function()
        local real = home
        note("note.md", { "# 本体", "see [[note]]" })
        note("from.md", { "see [[note]]" })
        local link = symlinked(real)
        if not link then return end
        -- The collection is reached through the link; the note was opened by
        -- its real path, as a `:edit` of a resolved buffer name gives.
        config.setup({ home = link })
        assert.are.same({ "from.md" }, sources(real .. "/note.md"))
        vim.fn.delete(link)
    end)

    it("searches notes in subdirectories too", function()
        local target = note("note.md", { "# 本体" })
        note("daily/2026-07-29.md", { "打合せ [[note]]" })
        assert.are.same({ "daily/2026-07-29.md" }, sources(target))
    end)

    it("reports each line once, however many links it holds", function()
        local target = note("note.md", { "# 本体" })
        note("from.md", { "[[note]] and [[note#見出し]] again" })
        assert.are.equal(1, #entries(target))
    end)

    it("reports every line that links, and says which", function()
        local target = note("note.md", { "# 本体" })
        note("from.md", { "one", "see [[note]]", "three", "また [[note]] へ" })
        assert.are.same({
            "from.md:2: see [[note]]",
            "from.md:4: また [[note]] へ",
        }, entries(target))
    end)

    it("trims the line it shows", function()
        local target = note("note.md", { "# 本体" })
        note("from.md", { "    - see [[note]]   " })
        assert.are.same({ "from.md:1: - see [[note]]" }, entries(target))
    end)

    -- The path has to be relative to the notes directory: that is what the
    -- picker's action resolves it against, and a path relative to whatever
    -- directory Vim happens to be in would have the notes directory prepended
    -- to it and open nothing.
    it("gives a path that resolves against the notes directory", function()
        local target = note("note.md", { "# 本体" })
        note("daily/2026-07-29.md", { "[[note]]" })
        local rel = entries(target)[1]:match("^(.-):%d+: ")
        assert.are.equal("daily/2026-07-29.md", rel)
        assert.are.equal(1, vim.fn.filereadable(home .. "/" .. rel))
    end)

    it("finds nothing when nothing links", function()
        local target = note("note.md", { "# 本体" })
        note("from.md", { "no links here" })
        assert.are.same({}, entries(target))
    end)

    it("refuses a path it cannot read a name from", function()
        assert.is_nil(t.collect_backlinks(nil))
        assert.is_nil(t.collect_backlinks("v:null"))
        assert.is_nil(t.collect_backlinks(42))
    end)
end)

describe("get_note_name", function()
    it("drops the extension", function()
        assert.are.equal("my_note", t.get_note_name("/home/x/notes/my_note.md"))
        assert.are.equal("2026-07-29", t.get_note_name("daily/2026-07-29.md"))
        assert.are.equal("会議録", t.get_note_name("/home/x/notes/会議録.md"))
    end)

    -- Only the last one: a note called "note.v2" keeps its dot.
    it("drops only the last extension", function()
        assert.are.equal("note.v2", t.get_note_name("note.v2.md"))
    end)

    it("leaves a name with no extension alone", function()
        assert.are.equal("my_note", t.get_note_name("my_note"))
    end)

    -- A leading dot is not an extension separator. Read as one it gives the
    -- empty name, which every empty link "[[]]" would then be a backlink to.
    it("does not read a leading dot as an extension", function()
        assert.are.equal(".bashrc", t.get_note_name(".bashrc"))
    end)

    it("refuses what is not a path", function()
        assert.is_nil(t.get_note_name(nil))
        assert.is_nil(t.get_note_name(42))
        assert.is_nil(t.get_note_name("v:null"))
    end)
end)
