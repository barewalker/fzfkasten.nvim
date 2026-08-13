local M = {}
local config = require("fzfkasten.config")

-- Claude Code runs in a pane of a terminal multiplexer, not inside the editor,
-- so reaching it is keystroke injection rather than an editor protocol: write
-- the text, then send the Return that submits it. That, plus a way to list
-- panes so one can be pointed at, is all a multiplexer has to provide -- which
-- is why herdr and tmux fit the same shape here.
local MUX = {}

-- Text arrives as a paste, not as typing: wrapped in the brackets a terminal
-- puts around pasted content (bracketed paste, DEC mode 2004). That is what it
-- is -- content from somewhere else, not keys someone pressed -- and saying so
-- is what makes it arrive intact. A prompt with newlines in it would otherwise
-- be submitted a line at a time, the first line running as its own message; and
-- anything that reads keystrokes on the way in, an input method or a key
-- handler of its own, would otherwise interpret the characters rather than take
-- them literally. Pasted content is passed through untouched by convention,
-- which is why tmux offers `paste-buffer -p` for the same reason. The Return
-- that submits goes as a keystroke, outside the brackets, or it would be text.
local PASTE_START, PASTE_END = "\27[200~", "\27[201~"

local function as_paste(text, wrap)
 if wrap == false then return text end
 return PASTE_START .. text .. PASTE_END
end

MUX.herdr = {
 default_cmd = "herdr",
 send_text = function(cmd, target, text) return { cmd, "pane", "send-text", target, text } end,
 send_enter = function(cmd, target) return { cmd, "pane", "send-keys", target, "Enter" } end,
 list = function(cmd) return { cmd, "pane", "list" } end,
 -- `pane list` answers one JSON object. A pane running an agent carries
 -- agent_session.agent, which is how the Claude panes are told from shells.
 parse = function(out)
  local ok, answer = pcall(vim.json.decode, out)
  if not ok or type(answer) ~= "table" then return {} end
  local panes = type(answer.result) == "table" and answer.result.panes or nil
  if type(panes) ~= "table" then return {} end
  local found = {}
  for _, p in ipairs(panes) do
   if type(p) == "table" and p.pane_id then
    local agent = type(p.agent_session) == "table" and p.agent_session.agent or nil
    found[#found + 1] = {
     target = p.pane_id,
     agent = agent,
     label = string.format("%-8s %-8s %s", p.pane_id, agent or "shell",
      p.terminal_title_stripped or p.cwd or ""),
    }
   end
  end
  return found
 end,
}

MUX.tmux = {
 default_cmd = "tmux",
 -- -l writes the string literally instead of reading it as key names, and `--`
 -- keeps a prompt that starts with a dash from being taken for an option.
 send_text = function(cmd, target, text) return { cmd, "send-keys", "-t", target, "-l", "--", text } end,
 send_enter = function(cmd, target) return { cmd, "send-keys", "-t", target, "Enter" } end,
 list = function(cmd)
  return { cmd, "list-panes", "-a", "-F",
   "#{pane_id}\t#{session_name}:#{window_index}.#{pane_index}\t#{pane_current_command}\t#{pane_title}" }
 end,
 parse = function(out)
  local found = {}
  for _, line in ipairs(vim.split(out or "", "\n", { trimempty = true })) do
   local id, where, command, title = line:match("^([^\t]+)\t([^\t]*)\t([^\t]*)\t(.*)$")
   if id then
    found[#found + 1] = {
     target = id,
     -- tmux knows the running process, not the agent, so this is "claude"
     -- when Claude was started by that name and "node" when it wasn't.
     agent = command ~= "" and command or nil,
     label = string.format("%-6s %-20s %-10s %s", id, where, command, title),
    }
   end
  end
  return found
 end,
}

--- The multiplexers this knows how to reach a pane through, sorted.
--- @return string[]
function M.backends()
 local names = vim.tbl_keys(MUX)
 table.sort(names)
 return names
end

-- The `claude.pane` options, with the multiplexer they name resolved. Returns
-- (pane, mux, cmd), or (pane, nil) when `via` is not a multiplexer we know.
local function backend()
 local claude = config.options.claude or {}
 local pane = claude.pane or {}
 local mux = MUX[pane.via or "herdr"]
 if not mux then return pane, nil end
 return pane, mux, pane.cmd or mux.default_cmd
end

-- With `host` set the pane is on another machine, so the multiplexer's CLI has
-- to run there. ssh joins its arguments into one string for the remote shell,
-- so every one of them has to survive that shell -- hence the escaping.
local function over_ssh(host, argv)
 if not host or host == "" then return argv end
 local quoted = {}
 for i, a in ipairs(argv) do quoted[i] = vim.fn.shellescape(a) end
 return { "ssh", host, table.concat(quoted, " ") }
end

-- Claude Code attaches a file named as `@<path>`, but its parser ends the path
-- at the first space -- and note titles have spaces in them. Quote those
-- instead: Claude reads a quoted absolute path just as readily, it only misses
-- the up-front attachment.
local function mention(path)
 if path:find("%s") then return '"' .. path .. '"' end
 return "@" .. path
end

-- The pane on another machine holds its own copy of the collection, which may
-- sit at another path. Both sides are the same clone, so only the prefix
-- differs. Returns nil for a file outside the collection: there is no way to
-- point at that one from over there.
local function map_path(path, home, root)
 if not root or root == "" or root == home then return path end
 if path == home then return root end
 if path:sub(1, #home + 1) ~= home .. "/" then return nil end
 return root .. path:sub(#home + 1)
end

local function warn(msg) vim.notify("[Fzfkasten] " .. msg, vim.log.levels.WARN) end
local function fail(msg) vim.notify("[Fzfkasten] " .. msg, vim.log.levels.ERROR) end

-- Guard: the integration has to be switched on before anything is sent.
local function enabled()
 local claude = config.options.claude or {}
 if not claude.enabled then
  warn("Claude integration is disabled. Set claude.enabled = true in setup().")
  return false
 end
 return true
end

-- What a command said when it went wrong, whichever stream it said it on.
local function said(res)
 local out = vim.trim((res.stderr or "") ~= "" and res.stderr or (res.stdout or ""))
 return out ~= "" and out or ("exit " .. tostring(res.code))
end

-- Run argv and hand the result back on the main loop. vim.system throws when
-- the program isn't installed at all, which is an ordinary outcome here (no
-- herdr on the machine, no ssh) and is reported like any other failure.
local function run(argv, on_done)
 local ok, err = pcall(vim.system, argv, { text = true }, vim.schedule_wrap(on_done))
 if not ok then
  on_done({ code = 127, stdout = "", stderr = tostring(err) })
 end
end

-- The pane picked this session when none is configured. Remembered so a send is
-- one step after the first one, and forgotten when nvim is.
local chosen = nil

-- A pane list is mostly shells. herdr labels an agent pane with the agent's
-- name and tmux reports the running command, so "claude" narrows both -- but
-- fall back to the whole list rather than to nothing, since a Claude that
-- neither can see is still a pane you may want to send to.
local function claude_first(panes)
 local claude = vim.tbl_filter(function(p) return p.agent == "claude" end, panes)
 return #claude > 0 and claude or panes
end

-- Resolve the pane to send to and hand it to `cb`, asking the multiplexer for
-- its panes when there is nothing configured or remembered. `cb` is not called
-- if there is no pane to be had, or the user picks nothing.
local function with_target(cb)
 local pane, mux, cmd = backend()
 if not mux then
  fail("claude.pane.via is '" .. tostring(pane.via) .. "'; use "
   .. table.concat(M.backends(), " or ") .. ".")
  return
 end
 if pane.target and pane.target ~= "" then return cb(pane.target) end
 if chosen then return cb(chosen) end

 run(over_ssh(pane.host, mux.list(cmd)), function(res)
  if res.code ~= 0 then
   fail("Could not list " .. (pane.via or "herdr") .. " panes: " .. said(res))
   return
  end
  local panes = claude_first(mux.parse(res.stdout or ""))
  if #panes == 0 then
   warn("No " .. (pane.via or "herdr") .. " panes to send to.")
   return
  end
  vim.ui.select(panes, {
   prompt = "Claude pane" .. (pane.host and pane.host ~= "" and (" on " .. pane.host) or "") .. ":",
   format_item = function(p) return p.label end,
  }, function(picked)
   if not picked then return end
   chosen = picked.target
   cb(picked.target)
  end)
 end)
end

--- Pick the pane to send to, in place of the one picked earlier this session.
function M.choose_pane()
 if not enabled() then return end
 local pane = backend()
 if pane.target and pane.target ~= "" then
  warn("claude.pane.target is '" .. pane.target .. "' in setup(), so there is nothing to pick.")
  return
 end
 chosen = nil
 with_target(function(target)
  vim.notify("[Fzfkasten] Prompts and notes now go to pane " .. target .. ".", vim.log.levels.INFO)
 end)
end

-- Write the text into the pane, then submit it if asked. The Return is a
-- separate command in both multiplexers, and only worth sending if the text
-- landed.
local function send_text(text, submit, cb)
 with_target(function(target)
  local pane, mux, cmd = backend()
  run(over_ssh(pane.host, mux.send_text(cmd, target, as_paste(text, pane.paste))), function(res)
   if res.code ~= 0 then
    fail("Could not send to pane " .. target .. ": " .. said(res))
    return
   end
   if not submit then
    if cb then cb() end
    return
   end
   run(over_ssh(pane.host, mux.send_enter(cmd, target)), function(res2)
    if res2.code ~= 0 then
     fail("Sent the text but not the Return: " .. said(res2))
     return
    end
    if cb then cb() end
   end)
  end)
 end)
end

-- Git, run in the collection and answered on the spot: these are local reads of
-- a warm repository, and what they say decides whether the send happens at all.
local function git(dir, args)
 local argv = { "git", "-C", dir }
 vim.list_extend(argv, args)
 local ok, res = pcall(function() return vim.system(argv, { text = true }):wait(5000) end)
 if not ok or type(res) ~= "table" then return nil end
 return res
end

-- What the pane on the other machine would read if the send happened now:
--   "clean"    -- pushed, so its copy holds this very version
--   "dirty"    -- edited and not committed, so its copy cannot catch up at all
--   "unpushed" -- committed but not pushed, so its copy is behind
--   "unknown"  -- not a git work tree, or no upstream: nothing can be said
local function sync_state(dir, path)
 local status = git(dir, { "status", "--porcelain", "--", path })
 if not status or status.code ~= 0 then return "unknown" end
 if vim.trim(status.stdout or "") ~= "" then return "dirty" end
 local ahead = git(dir, { "rev-list", "--count", "@{u}..HEAD" })
 if not ahead or ahead.code ~= 0 then return "unknown" end
 return tonumber(vim.trim(ahead.stdout or "")) ~= 0 and "unpushed" or "clean"
end

-- Push here, bring the other machine up to date, then carry on. --ff-only so a
-- collection that has moved on over there is left alone and said so, rather
-- than merged from under its owner.
local function push_then(cb)
 local pane = backend()
 local home = config.options.home
 local root = (pane.root and pane.root ~= "" and pane.root) or home
 run({ "git", "-C", home, "push" }, function(res)
  if res.code ~= 0 then
   fail("git push failed, so nothing was sent: " .. said(res))
   return
  end
  run(over_ssh(pane.host, { "git", "-C", root, "pull", "--ff-only" }), function(res2)
   if res2.code ~= 0 then
    fail("Pushed, but " .. pane.host .. " could not pull, so nothing was sent: " .. said(res2))
    return
   end
   cb()
  end)
 end)
end

-- Ask before sending a note the other machine cannot see yet. Pushing is
-- offered; committing is not. What to commit, and under what message, is not a
-- decision to take on someone's collection from a send keybinding.
local function with_fresh_copy(path, cb)
 local pane = backend()
 if not path or not pane.host or pane.host == "" then return cb() end

 local state = sync_state(config.options.home, path)
 if state == "clean" or state == "unknown" then return cb() end

 if state == "dirty" then
  vim.ui.select({ "Send anyway -- it reads the last committed version", "Cancel" }, {
   prompt = "Uncommitted changes: " .. pane.host .. " cannot see them.",
  }, function(_, idx)
   if idx == 1 then cb() end
  end)
  return
 end

 vim.ui.select({ "Push, pull there, then send", "Send anyway -- it reads an older version", "Cancel" }, {
  prompt = "Committed but not pushed: " .. pane.host .. " has an older copy.",
 }, function(_, idx)
  if idx == 1 then push_then(cb)
  elseif idx == 2 then cb() end
 end)
end

-- The path of the file to talk about, as the pane would have to name it.
-- Returns (path, nil) or (nil, message).
local function pane_path(bufnr)
 local name = vim.api.nvim_buf_get_name(bufnr)
 if name == "" then
  return nil, "Buffer has no file name. Save the file first."
 end
 if vim.fn.filereadable(name) == 0 then
  return nil, "'" .. name .. "' has never been written. The pane reads the file, so save it first."
 end
 local pane = backend()
 local mapped = map_path(name, config.options.home, pane.root)
 if not mapped then
  return nil, "This file is outside " .. config.options.home
   .. ", so " .. tostring(pane.host) .. " has no copy of it."
 end
 return mapped
end

-- What a buffer nvim made and never wrote -- the task list, a preview -- looks
-- like on the screen. Its lines, plus the virtual text hung off them: the task
-- list keeps each task's note and line there, which is on the screen but not in
-- the lines, and without it a list of tasks says nothing about where they came
-- from. Only what is rendered, in the order it is rendered.
local function view_lines(bufnr, first, last)
 local from = (first or 1) - 1
 local lines = vim.api.nvim_buf_get_lines(bufnr, from, last or -1, false)
 local to = from + #lines - 1
 if #lines == 0 then return lines end

 local trailing = {}
 local marks = vim.api.nvim_buf_get_extmarks(bufnr, -1, { from, 0 }, { to, -1 }, { details = true })
 for _, mark in ipairs(marks) do
  local row, details = mark[2], mark[4]
  if details and details.virt_text then
   local parts = {}
   for _, chunk in ipairs(details.virt_text) do parts[#parts + 1] = chunk[1] end
   trailing[row] = (trailing[row] or "") .. table.concat(parts)
  end
 end
 for i, line in ipairs(lines) do
  local extra = vim.trim(trailing[from + i - 1] or "")
  if extra ~= "" then lines[i] = vim.trim(line) ~= "" and (line .. "  " .. extra) or extra end
 end
 return lines
end

-- What goes in front of the request: the note's path when there is a file for
-- the pane to read, and the view itself when there is not. Returns
-- ({ text = string, path = string|nil }, nil) or (nil, message) -- `path` is the
-- file here that the text names, when it names one, for the freshness check.
local function reference(bufnr, first, last)
 bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr

 -- A buffer with no file behind it cannot be named -- its name means nothing
 -- outside nvim -- so what you are looking at is sent instead. Pasted rather
 -- than pointed at, so it is whole, but a copy: Claude reads it, and cannot
 -- write back to something that was never a file.
 if vim.bo[bufnr].buftype ~= "" then
  local pane = backend()
  local max = pane.max_lines or 500
  local lines = view_lines(bufnr, first, last)
  if #lines == 0 then
   return nil, "There is nothing in this buffer to send."
  end
  if #lines > max then
   return nil, ("This buffer is %d lines, more than claude.pane.max_lines (%d)."):format(#lines, max)
    .. " Send a selection of it, or raise the limit."
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  local title = name ~= "" and name or ("buffer " .. bufnr)
  if first and last then title = ("%s (lines %d-%d)"):format(title, first, last) end
  return { text = title .. ":\n" .. table.concat(lines, "\n") .. "\n" }
 end

 local path, err = pane_path(bufnr)
 if not path then return nil, err end
 local named = first and last and ("%s (lines %d-%d) "):format(mention(path), first, last)
  or (mention(path) .. " ")
 return { text = named, path = vim.api.nvim_buf_get_name(bufnr) }
end

--- Whether a pane can be sent to: the integration is on and the multiplexer's
--- CLI is installed (which can only be checked for a pane on this machine).
--- @return boolean
function M.is_available()
 local claude = config.options.claude or {}
 if not claude.enabled then return false end
 local pane, _, cmd = backend()
 if not cmd then return false end
 if pane.host and pane.host ~= "" then return vim.fn.executable("ssh") == 1 end
 return vim.fn.executable(cmd) == 1
end

--- Put the current buffer to the Claude pane -- its path when it is a file, the
--- view itself when it is not -- without submitting, so the request can be
--- typed after it.
function M.send_current_buffer()
 if not enabled() then return end
 local ref, err = reference(0)
 if not ref then return warn(err) end
 with_fresh_copy(ref.path, function()
  send_text(ref.text, false)
 end)
end

--- The same for the selected line range: the file's path and the range when it
--- is a file, those lines themselves when it is not.
function M.send_selection()
 if not enabled() then return end
 local first, last = vim.fn.line("'<"), vim.fn.line("'>")
 local ref, err = reference(0, first, last)
 if not ref then return warn(err) end
 with_fresh_copy(ref.path, function()
  send_text(ref.text, false)
 end)
end

-- Notes a prompt may open before sending its text, so the note it is about goes
-- with it. "weekly"/"daily" reuse core.open_note, which creates the note from
-- its template when it doesn't exist yet; "current" names the note you are in;
-- omitting it sends the text alone, naming no note at all.
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
-- a message. Pure, so it is unit-tested without a multiplexer to send to.
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

--- Send a configured prompt (config.claude.prompts[name]) to the Claude pane,
--- naming the prompt's note in the text so Claude reads it as context.
--- @param name string|nil
function M.send_prompt(name)
 if not enabled() then return end

 local prompts = config.options.claude.prompts or {}
 local prompt, err = resolve_prompt(prompts, name)
 if not prompt then
  local names = M.prompt_names()
  local listed = #names > 0 and (" Configured: " .. table.concat(names, ", ") .. ".")
   or " No prompts are configured (set claude.prompts in setup())."
  if err == "empty" then
   warn("Usage: :FzfKastenClaudePrompt <name>." .. listed)
  elseif err == "unknown" then
   warn("No claude.prompts entry named '" .. name .. "'." .. listed)
  elseif err == "no-text" then
   warn("Prompt '" .. name .. "' has no `text` to send.")
  else -- bad-note
   warn("Prompt '" .. name .. "' has an unknown `note` ("
    .. tostring(prompt and prompt.note) .. "); use weekly, daily or current.")
  end
  return
 end

 -- Open the note first. The pane cannot see the editor, so opening it is not
 -- what makes it context -- what goes in the text is. It is still worth doing:
 -- it is the note about to be discussed, and opening a weekly or daily note is
 -- also what creates it from its template when the period is new.
 local ref
 if prompt.note == "weekly" or prompt.note == "daily" then
  require("fzfkasten.core").open_note(prompt.note)
 end
 if prompt.note then
  local err2
  ref, err2 = reference(0)
  if not ref then return warn(err2) end
 end

 local text = ref and (ref.text .. prompt.text) or prompt.text
 local submit = prompt.submit ~= false
 with_fresh_copy(ref and ref.path, function()
  send_text(text, submit)
 end)
end

-- Pure helpers exposed for tests (see tests/claude_spec.lua).
M._test = {
 resolve_prompt = resolve_prompt,
 VALID_NOTES = VALID_NOTES,
 MUX = MUX,
 as_paste = as_paste,
 over_ssh = over_ssh,
 reference = reference,
 view_lines = view_lines,
 mention = mention,
 map_path = map_path,
 claude_first = claude_first,
}

return M
