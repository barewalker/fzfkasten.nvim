-- Buffer-level tweaks applied to notes opened *through* fzfkasten.
--
-- We don't touch notes you open by other means (e.g. `:edit`, netrw); only
-- buffers that fzfkasten itself opens are marked and (by default) get
-- diagnostics / autoformat turned off, since those tend to be noisy on prose.
local config = require('fzfkasten.config')
local M = {}

local function disable_diagnostics(bufnr)
    -- Signature of vim.diagnostic.enable changed in 0.10: enable(false, filter).
    -- Fall back to the deprecated vim.diagnostic.disable on older versions.
    if vim.fn.has("nvim-0.10") == 1 then
        pcall(vim.diagnostic.enable, false, { bufnr = bufnr })
    else
        pcall(vim.diagnostic.disable, bufnr)
    end
end

-- Mark `bufnr` as an fzfkasten note buffer and apply the configured opt-outs.
-- Always sets `vim.b[bufnr].fzfkasten = true` so user autocmds can detect and
-- skip these buffers regardless of which formatter/diagnostic setup they run.
function M.mark(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    local opts = config.options.note_buffer or {}

    vim.b[bufnr].fzfkasten = true

    if opts.disable_diagnostics ~= false then
        disable_diagnostics(bufnr)
    end

    if opts.disable_format ~= false then
        -- conform.nvim honours these; we also set generic flags that common
        -- "format on save" autocmds tend to check. Users with a bespoke setup
        -- can additionally gate on `vim.b.fzfkasten` (see README).
        vim.b[bufnr].disable_autoformat = true
        vim.b[bufnr].autoformat = false
        vim.b[bufnr].format_on_save = false
    end

    if type(opts.on_open) == "function" then
        pcall(opts.on_open, bufnr)
    end
end

-- Open `path` as a note buffer: `:edit` it, then mark the resulting buffer.
-- This is the single entry point fzfkasten uses to open notes so that every
-- code path gets the same treatment.
function M.edit(path)
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    M.mark(vim.api.nvim_get_current_buf())
end

return M
