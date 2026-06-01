local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local function req(moduleName: string)
	if _G.BT_LAUNCHER_LOAD then
		return _G.BT_LAUNCHER_LOAD("Launcher/" .. moduleName .. ".lua")
	end
	return require(script.Parent[moduleName])
end

local Config = req("Config")
local RemoteLoader = req("RemoteLoader")

local RemoteToolBuilder = {}

local manifestModule = (script and script.Parent and script.Parent:FindFirstChild("manifest")) or nil
local manifestOverride: { string }? = nil

function RemoteToolBuilder.setManifest(paths: { string })
	manifestOverride = paths
end

local function getManifest(): { string }
	if manifestOverride then
		return manifestOverride
	end
	if manifestModule then
		return require(manifestModule)
	end
	warn("[BT] manifest.lua не найден — запусти: node scripts/generate-manifest.js")
	return {}
end

local function parsePath(path: string): (string, { string })
	local segments = string.split(path, "/")
	local fileName = segments[#segments]
	table.remove(segments, #segments)

	if fileName == "init.lua" then
		local moduleName = segments[#segments]
		local parentParts = {}
		for index = 1, #segments - 1 do
			parentParts[index] = segments[index]
		end
		return moduleName, parentParts
	end

	local moduleName = string.gsub(fileName, "%.lua$", "")
	return moduleName, segments
end

local function getOrCreateFolder(parent: Instance, name: string): Folder
	local existing = parent:FindFirstChild(name)
	if existing and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = parent
	return folder
end

local function ensureParent(tool: Tool, parentParts: { string }): Instance
	local parent: Instance = tool
	for _, segment in parentParts do
		local child = parent:FindFirstChild(segment)
		if child and child:IsA("Folder") then
			parent = child
		elseif child and child:IsA("ModuleScript") then
			parent = child
		else
			parent = getOrCreateFolder(parent, segment)
		end
	end
	return parent
end

local function createModuleShell(tool: Tool, path: string): ModuleScript
	local moduleName, parentParts = parsePath(path)
	local parent = ensureParent(tool, parentParts)

	local existing = parent:FindFirstChild(moduleName)
	if existing and existing:IsA("ModuleScript") then
		RemoteLoader.registerModule(existing, path)
		return existing
	end

	local moduleScript = Instance.new("ModuleScript")
	moduleScript.Name = moduleName
	moduleScript.Parent = parent
	RemoteLoader.registerModule(moduleScript, path)
	return moduleScript
end

local function attachSyncAPI(tool: Tool)
	local syncAPI = Instance.new("BindableFunction")
	syncAPI.Name = "SyncAPI"
	syncAPI.Parent = tool

	local syncModule = Instance.new("ModuleScript")
	syncModule.Name = "SyncModule"
	syncModule.Parent = syncAPI
	RemoteLoader.registerModule(syncModule, "SyncAPI.lua")

	local localEndpoint = Instance.new("LocalScript")
	localEndpoint.Name = "LocalEndpoint"
	localEndpoint.Parent = syncAPI
	RemoteLoader.registerModule(localEndpoint, "Support/LocalAPIEndpoint.local.client.lua")
end

local function attachLoadedIndicator(tool: Tool)
	local loaded = Instance.new("BoolValue")
	loaded.Name = "Loaded"
	loaded.Value = false
	loaded.Parent = tool

	local descendantCount = Instance.new("IntValue")
	descendantCount.Name = "DescendantCount"
	descendantCount.Value = 0
	descendantCount.Parent = loaded

	local counter = Instance.new("LocalScript")
	counter.Name = "DescendantCounter"
	counter.Parent = descendantCount
	RemoteLoader.registerModule(counter, "Support/DescendantCounter.local.client.lua")

	local listener = Instance.new("LocalScript")
	listener.Name = "ReplicationListener"
	listener.Parent = loaded
	RemoteLoader.registerModule(listener, "Support/ReplicationListener.client.lua")
end

local function attachMetadata(tool: Tool)
	local version = Instance.new("StringValue")
	version.Name = "Version"
	version.Value = "3.1.0"
	version.Parent = tool

	local autoUpdate = Instance.new("BoolValue")
	autoUpdate.Name = "AutoUpdate"
	autoUpdate.Value = false
	autoUpdate.Parent = tool

	local interfaces = Instance.new("Folder")
	interfaces.Name = "Interfaces"
	interfaces.Parent = tool

	local payloadInterfaces = ReplicatedStorage:FindFirstChild("BT")
		and ReplicatedStorage.BT:FindFirstChild("Payload")
		and ReplicatedStorage.BT.Payload:FindFirstChild("Interfaces")

	if payloadInterfaces then
		for _, child in payloadInterfaces:GetChildren() do
			child:Clone().Parent = interfaces
		end
	end
end

local function buildModuleTree(tool: Tool, paths: { string })
	for _, path in paths do
		if path == "SyncAPI.lua"
			or path == "Support/LocalAPIEndpoint.local.client.lua"
			or path == "Support/DescendantCounter.local.client.lua"
			or path == "Support/ReplicationListener.client.lua"
		then
			continue
		end
		createModuleShell(tool, path)
	end
end

function RemoteToolBuilder.Build(
	player: Player?,
	callbacks: { onFile: any?, onMessage: any? } | ((string) -> ())?
): Tool
	player = player or Players.LocalPlayer

	local onFile: ((number, number, string, boolean, string?) -> ())?
	local onMessage: ((string) -> ())?
	if type(callbacks) == "function" then
		onMessage = callbacks
	elseif type(callbacks) == "table" then
		onFile = callbacks.onFile
		onMessage = callbacks.onMessage
	end

	local existing = player.Backpack:FindFirstChild(Config.ToolName)
	if existing and existing:IsA("Tool") then
		existing:Destroy()
	end
	local equipped = player.Character and player.Character:FindFirstChild(Config.ToolName)
	if equipped and equipped:IsA("Tool") then
		equipped:Destroy()
	end

	if not RemoteLoader.BaseUrl or RemoteLoader.BaseUrl == "" then
		error("[BT] Config.RemoteBaseUrl не задан", 0)
	end

	RemoteLoader.clear()

	local paths = getManifest()
	if onMessage then
		onMessage("Загрузка обязательных файлов…")
	end

	local failed = RemoteLoader.preloadCritical(function(index, total, path, fileOk, fileErr)
		if onFile then
			onFile(index, total, path, fileOk, fileErr)
		end
	end)

	RemoteLoader.assertCriticalLoaded()

	if #failed > 0 then
		error(`[BT] не удалось загрузить: {table.concat(failed, ", ")}`, 0)
	end

	if onMessage then
		onMessage(`Модули по требованию (всего в манифесте: {#paths})…`)
	end

	local tool = Instance.new("Tool")
	tool.Name = Config.ToolName
	tool.RequiresHandle = false
	tool.CanBeDropped = true
	tool:SetAttribute("BT_LocalOnly", true)

	if onMessage then
		onMessage("Сборка дерева модулей…")
	end

	buildModuleTree(tool, paths)
	attachSyncAPI(tool)
	attachLoadedIndicator(tool)
	attachMetadata(tool)

	RemoteLoader.run("Support/LocalAPIEndpoint.local.client.lua", tool, tool.SyncAPI.LocalEndpoint :: LocalScript)
	RemoteLoader.run("Support/DescendantCounter.local.client.lua", tool, tool.Loaded.DescendantCount.DescendantCounter :: LocalScript)
	RemoteLoader.run("Support/ReplicationListener.client.lua", tool, tool.Loaded.ReplicationListener :: LocalScript)

	tool.Parent = player:WaitForChild("Backpack")
	return tool
end

function RemoteToolBuilder.StartRuntime(tool: Tool)
	local loader = tool:WaitForChild("Loader") :: ModuleScript
	local path = loader:GetAttribute("BTPath") or "Loader/init.lua"
	return RemoteLoader.run(path, tool, loader)
end

function RemoteToolBuilder.Equip(tool: Tool)
	local player = Players.LocalPlayer
	local character = player.Character
	if tool.Parent == player.Backpack and character then
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			humanoid:EquipTool(tool)
		end
	end
end

return RemoteToolBuilder
