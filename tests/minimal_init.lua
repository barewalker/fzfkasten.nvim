-- Minimal init for the test suite. Run from the repo root:
--
--   nvim --headless -u tests/minimal_init.lua \
--     -c "PlenaryBustedDirectory tests/ { minimal_init = 'tests/minimal_init.lua' }"
--
-- or simply `make test`. It puts the plugin, plenary and fzf-lua on the
-- runtimepath -- tasks.lua `require`s fzf-lua at load, so it has to be found
-- even though the tests only exercise pure string helpers.

-- The repo root is this file's grandparent (tests/minimal_init.lua -> root).
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

-- Find a plugin wherever the user's manager dropped it. lazy.nvim first, then
-- the native `pack/*/start` layout, so this runs on more than one setup.
local function plugin_dir(name)
    local data = vim.fn.stdpath("data")
    for _, glob in ipairs({
        data .. "/lazy/" .. name,
        data .. "/site/pack/*/start/" .. name,
        data .. "/site/pack/*/opt/" .. name,
    }) do
        local hits = vim.fn.glob(glob, true, true)
        if #hits > 0 then
            return hits[1]
        end
    end
    return nil
end

vim.opt.rtp:prepend(root)

for _, name in ipairs({ "plenary.nvim", "fzf-lua" }) do
    local dir = plugin_dir(name)
    if not dir then
        io.stderr:write("[fzfkasten tests] could not find " .. name .. " on this machine\n")
        vim.cmd("cquit 1")
    end
    vim.opt.rtp:append(dir)
end

-- Load fzf-lua now, while `assert` is still Lua's builtin. plenary.busted
-- replaces the global `assert` with luassert, and fzf-lua's utils.lua runs
-- `assert(tonumber(...))` at load; requiring it after busted therefore crashes.
-- Loading it here caches the module, so the later require from tasks.lua reuses
-- it without re-running that line.
pcall(require, "fzf-lua")

vim.cmd("runtime plugin/plenary.vim")
