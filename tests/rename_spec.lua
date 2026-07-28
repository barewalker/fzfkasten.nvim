-- Renaming a note, and the link rewriting that comes with it.
--
-- This is the widest-reaching write in the plugin: it walks every note under
-- `home` and rewrites the ones that link to the old name. A mistake in the
-- matching does not damage one note, it damages the collection -- and quietly,
-- since you find out the next time you follow a link.
--
-- So the cases below care as much about what is *not* rewritten as about what
-- is: a note that merely contains the old name, a link to something else, a
-- different note whose name starts with the same letters.

local config = require("fzfkasten.config")
local core = require("fzfkasten.core")

local home

local function setup(opts)
    home = vim.fn.tempname()
    vim.fn.mkdir(home, "p")
    config.setup(vim.tbl_deep_extend("force", { home = home }, opts or {}))
end

local function cleanup()
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
        local name = vim.api.nvim_buf_get_name(b)
        if home and name:find(home, 1, true) == 1 then
            pcall(vim.api.nvim_buf_delete, b, { force = true })
        end
    end
    if home then
        -- A case may have made a directory read-only to force a failure.
        vim.fn.system({ "chmod", "-R", "u+w", home })
        vim.fn.delete(home, "rf")
        home = nil
    end
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

local function exists(name)
    return vim.fn.filereadable(path(name)) == 1
end

describe("rename_note: rewriting links", function()
    after_each(cleanup)

    before_each(function()
        setup()
        note("old.md", { "# old", "a self link to [[old]]" })
        note("linker.md", {
            "plain [[old]] link",
            "aliased [[old|the old one]] link",
            "unrelated [[other]] link",
            "two on one line: [[old]] and [[other]]",
        })
        note("innocent.md", { "the word old appears here but is not a link" })
    end)

    it("moves the file", function()
        core.rename_note(path("old.md"), "new")
        assert.is_true(exists("new.md"))
        assert.is_false(exists("old.md"))
    end)

    it("rewrites a plain link", function()
        core.rename_note(path("old.md"), "new")
        assert.are.equal("plain [[new]] link", read("linker.md")[1])
    end)

    it("keeps the alias when rewriting", function()
        core.rename_note(path("old.md"), "new")
        assert.are.equal("aliased [[new|the old one]] link", read("linker.md")[2])
    end)

    it("leaves links to other notes alone", function()
        core.rename_note(path("old.md"), "new")
        assert.are.equal("unrelated [[other]] link", read("linker.md")[3])
    end)

    it("rewrites every link on a line without touching the others", function()
        core.rename_note(path("old.md"), "new")
        assert.are.equal("two on one line: [[new]] and [[other]]", read("linker.md")[4])
    end)

    -- Only whole link targets count. A note that talks about the old name, or
    -- one whose own name starts with it, is not a link to it.
    it("does not touch prose that merely contains the name", function()
        local before = read("innocent.md")
        core.rename_note(path("old.md"), "new")
        assert.are.same(before, read("innocent.md"))
    end)

    it("does not touch a link whose target only starts with the old name", function()
        note("prefix.md", { "see [[old-notes]] and [[oldest]]" })
        core.rename_note(path("old.md"), "new")
        assert.are.equal("see [[old-notes]] and [[oldest]]", read("prefix.md")[1])
    end)

    it("rewrites the renamed note's own links to itself", function()
        core.rename_note(path("old.md"), "new")
        assert.are.equal("a self link to [[new]]", read("new.md")[2])
    end)

    it("reaches notes in subdirectories", function()
        note("sub/deep.md", { "down here: [[old]]" })
        core.rename_note(path("old.md"), "new")
        assert.are.equal("down here: [[new]]", read("sub/deep.md")[1])
    end)
end)

describe("rename_note: refusing", function()
    after_each(cleanup)

    before_each(function()
        setup()
        note("old.md", { "# old" })
        note("linker.md", { "link to [[old]]" })
    end)

    -- Renaming onto an existing note would lose one of them, and the links
    -- would point at whichever survived.
    it("refuses when the destination already exists, changing nothing", function()
        note("taken.md", { "# taken" })
        core.rename_note(path("old.md"), "taken")

        assert.is_true(exists("old.md"))
        assert.are.same({ "# taken" }, read("taken.md"))
        assert.are.equal("link to [[old]]", read("linker.md")[1])
    end)

    it("refuses a name that sanitizes to nothing", function()
        core.rename_note(path("old.md"), "///")
        assert.is_true(exists("old.md"))
        assert.are.equal("link to [[old]]", read("linker.md")[1])
    end)

    -- The order matters more than it looks. Rewriting the links first and then
    -- failing to move the file would leave every link pointing at a name that
    -- does not exist -- the whole collection broken by a rename that did not
    -- happen. Moving first means a failure here changes nothing at all.
    it("leaves the links alone when the file cannot be moved", function()
        vim.fn.mkdir(home .. "/locked", "p")
        note("locked/stuck.md", { "# stuck" })
        note("points.md", { "link to [[stuck]]" })
        vim.fn.system({ "chmod", "500", home .. "/locked" })

        core.rename_note(path("locked/stuck.md"), "moved")

        assert.is_true(exists("locked/stuck.md"), "the file moved despite the directory being read-only")
        assert.is_false(exists("locked/moved.md"))
        assert.are.equal("link to [[stuck]]", read("points.md")[1],
            "links were rewritten for a rename that did not happen")
    end)
end)
