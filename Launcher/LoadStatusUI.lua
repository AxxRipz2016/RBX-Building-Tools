--[[
	Экран загрузки Remote BT (без script.Parent).
]]
local LoadStatusUI = {}

function LoadStatusUI.create()
	local player = game:GetService("Players").LocalPlayer
	local gui = Instance.new("ScreenGui")
	gui.Name = "BT Load Status"
	gui.ResetOnSpawn = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = player:WaitForChild("PlayerGui")

	local frame = Instance.new("Frame")
	frame.Name = "Panel"
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromScale(0.5, 0.5)
	frame.Size = UDim2.fromOffset(420, 160)
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
	title.Size = UDim2.new(1, -24, 0, 22)
	title.Font = Enum.Font.GothamBold
	title.TextSize = 16
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextColor3 = Color3.fromRGB(240, 240, 240)
	title.Text = "Building Tools — загрузка"
	title.Parent = frame

	local progress = Instance.new("TextLabel")
	progress.Name = "Progress"
	progress.BackgroundTransparency = 1
	progress.Position = UDim2.fromOffset(12, 36)
	progress.Size = UDim2.new(1, -24, 0, 40)
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
	barBack.Position = UDim2.fromOffset(12, 82)
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
	detail.Position = UDim2.fromOffset(12, 98)
	detail.Size = UDim2.new(1, -24, 0, 52)
	detail.Font = Enum.Font.Gotham
	detail.TextSize = 11
	detail.TextWrapped = true
	detail.TextXAlignment = Enum.TextXAlignment.Left
	detail.TextYAlignment = Enum.TextYAlignment.Top
	detail.TextColor3 = Color3.fromRGB(255, 120, 120)
	detail.Text = ""
	detail.Parent = frame

	local api = {}

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
	end

	function api.addError(path: string, err: string)
		local line = path .. ": " .. err
		if detail.Text == "" then
			detail.Text = line
		else
			detail.Text = detail.Text .. "\n" .. line
		end
	end

	function api.setDone(message: string)
		title.Text = "Building Tools"
		progress.Text = message
		progress.TextColor3 = Color3.fromRGB(120, 220, 140)
		barFill.Size = UDim2.fromScale(1, 1)
		barFill.BackgroundColor3 = Color3.fromRGB(40, 160, 90)
	end

	function api.setFatal(message: string)
		title.Text = "Ошибка загрузки"
		progress.Text = message
		progress.TextColor3 = Color3.fromRGB(255, 100, 100)
		barFill.BackgroundColor3 = Color3.fromRGB(180, 60, 60)
	end

	function api.destroy()
		gui:Destroy()
	end

	return api
end

return LoadStatusUI
