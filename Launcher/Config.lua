--[[
	Настройки лаунчера для своего плейса.
	AllowedUserIds пустой = BT могут запросить все игроки.
]]
local Config = {}

Config.ToolName = "Building Tools"
Config.LauncherGuiName = "BT Launcher"

-- "Payload" = ReplicatedStorage.BT.Payload (Rojo)
-- "Remote" = HttpGet + кэш с GitHub (без Payload)
Config.LoadMode = "Payload"

-- Пример: https://raw.githubusercontent.com/USER/REPO/main/
Config.RemoteBaseUrl = ""

-- Пример: { 123456789 } — только эти UserId
Config.AllowedUserIds = {}

function Config.IsAllowed(player: Player): boolean
	if #Config.AllowedUserIds == 0 then
		return true
	end
	for _, userId in Config.AllowedUserIds do
		if player.UserId == userId then
			return true
		end
	end
	return false
end

return Config
