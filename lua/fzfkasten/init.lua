local M = {}
function M.setup(opts) require('fzfkasten.config').setup(opts) end
M.goto_daily = function() require('fzfkasten.core').open_note("daily") end
M.goto_weekly = function() require('fzfkasten.core').open_note("weekly") end
M.find_notes = function() require('fzfkasten.pickers').find_notes() end
M.search_tags = function() require('fzfkasten.pickers').search_tags() end
M.search_by_tag = function() require('fzfkasten.pickers').search_by_tag() end
M.insert_link = function() require('fzfkasten.pickers').insert_link() end
M.search_content = function() require('fzfkasten.pickers').search_content() end
M.new_note = function() require('fzfkasten.core').create_new_note_interactively() end
M.panel = function() require('fzfkasten.pickers').panel() end
M.follow_link = function() require('fzfkasten.pickers').follow_link() end
M.goto_link = function() require('fzfkasten.pickers').goto_link() end
-- Mints the id on the line under the cursor, so it writes to the buffer -- the
-- one entry point here that does.
M.yank_link = function() require('fzfkasten.pickers').yank_block_link() end
M.show_backlinks = function() require('fzfkasten.pickers').show_backlinks(vim.api.nvim_buf_get_name(0)) end
M.rename_note = function() require('fzfkasten.core').rename_note_interactively() end
M.link_tree = function(depth)
    require('fzfkasten.graph').link_tree(vim.api.nvim_buf_get_name(0), depth)
end
M.orphans = function() require('fzfkasten.graph').orphans_picker() end
M.dead_links = function() require('fzfkasten.graph').dead_links_picker() end
M.hubs = function() require('fzfkasten.graph').hubs_picker() end
M.link_graph = function() return require('fzfkasten.graph').build() end
M.find_daily_notes = function() require('fzfkasten.pickers').find_daily_notes_picker() end
M.log = function() require('fzfkasten.pickers').log() end
-- Kept as an alias: the date picker grew to cover weeks and previews and became
-- the log picker, but the old command name still works.
M.pick_daily_date = function() require('fzfkasten.pickers').log() end
M.find_weekly_notes = function() require('fzfkasten.pickers').find_weekly_notes_picker() end
M.tasks = function() require('fzfkasten.tasks').pick() end
M.task_toggle = function() require('fzfkasten.tasks').toggle() end
-- With text, capture it. Without, prompt: bound to a key, one press then type
-- is the whole capture, no note to open and nothing to aim at.
M.task_add = function(text)
    if text and vim.trim(text) ~= "" then
        return require('fzfkasten.tasks').add(text)
    end
    vim.ui.input({ prompt = "New task: " }, function(input)
        if input and vim.trim(input) ~= "" then
            require('fzfkasten.tasks').add(input)
        end
    end)
end
M.task_inbox = function() require('fzfkasten.tasks').inbox() end
M.task_tag = function(opts) require('fzfkasten.tasks').tag(opts) end
M.task_cancel = function() require('fzfkasten.tasks').cancel() end
-- The list buffer answers for its own rows: there the task is a row, not the
-- line the cursor is on, and the buffer is a view that cannot be written into.
-- Asking here rather than in `tasks` keeps the writers unaware of the views.
M.task_due = function(date)
    local list = require('fzfkasten.tasklist')
    if list.is_current() then
        return list.set_due(date)
    end
    require('fzfkasten.tasks').set_due(date)
end
M.task_undo = function() return require('fzfkasten.tasks').undo() end
M.task_list = function() require('fzfkasten.tasklist').open() end
M.task_list_inbox = function() require('fzfkasten.tasklist').inbox() end
M.collect_tasks = function(opts) return require('fzfkasten.tasks').collect(opts) end
M.claude_send_buffer = function() require('fzfkasten.claude').send_current_buffer() end
M.claude_send_selection = function() require('fzfkasten.claude').send_selection() end
M.claude_pane = function() require('fzfkasten.claude').choose_pane() end
M.claude_prompt = function(name) require('fzfkasten.claude').send_prompt(name) end
M.claude_prompt_names = function() return require('fzfkasten.claude').prompt_names() end
return M