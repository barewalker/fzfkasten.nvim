local M = {}
function M.setup(opts) require('fzfkasten.config').setup(opts) end
M.goto_daily = function() require('fzfkasten.core').open_note("daily") end
M.goto_weekly = function() require('fzfkasten.core').open_note("weekly") end
M.find_notes = function() require('fzfkasten.pickers').find_notes() end
M.search_tags = function() require('fzfkasten.pickers').search_tags() end
M.insert_link = function() require('fzfkasten.pickers').insert_link() end
M.search_content = function() require('fzfkasten.pickers').search_content() end
M.new_note = function() require('fzfkasten.core').create_new_note_interactively() end
M.panel = function() require('fzfkasten.pickers').panel() end
M.follow_link = function() require('fzfkasten.pickers').follow_link() end
M.show_backlinks = function() require('fzfkasten.pickers').show_backlinks() end
M.find_daily_notes = function() require('fzfkasten.pickers').find_daily_notes_picker() end
M.find_weekly_notes = function() require('fzfkasten.pickers').find_weekly_notes_picker() end
return M