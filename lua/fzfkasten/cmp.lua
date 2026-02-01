local M = {}
local config = require("fzfkasten.config")
local utils = require("fzfkasten.utils")

M.new = function(opts)
  local self = setmetatable({}, M)
  self.opts = opts
  return self
end

M.get_trigger_characters = function(self)
  return { self.opts.tag_trigger }
end

M.complete = function(self, params, callback)
  local current_line = vim.api.nvim_buf_get_lines(params.bufnr, params.context.cursor.row, params.context.cursor.row + 1, false)[1]
  local pre_trigger_text = string.sub(current_line, 1, params.context.cursor.col)

  local trigger_char_escaped = vim.fn.escape(self.opts.tag_trigger, '^$.%+-*?[](){}')
  local trigger_pattern = '(^|[^%w])' .. trigger_char_escaped .. '([%w_-]*)$'
  
  -- We match against the text before the cursor to see if we are in a tag context
  local match_start, _, _, typed = string.find(pre_trigger_text, trigger_pattern)

  if not match_start then
    callback({ items = {} })
    return
  end
  
  local home_dir = config.options.home
  local tag_pattern = self.opts.tag_pattern

  -- Simplified rg command: Use -o -r '$1' to print only the first capture group (the tag name).
  local rg_cmd = string.format(
    "rg --no-heading --color never --glob '*.%s' --pregrep '%s' %s",
    config.options.extension,
    tag_pattern,
    home_dir
  )
  
  local all_tags = {}

  vim.fn.jobstart(rg_cmd, {
    on_stdout = vim.schedule_wrap(function(_, data)
        if data then
            for _, captured_tag in ipairs(data) do
                if captured_tag and captured_tag ~= '' then
                    -- Reconstruct the full tag
                    local full_tag = self.opts.tag_trigger .. captured_tag
                    table.insert(all_tags, full_tag)
                end
            end
        end
    end),
    on_stderr = vim.schedule_wrap(function(_, data)
      if data and #data > 0 and data[1] ~= '' then
        vim.notify("[Fzfkasten] rg error: " .. table.concat(data, "\n"), vim.log.levels.ERROR)
      end
    end),
    on_exit = vim.schedule_wrap(function()
      if #all_tags == 0 then
        callback({ items = {} })
        return
      end

      -- Deduplicate and process
      local tags_set = {}
      for _, tag in ipairs(all_tags) do
        tags_set[tag] = true
      end

      local tags_list = {}
      for tag, _ in pairs(tags_set) do
        table.insert(tags_list, tag)
      end
      table.sort(tags_list)

      local completions = {}
      for _, tag in ipairs(tags_list) do
        -- Filter based on what the user has typed after the trigger
        if string.find(tag, '^' .. self.opts.tag_trigger .. (typed or '')) then
            table.insert(completions, {
              label = tag,
              kind = 'Tag',
            })
        end
      end

      callback({ items = completions })
    end),
  })
end

return M
