-- Pictures and files a note links to, kept the way Notejo keeps them.
--
-- Notejo (the Android app over the same collection) can keep pictures out of
-- the repository: in a Google Drive folder, with only the link in the note.
-- That is a link a desktop can only follow through a browser, and on WSL the
-- browser `vim.ui.open` reaches is the Windows one. Here the file is fetched
-- with rclone instead -- the Drive remote is set up once in WSL or Linux -- and
-- opened with a viewer that runs on the same side. Nothing on Windows is asked.
--
-- The other half is adding one: `:FzfKastenAttach` puts a file where Notejo
-- would have -- Drive, a WebDAV folder, or the repository -- and the link where
-- the cursor is. Without a file it lists the newest ones in the folders
-- pictures arrive in, which is the desktop's "take a photo".

local config = require("fzfkasten.config")

local M = {}

local function options()
    return config.options.attachments or {}
end

-- --- Reading a link ---------------------------------------------------------

-- The Drive file a link points at, or nil. Drive writes the same file three
-- ways depending on where the link was copied: a /file/d/ path, an ?id= query,
-- and the old open?id= form.
function M.drive_id(url)
    if type(url) ~= "string" then return nil end
    local host = url:match("^https?://([^/]+)")
    if not host or not (host == "drive.google.com" or host == "docs.google.com") then
        return nil
    end
    for _, kind in ipairs({ "file", "document", "spreadsheets", "presentation" }) do
        local id = url:match("/" .. kind .. "/d/([%w_%-]+)")
        if id then return id end
    end
    return url:match("[?&]id=([%w_%-]+)")
end

-- A name as one step of a URL, and back.
function M.encode(name)
    return (name:gsub("[^%w%-._~]", function(c) return string.format("%%%02X", c:byte()) end))
end

local function decode(text)
    return (text:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end))
end

-- `path` under the rclone remote `remote`: "nas:" and "nas:Notejo" both take one.
local function under(remote, path)
    if remote:match("[:/]$") then return remote .. path end
    return remote .. "/" .. path
end

-- The path under the WebDAV folder that `url` points at, or nil when it points
-- anywhere else -- or the folder is not set up, or the path climbs out of it.
function M.webdav_path(url)
    local opts = options()
    if type(url) ~= "string" or not opts.webdav_url or not opts.webdav_remote then return nil end
    local base = opts.webdav_url:gsub("/+$", "") .. "/"
    if url:sub(1, #base) ~= base then return nil end
    local path = decode((url:sub(#base + 1):gsub("[#?].*$", "")))
    if path == "" or path:sub(-1) == "/" then return nil end
    for _, part in ipairs(vim.split(path, "/", { plain = true })) do
        if part == ".." then return nil end
    end
    return path
end

-- What `target` is, seen from the note at `note_path`:
--   { kind = "drive", id = ... }   a file in Google Drive
--   { kind = "webdav", path = ..., url = ... }  a file in the WebDAV folder
--   { kind = "web", url = ... }    anything else on the web
--   { kind = "local", path = ... } a file in the collection, by relative path
function M.classify(target, note_path)
    if not target or target == "" then return nil end
    target = target:gsub("^<(.*)>$", "%1")
    local id = M.drive_id(target)
    if id then return { kind = "drive", id = id } end
    local dav = M.webdav_path(target)
    if dav then return { kind = "webdav", path = dav, url = target } end
    if target:match("^%a[%w+.-]*://") then return { kind = "web", url = target } end

    local base = target:gsub("[#?].*$", "")
    local dir = vim.fn.fnamemodify(note_path or "", ":h")
    local path = base:sub(1, 1) == "/" and base or (dir .. "/" .. base)
    return { kind = "local", path = vim.fs.normalize(vim.fn.simplify(path)) }
end

-- The `[label](target)`, `![alt](target)` or bare URL the column `col` (1-based)
-- of `line` sits in, as its target.
function M.target_at(line, col)
    local from = 1
    while true do
        local s, e, target = line:find("!?%[[^%]]*%]%(([^%)]+)%)", from)
        if not s then break end
        if col >= s and col <= e then return target end
        from = e + 1
    end
    from = 1
    while true do
        local s, e = line:find("https?://[^%s<>%(%)%[%]`\"']+", from)
        if not s then break end
        local url = line:sub(s, e):gsub("[.,;:!?。、」』）]+$", "")
        if col >= s and col <= s + #url - 1 then return url end
        from = e + 1
    end
    return nil
end

-- --- Opening ----------------------------------------------------------------

-- Hand a local file to the viewer: the configured command when there is one,
-- `vim.ui.open` when not. On WSL `vim.ui.open` is `wslview` -- Windows -- which
-- is why `viewer` exists.
function M.view(path)
    local viewer = options().viewer
    if type(viewer) == "string" then viewer = { viewer } end
    if viewer and #viewer > 0 then
        local command = vim.list_extend(vim.deepcopy(viewer), { path })
        local ok, err = pcall(vim.system, command, { detach = true })
        if not ok then
            vim.notify("[Fzfkasten] " .. tostring(err), vim.log.levels.ERROR)
        end
        return
    end
    local ok, err = pcall(vim.ui.open, path)
    if not ok then
        vim.notify("[Fzfkasten] " .. tostring(err), vim.log.levels.ERROR)
    end
end

-- Seam for the tests: run a command and call back with (code, stdout, stderr).
-- `vim.system` raises rather than returning a status when the command is not
-- installed, so that case is reported here as a failed run like any other.
M._run = function(command, on_done)
    local ok, err = pcall(vim.system, command, { text = true }, function(result)
        vim.schedule(function()
            on_done(result.code, result.stdout or "", result.stderr or "")
        end)
    end)
    if ok then return end
    local reason = tostring(err)
    if vim.fn.executable(command[1]) ~= 1 then
        reason = command[1] .. " is not installed (or not on PATH)"
    end
    vim.schedule(function() on_done(127, "", reason) end)
end

local function cache_dir()
    return options().cache or (vim.fn.stdpath("cache") .. "/fzfkasten/attachments")
end

local function size_of(dir)
    local total = 0
    for _, file in ipairs(vim.fn.glob(dir .. "/*", false, true)) do
        local st = vim.uv.fs_stat(file)
        if st then total = total + st.size end
    end
    return total
end

-- Let go of fetched files nobody has opened for `keep_days`, then of the ones
-- opened longest ago until what is left fits in `keep_mb`. `keeping` is the one
-- being opened now: a viewer is reading it. Either limit set to false is no
-- limit; everything here can be fetched again.
function M.prune(keeping, now)
    local opts = options()
    now = now or os.time()
    local kept, total = {}, 0
    for _, dir in ipairs(vim.fn.glob(cache_dir() .. "/*", false, true)) do
        local st = vim.uv.fs_stat(dir)
        if st and st.type == "directory" and dir ~= keeping then
            if opts.keep_days and now - st.mtime.sec > opts.keep_days * 86400 then
                vim.fn.delete(dir, "rf")
            else
                local size = size_of(dir)
                total = total + size
                table.insert(kept, { dir = dir, opened = st.mtime.sec, size = size })
            end
        end
    end
    if not opts.keep_mb then return end
    if keeping then total = total + size_of(keeping) end
    table.sort(kept, function(a, b) return a.opened < b.opened end)
    for _, entry in ipairs(kept) do
        if total <= opts.keep_mb * 1024 * 1024 then break end
        vim.fn.delete(entry.dir, "rf")
        total = total - entry.size
    end
end

-- View the file kept in `dir`, and note that it was opened just now.
local function view_kept(dir, file)
    local now = os.time()
    vim.uv.fs_utime(dir, now, now)
    M.view(file)
    M.prune(dir, now)
end

-- Where a Drive or WebDAV file is kept once fetched, what it is fetched from,
-- and the command that fetches it into a folder. nil when it cannot be.
local function source_of(what)
    local opts = options()
    if what.kind == "drive" and opts.rclone_remote then
        -- Kept by id: a file renamed in Drive is still the same file, and
        -- still already here.
        return what.id, "Drive", function(dir)
            return { "rclone", "backend", "copyid", opts.rclone_remote, what.id, dir .. "/" }
        end
    elseif what.kind == "webdav" then
        -- Through the rclone remote rather than the address, so the password
        -- stays where rclone keeps it and no browser is asked to sign in.
        local name = vim.fn.fnamemodify(what.path, ":t")
        return "dav-" .. vim.fn.sha256(what.path):sub(1, 16), "WebDAV", function(dir)
            return { "rclone", "copyto", under(opts.webdav_remote, what.path), dir .. "/" .. name }
        end
    end
end

local function kept_file(key)
    return vim.fn.glob(cache_dir() .. "/" .. key .. "/*", false, true)[1]
end

-- One fetch per file however many ask, and a few at a time: a note of twenty
-- pictures is not twenty rclones at once.
local waiting = {} -- key -> the callbacks to answer
local queue, running = {}, 0
local AT_ONCE = 3

local function pump()
    while running < AT_ONCE and #queue > 0 do
        local job = table.remove(queue, 1)
        running = running + 1
        local dir = cache_dir() .. "/" .. job.key
        vim.fn.mkdir(dir, "p")
        M._run(job.command(dir), function(code, _, err)
            running = running - 1
            local got = vim.fn.glob(dir .. "/*", false, true)[1]
            if code ~= 0 or not got then
                vim.fn.delete(dir, "rf")
                got = nil
            end
            local callbacks = waiting[job.key]
            waiting[job.key] = nil
            for _, callback in ipairs(callbacks) do callback(got, vim.trim(err or "")) end
            pump()
        end)
    end
end

-- Fetch into the cache under `key` and call back with (file) or (nil, why).
local function fetch(key, command, callback)
    if waiting[key] then
        table.insert(waiting[key], callback)
        return
    end
    waiting[key] = { callback }
    table.insert(queue, { key = key, command = command })
    pump()
end

-- Fetch once, then view; from the cache every time after.
local function open_remote(what)
    local key, from, command = source_of(what)
    if not key then
        vim.notify("[Fzfkasten] attachments.rclone_remote is not set, so Drive links cannot be fetched.",
            vim.log.levels.WARN)
        return
    end
    local dir = cache_dir() .. "/" .. key
    local have = kept_file(key)
    if have then
        view_kept(dir, have)
        return
    end
    vim.notify("[Fzfkasten] Fetching from " .. from .. "…", vim.log.levels.INFO)
    fetch(key, command, function(file, why)
        if not file then
            vim.notify("[Fzfkasten] Could not fetch it from " .. from .. ": " .. why, vim.log.levels.ERROR)
            return
        end
        view_kept(dir, file)
    end)
end

-- --- Showing in the note -----------------------------------------------------

-- A picture of nothing, shown where one is still on its way: 1x1, clear.
local BLANK = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="

local function blank()
    local path = cache_dir() .. "/blank.png"
    if vim.fn.filereadable(path) == 0 then
        vim.fn.mkdir(cache_dir(), "p")
        local f = io.open(path, "wb")
        if not f then return nil end
        f:write(vim.base64.decode(BLANK))
        f:close()
    end
    return path
end

-- Seam for the tests: have whatever draws pictures in `note` look again.
-- snacks.image redraws a buffer on BufWinEnter.
M._redraw = function(note)
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(buf) and vim.api.nvim_buf_get_name(buf) == note then
            pcall(vim.api.nvim_exec_autocmds, "BufWinEnter", { buffer = buf })
        end
    end
end

local shown = {}  -- key -> true once its folder has been marked as opened
local failed = {} -- key -> true: not asked for again until Neovim is restarted

-- For snacks.image's `resolve`: the file to draw for the picture `src` linked
-- from the note `file`, when it is one kept in Drive or the WebDAV folder.
--
--   image = { resolve = function(file, src)
--     return require("fzfkasten.attach").resolve(file, src)
--   end }
--
-- A picture already fetched is answered at once. One that is not is fetched
-- behind the note, a blank standing in for it; the note is drawn again when it
-- arrives. nil -- for anything else, so paths and other addresses are left to
-- snacks -- and for a file that could not be fetched.
function M.resolve(file, src)
    local what = M.classify(src, file)
    if not what or (what.kind ~= "drive" and what.kind ~= "webdav") then return nil end
    local key, _, command = source_of(what)
    if not key or failed[key] then return nil end
    local have = kept_file(key)
    if have then
        if not shown[key] then
            shown[key] = true
            local now = os.time()
            vim.uv.fs_utime(cache_dir() .. "/" .. key, now, now)
        end
        return have
    end
    shown[key] = true
    fetch(key, command, function(got)
        if not got then failed[key] = true end
        M._redraw(file)
    end)
    return blank()
end

-- Open whatever the link under the cursor points at. True when there was one.
function M.open_under_cursor()
    local line = vim.api.nvim_get_current_line()
    local col = vim.api.nvim_win_get_cursor(0)[2] + 1
    local what = M.classify(M.target_at(line, col), vim.api.nvim_buf_get_name(0))
    if not what then return false end
    if what.kind == "drive" or what.kind == "webdav" then
        open_remote(what)
    elseif what.kind == "web" then
        M.view(what.url)
    elseif vim.fn.filereadable(what.path) == 1 then
        M.view(what.path)
    else
        vim.notify("[Fzfkasten] There is no file at " .. what.path, vim.log.levels.WARN)
    end
    return true
end

-- --- Adding -----------------------------------------------------------------

local PICTURES = { jpg = true, jpeg = true, png = true, gif = true, webp = true, heic = true, bmp = true }

-- The name Notejo would give it: the note's name, the moment, the file's own
-- extension. Readable in the folder, and in order.
function M.name_for(note_path, file, now)
    local stem = vim.fn.fnamemodify(note_path, ":t:r")
    stem = stem:gsub("[^%w_%-\128-\255]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
    if stem == "" then stem = "note" end
    local ext = vim.fn.fnamemodify(file, ":e"):lower()
    return stem .. "-" .. os.date("%Y%m%d-%H%M%S", now or os.time()) .. (ext ~= "" and ("." .. ext) or "")
end

-- The markdown for a link to `target`: shown in place for a picture, named for
-- anything else.
function M.link_for(file, target)
    local ext = vim.fn.fnamemodify(file, ":e"):lower()
    if PICTURES[ext] then return "![](" .. target .. ")" end
    return "[" .. vim.fn.fnamemodify(file, ":t"):gsub("%]", "\\]") .. "](" .. target .. ")"
end

-- `target` as a link written in the note at `from` names it.
function M.relative(from, target)
    -- A note at the top has "." for a folder, which is no folder at all.
    local here = vim.tbl_filter(function(part) return part ~= "." end,
        vim.split(vim.fn.fnamemodify(from, ":h"), "/", { trimempty = true }))
    local there = vim.split(target, "/", { trimempty = true })
    local common = 0
    while common < #here and common < #there - 1 and here[common + 1] == there[common + 1] do
        common = common + 1
    end
    local parts = {}
    for _ = common + 1, #here do table.insert(parts, "..") end
    for i = common + 1, #there do table.insert(parts, there[i]) end
    return table.concat(parts, "/")
end

-- Put `text` into `buf` at the (0-based) position the cursor was at when the
-- attaching began -- the upload takes seconds, and the cursor may have moved.
local function insert_at(buf, row, col, text)
    if not vim.api.nvim_buf_is_valid(buf) then return end
    vim.api.nvim_buf_set_text(buf, row, col, row, col, { text })
end

-- Where the cursor is now. Taken before anything slow or anything that takes
-- the window away: an upload, the list of files.
local function place()
    local buf = vim.api.nvim_get_current_buf()
    local cursor = vim.api.nvim_win_get_cursor(0)
    local row, col = cursor[1] - 1, cursor[2] + 1
    col = math.min(col, #vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1])
    return { buf = buf, note = vim.api.nvim_buf_get_name(buf), row = row, col = col }
end

-- A name in `dir` that no file has yet: an attachment never replaces another.
local function unused(dir, name)
    local stem, ext = name:match("^(.*)(%.[^.]+)$")
    if not stem then stem, ext = name, "" end
    local candidate, n = name, 1
    while vim.uv.fs_stat(dir .. "/" .. candidate) do
        n = n + 1
        candidate = stem .. "-" .. n .. ext
    end
    return candidate
end

local function send(what, file, where, on_sent)
    vim.notify("[Fzfkasten] Sending to " .. what .. "…", vim.log.levels.INFO)
    M._run({ "rclone", "copyto", file, where }, function(code, _, err)
        if code ~= 0 then
            vim.notify("[Fzfkasten] Could not send it to " .. what .. ": " .. vim.trim(err), vim.log.levels.ERROR)
            return
        end
        on_sent()
    end)
end

local function attach_at(file, at)
    local opts = options()
    file = vim.fn.expand(file or "")
    if file == "" or vim.fn.filereadable(file) == 0 then
        vim.notify("[Fzfkasten] No file at " .. file, vim.log.levels.ERROR)
        return
    end
    local name = M.name_for(at.note, file)
    local function link(target)
        insert_at(at.buf, at.row, at.col, M.link_for(file, target))
    end

    if opts.home == "repository" then
        local folder = (opts.repo_folder or "attachments"):gsub("/+$", "")
        local into = config.options.home .. "/" .. folder
        vim.fn.mkdir(into, "p")
        name = unused(into, name)
        local ok = vim.uv.fs_copyfile(file, into .. "/" .. name)
        if not ok then
            vim.notify("[Fzfkasten] Could not copy it into " .. into, vim.log.levels.ERROR)
            return
        end
        local rel_note = at.note:sub(#config.options.home + 2)
        link(M.relative(rel_note, folder .. "/" .. name))
    elseif opts.home == "drive" then
        if not opts.rclone_remote then
            vim.notify("[Fzfkasten] attachments.rclone_remote is not set.", vim.log.levels.WARN)
            return
        end
        local folder = under(opts.rclone_remote, opts.drive_folder or "Notejo")
        send("Drive", file, folder .. "/" .. name, function()
            -- The link is to the file's id, so it survives being moved or
            -- renamed in Drive -- and it is the same link Notejo writes.
            M._run({ "rclone", "lsjson", folder, "--files-only", "--include", "/" .. name },
                function(listed, out)
                    local ok, entries = pcall(vim.json.decode, out)
                    local id = listed == 0 and ok and entries[1] and entries[1].ID
                    if not id then
                        vim.notify("[Fzfkasten] Sent, but Drive did not say where: " .. folder .. "/" .. name,
                            vim.log.levels.WARN)
                        return
                    end
                    link("https://drive.google.com/file/d/" .. id .. "/view")
                end)
        end)
    elseif opts.home == "webdav" then
        if not opts.webdav_remote or not opts.webdav_url then
            vim.notify("[Fzfkasten] attachments.webdav_remote and attachments.webdav_url are both needed.",
                vim.log.levels.WARN)
            return
        end
        -- The address Notejo writes for the same file: the folder's, then the name.
        send("WebDAV", file, under(opts.webdav_remote, name), function()
            link(opts.webdav_url:gsub("/+$", "") .. "/" .. M.encode(name))
        end)
    end
end

-- --- Choosing ---------------------------------------------------------------

-- The files in the `pick_from` folders and one level below them, newest first:
-- { path = ..., mtime = ... }. What was just saved or captured is at the top.
function M.candidates()
    local opts = options()
    local found = {}
    local function scan(dir, depth)
        for name, kind in vim.fs.dir(dir) do
            local path = dir .. "/" .. name
            if name:sub(1, 1) ~= "." then
                if kind == "link" then
                    local st = vim.uv.fs_stat(path)
                    kind = st and st.type or kind
                end
                if kind == "file" then
                    local st = vim.uv.fs_stat(path)
                    if st then table.insert(found, { path = path, mtime = st.mtime.sec }) end
                elseif kind == "directory" and depth < 1 then
                    scan(path, depth + 1)
                end
            end
        end
    end
    for _, dir in ipairs(opts.pick_from or {}) do
        dir = vim.fs.normalize(vim.fn.expand(dir))
        if vim.fn.isdirectory(dir) == 1 then scan(dir, 0) end
    end
    table.sort(found, function(a, b)
        if a.mtime ~= b.mtime then return a.mtime > b.mtime end
        return a.path < b.path
    end)
    for i = #found, (opts.pick_limit or 300) + 1, -1 do found[i] = nil end
    return found
end

-- Seam for the tests: show `entries` and call back with the one chosen.
-- `remote` entries are names of files that are not here, so nothing to preview.
M._choose = function(entries, on_choice, remote)
    require("fzf-lua").fzf_exec(entries, vim.tbl_deep_extend("force", config.options.fzf or {}, {
        prompt = remote and "Link> " or "Attach> ",
        previewer = not remote and "builtin" or false,
        winopts = remote and { preview = { hidden = "hidden" } } or nil,
        fzf_opts = remote and { ["--no-sort"] = "" } or {
            ["--delimiter"] = ":",
            ["--with-nth"] = "3..",
            ["--no-sort"] = "",
        },
        actions = {
            ["default"] = function(selected)
                if selected and selected[1] then on_choice(selected[1]) end
            end,
        },
    }))
end

local function pick(at)
    local found = M.candidates()
    if #found == 0 then
        vim.notify("[Fzfkasten] No files in attachments.pick_from. Name one: :FzfKastenAttach {file}",
            vim.log.levels.WARN)
        return
    end
    local entries, lookup = {}, {}
    for _, file in ipairs(found) do
        -- `path:1:` is for the previewer; what is read starts after it.
        local entry = string.format("%s:1: %s  %s", file.path, os.date("%m-%d %H:%M", file.mtime),
            vim.fn.fnamemodify(file.path, ":~"))
        table.insert(entries, entry)
        lookup[entry] = file.path
    end
    M._choose(entries, function(entry)
        if lookup[entry] then attach_at(lookup[entry], at) end
    end)
end

-- "2026-11-15T02:42:03.043Z", as rclone writes a moment, in this machine's time.
local function local_stamp(iso)
    local y, mo, d, h, mi, sec = (iso or ""):match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
    if not y then return "" end
    local now = os.time()
    local offset = os.difftime(now, os.time(os.date("!*t", now)))
    local t = os.time({ year = y, month = mo, day = d, hour = h, min = mi, sec = sec, isdst = false }) + offset
    return os.date("%m-%d %H:%M", t)
end

-- Link a file that is already in the Drive folder or the WebDAV one -- sent
-- from the phone, dropped there by hand -- without sending anything: list the
-- folder newest first, and write the link to the one chosen at the cursor.
function M.link_existing()
    local opts = options()
    local folder, target
    if opts.home == "webdav" and opts.webdav_remote and opts.webdav_url then
        folder = opts.webdav_remote
        target = function(entry) return opts.webdav_url:gsub("/+$", "") .. "/" .. M.encode(entry.Name) end
    elseif opts.rclone_remote then
        folder = under(opts.rclone_remote, opts.drive_folder or "Notejo")
        target = function(entry) return entry.ID and ("https://drive.google.com/file/d/" .. entry.ID .. "/view") end
    else
        vim.notify("[Fzfkasten] attachments.rclone_remote is not set, so there is no folder to list.",
            vim.log.levels.WARN)
        return
    end
    local at = place()
    M._run({ "rclone", "lsjson", folder, "--files-only", "--no-mimetype" }, function(code, out, err)
        local ok, files = pcall(vim.json.decode, out)
        if code ~= 0 or not ok or type(files) ~= "table" then
            vim.notify("[Fzfkasten] Could not list " .. folder .. ": " .. vim.trim(err), vim.log.levels.ERROR)
            return
        end
        if #files == 0 then
            vim.notify("[Fzfkasten] Nothing in " .. folder .. " yet.", vim.log.levels.INFO)
            return
        end
        table.sort(files, function(a, b)
            if a.ModTime ~= b.ModTime then return (a.ModTime or "") > (b.ModTime or "") end
            return a.Name < b.Name
        end)
        local entries, lookup = {}, {}
        for _, file in ipairs(files) do
            local entry = local_stamp(file.ModTime) .. "  " .. file.Name
            if not lookup[entry] then
                table.insert(entries, entry)
                lookup[entry] = file
            end
        end
        M._choose(entries, function(entry)
            local file = lookup[entry]
            local to = file and target(file)
            if to then insert_at(at.buf, at.row, at.col, M.link_for(file.Name, to)) end
        end, true)
    end)
end

-- Add `file` to the collection's attachment home and link it at the cursor.
-- Without one, choose among the newest files in `attachments.pick_from`.
function M.attach(file)
    local home = options().home
    if home ~= "drive" and home ~= "webdav" and home ~= "repository" then
        vim.notify("[Fzfkasten] Set attachments.home to \"drive\", \"webdav\" or \"repository\" first.",
            vim.log.levels.WARN)
        return
    end
    local at = place()
    if file == nil or file == "" then
        pick(at)
    else
        attach_at(file, at)
    end
end

return M
