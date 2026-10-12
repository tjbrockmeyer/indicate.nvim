if vim.g.loaded_indicate then
	return
end
vim.g.loaded_indicate = 1

local function commands()
	vim.api.nvim_create_user_command("Indicate", function()
		require("indicate").toggle()
	end, { desc = "Indicate: toggle the indicator panel" })
end

local function autocmds()
	local panel = require("indicate.ui.panel")
	local opts = require("indicate.opts")

	local timer
	local function debounced(fn)
		if not timer then
			timer = vim.uv.new_timer()
		end
		timer:stop()
		timer:start(
			opts.refresh_debounce,
			0,
			vim.schedule_wrap(function()
				timer:stop()
				fn()
			end)
		)
	end

	local group = vim.api.nvim_create_augroup("Indicate", { clear = true })

	-- run state or configuration changed
	vim.api.nvim_create_autocmd("User", {
		group = group,
		pattern = "IndicateChanged",
		callback = function()
			panel.refresh()
		end,
	})

	-- files changed on disk: the stored hashes may now be stale
	vim.api.nvim_create_autocmd({ "BufWritePost", "FocusGained" }, {
		group = group,
		callback = function()
			if not panel.win() then
				return
			end
			debounced(function()
				panel.refresh()
			end)
		end,
	})

	-- moved to another repository
	vim.api.nvim_create_autocmd("DirChanged", {
		group = group,
		callback = function()
			if panel.win() then
				panel.reload()
			end
		end,
	})

	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = group,
		callback = function()
			if timer then
				timer:stop()
			end
			require("indicate.log").close()
		end,
	})
end

commands()
autocmds()
require("indicate").highlights()
