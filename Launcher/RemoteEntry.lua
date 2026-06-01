--[[
	BT_SoloPastebin → loadstring(game:HttpGet(этот файл))()
	В executor: getgenv().loadstring для всех следующих модулей.
]]
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

_G.BT_LAUNCHER_LOAD = loadFromGit

local LoadStatusUI = loadFn(httpGet(BASE_URL .. "Launcher/LoadStatusUI.lua"), "@LoadStatusUI")()
local ui = LoadStatusUI.create()

local ok, err = pcall(function()
	local Config = loadFromGit("Launcher/Config.lua")
	Config.LoadMode = "Remote"
	Config.RemoteBaseUrl = BASE_URL

	local RemoteLoader = loadFromGit("Launcher/RemoteLoader.lua")
	local RemoteToolBuilder = loadFromGit("Launcher/RemoteToolBuilder.lua")
	local manifest = loadFn(httpGet(BASE_URL .. "Launcher/manifest.lua"), "Launcher/manifest.lua")()

	RemoteLoader.configure(BASE_URL)
	RemoteToolBuilder.setManifest(manifest)

	local player = Players.LocalPlayer
	local tool = RemoteToolBuilder.Build(player, {
		onFile = function(index, total, path, fileOk, fileErr)
			ui.setProgress(index, total, path, fileOk)
			if fileOk == false then
				ui.addError(path, fileErr or "неизвестная ошибка")
			end
		end,
		onMessage = function(message: string)
			ui.setProgress(0, 0, message, true)
		end,
	})

	ui.setDone("Запуск…")
	RemoteToolBuilder.StartRuntime(tool)
	RemoteToolBuilder.Equip(tool)

	local failed = RemoteLoader.getFailed()
	local failCount = 0
	for _ in failed do
		failCount += 1
	end

	local doneText = if failCount > 0
		then `Готово (пропущено файлов: {failCount})`
		else "Готово — Tool в Backpack"
	ui.setDone(doneText)
	task.delay(3, ui.destroy)

	print("[BT] RemoteEntry: Tool готов")
end)

if not ok then
	ui.setFatal(tostring(err))
	warn("[BT Solo]", err)
end
