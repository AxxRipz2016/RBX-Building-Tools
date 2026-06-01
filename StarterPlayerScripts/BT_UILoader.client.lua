--[[
	Клиент: окно лаунчера (кнопка «Получить инструмент»).
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Bootstrap = require(ReplicatedStorage:WaitForChild("BT"):WaitForChild("Launcher"):WaitForChild("Bootstrap"))
Bootstrap.RunUI()
