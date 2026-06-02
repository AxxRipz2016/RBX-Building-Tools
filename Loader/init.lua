local Tool = script.Parent;

-- Load tool completely before proceeding
local Indicator = Tool:WaitForChild 'Loaded';
while not Indicator.Value do
	Indicator.Changed:Wait();
end;

-- Initialize the core
local Core = _G.Core or require(Tool:WaitForChild 'Core');
if not Core.Assets then
	Core.Assets = require(Tool:WaitForChild('Assets'));
end

if Core.__dockToolsRegistered then
	if type(Core.RefreshToolDock) == 'function' then
		Core.RefreshToolDock();
	end
	return Core;
end

local function registerTool(iconKey, hotkey, moduleName)
	local toolModule = require(Tool.Tools:WaitForChild(moduleName));
	Core.AssignHotkey(hotkey, function()
		Core.EquipTool(toolModule);
	end);
	Core.AddToolButton(Core.Assets[iconKey], hotkey, toolModule);
end

-- Get core tools
local CoreTools = Tool:WaitForChild 'Tools';

registerTool('MoveIcon', 'Z', 'Move');
registerTool('ResizeIcon', 'X', 'Resize');
registerTool('RotateIcon', 'C', 'Rotate');
registerTool('PaintIcon', 'V', 'Paint');
registerTool('SurfaceIcon', 'B', 'Surface');
registerTool('MaterialIcon', 'N', 'Material');
registerTool('AnchorIcon', 'M', 'Anchor');
registerTool('CollisionIcon', 'K', 'Collision');
registerTool('NewPartIcon', 'J', 'NewPart');
registerTool('MeshIcon', 'H', 'Mesh');
registerTool('TextureIcon', 'G', 'Texture');
registerTool('WeldIcon', 'F', 'Weld');
registerTool('LightingIcon', 'U', 'Lighting');
registerTool('DecorateIcon', 'P', 'Decorate');

Core.__dockToolsRegistered = true;
if type(Core.RefreshToolDock) == 'function' then
	Core.RefreshToolDock();
end

return Core
