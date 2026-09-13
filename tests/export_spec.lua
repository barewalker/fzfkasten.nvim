-- The graph written out as a page.
--
-- What counts as a link is settled in links_spec and what the graph makes of
-- them in graph_spec; what is pinned here is only what the export adds. Three
-- things it does are correct by construction and would fail quietly otherwise:
-- a name no note answers to is still a node, two notes linking to each other
-- are one line rather than two drawn on top of each other, and a degree is
-- counted over the whole graph even when a neighbourhood is drawn.

local config = require("fzfkasten.config")
local graph = require("fzfkasten.graph")
local export = require("fzfkasten.export")

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

-- The whole collection, in the order the export indexes it.
local function everything(g)
    local names, seen = {}, {}
    for _, name in ipairs(g.names) do
        names[#names + 1] = name
        seen[name] = true
    end
    local missing = {}
    for _, edge in ipairs(g.edges) do
        if not seen[edge.to] then
            seen[edge.to] = true
            missing[#missing + 1] = edge.to
        end
    end
    table.sort(missing)
    return vim.list_extend(names, missing)
end

local function node_named(data, name)
    for _, n in ipairs(data.nodes) do
        if n.name == name then return n end
    end
end

describe("data", function()
    before_each(setup)
    after_each(cleanup)

    it("indexes notes and counts both sides", function()
        note("a.md", { "see [[b]]" })
        note("b.md", { "and [[c]]" })
        note("c.md", { "nothing here" })

        local g = graph.build()
        local data = export.data(g, everything(g))

        assert.equals(3, #data.nodes)
        assert.equals(2, #data.links)
        assert.same({ name = "b", path = "b.md", missing = false, back = 1, out = 1 },
            node_named(data, "b"))
    end)

    it("keeps a name no note answers to as a node of its own", function()
        note("a.md", { "see [[never-written]]" })

        local g = graph.build()
        local data = export.data(g, everything(g))

        local missing = node_named(data, "never-written")
        assert.is_true(missing.missing)
        assert.is_nil(missing.path)
        assert.equals(1, missing.back)
        assert.equals(1, #data.links)
    end)

    it("draws a mutual link once", function()
        note("a.md", { "see [[b]]" })
        note("b.md", { "see [[a]]" })

        local g = graph.build()
        local data = export.data(g, everything(g))

        assert.equals(1, #data.links)
    end)

    it("draws a note that names the same target twice once", function()
        note("a.md", { "see [[b]]", "and again [[b]]" })
        note("b.md", { "." })

        local g = graph.build()
        local data = export.data(g, everything(g))

        assert.equals(1, #data.links)
    end)

    it("links by index into the node list", function()
        note("a.md", { "see [[b]]" })
        note("b.md", { "." })

        local g = graph.build()
        local data = export.data(g, everything(g))
        local link = data.links[1]

        -- Zero-based: the page reads them as offsets into its own array.
        assert.equals("a", data.nodes[link.source + 1].name)
        assert.equals("b", data.nodes[link.target + 1].name)
    end)

    it("counts a neighbourhood note's degree over the whole graph", function()
        note("root.md", { "see [[hub]]" })
        note("hub.md", { "see [[x]] [[y]] [[z]]" })
        note("x.md", { "." })
        note("y.md", { "." })
        note("z.md", { "." })

        local g = graph.build()
        -- Only root and hub are drawn, but hub links out three times whether or
        -- not the notes it links to are in the picture.
        local data = export.data(g, { "root", "hub" }, "root")

        assert.equals(2, #data.nodes)
        assert.equals(3, node_named(data, "hub").out)
        -- The links to x, y and z have no node to land on and are left out.
        assert.equals(1, #data.links)
        assert.equals(0, data.root_index)
    end)

    it("leaves the ignored directories out", function()
        note("a.md", { "see [[b]]" })
        note("b.md", { "." })
        note("templates/daily.md", { "[[{{title}}]]" })

        local g = graph.build()
        local data = export.data(g, everything(g))

        assert.is_nil(node_named(data, "daily"))
        assert.is_nil(node_named(data, "{{title}}"))
    end)
end)

describe("render", function()
    before_each(setup)
    after_each(cleanup)

    it("writes the graph into a page that carries its own drawing", function()
        note("a.md", { "see [[b]]" })
        note("b.md", { "." })

        local g = graph.build()
        local html = export.render(export.data(g, everything(g)), "2 notes, whole collection")

        assert.is_string(html)
        assert.is_nil(html:find("{{DATA}}", 1, true))
        assert.is_nil(html:find("{{TITLE}}", 1, true))
        assert.is_truthy(html:find("2 notes, whole collection", 1, true))
        -- Nothing is fetched: the page is the whole thing.
        assert.is_nil(html:find("https://", 1, true))
    end)

    it("does not let a note's name close the script tag it rides in", function()
        note("a.md", { "see [[</script><b>oops]]" })

        local g = graph.build()
        local html = export.render(export.data(g, everything(g)), "test")

        -- One script tag opens the data and one closes it; the name inside is
        -- escaped rather than ending it early.
        local _, closes = html:gsub("</script>", "")
        local _, opens = html:gsub("<script", "")
        assert.equals(opens, closes)
    end)
end)

describe("graph_export", function()
    before_each(setup)
    after_each(cleanup)

    it("writes the page where the config says", function()
        local out = vim.fn.tempname() .. "/graph.html"
        config.setup({ home = home, graph = { export = { path = out, open = false } } })
        note("a.md", { "see [[b]]" })
        note("b.md", { "." })

        local written = export.graph_export(home .. "/a.md")

        assert.equals(out, written)
        assert.equals(1, vim.fn.filereadable(out))
        vim.fn.delete(vim.fn.fnamemodify(out, ":h"), "rf")
    end)

    it("opens the page it wrote", function()
        local out = vim.fn.tempname() .. "/graph.html"
        local opened
        config.setup({ home = home, graph = { export = { path = out,
            open = function(p) opened = p end } } })
        note("a.md", { "see [[b]]" })
        note("b.md", { "." })

        export.graph_export(home .. "/a.md")

        assert.equals(out, opened)
        vim.fn.delete(vim.fn.fnamemodify(out, ":h"), "rf")
    end)

    it("leaves it closed when told to", function()
        local out = vim.fn.tempname() .. "/graph.html"
        config.setup({ home = home, graph = { export = { path = out, open = false } } })
        note("a.md", { "see [[b]]" })
        note("b.md", { "." })

        -- Nothing to observe but the absence of a browser; what is pinned here
        -- is that `false` is honoured rather than read as "some value, so yes".
        assert.equals(out, export.graph_export(home .. "/a.md"))
        vim.fn.delete(vim.fn.fnamemodify(out, ":h"), "rf")
    end)

    it("does not reach for a browser when there is no display to open it on", function()
        if vim.fn.has("linux") == 0 or vim.fn.has("wsl") == 1 then return end

        local out = vim.fn.tempname() .. "/graph.html"
        config.setup({ home = home, graph = { export = { path = out, open = true } } })
        note("a.md", { "see [[b]]" })
        note("b.md", { "." })

        local display, wayland = vim.env.DISPLAY, vim.env.WAYLAND_DISPLAY
        local ui_open, reached = vim.ui.open, false
        vim.env.DISPLAY, vim.env.WAYLAND_DISPLAY = nil, nil
        vim.ui.open = function() reached = true end

        local written = pcall(export.graph_export, home .. "/a.md")

        vim.ui.open = ui_open
        vim.env.DISPLAY, vim.env.WAYLAND_DISPLAY = display, wayland

        assert.is_true(written)
        -- Written all the same: the page is the point, opening it is a
        -- convenience, and one that cannot work here says so instead.
        assert.is_false(reached)
        assert.equals(1, vim.fn.filereadable(out))
        vim.fn.delete(vim.fn.fnamemodify(out, ":h"), "rf")
    end)

    it("refuses a depth around a file that is not in the collection", function()
        note("a.md", { "see [[b]]" })

        assert.is_nil(export.graph_export("", 2))
    end)
end)
