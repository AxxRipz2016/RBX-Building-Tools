--[[
	Экран загрузки Remote BT (без script.Parent).
]]
local LoadStatusUI = {}

local function copyToClipboard(text: string): boolean
	if text == "" then
		return false
	end
	local fn = setclipboard
		or (getgenv and getgenv().setclipboard)
		or (getrenv and getrenv().setclipboard)
	if type(fn) == "function" then
		fn(text)
		return true
	end
	return false
end

function LoadStatusUI.create()
	local player = game:GetService("Players").LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")

	local old = playerGui:FindFirstChild("BT Load Status")
	if old then
		old:Destroy()
	end

	local gui = Instance.new("ScreenGui")
	gui.Name = "BT Load Status"
	gui.ResetOnSpawn = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = playerGui

	local frame = Instance.new("Frame")
	frame.Name = "Panel"
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromScale(0.5, 0.5)
	frame.Size = UDim2.fromOffset(420, 262)
	frame.BackgroundColor3 = Color3.fromRGB(25, 25, 28)
	frame.BorderSizePixel = 0
	frame.Parent = gui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = frame

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.BackgroundTransparency = 1
	title.Position = UDim2.fromOffset(12, 10)
	title.Size = UDim2.new(1, -52, 0, 22)
	title.Font = Enum.Font.GothamBold
	title.TextSize = 16
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextColor3 = Color3.fromRGB(240, 240, 240)
	title.Text = "Building Tools — загрузка"
	title.Parent = frame

	local versionLine = Instance.new("TextLabel")
	versionLine.Name = "VersionLine"
	versionLine.BackgroundTransparency = 1
	versionLine.Position = UDim2.fromOffset(12, 30)
	versionLine.Size = UDim2.new(1, -52, 0, 14)
	versionLine.Font = Enum.Font.Gotham
	versionLine.TextSize = 11
	versionLine.TextXAlignment = Enum.TextXAlignment.Left
	versionLine.TextColor3 = Color3.fromRGB(140, 140, 150)
	versionLine.Text = ""
	versionLine.Parent = frame

	local closeTop = Instance.new("TextButton")
	closeTop.Name = "CloseTop"
	closeTop.BackgroundTransparency = 1
	closeTop.Position = UDim2.new(1, -36, 0, 6)
	closeTop.Size = UDim2.fromOffset(28, 28)
	closeTop.Font = Enum.Font.GothamBold
	closeTop.TextSize = 18
	closeTop.TextColor3 = Color3.fromRGB(180, 180, 180)
	closeTop.Text = "×"
	closeTop.Parent = frame

	local progress = Instance.new("TextLabel")
	progress.Name = "Progress"
	progress.BackgroundTransparency = 1
	progress.Position = UDim2.fromOffset(12, 48)
	progress.Size = UDim2.new(1, -24, 0, 36)
	progress.Font = Enum.Font.Gotham
	progress.TextSize = 13
	progress.TextWrapped = true
	progress.TextXAlignment = Enum.TextXAlignment.Left
	progress.TextYAlignment = Enum.TextYAlignment.Top
	progress.TextColor3 = Color3.fromRGB(200, 200, 200)
	progress.Text = "Подготовка…"
	progress.Parent = frame

	local barBack = Instance.new("Frame")
	barBack.Name = "BarBack"
	barBack.Position = UDim2.fromOffset(12, 88)
	barBack.Size = UDim2.new(1, -24, 0, 8)
	barBack.BackgroundColor3 = Color3.fromRGB(50, 50, 55)
	barBack.BorderSizePixel = 0
	barBack.Parent = frame

	local barCorner = Instance.new("UICorner")
	barCorner.CornerRadius = UDim.new(0, 4)
	barCorner.Parent = barBack

	local barFill = Instance.new("Frame")
	barFill.Name = "Fill"
	barFill.Size = UDim2.fromScale(0, 1)
	barFill.BackgroundColor3 = Color3.fromRGB(0, 120, 215)
	barFill.BorderSizePixel = 0
	barFill.Parent = barBack

	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(0, 4)
	fillCorner.Parent = barFill

	local detail = Instance.new("TextLabel")
	detail.Name = "Detail"
	detail.BackgroundTransparency = 1
	detail.Position = UDim2.fromOffset(12, 102)
	detail.Size = UDim2.new(1, -24, 0, 52)
	detail.Font = Enum.Font.Gotham
	detail.TextSize = 11
	detail.TextWrapped = true
	detail.TextXAlignment = Enum.TextXAlignment.Left
	detail.TextYAlignment = Enum.TextYAlignment.Top
	detail.TextColor3 = Color3.fromRGB(255, 120, 120)
	detail.Text = ""
	detail.Parent = frame

	local cancelBtn = Instance.new("TextButton")
	cancelBtn.Name = "Cancel"
	cancelBtn.Position = UDim2.new(0, 12, 1, -104)
	cancelBtn.Size = UDim2.new(1, -24, 0, 30)
	cancelBtn.BackgroundColor3 = Color3.fromRGB(140, 55, 55)
	cancelBtn.BorderSizePixel = 0
	cancelBtn.Font = Enum.Font.Gotham
	cancelBtn.TextSize = 14
	cancelBtn.TextColor3 = Color3.fromRGB(240, 240, 240)
	cancelBtn.Text = "Отмена загрузки"
	cancelBtn.Parent = frame

	local cancelCorner = Instance.new("UICorner")
	cancelCorner.CornerRadius = UDim.new(0, 6)
	cancelCorner.Parent = cancelBtn

	local copyBtn = Instance.new("TextButton")
	copyBtn.Name = "Copy"
	copyBtn.Position = UDim2.new(0, 12, 1, -68)
	copyBtn.Size = UDim2.new(1, -24, 0, 28)
	copyBtn.BackgroundColor3 = Color3.fromRGB(45, 90, 140)
	copyBtn.BorderSizePixel = 0
	copyBtn.Font = Enum.Font.Gotham
	copyBtn.TextSize = 13
	copyBtn.TextColor3 = Color3.fromRGB(230, 230, 230)
	copyBtn.Text = "Копировать ошибку в буфер"
	copyBtn.Visible = false
	copyBtn.Parent = frame

	local copyCorner = Instance.new("UICorner")
	copyCorner.CornerRadius = UDim.new(0, 6)
	copyCorner.Parent = copyBtn

	local closeBtn = Instance.new("TextButton")
	closeBtn.Name = "Close"
	closeBtn.Position = UDim2.new(0, 12, 1, -36)
	closeBtn.Size = UDim2.new(1, -24, 0, 30)
	closeBtn.BackgroundColor3 = Color3.fromRGB(55, 55, 60)
	closeBtn.BorderSizePixel = 0
	closeBtn.Font = Enum.Font.Gotham
	closeBtn.TextSize = 14
	closeBtn.TextColor3 = Color3.fromRGB(230, 230, 230)
	closeBtn.Text = "Закрыть"
	closeBtn.Parent = frame

	local closeCorner = Instance.new("UICorner")
	closeCorner.CornerRadius = UDim.new(0, 6)
	closeCorner.Parent = closeBtn

	local api = {}
	local destroyed = false
	local cancelled = false
	local onCancelCallback: (() -> ())? = nil

	local function getErrorText(): string
		local parts = {}
		if versionLine.Text ~= "" then
			table.insert(parts, versionLine.Text)
		end
		if progress.Text ~= "" then
			table.insert(parts, progress.Text)
		end
		if detail.Text ~= "" then
			table.insert(parts, detail.Text)
		end
		return table.concat(parts, "\n")
	end

	local function refreshCopyButton()
		copyBtn.Visible = detail.Text ~= "" or progress.TextColor3 == Color3.fromRGB(255, 100, 100)
	end

	local function close()
		if destroyed then
			return
		end
		destroyed = true
		gui:Destroy()
	end

	cancelBtn.MouseButton1Click:Connect(function()
		if cancelled or destroyed then
			return
		end
		cancelled = true
		cancelBtn.Text = "Отмена…"
		cancelBtn.AutoButtonColor = false
		if onCancelCallback then
			onCancelCallback()
		end
	end)

	closeTop.MouseButton1Click:Connect(close)
	closeBtn.MouseButton1Click:Connect(close)

	copyBtn.MouseButton1Click:Connect(function()
		local text = getErrorText()
		if copyToClipboard(text) then
			copyBtn.Text = "Скопировано — вставь в чат (Ctrl+V)"
			copyBtn.BackgroundColor3 = Color3.fromRGB(40, 120, 70)
		else
			copyBtn.Text = "setclipboard недоступен"
			copyBtn.BackgroundColor3 = Color3.fromRGB(120, 50, 50)
		end
	end)

	function api.setVersionInfo(text: string)
		versionLine.Text = text
	end

	function api.setProgress(index: number, total: number, path: string, ok: boolean?)
		local ratio = if total > 0 then index / total else math.min(index / 120, 0.95)
		barFill.Size = UDim2.fromScale(math.clamp(ratio, 0, 1), 1)
		local status = if ok == false then "ОШИБКА" else "OK"
		progress.Text = if total > 0
			then string.format("[%d / %d] %s  (%s)", index, total, path, status)
			else string.format("[%d] %s  (%s)", index, path, status)
		progress.TextColor3 = if ok == false
			then Color3.fromRGB(255, 180, 100)
			else Color3.fromRGB(200, 200, 200)
		refreshCopyButton()
	end

	function api.addError(path: string, err: string)
		local line = path .. ": " .. err
		if detail.Text == "" then
			detail.Text = line
		else
			detail.Text = detail.Text .. "\n" .. line
		end
		refreshCopyButton()
	end

	function api.onCancel(callback: () -> ())
		onCancelCallback = callback
	end

	function api.setCancelled()
		cancelled = true
		cancelBtn.Text = "Отменено"
		cancelBtn.BackgroundColor3 = Color3.fromRGB(90, 90, 95)
	end

	function api.setDone(message: string)
		cancelBtn.Visible = false
		title.Text = "Building Tools"
		progress.Text = message
		local hasErrors = detail.Text ~= ""
		progress.TextColor3 = if hasErrors
			then Color3.fromRGB(255, 180, 100)
			else Color3.fromRGB(120, 220, 140)
		barFill.Size = UDim2.fromScale(1, 1)
		barFill.BackgroundColor3 = if hasErrors
			then Color3.fromRGB(160, 100, 40)
			else Color3.fromRGB(40, 160, 90)
		closeBtn.Text = "Закрыть (можно запустить снова)"
		refreshCopyButton()
	end

	function api.setFatal(message: string)
		title.Text = "Ошибка загрузки"
		progress.Text = message
		progress.TextColor3 = Color3.fromRGB(255, 100, 100)
		barFill.BackgroundColor3 = Color3.fromRGB(180, 60, 60)
		closeBtn.Text = "Закрыть"
		refreshCopyButton()
		copyToClipboard(getErrorText())
	end

	function api.copyError(): boolean
		return copyToClipboard(getErrorText())
	end

	function api.destroy()
		close()
	end

	return api
end

return LoadStatusUI
