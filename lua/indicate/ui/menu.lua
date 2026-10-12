--- The `:Indicate` menus (indicator list + attribute editor).
---
--- Uses the snacks picker when available (preview pane + keymap hints), with a
--- `vim.ui.select` fallback.
local config = require("indicate.config")
local prompt = require("indicate.ui.prompt")
local log = require("indicate.log")

local M = {}

--- @class indicate.MenuItem
--- @field text string
--- @field data any
--- @field preview? { text: string, ft?: string }

--- Show a picker with a preview pane.
--- @param o { title: string, items: indicate.MenuItem[], on_select: fun(data: any) }
function M.pick(o)
	local ok, snacks = pcall(require, "snacks")
	if ok and snacks.picker then
		local items = {}
		for _, item in ipairs(o.items) do
			items[#items + 1] = {
				text = item.text,
				data = item.data,
				preview = item.preview
						and {
							text = item.preview.text,
							ft = item.preview.ft or "markdown",
							loc = false,
						}
					or nil,
			}
		end
		snacks.picker.pick({
			source = "indicate",
			title = o.title,
			items = items,
			format = "text",
			preview = "preview",
			confirm = function(picker, item)
				picker:close()
				if item and o.on_select then
					vim.schedule(function()
						o.on_select(item.data)
					end)
				end
			end,
			-- show the keybindings of the menu in the window footers
			win = {
				input = {
					footer_keys = { "<CR>", "j", "k", "q" },
					keys = {
						["<CR>"] = { "confirm", mode = { "i", "n" }, desc = "select" },
						["q"] = { "cancel", mode = { "i", "n" }, desc = "quit" },
						["j"] = { "list_down", mode = { "i", "n" }, desc = "next" },
						["k"] = { "list_up", mode = { "i", "n" }, desc = "prev" },
					},
				},
				list = {
					footer_keys = { "<CR>", "q", "j", "k" },
					keys = {
						["<CR>"] = { "confirm", desc = "select" },
						["q"] = { "cancel", desc = "quit" },
						["j"] = { "list_down", desc = "next" },
						["k"] = { "list_up", desc = "prev" },
					},
				},
			},
		})
		return
	end

	local labels = {}
	for i, item in ipairs(o.items) do
		labels[i] = item.text
	end
	vim.ui.select(labels, { prompt = o.title }, function(_, idx)
		if idx and o.on_select then
			o.on_select(o.items[idx].data)
		end
	end)
end

--- @param value string
--- @return string[]
function M.parse_patterns(value)
	local patterns = {}
	for chunk in tostring(value):gmatch("[^,\n]+") do
		local pattern = vim.trim(chunk)
		if pattern ~= "" then
			patterns[#patterns + 1] = pattern
		end
	end
	return patterns
end


local attributes = {
	{ key = "name", label = "Name", hint = "Unique name of the indicator." },
	{
		key = "cwd",
		label = "Cwd",
		hint = "Directory the command runs in, relative to the repository root (or absolute).",
	},
	{ key = "command", label = "Command", hint = "Shell command to run from the cwd." },
	{
		key = "files",
		label = "Files",
		hint = "Comma separated glob patterns of the files this check depends on, relative to the cwd.",
	},
}

--- @param cfg indicate.Config
--- @param ind indicate.Indicator
--- @param key string
--- @return string
local function current_value(cfg, ind, key)
	if key == "name" then
		return ind.name
	end
	if key == "cwd" then
		return ("`%s`\n\nresolves to `%s`"):format(ind.cwd, config.resolve_cwd(cfg, ind))
	end
	if key == "command" then
		return "```sh\n" .. ind.command .. "\n```"
	end
	if key == "files" then
		local out = {}
		for _, pattern in ipairs(ind.files) do
			out[#out + 1] = "- `" .. pattern .. "`"
		end
		return #out > 0 and table.concat(out, "\n") or "(none)"
	end
	return ""
end

--- Attribute menu for a single indicator. Selecting an attribute edits it and
--- returns to this menu.
--- @param cfg indicate.Config
--- @param ind indicate.Indicator
function M.attributes(cfg, ind)
	local items = {}
	for _, attr in ipairs(attributes) do
		items[#items + 1] = {
			text = attr.label,
			data = { attr = attr.key },
			preview = {
				text = ("# %s\n\n%s\n\n_current value_\n\n%s"):format(
					attr.label,
					attr.hint,
					current_value(cfg, ind, attr.key)
				),
			},
		}
	end
	items[#items + 1] = {
		text = "Delete indicator",
		data = { attr = "delete" },
		preview = {
			text = ("# Delete indicator\n\nRemove `%s` from `config.json` and delete its stored run artifacts."):format(
				ind.name
			),
		},
	}
	M.pick({
		title = ("Indicate · %s"):format(ind.name),
		items = items,
		on_select = function(data)
			M.edit(cfg, ind, data.attr)
		end,
	})
end

--- @param cfg indicate.Config
--- @param ind indicate.Indicator
local function reopen(cfg, ind)
	M.attributes(cfg, ind)
end

--- Edit a single attribute of an indicator.
--- @param cfg indicate.Config
--- @param ind indicate.Indicator
--- @param attr "name"|"cwd"|"command"|"files"|"delete"
function M.edit(cfg, ind, attr)
	if attr == "delete" then
		if vim.fn.confirm(("Indicate: delete '%s'?"):format(ind.name), "&Yes\n&No", 2) ~= 1 then
			reopen(cfg, ind)
			return
		end
		config.remove(cfg, ind)
		config.remove_artifacts(cfg, ind)
		config.save(cfg)
		vim.notify(("Indicate: deleted '%s'"):format(ind.name), vim.log.levels.INFO)
		config.changed()
		return
	end

	if attr == "files" then
		prompt.input(
			{ prompt = "Indicate: glob patterns (comma separated)", default = table.concat(ind.files, ", ") },
			function(value)
				if value == nil then
					reopen(cfg, ind)
					return
				end
				local patterns = M.parse_patterns(value)
				if #patterns == 0 then
					vim.notify("Indicate: at least one glob pattern is required", vim.log.levels.WARN)
					reopen(cfg, ind)
					return
				end
				ind.files = patterns
				config.save(cfg)
				config.changed()
				reopen(cfg, ind)
			end
		)
		return
	end

	local defaults = { name = ind.name, cwd = ind.cwd, command = ind.command }
	local prompts = {
		name = "Indicate: name",
		cwd = "Indicate: cwd (relative to repo root)",
		command = "Indicate: command",
	}
	prompt.input({ prompt = prompts[attr], default = defaults[attr] }, function(value)
		if value == nil then
			reopen(cfg, ind)
			return
		end
		value = vim.trim(value)
		if value == "" then
			vim.notify("Indicate: the value cannot be empty", vim.log.levels.WARN)
			reopen(cfg, ind)
			return
		end
		if attr == "name" then
			local existing = config.get(cfg, value)
			if existing and existing ~= ind then
				vim.notify(("Indicate: an indicator named '%s' already exists"):format(value), vim.log.levels.WARN)
				reopen(cfg, ind)
				return
			end
			ind.name = value
		elseif attr == "cwd" then
			local absolute = config.resolve_path(cfg, value)
			if vim.fn.isdirectory(absolute) == 0 then
				vim.notify(("Indicate: no such directory: %s"):format(absolute), vim.log.levels.WARN)
				reopen(cfg, ind)
				return
			end
			ind.cwd = value
		else
			ind.command = value
		end
		config.save(cfg)
		config.changed()
		reopen(cfg, ind)
	end)
end

M.pick = log.wrap("menu.pick", M.pick)
return M
