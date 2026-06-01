--[[
	Один файл без ReplicatedStorage: вставь URL и запусти.
	Работает только где доступны HttpService + loadstring.
]]
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")

local ENTRY_URL = "https://raw.githubusercontent.com/utststs95/RBX-Building-Tools/development/Launcher/RemoteEntry.lua"

local ok, err = pcall(function()
	local source = HttpService:GetAsync(ENTRY_URL)
	local fn = loadstring(source, "BT.RemoteEntry")
	fn()
end)

if not ok then
	warn("[BT Solo]", err)
end
