--[[
	Полностью клиентский лаунчер: Tool через Instance.new, без сервера.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local launcher = ReplicatedStorage:WaitForChild("BT"):WaitForChild("Launcher")
local Bootstrap = require(launcher.Bootstrap)

Bootstrap.RunUI()
Bootstrap.RunToolSetup()
