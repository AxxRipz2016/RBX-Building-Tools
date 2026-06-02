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

local function httpGetRetry(url: string): string
	for attempt = 1, 6 do
		local ok, body = pcall(function()
			return httpGet(url)
		end)
		if ok and type(body) == "string" and #body > 40 then
			local head = body:sub(1, 120):lower()
			if not head:find("<!doctype", 1, true) and not head:find("<html", 1, true) then
				return body
			end
		end
		task.wait(0.35 * attempt)
	end
	return ""
end

local verSrc = httpGetRetry(BASE .. "Launcher/Version.lua?bt=" .. tostring(tick()))
local verTag = "0"
if verSrc ~= "" then
	verTag = verSrc:match('Launcher%s*=%s*"(%d+)"') or verSrc:match("Launcher%s*=%s*(%d+)") or tostring(tick())
end

local entrySrc = httpGetRetry(BASE .. "Launcher/RemoteEntry.lua?bt=" .. verTag)
if entrySrc == "" or not entrySrc:find("BT_LAUNCHER_BUSY", 1, true) then
	error("[BT] RemoteEntry не загрузился (пусто/HTML). Повтори через минуту", 0)
end

local chunk, err = loadFn(entrySrc, "BT.RemoteEntry")
if not chunk then
	error("[BT] Bootstrap compile RemoteEntry: " .. tostring(err), 0)
end

local ok, runErr = pcall(chunk)
if not ok then
	error("[BT] Bootstrap: " .. tostring(runErr), 0)
end
