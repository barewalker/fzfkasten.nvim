local M = {}
local config = require('fzfkasten.config')
local utils = require('fzfkasten.utils')
local pickers = require('fzfkasten.pickers') -- Added for template selection
local buffer = require('fzfkasten.buffer') -- Opens notes and applies per-buffer opt-outs

local function get_external_content(cmd)
    local handle = io.popen(cmd)
    if not handle then return "" end
    local result = handle:read("*a")
    handle:close()
    return result
end

function M.open_note(note_type, time)
    time = time or os.time()
    local opts = config.options.notes[note_type]
    local date_str = os.date(opts.format, time)
    local filename = config.options.transform.new_file_name(date_str) .. "." .. config.options.extension
    local target_dir = utils.join_path(config.options.home, opts.dir)
    local full_path = utils.join_path(target_dir, filename)

    if vim.fn.isdirectory(target_dir) == 0 then
        vim.fn.mkdir(target_dir, "p")
    end

    local is_new = vim.fn.filereadable(full_path) == 0
    buffer.edit(full_path)

    if is_new then
        M.apply_note_template(note_type, date_str, time)
    end
end

function M.apply_note_template(note_type, title, time)
    local opts = config.options.notes[note_type]
    local content = ""
    if opts.template then
        content = M.load_template(opts.template, title, time)
    end
    if opts.use_external_cmd and opts.external_cmd then
        content = content .. "\n## External Data\n" .. get_external_content(opts.external_cmd)
    end
    
    -- Only apply if the buffer is empty
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    if #lines <= 1 and (lines[1] == nil or lines[1] == "") then
        vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.split(content, "\n"))
    end
end

function M.load_template(rel_path, title, time)
    time = time or os.time()
    -- Gracefully handle cases where rel_path might already include "templates/"
    local clean_rel_path = rel_path:gsub("^templates/", "")
    local abs_path = utils.join_path(config.options.home, "templates", clean_rel_path)

    if vim.fn.filereadable(abs_path) == 0 then
        return "# " .. title
    end
    local data = table.concat(vim.fn.readfile(abs_path), "\n")

    local placeholders = {
        title = title,
        date = os.date("%Y-%m-%d", time),
        hdate = os.date(config.options.hdate_format, time),
        year = os.date("%Y", time),
        month = os.date("%m", time),
        day = os.date("%d", time),
        week = os.date("%V", time),
        time = os.date("%H:%M", time),
    }
    for k, v in pairs(config.options.template_placeholders or {}) do
        placeholders[k] = v
    end

    local final_content = data:gsub("{{(.-)}}", function(key)
        local v = placeholders[key]
        if v == nil then
            return nil -- leave "{{key}}" intact for unknown placeholders
        end
        if type(v) == "function" then
            local ok, result = pcall(v, title)
            if not ok then
                vim.notify(
                    string.format("[Fzfkasten] placeholder {{%s}} raised: %s", key, tostring(result)),
                    vim.log.levels.WARN
                )
                return nil
            end
            v = result
        end
        return tostring(v)
    end)

    return final_content
end

function M.create_new_note_interactively()
    local title = vim.fn.input("Note Title: ")
    if not title or title:gsub("%s+", "") == "" then
        vim.notify("Note creation cancelled or empty title provided.", vim.log.levels.INFO)
        return
    end

    pickers.select_template(function(selected_template_name)
        local template_to_use = selected_template_name
        if not template_to_use and config.options.new_note_template then
            template_to_use = config.options.new_note_template
        end

        local sanitized_title = config.options.transform.sanitize_filename(
            config.options.transform.new_file_name(title)
        )
        if sanitized_title == "" then
            vim.notify("Sanitized note title is empty; aborting.", vim.log.levels.ERROR)
            return
        end
        local filename = sanitized_title .. "." .. config.options.extension
        local full_path = utils.join_path(config.options.home, filename)

        buffer.edit(full_path)

        local current_buf = vim.api.nvim_get_current_buf()

        local content = ""
        if template_to_use then
            content = M.load_template(template_to_use, title)
        else
            content = "# " .. title -- Fallback if no template is selected/configured
        end

        vim.api.nvim_buf_set_lines(current_buf, 0, -1, false, {})
        vim.api.nvim_buf_set_lines(current_buf, 0, 0, false, vim.split(content, "\n"))
        -- filetype is set centrally in buffer.edit (called above).
    end)
end

-- Split the inside of a wikilink into its parts: `[[name#anchor|alias]]`, of
-- which the last two are optional.
--
-- `|` is taken first, so an alias may itself contain a `#` ("[[note|see #3]]");
-- the anchor is then whatever follows the first `#` of what is left, so a
-- heading containing one ("[[note#Q#A]]") survives the round trip.
-- @return string name, string|nil anchor, string|nil alias
local function split_link(content)
    local body, alias = content:match("^(.-)|(.*)$")
    if not body then
        body = content
    end
    local name, anchor = body:match("^(.-)#(.*)$")
    if not name then
        name = body
    end
    return name, anchor, alias
end

-- Point a wikilink at `new_name`, or nil when it points somewhere else and
-- should be left exactly as it is.
--
-- The anchor and the alias are carried across untouched: renaming a note moves
-- neither the heading inside it nor the words you chose to call it by. Only
-- whole names match, so `[[old-notes]]` is not a link to `old`, and `[[#top]]`
-- -- an anchor within the same note, with no name at all -- is nobody's link.
local function retarget(content, old_name, new_name)
    local name, anchor, alias = split_link(content)
    if name ~= old_name then
        return nil
    end
    return "[[" .. new_name
        .. (anchor and ("#" .. anchor) or "")
        .. (alias and ("|" .. alias) or "")
        .. "]]"
end

-- What a note currently says, and where saying it back has to go.
--
-- A loaded buffer with unsaved changes is the note; the file is behind it.
-- Reading the file and writing it back would rewrite text the buffer does not
-- have, and the next `:w` would overwrite the link update with the buffer's
-- own -- silently leaving that one note pointing at a name that no longer
-- exists. So a dirty buffer is read and written in place, and its `:w` carries
-- both its edits and ours.
-- @return string[] lines, integer|nil bufnr to write back to instead of the file
local function note_source(note_file)
    local bufnr = vim.fn.bufnr(note_file)
    if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].modified then
        return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), bufnr
    end
    local ok, lines = pcall(vim.fn.readfile, note_file)
    return ok and lines or {}, nil
end

local function write_note(note_file, lines, bufnr)
    if bufnr then
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
        return
    end
    vim.fn.writefile(lines, note_file)
    -- A clean buffer on the same file is now behind; bring it up to date.
    local loaded = vim.fn.bufnr(note_file)
    if loaded ~= -1 and vim.api.nvim_buf_is_loaded(loaded) then
        vim.schedule(function()
            pcall(vim.cmd, "checktime " .. loaded)
        end)
    end
end

function M.rename_note(old_path, new_name_raw)
    local old_name = vim.fn.fnamemodify(old_path, ":t:r")
    local extension = vim.fn.fnamemodify(old_path, ":e")
    local new_name = config.options.transform.sanitize_filename(
        config.options.transform.new_file_name(new_name_raw)
    )
    if new_name == "" then
        vim.notify("Sanitized new name is empty; aborting rename.", vim.log.levels.ERROR)
        return
    end
    local new_filename = new_name .. "." .. extension
    local old_dir = vim.fn.fnamemodify(old_path, ":h")
    local new_path = utils.join_path(old_dir, new_filename)

    if vim.fn.filereadable(new_path) == 1 then
        vim.notify("Error: Destination file already exists: " .. new_path, vim.log.levels.ERROR)
        return
    end

    -- 1. Move the file, before touching anything else.
    --
    -- The order is the whole safety of this operation. Rewriting the links
    -- first and then failing to move would point every one of them at a name
    -- that does not exist -- the collection broken by a rename that never
    -- happened, and nothing to undo it with. Moving first means a failure here
    -- changes nothing at all.
    local success, err = os.rename(old_path, new_path)
    if not success then
        vim.notify("Error renaming file: " .. tostring(err), vim.log.levels.ERROR)
        return
    end

    -- 2. Point the links at the new name. Globbed after the move, so the note
    -- itself is found at its new path and its own links are updated too.
    local all_notes_pattern = utils.join_path(config.options.home, "**/*." .. config.options.extension)
    local all_notes = vim.fn.glob(all_notes_pattern, true, true)
    local updated = 0

    for _, note_file in ipairs(all_notes) do
        local lines, bufnr = note_source(note_file)
        local changed = false
        local new_lines = {}

        for _, line in ipairs(lines) do
            -- `[[name]]`, `[[name#anchor]]`, `[[name|alias]]`, or all three.
            local updated_line = line:gsub("%[%[(.-)%]%]", function(link_content)
                local retargeted = retarget(link_content, old_name, new_name)
                if retargeted then
                    changed = true
                end
                return retargeted -- nil leaves the link exactly as it was
            end)
            table.insert(new_lines, updated_line)
        end

        if changed then
            write_note(note_file, new_lines, bufnr)
            updated = updated + 1
        end
    end

    -- 3. Update buffers
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_get_name(buf) == old_path then
            vim.api.nvim_buf_delete(buf, { force = true })
        end
    end
    buffer.edit(new_path)

    -- Say how many notes were touched: this rewrote files you did not have
    -- open, and "updated links" alone gives you no idea how much happened.
    vim.notify(string.format("Renamed '%s' to '%s'; %d note%s updated.",
        old_name, new_name, updated, updated == 1 and "" or "s"), vim.log.levels.INFO)
end

-- Pure helpers, exposed for tests (tests/rename_spec.lua). The link surgery
-- runs over every note in the collection, so its edge cases are pinned here
-- rather than only through a rename that writes hundreds of files.
M._test = {
    split_link = split_link,
    retarget = retarget,
}

function M.rename_note_interactively(filepath)
    local current_path = filepath or vim.api.nvim_buf_get_name(0)
    if current_path == "" or vim.fn.filereadable(current_path) == 0 then
        vim.notify("Invalid file for renaming.", vim.log.levels.ERROR)
        return
    end

    local old_name = vim.fn.fnamemodify(current_path, ":t:r")
    local new_name = vim.fn.input("Rename '" .. old_name .. "' to: ", old_name)
    
    if new_name == "" or new_name == old_name then
        vim.notify("Rename cancelled or name unchanged.", vim.log.levels.INFO)
        return
    end

    M.rename_note(current_path, new_name)
end

return M
