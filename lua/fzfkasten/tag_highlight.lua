-- #tags coloured in every note, from the first redraw.
--
-- A markdown language server such as marksman colours tags too, but only once
-- it has read the whole collection: a second or two after a fresh Neovim
-- opens a note, which is every time ttykasten (or a shell alias) opens one.
-- This colours them at once, with the tag pattern the rest of fzfkasten reads
-- tags with, in any buffer whose file is a note under `home`, however it was
-- opened. It sits just below the language server's priority, so where a
-- server colours the same text, the server has the last word.
local config = require('fzfkasten.config')

local M = {}

local ns = vim.api.nvim_create_namespace("fzfkasten-tags")
local PRIORITY = (vim.hl or vim.highlight).priorities.semantic_tokens - 1

-- marksman's tag colour, @lsp.type.enumMember, links to @constant, so linking
-- here too keeps the colour from changing when the server starts. A
-- colorscheme or `vim.api.nvim_set_hl(0, "FzfkastenNoteTag", ...)` restyles it.
local function define_group()
    vim.api.nvim_set_hl(0, "FzfkastenNoteTag", { link = "@constant", default = true })
end

--- Where `pattern` (a Lua pattern, `patterns.tag`) matches in `line`, as
--- 0-based `{ start, end_exclusive }` byte ranges, left to right.
function M.ranges(line, pattern)
    local out, init = {}, 1
    while true do
        local s, e = line:find(pattern, init)
        if not s then
            return out
        end
        if e >= s then
            out[#out + 1] = { s - 1, e }
        end
        init = math.max(e, s) + 1
    end
end

--- Whether `name`, a buffer's full path, is a note: under `home`, with the
--- notes' extension.
function M.is_note(name, home, extension)
    home = home:gsub("/+$", "")
    local ext = "." .. extension
    return home ~= ""
        and name:sub(1, #home + 1) == home .. "/"
        and name:sub(-#ext) == ext
end

local function note_buffer(buf)
    local o = config.options
    return M.is_note(vim.api.nvim_buf_get_name(buf), o.home or "", o.extension or "md")
end

function M.enable()
    define_group()
    vim.api.nvim_create_autocmd("ColorScheme", {
        group = vim.api.nvim_create_augroup("fzfkasten-tags", { clear = true }),
        callback = define_group,
    })
    vim.api.nvim_set_decoration_provider(ns, {
        on_win = function(_, _, buf)
            return note_buffer(buf)
        end,
        on_line = function(_, _, buf, row)
            local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
            if not line then
                return
            end
            for _, r in ipairs(M.ranges(line, config.options.patterns.tag)) do
                vim.api.nvim_buf_set_extmark(buf, ns, row, r[1], {
                    end_col = r[2],
                    hl_group = "FzfkastenNoteTag",
                    ephemeral = true,
                    priority = PRIORITY,
                })
            end
        end,
    })
end

return M
