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
		local fn, err = loadFn(source, chunkName, "t", env)
		if fn then
			return fn, nil
		end
		if err and not err:find("unexpected", 1, true) then
			return nil, tostring(err)
		end
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

local function isLikelyLuaSource(body: string): boolean
	body = normalizeBody(body)
	if #body < 8 then
		return false
	end
	local head = body:sub(1, 400):lower()
	-- Только явные HTTP/HTML-ошибки (не слова в комментариях Lua)
	if head:match("^%s*404") or head:match("^%s*403") then
		return false
	end
	if head:find("<!doctype", 1, true) or head:match("^%s*<html") or head:match("^%s*<body") then
		return false
	end
	if head:find("too many requests", 1, true) and not head:match("^%s*%-%-") then
		return false
	end
	-- Признаки Lua (Try.lua, find.lua и т.д.)
	if head:match("^%s*%-%-") or head:match("^%s*local ") or head:match("^%s*return ")
		or head:match("^%s*function ") then
		return true
	end
	return body:find("\nlocal ", 1, true) ~= nil or body:find("\nfunction ", 1, true) ~= nil
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

local function rewriteForRemote(source: string): string
	-- script / require / getfenv — зарезервированы; иначе идёт нативный require пустых ModuleScript
	source = source:gsub("(%f[%a])script(%f[%A])", "__bt_script")
	source = source:gsub("(%f[%a])require(%f[%A])", "__bt_require")
	source = source:gsub("(%f[%a])getfenv(%f[%A])", "__bt_getfenv")
	-- Tool без Parent (до Backpack) — nil:IsA
	source = source:gsub("Tool%.Parent:IsA", "Tool.Parent and Tool.Parent:IsA")
	return source
end

local function wrapBoundSource(source: string): string
	local body = rewriteForRemote(source)
	return "return function(__bt_script, __bt_tool, __bt_require)\n"
		.. "local __bt_module = {}\n"
		.. "local function __bt_getfenv(level)\n"
		.. "\tif level == nil or level == 0 or level == 1 then return __bt_module end\n"
		.. "\treturn _G\n"
		.. "end\n"
		.. "Tool = __bt_tool\n"
		.. "Plugin = __bt_tool.Parent and __bt_tool.Parent:IsA(\"Plugin\") and __bt_tool.Parent or nil\n"
		.. "Game = game\n"
		.. body
		.. "\nend"
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

function RemoteLoader.run(path: string, tool: Tool, scriptInstance: Instance?): any
	if moduleCache[path] ~= nil then
		return moduleCache[path]
	end

	local okSource, err = RemoteLoader.fetchSource(path)
	if not okSource then
		error(`[BT] run {path}: {err}`, 0)
	end

	local source = sourceCache[path]
	local btRequire = buildRequire(tool)

	local env = setmetatable({
		script = scriptInstance,
		Tool = tool,
		plugin = false,
		require = btRequire,
	}, {
		__index = _G,
	})

	local toCompile = if scriptInstance then wrapBoundSource(source) else source
	local fn, compileError = RemoteLoader.compile(toCompile, "@" .. path, env)
	if not fn then
		error(`[BT] compile {path}: {compileError}`, 0)
	end

	local ok, result = pcall(function()
		if scriptInstance then
			local factory = fn()
			return factory(scriptInstance, tool, btRequire) -- __bt_script, __bt_tool, __bt_require
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
	fetchCount = 0
	lastFetchAt = 0
end

return RemoteLoader
