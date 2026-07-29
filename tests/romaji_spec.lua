-- Romaji narrowing: choosing a backend, and what each one does.
--
-- Two programs can answer "what Japanese could `kaigi` be" -- `ttyskk migemo`
-- and kensaku.vim -- and neither is installed in CI, so both stand in here: a
-- shell script on disk for ttyskk, a real autoload script on the runtimepath
-- for kensaku (Vim refuses a `kensaku#query` definition anywhere else, E746,
-- and that is how kensaku arrives anyway: undefined until something calls it).
--
-- Standing them in is what lets these cases ask the questions that matter:
-- which backend gets picked, what reaches it, and what comes back when it
-- answers badly. It answers badly more often than it looks -- kensaku returns
-- "" until denops has started, so the first <alt-/> of a session goes through a
-- backend that is installed, callable and not ready. Every failure here has the
-- same shape as success from the outside: a picker with nothing in it. Nothing
-- narrowed and nothing matched are the same screen.

local config = require("fzfkasten.config")
local romaji = require("fzfkasten.romaji")

local function setup(opts)
    config.setup({ home = "/tmp/fzfkasten-romaji-test", romaji = opts or { backend = "auto" } })
    romaji._test.reset_probe()
end

-- kensaku ------------------------------------------------------------------

local kensaku_dir

local function install_kensaku(result, throw)
    vim.g.kensaku_test_result = result
    vim.g.kensaku_test_throw = throw and 1 or 0
    vim.g.kensaku_test_args = vim.NIL
    if kensaku_dir then return end

    kensaku_dir = vim.fn.tempname()
    vim.fn.mkdir(kensaku_dir .. "/autoload", "p")
    vim.fn.writefile({
        "function! kensaku#query(romaji, ...) abort",
        "  let g:kensaku_test_args = [a:romaji, a:0 ? a:1 : v:null]",
        "  if g:kensaku_test_throw",
        "    throw 'kensaku: denops is not ready'",
        "  endif",
        "  return g:kensaku_test_result",
        "endfunction",
    }, kensaku_dir .. "/autoload/kensaku.vim")
    vim.opt.rtp:prepend(kensaku_dir)
end

local function remove_kensaku()
    if kensaku_dir then
        vim.opt.rtp:remove(kensaku_dir)
        vim.fn.delete(kensaku_dir, "rf")
        kensaku_dir = nil
    end
    pcall(vim.cmd, "delfunction! kensaku#query")
end

local function kensaku_args()
    local args = vim.g.kensaku_test_args
    return args ~= vim.NIL and args or nil
end

-- ttyskk -------------------------------------------------------------------

-- A shell script standing in for the binary: it appends its arguments to
-- `args`, prints `stdout`, and exits with `code`. A case can then say what
-- ttyskk answered, and read back what it was asked.
local ttyskk_dir

local function install_ttyskk(stdout, code)
    if not ttyskk_dir then
        ttyskk_dir = vim.fn.tempname()
        vim.fn.mkdir(ttyskk_dir, "p")
        local script = ttyskk_dir .. "/ttyskk"
        vim.fn.writefile({
            "#!/bin/sh",
            'printf "%s\\n" "$*" >> ' .. vim.fn.shellescape(ttyskk_dir .. "/args"),
            "cat " .. vim.fn.shellescape(ttyskk_dir .. "/stdout") .. " 2>/dev/null",
            'exit "$(cat ' .. vim.fn.shellescape(ttyskk_dir .. "/code") .. ' 2>/dev/null || echo 0)"',
        }, script)
        vim.fn.setfperm(script, "rwxr-xr-x")
    end
    vim.fn.writefile(vim.split(stdout or "", "\n"), ttyskk_dir .. "/stdout")
    vim.fn.writefile({ tostring(code or 0) }, ttyskk_dir .. "/code")
    vim.fn.delete(ttyskk_dir .. "/args")
    return ttyskk_dir .. "/ttyskk"
end

local function remove_ttyskk()
    if ttyskk_dir then
        vim.fn.delete(ttyskk_dir, "rf")
        ttyskk_dir = nil
    end
end

-- Every command line the stand-in was called with, in order.
local function ttyskk_calls()
    local ok, lines = pcall(vim.fn.readfile, ttyskk_dir .. "/args")
    return ok and lines or {}
end

-- ...minus the availability probe, which every case triggers and none is about.
-- Always the first call: nothing reaches the backend without `available()`
-- having answered first, and it is only asked once.
local function ttyskk_queries()
    local calls = ttyskk_calls()
    if calls[1] then
        assert(calls[1]:match(" a$"), "expected a probe first, got: " .. calls[1])
        table.remove(calls, 1)
    end
    return calls
end

-- Deep, so that `extra` can set one ttyskk option without dropping `cmd` -- a
-- shallow merge here quietly pointed a case at the real binary on this machine.
local function with_ttyskk(stdout, code, extra)
    local cmd = install_ttyskk(stdout, code)
    setup(vim.tbl_deep_extend("force", { backend = "ttyskk", ttyskk = { cmd = cmd } }, extra or {}))
    return cmd
end

describe("the ttyskk backend", function()
    after_each(function()
        remove_ttyskk()
        remove_kensaku()
    end)

    it("is unavailable when the command is not there", function()
        setup({ backend = "ttyskk", ttyskk = { cmd = "/nonexistent/ttyskk" } })
        assert.is_false(romaji.available())
        assert.is_nil(romaji.regex("kaigi"))
    end)

    -- The binary existing is not the same as it knowing `migemo`; an older
    -- ttyskk is on plenty of machines, and it would advertise <alt-/> and then
    -- warn on every press.
    it("is unavailable when the command does not know migemo", function()
        with_ttyskk("", 1)
        assert.is_false(romaji.available())
    end)

    it("is available when migemo answers", function()
        with_ttyskk("(?:a|あ)")
        assert.is_true(romaji.available())
    end)

    it("hands back what migemo built", function()
        with_ttyskk("(?:kaigi|かいぎ|会議)")
        assert.are.equal("(?:kaigi|かいぎ|会議)", romaji.rg_regex("kaigi"))
    end)

    it("trims the trailing newline off the answer", function()
        with_ttyskk("(?:kaigi|会議)\n")
        assert.are.equal("(?:kaigi|会議)", romaji.rg_regex("kaigi"))
    end)

    -- The distinction the two functions exist for. ripgrep's engine reads
    -- `(?:...)` and `|`; Vim's `\%(...\)` and `\|` mean nothing to it, so a
    -- content search built with the wrong flavour matches nothing while the
    -- task picker, built from the same query, matches fine.
    it("asks for the flavour the caller needs", function()
        with_ttyskk("(?:x)")
        romaji.regex("kaigi")
        romaji.rg_regex("kaigi")
        assert.are.same({
            "migemo --flavour vim kaigi",
            "migemo --flavour rg kaigi",
        }, ttyskk_queries())
    end)

    it("passes a candidate limit when one is configured", function()
        with_ttyskk("(?:x)", 0, { ttyskk = { limit = 200 } })
        romaji.rg_regex("kaigi")
        assert.are.same({ "migemo --flavour rg --limit 200 kaigi" }, ttyskk_queries())
    end)

    it("leaves the limit to ttyskk when none is configured", function()
        with_ttyskk("(?:x)")
        romaji.rg_regex("kaigi")
        assert.are.same({ "migemo --flavour rg kaigi" }, ttyskk_queries())
    end)

    it("is nil for a query with nothing in it, without calling out", function()
        with_ttyskk("(?:x)")
        romaji.available() -- probe first, so an empty log below is the query's doing
        assert.is_nil(romaji.rg_regex(""))
        assert.is_nil(romaji.rg_regex("   "))
        assert.is_nil(romaji.rg_regex(nil))
        assert.are.same({}, ttyskk_queries())
    end)

    -- A non-zero exit is ttyskk saying it could not build one -- no dictionary,
    -- a flavour it does not know. Treating whatever it printed as a regex would
    -- filter every entry out of the picker.
    it("is nil when migemo fails", function()
        with_ttyskk("(?:a|あ)")
        assert.is_true(romaji.available())
        vim.fn.writefile({ "1" }, ttyskk_dir .. "/code")
        assert.is_nil(romaji.rg_regex("kaigi"))
    end)

    it("is nil when migemo answers with nothing", function()
        with_ttyskk("(?:a|あ)")
        assert.is_true(romaji.available())
        vim.fn.writefile({ "" }, ttyskk_dir .. "/stdout")
        assert.is_nil(romaji.rg_regex("kaigi"))
    end)

    -- Asked on every picker open, so it is remembered rather than re-run.
    it("asks whether migemo works only once", function()
        with_ttyskk("(?:a|あ)")
        romaji.available()
        romaji.available()
        romaji.available()
        assert.are.equal(1, #ttyskk_calls())
    end)

    it("asks again when the command is changed", function()
        with_ttyskk("(?:a|あ)")
        romaji.available()
        setup({ backend = "ttyskk", ttyskk = { cmd = "/nonexistent/ttyskk" } })
        assert.is_false(romaji.available())
    end)
end)

describe("the kensaku backend", function()
    after_each(function()
        remove_kensaku()
        remove_ttyskk()
    end)

    local function with_kensaku(result, throw)
        install_kensaku(result, throw)
        setup({ backend = "kensaku" })
    end

    it("is unavailable when kensaku is not installed", function()
        setup({ backend = "kensaku" })
        assert.is_false(romaji.available())
        assert.is_nil(romaji.regex("kaigi"))
    end)

    -- `exists('*kensaku#query')` is false until the autoload script has run
    -- once, so looking only for the function would hide the filter from someone
    -- who has kensaku installed until they had already used it.
    it("is available when only the autoload script is on the runtimepath", function()
        with_kensaku("かいぎ")
        assert.are.equal(0, vim.fn.exists("*kensaku#query"))
        assert.is_true(romaji.available())
    end)

    it("hands back what kensaku built", function()
        with_kensaku([[\m\%(かいぎ\|会議\)]])
        assert.are.equal([[\m\%(かいぎ\|会議\)]], romaji.regex("kaigi"))
    end)

    it("trims the query before kensaku sees it", function()
        with_kensaku("かいぎ")
        romaji.regex("  kaigi  ")
        assert.are.equal("kaigi", kensaku_args()[1])
    end)

    -- Denops not started yet. Returning "" as if it were a regex would filter
    -- every entry out of the picker.
    it("is nil when kensaku answers with an empty string", function()
        with_kensaku("")
        assert.is_nil(romaji.regex("kaigi"))
    end)

    it("is nil when kensaku answers with something that is not a string", function()
        with_kensaku({ "かいぎ" })
        assert.is_nil(romaji.regex("kaigi"))
    end)

    it("is nil, not an error, when kensaku throws", function()
        with_kensaku("かいぎ", true)
        assert.is_nil(romaji.regex("kaigi"))
    end)

    -- The Vim flavour is kensaku's default, so that call passes no flavour at
    -- all -- which is what tells it apart from the rg one.
    it("asks for the Vim flavour by asking for no flavour", function()
        with_kensaku("かいぎ")
        romaji.regex("kaigi")
        assert.are.equal(vim.NIL, kensaku_args()[2])
    end)

    it("asks for the flavour ripgrep understands", function()
        with_kensaku("(?:かいぎ)")
        romaji.rg_regex("kaigi")
        local rxop = kensaku_args()[2].rxop
        assert.are.equal("|", rxop["or"])
        assert.are.equal("(?:", rxop.startGroup)
        assert.are.equal(")", rxop.endGroup)
        assert.are.equal("[", rxop.startClass)
        assert.are.equal("]", rxop.endClass)
        assert.are.equal("", rxop.newline)
        assert.are.equal("\\.[]{}()*+-?^$|", rxop.escape)
    end)
end)

describe("choosing a backend", function()
    after_each(function()
        remove_ttyskk()
        remove_kensaku()
    end)

    -- ttyskk first because it costs nothing beyond itself, where kensaku brings
    -- Deno and a dictionary download. Both answer the same question, so on a
    -- machine with both this preference is the whole difference.
    it("prefers ttyskk when both are there", function()
        local cmd = install_ttyskk("(?:a|あ)")
        install_kensaku("かいぎ")
        setup({ backend = "auto", ttyskk = { cmd = cmd } })
        assert.are.equal("ttyskk", romaji.backend_name())
    end)

    it("falls back to kensaku when ttyskk is not there", function()
        install_kensaku("かいぎ")
        setup({ backend = "auto", ttyskk = { cmd = "/nonexistent/ttyskk" } })
        assert.are.equal("kensaku", romaji.backend_name())
    end)

    it("has no backend when neither is there", function()
        setup({ backend = "auto", ttyskk = { cmd = "/nonexistent/ttyskk" } })
        assert.is_nil(romaji.backend_name())
        assert.is_false(romaji.available())
    end)

    it("uses the one it is told to, even when the other is there", function()
        local cmd = install_ttyskk("(?:a|あ)")
        install_kensaku("かいぎ")
        setup({ backend = "kensaku", ttyskk = { cmd = cmd } })
        assert.are.equal("kensaku", romaji.backend_name())
    end)

    -- Pinning a backend that is not installed means no narrowing, not a quiet
    -- switch to the other one: being asked for ttyskk and answering with Deno
    -- is not what was asked for.
    it("does not fall back from a backend it was told to use", function()
        install_kensaku("かいぎ")
        setup({ backend = "ttyskk", ttyskk = { cmd = "/nonexistent/ttyskk" } })
        assert.is_nil(romaji.backend_name())
    end)

    -- Off is a setting, not a mistake: it has to be silent. Falling through to
    -- the unknown-name path below would give the same empty result with a
    -- warning about `false` attached to it.
    it("turns the whole thing off when told false, and says nothing about it", function()
        local warnings = {}
        local notify = vim.notify
        vim.notify = function(msg, level)
            if level == vim.log.levels.WARN then warnings[#warnings + 1] = msg end
        end
        local cmd = install_ttyskk("(?:a|あ)")
        setup({ backend = false, ttyskk = { cmd = cmd } })
        local available, re, header = romaji.available(), romaji.regex("kaigi"), romaji.header_hint(nil)
        vim.notify = notify

        assert.is_false(available)
        assert.is_nil(re)
        assert.is_nil(header)
        assert.are.same({}, warnings)
    end)

    it("takes a backend of your own", function()
        setup({ backend = {
            name = "mine",
            available = function() return true end,
            regex = function(q) return "\\m" .. q end,
            rg_regex = function(q) return "rg:" .. q end,
        } })
        assert.are.equal("mine", romaji.backend_name())
        assert.are.equal("\\mkaigi", romaji.regex("kaigi"))
        assert.are.equal("rg:kaigi", romaji.rg_regex("kaigi"))
    end)

    it("ignores a backend of your own that says it cannot answer", function()
        setup({ backend = {
            name = "mine",
            available = function() return false end,
            regex = function() return "x" end,
            rg_regex = function() return "x" end,
        } })
        assert.is_false(romaji.available())
    end)

    it("says so rather than guessing when the name means nothing", function()
        local warnings = {}
        local notify = vim.notify
        vim.notify = function(msg, level)
            if level == vim.log.levels.WARN then warnings[#warnings + 1] = msg end
        end
        install_kensaku("かいぎ")
        setup({ backend = "migemo" })
        local available = romaji.available()
        vim.notify = notify
        assert.is_false(available)
        assert.is_truthy(warnings[1] and warnings[1]:find("migemo", 1, true))
    end)
end)

describe("matches", function()
    -- An unfiltered picker guards every entry with this too, so "no filter"
    -- has to mean "keep it" rather than "keep nothing".
    it("keeps everything when there is no filter", function()
        assert.is_true(romaji.matches("会議録", nil))
        assert.is_true(romaji.matches("会議録", ""))
        assert.is_true(romaji.matches("", nil))
    end)

    it("keeps what the filter matches", function()
        assert.is_true(romaji.matches("2026-07-29 会議録", [[\m\%(かいぎ\|会議\)]]))
        assert.is_true(romaji.matches("かいぎのメモ", [[\m\%(かいぎ\|会議\)]]))
    end)

    it("drops what it does not", function()
        assert.is_false(romaji.matches("買い物リスト", [[\m\%(かいぎ\|会議\)]]))
    end)
end)

describe("header_hint", function()
    after_each(remove_kensaku)

    -- Advertising a key that only warns is worse than not advertising it.
    it("says nothing when no backend is available", function()
        setup({ backend = "auto", ttyskk = { cmd = "/nonexistent/ttyskk" } })
        assert.is_nil(romaji.header_hint(nil))
        assert.are.equal("", romaji.header_hint(""))
        assert.are.equal("<ctrl-x> done", romaji.header_hint("<ctrl-x> done"))
    end)

    it("is the whole header when there was none", function()
        install_kensaku("かいぎ")
        setup({ backend = "kensaku" })
        assert.are.equal("<alt-/> romaji", romaji.header_hint(nil))
        assert.are.equal("<alt-/> romaji", romaji.header_hint(""))
    end)

    it("is appended to a header there already is", function()
        install_kensaku("かいぎ")
        setup({ backend = "kensaku" })
        assert.are.equal("<ctrl-x> done   <alt-/> romaji", romaji.header_hint("<ctrl-x> done"))
    end)
end)

describe("prompt", function()
    -- A filtered list is short, and a short list looks like a complete one.
    it("flags an active filter", function()
        assert.are.equal("Notes (romaji)> ", romaji.prompt("Notes", [[\mかいぎ]]))
    end)

    it("says nothing without one", function()
        assert.are.equal("Notes> ", romaji.prompt("Notes", nil))
        assert.are.equal("Notes> ", romaji.prompt("Notes", ""))
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
        remove_ttyskk()
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

    local function with_kensaku(result)
        install_kensaku(result)
        setup({ backend = "kensaku" })
    end

    it("seeds the prompt with what was typed in the picker", function()
        with_kensaku("かいぎ")
        answer(nil)
        fire(romaji.action(reopen, CURRENT), { "kaigi" })
        assert.are.equal("kaigi", asked[1].default)
    end)

    it("takes the picker's query as its seed", function()
        assert.are.equal("{q}", romaji.action(reopen, nil).field_index)
        assert.are.equal("{q}", romaji.grep_action(reopen, nil).field_index)
    end)

    it("filters by what the backend built", function()
        with_kensaku([[\m\%(かいぎ\|会議\)]])
        answer("kaigi")
        fire(romaji.action(reopen, nil))
        assert.are.same({ [[\m\%(かいぎ\|会議\)]] }, reopened)
    end)

    -- Blank clears and <esc> keeps: two ways out of the same prompt that must
    -- not be conflated, since one of them throws away the filter you had.
    it("clears the filter on a blank query", function()
        with_kensaku("かいぎ")
        answer("   ")
        fire(romaji.action(reopen, CURRENT))
        assert.are.same({ "<nil>" }, reopened)
    end)

    it("leaves the filter alone when the prompt is cancelled", function()
        with_kensaku("かいぎ")
        answer(nil)
        fire(romaji.action(reopen, CURRENT))
        assert.are.same({ CURRENT }, reopened)
        assert.are.same({}, warnings)
    end)

    -- Denops not ready, most likely. Reopening unchanged is the point: the
    -- alternative is a picker filtered by nothing that shows nothing.
    it("says so and keeps the view when the backend cannot build a query", function()
        with_kensaku("")
        answer("kaigi")
        fire(romaji.action(reopen, CURRENT))
        assert.are.same({ CURRENT }, reopened)
        assert.are.equal(1, #warnings)
        assert.is_truthy(warnings[1]:find("kaigi", 1, true))
    end)

    it("says so and asks nothing when no backend is available", function()
        setup({ backend = "auto", ttyskk = { cmd = "/nonexistent/ttyskk" } })
        answer("kaigi")
        fire(romaji.action(reopen, CURRENT))
        assert.are.same({ CURRENT }, reopened)
        assert.are.same({}, asked)
        assert.are.equal(1, #warnings)
    end)

    -- The one difference between the two actions, and the one that decides
    -- whether a content search finds anything.
    it("builds an rg pattern for the grep action, a Vim one for the other", function()
        local cmd = install_ttyskk("(?:a|あ)")
        setup({ backend = "ttyskk", ttyskk = { cmd = cmd } })
        answer("kaigi")
        fire(romaji.grep_action(reopen, nil))
        reopened = {}
        answer("kaigi")
        fire(romaji.action(reopen, nil))
        assert.are.same({
            "migemo --flavour rg kaigi",
            "migemo --flavour vim kaigi",
        }, ttyskk_queries())
    end)
end)
