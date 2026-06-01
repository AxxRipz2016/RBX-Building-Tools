--[[
	HttpGet → loadstring → кэш. Везде: game:HttpGet(url, true)
]]
local function httpGet(url: string): string
	return game:HttpGet(url, true)
end

local function httpLoad(url: string, chunkName: string): () -> (...any)
	return loadstring(httpGet(url), chunkName) :: any
end

local RemoteLoader = {}

local sourceCache: { [string]: string } = {}
local moduleCache: { [string]: any } = {}
local registry: { [ModuleScript]: string } = {}

function RemoteLoader.configure(baseUrl: string)
	RemoteLoader.BaseUrl = baseUrl
	if not baseUrl:match("/$") then
		RemoteLoader.BaseUrl = baseUrl .. "/"
	end
end

function RemoteLoader.registerModule(moduleScript: ModuleScript, path: string)
	registry[moduleScript] = path
	moduleScript:SetAttribute("BTPath", path)
end

function RemoteLoader.fetchSource(path: string): string
	if sourceCache[path] then
		return sourceCache[path]
	end

	local url = RemoteLoader.BaseUrl .. path
	local ok, result = pcall(function()
		return httpGet(url)
	end)
	if not ok then
		error(`[BT] HttpGet failed for {path}: {result}`, 0)
	end

	sourceCache[path] = result
	return result
end

function RemoteLoader.preloadAll(paths: { string }, onProgress: ((number, number, string) -> ())?)
	local total = #paths
	for index, path in paths do
		if onProgress then
			onProgress(index, total, path)
		end
		RemoteLoader.fetchSource(path)
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

	local url = RemoteLoader.BaseUrl .. path
	local env = setmetatable({
		script = scriptInstance,
		Tool = tool,
		plugin = false,
		require = buildRequire(tool),
	}, {
		__index = _G,
	})

	local ok, result = pcall(function()
		local source = httpGet(url)
		sourceCache[path] = source
		local fn, compileError = load(source, "@" .. path, "t", env)
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
end

return RemoteLoader
