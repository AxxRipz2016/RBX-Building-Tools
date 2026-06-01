--[[
	BT_SoloPastebin → loadstring(game:HttpGet(этот файл))()
	В executor: getgenv().loadstring для всех следующих модулей.
]]
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")

local BASE_URL = "https://raw.githubusercontent.com/utststs95/RBX-Building-Tools/refs/heads/development/"

local loadFn
local httpGet

do
	local g = getgenv and getgenv() or nil
	local r = getrenv and getrenv() or nil
	loadFn = (g and (g.loadstring or g.load))
		or (r and (r.loadstring or r.load))
		or loadstring
	httpGet = function(url: string)
		if g and g.http_request then
			local res = g.http_request({ Url = url, Method = "GET" })
			return (type(res) == "table" and (res.Body or res.body)) or ""
		end
		if g and g.request then
			local res = g.request({ Url = url, Method = "GET" })
			return (type(res) == "table" and (res.Body or res.body)) or ""
		end
		if HttpService.HttpEnabled then
			return HttpService:GetAsync(url)
		end
		return game:HttpGet(url, true)
	end
end

local moduleCache: { [string]: any } = {}

local function loadFromGit(path: string)
	if moduleCache[path] ~= nil then
		return moduleCache[path]
	end
	local url = BASE_URL .. path
	local src = httpGet(url)
	local chunk, compileErr = loadFn(src, "@" .. path)
	if not chunk then
		error(`[BT] compile {path}: {compileErr}`, 0)
	end
	moduleCache[path] = chunk()
	return moduleCache[path]
end

_G.BT_HTTP_GET = httpGet
_G.BT_LAUNCHER_COMPILE = function(source: string, chunkName: string, env: any?)
	local fn, err = loadFn(source, chunkName, "t", env)
	if fn then
		return fn, nil
	end
	fn, err = loadFn(source, chunkName)
	if fn then
		return fn, nil
	end
	return nil, err
end
_G.BT_LAUNCHER_LOAD = loadFromGit

local Version = loadFn(httpGet(BASE_URL .. "Launcher/Version.lua"), "@Version")()

local LoadStatusUI = loadFn(httpGet(BASE_URL .. "Launcher/LoadStatusUI.lua"), "@LoadStatusUI")()
local ui = LoadStatusUI.create()
ui.setVersionInfo(
	`Launcher r{Version.Launcher} · BT {Version.Tool} · Roact {Version.Roact} · {Version.Branch}`
)

local ok, err = pcall(function()
	local Config = loadFromGit("Launcher/Config.lua")
	Config.LoadMode = "Remote"
	Config.RemoteBaseUrl = BASE_URL

	local RemoteLoader = loadFromGit("Launcher/RemoteLoader.lua")
	local RemoteToolBuilder = loadFromGit("Launcher/RemoteToolBuilder.lua")
	local manifest = loadFn(httpGet(BASE_URL .. "Launcher/manifest.lua"), "Launcher/manifest.lua")()

	RemoteLoader.configure(BASE_URL, Config.RemoteVendorUrls)
	RemoteToolBuilder.setManifest(manifest)
	RemoteToolBuilder.setVersionInfo(Version)
	_G.BT_LAUNCHER_VERSION = Version

	local fileIndex = 0
	RemoteLoader.setProgressCallback(function(path, fileOk, fileErr)
		fileIndex += 1
		ui.setProgress(fileIndex, 0, path, fileOk)
		if fileOk == false then
			ui.addError(path, fileErr or "неизвестная ошибка")
		end
	end)

	local player = Players.LocalPlayer
	local tool = RemoteToolBuilder.Build(player, {
		onMessage = function(message: string)
			ui.setProgress(0, 0, message, true)
		end,
	})

	ui.setDone("Запуск…")
	RemoteToolBuilder.StartRuntime(tool)
	RemoteToolBuilder.Equip(tool)

	local failCount = 0
	for _ in RemoteLoader.getFailed() do
		failCount += 1
	end

	local doneText = if failCount > 0
		then `r{Version.Launcher} · ошибки: {failCount} файлов`
		else `r{Version.Launcher} · OK · {RemoteLoader.getFetchCount()} файлов · Tool в Backpack`
	ui.setDone(doneText)

	print(`[BT] RemoteEntry r{Version.Launcher} · BT {Version.Tool} · Roact {Version.Roact} — готов`)
end)

if not ok then
	ui.setFatal(tostring(err))
	warn("[BT Solo]", err)
end
