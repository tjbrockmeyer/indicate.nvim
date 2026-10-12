--- Guided creation of a new indicator.
local config = require("indicate.config")
local prompt_ui = require("indicate.ui.prompt")

local M = {}

--- Ask a question, returning nil when the user cancels. Works for both async
--- (`Snacks.input` / `vim.ui.input`) and synchronous (builtin `input()`)
--- implementations.
--- @param o table `vim.ui.input` options
--- @return string? value
local function co_input(o)
	local co = coroutine.running()
	local result, done, in_call = nil, false, true
	prompt_ui.input(o, function(value)
		if done then
			return
		end
		done, result = true, value
		if not in_call then
			coroutine.resume(co)
		end
	end)
	in_call = false
	if not done then
		coroutine.yield()
	end
	return result
end

--- @param prompt string
--- @param default string
--- @param validate fun(value: string): boolean, string?
--- @return string? value
local function ask(prompt, default, validate)
	while true do
		local value = co_input({ prompt = prompt, default = default })
		if value == nil then
			return nil
		end
		value = vim.trim(value)
		local ok, err = validate(value)
		if ok then
			return value
		end
		vim.notify("Indicate: " .. tostring(err), vim.log.levels.WARN)
	end
end

--- Walk the user through creating one attribute at a time.
--- @param cfg indicate.Config
function M.create(cfg)
	local co = coroutine.create(function()
		local name = ask("Indicate: indicator name", "", function(value)
			if value == "" then
				return false, "the name cannot be empty"
			end
			if config.get(cfg, value) then
				return false, ("an indicator named '%s' already exists"):format(value)
			end
			return true
		end)
		if not name then
			return
		end

		local cwd = ask("Indicate: cwd (relative to the repo root)", ".", function(value)
			local absolute = config.resolve_path(cfg, value)
			if vim.fn.isdirectory(absolute) == 0 then
				return false, ("no such directory: %s"):format(absolute)
			end
			return true
		end)
		if not cwd then
			return
		end

		local command = ask("Indicate: command", "", function(value)
			if value == "" then
				return false, "the command cannot be empty"
			end
			return true
		end)
		if not command then
			return
		end

		local menu = require("indicate.ui.menu")
		local files = ask("Indicate: glob patterns (comma separated)", "**/*", function(value)
			if #menu.parse_patterns(value) == 0 then
				return false, "at least one glob pattern is required"
			end
			return true
		end)
		if not files then
			return
		end

		local ind = { name = name, cwd = cwd, command = command, files = menu.parse_patterns(files) }
		config.add(cfg, ind)
		local saved, err = config.save(cfg)
		if not saved then
			vim.notify("Indicate: could not save config.json: " .. tostring(err), vim.log.levels.ERROR)
			return
		end
		config.changed()
		vim.notify(("Indicate: created '%s'"):format(ind.name), vim.log.levels.INFO)
	end)

	local ok, err = coroutine.resume(co)
	if not ok then
		vim.notify("Indicate: " .. tostring(err), vim.log.levels.ERROR)
	end
end

return M
