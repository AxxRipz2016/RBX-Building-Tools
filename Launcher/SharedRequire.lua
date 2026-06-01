--[[
	require(script.Parent.X) не работает после loadstring с GitHub.
	RemoteEntry задаёт _G.BT_LAUNCHER_LOAD до загрузки модулей.
]]
return function(moduleName: string)
	if _G.BT_LAUNCHER_LOAD then
		return _G.BT_LAUNCHER_LOAD("Launcher/" .. moduleName .. ".lua")
	end
	local parent = script and script.Parent
	if parent then
		return require(parent[moduleName])
	end
	error("[BT] SharedRequire: нет BT_LAUNCHER_LOAD и script.Parent", 0)
end
