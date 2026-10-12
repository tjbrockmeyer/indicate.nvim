--- Running indicator commands and storing their run artifacts.
local config = require("indicate.config")
local hash = require("indicate.hash")
local opts = require("indicate.opts")

local M = {}

--- @type table<string, boolean> slugs of indicators with a command in flight
local running = {}

--- @param name string
--- @return boolean
function M.is_running(name)
	return running[config.slug(name)] == true
end

--- @param name string
--- @return integer number of runs of this indicator in flight
function M.count(name)
	return running[config.slug(name)] and 1 or 0
end

--- @return string[] names of indicators that are currently running
function M.running_names()
	local names = {}
	for slug in pairs(running) do
		names[#names + 1] = slug
	end
	table.sort(names)
	return names
end

--- @param ind indicate.Indicator
--- @param cwd string
--- @param res vim.SystemCompleted
--- @return string
local function log_contents(ind, cwd, res)
	local stdout = (res.stdout or ""):gsub("\n+$", "")
	local stderr = (res.stderr or ""):gsub("\n+$", "")
	local exit = tostring(res.code)
	if res.signal and res.signal ~= 0 then
		exit = exit .. (" (signal %d)"):format(res.signal)
	end
	local lines = {
		"$ " .. ind.command,
		"cwd: " .. cwd,
		"time: " .. os.date("%Y-%m-%d %H:%M:%S"),
		"exit: " .. exit,
		"",
		"--- stdout ---",
		stdout,
		"",
		"--- stderr ---",
		stderr,
		"",
	}
	return table.concat(lines, "\n")
end

--- Write the run artifacts of an indicator: exit code, file hash and logs.
--- @param cfg indicate.Config
--- @param ind indicate.Indicator
--- @param res vim.SystemCompleted
--- @param digest string
function M.write(cfg, ind, res, digest)
	vim.fn.mkdir(config.runs(cfg), "p")
	config.write(config.artifact(cfg, ind, "result"), tostring(res.code or 0) .. "\n")
	config.write(config.artifact(cfg, ind, "hash"), (digest or "") .. "\n")
	config.write(config.artifact(cfg, ind, "logs"), log_contents(ind, config.resolve_cwd(cfg, ind), res))
end

--- Run one indicator in the background.
--- @param cfg indicate.Config
--- @param ind indicate.Indicator
--- @param o { callback?: fun(res: vim.SystemCompleted, digest: string), notify?: boolean }?
--- @return boolean ok, string? err
function M.run(cfg, ind, o)
	o = o or {}
	local slug = config.slug(ind.name)
	if running[slug] then
		local msg = ("Indicate: '%s' is already running"):format(ind.name)
		if o.notify then
			vim.notify(msg, vim.log.levels.WARN)
		end
		return false, msg
	end
	local cwd = config.resolve_cwd(cfg, ind)
	if vim.fn.isdirectory(cwd) == 0 then
		local msg = ("Indicate: '%s' has a cwd that does not exist: %s"):format(ind.name, cwd)
		if o.notify then
			vim.notify(msg, vim.log.levels.ERROR)
		end
		return false, msg
	end
	running[slug] = true
	config.changed()
	local ok, err = pcall(vim.system, { vim.o.shell, "-c", ind.command }, { cwd = cwd, text = true }, function(res)
		vim.schedule(function()
			running[slug] = nil
			local digest = select(1, hash.hash(cwd, ind.files, cfg.root))
			M.write(cfg, ind, res, digest)
			config.changed()
			if o.callback then
				o.callback(res, digest)
			end
			if o.notify or opts.notify_on_run then
				local passed = res.code == 0
				vim.notify(
					("Indicate: '%s' %s (exit %s)"):format(ind.name, passed and "passed" or "failed", tostring(res.code)),
					passed and vim.log.levels.INFO or vim.log.levels.WARN
				)
			end
		end)
	end)
	if not ok then
		running[slug] = nil
		config.changed()
		return false, tostring(err)
	end
	return true
end

--- Run every configured indicator, each in its own process.
--- @param cfg indicate.Config
--- @param o { callback?: fun(res: vim.SystemCompleted, digest: string), notify?: boolean }?
function M.run_all(cfg, o)
	local started = 0
	for _, ind in ipairs(cfg.indicators) do
		local ok = M.run(cfg, ind, o)
		if ok then
			started = started + 1
		end
	end
	if o and o.notify and started > 0 then
		vim.notify(("Indicate: running %d indicator(s)"):format(started), vim.log.levels.INFO)
	end
	return started
end

return M
