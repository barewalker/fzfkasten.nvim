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

-- Notes a prompt may open before sending its text, so Claude has that note as
-- its active context. "current" (or nil) opens nothing and sends from wherever
-- you are. weekly/daily reuse core.open_note, which creates the note from its
-- template when it doesn't exist yet.
local VALID_NOTES = { weekly = true, daily = true, current = true }

--- The configured prompt names, sorted -- for command completion. Reads config
--- only, so it works (returning {}) even when Claude integration is disabled.
--- @return string[]
function M.prompt_names()
 local prompts = config.options.claude and config.options.claude.prompts or {}
 local names = vim.tbl_keys(prompts)
 table.sort(names)
 return names
end

-- Resolve `name` against the `prompts` table into a validated entry. Returns
-- (prompt, nil) on success, or (nil, code) where code is one of "empty" (no
-- name given), "unknown", "no-text", "bad-note" -- send_prompt turns each into
-- a message. Pure, so it is unit-tested without claudecode installed.
local function resolve_prompt(prompts, name)
 prompts = prompts or {}
 if not name or vim.trim(name) == "" then
  return nil, "empty"
 end
 local prompt = prompts[name]
 if not prompt then
  return nil, "unknown"
 end
 if type(prompt.text) ~= "string" or vim.trim(prompt.text) == "" then
  return nil, "no-text"
 end
 if prompt.note ~= nil and not VALID_NOTES[prompt.note] then
  return nil, "bad-note"
 end
 return prompt, nil
end

-- A newly created terminal needs a beat before Claude is up to read a paste, so
-- a fresh launch defers the send by this much; an already-running terminal is
-- sent to at once.
local STARTUP_DELAY_MS = 300

--- Send a configured prompt (config.claude.prompts[name]) to the Claude
--- terminal, first opening the prompt's note so Claude has it as context.
--- @param name string|nil
function M.send_prompt(name)
 local claudecode = guard()
 if not claudecode then return end

 local prompts = config.options.claude.prompts or {}
 local prompt, err = resolve_prompt(prompts, name)
 if not prompt then
  local names = M.prompt_names()
  local listed = #names > 0 and (" Configured: " .. table.concat(names, ", ") .. ".")
   or " No prompts are configured (set claude.prompts in setup())."
  if err == "empty" then
   vim.notify("[Fzfkasten] Usage: :FzfKastenClaudePrompt <name>." .. listed,
    vim.log.levels.WARN)
  elseif err == "unknown" then
   vim.notify("[Fzfkasten] No claude.prompts entry named '" .. name .. "'." .. listed,
    vim.log.levels.WARN)
  elseif err == "no-text" then
   vim.notify("[Fzfkasten] Prompt '" .. name .. "' has no `text` to send.",
    vim.log.levels.WARN)
  else -- bad-note
   vim.notify("[Fzfkasten] Prompt '" .. name .. "' has an unknown `note` ("
    .. tostring(prompt and prompt.note) .. "); use weekly, daily or current.",
    vim.log.levels.WARN)
  end
  return
 end

 local tok, terminal = pcall(require, "claudecode.terminal")
 if not tok or not terminal then
  vim.notify("[Fzfkasten] claudecode.terminal module not found.", vim.log.levels.ERROR)
  return
 end

 -- Open the note first, so it is the active buffer Claude reads as context.
 if prompt.note == "weekly" or prompt.note == "daily" then
  require("fzfkasten.core").open_note(prompt.note)
 end

 -- ensure_visible creates the terminal if there isn't one; send_to_terminal
 -- itself never opens one. Remember whether one was already running: only a
 -- fresh launch needs the startup grace before the paste will land.
 local existed = terminal.get_active_terminal_bufnr() ~= nil
 terminal.ensure_visible()

 local submit = prompt.submit ~= false
 local function send()
  local ok = terminal.send_to_terminal(prompt.text, { submit = submit })
  if not ok then
   vim.notify("[Fzfkasten] Could not send prompt '" .. name
    .. "' to the Claude terminal.", vim.log.levels.WARN)
  end
 end
 if existed then
  send()
 else
  vim.defer_fn(send, STARTUP_DELAY_MS)
 end
end

-- Pure helpers exposed for tests (see tests/claude_spec.lua).
M._test = {
 resolve_prompt = resolve_prompt,
 VALID_NOTES = VALID_NOTES,
}

return M
