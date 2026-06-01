local Players = game:GetService("Players")

local Config = require(script.Parent.Config)
local Session = require(script.Parent.Session)
local ToolFactory = require(script.Parent.ToolFactory)
local ToolBuilder = require(script.Parent.ToolBuilder)
local RemoteToolBuilder = require(script.Parent.RemoteToolBuilder)
local BTRuntime = require(script.Parent.BTRuntime)
local UILoader = require(script.Parent.UILoader)

local Bootstrap = {}

local function setupTool()
	local player = Players.LocalPlayer
	if not Config.IsAllowed(player) then
		return
	end

	local tool = ToolFactory.GiveTool(player, function(status)
		UILoader.SetStatus(status)
	end)
	Session.Tool = tool

	UILoader.SetStatus("Загрузка BT…")

	if ToolFactory.WaitUntilLoaded(tool, 60) then
		Session.Loaded = true
		UILoader.SetStatus("Инициализация BT…")
		Session.Core = BTRuntime.Start(tool)
		UILoader.SetStatus("Экипировка…")
		if Config.LoadMode == "Remote" then
			RemoteToolBuilder.Equip(tool)
		else
			ToolBuilder.Equip(tool)
		end
		UILoader.SetStatus("Готово (локально)")
	else
		UILoader.SetStatus("Ошибка загрузки")
	end
end

function Bootstrap.RunUI()
	local player = Players.LocalPlayer
	if not Config.IsAllowed(player) then
		return
	end

	UILoader.Create(function()
		task.defer(setupTool)
	end)
end

function Bootstrap.RunToolSetup()
	task.defer(setupTool)
end

return Bootstrap
