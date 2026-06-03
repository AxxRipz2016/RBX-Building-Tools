local Root = script:FindFirstAncestorWhichIsA('Tool')
local Vendor = Root:WaitForChild('Vendor')
local Libraries = Root:WaitForChild('Libraries')

-- Libraries
local Roact = require(Vendor:WaitForChild('Roact'))
local Maid = require(Libraries:WaitForChild('Maid'))

-- Roact
local new = Roact.createElement
local ToolButton = require(script.Parent:WaitForChild('ToolButton'))

-- Create component
-- Component (не PureComponent): Tools обновляется той же таблицей после table.insert
local ToolList = Roact.Component:extend(script.Name)

function ToolList:init()
    self.Maid = Maid.new()
    self.CanvasSize, self.SetCanvasSize = Roact.createBinding(UDim2.new())

    local core = self.props.Core
    if core then
        self:setState({
            CurrentTool = core.CurrentTool;
        })
        local toolChanged = core.ToolChanged
        if type(toolChanged) == "table" and type(toolChanged.Connect) == "function" then
            self.Maid.CurrentTool = toolChanged:Connect(function (BuildingToolModule)
                self:setState({
                    CurrentTool = BuildingToolModule;
                })
            end)
        end
    end
end

function ToolList:render()
    local Children = {
        Layout = new('UIGridLayout', {
            CellPadding = UDim2.new(0, 0, 0, 0);
            CellSize = UDim2.new(0, 35, 0, 35);
            FillDirection = Enum.FillDirection.Horizontal;
            FillDirectionMaxCells = 2;
            HorizontalAlignment = Enum.HorizontalAlignment.Left;
            VerticalAlignment = Enum.VerticalAlignment.Top;
            SortOrder = Enum.SortOrder.LayoutOrder;
            StartCorner = Enum.StartCorner.TopLeft;
            [Roact.Ref] = function (rbx)
                if rbx then
                    self.SetCanvasSize(UDim2.fromOffset(rbx.AbsoluteContentSize.X, rbx.AbsoluteContentSize.Y))
                end
            end;
            [Roact.Change.AbsoluteContentSize] = function (rbx)
                self.SetCanvasSize(UDim2.fromOffset(rbx.AbsoluteContentSize.X, rbx.AbsoluteContentSize.Y))
            end;
        });
    }

    local tools = self.props.Tools
    print(tools)
    print(type(tools))
    if type(tools) ~= 'table' then
        tools = {}
    end

    -- Build buttons for each tool
    for ToolIndex, ToolInfo in ipairs(tools) do
        Children[tostring(ToolIndex)] = new(ToolButton, {
            CurrentTool = self.state.CurrentTool;
            IconAssetId = ToolInfo.IconAssetId;
            HotkeyLabel = ToolInfo.HotkeyLabel;
            Tool = ToolInfo.Tool;
            Core = self.props.Core;
        })
    end

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

    return new('Frame', {
        BackgroundTransparency = 0.8;
        BackgroundColor3 = Color3.fromRGB(0, 0, 0);
        BorderSizePixel = 0;
        LayoutOrder = self.props.LayoutOrder;
        Size = UDim2.fromOffset(70, math.max(245, 35 * math.ceil(#tools / 2)));
    }, frameChildren)
end

return ToolList
