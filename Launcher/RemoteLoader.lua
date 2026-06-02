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

local continueOnError = true
local runtimeErrors: { string } = {}
local loadCancelled = false

local NO_STUB_PATHS: { [string]: boolean } = {
	["Core/init.lua"] = true,
	["Loader/init.lua"] = true,
}

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

local CORE_INIT_CHILDREN = { "Security", "History", "Selection", "Targeting" }

local CORE_SELF = "(_G.Core or Core)"

local function patchCoreSelfReference(source: string): string
	source = source:gsub("local Core = getfenv%(0%)", `local Core = {CORE_SELF}`)
	source = source:gsub("Core = getfenv%(0%)", `Core = {CORE_SELF}`)
	return source
end

-- Loader/UI читают Core.Support — один блок после Assets (не gsub по всему файлу: ломает { Selection = … })
local CORE_EXPORT_BLOCK = [[
Core.Security = Security
Core.History = History
Core.Selection = Selection
Core.Targeting = Targeting
Core.Region = Region
Core.Signal = Signal
Core.Support = Support
Core.Try = Try
Core.Make = Make
Core.Assets = Assets
]]

local CORE_UI_EXPORT_BLOCK = [[
Core.ToolChanged = ToolChanged
Core.Mode = Mode
]]

-- AssignHotkey/EquipTool объявляются позже — не экспортировать раньше (иначе Core.AssignHotkey = nil)
local CORE_LATE_EXPORT_BLOCK = [[
Core.EquipTool = EquipTool
Core.AssignHotkey = AssignHotkey
Core.ToggleExplorer = ToggleExplorer
Core.DeleteSelection = DeleteSelection
Core.CloneSelection = CloneSelection
Core.ExportSelection = ExportSelection
]]

local function patchCoreModuleExports(source: string): string
	if source:find("Core%.Support = Support", 1, true) then
		return source
	end
	local inserted = source:gsub("(Assets = require%([^\n]+%)\n)", "%1" .. CORE_EXPORT_BLOCK .. "\n", 1)
	if inserted == source then
		inserted = source:gsub("(Cryo = require%([^\n]+%)\n)", "%1" .. CORE_EXPORT_BLOCK .. "\n", 1)
	end
	return inserted
end

local function patchCoreUiExports(source: string): string
	if source:find("Core%.ToolChanged = ToolChanged", 1, true) then
		return source
	end
	local inserted = source:gsub("(ToolChanged = Signal%.new%(%)\n)", "%1" .. CORE_UI_EXPORT_BLOCK, 1)
	return inserted
end

local function patchCoreLateExports(source: string): string
	if source:find("InitializeUI%(%);\nCore%.EquipTool = EquipTool", 1, true) then
		return source
	end
	-- убрать ранний ошибочный экспорт (r47): AssignHotkey ещё не объявлен
	source = source:gsub(
		"(ToolChanged = Signal%.new%(%)\nCore%.ToolChanged = ToolChanged\nCore%.Mode = Mode\n)Core%.EquipTool = EquipTool\nCore%.AssignHotkey = AssignHotkey\n",
		"%1"
	)
	return source:gsub("(InitializeUI%(%);\n)", "%1" .. CORE_LATE_EXPORT_BLOCK .. "\n", 1)
end

-- В env Tool = Roblox Tool; параметры function (Tool) перекрывают env → Tool.Color у Building Tools
local function patchCoreToolParamShadowing(source: string): string
	if source:find("RecolorHandle%(ActiveBuildingTool%.Color%)", 1, true)
		and source:find("AddToolButton%(IconAssetId, HotkeyLabel, ToolModule%)", 1, true)
	then
		return source
	end

	source = source:gsub("ToolChanged:Connect%(function %(Tool%)", "ToolChanged:Connect(function (ActiveBuildingTool)")
	source = source:gsub("RecolorHandle%(Tool%.Color%)", "RecolorHandle(ActiveBuildingTool.Color)")
	source = source:gsub(
		"Selection%.RecolorOutlines%(Tool%.Color%)",
		"Selection.RecolorOutlines(ActiveBuildingTool.Color)"
	)

	source = source:gsub("function EquipTool%(Tool%)", "function EquipTool(BuildingToolModule)")
	source = source:gsub("CurrentTool = Tool;", "CurrentTool = BuildingToolModule;")
	source = source:gsub("ToolChanged:Fire%(Tool%)", "ToolChanged:Fire(BuildingToolModule)")
	source = source:gsub("Tool:Equip%(%);", "BuildingToolModule:Equip();", 1)

	-- AddToolButton: { Tool = Tool } в executor берёт env Tool (Roblox), не параметр
	source = source:gsub(
		"local function AddToolButton%(IconAssetId, HotkeyLabel, Tool%)",
		"local function AddToolButton(IconAssetId, HotkeyLabel, ToolModule)"
	)
	source = source:gsub(
		"HotkeyLabel = HotkeyLabel;\n\t\t\tTool = Tool;",
		"HotkeyLabel = HotkeyLabel;\n\t\t\tTool = ToolModule;"
	)

	return source
end

local function patchCoreReturn(source: string): string
	return source:gsub("return getfenv%(0%)", "return (_G.Core or Core)")
end

local function patchCoreInitRequires(source: string): string
	for _, child in CORE_INIT_CHILDREN do
		local viaTool = `require(Tool:WaitForChild('Core'):WaitForChild('{child}'))`
		source = source:gsub(`{child} = require%(script%.{child}%)`, `{child} = {viaTool}`)
		source = source:gsub(`{child} = require%(__bt_script%.{child}%)`, `{child} = {viaTool}`)
		source = source:gsub(`require%(script%.{child}%)`, viaTool)
		source = source:gsub(`require%(__bt_script%.{child}%)`, viaTool)
	end
	return source
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
		source = patchCoreSelfReference(source)
		source = patchCoreInitRequires(source)
		source = patchCoreModuleExports(source)
		source = patchCoreUiExports(source)
		source = patchCoreLateExports(source)
		source = patchCoreToolParamShadowing(source)
		source = source:gsub(
			"function RecolorHandle%(Color%)\n\tSyncAPI:Invoke%('RecolorHandle', Color%);\nend;",
			[[function RecolorHandle(Color)
	local target = Color
	if typeof(target) == "BrickColor" then
		target = target.Color
	end
	if typeof(target) ~= "Color3" then
		return
	end
	local ok = pcall(function()
		local handle = Tool:FindFirstChild("Handle")
		if handle and handle:IsA("BasePart") then
			handle.Color = target
		end
	end)
	if not ok then
		-- no-op
	end
end;]]
		)
		source = patchCoreReturn(source)
		if not source:find("UIRoot = UI", 1, true) then
			source = source:gsub("Tools = ToolList;", "Tools = ToolList;\n\t\tUIRoot = UI;")
		end
		source = source:gsub(
			"(Core%.UI = UI\n)",
			"%1\tif UIContainer then\n\t\tUI.Parent = UIContainer\n\tend\n"
		)
		if not source:find("Core%.Security = Security", 1, true) then
			source = source:gsub(
				"(Security = require%(script%.Security%)\n)",
				"%1Core.Security = Security\n"
			)
			source = source:gsub(
				"(Security = require%(Tool:WaitForChild%('Core'%):WaitForChild%('Security')%)\n)",
				"%1Core.Security = Security\n"
			)
			source = source:gsub(
				"(History = require%(script%.History%)\n)",
				"%1Core.History = History\n"
			)
			source = source:gsub(
				"(History = require%(Tool:WaitForChild%('Core'%):WaitForChild%('History')%)\n)",
				"%1Core.History = History\n"
			)
			source = source:gsub(
				"(Selection = require%(script%.Selection%)\n)",
				"%1Core.Selection = Selection\n"
			)
			source = source:gsub(
				"(Selection = require%(Tool:WaitForChild%('Core'%):WaitForChild%('Selection')%)\n)",
				"%1Core.Selection = Selection\n"
			)
			source = source:gsub(
				"(Targeting = require%(script%.Targeting%)\n)",
				"%1Core.Targeting = Targeting\n"
			)
			source = source:gsub(
				"(Targeting = require%(Tool:WaitForChild%('Core'%):WaitForChild%('Targeting')%)\n)",
				"%1Core.Targeting = Targeting\n"
			)
		end
	end

	if path == "Loader/init.lua" then
		local loaderBootstrap = [[
if Core then
	if not Core.Support then
		Core.Support = require(Tool.Libraries:WaitForChild('SupportLibrary'))
	end
	if type(Core.AddToolButton) ~= 'function' then
		Core.AddToolButton = function() end
	end
end
]]
		source = source:gsub(
			"(local Core = require%(Tool:WaitForChild 'Core'%)%)\n",
			"%1\n" .. loaderBootstrap
		)
		source = source:gsub(
			"(local Core = require%(Tool:WaitForChild%('Core'%)%)\n)",
			"%1" .. loaderBootstrap
		)
		-- executor: Core.Support.Call часто nil — тот же смысл, что Support.Call(EquipTool, tool)
		source = source:gsub(
			"Core%.AssignHotkey%('([^']+)', Core%.Support%.Call%(Core%.EquipTool, (%w+)%)%);",
			"Core.AssignHotkey('%1', function() Core.EquipTool(%2) end);"
		)
	end

	if path == "Launcher/Interfaces/lol.lua" then
		-- Безопасно привязываем "workspace" к Tool.Interfaces в executor.
		source = source:gsub(
			"local workspace = script%.Parent",
			"local workspace = (_G.__bt_interfaces_root or (script and script.Parent) or workspace)"
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

function RemoteLoader.setContinueOnError(value: boolean)
	continueOnError = value
end

function RemoteLoader.getRuntimeErrors(): { string }
	return runtimeErrors
end

function RemoteLoader.requestCancel()
	loadCancelled = true
end

function RemoteLoader.isLoadCancelled(): boolean
	return loadCancelled
end

local function recordRunError(path: string, err: string)
	local msg = tostring(err)
	failedPaths[path] = msg
	table.insert(runtimeErrors, `run {path}: {msg}`)
	if progressCallback then
		progressCallback(path, false, msg)
	end
end

local function makeStubModule(modulePath: string): any
	return setmetatable({}, {
		__index = function(_self, key)
			local stub = function()
				warn(`[BT] пропуск {modulePath}.{key} — модуль не загружен`)
			end
			return stub
		end,
	})
end

function RemoteLoader.getFetchCount(): number
	return fetchCount
end

function RemoteLoader.registerModule(moduleScript: ModuleScript, path: string)
	registry[moduleScript] = path
	moduleScript:SetAttribute("BTPath", path)
end

function RemoteLoader.fetchSource(path: string): (boolean, string?)
	if loadCancelled then
		return false, "отменено"
	end
	if sourceCache[path] then
		return true, sourceCache[path]
	end

	local lastErr: string? = nil
	local tried: { string } = {}

	for _, url in getFetchUrls(path) do
		if loadCancelled then
			return false, "отменено"
		end
		table.insert(tried, url)
		for attempt = 1, MAX_RETRIES do
			if loadCancelled then
				return false, "отменено"
			end
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
		if loadCancelled then
			break
		end
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
		if loadCancelled then
			break
		end
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

-- Заменяем только идентификатор script, не поля вроде Core.script
local function rewriteScriptIdentifier(source: string, replacement: string): string
	source = source:gsub("([^%.%w_])script([%.:%(])", "%1" .. replacement .. "%2")
	source = source:gsub("^script([%.:%(])", replacement .. "%1")
	source = source:gsub("([^%.%w_])script(%f[%A])", "%1" .. replacement .. "%2")
	source = source:gsub("^script(%f[%A])", replacement .. "%1")
	return source
end

local function rewriteCommon(source: string, useBtRequire: boolean): string
	source = source:gsub("Tool%.Parent:IsA", "Tool.Parent and Tool.Parent:IsA")
	source = rewriteScriptIdentifier(source, "__bt_script")
	source = source:gsub("__bt_script%.Parent", SCRIPT_PARENT_EXPR)
	if useBtRequire then
		source = source:gsub("(%f[%a])require(%f[%A])", "__bt_require")
	end
	return source
end

local MODULE_ENV_PREAMBLE = "local require = (_G.__bt_require or __bt_require)\n"
	.. "local script = (_G.__bt_script or (typeof(script) == \"Instance\" and script) or __bt_script)\n"

local function ensureModulePreamble(source: string): string
	if source:find("local require = __bt_require", 1, true) then
		return source
	end
	return MODULE_ENV_PREAMBLE .. source
end

local TOOL_BIND = "_G.__bt_tool or Tool"

local function rewriteToolParentForRemote(path: string, source: string): string
	if path:sub(1, 6) == "Core/" and path ~= "Core/init.lua" then
		source = source:gsub("Tool = script%.Parent%.Parent", `Tool = {TOOL_BIND};`)
		source = source:gsub("Tool = __bt_script%.Parent%.Parent", `Tool = {TOOL_BIND};`)
	end
	if path == "Loader/init.lua" or path == "Core/init.lua" then
		source = source:gsub("Tool = script%.Parent;", `Tool = {TOOL_BIND};`)
		source = source:gsub("local Tool = script%.Parent;", `local Tool = {TOOL_BIND};`)
		source = source:gsub("local Tool = __bt_script%.Parent;", `local Tool = {TOOL_BIND};`)
		source = source:gsub("Tool = __bt_script%.Parent;", `Tool = {TOOL_BIND};`)
		source = source:gsub("local Tool = Tool;", `local Tool = {TOOL_BIND};`)
		source = source:gsub("Tool = Tool;", `Tool = {TOOL_BIND};`)
	end
	return source
end

local function stripModulePreamble(body: string): string
	body = body:gsub("^local require = [^\n]+\n", "", 1)
	body = body:gsub("^local script = [^\n]+\n", "", 1)
	return body
end

type BtGlobalSnapshot = { __bt_require: any, __bt_tool: any, __bt_script: any }

local function pinBtGlobals(btRequire: any, tool: Tool, scriptInstance: Instance?): BtGlobalSnapshot
	local snap: BtGlobalSnapshot = {
		__bt_require = _G.__bt_require,
		__bt_tool = _G.__bt_tool,
		__bt_script = _G.__bt_script,
	}
	_G.__bt_require = btRequire
	_G.__bt_tool = tool
	_G.__bt_script = scriptInstance
	return snap
end

local function unpinBtGlobals(snap: BtGlobalSnapshot)
	_G.__bt_require = snap.__bt_require
	_G.__bt_tool = snap.__bt_tool
	_G.__bt_script = snap.__bt_script
end

local function runWithPinnedGlobals<T...>(fn: () -> T..., btRequire: any, tool: Tool, scriptInstance: Instance?): (boolean, T...)
	local snap = pinBtGlobals(btRequire, tool, scriptInstance)
	local ok, result = pcall(fn)
	unpinBtGlobals(snap)
	return ok, result
end

local function rewriteCoreChildRequires(source: string): string
	return patchCoreInitRequires(source)
end

-- ModuleScript в custom env (присваивания → env / Core)
local function rewriteForModuleEnv(path: string, source: string): string
	source = rewriteToolParentForRemote(path, source)
	source = ensureModulePreamble(source)
	if path == "Core/init.lua" then
		source = source:gsub("^local script = [^\n]+\n", "local script = Tool:WaitForChild('Core')\n", 1)
	end
	-- require не заменяем на __bt_require: в теле должен быть require(), local require = … в preamble
	source = rewriteCommon(source, false)
	if path == "Core/init.lua" then
		source = rewriteCoreChildRequires(source)
	end
	source = rewriteToolParentForRemote(path, source)
	if path == "Core/init.lua" then
		source = source:gsub("local Core = getfenv%(0%)\r?\n?", `local Core = {CORE_SELF}\n`)
	else
		source = source:gsub("local Core = getfenv%(0%)\r?\n?", "")
	end
	source = source:gsub("getfenv%(%s*0%s*%)", "Core")
	if path == "Core/init.lua" then
		source = patchCoreSelfReference(source)
		source = patchCoreToolParamShadowing(source)
	end
	return source
end

-- ModuleScript в env: дублирует rewriteForModuleEnv (оставлено для читаемости / fallback-имени)
local function rewriteForEnvWrap(path: string, source: string): string
	return rewriteForModuleEnv(path, source)
end

local function rewriteForLocalWrap(source: string): string
	source = rewriteCommon(source, true)
	source = source:gsub("local Core = getfenv%(0%)\r?\n?", "")
	source = source:gsub("getfenv%(%s*0%s*%)", "Core")
	source = source:gsub("(%f[%a])getfenv(%f[%A])", "__bt_getfenv")
	return source
end

local function wrapChunkSource(source: string): string
	local body = rewriteForLocalWrap(source)
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
		__bt_require = btRequire,
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
	env.Core.script = scriptInstance
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
			local msg = `require {modulePath} ({target:GetFullName()}): {result}`
			if continueOnError and not NO_STUB_PATHS[modulePath] then
				recordRunError(modulePath, msg)
				return makeStubModule(modulePath)
			end
			error(`[BT] {msg}`, 0)
		end
		if result == nil and continueOnError and not NO_STUB_PATHS[modulePath] then
			return makeStubModule(modulePath)
		end
		return result
	end
end

local function tryParamWrapperRun(
	path: string,
	body: string,
	tool: Tool,
	scriptInstance: Instance,
	btRequire: any,
	compileFn: (string, string, any?) -> (any?, string?)
): (boolean, any)
	local innerBody = stripModulePreamble(body)
	local wrapSource = "return function(__bt_script, __bt_tool, __bt_require)\n"
		.. "_G.__bt_require = __bt_require\n"
		.. "_G.__bt_tool = __bt_tool\n"
		.. "_G.__bt_script = __bt_script\n"
		.. "local require = __bt_require\n"
		.. "local script = __bt_script\n"
		.. `local Tool = __bt_tool\n`
		.. innerBody
		.. "\nend"

	local wrapFn, compileError = compileFn(wrapSource, "@" .. path .. "#params", nil)
	if not wrapFn then
		return false, `params compile: {compileError}`
	end

	return pcall(function()
		return wrapFn()(scriptInstance, tool, btRequire)
	end)
end

local function runModuleWithEnv(
	path: string,
	raw: string,
	tool: Tool,
	scriptInstance: Instance,
	btRequire: any
): any
	local compileFn = RemoteLoader.compile or defaultCompile

	-- Огромный auto-generated UI (lol.lua) не компилируется одним чанком
	-- из-за лимита локальных регистров (200). Выполняем по секциям "Элемент:".
	if path == "Launcher/Interfaces/lol.lua" then
		local env = buildModuleEnv(tool, scriptInstance, btRequire)
		local interfacesRoot = if scriptInstance and scriptInstance.Parent
			then scriptInstance.Parent
			else (tool:FindFirstChild("Interfaces") or tool)
		env.__bt_interfaces_root = interfacesRoot
		local prefix = "local workspace = __bt_interfaces_root\n"
		local marker = "\n-- Элемент:"
		local blocks: { string } = {}
		local searchFrom = 1
		local firstStart = string.find(raw, "-- Элемент:", 1, true)

		if firstStart then
			while true do
				local blockStart = string.find(raw, "-- Элемент:", searchFrom, true)
				if not blockStart then
					break
				end
				local nextStart = string.find(raw, marker, blockStart + 1, true)
				local blockEnd = if nextStart then nextStart - 1 else #raw
				local block = string.sub(raw, blockStart, blockEnd)
				table.insert(blocks, prefix .. block)
				if not nextStart then
					break
				end
				searchFrom = nextStart + 1
			end
		else
			table.insert(blocks, raw)
		end

		for i, block in ipairs(blocks) do
			local fn, compileError = compileFn(block, "@" .. path .. "#part" .. tostring(i), env)
			if not fn then
				error(`compile part {i}: {compileError}`, 0)
			end
			local ok, runErr = runWithPinnedGlobals(function()
				return fn()
			end, btRequire, tool, scriptInstance)
			if not ok then
				error(`run part {i}: {runErr}`, 0)
			end
		end
		return true
	end

	local coreEnv = buildModuleEnv(tool, scriptInstance, btRequire)
	if path == "Core/init.lua" then
		_G.Core = coreEnv
	end
	local body = rewriteForModuleEnv(path, raw)

	local function tryEnvRun(): (boolean, any)
		local fn, compileError = compileFn(body, "@" .. path, coreEnv)
		if not fn then
			return false, `compile: {compileError}`
		end
		return runWithPinnedGlobals(function()
			return fn()
		end, btRequire, tool, scriptInstance)
	end

	local ok, result = tryEnvRun()
	if ok then
		if path == "Core/init.lua" then
			return coreEnv
		end
		return result
	end

	-- Core должен выполняться в env (getfenv → Core); для Loader — запасной запуск с аргументами
	if path ~= "Core/init.lua" then
		local wrapOk, wrapResult = tryParamWrapperRun(path, body, tool, scriptInstance, btRequire, compileFn)
		if wrapOk then
			return wrapResult
		end
		error(`{result}; {wrapResult}`, 0)
	end

	error(tostring(result), 0)
end

function RemoteLoader.run(path: string, tool: Tool, scriptInstance: Instance?): any
	local cached = moduleCache[path]
	if cached ~= nil then
		if cached == false then
			return nil
		end
		return cached
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
		if continueOnError and not NO_STUB_PATHS[path] then
			recordRunError(path, tostring(result))
			moduleCache[path] = false
			return nil
		end
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
	table.clear(runtimeErrors)
	loadCancelled = false
	fetchCount = 0
	lastFetchAt = 0
end

return RemoteLoader
