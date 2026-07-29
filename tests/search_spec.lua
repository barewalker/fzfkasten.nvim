-- Content search, and the ripgrep command it ends up running.
--
-- `fzf.live_grep` builds that command from `rg_opts`, and setting `cmd`
-- replaces the whole command line rather than just naming the binary -- so a
-- bare `cmd = "rg"` silently threw those options away. fzf-lua patched
-- `--line-number` and `--column` back in and said so, twice, every time the
-- picker opened; the rest it did not patch, and nothing said anything:
--
--   --smart-case        `readme` stopped finding README (0 lines, not 3)
--   -e                  a query beginning with `-` was read as a flag
--   --color=always      no match highlighting
--   --max-columns=4096  one minified line could swamp the list
--
-- Which is the shape of failure worth a test: the picker still opened, still
-- searched, and still found things -- just not the things it used to.

local config = require("fzfkasten.config")
local pickers = require("fzfkasten.pickers")
local fzf = require("fzf-lua")

local home

-- Stand in for whichever fzf-lua entry point the picker reaches, and build the
-- command the way fzf-lua would, so the assertions are about what ripgrep is
-- actually run with rather than about the options table.
local function capture(filter)
    local seen = {}
    local live_grep, grep, notify = fzf.live_grep, fzf.grep, vim.notify

    local function record(opts)
        seen.opts = opts
        local ok, normalized = pcall(require("fzf-lua.config").normalize_opts, opts, "grep")
        if ok then
            seen.normalized = normalized
            local built, cmd = pcall(require("fzf-lua.make_entry").get_grep_cmd,
                normalized, normalized.search or "", true)
            seen.cmd = built and cmd or nil
        end
    end

    seen.messages = {}
    vim.notify = function(msg) seen.messages[#seen.messages + 1] = tostring(msg) end
    fzf.live_grep, fzf.grep = record, record
    pcall(pickers.search_content, filter)
    fzf.live_grep, fzf.grep, vim.notify = live_grep, grep, notify
    return seen
end

describe("search_content", function()
    before_each(function()
        home = vim.fn.tempname()
        vim.fn.mkdir(home, "p")
        vim.fn.writefile({ "# README", "会議の記録" }, home .. "/note.md")
        config.setup({ home = home, romaji = { backend = false } })
    end)

    after_each(function()
        if home then
            vim.fn.delete(home, "rf")
            home = nil
        end
    end)

    -- The defect itself, stated in the form that caused it. Naming the binary
    -- here replaces the entire command line.
    it("does not override the whole ripgrep command line", function()
        assert.is_nil(capture(nil).opts.cmd)
        assert.is_nil(capture([[\m\%(かいぎ\)]]).opts.cmd)
    end)

    -- ...and what that costs when it happens. `readme` finding README is the
    -- one a reader will recognise.
    it("searches case-insensitively for a lowercase query", function()
        local cmd = capture(nil).cmd
        assert.is_truthy(cmd, "fzf-lua did not build a command")
        assert.is_truthy(cmd:find("--smart-case", 1, true), cmd)
    end)

    it("passes the query as a pattern, so a leading dash is not a flag", function()
        local cmd = capture(nil).cmd
        assert.is_truthy(cmd:find(" -e ", 1, true), cmd)
    end)

    it("keeps the rest of fzf-lua's ripgrep options", function()
        local cmd = capture(nil).cmd
        for _, flag in ipairs({ "--no-heading", "--color=always", "--max-columns=4096" }) do
            assert.is_truthy(cmd:find(flag, 1, true), flag .. " missing from: " .. cmd)
        end
    end)

    -- The visible symptom, and the reason this was noticed at all: two lines of
    -- "[Fzf-lua] Added missing ..." before you had typed anything.
    it("opens without fzf-lua having to patch the command", function()
        local messages = capture(nil).messages
        for _, msg in ipairs(messages) do
            assert.is_nil(msg:find("Added missing", 1, true),
                "fzf-lua patched the command: " .. msg)
        end
    end)

    -- The filtered branch greps for a pattern the romaji backend already built,
    -- so it must not be escaped again on the way in.
    it("greps the romaji pattern as a pattern", function()
        local seen = capture([[\m\%(かいぎ\|会議\)]])
        assert.are.equal([[\m\%(かいぎ\|会議\)]], seen.opts.search)
        assert.is_true(seen.opts.no_esc)
    end)

    it("searches the notes directory, not the working directory", function()
        assert.are.equal(home, capture(nil).opts.cwd)
        assert.are.equal(home, capture([[\mか]]).opts.cwd)
    end)
end)
