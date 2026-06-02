--[[
	Вставьте в executor ТОЛЬКО это (не кэшируйте старый RemoteEntry в paste):

	loadstring(game:HttpGet(
		"https://raw.githubusercontent.com/utststs95/RBX-Building-Tools/refs/heads/development/Launcher/Bootstrap.lua"
		.. "?bt=" .. tostring(tick()),
		true
	))()
]]
local BASE = "https://raw.githubusercontent.com/utststs95/RBX-Building-Tools/refs/heads/development/"
local g = getgenv and getgenv() or nil
local loadFn = (g and (g.loadstring or g.load)) or loadstring

local function httpGet(url: string): string
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

local verSrc = httpGet(BASE .. "Launcher/Version.lua?bt=" .. tostring(tick()))
local verTag = verSrc:match('Launcher%s*=%s*"(%d+)"') or tostring(tick())
local entrySrc = httpGet(BASE .. "Launcher/RemoteEntry.lua?bt=" .. verTag)

local chunk, err = loadFn(entrySrc, "BT.RemoteEntry")
if not chunk then
	error("[BT] Bootstrap compile RemoteEntry: " .. tostring(err), 0)
end

local ok, runErr = pcall(chunk)
if not ok then
	error("[BT] Bootstrap: " .. tostring(runErr), 0)
end
