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
	if env ~= nil then
		local fn, err = loadFn(source, chunkName, "t", env)
		if fn then
			return fn, nil
		end
		fn, err = loadFn(source, chunkName, env)
		if fn then
			return fn, nil
		end
		return nil, err
	end
	local fn, err = loadFn(source, chunkName)
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
	`Launcher r{Version.Launcher} · BT {Version.Tool} · Roact {Version.Roact} · Cryo {Version.Cryo}`
)

local ok, err = pcall(function()
	local Config = loadFromGit("Launcher/Config.lua")
	Config.LoadMode = "Remote"
	Config.RemoteBaseUrl = BASE_URL

	local RemoteLoader = loadFromGit("Launcher/RemoteLoader.lua")
	local RemoteToolBuilder = loadFromGit("Launcher/RemoteToolBuilder.lua")
	local manifest = loadFn(httpGet(BASE_URL .. "Launcher/manifest.lua"), "Launcher/manifest.lua")()

	RemoteLoader.configure(BASE_URL, Config.RemoteVendorUrls)
	if Config.ContinueOnLoadErrors ~= false then
		RemoteLoader.setContinueOnError(true)
	end
	RemoteToolBuilder.setManifest(manifest)
	RemoteToolBuilder.setVersionInfo(Version)
	_G.BT_LAUNCHER_VERSION = Version

	ui.onCancel(function()
		RemoteLoader.requestCancel()
		ui.setCancelled()
		ui.addError("—", "загрузка отменена пользователем")
	end)

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

	if RemoteLoader.isLoadCancelled() then
		ui.setDone(`r{Version.Launcher} · загрузка отменена`)
		return
	end

	ui.setProgress(0, 0, "Запуск Core и инструментов…", true)

	local runOk, runErr = pcall(function()
		RemoteToolBuilder.StartRuntime(tool)
	end)
	if not runOk then
		ui.addError("StartRuntime", tostring(runErr))
	end

	RemoteToolBuilder.GiveToPlayer(tool, player)
	if not runOk then
		ui.addError("Tool", "в Backpack; Core/Loader не стартовал — «Копировать ошибку»")
	end

	local failCount = 0
	for _ in RemoteLoader.getFailed() do
		failCount += 1
	end
	local runErrCount = #RemoteLoader.getRuntimeErrors()

	local doneText = if runOk and failCount == 0 and runErrCount == 0
		then `r{Version.Launcher} · OK · {RemoteLoader.getFetchCount()} файлов · Tool в Backpack`
		elseif not runOk
		then `r{Version.Launcher} · Tool в Backpack · ошибка запуска (копируй ниже)`
		else `r{Version.Launcher} · ошибки: {failCount} файлов, run: {runErrCount}`
	ui.setDone(doneText)
	if failCount > 0 or runErrCount > 0 or not runOk then
		ui.setProgress(0, 0, doneText, false)
	end

	print(`[BT] RemoteEntry r{Version.Launcher} · BT {Version.Tool} · Roact {Version.Roact} · Cryo {Version.Cryo} — готов`)
end)

if not ok then
	ui.setFatal(tostring(err))
	warn("[BT Solo]", err)
end
