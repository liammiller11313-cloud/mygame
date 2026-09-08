--!strict
--[[
	SwordScript — Script, inside ClassicSword.

	Originally rescripted by Luckymaxer, updated for R15 by StarWars, re-updated
	by TakeoHonorable. Attribution kept because it is theirs.

	── NO SECURITY WORK NEEDED, AND THAT IS WORTH SAYING ────────────────────────
	Alone in this pack, the sword needed none. It has no RemoteEvent and no
	RemoteFunction: it runs entirely off Tool.Activated and Handle.Touched, both
	of which the engine raises only for the character actually holding it. There
	is no packet to forge and no thread to park. It even checks the RightGrip
	weld before it will damage anything, which is a check the other six do not
	make. It is the best-behaved script of the seven.

	It just has never dealt its slash damage.

	── THE SLASH HAS ALWAYS DONE 5 ──────────────────────────────────────────────
	    if (Tick - LastAttack < 0.2) then Lunge() else Attack() end
	    LastAttack = Tick
	    --wait(0.5)
	    Damage = DamageValues.BaseDamage

	Attack() sets Damage to SlashDamage and returns without yielding. The very
	next line puts it back to BaseDamage. So the window in which a slash is worth
	10 is zero frames wide, and every slash this sword has ever landed did 5.
	DamageValues.SlashDamage has been dead config.

	The commented-out `wait(0.5)` above it is the original, and putting it back
	would fix the slash and break the lunge instead: Tool.Enabled stays false for
	the length of that wait, and the lunge is triggered by a SECOND click inside
	0.2 seconds — which you cannot make if the tool is disabled for half a
	second. Whoever removed the wait was fixing that, and traded one bug for the
	other.

	Both work now because the damage window stopped being the same thing as the
	cooldown. Damage reverts on its own timer, tokened so a lunge started during
	a slash's window is not dropped back to 5 when that window expires, and
	Tool.Enabled goes back immediately after a slash so the double-click still
	lands. The lunge still holds the tool for the length of its grip animation,
	which is where its cooldown always was.

	── THE FIRST R15 SWING WAS SILENT ───────────────────────────────────────────
	The Animation objects were created at the END of Activated, after the attack
	that wanted them had already run — so `Tool:FindFirstChild("R15Slash")` was
	nil on the first swing and every R15 player's opening slash played nothing.
	They are built once, at load.

	Untouched: 5 / 10 / 30, the two grips, the three sounds, the team and self
	checks, the RightGrip weld test, R6's toolanim path, and the particle rate
	bump for the Omega Rainbow Katana thumbnail.
]]

local Players = game:GetService("Players")
local Debris = game:GetService("Debris")

local Tool = script.Parent
local Handle = Tool:WaitForChild("Handle")

local DAMAGE = {
	Base = 5,
	Slash = 10,
	Lunge = 30,
}

--[[ How long each attack is worth more than a poke. The slash window is the
     `wait(0.5)` from the original, moved off the cooldown; the lunge's matches
     the 0.2 + 0.6 its grip animation already took. ]]
local SLASH_WINDOW = 0.5
local LUNGE_WINDOW = 0.8
local DOUBLE_CLICK = 0.2

local GRIPS = {
	Up = CFrame.new(0, 0, -1.70000005, 0, 0, 1, 1, 0, 0, 0, 1, 0),
	Out = CFrame.new(0, 0, -1.70000005, 0, 1, 0, 1, -0, 0, 0, 0, -1),
}

local SOUNDS = {
	Slash = Handle:WaitForChild("SwordSlash") :: Sound,
	Lunge = Handle:WaitForChild("SwordLunge") :: Sound,
	Unsheath = Handle:WaitForChild("Unsheath") :: Sound,
}

-- Built once, at load, so the first R15 swing has something to play.
local function animation(name: string, id: number): Animation
	local existing = Tool:FindFirstChild(name)
	if existing and existing:IsA("Animation") then
		return existing
	end
	local anim = Instance.new("Animation")
	anim.Name = name
	anim.AnimationId = "rbxassetid://" .. id
	anim.Parent = Tool
	return anim
end
local SLASH_ANIM = animation("R15Slash", 522635514)
local LUNGE_ANIM = animation("R15Lunge", 522638767)

local damage = DAMAGE.Base
local attackToken = 0

local equipped = false
local character: Model? = nil
local player: Player? = nil
local humanoid: Humanoid? = nil
local torso: BasePart? = nil

for _, child in Handle:GetChildren() do
	if child:IsA("ParticleEmitter") then
		child.Rate = 20
	end
end

Tool.Grip = GRIPS.Up
Tool.Enabled = true

local function isAlive(): boolean
	return player ~= nil
		and player.Parent ~= nil
		and character ~= nil
		and character.Parent ~= nil
		and humanoid ~= nil
		and humanoid.Parent ~= nil
		and humanoid.Health > 0
		and torso ~= nil
		and torso.Parent ~= nil
end

local function isTeamMate(a: Player?, b: Player?): boolean
	return a ~= nil and b ~= nil and not a.Neutral and not b.Neutral and a.TeamColor == b.TeamColor
end

--[[ Raises the sword's bite for a while, then puts it back.

     The token is what lets a lunge interrupt a slash. Without it the slash's
     half-second timer would land mid-lunge and drop it from 30 to 5 — which is
     exactly the class of bug the original had, just moved. ]]
local function biteFor(amount: number, duration: number)
	attackToken += 1
	local mine = attackToken
	damage = amount
	task.delay(duration, function()
		if attackToken == mine then
			damage = DAMAGE.Base
		end
	end)
end

local function play(anim: Animation, r6Name: string)
	if not humanoid then
		return
	end
	if humanoid.RigType == Enum.HumanoidRigType.R6 then
		local marker = Instance.new("StringValue")
		marker.Name = "toolanim"
		marker.Value = r6Name
		marker.Parent = Tool
		return
	end
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if animator then
		animator:LoadAnimation(anim):Play(0)
	end
end

local function onTouched(hit: BasePart)
	if not hit or not hit.Parent or not equipped or not isAlive() then
		return
	end

	--[[ The sword has to actually be in a hand. This is the check the rest of
	     the pack does not make, and it is why a dropped sword lying on the floor
	     cannot hurt anyone who walks into it. ]]
	local arm = (character :: Model):FindFirstChild("Right Arm")
		or (character :: Model):FindFirstChild("RightHand")
	if not arm then
		return
	end
	local grip = arm:FindFirstChild("RightGrip") :: Weld?
	if not grip or (grip.Part0 ~= Handle and grip.Part1 ~= Handle) then
		return
	end

	local victimModel = hit.Parent
	if victimModel == character then
		return
	end
	local victim = victimModel:FindFirstChildOfClass("Humanoid")
	if not victim or victim.Health <= 0 then
		return
	end

	local victimPlayer = Players:GetPlayerFromCharacter(victimModel)
	if victimPlayer and (victimPlayer == player or isTeamMate(player, victimPlayer)) then
		return
	end

	for _, existing in victim:GetChildren() do
		if existing:IsA("ObjectValue") and existing.Name == "creator" then
			existing:Destroy()
		end
	end

	local tag = Instance.new("ObjectValue")
	tag.Name = "creator"
	tag.Value = player
	tag.Parent = victim
	Debris:AddItem(tag, 2)

	victim:TakeDamage(damage)
end

local function attack()
	biteFor(DAMAGE.Slash, SLASH_WINDOW)
	SOUNDS.Slash:Play()
	play(SLASH_ANIM, "Slash")
end

local function lunge()
	biteFor(DAMAGE.Lunge, LUNGE_WINDOW)
	SOUNDS.Lunge:Play()
	play(LUNGE_ANIM, "Lunge")

	task.wait(0.2)
	Tool.Grip = GRIPS.Out
	task.wait(0.6)
	Tool.Grip = GRIPS.Up
end

local lastAttack = 0

Tool.Activated:Connect(function()
	if not Tool.Enabled or not equipped or not isAlive() then
		return
	end
	Tool.Enabled = false

	--[[ os.clock rather than a yield on RunService.Stepped. The original waited
	     a frame purely to get a timestamp, which cost every swing a frame of
	     input lag for a number it could have read for free. ]]
	local now = os.clock()
	if now - lastAttack < DOUBLE_CLICK then
		lunge() -- yields for its grip animation; that IS the lunge's cooldown
	else
		attack()
	end
	lastAttack = now

	Tool.Enabled = true
end)

Tool.Equipped:Connect(function()
	character = Tool.Parent :: Model
	player = Players:GetPlayerFromCharacter(character)
	humanoid = (character :: Model):FindFirstChildOfClass("Humanoid")
	torso = (character :: Model):FindFirstChild("Torso") :: BasePart?
		or (character :: Model):FindFirstChild("HumanoidRootPart") :: BasePart?
	if not isAlive() then
		return
	end
	equipped = true
	SOUNDS.Unsheath:Play()
end)

Tool.Unequipped:Connect(function()
	Tool.Grip = GRIPS.Up
	equipped = false
end)

Handle.Touched:Connect(onTouched)
