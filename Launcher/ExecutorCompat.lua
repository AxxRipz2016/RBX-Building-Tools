--[[
	В executor: loadstring снаружи работает, внутри скачанного чанка — часто нет.
	Берём loadstring/load из getgenv / getrenv.
]]
local ExecutorCompat = {}

local function tryGet(from: () -> any?, key: string)
	local ok, env = pcall(from :: any)
	if ok and type(env) == "table" and env[key] then
		return env[key]
	end
	return nil
end

function ExecutorCompat.getLoad()
	local fromGenv = tryGet(getgenv, "loadstring") or tryGet(getgenv, "load")
	if fromGenv then
		return fromGenv
	end
	local fromRenv = tryGet(getrenv, "loadstring") or tryGet(getrenv, "load")
	if fromRenv then
		return fromRenv
	end
	return loadstring
end

function ExecutorCompat.getHttpGet()
	local request = tryGet(getgenv, "http_request") or tryGet(getgenv, "request")
	if request then
		return function(url: string): string
			local response = request({
				Url = url,
				Method = "GET",
			})
			if type(response) == "table" then
				return response.Body or response.body or ""
			end
			return tostring(response)
		end
	end

	return function(url: string): string
		return game:HttpGet(url, true)
	end
end

function ExecutorCompat.loadUrl(url: string, chunkName: string?): ...any
	local loadFn = ExecutorCompat.getLoad()
	local httpGet = ExecutorCompat.getHttpGet()
	return loadFn(httpGet(url), chunkName or url)()
end

return ExecutorCompat
