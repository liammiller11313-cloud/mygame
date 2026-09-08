--!strict
--[[
	CannonBall — Script, cloned into each superball. Keep it Disabled in the tool.

	── THE ONE LINE THAT HAD TO CHANGE ──────────────────────────────────────────
	    while (humanoid:FindFirstChild("creator")) do
	        humanoid:FindFirstChild("creator").Parent:Destroy()
	    end

	`humanoid:FindFirstChild("creator")` is the tag. Its `.Parent` is the
	HUMANOID. So that line destroyed the Humanoid of anybody who already carried
	a creator tag — and creator tags last one second, so "already carried one"
	means "was damaged by anyone in the last second", which in a brickbattle is
	most of the time two people are shooting at the same target.

	Destroying a Humanoid is worse than killing the character. Roblox drives
	respawn off `Humanoid.Died`, and a Humanoid that is destroyed rather than
	killed never fires it — so the player collapses and, depending on how the
	place handles respawns, may never come back. The `TakeDamage` call on the
	next line then runs against a destroyed instance.

	The slingshot's PelletScript has the same loop written correctly, which is
	how the difference shows: it does `.Parent = nil` on the TAG. This now
	destroys the tag, which is what the loop was always for.

	Everything else is untouched — 25 damage, the five second life, the team
	check, the halving decay per bounce, the 0.1s gate on the bounce sound.
]]

local Ball = script.Parent
local Debris = game:GetService("Debris")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local damage = 25
local lastSoundTime = RunService.Stepped:Wait()
local connection: RBXScriptConnection? = nil

local function isTeamMate(a: Player?, b: Player?): boolean
	return a ~= nil and b ~= nil and not a.Neutral and not b.Neutral and a.TeamColor == b.TeamColor
end

local function tagHumanoid(humanoid: Humanoid)
	local tag = Ball:FindFirstChild("creator")
	if not tag then
		return
	end

	-- The tag, not the thing it is attached to. See the header.
	local existing = humanoid:FindFirstChild("creator")
	while existing do
		existing:Destroy()
		existing = humanoid:FindFirstChild("creator")
	end

	local fresh = tag:Clone()
	fresh.Parent = humanoid
	Debris:AddItem(fresh, 1)
end

local function onTouched(hit: BasePart)
	if not hit or not hit.Parent then
		return
	end

	local now = RunService.Stepped:Wait()
	if now - lastSoundTime <= 0.1 then
		return
	end
	lastSoundTime = now

	local boing = Ball:FindFirstChild("Boing")
	if boing and boing:IsA("Sound") then
		boing:Play()
	end

	local humanoid = hit.Parent:FindFirstChildOfClass("Humanoid")
	local tag = Ball:FindFirstChild("creator") :: ObjectValue?

	if tag and humanoid then
		local victim = Players:GetPlayerFromCharacter(humanoid.Parent)
		if not isTeamMate(tag.Value :: Player?, victim) then
			tagHumanoid(humanoid)
			humanoid:TakeDamage(damage)
			if connection then
				connection:Disconnect()
			end
		end
		return
	end

	-- Bounced off the world. Every bounce costs half its bite.
	damage /= 2
	if damage < 2 and connection then
		connection:Disconnect()
	end
end

connection = Ball.Touched:Connect(onTouched)

task.wait(5)
Ball:Destroy()
