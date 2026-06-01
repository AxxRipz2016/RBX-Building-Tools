--[[
	BT_SoloPastebin: loadstring(game:HttpGet(RemoteEntry))()
	Дальше все модули так же: loadstring(game:HttpGet(url, true))()
]]
local Players = game:GetService("Players")

local BASE_URL = "https://raw.githubusercontent.com/utststs95/RBX-Building-Tools/development/"

local moduleCache: { [string]: any } = {}

local function loadFromGit(path: string)
	if moduleCache[path] ~= nil then
		return moduleCache[path]
	end
	local url = BASE_URL .. path
	moduleCache[path] = loadstring(game:HttpGet(url, true), "@" .. path)()
	return moduleCache[path]
end

local Config = loadFromGit("Launcher/Config.lua")
Config.LoadMode = "Remote"
Config.RemoteBaseUrl = BASE_URL

local RemoteLoader = loadFromGit("Launcher/RemoteLoader.lua")
local RemoteToolBuilder = loadFromGit("Launcher/RemoteToolBuilder.lua")
local manifest = loadstring(game:HttpGet(BASE_URL .. "Launcher/manifest.lua", true), "Launcher/manifest.lua")()

RemoteLoader.configure(BASE_URL)
RemoteToolBuilder.setManifest(manifest)

local player = Players.LocalPlayer
local tool = RemoteToolBuilder.Build(player)
RemoteToolBuilder.StartRuntime(tool)
RemoteToolBuilder.Equip(tool)

print("[BT] RemoteEntry: Tool готов")
