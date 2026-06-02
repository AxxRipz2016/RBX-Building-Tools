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
local versionInfo: { Launcher: string, Tool: string, Roact: string, Branch: string }? = nil

function RemoteToolBuilder.setManifest(paths: { string })
	manifestOverride = paths
end

function RemoteToolBuilder.setVersionInfo(info: { Launcher: string, Tool: string, Roact: string, Branch: string })
	versionInfo = info
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

local function stripSrcFolders(segments: { string }): { string }
	local out: { string } = {}
	for _, name in segments do
		if name ~= "src" then
			table.insert(out, name)
		end
	end
	return out
end

-- Файлы не по пути папок (см. default.project.json: Assets → корень Tool)
local MODULE_PLACEMENT: { [string]: { string } } = {
	["Support/Assets.lua"] = {},
}

local function parsePath(path: string): (string, { string })
	local placement = MODULE_PLACEMENT[path]
	if placement ~= nil then
		local fileName = string.match(path, "([^/]+)%.lua$") or path
		local moduleName = string.gsub(fileName, "%.lua$", "")
		return moduleName, placement
	end

	local segments = string.split(path, "/")
	local fileName = segments[#segments]
	table.remove(segments, #segments)
	segments = stripSrcFolders(segments)

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

local STAGING_NAME = "BT_RemoteStaging"

local function getStagingParent(): Folder
	local folder = ReplicatedStorage:FindFirstChild(STAGING_NAME)
	if folder and folder:IsA("Folder") then
		return folder
	end
	folder = Instance.new("Folder")
	folder.Name = STAGING_NAME
	folder.Parent = ReplicatedStorage
	return folder
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
	local isInitModule = path:sub(-#"init.lua") == "init.lua"

	local existing = parent:FindFirstChild(moduleName)
	if existing and existing:IsA("ModuleScript") then
		RemoteLoader.registerModule(existing, path)
		return existing
	end

	-- map.lua и т.п. могли создать Folder List/Dictionary до init.lua
	if isInitModule and existing and existing:IsA("Folder") then
		existing:Destroy()
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
	local toolVer = if versionInfo then versionInfo.Tool else "3.1.0"
	local version = Instance.new("StringValue")
	version.Name = "Version"
	version.Value = toolVer
	version.Parent = tool

	if versionInfo then
		tool:SetAttribute("BT_LauncherVersion", versionInfo.Launcher)
		tool:SetAttribute("BT_RoactVersion", versionInfo.Roact)
		tool:SetAttribute("BT_LoadBranch", versionInfo.Branch)

		local launcherVer = Instance.new("StringValue")
		launcherVer.Name = "LauncherVersion"
		launcherVer.Value = `r{versionInfo.Launcher}`
		launcherVer.Parent = tool
	end

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

local SKIPPED_TREE_PATHS = {
	["SyncAPI.lua"] = true,
	["Support/LocalAPIEndpoint.local.client.lua"] = true,
	["Support/DescendantCounter.local.client.lua"] = true,
	["Support/ReplicationListener.client.lua"] = true,
}

local function buildModuleTree(tool: Tool, paths: { string })
	local initPaths: { string } = {}
	local otherPaths: { string } = {}

	for _, path in paths do
		if SKIPPED_TREE_PATHS[path] then
			continue
		end
		if path:sub(-#"init.lua") == "init.lua" then
			table.insert(initPaths, path)
		else
			table.insert(otherPaths, path)
		end
	end

	table.sort(initPaths, function(a, b)
		return #a < #b
	end)
	table.sort(otherPaths, function(a, b)
		return #a < #b
	end)

	for _, path in initPaths do
		createModuleShell(tool, path)
	end
	for _, path in otherPaths do
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

	if RemoteLoader.isLoadCancelled() then
		error("[BT] загрузка отменена", 0)
	end

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
	tool.Parent = getStagingParent()

	if onMessage then
		onMessage("Сборка дерева модулей…")
	end

	buildModuleTree(tool, paths)

	if onMessage then
		onMessage("Предзагрузка Libraries…")
	end
	RemoteLoader.preloadByPrefixes(paths, { "Libraries/" })
	if onMessage then
		onMessage("Предзагрузка Roact…")
	end
	RemoteLoader.preloadByPrefixes(paths, { "Vendor/Roact/" })

	attachSyncAPI(tool)
	attachLoadedIndicator(tool)
	attachMetadata(tool)

	RemoteLoader.run("Support/LocalAPIEndpoint.local.client.lua", tool, tool.SyncAPI.LocalEndpoint :: LocalScript)
	RemoteLoader.run("Support/DescendantCounter.local.client.lua", tool, tool.Loaded.DescendantCount.DescendantCounter :: LocalScript)
	RemoteLoader.run("Support/ReplicationListener.client.lua", tool, tool.Loaded.ReplicationListener :: LocalScript)

	-- Tool в Backpack только после StartRuntime (см. RemoteEntry)
	return tool
end

function RemoteToolBuilder.GiveToPlayer(tool: Tool, player: Player?)
	player = player or Players.LocalPlayer
	local character = player.Character
	if character then
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			humanoid:UnequipTools()
		end
	end
	tool.Parent = player:WaitForChild("Backpack")
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
