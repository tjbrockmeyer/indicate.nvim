--- Logs window for the last run of an indicator.
local config = require("indicate.config")
local opts = require("indicate.opts")
local log = require("indicate.log")

local M = {}

local win_id, buf_id

--- @return integer? win
function M.win()
	if win_id and vim.api.nvim_win_is_valid(win_id) then
		return win_id
	end
	win_id = nil
	return nil
end

function M.close()
	local win = M.win()
	if win then
		pcall(vim.api.nvim_win_close, win, true)
	end
	win_id = nil
end

--- @param cfg indicate.Config
--- @param ind indicate.Indicator
--- @param o { lines?: string[], title?: string }?
function M.open(cfg, ind, o)
	o = o or {}
	local lines = o.lines
	if not lines then
		local path = config.artifact(cfg, ind, "logs")
		if vim.fn.filereadable(path) == 1 then
			lines = vim.fn.readfile(path)
		else
			lines = { ("(no logs yet for '%s' - it has never been run)"):format(ind.name) }
		end
		if #lines == 0 then
			lines = { "(empty log)" }
		end
		if #lines > opts.max_log_lines then
			local trimmed = { ("... %d earlier lines truncated ..."):format(#lines - opts.max_log_lines) }
			vim.list_extend(trimmed, vim.list_slice(lines, #lines - opts.max_log_lines + 1))
			lines = trimmed
		end
	end

	local win = M.win()
	if not win then
		-- Open next to the panel, keeping the panel as the rightmost window.
		local panel = require("indicate.ui.panel")
		local reference = panel.win() or vim.api.nvim_get_current_win()
		vim.api.nvim_set_current_win(reference)
		vim.cmd("leftabove vsplit")
		win = vim.api.nvim_get_current_win()
		win_id = win
		buf_id = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_win_set_buf(win, buf_id)
		pcall(vim.api.nvim_buf_set_name, buf_id, "indicate://logs")
		vim.keymap.set("n", "q", function()
			M.close()
		end, { buffer = buf_id, nowait = true, silent = true, desc = "Indicate: close logs" })
		vim.keymap.set("n", "<Esc>", function()
			M.close()
		end, { buffer = buf_id, nowait = true, silent = true, desc = "Indicate: close logs" })
	end

	local buf = buf_id
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	vim.bo[buf].filetype = "indicate-log"
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "hide"
	vim.bo[buf].swapfile = false
	vim.wo[win].wrap = false
	vim.wo[win].number = false
	vim.wo[win].relativenumber = false
	vim.wo[win].winbar = (" Logs: %s "):format(o.title or ind.name)
	vim.api.nvim_set_current_win(win)
	pcall(vim.api.nvim_win_set_cursor, win, { 1, 0 })
end

M.open = log.wrap("logs.open", M.open)
return M
