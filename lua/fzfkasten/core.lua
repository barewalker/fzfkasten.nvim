local M = {}
local config = require('fzfkasten.config')
local utils = require('fzfkasten.utils')

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
    local abs_path = utils.join_path(config.options.home, rel_path)
    if vim.fn.filereadable(abs_path) == 0 then
        return "# " .. title
    end
    local data = table.concat(vim.fn.readfile(abs_path), "\n")
    return data:gsub("{{title}}", title):gsub("{{date}}", os.date("%Y-%m-%d")):gsub("{{hdate}}", os.date(config.options.hdate_format))
end

function M.create_new_note_interactively()
    local title = vim.fn.input("Note Title: ")
    if not title or title:gsub("%s+", "") == "" then
        vim.notify("Note creation cancelled or empty title provided.", vim.log.levels.INFO)
        return
    end

    local sanitized_title = title:gsub("%s", "_"):gsub("[^%w_%.%-]+", "") -- Basic sanitization
    local filename = sanitized_title .. "." .. config.options.extension
    local full_path = utils.join_path(config.options.home, filename)

    local target_dir = config.options.home -- For now, new notes go directly into home
    if vim.fn.isdirectory(target_dir) == 0 then
        vim.fn.mkdir(target_dir, "p")
    end

    vim.cmd("edit " .. full_path)

    local content = ""
    if config.options.new_note_template then
        content = M.load_template(config.options.new_note_template, title)
    else
        content = "# " .. title
    end

    vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.split(content, "\n"))
end

return M
