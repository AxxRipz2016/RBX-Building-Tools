--[[
	Общее состояние между клиентскими LocalScript'ами лаунчера.
]]
local Session = {}

Session.Tool = nil :: Tool?
Session.Core = nil
Session.Loaded = false
Session.LauncherGui = nil :: ScreenGui?

return Session
