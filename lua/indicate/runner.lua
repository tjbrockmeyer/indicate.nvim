--- Running indicator commands and storing their run artifacts.
local config = require("indicate.config")
local hash = require("indicate.hash")
local opts = require("indicate.opts")
local log = require("indicate.log")

local M = {}

--- @class indicate.Run
--- @field name string indicator name
--- @field command string shell command that is running
--- @field cwd string directory the command runs in
--- @field time string wall clock time the run started
--- @field started integer `uv.hrtime` value the run started at
--- @field stdout string[] output chunks of stdout received so far
--- @field stderr string[] output chunks of stderr received so far
--- @field handle vim.SystemObj? process handle, used to cancel the run
--- @field cancelled boolean? set once the run has been cancelled

--- @type table<string, indicate.Run> in flight runs, keyed by indicator slug
local running = {}

--- @param name string
--- @return boolean
function M.is_running(name)
	return running[config.slug(name)] ~= nil
end

--- @param name string
--- @return integer number of runs of this indicator in flight
function M.count(name)
	return running[config.slug(name)] and 1 or 0
end

--- @return string[] slugs of indicators that are currently running
function M.running_names()
	local names = {}
	for slug in pairs(running) do
		names[#names + 1] = slug
	end
	table.sort(names)
	return names
end

--- The in-flight run of an indicator, with the output received so far. The
--- returned table is live: it is mutated as more output arrives, so a caller
--- that keeps a reference sees the current state.
--- @param name string
--- @return indicate.Run? run
function M.progress(name)
	return running[config.slug(name)]
end

--- @param o { command: string, cwd: string, time: string, exit: string, stdout: string, stderr: string }
--- @return string
local function format_logs(o)
	local stdout = (o.stdout or ""):gsub("\n+$", "")
	local stderr = (o.stderr or ""):gsub("\n+$", "")
	local lines = {
		"$ " .. o.command,
		"cwd: " .. o.cwd,
		"time: " .. o.time,
		"exit: " .. o.exit,
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

--- The logs of an in-flight run, as lines, showing the output received so far.
--- @param name string
--- @return string[]? lines nil when the indicator is not running
function M.progress_lines(name)
	local run = M.progress(name)
	if not run then
		return nil
	end
	local text = format_logs({
		command = run.command,
		cwd = run.cwd,
		time = run.time,
		exit = "running...",
		stdout = table.concat(run.stdout),
		stderr = table.concat(run.stderr),
	})
	text = text:gsub("\n+$", "")
	return vim.split(text, "\n", { plain = true })
end

--- Write the run artifacts of an indicator: exit code, file hash and logs.
--- @param cfg indicate.Config
--- @param ind indicate.Indicator
--- @param res vim.SystemCompleted
--- @param digest string
--- @param output { stdout: string, stderr: string }? captured output, when the
---   run was streamed (with a custom handler `res.stdout`/`res.stderr` are nil)
function M.write(cfg, ind, res, digest, output)
	vim.fn.mkdir(config.runs(cfg), "p")
	config.write(config.artifact(cfg, ind, "result"), tostring(res.code or 0) .. "\n")
	config.write(config.artifact(cfg, ind, "hash"), (digest or "") .. "\n")
	local exit = tostring(res.code)
	if res.signal and res.signal ~= 0 then
		exit = exit .. (" (signal %d)"):format(res.signal)
	end
	config.write(
		config.artifact(cfg, ind, "logs"),
		format_logs({
			command = ind.command,
			cwd = config.resolve_cwd(cfg, ind),
			time = os.date("%Y-%m-%d %H:%M:%S"),
			exit = exit,
			stdout = output and output.stdout or res.stdout or "",
			stderr = output and output.stderr or res.stderr or "",
		})
	)
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
	local started = log.now()
	local run = {
		name = ind.name,
		command = ind.command,
		cwd = cwd,
		time = os.date("%Y-%m-%d %H:%M:%S"),
		started = started,
		stdout = {},
		stderr = {},
	}
	running[slug] = run
	config.changed()
	log.line("run '%s' started (cwd %s)", ind.name, cwd)

	--- @param stream "stdout"|"stderr"
	--- @return fun(err: string?, data: string?)
	local function capture(stream)
		return function(_, data)
			if data and data ~= "" then
				local chunks = run[stream]
				chunks[#chunks + 1] = data
			end
		end
	end

	local ok, proc = log.measure("runner.spawn", pcall, vim.system, { vim.o.shell, "-c", ind.command }, {
		cwd = cwd,
		text = true,
		stdout = capture("stdout"),
		stderr = capture("stderr"),
	}, function(res)
		vim.schedule(function()
			running[slug] = nil
			if run.cancelled then
				log.line("run '%s' cancelled after %.0f ms", ind.name, log.elapsed(started))
				config.changed()
				if o.notify or opts.notify_on_run then
					vim.notify(("Indicate: '%s' cancelled"):format(ind.name), vim.log.levels.WARN)
				end
				return
			end
			log.line("run '%s' finished in %.0f ms (exit %s)", ind.name, log.elapsed(started), tostring(res.code))
			local digest, _, parts, files = hash.hash(cwd, ind.files, cfg.root)
			M.write(cfg, ind, res, digest, {
				stdout = table.concat(run.stdout),
				stderr = table.concat(run.stderr),
			})
			pcall(function()
				require("indicate.state").remember(cfg, ind, digest, parts, files)
			end)
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
		return false, tostring(proc)
	end
	run.handle = proc
	return true
end

--- Cancel the in-flight run of an indicator, if there is one. The run's
--- artifacts are left untouched, so the panel and the logs keep showing the
--- last completed run.
--- @param name string
--- @param o { notify?: boolean }?
--- @return boolean whether a run was cancelled
function M.cancel(name, o)
	o = o or {}
	local run = running[config.slug(name)]
	if not run or not run.handle then
		if o.notify then
			vim.notify(("Indicate: '%s' is not running"):format(name), vim.log.levels.WARN)
		end
		return false
	end
	run.cancelled = true
	pcall(function()
		run.handle:kill(15)
	end)
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
