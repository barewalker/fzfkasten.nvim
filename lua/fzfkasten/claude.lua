local M = {}
local config = require("fzfkasten.config")

--- Safely require claudecode module
--- @return table|nil
local function get_claudecode()
 local ok, mod = pcall(require, "claudecode")
 if ok then return mod end
 return nil
end

--- Check if Claude integration is available and enabled
--- @return boolean
function M.is_available()
 if not config.options.claude or not config.options.claude.enabled then
  return false
 end
 return get_claudecode() ~= nil
end

--- Guard: check enabled + installed, notify user on failure
--- @return table|nil claudecode module or nil
local function guard()
 if not config.options.claude or not config.options.claude.enabled then
  vim.notify("[Fzfkasten] Claude integration is disabled. Set claude.enabled = true in setup().", vim.log.levels.WARN)
  return nil
 end
 local claudecode = get_claudecode()
 if not claudecode then
  vim.notify("[Fzfkasten] claudecode.nvim is not installed.", vim.log.levels.WARN)
  return nil
 end
 return claudecode
end

--- Send the current buffer to Claude as an @mention
function M.send_current_buffer()
 local claudecode = guard()
 if not claudecode then return end

 local bufname = vim.api.nvim_buf_get_name(0)
 if bufname == "" then
  vim.notify("[Fzfkasten] Buffer has no file name. Save the file first.", vim.log.levels.WARN)
  return
 end

 local line_count = vim.api.nvim_buf_line_count(0)
 local ok, err = claudecode.send_at_mention(bufname, 0, line_count - 1, "fzfkasten")
 if not ok then
  vim.notify("[Fzfkasten] Failed to send to Claude: " .. (err or "unknown error"), vim.log.levels.ERROR)
 end
end

--- Send the visual selection to Claude as an @mention
function M.send_selection()
 local claudecode = guard()
 if not claudecode then return end

 local bufname = vim.api.nvim_buf_get_name(0)
 if bufname == "" then
  vim.notify("[Fzfkasten] Buffer has no file name. Save the file first.", vim.log.levels.WARN)
  return
 end

 -- Get visual selection range (1-indexed from Vim, convert to 0-indexed for Claude)
 local start_line = vim.fn.line("'<") - 1
 local end_line = vim.fn.line("'>") - 1

 local ok, err = claudecode.send_at_mention(bufname, start_line, end_line, "fzfkasten")
 if not ok then
  vim.notify("[Fzfkasten] Failed to send to Claude: " .. (err or "unknown error"), vim.log.levels.ERROR)
 end
end

--- Toggle the Claude terminal
function M.toggle_terminal()
 local claudecode = guard()
 if not claudecode then return end

 local tok, terminal = pcall(require, "claudecode.terminal")
 if not tok or not terminal then
  vim.notify("[Fzfkasten] claudecode.terminal module not found.", vim.log.levels.ERROR)
  return
 end

 terminal.focus_toggle()
end

return M
