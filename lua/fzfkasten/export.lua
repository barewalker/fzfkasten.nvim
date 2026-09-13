-- The graph as a picture, written out as one HTML file.
--
-- The four pickers answer a question each -- what is this joined to, what is
-- joined to nothing, what points nowhere, where does everything meet. None of
-- them answers "what shape is the collection in", because that is not a
-- question a list has an answer to: you have to see it laid out. So the same
-- `build()` the pickers read is written to a page that draws it.
--
-- The page carries its own layout and drawing, a few hundred lines of it, and
-- loads nothing from anywhere: opened over a tailnet, off a USB stick or from
-- a laptop on a train it draws the same graph. Nothing here talks to a browser
-- either -- the command writes a file and tells you where it is, and how you
-- look at a file is your business, not the plugin's.
local graph = require('fzfkasten.graph')
local config = require('fzfkasten.config')
local utils = require('fzfkasten.utils')

local M = {}

local function export_options()
    return ((config.options.graph or {}).export) or {}
end

--- Every name the graph knows, notes first and in sorted order.
---
--- Names no note answers to are part of the picture rather than an error: a
--- link reaching for a note that was never written is a real edge of the
--- collection, and leaving it out would draw the graph as tidier than it is.
--- @return string[]
local function all_names(g)
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

--- `root` and everything within `depth` links of it, in either direction.
--- The same walk `:FzfKastenLinkTree` draws, read for its names alone.
--- @return string[]
local function near_names(g, root, depth)
    local names, seen = { root }, { [root] = true }
    for _, row in ipairs(graph.tree(g, root, depth)) do
        if not seen[row.name] then
            seen[row.name] = true
            names[#names + 1] = row.name
        end
    end
    return names
end

--- The nodes and links of `names`, in the shape the page reads.
---
--- Degrees are counted over the whole graph even when only a neighbourhood is
--- drawn: how connected a note is does not change because you asked about its
--- corner, and a hub drawn the size of a leaf would be a lie about the note.
---
--- Two notes linking to each other are one line, not two. The page draws no
--- arrowheads -- at a few hundred notes they are noise, and direction is what
--- the panel on the right is for -- so a second line would only be drawn on
--- top of the first.
--- @param g fzfkasten.Graph
--- @param names string[] the nodes to draw, in the order they are indexed
--- @param root string|nil the note at the centre, when there is one
--- @return table
function M.data(g, names, root)
    local index, nodes = {}, {}
    for i, name in ipairs(names) do
        index[name] = i - 1
        local paths = g.paths[name]
        nodes[i] = {
            name = name,
            path = paths and paths[1] or nil,
            missing = paths == nil,
            back = #(g.back[name] or {}),
            out = #(g.out[name] or {}),
        }
    end

    local links, at = {}, {}
    for _, edge in ipairs(g.edges) do
        local s, t = index[edge.from], index[edge.to]
        if s and t then
            at[s] = at[s] or {}
            if at[t] and at[t][s] then
                -- Already drawn the other way round.
            elseif not at[s][t] then
                links[#links + 1] = { source = s, target = t }
                at[s][t] = #links
            end
        end
    end

    return {
        nodes = nodes,
        links = links,
        root_index = root and index[root] or nil,
    }
end

--- The page template, shipped beside the Lua.
---
--- Looked for on the runtimepath first, which is where every plugin manager
--- puts it, and next to this file second, which is where it is when the repo
--- has merely been cloned somewhere and pointed at.
--- @return string|nil
local function template()
    local hits = vim.api.nvim_get_runtime_file("assets/graph.html", false)
    local path = hits[1]
    if not path or vim.fn.filereadable(path) == 0 then
        local here = debug.getinfo(1, "S").source:sub(2)
        path = vim.fn.fnamemodify(here, ":p:h:h:h") .. "/assets/graph.html"
    end
    if vim.fn.filereadable(path) == 0 then
        return nil
    end
    local ok, lines = pcall(vim.fn.readfile, path)
    return ok and table.concat(lines, "\n") or nil
end

--- The page, with the graph in it.
--- @param data table from `M.data`
--- @param scope string one line saying what was drawn
--- @return string|nil html, string|nil err
function M.render(data, scope)
    local page = template()
    if not page then
        return nil, "could not find assets/graph.html -- is the plugin on the runtimepath?"
    end

    data.scope = scope
    local json = vim.json.encode(data)
    -- The data rides inside a <script> tag, so a note called `</script foo` has
    -- to not end it. `\/` is an escaped `/` in JSON and reads back as itself.
    json = json:gsub("</", "<\\/")

    local fields = { DATA = json, TITLE = "fzfkasten: " .. scope }
    return (page:gsub("{{(%u+)}}", function(key)
        return fields[key]
    end))
end

--- Open the page that was just written.
---
--- `true` hands it to whatever the system opens an HTML file with. That is the
--- right answer at the machine and the wrong one over ssh, where there is no
--- display to open it on -- so a string (a command, with `{}` where the path
--- goes) or a function takes over for a browser somewhere else.
---
--- A failure is reported rather than swallowed: a command that quietly does
--- nothing is worse than one that says it could not.
local function open_written(path)
    local how = export_options().open
    if not how then return end

    if type(how) == "function" then
        local ok, err = pcall(how, path)
        if not ok then
            vim.notify("graph.export.open raised: " .. tostring(err), vim.log.levels.WARN)
        end
        return
    end

    if type(how) == "string" then
        local cmd = how:find("{}", 1, true)
            and (how:gsub("{}", function() return vim.fn.shellescape(path) end))
            or (how .. " " .. vim.fn.shellescape(path))
        -- Not waited on: a browser holds its terminal for as long as it is
        -- open, and Neovim is not going to sit there for that.
        local ok, err = pcall(vim.system, { "sh", "-c", cmd }, { text = true },
            vim.schedule_wrap(function(res)
                if res.code ~= 0 then
                    local said = vim.trim(res.stderr or "")
                    vim.notify("graph.export.open failed: " .. (said ~= "" and said or cmd),
                        vim.log.levels.WARN)
                end
            end))
        if not ok then
            vim.notify("Could not run graph.export.open: " .. tostring(err), vim.log.levels.WARN)
        end
        return
    end

    -- Over ssh -- which is how a collection on another machine is usually
    -- reached -- there is no display for `xdg-open` to put anything on. It
    -- fails a moment later, after Neovim has stopped watching it, so the
    -- command appears to quietly do nothing at all. Asked here instead, while
    -- there is still somewhere to say it.
    if vim.fn.has("linux") == 1 and vim.fn.has("wsl") == 0
        and vim.env.DISPLAY == nil and vim.env.WAYLAND_DISPLAY == nil then
        vim.notify(string.format(
            "No display to open the page on -- it is written at %s. "
            .. "Set graph.export.open to a command (e.g. \"ssh laptop 'xdg-open {}'\") "
            .. "to open it somewhere else.", path), vim.log.levels.WARN)
        return
    end

    local ok, opened, err = pcall(vim.ui.open, path)
    if not ok then
        vim.notify("Could not open the page: " .. tostring(opened), vim.log.levels.WARN)
    elseif not opened then
        vim.notify(string.format(
            "Could not open the page (%s). It is written at %s -- set graph.export.open to a command to open it elsewhere.",
            err or "no opener", path), vim.log.levels.WARN)
    end
end

--- @return boolean ok, string|nil err
local function write(path, html)
    local dir = vim.fn.fnamemodify(path, ":h")
    if vim.fn.isdirectory(dir) == 0 and vim.fn.mkdir(dir, "p") == 0 then
        return false, "could not create " .. dir
    end
    local ok, err = pcall(vim.fn.writefile, vim.split(html, "\n"), path)
    if not ok then
        return false, tostring(err)
    end
    return true
end

--- Write the graph out as a page.
---
--- With no depth it draws the whole collection; with one it draws the note in
--- `filepath` and everything within that many links of it. The two are one
--- command because they are one picture at two scales -- the collection to see
--- its shape, a neighbourhood to read the names in it.
--- @param filepath string the buffer's file, for the depth form
--- @param depth integer|nil links out from that note, or nil for everything
--- @return string|nil path written
function M.graph_export(filepath, depth)
    local g = graph.build()

    local names, root, scope
    if depth then
        depth = math.max(depth, 1)
        root = utils.note_name(filepath)
        -- A note of the collection with nothing joined to it still draws (as
        -- itself, alone, which is the honest picture). A file that is not in
        -- the collection at all has no neighbourhood to draw.
        if not root or (not g.paths[root] and #(g.back[root] or {}) == 0) then
            vim.notify("Not a note of the collection -- run it with no depth to draw everything.",
                vim.log.levels.WARN)
            return nil
        end
        names = near_names(g, root, depth)
        scope = string.format("%s, %d link%s out", root, depth, depth == 1 and "" or "s")
    else
        names = all_names(g)
        scope = string.format("%d notes, whole collection", #g.names)
    end

    if #names == 0 then
        vim.notify("Nothing to draw: the collection has no notes in it.", vim.log.levels.INFO)
        return nil
    end

    local html, err = M.render(M.data(g, names, root), scope)
    if not html then
        vim.notify(err, vim.log.levels.ERROR)
        return nil
    end

    local path = vim.fn.expand(export_options().path
        or (vim.fn.stdpath("cache") .. "/fzfkasten/graph.html"))
    local ok, werr = write(path, html)
    if not ok then
        vim.notify("Could not write the graph: " .. werr, vim.log.levels.ERROR)
        return nil
    end

    vim.notify(string.format("Wrote %s (%s)", path, scope), vim.log.levels.INFO)
    open_written(path)

    return path
end

return M
