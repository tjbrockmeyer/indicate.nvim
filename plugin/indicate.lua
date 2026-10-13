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
		callback = function(args)
			if not panel.win() then
				return
			end
			if args.event == "FocusGained" then
				-- files may have changed outside of nvim: recompute everything
				require("indicate.state").invalidate_all()
			elseif args.file and args.file ~= "" then
				-- a write can only affect the indicators that match the file
				local path = vim.fs.normalize(vim.fn.fnamemodify(args.file, ":p"))
				if not panel.file_written(path) then
					return
				end
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
			require("indicate.hash").save_cache()
			require("indicate.ui.logs").stop()
			require("indicate.log").close()
		end,
	})
end

commands()
autocmds()
require("indicate").highlights()
