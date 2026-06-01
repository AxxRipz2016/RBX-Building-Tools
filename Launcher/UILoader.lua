local Players = game:GetService("Players")

local Config = require(script.Parent.Config)
local Session = require(script.Parent.Session)

local UILoader = {}

function UILoader.Destroy()
	if Session.LauncherGui then
		Session.LauncherGui:Destroy()
		Session.LauncherGui = nil
	end
end

function UILoader.Create(onBuild: () -> ())
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")

	UILoader.Destroy()

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = Config.LauncherGuiName
	screenGui.ResetOnSpawn = false
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.Parent = playerGui

	local frame = Instance.new("Frame")
	frame.Name = "Panel"
	frame.AnchorPoint = Vector2.new(0, 1)
	frame.Position = UDim2.new(0, 12, 1, -12)
	frame.Size = UDim2.fromOffset(240, 104)
	frame.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
	frame.BorderSizePixel = 0
	frame.Parent = screenGui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = frame

	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Position = UDim2.fromOffset(10, 8)
	title.Size = UDim2.new(1, -20, 0, 18)
	title.Font = Enum.Font.GothamBold
	title.TextSize = 13
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextColor3 = Color3.fromRGB(240, 240, 240)
	title.Text = "BT — только у тебя"
	title.Parent = frame

	local hint = Instance.new("TextLabel")
	hint.BackgroundTransparency = 1
	hint.Position = UDim2.fromOffset(10, 26)
	hint.Size = UDim2.new(1, -20, 0, 28)
	hint.Font = Enum.Font.Gotham
	hint.TextSize = 11
	hint.TextWrapped = true
	hint.TextXAlignment = Enum.TextXAlignment.Left
	hint.TextColor3 = Color3.fromRGB(180, 180, 180)
	hint.Text = "Части видишь только ты"
	hint.Parent = frame

	local button = Instance.new("TextButton")
	button.Name = "Build"
	button.Position = UDim2.fromOffset(10, 58)
	button.Size = UDim2.new(1, -20, 0, 36)
	button.Font = Enum.Font.Gotham
	button.TextSize = 14
	button.TextColor3 = Color3.fromRGB(255, 255, 255)
	button.BackgroundColor3 = Color3.fromRGB(0, 120, 215)
	button.BorderSizePixel = 0
	button.Text = "Создать Building Tools"
	button.Parent = frame

	local buttonCorner = Instance.new("UICorner")
	buttonCorner.CornerRadius = UDim.new(0, 4)
	buttonCorner.Parent = button

	button.MouseButton1Click:Connect(onBuild)

	Session.LauncherGui = screenGui
	return screenGui
end

function UILoader.SetStatus(text: string)
	if not Session.LauncherGui then
		return
	end
	local panel = Session.LauncherGui:FindFirstChild("Panel")
	if not panel then
		return
	end
	local button = panel:FindFirstChild("Build")
	if button and button:IsA("TextButton") then
		button.Text = text
	end
end

return UILoader
