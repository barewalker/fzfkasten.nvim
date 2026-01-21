local M = {}
local config = require('fzfkasten.config')
local utils = require('fzfkasten.utils')
local pickers = require('fzfkasten.pickers') -- Added for template selection

local function get_external_content(cmd)
    local handle = io.popen(cmd)
    if not handle then return "" end
    local result = handle:read("*a")
    handle:close()
    return result
end

function M.open_note(note_type)
    local opts = config.options.notes[note_type]
    local date_str = os.date(opts.format)
    local filename = config.options.transform.new_file_name(date_str) .. "." .. config.options.extension
    local target_dir = utils.join_path(config.options.home, opts.dir)
    local full_path = utils.join_path(target_dir, filename)

    if vim.fn.isdirectory(target_dir) == 0 then
        vim.fn.mkdir(target_dir, "p")
    end

    local is_new = vim.fn.filereadable(full_path) == 0
    vim.cmd("edit " .. vim.fn.fnameescape(full_path))

    if is_new then
        M.apply_note_template(note_type, date_str)
    end
end

function M.apply_note_template(note_type, title)
    local opts = config.options.notes[note_type]
    local content = ""
    if opts.template then
        content = M.load_template(opts.template, title)
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

function M.load_template(rel_path, title)
    -- Gracefully handle cases where rel_path might already include "templates/"
    local clean_rel_path = rel_path:gsub("^templates/", "")
    local abs_path = utils.join_path(config.options.home, "templates", clean_rel_path)
    
    if vim.fn.filereadable(abs_path) == 0 then
        return "# " .. title
    end
    local data = table.concat(vim.fn.readfile(abs_path), "\n")
    local final_content = data:gsub("{{title}}", title):gsub("{{date}}", os.date("%Y-%m-%d")):gsub("{{hdate}}", os.date(config.options.hdate_format))
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

        local sanitized_title = config.options.transform.new_file_name(title):gsub("[^%w%s_%.%-]+", "") -- Sanitization allowing spaces
        local filename = sanitized_title .. "." .. config.options.extension
        local full_path = utils.join_path(config.options.home, filename)

        vim.cmd("edit " .. vim.fn.fnameescape(full_path))

        local current_buf = vim.api.nvim_get_current_buf()

        local content = ""
        if template_to_use then
            content = M.load_template(template_to_use, title)
        else
            content = "# " .. title -- Fallback if no template is selected/configured
        end

        vim.api.nvim_buf_set_lines(current_buf, 0, -1, false, {})
        vim.api.nvim_buf_set_lines(current_buf, 0, 0, false, vim.split(content, "\n"))
    end)
end

function M.rename_note(old_path, new_name_raw)
    local old_name = vim.fn.fnamemodify(old_path, ":t:r")
    local extension = vim.fn.fnamemodify(old_path, ":e")
    local new_name = config.options.transform.new_file_name(new_name_raw):gsub("[^%w%s_%.%-]+", "")
    local new_filename = new_name .. "." .. extension
    local old_dir = vim.fn.fnamemodify(old_path, ":h")
    local new_path = utils.join_path(old_dir, new_filename)

    if vim.fn.filereadable(new_path) == 1 then
        vim.notify("Error: Destination file already exists: " .. new_path, vim.log.levels.ERROR)
        return
    end

    -- 1. Find all notes and update links
    local all_notes_pattern = utils.join_path(config.options.home, "**/*." .. config.options.extension)
    local all_notes = vim.fn.glob(all_notes_pattern, true, true)
    
    for _, note_file in ipairs(all_notes) do
        local lines = vim.fn.readfile(note_file)
        local changed = false
        local new_lines = {}
        
        for _, line in ipairs(lines) do
            -- Pattern to match [[old_name]] or [[old_name|alias]]
            local updated_line = line:gsub("%[%[(.-)%]%]", function(link_content)
                local target = link_content:match("^(.-)|") or link_content
                if target == old_name then
                    local alias = link_content:match("|(.*)$")
                    changed = true
                    if alias then
                        return "[[" .. new_name .. "|" .. alias .. "]]"
                    else
                        return "[[" .. new_name .. "]]"
                    end
                end
                return nil -- No change
            end)
            table.insert(new_lines, updated_line)
        end
        
        if changed then
            vim.fn.writefile(new_lines, note_file)
        end
    end

    -- 2. Rename the file
    local success, err = os.rename(old_path, new_path)
    if not success then
        vim.notify("Error renaming file: " .. tostring(err), vim.log.levels.ERROR)
        return
    end

    -- 3. Update buffers
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_get_name(buf) == old_path then
            vim.api.nvim_buf_delete(buf, { force = true })
        end
    end
    vim.cmd("edit " .. vim.fn.fnameescape(new_path))

    vim.notify("Renamed '" .. old_name .. "' to '" .. new_name .. "' and updated links.", vim.log.levels.INFO)
end

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
