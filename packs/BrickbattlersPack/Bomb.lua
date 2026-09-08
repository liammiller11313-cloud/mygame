--!strict
--[[
	Bomb — Script, cloned into each planted timebomb. Keep it Disabled.

	No tag bug either. What it had was a tag that never went away.

	── THE TAG THAT OUTLIVED THE BOMB ───────────────────────────────────────────
	    -- tag does not need to expire iff all explosions lethal
	    local new_tag = creator:clone()
	    new_tag.Parent = humanoid

	`untagHumanoid` sat directly underneath it and was never called from
	anywhere. So the comment's "iff" was the load-bearing word and it was not
	true: anybody who lived through the blast — standing at the edge of the
	twelve stud radius, or simply tougher than the bomb expected — walked away
	wearing the bomber's name permanently. Their next death, to anything at all,
	credited the bomber. The tag expires on a Debris timer now, the same second
	every other weapon in this pack uses, and the dead function is gone.

	── AND THE SAME CRASH THE ROCKET HAD ────────────────────────────────────────
	`part.Parent.Humanoid` threw on any part in the world named "Head" whose
	parent has no Humanoid, which an explosion radius will find sooner or later.

	── WORTH CHECKING WHEN YOU TEST ─────────────────────────────────────────────
	Both sound ids are legacy paths with backslashes in them:

	    rbxasset://sounds\clickfast.wav
	    rbxasset://sounds\Rocket shot.wav

	They are left exactly as they were, because guessing replacement asset ids
	would be inventing content. If the bomb ticks silently, that is why — and it
	is two SoundId strings to fix, not a code problem.

	Everything else is untouched: the accelerating tick, the two-colour flash,
	the twelve stud radius and the very enthusiastic blast pressure.
]]

local Debris = game:GetService("Debris")

local bomb = script.Parent

local TICK_START = 0.4
local TICK_ACCEL = 0.9
local TICK_FLOOR = 0.1
local BLAST_RADIUS = 12
local BLAST_PRESSURE = 1000000
local TAG_LIFETIME = 1
local COLORS = { 26, 21 }

local tickSound = Instance.new("Sound")
tickSound.SoundId = "rbxasset://sounds\\clickfast.wav"
tickSound.Parent = bomb

local function tagHumanoid(humanoid: Humanoid, creator: Instance)
	local fresh = creator:Clone()
	fresh.Parent = humanoid
	--[[ The line the original was missing. Its own comment said the tag need not
	     expire "iff all explosions lethal", and untagHumanoid was written and
	     never called — so a survivor kept it forever. ]]
	Debris:AddItem(fresh, TAG_LIFETIME)
end

local function onBlownUp(part: BasePart, creator: Instance)
	if part.Name ~= "Head" then
		return
	end
	local humanoid = part.Parent and part.Parent:FindFirstChildOfClass("Humanoid")
	if humanoid then
		tagHumanoid(humanoid, creator)
	end
end

local function blowUp()
	local sound = Instance.new("Sound")
	sound.SoundId = "rbxasset://sounds\\Rocket shot.wav"
	sound.Volume = 1
	sound.Parent = bomb
	sound:Play()

	local explosion = Instance.new("Explosion")
	explosion.BlastRadius = BLAST_RADIUS
	explosion.BlastPressure = BLAST_PRESSURE
	explosion.Position = bomb.Position

	local creator = bomb:FindFirstChild("creator")
	if creator then
		explosion.Hit:Connect(function(part: BasePart)
			onBlownUp(part, creator)
		end)
	end

	explosion.Parent = workspace
	bomb.Transparency = 1
end

local interval = TICK_START
local color = 1
while interval > TICK_FLOOR do
	task.wait(interval)
	interval *= TICK_ACCEL
	bomb.BrickColor = BrickColor.new(COLORS[color])
	color = if color >= #COLORS then 1 else color + 1
	tickSound:Play()
end

blowUp()
task.wait(2)
bomb:Destroy()
