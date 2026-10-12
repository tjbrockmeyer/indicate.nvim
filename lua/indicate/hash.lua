--- Content hashing of the files matching an indicator's glob patterns.
---
--- A hash is the sha256 of a sorted list of `relative-path\0sha256(contents)`
--- entries. Individual file hashes are cached in memory and keyed by
--- (size, mtime), so repeated refreshes only re-read files that changed.
local M = {}

--- @type table<string, { size: integer, mtime: integer, hash: string }>
local cache = {}

--- Drop the in memory file hash cache.
function M.clear()
	cache = {}
end

local function is_ignored(path)
	return path:find("/%.git/", 1) ~= nil
		or path:find("/%.jj/", 1) ~= nil
		or path:find("/%.indicate/", 1) ~= nil
end

--- Expand the glob patterns (relative to `cwd`) into a sorted list of files.
--- Directories, symlinked directories and files inside `.git`, `.jj` and
--- `.indicate` are skipped.
--- @param cwd string
--- @param patterns string[]
--- @return string[] absolute paths
function M.files(cwd, patterns)
	local seen, files = {}, {}
	for _, pattern in ipairs(patterns or {}) do
		if type(pattern) == "string" and pattern ~= "" then
			local absolute = pattern
			if not vim.startswith(pattern, "/") and not pattern:match("^%a:[/\\]") then
				absolute = vim.fs.joinpath(cwd, pattern)
			end
			for _, match in ipairs(vim.fn.glob(absolute, false, true)) do
				local path = vim.fs.normalize(match)
				if
					not seen[path]
					and not is_ignored(path)
					and vim.fn.isdirectory(path) == 0
					and vim.fn.filereadable(path) == 1
				then
					seen[path] = true
					files[#files + 1] = path
				end
			end
		end
	end
	table.sort(files)
	return files
end

--- @param path string
--- @return string? sha256 of the file contents
local function file_hash(path)
	local stat = vim.uv.fs_stat(path)
	if not stat or stat.type ~= "file" then
		return nil
	end
	local mtime = 0
	if stat.mtime then
		mtime = stat.mtime.sec * 1000 + math.floor((stat.mtime.nsec or 0) / 1000000)
	end
	local entry = cache[path]
	if entry and entry.size == stat.size and entry.mtime == mtime then
		return entry.hash
	end
	local fd = io.open(path, "rb")
	if not fd then
		return nil
	end
	local contents = fd:read("*a")
	fd:close()
	if not contents then
		return nil
	end
	local digest = vim.fn.sha256(contents)
	cache[path] = { size = stat.size, mtime = mtime, hash = digest }
	return digest
end

--- Hash of every file matched by `patterns` (relative to `cwd`).
--- @param cwd string
--- @param patterns string[]
--- @return string hash, integer count
function M.hash(cwd, patterns)
	local parts = {}
	for _, path in ipairs(M.files(cwd, patterns)) do
		local digest = file_hash(path)
		if digest then
			parts[#parts + 1] = (vim.fs.relpath(cwd, path) or path) .. "\0" .. digest
		end
	end
	return vim.fn.sha256(table.concat(parts, "\n")), #parts
end

return M
