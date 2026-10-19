-- #tags coloured in notes: where the tag pattern matches, and which buffers
-- count as notes.

local th = require("fzfkasten.tag_highlight")

local TAG = [[#([%w_-]+)]]

describe("tag_highlight.ranges", function()
    it("finds each tag, # included", function()
        assert.are.same({ { 6, 11 }, { 12, 19 } }, th.ranges("- [ ] #todo #budget", TAG))
    end)

    it("reads tags as the tag pattern does", function()
        -- No left boundary, ASCII only, and a heading's `# ` is no tag.
        assert.are.same({ { 1, 3 } }, th.ranges("a#b", TAG))
        assert.are.same({}, th.ranges("# Heading", TAG))
        assert.are.same({}, th.ranges("#会議", TAG))
        assert.are.same({ { 6, 9 } }, th.ranges("check #12", TAG))
    end)

    it("finds nothing in an empty line", function()
        assert.are.same({}, th.ranges("", TAG))
    end)
end)

describe("tag_highlight.is_note", function()
    it("takes files under home with the extension", function()
        assert.is_true(th.is_note("/n/a.md", "/n", "md"))
        assert.is_true(th.is_note("/n/sub/a.md", "/n/", "md"))
    end)

    it("leaves out other files", function()
        assert.is_false(th.is_note("/notes/a.md", "/n", "md"))
        assert.is_false(th.is_note("/n/a.txt", "/n", "md"))
        assert.is_false(th.is_note("/n/a.md", "", "md"))
        assert.is_false(th.is_note("", "/n", "md"))
    end)
end)
