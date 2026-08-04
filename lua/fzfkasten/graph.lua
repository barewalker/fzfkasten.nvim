-- The collection as a graph: every note, and every `[[link]]` between them.
--
-- Backlinks answer "what points at this note", one note at a time. The same
-- walk run over the whole collection answers what a single note cannot: which
-- notes are joined to nothing, which links name notes that were never written,
-- and which notes everything converges on. A neighbourhood is a graph question
-- too -- two links away, in either direction, is not something a backlink list
-- can reach.
--
-- Rebuilt on every call rather than cached. Over 466 notes (24k lines, 1.2MB)
-- the walk costs about 40ms, the same order as the note finder's own index and
-- well under the time fzf takes to appear. A cache would have to be invalidated
-- by every write, every `git pull` and every edit made on a phone, and a graph
-- that is quietly out of date is worse than one that takes 40ms.
local fzf = require('fzf-lua')
local config = require('fzfkasten.config')
local utils = require('fzfkasten.utils')
local buffer = require('fzfkasten.buffer')

local M = {}

--- @class fzfkasten.GraphEdge
--- @field from string name of the note the link is written in
--- @field to string name the link points at, which may be no note at all
--- @field rel string path of the linking note, relative to `home`
--- @field lineno integer line the link is written on
--- @field line string that line, trimmed

--- @class fzfkasten.Graph
--- @field names string[] every note in the collection, sorted
--- @field paths table<string, string[]> note name -> its paths, relative to `home`
--- @field out table<string, fzfkasten.GraphEdge[]> name -> the links it writes
--- @field back table<string, fzfkasten.GraphEdge[]> name -> the links pointing at it
--- @field edges fzfkasten.GraphEdge[] every link, in the order they were read

-- Directories (relative to `home`) the graph never reads.
local function ignored_dirs()
    return (config.options.graph or {}).ignore_dirs or {}
end

local function is_ignored(rel)
    for _, dir in ipairs(ignored_dirs()) do
        if rel == dir or rel:sub(1, #dir + 1) == dir .. "/" then
            return true
        end
    end
    return false
end

-- Opens or closes a fenced code block: three or more backticks or tildes, up to
-- three spaces in. Markdown's own rule, near enough -- what it has to get right
-- here is only that a fence is a whole line of its own.
local function is_fence(line)
    return line:match("^ ? ? ?```") ~= nil or line:match("^ ? ? ?~~~") ~= nil
end

-- Inline code, for the same reason a fence is skipped: a note explaining its
-- own conventions writes "`#tag`, `@tag`, `[[tag]]`", and that is an example of
-- a link, not a link to a note called `tag`. A backtick with nothing closing it
-- is not a code span, so a line that merely contains one is left as it is.
local function without_code_spans(line)
    return (line:gsub("`+[^`]*`+", ""))
end

--- Read every note and every link between them.
---
--- One edge per (note, target) pair: a note that names the same target on four
--- lines is one link to it, which is what "connected" means here. The line kept
--- is the first, so a dead link is reported where it is first written.
---
--- Fenced code blocks are not read. `[[` is a link in prose and an ordinary
--- pair of brackets in a shell -- `if [[ ! -f ~/.config/x ]]; then` is a link
--- to a note called `! -f ~/.config/x` to anything reading the line as prose,
--- and in a collection that keeps command lines in it, that is what the dead
--- link list fills up with.
--- @return fzfkasten.Graph
function M.build()
    local home = config.options.home
    local link_pattern = config.options.patterns.link
    local pattern = utils.join_path(home, "**/*." .. config.options.extension)

    local g = { names = {}, paths = {}, out = {}, back = {}, edges = {} }

    for _, file in ipairs(vim.fn.glob(pattern, true, true) or {}) do
        local rel = file:gsub("^" .. vim.pesc(home) .. "/?", "")
        local name = utils.note_name(file)
        if name and not is_ignored(rel) then
            if not g.paths[name] then
                g.paths[name] = {}
                g.names[#g.names + 1] = name
                g.out[name], g.back[name] = {}, {}
            end
            -- Two notes of the same name in different directories are one node:
            -- a link names a note, not a path, and `follow_link` offers both
            -- files when it is asked to open one. Their links merge for the same
            -- reason -- from the link's point of view there is one target here.
            table.insert(g.paths[name], rel)

            local ok, lines = pcall(vim.fn.readfile, file)
            local linked = {}
            local in_code = false
            for lineno, line in ipairs(ok and lines or {}) do
                if is_fence(line) then
                    in_code = not in_code
                elseif not in_code then
                    for inner in without_code_spans(line):gmatch(link_pattern) do
                        local target = utils.split_link(inner)
                        -- A note is not its own neighbour, and `[[]]` names nothing.
                        if target and target ~= "" and target ~= name and not linked[target] then
                            linked[target] = true
                            g.edges[#g.edges + 1] = {
                                from = name,
                                to = target,
                                rel = rel,
                                lineno = lineno,
                                line = vim.trim(line),
                            }
                        end
                    end
                end
            end
        end
    end

    -- Wired in a second pass: a link is read before we know whether anything
    -- answers to the name it points at -- the note may be read later in the
    -- walk, or never, because it does not exist.
    for _, edge in ipairs(g.edges) do
        table.insert(g.out[edge.from], edge)
        g.back[edge.to] = g.back[edge.to] or {}
        table.insert(g.back[edge.to], edge)
    end

    table.sort(g.names)
    return g
end

-- Tree drawing. Two columns per level: deep enough to read, narrow enough that
-- a note's name still fits on the line at depth 3.
local BRANCH, LAST, PIPE, BLANK = "├─ ", "└─ ", "│  ", "   "

--- Every note joined to `name` by one link, in either direction.
---
--- Its own links first, in the order the note writes them -- that order is the
--- note's own -- then the notes pointing back at it. A note on both sides is
--- listed once, marked as the mutual link it is.
---
--- Neither list needs de-duplicating: `build` keeps one edge per (note, target)
--- pair, so a name appears at most once on each side.
--- @return { name: string, arrow: string, rel: string, lineno: integer, missing: boolean }[]
local function neighbours(g, name)
    local kids, out_at = {}, {}

    for _, edge in ipairs(g.out[name] or {}) do
        local paths = g.paths[edge.to]
        out_at[edge.to] = #kids + 1
        kids[#kids + 1] = {
            name = edge.to,
            arrow = "→",
            -- There is nothing to open for a note that was never written, so
            -- the entry points at the link instead: the line naming it is the
            -- only place that note exists at all.
            rel = paths and paths[1] or edge.rel,
            lineno = paths and 1 or edge.lineno,
            missing = paths == nil,
        }
    end

    for _, edge in ipairs(g.back[name] or {}) do
        if out_at[edge.from] then
            kids[out_at[edge.from]].arrow = "↔"
        else
            -- Opened at the line that links here, the way the backlink list
            -- does it: what you want to read is the sentence that made the
            -- link, not the top of the note it happens to sit in.
            kids[#kids + 1] = {
                name = edge.from,
                arrow = "←",
                rel = edge.rel,
                lineno = edge.lineno,
                missing = false,
            }
        end
    end

    return kids
end

--- @class fzfkasten.GraphRow
--- @field name string
--- @field rel string path the row opens, relative to `home`
--- @field lineno integer line it opens at
--- @field missing boolean the name has no note behind it
--- @field display string the row as shown, tree drawing and arrow included

--- The neighbourhood of `root`, out to `depth` links, as rows of a tree.
---
--- Breadth-first, so a note is hung off the shortest way to reach it: walked
--- depth-first with the same "each note appears once" rule, a note one link away
--- would show up three levels down merely because that branch ran first.
--- @param g fzfkasten.Graph
--- @param root string note name at the centre
--- @param depth integer how many links out to walk
--- @return fzfkasten.GraphRow[]
function M.tree(g, root, depth)
    local kids_of = { [root] = {} }
    local dist = { [root] = 0 }
    local queue, head = { root }, 1

    while head <= #queue do
        local name = queue[head]
        head = head + 1
        if dist[name] < depth then
            for _, kid in ipairs(neighbours(g, name)) do
                if not dist[kid.name] then
                    dist[kid.name] = dist[name] + 1
                    kids_of[kid.name] = {}
                    table.insert(kids_of[name], kid)
                    queue[#queue + 1] = kid.name
                end
            end
        end
    end

    local rows = {}
    local function render(name, prefix)
        local kids = kids_of[name]
        for i, kid in ipairs(kids) do
            local last = i == #kids
            rows[#rows + 1] = {
                name = kid.name,
                rel = kid.rel,
                lineno = kid.lineno,
                missing = kid.missing,
                display = prefix .. (last and LAST or BRANCH) .. kid.arrow .. " " .. kid.name
                    .. (kid.missing and "  (no note)" or ""),
            }
            render(kid.name, prefix .. (last and BLANK or PIPE))
        end
    end
    render(root, "")

    return rows
end

--- Notes nothing links to and which link nowhere: the ones the collection has
--- not connected to anything yet.
--- @return string[] paths relative to `home`, sorted
function M.orphans(g)
    local rels = {}
    for _, name in ipairs(g.names) do
        if #g.out[name] == 0 and #g.back[name] == 0 then
            for _, rel in ipairs(g.paths[name]) do
                rels[#rels + 1] = rel
            end
        end
    end
    table.sort(rels)
    return rels
end

--- Links naming a note that does not exist -- a note you meant to write, or a
--- name that drifted. One entry per link, so each is a place in a note.
--- @return fzfkasten.GraphEdge[] sorted by the name they point at
function M.dead_links(g)
    local dead = {}
    for _, edge in ipairs(g.edges) do
        if not g.paths[edge.to] then
            dead[#dead + 1] = edge
        end
    end
    table.sort(dead, function(a, b)
        if a.to ~= b.to then return a.to < b.to end
        if a.rel ~= b.rel then return a.rel < b.rel end
        return a.lineno < b.lineno
    end)
    return dead
end

--- Notes by how much of the collection meets there, most connected first.
--- Notes joined to nothing are left out; `orphans` is the list of those.
--- @return { name: string, rel: string, back: integer, out: integer }[]
function M.hubs(g)
    local hubs = {}
    for _, name in ipairs(g.names) do
        local back, out = #g.back[name], #g.out[name]
        if back + out > 0 then
            hubs[#hubs + 1] = { name = name, rel = g.paths[name][1], back = back, out = out }
        end
    end
    table.sort(hubs, function(a, b)
        if a.back + a.out ~= b.back + b.out then return a.back + a.out > b.back + b.out end
        -- Being linked to is what makes a note a place others meet, so it
        -- breaks the tie: a note with ten backlinks is more of a hub than one
        -- that links out ten times.
        if a.back ~= b.back then return a.back > b.back end
        return a.name < b.name
    end)
    return hubs
end

-- "rel:lineno: text", the shape the log and backlink pickers use: fzf-lua's
-- builtin previewer resolves it against `home` and shows the note at that line,
-- and `entry_to_file` reads the same string back when the entry is picked.
local function entry(rel, lineno, text)
    return string.format("%s:%d: %s", rel, lineno, text)
end

local function open(selected)
    if not selected or #selected == 0 then return end
    local file = fzf.path.entry_to_file(selected[1], { cwd = config.options.home })
    if not file.path then
        vim.notify("Could not open: " .. selected[1], vim.log.levels.ERROR)
        return
    end
    buffer.edit(file.path)
    if file.line and file.line > 0 then
        -- The line is read from an entry built before the note was opened, and
        -- the note may have been edited since -- from a phone, by a `git pull`.
        pcall(vim.api.nvim_win_set_cursor, 0, { file.line, (file.col or 1) - 1 })
    end
end

-- Every picker here lists lines of notes, previews them in place, and opens
-- what you pick. Order is the answer in each -- a tree, a ranking, a sorted
-- path -- so fzf must not re-sort it, and the path is shown to the previewer
-- rather than to you.
local function pick(prompt, entries, header)
    fzf.fzf_exec(entries, vim.tbl_deep_extend("force", config.options.fzf, {
        prompt = prompt,
        cwd = config.options.home,
        previewer = "builtin",
        fzf_opts = {
            ["--delimiter"] = ":",
            ["--with-nth"] = "3..",
            ["--no-sort"] = "",
            ["--header"] = header,
        },
        actions = { ['default'] = open },
    }))
end

-- Ask which note the tree starts from, and draw it from there.
local function pick_root(depth)
    fzf.files(vim.tbl_deep_extend("force", config.options.fzf.files, {
        cwd = config.options.home,
        prompt = "Link tree from> ",
        actions = {
            ['default'] = function(selected)
                if not selected or #selected == 0 then return end
                local file = fzf.path.entry_to_file(selected[1], { cwd = config.options.home })
                M.link_tree(file.path, depth)
            end,
        },
    }))
end

--- The note at `filepath` and what it is joined to, out to `depth` links.
---
--- With no note to start from -- run from a dashboard, a scratch buffer, or a
--- file outside the collection -- it asks which note rather than refusing. The
--- graph is a thing you browse, and "open a note first, then ask what it is
--- joined to" is a step that answers nothing: the note you want is usually the
--- one you were about to look for.
function M.link_tree(filepath, depth)
    -- A depth below 1 has no tree in it, and "nothing links here" is the wrong
    -- thing to say about a note whose neighbours were never looked for.
    depth = math.max(depth or (config.options.graph or {}).depth or 2, 1)

    local root = utils.note_name(filepath)
    if not root then
        return pick_root(depth)
    end

    local g = M.build()
    -- A note of the collection with nothing joined to it is a fair answer
    -- ("nothing links here", below). A file that is not in the collection at
    -- all is not -- there is no graph question to ask about it.
    if not g.paths[root] and #(g.back[root] or {}) == 0 then
        return pick_root(depth)
    end

    local rows = M.tree(g, root, depth)

    if #rows == 0 then
        vim.notify("Nothing links to or from '" .. root .. "'.", vim.log.levels.INFO)
        return
    end

    local entries = {}
    -- The root's own row, so the tree has the trunk it hangs from. Its path
    -- comes from the graph when the note is in the collection, and from the
    -- buffer when it is not -- a note outside `home` can still be linked to.
    local rel = (g.paths[root] or {})[1]
        or vim.fn.fnamemodify(filepath, ":p"):gsub("^" .. vim.pesc(config.options.home) .. "/?", "")
    entries[1] = entry(rel, 1, "● " .. root)
    for _, row in ipairs(rows) do
        entries[#entries + 1] = entry(row.rel, row.lineno, row.display)
    end

    pick(string.format("Links %d deep> ", depth), entries,
        "→ links out   ← links in   ↔ both")
end

--- Notes joined to nothing.
function M.orphans_picker()
    local rels = M.orphans(M.build())
    if #rels == 0 then
        vim.notify("Every note is linked to something.", vim.log.levels.INFO)
        return
    end

    -- Plain paths rather than "rel:1: ..." entries: there is nothing to say
    -- about an orphan beyond which note it is, and a path is what you would
    -- search for. The builtin previewer resolves them against `home` as it does
    -- in the note finder.
    fzf.fzf_exec(rels, vim.tbl_deep_extend("force", config.options.fzf, {
        prompt = string.format("Orphans (%d)> ", #rels),
        cwd = config.options.home,
        previewer = "builtin",
        actions = {
            ['default'] = function(selected)
                if not selected or #selected == 0 then return end
                local file = fzf.path.entry_to_file(selected[1], { cwd = config.options.home })
                buffer.edit(file.path)
            end,
        },
    }))
end

--- Links pointing at notes that do not exist.
function M.dead_links_picker()
    local dead = M.dead_links(M.build())
    if #dead == 0 then
        vim.notify("Every link points at a note.", vim.log.levels.INFO)
        return
    end

    local entries = {}
    for _, edge in ipairs(dead) do
        entries[#entries + 1] = entry(edge.rel, edge.lineno,
            string.format("%s  ←  %s", edge.to, edge.line))
    end

    -- It opens the link, not the note: the note is the thing that is missing.
    -- With `follow_link.create_nonexisting` set, `gf` on the line you land on
    -- writes it from the template.
    pick(string.format("Dead links (%d)> ", #dead), entries,
        "opens the line the link is written on")
end

--- Notes by how much meets there.
function M.hubs_picker()
    local hubs = M.hubs(M.build())
    if #hubs == 0 then
        vim.notify("No note is linked to any other.", vim.log.levels.INFO)
        return
    end

    local entries = {}
    for _, hub in ipairs(hubs) do
        entries[#entries + 1] = entry(hub.rel, 1,
            string.format("%3d ←  %3d →   %s", hub.back, hub.out, hub.name))
    end

    pick(string.format("Hubs (%d)> ", #hubs), entries, "linked to ←   links out →")
end

return M
