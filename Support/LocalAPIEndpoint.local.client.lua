--[[
	Клиентский SyncAPI: все действия выполняются локально (без сервера).
	Используется с Tool:SetAttribute("BT_LocalOnly", true).
]]
local Players = game:GetService("Players")

local SyncAPI = script.Parent
local SyncModule
local invokeDepth = 0

SyncAPI.OnInvoke = function(...)
	if invokeDepth > 0 then
		warn("[BT] SyncAPI: рекурсивный Invoke — пропуск")
		return nil
	end
	invokeDepth += 1
	local ok, result = pcall(function()
		SyncModule = SyncModule or require(SyncAPI:WaitForChild("SyncModule"))
		return SyncModule.PerformAction(Players.LocalPlayer, ...)
	end)
	invokeDepth -= 1
	if not ok then
		warn("[BT] SyncAPI:", result)
		return nil
	end
	return result
end
