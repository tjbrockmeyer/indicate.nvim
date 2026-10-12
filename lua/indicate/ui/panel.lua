--- The Indicate side panel (`:Indicate`).
local config = require("indicate.config")
local opts = require("indicate.opts")
local runner = require("indicate.runner")
local status = require("indicate.state")
local log = require("indicate.log")

local M = {}

local ns = vim.api.nvim_create_namespace("indicate-panel")

local win_id, buf_id, cfg_ref, line_map

--- @return integer? win
function M.win()
	if win_id and vim.api.nvim_win_is_valid(win_id) then
		return win_id
	end
	win_id = nil
	return nil
end

--- @return indicate.Config? cfg
function M.cfg()
	return cfg_ref
end

local function current_indicator()
	local win = M.win()
	if not win then
		return nil
	end
	local row = vim.api.nvim_win_get_cursor(win)[1]
	return line_map and line_map[row] or nil
end

local function open_logs(ind)
	local cfg = cfg_ref
	if cfg and ind then
		require("indicate.ui.logs").open(cfg, ind)
	end
end

local function edit(ind)
	local cfg = cfg_ref
	if cfg and ind then
		require("indicate.ui.menu").attributes(cfg, ind)
	end
end

local function keymaps(buf)
	local function map(lhs, fn, desc)
		vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true, desc = desc })
	end
	map("r", function()
		local ind = current_indicator()
		if ind and cfg_ref then
			runner.run(cfg_ref, ind, { notify = true })
		end
	end, "Indicate: run indicator")
	map("R", function()
		if cfg_ref then
			runner.run_all(cfg_ref, { notify = true })
		end
	end, "Indicate: run all indicators")
	map("l", function()
		open_logs(current_indicator())
	end, "Indicate: show logs")
	map("n", function()
		local cfg = cfg_ref
		if cfg then
			require("indicate.ui.wizard").create(cfg)
		end
	end, "Indicate: create indicator")
	map("e", function()
		edit(current_indicator())
	end, "Indicate: edit indicator")
	map("J", function()
		M.move(1)
	end, "Indicate: move indicator down")
	map("K", function()
		M.move(-1)
	end, "Indicate: move indicator up")
	map("q", function()
		M.close()
	end, "Indicate: close panel")
end

--- Move the indicator under the cursor up (`-1`) or down (`1`) in
--- `config.json`, keeping the cursor on it.
--- @param delta integer
function M.move(delta)
	local cfg, win = cfg_ref, M.win()
	if not cfg or not win then
		return
	end
	local ind = current_indicator()
	if not ind then
		return
	end
	local index
	for i, entry in ipairs(cfg.indicators) do
		if entry == ind then
			index = i
			break
		end
	end
	if not index then
		return
	end
	local target = index + delta
	if target < 1 or target > #cfg.indicators then
		vim.notify(
			("Indicate: '%s' is already %s"):format(ind.name, delta < 0 and "first" or "last"),
			vim.log.levels.INFO
		)
		return
	end
	cfg.indicators[index], cfg.indicators[target] = cfg.indicators[target], cfg.indicators[index]
	local saved, err = config.save(cfg)
	if not saved then
		vim.notify("Indicate: could not save config.json: " .. tostring(err), vim.log.levels.ERROR)
		return
	end
	local row = vim.api.nvim_win_get_cursor(win)[1]
	M.refresh()
	pcall(vim.api.nvim_win_set_cursor, win, { row + delta, 0 })
end

--- @param cfg indicate.Config
--- @param win integer
local function create_window(cfg, win)
	local buf = vim.api.nvim_create_buf(false, true)
	buf_id = buf
	vim.api.nvim_win_set_buf(win, buf)
	vim.bo[buf].filetype = "indicate"
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "hide"
	vim.bo[buf].swapfile = false
	vim.wo[win].number = false
	vim.wo[win].relativenumber = false
	vim.wo[win].signcolumn = "no"
	vim.wo[win].foldcolumn = "0"
	vim.wo[win].wrap = false
	vim.wo[win].list = false
	vim.wo[win].cursorline = true
	vim.wo[win].winfixwidth = true
	vim.wo[win].winbar = " Indicate "
	vim.api.nvim_win_set_width(win, opts.panel.width)
	keymaps(buf)
	M.refresh()
	return buf
end

--- Open (or refresh) the panel, offering to create `.indicate` when the cwd is
--- not inside a repository that has one yet.
function M.open()
	local cfg = config.open()
	if not cfg then
		local root = config.root()
		local dir = config.dir(root)
		local choice = vim.fn.confirm(
			("Indicate: no %s directory found.\nCreate it at %s?"):format(config.dirname, dir),
			"&Yes\n&No",
			1
		)
		if choice ~= 1 then
			return
		end
		local created, err = config.open({ create = true, root = root })
		if not created then
			vim.notify("Indicate: could not create " .. dir .. ": " .. tostring(err), vim.log.levels.ERROR)
			return
		end
		vim.notify("Indicate: created " .. dir, vim.log.levels.INFO)
		cfg = created
	end
	cfg_ref = cfg
	local win = M.win()
	if not win then
		vim.cmd("botright vnew")
		win = vim.api.nvim_get_current_win()
		win_id = win
		create_window(cfg, win)
	else
		M.refresh()
	end
end

function M.close()
	local win = M.win()
	if win then
		pcall(vim.api.nvim_win_close, win, true)
	end
	win_id = nil
end

function M.toggle()
	if M.win() then
		M.close()
	else
		M.open()
	end
end

--- Re-resolve the configuration (cwd changed) and refresh.
function M.reload()
	local cfg = config.open()
	if not cfg then
		M.close()
		return
	end
	cfg_ref = cfg
	M.refresh()
end

--- Re-render the panel from the stored run artifacts.
function M.refresh()
	local win, buf = M.win(), buf_id
	if not win or not buf or not vim.api.nvim_buf_is_valid(buf) or not cfg_ref then
		return
	end
	local lines, marks, map = {}, {}, {}
	for _, ind in ipairs(cfg_ref.indicators) do
		local st = status.status(cfg_ref, ind)
		local dot, hl = status.dot(st.status)
		lines[#lines + 1] = dot .. " " .. ind.name .. (st.dirty and " *" or "")
		map[#lines] = ind
		marks[#marks + 1] = { row = #lines - 1, hl = hl, dot = dot, dirty = st.dirty }
	end
	if #lines == 0 then
		lines[#lines + 1] = "(no indicators configured)"
	end
	local hint_row
	if opts.panel.hints then
		lines[#lines + 1] = ""
		hint_row = #lines - 1
		lines[#lines + 1] = "r run · R run all · l logs"
		lines[#lines + 1] = "n new · e edit · J/K move"
		lines[#lines + 1] = "q close"
	end
	local modifiable = vim.bo[buf].modifiable
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = modifiable
	vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
	for _, mark in ipairs(marks) do
		pcall(vim.api.nvim_buf_set_extmark, buf, ns, mark.row, 0, {
			end_col = #mark.dot,
			hl_group = mark.hl,
		})
		if mark.dirty then
			local star = lines[mark.row + 1]:find("*", 1, true)
			if star then
				pcall(vim.api.nvim_buf_set_extmark, buf, ns, mark.row, star - 1, {
					end_col = star,
					hl_group = "IndicateStar",
				})
			end
		end
	end
	if hint_row then
		for row = hint_row, #lines - 1 do
			pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, 0, {
				end_col = #lines[row + 1],
				hl_group = "Comment",
			})
		end
	end
	line_map = map
end

M.refresh = log.wrap("panel.refresh", M.refresh)
M.open = log.wrap("panel.open", M.open)
M.reload = log.wrap("panel.reload", M.reload)
return M
