--!strict
--[[
	SlingshotClient — LocalScript, inside ClassicSlingshot. Replaces `Client`.

	The old one answered MouseLoc:

	    MouseLoc.OnClientInvoke = function()
	        return game.Players.LocalPlayer:GetMouse().Hit.p
	    end

	which meant the SERVER was waiting on this machine every time the tool was
	used. Now this machine volunteers the aim and the server checks it, so a
	client that says nothing simply does not shoot — rather than leaving a server
	thread parked forever.

	Delete the MouseLoc RemoteFunction from the tool once this is in.
]]

local Players = game:GetService("Players")

local player = Players.LocalPlayer
local tool = script.Parent

local RELOAD = 6
local REMOTE_WAIT = 10

local remote = tool:WaitForChild("Shoot", REMOTE_WAIT) :: RemoteEvent?
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

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not character or not humanoid or humanoid.Health <= 0 then
		return
	end

	readyAt = now + RELOAD
	remote:FireServer(mouse.Hit.Position)
end)
