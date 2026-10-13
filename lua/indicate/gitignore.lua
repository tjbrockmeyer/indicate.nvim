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
local log = require("indicate.log")

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

--- @class indicate.IgnoreFrame
--- @field base string directory the `.gitignore` of this frame is relative to
--- @field rules indicate.GitignoreRule[]
--- @field parts string[] components of the walked directory below `base`
--- @field anc integer index of the last rule matching a prefix of `parts`

--- @param rules indicate.GitignoreRule[]
--- @param parts string[]
--- @return integer index of the last rule matching any prefix of `parts`
local function ancestor_rule(rules, parts)
	local anc = 0
	for j = 1, #rules do
		local components = rules[j].components
		for i = 1, #parts do
			if glob.match(components, vim.list_slice(parts, 1, i)) then
				anc = j
				break
			end
		end
	end
	return anc
end

--- Build the matching context for the directory a walk starts in. One frame per
--- `.gitignore` that covers `dir`, ordered deepest first like `M.load`.
--- @param ignores indicate.Gitignore[]
--- @param dir string
--- @return indicate.IgnoreFrame[]
function M.context(ignores, dir)
	dir = vim.fs.normalize(dir)
	local frames = {}
	for _, ignore in ipairs(ignores) do
		local prefix = dir_prefix(ignore.base)
		if dir == ignore.base or vim.startswith(dir, prefix) then
			local rel = dir == ignore.base and "" or dir:sub(#prefix + 1)
			local parts = rel == "" and {} or vim.split(rel, "/", { plain = true })
			frames[#frames + 1] = {
				base = ignore.base,
				rules = ignore.rules,
				parts = parts,
				anc = ancestor_rule(ignore.rules, parts),
			}
		end
	end
	return frames
end

--- Extend the context by descending into the directory `name`. Only the new
--- component can add a match: the ancestors of a child are the ancestors of its
--- parent plus the parent itself, which `anc` already covers, so only the rules
--- after `anc` have to be re-checked.
--- @param frames indicate.IgnoreFrame[]
--- @param name string
--- @return indicate.IgnoreFrame[]
function M.descend(frames, name)
	local out = {}
	for _, frame in ipairs(frames) do
		local parts = frame.parts
		local child = {}
		for i = 1, #parts do
			child[i] = parts[i]
		end
		child[#parts + 1] = name
		local rules, anc = frame.rules, frame.anc
		for j = anc + 1, #rules do
			if glob.match(rules[j].components, child) then
				anc = j
			end
		end
		out[#out + 1] = { base = frame.base, rules = rules, parts = child, anc = anc }
	end
	return out
end

--- Whether the directory a context describes is ignored.
--- @param frames indicate.IgnoreFrame[]
--- @return boolean
function M.context_ignored(frames)
	for _, frame in ipairs(frames) do
		if frame.anc > 0 then
			return not frame.rules[frame.anc].negated
		end
	end
	return false
end

--- Whether the file `name` inside the directory a context describes is ignored.
--- @param frames indicate.IgnoreFrame[]
--- @param name string
--- @return boolean
function M.context_file_ignored(frames, name)
	for _, frame in ipairs(frames) do
		local parts = frame.parts
		local file = {}
		for i = 1, #parts do
			file[i] = parts[i]
		end
		file[#parts + 1] = name
		local rules, anc = frame.rules, frame.anc
		for j = anc + 1, #rules do
			if not rules[j].dir_only and glob.match(rules[j].components, file) then
				anc = j
			end
		end
		if anc > 0 then
			return not rules[anc].negated
		end
	end
	return false
end

M.load = log.wrap("gitignore.load", M.load)
return M
