--- Indicate: keep the pass/fail state of your checks visible in Neovim.
---
--- `:Indicate` toggles the indicator panel.
local opts = require("indicate.opts")

local M = {}

--- @param o table? options, see `indicate/opts.lua`
function M.setup(o)
	opts.setup(o)
	M.highlights()
end

function M.highlights()
	local hl = vim.api.nvim_set_hl
	hl(0, "IndicatePass", { link = "DiagnosticOk", default = true })
	hl(0, "IndicateFail", { link = "DiagnosticError", default = true })
	hl(0, "IndicateNever", { link = "Comment", default = true })
	hl(0, "IndicateRunning", { link = "DiagnosticWarn", default = true })
	hl(0, "IndicateStar", { link = "DiagnosticWarn", default = true })
end

--- `:Indicate` - toggle the indicator panel.
function M.toggle()
	require("indicate.ui.panel").toggle()
end

return M
