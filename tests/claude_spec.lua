-- Tests for the configured-prompt plumbing (:FzfKastenClaudePrompt).
--
-- The interesting logic is prompt resolution -- name lookup and validation --
-- which is pure and lives in claude._test. The send path itself needs
-- claudecode.nvim, which isn't installed here; the completion condition is that
-- it degrades to a notify instead of erroring, so that path is only smoke-tested.

local config = require("fzfkasten.config")
local claude = require("fzfkasten.claude")
local t = claude._test

local function setup(claude_opts)
    config.setup({ home = "/tmp/fzfkasten-test", claude = claude_opts })
end

describe("resolve_prompt", function()
    local prompts = {
        retro = { note = "weekly", text = "/some-retro" },
        bare = { text = "hello" },
        blank = { text = "   " },
        notext = { note = "daily" },
        badnote = { note = "monthly", text = "x" },
    }

    it("returns a configured prompt by name", function()
        local p, err = t.resolve_prompt(prompts, "retro")
        assert.are.same(prompts.retro, p)
        assert.is_nil(err)
    end)

    it("accepts a prompt with no note (defaults to current)", function()
        local p, err = t.resolve_prompt(prompts, "bare")
        assert.are.same(prompts.bare, p)
        assert.is_nil(err)
    end)

    it("reports an empty name", function()
        local p, err = t.resolve_prompt(prompts, "")
        assert.is_nil(p)
        assert.are.equal("empty", err)
        assert.are.equal("empty", (select(2, t.resolve_prompt(prompts, nil))))
        assert.are.equal("empty", (select(2, t.resolve_prompt(prompts, "  "))))
    end)

    it("reports an unknown name", function()
        local p, err = t.resolve_prompt(prompts, "nope")
        assert.is_nil(p)
        assert.are.equal("unknown", err)
    end)

    it("rejects a prompt with missing or blank text", function()
        assert.are.equal("no-text", (select(2, t.resolve_prompt(prompts, "notext"))))
        assert.are.equal("no-text", (select(2, t.resolve_prompt(prompts, "blank"))))
    end)

    it("rejects an unknown note target", function()
        assert.are.equal("bad-note", (select(2, t.resolve_prompt(prompts, "badnote"))))
    end)

    it("accepts every valid note target", function()
        for note in pairs(t.VALID_NOTES) do
            local p = t.resolve_prompt({ p = { note = note, text = "x" } }, "p")
            assert.is_not_nil(p)
        end
    end)

    it("treats a nil prompts table as no prompts", function()
        assert.are.equal("unknown", (select(2, t.resolve_prompt(nil, "retro"))))
    end)
end)

describe("prompt_names", function()
    it("is empty when nothing is configured", function()
        setup({ enabled = true })
        assert.are.same({}, claude.prompt_names())
    end)

    it("lists configured names sorted", function()
        setup({ enabled = true, prompts = { zeta = { text = "z" }, alpha = { text = "a" } } })
        assert.are.same({ "alpha", "zeta" }, claude.prompt_names())
    end)

    it("works even when the integration is disabled", function()
        setup({ enabled = false, prompts = { one = { text = "1" } } })
        assert.are.same({ "one" }, claude.prompt_names())
    end)
end)

describe("send_prompt without claudecode", function()
    -- claudecode.nvim isn't installed in the test runtime, so guard() bows out
    -- with a notify. The point is that it never errors -- the "未導入環境で落ちない"
    -- completion condition.
    it("does not error when the integration is disabled", function()
        setup({ enabled = false, prompts = { retro = { text = "/x" } } })
        assert.has_no.errors(function() claude.send_prompt("retro") end)
    end)

    it("does not error when claudecode is absent but enabled", function()
        setup({ enabled = true, prompts = { retro = { text = "/x" } } })
        assert.has_no.errors(function() claude.send_prompt("retro") end)
    end)

    it("does not error on an unknown or empty name", function()
        setup({ enabled = true, prompts = {} })
        assert.has_no.errors(function() claude.send_prompt("nope") end)
        assert.has_no.errors(function() claude.send_prompt("") end)
    end)
end)
