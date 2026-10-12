--- Read the stored run artifacts and derive the display state of an indicator.
local config = require("indicate.config")
local hash = require("indicate.hash")
local runner = require("indicate.runner")

local M = {}

--- @class indicate.Stored
--- @field ran boolean whether the indicator has ever been run
--- @field result integer? exit code of the last run
--- @field hash string? file hash at the time of the last run
--- @field logs string? logs of the last run

--- @param cfg indicate.Config
--- @param ind indicate.Indicator
--- @return indicate.Stored
function M.read(cfg, ind)
	local result = config.read(config.artifact(cfg, ind, "result"))
	local digest = config.read(config.artifact(cfg, ind, "hash"))
	local logs = config.read(config.artifact(cfg, ind, "logs"))
	return {
		ran = result ~= nil,
		result = result and tonumber(vim.trim(result)) or nil,
		hash = digest and vim.trim(digest) or nil,
		logs = logs,
	}
end

--- @class indicate.Status
--- @field status "pass"|"fail"|"never"|"running"
--- @field dirty boolean files changed since the last run
--- @field result integer?
--- @field ran boolean
--- @field logs string?

--- @param cfg indicate.Config
--- @param ind indicate.Indicator
--- @return indicate.Status
function M.status(cfg, ind)
	local stored = M.read(cfg, ind)
	local status = "never"
	if stored.ran then
		status = stored.result == 0 and "pass" or "fail"
	end
	if runner.is_running(ind.name) then
		status = "running"
	end
	local dirty = false
	if stored.hash and stored.hash ~= "" then
		local current = select(1, hash.hash(config.resolve_cwd(cfg, ind), ind.files, cfg.root))
		dirty = current ~= stored.hash
	end
	return {
		status = status,
		dirty = dirty,
		result = stored.result,
		ran = stored.ran,
		logs = stored.logs,
	}
end

--- @param status string
--- @return string dot, string hl_group
function M.dot(status)
	if status == "pass" then
		return "●", "IndicatePass"
	end
	if status == "fail" then
		return "●", "IndicateFail"
	end
	if status == "running" then
		return "◐", "IndicateRunning"
	end
	return "●", "IndicateNever"
end

return M
