--[[
	Соло для executor: снаружи и внутри RemoteEntry — getgenv().loadstring
]]
local ENTRY_URL = "https://raw.githubusercontent.com/utststs95/RBX-Building-Tools/development/Launcher/RemoteEntry.lua"

local g = getgenv and getgenv() or nil
local loadFn = (g and (g.loadstring or g.load)) or loadstring
local httpGet = function(url: string)
	if g and g.http_request then
		local res = g.http_request({ Url = url, Method = "GET" })
		return (type(res) == "table" and (res.Body or res.body)) or ""
	end
	return game:HttpGet(url, true)
end

local ok, err = pcall(function()
	loadFn(httpGet(ENTRY_URL), "BT.RemoteEntry")()
end)

if not ok then
	warn("[BT Solo]", err)
end
