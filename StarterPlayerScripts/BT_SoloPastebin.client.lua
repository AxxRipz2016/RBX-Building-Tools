--[[
	Соло для executor: снаружи и внутри RemoteEntry — getgenv().loadstring
]]
local ENTRY_URL = "https://raw.githubusercontent.com/utststs95/RBX-Building-Tools/refs/heads/development/Launcher/RemoteEntry.lua"

local g = getgenv and getgenv() or nil
local loadFn = (g and (g.loadstring or g.load)) or loadstring
local httpGet = function(url: string)
	if g and g.http_request then
		local res = g.http_request({ Url = url, Method = "GET" })
		return (type(res) == "table" and (res.Body or res.body)) or ""
	end
	return game:HttpGet(url, true)
end

local chunk, compileErr = loadFn(httpGet(ENTRY_URL), "BT.RemoteEntry")
if not chunk then
	warn("[BT Solo] compile RemoteEntry:", compileErr)
	return
end

local ok, err = pcall(chunk)
if not ok then
	warn("[BT Solo]", err)
end
