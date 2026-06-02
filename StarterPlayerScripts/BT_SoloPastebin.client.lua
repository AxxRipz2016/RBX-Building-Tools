--[[
	Соло для executor. Не вставляйте старый RemoteEntry в paste — только Bootstrap (сброс кэша HttpGet).
]]
local BOOTSTRAP_URL =
	"https://raw.githubusercontent.com/utststs95/RBX-Building-Tools/refs/heads/development/Launcher/Bootstrap.lua"

local HttpService = game:GetService("HttpService")
local g = getgenv and getgenv() or nil
local loadFn = (g and (g.loadstring or g.load)) or loadstring
local httpGet = function(url: string)
	if g and g.http_request then
		local res = g.http_request({ Url = url, Method = "GET" })
		return (type(res) == "table" and (res.Body or res.body)) or ""
	end
	if g and g.request then
		local res = g.request({ Url = url, Method = "GET" })
		return (type(res) == "table" and (res.Body or res.body)) or ""
	end
	if HttpService.HttpEnabled then
		return HttpService:GetAsync(url)
	end
	return game:HttpGet(url, true)
end

local chunk, compileErr = loadFn(httpGet(BOOTSTRAP_URL .. "?bt=" .. tostring(tick())), "BT.Bootstrap")
if not chunk then
	warn("[BT Solo] compile Bootstrap:", compileErr)
	return
end

local ok, err = pcall(chunk)
if not ok then
	warn("[BT Solo]", err)
end
