--- Content hashing of the files matching an indicator's glob patterns.
---
--- A hash is the sha256 of a sorted list of `relative-path\0sha256(contents)`
--- entries. Individual file hashes are cached in memory and keyed by
--- (size, mtime), so repeated refreshes only re-read files that changed.
---
--- The files are collected by walking the tree below the static prefix of each
--- pattern instead of expanding the pattern with `glob()`, so the directories
--- in `always_ignore`, `.gitignore`d directories and symlinked directories are
--- never descended into. See `indicate/glob.lua` for the pattern matching.
local gitignore = require("indicate.gitignore")
local glob = require("indicate.glob")
local log = require("indicate.log")

local M = {}

--- @type table<string, { size: integer, mtime: integer, hash: string }>
local cache = {}

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

--- Drop the in memory file hash cache.
function M.clear()
	cache = {}
end

local function is_ignored(path)
	return path:find("/%.git/", 1) ~= nil
		or path:find("/%.jj/", 1) ~= nil
		or path:find("/%.indicate/", 1) ~= nil
end

--- Recursively visit the files below `dir`, without descending into pruned
--- directories. Symlinked directories are not followed: doing so can duplicate
--- whole trees and even loop forever.
--- @param dir string
--- @param parts string[] components of `dir` below the search root
--- @param visit fun(path: string, parts: string[])
--- @param prune fun(dir: string, name: string, parts: string[]): boolean
local function walk(dir, parts, visit, prune)
	local handle = vim.uv.fs_scandir(dir)
	if not handle then
		return
	end
	while true do
		local name, kind = vim.uv.fs_scandir_next(handle)
		if not name then
			break
		end
		local path = dir .. "/" .. name
		local child = vim.list_slice(parts)
		child[#child + 1] = name
		if kind == nil then
			local stat = vim.uv.fs_lstat(path)
			kind = stat and stat.type or nil
		end
		if kind == "directory" then
			if not prune(path, name, child) then
				walk(path, child, visit, prune)
			end
		elseif kind == "file" then
			visit(path, child)
		elseif kind == "link" then
			-- a symlink to a file is hashed like the file it points at
			local stat = vim.uv.fs_stat(path)
			if stat and stat.type == "file" then
				visit(path, child)
			end
		end
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

--- Expand the glob patterns (relative to `cwd`) into a sorted list of files.
--- @param cwd string
--- @param patterns string[]
--- @param root string? repository root (the parent of `.indicate`)
--- @return string[] absolute paths
function M.files(cwd, patterns, root)
	local token = log.start("hash.files")
	local seen, files = {}, {}
	local ignores = gitignore.load(root or cwd, cwd)
	local direct, groups = {}, {}

	local function add(path)
		path = vim.fs.normalize(path)
		if seen[path] or is_ignored(path) or gitignore.ignored(ignores, path) then
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
					direct[#direct + 1] = expanded
				elseif vim.fn.isdirectory(dir) == 1 then
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
		if vim.fn.filereadable(path) == 1 then
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
		local function prune(path, name, parts)
			if always_ignore[name] or is_ignored(path) or gitignore.ignored(ignores, path, true) then
				return true
			end
			for _, components in ipairs(group) do
				if glob.can_extend(components, parts, true) then
					return false
				end
			end
			return true
		end
		walk(dir, {}, visit, prune)
	end

	table.sort(files)
	log.stop(token, "%d file(s)", #files)
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
--- @param root string? repository root (the parent of `.indicate`)
--- @return string hash, integer count
function M.hash(cwd, patterns, root)
	local token = log.start("hash.hash")
	local parts = {}
	for _, path in ipairs(M.files(cwd, patterns, root)) do
		local digest = file_hash(path)
		if digest then
			parts[#parts + 1] = (vim.fs.relpath(cwd, path) or path) .. "\0" .. digest
		end
	end
	log.stop(token, "%d file(s)", #parts)
	return vim.fn.sha256(table.concat(parts, "\n")), #parts
end

return M
