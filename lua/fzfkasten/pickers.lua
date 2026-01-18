local fzf = require('fzf-lua')
local config = require('fzfkasten.config')
local utils = require('fzfkasten.utils') -- Added for path joining if needed later
local M = {}

function M.find_notes()
    fzf.files(vim.tbl_deep_extend("force", config.options.fzf.files, {
        cwd = config.options.home, prompt = "Notes> "
    }))
end
function M.search_tags()
    fzf.grep(vim.tbl_deep_extend("force", config.options.fzf, {
        search = config.options.patterns.tag,
        cwd = config.options.home,
        prompt = "Tags> ",
        rg_opts = "--column --line-number --no-heading --color=always --smart-case --only-matching -e",
        no_esc = true,
    }))
end
function M.insert_link()
    fzf.files(vim.tbl_deep_extend("force", config.options.fzf.files, {
        cwd = config.options.home,
        actions = {
            ['default'] = function(selected)
                local file = vim.fn.fnamemodify(selected[1], ":t:r")
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
                -- Extract the file path from the selected backlink string (e.g., "path/to/note.md:123: link_line")
                local backlink_file_path = selected_backlink[1]:match("^(.-):%d+:")
                if backlink_file_path then
                    -- Expand path to full path and remove trailing ':' from match
                    local full_path = vim.fn.fnamemodify(backlink_file_path:gsub(":%d+:", ""), ":p")
                    vim.cmd("edit " .. full_path)
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
                local selected_note_path = selected[1]
                local actions = {
                    "Open: " .. selected_note_path,
                    "Show Backlinks: " .. selected_note_path,
                    "Delete: " .. selected_note_path,
                }

                fzf.run(vim.tbl_deep_extend("force", config.options.fzf, {
                    prompt = "Action> ",
                    input = actions, -- input expects a table of strings for fzf.run
                    actions = {
                        ['default'] = function(action_selected)
                            vim.notify("DEBUG: action_selected BEFORE GUARD: " .. vim.inspect(action_selected), vim.log.levels.INFO)
                            if not action_selected then return end
                            vim.notify("DEBUG: action_selected: " .. vim.inspect(action_selected), vim.log.levels.INFO)
                            if action_selected:find("Open:") then
                                vim.cmd("edit " .. selected_note_path)
                            elseif action_selected:find("Show Backlinks:") then
                                local path_from_action = action_selected:match("^%s*Show Backlinks:%s*(.*)$")
                                vim.notify("DEBUG: path_from_action: '" .. tostring(path_from_action) .. "'", vim.log.levels.INFO)
                                if path_from_action then
                                    vim.notify("DEBUG: Calling show_backlinks with filepath: '" .. tostring(path_from_action) .. "'", vim.log.levels.INFO)
                                    show_backlinks(path_from_action)
                                else
                                    vim.notify("Error: Could not extract path from selected action: '" .. tostring(action_selected) .. "'", vim.log.levels.ERROR)
                                end
                            elseif action_selected:find("Delete:") then
                                local confirmation = vim.fn.input("Confirm deletion of " .. selected_note_path .. " (yes/no)? ")
                                if confirmation:lower() == "yes" then
                                    vim.fn.delete(selected_note_path)
                                    vim.notify("Deleted: " .. selected_note_path, vim.log.levels.INFO)
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
                    vim.cmd("edit " .. target_file)
                else
                    vim.notify("Note not found: " .. target_file, vim.log.levels.ERROR)
                end
            end
        }
    }))
end

return M
