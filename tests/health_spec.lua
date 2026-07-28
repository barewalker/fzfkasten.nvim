-- `:checkhealth fzfkasten`, driven through the states worth reporting.
--
-- A health check is only worth having for the runs where something is wrong, so
-- these cases break things on purpose -- no notes directory, a template that
-- isn't there, nowhere to capture to -- and read back what the user would see.
-- Checking only the healthy case would test the one run that needed no help.

local config = require("fzfkasten.config")
local health = require("fzfkasten.health")

local home
local original_health
local calls

local LEVELS = { "start", "ok", "info", "warn", "error" }

local function record()
    calls = {}
    original_health = vim.health
    vim.health = {}
    for _, level in ipairs(LEVELS) do
        vim.health[level] = function(message, extra)
            table.insert(calls, { level = level, message = message, extra = extra })
        end
    end
end

local function restore()
    if original_health then
        vim.health = original_health
        original_health = nil
    end
    if home then
        vim.fn.delete(home, "rf")
        home = nil
    end
end

local function setup(opts)
    home = vim.fn.tempname()
    vim.fn.mkdir(home, "p")
    config.setup(vim.tbl_deep_extend("force", { home = home }, opts or {}))
end

-- The first reported line of `level` whose message contains `needle`, or nil.
local function reported(level, needle)
    for _, call in ipairs(calls) do
        if call.level == level and call.message:find(needle, 1, true) then
            return call
        end
    end
    return nil
end

local function levels_of(needle)
    local found = {}
    for _, call in ipairs(calls) do
        if call.message:find(needle, 1, true) then
            table.insert(found, call.level)
        end
    end
    return found
end

describe("health: a working setup", function()
    after_each(restore)

    before_each(function()
        setup({ tasks = { require_tag = "todo", capture_note = "tasks/active.md" } })
        record()
        health.check()
    end)

    it("reports nothing as an error", function()
        for _, call in ipairs(calls) do
            assert.are_not.equal("error", call.level,
                "unexpected error: " .. call.message)
        end
    end)

    it("names the notes directory and counts what is in it", function()
        vim.fn.writefile({ "# one" }, home .. "/one.md")
        vim.fn.writefile({ "# two" }, home .. "/two.md")
        calls = {}
        health.check()
        assert.is_not_nil(reported("ok", "2 .md files"))
    end)

    it("confirms setup() ran", function()
        assert.is_not_nil(reported("ok", "setup() has run"))
    end)

    it("says which checkbox counts as a task", function()
        assert.is_not_nil(reported("ok", "require_tag: #todo"))
    end)
end)

describe("health: what it says when something is wrong", function()
    after_each(restore)

    it("errors when home is not a directory", function()
        setup()
        local missing = home .. "/nowhere"
        config.options.home = missing
        record()
        health.check()
        local call = reported("error", "is not a directory")
        assert.is_not_nil(call)
        assert.is_truthy(call.message:find(missing, 1, true))
    end)

    it("errors when home is unset", function()
        setup()
        config.options.home = ""
        record()
        health.check()
        assert.is_not_nil(reported("error", "there is nowhere to look for notes"))
    end)

    -- The default `home` is a guess, so "configured with nothing" and "never
    -- configured" are different answers and the check has to tell them apart.
    it("warns when setup() never ran", function()
        setup()
        config.configured = false
        record()
        health.check()
        assert.is_not_nil(reported("warn", "setup() has not run"))
        config.configured = true
    end)

    it("warns about a template that is configured but not there", function()
        setup({ new_note_template = "templates/missing.md" })
        record()
        health.check()
        local call = reported("warn", "templates/missing.md")
        assert.is_not_nil(call)
        -- The advice has to say where it looked, or there is nothing to act on.
        assert.is_truthy(table.concat(call.extra or {}, " "):find(home, 1, true))
    end)

    it("is quiet about templates that are there", function()
        vim.fn.mkdir(vim.fn.tempname(), "p")
        setup({ new_note_template = "templates/new.md" })
        vim.fn.mkdir(home .. "/templates", "p")
        vim.fn.writefile({ "# {{title}}" }, home .. "/templates/new.md")
        record()
        health.check()
        assert.are.same({ "ok" }, levels_of("templates/new.md"))
    end)

    it("warns when captures have nowhere to go", function()
        setup({ tasks = { capture_note = false, always = {} } })
        record()
        health.check()
        assert.is_not_nil(reported("warn", "nowhere to write"))
    end)

    it("says a capture note that does not exist yet will be made", function()
        setup({ tasks = { capture_note = "tasks/active.md" } })
        record()
        health.check()
        assert.is_not_nil(reported("ok", "not created yet"))
    end)

    it("errors when the Claude integration is on but not installed", function()
        setup({ claude = { enabled = true } })
        record()
        health.check()
        assert.is_not_nil(reported("error", "claudecode.nvim is not installed"))
    end)

    it("says nothing alarming when the Claude integration is off", function()
        setup({ claude = { enabled = false } })
        record()
        health.check()
        assert.is_nil(reported("error", "claudecode"))
        assert.is_not_nil(reported("info", "Claude integration is off"))
    end)

    it("notes when there is no inbox because require_tag is unset", function()
        setup({ tasks = { require_tag = false } })
        record()
        health.check()
        assert.is_not_nil(reported("info", "there is no inbox"))
    end)

    it("points out an empty notes directory rather than looking healthy", function()
        setup()
        record()
        health.check()
        assert.is_not_nil(reported("info", "every picker will come up empty"))
    end)
end)

describe("health: sections", function()
    after_each(restore)

    it("groups its findings, so a long report is readable", function()
        setup()
        record()
        health.check()
        local sections = {}
        for _, call in ipairs(calls) do
            if call.level == "start" then
                table.insert(sections, call.message)
            end
        end
        assert.are.same({
            "Neovim", "Configuration", "Dependencies",
            "Templates", "Tasks", "Optional integrations",
        }, sections)
    end)

    -- Every line has to be actionable on its own; a bare "error" with no
    -- message is the health check equivalent of a silent failure.
    it("never reports an empty message", function()
        setup()
        record()
        health.check()
        assert.is_true(#calls > 0)
        for _, call in ipairs(calls) do
            assert.is_truthy(call.message and call.message ~= "",
                call.level .. " reported nothing")
        end
    end)
end)
