-- Romaji narrowing for the pickers: type `kaigi`, match 会議.
--
-- fzf matches on the literal query, so a Japanese list can only be narrowed by
-- typing Japanese. What lifts that is a migemo: romaji in, a regex over the
-- Japanese text out -- and, importantly, over the *kanji* too, which takes a
-- reading-to-headword dictionary and not just a kana table.
--
-- Two programs here can do that, so this module is a seam rather than a wrapper:
--
--   ttyskk   `ttyskk migemo` (Rust, reads the SKK dictionaries already on the
--            machine). No runtime of its own, ~30ms per query.
--   kensaku  kensaku.vim, which runs on denops and therefore on Deno, and
--            downloads a 2.1MB migemo dictionary on first use.
--
-- `auto` prefers ttyskk: it is the one that costs nothing beyond itself. Name a
-- backend in `romaji.backend` to pin it, pass a table of your own to supply
-- one, or `false` to turn <alt-/> off.
--
-- The pattern every caller follows: keep a `filter` (a `\m` Vim regex or nil) in
-- the picker's own state, drop entries that do not match it, and rebuild the
-- picker with a new `filter` when `<alt-/>` fires. Nothing here reaches into a
-- picker; a caller passes a `reopen(regex)` that reopens itself.
local M = {}

local function options()
    local config = require("fzfkasten.config")
    return (config.options and config.options.romaji) or {}
end

-- kensaku.vim ---------------------------------------------------------------

-- kensaku's JavaScript regex flavour, inlined from `g:kensaku#rxop#javascript`
-- (autoload/kensaku/rxop.vim). This is what ripgrep's Rust engine understands
-- -- `(?:...)`, `|`, classes -- whereas the Vim flavour is not. Inlining it
-- means the rg call leans only on `kensaku#query`, exactly like the Vim one,
-- rather than also on the flavour global loading in time; the two then succeed
-- or fail together instead of content search lagging the task picker.
local RXOP_RG = {
    ["or"] = "|",
    startGroup = "(?:",
    endGroup = ")",
    startClass = "[",
    endClass = "]",
    newline = "",
    escape = "\\.[]{}()*+-?^$|",
}

local kensaku = { name = "kensaku" }

-- `exists('*kensaku#query')` only sees the function after its autoload script
-- has run once, so also look for that script on runtimepath -- otherwise a
-- fresh session hides the filter until kensaku is first used.
function kensaku.available()
    return vim.fn.exists("*kensaku#query") == 1
        or vim.fn.globpath(vim.o.runtimepath, "autoload/kensaku.vim") ~= ""
end

local function kensaku_query(romaji, rxop)
    local ok, re = pcall(vim.fn["kensaku#query"], romaji, rxop and { rxop = rxop } or nil)
    -- The wrapper returns "" until denops has started, so an empty answer is
    -- kensaku working correctly and not being ready -- not a regex.
    if ok and type(re) == "string" and re ~= "" then return re end
    return nil
end

function kensaku.regex(romaji)
    return kensaku_query(romaji, nil)
end

function kensaku.rg_regex(romaji)
    return kensaku_query(romaji, RXOP_RG)
end

-- ttyskk --------------------------------------------------------------------

local ttyskk = { name = "ttyskk" }

-- Whether `<cmd> migemo` answers, keyed by the command so that changing
-- `romaji.ttyskk.cmd` re-asks. Probed once rather than on every picker open:
-- the call is ~30ms, and `available()` runs whenever a header is drawn.
local probed = {}

local function ttyskk_opts()
    return options().ttyskk or {}
end

local function ttyskk_run(flavour, romaji)
    local opts = ttyskk_opts()
    local cmd = { opts.cmd or "ttyskk", "migemo", "--flavour", flavour }
    if opts.limit then
        cmd[#cmd + 1] = "--limit"
        cmd[#cmd + 1] = tostring(opts.limit)
    end
    cmd[#cmd + 1] = romaji

    -- pcall because a missing command raises rather than returning a status,
    -- and a timeout because this runs in front of the user: a hung migemo must
    -- not be a hung Neovim.
    local ok, result = pcall(function()
        return vim.system(cmd, { text = true, timeout = opts.timeout or 5000 }):wait()
    end)
    if not ok or type(result) ~= "table" or result.code ~= 0 then return nil end
    local re = vim.trim(result.stdout or "")
    if re == "" then return nil end
    return re
end

function ttyskk.available()
    local cmd = ttyskk_opts().cmd or "ttyskk"
    if probed[cmd] ~= nil then return probed[cmd] end
    if vim.fn.executable(cmd) ~= 1 then
        probed[cmd] = false
        return false
    end
    -- The binary existing is not the same as it knowing `migemo`; an older
    -- ttyskk is on plenty of machines. Ask it something and see.
    probed[cmd] = ttyskk_run("rg", "a") ~= nil
    return probed[cmd]
end

function ttyskk.regex(romaji)
    return ttyskk_run("vim", romaji)
end

function ttyskk.rg_regex(romaji)
    return ttyskk_run("rg", romaji)
end

-- Choosing one -------------------------------------------------------------

local BACKENDS = { ttyskk = ttyskk, kensaku = kensaku }

-- Tried in this order under "auto". ttyskk first because it is the one that
-- brings no runtime of its own.
local AUTO = { "ttyskk", "kensaku" }

--- The backend to use, or nil when none can answer.
--- @return table|nil
function M.backend()
    local choice = options().backend
    if choice == nil then choice = "auto" end
    if choice == false then return nil end

    if type(choice) == "table" then
        return choice.available and choice.available() and choice or nil
    end

    if choice ~= "auto" then
        local backend = BACKENDS[choice]
        if not backend then
            vim.notify("[Fzfkasten] unknown romaji.backend: " .. tostring(choice),
                vim.log.levels.WARN)
            return nil
        end
        return backend.available() and backend or nil
    end

    for _, name in ipairs(AUTO) do
        local backend = BACKENDS[name]
        if backend.available() then return backend end
    end
    return nil
end

--- Is romaji narrowing available at all? Safe to call anywhere.
function M.available()
    return M.backend() ~= nil
end

--- The name of the active backend, for `:checkhealth` to report.
--- @return string|nil
function M.backend_name()
    local backend = M.backend()
    return backend and backend.name or nil
end

local function build(kind, romaji)
    romaji = vim.trim(romaji or "")
    if romaji == "" then return nil end
    local backend = M.backend()
    if not backend then return nil end
    return backend[kind](romaji)
end

--- Turn a romaji query into a `\m` Vim regex, or nil when there is nothing to
--- match on (blank input, no backend, or the backend not ready). Use this for
--- filtering entries in Lua with `M.matches` (`vim.fn.match`).
function M.regex(romaji)
    return build("regex", romaji)
end

--- Turn a romaji query into a ripgrep-compatible regex, or nil. Use this when
--- the query is fed to `rg` (content search), not matched in Lua.
---
--- Kept apart from `M.regex` because the flavours are not interchangeable:
--- ripgrep's engine reads `(?:...)` and `|`, and makes nothing of Vim's `\%(`
--- and `\|`. Handing it the wrong one does not fail -- it matches nothing.
function M.rg_regex(romaji)
    return build("rg_regex", romaji)
end

--- Does `text` match the filter? A nil/empty filter matches everything, so a
--- caller can guard every entry with this and let an unfiltered picker fall
--- straight through.
function M.matches(text, re)
    if not re or re == "" then return true end
    return vim.fn.match(text, re) >= 0
end

--- Append the `<alt-/>` hint to an fzf `--header`, but only when something is
--- there to honour it, so the header never advertises a key that just warns.
function M.header_hint(header)
    if not M.available() then return header end
    if header == nil or header == "" then return "<alt-/> romaji" end
    return header .. "   <alt-/> romaji"
end

--- A picker prompt that flags an active romaji filter, so a short list reads as
--- "filtered" rather than "all there is". `label` is the bare name ("Notes").
function M.prompt(label, re)
    return (re and re ~= "") and (label .. " (romaji)> ") or (label .. "> ")
end

-- Shared `<alt-/>` flow: ask for a romaji query (seeded from the fzf query),
-- turn it into a filter with `build`, and hand it to `reopen`. `build` is
-- `M.regex` for Lua-side filtering or `M.rg_regex` for ripgrep -- the only
-- difference between the two public actions below.
--
-- Seeds the input with `{q}` because you often start typing romaji in the
-- picker, get no hits, then reach for this. Like the task capture it steps out
-- to a real `vim.ui.input`, so it must let the picker finish closing first --
-- opening mid-teardown races it (the input never attaches, and its window can
-- be left behind). Hence the deferred reopen.
local function input_action(make, reopen, current)
    return {
        fn = function(selected)
            local seed = (selected and selected[1]) or ""
            vim.defer_fn(function()
                if not M.available() then
                    vim.notify("[Fzfkasten] no romaji backend is available.",
                        vim.log.levels.WARN)
                    reopen(current)
                    return
                end
                vim.ui.input({
                    prompt = "Romaji filter (blank = clear): ",
                    default = seed,
                }, function(input)
                    -- Cancelled (<esc>): leave the current view untouched.
                    if input == nil then
                        reopen(current)
                        return
                    end
                    input = vim.trim(input)
                    if input == "" then
                        reopen(nil)
                        return
                    end
                    local re = make(input)
                    if not re then
                        vim.notify("[Fzfkasten] could not build a query from " .. input,
                            vim.log.levels.WARN)
                        reopen(current)
                    else
                        reopen(re)
                    end
                end)
            end, 50)
        end,
        field_index = "{q}",
    }
end

--- `<alt-/>` for a picker that filters its own entries in Lua. `reopen(regex)`
--- must reopen the same picker keeping only entries `regex` (a `\m` Vim regex)
--- matches via `M.matches`; nil clears the filter. `current` is the active
--- filter, so cancelling or a failed query leaves it as-is.
function M.action(reopen, current)
    return input_action(M.regex, reopen, current)
end

--- `<alt-/>` for a content-search picker backed by ripgrep. `reopen(regex)` gets
--- an rg-compatible pattern (nil clears), to run as `rg <regex>`.
function M.grep_action(reopen, current)
    return input_action(M.rg_regex, reopen, current)
end

M._test = {
    backends = BACKENDS,
    reset_probe = function() probed = {} end,
}

return M
