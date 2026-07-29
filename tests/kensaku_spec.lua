-- Romaji narrowing: the `<alt-/>` filter, and the pieces around kensaku.vim.
--
-- kensaku is optional and is not installed here or in CI, so the cases that
-- need it stand in a Vim function of their own named `kensaku#query`. That is
-- what `available()` looks for, and standing in for it is what lets these cases
-- ask the questions that matter: what reaches kensaku, and what comes back when
-- it answers badly.
--
-- It answers badly more often than it looks. The wrapper returns "" until
-- denops has started, so the first `<alt-/>` of a session goes through a
-- kensaku that is installed, callable, and not ready -- and every failure here
-- has the same shape as success from the outside: a picker with nothing in it.
-- Nothing narrowed and nothing matched are the same screen.

local kensaku = require("fzfkasten.kensaku")

-- Stand in for kensaku#query. `result` is what it returns; `throw` makes it
-- fail the way a broken kensaku would, which `M.regex` has to survive.
--
-- Written as a real autoload script on the runtimepath, since Vim refuses to
-- define an autoloaded name anywhere else (E746) -- which suits these cases:
-- that is how kensaku itself arrives, undefined until something calls it.
local stub_dir

local function install_kensaku(result, throw)
    vim.g.kensaku_test_result = result
    vim.g.kensaku_test_throw = throw and 1 or 0
    vim.g.kensaku_test_args = vim.NIL
    if stub_dir then return end

    stub_dir = vim.fn.tempname()
    vim.fn.mkdir(stub_dir .. "/autoload", "p")
    vim.fn.writefile({
        "function! kensaku#query(romaji, ...) abort",
        "  let g:kensaku_test_args = [a:romaji, a:0 ? a:1 : v:null]",
        "  if g:kensaku_test_throw",
        "    throw 'kensaku: denops is not ready'",
        "  endif",
        "  return g:kensaku_test_result",
        "endfunction",
    }, stub_dir .. "/autoload/kensaku.vim")
    vim.opt.rtp:prepend(stub_dir)
end

local function remove_kensaku()
    if stub_dir then
        vim.opt.rtp:remove(stub_dir)
        vim.fn.delete(stub_dir, "rf")
        stub_dir = nil
    end
    pcall(vim.cmd, "delfunction! kensaku#query")
end

local function query_args()
    local args = vim.g.kensaku_test_args
    return args ~= vim.NIL and args or nil
end

describe("available", function()
    after_each(remove_kensaku)

    -- The state every case that follows assumes: neither the function nor the
    -- autoload script is anywhere on this runtimepath.
    it("is false with kensaku nowhere in sight", function()
        assert.is_false(kensaku.available())
    end)

    it("is true once the function exists", function()
        install_kensaku("かいぎ")
        kensaku.regex("kaigi") -- calling it is what loads the autoload script
        assert.are.equal(1, vim.fn.exists("*kensaku#query"))
        assert.is_true(kensaku.available())
    end)

    -- The second half of the check, and the reason it is there:
    -- `exists('*kensaku#query')` is false until the autoload script has run
    -- once, so a fresh session would hide the filter from someone who has
    -- kensaku installed until they had already used it.
    it("is true when only the autoload script is on the runtimepath", function()
        install_kensaku("かいぎ")
        assert.are.equal(0, vim.fn.exists("*kensaku#query"))
        assert.is_true(kensaku.available())
    end)
end)

describe("regex", function()
    after_each(remove_kensaku)

    it("is nil when kensaku is not installed", function()
        assert.is_nil(kensaku.regex("kaigi"))
    end)

    it("is nil for a query with nothing in it", function()
        install_kensaku("かいぎ")
        assert.is_nil(kensaku.regex(""))
        assert.is_nil(kensaku.regex("   "))
        assert.is_nil(kensaku.regex(nil))
    end)

    it("hands back what kensaku built", function()
        install_kensaku([[\m\%(かいぎ\|会議\)]])
        assert.are.equal([[\m\%(かいぎ\|会議\)]], kensaku.regex("kaigi"))
    end)

    it("trims the query before kensaku sees it", function()
        install_kensaku("かいぎ")
        kensaku.regex("  kaigi  ")
        assert.are.equal("kaigi", query_args()[1])
    end)

    -- Denops not started yet. Returning "" as if it were a regex would filter
    -- every entry out of the picker.
    it("is nil when kensaku answers with an empty string", function()
        install_kensaku("")
        assert.is_nil(kensaku.regex("kaigi"))
    end)

    it("is nil when kensaku answers with something that is not a string", function()
        install_kensaku({ "かいぎ" })
        assert.is_nil(kensaku.regex("kaigi"))
    end)

    it("is nil, not an error, when kensaku throws", function()
        install_kensaku("かいぎ", true)
        assert.is_nil(kensaku.regex("kaigi"))
    end)

    -- The Vim flavour is kensaku's default, so this call passes no flavour at
    -- all -- which is what tells it apart from rg_regex below.
    it("asks for the Vim flavour by asking for no flavour", function()
        install_kensaku("かいぎ")
        kensaku.regex("kaigi")
        assert.are.equal(vim.NIL, query_args()[2])
    end)
end)

describe("rg_regex", function()
    after_each(remove_kensaku)

    it("is nil when kensaku is not installed", function()
        assert.is_nil(kensaku.rg_regex("kaigi"))
    end)

    it("is nil for a query with nothing in it", function()
        install_kensaku("(?:かいぎ|会議)")
        assert.is_nil(kensaku.rg_regex(""))
        assert.is_nil(kensaku.rg_regex("   "))
    end)

    it("hands back what kensaku built", function()
        install_kensaku("(?:かいぎ|会議)")
        assert.are.equal("(?:かいぎ|会議)", kensaku.rg_regex("kaigi"))
    end)

    it("is nil when kensaku is not ready or fails", function()
        install_kensaku("")
        assert.is_nil(kensaku.rg_regex("kaigi"))
        install_kensaku("(?:かいぎ)", true)
        assert.is_nil(kensaku.rg_regex("kaigi"))
    end)

    -- The distinction the two functions exist for. ripgrep's engine reads
    -- `(?:...)` and `|`; Vim's `\%(...\)` and `\|` mean nothing to it, so a
    -- content search built with the Vim flavour matches nothing while the task
    -- picker, built with the same query, matches fine.
    it("asks for the flavour ripgrep understands", function()
        install_kensaku("(?:かいぎ)")
        kensaku.rg_regex("kaigi")
        local rxop = query_args()[2].rxop
        assert.are.equal("|", rxop["or"])
        assert.are.equal("(?:", rxop.startGroup)
        assert.are.equal(")", rxop.endGroup)
        assert.are.equal("[", rxop.startClass)
        assert.are.equal("]", rxop.endClass)
        assert.are.equal("", rxop.newline)
        assert.are.equal("\\.[]{}()*+-?^$|", rxop.escape)
    end)
end)

describe("matches", function()
    -- An unfiltered picker guards every entry with this too, so "no filter"
    -- has to mean "keep it" rather than "keep nothing".
    it("keeps everything when there is no filter", function()
        assert.is_true(kensaku.matches("会議録", nil))
        assert.is_true(kensaku.matches("会議録", ""))
        assert.is_true(kensaku.matches("", nil))
    end)

    it("keeps what the filter matches", function()
        assert.is_true(kensaku.matches("2026-07-29 会議録", [[\m\%(かいぎ\|会議\)]]))
        assert.is_true(kensaku.matches("かいぎのメモ", [[\m\%(かいぎ\|会議\)]]))
    end)

    it("drops what it does not", function()
        assert.is_false(kensaku.matches("買い物リスト", [[\m\%(かいぎ\|会議\)]]))
    end)
end)

describe("header_hint", function()
    after_each(remove_kensaku)

    -- Advertising a key that only warns is worse than not advertising it.
    it("says nothing when kensaku is not installed", function()
        assert.is_nil(kensaku.header_hint(nil))
        assert.are.equal("", kensaku.header_hint(""))
        assert.are.equal("<ctrl-x> done", kensaku.header_hint("<ctrl-x> done"))
    end)

    it("is the whole header when there was none", function()
        install_kensaku("")
        assert.are.equal("<alt-/> romaji", kensaku.header_hint(nil))
        assert.are.equal("<alt-/> romaji", kensaku.header_hint(""))
    end)

    it("is appended to a header there already is", function()
        install_kensaku("")
        assert.are.equal("<ctrl-x> done   <alt-/> romaji", kensaku.header_hint("<ctrl-x> done"))
    end)
end)

describe("prompt", function()
    -- A filtered list is short, and a short list looks like a complete one.
    it("flags an active filter", function()
        assert.are.equal("Notes (romaji)> ", kensaku.prompt("Notes", [[\mかいぎ]]))
    end)

    it("says nothing without one", function()
        assert.are.equal("Notes> ", kensaku.prompt("Notes", nil))
        assert.are.equal("Notes> ", kensaku.prompt("Notes", ""))
    end)
end)

describe("the <alt-/> action", function()
    local ui_input, notify
    local asked, reopened, warnings

    before_each(function()
        asked, reopened, warnings = {}, {}, {}
        ui_input = vim.ui.input
        notify = vim.notify
        vim.notify = function(msg, level)
            if level == vim.log.levels.WARN then
                warnings[#warnings + 1] = msg
            end
        end
    end)

    after_each(function()
        vim.ui.input = ui_input
        vim.notify = notify
        remove_kensaku()
    end)

    -- Answer the next prompt with `reply`; nil is <esc>.
    local function answer(reply)
        vim.ui.input = function(opts, on_confirm)
            asked[#asked + 1] = opts
            on_confirm(reply)
        end
    end

    local function reopen(re)
        reopened[#reopened + 1] = re or "<nil>"
    end

    -- The action steps out to a real `vim.ui.input`, so it waits for the picker
    -- to finish closing before opening one -- opening mid-teardown races it.
    local function fire(action, selected)
        action.fn(selected or { "" })
        vim.wait(2000, function() return #reopened > 0 end)
    end

    local CURRENT = [[\mいま]]

    it("seeds the prompt with what was typed in the picker", function()
        install_kensaku("かいぎ")
        answer(nil)
        fire(kensaku.action(reopen, CURRENT), { "kaigi" })
        assert.are.equal("kaigi", asked[1].default)
    end)

    it("takes the picker's query as its seed", function()
        assert.are.equal("{q}", kensaku.action(reopen, nil).field_index)
        assert.are.equal("{q}", kensaku.grep_action(reopen, nil).field_index)
    end)

    it("filters by what kensaku built", function()
        install_kensaku([[\m\%(かいぎ\|会議\)]])
        answer("kaigi")
        fire(kensaku.action(reopen, nil))
        assert.are.same({ [[\m\%(かいぎ\|会議\)]] }, reopened)
    end)

    -- Blank clears and <esc> keeps: two ways out of the same prompt that must
    -- not be conflated, since one of them throws away the filter you had.
    it("clears the filter on a blank query", function()
        install_kensaku("かいぎ")
        answer("   ")
        fire(kensaku.action(reopen, CURRENT))
        assert.are.same({ "<nil>" }, reopened)
    end)

    it("leaves the filter alone when the prompt is cancelled", function()
        install_kensaku("かいぎ")
        answer(nil)
        fire(kensaku.action(reopen, CURRENT))
        assert.are.same({ CURRENT }, reopened)
        assert.are.same({}, warnings)
    end)

    -- Denops not ready, most likely. Reopening unchanged is the point: the
    -- alternative is a picker filtered by nothing that shows nothing.
    it("says so and keeps the view when kensaku cannot build a query", function()
        install_kensaku("")
        answer("kaigi")
        fire(kensaku.action(reopen, CURRENT))
        assert.are.same({ CURRENT }, reopened)
        assert.are.equal(1, #warnings)
        assert.is_truthy(warnings[1]:find("kaigi", 1, true))
    end)

    it("says so and asks nothing when kensaku is not installed", function()
        answer("kaigi")
        fire(kensaku.action(reopen, CURRENT))
        assert.are.same({ CURRENT }, reopened)
        assert.are.same({}, asked)
        assert.are.equal(1, #warnings)
    end)

    -- The one difference between the two actions, and the one that decides
    -- whether a content search finds anything.
    it("builds an rg pattern for the grep action, a Vim one for the other", function()
        install_kensaku("(?:かいぎ)")
        answer("kaigi")
        fire(kensaku.grep_action(reopen, nil))
        assert.is_truthy(query_args()[2].rxop)

        reopened = {}
        install_kensaku("かいぎ")
        answer("kaigi")
        fire(kensaku.action(reopen, nil))
        assert.are.equal(vim.NIL, query_args()[2])
    end)
end)
