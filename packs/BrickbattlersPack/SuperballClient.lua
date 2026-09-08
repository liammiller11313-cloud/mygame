--!strict
--[[
	SuperballClient — LocalScript, inside ClassicSuperball. Replaces `Client`.

	Identical in shape to SlingshotClient: this machine volunteers where it is
	aiming instead of being asked for it, so the server never waits on it.

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
