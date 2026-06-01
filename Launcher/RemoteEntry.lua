--[[
	Точка входа для BT_SoloPastebin.client.lua (один HttpGet на этот файл).
	Остальное качается с GitHub по manifest.
]]
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")

local BASE_URL = "https://raw.githubusercontent.com/utststs95/RBX-Building-Tools/development/"

local sourceCache: { [string]: string } = {}
local moduleFnCache: { [string]: () -> any } = {}

local function fetch(path: string): string
	if sourceCache[path] then
		return sourceCache[path]
	end
	local url = BASE_URL .. path
	sourceCache[path] = HttpService:GetAsync(url)
	return sourceCache[path]
end

local function loadRepoModule(path: string)
	if moduleFnCache[path] then
		return moduleFnCache[path]()
	end
	local fn = loadstring(fetch(path), "@" .. path)
	moduleFnCache[path] = fn
	return fn()
end

local Config = loadRepoModule("Launcher/Config.lua")
Config.LoadMode = "Remote"
Config.RemoteBaseUrl = BASE_URL

local RemoteLoader = loadRepoModule("Launcher/RemoteLoader.lua")
local RemoteToolBuilder = loadRepoModule("Launcher/RemoteToolBuilder.lua")
local manifest = loadstring(fetch("Launcher/manifest.lua"), "manifest")()

RemoteLoader.configure(BASE_URL)
RemoteToolBuilder.setManifest(manifest)

local player = Players.LocalPlayer
local tool = RemoteToolBuilder.Build(player)
RemoteToolBuilder.StartRuntime(tool)
RemoteToolBuilder.Equip(tool)

print("[BT] RemoteEntry: Tool готов")
