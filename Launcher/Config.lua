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

-- https://github.com/utststs95/RBX-Building-Tools (ветка development)
Config.RemoteBaseUrl = "https://raw.githubusercontent.com/utststs95/RBX-Building-Tools/refs/heads/development/"

-- Submodule Vendor/Roact не попадает на GitHub — качаем с upstream (версия rotriever.toml)
Config.RemoteVendorUrls = {
	["Vendor/Roact/"] = "https://raw.githubusercontent.com/Roblox/roact/v1.3.0/",
}

-- Меняй при push лаунчера (дублирует Version.lua для Rojo)
Config.LauncherVersion = "31"

-- Пример: { 123456789 } — только эти UserId
Config.AllowedUserIds = {247402615}

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
