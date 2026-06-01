--[[
	Соло-лаунчер: один HttpGet + loadstring.
	URL — RemoteEntry на GitHub (ветка development).
]]
local ENTRY_URL = "https://raw.githubusercontent.com/utststs95/RBX-Building-Tools/development/Launcher/RemoteEntry.lua"

local ok, err = pcall(function()
	loadstring(game:HttpGet(ENTRY_URL, true))()
end)

if not ok then
	warn("[BT Solo]", err)
end
