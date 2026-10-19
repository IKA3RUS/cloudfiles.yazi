--- @since 26.9.1

-- cloudfiles.yazi
-- Makes yazi aware of macOS cloud placeholders: files a File Provider client
-- (SeaDrive, iCloud Drive, Dropbox, OneDrive, Google Drive, ...) lists but
-- hasn't downloaded. macOS flags them `dataless`, and reading even one byte
-- fetches the whole file, so nothing may read them just because they're on
-- screen.
--
-- * fetch: give placeholders the MIME type `cloud/placeholder` without reading
--          them. No previewer or preloader matches it, so nothing downloads
--          them; local files fall through to yazi's own `mime.local`.
-- * entry: download placeholders in the background, then open them
-- * peek:  show a card for placeholders instead of a preview
--
-- Everything that crosses into a sync block or `ya.emit` is a plain path
-- string: yazi moves Url userdata passed there, and the caller's copy is
-- destroyed.

local MIME = "cloud/placeholder"
-- Marker sets: Nerd Font (md-cloud_outline, md-cloud_download), and plain
-- text for terminals without one. A terminal can't report its font, so the
-- user picks with `nerd_font = false`.
local ICONS = {
	nerd = { cloud = "\u{F0163}", downloading = "\u{F0162}" },
	text = { cloud = "○", downloading = "◐" },
}
local PARALLEL = 3 -- concurrent downloads, across all presses
local RETRY_WAIT = { 1, 1, 1, 10, 30, 60 } -- seconds before each retry of a failed download

---------------------------------------------------------------------------
-- Shared state (sync context)
---------------------------------------------------------------------------

-- st.downloading[path] = true while a download runs; st.active counts them.

-- Marks paths as downloading and returns the ones that weren't already.
local claim = ya.sync(function(st, paths)
	st.downloading = st.downloading or {}
	local fresh = {}
	for _, p in ipairs(paths) do
		if not st.downloading[p] then
			st.downloading[p] = true
			fresh[#fresh + 1] = p
		end
	end
	st.active = (st.active or 0) + #fresh
	ui.render()
	return fresh
end)

local release = ya.sync(function(st, path)
	if st.downloading and st.downloading[path] then
		st.downloading[path] = nil
		st.active = math.max(0, (st.active or 0) - 1)
		ui.render()
	end
end)

-- Download slots shared by every press, so PARALLEL is a global limit.
local take_slot = ya.sync(function(st)
	if (st.running or 0) >= PARALLEL then
		return false
	end
	st.running = (st.running or 0) + 1
	return true
end)

local free_slot = ya.sync(function(st) st.running = math.max(0, (st.running or 0) - 1) end)

local get_card = ya.sync(function(st) return st.icon or ICONS.nerd.cloud, st.center end)

-- Paths of the selected files, or of the hovered file if nothing is selected.
-- The second value is true when nothing is selected and a directory is hovered.
local get_targets = ya.sync(function()
	local tab, paths = cx.active, {}
	for _, u in pairs(tab.selected) do
		paths[#paths + 1] = tostring(u.path)
	end
	if #paths == 0 then
		local h = tab.current.hovered
		if not h then
			return {}, false
		elseif h.cha.is_dir then
			return {}, true
		end
		paths[1] = tostring(h.url.path)
	end
	return paths, false
end)

---------------------------------------------------------------------------
-- Helpers (async context)
---------------------------------------------------------------------------

-- Returns { [path] = true } for every path that is a dataless placeholder.
-- `stat` only reads metadata, so it never triggers a download.
local function dataless(paths)
	local res = {}
	if #paths == 0 then
		return res
	end

	local out = Command("stat"):arg({ "-f", "%Sf", "--" }):arg(paths):output()
	if not out then
		return res
	elseif not out.status.success then
		-- stat prints nothing for a path it can't read, so the lines no longer
		-- line up with `paths`. Rare (a file just vanished): ask one at a time.
		if #paths > 1 then
			for _, p in ipairs(paths) do
				res[p] = dataless({ p })[p]
			end
		end
		return res
	end

	local i = 0
	for line in out.stdout:gmatch("[^\n]+") do
		i = i + 1
		if paths[i] and line:find("dataless", 1, true) then
			res[paths[i]] = true
		end
	end
	return res
end

-- Swaps `cloud/placeholder` for the real MIME type of files that are local
-- now, using the same `file` call and parsing as yazi's own mime.local. yazi
-- then re-peeks the hovered file and re-runs preloaders for the updated ones.
local function refresh(paths)
	local ml = require("mime.local")
	local out = Command(ml.file1_bin()):arg({ "-bL", "--mime-type", "--" }):arg(paths):output()

	-- Keep each line's newline: match_mimetype expects it, as `file` emits it.
	local lines, i = {}, 0
	for line in (out and out.stdout or ""):gmatch("[^\n]*\n") do
		i = i + 1
		lines[i] = line
	end

	local updates = {}
	for j, p in ipairs(paths) do
		updates[Url(p)] = lines[j] and ml.match_mimetype(lines[j]) or "application/octet-stream"
	end
	ya.emit("update_mimes", { updates = updates })
end

local function open(paths, interactive)
	local args = { interactive = interactive }
	for i, p in ipairs(paths) do
		args[i] = Url(p)
	end
	ya.emit("open", args)
end

local function basename(p) return p:match("[^/]+$") or p end


-- Runs another fetcher on `files` from inside our coroutine, passing its
-- results through (the same pattern yazi's mime.remote uses).
local function forward(name, job, files)
	local resume = require(name):fetch(ya.dict_merge(job, { files = files }))
	local file, result = resume()
	while file do
		file, result = resume(coroutine.yield(file, result))
	end
end

---------------------------------------------------------------------------
-- UI (setup runs once from init.lua)
---------------------------------------------------------------------------

local function setup(st, opts)
	opts = opts or {}
	st.downloading = st.downloading or {}
	st.active = st.active or 0
	local set = opts.nerd_font == false and ICONS.text or ICONS.nerd
	st.icon = opts.icon or set.cloud
	st.center = opts.center or false
	local down = opts.downloading or set.downloading

	local color = opts.color or "blue"
	local style = ui.Style():fg(color)

	-- Themes often draw the hovered row reversed, which would turn a colored
	-- icon into a colored block. Pre-swap fg and bg there so the reversal
	-- swaps them back: a colored icon on the row's own highlight color.
	local function marker(f, icon)
		local s = style
		if f.is_hovered then
			local row = Entity:new(f):style()
			if row:raw().reversed then
				s = ui.Style():fg(row:fg() or "reset"):bg(color)
			end
		end
		return ui.Line { " ", ui.Span(icon .. " "):style(s) }
	end

	-- Cloud / download marker in the file list. The trailing space is part of
	-- the span so the icon always has an empty cell after it: terminals like
	-- Ghostty draw Nerd Font icons two cells wide only when the next cell is
	-- blank, and themes may put a padding glyph there on the hovered row.
	Linemode:children_add(function(self)
		local f = self._file
		if not f.in_current then
			return ""
		elseif st.downloading[tostring(f.url.path)] then
			return marker(f, down)
		elseif f:mime() == MIME then
			return marker(f, st.icon)
		end
		return ""
	end, opts.order or 500) -- before the linemode (solo, 1000)

	-- Active download count in the status bar
	Status:children_add(function()
		if st.active == 0 then
			return ""
		end
		return ui.Line { ui.Span(string.format(" %s  %d ", down, st.active)):style(style) }
	end, opts.status_order or 500, Status.RIGHT)
end

---------------------------------------------------------------------------
-- Fetcher: MIME types without reading placeholders
---------------------------------------------------------------------------

local function fetch(_, job)
	return ya.co(function()
		local paths = {}
		for _, f in ipairs(job.files) do
			if not f.cha.is_dummy then
				paths[#paths + 1] = tostring(f.path)
			end
		end

		local cloud, updates, rest = dataless(paths), {}, {}
		for _, f in ipairs(job.files) do
			if cloud[tostring(f.path)] then
				if coroutine.yield(f, { MIME }) then
					updates[f.url] = MIME
				end
			else
				rest[#rest + 1] = f
			end
		end

		if next(updates) then
			ya.emit("update_mimes", { updates = updates })
		end
		if #rest > 0 then
			forward("mime.local", job, rest)
		end
	end)
end

---------------------------------------------------------------------------
-- Functional plugin: download if needed, then open
---------------------------------------------------------------------------

local function entry(_, job)
	local interactive = job.args.interactive and true or nil
	local targets, hovered_dir = get_targets()

	local cloud, todo = dataless(targets), {}
	for _, p in ipairs(targets) do
		if cloud[p] then
			todo[#todo + 1] = p
		end
	end

	-- Nothing to download: behave exactly like the normal open.
	if hovered_dir or #todo == 0 then
		return ya.emit("open", { interactive = interactive })
	end

	-- Placeholders an earlier press is still downloading get opened by that
	-- press when they land, so leave them out of this one.
	local fresh, busy, mine = claim(todo), {}, {}
	for _, p in ipairs(todo) do
		busy[p] = true
	end
	for _, p in ipairs(fresh) do
		busy[p] = nil
	end
	for _, p in ipairs(targets) do
		if not busy[p] then
			mine[#mine + 1] = p
		end
	end

	if #fresh == 0 then
		if #mine > 0 then
			open(mine, interactive)
		end
		return
	end

	-- Download a few at a time; each marker clears as soon as its own file
	-- lands. Reading one byte makes macOS fetch the whole file from the provider.
	local ok, n = {}, 0
	local function worker()
		while n < #fresh do
			n = n + 1
			local p = fresh[n]
			for attempt = 1, #RETRY_WAIT + 1 do
				while not take_slot() do
					ya.sleep(0.2)
				end
				local status = Command("head"):arg({ "-c1", "--", p }):stdout(Command.NULL):stderr(Command.NULL):status()
				free_slot()
				ok[p] = status ~= nil and status.success
				if ok[p] or attempt > #RETRY_WAIT then
					break
				end
				-- SeaDrive refuses a download within milliseconds while it is still
				-- re-listing a folder that changed on the server (File Provider
				-- error -2005), and accepts it a few seconds later.
				ya.sleep(RETRY_WAIT[attempt])
			end
			release(p)
		end
	end
	local workers = {}
	for i = 1, math.min(PARALLEL, #fresh) do
		workers[i] = worker
	end
	ya.join(table.unpack(workers))

	local done, failed = {}, {}
	for _, p in ipairs(fresh) do
		if ok[p] then
			done[#done + 1] = p
		else
			failed[#failed + 1] = basename(p)
		end
	end

	if #failed > 0 then
		ya.notify {
			title = "Uh Oh!",
			content = table.concat(failed, ", ") .. "\nIs the sync app running and online?",
			timeout = 8,
			level = "error",
		}
	end

	if #done > 0 then
		refresh(done)
	end

	-- Open everything from this press that is local now, through yazi's own
	-- open rules. Failed placeholders stay behind (and keep their cloud marker).
	local now = {}
	for _, p in ipairs(mine) do
		if ok[p] ~= false then
			now[#now + 1] = p
		end
	end
	if #now > 0 then
		open(now, interactive)
	end
end

---------------------------------------------------------------------------
-- Previewer: a card instead of reading (and downloading) the file
---------------------------------------------------------------------------

local function peek(_, job)
	local p = tostring(job.file.path)
	if not dataless({ p })[p] then
		-- Downloaded outside yazi since its MIME type was set. Fixing the type
		-- makes yazi re-peek with the previewer it normally uses.
		return refresh({ p })
	end

	local icon, center = get_card()
	local lines = {
		ui.Line(icon .. "  " .. ya.readable_size(job.file.cha.len)),
		ui.Line("Press Enter to download and open."),
	}
	local area = job.area
	if center then
		local top = math.max(0, math.floor((area.h - #lines) / 2))
		area = ui.Rect { x = area.x, y = area.y + top, w = area.w, h = area.h - top }
	end
	local text = ui.Text(lines):area(area):wrap(ui.Wrap.YES)
	ya.preview_widget(job, center and text:align(ui.Align.CENTER) or text)
end

local function seek() end

return {
	setup = setup,
	fetch = fetch,
	entry = entry,
	peek = peek,
	seek = seek,
}
