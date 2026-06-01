local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local btFolder = ReplicatedStorage:WaitForChild("BT")
local launcher = btFolder:WaitForChild("Launcher")
local Config = require(launcher.Config)
local ToolFactory = require(launcher.ToolFactory)

local requestTool = btFolder:WaitForChild("RemoteEvents"):WaitForChild("RequestTool") :: RemoteEvent

requestTool.OnServerEvent:Connect(function(player)
	ToolFactory.GiveTool(player)
end)

local function onPlayerAdded(player: Player)
	if not Config.IsAllowed(player) then
		return
	end
	task.defer(function()
		ToolFactory.GiveTool(player)
	end)
end

Players.PlayerAdded:Connect(onPlayerAdded)
for _, player in Players:GetPlayers() do
	onPlayerAdded(player)
end
