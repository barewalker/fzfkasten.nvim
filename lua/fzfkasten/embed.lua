-- `![[note#^id]]`: the lines a link points at, shown under the link.
--
-- A link says where something is; this shows what is there, so a daily note
-- that refers to three lines of last week's minutes can be read without
-- opening the minutes. The lines are drawn as virtual lines and never written
-- into the note: what is shown is whatever the other note says now, there is no
-- second copy to fall behind, and a quoted `- [ ] ... #todo` is not a second
-- task for the task scan to find.
--
-- Three anchors, none of them a line number -- a line number is wrong the
-- moment a line is added above it:
--
--   ![[note#Heading]]      the section, down to the next heading of its level
--   ![[note#^id]]          the line, and the list items nested under it
--   ![[note#^id1..^id2]]   everything from one line to the other
--   ![[note]]              the note, without its frontmatter
--
-- A leading `#` alone (`![[#Heading]]`) quotes from the note it is written in.
local config = require('fzfkasten.config')
local utils = require('fzfkasten.utils')

local M = {}

local uv = vim.uv or vim.loop
local ns = vim.api.nvim_create_namespace("fzfkasten-embed")
local BAR = "▎ "

local function define_groups()
    vim.api.nvim_set_hl(0, "FzfkastenEmbed", { link = "@markup.quote", default = true })
    vim.api.nvim_set_hl(0, "FzfkastenEmbedBorder", { link = "Comment", default = true })
    vim.api.nvim_set_hl(0, "FzfkastenEmbedMissing", { link = "DiagnosticWarn", default = true })
end

local function options()
    return config.options.embed or {}
end

-- The same rule the link graph reads fences by: a fence is a line of its own.
local function is_fence(line)
    return line:match("^ ? ? ?```") ~= nil or line:match("^ ? ? ?~~~") ~= nil
end

--- The targets of the embeds on `line`: what stands between `![[` and `]]`.
--- Inline code is passed over, so a note explaining this syntax quotes nothing.
--- @param line string
--- @return string[]
function M.targets(line)
    if not line:find("![[", 1, true) then
        return {}
    end
    local out = {}
    for target in line:gsub("`[^`]*`", ""):gmatch("!%[%[(.-)%]%]") do
        if vim.trim(target) ~= "" then
            out[#out + 1] = target
        end
    end
    return out
end

--- What an anchor asks for.
--- @param anchor string|nil
--- @return "note"|"block"|"range"|"heading" kind, string|nil a, string|nil b
function M.split_anchor(anchor)
    local trimmed = vim.trim(anchor or "")
    if trimmed == "" then
        return "note"
    end
    local a, b = trimmed:match("^%^([%w-]+)%.%.%^?([%w-]+)$")
    if a then
        return "range", a, b
    end
    local id = trimmed:match("^%^(.+)$")
    if id then
        return "block", id
    end
    return "heading", trimmed
end

local function indent_of(line)
    return vim.fn.strdisplaywidth(line:match("^%s*"))
end

local function is_list_item(line)
    return line:match("^%s*[-*+]%s") ~= nil or line:match("^%s*%d+[.)]%s") ~= nil
end

local function find_id(lines, id)
    for lineno, line in ipairs(lines) do
        if utils.block_id(line) == id then
            return lineno
        end
    end
end

-- The last line of the block that starts at `lineno`: the line itself, and for
-- a list item whatever is nested under it. Only a list item has children --
-- an indented line after a paragraph is the next thing, not part of it.
local function block_end(lines, lineno)
    if not is_list_item(lines[lineno]) then
        return lineno
    end
    local base, last = indent_of(lines[lineno]), lineno
    for j = lineno + 1, #lines do
        local line = lines[j]
        if line:match("^%s*$") then
            -- Blank: part of the block only if something deeper follows.
        elseif indent_of(line) > base then
            last = j
        else
            break
        end
    end
    return last
end

local function trim_blank(lines, from, to)
    while from <= to and lines[from]:match("^%s*$") do from = from + 1 end
    while to >= from and lines[to]:match("^%s*$") do to = to - 1 end
    if from > to then
        return nil
    end
    return from, to
end

--- The lines of `lines` that `anchor` names, as 1-based inclusive bounds.
--- @param lines string[]
--- @param anchor string|nil
--- @return integer|nil from, integer|string to the last line, or why there is none
function M.extract(lines, anchor)
    local kind, a, b = M.split_anchor(anchor)

    if kind == "note" then
        local from = 1
        if lines[1] == "---" then
            for j = 2, #lines do
                if lines[j] == "---" then
                    from = j + 1
                    break
                end
            end
        end
        local f, t = trim_blank(lines, from, #lines)
        if not f then
            return nil, "Nothing in"
        end
        return f, t
    end

    if kind == "block" then
        local at = find_id(lines, a)
        if not at then
            return nil, "No line '^" .. a .. "' in"
        end
        return at, block_end(lines, at)
    end

    if kind == "range" then
        local first, last = find_id(lines, a), find_id(lines, b)
        if not first then
            return nil, "No line '^" .. a .. "' in"
        end
        if not last then
            return nil, "No line '^" .. b .. "' in"
        end
        -- Written the wrong way round, or the lines swapped places since.
        if first > last then
            first, last = last, first
        end
        return first, block_end(lines, last)
    end

    local wanted, fenced, start, level = a:lower(), false, nil, nil
    local stop = #lines
    for lineno, line in ipairs(lines) do
        if is_fence(line) then
            fenced = not fenced
        elseif not fenced then
            local hashes, text = line:match("^(#+)%s+(.-)%s*$")
            if hashes then
                if start and #hashes <= level then
                    stop = lineno - 1
                    break
                elseif not start and text:lower() == wanted then
                    start, level = lineno, #hashes
                end
            end
        end
    end
    if not start then
        return nil, "No heading '" .. a .. "' in"
    end
    return trim_blank(lines, start, stop)
end

-- Where `text` is cut so that no piece is wider than `width` cells, as byte
-- ranges into it: { from, to, indent }, the indent being what a continuation
-- line is given in front. Ranges rather than strings, because the colours of
-- a line are kept by byte and have to be cut at the same places.
local function pieces(text, width)
    width = math.max(width, 20)
    if vim.fn.strdisplaywidth(text) <= width then
        return { { from = 1, to = #text, indent = "" } }
    end
    local indent = text:match("^ *")
    if #indent > width / 2 then
        indent = ""
    end
    local out, from, used = {}, 1, 0
    for at, ch in text:gmatch("()([%z\1-\127\194-\244][\128-\191]*)") do
        local w = vim.fn.strdisplaywidth(ch)
        if used + w > width and at > from then
            out[#out + 1] = { from = from, to = at - 1, indent = #out > 0 and indent or "" }
            from, used = at, #indent
        end
        used = used + w
    end
    out[#out + 1] = { from = from, to = #text, indent = #out > 0 and indent or "" }
    return out
end

--- `text` cut into pieces no wider than `width` cells. Virtual lines are not
--- wrapped by Neovim, so a paragraph kept on one line would otherwise run off
--- the window. Counted in cells, so a Japanese line breaks where it looks full.
--- Continuation lines keep the indent of the first.
--- @param text string
--- @param width integer
--- @return string[]
function M.wrap(text, width)
    text = text:gsub("\t", "    ")
    local out = {}
    for _, p in ipairs(pieces(text, width)) do
        out[#out + 1] = p.indent .. text:sub(p.from, p.to)
    end
    return out
end

-- The colours of quoted lines. A virtual line is not buffer text, so nothing
-- highlights it for us: the lines are parsed here as markdown, on their own,
-- and the captures of the highlight queries are laid over them by hand --
-- injected languages too, which is what colours emphasis, links and the code
-- inside a fence.
--
-- Parsed as a fragment rather than cut out of a parse of the whole note: the
-- fragment is at most `max_lines` long, where the note is as long as it is and
-- would be parsed again for every quote from it. What that costs is the rare
-- quote that starts inside a construct it does not show the start of.
local hl_cache, hl_cached = {}, 0

--- @param lines string[]
--- @return table<integer, table<integer, string>>|nil per line, the group of each byte
function M.highlight(lines)
    local text = table.concat(lines, "\n")
    if hl_cache[text] ~= nil then
        return hl_cache[text] or nil
    end

    local marks = {}
    for i = 1, #lines do
        marks[i] = {}
    end
    local ok = pcall(function()
        -- With the newline a file ends in: without it the last line is not
        -- closed, and a lone heading or the fence ending a code block is not
        -- read as what it is.
        local source = text .. "\n"
        local parser = vim.treesitter.get_string_parser(source, "markdown")
        parser:parse(true)
        -- A tree's own captures before those of the trees injected into it, so
        -- the inner, more specific colour is the one left standing.
        parser:for_each_tree(function(tree, ltree)
            local lang = ltree:lang()
            local query = vim.treesitter.query.get(lang, "highlights")
            if not query then
                return
            end
            for id, node in query:iter_captures(tree:root(), source) do
                local name = query.captures[id]
                if name:sub(1, 1) ~= "_" and name ~= "spell" and name ~= "nospell" and name ~= "conceal" then
                    local group = "@" .. name .. "." .. lang
                    local sr, sc, er, ec = node:range()
                    for row = sr, er do
                        local line = lines[row + 1]
                        if line then
                            local to = row == er and ec or #line
                            for col = (row == sr and sc or 0) + 1, math.min(to, #line) do
                                marks[row + 1][col] = group
                            end
                        end
                    end
                end
            end
        end)
    end)

    -- No markdown parser on this Neovim: remembered too, so it is asked once.
    if hl_cached > 200 then
        hl_cache, hl_cached = {}, 0
    end
    hl_cache[text], hl_cached = ok and marks or false, hl_cached + 1
    return ok and marks or nil
end

-- Which file a name is. One `rg --files` for the whole collection, asked for
-- off the main loop and kept: resolving a name by globbing the tree, as
-- following a link does, costs seconds on the machine where a syscall is slow,
-- and this runs on redraws rather than on a keypress.
local index = { home = nil, by_name = nil, at = 0, loading = false, waiting = {} }

local function now()
    return uv.hrtime() / 1e6
end

local function build_index(rels, home)
    local ext = "." .. config.options.extension
    local by_name = {}
    table.sort(rels)
    for _, rel in ipairs(rels) do
        local base = rel:match("[^/]+$")
        if base and base:sub(-#ext) == ext then
            local name = base:sub(1, -(#ext + 1))
            by_name[name] = by_name[name] or {}
            table.insert(by_name[name], vim.fs.normalize(home .. "/" .. rel))
        end
    end
    return by_name
end

local function load_index(done)
    table.insert(index.waiting, done)
    if index.loading then
        return
    end
    index.loading = true
    local home = config.options.home

    local function finish(rels)
        index.by_name, index.home, index.at = build_index(rels, home), home, now()
        index.loading = false
        local waiting = index.waiting
        index.waiting = {}
        for _, f in ipairs(waiting) do
            f()
        end
    end

    local function walk()
        local prefix = vim.fs.normalize(home) .. "/"
        local rels = {}
        for _, f in ipairs(vim.fn.glob(prefix .. "**/*." .. config.options.extension, true, true)) do
            rels[#rels + 1] = vim.fs.normalize(f):sub(#prefix + 1)
        end
        finish(rels)
    end

    local started = vim.fn.executable("rg") == 1 and pcall(vim.system,
        { "rg", "--files", "--no-messages", "--no-ignore-vcs", "--glob", "*." .. config.options.extension },
        { cwd = home, text = true },
        vim.schedule_wrap(function(res)
            if res.code > 1 then
                return walk()
            end
            finish(vim.split(res.stdout or "", "\n", { plain = true }))
        end))
    if not started then
        walk()
    end
end

-- The file `name` names, seen from the note at `from`. Several notes may share
-- a name: the directory the link wrote decides, then the directory of the note
-- doing the quoting, then the first in path order -- always the same one, so
-- what is shown does not change between redraws.
local function resolve(name, dir, from)
    local matches = index.by_name and index.by_name[name]
    if not matches or #matches == 0 then
        return nil
    end
    if #matches == 1 then
        return matches[1]
    end
    local function in_dir(d)
        for _, f in ipairs(matches) do
            local parent = vim.fs.dirname(f)
            if parent == d or parent:sub(-(#d + 1)) == "/" .. d then
                return f
            end
        end
    end
    return (dir and dir ~= "" and in_dir(dir)) or in_dir(vim.fs.dirname(from)) or matches[1]
end

-- What a file holds, re-read only when its stat says it changed.
local files = {}

local function read_file(path)
    local st = uv.fs_stat(path)
    if not st then
        files[path] = nil
        return nil
    end
    local cached = files[path]
    if cached and cached.sec == st.mtime.sec and cached.nsec == st.mtime.nsec and cached.size == st.size then
        return cached.lines
    end
    local fd = io.open(path, "r")
    if not fd then
        return nil
    end
    local text = fd:read("*a") or ""
    fd:close()
    local lines = vim.split(text:gsub("\r\n", "\n"), "\n", { plain = true })
    if lines[#lines] == "" then
        lines[#lines] = nil
    end
    files[path] = { sec = st.mtime.sec, nsec = st.mtime.nsec, size = st.size, lines = lines }
    return lines
end

local function is_note(buf)
    if not vim.api.nvim_buf_is_loaded(buf) or vim.bo[buf].buftype ~= "" then
        return false
    end
    local o = config.options
    return require('fzfkasten.tag_highlight').is_note(vim.api.nvim_buf_get_name(buf), o.home or "", o.extension or "md")
end

-- The lines one embed shows, as virtual lines.
-- @return table[] virt_lines, boolean missed whether the note was not found
local function quote(target, from, ctx)
    local function note(text, group)
        return { { { BAR, "FzfkastenEmbedBorder" }, { text, group or "FzfkastenEmbedBorder" } } }
    end

    local name, anchor, _, dir = utils.split_link(target)
    local path = from
    if name ~= "" then
        path = resolve(name, dir, from)
        if not path then
            return note("No note '" .. name .. "'", "FzfkastenEmbedMissing"), true
        end
    end
    local shown = name ~= "" and ("'" .. name .. "'") or "this note"

    -- A note open here is read from its buffer: what it says now, saved or not.
    local lines
    local open = ctx.bufs[path]
    if open then
        lines = vim.api.nvim_buf_get_lines(open, 0, -1, false)
    else
        lines = read_file(path)
        ctx.used[path] = true
    end
    if not lines then
        return note("Cannot read " .. shown, "FzfkastenEmbedMissing"), false
    end

    local first, last = M.extract(lines, anchor)
    if not first then
        return note(last .. " " .. shown, "FzfkastenEmbedMissing"), false
    end

    local max = tonumber(options().max_lines) or 20
    local cut = 0
    if max > 0 and last - first + 1 > max then
        cut = (last - first + 1) - max
        last = first + max - 1
    end

    local shown_lines = {}
    for lineno = first, last do
        -- The id names the line; it is not part of what the line says.
        shown_lines[#shown_lines + 1] = (utils.strip_block_id(lines[lineno]):gsub("\t", "    "))
    end
    local marks = options().highlight ~= false and M.highlight(shown_lines) or nil
    local tags = (config.options.note_buffer or {}).highlight_tags ~= false

    local out = {}
    for i, text in ipairs(shown_lines) do
        local groups = marks and marks[i] or {}
        if tags then
            -- Tags are coloured here as they are in the note itself.
            local ranges = require('fzfkasten.tag_highlight').ranges(text, config.options.patterns.tag)
            if #ranges > 0 then
                groups = vim.deepcopy(groups)
                for _, r in ipairs(ranges) do
                    for col = r[1] + 1, r[2] do
                        groups[col] = "FzfkastenNoteTag"
                    end
                end
            end
        end
        for _, p in ipairs(pieces(text, ctx.width)) do
            local chunks = { { BAR, "FzfkastenEmbedBorder" }, { p.indent, "FzfkastenEmbed" } }
            local a = p.from
            while a <= p.to do
                local group, b = groups[a], a
                while b < p.to and groups[b + 1] == group do
                    b = b + 1
                end
                chunks[#chunks + 1] = { text:sub(a, b), group and { "FzfkastenEmbed", group } or "FzfkastenEmbed" }
                a = b + 1
            end
            out[#out + 1] = chunks
        end
    end
    if cut > 0 then
        out[#out + 1] = note(("… %d more line%s"):format(cut, cut == 1 and "" or "s"))[1]
    end
    return out, false
end

-- Draw every embed of `buf`. Returns whether some note was not found, which
-- may only mean the index is older than the note.
local function render(buf, ctx)
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)

    local width
    for _, win in ipairs(vim.fn.win_findbuf(buf)) do
        local info = vim.fn.getwininfo(win)[1]
        if info then
            local w = info.width - info.textoff
            width = width and math.min(width, w) or w
        end
    end
    if not width then
        return false
    end
    ctx.width = width - vim.fn.strdisplaywidth(BAR) - 1

    local from = vim.fs.normalize(vim.api.nvim_buf_get_name(buf))
    local fenced, missed = false, false
    for row, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
        if is_fence(line) then
            fenced = not fenced
        elseif not fenced then
            local virt = {}
            for _, target in ipairs(M.targets(line)) do
                local lines, miss = quote(target, from, ctx)
                missed = missed or miss
                vim.list_extend(virt, lines)
            end
            if #virt > 0 then
                vim.api.nvim_buf_set_extmark(buf, ns, row - 1, 0, { virt_lines = virt })
            end
        end
    end
    return missed
end

-- A quoted file that no buffer holds changes behind Neovim's back: a sync
-- pulls, another program edits. Watching it is what lets the quote follow.
-- A watch is dropped as soon as it fires and made again by the redraw it
-- caused, because a file replaced by rename leaves the old watch on nothing.
local watchers = {}
local schedule

local function watch(used)
    for path, handle in pairs(watchers) do
        if not used[path] then
            handle:stop()
            handle:close()
            watchers[path] = nil
        end
    end
    if options().watch == false then
        return
    end
    for path in pairs(used) do
        if not watchers[path] then
            local handle = uv.new_fs_event()
            local ok = handle and pcall(handle.start, handle, path, {}, vim.schedule_wrap(function()
                if watchers[path] == handle then
                    handle:stop()
                    handle:close()
                    watchers[path] = nil
                end
                schedule(100)
            end))
            if ok then
                watchers[path] = handle
            elseif handle then
                handle:close()
            end
        end
    end
end

--- Redraw the embeds of every note on screen, now.
function M.refresh()
    local home = config.options.home
    if not home or home == "" then
        return
    end
    if not index.by_name or index.home ~= home then
        return load_index(M.refresh)
    end

    local ctx = { bufs = {}, used = {} }
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(buf) then
            local name = vim.api.nvim_buf_get_name(buf)
            if name ~= "" then
                ctx.bufs[vim.fs.normalize(name)] = buf
            end
        end
    end

    local missed, seen = false, {}
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        local buf = vim.api.nvim_win_get_buf(win)
        if not seen[buf] and is_note(buf) then
            seen[buf] = true
            missed = render(buf, ctx) or missed
        end
    end
    watch(ctx.used)

    -- A note made since the listing was taken. Asked again at most every few
    -- seconds, so a link to a note that really is not there costs one walk.
    if missed and now() - index.at > 5000 then
        load_index(M.refresh)
    end
end

local timer
schedule = function(delay)
    timer = timer or uv.new_timer()
    timer:stop()
    timer:start(delay or 0, 0, vim.schedule_wrap(M.refresh))
end

function M.enable()
    define_groups()
    local group = vim.api.nvim_create_augroup("fzfkasten-embed", { clear = true })
    vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = define_groups })
    -- Showing a note, and anything that changes how wide it is shown.
    vim.api.nvim_create_autocmd({ "BufWinEnter", "VimResized", "WinResized", "FocusGained" }, {
        group = group,
        callback = function() schedule(0) end,
    })
    -- A note written here may be one that was not in the listing yet.
    vim.api.nvim_create_autocmd("BufWritePost", {
        group = group,
        callback = function(ev)
            if not is_note(ev.buf) then
                return
            end
            local path = vim.fs.normalize(vim.api.nvim_buf_get_name(ev.buf))
            local name = utils.note_name(path)
            if index.by_name and name and not vim.tbl_contains(index.by_name[name] or {}, path) then
                index.by_name[name] = index.by_name[name] or {}
                table.insert(index.by_name[name], path)
                table.sort(index.by_name[name])
            end
            schedule(0)
        end,
    })
    -- Typing: in the note that quotes (an embed written or removed) or in the
    -- note quoted from. Waited out, so a burst of keys is one redraw.
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP" }, {
        group = group,
        callback = function(ev)
            if is_note(ev.buf) then
                schedule(150)
            end
        end,
    })
    schedule(0)
end

M._test = { index = index, files = files, ns = ns }

return M
