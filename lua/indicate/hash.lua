--- Content hashing of the files matching an indicator's glob patterns.
---
--- A hash is the sha256 of a sorted list of `relative-path\0sha256(contents)`
--- entries. Individual file hashes are cached in memory and keyed by
--- (size, mtime), so repeated refreshes only re-read files that changed.
---
--- The matched file list is cached as well, together with the mtimes of the
--- directories that were walked. It is reused until one of those directories
--- changes (a file added, removed or renamed) or the entry expires, so a
--- refresh that only sees content edits never walks the tree. The files are
--- collected by walking the tree below the static prefix of each pattern
--- instead of expanding the pattern with `glob()`, so the directories in
--- `always_ignore`, `.gitignore`d directories and symlinked directories are
--- never descended into. See `indicate/glob.lua` for the pattern matching.
local gitignore = require("indicate.gitignore")
local glob = require("indicate.glob")
local log = require("indicate.log")

local M = {}

--- @type table<string, { size: integer, mtime: integer, hash: string }>
local cache = {}

--- Matched file lists, keyed by `cwd\0root\0patterns`.
--- @type table<string, { files: string[], dirs: table<string, integer|false>, time: integer }>
local list_cache = {}
local list_cache_size = 0
--- Drop the whole list cache once it holds this many entries.
local list_cache_max = 256
--- Re-walk a cached list at most this often (ns), as a safety net for
--- filesystems whose directory mtimes cannot be trusted.
local list_cache_ttl = 300 * 1e9

--- Directories that only ever hold generated or third party files, so they are
--- never walked into. Patterns matching files inside them find nothing.
local always_ignore = {
	[".git"] = true,
	[".jj"] = true,
	[".indicate"] = true,
	[".venv"] = true,
	[".cache"] = true,
	[".gradle"] = true,
	[".mypy_cache"] = true,
	[".next"] = true,
	[".nuxt"] = true,
	[".parcel-cache"] = true,
	[".pytest_cache"] = true,
	[".ruff_cache"] = true,
	[".tox"] = true,
	[".turbo"] = true,
	["__pycache__"] = true,
	["node_modules"] = true,
	["venv"] = true,
}

--- @param stat vim.uv.fs_stat.result?
--- @return integer? mtime in milliseconds
local function mtime_ms(stat)
	if not stat or not stat.mtime then
		return nil
	end
	return stat.mtime.sec * 1000 + math.floor((stat.mtime.nsec or 0) / 1000000)
end

--- Drop the in memory file hash and file list caches.
function M.clear()
	cache = {}
	list_cache = {}
	list_cache_size = 0
end

local function is_ignored(path)
	return path:find("/%.git/", 1) ~= nil
		or path:find("/%.jj/", 1) ~= nil
		or path:find("/%.indicate/", 1) ~= nil
end

--- @class indicate.WalkStats
--- @field dirs integer directories scanned
--- @field entries integer directory entries visited
--- @field lstat integer entries whose type needed an `lstat`
--- @field mtimes table<string, integer|false> mtime of every scanned directory

--- @param stats indicate.WalkStats
--- @param dir string
local function record_dir(stats, dir)
	stats.mtimes[dir] = mtime_ms(vim.uv.fs_stat(dir)) or false
end

--- Recursively visit the files below `dir`, without descending into pruned
--- directories. Symlinked directories are not followed: doing so can duplicate
--- whole trees and even loop forever.
--- @param dir string
--- @param parts string[] components of `dir` below the search root
--- @param ctx indicate.IgnoreFrame[] gitignore context of `dir`
--- @param visit fun(path: string, parts: string[])
--- @param prune fun(dir: string, name: string, parts: string[], ctx: indicate.IgnoreFrame[]): boolean
--- @param stats indicate.WalkStats
local function walk(dir, parts, ctx, visit, prune, stats)
	record_dir(stats, dir)
	stats.dirs = stats.dirs + 1
	local handle = vim.uv.fs_scandir(dir)
	if not handle then
		return
	end
	while true do
		local name, kind = vim.uv.fs_scandir_next(handle)
		if not name then
			break
		end
		stats.entries = stats.entries + 1
		local path = dir .. "/" .. name
		if kind == nil then
			stats.lstat = stats.lstat + 1
			local lstat = vim.uv.fs_lstat(path)
			kind = lstat and lstat.type or nil
		end
		parts[#parts + 1] = name
		if kind == "directory" then
			local child = gitignore.descend(ctx, name)
			if not prune(path, name, parts, child) then
				walk(path, parts, child, visit, prune, stats)
			end
		elseif kind == "file" then
			if not is_ignored(path) and not gitignore.context_file_ignored(ctx, name) then
				visit(path, parts)
			end
		elseif kind == "link" then
			-- a symlink to a file is hashed like the file it points at
			local target = vim.uv.fs_stat(path)
			if
				target
				and target.type == "file"
				and not is_ignored(path)
				and not gitignore.context_file_ignored(ctx, name)
			then
				visit(path, parts)
			end
		end
		parts[#parts] = nil
	end
end

--- @param component string
--- @return boolean
local function has_wildcard(component)
	return component:find("*", 1, true) ~= nil
		or component:find("?", 1, true) ~= nil
		or component:find("[", 1, true) ~= nil
end

--- Split an absolute pattern into the directory to start walking in and the
--- components that have to match the path below it.
--- @param pattern string
--- @return string? dir, (string|indicate.GlobComponent)[]? components
local function split_pattern(pattern)
	local parts = vim.split(pattern, "/", { plain = true })
	local index = 1
	while index <= #parts and not has_wildcard(parts[index]) do
		index = index + 1
	end
	if index > #parts then
		-- no wildcard at all: the pattern names one path
		return nil
	end
	local dir = table.concat(vim.list_slice(parts, 1, index - 1), "/")
	if dir == "" then
		dir = "/"
	end
	local components = {}
	for i = index, #parts do
		components[#components + 1] = parts[i] == "**" and "**" or glob.compile(parts[i])
	end
	return dir, components
end

--- @param parts string[]
--- @return boolean whether a directory component is one the walk skips
local function has_always_ignore(parts)
	for i = 1, #parts - 1 do
		if always_ignore[parts[i]] then
			return true
		end
	end
	return false
end

--- @param cwd string
--- @param patterns string[]
--- @param root string?
--- @return string
local function list_key(cwd, patterns, root)
	return table.concat({ vim.fs.normalize(cwd), root or "", table.concat(patterns or {}, "\0") }, "\0")
end

--- Whether every directory a cached list was built from still has the same
--- mtime, and the entry has not expired.
--- @param entry { files: string[], dirs: table<string, integer|false>, time: integer }
--- @return boolean
local function list_valid(entry)
	if vim.uv.hrtime() - entry.time > list_cache_ttl then
		return false
	end
	for dir, mtime in pairs(entry.dirs) do
		if (mtime_ms(vim.uv.fs_stat(dir)) or false) ~= mtime then
			return false
		end
	end
	return true
end

--- Expand the glob patterns (relative to `cwd`) into a sorted list of files.
--- @param cwd string
--- @param patterns string[]
--- @param root string? repository root (the parent of `.indicate`)
--- @return string[] absolute paths
function M.files(cwd, patterns, root)
	local key = list_key(cwd, patterns, root)
	local cached = list_cache[key]
	if cached and list_valid(cached) then
		log.line("hash.files: cached (%d file(s))", #cached.files)
		return cached.files
	end

	local token = log.start("hash.files")
	local seen, files = {}, {}
	local ignores = gitignore.load(root or cwd, cwd)
	local direct, groups = {}, {}
	local stats = { dirs = 0, entries = 0, lstat = 0, mtimes = {} }

	local function add(path)
		if seen[path] then
			return
		end
		seen[path] = true
		files[#files + 1] = path
	end

	for _, pattern in ipairs(patterns or {}) do
		if type(pattern) == "string" and pattern ~= "" then
			local absolute = pattern
			if not vim.startswith(pattern, "/") and not pattern:match("^%a:[/\\]") then
				absolute = vim.fs.joinpath(cwd, pattern)
			end
			for _, expanded in ipairs(glob.expand(absolute)) do
				local dir, components = split_pattern(expanded)
				if not components then
					direct[#direct + 1] = vim.fs.normalize(expanded)
				elseif vim.fn.isdirectory(dir) == 1 then
					dir = vim.fs.normalize(dir)
					local group = groups[dir]
					if not group then
						group = {}
						groups[dir] = group
					end
					group[#group + 1] = components
				end
			end
		end
	end

	for _, path in ipairs(direct) do
		record_dir(stats, vim.fs.dirname(path))
		if
			vim.fn.filereadable(path) == 1
			and not is_ignored(path)
			and not gitignore.ignored(ignores, path)
		then
			add(path)
		end
	end

	for dir, group in pairs(groups) do
		local function visit(path, parts)
			for _, components in ipairs(group) do
				if glob.match(components, parts, true) then
					add(path)
					return
				end
			end
		end
		local function prune(path, name, parts, ctx)
			if always_ignore[name] or is_ignored(path) or gitignore.context_ignored(ctx) then
				return true
			end
			for _, components in ipairs(group) do
				if glob.can_extend(components, parts, true) then
					return false
				end
			end
			return true
		end
		walk(dir, {}, gitignore.context(ignores, dir), visit, prune, stats)
	end

	table.sort(files)
	log.stop(
		token,
		"%d file(s), %d dir(s), %d entries, %d lstat",
		#files,
		stats.dirs,
		stats.entries,
		stats.lstat
	)

	if list_cache_size >= list_cache_max then
		list_cache = {}
		list_cache_size = 0
	end
	if not list_cache[key] then
		list_cache_size = list_cache_size + 1
	end
	list_cache[key] = { files = files, dirs = stats.mtimes, time = vim.uv.hrtime() }
	return files
end

--- Whether `path` is one of the files `M.files(cwd, patterns, root)` returns.
--- Lets a write invalidate only the indicators it can actually affect.
--- @param cwd string
--- @param patterns string[]
--- @param root string?
--- @param path string absolute path
--- @return boolean
function M.matches(cwd, patterns, root, path)
	path = vim.fs.normalize(path)
	if is_ignored(path) then
		return false
	end
	local ignores = gitignore.load(root or cwd, cwd)
	if gitignore.ignored(ignores, path) then
		return false
	end
	for _, pattern in ipairs(patterns or {}) do
		if type(pattern) == "string" and pattern ~= "" then
			local absolute = pattern
			if not vim.startswith(pattern, "/") and not pattern:match("^%a:[/\\]") then
				absolute = vim.fs.joinpath(cwd, pattern)
			end
			for _, expanded in ipairs(glob.expand(absolute)) do
				local dir, components = split_pattern(expanded)
				if not components then
					if vim.fs.normalize(expanded) == path then
						return true
					end
				elseif vim.fn.isdirectory(dir) == 1 then
					local rel = vim.fs.relpath(dir, path)
					if rel and rel ~= "" and not vim.startswith(rel, "..") then
						local parts = vim.split(rel, "/", { plain = true })
						if not has_always_ignore(parts) and glob.match(components, parts, true) then
							return true
						end
					end
				end
			end
		end
	end
	return false
end

--- sha256 of the file contents, cached by (size, mtime).
--- @param path string
--- @return string?
function M.digest(path)
	local stat = vim.uv.fs_stat(path)
	if not stat or stat.type ~= "file" then
		return nil
	end
	local mtime = mtime_ms(stat) or 0
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

--- The `relative-path\0sha256` entry of one file, as used by `M.aggregate`.
--- @param cwd string
--- @param path string absolute path
--- @param digest string sha256 of the file contents
--- @return string
function M.part(cwd, path, digest)
	return (vim.fs.relpath(cwd, path) or path) .. "\0" .. digest
end

--- Combine the per-file entries of a matched file list into one hash. Entries
--- are looked up by path and joined in the (sorted) order of `files`, so an
--- incremental update only has to recompute the entry of the changed file.
--- @param files string[] matched files, in the order `M.files` returns them
--- @param parts table<string, string> `relative-path\0sha256` per file
--- @return string hash, integer count
function M.aggregate(files, parts)
	local ordered = {}
	for _, path in ipairs(files) do
		local part = parts[path]
		if part then
			ordered[#ordered + 1] = part
		end
	end
	return vim.fn.sha256(table.concat(ordered, "\n")), #ordered
end

--- Hash of every file matched by `patterns` (relative to `cwd`).
--- @param cwd string
--- @param patterns string[]
--- @param root string? repository root (the parent of `.indicate`)
--- @return string hash, integer count, table<string, string> per-file entries, string[] matched files
function M.hash(cwd, patterns, root)
	local token = log.start("hash.hash")
	local files = M.files(cwd, patterns, root)
	local parts = {}
	for _, path in ipairs(files) do
		local digest = M.digest(path)
		if digest then
			parts[path] = M.part(cwd, path, digest)
		end
	end
	local digest, count = M.aggregate(files, parts)
	log.stop(token, "%d file(s)", count)
	return digest, count, parts, files
end

return M
