--- Repository scoped `.indicate` directory and `config.json` handling.
local M = {}

M.dirname = ".indicate"
M.config_file = "config.json"
M.runs_dir = "runs"
M.version = 1

--- Preferred key order when serializing config.json.
local key_order = { version = 1, indicators = 2, name = 3, cwd = 4, command = 5, files = 6 }

--- Turn an indicator name into a filename safe slug.
--- @param name string
--- @return string
function M.slug(name)
	local slug = tostring(name):lower():gsub("[^%w%-%.]+", "_"):gsub("^_+", ""):gsub("_+$", "")
	if slug == "" then
		slug = "indicator"
	end
	return slug
end

--- Walk up the tree from `dir` looking for an existing `.indicate` directory.
--- @param dir string?
--- @return string? path to the `.indicate` directory
function M.find(dir)
	local current = vim.fs.normalize(dir or vim.uv.cwd())
	while current and current ~= "" do
		local candidate = vim.fs.joinpath(current, M.dirname)
		if vim.fn.isdirectory(candidate) == 1 then
			return candidate
		end
		local parent = vim.fs.dirname(current)
		if not parent or parent == current then
			break
		end
		current = parent
	end
	return nil
end

--- @param cmd string[]
--- @param cwd string
--- @return string?
local function run_capture(cmd, cwd)
	local ok, res = pcall(function()
		return vim.system(cmd, { cwd = cwd, text = true }):wait()
	end)
	if not ok or type(res) ~= "table" or res.code ~= 0 then
		return nil
	end
	local out = vim.trim(res.stdout or "")
	if out == "" then
		return nil
	end
	return out
end

--- Top level of the enclosing repository, falling back to `dir` itself when the
--- directory is not inside a git/jj repository.
--- @param dir string?
--- @return string
function M.root(dir)
	local base = vim.fs.normalize(dir or vim.uv.cwd())
	local top = run_capture({ "git", "rev-parse", "--show-toplevel" }, base)
	if top then
		return vim.fs.normalize(top)
	end
	local marker = vim.fs.root(base, ".git")
	if marker then
		return vim.fs.normalize(marker)
	end
	local jj = run_capture({ "jj", "root" }, base)
	if jj then
		return vim.fs.normalize(jj)
	end
	return base
end

--- @param root string
--- @return string path of the `.indicate` directory for `root`
function M.dir(root)
	return vim.fs.joinpath(vim.fs.normalize(root), M.dirname)
end

--- @param cfg indicate.Config
--- @return string
function M.runs(cfg)
	return vim.fs.joinpath(cfg.dir, M.runs_dir)
end

--- Path of a run artifact, e.g. `runs/tests-result`.
--- @param cfg indicate.Config
--- @param ind indicate.Indicator
--- @param suffix string
--- @return string
function M.artifact(cfg, ind, suffix)
	return vim.fs.joinpath(M.runs(cfg), M.slug(ind.name) .. "-" .. suffix)
end

--- Write `contents` to `path` atomically (temp file + rename), creating parents.
--- @param path string
--- @param contents string
--- @return boolean? ok, string? err
function M.write(path, contents)
	local parent = vim.fs.dirname(path)
	if parent and parent ~= "" and vim.fn.isdirectory(parent) == 0 then
		vim.fn.mkdir(parent, "p")
	end
	local tmp = path .. ".tmp"
	local fd, open_err = io.open(tmp, "w")
	if not fd then
		return nil, open_err or ("cannot open %s for writing"):format(tmp)
	end
	fd:write(contents)
	fd:close()
	local renamed = vim.uv.fs_rename(tmp, path)
	if not renamed then
		pcall(vim.uv.fs_unlink, tmp)
		return nil, ("cannot write %s"):format(path)
	end
	return true
end

--- @param path string
--- @return string? contents
function M.read(path)
	local fd = io.open(path, "r")
	if not fd then
		return nil
	end
	local contents = fd:read("*a")
	fd:close()
	return contents
end

local function sorted_keys(t)
	local keys = vim.tbl_keys(t)
	table.sort(keys, function(a, b)
		local ai = key_order[a] or math.huge
		local bi = key_order[b] or math.huge
		if ai ~= bi then
			return ai < bi
		end
		return tostring(a) < tostring(b)
	end)
	return keys
end

local function encode_value(value, level)
	local indent = "  "
	local t = type(value)
	if t == "string" then
		return vim.json.encode(value)
	end
	if t == "number" or t == "boolean" then
		return tostring(value)
	end
	if t ~= "table" then
		return "null"
	end
	local pad = indent:rep(level + 1)
	if vim.islist(value) then
		if #value == 0 then
			return "[]"
		end
		local parts = {}
		for i = 1, #value do
			parts[#parts + 1] = pad .. encode_value(value[i], level + 1)
		end
		return "[\n" .. table.concat(parts, ",\n") .. "\n" .. indent:rep(level) .. "]"
	end
	local keys = sorted_keys(value)
	if #keys == 0 then
		return "{}"
	end
	local parts = {}
	for _, key in ipairs(keys) do
		parts[#parts + 1] = pad .. vim.json.encode(tostring(key)) .. ": " .. encode_value(value[key], level + 1)
	end
	return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent:rep(level) .. "}"
end

--- Pretty print a table as JSON with a stable key order.
--- @param data table
--- @return string
function M.encode(data)
	return encode_value(data, 0)
end

--- @param dir string path of the `.indicate` directory
--- @return indicate.Config? cfg, string? err
function M.load(dir)
	dir = vim.fs.normalize(dir)
	local path = vim.fs.joinpath(dir, M.config_file)
	local raw = M.read(path)
	if not raw then
		return nil, ("no %s found"):format(path)
	end
	local ok, decoded = pcall(vim.json.decode, raw)
	if not ok or type(decoded) ~= "table" then
		return nil, ("invalid json in %s"):format(path)
	end
	local indicators = {}
	for _, entry in ipairs(decoded.indicators or {}) do
		if type(entry) == "table" and type(entry.name) == "string" then
			indicators[#indicators + 1] = {
				name = entry.name,
				cwd = type(entry.cwd) == "string" and entry.cwd ~= "" and entry.cwd or ".",
				command = type(entry.command) == "string" and entry.command or "",
				files = vim.islist(entry.files) and vim.deepcopy(entry.files) or {},
			}
		end
	end
	return {
		dir = dir,
		root = vim.fs.dirname(dir),
		path = path,
		version = M.version,
		indicators = indicators,
	}
end

--- Persist the configuration back to `config.json`.
--- @param cfg indicate.Config
--- @return boolean? ok, string? err
function M.save(cfg)
	local data = { version = M.version, indicators = {} }
	for _, ind in ipairs(cfg.indicators or {}) do
		data.indicators[#data.indicators + 1] = {
			name = ind.name,
			cwd = ind.cwd or ".",
			command = ind.command or "",
			files = ind.files or {},
		}
	end
	local path = cfg.path or vim.fs.joinpath(cfg.dir, M.config_file)
	local ok, err = M.write(path, M.encode(data) .. "\n")
	if not ok then
		return nil, err
	end
	cfg.path = path
	return true
end

--- Create `.indicate` (with `runs/`) for `root` and load it.
--- @param root string
--- @return indicate.Config? cfg, string? err
function M.initialize(root)
	root = vim.fs.normalize(root)
	local dir = M.dir(root)
	local path = vim.fs.joinpath(dir, M.config_file)
	for _, folder in ipairs({ dir, vim.fs.joinpath(dir, M.runs_dir) }) do
		local ok, err = pcall(vim.fn.mkdir, folder, "p")
		if not ok then
			return nil, tostring(err)
		end
	end
	if vim.fn.filereadable(path) == 1 then
		return M.load(dir)
	end
	local cfg = { dir = dir, root = root, path = path, version = M.version, indicators = {} }
	local ok, err = M.save(cfg)
	if not ok then
		return nil, err
	end
	return cfg
end

--- Find the `.indicate` directory for `start` (or the cwd), optionally creating
--- it at the repository root when it does not exist yet.
--- @param opts { start?: string, create?: boolean, root?: string }?
--- @return indicate.Config? cfg, string? err
function M.open(opts)
	opts = opts or {}
	local start = vim.fs.normalize(opts.start or vim.uv.cwd())
	local dir = M.find(start)
	if dir then
		return M.load(dir)
	end
	if not opts.create then
		return nil, ("no %s directory found for %s"):format(M.dirname, start)
	end
	return M.initialize(opts.root or M.root(start))
end

--- @param cfg indicate.Config
--- @param name string
--- @return indicate.Indicator? ind
function M.get(cfg, name)
	local want = tostring(name):lower()
	local want_slug = M.slug(name)
	for _, ind in ipairs(cfg.indicators) do
		if ind.name:lower() == want or M.slug(ind.name) == want_slug then
			return ind
		end
	end
	return nil
end

--- @param cfg indicate.Config
--- @param ind indicate.Indicator
--- @return indicate.Indicator? ind, string? err
function M.add(cfg, ind)
	local existing = M.get(cfg, ind.name)
	if existing then
		return nil, ("an indicator named '%s' already exists"):format(ind.name)
	end
	cfg.indicators[#cfg.indicators + 1] = ind
	return ind
end

--- @param cfg indicate.Config
--- @param target string|indicate.Indicator
--- @return indicate.Indicator? removed
function M.remove(cfg, target)
	local name = type(target) == "table" and target.name or target
	for i, ind in ipairs(cfg.indicators) do
		if ind == target or ind.name == name or M.slug(ind.name) == M.slug(name) then
			table.remove(cfg.indicators, i)
			return ind
		end
	end
	return nil
end

--- Resolve a configured path against the repository root. Absolute paths are
--- used as is.
--- @param cfg indicate.Config
--- @param value string?
--- @return string
function M.resolve_path(cfg, value)
	if type(value) ~= "string" or value == "" then
		value = "."
	end
	if vim.startswith(value, "/") or value:match("^%a:[/\\]") then
		return vim.fs.normalize(value)
	end
	return vim.fs.normalize(vim.fs.joinpath(cfg.root, value))
end

--- Absolute directory the indicator command runs in.
--- @param cfg indicate.Config
--- @param ind indicate.Indicator
--- @return string
function M.resolve_cwd(cfg, ind)
	return M.resolve_path(cfg, ind.cwd)
end

--- Remove the stored run artifacts of an indicator.
--- @param cfg indicate.Config
--- @param ind indicate.Indicator
function M.remove_artifacts(cfg, ind)
	for _, suffix in ipairs({ "result", "hash", "logs" }) do
		pcall(vim.uv.fs_unlink, M.artifact(cfg, ind, suffix))
	end
end

--- Let interested modules (the panel) know that config or run state changed.
function M.changed()
	vim.api.nvim_exec_autocmds("User", { pattern = "IndicateChanged" })
end

return M
