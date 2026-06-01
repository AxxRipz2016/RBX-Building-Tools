--[[
	BT_SoloPastebin → loadstring(game:HttpGet(этот файл))()
	В executor: getgenv().loadstring для всех следующих модулей.
]]
local Players = game:GetService("Players")

local BASE_URL = "https://raw.githubusercontent.com/utststs95/RBX-Building-Tools/development/"

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
	moduleCache[path] = loadFn(httpGet(url), "@" .. path)()
	return moduleCache[path]
end

_G.BT_LAUNCHER_LOAD = loadFromGit

local Config = loadFromGit("Launcher/Config.lua")
Config.LoadMode = "Remote"
Config.RemoteBaseUrl = BASE_URL

local RemoteLoader = loadFromGit("Launcher/RemoteLoader.lua")
local RemoteToolBuilder = loadFromGit("Launcher/RemoteToolBuilder.lua")
local manifest = loadFn(httpGet(BASE_URL .. "Launcher/manifest.lua"), "Launcher/manifest.lua")()

RemoteLoader.configure(BASE_URL)
RemoteToolBuilder.setManifest(manifest)

local player = Players.LocalPlayer
local tool = RemoteToolBuilder.Build(player)
RemoteToolBuilder.StartRuntime(tool)
RemoteToolBuilder.Equip(tool)

print("[BT] RemoteEntry: Tool готов")
