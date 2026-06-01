--[[
	HttpGet → кэш. Ошибки не роняют весь preload.
]]
local RemoteLoader = {}

local sourceCache: { [string]: string } = {}
local moduleCache: { [string]: any } = {}
local registry: { [ModuleScript]: string } = {}
local failedPaths: { [string]: string } = {}

local CRITICAL_PATHS = {
	["Core/init.lua"] = true,
	["Loader/init.lua"] = true,
	["SyncAPI.lua"] = true,
	["Support/LocalAPIEndpoint.local.client.lua"] = true,
	["Support/DescendantCounter.local.client.lua"] = true,
	["Support/ReplicationListener.client.lua"] = true,
	["Support/Assets.lua"] = true,
}

function RemoteLoader.configure(baseUrl: string)
	RemoteLoader.BaseUrl = baseUrl
	if not baseUrl:match("/$") then
		RemoteLoader.BaseUrl = baseUrl .. "/"
	end
end

function RemoteLoader.hasSource(path: string): boolean
	return sourceCache[path] ~= nil
end

function RemoteLoader.getFailed(): { [string]: string }
	return failedPaths
end

function RemoteLoader.registerModule(moduleScript: ModuleScript, path: string)
	registry[moduleScript] = path
	moduleScript:SetAttribute("BTPath", path)
end

function RemoteLoader.fetchSource(path: string): (boolean, string?)
	if sourceCache[path] then
		return true, sourceCache[path]
	end

	local url = RemoteLoader.BaseUrl .. path
	local ok, result = pcall(function()
		return game:HttpGet(url, true)
	end)

	if not ok then
		failedPaths[path] = tostring(result)
		return false, failedPaths[path]
	end

	if type(result) ~= "string" or #result == 0 then
		failedPaths[path] = "пустой ответ"
		return false, failedPaths[path]
	end

	if result:find("<!DOCTYPE", 1, true) or result:find("<html", 1, true) then
		failedPaths[path] = "404 / HTML вместо Lua"
		return false, failedPaths[path]
	end

	sourceCache[path] = result
	failedPaths[path] = nil
	return true, result
end

function RemoteLoader.preloadAll(
	paths: { string },
	onProgress: ((number, number, string, boolean, string?) -> ())?
): { string }
	local total = #paths
	local hardFailures: { string } = {}

	for index, path in paths do
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
	for path in CRITICAL_PATHS do
		if not RemoteLoader.hasSource(path) then
			error(`[BT] не загружен обязательный файл: {path}`, 0)
		end
	end
end

local function buildRequire(tool: Tool)
	return function(target: any): any
		if type(target) ~= "userdata" or not target:IsA("ModuleScript") then
			error("[BT] require: ожидается ModuleScript", 2)
		end
		local modulePath = registry[target] or target:GetAttribute("BTPath")
		if not modulePath then
			error(`[BT] require: нет BTPath у {target:GetFullName()}`, 2)
		end
		return RemoteLoader.run(modulePath, tool, target)
	end
end

function RemoteLoader.run(path: string, tool: Tool, scriptInstance: ModuleScript?): any
	if moduleCache[path] ~= nil then
		return moduleCache[path]
	end

	local okSource, err = RemoteLoader.fetchSource(path)
	if not okSource then
		error(`[BT] run {path}: {err}`, 0)
	end

	local env = setmetatable({
		script = scriptInstance,
		Tool = tool,
		plugin = false,
		require = buildRequire(tool),
	}, {
		__index = _G,
	})

	local ok, result = pcall(function()
		local fn, compileError = load(sourceCache[path], "@" .. path, "t", env)
		if not fn then
			error(compileError, 0)
		end
		return fn()
	end)
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
end

return RemoteLoader
