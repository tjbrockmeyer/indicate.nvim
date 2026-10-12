--- Glob patterns: compiling a component, matching paths against a pattern and
--- expanding `{a,b}` alternatives.
---
--- Implements the subset of `glob()` semantics the plugin relies on: `*`, `?`
--- and `[...]` never cross a `/`, `**` matches any number of directories (a
--- trailing `**` matches everything inside, so it needs at least one) and, with
--- `no_dotfiles`, wildcards do not match names starting with a dot.
local M = {}

--- @class indicate.GlobComponent
--- @field pattern string anchored Lua pattern for one path component
--- @field dot boolean the component explicitly starts with a dot

--- Lua patterns for the characters that are magic in a Lua pattern.
local escapes = {
	["%"] = "%%",
	["^"] = "%^",
	["$"] = "%$",
	["("] = "%(",
	[")"] = "%)",
	["."] = "%.",
	["+"] = "%+",
	["-"] = "%-",
	["["] = "%[",
	["]"] = "%]",
	["*"] = "%*",
	["?"] = "%?",
}

--- Compile one glob path component into an anchored Lua pattern.
--- @param component string
--- @return indicate.GlobComponent
function M.compile(component)
	local out, i = {}, 1
	while i <= #component do
		local char = component:sub(i, i)
		if char == "*" then
			out[#out + 1] = "[^/]*"
			i = i + 1
		elseif char == "?" then
			out[#out + 1] = "[^/]"
			i = i + 1
		elseif char == "[" then
			local close = component:find("]", i + 1, true)
			if close then
				local body = component:sub(i + 1, close - 1):gsub("^[!^]", "^"):gsub("%%", "%%%%")
				out[#out + 1] = "[" .. body .. "]"
				i = close + 1
			else
				out[#out + 1] = "%["
				i = i + 1
			end
		else
			out[#out + 1] = escapes[char] or char
			i = i + 1
		end
	end
	return { pattern = "^" .. table.concat(out) .. "$", dot = component:sub(1, 1) == "." }
end

--- @param component string|indicate.GlobComponent
--- @param name string
--- @param no_dotfiles boolean?
--- @return boolean
local function name_matches(component, name, no_dotfiles)
	if no_dotfiles and name:sub(1, 1) == "." and not component.dot then
		return false
	end
	return name:match(component.pattern) ~= nil
end

--- Whether a name is a dotfile, which `*` and `**` never match.
--- @param name string
--- @param no_dotfiles boolean?
--- @return boolean
local function dotfile_blocked(name, no_dotfiles)
	return no_dotfiles == true and name:sub(1, 1) == "."
end

--- Match a path against a pattern.
--- @param components (string|indicate.GlobComponent)[] pattern, `**` or a compiled component
--- @param parts string[] path components, `/` separated
--- @param no_dotfiles boolean? wildcards do not match names starting with a dot
--- @return boolean
function M.match(components, parts, no_dotfiles)
	local function walk(i, j)
		if i > #components then
			return j > #parts
		end
		local component = components[i]
		if component == "**" then
			local first = i == #components and j + 1 or j
			for k = first, #parts + 1 do
				-- k - 1 is the component `**` consumes on this iteration
				if dotfile_blocked(parts[k - 1] or "", no_dotfiles) then
					break
				end
				if walk(i + 1, k) then
					return true
				end
			end
			return false
		end
		if j > #parts or not name_matches(component, parts[j], no_dotfiles) then
			return false
		end
		return walk(i + 1, j + 1)
	end
	return walk(1, 1)
end

--- Whether a path whose leading components are `parts` could still match, that
--- is whether the pattern can consume them and has something left over.
--- @param components (string|indicate.GlobComponent)[]
--- @param parts string[]
--- @param no_dotfiles boolean?
--- @return boolean
function M.can_extend(components, parts, no_dotfiles)
	local function walk(i, j)
		if j > #parts then
			return i <= #components
		end
		if i > #components then
			return false
		end
		local component = components[i]
		if component == "**" then
			if walk(i + 1, j) then
				return true
			end
			if dotfile_blocked(parts[j], no_dotfiles) then
				return false
			end
			return walk(i, j + 1)
		end
		if not name_matches(component, parts[j], no_dotfiles) then
			return false
		end
		return walk(i + 1, j + 1)
	end
	return walk(1, 1)
end

--- Expand the `{a,b}` alternatives of a pattern into separate patterns.
--- @param pattern string
--- @return string[]
function M.expand(pattern)
	local open = pattern:find("{", 1, true)
	if not open then
		return { pattern }
	end
	local depth, close = 0, nil
	for i = open, #pattern do
		local char = pattern:sub(i, i)
		if char == "{" then
			depth = depth + 1
		elseif char == "}" then
			depth = depth - 1
			if depth == 0 then
				close = i
				break
			end
		end
	end
	if not close then
		return { pattern }
	end
	local head, body, tail = pattern:sub(1, open - 1), pattern:sub(open + 1, close - 1), pattern:sub(close + 1)
	local alternatives, start, level = {}, 1, 0
	for i = 1, #body do
		local char = body:sub(i, i)
		if char == "{" then
			level = level + 1
		elseif char == "}" then
			level = level - 1
		elseif char == "," and level == 0 then
			alternatives[#alternatives + 1] = body:sub(start, i - 1)
			start = i + 1
		end
	end
	alternatives[#alternatives + 1] = body:sub(start)
	local expanded = {}
	for _, alternative in ipairs(alternatives) do
		for _, rest in ipairs(M.expand(head .. alternative .. tail)) do
			expanded[#expanded + 1] = rest
		end
	end
	return expanded
end

return M
