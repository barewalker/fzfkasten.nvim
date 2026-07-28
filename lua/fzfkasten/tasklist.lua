-- The task list as a buffer you work in with Vim keys.
--
-- The picker (`:FzfKastenTasks`) is the right tool for finding one task fast:
-- you type, you press enter, and its ctrl/alt bindings never come up. It is the
-- wrong tool for working down a list, where you want `j`, `k`, `/`, `gg` and
-- everything else you already know -- and cannot have them, because fzf's
-- prompt owns every unmodified key. There is no key scheme that fixes that; the
-- input field is the reason.
--
-- So this renders the same `tasks.collect` into an ordinary scratch buffer,
-- where the only keys defined are the actions themselves. Movement, search and
-- scrolling are Vim's, untouched.
--
-- The buffer is never written and is not the ledger -- the notes still are.
-- Every action goes through the same `tasks.*_at` writers the picker uses, and
-- the buffer is redrawn from disk afterwards. Close it and nothing is lost.

local tasks = require('fzfkasten.tasks')
local config = require('fzfkasten.config')
local buffer = require('fzfkasten.buffer')

local M = {}

local NAME = "fzfkasten://tasks"
local ns = vim.api.nvim_create_namespace("fzfkasten-tasklist")

-- The one list buffer, and what it is currently showing. Reopening reuses it
-- rather than stacking up buffers that all say the same thing.
local buf = nil
local view = nil -- { opts, rows = { [lineno] = task }, origin = winid, win = winid }

-- The preview split under the list. `shown` is the task it is currently
-- displaying ("path:lineno"), so moving the cursor within one row -- or back
-- onto a row that is already up -- doesn't re-read the note.
local preview = { win = nil, buf = nil, shown = nil }

local augroup = vim.api.nvim_create_augroup("fzfkasten-tasklist", { clear = true })

-- Rows start here: line 1 is the heading, line 2 is blank.
local FIRST_ROW = 3

local function options()
    return (config.options.tasks or {}).list or {}
end

local function keys()
    return options().keys or {}
end

local function preview_options()
    return options().preview or {}
end

local function alive()
    return buf ~= nil and vim.api.nvim_buf_is_valid(buf)
end

local function preview_alive()
    return preview.win ~= nil and vim.api.nvim_win_is_valid(preview.win)
end

-- The task under the cursor, or nil on the heading, a blank line or the "empty"
-- notice. Every action starts here, so none of them can act on a row that isn't
-- a task.
--
-- Reads the list window rather than the current one: the preview update runs
-- from an autocmd, and the scroll keys run while the preview holds focus.
local function current_task()
    if not alive() or not view then return nil end
    local win = view.win
    if not win or not vim.api.nvim_win_is_valid(win) then
        return nil
    end
    return view.rows[vim.api.nvim_win_get_cursor(win)[1]]
end

-- Draw `lines` into the buffer, which is otherwise kept unmodifiable: this is a
-- view of the notes, and typing into it would edit nothing.
local function set_lines(lines)
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.bo[buf].modified = false
end

-- Colour the parts of a row that are structure rather than text, and hang the
-- task's note and line off the right edge as virtual text -- there, but never
-- in the way of reading the task, and never something a yank picks up.
local function decorate(lineno, line, task)
    local function hl(pattern, group)
        local from, to = line:find(pattern)
        if from then
            vim.api.nvim_buf_set_extmark(buf, ns, lineno - 1, from - 1, {
                end_col = to,
                hl_group = group,
            })
        end
    end
    hl("^%s*↳", "Comment")
    hl("%(%u%)", "Statement")
    hl("%[%d+/%d+%]", "Comment")
    hl("%[due [^%]]+%]", "Constant")
    hl("←.*$", "Comment")

    if options().source ~= false then
        vim.api.nvim_buf_set_extmark(buf, ns, lineno - 1, 0, {
            virt_text = { { string.format("%s:%d", task.rel, task.lineno), "Comment" } },
            virt_text_pos = "right_align",
        })
    end
end

-- The note's lines, from the buffer when one is loaded and from disk otherwise.
--
-- Preferring the buffer matters: with the note open and edited but unsaved, the
-- file on disk is behind, and a preview showing the old text would be lying
-- about the very line you are about to act on.
local function note_lines(path)
    local bufnr = vim.fn.bufnr(path)
    if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
        return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    end
    local ok, lines = pcall(vim.fn.readfile, path)
    return ok and lines or {}
end

local function close_preview()
    if preview_alive() then
        pcall(vim.api.nvim_win_close, preview.win, true)
    end
    preview.win, preview.shown = nil, nil
end

-- Show the task's note around its line, with the task line marked.
--
-- The window is not focused: this runs as the cursor moves through the list, so
-- everything here goes through `nvim_win_*` on the preview window explicitly.
local function draw_preview(task)
    if not preview_alive() then return end
    if not task then
        -- Between tasks (the heading, the blank line): leave the last note up
        -- rather than flashing an empty window on the way past.
        return
    end
    local key = task.path .. ":" .. task.lineno
    if preview.shown == key then return end
    preview.shown = key

    local lines = note_lines(task.path)
    vim.bo[preview.buf].modifiable = true
    vim.api.nvim_buf_set_lines(preview.buf, 0, -1, false, lines)
    vim.bo[preview.buf].modifiable = false
    vim.bo[preview.buf].modified = false

    local filetype = vim.filetype.match({ filename = task.path }) or "markdown"
    if vim.bo[preview.buf].filetype ~= filetype then
        vim.bo[preview.buf].filetype = filetype
    end

    vim.api.nvim_buf_clear_namespace(preview.buf, ns, 0, -1)
    local lineno = math.min(task.lineno, math.max(#lines, 1))
    if #lines > 0 then
        vim.api.nvim_buf_set_extmark(preview.buf, ns, lineno - 1, 0, {
            line_hl_group = "Visual",
        })
    end
    pcall(vim.api.nvim_win_set_cursor, preview.win, { lineno, 0 })
    -- Centre it, so the lines above the task -- the heading it sits under, the
    -- bullet it hangs off -- are what the window is actually for.
    vim.api.nvim_win_call(preview.win, function() vim.cmd("normal! zz") end)
end

-- Split the preview under the list. `height` is a fraction of the list window
-- when below 1, and a line count otherwise.
local function open_preview()
    if preview_alive() or preview_options().enabled == false then return end
    local list_win = vim.api.nvim_get_current_win()
    local total = vim.api.nvim_win_get_height(list_win)
    local height = preview_options().height or 0.5
    if height < 1 then
        height = math.floor(total * height)
    end
    height = math.max(3, math.min(math.floor(height), total - 3))

    if preview.buf == nil or not vim.api.nvim_buf_is_valid(preview.buf) then
        preview.buf = vim.api.nvim_create_buf(false, true)
        vim.bo[preview.buf].buftype = "nofile"
        vim.bo[preview.buf].swapfile = false
        vim.bo[preview.buf].buflisted = false
        vim.bo[preview.buf].modifiable = false
        -- Out of the preview and back to the list, the same key that leaves the
        -- list itself -- `q` gets you out of wherever you are.
        vim.keymap.set("n", "q", function()
            if view and view.win and vim.api.nvim_win_is_valid(view.win) then
                vim.api.nvim_set_current_win(view.win)
            end
        end, { buffer = preview.buf, nowait = true, desc = "Fzfkasten task list: back to the list" })
    end

    vim.cmd("belowright split")
    preview.win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(preview.win, preview.buf)
    vim.api.nvim_win_set_height(preview.win, height)
    vim.wo[preview.win].number = true
    vim.wo[preview.win].wrap = false
    vim.wo[preview.win].winfixheight = true
    vim.api.nvim_set_current_win(list_win)
    preview.shown = nil
end

-- Close the preview once the list is no longer on screen anywhere.
--
-- The preview belongs to the list, not to the window it happens to sit under:
-- switch that window to something else -- `<enter>` onto a note, a walk back
-- through the jumplist, `:bnext` -- and a split still showing a note nobody is
-- pointing at is left behind. It is not enough to watch for the buffer being
-- wiped, because leaving it merely hides it.
--
-- Deferred, because `BufWinLeave` fires *before* the buffer leaves and closing
-- a window from inside it is refused. By the time the schedule runs the layout
-- has settled, so "is the list displayed at all?" is a question worth asking --
-- and it answers the case of the list being open in two windows for free.
local function close_preview_unless_shown()
    vim.schedule(function()
        if not alive() or #vim.fn.win_findbuf(buf) == 0 then
            close_preview()
        end
    end)
end

-- Scroll the preview without leaving the list. `keys` is a normal-mode scroll
-- command; it runs in the preview window, so `<c-e>`/`<c-f>` mean there what
-- they mean anywhere in Vim -- only the window they act on is different.
local function scroll_preview(command)
    if not preview_alive() then
        vim.notify("[Fzfkasten] The preview is not open.", vim.log.levels.INFO)
        return
    end
    vim.api.nvim_win_call(preview.win, function()
        vim.cmd.normal({ vim.keycode(command), bang = true })
    end)
end

-- Rebuild the buffer from the notes on disk.
--
-- The cursor is kept on its line number rather than on the task that was under
-- it: complete one and the next moves up into place, so a run of them is one
-- keypress each. That is the picker's `reload` behaviour, and the reason it is
-- worth keeping here.
local function render()
    local collected = tasks.collect(view.opts)
    local label = view.opts.inbox and "Inbox" or "Tasks"
    local order = view.opts.sort or "priority"
    local lines = {
        string.format("%s — %d   ·   %s%s", label, #collected, order,
            view.opts.reverse and ", reversed" or ""),
        "",
    }

    local rows = {}
    for _, task in ipairs(collected) do
        table.insert(lines, tasks.entry_text(task))
        rows[#lines] = task
    end
    if #collected == 0 then
        table.insert(lines, view.opts.inbox
            and "  Nothing waiting to be triaged."
            or "  No open tasks.")
    end

    local cursor = vim.api.nvim_win_get_cursor(0)[1]
    set_lines(lines)
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, { end_col = #lines[1], hl_group = "Title" })
    for lineno, task in pairs(rows) do
        decorate(lineno, lines[lineno], task)
    end
    view.rows = rows

    -- Clamp, so finishing the last task doesn't leave the cursor past the end.
    vim.api.nvim_win_set_cursor(0, { math.max(FIRST_ROW, math.min(cursor, #lines)), 0 })

    -- The row under the cursor is a different task now, even when the cursor
    -- did not move, so the preview is redrawn unconditionally.
    preview.shown = nil
    draw_preview(current_task())
end

-- Redraw only if the list is still on screen. An action can send you into a
-- note (`<CR>`), and redrawing then would move a cursor that is no longer ours.
local function refresh()
    if alive() and vim.api.nvim_get_current_buf() == buf then
        render()
    end
end

-- Change what the list is showing and draw it again.
local function reshape(changed)
    view.opts = vim.tbl_extend("force", view.opts, changed)
    render()
end

-- Open the note this row came from. In a split the note replaces what you were
-- reading, not the list -- keeping both on screen is the reason you asked for a
-- split. Taking the whole window means the list steps aside, and `<C-o>` brings
-- it back.
local function open_task()
    local task = current_task()
    if not task then return end
    if view.origin and vim.api.nvim_win_is_valid(view.origin)
        and view.origin ~= vim.api.nvim_get_current_win() then
        vim.api.nvim_set_current_win(view.origin)
    end
    buffer.edit(task.path)
    local last = vim.api.nvim_buf_line_count(0)
    vim.api.nvim_win_set_cursor(0, { math.min(task.lineno, last), 0 })
end

-- Wrap an action that rewrites a note so the list redraws after it. `fn` gets
-- the task under the cursor and is not called when there isn't one.
local function on_task(fn)
    return function()
        local task = current_task()
        if not task then return end
        fn(task)
        refresh()
    end
end

local ACTIONS = {
    open = open_task,
    done = on_task(function(task) tasks.toggle_at(task.path, task.lineno) end),
    cancel = on_task(function(task) tasks.cancel_at(task.path, task.lineno) end),
    tag = on_task(function(task) tasks.tag_at(task.path, task.lineno) end),
    undo = function()
        tasks.undo()
        refresh()
    end,
    -- The capture steps out to a real input, which cannot run while this
    -- buffer's mapping is still on the stack in some setups; deferring also
    -- lets the redraw land after the note is written.
    add = function()
        vim.schedule(function()
            tasks.capture(nil, refresh)
        end)
    end,
    sort = function() reshape({ sort = tasks.next_sort(view.opts.sort) }) end,
    reverse = function() reshape({ reverse = not view.opts.reverse }) end,
    inbox = function()
        if not config.options.tasks.require_tag then
            vim.notify(
                "[Fzfkasten] The inbox needs tasks.require_tag set; without it "
                .. "every checkbox is already a task.",
                vim.log.levels.WARN
            )
            return
        end
        reshape({ inbox = not view.opts.inbox })
    end,
    refresh = refresh,
    close = function()
        close_preview()
        -- `:bdelete` rather than closing the window: in a split that leaves the
        -- split you were reading in, and taking the whole window it puts back
        -- whatever was there before.
        pcall(vim.cmd, "bdelete " .. buf)
    end,

    -- Step into the preview, where every Vim key works because it is an
    -- ordinary window: `j`, `gg`, `/`, `<c-d>`. `q` (or `<c-w>p`) comes back.
    preview = function()
        if not preview_alive() then
            open_preview()
            draw_preview(current_task())
        end
        if preview_alive() then
            vim.api.nvim_set_current_win(preview.win)
        end
    end,
    preview_toggle = function()
        if preview_alive() then
            close_preview()
        else
            open_preview()
            preview.shown = nil
            draw_preview(current_task())
        end
    end,
    preview_down = function() scroll_preview("<C-e>") end,
    preview_up = function() scroll_preview("<C-y>") end,
    preview_page_down = function() scroll_preview("<C-f>") end,
    preview_page_up = function() scroll_preview("<C-b>") end,
}

-- Where the list opens. Everything but "full" leaves the window you were in, so
-- `<CR>` has somewhere to put the note.
local function open_window(where)
    if where == "split" then
        vim.cmd("split")
    elseif where == "vsplit" then
        vim.cmd("vsplit")
    elseif where == "tab" then
        vim.cmd("tabnew")
    end
end

-- The window in this tab already showing the list, if there is one.
local function window_showing()
    if not alive() then return nil end
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if vim.api.nvim_win_get_buf(win) == buf then
            return win
        end
    end
    return nil
end

-- Where `<enter>` should put a note: the window you came from -- unless you came
-- from the list itself, in which case the one it already had, or coming back to
-- the list and pressing `<enter>` would open the note straight over it. Under
-- `open = "full"` the list *is* its own origin, and `open_task` edits in place.
local function resolve_origin(from, list_win)
    if from ~= list_win then
        return from
    end
    local previous = view and view.origin
    if previous and previous ~= list_win and vim.api.nvim_win_is_valid(previous) then
        return previous
    end
    return from
end

local function create_buffer()
    local created = vim.api.nvim_create_buf(false, true)
    pcall(vim.api.nvim_buf_set_name, created, NAME)
    vim.bo[created].buftype = "nofile"
    vim.bo[created].swapfile = false
    vim.bo[created].buflisted = false
    vim.bo[created].modifiable = false
    vim.bo[created].filetype = "fzfkasten-tasks"
    return created
end

local function apply_keys()
    for name, action in pairs(ACTIONS) do
        local lhs = keys()[name]
        if lhs and lhs ~= "" then
            vim.keymap.set("n", lhs, action, {
                buffer = buf,
                nowait = true,
                desc = "Fzfkasten task list: " .. name,
            })
        end
    end
end

--- Open the task list buffer.
---
--- Reuses the one buffer if it is already around, so this doubles as "bring the
--- list back" -- including after `<CR>` sent you into a note.
--- @param opts table|nil forwarded to `tasks.collect`; `{ inbox = true }` opens
---   the triage list, `sort`/`reverse` pick the ordering to start from.
function M.open(opts)
    opts = opts or {}
    local origin = vim.api.nvim_get_current_win()

    -- Already on screen: focus it. Reopening is how you come back to the list,
    -- and coming back to something you are already looking at should not split
    -- the screen a second time onto the same buffer.
    local shown = window_showing()
    if shown then
        origin = resolve_origin(origin, shown)
        vim.api.nvim_set_current_win(shown)
    else
        open_window(options().open or "full")
        if not alive() then
            buf = create_buffer()
        end
        vim.api.nvim_win_set_buf(0, buf)
    end

    -- Keep the ordering you were last looking at when reopening, unless this
    -- call asks for something specific: reopening the list should hand it back
    -- as you left it.
    local previous = view and view.opts or {}
    view = {
        opts = vim.tbl_extend("force", previous, opts),
        rows = {},
        -- In a full-window list the window we are in *is* the origin, and
        -- `open_task` notices they are the same and edits in place.
        origin = origin,
        win = vim.api.nvim_get_current_win(),
    }

    -- Reading a list, not writing one: the cursor sits on rows, and a stray
    -- keystroke should do nothing rather than something.
    vim.wo[0].wrap = false
    vim.wo[0].cursorline = true
    vim.wo[0].number = false
    vim.wo[0].relativenumber = false
    vim.wo[0].signcolumn = "no"

    apply_keys()

    -- The preview follows the cursor, and goes away with the list: a split left
    -- behind showing a note you are no longer looking at is worse than no
    -- preview at all.
    vim.api.nvim_clear_autocmds({ group = augroup })
    vim.api.nvim_create_autocmd("CursorMoved", {
        group = augroup,
        buffer = buf,
        callback = function() draw_preview(current_task()) end,
    })
    vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
        group = augroup,
        buffer = buf,
        callback = close_preview,
    })
    -- The list leaving its window, by whatever route.
    vim.api.nvim_create_autocmd("BufWinLeave", {
        group = augroup,
        buffer = buf,
        callback = close_preview_unless_shown,
    })
    -- ...and the window itself being closed, which `BufWinLeave` does not cover
    -- when it is the preview that goes: this then finds the list still up and
    -- leaves it alone, which is the point of asking rather than just closing.
    vim.api.nvim_create_autocmd("WinClosed", {
        group = augroup,
        callback = close_preview_unless_shown,
    })

    open_preview()
    render()
end

--- Open the list showing the checkboxes `require_tag` leaves out.
function M.inbox()
    M.open({ inbox = true })
end

-- Test hooks (see tests/tasklist_spec.lua). `reset` forgets the buffer and what
-- it was showing, so one case's ordering can't leak into the next -- the
-- remembered `opts` that makes reopening feel right is what makes a suite
-- order-dependent without this.
M._test = {
    reset = function()
        close_preview()
        if preview.buf and vim.api.nvim_buf_is_valid(preview.buf) then
            pcall(vim.api.nvim_buf_delete, preview.buf, { force = true })
        end
        preview.buf = nil
        if alive() then
            pcall(vim.api.nvim_buf_delete, buf, { force = true })
        end
        buf, view = nil, nil
    end,
    rows = function() return view and view.rows or {} end,
    bufnr = function() return buf end,
    preview = function() return preview end,
}

return M
