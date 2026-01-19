local M = {}
local config = require('fzfkasten.config')

function M.join_path(...)
    return (table.concat({...}, "/"):gsub("//+", "/"))
end

function M.get_template_path(template_name)
    return M.join_path(config.options.home, "templates", template_name)
end

-- This function is intended to list templates. In a Neovim context, it would use vim.fn.glob.
-- For the purpose of this setup, we'll assume templates are in config.options.home/templates/
function M.list_templates()
    local templates_dir = M.join_path(config.options.home, "templates")
    local template_files = {}
    -- In a real Neovim environment, this would be something like:
    -- for _, fpath in ipairs(vim.fn.glob(templates_dir .. "/*.md", true, true)) do
    --     table.insert(template_files, vim.fn.fnamemodify(fpath, ":t"))
    -- end
    -- For now, we'll return a placeholder, and ensure the fzf-lua picker handles the actual listing.
    return { "default.md" } -- Placeholder, will be replaced by fzf-lua picker
end

return M