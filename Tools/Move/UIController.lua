local Tool = script.Parent.Parent.Parent
local Libraries = Tool:WaitForChild('Libraries')

-- API
local Core = require(Tool.Core)

-- Libraries
local Support = require(Libraries:WaitForChild 'SupportLibrary')
local Maid = require(Libraries:WaitForChild 'Maid')
local ListenForManualWindowTrigger = require(Tool.Core:WaitForChild('ListenForManualWindowTrigger'))

local function btSetGuiVisible(gui, visible)
	if gui == nil or typeof(gui) ~= "Instance" then
		return
	end
	if gui:IsA("ScreenGui") then
		gui.Enabled = visible and true or false
	elseif gui:IsA("GuiObject") then
		gui.Visible = visible and true or false
	end
end

local function getSelectionParts()
	if type(Core.GetSelectionParts) == "function" then
		return Core.GetSelectionParts()
	end
	local sel = Core.Selection
	if sel and type(sel.Parts) == "table" then
		return sel.Parts
	end
	return {}
end

-- Create class
local UIController = {}
UIController.__index = UIController

function UIController.new(Tool)
    local self = {
        Tool = Tool;

        -- State
        UI = nil;
        Maid = Maid.new()
    }

    return setmetatable(self, UIController)
end

function UIController:ShowUI()
	-- Creates and reveals the UI

	-- Reveal UI if already created
	if self.UI then
		btSetGuiVisible(self.UI, true)
		if type(Support.Loop) == "function" then
			self.Maid.UIUpdater = Support.Loop(0.1, self.UpdateUI, self)
		end
        self:AttachDragListener()
        self:AttachAxesListener()
		return
	end

	-- Create the UI
	if type(Core.EnsureUI) == "function" then
		Core.EnsureUI()
	end
	local uiRoot = Core.UI
	if not uiRoot or not uiRoot:IsA("ScreenGui") then
		warn("[BT] Move UI: Core.UI не инициализирован")
		return
	end
	if not uiRoot.Parent then
		local pg = game:GetService("Players").LocalPlayer:FindFirstChild("PlayerGui")
		if pg then
			uiRoot.Parent = pg
			uiRoot.Enabled = true
		end
	end
	self.UI = (Core.Tool or Tool):WaitForChild('Interfaces'):WaitForChild('BTMoveToolGUI'):Clone()
	self.UI.Parent = uiRoot
	btSetGuiVisible(self.UI, true)

	-- Add functionality to the axes option switch
	local AxesSwitch = self.UI.AxesOption
	AxesSwitch.Global.Button.MouseButton1Down:Connect(function ()
		self.Tool:SetAxes('Global')
	end)
	AxesSwitch.Local.Button.MouseButton1Down:Connect(function ()
		self.Tool:SetAxes('Local')
	end)
	AxesSwitch.Last.Button.MouseButton1Down:Connect(function ()
		self.Tool:SetAxes('Last')
	end)

	-- Add functionality to the increment input
	local IncrementInput = self.UI.IncrementOption.Increment.TextBox
	IncrementInput.FocusLost:Connect(function (EnterPressed)
		self.Tool.Increment = tonumber(IncrementInput.Text) or self.Tool.Increment
		IncrementInput.Text = Support.Round(self.Tool.Increment, 4)
	end)

	-- Add functionality to the position inputs
	local XInput = self.UI.Info.Center.X.TextBox
	local YInput = self.UI.Info.Center.Y.TextBox
	local ZInput = self.UI.Info.Center.Z.TextBox
	XInput.FocusLost:Connect(function (EnterPressed)
		local NewPosition = tonumber(XInput.Text)
		if NewPosition then
			self.Tool:SetAxisPosition('X', NewPosition)
		end
	end)
	YInput.FocusLost:Connect(function (EnterPressed)
		local NewPosition = tonumber(YInput.Text)
		if NewPosition then
			self.Tool:SetAxisPosition('Y', NewPosition)
		end
	end)
	ZInput.FocusLost:Connect(function (EnterPressed)
		local NewPosition = tonumber(ZInput.Text)
		if NewPosition then
			self.Tool:SetAxisPosition('Z', NewPosition)
		end
	end)

	-- Hook up manual triggering
	local SignatureButton = self.UI:WaitForChild('Title'):WaitForChild('Signature')
	ListenForManualWindowTrigger(self.Tool.ManualText, self.Tool.Color.Color, SignatureButton)

	-- Update the UI every 0.1 seconds
	if type(Support.Loop) == "function" then
		self.Maid.UIUpdater = Support.Loop(0.1, self.UpdateUI, self)
	end

    -- Attach state listeners
    self:AttachDragListener()
    self:AttachAxesListener()

end

function UIController:AttachDragListener()
    self.Maid.DragListener = self.Tool.DragChanged:Connect(function (Distance)

        -- Update the "distance moved" indicator
        self.UI.Changes.Text.Text = 'moved ' .. math.abs(Distance) .. ' studs'

    end)
end

function UIController:AttachAxesListener()
    self.Maid.AxesListener = self.Tool.AxesChanged:Connect(function (AxesMode)

        -- Update the UI switch
        Core.ToggleSwitch(AxesMode, self.UI.AxesOption)

    end)
end

function UIController:HideUI()
	-- Hides the tool UI

	-- Make sure there's a UI
	if not self.UI then
		return
	end

	-- Hide the UI
	btSetGuiVisible(self.UI, false)

	-- Stop updating the UI
    self.Maid:Destroy()

end

function UIController:UpdateUI()
	-- Updates information on the UI

	-- Make sure the UI's on
	if not self.UI then
		return
	end

	-- Only show and calculate selection info if it's not empty
	local parts = getSelectionParts()
	if #parts == 0 then
		self.UI.Info.Visible = false
		self.UI.Size = UDim2.new(0, 245, 0, 90)
		return
	else
		self.UI.Info.Visible = true
		self.UI.Size = UDim2.new(0, 245, 0, 150)
	end

	---------------------------------------------
	-- Update the position information indicators
	---------------------------------------------

	-- Identify common positions across axes
	local XVariations, YVariations, ZVariations = {}, {}, {}
	for _, Part in pairs(parts) do
		table.insert(XVariations, Support.Round(Part.Position.X, 3))
		table.insert(YVariations, Support.Round(Part.Position.Y, 3))
		table.insert(ZVariations, Support.Round(Part.Position.Z, 3))
	end
	local CommonX = Support.IdentifyCommonItem(XVariations)
	local CommonY = Support.IdentifyCommonItem(YVariations)
	local CommonZ = Support.IdentifyCommonItem(ZVariations)

	-- Shortcuts to indicators
	local XIndicator = self.UI.Info.Center.X.TextBox
	local YIndicator = self.UI.Info.Center.Y.TextBox
	local ZIndicator = self.UI.Info.Center.Z.TextBox

	-- Update each indicator if it's not currently being edited
	if not XIndicator:IsFocused() then
		XIndicator.Text = CommonX or '*'
	end
	if not YIndicator:IsFocused() then
		YIndicator.Text = CommonY or '*'
	end
	if not ZIndicator:IsFocused() then
		ZIndicator.Text = CommonZ or '*'
	end

end

function UIController:FocusIncrementInput()
    self.UI.IncrementOption.Increment.TextBox:CaptureFocus()
end

return UIController