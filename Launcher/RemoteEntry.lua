--[[
	BT_SoloPastebin → loadstring(game:HttpGet(этот файл))()
	В executor: getgenv().loadstring для всех следующих модулей.
]]
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")

local BASE_URL = "https://raw.githubusercontent.com/utststs95/RBX-Building-Tools/refs/heads/development/"
-- Меняй при смене логики loadFromGit (старый paste без ?bt= кэширует RemoteEntry)
local ENTRY_REV = 4

local loadFn
local httpGet
local cacheTag = tostring(tick())

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

local function gitUrl(path: string): string
	local url = BASE_URL .. path
	local sep = if url:find("?", 1, true) then "&" else "?"
	return url .. sep .. "bt=" .. cacheTag
end

local moduleCache: { [string]: any } = {}

local function isLikelyLuaSource(body: string): boolean
	body = body:gsub("^\239\187\191", ""):gsub("^%s+", ""):gsub("%s+$", "")
	if #body < 4 then
		return false
	end
	local head = body:sub(1, 200):lower()
	if head:match("^%s*404") or head:match("^%s*403") then
		return false
	end
	if head:find("<!doctype", 1, true) or head:match("^%s*<html") then
		return false
	end
	return true
end

local function loadFromGit(path: string)
	if moduleCache[path] ~= nil then
		return moduleCache[path]
	end
	local src = httpGet(gitUrl(path))
	if not isLikelyLuaSource(src) then
		error(`[BT] {path}: пустой ответ или HTML (проверь URL / лимит HttpGet)`, 0)
	end
	if path == "Launcher/RemoteLoader.lua" then
		if #src < 30000 then
			error(`[BT] RemoteLoader.lua обрезан ({#src} байт, нужно ~40k+) — другой HttpGet или зеркало`, 0)
		end
		if not src:find("BT-RemoteLoader-EOF", 1, true) then
			error("[BT] RemoteLoader.lua неполный (нет EOF-маркера, обрезан HttpGet?)", 0)
		end
	end
	local chunk, compileErr = loadFn(src, "@" .. path)
	if not chunk then
		error(`[BT] compile {path}: {compileErr}`, 0)
	end
	local runOk, result = pcall(chunk)
	if not runOk then
		error(`[BT] run {path}: {result}`, 0)
	end
	if result == nil then
		result = (path == "Launcher/RemoteLoader.lua") and _G.BT_RemoteLoader or nil
	end
	if result == nil then
		error(`[BT] {path}: модуль вернул nil`, 0)
	end
	moduleCache[path] = result
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

local Version = loadFn(httpGet(gitUrl("Launcher/Version.lua")), "@Version")()
cacheTag = Version.Launcher

local LoadStatusUI = loadFn(httpGet(gitUrl("Launcher/LoadStatusUI.lua")), "@LoadStatusUI")()
local ui = LoadStatusUI.create()
ui.setVersionInfo(
	`Launcher r{Version.Launcher} · BT {Version.Tool} · Roact {Version.Roact} · Cryo {Version.Cryo}`
)

local ok, err = pcall(function()
	local Config = loadFromGit("Launcher/Config.lua")
	Config.LoadMode = "Remote"
	Config.RemoteBaseUrl = BASE_URL

	local RemoteLoader = loadFromGit("Launcher/RemoteLoader.lua")
	if type(RemoteLoader) ~= "table" or type(RemoteLoader.configure) ~= "function" then
		local fallback = _G.BT_RemoteLoader
		if type(fallback) == "table" and type(fallback.configure) == "function" then
			RemoteLoader = fallback
		else
			error(
				"[BT] RemoteLoader не загрузился (nil/configure). В paste — только Bootstrap.lua, не старый RemoteEntry",
				0
			)
		end
	end
	local RemoteToolBuilder = loadFromGit("Launcher/RemoteToolBuilder.lua")
	local manifest = loadFn(httpGet(gitUrl("Launcher/manifest.lua")), "Launcher/manifest.lua")()

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
	local totalFiles = #manifest
	RemoteLoader.setProgressCallback(function(path, fileOk, fileErr)
		fileIndex += 1
		ui.setProgress(fileIndex, totalFiles, path, fileOk)
		if fileOk == false then
			ui.addError(path, fileErr or "неизвестная ошибка")
		end
	end)

	local player = Players.LocalPlayer
	local tool = RemoteToolBuilder.Build(player, {
		onFile = function(index, total, path, fileOk, fileErr)
			fileIndex = math.max(fileIndex, index)
			ui.setProgress(index, if total > 0 then total else totalFiles, path, fileOk)
			if fileOk == false then
				ui.addError(path, fileErr or "неизвестная ошибка")
			end
		end,
		onMessage = function(message: string)
			ui.setProgress(fileIndex, totalFiles, message, true)
		end,
	})

	if RemoteLoader.isLoadCancelled() then
		ui.setDone(`r{Version.Launcher} · загрузка отменена`)
		return
	end

	ui.setProgress(0, 0, "Запуск Core и инструментов…", true)

	task.spawn(function()
		local runOk, runErr = pcall(function()
			RemoteToolBuilder.StartRuntime(tool, function(stepText: string)
				ui.setProgress(0, 0, stepText, true)
			end)
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
		else
			task.delay(2, function()
				if ui.destroy then
					ui.destroy()
				end
			end)
		end

		print(`[BT] RemoteEntry r{Version.Launcher} · BT {Version.Tool} · Roact {Version.Roact} · Cryo {Version.Cryo} — готов`)
	end)
end)

if not ok then
	ui.setFatal(tostring(err))
	warn("[BT Solo]", err)
end
