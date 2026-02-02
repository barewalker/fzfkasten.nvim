local fzf = require('fzf-lua')
local config = require('fzfkasten.config')
local utils = require('fzfkasten.utils') -- Added for path joining if needed later
local M = {}

function M.find_notes()
    fzf.files(vim.tbl_deep_extend("force", config.options.fzf.files, {
        cwd = config.options.home,
        prompt = "Notes> ",
        actions = {
            ['default'] = function(selected)
                if not selected or #selected == 0 then return end
                local entry = fzf.path.entry_to_file(selected[1], { cwd = config.options.home })
                vim.cmd("edit " .. vim.fn.fnameescape(entry.path))
            end
        }
    }))
end
function M.search_tags()
    -- Use a regex that strictly matches #tag
    local rg_tag_pattern = "#[a-zA-Z0-9_-]+"

    fzf.grep(vim.tbl_deep_extend("force", config.options.fzf, {
        search = rg_tag_pattern,
        cwd = config.options.home,
        prompt = "Tags> ",
        rg_opts = "--column --line-number --no-heading --color=always --smart-case --only-matching -e",
        no_esc = true,
        actions = {
            ['default'] = function(selected)
                if not selected or #selected == 0 then return end
                local entry = fzf.path.entry_to_file(selected[1], { cwd = config.options.home })
                vim.cmd("edit " .. vim.fn.fnameescape(entry.path))
                if entry.line then
                    vim.api.nvim_win_set_cursor(0, { entry.line, (entry.col or 1) - 1 })
                end
            end
        }
    }))
end

function M.search_by_tag()
    -- 1. Extract all unique tags
    -- Lua pattern: # followed by alphanumeric, _, or -
    local tag_lua_pattern = "#([%w_-]+)"
    local all_notes_pattern = utils.join_path(config.options.home, "**/*." .. config.options.extension)
    local all_notes = vim.fn.glob(all_notes_pattern, true, true)
    
    local tags_set = {}
    for _, note_file in ipairs(all_notes) do
        local file = io.open(note_file, "r")
        if file then
            local content = file:read("*a")
            file:close()
            -- In Lua, we match the tag name following the #
            for tag_name in string.gmatch(content, tag_lua_pattern) do
                tags_set["#" .. tag_name] = true
            end
        end
    end

    local tags_list = {}
    for tag, _ in pairs(tags_set) do
        table.insert(tags_list, tag)
    end
    table.sort(tags_list)

    if #tags_list == 0 then
        vim.notify("No tags found in your Zettelkasten.", vim.log.levels.INFO)
        return
    end

    -- 2. Show tags in fzf
    fzf.fzf_exec(tags_list, vim.tbl_deep_extend("force", config.options.fzf, {
        prompt = "Select Tag> ",
        actions = {
            ['default'] = function(selected)
                if not selected or #selected == 0 then return end
                -- fzf_exec returns the raw string from tags_list
                local tag = selected[1]
                -- 3. Search for the selected tag across all notes
                fzf.grep(vim.tbl_deep_extend("force", config.options.fzf, {
                    search = tag .. " ", -- Add space to match tag exactly if followed by space
                    cwd = config.options.home,
                    prompt = "Notes with " .. tag .. "> ",
                    actions = {
                        ['default'] = function(grep_selected)
                            if not grep_selected or #grep_selected == 0 then return end
                            local entry = fzf.path.entry_to_file(grep_selected[1], { cwd = config.options.home })
                            vim.cmd("edit " .. vim.fn.fnameescape(entry.path))
                            if entry.line then
                                vim.api.nvim_win_set_cursor(0, { entry.line, (entry.col or 1) - 1 })
                            end
                        end
                    }
                }))
            end
        }
    }))
end
function M.insert_link()
    fzf.files(vim.tbl_deep_extend("force", config.options.fzf.files, {
        cwd = config.options.home,
        actions = {
            ['default'] = function(selected)
                if not selected or #selected == 0 then return end
                local entry = fzf.path.entry_to_file(selected[1], { cwd = config.options.home })
                local file = vim.fn.fnamemodify(entry.path, ":t:r")
                vim.api.nvim_put({ config.options.transform.insert_link(file) }, "c", true, true)
            end
        }
    }))
end

function M.search_content()
    fzf.live_grep(vim.tbl_deep_extend("force", config.options.fzf, {
        cmd = "rg",
        cwd = config.options.home,
        prompt = "Grep> ",
        no_ignore = true,
        actions = {
            ['default'] = function(selected)
                if not selected or #selected == 0 then return end
                local entry = fzf.path.entry_to_file(selected[1], { cwd = config.options.home })
                vim.cmd("edit " .. vim.fn.fnameescape(entry.path))
                if entry.line then
                    vim.api.nvim_win_set_cursor(0, { entry.line, (entry.col or 1) - 1 })
                end
            end
        }
    }))
end

-- Helper to extract the note name from a full path (e.g., "path/to/my_note.md" -> "my_note")
local function get_note_name(filepath)
    if not filepath or type(filepath) ~= "string" or filepath == "v:null" then
        return nil -- Return nil if input path is invalid
    end

    local filename_with_ext = vim.fn.fnamemodify(filepath, ":t")
    if not filename_with_ext or type(filename_with_ext) ~= "string" or filename_with_ext == "v:null" then
        return nil -- Return nil if fnamemodify returns invalid filename
    end

    local basename = filename_with_ext:match("^(.*)%.[^%.]*$")
    if basename then
        return basename
    else
        return filename_with_ext -- No extension, return as is (e.g., "my_note", ".bashrc")
    end
end

-- Actual implementation of show_backlinks
function M.show_backlinks(filepath)
    vim.notify("DEBUG: show_backlinks called with filepath: '" .. tostring(filepath) .. "'", vim.log.levels.INFO)
    local target_note_name = get_note_name(filepath)
    if not target_note_name then
        vim.notify("Could not determine note name from path: " .. tostring(filepath), vim.log.levels.ERROR)
        return
    end
    local backlinks = {}

    local all_note_files_pattern = utils.join_path(config.options.home, "**/*." .. config.options.extension)
    local all_note_files = vim.fn.glob(all_note_files_pattern, true, true)

    if not all_note_files or #all_note_files == 0 then
        vim.notify("No other notes found in your Zettelkasten.", vim.log.levels.INFO)
        return
    end

    -- Construct a regex to find links to the target note
    -- This regex looks for [[target_note_name]] or [[target_note_name|alias]]
    local link_search_pattern = "\\[\\[" .. target_note_name:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1") .. "(\\|.-)?\\]\\]"

    for _, note_file in ipairs(all_note_files) do
        if note_file ~= filepath then -- Don't search in the current file itself
            local file = io.open(note_file, "r")
            if file then
                local content = file:read("*a")
                file:close()

                -- Split content into lines to search for backlinks per line
                for line_num, line in ipairs(vim.split(content, "\n", { plain = true })) do
                    for link_full_content in string.gmatch(line, config.options.patterns.link) do
                        -- link_full_content will be "1on1" or "1on1|alias"
                        local link_target_name = link_full_content:match("^(.-)|.*$") or link_full_content
                        if link_target_name == target_note_name then
                            -- Found a backlink
                            table.insert(backlinks, string.format("%s:%d: %s",
                                vim.fn.fnamemodify(note_file, ":~:."), -- Relative path to file
                                line_num,
                                line:match("^(%s*.-)%s*$") -- Trim leading/trailing whitespace
                            ))
                            break -- Only add once per line if multiple links point to the same target
                        end
                    end
                end
            end
        end
    end

    if #backlinks == 0 then
        vim.notify("No backlinks found for '" .. target_note_name .. "'.", vim.log.levels.INFO)
        return
    end

    fzf.fzf_exec(backlinks, vim.tbl_deep_extend("force", config.options.fzf, {
        prompt = "Backlinks for " .. target_note_name .. "> ",
        actions = {
            ['default'] = function(selected_backlink)
                if not selected_backlink or #selected_backlink == 0 then return end
                local entry = fzf.path.entry_to_file(selected_backlink[1], { cwd = config.options.home })
                if entry.path then
                    vim.cmd("edit " .. vim.fn.fnameescape(entry.path))
                    if entry.line then
                        vim.api.nvim_win_set_cursor(0, { entry.line, (entry.col or 1) - 1 })
                    end
                else
                    vim.notify("Could not open backlink: " .. selected_backlink[1], vim.log.levels.ERROR)
                end
            end
        }
    }))
end

function M.panel()
    fzf.files(vim.tbl_deep_extend("force", config.options.fzf.files, {
        cwd = config.options.home,
        prompt = "Panel: Select Note> ",
        actions = {
            ['default'] = function(selected)
                if not selected or #selected == 0 then return end
                local entry = fzf.path.entry_to_file(selected[1], { cwd = config.options.home })
                local clean_path = entry.path
                local actions = {
                    "Open: " .. clean_path,
                    "Show Backlinks: " .. clean_path,
                    "Rename: " .. clean_path,
                    "Delete: " .. clean_path,
                }

                fzf.fzf_exec(actions, vim.tbl_deep_extend("force", config.options.fzf, {
                    prompt = "Action> ",
                    actions = {
                        ['default'] = function(action_selected)
                            if not action_selected or #action_selected == 0 then return end
                            local selection = action_selected[1]

                            if selection:find("Open:") then
                                vim.cmd("edit " .. vim.fn.fnameescape(clean_path))
                            elseif selection:find("Show Backlinks:") then
                                M.show_backlinks(clean_path)
                            elseif selection:find("Rename:") then
                                require('fzfkasten.core').rename_note_interactively(clean_path)
                            elseif selection:find("Delete:") then
                                local confirmation = vim.fn.input("Confirm deletion of " .. clean_path .. " (yes/no)? ")
                                if confirmation:lower() == "yes" then
                                    vim.fn.delete(clean_path)
                                    vim.notify("Deleted: " .. clean_path, vim.log.levels.INFO)
                                else
                                    vim.notify("Deletion cancelled.", vim.log.levels.INFO)
                                end
                            end
                        end
                    }
                }))
            end
        }
    }))
end

function M.follow_link()
    local current_buffer_content = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local links = {}
    local link_pattern = config.options.link or "%[%[(.-)%]%]" -- Use config.options.link if available, otherwise fallback

    for _, line in ipairs(current_buffer_content) do
        -- Use gmatch with the link pattern to find all links in the line
        for link_text in string.gmatch(line, link_pattern) do
            if link_text ~= "" then
                table.insert(links, link_text)
            end
        end
    end

    if #links == 0 then
        vim.notify("No links found in current buffer.", vim.log.levels.INFO)
        return
    end

    fzf.fzf_exec(links, vim.tbl_deep_extend("force", config.options.fzf, {
        prompt = "Follow Link> ",
        actions = {
            ['default'] = function(selected_link)
                if not selected_link or #selected_link == 0 then return end
                local target_file = utils.join_path(config.options.home, selected_link[1] .. "." .. config.options.extension)
                if vim.fn.filereadable(target_file) == 1 then
                    vim.cmd("edit " .. vim.fn.fnameescape(target_file))
                else
                    vim.notify("Note not found: " .. target_file, vim.log.levels.ERROR)
                end
            end
        }
    }))
end

function M.select_template(callback)
    local templates_dir = utils.join_path(config.options.home, "templates")

    fzf.files(vim.tbl_deep_extend("force", config.options.fzf.files, {
        cwd = templates_dir,
        prompt = "Select Template> ",
        actions = {
            ['default'] = function(selected)
                if selected and #selected > 0 then
                    local entry = fzf.path.entry_to_file(selected[1], { cwd = templates_dir })
                    local clean_filename = vim.fn.fnamemodify(entry.path, ":t")
                    if callback then
                        callback(clean_filename)
                    end
                else
                    if callback then
                        callback(nil) -- User cancelled or no selection
                    end
                end
            end,
            ['ctrl-c'] = function()
                if callback then
                    callback(nil) -- User cancelled
                end
            end,
        }
    }))
end

function M.find_daily_notes_picker()
    local daily_dir = utils.join_path(config.options.home, config.options.notes.daily.dir)
    fzf.files(vim.tbl_deep_extend("force", config.options.fzf.files, {
        cwd = daily_dir,
        prompt = "Find Daily Note> ",
        actions = {
            ['default'] = function(selected)
                if selected and #selected > 0 then
                    local entry = fzf.path.entry_to_file(selected[1], { cwd = daily_dir })
                    local full_path = entry.path
                    vim.cmd("edit " .. vim.fn.fnameescape(full_path))
                    local title = vim.fn.fnamemodify(full_path, ":t:r")
                    require('fzfkasten.core').apply_note_template("daily", title)
                end
            end,
        }
    }, config.options.notes.daily.fzf_opts or {}))
end

function M.find_weekly_notes_picker()
    local weekly_dir = utils.join_path(config.options.home, config.options.notes.weekly.dir)
    fzf.files(vim.tbl_deep_extend("force", config.options.fzf.files, {
        cwd = weekly_dir,
        prompt = "Find Weekly Note> ",
        actions = {
            ['default'] = function(selected)
                if selected and #selected > 0 then
                    local entry = fzf.path.entry_to_file(selected[1], { cwd = weekly_dir })
                    local full_path = entry.path
                    vim.cmd("edit " .. vim.fn.fnameescape(full_path))
                    local title = vim.fn.fnamemodify(full_path, ":t:r")
                    require('fzfkasten.core').apply_note_template("weekly", title)
                end
            end,
        }
    }, config.options.notes.weekly.fzf_opts or {}))
end

return M
