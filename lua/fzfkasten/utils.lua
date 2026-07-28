local M = {}
local config = require('fzfkasten.config')

function M.join_path(...)
    return (table.concat({...}, "/"):gsub("//+", "/"))
end

--- `days` calendar days from `now`, as a timestamp. Negative counts backwards.
---
--- Counted in calendar days rather than 86400-second steps, because on the day
--- the clocks change a day is 23 or 25 hours long and stepping by seconds lands
--- on the wrong date: a log picker built that way skips the changeover day
--- entirely -- you cannot reach that day's note -- and `due:tomorrow` writes
--- yesterday's date into a note.
---
--- Normalising at midday is what makes it safe: an hour either way can then
--- never move the date. `os.time` renormalises an out-of-range day, so month,
--- year and leap-day boundaries need no arithmetic of their own.
--- @param now integer|nil timestamp to count from; defaults to the current time
--- @param days integer
--- @return integer
function M.days_from(now, days)
    local t = os.date("*t", now or os.time())
    t.day = t.day + days
    t.hour, t.min, t.sec = 12, 0, 0
    -- Let the C library work out whether the result is in DST; keeping the
    -- source day's flag would reintroduce the hour this is here to avoid.
    t.isdst = nil
    return os.time(t)
end

--- Split the inside of a wikilink into its parts: `[[name#anchor|alias]]`, of
--- which the last two are optional.
---
--- `|` is taken first, so an alias may itself contain a `#` (`[[note|see #3]]`);
--- the anchor is then everything after the first `#` of what is left, so a
--- heading containing one (`[[note#Q#A]]`) survives the round trip.
---
--- Lives here rather than in core or pickers because both need it and they
--- require each other: following a link and renaming one have to agree on what
--- a link means, or an anchor you can write is an anchor that only one of them
--- honours.
--- @param content string the text between the brackets
--- @return string name, string|nil anchor, string|nil alias
function M.split_link(content)
    local body, alias = content:match("^(.-)|(.*)$")
    if not body then
        body = content
    end
    local name, anchor = body:match("^(.-)#(.*)$")
    if not name then
        name = body
    end
    return name, anchor, alias
end

function M.get_template_path(template_name)
    return M.join_path(config.options.home, "templates", template_name)
end

-- This function is intended to list templates. In a Neovim context, it would use vim.fn.glob.
-- For the purpose of this setup, we'll assume templates are in config.options.home/templates/
function M.list_templates()
    local templates_dir = M.join_path(config.options.home, "templates")
    local template_files = {}
    -- In a real Neovim environment, this would be something like:
    -- for _, fpath in ipairs(vim.fn.glob(templates_dir .. "/*.md", true, true)) do
    --     table.insert(template_files, vim.fn.fnamemodify(fpath, ":t"))
    -- end
    -- For now, we'll return a placeholder, and ensure the fzf-lua picker handles the actual listing.
    return { "default.md" } -- Placeholder, will be replaced by fzf-lua picker
end

return M