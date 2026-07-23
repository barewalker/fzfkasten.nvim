-- Romaji narrowing for fzf pickers, via kensaku.vim (an optional dependency).
--
-- fzf matches on the literal query, so a Japanese list can only be narrowed by
-- typing Japanese. kensaku turns a romaji query into a regex over the Japanese
-- text; this module wraps that into a picker-agnostic `<alt-/>` action plus the
-- small helpers a picker needs to filter its own entries and label itself.
--
-- The pattern every caller follows: keep a `filter` (a `\m` Vim regex or nil) in
-- the picker's own state, drop entries that do not match it, and rebuild the
-- picker with a new `filter` when `<alt-/>` fires. Nothing here reaches into a
-- picker; a caller passes a `reopen(regex)` that reopens itself.
local M = {}

-- kensaku installed? `exists('*kensaku#query')` only sees the function after its
-- autoload script has run once, so also look for that script on runtimepath --
-- otherwise a fresh session hides the filter until kensaku is first used.
function M.available()
    return vim.fn.exists("*kensaku#query") == 1
        or vim.fn.globpath(vim.o.runtimepath, "autoload/kensaku.vim") ~= ""
end

-- Turn a romaji query into a `\m` Vim regex, or nil when there is nothing to
-- match on (blank input, kensaku absent, or denops not ready yet -- the vim
-- wrapper returns "" until it is). Safe to call without checking availability.
-- Use this for filtering entries in Lua with `M.matches` (`vim.fn.match`).
function M.regex(romaji)
    romaji = vim.trim(romaji or "")
    if romaji == "" or not M.available() then return nil end
    local ok, re = pcall(vim.fn["kensaku#query"], romaji)
    if ok and type(re) == "string" and re ~= "" then return re end
    return nil
end

-- Turn a romaji query into a ripgrep-compatible regex, or nil. kensaku's
-- JavaScript flavour (`(?:...)`, `|`, classes) is what ripgrep's Rust engine
-- understands; the Vim flavour above is not. `eval` on the flavour global also
-- triggers its autoload script, which a bare `vim.g` access would not. Use this
-- when the query is fed to `rg` (content search), not matched in Lua.
function M.rg_regex(romaji)
    romaji = vim.trim(romaji or "")
    if romaji == "" or not M.available() then return nil end
    local ok_rxop, rxop = pcall(vim.fn.eval, "g:kensaku#rxop#javascript")
    if not ok_rxop then return nil end
    local ok, re = pcall(vim.fn["kensaku#query"], romaji, { rxop = rxop })
    if ok and type(re) == "string" and re ~= "" then return re end
    return nil
end

-- Does `text` match the filter? A nil/empty filter matches everything, so a
-- caller can guard every entry with this and let an unfiltered picker fall
-- straight through.
function M.matches(text, re)
    if not re or re == "" then return true end
    return vim.fn.match(text, re) >= 0
end

-- Append the `<alt-/>` hint to an fzf `--header`, but only when kensaku is
-- there to honour it, so the header never advertises a key that just warns.
function M.header_hint(header)
    if not M.available() then return header end
    if header == nil or header == "" then return "<alt-/> romaji" end
    return header .. "   <alt-/> romaji"
end

-- A picker prompt that flags an active romaji filter, so a short list reads as
-- "filtered" rather than "all there is". `label` is the bare name ("Notes").
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
local function input_action(build, reopen, current)
    return {
        fn = function(selected)
            local seed = (selected and selected[1]) or ""
            vim.defer_fn(function()
                if not M.available() then
                    vim.notify("[Fzfkasten] kensaku.vim is not available.",
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
                    local re = build(input)
                    if not re then
                        vim.notify("[Fzfkasten] kensaku could not build a query "
                            .. "from " .. input, vim.log.levels.WARN)
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

-- `<alt-/>` for a picker that filters its own entries in Lua. `reopen(regex)`
-- must reopen the same picker keeping only entries `regex` (a `\m` Vim regex)
-- matches via `M.matches`; nil clears the filter. `current` is the active
-- filter, so cancelling or a failed query leaves it as-is.
function M.action(reopen, current)
    return input_action(M.regex, reopen, current)
end

-- `<alt-/>` for a content-search picker backed by ripgrep. `reopen(regex)` gets
-- an rg-compatible pattern (nil clears), to run as `rg <regex>`.
function M.grep_action(reopen, current)
    return input_action(M.rg_regex, reopen, current)
end

return M
