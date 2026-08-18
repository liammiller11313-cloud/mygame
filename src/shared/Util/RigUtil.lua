--!strict
--[[
	RigUtil — everything the game needs to ask about a humanoid rig.

	Roblox gives you two rig layouts (R6 and R15) with completely different part
	names, and a bullet does not care which one it hit. Every question about a
	body — what region is this part, who owns it, is it already dead — goes
	through here so that no combat code ever has to branch on rig type.
]]

local Players = game:GetService("Players")

local GameConfig = require(script.Parent.Parent.Config.GameConfig)
local Enums = require(script.Parent.Parent.Enums)

local RigUtil = {}

--[[
	Which hit region a part belongs to. Unknown parts resolve to Torso, which is
	the 1.0x multiplier — an unrecognised accessory should never accidentally
	become a 4x headshot surface or a 0x freebie.
]]
function RigUtil.getHitRegion(part: BasePart): string
	local region = GameConfig.PartRegions[part.Name]
	if region then
		return region
	end
	-- Hats and cosmetics are welded to the head; treat a hit on one as a body
	-- shot rather than a headshot, so cosmetics can never widen a hitbox.
	return Enums.HitRegion.Torso
end

--[[
	Walks up from any part to the Model that owns it, if that model has a
	Humanoid. Returns nil for scenery. Bounded so a deeply nested part cannot
	walk all the way to DataModel.
]]
function RigUtil.getCharacterFromPart(part: BasePart): (Model?, Humanoid?)
	local current: Instance? = part
	local depth = 0
	while current and depth < 6 do
		if current:IsA("Model") then
			local humanoid = current:FindFirstChildOfClass("Humanoid")
			if humanoid then
				return current, humanoid
			end
		end
		current = current.Parent
		depth += 1
	end
	return nil, nil
end

--[[ True when a model is a survivor's character rather than an infected. ]]
function RigUtil.isSurvivor(model: Model): boolean
	return Players:GetPlayerFromCharacter(model) ~= nil
end

--[[ True when a model is an infected spawned by the game. ]]
function RigUtil.isInfected(model: Model): boolean
	return model:GetAttribute("FL_Kind") ~= nil and Players:GetPlayerFromCharacter(model) == nil
end

--[[ A humanoid that is alive and has not been flagged dead by the combat code.
     Checks the attribute too, because a body being ragdolled still has Health
     briefly and must not be shot again for more gore. ]]
function RigUtil.isAlive(model: Model): boolean
	if model:GetAttribute("FL_IsDead") == true then
		return false
	end
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.Health > 0
end

--[[ The primary part to aim at, measure from, or apply an impulse to. ]]
function RigUtil.getRoot(model: Model): BasePart?
	local root = model:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	if model.PrimaryPart then
		return model.PrimaryPart
	end
	return model:FindFirstChildWhichIsA("BasePart")
end

--[[ Every BasePart in a rig, excluding accessories. Used by the ragdoll and
     dismemberment code, which must not try to weld a hat. ]]
function RigUtil.getBodyParts(model: Model): { BasePart }
	local parts = {}
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") and not descendant:FindFirstAncestorWhichIsA("Accessory") then
			table.insert(parts, descendant)
		end
	end
	return parts
end

--[[ Every Motor6D in a rig. Ragdolling replaces these with constraints; the
     originals are kept so a body could in principle be un-ragdolled. ]]
function RigUtil.getMotors(model: Model): { Motor6D }
	local motors = {}
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("Motor6D") then
			table.insert(motors, descendant)
		end
	end
	return motors
end

--[[ The Motor6D that attaches a named part to its parent, or nil. Severing a
     limb is exactly "destroy this motor and let physics take over". ]]
function RigUtil.findMotorForPart(model: Model, partName: string): Motor6D?
	for _, motor in RigUtil.getMotors(model) do
		if motor.Part1 and motor.Part1.Name == partName then
			return motor
		end
	end
	return nil
end

--[[
	Makes every part of a rig non-collidable with players and unqueryable by
	raycasts. Applied to corpses and gibs so a pile of bodies never blocks a
	doorway, absorbs a bullet meant for a live target, or shoves a survivor off
	a ledge — all three are classic zombie-game failure modes.
]]
function RigUtil.makeDebris(model: Model)
	for _, part in RigUtil.getBodyParts(model) do
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.Massless = true
		part.CollisionGroup = "Debris"
	end
end

--[[ Sets every part's collision group in one call. ]]
function RigUtil.setCollisionGroup(model: Model, groupName: string)
	for _, part in RigUtil.getBodyParts(model) do
		part.CollisionGroup = groupName
	end
end

--[[ Scales a rig uniformly. Used for the Tank (2.35x) and the Boomer (1.35x),
     which read as different creatures largely because of their silhouette. ]]
function RigUtil.scaleRig(model: Model, scale: number)
	if scale == 1 then
		return
	end
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		-- R15 exposes scale as NumberValues the Humanoid honours automatically.
		for _, name in { "BodyDepthScale", "BodyHeightScale", "BodyWidthScale", "HeadScale" } do
			local value = humanoid:FindFirstChild(name)
			if value and value:IsA("NumberValue") then
				value.Value = scale
			end
		end
	end
end

--[[ Sum of every body part's mass, for impulse maths that should feel the same
     on a Common and a Tank rather than launching the light one into orbit. ]]
function RigUtil.getMass(model: Model): number
	local total = 0
	for _, part in RigUtil.getBodyParts(model) do
		total += part.AssemblyMass
	end
	return math.max(total, 0.01)
end

return RigUtil
