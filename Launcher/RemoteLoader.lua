--[[
	Ленивая загрузка с GitHub: throttle, retry, loadstring из executor.
]]
local HttpService = game:GetService("HttpService")

-- Сразу в _G: старый RemoteEntry / обрезанный HttpGet иначе получают nil вместо модуля
local RemoteLoader = if type(_G.BT_RemoteLoader) == "table" then _G.BT_RemoteLoader else {}
_G.BT_RemoteLoader = RemoteLoader

local sourceCache: { [string]: string } = {}
local moduleCache: { [string]: any } = {}
local registry: { [ModuleScript]: string } = {}
local failedPaths: { [string]: string } = {}

local FETCH_DELAY = 0.1
local MAX_RETRIES = 6
local lastFetchAt = 0
local fetchCount = 0

local progressCallback: ((string, boolean, string?) -> ())?

local continueOnError = true
local runtimeErrors: { string } = {}
local loadCancelled = false

local NO_STUB_PATHS: { [string]: boolean } = {
	["Core/init.lua"] = true,
	["Loader/init.lua"] = true,
	["Core/BoundingBox.lua"] = true,
	["Core/Snapping.lua"] = true,
	["SyncAPI.lua"] = true,
	["Tools/Move/init.lua"] = true,
	["Support/Assets.lua"] = true,
}

local CRITICAL_PATHS = {
	"Core/init.lua",
	"Loader/init.lua",
	"SyncAPI.lua",
	"Support/LocalAPIEndpoint.local.client.lua",
	"Support/DescendantCounter.local.client.lua",
	"Support/ReplicationListener.client.lua",
	"Support/Assets.lua",
}

local function throttle()
	local now = os.clock()
	local waitFor = FETCH_DELAY - (now - lastFetchAt)
	if waitFor > 0 then
		task.wait(waitFor)
	end
	lastFetchAt = os.clock()
end

local function defaultHttpGet(url: string): string
	if HttpService.HttpEnabled then
		return HttpService:GetAsync(url)
	end
	return game:HttpGet(url, true)
end

local function defaultCompile(source: string, chunkName: string, env: any?): (any?, string?)
	local g = if getgenv then getgenv() else nil
	local r = if getrenv then getrenv() else nil
	local loadFn = (g and (g.load or g.loadstring))
		or (r and (r.load or r.loadstring))
		or load
		or loadstring

	if type(loadFn) ~= "function" then
		return nil, "load/loadstring недоступен (нужен executor)"
	end

	if env ~= nil then
		local lastErr: string?
		local attempts = {
			function()
				return loadFn(source, chunkName, "t", env)
			end,
			function()
				return loadFn(source, chunkName, env)
			end,
		}
		for _, attempt in attempts do
			local fn, err = attempt()
			if fn then
				return fn, nil
			end
			lastErr = if err then tostring(err) else lastErr
		end
		return nil, lastErr or "load с env не поддерживается"
	end

	local fn, err = loadFn(source, chunkName)
	if not fn then
		return nil, tostring(err or "compile failed")
	end
	return fn, nil
end

local vendorPrefixes: { { prefix: string, base: string } } = {}

local function normalizeBase(url: string): string
	if not url:match("/$") then
		return url .. "/"
	end
	return url
end

local function normalizeBody(body: string): string
	if body:sub(1, 3) == string.char(0xEF, 0xBB, 0xBF) then
		body = body:sub(4)
	end
	return body
end

local CORE_INIT_CHILDREN = { "Security", "History", "Selection", "Targeting" }

local CORE_SELF = "(_G.Core or Core)"

local function patchCoreSelfReference(source: string): string
	source = source:gsub("local Core = getfenv%(0%)", `local Core = {CORE_SELF}`)
	source = source:gsub("Core = getfenv%(0%)", `Core = {CORE_SELF}`)
	return source
end

-- Loader/UI читают Core.Support — один блок после Assets (не gsub по всему файлу: ломает { Selection = … })
local CORE_EXPORT_BLOCK = [[
Core.Security = Security
Core.History = History
Core.Selection = Selection
Core.Targeting = Targeting
Core.BoundingBox = BoundingBoxModule
Core.Region = Region
Core.Signal = Signal
Core.Support = Support
Core.Try = Try
Core.Make = Make
Core.Assets = Assets
Core.Tool = Tool
]]

local CORE_UI_EXPORT_BLOCK = [[
Core.ToolChanged = ToolChanged
Core.Mode = Mode
]]

-- AssignHotkey/EquipTool объявляются позже — не экспортировать раньше (иначе Core.AssignHotkey = nil)
local CORE_RESOLVE_TOOL_BLOCK = [[
local function IsBuildingToolModule(ToolModule)
	return type(ToolModule) == "table"
		and type(ToolModule.Equip) == "function"
		and type(ToolModule.Unequip) == "function"
end

local cachedDefaultMove

local function DefaultBuildingToolModule()
	if IsBuildingToolModule(cachedDefaultMove) then
		return cachedDefaultMove
	end
	if type(Core) == "table" and IsBuildingToolModule(Core.__bt_defaultMove) then
		cachedDefaultMove = Core.__bt_defaultMove
		return cachedDefaultMove
	end
	local tools = Tool:FindFirstChild("Tools")
	local moveInst = tools and tools:FindFirstChild("Move")
	if not moveInst or not moveInst:IsA("ModuleScript") then
		warn("[BT] DefaultBuildingToolModule: Move ModuleScript не найден")
		return nil
	end
	local ok, mod = pcall(require, moveInst)
	if not ok or not IsBuildingToolModule(mod) then
		warn("[BT] require Move:", mod)
		return nil
	end
	cachedDefaultMove = mod
	Core.__bt_defaultMove = mod
	return mod
end

function ResolveBuildingToolModule(BuildingToolModule)
	if typeof(BuildingToolModule) == "Instance" then
		return nil
	end
	if type(BuildingToolModule) ~= "table" then
		return nil
	end
	local moduleName = BuildingToolModule.__btModuleName
	if type(moduleName) == "string" then
		local toolsFolder = Tool:FindFirstChild("Tools")
		local mod = toolsFolder and toolsFolder:FindFirstChild(moduleName)
		if mod then
			return require(mod)
		end
	end
	if IsBuildingToolModule(BuildingToolModule) then
		return BuildingToolModule
	end
	return nil
end
]]

local CORE_LATE_EXPORT_BLOCK = [[
Core.ResolveBuildingToolModule = ResolveBuildingToolModule
Core.RegisterDockTools = RegisterDockTools
Core.EquipTool = EquipTool
Core.AssignHotkey = AssignHotkey
Core.ToggleExplorer = ToggleExplorer
Core.DeleteSelection = DeleteSelection
Core.CloneSelection = CloneSelection
Core.ExportSelection = ExportSelection
]]

-- API, который Tools читают как Core.* (в executor без этого — nil)
local CORE_API_EXPORT_BLOCK = [[
Core.IsSelectable = IsSelectable
Core.PreserveJoints = PreserveJoints
Core.RestoreJoints = RestoreJoints
Core.ToggleSwitch = ToggleSwitch
Core.SyncAPI = SyncAPI
Core.Mouse = Mouse
Core.CurrentTool = CurrentTool
]]

-- Регистрация кнопок дока: require только по клику/хоткею (не блокировать старт)
local CORE_DOCK_REGISTER_BLOCK = [[

function RegisterDockTools()
	if type(Core.AddToolButton) ~= "function" then
		warn("[BT] RegisterDockTools: сначала нужен InitializeUI (AddToolButton)")
		return
	end
	if type(Assets) ~= "table" then
		warn("[BT] RegisterDockTools: Assets не загружен")
		return
	end
	if Core.__dockToolsRegistered and (Core.__bt_dockButtonCount or 0) > 0 then
		if Core.RefreshToolDock then
			Core.RefreshToolDock()
		end
		return
	end
	local function LazyTool(moduleName, displayName, themeColor)
		local loaded
		local proxy = {
			Name = displayName;
			Color = themeColor;
			__btModuleName = moduleName;
		}
		setmetatable(proxy, {
			__index = function(_, key)
				if not loaded then
					loaded = require(Tool:WaitForChild('Tools'):WaitForChild(moduleName))
					if loaded.Name then proxy.Name = loaded.Name end
					if loaded.Color then proxy.Color = loaded.Color end
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
	local function BT_Reg(iconKey, hotkey, moduleName, displayName, themeColor)
		local iconId = rawget(Assets, iconKey)
		if type(iconId) ~= "string" then
			local fb = _G.__bt_dock_icons
			if type(fb) == "table" then
				iconId = fb[iconKey]
			end
		end
		if type(iconId) ~= "string" then
			warn("[BT] нет иконки:", iconKey)
			return
		end
		local lazy = LazyTool(moduleName, displayName, themeColor)
		AssignHotkey(hotkey, function()
			EquipTool(require(Tool:WaitForChild('Tools'):WaitForChild(moduleName)))
		end)
		Core.AddToolButton(iconId, hotkey, lazy)
	end
	BT_Reg('MoveIcon', 'Z', 'Move', 'Move Tool', Color3.fromRGB(255, 140, 60))
	BT_Reg('ResizeIcon', 'X', 'Resize', 'Resize Tool', Color3.fromRGB(0, 120, 255))
	BT_Reg('RotateIcon', 'C', 'Rotate', 'Rotate Tool', Color3.fromRGB(80, 200, 80))
	BT_Reg('PaintIcon', 'V', 'Paint', 'Paint Tool', Color3.fromRGB(255, 80, 80))
	BT_Reg('SurfaceIcon', 'B', 'Surface', 'Surface Tool', Color3.fromRGB(255, 220, 80))
	BT_Reg('MaterialIcon', 'N', 'Material', 'Material Tool', Color3.fromRGB(60, 160, 80))
	BT_Reg('AnchorIcon', 'M', 'Anchor', 'Anchor Tool', Color3.fromRGB(255, 160, 60))
	BT_Reg('CollisionIcon', 'K', 'Collision', 'Collision Tool', Color3.fromRGB(160, 80, 255))
	BT_Reg('NewPartIcon', 'J', 'NewPart', 'New Part Tool', Color3.fromRGB(240, 240, 240))
	BT_Reg('MeshIcon', 'H', 'Mesh', 'Mesh Tool', Color3.fromRGB(255, 150, 200))
	BT_Reg('TextureIcon', 'G', 'Texture', 'Texture Tool', Color3.fromRGB(220, 80, 220))
	BT_Reg('WeldIcon', 'F', 'Weld', 'Weld Tool', Color3.fromRGB(30, 30, 30))
	BT_Reg('LightingIcon', 'U', 'Lighting', 'Lighting Tool', Color3.fromRGB(255, 230, 100))
	BT_Reg('DecorateIcon', 'P', 'Decorate', 'Decorate Tool', Color3.fromRGB(255, 100, 180))
	Core.__dockToolsRegistered = true
	if Core.RefreshToolDock then
		Core.RefreshToolDock()
	end
end

RegisterDockTools();
]]

local function patchCoreModuleExports(source: string): string
	if source:find("Core.Support = Support", 1, true) then
		return source
	end
	local inserted = source:gsub("(Assets = require%([^\n]+%)\n)", "%1" .. CORE_EXPORT_BLOCK .. "\n", 1)
	if inserted == source then
		inserted = source:gsub("(Cryo = require%([^\n]+%)\n)", "%1" .. CORE_EXPORT_BLOCK .. "\n", 1)
	end
	return inserted
end

local function patchCoreUiExports(source: string): string
	if source:find("Core.ToolChanged = ToolChanged", 1, true) then
		return source
	end
	local inserted = source:gsub("(ToolChanged = Signal%.new%(%)\n)", "%1" .. CORE_UI_EXPORT_BLOCK, 1)
	return inserted
end

local function patchCoreLateExports(source: string): string
	source = source:gsub("BrickColor%.new%('Black'%)", "BrickColor.new('Really black')")
	source = source:gsub(
		"AddToolButton%(Assets%[iconKey%], hotkey,",
		"Core.AddToolButton(Assets[iconKey], hotkey,"
	)
	if source:find("function RegisterDockTools", 1, true) then
		source = source:gsub(
			"InitializeUI%(%);\r?\nRegisterDockTools%(%);",
			"InitializeUI(); -- BT: RegisterDockTools deferred to StartRuntime",
			1
		)
		source = source:gsub(
			"\nRegisterDockTools%(%);\r?\n\r?\nCore%.ResolveBuildingToolModule",
			"\n-- BT: RegisterDockTools via StartRuntime\n\nCore.ResolveBuildingToolModule",
			1
		)
		if not source:find("RegisterDockTools%(%);", 1, true) then
			source = source:gsub("(InitializeUI%(%);%s*\n)", "%1RegisterDockTools();\n", 1)
		end
		return source
	end
	if source:find("BT_Reg%('MoveIcon'", 1, true) or source:find("__dockToolsRegistered", 1, true) then
		return source
	end
	-- убрать ранний ошибочный экспорт (r47): AssignHotkey ещё не объявлен
	source = source:gsub(
		"(ToolChanged = Signal%.new%(%)\nCore%.ToolChanged = ToolChanged\nCore%.Mode = Mode\n)Core%.EquipTool = EquipTool\nCore%.AssignHotkey = AssignHotkey\n",
		"%1"
	)
	if source:find("Core.IsSelectable = IsSelectable", 1, true) then
		return source
	end
	return source:gsub(
		"(%-%- Initialize the UI\nInitializeUI%(%);)",
		CORE_API_EXPORT_BLOCK .. "\n\n%1\n" .. CORE_LATE_EXPORT_BLOCK .. "\n" .. CORE_DOCK_REGISTER_BLOCK .. "\n",
		1
	)
end

-- В env Tool = Roblox Tool; параметры function (Tool) перекрывают env → Tool.Color у Building Tools
local function patchCoreToolParamShadowing(source: string): string
	-- ToolChanged: в executor параметр Tool = Roblox Tool; в теле coroutine.wrap(...)(Tool.Color), не RecolorHandle(Tool.Color)
	source = source:gsub(
		"ToolChanged:Connect%(function %(Tool%)\r?\n\tcoroutine%.wrap%(RecolorHandle%)%(Tool%.Color%);?\r?\n\tcoroutine%.wrap%(Selection%.RecolorOutlines%)%(Tool%.Color%);?\r?\nend%);",
		[[ToolChanged:Connect(function (BuildingToolModule)
	if type(BuildingToolModule) ~= "table" or BuildingToolModule.Color == nil then
		return
	end
	local themeColor = BuildingToolModule.Color
	coroutine.wrap(RecolorHandle)(themeColor)
	coroutine.wrap(Selection.RecolorOutlines)(themeColor)
end);]]
	)
	source = source:gsub("ToolChanged:Connect%(function %(Tool%)", "ToolChanged:Connect(function (BuildingToolModule)")
	source = source:gsub(
		"coroutine%.wrap%(RecolorHandle%)%(Tool%.Color%)",
		"coroutine.wrap(RecolorHandle)(BuildingToolModule.Color)"
	)
	source = source:gsub(
		"coroutine%.wrap%(Selection%.RecolorOutlines%)%(Tool%.Color%)",
		"coroutine.wrap(Selection.RecolorOutlines)(BuildingToolModule.Color)"
	)
	source = source:gsub("RecolorHandle%(Tool%.Color%)", "RecolorHandle(BuildingToolModule.Color)")
	source = source:gsub(
		"Selection%.RecolorOutlines%(Tool%.Color%)",
		"Selection.RecolorOutlines(BuildingToolModule.Color)"
	)

	local coreToolPatchesNeeded = not source:find("ResolveBuildingToolModule", 1, true)
	if coreToolPatchesNeeded then
		source = source:gsub("(function EquipTool%()", CORE_RESOLVE_TOOL_BLOCK .. "\n\n%1", 1)
		source = source:gsub("function EquipTool%(Tool%)", "function EquipTool(BuildingToolModule)")
		source = source:gsub(
			"if CurrentTool and CurrentTool%.Equipped then\r?\n\t\tCurrentTool:Unequip%(%);\r?\n\t\tCurrentTool%.Equipped = false;\r?\n\tend;",
			[[if CurrentTool then
		local activeTool = ResolveBuildingToolModule(CurrentTool)
		if activeTool.Equipped then
			activeTool:Unequip();
			activeTool.Equipped = false;
		end
	end;]]
		)
		source = source:gsub(
			"EquipTool%(ResolveBuildingToolModule%(CurrentTool%) or require%(Tool%.Tools%.Move%)%)",
			"EquipTool(ResolveBuildingToolModule(CurrentTool) or DefaultBuildingToolModule())"
		)
		source = source:gsub(
			"EquipTool%(CurrentTool or require%(Tool%.Tools%.Move%)%)",
			"EquipTool(ResolveBuildingToolModule(CurrentTool) or DefaultBuildingToolModule())"
		)
		source = source:gsub(
			"if CurrentTool then\r?\n\t\tCurrentTool:Unequip%(%);\r?\n\t\tCurrentTool%.Equipped = false;",
			[[if CurrentTool then
		local activeTool = ResolveBuildingToolModule(CurrentTool)
		activeTool:Unequip();
		activeTool.Equipped = false;]]
		)
		source = source:gsub("CurrentTool = Tool;", "CurrentTool = BuildingToolModule;")
	end
	source = source:gsub("ToolChanged:Fire%(Tool%)", "ToolChanged:Fire(BuildingToolModule)")
	source = source:gsub("Tool:Equip%(%);", "BuildingToolModule:Equip();", 1)

	-- AddToolButton: { Tool = Tool } в executor берёт env Tool (Roblox), не параметр
	source = source:gsub(
		"local function AddToolButton%(IconAssetId, HotkeyLabel, Tool%)",
		"local function AddToolButton(IconAssetId, HotkeyLabel, ToolModule)"
	)
	source = source:gsub(
		"HotkeyLabel = HotkeyLabel;\n\t\t\tTool = Tool;",
		"HotkeyLabel = HotkeyLabel;\n\t\t\tTool = ToolModule;"
	)

	return source
end

local function patchCoreReturn(source: string): string
	return source:gsub("return getfenv%(0%)", "return (_G.Core or Core)")
end

local CORE_BT = "((_G.__bt_tool or Tool):WaitForChild('Core'))"

local BT_GET_CORE_BODY = [[function GetCore()
	if type(_G.Core) == "table" then
		return _G.Core
	end
	local rbxTool = _G.__bt_tool or Tool
	local coreInst = rbxTool and rbxTool:FindFirstChild("Core")
	if coreInst and coreInst:IsA("ModuleScript") then
		return require(coreInst)
	end
	error("[BT] GetCore: Core не инициализирован", 0)
end]]

-- executor: require(script.Parent) / require(Tool.Core) часто не тот же объект, что _G.Core
local function patchCoreAndToolRequires(path: string, source: string): string
	local coreViaScript = "(_G.Core or require((_G.__bt_tool or Tool):WaitForChild('Core')))"

	if path:sub(1, 6) == "Core/" and path ~= "Core/init.lua" then
		source = source:gsub("Core = require%(script%.Parent%);", "Core = " .. coreViaScript .. ";")
		source = source:gsub("local Core = require%(script%.Parent%);", "local Core = " .. coreViaScript .. ";")
		source = source:gsub(
			"function GetCore%(%)\r?\n\t%-%- Returns the core API\r?\n\treturn require%(script%.Parent%);",
			BT_GET_CORE_BODY,
			1
		)
		source = source:gsub(
			"function GetCore%(%)\r?\n\treturn require%(script%.Parent%);",
			BT_GET_CORE_BODY,
			1
		)
		source = source:gsub("return require%(script%.Parent%);", "return (_G.Core or Core)")

		for _, child in CORE_INIT_CHILDREN do
			source = source:gsub(
				"require%(script%.Parent." .. child .. "%)",
				"require(" .. CORE_BT .. ":WaitForChild('" .. child .. "'))"
			)
		end

		source = source:gsub(
			"require%(Core%.Tool%.Core%.BoundingBox%)",
			"require(" .. CORE_BT .. ":WaitForChild('BoundingBox'))"
		)

		if path == "Core/ListenForManualWindowTrigger.lua" then
			source = source:gsub(
				"local Core = require%(Tool%.Core%)",
				"local Core = _G.Core or require(Tool.Core)"
			)
		end
	end

	if path:find("^Tools/", 1, true) or path == "Core/ListenForManualWindowTrigger.lua" then
		local toolCoreBootstrap = [[

Core = _G.Core or Core
if Core then
	local sync = Tool:FindFirstChild("SyncAPI")
	if sync then
		Core.SyncAPI = Core.SyncAPI or sync
	end
	if Core.SyncAPI and type(Core.SyncAPI.Invoke) ~= "function" then
		Core.SyncAPI = { Invoke = function() return nil end }
	end
end
]]
		source = source:gsub("Core = require%(Tool%.Core%);", "Core = _G.Core or require(Tool.Core);" .. toolCoreBootstrap)
		source = source:gsub(
			"local Core = require%(Tool%.Core%)",
			"local Core = _G.Core or require(Tool.Core)" .. toolCoreBootstrap
		)
		source = source:gsub(
			"local BoundingBox = require%(Tool%.Core%.BoundingBox%)",
			"local BoundingBox = Core.BoundingBox or require(Tool:WaitForChild('Core'):WaitForChild('BoundingBox'))"
		)
		source = source:gsub(
			"BoundingBox = require%(Tool%.Core%.BoundingBox%)",
			"BoundingBox = Core.BoundingBox or require(Tool:WaitForChild('Core'):WaitForChild('BoundingBox'))"
		)
		source = source:gsub(
			"SnapTracking = require%(Tool%.Core%.Snapping%)",
			"SnapTracking = require(Tool:WaitForChild('Core'):WaitForChild('Snapping'))"
		)
		source = source:gsub(
			"require%(Core%.Tool%.Tools%.Move%)",
			"require((Core.Tool or Tool).Tools.Move)"
		)
	end

	return source
end

local function patchCoreInitRequires(source: string): string
	for _, child in CORE_INIT_CHILDREN do
		local viaTool = `require(Tool:WaitForChild('Core'):WaitForChild('{child}'))`
		source = source:gsub(`{child} = require%(script%.{child}%)`, `{child} = {viaTool}`)
		source = source:gsub(`{child} = require%(__bt_script%.{child}%)`, `{child} = {viaTool}`)
		source = source:gsub(`require%(script%.{child}%)`, viaTool)
		source = source:gsub(`require%(__bt_script%.{child}%)`, viaTool)
	end
	return source
end

local function applyCoreEquipSafetyPatches(source: string): string
	source = source:gsub(
		"BuildingToolModule:Equip%(%);",
		[[if type(BuildingToolModule) == "table" and type(BuildingToolModule.Equip) == "function" then
		local __bt_ok, __bt_err = pcall(function()
			BuildingToolModule:Equip()
		end)
		if not __bt_ok then
			warn("[BT] Equip failed:", __bt_err)
		end
	end]]
	)
	source = source:gsub(
		"EquipTool%(initialTool%);",
		[[do
		local __bt_t = initialTool
		if type(__bt_t) ~= "table" or type(__bt_t.Equip) ~= "function" then
			__bt_t = (type(Core) == "table" and Core.__bt_defaultMove) or nil
		end
		if type(__bt_t) == "table" and type(__bt_t.Equip) == "function" then
			EquipTool(__bt_t)
		else
			warn("[BT] Enable: Move недоступен, Equip пропущен")
		end
	end]]
	)
	return source
end

local function getEmbeddedToolListSource(): string?
	if type(_G.BT_TOOL_LIST_SOURCE) == "string" and #_G.BT_TOOL_LIST_SOURCE > 100 then
		return _G.BT_TOOL_LIST_SOURCE
	end
	local ok, mod = pcall(function()
		if _G.BT_LAUNCHER_LOAD then
			return _G.BT_LAUNCHER_LOAD("Launcher/BT_ToolListSource.lua")
		end
		return nil
	end)
	if ok and type(mod) == "string" and #mod > 100 then
		_G.BT_TOOL_LIST_SOURCE = mod
		return mod
	end
	return nil
end

local function patchToolsRuntime(path: string, source: string): string
	if not path:find("^Tools/", 1, true) or path:find("Libraries/", 1, true) then
		return source
	end

	if source:find("\nfunction ShowUI%(", 1, true) and not source:find("\nlocal function ShowUI%(", 1, true) then
		source = source:gsub("\nfunction ShowUI%(", "\nlocal function ShowUI(")
	end
	if source:find("\nfunction HideUI%(", 1, true) and not source:find("\nlocal function HideUI%(", 1, true) then
		source = source:gsub("\nfunction HideUI%(", "\nlocal function HideUI(")
	end

	if path == "Tools/Weld.lua" and source:find("if UI then", 1, true) and not source:find("WeldTool%.UI", 1, true) then
		source = source:gsub("if UI then", "if WeldTool.UI then")
		source = source:gsub("if not UI then", "if not WeldTool.UI then")
		source = source:gsub("UI = Core%.Tool%.Interfaces%.BTWeldToolGUI", "WeldTool.UI = Core.Tool.Interfaces.BTWeldToolGUI")
		source = source:gsub("UI%.Parent = Core%.UI", "WeldTool.UI.Parent = Core.UI")
		source = source:gsub("UI%.Visible", "WeldTool.UI.Visible")
		source = source:gsub("UI%.Interface", "WeldTool.UI.Interface")
		source = source:gsub("UI:WaitForChild", "WeldTool.UI:WaitForChild")
		source = source:gsub("UI%.Changes", "WeldTool.UI.Changes")
	end

	if path == "Tools/Anchor.lua" and source:find("if UI then", 1, true) and not source:find("AnchorTool%.UI", 1, true) then
		source = source:gsub("if UI then", "if AnchorTool.UI then")
		source = source:gsub("if not UI then", "if not AnchorTool.UI then")
		source = source:gsub("UI = Core%.Tool%.Interfaces%.BTAnchorToolGUI", "AnchorTool.UI = Core.Tool.Interfaces.BTAnchorToolGUI")
		source = source:gsub("UI%.Parent = Core%.UI", "AnchorTool.UI.Parent = Core.UI")
		source = source:gsub("UI%.Visible", "AnchorTool.UI.Visible")
		source = source:gsub("UI%.Status", "AnchorTool.UI.Status")
		source = source:gsub("UI:WaitForChild", "AnchorTool.UI:WaitForChild")
	end

	if path == "Tools/Collision.lua" and source:find("if UI then", 1, true) and not source:find("CollisionTool%.UI", 1, true) then
		source = source:gsub("if UI then", "if CollisionTool.UI then")
		source = source:gsub("if not UI then", "if not CollisionTool.UI then")
		source = source:gsub("UI = Core%.Tool%.Interfaces%.BTCollisionToolGUI", "CollisionTool.UI = Core.Tool.Interfaces.BTCollisionToolGUI")
		source = source:gsub("UI%.Parent = Core%.UI", "CollisionTool.UI.Parent = Core.UI")
		source = source:gsub("UI%.Visible", "CollisionTool.UI.Visible")
		source = source:gsub("UI%.Status", "CollisionTool.UI.Status")
		source = source:gsub("UI:WaitForChild", "CollisionTool.UI:WaitForChild")
	end

	if path == "Tools/Lighting.lua" then
		source = source:gsub("local UI = Tool:WaitForChild%('UI'%)", "local UITree = Tool:WaitForChild('UI')")
		source = source:gsub("require%(UI:", "require(UITree:")
		if not source:find("assets%.CheckedCheckbox", 1, true) then
			source = source:gsub(
				"ShadowsCheckbox%.Image = Core%.Assets%.CheckedCheckbox;",
				"ShadowsCheckbox.Image = (Core.Assets and Core.Assets.CheckedCheckbox) or 'rbxassetid://401518893';"
			)
			source = source:gsub(
				"ShadowsCheckbox%.Image = Core%.Assets%.UncheckedCheckbox;",
				"ShadowsCheckbox.Image = (Core.Assets and Core.Assets.UncheckedCheckbox) or 'rbxassetid://401518903';"
			)
			source = source:gsub(
				"ShadowsCheckbox%.Image = Core%.Assets%.SemicheckedCheckbox;",
				"ShadowsCheckbox.Image = (Core.Assets and Core.Assets.SemicheckedCheckbox) or 'rbxassetid://404298168';"
			)
		end
	end

	if path == "Tools/Move/UIController.lua" and not source:find("function getSelectionParts", 1, true) then
		source = source:gsub(
			"(%-%- Create class\r?\nlocal UIController = %{%})",
			[[local function getSelectionParts()
	if Selection and type(Selection.Parts) == "table" then
		return Selection.Parts
	end
	return {}
end

%1]]
		)
		source = source:gsub("#Selection%.Parts", "#getSelectionParts()")
		source = source:gsub("pairs%(Selection%.Parts%)", "pairs(getSelectionParts())")
	end

	return source
end

local function patchRemoteSource(path: string, source: string): string
	if path == "UI/Dock/ToolList.lua" then
		local embedded = getEmbeddedToolListSource()
		if embedded then
			source = embedded
		end
	end

	source = patchToolsRuntime(path, source)

	if path:find("RobloxRenderer.lua", 1, true) then
		source = source:gsub(
			"function RobloxRenderer%.isHostObject%(target%)\n\treturn typeof%(target%) == \"Instance\"\nend",
			[[function RobloxRenderer.isHostObject(target)
	if target == nil then
		return false
	end
	if typeof(target) == "Instance" then
		return true
	end
	local ok = pcall(function()
		return target.ClassName
	end)
	return ok
end]]
		)
		source = source:gsub(
			"return typeof%(target%) == \"Instance\"",
			"return RobloxRenderer.isHostObject(target)"
		)
	end

	if path:find("createReconciler.lua", 1, true) then
		source = source:gsub(
			'assert%(renderer%.isHostObject%(targetHostParent%), "Expected target to be host object"%)',
			"if not renderer.isHostObject(targetHostParent) then return end"
		)
	end

	if path:find("Dock/AboutPane.lua", 1, true) then
		source = source:gsub("new%(Roact%.Portal,", "false and new(Roact.Portal,")
	end

	if path == "Support/ReplicationListener.client.lua" then
		source = [[
local Indicator = script.Parent
Indicator.Value = true
]]
	end

	if path == "Support/DescendantCounter.local.client.lua" then
		source = [[
local Count = script.Parent
local Tool = Count.Parent.Parent
Count.Value = #Tool:GetDescendants()
]]
	end

	if path == "UI/Notifications/init.lua" then
		-- [=[ ]=] вместо [[ ]]: иначе `return Notifications]]` рвёт парсер RemoteLoader.lua
		source = [=[local Root = script:FindFirstAncestorWhichIsA('Tool')
local Vendor = Root:WaitForChild('Vendor')
local Roact = require(Vendor:WaitForChild('Roact'))
local new = Roact.createElement

local Notifications = Roact.PureComponent:extend(script.Name)

function Notifications:init()
	self:setState({
		ShouldWarnAboutHttpService = false;
		ShouldWarnAboutUpdate = false;
	})
end

function Notifications:render()
	return new('ScreenGui', {
		Enabled = true;
	}, {})
end

return Notifications]=]
	end

	if path == "Core/BoundingBox.lua" then
		if not source:find("safeDestroyBox", 1, true) then
			source = source:gsub(
				"(local PotentialPartMonitors = %{%};)\n",
				[[%1

local function safeDestroyBox(box)
	if box == nil then
		return
	end
	if typeof(box) == "Instance" then
		box:Destroy()
	end
end
]]
			)
			source = source:gsub("BoundingBox:Destroy%(%);", "safeDestroyBox(BoundingBox);")
			source = source:gsub("InactiveBoundingBox:Destroy%(%);", "safeDestroyBox(InactiveBoundingBox);")
		end
	end

	if path == "UI/Dock/init.lua" then
		source = source:gsub(
			"Roact%.PureComponent:extend%(script%.Name%)",
			"Roact.Component:extend(script.Name)"
		)
	end

	if path == "UI/Dock/ToolList.lua" then
		source = source:gsub(
			"Roact%.PureComponent:extend%(script%.Name%)",
			"Roact.Component:extend(script.Name)"
		)
		source = source:gsub(
			"toolChanged:Connect%(function %(Tool%)",
			"toolChanged:Connect(function (BuildingToolModule)"
		)
		source = source:gsub(
			"CurrentTool = Tool;",
			"CurrentTool = BuildingToolModule;"
		)
		if not source:find("local tools = self%.props%.Tools", 1, true) then
			source = source:gsub(
				"(%-%- Build buttons for each tool)\n",
				[[%1
    local tools = self.props.Tools
    if type(tools) ~= 'table' then
        tools = {}
    end
]]
			)
			source = source:gsub(
				"for ToolIndex, ToolInfo in ipairs%(self%.props%.Tools%)",
				"for ToolIndex, ToolInfo in ipairs(tools)"
			)
		end
		if source:find("}, Children%)", 1, true) and not source:find("frameChildren", 1, true) then
			source = source:gsub(
				"(%s*%-%- Build buttons for each tool\r?\n%s*for ToolIndex, ToolInfo in ipairs%(self%.props%.Tools%) do[^\n]+\n[^\n]+\n[^\n]+\n[^\n]+\n[^\n]+\n[^\n]+\n[^\n]+\n%s*end)\r?\n\r?\n%s*return new%('Frame',",
				[[%1

    local frameChildren = {
        Corners = new('UICorner', {
            CornerRadius = UDim.new(0, 3);
        });
        SizeConstraint = new('UISizeConstraint', {
            MinSize = Vector2.new(70, 0);
        });
        Layout = Children.Layout;
    }
    for key, element in Children do
        if key ~= 'Layout' then
            frameChildren[key] = element
        end
    end

    return new('Frame',]]
			)
			source = source:gsub(
				"return UDim2%.fromOffset%(CanvasSize%.X%.Offset, %(35%) %* 7%)",
				"return UDim2.fromOffset(math.max(70, CanvasSize.X.Offset), math.max(35, CanvasSize.Y.Offset))"
			)
			source = source:gsub(
				"Layout = Children%.Layout;\r?\n%s*}, Children%)",
				"}, frameChildren)"
			)
		end
		if not source:find("UDim2%.fromOffset%(70, math%.max%(245", 1, true) then
			source = source:gsub(
				"Size = self%.CanvasSize:map%b(function %[^(]*%([^)]*%).-end%);",
				"Size = UDim2.fromOffset(70, math.max(245, 35 * math.ceil(#tools / 2)));"
			)
		end
	end

	if path == "Core/BoundingBox.lua" then
		if not source:find("if BoundingBoxHandleCallback then", 1, true) then
			source = source:gsub(
				"BoundingBoxHandleCallback%(nil%);",
				"if BoundingBoxHandleCallback then BoundingBoxHandleCallback(nil); end"
			)
		end
		if not source:find("Core.Make недоступен", 1, true) then
			source = source:gsub(
				"(local Core = require%(script%.Parent%);)\n",
				[[%1
local Tool = (_G.__bt_tool or Core.Tool)
if Tool and type(Core.Make) ~= 'function' then
	Core.Make = require(Tool.Libraries:WaitForChild('Make'))
end
if type(Core.Support) ~= 'table' and Tool then
	Core.Support = require(Tool.Libraries:WaitForChild('SupportLibrary'))
end
local Support = Core.Support
]]
			)
			source = source:gsub(
				"BoundingBox = Core%.Make 'Part' %{",
				[[local make = Core.Make
	if type(make) ~= 'function' and Tool then
		make = require(Tool.Libraries:WaitForChild('Make'))
	end
	if type(make) ~= 'function' then
		warn('[BT] BoundingBox: Core.Make недоступен')
		return
	end
			BoxPart = make 'Part' {]]
			)
		end
		if not source:find("local BoxPart", 1, true) and source:find("BoundingBox = make", 1, true) then
			source = source:gsub(
				"(local PotentialPartMonitors = %{%};)\n",
				[[%1
local BoxPart
local InactiveBoxPart
]]
			)
			source = source:gsub("BoundingBox = make 'Part'", "BoxPart = make 'Part'")
			source = source:gsub("InactiveBoundingBox", "InactiveBoxPart")
			source = source:gsub("elseif BoundingBox and", "elseif BoxPart and")
			source = source:gsub("if BoundingBox then", "if BoxPart then")
			source = source:gsub("BoundingBox = InactiveBoxPart", "BoxPart = InactiveBoxPart")
			source = source:gsub("InactiveBoxPart = BoundingBox", "InactiveBoxPart = BoxPart")
			source = source:gsub("BoundingBox = InactiveBoxPart", "BoxPart = InactiveBoxPart")
			source = source:gsub("BoundingBox = nil", "BoxPart = nil")
			source = source:gsub("BoundingBox%.Size", "BoxPart.Size")
			source = source:gsub("BoundingBox%.CFrame", "BoxPart.CFrame")
			source = source:gsub("BoundingBoxHandleCallback%(BoundingBox%)", "BoundingBoxHandleCallback(BoxPart)")
			source = source:gsub("return BoundingBox;", "return BoxPart;")
			source = source:gsub("safeDestroyBox%(BoundingBox%)", "safeDestroyBox(BoxPart)")
		end
		if not source:find("Core%.Mouse and typeof", 1, true) then
			source = source:gsub(
				"Core%.Mouse%.TargetFilter = BoundingBox;",
				"if Core.Mouse and typeof(Core.Mouse) == 'Instance' then Core.Mouse.TargetFilter = BoxPart; end"
			)
			source = source:gsub(
				"Core%.Mouse%.TargetFilter = BoxPart;",
				"if Core.Mouse and typeof(Core.Mouse) == 'Instance' then Core.Mouse.TargetFilter = BoxPart; end"
			)
		end
		if not source:find("type%(BoundingBoxUpdater%.Stop%)", 1, true) then
			source = source:gsub(
				"if BoundingBoxUpdater then\r?\n\t\tBoundingBoxUpdater:Stop%(%);",
				"if BoundingBoxUpdater then\n\t\tif type(BoundingBoxUpdater.Stop) == 'function' then BoundingBoxUpdater:Stop(); end"
			)
		end
		if not source:find("type%(StopAggregatingStaticParts%)", 1, true) then
			source = source:gsub(
				"(%-%- Stop tracking static parts\r?\n\t)StopAggregatingStaticParts%(%);",
				"%1if type(StopAggregatingStaticParts) == 'function' then StopAggregatingStaticParts(); end"
			)
		end
		source = source:gsub(
			"BoundingBoxHandleCallback%(BoundingBox%);",
			"if BoundingBoxHandleCallback then BoundingBoxHandleCallback(BoundingBox); end"
		)
		source = source:gsub(
			"BoundingBoxHandleCallback%(BoxPart%);",
			"if BoundingBoxHandleCallback then BoundingBoxHandleCallback(BoxPart); end"
		)
		if not source:find("getSelectionParts", 1, true) then
			source = source:gsub(
				"(local function safeDestroyBox)",
				[[local function getSelectionParts()
	if Core.Selection and type(Core.Selection.Parts) == "table" then
		return Core.Selection.Parts
	end
	return {}
end

%1]]
			)
			source = source:gsub("#Core%.Selection%.Parts", "#getSelectionParts()")
			source = source:gsub("ipairs%(Core%.Selection%.Parts%)", "ipairs(getSelectionParts())")
			source = source:gsub("AddStaticParts%(Core%.Selection%.Parts%)", "AddStaticParts(getSelectionParts())")
			source = source:gsub(
				"CalculateExtents%(Core%.Selection%.Parts,",
				"CalculateExtents(getSelectionParts(),"
			)
			source = source:gsub(
				"(function StartAggregatingStaticParts%(%)\r?\n\t%-%- Begins)",
				[[function StartAggregatingStaticParts()
	if not Core.Selection then
		return
	end
	-- Begins]]
			)
		end
	end

	if path == "UI/Dock/ToolButton.lua" then
		if not source:find("ResolveBuildingToolModule", 1, true) then
			source = source:gsub(
				"core%.EquipTool%(self%.props%.Tool%)",
				[[local toolModule = self.props.Tool
                if type(core.ResolveBuildingToolModule) == "function" then
                    toolModule = core.ResolveBuildingToolModule(toolModule)
                end
                core.EquipTool(toolModule)]]
			)
		end
	end

	if path == "Core/Targeting.lua" then
		source = source:gsub(
			"if not GetCore%(%).IsSelectable%(%{ Target %}%) then",
			"if not (GetCore() and type(GetCore().IsSelectable) == 'function' and GetCore().IsSelectable({ Target })) then"
		)
		source = source:gsub(
			"local Core = GetCore%(%);\n\tlocal Connections = Core%.Connections;",
			"local Core = GetCore();\n\tif not Core.Connections then\n\t\tCore.Connections = {};\n\tend\n\tlocal Connections = Core.Connections;"
		)
		source = source:gsub(
			"if not Core%.IsSelectable%({ NewTarget }%) then",
			"if (not Core) or type(Core.IsSelectable) ~= 'function' or not Core.IsSelectable({ NewTarget }) then"
		)
		source = source:gsub(
			"if not Core%.Selection%.IsSelected%(NewScopeTarget%) then",
			"if Core.Selection and type(Core.Selection.IsSelected) == 'function' and not Core.Selection.IsSelected(NewScopeTarget) then"
		)
	end

	if path == "Core/init.lua" then
		source = source:gsub(
			"if UI then\r?\n\t\treturn;",
			"if Core.UI then\n\t\treturn;"
		)
		if not source:find("Player:GetMouse%(", 1, true) then
			source = source:gsub(
				"(%-%- Update the core mouse\r?\n\t)getfenv%(0%)%.Mouse = Mouse;",
				[[%1if Mouse == nil or typeof(Mouse) ~= "Instance" then
		Mouse = Player:GetMouse()
	end
	Core.Mouse = Mouse
	getfenv(0).Mouse = Mouse;]]
			)
		end
		if not source:find("RefreshToolDock%(%)\r?\n\tend", 1, true) then
			source = source:gsub(
				"(UI%.Parent = UIContainer;)\r?\n",
				"%1\n\tUI.Enabled = true;\n\tif type(Core.RefreshToolDock) == 'function' then\n\t\tCore.RefreshToolDock()\n\tend\n",
				1
			)
		end
		source = source:gsub(
			"Tool%.Equipped:Connect%(Enable%);",
			"Tool.Equipped:Connect(function()\n\t\tEnable(Player:GetMouse())\n\tend);"
		)
		if not source:find("Core.__bt_Roact", 1, true) then
			source = source:gsub(
				"(local Cryo = require%(Tool%.Libraries:WaitForChild%('Cryo'%)%)\n)",
				"%1Core.__bt_Roact = Roact\nCore.__bt_Cryo = Cryo\n"
			)
		end
		source = applyCoreEquipSafetyPatches(source)
		if not source:find("__bt_equip_guard", 1, true) then
			source = source:gsub(
				"function EquipTool%(BuildingToolModule%)\r?\n\t%-%- Equips[^\n]*\n",
				[[function EquipTool(BuildingToolModule)
	-- Equips and switches to the given tool
	if type(BuildingToolModule) ~= "table" or type(BuildingToolModule.Equip) ~= "function" then
		if type(_G.Core) == "table" and type(_G.Core.__bt_defaultMove) == "table" and type(_G.Core.__bt_defaultMove.Equip) == "function" then
			BuildingToolModule = _G.Core.__bt_defaultMove
		else
			local rbxTool = _G.__bt_tool or Tool
			local tools = rbxTool and rbxTool:FindFirstChild("Tools")
			local moveInst = tools and tools:FindFirstChild("Move")
			if moveInst and moveInst:IsA("ModuleScript") then
				local ok, mod = pcall(require, moveInst)
				if ok and type(mod) == "table" and type(mod.Equip) == "function" then
					BuildingToolModule = mod
					if type(_G.Core) == "table" then
						_G.Core.__bt_defaultMove = mod
					end
				end
			end
		end
	end
	if type(BuildingToolModule) ~= "table" or type(BuildingToolModule.Equip) ~= "function" then
		warn("[BT] EquipTool: нет валидного модуля инструмента")
		return
	end
]]
			)
			source = source:gsub(
				"BuildingToolModule:Equip%(%);",
				[[local __bt_equipOk, __bt_equipErr = pcall(function()
		BuildingToolModule:Equip()
	end)
	if not __bt_equipOk then
		warn("[BT] Equip failed:", __bt_equipErr)
	end]]
			)
			source = source:gsub(
				"EquipTool%(ResolveBuildingToolModule%(CurrentTool%) or DefaultBuildingToolModule%(%)%)",
				[[EquipTool((type(Core) == "table" and IsBuildingToolModule(Core.__bt_defaultMove) and Core.__bt_defaultMove)
		or ResolveBuildingToolModule(CurrentTool)
		or DefaultBuildingToolModule())]]
			)
		end
		source = source:gsub("SyncAPI = Tool%.SyncAPI;", "SyncAPI = Tool.SyncAPI;\nCore.SyncAPI = SyncAPI;", 1)
		source = patchCoreSelfReference(source)
		source = patchCoreInitRequires(source)
		source = patchCoreModuleExports(source)
		source = patchCoreUiExports(source)
		source = patchCoreLateExports(source)
		source = patchCoreToolParamShadowing(source)
		source = source:gsub(
			"function RecolorHandle%(Color%)\n\tSyncAPI:Invoke%('RecolorHandle', Color%);\nend;",
			[[function RecolorHandle(Color)
	local target = Color
	if typeof(target) == "BrickColor" then
		target = target.Color
	end
	if typeof(target) ~= "Color3" then
		return
	end
	local rbxTool = (_G.__bt_tool or Tool)
	local handle = rbxTool and rbxTool:FindFirstChild("Handle")
	if handle and handle:IsA("BasePart") then
		handle.Color = target
	end
end;]]
		)
		-- UI должна показываться только когда Tool действительно в руках персонажа.
		source = source:gsub(
			"UI%.Parent = UIContainer;",
			"if Mode ~= 'Tool' or (Player.Character and Tool.Parent == Player.Character) then\n\t\tUI.Parent = UIContainer;\n\t\tUI.Enabled = true;\n\tend;"
		)
		source = source:gsub("UI%.Parent = script;", "UI.Parent = nil; UI.Enabled = false;")
		source = source:gsub(
			"if not Core%.StartupNotificationsDisplayed then[%s%S]-Core%.StartupNotificationsDisplayed = true\n\tend;",
			"if not Core.StartupNotificationsDisplayed then\n\t\tCore.StartupNotificationsDisplayed = true\n\tend;"
		)
		source = source:gsub(
			"Targeting:EnableTargeting%(%)\n\tSelection%.EnableOutlines%(%);",
			"pcall(function()\n\t\tTargeting:EnableTargeting();\n\tend)\n\tSelection.EnableOutlines();"
		)
		source = source:gsub(
			"while not UI do\n\t\twait%(0%.1%);",
			"for __bt_ui = 1, 300 do\n\t\tif UI then break end\n\t\ttask.wait(0.05);"
		)
		source = source:gsub(
			"while not Indicator%.Value do\r?\n\tIndicator%.Changed:Wait%(%);\r?\nend;",
			"if not Indicator.Value then Indicator.Value = true end"
		)
		source = source:gsub(
			"Connections = {};",
			"Connections = {};\nCore.Connections = Connections;",
			1
		)
		source = source:gsub(
			"Tools = ToolList;",
			"Tools = ToolList;\n\t\tUIRoot = UI;",
			1
		)
		-- В паттерне gsub нельзя %}: иначе "invalid pattern capture"
		source = source:gsub(
			"Tools = Cryo%.List%.join%(ToolList%);(%s*\n\t\t})",
			"Tools = Cryo.List.join(ToolList);\n\t\t\tUIRoot = UI;%1"
		)
		if not source:find("Core.__bt_ToolList", 1, true) then
			source = source:gsub(
				"local DockHandle = Roact%.mount%(DockElement, UI, 'Dock'%)",
				[[local DockHandle = Roact.mount(DockElement, UI, 'Dock')
	Core.__bt_ToolList = ToolList
	Core.__bt_DockHandle = DockHandle
	Core.__bt_DockComponent = DockComponent
	Core.__bt_UI = UI]]
			)
		end
		if not source:find("function Core.RefreshToolDock", 1, true) then
			source = source:gsub(
				"Core%.AddToolButton = AddToolButton\n",
				"Core.AddToolButton = AddToolButton\n\tfunction Core.RefreshToolDock()\n\t\tif DockHandle and ToolList then\n\t\t\tRoact.update(DockHandle, Roact.createElement(DockComponent, {\n\t\t\t\tCore = Core;\n\t\t\t\tTools = Cryo.List.join(ToolList);\n\t\t\t\tUIRoot = UI;\n\t\t\t}))\n\t\tend\n\tend\n"
			)
		end
		source = patchCoreReturn(source)
		source = source:gsub(
			"(Core%.UI = UI\n)",
			"%1\tUI.Parent = nil;\n\tUI.Enabled = false;\n"
		)
		-- r82: «Tool = Tool» в AddToolButton мог стать Roblox Tool
		source = source:gsub(
			"local function AddToolButton%(IconAssetId, HotkeyLabel, Tool%)\r?\n\t\t?table%.insert%(ToolList, %{\r?\n\t\t\tIconAssetId = IconAssetId;\r?\n\t\t\tHotkeyLabel = HotkeyLabel;\r?\n\t\t\tTool = %(_G%.__bt_tool or Tool%);",
			[[local function AddToolButton(IconAssetId, HotkeyLabel, ToolModule)
		table.insert(ToolList, {
			IconAssetId = IconAssetId;
			HotkeyLabel = HotkeyLabel;
			Tool = ToolModule;]]
		)
		if not source:find("IsBuildingToolModule", 1, true) then
			source = source:gsub(
				"(function ResolveBuildingToolModule%(BuildingToolModule%)\r?\n)(.-)(\r?\nend\r?\n\r?\nfunction EquipTool)",
				CORE_RESOLVE_TOOL_BLOCK .. "\n\nfunction EquipTool",
				1
			)
			source = source:gsub(
				"function EquipTool%(BuildingToolModule%)\r?\n\t%-%- Equips[^\n]*\r?\n\tBuildingToolModule = ResolveBuildingToolModule%(BuildingToolModule%)",
				[[function EquipTool(BuildingToolModule)
	-- Equips and switches to the given tool
	BuildingToolModule = ResolveBuildingToolModule(BuildingToolModule)
	if not IsBuildingToolModule(BuildingToolModule) then
		BuildingToolModule = DefaultBuildingToolModule()
	end
	if not IsBuildingToolModule(BuildingToolModule) then
		warn("[BT] EquipTool: не удалось загрузить Move")
		return
	end]]
			)
			source = source:gsub(
				"if activeTool%.Equipped then",
				"if IsBuildingToolModule(activeTool) and activeTool.Equipped then"
			)
			source = source:gsub(
				"EquipTool%(ResolveBuildingToolModule%(CurrentTool%) or require%(Tool%.Tools%.Move%)%)",
				"EquipTool(ResolveBuildingToolModule(CurrentTool) or DefaultBuildingToolModule())"
			)
			source = source:gsub(
				"if CurrentTool then\r?\n\t\tlocal activeTool = ResolveBuildingToolModule%(CurrentTool%)\r?\n\t\tactiveTool:Unequip%(%);",
				[[if CurrentTool then
		local activeTool = ResolveBuildingToolModule(CurrentTool)
		if IsBuildingToolModule(activeTool) then
			activeTool:Unequip();]]
			)
		end
		if not source:find("Core.Security = Security", 1, true) then
			source = source:gsub(
				"(Security = require%(script%.Security%)\n)",
				"%1Core.Security = Security\n"
			)
			source = source:gsub(
				"(Security = require%(Tool:WaitForChild%('Core'%):WaitForChild%('Security')%)\n)",
				"%1Core.Security = Security\n"
			)
			source = source:gsub(
				"(History = require%(script%.History%)\n)",
				"%1Core.History = History\n"
			)
			source = source:gsub(
				"(History = require%(Tool:WaitForChild%('Core'%):WaitForChild%('History')%)\n)",
				"%1Core.History = History\n"
			)
			source = source:gsub(
				"(Selection = require%(script%.Selection%)\n)",
				"%1Core.Selection = Selection\n"
			)
			source = source:gsub(
				"(Selection = require%(Tool:WaitForChild%('Core'%):WaitForChild%('Selection')%)\n)",
				"%1Core.Selection = Selection\n"
			)
			source = source:gsub(
				"(Targeting = require%(script%.Targeting%)\n)",
				"%1Core.Targeting = Targeting\n"
			)
			source = source:gsub(
				"(Targeting = require%(Tool:WaitForChild%('Core'%):WaitForChild%('Targeting')%)\n)",
				"%1Core.Targeting = Targeting\n"
			)
			source = source:gsub(
				"(local BoundingBoxModule = require%(script:WaitForChild%('BoundingBox')%)\n)",
				"%1Core.BoundingBox = BoundingBoxModule\n"
			)
			source = source:gsub(
				"(local BoundingBoxModule = require%(__bt_script:WaitForChild%('BoundingBox')%)\n)",
				"%1Core.BoundingBox = BoundingBoxModule\n"
			)
		end
	end

	if path == "Loader/init.lua" then
		-- Локальный Loader/init.lua уже с _G.Core и registerTool — не переписываем
	end

	if path == "Tools/Move/FreeDragging.lua" then
		source = source:gsub(
			"if not Core%.IsSelectable%(%{ TargetPart %}%) and not IsSnapping then",
			"if not (type(Core.IsSelectable) == 'function' and Core.IsSelectable({ TargetPart })) and not IsSnapping then"
		)
		if not source:find("typeof%(Core%.Mouse%)", 1, true) then
			source = source:gsub(
				"(%-%- Get mouse target\r?\n\t\t)local TargetPart = Core%.Mouse%.Target",
				[[if not Core.Mouse or typeof(Core.Mouse) ~= 'Instance' then
			return Enum.ContextActionResult.Pass
		end

		-- Get mouse target
		local TargetPart = Core.Mouse.Target]]
			)
		end
	end

	if path:find("^Tools/", 1, true) or path == "Core/Snapping.lua" then
		source = source:gsub(
			"Core%.Tool%.Interfaces%.([%w_]+)",
			"(Core.Tool or Tool):WaitForChild('Interfaces'):WaitForChild('%1')"
		)
		source = source:gsub(
			"Core%.Tool%.Core%.([%w_]+)",
			function(child)
				return CORE_BT .. ":WaitForChild('" .. child .. "')"
			end
		)
	end

	if path == "Tools/Move/UIController.lua" then
		source = source:gsub(
			"self%.UI = Core%.Tool%.Interfaces%.BTMoveToolGUI:Clone%(%)",
			"self.UI = (Core.Tool or Tool):WaitForChild('Interfaces'):WaitForChild('BTMoveToolGUI'):Clone()"
		)
	end

	if path == "Launcher/Interfaces/lol.lua" then
		-- Не использовать game.Workspace: только папка Tool.Interfaces
		source = source:gsub(
			"local workspace = %(_G%.__bt_interfaces_root or %(script and script%.Parent%) or workspace%)",
			"local workspace = (_G.__bt_interfaces_root or (script and script.Parent))"
		)
		source = source:gsub(
			"local workspace = script%.Parent",
			"local workspace = (_G.__bt_interfaces_root or (script and script.Parent))"
		)
		source = source:gsub(
			"%.Parent = workspace",
			".Parent = _G.__bt_interfaces_root"
		)
	end

	source = patchCoreAndToolRequires(path, source)

	return source
end

local function isLikelyLuaSource(body: string): boolean
	body = normalizeBody(body)
	if #body < 4 then
		return false
	end
	local head = body:sub(1, 200):lower()
	-- Отклоняем только явные HTTP/HTML (остальное — Lua: Assets={}, --, local…)
	if head:match("^%s*404") or head:match("^%s*403") then
		return false
	end
	if head:find("<!doctype", 1, true) or head:match("^%s*<html") or head:match("^%s*<body") then
		return false
	end
	if head:find("too many requests", 1, true) and #body < 250 then
		return false
	end
	return true
end

local function getJsDelivrUrl(path: string): string?
	local user, repo, branch = RemoteLoader.BaseUrl:match(
		"raw%.githubusercontent%.com/([^/]+)/([^/]+)/refs/heads/([^/]+)/"
	)
	if not user then
		return nil
	end
	return `https://cdn.jsdelivr.net/gh/{user}/{repo}@{branch}/{path}`
end

local function getFetchUrls(path: string): { string }
	local urls: { string } = {}
	local seen: { [string]: boolean } = {}

	local function add(url: string)
		if not seen[url] then
			seen[url] = true
			table.insert(urls, url)
		end
	end

	local repoUrl = RemoteLoader.BaseUrl .. path
	local isInit = path:sub(-#"init.lua") == "init.lua"

	for _, entry in vendorPrefixes do
		if path:sub(1, #entry.prefix) ~= entry.prefix then
			continue
		end
		local vendorUrl = entry.base .. path:sub(#entry.prefix + 1)

		-- Vendor/Roact — submodule, в GitHub пусто → только Roblox/roact
		if entry.prefix == "Vendor/Roact/" then
			add(vendorUrl)
			return urls
		end

		add(vendorUrl)
		add(repoUrl)
		return urls
	end

	local mirror = getJsDelivrUrl(path)
	if mirror then
		add(mirror)
	end
	add(repoUrl)
	if not isInit then
		for _, entry in vendorPrefixes do
			if path:sub(1, #entry.prefix) == entry.prefix then
				add(entry.base .. path:sub(#entry.prefix + 1))
			end
		end
	end
	return urls
end

function RemoteLoader.configure(baseUrl: string, vendorUrls: { [string]: string }?)
	RemoteLoader.BaseUrl = normalizeBase(baseUrl)
	table.clear(vendorPrefixes)
	if vendorUrls then
		local sorted: { string } = {}
		for prefix in vendorUrls do
			table.insert(sorted, prefix)
		end
		table.sort(sorted, function(a, b)
			return #a > #b
		end)
		for _, prefix in sorted do
			table.insert(vendorPrefixes, {
				prefix = prefix,
				base = normalizeBase(vendorUrls[prefix]),
			})
		end
	end
	RemoteLoader.httpGet = _G.BT_HTTP_GET or defaultHttpGet
	RemoteLoader.compile = _G.BT_LAUNCHER_COMPILE or defaultCompile
	loadCancelled = false
end

function RemoteLoader.resetCancel()
	loadCancelled = false
end

function RemoteLoader.setProgressCallback(cb: ((string, boolean, string?) -> ())?)
	progressCallback = cb
end

function RemoteLoader.hasSource(path: string): boolean
	return sourceCache[path] ~= nil
end

function RemoteLoader.getSource(path: string): string?
	return sourceCache[path]
end

function RemoteLoader.getFailed(): { [string]: string }
	return failedPaths
end

function RemoteLoader.setContinueOnError(value: boolean)
	continueOnError = value
end

function RemoteLoader.getRuntimeErrors(): { string }
	return runtimeErrors
end

function RemoteLoader.requestCancel()
	loadCancelled = true
end

function RemoteLoader.isLoadCancelled(): boolean
	return loadCancelled
end

local function recordRunError(path: string, err: string)
	local msg = tostring(err)
	failedPaths[path] = msg
	table.insert(runtimeErrors, `run {path}: {msg}`)
	if progressCallback then
		progressCallback(path, false, msg)
	end
end

local function makeStubModule(modulePath: string): any
	return setmetatable({}, {
		__index = function(_self, key)
			local stub = function()
				warn(`[BT] пропуск {modulePath}.{key} — модуль не загружен`)
			end
			return stub
		end,
	})
end

function RemoteLoader.getFetchCount(): number
	return fetchCount
end

function RemoteLoader.getCachedModule(path: string): any
	local cached = moduleCache[path]
	if cached == false then
		return nil
	end
	return cached
end

function RemoteLoader.registerModule(moduleScript: ModuleScript, path: string)
	registry[moduleScript] = path
	moduleScript:SetAttribute("BTPath", path)
end

function RemoteLoader.fetchSource(path: string): (boolean, string?)
	if loadCancelled then
		return false, "отменено"
	end
	if sourceCache[path] then
		return true, sourceCache[path]
	end

	local lastErr: string? = nil
	local tried: { string } = {}

	for _, url in getFetchUrls(path) do
		if loadCancelled then
			return false, "отменено"
		end
		table.insert(tried, url)
		for attempt = 1, MAX_RETRIES do
			if loadCancelled then
				return false, "отменено"
			end
			throttle()
			local ok, result = pcall(function()
				return RemoteLoader.httpGet(url)
			end)

			if ok and type(result) == "string" and #result > 0 then
				result = normalizeBody(result)
			end
			if ok and type(result) == "string" and #result > 0 and isLikelyLuaSource(result) then
				result = patchRemoteSource(path, result)
				sourceCache[path] = result
				failedPaths[path] = nil
				fetchCount += 1
				if progressCallback then
					progressCallback(path, true, nil)
				end
				return true, result
			else
				local preview = ""
				if ok and type(result) == "string" and #result > 0 then
					preview = result:sub(1, 48):gsub("%s+", " ")
				end
				lastErr = if ok and type(result) == "string" and #result > 0
					then `не Lua ({url}) [{preview}]`
					else if ok then "пустой ответ" else tostring(result)
			end

			if attempt < MAX_RETRIES then
				task.wait(0.2 * attempt)
			end
		end
	end

	failedPaths[path] = lastErr or (`HttpGet failed: {table.concat(tried, " | ")}`)
	if progressCallback then
		progressCallback(path, false, failedPaths[path])
	end
	return false, failedPaths[path]
end

function RemoteLoader.preloadRemaining(
	paths: { string },
	onProgress: ((number, number, string, boolean, string?) -> ())?
): { string }
	local hardFailures: { string } = {}
	local pending: { string } = {}
	for _, path in paths do
		if not sourceCache[path] then
			table.insert(pending, path)
		end
	end
	table.sort(pending, function(a, b)
		return #a < #b
	end)

	local total = #pending
	for index, path in pending do
		if loadCancelled then
			break
		end
		local ok, err = RemoteLoader.fetchSource(path)
		if onProgress then
			onProgress(index, total, path, ok, err)
		end
		if not ok then
			table.insert(hardFailures, path)
		end
		task.wait(0.02)
	end
	return hardFailures
end

function RemoteLoader.preloadByPrefixes(
	paths: { string },
	prefixes: { string },
	onProgress: ((number, number, string, boolean, string?) -> ())?
)
	local pending: { string } = {}
	for _, path in paths do
		for _, prefix in prefixes do
			if path:sub(1, #prefix) == prefix then
				table.insert(pending, path)
				break
			end
		end
	end
	table.sort(pending, function(a, b)
		return #a < #b
	end)

	local total = #pending
	for index, path in pending do
		if loadCancelled then
			break
		end
		local ok, err = RemoteLoader.fetchSource(path)
		if onProgress then
			onProgress(index, total, path, ok, err)
		end
		if not ok then
			error(`[BT] preload {path}: {err}`, 0)
		end
		task.wait(0.02)
	end
end

function RemoteLoader.preloadCritical(
	onProgress: ((number, number, string, boolean, string?) -> ())?
): { string }
	local hardFailures: { string } = {}
	local total = #CRITICAL_PATHS

	for index, path in CRITICAL_PATHS do
		if loadCancelled then
			break
		end
		local ok, err = RemoteLoader.fetchSource(path)
		if onProgress then
			onProgress(index, total, path, ok, err)
		end
		if not ok then
			table.insert(hardFailures, path)
			warn(`[BT] HttpGet: {path} — {err}`)
		end
	end

	return hardFailures
end

function RemoteLoader.assertCriticalLoaded()
	for _, path in CRITICAL_PATHS do
		if not RemoteLoader.hasSource(path) then
			error(`[BT] не загружен обязательный файл: {path}`, 0)
		end
	end
end

local function btToolParent(scriptInst: Instance?, toolInst: Tool?): Instance?
	if scriptInst ~= nil then
		local p = scriptInst.Parent
		if p ~= nil then
			return p
		end
		if toolInst ~= nil then
			local n = scriptInst.Name
			if n == "LocalEndpoint" then
				return toolInst:FindFirstChild("SyncAPI")
			end
			if n == "DescendantCounter" then
				local loaded = toolInst:FindFirstChild("Loaded")
				return if loaded then loaded:FindFirstChild("DescendantCount") else nil
			end
			if n == "ReplicationListener" then
				return toolInst:FindFirstChild("Loaded")
			end
		end
	end
	return toolInst
end

local WRAP_TOOL_PARENT_PREAMBLE = [[
local function __bt_tool_parent(__bt_script, __bt_tool)
	if __bt_script ~= nil then
		local p = __bt_script.Parent
		if p ~= nil then
			return p
		end
		if __bt_tool ~= nil then
			local n = __bt_script.Name
			if n == "LocalEndpoint" then
				return __bt_tool:FindFirstChild("SyncAPI")
			end
			if n == "DescendantCounter" then
				local loaded = __bt_tool:FindFirstChild("Loaded")
				return loaded and loaded:FindFirstChild("DescendantCount")
			end
			if n == "ReplicationListener" then
				return __bt_tool:FindFirstChild("Loaded")
			end
		end
	end
	return __bt_tool
end
]]

-- Без вызова __bt_tool_parent (в load-env executor часто nil) — только __bt_script/__bt_tool
local SCRIPT_PARENT_EXPR =
	"((function(__s,__t) if __s ~= nil then local __p = __s.Parent if __p ~= nil then return __p end if __t ~= nil then local __n = __s.Name if __n == \"LocalEndpoint\" then return __t:FindFirstChild(\"SyncAPI\") end if __n == \"DescendantCounter\" then local __ld = __t:FindFirstChild(\"Loaded\") return __ld and __ld:FindFirstChild(\"DescendantCount\") end if __n == \"ReplicationListener\" then return __t:FindFirstChild(\"Loaded\") end end end return __t end)(__bt_script,__bt_tool))"

-- Заменяем только идентификатор script, не поля вроде Core.script
local function rewriteScriptIdentifier(source: string, replacement: string): string
	source = source:gsub("([^%.%w_])script([%.:%(])", "%1" .. replacement .. "%2")
	source = source:gsub("^script([%.:%(])", replacement .. "%1")
	source = source:gsub("([^%.%w_])script(%f[%A])", "%1" .. replacement .. "%2")
	source = source:gsub("^script(%f[%A])", replacement .. "%1")
	return source
end

local function rewriteCommon(source: string, useBtRequire: boolean): string
	source = source:gsub("Tool%.Parent:IsA", "Tool.Parent and Tool.Parent:IsA")
	source = rewriteScriptIdentifier(source, "__bt_script")
	source = source:gsub("__bt_script%.Parent", SCRIPT_PARENT_EXPR)
	if useBtRequire then
		source = source:gsub("(%f[%a])require(%f[%A])", "__bt_require")
	end
	return source
end

local MODULE_ENV_PREAMBLE = "local require = (_G.__bt_require or __bt_require)\n"
	.. "local script = (_G.__bt_script or (typeof(script) == \"Instance\" and script) or __bt_script)\n"

local function ensureModulePreamble(source: string): string
	if source:find("local require = __bt_require", 1, true) then
		return source
	end
	return MODULE_ENV_PREAMBLE .. source
end

local TOOL_BIND = "_G.__bt_tool or Tool"

local function rewriteToolParentForRemote(path: string, source: string): string
	if path:sub(1, 6) == "Core/" and path ~= "Core/init.lua" then
		source = source:gsub("Tool = script%.Parent%.Parent", `Tool = {TOOL_BIND};`)
		source = source:gsub("Tool = __bt_script%.Parent%.Parent", `Tool = {TOOL_BIND};`)
	end
	if path == "Loader/init.lua" or path == "Core/init.lua" then
		source = source:gsub("Tool = script%.Parent;", `Tool = {TOOL_BIND};`)
		source = source:gsub("local Tool = script%.Parent;", `local Tool = {TOOL_BIND};`)
		source = source:gsub("local Tool = __bt_script%.Parent;", `local Tool = {TOOL_BIND};`)
		source = source:gsub("Tool = __bt_script%.Parent;", `Tool = {TOOL_BIND};`)
		-- Не трогать «Tool = Tool» в AddToolButton (иначе в док попадает Roblox Tool)
	end
	return source
end

local function stripModulePreamble(body: string): string
	body = body:gsub("^local require = [^\n]+\n", "", 1)
	body = body:gsub("^local script = [^\n]+\n", "", 1)
	return body
end

type BtGlobalSnapshot = { __bt_require: any, __bt_tool: any, __bt_script: any }

local function pinBtGlobals(btRequire: any, tool: Tool, scriptInstance: Instance?): BtGlobalSnapshot
	local snap: BtGlobalSnapshot = {
		__bt_require = _G.__bt_require,
		__bt_tool = _G.__bt_tool,
		__bt_script = _G.__bt_script,
	}
	_G.__bt_require = btRequire
	_G.__bt_tool = tool
	_G.__bt_script = scriptInstance
	return snap
end

local function unpinBtGlobals(snap: BtGlobalSnapshot)
	_G.__bt_require = snap.__bt_require
	_G.__bt_tool = snap.__bt_tool
	_G.__bt_script = snap.__bt_script
end

local function runWithPinnedGlobals<T...>(fn: () -> T..., btRequire: any, tool: Tool, scriptInstance: Instance?): (boolean, T...)
	local snap = pinBtGlobals(btRequire, tool, scriptInstance)
	local ok, result = pcall(fn)
	unpinBtGlobals(snap)
	return ok, result
end

local function rewriteCoreChildRequires(source: string): string
	return patchCoreInitRequires(source)
end

-- ModuleScript в custom env (присваивания → env / Core)
local function rewriteForModuleEnv(path: string, source: string): string
	source = rewriteToolParentForRemote(path, source)
	source = ensureModulePreamble(source)
	if path == "Core/init.lua" then
		source = source:gsub("^local script = [^\n]+\n", "local script = Tool:WaitForChild('Core')\n", 1)
	end
	-- require не заменяем на __bt_require: в теле должен быть require(), local require = … в preamble
	source = rewriteCommon(source, false)
	if path == "Core/init.lua" then
		source = rewriteCoreChildRequires(source)
	end
	source = rewriteToolParentForRemote(path, source)
	if path == "Core/init.lua" then
		source = source:gsub("local Core = getfenv%(0%)\r?\n?", `local Core = {CORE_SELF}\n`)
	else
		source = source:gsub("local Core = getfenv%(0%)\r?\n?", "")
	end
	source = source:gsub("getfenv%(%s*0%s*%)", "Core")
	if path == "Core/init.lua" then
		source = patchCoreSelfReference(source)
		source = patchCoreToolParamShadowing(source)
		source = applyCoreEquipSafetyPatches(source)
	end
	if path == "Core/Targeting.lua" or path == "Core/Selection.lua" then
		source = source:gsub("function GetCore%(%).-end;", BT_GET_CORE_BODY, 1)
	end
	return source
end

-- ModuleScript в env: дублирует rewriteForModuleEnv (оставлено для читаемости / fallback-имени)
local function rewriteForEnvWrap(path: string, source: string): string
	return rewriteForModuleEnv(path, source)
end

local function rewriteForLocalWrap(source: string): string
	source = rewriteCommon(source, true)
	source = source:gsub("local Core = getfenv%(0%)\r?\n?", "")
	source = source:gsub("getfenv%(%s*0%s*%)", "Core")
	source = source:gsub("(%f[%a])getfenv(%f[%A])", "__bt_getfenv")
	return source
end

local function wrapChunkSource(source: string): string
	local body = rewriteForLocalWrap(source)
	return "return function(__bt_script, __bt_tool, __bt_require)\n"
		.. WRAP_TOOL_PARENT_PREAMBLE
		.. "if __bt_script == nil and __bt_tool == nil then error('[BT] script и Tool nil', 0) end\n"
		.. "local Core = setmetatable({}, { __index = _G })\n"
		.. "_G.Core = Core\n"
		.. "local function __bt_getfenv(_level)\n"
		.. "\treturn Core\n"
		.. "end\n"
		.. "local require = __bt_require\n"
		.. "local script = __bt_script\n"
		.. "local Players = game:GetService(\"Players\")\n"
		.. "Game = game\n"
		.. "Tool = __bt_tool\n"
		.. "Core.script = __bt_script\n"
		.. "Core.Tool = __bt_tool\n"
		.. "Core.require = __bt_require\n"
		.. "Core.Players = Players\n"
		.. "Core.Player = Players.LocalPlayer\n"
		.. body
		.. "\nend"
end

local function buildModuleEnv(tool: Tool, scriptInstance: Instance?, btRequire: any): any
	local Players = game:GetService("Players")
	local env = {
		script = scriptInstance,
		__bt_script = scriptInstance,
		__bt_tool = tool,
		__bt_tool_parent = btToolParent,
		Core = nil :: any,
		Tool = tool,
		require = btRequire,
		__bt_require = btRequire,
		plugin = false,
		game = game,
		Game = game,
		Players = Players,
		Player = Players.LocalPlayer,
		Workspace = game:GetService("Workspace"),
		RunService = game:GetService("RunService"),
		HttpService = game:GetService("HttpService"),
		ReplicatedStorage = game:GetService("ReplicatedStorage"),
		UserInputService = game:GetService("UserInputService"),
		CollectionService = game:GetService("CollectionService"),
		Color3 = Color3,
		BrickColor = BrickColor,
		Enum = Enum,
	}
	env.Core = env
	env.Core.script = scriptInstance
	env.Core.Tool = tool
	return setmetatable(env, {
		__index = function(_t, k)
			local v = rawget(env, k)
			if v ~= nil then
				return v
			end
			return _G[k]
		end,
		__newindex = function(_t, k, v)
			rawset(env, k, v)
		end,
	})
end

local function buildRequire(tool: Tool)
	return function(target: any): any
		if target == nil then
			if type(_G.Core) == "table" then
				return _G.Core
			end
			error("[BT] require: nil (ожидался ModuleScript)", 2)
		end
		if type(target) ~= "userdata" or not target:IsA("ModuleScript") then
			local kind = if typeof(target) == "Instance" then target.ClassName else typeof(target)
			error(`[BT] require: ожидается ModuleScript, получен {kind} ({tostring(target)})`, 2)
		end
		local modulePath = registry[target] or target:GetAttribute("BTPath")
		if not modulePath then
			error(`[BT] require: нет BTPath у {target:GetFullName()}`, 2)
		end
		if modulePath == "Core/init.lua" and type(_G.Core) == "table" then
			return _G.Core
		end
		local ok, result = pcall(RemoteLoader.run, modulePath, tool, target)
		if not ok then
			local msg = `require {modulePath} ({target:GetFullName()}): {result}`
			if continueOnError and not NO_STUB_PATHS[modulePath] then
				recordRunError(modulePath, msg)
				return makeStubModule(modulePath)
			end
			error(`[BT] {msg}`, 0)
		end
		if result == nil and continueOnError and not NO_STUB_PATHS[modulePath] then
			return makeStubModule(modulePath)
		end
		return result
	end
end

local function tryParamWrapperRun(
	path: string,
	body: string,
	tool: Tool,
	scriptInstance: Instance,
	btRequire: any,
	compileFn: (string, string, any?) -> (any?, string?)
): (boolean, any)
	local innerBody = stripModulePreamble(body)
	local wrapSource = "return function(__bt_script, __bt_tool, __bt_require)\n"
		.. "_G.__bt_require = __bt_require\n"
		.. "_G.__bt_tool = __bt_tool\n"
		.. "_G.__bt_script = __bt_script\n"
		.. "local require = __bt_require\n"
		.. "local script = __bt_script\n"
		.. `local Tool = __bt_tool\n`
		.. innerBody
		.. "\nend"

	local wrapFn, compileError = compileFn(wrapSource, "@" .. path .. "#params", nil)
	if not wrapFn then
		return false, `params compile: {compileError}`
	end

	return pcall(function()
		return wrapFn()(scriptInstance, tool, btRequire)
	end)
end

local function runModuleWithEnv(
	path: string,
	raw: string,
	tool: Tool,
	scriptInstance: Instance,
	btRequire: any
): any
	local compileFn = RemoteLoader.compile or defaultCompile

	-- Огромный auto-generated UI (lol.lua) не компилируется одним чанком
	-- из-за лимита локальных регистров (200). Выполняем по секциям "Элемент:".
	if path == "Launcher/Interfaces/lol.lua" then
		local env = buildModuleEnv(tool, scriptInstance, btRequire)
		local interfacesRoot = if scriptInstance and scriptInstance.Parent
			then scriptInstance.Parent
			else (tool:FindFirstChild("Interfaces") or tool)
		env.__bt_interfaces_root = interfacesRoot
		_G.__bt_interfaces_root = interfacesRoot
		local prefix = "local workspace = (_G.__bt_interfaces_root or __bt_interfaces_root)\n"
		local marker = "\n-- Элемент:"
		local blocks: { string } = {}
		local searchFrom = 1
		local firstStart = string.find(raw, "-- Элемент:", 1, true)

		if firstStart then
			while true do
				local blockStart = string.find(raw, "-- Элемент:", searchFrom, true)
				if not blockStart then
					break
				end
				local nextStart = string.find(raw, marker, blockStart + 1, true)
				local blockEnd = if nextStart then nextStart - 1 else #raw
				local block = string.sub(raw, blockStart, blockEnd)
				table.insert(blocks, prefix .. block)
				if not nextStart then
					break
				end
				searchFrom = nextStart + 1
			end
		else
			table.insert(blocks, raw)
		end

		for i, block in ipairs(blocks) do
			local fn, compileError = compileFn(block, "@" .. path .. "#part" .. tostring(i), env)
			if not fn then
				error(`compile part {i}: {compileError}`, 0)
			end
			local ok, runErr = runWithPinnedGlobals(function()
				_G.__bt_interfaces_root = interfacesRoot
				return fn()
			end, btRequire, tool, scriptInstance)
			if not ok then
				error(`run part {i}: {runErr}`, 0)
			end
			if i % 1 == 0 then
				task.wait()
			end
		end
		return true
	end

	local coreEnv = buildModuleEnv(tool, scriptInstance, btRequire)
	if path == "Core/init.lua" then
		_G.Core = coreEnv
	end
	local body = rewriteForModuleEnv(path, raw)

	local function tryEnvRun(): (boolean, any)
		local fn, compileError = compileFn(body, "@" .. path, coreEnv)
		if not fn then
			return false, `compile: {compileError}`
		end
		return runWithPinnedGlobals(function()
			return fn()
		end, btRequire, tool, scriptInstance)
	end

	local ok, result = tryEnvRun()
	if ok then
		if path == "Core/init.lua" then
			return coreEnv
		end
		if result == nil and path == "Tools/Move/init.lua" and type(_G.Core) == "table" and type(_G.Core.__bt_defaultMove) == "table" then
			return _G.Core.__bt_defaultMove
		end
		return result
	end

	-- Core должен выполняться в env (getfenv → Core); для Loader — запасной запуск с аргументами
	if path ~= "Core/init.lua" then
		local wrapOk, wrapResult = tryParamWrapperRun(path, body, tool, scriptInstance, btRequire, compileFn)
		if wrapOk then
			return wrapResult
		end
		error(`{result}; {wrapResult}`, 0)
	end

	error(tostring(result), 0)
end

local function cacheModuleResult(path: string, result: any): any
	if result == nil then
		if continueOnError and not NO_STUB_PATHS[path] then
			result = makeStubModule(path)
		else
			error(`[BT] {path}: модуль вернул nil`, 0)
		end
	end
	moduleCache[path] = result
	return result
end

function RemoteLoader.run(path: string, tool: Tool, scriptInstance: Instance?): any
	local cached = moduleCache[path]
	if cached ~= nil then
		if cached == false then
			if continueOnError and not NO_STUB_PATHS[path] then
				return makeStubModule(path)
			end
			error(`[BT] повторный run {path} после ошибки`, 0)
		end
		return cached
	end

	local okSource, err = RemoteLoader.fetchSource(path)
	if not okSource then
		error(`[BT] run {path}: {err}`, 0)
	end

	if scriptInstance == nil then
		error(`[BT] run {path}: scriptInstance is nil`, 0)
	end

	local btRequire = buildRequire(tool)
	local raw = sourceCache[path]
	local ok, result

	if scriptInstance:IsA("ModuleScript") then
		ok, result = pcall(runModuleWithEnv, path, raw, tool, scriptInstance, btRequire)
	else
		local wrapped = wrapChunkSource(raw)
		local fn, compileError = RemoteLoader.compile(wrapped, "@" .. path, nil)
		if not fn then
			error(`[BT] compile {path}: {compileError}`, 0)
		end
		ok, result = pcall(function()
			return fn()(scriptInstance, tool, btRequire)
		end)
	end

	if not ok then
		if continueOnError and not NO_STUB_PATHS[path] then
			recordRunError(path, tostring(result))
			moduleCache[path] = false
			return makeStubModule(path)
		end
		error(`[BT] run {path}: {result}`, 0)
	end

	if path == "Core/init.lua" and (result == nil or type(result) ~= "table") then
		result = _G.Core
	end
	return cacheModuleResult(path, result)
end

function RemoteLoader.clear()
	table.clear(sourceCache)
	table.clear(moduleCache)
	table.clear(registry)
	table.clear(failedPaths)
	table.clear(runtimeErrors)
	_G.Core = nil
	_G.UI = nil
	loadCancelled = false
	fetchCount = 0
	lastFetchAt = 0
	progressCallback = nil
end

_G.BT_RemoteLoader = RemoteLoader

return RemoteLoader
-- BT-RemoteLoader-EOF
