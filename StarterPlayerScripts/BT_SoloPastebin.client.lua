--[[
	Соло: loadstring(game:HttpGet(url, true))()
]]
local ENTRY_URL = "https://raw.githubusercontent.com/utststs95/RBX-Building-Tools/development/Launcher/RemoteEntry.lua"

local ok, err = pcall(function()
	loadstring(game:HttpGet(ENTRY_URL, true))()
end)

if not ok then
	warn("[BT Solo]", err)
end
