--[[
	Соло-лаунчер: только этот LocalScript + (опционально) Interfaces в Payload.
	В Config.lua выставь LoadMode = "Remote" и RemoteBaseUrl на raw GitHub.

	Минимальный ReplicatedStorage: BT.Launcher (модули лаунчера через Rojo).
	Без Payload — весь BT качается с GitHub в кэш.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local launcher = ReplicatedStorage:WaitForChild("BT"):WaitForChild("Launcher")
local Config = require(launcher.Config)

Config.LoadMode = "Remote"
-- RemoteBaseUrl уже в Launcher/Config.lua

local Bootstrap = require(launcher.Bootstrap)
Bootstrap.RunUI()
Bootstrap.RunToolSetup()
