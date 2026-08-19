local fzf = require('fzf-lua')
local config = require('fzfkasten.config')
local utils = require('fzfkasten.utils') -- Added for path joining if needed later
local buffer = require('fzfkasten.buffer') -- Opens notes and applies per-buffer opt-outs
local romaji = require('fzfkasten.romaji') -- Optional romaji narrowing (/ prefix, <alt-/>)
local M = {}

-- Start ripgrep in the notes directory. Started rather than run, because the
-- index needs two passes over the same tree and they do not need each other:
-- both are set going before either is waited on. In series on WSL2 they cost
-- 531ms, which is the whole of what opening the finder costs there.
--
-- pcall because `vim.system` raises rather than returning a status when the cwd
-- is not there, and a `home` that does not exist is a configuration mistake
-- `:checkhealth` already names -- the pickers' job is to come up empty, as they
-- did when this was a glob, not to throw at whoever opened one.
--- @return vim.SystemObj|nil
local function rg_start(args)
    if vim.fn.executable("rg") ~= 1 then return nil end
    local ok, handle = pcall(vim.system, args, { cwd = config.options.home, text = true })
    if not ok then return nil end
    return handle
end

--- @return string[]|nil lines of rg's stdout, nil when it could not answer
local function rg_lines(handle)
    if not handle then return nil end
    local rg = handle:wait()
    -- 1 is "nothing found", a legitimate answer for an empty collection; above
    -- that rg failed, and reading the files ourselves answers that better than
    -- an empty picker does.
    if rg.code > 1 then return nil end
    return vim.split(rg.stdout or "", "\n", { plain = true })
end

-- Every note file under `home`, as a path relative to `home` -- the same shape
-- `fzf.files` shows, so `entry_to_file(.., { cwd = home })` resolves either.
-- Used to rebuild the finder as a plain list when a romaji filter is active.
--
-- ripgrep rather than `vim.fn.glob("**/*.md")`, which is what this was. Vim's
-- `**` walks the tree inside Neovim, one directory at a time, and descends into
-- `.git` on the way. Over 491 notes on a Linux filesystem that costs 11ms and
-- nobody notices; over the same collection on WSL2 it measured **6.2 seconds**,
-- paid every time the finder opened, before a key was pressed. rg walks it in
-- parallel, in one process, and skips dot-directories itself: 7ms there. This
-- is also what `fzf.files` was doing for us before the finder went live -- the
-- glob was the regression.
--
-- `--no-ignore-vcs` because the glob showed every note; a collection that
-- gitignores a directory of notes would otherwise find them quietly gone.
local function rg_files_args()
    return { "rg", "--files", "--no-messages", "--no-ignore-vcs",
        "--glob", "*." .. config.options.extension }
end

--- @param listed string[]|nil what `rg --files` said, or nil to walk it here
local function note_rel_paths(listed)
    local home = config.options.home
    local ext = config.options.extension

    if listed then
        return vim.tbl_filter(function(rel) return rel ~= "" end, listed)
    end

    local files = vim.fn.glob(utils.join_path(home, "**/*." .. ext), true, true) or {}
    local rels = {}
    for _, f in ipairs(files) do
        rels[#rels + 1] = f:gsub("^" .. vim.pesc(home) .. "/?", "")
    end
    return rels
end

-- Every note's headings, keyed by the path `note_rel_paths` gives -- or nil when
-- ripgrep cannot answer and the caller has to read the files itself.
--
-- One rg pass over the collection instead of `readfile` per note. Same reason as
-- above, and the same shape of number: 20ms for 491 files here, 3.5 *seconds* on
-- WSL2. `--heading` groups the matches under the filename and separates the
-- groups with a blank line, which parses without ambiguity -- a match can never
-- be blank, since the pattern requires a non-space after the hashes.
local function rg_headings_args()
    -- `--with-filename` explicitly: rg leaves the name out when it was given
    -- exactly one path, which is what the cache asks for when a single note has
    -- been written -- and then the first heading is read as the filename.
    return { "rg", "--no-messages", "--no-ignore-vcs", "--heading", "--with-filename",
        "--no-line-number", "--color", "never", "--glob", "*." .. config.options.extension,
        "-e", [[^#+\s+\S]] }
end

--- @param found string[]|nil what the heading pass said, or nil when it could not
local function headings_by_path(found)
    if not found then return nil end

    local by_path, current = {}, nil
    for _, line in ipairs(found) do
        if line == "" then
            current = nil
        elseif current == nil then
            current = line
            by_path[current] = {}
        else
            table.insert(by_path[current], line)
        end
    end
    return by_path
end

-- The headings of one note, for when ripgrep is not there to have read them all.
local function headings_of(rel)
    local ok, lines = pcall(vim.fn.readfile, utils.join_path(config.options.home, rel))
    local found = {}
    for _, line in ipairs(ok and lines or {}) do
        if line:match("^#+%s+%S") then found[#found + 1] = line end
    end
    return found
end

-- Headings already read, kept between openings of the picker.
--
-- Reading them is what opening the finder costs -- 455ms over 494 notes on the
-- WSL2 laptop, against 10ms here -- and almost nothing about them has changed
-- since the last time. So they are kept, and the passes above only ask about
-- notes this has never seen.
--
-- What that trades away is a heading edited by something other than this Neovim:
-- a `git pull`, another machine, or Claude writing to a note in a pane. The file
-- *list* is walked every time, so a new note is never missed; it is the heading
-- text of a note already read that can lag, which costs at most a romaji query
-- that does not reach a heading it should. Two things bound it: writing a note in
-- this Neovim drops that note from the cache, and the whole cache is thrown away
-- after `find.headings_stale_after` seconds (0 to keep nothing).
local function stale_after()
    local find = config.options.find or {}
    return find.headings_stale_after or 300
end

local cache = { home = nil, headings = {}, warm = false, read_at = 0 }
local watching = false

-- A note written in this Neovim is a heading edit we *can* see, so see it.
local function watch_writes()
    if watching then return end
    watching = true
    vim.api.nvim_create_autocmd("BufWritePost", {
        group = vim.api.nvim_create_augroup("FzfkastenNoteIndex", { clear = true }),
        callback = function(ev)
            local home = config.options.home
            if not home or home == "" then return end
            local written = vim.fn.fnamemodify(ev.file or "", ":p")
            local prefix = home:gsub("/$", "") .. "/"
            if vim.startswith(written, prefix) then
                cache.headings[written:sub(#prefix + 1)] = nil
            end
        end,
    })
end

--- @return { headings: table<string, string[]>, warm: boolean }
local function cached_headings()
    watch_writes()
    local aged = (vim.uv.hrtime() / 1e6 - cache.read_at) / 1000 >= stale_after()
    if cache.home ~= config.options.home or aged then
        cache = { home = config.options.home, headings = {}, warm = false, read_at = vim.uv.hrtime() / 1e6 }
    end
    return cache
end

-- Everything the note finder matches a note against: its path, and its own
-- headings unless `romaji.headings` says otherwise. Built when the picker opens
-- and reused for every keystroke after that, which is what makes matching on
-- each keystroke affordable at all.
--
-- Headings and not the whole body, because that keeps this picker about finding
-- a *note*. Searching the body is what `:FzfKastenSearchContent` is.
--
-- Matching against headings at all is what makes romaji narrowing worth having:
-- measured against 464 real notes, 32 had any Japanese in the filename while 135
-- carried it in their headings, 1654 headings' worth. Matching paths only, the
-- filter looked broken -- it ran, it narrowed, and it found almost nothing.
--- @return { rel: string, text: string }[]
local function note_index()
    local scan_headings = (config.options.romaji or {}).headings ~= false
    local known = scan_headings and cached_headings() or nil

    -- The list is walked every time: it is the cheap half, and it is the half
    -- that must be right -- a note written a moment ago has to be findable.
    local listing = rg_start(rg_files_args())

    -- The headings are the expensive half, so only notes the cache has never
    -- read are read. A cold cache asks about the whole collection at once, which
    -- is one rg rather than 494; a warm one usually asks about nothing, and the
    -- second pass does not happen at all.
    local scan
    if scan_headings and not known.warm then
        scan = rg_start(rg_headings_args())
    end

    local rels = note_rel_paths(rg_lines(listing))

    if scan_headings and known.warm then
        local unread = {}
        for _, rel in ipairs(rels) do
            if not known.headings[rel] then unread[#unread + 1] = rel end
        end
        if #unread > 0 then
            local args = rg_headings_args()
            args[#args + 1] = "--"
            vim.list_extend(args, unread)
            scan = rg_start(args)
        end
    end

    if scan_headings then
        local scanned = headings_by_path(rg_lines(scan))
        if scanned then
            for rel, found in pairs(scanned) do known.headings[rel] = found end
            -- A note with no headings has to be remembered as such, or it is a
            -- miss on every open and the cache never warms for it.
            for _, rel in ipairs(rels) do
                known.headings[rel] = known.headings[rel] or {}
            end
            known.warm = true
        end
    end

    local index = {}
    for _, rel in ipairs(rels) do
        local text = rel
        if scan_headings then
            -- Nothing cached and no rg to ask means reading the note here, which
            -- is what this used to do for every note on every open.
            local found = known.headings[rel] or headings_of(rel)
            if #found > 0 then
                text = rel .. "\n" .. table.concat(found, "\n")
            end
        end
        index[#index + 1] = { rel = rel, text = text }
    end
    return index
end

-- Notes the romaji filter matches, by path or by their own headings -- the same
-- ground `note_index` lays out, so the link inserter and the finder agree on
-- what a romaji query reaches.
--- @param filter string a `\m` Vim regex, or nil for everything
--- @return string[] paths relative to `home`
local function notes_matching(filter)
    local shown = {}
    for _, entry in ipairs(note_index()) do
        if romaji.matches(entry.text, filter) then shown[#shown + 1] = entry.rel end
    end
    return shown
end

-- Neovim's own fuzzy matcher, in this process.
--
-- A live picker has to turn fzf's matching off (`--disabled`): otherwise fzf
-- would filter our already-filtered list by the raw query and throw away
-- everything a romaji query had found. That leaves ordinary typing needing a
-- fuzzy matcher of its own.
--
-- This was `fzf --filter`, on the reasoning that fzf's matcher should be fzf's
-- and not an approximation of it by a plugin author. What that reasoning costs
-- is a process per keystroke: 4.5ms here, 166ms on the WSL2 machine this is also
-- used from, on top of the process fzf-lua already spawns to ask us -- which is
-- typing into a finder that answers a fifth of a second late. `matchfuzzy` is C,
-- in process, 0.2ms, and agrees with `fzf --filter` on the queries people type:
-- `nvmcfg` finds `nvim/config/init.lua.md`, `nvim conf` still ANDs its words.
--
-- What it does not have is fzf's operators -- `'exact`, `!not`, `^prefix`,
-- `$suffix` -- which now match as the literal characters they are.
local function fuzzy_filter(list, query)
    -- Raises on an invalid argument rather than returning nothing; showing
    -- everything is a better answer to that than an empty picker.
    local ok, matched = pcall(vim.fn.matchfuzzy, list, query)
    if not ok then return list end
    return matched
end

-- A query beginning with this is romaji: `/kaigi` matches 会議.
--
-- Taken from fzf-jp-extension, which patches the same token into fzf itself.
-- Doing it out here keeps stock fzf, and keeps fzf's matcher for every other
-- query -- the two modes cost nothing to each other.
local ROMAJI_PREFIX = "/"

-- The notes to show for `query`.
--
-- With no romaji backend, or one that cannot answer yet, `/kaigi` matches the
-- text `kaigi` as it stands rather than showing nothing. A picker that empties
-- itself looks the same as one whose filter found nothing, and the header only
-- offers `/` when a backend is there to honour it.
--- @param index { rel: string, text: string }[]
--- @param query string|nil
--- @return string[] paths relative to `home`
local function notes_for_query(index, query)
    query = query or ""
    local romaji_query = query:sub(1, #ROMAJI_PREFIX) == ROMAJI_PREFIX
        and query:sub(#ROMAJI_PREFIX + 1) or nil

    if romaji_query then
        local re = romaji.regex(romaji_query)
        if re then
            local shown = {}
            for _, entry in ipairs(index) do
                if vim.fn.match(entry.text, re) >= 0 then shown[#shown + 1] = entry.rel end
            end
            return shown
        end
        query = romaji_query
    end

    local all = {}
    for _, entry in ipairs(index) do all[#all + 1] = entry.rel end
    if query == "" then return all end
    return fuzzy_filter(all, query)
end

-- Says the `/` is there, and what it does, in the one place you are looking
-- when you would need it. A key you have to remember is a key you do not use.
local function find_header()
    if not romaji.available() then return "" end
    return "prefix / for romaji:  /kaigi → 会議"
end

-- fzf's version, asked once. The finder's fast path is built out of `transform`,
-- which arrived in 0.45; below that there is nothing to check for again.
local fzf_version
local function fzf_at_least(major, minor)
    if fzf_version == nil then
        local first = vim.fn.executable("fzf") == 1
            and (vim.fn.systemlist({ "fzf", "--version" })[1] or "") or ""
        local a, b = first:match("(%d+)%.(%d+)")
        fzf_version = a and { tonumber(a), tonumber(b) } or false
    end
    if not fzf_version then return false end
    if fzf_version[1] ~= major then return fzf_version[1] > major end
    return fzf_version[2] >= minor
end

-- Where the shell side of the finder keeps what it needs. One directory per
-- Neovim, inside its own temp directory, so it goes when Neovim goes.
local shell_home

-- Hand fzf everything it needs to narrow by romaji without us.
--
-- The live picker asks Neovim on every keystroke, and asking costs a process:
-- fzf-lua spawns `nvim -u NONE -l rpc.lua` to do it, 7ms here and 68ms on the
-- WSL2 laptop, for a query that in the ordinary case fzf could have matched
-- itself. So in the ordinary case, let it.
--
--   * fzf keeps its own matcher (no `--disabled`), so plain typing leaves this
--     process entirely alone -- no reload, no spawn, and fzf's own operators
--     (`'exact`, `!not`, `^prefix`) work again, which the Lua matcher had lost.
--   * `change` starts unbound, so nothing runs per keystroke at all.
--   * `/` on an empty query rebinds it. From then on each keystroke asks a
--     three-line shell script whether the query is still romaji: if it is, fzf
--     reloads from the migemo and `search()` clears its own matching so the
--     reloaded list survives; if it is not, `change` is unbound again and the
--     full list comes back. Deleting the `/` returns to fzf's matcher, and
--     nothing is left running.
--   * a `/` typed inside a query is just a `/`, which paths are full of.
--
-- Returns the binds, or nil when this cannot be done here -- an old fzf, no rg,
-- or a backend that only exists inside Neovim (kensaku runs on denops, and a
-- backend you passed as a table is Lua). The live picker answers those.
--- @return table<string, string>|nil
local function shell_binds(index)
    local migemo = romaji.rg_command()
    if not migemo or vim.fn.executable("rg") ~= 1 or not fzf_at_least(0, 45) then
        return nil
    end

    if not shell_home then
        shell_home = vim.fn.tempname()
        vim.fn.mkdir(shell_home, "p")
    end
    -- Nothing in here may need quoting when a shell script names it, and
    -- Neovim's temp names never do -- but a check beats a picker that fails in
    -- a way only fzf can see.
    if shell_home:match("[%s'\"$`]") then return nil end

    local lines = {}
    for _, entry in ipairs(index) do
        -- One line per note: the path, then everything it is matched against.
        -- Tabs would split the line where it must not split.
        lines[#lines + 1] = entry.rel .. "\t" .. entry.text:gsub("[\t\n]", " ")
    end
    local tsv = shell_home .. "/index.tsv"
    vim.fn.writefile(lines, tsv)

    local escaped = {}
    for _, word in ipairs(migemo) do escaped[#escaped + 1] = vim.fn.shellescape(word) end
    local romaji_sh = shell_home .. "/romaji.sh"
    vim.fn.writefile({
        "#!/bin/sh",
        "# Written by fzfkasten. Narrows the note index by the romaji in $1.",
        "# Anything it cannot answer shows every note, because a picker that",
        "# empties itself reads as a filter that found nothing.",
        'index="$(dirname "$0")/index.tsv"',
        'all() { cut -f1 "$index"; }',
        'q=${1#/}',
        '[ -n "$q" ] || { all; exit 0; }',
        're=$(' .. table.concat(escaped, " ") .. ' -- "$q" 2>/dev/null) || { all; exit 0; }',
        '[ -n "$re" ] || { all; exit 0; }',
        'rg -N --no-heading --color never -e "$re" "$index" | cut -f1',
    }, romaji_sh)

    local change_sh = shell_home .. "/change.sh"
    vim.fn.writefile({
        "#!/bin/sh",
        "# Written by fzfkasten. Tells fzf what a changed query means: romaji",
        "# while it starts with a slash, and fzf's own matching once it does not.",
        'dir=$(dirname "$0")',
        'case "$1" in',
        "  /*) echo \"search()+reload:'$dir/romaji.sh' {q}\" ;;",
        -- No `search()` here on purpose: fzf has already searched for the new
        -- query by the time this runs, and setting it again from `{q}` sets it
        -- to the *quoted* query, which matches nothing (measured).
        "  *)  echo \"unbind(change)+reload:cut -f1 '$dir/index.tsv'\" ;;",
        "esac",
    }, change_sh)

    for _, script in ipairs({ romaji_sh, change_sh }) do
        vim.fn.setfperm(script, "rwx------")
    end

    return {
        -- `+` so this joins whatever fzf-lua binds to `start` rather than
        -- replacing it.
        ["start"] = "+unbind(change)",
        ["change"] = "transform:'" .. change_sh .. "' {q}",
        ["/"] = "transform:[ -z {q} ] && echo 'rebind(change)+put(/)' || echo 'put(/)'",
    }
end

function M.find_notes()
    local function open(selected)
        if not selected or #selected == 0 then return end
        local entry = fzf.path.entry_to_file(selected[1], { cwd = config.options.home })
        buffer.edit(entry.path)
    end

    local index = note_index()
    local opts = vim.tbl_deep_extend("force", config.options.fzf, {
        cwd = config.options.home,
        prompt = "Notes> ",
        previewer = "builtin",
        fzf_opts = { ["--header"] = find_header() },
        actions = { ['default'] = open },
    })

    local binds = shell_binds(index)
    if binds or not romaji.available() then
        -- A static list with fzf matching on. With no romaji backend there is
        -- nothing to be live *for*, and `/` is only a character again.
        local paths = {}
        for _, entry in ipairs(index) do paths[#paths + 1] = entry.rel end
        if binds then
            opts.keymap = vim.tbl_deep_extend("force", opts.keymap or {}, { fzf = binds })
        end
        return fzf.fzf_exec(paths, opts)
    end

    fzf.fzf_live(function(args) return notes_for_query(index, args[1]) end, opts)
end
function M.search_tags()
    -- Use a regex that strictly matches #tag
    local rg_tag_pattern = "#[a-zA-Z0-9_-]+"

    fzf.grep(vim.tbl_deep_extend("force", config.options.fzf, {
        search = rg_tag_pattern,
        cwd = config.options.home,
        prompt = "Tags> ",
        rg_opts = "--column --line-number --no-heading --color=always --smart-case --only-matching -e",
        no_esc = true,
        actions = {
            ['default'] = function(selected)
                if not selected or #selected == 0 then return end
                local entry = fzf.path.entry_to_file(selected[1], { cwd = config.options.home })
                buffer.edit(entry.path)
                if entry.line then
                    vim.api.nvim_win_set_cursor(0, { entry.line, (entry.col or 1) - 1 })
                end
            end
        }
    }))
end

function M.search_by_tag()
    -- 1. Extract all unique tags
    -- Lua pattern: # followed by alphanumeric, _, or -
    local tag_lua_pattern = "#([%w_-]+)"
    local all_notes_pattern = utils.join_path(config.options.home, "**/*." .. config.options.extension)
    local all_notes = vim.fn.glob(all_notes_pattern, true, true)
    
    local tags_set = {}
    for _, note_file in ipairs(all_notes) do
        local file = io.open(note_file, "r")
        if file then
            local content = file:read("*a")
            file:close()
            -- In Lua, we match the tag name following the #
            for tag_name in string.gmatch(content, tag_lua_pattern) do
                tags_set["#" .. tag_name] = true
            end
        end
    end

    local tags_list = {}
    for tag, _ in pairs(tags_set) do
        table.insert(tags_list, tag)
    end
    table.sort(tags_list)

    if #tags_list == 0 then
        vim.notify("No tags found in your Zettelkasten.", vim.log.levels.INFO)
        return
    end

    -- 2. Show tags in fzf
    fzf.fzf_exec(tags_list, vim.tbl_deep_extend("force", config.options.fzf, {
        prompt = "Select Tag> ",
        actions = {
            ['default'] = function(selected)
                if not selected or #selected == 0 then return end
                -- fzf_exec returns the raw string from tags_list
                local tag = selected[1]
                -- 3. Search for the selected tag across all notes
                fzf.grep(vim.tbl_deep_extend("force", config.options.fzf, {
                    search = tag .. " ", -- Add space to match tag exactly if followed by space
                    cwd = config.options.home,
                    prompt = "Notes with " .. tag .. "> ",
                    actions = {
                        ['default'] = function(grep_selected)
                            if not grep_selected or #grep_selected == 0 then return end
                            local entry = fzf.path.entry_to_file(grep_selected[1], { cwd = config.options.home })
                            buffer.edit(entry.path)
                            if entry.line then
                                vim.api.nvim_win_set_cursor(0, { entry.line, (entry.col or 1) - 1 })
                            end
                        end
                    }
                }))
            end
        }
    }))
end
function M.insert_link(filter)
    local function insert(selected)
        if not selected or #selected == 0 then return end
        local entry = fzf.path.entry_to_file(selected[1], { cwd = config.options.home })
        local file = vim.fn.fnamemodify(entry.path, ":t:r")
        vim.api.nvim_put({ config.options.transform.insert_link(file) }, "c", true, true)
    end

    if not filter then
        fzf.files(vim.tbl_deep_extend("force", config.options.fzf.files, {
            cwd = config.options.home,
            prompt = "Insert Link> ",
            fzf_opts = { ["--header"] = romaji.header_hint("") },
            actions = {
                ['default'] = insert,
                ['alt-/'] = romaji.action(function(re) M.insert_link(re) end, nil),
            },
        }))
        return
    end

    -- Filtered by romaji, like `find_notes`, so a note written in Japanese is
    -- reachable without typing Japanese -- whether the Japanese is in its name
    -- or only in its headings.
    local shown = notes_matching(filter)
    fzf.fzf_exec(shown, vim.tbl_deep_extend("force", config.options.fzf, {
        cwd = config.options.home,
        prompt = romaji.prompt("Insert Link", filter),
        previewer = "builtin",
        fzf_opts = { ["--header"] = romaji.header_hint("") },
        actions = {
            ['default'] = insert,
            ['alt-/'] = romaji.action(function(re) M.insert_link(re) end, filter),
        },
    }))
end

function M.search_content(filter)
    local function open(selected)
        if not selected or #selected == 0 then return end
        local entry = fzf.path.entry_to_file(selected[1], { cwd = config.options.home })
        buffer.edit(entry.path)
        if entry.line then
            vim.api.nvim_win_set_cursor(0, { entry.line, (entry.col or 1) - 1 })
        end
    end

    -- No filter: the normal live grep (query is the rg pattern), plus `<alt-/>`
    -- to run a romaji search instead.
    --
    -- No `cmd` here. Setting it to "rg" replaces the whole command line, not
    -- just the binary, so fzf-lua's `rg_opts` are dropped -- and with them
    -- `--smart-case` (so `readme` stopped finding README), `--color=always`,
    -- `--max-columns=4096`, and the `-e` that keeps a query beginning with `-`
    -- from being read as a flag. fzf-lua patched `--line-number` and
    -- `--column` back in and said so, twice, on every open.
    if not filter then
        fzf.live_grep(vim.tbl_deep_extend("force", config.options.fzf, {
            cwd = config.options.home,
            prompt = "Grep> ",
            no_ignore = true,
            fzf_opts = { ["--header"] = romaji.header_hint("") },
            actions = {
                ['default'] = open,
                ['alt-/'] = romaji.grep_action(function(re) M.search_content(re) end, nil),
            },
        }))
        return
    end

    -- Filtered: the backend turned the romaji into an rg regex, so grep for it once
    -- (`no_esc` -- it is already a pattern) and let fzf narrow the hits. This is
    -- where romaji pays off most: note bodies are mostly Japanese.
    fzf.grep(vim.tbl_deep_extend("force", config.options.fzf, {
        search = filter,
        no_esc = true,
        cwd = config.options.home,
        prompt = romaji.prompt("Grep", filter),
        no_ignore = true,
        fzf_opts = { ["--header"] = romaji.header_hint("") },
        actions = {
            ['default'] = open,
            ['alt-/'] = romaji.grep_action(function(re) M.search_content(re) end, filter),
        },
    }))
end

-- The note name a path stands for ("path/to/my_note.md" -> "my_note"). Moved to
-- utils once the link graph needed the same answer; kept under this name here
-- because the backlink walk below reads better for it.
local get_note_name = utils.note_name

-- Every line in the collection that links to `filepath`, as "rel:lineno: text"
-- with `rel` relative to `home`.
--
-- Split out from the picker so that what counts as a link can be tested. It is
-- the same question `follow_link` and `rename_note` answer, and all three have
-- to answer it alike: `[[note#heading]]` is a link to `note`. Read as a name of
-- its own it matches nothing, and the note it points at then shows no backlink
-- from it -- which reads as "nothing links here", not as "the anchor threw me".
--
-- Relative to `home` rather than to the working directory because that is what
-- the picker's action resolves against. A `:~:.` path from a cwd outside the
-- collection is neither relative nor absolute -- `~/notes/a.md` -- and gets the
-- notes directory prepended to it, so the entry opens nothing.
--- @return string[]|nil entries, string|nil note_name
local function collect_backlinks(filepath)
    local target = get_note_name(filepath)
    if not target then
        return nil, nil
    end

    local home = config.options.home
    local pattern = utils.join_path(home, "**/*." .. config.options.extension)
    -- Resolved both sides: the path we were handed and the ones glob returns
    -- are the same file spelt differently often enough (a symlinked collection,
    -- a relative argument) that comparing them raw lists the note under itself.
    local self_path = vim.fn.resolve(vim.fn.fnamemodify(filepath, ":p"))
    local link_pattern = config.options.patterns.link
    local backlinks = {}

    for _, note_file in ipairs(vim.fn.glob(pattern, true, true) or {}) do
        if vim.fn.resolve(vim.fn.fnamemodify(note_file, ":p")) ~= self_path then
            local ok, lines = pcall(vim.fn.readfile, note_file)
            for lineno, line in ipairs(ok and lines or {}) do
                for inner in line:gmatch(link_pattern) do
                    local name = utils.split_link(inner)
                    if name == target then
                        backlinks[#backlinks + 1] = string.format("%s:%d: %s",
                            note_file:gsub("^" .. vim.pesc(home) .. "/?", ""),
                            lineno,
                            vim.trim(line))
                        break -- one entry per line, however many links it holds
                    end
                end
            end
        end
    end

    return backlinks, target
end

-- Actual implementation of show_backlinks
function M.show_backlinks(filepath)
    local backlinks, target_note_name = collect_backlinks(filepath)
    if not backlinks then
        vim.notify("Could not determine note name from path: " .. tostring(filepath), vim.log.levels.ERROR)
        return
    end

    if #backlinks == 0 then
        vim.notify("No backlinks found for '" .. target_note_name .. "'.", vim.log.levels.INFO)
        return
    end

    fzf.fzf_exec(backlinks, vim.tbl_deep_extend("force", config.options.fzf, {
        prompt = "Backlinks for " .. target_note_name .. "> ",
        actions = {
            ['default'] = function(selected_backlink)
                if not selected_backlink or #selected_backlink == 0 then return end
                local entry = fzf.path.entry_to_file(selected_backlink[1], { cwd = config.options.home })
                if entry.path then
                    buffer.edit(entry.path)
                    if entry.line then
                        vim.api.nvim_win_set_cursor(0, { entry.line, (entry.col or 1) - 1 })
                    end
                else
                    vim.notify("Could not open backlink: " .. selected_backlink[1], vim.log.levels.ERROR)
                end
            end
        }
    }))
end

function M.panel()
    fzf.files(vim.tbl_deep_extend("force", config.options.fzf.files, {
        cwd = config.options.home,
        prompt = "Panel: Select Note> ",
        actions = {
            ['default'] = function(selected)
                if not selected or #selected == 0 then return end
                local entry = fzf.path.entry_to_file(selected[1], { cwd = config.options.home })
                local clean_path = entry.path
                local actions = {
                    "Open: " .. clean_path,
                    "Show Backlinks: " .. clean_path,
                    "Rename: " .. clean_path,
                    "Delete: " .. clean_path,
                }

                fzf.fzf_exec(actions, vim.tbl_deep_extend("force", config.options.fzf, {
                    prompt = "Action> ",
                    actions = {
                        ['default'] = function(action_selected)
                            if not action_selected or #action_selected == 0 then return end
                            local selection = action_selected[1]

                            if selection:find("Open:") then
                                buffer.edit(clean_path)
                            elseif selection:find("Show Backlinks:") then
                                M.show_backlinks(clean_path)
                            elseif selection:find("Rename:") then
                                require('fzfkasten.core').rename_note_interactively(clean_path)
                            elseif selection:find("Delete:") then
                                local confirmation = vim.fn.input("Confirm deletion of " .. clean_path .. " (yes/no)? ")
                                if confirmation:lower() == "yes" then
                                    vim.fn.delete(clean_path)
                                    vim.notify("Deleted: " .. clean_path, vim.log.levels.INFO)
                                else
                                    vim.notify("Deletion cancelled.", vim.log.levels.INFO)
                                end
                            end
                        end
                    }
                }))
            end
        }
    }))
end

-- Find note files whose name matches `name` anywhere under `home` (recursive),
-- so links to notes in subdirectories (e.g. dailies) resolve too.
--
-- `dir` is the directory a link named, if it named one (`[[lognote/2025-W34]]`).
-- It only ever picks between notes that share a name, and only when it picks
-- something: a note that has since moved elsewhere is still the note that link
-- meant, and refusing to open it because it is no longer where the link says
-- would be worse than opening it.
local function resolve_note_files(name, dir)
    local pattern = utils.join_path(config.options.home, "**/*." .. config.options.extension)
    local files = vim.fn.glob(pattern, true, true) or {}
    local matches = {}
    for _, f in ipairs(files) do
        if vim.fn.fnamemodify(f, ":t:r") == name then
            table.insert(matches, f)
        end
    end

    if dir and dir ~= "" and #matches > 1 then
        local in_dir = {}
        for _, f in ipairs(matches) do
            local parent = vim.fn.fnamemodify(f, ":h")
            if parent == dir or parent:sub(-(#dir + 1)) == "/" .. dir then
                table.insert(in_dir, f)
            end
        end
        if #in_dir > 0 then
            return in_dir
        end
    end

    return matches
end

-- Create a note for a non-existing link target, in the home root, from a
-- template. Mirrors telekasten's follow_creates_nonexisting behaviour.
local function create_note_for_link(name)
    local fl = config.options.follow_link or {}
    local full_path = utils.join_path(config.options.home, name .. "." .. config.options.extension)
    buffer.edit(full_path)

    local core = require('fzfkasten.core')
    local template = fl.new_note_template or config.options.new_note_template
    local content = template and core.load_template(template, name) or ("# " .. name)

    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    if #lines <= 1 and (lines[1] == nil or lines[1] == "") then
        vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.split(content, "\n"))
    end
    vim.bo.filetype = "markdown"
end

-- Put the cursor on the line an id names.
--
-- The id answers by itself, so nothing here matches on the text: a task reworded
-- after it was linked to still resolves, which is the whole reason to point at a
-- line by id rather than at the heading it happens to sit under.
local function jump_to_block_id(id)
    for lineno, line in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
        if utils.block_id(line) == id then
            vim.api.nvim_win_set_cursor(0, { lineno, 0 })
            vim.cmd("normal! zz")
            return
        end
    end
    vim.notify("[Fzfkasten] No line '^" .. id .. "' in this note.", vim.log.levels.WARN)
end

-- Put the cursor where an anchor points, in the buffer just opened: on a line
-- when the anchor is an id, on the heading it names otherwise.
--
-- A heading is matched on its text rather than a slug, because that is what the
-- link says: `[[note#Results]]` is written by reading the note, not by guessing
-- how its headings would be encoded. Case-insensitive, since a heading is prose
-- and nobody recalls its capitalisation.
--
-- Nothing found is worth saying: the note opened at the top and looks like it
-- worked, so silence here reads as "there is no such section" only to whoever
-- already suspected it.
local function jump_to_anchor(anchor)
    if not anchor or anchor == "" then return end
    local trimmed = vim.trim(anchor)
    -- `#^id` names a line, anything else names a heading.
    local id = trimmed:match("^%^(.+)$")
    if id then
        return jump_to_block_id(id)
    end
    local wanted = trimmed:lower()
    for lineno, line in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
        local heading = line:match("^#+%s+(.-)%s*$")
        if heading and heading:lower() == wanted then
            vim.api.nvim_win_set_cursor(0, { lineno, 0 })
            vim.cmd("normal! zz")
            return
        end
    end
    vim.notify("[Fzfkasten] No heading '" .. anchor .. "' in this note.", vim.log.levels.WARN)
end

-- Open a link target (an inner "[[...]]" string, which may carry an anchor and
-- an alias): resolve recursively, pick via fzf on multiple matches, create when
-- missing (if configured), otherwise warn.
--
-- The anchor has to come off before anything looks for the note. Left on, the
-- name is "note#heading", which matches no file -- so with
-- `follow_link.create_nonexisting` set, following your own anchored link would
-- open a *new* note called `note#heading`, template and all, and one `:w` would
-- make it real. The directory and the extension come off for the same reason,
-- and the directory is kept to choose between notes that share a name.
local function open_link_target(raw_target)
    local name, anchor, _, dir = utils.split_link(raw_target)
    if not name or name == "" then return end

    local matches = resolve_note_files(name, dir)
    if #matches == 1 then
        buffer.edit(matches[1])
        jump_to_anchor(anchor)
    elseif #matches > 1 then
        fzf.fzf_exec(matches, vim.tbl_deep_extend("force", config.options.fzf, {
            prompt = "Multiple matches for '" .. name .. "'> ",
            actions = {
                ['default'] = function(selected)
                    if not selected or #selected == 0 then return end
                    buffer.edit(selected[1])
                    jump_to_anchor(anchor)
                end
            }
        }))
    else
        local fl = config.options.follow_link or {}
        if fl.create_nonexisting then
            create_note_for_link(name)
        else
            vim.notify("Note not found: " .. name, vim.log.levels.WARN)
        end
    end
end

-- Return the inner text of the "[[...]]" link under the cursor, or nil.
local function link_under_cursor()
    local line = vim.api.nvim_get_current_line()
    local cursor_col = vim.api.nvim_win_get_cursor(0)[2] + 1 -- 1-indexed byte column
    local init = 1
    while true do
        local s, e, inner = line:find("%[%[(.-)%]%]", init)
        if not s then break end
        if cursor_col >= s and cursor_col <= e then
            return inner
        end
        init = e + 1
    end
    return nil
end

function M.follow_link()
    -- Prefer the link under the cursor (telekasten-style direct follow).
    local under = link_under_cursor()
    if under and under ~= "" then
        open_link_target(under)
        return
    end

    -- Otherwise list every link in the buffer and let the user pick.
    local current_buffer_content = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local link_pattern = config.options.patterns.link

    -- display -> target map, preserving insertion order
    local entries = {}
    local seen = {}
    for _, line in ipairs(current_buffer_content) do
        for link_text in string.gmatch(line, link_pattern) do
            if link_text ~= "" then
                local target, alias = link_text:match("^(.-)|(.*)$")
                target = target or link_text
                local display = alias and string.format("%s  →  %s", alias, target) or target
                if not seen[display] then
                    seen[display] = target
                    table.insert(entries, display)
                end
            end
        end
    end

    if #entries == 0 then
        vim.notify("No links found in current buffer.", vim.log.levels.INFO)
        return
    end

    fzf.fzf_exec(entries, vim.tbl_deep_extend("force", config.options.fzf, {
        prompt = "Follow Link> ",
        actions = {
            ['default'] = function(selected_link)
                if not selected_link or #selected_link == 0 then return end
                local target = seen[selected_link[1]]
                if not target then return end
                open_link_target(target)
            end
        }
    }))
end

-- Intended to be mapped to `gf` in note buffers: follow the wikilink under the
-- cursor, falling back to Vim's built-in `gf` when there is none.
function M.goto_link()
    local under = link_under_cursor()
    if under and under ~= "" then
        open_link_target(under)
    else
        local ok, err = pcall(vim.cmd, "normal! gf")
        if not ok then
            vim.notify(tostring(err), vim.log.levels.WARN)
        end
    end
end

-- Put `text` where `p` will find it. The unnamed register is what `p` reads; `0`
-- is where a yank also lands, so the link survives a delete made on the way to
-- wherever it is being pasted. The selection registers are written only when
-- `clipboard` says the two are meant to be one thing -- writing them unasked
-- would replace whatever had been copied outside Neovim.
local function set_yank_registers(text)
    vim.fn.setreg('"', text, "c")
    vim.fn.setreg("0", text, "c")
    for _, which in ipairs(vim.split(vim.o.clipboard or "", ",", { trimempty = true })) do
        if which == "unnamed" then
            vim.fn.setreg("*", text, "c")
        elseif which == "unnamedplus" then
            vim.fn.setreg("+", text, "c")
        end
    end
end

-- The alias a yanked link carries when `block_id.alias` is on: what the line
-- says, with everything that is not prose taken off.
--
-- The tags go, and that is the part worth explaining. Copying `#todo #qms` into
-- the daily note would file that note under them too -- the tag search reads
-- every line, not only the ones that meant it -- so a link pasted for reference
-- would quietly join the collection's tag index. The brackets and the pipe go
-- because they are the link's own syntax and would end it early.
local function link_alias(line)
    local text = utils.strip_block_id(line)

    -- Off with the checkbox, or the bullet when the line carries no checkbox.
    local before, mark, after = text:match(config.options.tasks.patterns.toggle)
    if before then
        text = text:sub(#before + #mark + #after + 1)
    else
        text = text:gsub("^%s*[-*+]%s+", "")
    end

    text = text:gsub(config.options.patterns.tag, "")
    text = text:gsub("[%[%]|]", "")
    text = text:gsub("%s+", " ")
    text = vim.trim(text)

    -- Cut by character, not by byte: a Japanese line cut by byte ends mid-glyph
    -- and the alias renders as a broken character.
    local max = tonumber((config.options.block_id or {}).alias_max)
    if max and max > 0 and vim.fn.strchars(text) > max then
        text = vim.trim(vim.fn.strcharpart(text, 0, max)) .. "…"
    end
    return text
end

--- Mint an id for the line the cursor is on, write it there, and leave a link to
--- that line in the yank registers.
---
--- This direction, rather than reaching the line from wherever the link is being
--- written: the note holding the task is where you are when you decide it is
--- worth referring to, and the line is already under the cursor. From the other
--- end it would take a picker over every checkbox in the collection to find the
--- one you had just been reading.
---
--- An id already on the line is reused. Yanking twice is then the same link
--- twice, not two ids for one line -- and two ids is the state where rewording
--- the line breaks whichever of the links is not the one you follow.
function M.yank_block_link()
    local name = get_note_name(vim.api.nvim_buf_get_name(0))
    if not name or name == "" then
        vim.notify("[Fzfkasten] This buffer is not a note, so nothing can link to it.", vim.log.levels.WARN)
        return
    end

    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    local line = vim.api.nvim_buf_get_lines(0, lnum - 1, lnum, false)[1] or ""
    if vim.trim(line) == "" then
        vim.notify("[Fzfkasten] Nothing on this line to link to.", vim.log.levels.WARN)
        return
    end

    local id = utils.block_id(line)
    if not id then
        if not vim.bo.modifiable or vim.bo.readonly then
            vim.notify("[Fzfkasten] This buffer cannot be written to, so no id can be minted.", vim.log.levels.WARN)
            return
        end
        id = utils.new_block_id(utils.block_ids(vim.api.nvim_buf_get_lines(0, 0, -1, false)))
        vim.api.nvim_buf_set_lines(0, lnum - 1, lnum, false, { utils.with_block_id(line, id) })
    end

    local target = name .. "#^" .. id
    if (config.options.block_id or {}).alias then
        local alias = link_alias(line)
        if alias ~= "" then
            target = target .. "|" .. alias
        end
    end
    local link = "[[" .. target .. "]]"

    set_yank_registers(link)
    vim.notify("[Fzfkasten] Yanked " .. link)
end

function M.select_template(callback)
    local templates_dir = utils.join_path(config.options.home, "templates")

    fzf.files(vim.tbl_deep_extend("force", config.options.fzf.files, {
        cwd = templates_dir,
        prompt = "Select Template> ",
        actions = {
            ['default'] = function(selected)
                if selected and #selected > 0 then
                    local entry = fzf.path.entry_to_file(selected[1], { cwd = templates_dir })
                    local clean_filename = vim.fn.fnamemodify(entry.path, ":t")
                    if callback then
                        callback(clean_filename)
                    end
                else
                    if callback then
                        callback(nil) -- User cancelled or no selection
                    end
                end
            end,
            ['ctrl-c'] = function()
                if callback then
                    callback(nil) -- User cancelled
                end
            end,
        }
    }))
end

function M.find_daily_notes_picker()
    local daily_dir = utils.join_path(config.options.home, config.options.notes.daily.dir)
    fzf.files(vim.tbl_deep_extend("force", config.options.fzf.files, {
        cwd = daily_dir,
        prompt = "Find Daily Note> ",
        actions = {
            ['default'] = function(selected)
                if selected and #selected > 0 then
                    local entry = fzf.path.entry_to_file(selected[1], { cwd = daily_dir })
                    local full_path = entry.path
                    buffer.edit(full_path)
                    local title = vim.fn.fnamemodify(full_path, ":t:r")
                    require('fzfkasten.core').apply_note_template("daily", title)
                end
            end,
        }
    }, config.options.notes.daily.fzf_opts or {}))
end

local function prompt_manual_date_and_open()
    local input = vim.fn.input("Daily note date (YYYY-MM-DD): ")
    if not input or input:gsub("%s+", "") == "" then return end
    local y, mo, d = input:match("^(%d%d%d%d)-(%d%d)-(%d%d)$")
    if not y then
        vim.notify("Invalid date. Expected YYYY-MM-DD.", vim.log.levels.ERROR)
        return
    end
    local t = os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d), hour = 12 })
    if not t then
        vim.notify("Could not parse date.", vim.log.levels.ERROR)
        return
    end
    if t > os.time() then
        vim.notify("Future dates are not allowed.", vim.log.levels.ERROR)
        return
    end
    require('fzfkasten.core').open_note("daily", t)
end

-- Build the log picker's lines and a lookup from each line to the note it
-- stands for. Recent days first, then recent weeks. Each line is
-- "<rel>:1: <mark> <label>" so fzf-lua's builtin previewer (cwd = home) shows
-- the note when it exists; a missing note previews blank, and the mark (✓ / a
-- space) is what says which is which.
-- @return table entries, table lookup (entry string -> { type, time })
function M.log_entries(now)
    now = now or os.time()
    local home = config.options.home
    local ext = "." .. config.options.extension
    local new_name = config.options.transform.new_file_name

    local entries, lookup = {}, {}
    local function add(note_type, label, time)
        local note = config.options.notes[note_type]
        local rel = utils.join_path(note.dir, new_name(os.date(note.format, time)) .. ext)
        local exists = vim.fn.filereadable(utils.join_path(home, rel)) == 1
        local entry = string.format("%s:1: %s %s", rel, exists and "✓" or " ", label)
        table.insert(entries, entry)
        lookup[entry] = { type = note_type, time = time }
    end

    local daily = config.options.notes.daily
    for i = 0, (daily.lookback_days or 30) - 1 do
        local t = utils.days_from(now, -i)
        add("daily", os.date("%Y-%m-%d (%a)", t), t)
    end
    local weekly = config.options.notes.weekly
    for i = 0, (weekly.lookback_weeks or 8) - 1 do
        local t = utils.days_from(now, -i * 7)
        add("weekly", os.date(weekly.format, t), t)
    end
    return entries, lookup
end

-- One picker for the whole journal: recent days and weeks, existing notes
-- previewed and opened, missing ones created from their template on select.
-- Subsumes the daily/weekly finders -- it both browses (with preview) and
-- creates by date, which is what they did separately.
function M.log()
    local entries, lookup = M.log_entries()

    fzf.fzf_exec(entries, vim.tbl_deep_extend("force", config.options.fzf, {
        prompt = "Log> ",
        -- Entries carry paths relative to `home`; the builtin previewer needs
        -- this to resolve them, like the tasks picker.
        cwd = config.options.home,
        previewer = "builtin",
        fzf_opts = {
            ["--delimiter"] = ":",
            ["--with-nth"] = "3..",
            ["--no-sort"] = "",
            ["--header"] = "<ctrl-x> enter a date manually",
        },
        actions = {
            ['default'] = function(selected)
                if not selected or #selected == 0 then return end
                local p = lookup[selected[1]]
                if p then
                    require('fzfkasten.core').open_note(p.type, p.time)
                end
            end,
            ['ctrl-x'] = function()
                vim.schedule(prompt_manual_date_and_open)
            end,
        }
    }, config.options.notes.daily.fzf_opts or {}))
end

function M.find_weekly_notes_picker()
    local weekly_dir = utils.join_path(config.options.home, config.options.notes.weekly.dir)
    fzf.files(vim.tbl_deep_extend("force", config.options.fzf.files, {
        cwd = weekly_dir,
        prompt = "Find Weekly Note> ",
        actions = {
            ['default'] = function(selected)
                if selected and #selected > 0 then
                    local entry = fzf.path.entry_to_file(selected[1], { cwd = weekly_dir })
                    local full_path = entry.path
                    buffer.edit(full_path)
                    local title = vim.fn.fnamemodify(full_path, ":t:r")
                    require('fzfkasten.core').apply_note_template("weekly", title)
                end
            end,
        }
    }, config.options.notes.weekly.fzf_opts or {}))
end

-- Reading a link is the plugin's one piece of parsing that runs on every note,
-- and none of it is reachable from outside: the cursor lookup is a local, and
-- the backlink walk sat inside a picker. Exposed for the tests rather than
-- widened into the API.
M._test = {
    note_index = note_index,
    notes_for_query = notes_for_query,
    find_header = find_header,
    shell_binds = shell_binds,
    -- The heading cache lives across pickers, so a case that does not want the
    -- one the last case warmed says so, and one that wants to see it go stale
    -- can push it into the past rather than wait five minutes.
    forget_index = function() cache = { home = nil, headings = {}, warm = false, read_at = 0 } end,
    age_index = function(seconds) cache.read_at = cache.read_at - seconds * 1000 end,
    link_under_cursor = link_under_cursor,
    get_note_name = get_note_name,
    collect_backlinks = collect_backlinks,
}

return M
