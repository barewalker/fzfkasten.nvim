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

--- Split the inside of a wikilink into its parts: `[[dir/name.md#anchor|alias]]`,
--- of which all but the name are optional.
---
--- `|` is taken first, so an alias may itself contain a `#` (`[[note|see #3]]`);
--- the anchor is then everything after the first `#` of what is left, so a
--- heading containing one (`[[note#Q#A]]`) survives the round trip.
---
--- A note is named by its name, wherever it is filed and whatever the file is
--- called on disk, so a directory and the note extension are read off it and
--- handed back separately: `[[lognote/2025-W34]]` and `[[2025-W34.md]]` are both
--- links to `2025-W34`. Written those ways they used to be links to nothing --
--- unfollowable, invisible to the backlink list, and left behind by a rename
--- that reported success. Only the *configured* extension comes off, so a note
--- called `note.v2` keeps its own dot.
---
--- Lives here rather than in core or pickers because both need it and they
--- require each other: following a link and renaming one have to agree on what
--- a link means, or an anchor you can write is an anchor that only one of them
--- honours.
--- @param content string the text between the brackets
--- @return string name, string|nil anchor, string|nil alias, string|nil dir
function M.split_link(content)
    local body, alias = content:match("^(.-)|(.*)$")
    if not body then
        body = content
    end
    local name, anchor = body:match("^(.-)#(.*)$")
    if not name then
        name = body
    end

    local dir, basename = name:match("^(.*)/([^/]*)$")
    if dir then
        name = basename
    end

    local ext = config.options.extension
    if ext and ext ~= "" then
        name = name:gsub("%." .. vim.pesc(ext) .. "$", "")
    end

    return name, anchor, alias, dir
end

--- The name a `[[link]]` would call the note at `filepath`: its filename with
--- the extension taken off.
---
--- Lives here for the same reason `split_link` does -- the backlink walk, the
--- link graph and the rename all have to agree on what names a note, and they
--- cannot require each other. A leading dot is not an extension separator, so
--- `.bashrc` keeps its name rather than becoming the empty string, which every
--- empty link `[[]]` in the collection would otherwise be a link to.
--- @param filepath string
--- @return string|nil name, nil when the path is not one
function M.note_name(filepath)
    -- An unnamed buffer is "", which names no note. Read as one it is the empty
    -- name, which every empty link `[[]]` points at -- and the caller is told it
    -- has a note when what it has is a scratch buffer.
    if not filepath or type(filepath) ~= "string" or filepath == "" or filepath == "v:null" then
        return nil
    end

    local filename_with_ext = vim.fn.fnamemodify(filepath, ":t")
    if not filename_with_ext or type(filename_with_ext) ~= "string" or filename_with_ext == "v:null" then
        return nil
    end

    local basename = filename_with_ext:match("^(.*)%.[^%.]*$")
    if basename and basename ~= "" then
        return basename
    end
    return filename_with_ext -- No extension, return as is (e.g. "my_note", ".bashrc")
end

-- A `^id` preceded by whitespace: two characters at least, letters, digits and
-- hyphens. Two rather than one so that the `^2` of an exponent, which a note
-- about anything numeric will hold, is not read as an id.
local BLOCK_ID = "%s%^([%w][%w-]+)%f[%W]"

-- Seeded once, off the monotonic clock. `os.time()` has one-second resolution,
-- so two ids minted within the same second would come out identical -- which
-- for something whose whole job is to be unique is the one failure that counts.
math.randomseed(((vim.uv or vim.loop).hrtime()) % 2147483647)

--- The `^id` a line carries, or nil when it carries none.
---
--- Looked for anywhere on the line rather than at its end alone. `with_block_id`
--- keeps it last, but a note edited on a phone is not bound by that, and an id
--- that stopped being found because a stamp landed after it would break every
--- link already pointing at the line.
--- @param line string
--- @return string|nil
function M.block_id(line)
    if type(line) ~= "string" then
        return nil
    end
    return line:match(BLOCK_ID)
end

--- `text` without the id it carries, the whitespace in front of it included.
---
--- Every occurrence goes, not just the first: a line that somehow grew two ids
--- would otherwise show one of them in the task list, and an id is not part of
--- what a task says.
--- @param text string
--- @return string
function M.strip_block_id(text)
    if type(text) ~= "string" then
        return text
    end
    return (text:gsub(BLOCK_ID, ""))
end

--- `line` with `id` at its end, replacing any id already there.
---
--- At the end always, which is what the writers have to restore after they
--- rewrite a line: a completion stamp appended afterwards would push the id
--- into the middle, and a strikethrough would wrap around it -- `~~text ^t3k9~~`
--- reads as though the id were part of the dropped text.
--- @param line string
--- @param id string
--- @return string
function M.with_block_id(line, id)
    local bare = M.strip_block_id(line):gsub("%s+$", "")
    return bare .. " ^" .. id
end

--- A fresh id, avoiding anything in `taken`.
---
--- Random rather than built from the line's own words. A readable id
--- (`^qms-slice`) is a name, and a name classifies: sitting next to `#qms` it
--- would read as a second tag, which is the one thing an id is here not to be.
--- It also has to be minted without asking anything, since the whole operation
--- is meant to be one keystroke.
---
--- `taken` is a courtesy to the note being edited rather than a real defence --
--- at 2.2 billion ids the collection is not what runs out.
--- @param taken table<string, boolean>|nil ids already in use
--- @return string
function M.new_block_id(taken)
    local o = config.options.block_id or {}
    local alphabet = o.alphabet
    if type(alphabet) ~= "string" or alphabet == "" then
        alphabet = "abcdefghijklmnopqrstuvwxyz0123456789"
    end
    local length = tonumber(o.length) or 6
    if length < 1 then
        length = 6
    end

    local function mint()
        local out = {}
        for i = 1, length do
            local at = math.random(#alphabet)
            out[i] = alphabet:sub(at, at)
        end
        return table.concat(out)
    end

    for _ = 1, 64 do
        local id = mint()
        if not (taken and taken[id]) then
            return id
        end
    end
    return mint()
end

--- Every id in `lines`, as a set. What `new_block_id` is asked to avoid.
--- @param lines string[]
--- @return table<string, boolean>
function M.block_ids(lines)
    local seen = {}
    for _, line in ipairs(lines or {}) do
        local id = M.block_id(line)
        if id then
            seen[id] = true
        end
    end
    return seen
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