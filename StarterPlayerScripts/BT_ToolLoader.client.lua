--[[
	Клиент: запрос Tool с сервера и ожидание флага Loaded.
	Запускается после UILoader (имя файла позже в алфавите — Tool после UI).
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")

task.wait(0.1)

local Bootstrap = require(ReplicatedStorage:WaitForChild("BT"):WaitForChild("Launcher"):WaitForChild("Bootstrap"))
Bootstrap.RunToolSetup()
