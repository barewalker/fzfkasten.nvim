-- Pictures and files kept where Notejo keeps them: reading their links, opening
-- them without going through Windows, and adding new ones.
--
-- rclone is never run here. `attach._run` is the one place a command leaves
-- the plugin, and these replace it with a script of answers.

local config = require("fzfkasten.config")
local attach = require("fzfkasten.attach")

local home
local real_run = attach._run
local real_view = attach.view

local function setup(opts)
    home = vim.fn.tempname()
    vim.fn.mkdir(home, "p")
    config.setup(vim.tbl_deep_extend("force", {
        home = home,
        attachments = { cache = home .. "/.cache" },
    }, opts or {}))
end

local function cleanup()
    attach._run = real_run
    attach.view = real_view
    pcall(vim.cmd, "silent! %bwipeout!")
    if home then
        vim.fn.delete(home, "rf")
        home = nil
    end
end

local function open_note(name, lines)
    local full = home .. "/" .. name
    vim.fn.mkdir(vim.fn.fnamemodify(full, ":h"), "p")
    vim.fn.writefile(lines, full)
    vim.cmd("edit " .. vim.fn.fnameescape(full))
    return full
end

-- Answer each command in turn; record what was asked.
local function script(answers)
    local asked = {}
    attach._run = function(command, on_done)
        table.insert(asked, command)
        local answer = table.remove(answers, 1) or { 0, "", "" }
        if answer.before then answer.before(command) end
        on_done(answer[1], answer[2], answer[3])
    end
    return asked
end

local function viewed()
    local seen = {}
    attach.view = function(path) table.insert(seen, path) end
    return seen
end

describe("drive_id", function()
    it("reads the three ways Drive writes a link", function()
        assert.are.equal("1Z_3QY-T78", attach.drive_id("https://drive.google.com/file/d/1Z_3QY-T78/view?usp=drivesdk"))
        assert.are.equal("abc_D-9", attach.drive_id("https://drive.google.com/open?id=abc_D-9"))
        assert.are.equal("xyz", attach.drive_id("https://docs.google.com/uc?export=download&id=xyz"))
    end)

    it("leaves every other address alone", function()
        assert.is_nil(attach.drive_id("https://example.com/file/d/abc/view"))
        assert.is_nil(attach.drive_id("https://notdrive.google.com.example/file/d/abc"))
        assert.is_nil(attach.drive_id("attachments/a.jpg"))
    end)
end)

describe("classify", function()
    it("tells Drive, the web, and the collection apart", function()
        assert.are.same({ kind = "drive", id = "abc" },
            attach.classify("https://drive.google.com/file/d/abc/view", "/c/lognote/d.md"))
        assert.are.same({ kind = "web", url = "https://example.com/x" },
            attach.classify("https://example.com/x", "/c/lognote/d.md"))
        assert.are.same({ kind = "local", path = "/c/attachments/a.jpg" },
            attach.classify("../attachments/a.jpg", "/c/lognote/d.md"))
        assert.are.same({ kind = "local", path = "/c/lognote/figs/b.png" },
            attach.classify("./figs/b.png#zoom", "/c/lognote/d.md"))
    end)
end)

describe("target_at", function()
    local line = "see ![](https://drive.google.com/file/d/abc/view) and [doc](notes/d.pdf), or https://example.com/x."

    it("finds the link the cursor is in", function()
        assert.are.equal("https://drive.google.com/file/d/abc/view", attach.target_at(line, 7))
        assert.are.equal("notes/d.pdf", attach.target_at(line, line:find("doc") + 1))
    end)

    it("finds a bare address, without the full stop after it", function()
        assert.are.equal("https://example.com/x", attach.target_at(line, line:find("example") + 2))
    end)

    it("finds nothing between links", function()
        assert.is_nil(attach.target_at(line, 2))
    end)
end)

describe("naming and linking", function()
    it("names a file as Notejo does", function()
        local now = os.time({ year = 2026, month = 11, day = 15, hour = 11, min = 41, sec = 35 })
        assert.are.equal("2026-11-15-20261115-114135.jpg", attach.name_for("/c/lognote/2026-11-15.md", "/tmp/IMG_1.JPG", now))
        assert.are.equal("会議-メモ-20261115-114135.pdf", attach.name_for("/c/会議 メモ.md", "/tmp/a.pdf", now))
    end)

    it("shows a picture and names anything else", function()
        assert.are.equal("![](x)", attach.link_for("/tmp/p.png", "x"))
        assert.are.equal("[report.pdf](x)", attach.link_for("/tmp/report.pdf", "x"))
    end)

    it("links relative to the note", function()
        assert.are.equal("../attachments/a.jpg", attach.relative("lognote/d.md", "attachments/a.jpg"))
        assert.are.equal("attachments/a.jpg", attach.relative("d.md", "attachments/a.jpg"))
    end)
end)

describe("opening", function()
    after_each(cleanup)

    it("fetches a Drive file once, by id, and views it", function()
        setup({ attachments = { rclone_remote = "gdrive:" } })
        open_note("d.md", { "![](https://drive.google.com/file/d/ID9/view)" })
        vim.api.nvim_win_set_cursor(0, { 1, 4 })
        local seen = viewed()
        local asked = script({
            { 0, "", "", before = function(command)
                vim.fn.writefile({ "jpeg" }, command[#command] .. "photo.jpg")
            end },
        })

        assert.is_true(attach.open_under_cursor())
        assert.are.same({ "rclone", "backend", "copyid", "gdrive:", "ID9", home .. "/.cache/ID9/" }, asked[1])
        assert.are.same({ home .. "/.cache/ID9/photo.jpg" }, seen)

        -- The second time it is already here.
        assert.is_true(attach.open_under_cursor())
        assert.are.equal(1, #asked)
        assert.are.equal(2, #seen)
    end)

    it("views a file in the collection where it is", function()
        setup()
        vim.fn.mkdir(home .. "/attachments", "p")
        vim.fn.writefile({ "x" }, home .. "/attachments/a.jpg")
        open_note("lognote/d.md", { "![](../attachments/a.jpg)" })
        vim.api.nvim_win_set_cursor(0, { 1, 3 })
        local seen = viewed()
        assert.is_true(attach.open_under_cursor())
        assert.are.same({ home .. "/attachments/a.jpg" }, seen)
    end)

    it("says no when there is nothing under the cursor", function()
        setup()
        open_note("d.md", { "plain words" })
        assert.is_false(attach.open_under_cursor())
    end)
end)

describe("adding", function()
    after_each(cleanup)

    it("sends to Drive and links the file by its id", function()
        setup({ attachments = { home = "drive", rclone_remote = "gdrive:" } })
        local picture = home .. "/../pic-" .. vim.fn.rand() .. ".jpg"
        vim.fn.writefile({ "jpeg" }, picture)
        open_note("lognote/d.md", { "before " })
        vim.api.nvim_win_set_cursor(0, { 1, 6 })
        local asked = script({
            { 0, "", "" },
            { 0, '[{"Name":"x","ID":"NEWID"}]', "" },
        })

        attach.attach(picture)

        assert.are.equal("copyto", asked[1][2])
        assert.is_truthy(asked[1][4]:match("^gdrive:Notejo/d%-%d+%-%d+%.jpg$"))
        assert.are.equal("lsjson", asked[2][2])
        assert.are.equal("before ![](https://drive.google.com/file/d/NEWID/view)",
            vim.api.nvim_buf_get_lines(0, 0, 1, false)[1])
        vim.fn.delete(picture)
    end)

    it("copies into the repository and links it relatively", function()
        setup({ attachments = { home = "repository" } })
        local file = home .. "/../doc-" .. vim.fn.rand() .. ".pdf"
        vim.fn.writefile({ "pdf" }, file)
        open_note("lognote/d.md", { "" })
        script({})

        attach.attach(file)

        local copied = vim.fn.glob(home .. "/attachments/d-*.pdf", false, true)
        assert.are.equal(1, #copied)
        local name = vim.fn.fnamemodify(copied[1], ":t")
        assert.are.equal("[" .. vim.fn.fnamemodify(file, ":t") .. "](../attachments/" .. name .. ")",
            vim.api.nvim_buf_get_lines(0, 0, 1, false)[1])
        vim.fn.delete(file)
    end)

    it("does nothing without a home", function()
        setup()
        open_note("d.md", { "" })
        local asked = script({})
        local file = home .. "/x.jpg"
        vim.fn.writefile({ "x" }, file)
        attach.attach(file)
        assert.are.equal(0, #asked)
        assert.are.equal("", vim.api.nvim_buf_get_lines(0, 0, 1, false)[1])
    end)
end)

describe("Drive documents", function()
    it("reads the id of a document, a sheet and a deck", function()
        assert.are.equal("DOC1", attach.drive_id("https://docs.google.com/document/d/DOC1/edit"))
        assert.are.equal("SH-2", attach.drive_id("https://docs.google.com/spreadsheets/d/SH-2/edit#gid=0"))
        assert.are.equal("P_3", attach.drive_id("https://docs.google.com/presentation/d/P_3/view"))
    end)
end)

describe("WebDAV", function()
    after_each(cleanup)

    local dav = { webdav_remote = "nas:Notejo", webdav_url = "https://cloud.example/dav/files/me/Notejo/" }

    it("knows a link under its folder, and no other", function()
        setup({ attachments = dav })
        assert.are.same(
            { kind = "webdav", path = "会議 メモ-1.jpg", url = "https://cloud.example/dav/files/me/Notejo/%E4%BC%9A%E8%AD%B0%20%E3%83%A1%E3%83%A2-1.jpg" },
            attach.classify("https://cloud.example/dav/files/me/Notejo/%E4%BC%9A%E8%AD%B0%20%E3%83%A1%E3%83%A2-1.jpg", "/c/d.md"))
        assert.are.equal("sub/a.pdf", attach.webdav_path("https://cloud.example/dav/files/me/Notejo/sub/a.pdf?x=1"))
        assert.is_nil(attach.webdav_path("https://cloud.example/dav/files/me/Notejo-other/a.pdf"))
        assert.is_nil(attach.webdav_path("https://cloud.example/dav/files/me/Notejo/../secret"))
        assert.is_nil(attach.webdav_path("https://cloud.example/dav/files/me/Notejo/%2E%2E/secret"))
        assert.are.equal("web", attach.classify("https://cloud.example/elsewhere/a.jpg", "/c/d.md").kind)
    end)

    it("is the web when the folder is not set up", function()
        setup()
        assert.are.equal("web", attach.classify("https://cloud.example/dav/files/me/Notejo/a.jpg", "/c/d.md").kind)
    end)

    it("fetches through the remote, once, and views it", function()
        setup({ attachments = dav })
        open_note("d.md", { "![](https://cloud.example/dav/files/me/Notejo/d-1.jpg)" })
        vim.api.nvim_win_set_cursor(0, { 1, 4 })
        local seen = viewed()
        local asked = script({
            { 0, "", "", before = function(command) vim.fn.writefile({ "jpeg" }, command[#command]) end },
        })

        assert.is_true(attach.open_under_cursor())
        assert.are.same({ "rclone", "copyto", "nas:Notejo/d-1.jpg" }, vim.list_slice(asked[1], 1, 3))
        assert.are.equal(1, #seen)
        assert.are.equal("d-1.jpg", vim.fn.fnamemodify(seen[1], ":t"))

        assert.is_true(attach.open_under_cursor())
        assert.are.equal(1, #asked)
        assert.are.same({ seen[1], seen[1] }, seen)
    end)

    it("sends through the remote and links the address Notejo would", function()
        setup({ attachments = vim.tbl_extend("force", dav, { home = "webdav" }) })
        local picture = home .. "/../pic-" .. vim.fn.rand() .. ".png"
        vim.fn.writefile({ "png" }, picture)
        open_note("lognote/会議 メモ.md", { "" })
        local asked = script({ { 0, "", "" } })

        attach.attach(picture)

        assert.are.equal(1, #asked)
        assert.are.equal("copyto", asked[1][2])
        local name = asked[1][4]:match("^nas:Notejo/(会議%-メモ%-%d+%-%d+%.png)$")
        assert.is_truthy(name)
        assert.are.equal("![](https://cloud.example/dav/files/me/Notejo/" .. attach.encode(name) .. ")",
            vim.api.nvim_buf_get_lines(0, 0, 1, false)[1])
        -- What was written is read back as the same file.
        assert.are.equal(name, attach.webdav_path("https://cloud.example/dav/files/me/Notejo/" .. attach.encode(name)))
        vim.fn.delete(picture)
    end)

    it("writes no link when the send fails", function()
        setup({ attachments = vim.tbl_extend("force", dav, { home = "webdav" }) })
        local file = home .. "/x.pdf"
        vim.fn.writefile({ "x" }, file)
        open_note("d.md", { "" })
        script({ { 1, "", "401 Unauthorized" } })
        attach.attach(file)
        assert.are.equal("", vim.api.nvim_buf_get_lines(0, 0, 1, false)[1])
    end)
end)

describe("keeping fetched files", function()
    after_each(cleanup)

    -- A fetched file of `kb` kilobytes, last opened `days` ago.
    local function kept(key, kb, days, now)
        local dir = home .. "/.cache/" .. key
        vim.fn.mkdir(dir, "p")
        local f = assert(io.open(dir .. "/f.bin", "wb"))
        f:write(string.rep("x", kb * 1024))
        f:close()
        vim.uv.fs_utime(dir, now - days * 86400, now - days * 86400)
        return dir
    end

    it("lets go of what has not been opened for keep_days", function()
        setup({ attachments = { keep_days = 14, keep_mb = false } })
        local now = os.time()
        local old, recent = kept("old", 1, 15, now), kept("recent", 1, 13, now)
        attach.prune(nil, now)
        assert.are.equal(0, vim.fn.isdirectory(old))
        assert.are.equal(1, vim.fn.isdirectory(recent))
    end)

    it("lets go of the ones opened longest ago until the rest fits", function()
        setup({ attachments = { keep_days = false, keep_mb = 1 } })
        local now = os.time()
        local a, b, c = kept("a", 500, 3, now), kept("b", 500, 2, now), kept("c", 500, 1, now)
        attach.prune(c, now)
        assert.are.equal(0, vim.fn.isdirectory(a))
        assert.are.equal(1, vim.fn.isdirectory(b))
        assert.are.equal(1, vim.fn.isdirectory(c))
    end)

    it("never lets go of the one being opened", function()
        setup({ attachments = { keep_days = 0, keep_mb = 0 } })
        local now = os.time()
        local open, other = kept("open", 10, 40, now), kept("other", 10, 0, now - 1)
        attach.prune(open, now)
        assert.are.equal(1, vim.fn.isdirectory(open))
        assert.are.equal(0, vim.fn.isdirectory(other))
    end)

    it("keeps everything with both limits off", function()
        setup({ attachments = { keep_days = false, keep_mb = false } })
        local now = os.time()
        local old = kept("old", 10, 4000, now)
        attach.prune(nil, now)
        assert.are.equal(1, vim.fn.isdirectory(old))
    end)

    it("counts an opening as the last time it was opened", function()
        setup({ attachments = { rclone_remote = "gdrive:", keep_days = 14 } })
        local now = os.time()
        local dir = kept("ID9", 1, 13, now)
        open_note("d.md", { "![](https://drive.google.com/file/d/ID9/view)" })
        vim.api.nvim_win_set_cursor(0, { 1, 4 })
        viewed()
        script({})
        assert.is_true(attach.open_under_cursor())
        assert.is_true(now - vim.uv.fs_stat(dir).mtime.sec < 60)
    end)
end)

describe("choosing a file", function()
    after_each(cleanup)

    local real_choose = attach._choose
    after_each(function() attach._choose = real_choose end)

    local function put(path, age)
        vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
        vim.fn.writefile({ "x" }, path)
        local t = os.time() - age
        vim.uv.fs_utime(path, t, t)
    end

    it("lists the folders one level deep, newest first, without hidden files", function()
        setup()
        local inbox = home .. "/inbox"
        put(inbox .. "/old.pdf", 300)
        put(inbox .. "/Screenshots/new.png", 10)
        put(inbox .. "/mid.jpg", 100)
        put(inbox .. "/.hidden", 1)
        put(inbox .. "/a/b/too-deep.png", 1)
        config.options.attachments.pick_from = { inbox, home .. "/not-there" }

        local names = vim.tbl_map(function(f) return f.path:sub(#inbox + 2) end, attach.candidates())
        assert.are.same({ "Screenshots/new.png", "mid.jpg", "old.pdf" }, names)
    end)

    it("links the chosen one where the cursor was when asked", function()
        setup({ attachments = { home = "repository" } })
        local inbox = home .. "/inbox"
        put(inbox .. "/shot.png", 10)
        put(inbox .. "/older.png", 100)
        config.options.attachments.pick_from = { inbox }
        open_note("d.md", { "ab" })
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        local shown
        attach._choose = function(entries, on_choice)
            shown = entries
            -- The list has the window by now; the cursor is somewhere else.
            vim.cmd("new")
            on_choice(entries[1])
        end

        attach.attach("")

        assert.are.equal(2, #shown)
        assert.is_truthy(shown[1]:find("shot.png", 1, true))
        vim.cmd("bwipeout!")
        local line = vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]
        assert.is_truthy(line:match("^a!%[%]%(attachments/d%-%d+%-%d+%.png%)b$"))
    end)

    it("says so when there is nothing to choose from", function()
        setup({ attachments = { home = "repository", pick_from = {} } })
        open_note("d.md", { "" })
        local asked = false
        attach._choose = function() asked = true end
        attach.attach(nil)
        assert.is_false(asked)
    end)
end)

describe("adding to the repository", function()
    after_each(cleanup)

    it("never replaces a file already there", function()
        setup({ attachments = { home = "repository" } })
        local file = home .. "/x.pdf"
        vim.fn.writefile({ "new" }, file)
        open_note("d.md", { "" })
        local taken = attach.name_for(home .. "/d.md", file)
        vim.fn.mkdir(home .. "/attachments", "p")
        vim.fn.writefile({ "old" }, home .. "/attachments/" .. taken)

        attach.attach(file)

        local all = vim.fn.glob(home .. "/attachments/*", false, true)
        -- The second may have ticked over; either way the old one is as it was.
        assert.are.equal(2, #all)
        assert.are.same({ "old" }, vim.fn.readfile(home .. "/attachments/" .. taken))
    end)
end)

describe("linking a file already there", function()
    after_each(cleanup)

    local real_choose = attach._choose
    after_each(function() attach._choose = real_choose end)

    local listing = vim.json.encode({
        { Name = "old.pdf", ID = "OLD", ModTime = "2026-11-01T00:00:00.000Z" },
        { Name = "new.jpg", ID = "NEW", ModTime = "2026-11-15T02:42:03.043Z" },
    })

    it("lists the Drive folder newest first and links the one chosen by its id", function()
        setup({ attachments = { home = "drive", rclone_remote = "gdrive:", drive_folder = "Z/att" } })
        open_note("d.md", { "ab" })
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        local asked = script({ { 0, listing, "" } })
        local shown
        attach._choose = function(entries, on_choice, remote)
            shown = entries
            assert.is_true(remote)
            on_choice(entries[2])
        end

        attach.link_existing()

        assert.are.same({ "rclone", "lsjson", "gdrive:Z/att", "--files-only", "--no-mimetype" }, asked[1])
        assert.is_truthy(shown[1]:find("new.jpg", 1, true))
        assert.are.equal("a[old.pdf](https://drive.google.com/file/d/OLD/view)b",
            vim.api.nvim_buf_get_lines(0, 0, 1, false)[1])
    end)

    it("links a WebDAV file by its address", function()
        setup({ attachments = { home = "webdav", webdav_remote = "nas:Notejo", webdav_url = "https://c.example/Notejo" } })
        open_note("d.md", { "" })
        local asked = script({ { 0, listing, "" } })
        attach._choose = function(entries, on_choice) on_choice(entries[1]) end
        attach.link_existing()
        assert.are.equal("nas:Notejo", asked[1][3])
        assert.are.equal("![](https://c.example/Notejo/new.jpg)", vim.api.nvim_buf_get_lines(0, 0, 1, false)[1])
    end)

    it("asks nothing with no folder to list, and writes nothing when the listing fails", function()
        setup()
        open_note("d.md", { "" })
        local asked = script({})
        attach.link_existing()
        assert.are.equal(0, #asked)

        config.options.attachments.rclone_remote = "gdrive:"
        script({ { 1, "", "no such remote" } })
        local chose = false
        attach._choose = function() chose = true end
        attach.link_existing()
        assert.is_false(chose)
        assert.are.equal("", vim.api.nvim_buf_get_lines(0, 0, 1, false)[1])
    end)
end)

describe("showing a picture in the note", function()
    after_each(cleanup)

    local real_redraw = attach._redraw
    after_each(function() attach._redraw = real_redraw end)

    local function redrawn()
        local notes = {}
        attach._redraw = function(note) table.insert(notes, note) end
        return notes
    end

    it("leaves paths and other addresses to whoever draws them", function()
        setup({ attachments = { rclone_remote = "gdrive:" } })
        local asked = script({})
        assert.is_nil(attach.resolve(home .. "/d.md", "attachments/a.jpg"))
        assert.is_nil(attach.resolve(home .. "/d.md", "https://example.com/a.jpg"))
        assert.are.equal(0, #asked)
    end)

    it("fetches a Drive picture behind the note, then has it drawn again", function()
        setup({ attachments = { rclone_remote = "gdrive:" } })
        local notes = redrawn()
        local finish
        local asked = {}
        attach._run = function(command, on_done)
            table.insert(asked, command)
            finish = function()
                vim.fn.writefile({ "jpeg" }, command[#command] .. "photo.jpg")
                on_done(0, "", "")
            end
        end
        local src = "https://drive.google.com/file/d/PIC1/view"

        local first = attach.resolve(home .. "/d.md", src)
        assert.are.equal(home .. "/.cache/blank.png", first)
        assert.are.equal(1, vim.fn.filereadable(first))
        -- Drawn again before it has arrived: still one fetch.
        assert.are.equal(first, attach.resolve(home .. "/d.md", src))
        assert.are.equal(1, #asked)
        assert.are.same({ "rclone", "backend", "copyid", "gdrive:", "PIC1" }, vim.list_slice(asked[1], 1, 5))

        finish()
        assert.are.same({ home .. "/d.md", home .. "/d.md" }, notes)
        assert.are.equal(home .. "/.cache/PIC1/photo.jpg", attach.resolve(home .. "/d.md", src))
        assert.are.equal(1, #asked)
    end)

    it("answers at once for one already fetched", function()
        setup({ attachments = { webdav_remote = "nas:N", webdav_url = "https://c.example/N" } })
        local asked = script({ { 0, "", "", before = function(command) vim.fn.writefile({ "x" }, command[#command]) end } })
        redrawn()
        attach.resolve(home .. "/d.md", "https://c.example/N/a%20b.png")
        local path = attach.resolve(home .. "/d.md", "https://c.example/N/a%20b.png")
        assert.are.equal("a b.png", vim.fn.fnamemodify(path, ":t"))
        assert.are.equal(1, #asked)
    end)

    it("does not ask again for one that could not be fetched", function()
        setup({ attachments = { rclone_remote = "gdrive:" } })
        local notes = redrawn()
        local asked = script({ { 1, "", "not found" } })
        local src = "https://drive.google.com/file/d/GONE7/view"
        attach.resolve(home .. "/d.md", src)
        assert.are.equal(1, #notes)
        assert.is_nil(attach.resolve(home .. "/d.md", src))
        assert.are.equal(1, #asked)
    end)

    it("fetches a few at a time", function()
        setup({ attachments = { rclone_remote = "gdrive:" } })
        redrawn()
        local pending = {}
        attach._run = function(command, on_done) table.insert(pending, on_done) end
        for i = 1, 5 do
            attach.resolve(home .. "/d.md", "https://drive.google.com/file/d/MANY" .. i .. "/view")
        end
        assert.are.equal(3, #pending)
        pending[1](1, "", "x")
        assert.are.equal(4, #pending)
        for i = 2, 4 do pending[i](1, "", "x") end
        pending[5](1, "", "x")
        assert.are.equal(5, #pending)
    end)

    it("has nothing to say about Drive with no remote", function()
        setup()
        assert.is_nil(attach.resolve(home .. "/d.md", "https://drive.google.com/file/d/X/view"))
    end)

    it("reports a command that is not installed as a failed run", function()
        local code, err
        real_run({ "fzfkasten-no-such-command" }, function(c, _, e) code, err = c, e end)
        vim.wait(1000, function() return code ~= nil end)
        assert.are.equal(127, code)
        assert.is_truthy(err:find("fzfkasten-no-such-command is not installed", 1, true))
    end)
end)
