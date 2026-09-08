--!strict
--[[
	WallMakerClient — LocalScript, inside ClassicTrowel. Says where to build.

	Replaces the tool's `Client`, which existed only to answer MouseLoc:

	    MouseLoc.OnClientInvoke = function()
	        return game.Players.LocalPlayer:GetMouse().Hit.p
	    end

	The server used to ask for a position with MouseLoc:InvokeClient and yield
	until that answer came back; now the client volunteers one and the server
	checks it. Same information, no thread parked waiting on somebody else's
	machine.

	Delete both the old `Client` and the `MouseLoc` RemoteFunction once this is
	in. Neither does anything afterwards, and a RemoteFunction still sitting in
	the tool is a hang still available to whatever calls it next.
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
