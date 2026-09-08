--!strict
--[[
	WallMakerClient — LocalScript, inside ClassicTrowel. Says where to build.

	This is the half that did not exist. The server used to ask the client for a
	position with MouseLoc:InvokeClient and yield until it answered; now the
	client volunteers one and the server checks it. Same information, no thread
	parked waiting on somebody else's machine.

	The old MouseLoc RemoteFunction can be deleted from the tool once this is in.
]]

local Players = game:GetService("Players")

local player = Players.LocalPlayer
local tool = script.Parent

local COOLDOWN = 5
local REMOTE_WAIT = 10

local remote = tool:WaitForChild("PlaceWall", REMOTE_WAIT) :: RemoteEvent?
local mouse: Mouse? = nil
local readyAt = 0

tool.Equipped:Connect(function(equippedMouse)
	mouse = equippedMouse or player:GetMouse()
end)

tool.Activated:Connect(function()
	if not remote or not mouse then
		return
	end
	local now = os.clock()
	if now < readyAt then
		return
	end
	readyAt = now + COOLDOWN
	remote:FireServer(mouse.Hit.Position)
end)
