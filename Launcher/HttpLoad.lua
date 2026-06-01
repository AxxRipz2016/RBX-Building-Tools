--[[
	Для Rojo (require из Launcher). Тот же стиль, что и в RemoteEntry.
]]
local HttpLoad = {}

function HttpLoad.get(url: string): string
	return game:HttpGet(url, true)
end

function HttpLoad.run(url: string, chunkName: string?): ...any
	return loadstring(game:HttpGet(url, true), chunkName or url)()
end

return HttpLoad
