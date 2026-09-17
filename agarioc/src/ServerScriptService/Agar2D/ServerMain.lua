local Players = game:GetService("Players")
local StarterPlayer = game:GetService("StarterPlayer")

Players.CharacterAutoLoads = false

pcall(function()
	StarterPlayer.DevComputerMovementMode = Enum.DevComputerMovementMode.Scriptable
end)
pcall(function()
	StarterPlayer.DevTouchMovementMode = Enum.DevTouchMovementMode.Scriptable
end)
pcall(function()
	StarterPlayer.EnableMouseLockOption = false
end)

local GameService = require(script.Parent:WaitForChild("GameService"))

local service = GameService.new()
service:start()
