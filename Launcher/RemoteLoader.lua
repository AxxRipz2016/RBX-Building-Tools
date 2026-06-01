--[[
	HttpGet → loadstring/load → кэш модулей.
]]
local HttpService = game:GetService("HttpService")

local RemoteLoader = {}

local sourceCache: { [string]: string } = {}
local moduleCache: { [string]: any } = {}
local registry: { [ModuleScript]: string } = {}

local activeTool: Tool? = nil

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
		return HttpService:GetAsync(url)
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
		local path = registry[target] or target:GetAttribute("BTPath")
		if not path then
			error(`[BT] require: нет BTPath у {target:GetFullName()}`, 2)
		end
		return RemoteLoader.run(path, tool, target)
	end
end

function RemoteLoader.run(path: string, tool: Tool, scriptInstance: ModuleScript?): any
	if moduleCache[path] ~= nil then
		return moduleCache[path]
	end

	activeTool = tool
	local source = RemoteLoader.fetchSource(path)
	local env = setmetatable({
		script = scriptInstance,
		Tool = tool,
		plugin = false,
		require = buildRequire(tool),
	}, {
		__index = _G,
	})

	local fn, compileError = load(source, "@" .. path, "t", env)
	if not fn then
		error(`[BT] compile {path}: {compileError}`, 0)
	end

	local ok, result = pcall(fn)
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
	activeTool = nil
end

return RemoteLoader
