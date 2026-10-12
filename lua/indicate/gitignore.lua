--- Minimal `.gitignore` support, used to keep ignored files out of the hash
--- and to prune ignored directories while walking.
---
--- The `.gitignore` files of the directories from the repository root (the
--- parent of `.indicate`) down to the directory the glob patterns are relative
--- to are read. The file closest to a path wins over the ones above it.
---
--- Supported syntax: comments (`#`), negations (`!`), anchoring (a `/`
--- anywhere but at the end), directory only rules (a trailing `/`) and the
--- wildcards `*`, `?`, `[...]` and `**`.
---
--- Deliberate simplification: git cannot re-include a file below an ignored
--- directory, this implementation can.
local glob = require("indicate.glob")

local M = {}

--- @class indicate.Gitignore
--- @field base string directory the patterns of this file are relative to
--- @field rules indicate.GitignoreRule[]

--- @class indicate.GitignoreRule
--- @field negated boolean
--- @field dir_only boolean matches directories (and everything inside them)
--- @field components (string|indicate.GlobComponent)[] `**` or a compiled component

--- Drop trailing whitespace that is not escaped, as git does.
--- @param line string
--- @return string
local function trim_right(line)
	while #line > 0 and (line:sub(-1) == " " or line:sub(-1) == "\t") do
		local backslashes = 0
		local i = #line - 1
		while i >= 1 and line:sub(i, i) == "\\" do
			backslashes, i = backslashes + 1, i - 1
		end
		if backslashes % 2 == 1 then
			break
		end
		line = line:sub(1, -2)
	end
	return line
end

--- @param line string one line of a `.gitignore`
--- @return indicate.GitignoreRule?
local function parse_line(line)
	if line == "" or line:sub(1, 1) == "#" then
		return nil
	end
	local negated = false
	if line:sub(1, 1) == "!" then
		negated = true
		line = line:sub(2)
	elseif line:sub(1, 2) == "\\!" or line:sub(1, 2) == "\\#" then
		line = line:sub(2)
	end
	local dir_only = false
	if line:sub(-1) == "/" then
		dir_only = true
		line = line:sub(1, -2)
	end
	local anchored = false
	if line:sub(1, 1) == "/" then
		anchored = true
		line = line:sub(2)
	elseif line:find("/", 1, true) then
		-- a slash anywhere but at the end anchors the pattern
		anchored = true
	end
	if line == "" then
		return nil
	end
	local components = {}
	if not anchored then
		-- `foo` matches `foo` in any directory
		components[1] = "**"
	end
	for component in line:gmatch("[^/]+") do
		components[#components + 1] = component == "**" and "**" or glob.compile(component)
	end
	return { negated = negated, dir_only = dir_only, components = components }
end

--- Apply the rules of one `.gitignore` to a path below its directory.
--- @param rules indicate.GitignoreRule[]
--- @param rel string path relative to the `.gitignore`, `/` separated
--- @param is_dir boolean whether `rel` itself is a directory
--- @return boolean? ignored, nil when no rule matched
local function evaluate(rules, rel, is_dir)
	local parts = vim.split(rel, "/", { plain = true })
	local candidates = {}
	-- a rule matching a directory also matches everything inside it
	for i = #parts - (is_dir and 0 or 1), 1, -1 do
		candidates[#candidates + 1] = { parts = vim.list_slice(parts, 1, i), dir = true }
	end
	if not is_dir then
		candidates[#candidates + 1] = { parts = parts, dir = false }
	end
	local ignored = nil
	for _, rule in ipairs(rules) do
		for _, candidate in ipairs(candidates) do
			if (not rule.dir_only or candidate.dir) and glob.match(rule.components, candidate.parts) then
				ignored = not rule.negated
				break
			end
		end
	end
	return ignored
end

--- @param path string
--- @return indicate.GitignoreRule[]?
local function read_rules(path)
	local fd = io.open(path, "r")
	if not fd then
		return nil
	end
	local contents = fd:read("*a")
	fd:close()
	if not contents then
		return nil
	end
	local rules = {}
	for line in vim.gsplit(contents, "\n", { plain = true }) do
		local rule = parse_line(trim_right((line:gsub("\r$", ""))))
		if rule then
			rules[#rules + 1] = rule
		end
	end
	return rules
end

--- @param dir string
--- @return string
local function dir_prefix(dir)
	return dir == "/" and "/" or dir .. "/"
end

--- Read the `.gitignore` files of the directories from `root` down to `cwd`.
--- The list is ordered deepest first, so the rules closest to a file win.
--- @param root string repository root (the parent of `.indicate`)
--- @param cwd string directory the glob patterns are relative to
--- @return indicate.Gitignore[]
function M.load(root, cwd)
	local base = vim.fs.normalize(root or cwd)
	local dir = vim.fs.normalize(cwd)
	local chain = {}
	while dir and dir ~= "" do
		chain[#chain + 1] = dir
		if dir == base or not vim.startswith(dir, dir_prefix(base)) then
			break
		end
		local parent = vim.fs.dirname(dir)
		if not parent or parent == dir then
			break
		end
		dir = parent
	end
	local ignores = {}
	for _, directory in ipairs(chain) do
		local rules = read_rules(vim.fs.joinpath(directory, ".gitignore"))
		if rules and #rules > 0 then
			ignores[#ignores + 1] = { base = directory, rules = rules }
		end
	end
	return ignores
end

--- Whether one of the loaded `.gitignore` files ignores `path`.
--- @param ignores indicate.Gitignore[]
--- @param path string absolute path
--- @param is_dir boolean? whether `path` is a directory
--- @return boolean
function M.ignored(ignores, path, is_dir)
	for _, ignore in ipairs(ignores) do
		local prefix = dir_prefix(ignore.base)
		if vim.startswith(path, prefix) then
			local state = evaluate(ignore.rules, path:sub(#prefix + 1), is_dir == true)
			if state ~= nil then
				return state
			end
		end
	end
	return false
end

return M
