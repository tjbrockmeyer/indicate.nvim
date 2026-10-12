--- User configurable options for Indicate.
--- Kept in its own module so every other module can read options without
--- requiring the top level `indicate` module (avoids require cycles).
local M = {
	--- indicator panel
	panel = {
		width = 32,
		hints = true,
	},
	--- debounce (ms) for refreshing the panel on write/focus events
	refresh_debounce = 300,
	--- lines of a log shown in the logs window
	max_log_lines = 2000,
	--- notify when a manual run finishes
	notify_on_run = false,
	--- write timing of potentially slow operations to
	--- `<repo>/.indicate/indicate.log`
	debug = true,
	--- replace the git/jj top level lookup entirely (mainly for tests)
	root = nil,
}

--- Merge user options into the defaults, in place.
--- @param o table?
function M.setup(o)
	if type(o) ~= "table" then
		return
	end
	local merged = vim.tbl_deep_extend("force", M, o)
	for k in pairs(M) do
		M[k] = nil
	end
	for k, v in pairs(merged) do
		M[k] = v
	end
end

return M
