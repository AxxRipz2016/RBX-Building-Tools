local Root = script:FindFirstAncestorWhichIsA('Tool')
local Libraries = Root:WaitForChild('Libraries')
local Vendor = Root:WaitForChild('Vendor')

-- Libraries
local Roact = require(Vendor:WaitForChild('Roact'))
local fastSpawn = require(Libraries:WaitForChild('fastSpawn'))

-- Roact
local new = Roact.createElement
local NotificationDialog = require(script:WaitForChild('NotificationDialog'))

-- Create component
local Notifications = Roact.PureComponent:extend(script.Name)

function Notifications:init()
    self.Active = true
    self:setState({
        ShouldWarnAboutHttpService = false;
        ShouldWarnAboutUpdate = false;
    })

    local core = self.props.Core
    if type(fastSpawn) ~= "function" or not core then
        return
    end

    fastSpawn(function ()
        local isVersionOutdated = core and core.IsVersionOutdated
        if not self.Active or type(isVersionOutdated) ~= "function" then
            return
        end
        local ok, IsOutdated = pcall(isVersionOutdated)
        if ok and self.Active then
            self:setState({
                ShouldWarnAboutUpdate = IsOutdated;
            })
        end
    end)
    fastSpawn(function ()
        local syncApi = core and core.SyncAPI
        if not self.Active or not syncApi or type(syncApi.Invoke) ~= "function" then
            return
        end
        local ok, IsHttpServiceDisabled = pcall(function ()
            return (core.Mode == 'Tool') and not syncApi:Invoke('IsHttpServiceEnabled')
        end)
        if ok and self.Active then
            self:setState({
                ShouldWarnAboutHttpService = IsHttpServiceDisabled;
            })
        end
    end)
end

function Notifications:willUnmount()
    self.Active = false
end

function Notifications:render()
    return new('ScreenGui', {}, {
        Container = new('Frame', {
            AnchorPoint = Vector2.new(0.5, 0.5);
            BackgroundTransparency = 1;
            Position = UDim2.new(0.5, 0, 0.5, 0);
            Size = UDim2.new(0, 300, 1, 0);
        }, {
            Layout = new('UIListLayout', {
                Padding = UDim.new(0, 10);
                FillDirection = Enum.FillDirection.Vertical;
                HorizontalAlignment = Enum.HorizontalAlignment.Left;
                VerticalAlignment = Enum.VerticalAlignment.Center;
                SortOrder = Enum.SortOrder.LayoutOrder;
            });
            UpdateNotification = (self.state.ShouldWarnAboutUpdate or nil) and new(NotificationDialog, {
                LayoutOrder = 1;
                ThemeColor = Color3.fromRGB(255, 170, 0);
                NoticeText = 'This version of Building Tools is <b>outdated.</b>';
                DetailText = (self.props.Core.Mode == 'Plugin') and
                    'To update plugins, go to\n<b>PLUGINS</b> > <b>Manage Plugins</b> :-)' or
                    'Own this place? Simply <b>reinsert</b> the Building Tools model.';
                OnDismiss = function ()
                    self:setState({
                        ShouldWarnAboutUpdate = false;
                    })
                end;
            });
            HTTPEnabledNotification = (self.state.ShouldWarnAboutHttpService or nil) and new(NotificationDialog, {
                LayoutOrder = 0;
                ThemeColor = Color3.fromRGB(255, 0, 4);
                NoticeText = 'HTTP requests must be <b>enabled</b> for some features of Building Tools to work, including exporting.';
                DetailText = 'Own this place? Edit it in Studio, and toggle on\nHOME > <b>Game Settings</b> > Security > <b>Allow HTTP Requests</b> :-)';
                OnDismiss = function ()
                    self:setState({
                        ShouldWarnAboutHttpService = false;
                    })
                end;
            });
        });
    })
end

return Notifications