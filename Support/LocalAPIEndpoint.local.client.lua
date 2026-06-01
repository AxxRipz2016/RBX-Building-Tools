--[[
	Клиентский SyncAPI: все действия выполняются локально (без сервера).
	Используется с Tool:SetAttribute("BT_LocalOnly", true).
]]
local Players = game:GetService("Players")

local SyncAPI = script.Parent
local SyncModule

SyncAPI.OnInvoke = function(...)
	SyncModule = SyncModule or require(SyncAPI:WaitForChild("SyncModule"))
	return SyncModule.PerformAction(Players.LocalPlayer, ...)
end
