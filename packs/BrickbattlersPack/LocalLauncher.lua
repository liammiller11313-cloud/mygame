--!strict
--[[
	LocalLauncher — LocalScript, inside RocketLauncher. Asks to fire.

	The original reached into ReplicatedStorage for a shared, globally reachable
	RemoteEvent. This one uses the tool's own, and the cooldown it keeps is now
	only a courtesy that stops the button spamming packets — ServerLauncher holds
	the cooldown that actually decides anything.
]]

local Players = game:GetService("Players")

local player = Players.LocalPlayer
local tool = script.Parent

local COOLDOWN = 3
local REMOTE_WAIT = 10

local remote = tool:WaitForChild("RocketFire", REMOTE_WAIT) :: RemoteEvent?
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

	readyAt = now + COOLDOWN
	remote:FireServer(mouse.Hit.Position)
end)
