--[[
	BT_SoloPastebin → loadstring(game:HttpGet(этот файл))()
	В executor: getgenv().loadstring для всех следующих модулей.
]]
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")

if _G.BT_LAUNCHER_BUSY then
	warn("[BT] Загрузка уже идёт — дождитесь окна или перезайдите в плейс")
	return
end
_G.BT_LAUNCHER_BUSY = true
_G.BT_LAUNCHER_FETCH_READY = false

local BASE_URL = "https://raw.githubusercontent.com/utststs95/RBX-Building-Tools/refs/heads/development/"
-- Меняй при смене логики loadFromGit (старый paste без ?bt= кэширует RemoteEntry)
local ENTRY_REV = 4

local loadFn
local httpGet
local cacheTag = tostring(tick())

do
	local g = getgenv and getgenv() or nil
	local r = getrenv and getrenv() or nil
	loadFn = (g and (g.loadstring or g.load))
		or (r and (r.loadstring or r.load))
		or loadstring
	httpGet = function(url: string)
		if g and g.http_request then
			local res = g.http_request({ Url = url, Method = "GET" })
			return (type(res) == "table" and (res.Body or res.body)) or ""
		end
		if g and g.request then
			local res = g.request({ Url = url, Method = "GET" })
			return (type(res) == "table" and (res.Body or res.body)) or ""
		end
		if HttpService.HttpEnabled then
			return HttpService:GetAsync(url)
		end
		return game:HttpGet(url, true)
	end
end

local function gitUrl(path: string): string
	local url = BASE_URL .. path
	local sep = if url:find("?", 1, true) then "&" else "?"
	return url .. sep .. "bt=" .. cacheTag
end

local moduleCache: { [string]: any } = {}

local GITHUB_REPO = "utststs95/RBX-Building-Tools"
local GITHUB_BRANCH = "development"

local function isLikelyLuaSource(body: string): boolean
	body = body:gsub("^\239\187\191", ""):gsub("^%s+", ""):gsub("%s+$", "")
	if #body < 4 then
		return false
	end
	local head = body:sub(1, 200):lower()
	if head:match("^%s*404") or head:match("^%s*403") or head:find("too many requests", 1, true) then
		return false
	end
	if head:find("<!doctype", 1, true) or head:match("^%s*<html") then
		return false
	end
	return true
end

local function httpGetWithRetry(path: string): string
	local urls = {
		gitUrl(path),
		`https://cdn.jsdelivr.net/gh/{GITHUB_REPO}@{GITHUB_BRANCH}/{path}?bt={cacheTag}`,
		`{BASE_URL}{path}?bt={cacheTag}&mirror=1`,
	}
	local lastPreview = ""
	for attempt = 1, 6 do
		for _, url in urls do
			local ok, body = pcall(function()
				return httpGet(url)
			end)
			if ok and type(body) == "string" and isLikelyLuaSource(body) then
				return body
			end
			if ok and type(body) == "string" and #body > 0 then
				lastPreview = body:sub(1, 60):gsub("%s+", " ")
			end
		end
		task.wait(0.35 * attempt)
	end
	return ""
end

local function mayUseRemoteFetcher(): boolean
	if not _G.BT_LAUNCHER_FETCH_READY then
		return false
	end
	local activeLoader = _G.BT_RemoteLoader
	if type(activeLoader) ~= "table" or type(activeLoader.fetchSource) ~= "function" then
		return false
	end
	if activeLoader.BaseUrl == nil or activeLoader.BaseUrl == "" then
		return false
	end
	if type(activeLoader.isLoadCancelled) == "function" and activeLoader.isLoadCancelled() then
		return false
	end
	return true
end

local function loadFromGit(path: string)
	if moduleCache[path] ~= nil then
		return moduleCache[path]
	end

	local src: string
	if mayUseRemoteFetcher() then
		local activeLoader = _G.BT_RemoteLoader
		local okFetch, fetchErr = activeLoader.fetchSource(path)
		if not okFetch then
			if fetchErr == "отменено" and type(activeLoader.resetCancel) == "function" then
				activeLoader.resetCancel()
			end
			src = httpGetWithRetry(path)
			if not isLikelyLuaSource(src) then
				error(`[BT] {path}: {fetchErr}`, 0)
			end
		else
			src = activeLoader.getSource(path) or ""
		end
	else
		src = httpGetWithRetry(path)
	end

	if not isLikelyLuaSource(src) then
		error(
			`[BT] {path}: пустой ответ или HTML (GitHub лимит / обрезан HttpGet). Повтори через 1 мин или другой request`,
			0
		)
	end
	if path == "Launcher/RemoteLoader.lua" then
		if #src < 30000 then
			error(`[BT] RemoteLoader.lua обрезан ({#src} байт, нужно ~40k+) — другой HttpGet или зеркало`, 0)
		end
		if not src:find("BT-RemoteLoader-EOF", 1, true) then
			error("[BT] RemoteLoader.lua неполный (нет EOF-маркера, обрезан HttpGet?)", 0)
		end
	end
	local chunk, compileErr = loadFn(src, "@" .. path)
	if not chunk then
		error(`[BT] compile {path}: {compileErr}`, 0)
	end
	local runOk, result = pcall(chunk)
	if not runOk then
		error(`[BT] run {path}: {result}`, 0)
	end
	if result == nil then
		result = (path == "Launcher/RemoteLoader.lua") and _G.BT_RemoteLoader or nil
	end
	if result == nil then
		error(`[BT] {path}: модуль вернул nil`, 0)
	end
	moduleCache[path] = result
	return moduleCache[path]
end

_G.BT_HTTP_GET = httpGet
_G.BT_LAUNCHER_COMPILE = function(source: string, chunkName: string, env: any?)
	if env ~= nil then
		local fn, err = loadFn(source, chunkName, "t", env)
		if fn then
			return fn, nil
		end
		fn, err = loadFn(source, chunkName, env)
		if fn then
			return fn, nil
		end
		return nil, err
	end
	local fn, err = loadFn(source, chunkName)
	if fn then
		return fn, nil
	end
	return nil, err
end
_G.BT_LAUNCHER_LOAD = loadFromGit

-- Экран сразу (до HttpGet), иначе при пустом Version GUI не создаётся
local function showInstantBootScreen()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local old = playerGui:FindFirstChild("BT Load Status")
	if old then
		old:Destroy()
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = "BT Load Status"
	gui.ResetOnSpawn = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.DisplayOrder = 1000
	gui.Parent = playerGui

	local frame = Instance.new("Frame")
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromScale(0.5, 0.5)
	frame.Size = UDim2.fromOffset(420, 120)
	frame.BackgroundColor3 = Color3.fromRGB(25, 25, 28)
	frame.BorderSizePixel = 0
	frame.Parent = gui
	Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 8)

	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Size = UDim2.new(1, -24, 0, 28)
	title.Position = UDim2.fromOffset(12, 12)
	title.Font = Enum.Font.GothamBold
	title.TextSize = 16
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextColor3 = Color3.fromRGB(240, 240, 240)
	title.Text = "Building Tools — подключение…"
	title.Parent = frame

	local sub = Instance.new("TextLabel")
	sub.BackgroundTransparency = 1
	sub.Size = UDim2.new(1, -24, 0, 40)
	sub.Position = UDim2.fromOffset(12, 40)
	sub.Font = Enum.Font.Gotham
	sub.TextSize = 12
	sub.TextWrapped = true
	sub.TextXAlignment = Enum.TextXAlignment.Left
	sub.TextYAlignment = Enum.TextYAlignment.Top
	sub.TextColor3 = Color3.fromRGB(180, 180, 190)
	sub.Text = "Загрузка с GitHub…"
	sub.Parent = frame

	return function()
		if gui.Parent then
			gui:Destroy()
		end
	end
end

local dismissInstantBoot = showInstantBootScreen()

local DEFAULT_VERSION = {
	Launcher = "0",
	Tool = "3.1.0",
	Roact = "1.3.0",
	Cryo = "master",
	Branch = "development",
}

local function loadVersionTable()
	local src = httpGetWithRetry("Launcher/Version.lua")
	if not isLikelyLuaSource(src) then
		return DEFAULT_VERSION
	end
	local fn, compileErr = loadFn(src, "@Version")
	if not fn then
		warn("[BT] Version compile:", compileErr)
		return DEFAULT_VERSION
	end
	local ok, result = pcall(fn)
	if ok and type(result) == "table" and type(result.Launcher) == "string" then
		return result
	end
	return DEFAULT_VERSION
end

local Version = loadVersionTable()
cacheTag = Version.Launcher

local ui
local initOk, initErr = pcall(function()
	local statusSrc = httpGetWithRetry("Launcher/LoadStatusUI.lua")
	if not isLikelyLuaSource(statusSrc) then
		error("[BT] LoadStatusUI.lua не загрузился (пустой ответ / HTML)", 0)
	end
	local LoadStatusUI = loadFn(statusSrc, "@LoadStatusUI")()
	if type(LoadStatusUI) ~= "table" or type(LoadStatusUI.create) ~= "function" then
		error("[BT] LoadStatusUI: неверный модуль", 0)
	end
	dismissInstantBoot()
	ui = LoadStatusUI.create()
	ui.setVersionInfo(
		`Launcher r{Version.Launcher} · BT {Version.Tool} · Roact {Version.Roact} · Cryo {Version.Cryo}`
	)
end)

if not initOk then
	dismissInstantBoot()
	_G.BT_LAUNCHER_BUSY = nil
	warn("[BT Solo]", initErr)
	return
end

local ok, err = pcall(function()
	local Config = loadFromGit("Launcher/Config.lua")
	Config.LoadMode = "Remote"
	Config.RemoteBaseUrl = BASE_URL

	local RemoteLoader = loadFromGit("Launcher/RemoteLoader.lua")
	_G.BT_RemoteLoader = RemoteLoader

	do
		local okTls, tlsSrc = pcall(function()
			return loadFromGit("Launcher/BT_ToolListSource.lua")
		end)
		if okTls and type(tlsSrc) == "string" and #tlsSrc > 100 then
			_G.BT_TOOL_LIST_SOURCE = tlsSrc
		end
	end
	do
		local okUic, uicSrc = pcall(function()
			return loadFromGit("Launcher/BT_UIControllerSource.lua")
		end)
		if okUic and type(uicSrc) == "string" and #uicSrc > 200 then
			_G.BT_UI_CONTROLLER_SOURCE = uicSrc
		end
	end
	if type(RemoteLoader) ~= "table" or type(RemoteLoader.configure) ~= "function" then
		local fallback = _G.BT_RemoteLoader
		if type(fallback) == "table" and type(fallback.configure) == "function" then
			RemoteLoader = fallback
		else
			error(
				"[BT] RemoteLoader не загрузился (nil/configure). В paste — только Bootstrap.lua, не старый RemoteEntry",
				0
			)
		end
	end
	RemoteLoader.configure(BASE_URL, Config.RemoteVendorUrls)
	if type(RemoteLoader.resetCancel) == "function" then
		RemoteLoader.resetCancel()
	end
	_G.BT_RemoteLoader = RemoteLoader
	_G.BT_LAUNCHER_FETCH_READY = true
	if Config.ContinueOnLoadErrors ~= false then
		RemoteLoader.setContinueOnError(true)
	end

	local RemoteToolBuilder = loadFromGit("Launcher/RemoteToolBuilder.lua")
	local manifestSrc = httpGetWithRetry("Launcher/manifest.lua")
	if not isLikelyLuaSource(manifestSrc) then
		local okM, _ = RemoteLoader.fetchSource("Launcher/manifest.lua")
		if okM then
			manifestSrc = RemoteLoader.getSource("Launcher/manifest.lua") or ""
		end
	end
	local manifest = loadFn(manifestSrc, "Launcher/manifest.lua")()

	RemoteToolBuilder.setManifest(manifest)
	RemoteToolBuilder.setVersionInfo(Version)
	_G.BT_LAUNCHER_VERSION = Version

	ui.onCancel(function()
		RemoteLoader.requestCancel()
		ui.setCancelled()
		ui.addError("—", "загрузка отменена пользователем")
	end)

	local fileIndex = 0
	local totalFiles = #manifest
	RemoteLoader.setProgressCallback(function(path, fileOk, fileErr)
		fileIndex += 1
		ui.setProgress(fileIndex, totalFiles, path, fileOk)
		if fileOk == false then
			ui.addError(path, fileErr or "неизвестная ошибка")
		end
	end)

	local player = Players.LocalPlayer
	local tool = RemoteToolBuilder.Build(player, {
		onFile = function(index, total, path, fileOk, fileErr)
			if index and index > fileIndex then
				fileIndex = index
			else
				fileIndex += 1
			end
			ui.setProgress(fileIndex, totalFiles, path, fileOk)
			if fileOk == false then
				ui.addError(path, fileErr or "неизвестная ошибка")
			end
		end,
		onMessage = function(message: string)
			ui.setProgress(fileIndex, totalFiles, message, true)
		end,
	})

	if RemoteLoader.isLoadCancelled() then
		ui.setDone(`r{Version.Launcher} · загрузка отменена`)
		return
	end

	ui.setProgress(0, 0, "Запуск Core и инструментов…", true)

	task.spawn(function()
		local runOk, runErr = pcall(function()
			RemoteToolBuilder.StartRuntime(tool, function(stepText: string)
				ui.setProgress(0, 0, stepText, true)
			end)
		end)
		if not runOk then
			ui.addError("StartRuntime", tostring(runErr))
		end

		RemoteToolBuilder.GiveToPlayer(tool, player)
		if not runOk then
			ui.addError("Tool", "в Backpack; Core/Loader не стартовал — «Копировать ошибку»")
		end

		local failCount = 0
		for _ in RemoteLoader.getFailed() do
			failCount += 1
		end
		local runErrCount = #RemoteLoader.getRuntimeErrors()

		local doneText = if runOk and failCount == 0 and runErrCount == 0
			then `r{Version.Launcher} · OK · {RemoteLoader.getFetchCount()} файлов · Tool в Backpack`
			elseif not runOk
			then `r{Version.Launcher} · Tool в Backpack · ошибка запуска (копируй ниже)`
			else `r{Version.Launcher} · ошибки: {failCount} файлов, run: {runErrCount}`
		ui.setDone(doneText)
		if failCount > 0 or runErrCount > 0 or not runOk then
			ui.setProgress(0, 0, doneText, false)
		else
			task.delay(2, function()
				if ui.destroy then
					ui.destroy()
				end
			end)
		end

		local dockCount = tool:GetAttribute("BT_DockButtonCount") or 0
		if dockCount == 0 and type(RemoteToolBuilder.rebuildToolDock) == "function" then
			dockCount = RemoteToolBuilder.rebuildToolDock(tool) or 0
			tool:SetAttribute("BT_DockButtonCount", dockCount)
		end
		local dockHint = if dockCount == 0
			then " (Core.UI/ToolList — см. warn выше)"
			else ""
		local manifestTotal = tool:GetAttribute("BT_ManifestCount") or 0
		local fetched = RemoteLoader.getFetchCount()
		local filesLine = if manifestTotal > 0
			then `{fetched}/{manifestTotal} файлов`
			else `{fetched} файлов`
		print(
			`[BT] RemoteEntry r{Version.Launcher} · BT {Version.Tool} · док {dockCount} кнопок · {filesLine} — готов{dockHint}`
		)
	end)
end)

if not ok and ui then
	ui.setFatal(tostring(err))
	warn("[BT Solo]", err)
elseif not ok then
	warn("[BT Solo]", err)
end

_G.BT_LAUNCHER_BUSY = nil
