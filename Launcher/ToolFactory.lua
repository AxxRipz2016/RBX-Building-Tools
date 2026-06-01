local Players = game:GetService("Players")

local Config = require(script.Parent.Config)
local ToolBuilder = require(script.Parent.ToolBuilder)
local RemoteToolBuilder = require(script.Parent.RemoteToolBuilder)
local RemoteLoader = require(script.Parent.RemoteLoader)

local ToolFactory = {}

function ToolFactory.FindTool(player: Player): Tool?
	local backpack = player:FindFirstChild("Backpack")
	if backpack then
		local tool = backpack:FindFirstChild(Config.ToolName)
		if tool and tool:IsA("Tool") then
			return tool
		end
	end
	local character = player.Character
	if character then
		local tool = character:FindFirstChild(Config.ToolName)
		if tool and tool:IsA("Tool") then
			return tool
		end
	end
	return nil
end

function ToolFactory.GiveTool(player: Player?, onProgress: ((string) -> ())?): Tool
	player = player or Players.LocalPlayer

	if Config.LoadMode == "Remote" then
		RemoteLoader.configure(Config.RemoteBaseUrl)
		return RemoteToolBuilder.Build(player, onProgress)
	end

	return ToolBuilder.Build(player)
end

function ToolFactory.WaitUntilLoaded(tool: Tool, timeoutSeconds: number?): boolean
	local loaded = tool:WaitForChild("Loaded", timeoutSeconds or 30)
	if not loaded:IsA("BoolValue") then
		return false
	end
	if loaded.Value then
		return true
	end
	local deadline = os.clock() + (timeoutSeconds or 30)
	while not loaded.Value and os.clock() < deadline do
		loaded.Changed:Wait()
	end
	return loaded.Value
end

function ToolFactory.WaitForTool(player: Player, timeoutSeconds: number?): Tool?
	local deadline = os.clock() + (timeoutSeconds or 30)
	repeat
		local tool = ToolFactory.FindTool(player)
		if tool then
			return tool
		end
		task.wait(0.1)
	until os.clock() >= deadline
	return nil
end

return ToolFactory
