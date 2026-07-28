local fzf = require('fzf-lua')
local config = require('fzfkasten.config')
local utils = require('fzfkasten.utils') -- Added for path joining if needed later
local buffer = require('fzfkasten.buffer') -- Opens notes and applies per-buffer opt-outs
local kensaku = require('fzfkasten.kensaku') -- Optional romaji narrowing (<alt-/>)
local M = {}

-- Every note file under `home`, as a path relative to `home` -- the same shape
-- `fzf.files` shows, so `entry_to_file(.., { cwd = home })` resolves either.
-- Used to rebuild the finder as a plain list when a romaji filter is active.
local function note_rel_paths()
    local pattern = utils.join_path(config.options.home, "**/*." .. config.options.extension)
    local files = vim.fn.glob(pattern, true, true) or {}
    local home = config.options.home
    local rels = {}
    for _, f in ipairs(files) do
        rels[#rels + 1] = f:gsub("^" .. vim.pesc(home) .. "/?", "")
    end
    return rels
end

function M.find_notes(filter)
    local function open(selected)
        if not selected or #selected == 0 then return end
        local entry = fzf.path.entry_to_file(selected[1], { cwd = config.options.home })
        buffer.edit(entry.path)
    end

    -- No filter: the normal `fzf.files` finder, with `<alt-/>` to start one.
    if not filter then
        fzf.files(vim.tbl_deep_extend("force", config.options.fzf.files, {
            cwd = config.options.home,
            prompt = "Notes> ",
            fzf_opts = { ["--header"] = kensaku.header_hint("") },
            actions = {
                ['default'] = open,
                ['alt-/'] = kensaku.action(function(re) M.find_notes(re) end, nil),
            },
        }))
        return
    end

    -- Filtered: kensaku can't reach into `fzf.files`, so list the notes
    -- ourselves and keep the ones whose path the romaji regex matches. The
    -- builtin previewer still shows each note (paths are relative to `home`).
    local shown = {}
    for _, rel in ipairs(note_rel_paths()) do
        if kensaku.matches(rel, filter) then shown[#shown + 1] = rel end
    end
    fzf.fzf_exec(shown, vim.tbl_deep_extend("force", config.options.fzf, {
        cwd = config.options.home,
        prompt = kensaku.prompt("Notes", filter),
        previewer = "builtin",
        fzf_opts = { ["--header"] = kensaku.header_hint("") },
        actions = {
            ['default'] = open,
            ['alt-/'] = kensaku.action(function(re) M.find_notes(re) end, filter),
        },
    }))
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
            fzf_opts = { ["--header"] = kensaku.header_hint("") },
            actions = {
                ['default'] = insert,
                ['alt-/'] = kensaku.action(function(re) M.insert_link(re) end, nil),
            },
        }))
        return
    end

    -- Filtered by romaji, like `find_notes`: list notes ourselves and keep the
    -- matches so a Japanese-titled note is reachable without typing Japanese.
    local shown = {}
    for _, rel in ipairs(note_rel_paths()) do
        if kensaku.matches(rel, filter) then shown[#shown + 1] = rel end
    end
    fzf.fzf_exec(shown, vim.tbl_deep_extend("force", config.options.fzf, {
        cwd = config.options.home,
        prompt = kensaku.prompt("Insert Link", filter),
        previewer = "builtin",
        fzf_opts = { ["--header"] = kensaku.header_hint("") },
        actions = {
            ['default'] = insert,
            ['alt-/'] = kensaku.action(function(re) M.insert_link(re) end, filter),
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
    if not filter then
        fzf.live_grep(vim.tbl_deep_extend("force", config.options.fzf, {
            cmd = "rg",
            cwd = config.options.home,
            prompt = "Grep> ",
            no_ignore = true,
            fzf_opts = { ["--header"] = kensaku.header_hint("") },
            actions = {
                ['default'] = open,
                ['alt-/'] = kensaku.grep_action(function(re) M.search_content(re) end, nil),
            },
        }))
        return
    end

    -- Filtered: kensaku turned the romaji into an rg regex, so grep for it once
    -- (`no_esc` -- it is already a pattern) and let fzf narrow the hits. This is
    -- where romaji pays off most: note bodies are mostly Japanese.
    fzf.grep(vim.tbl_deep_extend("force", config.options.fzf, {
        search = filter,
        no_esc = true,
        cwd = config.options.home,
        prompt = kensaku.prompt("Grep", filter),
        no_ignore = true,
        fzf_opts = { ["--header"] = kensaku.header_hint("") },
        actions = {
            ['default'] = open,
            ['alt-/'] = kensaku.grep_action(function(re) M.search_content(re) end, filter),
        },
    }))
end

-- Helper to extract the note name from a full path (e.g., "path/to/my_note.md" -> "my_note")
local function get_note_name(filepath)
    if not filepath or type(filepath) ~= "string" or filepath == "v:null" then
        return nil -- Return nil if input path is invalid
    end

    local filename_with_ext = vim.fn.fnamemodify(filepath, ":t")
    if not filename_with_ext or type(filename_with_ext) ~= "string" or filename_with_ext == "v:null" then
        return nil -- Return nil if fnamemodify returns invalid filename
    end

    local basename = filename_with_ext:match("^(.*)%.[^%.]*$")
    if basename then
        return basename
    else
        return filename_with_ext -- No extension, return as is (e.g., "my_note", ".bashrc")
    end
end

-- Actual implementation of show_backlinks
function M.show_backlinks(filepath)
    vim.notify("DEBUG: show_backlinks called with filepath: '" .. tostring(filepath) .. "'", vim.log.levels.INFO)
    local target_note_name = get_note_name(filepath)
    if not target_note_name then
        vim.notify("Could not determine note name from path: " .. tostring(filepath), vim.log.levels.ERROR)
        return
    end
    local backlinks = {}

    local all_note_files_pattern = utils.join_path(config.options.home, "**/*." .. config.options.extension)
    local all_note_files = vim.fn.glob(all_note_files_pattern, true, true)

    if not all_note_files or #all_note_files == 0 then
        vim.notify("No other notes found in your Zettelkasten.", vim.log.levels.INFO)
        return
    end

    -- Construct a regex to find links to the target note
    -- This regex looks for [[target_note_name]] or [[target_note_name|alias]]
    local link_search_pattern = "\\[\\[" .. target_note_name:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1") .. "(\\|.-)?\\]\\]"

    for _, note_file in ipairs(all_note_files) do
        if note_file ~= filepath then -- Don't search in the current file itself
            local file = io.open(note_file, "r")
            if file then
                local content = file:read("*a")
                file:close()

                -- Split content into lines to search for backlinks per line
                for line_num, line in ipairs(vim.split(content, "\n", { plain = true })) do
                    for link_full_content in string.gmatch(line, config.options.patterns.link) do
                        -- link_full_content will be "1on1" or "1on1|alias"
                        local link_target_name = link_full_content:match("^(.-)|.*$") or link_full_content
                        if link_target_name == target_note_name then
                            -- Found a backlink
                            table.insert(backlinks, string.format("%s:%d: %s",
                                vim.fn.fnamemodify(note_file, ":~:."), -- Relative path to file
                                line_num,
                                line:match("^(%s*.-)%s*$") -- Trim leading/trailing whitespace
                            ))
                            break -- Only add once per line if multiple links point to the same target
                        end
                    end
                end
            end
        end
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
local function resolve_note_files(name)
    local pattern = utils.join_path(config.options.home, "**/*." .. config.options.extension)
    local files = vim.fn.glob(pattern, true, true) or {}
    local matches = {}
    for _, f in ipairs(files) do
        if vim.fn.fnamemodify(f, ":t:r") == name then
            table.insert(matches, f)
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

-- Put the cursor on the heading an anchor names, in the buffer just opened.
--
-- Matched on the heading's text rather than a slug, because that is what the
-- link says: `[[note#Results]]` is written by reading the note, not by guessing
-- how its headings would be encoded. Case-insensitive, since a heading is prose
-- and nobody recalls its capitalisation.
--
-- Nothing found is worth saying: the note opened at the top and looks like it
-- worked, so silence here reads as "there is no such section" only to whoever
-- already suspected it.
local function jump_to_anchor(anchor)
    if not anchor or anchor == "" then return end
    local wanted = vim.trim(anchor):lower()
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
-- make it real.
local function open_link_target(raw_target)
    local name, anchor = utils.split_link(raw_target)
    if not name or name == "" then return end

    local matches = resolve_note_files(name)
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

return M
