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
		onMessage(`Загрузка обязательных файлов (манифест: {#paths})…`)
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
	tool:SetAttribute("BT_ManifestCount", #paths)
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
		local warmPrefixes = { "Core/", "Tools/", "UI/Dock/", "UI/Explorer/", "Support/Assets.lua" }
		for _, prefix in warmPrefixes do
			RemoteLoader.preloadByPrefixes(paths, { prefix }, onFile)
			task.wait()
		end
		if onMessage then
			onMessage("Предзагрузка остальных модулей (манифест)…")
		end
		local preloadFailed = RemoteLoader.preloadRemaining(paths, onFile)
		if #preloadFailed > 0 then
			warn(`[BT] не предзагружено: {table.concat(preloadFailed, ", ")}`)
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

-- Fallback иконок (если Assets не в кэше); дублирует BT_DockIcons.lua
local DOCK_ICON_FALLBACK: { [string]: string } = {
	MoveIcon = "rbxassetid://141741366",
	ResizeIcon = "rbxassetid://141794324",
	RotateIcon = "rbxassetid://141807775",
	PaintIcon = "rbxassetid://141741444",
	SurfaceIcon = "rbxassetid://141803491",
	MaterialIcon = "rbxassetid://141809090",
	AnchorIcon = "rbxassetid://141741323",
	CollisionIcon = "rbxassetid://141809596",
	NewPartIcon = "rbxassetid://141741393",
	MeshIcon = "rbxassetid://141806786",
	TextureIcon = "rbxassetid://141805275",
	WeldIcon = "rbxassetid://141741418",
	LightingIcon = "rbxassetid://141741341",
	DecorateIcon = "rbxassetid://141741412",
}

local DOCK_TOOL_ROWS: { { string } } = {
	{ "MoveIcon", "Z", "Move" },
	{ "ResizeIcon", "X", "Resize" },
	{ "RotateIcon", "C", "Rotate" },
	{ "PaintIcon", "V", "Paint" },
	{ "SurfaceIcon", "B", "Surface" },
	{ "MaterialIcon", "N", "Material" },
	{ "AnchorIcon", "M", "Anchor" },
	{ "CollisionIcon", "K", "Collision" },
	{ "NewPartIcon", "J", "NewPart" },
	{ "MeshIcon", "H", "Mesh" },
	{ "TextureIcon", "G", "Texture" },
	{ "WeldIcon", "F", "Weld" },
	{ "LightingIcon", "U", "Lighting" },
	{ "DecorateIcon", "P", "Decorate" },
}

local function getDockIconTable(): { [string]: string }
	local icons: { [string]: string } = {}
	for key, id in DOCK_ICON_FALLBACK do
		icons[key] = id
	end
	local ok, fromLauncher = pcall(req, "BT_DockIcons")
	if ok and type(fromLauncher) == "table" then
		for key, id in fromLauncher do
			if type(id) == "string" then
				icons[key] = id
			end
		end
	end
	local assets = RemoteLoader.getCachedModule("Support/Assets.lua")
	if type(assets) == "table" then
		for key, id in assets do
			if type(id) == "string" and type(key) == "string" and key:match("Icon$") then
				icons[key] = id
			end
		end
	end
	return icons
end

local function findDockToolModule(tool: Tool, moduleName: string): ModuleScript?
	local tools = tool:FindFirstChild("Tools")
	if not tools then
		return nil
	end
	local direct = tools:FindFirstChild(moduleName)
	if direct and direct:IsA("ModuleScript") then
		return direct
	end
	if direct and direct:IsA("Folder") then
		local initMod = direct:FindFirstChild("init")
		if initMod and initMod:IsA("ModuleScript") then
			return initMod
		end
	end
	for _, child in tools:GetChildren() do
		if child.Name == moduleName and child:IsA("ModuleScript") then
			return child
		end
	end
	return nil
end

local function getDockRoactCryo(tool: Tool, coreEnv: any): (any?, any?)
	if type(coreEnv) == "table" and type(coreEnv.__bt_Roact) == "table" and type(coreEnv.__bt_Cryo) == "table" then
		return coreEnv.__bt_Roact, coreEnv.__bt_Cryo
	end
	local vendor = tool:FindFirstChild("Vendor")
	local libraries = tool:FindFirstChild("Libraries")
	if not vendor or not libraries then
		return nil, nil
	end
	local roactInst = vendor:FindFirstChild("Roact")
	local cryoInst = libraries:FindFirstChild("Cryo")
	local Roact, Cryo
	if roactInst and roactInst:IsA("ModuleScript") then
		local path = roactInst:GetAttribute("BTPath") or "Vendor/Roact/src/init.lua"
		Roact = RemoteLoader.getCachedModule(path)
		if Roact == nil then
			Roact = RemoteLoader.run(path, tool, roactInst)
		end
	end
	if cryoInst and cryoInst:IsA("ModuleScript") then
		local path = cryoInst:GetAttribute("BTPath") or "Libraries/Cryo/init.lua"
		Cryo = RemoteLoader.getCachedModule(path)
		if Cryo == nil then
			Cryo = RemoteLoader.run(path, tool, cryoInst)
		end
	end
	if type(coreEnv) == "table" then
		if Roact then
			coreEnv.__bt_Roact = Roact
		end
		if Cryo then
			coreEnv.__bt_Cryo = Cryo
		end
	end
	return Roact, Cryo
end

local function runBuildingToolModule(tool: Tool, moduleName: string): any?
	local modScript = findDockToolModule(tool, moduleName)
	if not modScript then
		return nil
	end
	local path = modScript:GetAttribute("BTPath")
		or (if moduleName == "Move" or moduleName == "Paint"
			then `Tools/{moduleName}/init.lua`
			else `Tools/{moduleName}.lua`)
	return RemoteLoader.run(path, tool, modScript)
end

local function purgeOldPlayerUI()
	local player = Players.LocalPlayer
	if not player then
		return
	end
	local pg = player:FindFirstChild("PlayerGui")
	if not pg then
		return
	end
	local old = pg:FindFirstChild("Building Tools by F3X (UI)")
	if old then
		old:Destroy()
	end
	_G.UI = nil
end

local function makeLazyBuildingTool(tool: Tool, moduleName: string, displayName: string, themeColor: Color3): any
	local loaded: any
	local proxy = {
		Name = displayName,
		Color = themeColor,
		__btModuleName = moduleName,
	}
	setmetatable(proxy, {
		__index = function(_, key)
			if not loaded then
				loaded = runBuildingToolModule(tool, moduleName)
				if type(loaded) == "table" then
					if loaded.Name then
						proxy.Name = loaded.Name
					end
					if loaded.Color then
						proxy.Color = loaded.Color
					end
				end
			end
			if type(loaded) ~= "table" then
				return nil
			end
			local value = loaded[key]
			if type(value) == "function" then
				return function(_, ...)
					return value(loaded, ...)
				end
			end
			return value
		end,
	})
	return proxy
end

local function ensureDockHotkeys(coreEnv: any, tool: Tool, icons: { [string]: string })
	if coreEnv.__bt_dockHotkeysDone or type(coreEnv.AssignHotkey) ~= "function" then
		return
	end
	for _, row in DOCK_TOOL_ROWS do
		local iconKey, hotkey, moduleName = row[1], row[2], row[3]
		if type(icons[iconKey]) == "string" and findDockToolModule(tool, moduleName) then
			coreEnv.AssignHotkey(hotkey, function()
				local mod = runBuildingToolModule(tool, moduleName)
				if type(coreEnv.EquipTool) == "function" then
					coreEnv.EquipTool(mod)
				end
			end)
		end
	end
	coreEnv.__bt_dockHotkeysDone = true
end

local function findToolListFrame(coreEnv: any): Frame?
	local ui = (type(coreEnv) == "table" and (coreEnv.UI or coreEnv.__bt_UI)) or nil
	if not ui or not ui:IsA("ScreenGui") then
		local pg = Players.LocalPlayer and Players.LocalPlayer:FindFirstChild("PlayerGui")
		ui = pg and pg:FindFirstChild("Building Tools by F3X (UI)")
	end
	if not ui then
		return nil
	end
	local dock = ui:FindFirstChild("Dock")
	return if dock then dock:FindFirstChild("ToolList") :: Frame? else nil
end

local function syncDockButtonsNative(coreEnv: any, tool: Tool, icons: { [string]: string }): number
	local toolListFrame = findToolListFrame(coreEnv)
	if not toolListFrame then
		return 0
	end

	for _, child in toolListFrame:GetChildren() do
		if child:IsA("ImageButton") then
			child:Destroy()
		end
	end

	local added = 0
	for index, row in DOCK_TOOL_ROWS do
		local iconKey, hotkey, moduleName = row[1], row[2], row[3]
		local iconId = icons[iconKey]
		if type(iconId) == "string" and findDockToolModule(tool, moduleName) then
		local btn = Instance.new("ImageButton")
		btn.Name = "BT_ToolBtn_" .. moduleName
		btn.LayoutOrder = index
		btn.Size = UDim2.fromOffset(35, 35)
		btn.BackgroundColor3 = Color3.fromRGB(255, 140, 60)
		btn.BackgroundTransparency = 1
		btn.BorderSizePixel = 0
		btn.Image = iconId
		btn.AutoButtonColor = false
		btn.Parent = toolListFrame

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 3)
		corner.Parent = btn

		local hotkeyLabel = Instance.new("TextLabel")
		hotkeyLabel.Name = "Hotkey"
		hotkeyLabel.BackgroundTransparency = 1
		hotkeyLabel.Position = UDim2.fromOffset(3, 3)
		hotkeyLabel.Size = UDim2.fromOffset(12, 12)
		hotkeyLabel.Font = Enum.Font.Gotham
		hotkeyLabel.Text = hotkey
		hotkeyLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
		hotkeyLabel.TextSize = 9
		hotkeyLabel.TextXAlignment = Enum.TextXAlignment.Left
		hotkeyLabel.TextYAlignment = Enum.TextYAlignment.Top
		hotkeyLabel.Parent = btn

		btn.Activated:Connect(function()
			if type(coreEnv.EquipTool) ~= "function" then
				return
			end
			if type(coreEnv.EnsureUI) == "function" then
				pcall(coreEnv.EnsureUI)
			end
			local mod = runBuildingToolModule(tool, moduleName)
			if type(coreEnv.ResolveBuildingToolModule) == "function" then
				mod = coreEnv.ResolveBuildingToolModule(mod) or mod
			end
			coreEnv.EquipTool(mod)
		end)

		added = added + 1
		end
	end

	local rows = math.max(1, math.ceil(added / 2))
	toolListFrame.Size = UDim2.fromOffset(70, 35 * rows)
	return added
end

-- Roact ToolList на GitHub часто без кнопок (4-й аргумент Children) — дублируем реальными ImageButton
local function waitAndSyncDock(tool: Tool, maxAttempts: number?): number
	maxAttempts = maxAttempts or 30
	for attempt = 1, maxAttempts do
		local core = _G.Core
		if type(core) == "table" then
			local n = syncDockButtonsNative(core, tool, getDockIconTable())
			if n > 0 then
				warn(`[BT] ToolList: {n} кнопок в UI (попытка {attempt})`)
				return n
			end
		end
		task.wait(0.2)
	end
	warn("[BT] ToolList: Frame не найден — проверь PlayerGui после экипировки")
	return 0
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
	if not tool:GetAttribute("BT_EquipDockHook") then
		tool:SetAttribute("BT_EquipDockHook", true)
		tool.Equipped:Connect(function()
			task.defer(function()
				local count = tool:GetAttribute("BT_DockButtonCount") or 0
				if count == 0 then
					count = waitAndSyncDock(tool, 30)
					tool:SetAttribute("BT_DockButtonCount", count)
				end
			end)
		end)
	end
	tool.Parent = player:WaitForChild("Backpack")
end

local function describeToolModules(tool: Tool): string
	local tools = tool:FindFirstChild("Tools")
	if not tools then
		return "Tools:нет"
	end
	local names: { string } = {}
	for _, child in tools:GetChildren() do
		table.insert(names, child.Name .. "(" .. child.ClassName .. ")")
	end
	return "Tools:" .. table.concat(names, ",")
end

local function registerDockDirect(coreEnv: any, tool: Tool): number
	coreEnv = (type(coreEnv) == "table" and coreEnv) or _G.Core
	if type(coreEnv) ~= "table" then
		warn("[BT] док: Core не загружен (_G.Core nil)")
		return 0
	end

	local icons = getDockIconTable()
	_G.__bt_dock_icons = icons
	coreEnv.Assets = icons

	local toolList = coreEnv.__bt_ToolList
	local dockHandle = coreEnv.__bt_DockHandle
	local dockComponent = coreEnv.__bt_DockComponent
	local ui = coreEnv.__bt_UI or coreEnv.UI
	local Roact, Cryo = getDockRoactCryo(tool, coreEnv)

	if type(toolList) ~= "table" or not dockHandle or not dockComponent or not Roact or not Cryo then
		if type(coreEnv.AddToolButton) ~= "function" then
			warn(
				`[BT] док: нет API (ToolList={toolList ~= nil}, AddToolButton={type(coreEnv.AddToolButton)}, Core.UI={coreEnv.UI ~= nil}) · {describeToolModules(tool)}`
			)
			return 0
		end
		coreEnv.__bt_dockButtonCount = 0
		local added = 0
		for _, row in DOCK_TOOL_ROWS do
			local iconKey, hotkey, moduleName = row[1], row[2], row[3]
			local iconId = icons[iconKey]
			if type(iconId) == "string" and findDockToolModule(tool, moduleName) then
				ensureDockHotkeys(coreEnv, tool, icons)
				local lazy = makeLazyBuildingTool(tool, moduleName, moduleName .. " Tool", Color3.fromRGB(255, 140, 60))
				coreEnv.AddToolButton(iconId, hotkey, lazy)
				added = added + 1
			end
		end
		coreEnv.__bt_dockButtonCount = added
		if type(coreEnv.RefreshToolDock) == "function" then
			coreEnv.RefreshToolDock()
		end
		return added
	end

	table.clear(toolList)
	local added = 0
	for _, row in DOCK_TOOL_ROWS do
		local iconKey, hotkey, moduleName = row[1], row[2], row[3]
		local iconId = icons[iconKey]
		if type(iconId) ~= "string" then
			warn(`[BT] нет иконки: {iconKey}`)
		elseif not findDockToolModule(tool, moduleName) then
			warn(`[BT] нет Tools/{moduleName}`)
		else
			ensureDockHotkeys(coreEnv, tool, icons)
			table.insert(toolList, {
				IconAssetId = iconId,
				HotkeyLabel = hotkey,
				Tool = makeLazyBuildingTool(tool, moduleName, moduleName .. " Tool", Color3.fromRGB(255, 140, 60)),
			})
			added = added + 1
		end
	end

	local toolsSnapshot = table.clone(toolList)
	if Cryo and type(Cryo.List) == "table" and type(Cryo.List.join) == "function" then
		local okJoin, joined = pcall(Cryo.List.join, toolList)
		if okJoin and type(joined) == "table" then
			toolsSnapshot = joined
		end
	end

	coreEnv.__bt_nativeDockOnly = true
	local dockProps = {
		Core = coreEnv,
		Tools = {},
		UIRoot = ui,
	}
	local dockElement = Roact.createElement(dockComponent, dockProps)
	pcall(function()
		if dockHandle then
			Roact.unmount(dockHandle)
		end
	end)
	local mountOk, mountHandleOrErr = pcall(function()
		return Roact.mount(dockElement, ui, "Dock")
	end)
	if mountOk and mountHandleOrErr then
		coreEnv.__bt_DockHandle = mountHandleOrErr
	else
		warn(`[BT] Roact.mount дока: {mountHandleOrErr}`)
	end

	local nativeCount = syncDockButtonsNative(coreEnv, tool, icons)
	if nativeCount > 0 then
		added = nativeCount
	end

	coreEnv.__bt_dockButtonCount = added
	coreEnv.__dockToolsRegistered = true
	return added
end

function RemoteToolBuilder.rebuildToolDock(tool: Tool): number
	local core = _G.Core
	if type(core) ~= "table" then
		return 0
	end
	return syncDockButtonsNative(core, tool, getDockIconTable())
end

_G.__bt_rebuildToolDock = function()
	local t = _G.__bt_tool
	if t and t:IsA("Tool") then
		return RemoteToolBuilder.rebuildToolDock(t)
	end
	return 0
end

local function preloadMoveModule(tool: Tool): any?
	local toolsFolder = tool:FindFirstChild("Tools")
	local moveScript = toolsFolder and toolsFolder:FindFirstChild("Move")
	if not moveScript or not moveScript:IsA("ModuleScript") then
		warn("[BT] Move ModuleScript не найден")
		return nil
	end
	local okMove, moveModOrErr = pcall(RemoteLoader.run, "Tools/Move/init.lua", tool, moveScript)
	if not okMove then
		warn(`[BT] Move preload: {moveModOrErr}`)
		return nil
	end
	if type(moveModOrErr) ~= "table" or type(moveModOrErr.Equip) ~= "function" then
		warn("[BT] Move preload: модуль без Equip/Unequip")
		return nil
	end
	return moveModOrErr
end

local function finishDockRegistration(coreEnv: any, tool: Tool): number
	local assetsScript = tool:FindFirstChild("Assets")
	if assetsScript and assetsScript:IsA("ModuleScript") then
		pcall(RemoteLoader.run, "Support/Assets.lua", tool, assetsScript)
	end
	local added = registerDockDirect(coreEnv, tool)
	if added == 0 and type(coreEnv) == "table" and type(coreEnv.RegisterDockTools) == "function" then
		coreEnv.__dockToolsRegistered = false
		coreEnv.__bt_dockButtonCount = 0
		local ok, err = pcall(coreEnv.RegisterDockTools)
		if not ok then
			warn(`[BT] RegisterDockTools fallback: {err}`)
		end
		added = coreEnv.__bt_dockButtonCount or 0
	end
	return added
end

function RemoteToolBuilder.StartRuntime(tool: Tool, onStep: ((string) -> ())?)
	local function step(msg: string)
		if onStep then
			onStep(msg)
		end
		task.wait()
	end

	if tool:GetAttribute("BT_LocalOnly") then
		_G.__bt_tool = tool
		purgeOldPlayerUI()

		step("Assets…")
		local assetsScript = tool:FindFirstChild("Assets")
		if assetsScript and assetsScript:IsA("ModuleScript") then
			pcall(RemoteLoader.run, "Support/Assets.lua", tool, assetsScript)
		end
		_G.__bt_dock_icons = req("BT_DockIcons")

		step("Core…")
		local coreScript = tool:WaitForChild("Core") :: ModuleScript
		local coreEnv = RemoteLoader.run("Core/init.lua", tool, coreScript)

		step("Move…")
		local moveMod = preloadMoveModule(tool)
		if type(coreEnv) == "table" then
			_G.Core = coreEnv
			if moveMod then
				coreEnv.__bt_defaultMove = moveMod
			end
			local rawEquip = coreEnv.EquipTool
			if type(rawEquip) == "function" then
				coreEnv.EquipTool = function(toolModule: any)
					local resolved = moveMod
					if type(toolModule) == "table" and type(toolModule.Equip) == "function" then
						resolved = toolModule
					elseif type(coreEnv.ResolveBuildingToolModule) == "function" then
						local fromResolve = coreEnv.ResolveBuildingToolModule(toolModule)
						if type(fromResolve) == "table" and type(fromResolve.Equip) == "function" then
							resolved = fromResolve
						end
					end
					if type(resolved) ~= "table" or type(resolved.Equip) ~= "function" then
						resolved = coreEnv.__bt_defaultMove or moveMod
					end
					if type(resolved) ~= "table" or type(resolved.Equip) ~= "function" then
						warn("[BT] EquipTool: модуль инструмента недоступен")
						return
					end
					return rawEquip(resolved)
				end
			end
		end

		if not moveMod then
			moveMod = preloadMoveModule(tool)
			if moveMod and type(coreEnv) == "table" then
				coreEnv.__bt_defaultMove = moveMod
			end
		end

		step("Док…")
		local dockCount = finishDockRegistration(coreEnv, tool)
		tool:SetAttribute("BT_DockButtonCount", dockCount)
		warn(`[BT] StartRuntime док: {dockCount} (нативные кнопки появятся после экипировки)`)

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
