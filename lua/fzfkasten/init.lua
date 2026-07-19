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
M.show_backlinks = function() require('fzfkasten.pickers').show_backlinks(vim.api.nvim_buf_get_name(0)) end
M.rename_note = function() require('fzfkasten.core').rename_note_interactively() end
M.find_daily_notes = function() require('fzfkasten.pickers').find_daily_notes_picker() end
M.log = function() require('fzfkasten.pickers').log() end
-- Kept as an alias: the date picker grew to cover weeks and previews and became
-- the log picker, but the old command name still works.
M.pick_daily_date = function() require('fzfkasten.pickers').log() end
M.find_weekly_notes = function() require('fzfkasten.pickers').find_weekly_notes_picker() end
M.tasks = function() require('fzfkasten.tasks').pick() end
M.task_toggle = function() require('fzfkasten.tasks').toggle() end
M.task_inbox = function() require('fzfkasten.tasks').inbox() end
M.task_tag = function(opts) require('fzfkasten.tasks').tag(opts) end
M.task_cancel = function() require('fzfkasten.tasks').cancel() end
M.task_due = function(date) require('fzfkasten.tasks').set_due(date) end
M.task_undo = function() return require('fzfkasten.tasks').undo() end
M.collect_tasks = function(opts) return require('fzfkasten.tasks').collect(opts) end
M.claude_send_buffer = function() require('fzfkasten.claude').send_current_buffer() end
M.claude_send_selection = function() require('fzfkasten.claude').send_selection() end
M.claude_toggle = function() require('fzfkasten.claude').toggle_terminal() end
return M