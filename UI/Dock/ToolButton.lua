local Root = script:FindFirstAncestorWhichIsA('Tool')
local Vendor = Root:WaitForChild('Vendor')
local TextService = game:GetService('TextService')

-- Libraries
local Roact = require(Vendor:WaitForChild('Roact'))
local new = Roact.createElement

-- Create component
local ToolButton = Roact.PureComponent:extend(script.Name)

function ToolButton:init()
    self:UpdateHotkeyTextSize(self.props.HotkeyLabel)
end

function ToolButton:willUpdate(nextProps)
    if self.props.HotkeyLabel ~= nextProps.HotkeyLabel then
        self:UpdateHotkeyTextSize(nextProps.HotkeyLabel)
    end
end

function ToolButton:UpdateHotkeyTextSize(Text)
    self.HotkeyTextSize = TextService:GetTextSize(
        Text,
        9,
        Enum.Font.Gotham,
        Vector2.new(math.huge, math.huge)
    )
end

local function isCurrentTool(currentTool, buildingTool)
    if currentTool == buildingTool then
        return true
    end
    if type(currentTool) == "table" and type(buildingTool) == "table" then
        if currentTool.Name and buildingTool.Name and currentTool.Name == buildingTool.Name then
            return true
        end
    end
    return false
end

function ToolButton:render()
    local buildingTool = self.props.Tool
    local themeColor = Color3.new(0.85, 0.45, 0.1)
    if type(buildingTool) == "table" and buildingTool.Color then
        local c = buildingTool.Color
        if typeof(c) == "BrickColor" then
            themeColor = c.Color
        elseif typeof(c) == "Color3" then
            themeColor = c
        end
    end
    return new('ImageButton', {
        BackgroundColor3 = themeColor;
        BackgroundTransparency = isCurrentTool(self.props.CurrentTool, buildingTool) and 0 or 1;
        BorderSizePixel = 0;
        Image = self.props.IconAssetId;
        AutoButtonColor = false;
        [Roact.Event.Activated] = function ()
            local core = self.props.Core
            if core and type(core.EquipTool) == "function" then
                core.EquipTool(self.props.Tool)
            end
        end;
    }, {
        Corners = new('UICorner', {
            CornerRadius = UDim.new(0, 3);
        });
        Hotkey = new('TextLabel', {
            BackgroundTransparency = 1;
            Position = UDim2.new(0, 3, 0, 3);
            Size = UDim2.fromOffset(self.HotkeyTextSize.X, self.HotkeyTextSize.Y);
            Font = Enum.Font.Gotham;
            Text = self.props.HotkeyLabel;
            TextColor3 = Color3.fromRGB(255, 255, 255);
            TextSize = 9;
            TextXAlignment = Enum.TextXAlignment.Left;
            TextYAlignment = Enum.TextYAlignment.Top;
        });
    })
end

return ToolButton