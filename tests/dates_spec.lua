-- Calendar arithmetic, and why it is not seconds.
--
-- Stepping a day at a time by 86400 seconds is right for 363 days a year. On
-- the two the clocks change a day is 23 or 25 hours long, and the step lands on
-- the wrong date: the log picker skipped the changeover day entirely -- you
-- could not reach that day's note through it -- and `due:tomorrow` wrote the
-- day before.
--
-- These cases pin the calendar properties, which hold in any timezone, and one
-- of them re-runs the lot under a DST zone. If TZ cannot be changed in-process
-- on this platform that one skips itself rather than passing quietly.

local utils = require("fzfkasten.utils")
local config = require("fzfkasten.config")
local tasks = require("fzfkasten.tasks")

local function on(year, month, day, hour)
    return os.time({ year = year, month = month, day = day, hour = hour or 12, min = 0, sec = 0 })
end

local function date(timestamp)
    return os.date("%Y-%m-%d", timestamp)
end

describe("days_from", function()
    it("counts forwards and backwards", function()
        local base = on(2026, 7, 15)
        assert.are.equal("2026-07-15", date(utils.days_from(base, 0)))
        assert.are.equal("2026-07-16", date(utils.days_from(base, 1)))
        assert.are.equal("2026-07-14", date(utils.days_from(base, -1)))
        assert.are.equal("2026-07-25", date(utils.days_from(base, 10)))
    end)

    -- os.time renormalises an out-of-range day, so none of these need
    -- arithmetic of their own -- but that is worth knowing rather than assuming.
    it("crosses a month boundary", function()
        assert.are.equal("2026-02-28", date(utils.days_from(on(2026, 3, 1), -1)))
        assert.are.equal("2026-08-01", date(utils.days_from(on(2026, 7, 31), 1)))
    end)

    it("crosses a year boundary", function()
        assert.are.equal("2025-12-31", date(utils.days_from(on(2026, 1, 1), -1)))
        assert.are.equal("2027-01-01", date(utils.days_from(on(2026, 12, 31), 1)))
    end)

    it("knows about leap days", function()
        assert.are.equal("2028-02-29", date(utils.days_from(on(2028, 3, 1), -1)))
        assert.are.equal("2026-03-01", date(utils.days_from(on(2026, 2, 28), 1)))
    end)

    -- The property the whole thing exists for: N steps back from any instant
    -- give N distinct consecutive dates, whatever the hour.
    it("gives consecutive distinct days from any hour", function()
        for _, hour in ipairs({ 0, 1, 12, 23 }) do
            local base = on(2026, 3, 9, hour)
            local seen = {}
            for i = 0, 6 do
                local d = date(utils.days_from(base, -i))
                assert.is_nil(seen[d], "day repeated from hour " .. hour .. ": " .. d)
                seen[d] = true
            end
            -- ...and none skipped: seven back is exactly seven days earlier.
            local first = utils.days_from(base, 0)
            local last = utils.days_from(base, -6)
            assert.are.equal(6, math.floor(os.difftime(first, last) / 86400 + 0.5))
        end
    end)
end)

describe("days_from: across a daylight-saving change", function()
    local original

    -- glibc rereads TZ on each localtime(), so setting it here changes what
    -- os.date and os.time do. Where it does not, the guard below skips rather
    -- than letting the case pass without having tested anything.
    local function set_tz(tz)
        vim.fn.setenv("TZ", tz)
        return os.date("%Z", on(2026, 7, 15))
    end

    before_each(function()
        original = vim.fn.getenv("TZ")
        if original == vim.NIL then original = nil end
    end)

    after_each(function()
        if original then
            vim.fn.setenv("TZ", original)
        else
            vim.fn.setenv("TZ", vim.NIL)
        end
    end)

    it("does not skip the day the clocks go forward", function()
        local summer = set_tz("America/New_York")
        if summer ~= "EDT" then
            print("TZ cannot be changed in-process here (got " .. tostring(summer) .. "); skipping")
            return
        end
        -- 2026-03-08 is the changeover; 00:30 on the 9th is where seconds-based
        -- stepping jumped straight from the 9th to the 7th.
        local base = on(2026, 3, 9, 0)
        local days = {}
        for i = 0, 4 do
            days[#days + 1] = date(utils.days_from(base, -i))
        end
        assert.are.same({
            "2026-03-09", "2026-03-08", "2026-03-07", "2026-03-06", "2026-03-05",
        }, days)
    end)

    it("does not repeat the day the clocks go back", function()
        local summer = set_tz("America/New_York")
        if summer ~= "EDT" then return end
        -- 2026-11-01 is the changeover the other way, where a day is 25 hours.
        local base = on(2026, 11, 2, 0)
        local seen = {}
        for i = 0, 4 do
            local d = date(utils.days_from(base, -i))
            assert.is_nil(seen[d], "day repeated: " .. d)
            seen[d] = true
        end
    end)

    -- The user-visible consequence: this value is written into a note.
    it("resolves due dates to the right day", function()
        local summer = set_tz("America/New_York")
        if summer ~= "EDT" then return end
        config.setup({ home = "/tmp/fzfkasten-test" })
        local eve = on(2026, 3, 7, 23)
        assert.are.equal("2026-03-08", tasks._test.resolve_due("tomorrow", eve))
        assert.are.equal("2026-03-09", tasks._test.resolve_due("+2d", eve))
    end)
end)
