--- Read the stored run artifacts and derive the display state of an indicator.
---
--- The current file hash of an indicator is cached and only recomputed when
--- something could have changed: a matching file was written, the window
--- regained focus, the repository changed or the run artifacts were rewritten.
--- The hash itself is cheap to recompute once `indicate/hash.lua` has a cached
--- file list, so this mostly avoids the tree walk.
local config = require("indicate.config")
local hash = require("indicate.hash")
local runner = require("indicate.runner")
local log = require("indicate.log")

local M = {}

--- Cached current hash per indicator slug. The key records the (cwd, patterns)
--- it was computed for, so editing an indicator invalidates it too. The
--- per-file entries are kept so a single written file can be re-hashed without
--- walking or re-reading every matched file.
--- @type table<string, { key: string, files: string[], parts: table<string, string>, hash: string }>
local current = {}

--- @param cfg indicate.Config
--- @param ind indicate.Indicator
--- @return string
local function cache_key(cfg, ind)
	return config.resolve_cwd(cfg, ind) .. "\0" .. table.concat(ind.files or {}, "\0")
end

--- @param cfg indicate.Config
--- @param ind indicate.Indicator
--- @return string
local function current_hash(cfg, ind)
	local slug = config.slug(ind.name)
	local key = cache_key(cfg, ind)
	local entry = current[slug]
	if entry and entry.key == key then
		return entry.hash
	end
	local digest, _, parts, files = hash.hash(config.resolve_cwd(cfg, ind), ind.files, cfg.root)
	current[slug] = { key = key, files = files, parts = parts, hash = digest }
	return digest
end

--- Forget the cached current hash of one indicator.
--- @param name string
function M.invalidate(name)
	current[config.slug(name)] = nil
end

--- Forget every cached current hash.
function M.invalidate_all()
	current = {}
end

--- Re-hash a single file of an indicator in place, for when only its contents
--- changed. Falls back to invalidating the indicator when the file is not part
--- of the cached file list, so the next status does a full recompute.
--- @param cfg indicate.Config
--- @param ind indicate.Indicator
--- @param path string absolute path
--- @return boolean whether the cached hash could be updated in place
function M.touch(cfg, ind, path)
	local slug = config.slug(ind.name)
	local entry = current[slug]
	if not entry or entry.key ~= cache_key(cfg, ind) or not entry.parts or not entry.parts[path] then
		current[slug] = nil
		return false
	end
	local digest = hash.digest(path)
	if not digest then
		current[slug] = nil
		return false
	end
	entry.parts[path] = hash.part(config.resolve_cwd(cfg, ind), path, digest)
	entry.hash = hash.aggregate(entry.files, entry.parts)
	return true
end

--- Remember the hash that was just computed (for example after a run), so the
--- next status does not recompute it.
--- @param cfg indicate.Config
--- @param ind indicate.Indicator
--- @param digest string
--- @param parts table<string, string>? per-file entries of the hash, when known
--- @param files string[]? matched files the hash was computed from
function M.remember(cfg, ind, digest, parts, files)
	current[config.slug(ind.name)] = { key = cache_key(cfg, ind), files = files, parts = parts, hash = digest }
end

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
		dirty = current_hash(cfg, ind) ~= stored.hash
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

M.read = log.wrap("state.read", M.read)
M.status = log.wrap("state.status", M.status)
return M
