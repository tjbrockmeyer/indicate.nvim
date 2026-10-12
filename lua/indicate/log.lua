--- Debug/performance logging for Indicate.
---
--- When the `debug` option is enabled, the operations that can plausibly take a
--- long time (walking the tree, reading and hashing files, spawning the
--- `git`/`jj` processes, rendering the panel, ...) are timed and appended to
--- `<repo>/.indicate/indicate.log`. Nested operations are indented, so a slow
--- outer operation can be traced back to the inner one that dominates it:
---
---     2025-06-01 10:00:00 | panel.refresh: 18.40 ms
---     2025-06-01 10:00:00 |   state.status(unit tests): 15.10 ms
---     2025-06-01 10:00:00 |     hash.hash: 14.90 ms (1203 file(s))
---     2025-06-01 10:00:00 |       hash.files: 9.70 ms (1203 file(s))
---
--- Nothing is written while `debug` is off. The `git`/`jj` lookups happen
--- before the `.indicate` directory is known, so those lines are buffered and
--- flushed as soon as the directory is set (see `set_dir`). The log rotates to
--- `indicate.log.1` once it grows past `max_bytes`.
local opts = require("indicate.opts")

local M = {}

local uv = vim.uv or vim.loop

--- Rotate the log file once it grows past this many bytes.
local max_bytes = 2 * 1024 * 1024

--- Maximum number of lines buffered before `.indicate` is known.
local max_pending = 500

local unpack = table.unpack or unpack
local pack = table.pack or function(...)
	return { n = select("#", ...), ... }
end

--- @type string? directory the log is written to (the `.indicate` directory)
local dir
--- @type integer? open append handle
local fd
--- @type integer current nesting depth, used for indentation
local depth = 0
--- @type string[] lines logged before `dir` was known
local pending = {}

--- Whether timing information is collected (see `opts.debug`).
--- @return boolean
function M.enabled()
	return opts.debug == true
end

--- @return string? path of the log file
function M.path()
	if not dir then
		return nil
	end
	return vim.fs.joinpath(dir, "indicate.log")
end

--- @return string
local function nvim_version()
	local ok, v = pcall(vim.version)
	if ok and type(v) == "table" then
		return ("%d.%d.%d"):format(v.major or 0, v.minor or 0, v.patch or 0)
	end
	return "?"
end

--- @return integer? open handle
local function open_fd()
	if fd then
		return fd
	end
	local path = M.path()
	if not path then
		return nil
	end
	pcall(vim.fn.mkdir, dir, "p")
	local stat = uv.fs_stat(path)
	if stat and (stat.size or 0) > max_bytes then
		pcall(uv.fs_rename, path, path .. ".1")
	end
	fd = uv.fs_open(path, "a", 420)
	if fd then
		local pid = uv.os_getpid and uv.os_getpid() or 0
		uv.fs_write(
			fd,
			("\n==== Indicate %s · nvim %s · pid %d · cwd %s ====\n"):format(
				os.date("%Y-%m-%d %H:%M:%S"),
				nvim_version(),
				pid,
				uv.cwd() or "?"
			)
		)
	end
	return fd
end

--- @param line string
local function append(line)
	if not M.enabled() then
		return
	end
	if not dir then
		pending[#pending + 1] = line
		if #pending > max_pending then
			table.remove(pending, 1)
		end
		return
	end
	local handle = open_fd()
	if handle then
		uv.fs_write(handle, line .. "\n")
	end
end

--- @param level integer
--- @param message string
local function emit(level, message)
	append(("%s |%s %s"):format(os.date("%Y-%m-%d %H:%M:%S"), string.rep("  ", math.max(level, 0)), message))
end

--- Point the log at the `.indicate` directory of the current repository and
--- flush anything logged before the directory was known.
--- @param value string?
function M.set_dir(value)
	if not M.enabled() or type(value) ~= "string" or value == "" then
		return
	end
	value = vim.fs.normalize(value)
	if value == dir then
		return
	end
	local buffered = pending
	pending = {}
	if fd then
		pcall(uv.fs_close, fd)
		fd = nil
	end
	dir = value
	for _, line in ipairs(buffered) do
		append(line)
	end
end

--- Append a message at the current nesting depth.
--- @param fmt string
function M.line(fmt, ...)
	if not M.enabled() then
		return
	end
	local message = select("#", ...) > 0 and string.format(fmt, ...) or fmt
	emit(depth, message)
end

--- @return integer nanosecond timestamp (`uv.hrtime`)
function M.now()
	return uv.hrtime()
end

--- @param start integer a value returned by `now`
--- @return number milliseconds since `start`
function M.elapsed(start)
	return (uv.hrtime() - start) / 1e6
end

--- @class indicate.LogToken
--- @field label string
--- @field start integer
--- @field depth integer

--- Begin timing `label`. Returns nil while logging is disabled.
--- @param label string
--- @return indicate.LogToken?
function M.start(label)
	if not M.enabled() then
		return nil
	end
	local token = { label = label, start = uv.hrtime(), depth = depth }
	depth = depth + 1
	return token
end

--- Stop a token from `start` and log how long it took.
--- @param token indicate.LogToken?
--- @param fmt string? optional note appended to the line
function M.stop(token, fmt, ...)
	if not token then
		return
	end
	depth = depth - 1
	local ms = (uv.hrtime() - token.start) / 1e6
	local note = ""
	if fmt then
		note = " " .. string.format(fmt, ...)
	end
	emit(token.depth, ("%s: %.2f ms%s"):format(token.label, ms, note))
end

--- Time `fn(...)`, log how long it took and return its results unchanged.
--- @param label string
--- @param fn function
--- @return ...
function M.measure(label, fn, ...)
	if not M.enabled() then
		return fn(...)
	end
	local args = pack(...)
	local token = M.start(label)
	local ok, results = xpcall(function()
		return pack(fn(unpack(args, 1, args.n)))
	end, debug.traceback)
	M.stop(token)
	if not ok then
		error(results, 0)
	end
	return unpack(results, 1, results.n)
end

--- Wrap `fn` so every call is timed and logged under `label`.
--- @param label string
--- @param fn function
--- @return function
function M.wrap(label, fn)
	return function(...)
		return M.measure(label, fn, ...)
	end
end

--- Flush and close the log file (call on `VimLeavePre`).
function M.close()
	if fd then
		pcall(uv.fs_close, fd)
		fd = nil
	end
end

return M
