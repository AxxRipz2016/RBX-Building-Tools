local Config = require(script.Parent.Config)
local RemoteToolBuilder = require(script.Parent.RemoteToolBuilder)

local BTRuntime = {}

function BTRuntime.Start(tool: Tool)
	if Config.LoadMode == "Remote" then
		return RemoteToolBuilder.StartRuntime(tool)
	end

	local loader = tool:WaitForChild("Loader", 10)
	assert(loader and loader:IsA("ModuleScript"), "Building Tools: ModuleScript Loader не найден")
	return require(loader)
end

return BTRuntime
