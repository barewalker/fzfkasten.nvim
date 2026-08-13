-- Tests for the Claude-pane plumbing (:FzfKastenClaude*).
--
-- What is worth pinning is everything decided before a byte leaves the editor:
-- which prompt was named, how a note is named to a pane on another machine, and
-- what argv each multiplexer is driven with. That is all pure and lives in
-- claude._test. The sending itself needs a running herdr or tmux, which the
-- test runtime has neither of; the completion condition there is that it
-- degrades to a notify instead of erroring, so that path is only smoke-tested.

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

    it("accepts a prompt with no note (names no note)", function()
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

describe("mention", function()
    it("names a path Claude can attach with @", function()
        assert.are.equal("@/notes/2026-W33.md", t.mention("/notes/2026-W33.md"))
    end)

    it("quotes a path with spaces instead, since @ ends at the first one", function()
        assert.are.equal('"/notes/1on1 Aimoto.md"', t.mention("/notes/1on1 Aimoto.md"))
    end)
end)

describe("map_path", function()
    local home = "/home/me/zettelkasten"

    it("leaves the path alone when both machines agree on it", function()
        assert.are.equal(home .. "/a.md", t.map_path(home .. "/a.md", home, nil))
        assert.are.equal(home .. "/a.md", t.map_path(home .. "/a.md", home, home))
    end)

    it("swaps the collection root for the one on the other machine", function()
        assert.are.equal("/srv/notes/sub/a.md",
            t.map_path(home .. "/sub/a.md", home, "/srv/notes"))
        assert.are.equal("/srv/notes", t.map_path(home, home, "/srv/notes"))
    end)

    it("refuses a file outside the collection, which has no copy over there", function()
        assert.is_nil(t.map_path("/etc/hosts", home, "/srv/notes"))
        -- A sibling directory that merely starts with the same name is outside.
        assert.is_nil(t.map_path(home .. "-old/a.md", home, "/srv/notes"))
    end)
end)

describe("over_ssh", function()
    it("runs the command here when no host is set", function()
        local argv = { "herdr", "pane", "send-text", "w1:p2", "hello" }
        assert.are.same(argv, t.over_ssh(nil, argv))
        assert.are.same(argv, t.over_ssh("", argv))
    end)

    it("hands the far shell one string, quoted to survive it", function()
        local got = t.over_ssh("nuc", { "herdr", "pane", "send-text", "w1:p2", "a b 'c' $HOME" })
        assert.are.equal("ssh", got[1])
        assert.are.equal("nuc", got[2])
        -- The text must arrive whole and unexpanded: it is a prompt, not a
        -- command, and prompts have spaces, quotes and dollars in them.
        local quoted = vim.tbl_map(vim.fn.shellescape, { "herdr", "pane", "send-text", "w1:p2", "a b 'c' $HOME" })
        assert.are.equal(table.concat(quoted, " "), got[3])
        assert.are.equal(3, #got)
    end)
end)

describe("multiplexer argv", function()
    it("drives herdr with send-text then a separate Return", function()
        local h = t.MUX.herdr
        assert.are.same({ "herdr", "pane", "send-text", "w1:p2", "/retro" },
            h.send_text("herdr", "w1:p2", "/retro"))
        assert.are.same({ "herdr", "pane", "send-keys", "w1:p2", "Enter" },
            h.send_enter("herdr", "w1:p2"))
    end)

    it("drives tmux literally, and past a prompt that starts with a dash", function()
        local m = t.MUX.tmux
        assert.are.same({ "tmux", "send-keys", "-t", "%3", "-l", "--", "-x /retro" },
            m.send_text("tmux", "%3", "-x /retro"))
        assert.are.same({ "tmux", "send-keys", "-t", "%3", "Enter" },
            m.send_enter("tmux", "%3"))
    end)

    it("honours an executable given as a path, for a shorter PATH over ssh", function()
        assert.are.equal("/home/me/.local/bin/herdr",
            t.MUX.herdr.send_text("/home/me/.local/bin/herdr", "w1:p2", "x")[1])
    end)
end)

describe("as_paste", function()
    it("wraps the text in the brackets a terminal puts around a paste", function()
        assert.are.equal("\27[200~/retro\27[201~", t.as_paste("/retro", nil))
        assert.are.equal("\27[200~/retro\27[201~", t.as_paste("/retro", true))
    end)

    it("sends it as typing when asked to", function()
        assert.are.equal("/retro", t.as_paste("/retro", false))
    end)

    it("keeps a newline inside the brackets, where it is text and not a submit", function()
        assert.are.equal("\27[200~one\ntwo\27[201~", t.as_paste("one\ntwo", nil))
    end)
end)

describe("pane lists", function()
    it("reads herdr's JSON, marking which panes hold an agent", function()
        local out = vim.json.encode({
            result = {
                panes = {
                    { pane_id = "w1:p1", cwd = "/n", agent_session = { agent = "claude" },
                      terminal_title_stripped = "Weekly retro" },
                    { pane_id = "w1:p2", cwd = "/n" },
                },
            },
        })
        local panes = t.MUX.herdr.parse(out)
        assert.are.equal(2, #panes)
        assert.are.equal("w1:p1", panes[1].target)
        assert.are.equal("claude", panes[1].agent)
        assert.is_truthy(panes[1].label:find("Weekly retro", 1, true))
        assert.is_nil(panes[2].agent)
    end)

    it("survives an answer that is not the pane list it expected", function()
        assert.are.same({}, t.MUX.herdr.parse("not json at all"))
        assert.are.same({}, t.MUX.herdr.parse(vim.json.encode({ result = {} })))
    end)

    it("reads tmux's format lines, taking the command for the agent", function()
        local panes = t.MUX.tmux.parse(table.concat({
            "%1\tnotes:1.0\tclaude\tworkstation",
            "%2\tnotes:1.1\tzsh\tworkstation",
            "",
        }, "\n"))
        assert.are.equal(2, #panes)
        assert.are.equal("%1", panes[1].target)
        assert.are.equal("claude", panes[1].agent)
        assert.are.equal("zsh", panes[2].agent)
    end)

    it("narrows to the Claude panes, but not to nothing", function()
        local mixed = { { agent = "claude" }, { agent = "zsh" } }
        assert.are.equal(1, #t.claude_first(mixed))
        local shells = { { agent = "zsh" }, { agent = "node" } }
        assert.are.equal(2, #t.claude_first(shells))
    end)
end)

describe("backends", function()
    it("names the multiplexers it can reach a pane through", function()
        assert.are.same({ "herdr", "tmux" }, claude.backends())
    end)
end)

describe("sending with no multiplexer to send to", function()
    -- Neither herdr nor tmux is running in the test runtime, so the send path
    -- bows out with a notify. The point is that it never errors: a machine
    -- without the multiplexer installed must not have fzfkasten break on it.
    it("does not error when the integration is disabled", function()
        setup({ enabled = false, prompts = { retro = { text = "/x" } } })
        assert.has_no.errors(function() claude.send_prompt("retro") end)
        assert.has_no.errors(function() claude.send_current_buffer() end)
        assert.has_no.errors(function() claude.choose_pane() end)
    end)

    it("does not error when enabled but nothing is there to send to", function()
        -- A command that cannot exist, so a machine that does run herdr or tmux
        -- has nothing typed into one of its panes by the test suite.
        setup({ enabled = true, pane = { via = "herdr", cmd = "fzfkasten-no-such-mux", target = "w1:p1" },
            prompts = { retro = { text = "/x" } } })
        assert.has_no.errors(function() claude.send_prompt("retro") end)
    end)

    it("does not error on an unknown or empty name", function()
        setup({ enabled = true, prompts = {} })
        assert.has_no.errors(function() claude.send_prompt("nope") end)
        assert.has_no.errors(function() claude.send_prompt("") end)
    end)

    it("does not error on a `via` that is not a multiplexer", function()
        setup({ enabled = true, pane = { via = "screen" }, prompts = { retro = { text = "/x" } } })
        assert.has_no.errors(function() claude.send_prompt("retro") end)
        assert.is_false(claude.is_available())
    end)

    it("warns instead of sending a buffer with no file name", function()
        setup({ enabled = true, pane = { cmd = "fzfkasten-no-such-mux", target = "w1:p1" } })
        vim.cmd("enew!")
        assert.has_no.errors(function() claude.send_current_buffer() end)
    end)
end)

describe("a buffer with no file behind it", function()
    -- The task list is made by fzfkasten and never written, so there is nothing
    -- for the pane to read: what it shows is sent instead. Its rows keep the
    -- task's note and line as virtual text, which is on the screen but not in
    -- the lines, and has to go too or the tasks lose where they came from.
    local ns = vim.api.nvim_create_namespace("fzfkasten-test")

    local function view(lines, marks)
        local buf = vim.api.nvim_create_buf(false, true)
        vim.bo[buf].buftype = "nofile"
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        for row, text in pairs(marks or {}) do
            vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
                virt_text = { { text, "Comment" } },
                virt_text_pos = "right_align",
            })
        end
        return buf
    end

    before_each(function() setup({ enabled = true, pane = { target = "w1:p1" } }) end)

    it("takes the virtual text hanging off a row with the row", function()
        local buf = view({ "- [ ] write the retro", "- [ ] read the mail" },
            { [0] = "lognote/2026-W33.md:12" })
        assert.are.same({ "- [ ] write the retro  lognote/2026-W33.md:12", "- [ ] read the mail" },
            t.view_lines(buf, nil, nil))
    end)

    it("sends what it shows, under the buffer's name", function()
        local buf = view({ "- [ ] write the retro" }, { [0] = "lognote/2026-W33.md:12" })
        vim.api.nvim_buf_set_name(buf, "fzfkasten://tasks")
        local ref = t.reference(buf)
        assert.are.equal("fzfkasten://tasks:\n- [ ] write the retro  lognote/2026-W33.md:12\n", ref.text)
        -- Nothing here is a file, so there is no freshness to check.
        assert.is_nil(ref.path)
    end)

    it("sends only the selected rows, and says which they were", function()
        local buf = view({ "one", "two", "three" })
        vim.api.nvim_buf_set_name(buf, "fzfkasten://tasks-selected")
        local ref = t.reference(buf, 2, 3)
        assert.are.equal("fzfkasten://tasks-selected (lines 2-3):\ntwo\nthree\n", ref.text)
    end)

    it("refuses a view longer than max_lines rather than flooding the pane", function()
        setup({ enabled = true, pane = { target = "w1:p1", max_lines = 2 } })
        local buf = view({ "one", "two", "three" })
        local ref, err = t.reference(buf)
        assert.is_nil(ref)
        assert.is_truthy(err:find("more than claude.pane.max_lines (2)", 1, true))
    end)

    it("still names a real file by its path", function()
        local path = "/tmp/fzfkasten-test/named.md"
        vim.fn.mkdir("/tmp/fzfkasten-test", "p")
        vim.fn.writefile({ "note" }, path)
        vim.cmd("edit " .. path)
        local ref = t.reference(0)
        assert.are.equal("@" .. path .. " ", ref.text)
        assert.are.equal(path, ref.path)
        vim.fn.delete(path)
    end)
end)

describe("what can be named to a pane", function()
    -- The pane reads files. A buffer nvim keeps to itself has a name that means
    -- nothing out there, and a file not yet written has nothing to read -- both
    -- have to be refused rather than sent as a path that resolves to nothing.
    local sent

    before_each(function()
        setup({ enabled = true, pane = { cmd = "fzfkasten-no-such-mux", target = "w1:p1" } })
        sent = {}
        -- Nothing is spawned in these tests; the notify is the whole answer.
        vim.notify = function(msg) sent[#sent + 1] = msg end
    end)

    after_each(function() vim.notify = vim.schedule_wrap(print) end)

    local function warned(text)
        for _, msg in ipairs(sent) do
            if msg:find(text, 1, true) then return msg end
        end
    end

    it("refuses a named file that has never been written", function()
        vim.cmd("enew!")
        vim.api.nvim_buf_set_name(0, "/tmp/fzfkasten-test/never-written.md")
        claude.send_current_buffer()
        assert.is_not_nil(warned("has never been written"))
    end)

    it("accepts a file that is on disk", function()
        local path = "/tmp/fzfkasten-test/on-disk.md"
        vim.fn.mkdir("/tmp/fzfkasten-test", "p")
        vim.fn.writefile({ "note" }, path)
        vim.cmd("edit " .. path)
        claude.send_current_buffer()
        assert.is_nil(warned("is a buffer of nvim's own"))
        assert.is_nil(warned("has never been written"))
        vim.fn.delete(path)
    end)
end)
