--- Logs window for the last run of an indicator.
local config = require("indicate.config")
local opts = require("indicate.opts")
local log = require("indicate.log")
local runner = require("indicate.runner")

local M = {}

local win_id, buf_id

--- Indicator currently shown, so the live refresh knows what to re-render.
--- @type { cfg: indicate.Config, ind: indicate.Indicator }?
local shown

--- @type uv_timer_t? polls a running process while its logs are shown
local timer

--- Interval (ms) at which the logs of a running process are re-read.
local refresh_interval = 200

--- @return integer? win
function M.win()
	if win_id and vim.api.nvim_win_is_valid(win_id) then
		return win_id
	end
	win_id = nil
	return nil
end

local function stop_timer()
	if timer then
		timer:stop()
	end
end

function M.close()
	stop_timer()
	local win = M.win()
	if win then
		pcall(vim.api.nvim_win_close, win, true)
	end
	win_id = nil
	shown = nil
	-- Move the cursor back to the panel, when it is open.
	local panel_win = require("indicate.ui.panel").win()
	if panel_win then
		pcall(vim.api.nvim_set_current_win, panel_win)
	end
end

--- Stop the live refresh timer (call on `VimLeavePre`).
function M.stop()
	stop_timer()
end

--- The lines to show: the output of a running process, or the stored logs of
--- the last run.
--- @param cfg indicate.Config
--- @param ind indicate.Indicator
--- @return string[]
local function lines_for(cfg, ind)
	local lines = runner.progress_lines(ind.name)
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
	end
	if #lines > opts.max_log_lines then
		local trimmed = { ("... %d earlier lines truncated ..."):format(#lines - opts.max_log_lines) }
		vim.list_extend(trimmed, vim.list_slice(lines, #lines - opts.max_log_lines + 1))
		lines = trimmed
	end
	return lines
end

--- Replace the contents of the logs buffer, keeping the cursor in place.
--- @param cfg indicate.Config
--- @param ind indicate.Indicator
local function render(cfg, ind)
	local win, buf = M.win(), buf_id
	if not win or not buf or not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	local lines = lines_for(cfg, ind)
	local row = vim.api.nvim_win_get_cursor(win)[1]
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	if row > #lines then
		row = #lines
	end
	if row >= 1 then
		pcall(vim.api.nvim_win_set_cursor, win, { row, 0 })
	end
end

--- Re-render the shown logs; while the process is running keep polling, once it
--- has finished render the stored logs one last time and stop.
local function refresh()
	if not M.win() or not shown then
		stop_timer()
		return
	end
	render(shown.cfg, shown.ind)
	if not runner.is_running(shown.ind.name) then
		stop_timer()
	end
end

local function start_timer()
	if not timer then
		timer = vim.uv.new_timer()
	end
	timer:stop()
	timer:start(refresh_interval, refresh_interval, vim.schedule_wrap(refresh))
end

--- @param cfg indicate.Config
--- @param ind indicate.Indicator
--- @param o { lines?: string[], title?: string }?
function M.open(cfg, ind, o)
	o = o or {}
	stop_timer()

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
	local lines = o.lines or lines_for(cfg, ind)
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

	shown = { cfg = cfg, ind = ind }
	if not o.lines and runner.is_running(ind.name) then
		start_timer()
	end
end

M.open = log.wrap("logs.open", M.open)
return M
