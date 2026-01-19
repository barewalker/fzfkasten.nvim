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
    vim.cmd("edit " .. full_path)

    if is_new then
        local content = ""
        if opts.template then
            content = M.load_template(opts.template, date_str)
        end
        if opts.use_external_cmd and opts.external_cmd then
            content = content .. "\n## External Data\n" .. get_external_content(opts.external_cmd)
        end
        vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.split(content, "\n"))
    end
end

function M.load_template(rel_path, title)
    local abs_path = utils.join_path(config.options.home, "templates", rel_path)
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

        local sanitized_title = config.options.transform.new_file_name(title):gsub("%s", "_"):gsub("[^%w_%.%-]+", "") -- Basic sanitization
        local filename = sanitized_title .. "." .. config.options.extension
        local full_path = utils.join_path(config.options.home, filename)

        vim.cmd("edit " .. full_path)

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

return M
