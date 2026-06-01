--[[
	Клиентский подсчёт потомков для флага Loaded (без серверных скриптов).
]]
local Count = script.Parent
local Tool = Count.Parent.Parent

task.defer(function()
	task.wait()
	Count.Value = #Tool:GetDescendants()
end)
