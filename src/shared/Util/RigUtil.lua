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

--[[
	Which end of every Motor6D in a rig is the CHILD, resolved by walking the rig.

	The convention is Part0 = parent, Part1 = child, and the motor lives inside
	Part0. Real rigs break that in at least three ways, and a heuristic that
	handles one of them gets another wrong:

	    A  conventional          Parent=Torso  Part0=Torso  Part1=Left Arm
	    B  reversed endpoints    Parent=Torso  Part0=Left Arm  Part1=Torso
	    C  motor stored on the   Parent=Head   Part0=UpperTorso  Part1=Head
	       child part

	Reading Part1 gets B wrong. "The endpoint that is not the motor's Parent"
	gets A and B right and C exactly backwards — it names UpperTorso as the child
	of the neck, which is why a rig with a perfectly good head reported its head
	joint missing and refused to decapitate.

	None of that is guessable from one motor in isolation, so this does not
	guess. It walks the joint graph outward from the HumanoidRootPart: whichever
	endpoint is reached FIRST is the parent and the other is the child, because
	that is what parent and child mean. Every wiring above falls out of it
	correctly, including ones nobody has thought of.

	Returns a map so the walk is paid for once per rig rather than once per
	joint — every caller here wants the whole rig anyway.
]]
function RigUtil.mapMotorChildren(model: Model): { [Motor6D]: BasePart }
	local motors = RigUtil.getMotors(model)
	local children: { [Motor6D]: BasePart } = {}
	if #motors == 0 then
		return children
	end

	--[[ Every motor touching a given part, so the walk can step outward without
	     rescanning the list at each node. ]]
	local touching: { [BasePart]: { Motor6D } } = {}
	for _, motor in motors do
		local part0, part1 = motor.Part0, motor.Part1
		if part0 and part1 and part0 ~= part1 then
			touching[part0] = touching[part0] or {}
			touching[part1] = touching[part1] or {}
			table.insert(touching[part0], motor)
			table.insert(touching[part1], motor)
		end
	end

	local root = RigUtil.getRoot(model)
	if not root then
		return children
	end

	local seen: { [BasePart]: boolean } = { [root] = true }
	local queue: { BasePart } = { root }
	local head = 1
	while head <= #queue do
		local part = queue[head]
		head += 1
		for _, motor in touching[part] or {} do
			if children[motor] then
				continue
			end
			--[[ We arrived at `part`, so `part` is this joint's parent end and
			     whatever is on the other side of it is the child. ]]
			local other = if motor.Part0 == part then motor.Part1 else motor.Part0
			if other and not seen[other] then
				seen[other] = true
				children[motor] = other
				table.insert(queue, other)
			end
		end
	end

	--[[ Anything the walk never reached is a joint on a limb that is not
	     connected to the root at all. It still has to resolve to SOMETHING or it
	     silently disappears from every lookup, so it falls back to the
	     convention — and a rig in that state has bigger problems, which
	     PlaceholderFactory's audit is what reports. ]]
	for _, motor in motors do
		if not children[motor] and motor.Part1 then
			children[motor] = motor.Part1
		end
	end

	return children
end

--[[ The child end of ONE motor, for a caller that has a motor and not a rig.
     Prefer mapMotorChildren when you are about to ask about several. ]]
function RigUtil.motorChild(motor: Motor6D): BasePart?
	local model = motor:FindFirstAncestorOfClass("Model")
	if model then
		local resolved = RigUtil.mapMotorChildren(model)[motor]
		if resolved then
			return resolved
		end
	end
	return motor.Part1
end

--[[ The Motor6D that attaches a named part to its parent, or nil. Severing a
     limb is exactly "destroy this motor and let physics take over". Resolves the
     child end rather than reading Part1 — see RigUtil.motorChild. ]]
function RigUtil.findMotorForPart(model: Model, partName: string): Motor6D?
	for motor, child in RigUtil.mapMotorChildren(model) do
		if child.Name == partName then
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
