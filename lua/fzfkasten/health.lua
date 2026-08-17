-- `:checkhealth fzfkasten`.
--
-- Everything fzfkasten needs is outside itself: a notes directory that has to
-- exist, `fzf-lua` and the `fzf` binary, `ripgrep` for the scans, templates at
-- paths you gave it. When one of those is missing the symptom is usually a
-- picker that opens empty or a command that quietly does nothing -- which says
-- nothing about which of them it was. This says.
--
-- Each check is written to answer the question the reader actually has: not
-- "is ripgrep installed" but "what happens to me because it isn't".

local config = require("fzfkasten.config")

local M = {}

-- Resolved on each call rather than captured at load, so the suite can stand a
-- recorder in for `vim.health` and read back what a broken setup reports. The
-- failure messages are the point of this module, and a health check nobody has
-- seen fail is a health check nobody has tested.
local health = {}
for _, level in ipairs({ "start", "ok", "info", "warn", "error" }) do
    health[level] = function(...) return vim.health[level](...) end
end

-- 0.10 is the floor because of `vim.keycode()`, which the task list uses to
-- drive the preview's scrolling (news-0.10.txt).
local MIN_VERSION = "nvim-0.10"

local function check_neovim()
    health.start("Neovim")
    local version = vim.version()
    local as_string = string.format("%d.%d.%d", version.major, version.minor, version.patch)
    if vim.fn.has(MIN_VERSION) == 1 then
        health.ok("Neovim " .. as_string)
    else
        health.error("Neovim " .. as_string .. " is too old; 0.10 or newer is needed",
            { "vim.keycode(), which the task list preview relies on, arrived in 0.10." })
    end
end

local function check_setup()
    health.start("Configuration")
    if config.configured then
        health.ok("setup() has run")
    else
        health.warn("setup() has not run; the defaults are in use", {
            "`home` defaults to $ZETTELKASTEN_HOME or ~/notes, which is a guess.",
            "Call require('fzfkasten').setup({ home = ... }) from your config.",
        })
    end

    local home = config.options.home
    if not home or home == "" then
        health.error("`home` is not set: there is nowhere to look for notes")
    elseif vim.fn.isdirectory(home) == 1 then
        local glob = home .. "/**/*." .. config.options.extension
        local count = #(vim.fn.glob(glob, true, true) or {})
        health.ok(string.format("home: %s (%d .%s files)", home, count, config.options.extension))
        if count == 0 then
            health.info("No notes there yet, so every picker will come up empty.")
        end
    else
        health.error("home: " .. home .. " is not a directory", {
            "Nothing will be found until it exists. Create it, or point `home` elsewhere.",
        })
    end
end

-- A template configured but not there is worth saying out loud: creating a note
-- from it fails at the moment you are trying to write something down.
local function check_template(label, relative)
    if not relative or relative == "" then
        return
    end
    local full = relative
    if not vim.startswith(relative, "/") then
        full = config.options.home .. "/" .. relative
    end
    if vim.fn.filereadable(full) == 1 then
        health.ok(label .. ": " .. relative)
    else
        health.warn(label .. ": " .. relative .. " is configured but not readable", {
            "Looked for " .. full .. ".",
            "Notes created from it will be empty, or the command will fail.",
        })
    end
end

local function check_templates()
    health.start("Templates")
    local notes = config.options.notes or {}
    local any = config.options.new_note_template
        or (notes.daily or {}).template or (notes.weekly or {}).template
    if not any then
        health.info("No templates configured; new notes start empty.")
        return
    end
    check_template("new note", config.options.new_note_template)
    check_template("daily", (notes.daily or {}).template)
    check_template("weekly", (notes.weekly or {}).template)
    check_template("follow_link", (config.options.follow_link or {}).new_note_template)
end

local function check_dependencies()
    health.start("Dependencies")

    if pcall(require, "fzf-lua") then
        health.ok("fzf-lua")
    else
        health.error("fzf-lua is not installed", {
            "Every picker in fzfkasten is built on it; nothing will work without it.",
            "https://github.com/ibhagwan/fzf-lua",
        })
    end

    if vim.fn.executable("fzf") == 1 then
        health.ok("fzf")
    else
        health.error("the `fzf` binary is not on PATH", {
            "fzf-lua shells out to it, so the pickers will open and immediately fail.",
        })
    end

    if vim.fn.executable("rg") == 1 then
        health.ok("ripgrep")
    else
        health.warn("ripgrep (`rg`) is not on PATH", {
            "Task scanning falls back to reading every note, which still works but",
            "gets slow on a large collection. Content search needs it outright.",
            "Set tasks.patterns.scan = false to silence the per-scan warning.",
        })
    end
end

-- How long the backend takes to answer one query, said out loud.
--
-- The note finder asks on every keystroke, so this number *is* the typing
-- latency -- and nothing else in the setup shows it. A ttyskk without its
-- reading index answers in 270ms rather than 20ms, which everything else here
-- reports as a perfectly healthy romaji backend.
local function check_romaji_speed(romaji, advice)
    local started = vim.uv.hrtime()
    local re = romaji.regex("kaigi")
    local elapsed = (vim.uv.hrtime() - started) / 1e6

    if not re then
        health.warn("...but it answered nothing for `kaigi`, so `/kaigi` will match literally")
    elseif elapsed > 100 then
        health.warn(string.format("...but slowly: %.0fms per query, paid on every keystroke", elapsed),
            advice)
    else
        health.ok(string.format("%.0fms per query", elapsed))
    end
end

local function check_optional()
    health.start("Optional integrations")

    -- Which backend answered matters as much as whether one did: they are not
    -- interchangeable in cost (kensaku brings Deno with it) and a machine with
    -- both will silently pick one.
    local romaji = require("fzfkasten.romaji")
    local backend = romaji.backend_name()
    if backend == "ttyskk" then
        health.ok("romaji narrowing via ttyskk: <alt-/> matches 会議 from `kaigi`")
        check_romaji_speed(romaji, {
            "ttyskk re-reads the SKK dictionaries on every query unless it has an index.",
            "Build one once: `ttyskk migemo --build-index` (~0.4s, 270ms -> 20ms here).",
        })
    elseif backend == "kensaku" then
        health.ok("romaji narrowing via kensaku.vim: <alt-/> matches 会議 from `kaigi`", {
            "kensaku runs on denops, so this needs Deno; `ttyskk migemo` does not.",
        })
        check_romaji_speed(romaji, {
            "denops answers over RPC; a cold Deno is slow until it has warmed up.",
        })
    elseif backend then
        health.ok("romaji narrowing via a backend of your own: " .. tostring(backend))
        check_romaji_speed(romaji, nil)
    else
        health.info("No romaji backend (ttyskk or kensaku.vim); <alt-/> is hidden.")
    end

    local claude = config.options.claude or {}
    local pane = claude.pane or {}
    local backends = require("fzfkasten.claude").backends()
    if not claude.enabled then
        health.info("Claude integration is off (claude.enabled = false).")
    elseif not vim.tbl_contains(backends, pane.via or "herdr") then
        health.error("claude.pane.via is '" .. tostring(pane.via) .. "', which is not a multiplexer", {
            "Use one of: " .. table.concat(backends, ", ") .. ".",
        })
    else
        local via = pane.via or "herdr"
        local cmd = pane.cmd or via
        -- A pane on another machine is reached by running that CLI over ssh, so
        -- what has to be here is ssh; whether the far end has `cmd` on its PATH
        -- is a question only that machine can answer (and a non-interactive ssh
        -- gets a shorter PATH than a shell does, which is the usual surprise).
        if pane.host and pane.host ~= "" then
            if vim.fn.executable("ssh") == 1 then
                health.ok(("Claude pane: %s on %s, via ssh"):format(via, pane.host))
                health.info(("Check the far end yourself: ssh %s %s --version"):format(pane.host, cmd))
            else
                health.error("claude.pane.host is set but ssh is not on PATH")
            end
            if not pane.root or pane.root == "" then
                health.info("claude.pane.root is unset, so notes are named to "
                    .. pane.host .. " by their path here (" .. config.options.home .. ").")
            end
        elseif vim.fn.executable(cmd) == 1 then
            health.ok("Claude pane: " .. via .. " on this machine")
        else
            health.error("claude.enabled is true but `" .. cmd .. "` is not on PATH", {
                "The :FzfKastenClaude* commands will warn and do nothing.",
            })
        end
        if not pane.target or pane.target == "" then
            health.info("claude.pane.target is unset, so the first send of each session asks which pane.")
        end
    end
end

local function check_tasks()
    health.start("Tasks")
    local o = config.options.tasks or {}

    if o.require_tag then
        health.ok(string.format("require_tag: #%s -- only tagged checkboxes are your tasks", o.require_tag))
    else
        health.info("require_tag is unset, so every checkbox counts as a task and there is no inbox.")
    end

    local capture = o.capture_note or (o.always or {})[1]
    if capture then
        local full = config.options.home .. "/" .. capture
        local where = vim.fn.filereadable(full) == 1 and "" or " (not created yet; the first capture makes it)"
        health.ok("captures go to " .. capture .. where)
    else
        health.warn("No capture note: :FzfKastenTaskAdd has nowhere to write", {
            "Set tasks.capture_note, or put a note first in tasks.always.",
        })
    end

    -- A note listed in `always` is scanned regardless of `since_days`, so a
    -- name that no longer matches anything silently stops doing that.
    for _, relative in ipairs(o.always or {}) do
        if vim.fn.filereadable(config.options.home .. "/" .. relative) == 0 then
            health.info("always: " .. relative .. " does not exist yet.")
        end
    end

    if o.since_days then
        health.info(string.format(
            "since_days = %d: untagged checkboxes older than that stay out of the inbox.",
            o.since_days))
    end
end

function M.check()
    check_neovim()
    check_setup()
    check_dependencies()
    check_templates()
    check_tasks()
    check_optional()
end

return M
