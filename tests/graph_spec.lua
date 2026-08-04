-- The collection read as a graph.
--
-- What counts as a link is settled in links_spec; what is pinned here is what
-- the graph makes of them. Three of its answers are only correct by
-- construction and would fail quietly otherwise: a note appears in the tree at
-- its shortest distance (walked depth-first it would hang off whichever branch
-- ran first), a link to a note that was never written still has somewhere to
-- open (the line that names it), and a note reached both ways is one node, not
-- two.

local config = require("fzfkasten.config")
local graph = require("fzfkasten.graph")

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

-- The names on one side of a note, so a case can say what it found without
-- repeating the line numbers and paths it does not care about.
local function names_of(edges, field)
    local names = {}
    for _, edge in ipairs(edges) do
        names[#names + 1] = edge[field]
    end
    return names
end

local function displays(rows)
    local out = {}
    for _, row in ipairs(rows) do
        out[#out + 1] = row.display
    end
    return out
end

describe("build", function()
    before_each(setup)
    after_each(cleanup)

    it("records a link on both sides", function()
        note("a.md", { "see [[b]]" })
        note("b.md", { "# B" })
        local g = graph.build()
        assert.are.same({ "b" }, names_of(g.out["a"], "to"))
        assert.are.same({ "a" }, names_of(g.back["b"], "from"))
        assert.are.same({}, g.out["b"])
        assert.are.same({}, g.back["a"])
    end)

    it("reads an alias and an anchor as links to the note", function()
        note("a.md", { "[[b|別名]]" })
        note("c.md", { "[[b#見出し]]" })
        note("d.md", { "[[b#見出し|別名]]" })
        note("b.md", { "# B" })
        assert.are.same({ "a", "c", "d" }, names_of(graph.build().back["b"], "from"))
    end)

    -- A link written as a path names the same note, so it is the same edge --
    -- and the dead-link list, which is where these used to end up, is left
    -- saying only what is genuinely missing.
    it("reads a link written as a path as a link to the note", function()
        note("lognote/2025-W34.md", { "# 第34週" })
        note("a.md", { "[[lognote/2025-W34]] と [[lognote/2025-W34.md]]" })
        local g = graph.build()
        assert.are.same({ "2025-W34" }, names_of(g.out["a"], "to"))
        assert.are.same({}, graph.dead_links(g))
    end)

    it("counts a note linked twice as one link", function()
        note("a.md", { "[[b]]", "また [[b#見出し]] へ", "[[b|別名]]" })
        note("b.md", { "# B" })
        local g = graph.build()
        assert.are.equal(1, #g.out["a"])
        -- The first line, so a link is reported where it is first written.
        assert.are.equal(1, g.out["a"][1].lineno)
    end)

    it("counts every note a note links to", function()
        note("a.md", { "[[b]] と [[c]]", "[[d]]" })
        note("b.md", { "# B" })
        assert.are.same({ "b", "c", "d" }, names_of(graph.build().out["a"], "to"))
    end)

    it("is not its own neighbour", function()
        note("a.md", { "# A", "[[a]]" })
        local g = graph.build()
        assert.are.same({}, g.out["a"])
        assert.are.same({}, g.back["a"])
    end)

    it("ignores an empty link", function()
        note("a.md", { "an empty [[]] link" })
        assert.are.same({}, graph.build().out["a"])
    end)

    -- A note is its name, wherever it is filed: that is what a link can say.
    it("reads notes in subdirectories, under their name", function()
        note("daily/2026-07-29.md", { "打合せ [[a]]" })
        note("a.md", { "# A" })
        local g = graph.build()
        assert.are.same({ "2026-07-29" }, names_of(g.back["a"], "from"))
        assert.are.same({ "daily/2026-07-29.md" }, g.paths["2026-07-29"])
        -- The edge still knows where it was written, which is what the pickers
        -- open and preview.
        assert.are.same({ "daily/2026-07-29.md" }, names_of(g.back["a"], "rel"))
    end)

    -- A link names a note, not a path, and `follow_link` offers both files when
    -- asked to open one. Two nodes here would split a note's links in half.
    it("merges notes that share a name", function()
        note("a.md", { "[[b]]" })
        note("old/a.md", { "[[c]]" })
        local g = graph.build()
        assert.are.same({ "a.md", "old/a.md" }, g.paths["a"])
        assert.are.same({ "b", "c" }, names_of(g.out["a"], "to"))
    end)

    it("leaves out the directories graph.ignore_dirs names", function()
        note("templates/daily.md", { "[[{{title}}]]" })
        note("a.md", { "# A" })
        local g = graph.build()
        assert.is_nil(g.paths["daily"])
        assert.are.same({ "a" }, g.names)
    end)

    it("keeps a directory whose name merely starts the same", function()
        note("templates-old/x.md", { "# X" })
        assert.is_not_nil(graph.build().paths["x"])
    end)

    -- `[[` is a link in prose and a pair of brackets in a shell. Read as prose,
    -- `if [[ ! -f ~/.config/x ]]` links to a note called `! -f ~/.config/x`,
    -- and a collection that keeps command lines in it fills the dead-link list
    -- with them.
    describe("a fenced code block", function()
        it("is not read for links", function()
            note("a.md", {
                "[[real]]",
                "```bash",
                "if [[ ! -f ~/.config/x ]]; then",
                "```",
                "[[also-real]]",
            })
            assert.are.same({ "real", "also-real" }, names_of(graph.build().out["a"], "to"))
        end)

        it("is closed by its fence, whatever the fence said", function()
            note("a.md", { "```lua", "[[hidden]]", "```", "[[shown]]" })
            assert.are.same({ "shown" }, names_of(graph.build().out["a"], "to"))
        end)

        it("is fenced by tildes too", function()
            note("a.md", { "~~~", "[[hidden]]", "~~~" })
            assert.are.same({}, graph.build().out["a"])
        end)

        it("is one indented up to three spaces, as markdown has it", function()
            note("a.md", { "   ```", "[[hidden]]", "   ```" })
            assert.are.same({}, graph.build().out["a"])
        end)

        it("left unclosed swallows the rest of the note, as a renderer has it", function()
            note("a.md", { "[[before]]", "```", "[[after]]" })
            assert.are.same({ "before" }, names_of(graph.build().out["a"], "to"))
        end)
    end)

    -- A note explaining its own conventions writes "`#tag`, `@tag`, `[[tag]]`",
    -- and that is an example of a link, not a link to a note called `tag`.
    describe("inline code", function()
        it("is not read for links", function()
            note("a.md", { "書き方は `#tag` や `[[tag]]` など。[[real]] は本物。" })
            assert.are.same({ "real" }, names_of(graph.build().out["a"], "to"))
        end)

        it("leaves a line with one unclosed backtick alone", function()
            note("a.md", { "` の使い方と [[real]]" })
            assert.are.same({ "real" }, names_of(graph.build().out["a"], "to"))
        end)

        it("keeps the line it shows as it was written", function()
            note("a.md", { "`[[tag]]` のような書き方で [[real]] へ" })
            assert.are.equal("`[[tag]]` のような書き方で [[real]] へ",
                graph.build().out["a"][1].line)
        end)
    end)
end)

describe("tree", function()
    before_each(setup)
    after_each(cleanup)

    it("shows both directions, marked", function()
        note("root.md", { "[[out]]" })
        note("out.md", { "# Out" })
        note("in.md", { "[[root]]" })
        assert.are.same({
            "├─ → out",
            "└─ ← in",
        }, displays(graph.tree(graph.build(), "root", 1)))
    end)

    it("shows a note linked both ways once", function()
        note("root.md", { "[[both]]" })
        note("both.md", { "[[root]]" })
        assert.are.same({ "└─ ↔ both" }, displays(graph.tree(graph.build(), "root", 1)))
    end)

    it("stops at the depth it was given", function()
        note("root.md", { "[[one]]" })
        note("one.md", { "[[two]]" })
        note("two.md", { "[[three]]" })
        assert.are.same({ "└─ → one" }, displays(graph.tree(graph.build(), "root", 1)))
        assert.are.same({
            "└─ → one",
            "   └─ → two",
        }, displays(graph.tree(graph.build(), "root", 2)))
    end)

    it("draws the branches it walks through", function()
        note("root.md", { "[[a]] [[b]]" })
        note("a.md", { "[[deep]]" })
        note("b.md", { "# B" })
        note("deep.md", { "# Deep" })
        assert.are.same({
            "├─ → a",
            "│  └─ → deep",
            "└─ → b",
        }, displays(graph.tree(graph.build(), "root", 2)))
    end)

    -- Breadth-first is the whole of this: `near` is one link from the root and
    -- also two links away through `far`. Walked depth-first it would be drawn
    -- under `far`, three levels in, and the root's own link to it would show
    -- nowhere.
    it("hangs a note off the shortest way to reach it", function()
        note("root.md", { "[[far]] [[near]]" })
        note("far.md", { "[[near]]" })
        note("near.md", { "# Near" })
        assert.are.same({
            "├─ → far",
            "└─ → near",
        }, displays(graph.tree(graph.build(), "root", 3)))
    end)

    it("does not spin on a cycle", function()
        note("root.md", { "[[a]]" })
        note("a.md", { "[[b]]" })
        note("b.md", { "[[root]]" })
        -- root -> a -> b -> root. Both of the root's neighbours are one link
        -- away, in opposite directions, and there is nowhere left to go: a
        -- cycle is walked once and closes.
        assert.are.same({
            "├─ → a",
            "└─ ← b",
        }, displays(graph.tree(graph.build(), "root", 5)))
    end)

    it("says nothing where there is nothing", function()
        note("root.md", { "# Root" })
        assert.are.same({}, graph.tree(graph.build(), "root", 2))
    end)

    describe("a link to a note that does not exist", function()
        it("is marked as one", function()
            note("root.md", { "# Root", "書きかけ [[未作成]]" })
            assert.are.same({ "└─ → 未作成  (no note)" },
                displays(graph.tree(graph.build(), "root", 1)))
        end)

        -- There is no note to open, so the row opens the line that names it --
        -- the only place that note exists at all.
        it("opens the line naming it", function()
            note("root.md", { "# Root", "書きかけ [[未作成]]" })
            local row = graph.tree(graph.build(), "root", 1)[1]
            assert.is_true(row.missing)
            assert.are.equal("root.md", row.rel)
            assert.are.equal(2, row.lineno)
        end)

        it("gathers the notes naming it", function()
            note("root.md", { "[[未作成]]" })
            note("other.md", { "[[未作成]]" })
            assert.are.same({
                "└─ → 未作成  (no note)",
                "   └─ ← other",
            }, displays(graph.tree(graph.build(), "root", 2)))
        end)
    end)

    it("opens a note it links to at the top, and one linking back at the link",
        function()
            note("root.md", { "[[out]]" })
            note("out.md", { "# Out" })
            note("in.md", { "# In", "", "ここで [[root]] に触れた" })
            local rows = graph.tree(graph.build(), "root", 1)
            assert.are.same({ rel = "out.md", lineno = 1 }, { rel = rows[1].rel, lineno = rows[1].lineno })
            assert.are.same({ rel = "in.md", lineno = 3 }, { rel = rows[2].rel, lineno = rows[2].lineno })
        end)
end)

-- The command reads the current buffer's name, and there is not always one:
-- run from a dashboard or a scratch buffer it used to fail with "Could not
-- determine note name from path: " and nothing after the colon.
describe("link_tree", function()
    local fzf = require("fzf-lua")
    local original, opened

    before_each(function()
        setup()
        opened = {}
        original = { files = fzf.files, exec = fzf.fzf_exec }
        fzf.files = function(opts) opened.files = opts end
        fzf.fzf_exec = function(entries, opts) opened.exec = { entries = entries, opts = opts } end
    end)

    after_each(function()
        fzf.files, fzf.fzf_exec = original.files, original.exec
        cleanup()
    end)

    it("asks which note when the buffer has no file", function()
        note("a.md", { "[[b]]" })
        note("b.md", { "# B" })
        graph.link_tree("")
        assert.is_not_nil(opened.files)
        assert.is_nil(opened.exec)
    end)

    it("asks which note when the file is not in the collection", function()
        note("a.md", { "[[b]]" })
        graph.link_tree("/tmp/somewhere/else.md")
        assert.is_not_nil(opened.files)
    end)

    it("draws the tree for the note it was given, under its own row", function()
        note("a.md", { "[[b]]" })
        note("b.md", { "# B" })
        graph.link_tree(home .. "/a.md")
        assert.is_nil(opened.files)
        assert.are.same({ "a.md:1: ● a", "b.md:1: └─ → b" }, opened.exec.entries)
    end)

    -- A note of the collection that is joined to nothing is a fair answer, not
    -- a reason to ask for another note.
    it("says so for a note with nothing joined to it", function()
        note("alone.md", { "# Alone" })
        graph.link_tree(home .. "/alone.md")
        assert.is_nil(opened.files)
        assert.is_nil(opened.exec)
    end)

    it("takes a depth for one call, and never one below 1", function()
        note("a.md", { "[[b]]" })
        note("b.md", { "[[c]]" })
        note("c.md", { "# C" })
        graph.link_tree(home .. "/a.md", 1)
        assert.are.equal(2, #opened.exec.entries) -- the root and `b`
        graph.link_tree(home .. "/a.md", 0)
        assert.are.equal(2, #opened.exec.entries)
    end)
end)

describe("orphans", function()
    before_each(setup)
    after_each(cleanup)

    it("finds the notes joined to nothing", function()
        note("linked.md", { "[[target]]" })
        note("target.md", { "# Target" })
        note("alone.md", { "# Alone" })
        note("daily/also-alone.md", { "# Also" })
        assert.are.same({ "alone.md", "daily/also-alone.md" }, graph.orphans(graph.build()))
    end)

    -- A note whose only link points nowhere is still a note that reaches out,
    -- and it is in the dead-link list already. Calling it an orphan too would
    -- report the same broken link twice, in two lists that mean different
    -- things.
    it("does not count a note whose only link is broken", function()
        note("reaching.md", { "[[未作成]]" })
        assert.are.same({}, graph.orphans(graph.build()))
    end)

    it("lists both files when two notes share a name", function()
        note("a.md", { "# A" })
        note("old/a.md", { "# A" })
        assert.are.same({ "a.md", "old/a.md" }, graph.orphans(graph.build()))
    end)
end)

describe("dead_links", function()
    before_each(setup)
    after_each(cleanup)

    it("finds links no note answers to", function()
        note("a.md", { "# A", "[[real]] と [[未作成]]" })
        note("real.md", { "# Real" })
        local dead = graph.dead_links(graph.build())
        assert.are.equal(1, #dead)
        assert.are.same({ from = "a", to = "未作成", rel = "a.md", lineno = 2 }, {
            from = dead[1].from, to = dead[1].to, rel = dead[1].rel, lineno = dead[1].lineno,
        })
    end)

    it("reports each note naming it", function()
        note("a.md", { "[[未作成]]" })
        note("b.md", { "[[未作成]]" })
        assert.are.same({ "a", "b" }, names_of(graph.dead_links(graph.build()), "from"))
    end)

    it("finds nothing when every link lands", function()
        note("a.md", { "[[b]]" })
        note("b.md", { "# B" })
        assert.are.same({}, graph.dead_links(graph.build()))
    end)
end)

describe("hubs", function()
    before_each(setup)
    after_each(cleanup)

    it("ranks by how many links meet there", function()
        note("hub.md", { "# Hub" })
        note("a.md", { "[[hub]]" })
        note("b.md", { "[[hub]]" })
        note("c.md", { "[[hub]] [[a]]" })
        local hubs = graph.hubs(graph.build())
        assert.are.same({ "hub", "a", "c", "b" }, names_of(hubs, "name"))
        assert.are.same({ back = 3, out = 0 }, { back = hubs[1].back, out = hubs[1].out })
    end)

    -- All four notes below have two links each. Being linked to is what makes a
    -- note a place others meet, so it breaks the tie: linking out is something
    -- a note does on its own, and a note that only does that comes last.
    it("puts the note linked to ahead of the note linking out", function()
        note("linked.md", { "# Linked" })
        note("x.md", { "[[linked]]" })
        note("y.md", { "[[linked]]" })
        note("linker.md", { "[[x]] [[y]]" })
        assert.are.same({ "linked", "x", "y", "linker" },
            names_of(graph.hubs(graph.build()), "name"))
    end)

    it("leaves out the notes joined to nothing", function()
        note("a.md", { "[[b]]" })
        note("b.md", { "# B" })
        note("alone.md", { "# Alone" })
        assert.are.same({ "b", "a" }, names_of(graph.hubs(graph.build()), "name"))
    end)

    -- A link to a note that does not exist still counts for the note writing
    -- it: it did the linking, and the note it named is the dead-link list's
    -- business, not this one's.
    it("counts a link that lands nowhere", function()
        note("a.md", { "[[未作成]]" })
        local hubs = graph.hubs(graph.build())
        assert.are.same({ "a" }, names_of(hubs, "name"))
        assert.are.equal(1, hubs[1].out)
    end)
end)
