--[[
	Ленивая загрузка с GitHub: throttle, retry, loadstring из executor.
]]
local HttpService = game:GetService("HttpService")

local RemoteLoader = {}

local sourceCache: { [string]: string } = {}
local moduleCache: { [string]: any } = {}
local registry: { [ModuleScript]: string } = {}
local failedPaths: { [string]: string } = {}

local FETCH_DELAY = 0.1
local MAX_RETRIES = 6
local lastFetchAt = 0
local fetchCount = 0

local progressCallback: ((string, boolean, string?) -> ())?

local CRITICAL_PATHS = {
	"Core/init.lua",
	"Loader/init.lua",
	"SyncAPI.lua",
	"Support/LocalAPIEndpoint.local.client.lua",
	"Support/DescendantCounter.local.client.lua",
	"Support/ReplicationListener.client.lua",
	"Support/Assets.lua",
}

local function throttle()
	local now = os.clock()
	local waitFor = FETCH_DELAY - (now - lastFetchAt)
	if waitFor > 0 then
		task.wait(waitFor)
	end
	lastFetchAt = os.clock()
end

local function defaultHttpGet(url: string): string
	if HttpService.HttpEnabled then
		return HttpService:GetAsync(url)
	end
	return game:HttpGet(url, true)
end

local function defaultCompile(source: string, chunkName: string, env: any?): (any?, string?)
	local g = if getgenv then getgenv() else nil
	local r = if getrenv then getrenv() else nil
	local loadFn = (g and (g.load or g.loadstring))
		or (r and (r.load or r.loadstring))
		or load
		or loadstring

	if type(loadFn) ~= "function" then
		return nil, "load/loadstring недоступен (нужен executor)"
	end

	if env ~= nil then
		local lastErr: string?
		local attempts = {
			function()
				return loadFn(source, chunkName, "t", env)
			end,
			function()
				return loadFn(source, chunkName, env)
			end,
		}
		for _, attempt in attempts do
			local fn, err = attempt()
			if fn then
				return fn, nil
			end
			lastErr = if err then tostring(err) else lastErr
		end
		return nil, lastErr or "load с env не поддерживается"
	end

	local fn, err = loadFn(source, chunkName)
	if not fn then
		return nil, tostring(err or "compile failed")
	end
	return fn, nil
end

local vendorPrefixes: { { prefix: string, base: string } } = {}

local function normalizeBase(url: string): string
	if not url:match("/$") then
		return url .. "/"
	end
	return url
end

local function normalizeBody(body: string): string
	if body:sub(1, 3) == string.char(0xEF, 0xBB, 0xBF) then
		body = body:sub(4)
	end
	return body
end

local function patchRemoteSource(path: string, source: string): string
	if path:find("RobloxRenderer.lua", 1, true) then
		source = source:gsub(
			"function RobloxRenderer%.isHostObject%(target%)\n\treturn typeof%(target%) == \"Instance\"\nend",
			[[function RobloxRenderer.isHostObject(target)
	if target == nil then
		return false
	end
	if typeof(target) == "Instance" then
		return true
	end
	local ok = pcall(function()
		return target.ClassName
	end)
	return ok
end]]
		)
		source = source:gsub(
			"return typeof%(target%) == \"Instance\"",
			"return RobloxRenderer.isHostObject(target)"
		)
	end

	if path:find("createReconciler.lua", 1, true) then
		source = source:gsub(
			'assert%(renderer%.isHostObject%(targetHostParent%), "Expected target to be host object"%)',
			"if not renderer.isHostObject(targetHostParent) then return end"
		)
	end

	if path:find("Dock/AboutPane.lua", 1, true) then
		source = source:gsub("new%(Roact%.Portal,", "false and new(Roact.Portal,")
	end

	if path == "Core/init.lua" then
		if not source:find("UIRoot = UI", 1, true) then
			source = source:gsub("Tools = ToolList;", "Tools = ToolList;\n\t\tUIRoot = UI;")
		end
		source = source:gsub(
			"(Core%.UI = UI\n)",
			"%1\tif UIContainer then\n\t\tUI.Parent = UIContainer\n\tend\n"
		)
		if not source:find("Core%.History = History", 1, true) then
			source = source:gsub(
				"(History = require%(script%.History%)\n)",
				"%1Core.History = History\n"
			)
			source = source:gsub(
				"(Selection = require%(script%.Selection%)\n)",
				"%1Core.Selection = Selection\n"
			)
			source = source:gsub(
				"(Targeting = require%(script%.Targeting%)\n)",
				"%1Core.Targeting = Targeting\n"
			)
		end
	end

	if path:find("Dock/SelectionPane.lua", 1, true) then
		source = source:gsub(
			"function SelectionPane:UpdateHistoryState%(%)\n    self:setState%({\n        CanUndo = %(self%.props%.Core%.History%.Index > 0%);",
			[[function SelectionPane:UpdateHistoryState()
    local history = self.props.Core and self.props.Core.History
    if not history then
        return
    end
    self:setState({
        CanUndo = (history.Index > 0);]]
		)
		source = source:gsub(
			"CanRedo = %(self%.props%.Core%.History%.Index ~= #self%.props%.Core%.History%.Stack%);",
			"CanRedo = (history.Index ~= #history.Stack);"
		)
		source = source:gsub(
			"self:UpdateHistoryState%(%)\n    self%.Maid%.TrackHistory = self%.props%.Core%.History%.Changed:Connect",
			[[if self.props.Core and self.props.Core.History then
        self:UpdateHistoryState()
        self.Maid.TrackHistory = self.props.Core.History.Changed:Connect]]
		)
		source = source:gsub(
			"self:UpdateSelectionState%(%)\n    self%.Maid%.TrackSelection = self%.props%.Core%.Selection%.Changed:Connect",
			[[if self.props.Core and self.props.Core.Selection then
        self:UpdateSelectionState()
        self.Maid.TrackSelection = self.props.Core.Selection.Changed:Connect]]
		)
		source = source:gsub(
			"function SelectionPane:UpdateSelectionState%(%)\n    self:setState%({\n        IsSelectionEmpty = %(#self%.props%.Core%.Selection%.Items == 0%);",
			[[function SelectionPane:UpdateSelectionState()
    local selection = self.props.Core and self.props.Core.Selection
    if not selection then
        return
    end
    self:setState({
        IsSelectionEmpty = (#selection.Items == 0);]]
		)
	end

	return source
end

local function isLikelyLuaSource(body: string): boolean
	body = normalizeBody(body)
	if #body < 4 then
		return false
	end
	local head = body:sub(1, 200):lower()
	-- Отклоняем только явные HTTP/HTML (остальное — Lua: Assets={}, --, local…)
	if head:match("^%s*404") or head:match("^%s*403") then
		return false
	end
	if head:find("<!doctype", 1, true) or head:match("^%s*<html") or head:match("^%s*<body") then
		return false
	end
	if head:find("too many requests", 1, true) and #body < 250 then
		return false
	end
	return true
end

local function getJsDelivrUrl(path: string): string?
	local user, repo, branch = RemoteLoader.BaseUrl:match(
		"raw%.githubusercontent%.com/([^/]+)/([^/]+)/refs/heads/([^/]+)/"
	)
	if not user then
		return nil
	end
	return `https://cdn.jsdelivr.net/gh/{user}/{repo}@{branch}/{path}`
end

local function getFetchUrls(path: string): { string }
	local urls: { string } = {}
	local seen: { [string]: boolean } = {}

	local function add(url: string)
		if not seen[url] then
			seen[url] = true
			table.insert(urls, url)
		end
	end

	local repoUrl = RemoteLoader.BaseUrl .. path
	local isInit = path:sub(-#"init.lua") == "init.lua"

	for _, entry in vendorPrefixes do
		if path:sub(1, #entry.prefix) ~= entry.prefix then
			continue
		end
		local vendorUrl = entry.base .. path:sub(#entry.prefix + 1)

		-- Vendor/Roact — submodule, в GitHub пусто → только Roblox/roact
		if entry.prefix == "Vendor/Roact/" then
			add(vendorUrl)
			return urls
		end

		add(vendorUrl)
		add(repoUrl)
		return urls
	end

	local mirror = getJsDelivrUrl(path)
	if mirror then
		add(mirror)
	end
	add(repoUrl)
	if not isInit then
		for _, entry in vendorPrefixes do
			if path:sub(1, #entry.prefix) == entry.prefix then
				add(entry.base .. path:sub(#entry.prefix + 1))
			end
		end
	end
	return urls
end

function RemoteLoader.configure(baseUrl: string, vendorUrls: { [string]: string }?)
	RemoteLoader.BaseUrl = normalizeBase(baseUrl)
	table.clear(vendorPrefixes)
	if vendorUrls then
		local sorted: { string } = {}
		for prefix in vendorUrls do
			table.insert(sorted, prefix)
		end
		table.sort(sorted, function(a, b)
			return #a > #b
		end)
		for _, prefix in sorted do
			table.insert(vendorPrefixes, {
				prefix = prefix,
				base = normalizeBase(vendorUrls[prefix]),
			})
		end
	end
	RemoteLoader.httpGet = _G.BT_HTTP_GET or defaultHttpGet
	RemoteLoader.compile = _G.BT_LAUNCHER_COMPILE or defaultCompile
end

function RemoteLoader.setProgressCallback(cb: ((string, boolean, string?) -> ())?)
	progressCallback = cb
end

function RemoteLoader.hasSource(path: string): boolean
	return sourceCache[path] ~= nil
end

function RemoteLoader.getFailed(): { [string]: string }
	return failedPaths
end

function RemoteLoader.getFetchCount(): number
	return fetchCount
end

function RemoteLoader.registerModule(moduleScript: ModuleScript, path: string)
	registry[moduleScript] = path
	moduleScript:SetAttribute("BTPath", path)
end

function RemoteLoader.fetchSource(path: string): (boolean, string?)
	if sourceCache[path] then
		return true, sourceCache[path]
	end

	local lastErr: string? = nil
	local tried: { string } = {}

	for _, url in getFetchUrls(path) do
		table.insert(tried, url)
		for attempt = 1, MAX_RETRIES do
			throttle()
			local ok, result = pcall(function()
				return RemoteLoader.httpGet(url)
			end)

			if ok and type(result) == "string" and #result > 0 then
				result = normalizeBody(result)
			end
			if ok and type(result) == "string" and #result > 0 and isLikelyLuaSource(result) then
				result = patchRemoteSource(path, result)
				sourceCache[path] = result
				failedPaths[path] = nil
				fetchCount += 1
				if progressCallback then
					progressCallback(path, true, nil)
				end
				return true, result
			else
				local preview = ""
				if ok and type(result) == "string" and #result > 0 then
					preview = result:sub(1, 48):gsub("%s+", " ")
				end
				lastErr = if ok and type(result) == "string" and #result > 0
					then `не Lua ({url}) [{preview}]`
					else if ok then "пустой ответ" else tostring(result)
			end

			if attempt < MAX_RETRIES then
				task.wait(0.2 * attempt)
			end
		end
	end

	failedPaths[path] = lastErr or (`HttpGet failed: {table.concat(tried, " | ")}`)
	if progressCallback then
		progressCallback(path, false, failedPaths[path])
	end
	return false, failedPaths[path]
end

function RemoteLoader.preloadByPrefixes(paths: { string }, prefixes: { string })
	table.sort(paths, function(a, b)
		return #a < #b
	end)

	for _, path in paths do
		for _, prefix in prefixes do
			if path:sub(1, #prefix) == prefix then
				local ok, err = RemoteLoader.fetchSource(path)
				if not ok then
					error(`[BT] preload {path}: {err}`, 0)
				end
				task.wait(0.05)
				break
			end
		end
	end
end

function RemoteLoader.preloadCritical(
	onProgress: ((number, number, string, boolean, string?) -> ())?
): { string }
	local hardFailures: { string } = {}
	local total = #CRITICAL_PATHS

	for index, path in CRITICAL_PATHS do
		local ok, err = RemoteLoader.fetchSource(path)
		if onProgress then
			onProgress(index, total, path, ok, err)
		end
		if not ok then
			table.insert(hardFailures, path)
			warn(`[BT] HttpGet: {path} — {err}`)
		end
	end

	return hardFailures
end

function RemoteLoader.assertCriticalLoaded()
	for _, path in CRITICAL_PATHS do
		if not RemoteLoader.hasSource(path) then
			error(`[BT] не загружен обязательный файл: {path}`, 0)
		end
	end
end

local function btToolParent(scriptInst: Instance?, toolInst: Tool?): Instance?
	if scriptInst ~= nil then
		local p = scriptInst.Parent
		if p ~= nil then
			return p
		end
		if toolInst ~= nil then
			local n = scriptInst.Name
			if n == "LocalEndpoint" then
				return toolInst:FindFirstChild("SyncAPI")
			end
			if n == "DescendantCounter" then
				local loaded = toolInst:FindFirstChild("Loaded")
				return if loaded then loaded:FindFirstChild("DescendantCount") else nil
			end
			if n == "ReplicationListener" then
				return toolInst:FindFirstChild("Loaded")
			end
		end
	end
	return toolInst
end

local WRAP_TOOL_PARENT_PREAMBLE = [[
local function __bt_tool_parent(__bt_script, __bt_tool)
	if __bt_script ~= nil then
		local p = __bt_script.Parent
		if p ~= nil then
			return p
		end
		if __bt_tool ~= nil then
			local n = __bt_script.Name
			if n == "LocalEndpoint" then
				return __bt_tool:FindFirstChild("SyncAPI")
			end
			if n == "DescendantCounter" then
				local loaded = __bt_tool:FindFirstChild("Loaded")
				return loaded and loaded:FindFirstChild("DescendantCount")
			end
			if n == "ReplicationListener" then
				return __bt_tool:FindFirstChild("Loaded")
			end
		end
	end
	return __bt_tool
end
]]

-- Без вызова __bt_tool_parent (в load-env executor часто nil) — только __bt_script/__bt_tool
local SCRIPT_PARENT_EXPR =
	"((function(__s,__t) if __s ~= nil then local __p = __s.Parent if __p ~= nil then return __p end if __t ~= nil then local __n = __s.Name if __n == \"LocalEndpoint\" then return __t:FindFirstChild(\"SyncAPI\") end if __n == \"DescendantCounter\" then local __ld = __t:FindFirstChild(\"Loaded\") return __ld and __ld:FindFirstChild(\"DescendantCount\") end if __n == \"ReplicationListener\" then return __t:FindFirstChild(\"Loaded\") end end end return __t end)(__bt_script,__bt_tool))"

local function rewriteCommon(source: string): string
	source = source:gsub("Tool%.Parent:IsA", "Tool.Parent and Tool.Parent:IsA")
	source = source:gsub("(%f[%a])script(%f[%A])", "__bt_script")
	source = source:gsub("__bt_script%.Parent", SCRIPT_PARENT_EXPR)
	source = source:gsub("(%f[%a])require(%f[%A])", "__bt_require")
	return source
end

-- ModuleScript: окружение = таблица Core (как в Roblox), без local Core = getfenv(0)
local function prepareModuleSource(path: string, raw: string): string
	if path == "Loader/init.lua" then
		raw = raw:gsub("local Tool = script%.Parent;", "local Tool = __bt_tool;")
	end
	return rewriteForModuleEnv(raw)
end

local function rewriteForModuleEnv(source: string): string
	source = rewriteCommon(source)
	source = source:gsub("local Core = getfenv%(0%)\r?\n?", "")
	source = source:gsub("getfenv%(%s*0%s*%)", "Core")
	return source
end

local function rewriteForWrap(source: string): string
	source = rewriteCommon(source)
	source = source:gsub("local Core = getfenv%(0%)\r?\n?", "")
	source = source:gsub("getfenv%(%s*0%s*%)", "Core")
	source = source:gsub("(%f[%a])getfenv(%f[%A])", "__bt_getfenv")
	return source
end

local function wrapChunkSource(source: string): string
	local body = rewriteForWrap(source)
	return "return function(__bt_script, __bt_tool, __bt_require)\n"
		.. WRAP_TOOL_PARENT_PREAMBLE
		.. "if __bt_script == nil and __bt_tool == nil then error('[BT] script и Tool nil', 0) end\n"
		.. "local Core = setmetatable({}, { __index = _G })\n"
		.. "_G.Core = Core\n"
		.. "local function __bt_getfenv(_level)\n"
		.. "\treturn Core\n"
		.. "end\n"
		.. "local require = __bt_require\n"
		.. "local script = __bt_script\n"
		.. "local Players = game:GetService(\"Players\")\n"
		.. "Game = game\n"
		.. "Tool = __bt_tool\n"
		.. "Core.script = __bt_script\n"
		.. "Core.Tool = __bt_tool\n"
		.. "Core.require = __bt_require\n"
		.. "Core.Players = Players\n"
		.. "Core.Player = Players.LocalPlayer\n"
		.. body
		.. "\nend"
end

local function buildModuleEnv(tool: Tool, scriptInstance: Instance?, btRequire: any): any
	local Players = game:GetService("Players")
	local env = {
		script = scriptInstance,
		__bt_script = scriptInstance,
		__bt_tool = tool,
		__bt_tool_parent = btToolParent,
		Core = nil :: any,
		Tool = tool,
		require = btRequire,
		plugin = false,
		game = game,
		Game = game,
		Players = Players,
		Player = Players.LocalPlayer,
		Workspace = game:GetService("Workspace"),
		RunService = game:GetService("RunService"),
		HttpService = game:GetService("HttpService"),
		ReplicatedStorage = game:GetService("ReplicatedStorage"),
		UserInputService = game:GetService("UserInputService"),
		CollectionService = game:GetService("CollectionService"),
	}
	env.Core = env
	return setmetatable(env, {
		__index = function(_t, k)
			local v = rawget(env, k)
			if v ~= nil then
				return v
			end
			return _G[k]
		end,
		__newindex = function(_t, k, v)
			rawset(env, k, v)
		end,
	})
end

local function buildRequire(tool: Tool)
	return function(target: any): any
		if type(target) ~= "userdata" or not target:IsA("ModuleScript") then
			local kind = if typeof(target) == "Instance" then target.ClassName else typeof(target)
			error(`[BT] require: ожидается ModuleScript, получен {kind} ({tostring(target)})`, 2)
		end
		local modulePath = registry[target] or target:GetAttribute("BTPath")
		if not modulePath then
			error(`[BT] require: нет BTPath у {target:GetFullName()}`, 2)
		end
		local ok, result = pcall(RemoteLoader.run, modulePath, tool, target)
		if not ok then
			error(`[BT] require {modulePath} ({target:GetFullName()}): {result}`, 0)
		end
		return result
	end
end

local function runModuleWithEnv(
	path: string,
	raw: string,
	tool: Tool,
	scriptInstance: Instance,
	btRequire: any
): any
	local coreEnv = buildModuleEnv(tool, scriptInstance, btRequire)
	local body = prepareModuleSource(path, raw)
	local compileFn = RemoteLoader.compile or defaultCompile
	local fn, compileError = compileFn(body, "@" .. path, coreEnv)
	if not fn then
		error(`[BT] compile {path}: {compileError}`, 0)
	end
	return fn()
end

function RemoteLoader.run(path: string, tool: Tool, scriptInstance: Instance?): any
	if moduleCache[path] ~= nil then
		return moduleCache[path]
	end

	local okSource, err = RemoteLoader.fetchSource(path)
	if not okSource then
		error(`[BT] run {path}: {err}`, 0)
	end

	if scriptInstance == nil then
		error(`[BT] run {path}: scriptInstance is nil`, 0)
	end

	local btRequire = buildRequire(tool)
	local raw = sourceCache[path]
	local ok, result

	if scriptInstance:IsA("ModuleScript") then
		ok, result = pcall(runModuleWithEnv, path, raw, tool, scriptInstance, btRequire)
	else
		local wrapped = wrapChunkSource(raw)
		local fn, compileError = RemoteLoader.compile(wrapped, "@" .. path, nil)
		if not fn then
			error(`[BT] compile {path}: {compileError}`, 0)
		end
		ok, result = pcall(function()
			return fn()(scriptInstance, tool, btRequire)
		end)
	end

	if not ok then
		error(`[BT] run {path}: {result}`, 0)
	end

	moduleCache[path] = if result == nil then true else result
	return moduleCache[path]
end

function RemoteLoader.clear()
	table.clear(sourceCache)
	table.clear(moduleCache)
	table.clear(registry)
	table.clear(failedPaths)
	fetchCount = 0
	lastFetchAt = 0
end

return RemoteLoader
