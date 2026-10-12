--- Text prompt used by the menus and the wizard.
---
--- Prefers `Snacks.input` (an editable floating window) over the builtin
--- `vim.ui.input` command-line prompt, and falls back when snacks is missing.
local M = {}

--- @param snacks table
--- @return fun(o: table, cb: fun(value: string?))? input
local function snack_input(snacks)
	local mod = snacks.input
	if type(mod) == "function" then
		return mod
	end
	-- `Snacks.input` is a module table that is callable through `__call`
	if type(mod) == "table" and type(mod.input) == "function" then
		return mod.input
	end
	return nil
end

--- @param o table `vim.ui.input` options (prompt, default, ...)
--- @param cb fun(value: string?)
function M.input(o, cb)
	local called = false
	local function once(value)
		if called then
			return
		end
		called = true
		cb(value)
	end

	local ok, snacks = pcall(require, "snacks")
	if ok then
		local input = snack_input(snacks)
		if input and pcall(input, o, once) then
			return
		end
	end
	vim.ui.input(o, once)
end

return M
