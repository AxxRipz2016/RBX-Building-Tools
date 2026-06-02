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
	loaded.Parent = tool

	local descendantCount = Instance.new("IntValue")
	descendantCount.Name = "DescendantCount"
	descendantCount.Parent = loaded

	-- Solo/executor: ReplicationListener ждёт #потомков и может крутить while без отдачи кадра → белый экран
	if tool:GetAttribute("BT_LocalOnly") then
		descendantCount.Value = math.max(1, #tool:GetDescendants())
		loaded.Value = true
		return
	end

	loaded.Value = false
	descendantCount.Value = 0

	local counter = Instance.new("LocalScript")
	counter.Name = "DescendantCounter"
	counter.Parent = descendantCount
	RemoteLoader.registerModule(counter, "Support/DescendantCounter.local.client.lua")

	local listener = Instance.new("LocalScript")
	listener.Name = "ReplicationListener"
	listener.Parent = loaded
	RemoteLoader.registerModule(listener, "Support/ReplicationListener.client.lua")
end

local REQUIRED_INTERFACES = {
	"BTAnchorToolGUI",
	"BTCollisionToolGUI",
	"BTDecorateToolGUI",
	"BTLightingToolGUI",
	"BTMaterialToolGUI",
	"BTMeshToolGUI",
	"BTMoveToolGUI",
	"BTNewPartToolGUI",
	"BTPaintToolGUI",
	"BTResizeToolGUI",
	"BTRotateToolGUI",
	"BTSurfaceToolGUI",
	"BTTextureToolGUI",
	"BTWeldToolGUI",
}

local function ensureInterfacesFromLol(tool: Tool): boolean
	local interfaces = tool:FindFirstChild("Interfaces")
	if not interfaces then
		return false
	end

	local hasAll = true
	for _, name in REQUIRED_INTERFACES do
		if not interfaces:FindFirstChild(name) then
			hasAll = false
			break
		end
	end
	if hasAll then
		return true
	end

	_G.__bt_interfaces_root = interfaces
	local fallbackHost = Instance.new("ModuleScript")
	fallbackHost.Name = "lol_fallback"
	fallbackHost.Parent = interfaces
	RemoteLoader.registerModule(fallbackHost, "Launcher/Interfaces/lol.lua")
	local ok, err = pcall(function()
		RemoteLoader.run("Launcher/Interfaces/lol.lua", tool, fallbackHost)
	end)
	fallbackHost:Destroy()
	if not ok then
		warn(`[BT] не удалось собрать Interfaces из lol.lua: {tostring(err)}`)
		return false
	end

	for _, name in REQUIRED_INTERFACES do
		local gui = interfaces:FindFirstChild(name)
		if not gui then
			gui = game:GetService("Workspace"):FindFirstChild(name)
			if gui then
				gui.Parent = interfaces
			end
		end
	end

	for _, name in REQUIRED_INTERFACES do
		if not interfaces:FindFirstChild(name) then
			warn(`[BT] после lol.lua нет GUI: {name}`)
		end
	end
	return true
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

	if tool:GetAttribute("BT_LocalOnly") then
		tool:SetAttribute("BT_InterfacesPending", true)
		return
	end

	local payloadInterfaces = ReplicatedStorage:FindFirstChild("BT")
		and ReplicatedStorage.BT:FindFirstChild("Payload")
		and ReplicatedStorage.BT.Payload:FindFirstChild("Interfaces")

	if payloadInterfaces then
		for _, child in payloadInterfaces:GetChildren() do
			child:Clone().Parent = interfaces
		end
	end

	local hasAllInterfaces = true
	for _, name in REQUIRED_INTERFACES do
		if not interfaces:FindFirstChild(name) then
			hasAllInterfaces = false
			break
		end
	end

	if not hasAllInterfaces then
		ensureInterfacesFromLol(tool)
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
	tool.RequiresHandle = true
	tool.CanBeDropped = true
	tool:SetAttribute("BT_LocalOnly", true)
	-- Не кладём в ReplicatedStorage: иначе можно взять в руки до окончания StartRuntime
	tool.Parent = nil

	-- Handle, чтобы Tool можно было держать в руках (куб).
	do
		local handle = Instance.new("Part")
		handle.Name = "Handle"
		handle.Size = Vector3.new(1, 1, 1)
		handle.Color = Color3.fromRGB(255, 140, 60)
		handle.Material = Enum.Material.SmoothPlastic
		handle.Anchored = false
		handle.CanCollide = false
		handle.CanTouch = false
		handle.CanQuery = false
		handle.Massless = true
		handle.TopSurface = Enum.SurfaceType.Smooth
		handle.BottomSurface = Enum.SurfaceType.Smooth
		handle.Parent = tool
	end

	if onMessage then
		onMessage("Сборка дерева модулей…")
	end

	buildModuleTree(tool, paths)

	if onMessage then
		onMessage("Предзагрузка Libraries…")
	end
	RemoteLoader.preloadByPrefixes(paths, { "Libraries/" }, onFile)
	if onMessage then
		onMessage("Предзагрузка Roact…")
	end
	RemoteLoader.preloadByPrefixes(paths, { "Vendor/Roact/" }, onFile)

	if tool:GetAttribute("BT_LocalOnly") then
		if onMessage then
			onMessage("Предзагрузка Core / Move / UI…")
		end
		local warmPrefixes = { "Core/", "Tools/Move/", "UI/Dock/", "UI/Explorer/", "Support/Assets.lua" }
		for _, prefix in warmPrefixes do
			RemoteLoader.preloadByPrefixes(paths, { prefix }, onFile)
			task.wait()
		end
	else
		if onMessage then
			onMessage("Предзагрузка остальных модулей…")
		end
		local preloadFailed = RemoteLoader.preloadRemaining(paths, onFile)
		if #preloadFailed > 0 then
			warn(`[BT] не предзагружено: {table.concat(preloadFailed, ", ")}`)
		end
	end

	attachSyncAPI(tool)
	attachMetadata(tool)
	attachLoadedIndicator(tool)

	RemoteLoader.run("Support/LocalAPIEndpoint.local.client.lua", tool, tool.SyncAPI.LocalEndpoint :: LocalScript)

	if not tool:GetAttribute("BT_LocalOnly") then
		RemoteLoader.run(
			"Support/DescendantCounter.local.client.lua",
			tool,
			tool.Loaded.DescendantCount.DescendantCounter :: LocalScript
		)
		RemoteLoader.run(
			"Support/ReplicationListener.client.lua",
			tool,
			tool.Loaded.ReplicationListener :: LocalScript
		)
	end

	local loaded = tool:FindFirstChild("Loaded")
	if loaded and loaded:IsA("BoolValue") and not loaded.Value then
		local count = loaded:FindFirstChild("DescendantCount")
		if count and count:IsA("IntValue") then
			count.Value = #tool:GetDescendants()
		end
		loaded.Value = true
	elseif loaded and loaded:IsA("BoolValue") and tool:GetAttribute("BT_LocalOnly") then
		local count = loaded:FindFirstChild("DescendantCount")
		if count and count:IsA("IntValue") then
			count.Value = math.max(count.Value, #tool:GetDescendants())
		end
	end

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

function RemoteToolBuilder.StartRuntime(tool: Tool, onStep: ((string) -> ())?)
	local function step(msg: string)
		if onStep then
			onStep(msg)
		end
		task.wait()
	end

	if tool:GetAttribute("BT_LocalOnly") then
		step("Core…")
		local coreScript = tool:WaitForChild("Core") :: ModuleScript
		local coreEnv = RemoteLoader.run("Core/init.lua", tool, coreScript)
		if type(coreEnv) == "table" then
			_G.Core = coreEnv
		end

		if tool:GetAttribute("BT_InterfacesPending") then
			step("Интерфейсы (lol)…")
			ensureInterfacesFromLol(tool)
			tool:SetAttribute("BT_InterfacesPending", nil)
		end

		step("Готово")
		return _G.Core
	end

	step("Loader…")
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
