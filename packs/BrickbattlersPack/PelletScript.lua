--!strict
--[[
	PelletScript — Script, cloned into each slingshot pellet. Keep it Disabled.

	Behaviour is unchanged: 8 damage, two second life, and half the bite on every
	surface it touches until it is under 1 and gives up. The only edits are that
	the globals are locals now and the two-second wait is a `task.wait` rather
	than a hand-rolled loop over RunService.Stepped.

	── ONE THING LEFT ALONE, ON PURPOSE ─────────────────────────────────────────
	There is no team check here. The superball has one — `IsTeamMate` — and this
	does not, so a pellet hurts your own side and the superball does not. That is
	a real inconsistency between two weapons in the same pack, but which way to
	settle it is a design call rather than a repair: brickbattle with friendly
	fire is a different game from brickbattle without it, and both are defensible.
	Say which and it is four lines.
]]

local Debris = game:GetService("Debris")

local pellet = script.Parent
local damage = 8
local connection: RBXScriptConnection? = nil

local function tagHumanoid(humanoid: Humanoid)
	local tag = pellet:FindFirstChild("creator")
	if not tag then
		return
	end

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

	local humanoid = hit.Parent:FindFirstChildOfClass("Humanoid")
	if humanoid then
		tagHumanoid(humanoid)
		humanoid:TakeDamage(damage)
		return
	end

	damage /= 2
	if damage < 1 then
		if connection then
			connection:Disconnect()
		end
		pellet:Destroy()
	end
end

connection = pellet.Touched:Connect(onTouched)

task.wait(2)
if pellet.Parent then
	pellet:Destroy()
end
