local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(script.Parent.Config)

local ToolBuilder = {}

local function getPayload(): Folder
	return ReplicatedStorage:WaitForChild("BT"):WaitForChild("Payload")
end

local SKIPPED_SCRIPTS = {
	ToolInitializer = true,
	PluginInitializer = true,
}

local function isScriptInstance(instance: Instance): boolean
	return instance:IsA("ModuleScript") or instance:IsA("LocalScript")
end

local function shouldCloneScript(instance: Instance): boolean
	return isScriptInstance(instance) and not SKIPPED_SCRIPTS[instance.Name]
end

local function cloneScriptsInto(source: Instance, destination: Instance)
	for _, child in source:GetChildren() do
		if child:IsA("Folder") then
			local folder = destination:FindFirstChild(child.Name)
			if not folder then
				folder = Instance.new("Folder")
				folder.Name = child.Name
				folder.Parent = destination
			end
			cloneScriptsInto(child, folder)
		elseif shouldCloneScript(child) then
			child:Clone().Parent = destination
		end
	end
end

local function attachSyncAPI(tool: Tool, payload: Folder)
	local scriptsFolder = payload:WaitForChild("SyncAPI_Scripts")

	local syncAPI = Instance.new("BindableFunction")
	syncAPI.Name = "SyncAPI"
	syncAPI.Parent = tool

	for _, child in scriptsFolder:GetChildren() do
		if isScriptInstance(child) then
			child:Clone().Parent = syncAPI
		end
	end
end

local function attachLoadedIndicator(tool: Tool, payload: Folder)
	local scriptsFolder = payload:WaitForChild("Loaded_Scripts")

	local loaded = Instance.new("BoolValue")
	loaded.Name = "Loaded"
	loaded.Value = false
	loaded.Parent = tool

	local descendantCount = Instance.new("IntValue")
	descendantCount.Name = "DescendantCount"
	descendantCount.Value = 0
	descendantCount.Parent = loaded

	for _, child in scriptsFolder:GetChildren() do
		if not isScriptInstance(child) then
			continue
		end
		local clone = child:Clone()
		if clone.Name == "DescendantCounter" then
			clone.Parent = descendantCount
		else
			clone.Parent = loaded
		end
	end
end

local function attachInterfaces(tool: Tool, payload: Folder)
	local folder = Instance.new("Folder")
	folder.Name = "Interfaces"
	folder.Parent = tool

	local source = payload:FindFirstChild("Interfaces")
	if not source then
		warn("[BT] Payload.Interfaces не найден — вставь GUI из Building Tools by F3X.rbxmx")
		return folder
	end

	for _, child in source:GetChildren() do
		child:Clone().Parent = folder
	end

	if #folder:GetChildren() == 0 then
		warn("[BT] Payload.Interfaces пуст — скопируй BTMoveToolGUI и др. из Build/Building Tools by F3X.rbxmx")
	end

	return folder
end

local function attachMetadata(tool: Tool, payload: Folder)
	local version = Instance.new("StringValue")
	version.Name = "Version"
	version.Value = "3.1.0"
	version.Parent = tool

	local autoUpdate = Instance.new("BoolValue")
	autoUpdate.Name = "AutoUpdate"
	autoUpdate.Value = false
	autoUpdate.Parent = tool

	attachInterfaces(tool, payload)
end

local SCRIPT_ROOTS = { "Core", "Tools", "Loader", "Libraries", "Vendor", "UI", "Assets" }

local PACKAGE_ROOTS = {
	Core = true,
	Loader = true,
}

local function attachPackageRoot(tool: Tool, rootName: string, source: Folder)
	local init = source:FindFirstChild("init")
	if not init or not init:IsA("ModuleScript") then
		error(`Payload.{rootName}: нужен init ModuleScript`)
	end

	local root = init:Clone()
	root.Name = rootName
	root.Parent = tool

	for _, child in source:GetChildren() do
		if child == init or not shouldCloneScript(child) then
			continue
		end
		child:Clone().Parent = root
	end
end

local function attachScriptRoot(tool: Tool, rootName: string, source: Instance)
	if source:IsA("ModuleScript") then
		local clone = source:Clone()
		clone.Name = rootName
		clone.Parent = tool
		return
	end

	if not source:IsA("Folder") then
		return
	end

	if PACKAGE_ROOTS[rootName] then
		attachPackageRoot(tool, rootName, source)
		return
	end

	local folder = Instance.new("Folder")
	folder.Name = rootName
	folder.Parent = tool
	cloneScriptsInto(source, folder)
end

function ToolBuilder.Build(player: Player?): Tool
	player = player or Players.LocalPlayer

	local existing = player.Backpack:FindFirstChild(Config.ToolName)
	if existing and existing:IsA("Tool") then
		return existing
	end

	local payload = getPayload()

	local tool = Instance.new("Tool")
	tool.Name = Config.ToolName
	tool.RequiresHandle = false
	tool.CanBeDropped = true
	tool:SetAttribute("BT_LocalOnly", true)

	for _, rootName in SCRIPT_ROOTS do
		local source = payload:FindFirstChild(rootName)
		if source then
			attachScriptRoot(tool, rootName, source)
		end
	end

	attachSyncAPI(tool, payload)
	attachLoadedIndicator(tool, payload)
	attachMetadata(tool, payload)

	tool.Parent = player:WaitForChild("Backpack")
	return tool
end

function ToolBuilder.Equip(tool: Tool)
	local player = Players.LocalPlayer
	local character = player.Character
	if tool.Parent == player.Backpack and character then
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			humanoid:EquipTool(tool)
		end
	end
end

return ToolBuilder
