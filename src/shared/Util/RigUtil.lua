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

--[[
	Turns every Motor6D the right way round, and returns how many were backwards.

	── WHY A BACKWARDS JOINT IS INVISIBLE AND FATAL ────────────────────────────
	Roblox's animator does not read joint NAMES. For every Motor6D in the rig it
	takes `Part1` to be the bone, and it drives the pose whose name matches that
	part. So a shoulder wired

	    Part0 = Left Arm   Part1 = Torso

	presents itself to the animator as a bone called "Torso" hanging off the left
	arm. An R6 walk clip keys "Left Arm", finds no bone by that name, and moves
	the shoulder not at all — while every other joint in the rig animates
	normally. The result is a body that walks with one arm nailed to its side, or
	with nothing but its arms moving, or that simply drags.

	Nothing else here could catch it. The joint EXISTS, so buildMissingJoints
	correctly declines to build a second one over the top of it; the parts are
	all named correctly, so the missing-part report says nothing; the rig holds
	together and reports itself rigged. mapMotorChildren has always known which
	end is really the child — it walks outward from the HumanoidRootPart rather
	than trusting the convention — but knowing was only ever used to ANSWER
	questions about the rig, never to correct it.

	── THE SWAP IS EXACT, NOT APPROXIMATE ──────────────────────────────────────
	A Motor6D holds its two ends so that

	    Part0.CFrame * C0 == Part1.CFrame * C1

	Exchanging the parts and exchanging C0 with C1 turns that into

	    Part1.CFrame * C1 == Part0.CFrame * C0

	which is the same equation. So the limb does not move by so much as a stud:
	whatever pose the rig was built in is the pose it keeps, at any size and any
	proportion, with no pivot to guess at.

	The motor's Parent is deliberately left alone. The convention is to store a
	joint inside Part0, but the animator collects motors by walking the whole
	model, so where one lives changes nothing — and a rig that stores its joints
	on the child part is a wiring this already handles rather than a fault.
]]
function RigUtil.normalizeMotorDirection(model: Model): (number, { string })
	local flipped = 0
	local names: { string } = {}

	for motor, child in RigUtil.mapMotorChildren(model) do
		if motor.Part1 == child then
			continue
		end
		--[[ The resolved child has to actually BE the other endpoint. It always
		     is for a motor the walk reached, and for one it did not the map falls
		     back to Part1 — which the test above has already skipped. This is the
		     guard for neither of those being true rather than a case to handle. ]]
		if motor.Part0 ~= child then
			continue
		end

		--[[ Read all four before writing any: `motor.Part0 = motor.Part1` first
		     would leave the second assignment reading the value it just wrote and
		     put both ends on the same part. ]]
		local part0, part1 = motor.Part0, motor.Part1
		local c0, c1 = motor.C0, motor.C1
		motor.Part0 = part1
		motor.Part1 = part0
		motor.C0 = c1
		motor.C1 = c0

		flipped += 1
		table.insert(names, child.Name)
	end

	return flipped, names
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

--[[
	The standard skeletons, parent -> child, with each joint's pivot expressed in
	the PARENT's own space as fractions of its size.

	Fractions rather than studs so a half-scale Common and a Tank at 2.35 both get
	their shoulder in the right place without a table per size.
]]
local R6_SKELETON = table.freeze({
	table.freeze({ joint = "RootJoint", parent = "HumanoidRootPart", child = "Torso", at = Vector3.zero }),
	table.freeze({ joint = "Neck", parent = "Torso", child = "Head", at = Vector3.new(0, 0.5, 0) }),
	table.freeze({
		joint = "Left Shoulder",
		parent = "Torso",
		child = "Left Arm",
		at = Vector3.new(-0.5, 0.25, 0),
	}),
	table.freeze({
		joint = "Right Shoulder",
		parent = "Torso",
		child = "Right Arm",
		at = Vector3.new(0.5, 0.25, 0),
	}),
	table.freeze({
		joint = "Left Hip",
		parent = "Torso",
		child = "Left Leg",
		at = Vector3.new(-0.25, -0.5, 0),
	}),
	table.freeze({
		joint = "Right Hip",
		parent = "Torso",
		child = "Right Leg",
		at = Vector3.new(0.25, -0.5, 0),
	}),
})

local R15_SKELETON = table.freeze({
	table.freeze({ joint = "Root", parent = "HumanoidRootPart", child = "LowerTorso", at = Vector3.zero }),
	table.freeze({
		joint = "Waist",
		parent = "LowerTorso",
		child = "UpperTorso",
		at = Vector3.new(0, 0.5, 0),
	}),
	table.freeze({ joint = "Neck", parent = "UpperTorso", child = "Head", at = Vector3.new(0, 0.5, 0) }),
	table.freeze({
		joint = "LeftShoulder",
		parent = "UpperTorso",
		child = "LeftUpperArm",
		at = Vector3.new(-0.5, 0.4, 0),
	}),
	table.freeze({
		joint = "LeftElbow",
		parent = "LeftUpperArm",
		child = "LeftLowerArm",
		at = Vector3.new(0, -0.5, 0),
	}),
	table.freeze({
		joint = "LeftWrist",
		parent = "LeftLowerArm",
		child = "LeftHand",
		at = Vector3.new(0, -0.5, 0),
	}),
	table.freeze({
		joint = "RightShoulder",
		parent = "UpperTorso",
		child = "RightUpperArm",
		at = Vector3.new(0.5, 0.4, 0),
	}),
	table.freeze({
		joint = "RightElbow",
		parent = "RightUpperArm",
		child = "RightLowerArm",
		at = Vector3.new(0, -0.5, 0),
	}),
	table.freeze({
		joint = "RightWrist",
		parent = "RightLowerArm",
		child = "RightHand",
		at = Vector3.new(0, -0.5, 0),
	}),
	table.freeze({
		joint = "LeftHip",
		parent = "LowerTorso",
		child = "LeftUpperLeg",
		at = Vector3.new(-0.5, -0.5, 0),
	}),
	table.freeze({
		joint = "LeftKnee",
		parent = "LeftUpperLeg",
		child = "LeftLowerLeg",
		at = Vector3.new(0, -0.5, 0),
	}),
	table.freeze({
		joint = "LeftAnkle",
		parent = "LeftLowerLeg",
		child = "LeftFoot",
		at = Vector3.new(0, -0.5, 0),
	}),
	table.freeze({
		joint = "RightHip",
		parent = "LowerTorso",
		child = "RightUpperLeg",
		at = Vector3.new(0.5, -0.5, 0),
	}),
	table.freeze({
		joint = "RightKnee",
		parent = "RightUpperLeg",
		child = "RightLowerLeg",
		at = Vector3.new(0, -0.5, 0),
	}),
	table.freeze({
		joint = "RightAnkle",
		parent = "RightLowerLeg",
		child = "RightFoot",
		at = Vector3.new(0, -0.5, 0),
	}),
})

local function namedPart(model: Model, name: string): BasePart?
	local found = model:FindFirstChild(name, true)
	return if found and found:IsA("BasePart") then found else nil
end

--[[
	"R6" or "R15", by the one test the whole game agrees on.

	AnimationConfig.rigOf is this function; it forwards here rather than keeping
	its own copy, because the skeleton a repair BUILDS and the clip set that will
	be PLAYED on it have to be the same answer. Two independent expressions —
	even two identical ones — is a pair that can disagree, and the failure mode is
	the worst one this system has: an animation addresses NAMED joints, so a set
	aimed at the wrong build loads, reports itself as playing, and moves nothing.
	Worse, InfectedPoseController stands down for any body with tracks playing, so
	such a body is animated by neither.

	── WHY IT SEARCHES, AND WHY IT SKIPS ACCESSORIES ───────────────────────────
	This was a shallow FindFirstChild, on the reasoning that a rig's own torso is
	a direct child of the model. That is true of a rig Roblox built and routinely
	false of one a person assembled: parts get grouped into a Folder or a nested
	Model while it is being put together, and nobody moves them back out because
	nothing in Studio cares. The shallow test then calls a perfectly good R15 rig
	an R6 one and hands it R6 clips, which is the silent failure above.

	It looks anywhere now, except inside an Accessory — a hat or a backpack can
	carry a part named anything at all, and an accessory named UpperTorso must not
	decide what the body underneath it animates with. PlaceholderFactory's own
	joint audit already searched recursively, so this also ends a disagreement
	where the audit judged a rig R15 and the animator judged the same rig R6.
]]
function RigUtil.rigTypeOf(model: Model): (string, string?)
	for _, descendant in model:GetDescendants() do
		if not descendant:IsA("BasePart") then
			continue
		end
		local name = descendant.Name
		if name ~= "UpperTorso" and name ~= "LowerTorso" then
			continue
		end
		if not descendant:FindFirstAncestorWhichIsA("Accessory") then
			--[[ WHICH part decided it, returned alongside the verdict.

			     This is a positive test with one piece of evidence behind it, and
			     that evidence is worth handing back rather than throwing away.
			     The verdict picks the clip set, so getting it wrong is the
			     quietest failure in the game — the tracks load, report themselves
			     playing, move nothing, and the procedural poser stands down
			     because tracks are playing. When somebody who built an R6 rig
			     reads "R15" in the boot summary, the only useful next word is the
			     name of the part that said so: one stray mesh called LowerTorso,
			     inside a model that is R6 in every other respect, is the whole
			     bug and is otherwise invisible.

			     R6 is the ABSENCE of that evidence, so it has none to give and
			     returns nil. ]]
			return "R15", name
		end
	end
	return "R6", nil
end

--[[
	Builds whatever standard joints a rig is missing, and returns how many.

	── WHY THIS EXISTS AT RUNTIME AND NOT ONLY IN A STUDIO SCRIPT ──────────────
	A model with no Motor6Ds is a pile of loose parts: the Humanoid holds the
	root up at hip height and everything else falls or hangs where it was placed.
	The first answer to that was to WELD the parts to the root, which stops the
	body coming apart — and produces a body that can never animate, because an
	AnimationTrack drives Motor6Ds and a weld is not one. Half a fix.

	These are the same joints, built the same way. A rig repaired here holds
	together AND plays the zombie set, so a model somebody forgot to rig is a
	model that looks slightly stiff rather than one that is visibly broken.

	── IT CANNOT MOVE A LIMB ───────────────────────────────────────────────────
	A Motor6D holds Part1 at `Part0.CFrame * C0 * C1:Inverse()`. Deriving BOTH C0
	and C1 from the same world pivot makes that expression evaluate to exactly
	the limb's current CFrame, so whatever pose the parts are in is the pose they
	keep — at any size and any proportion.

	Welds between two parts it is about to joint are removed first. That is
	usually WHY the model has no joints (built by dragging parts together, and
	Studio welded them), and a weld left in place beside a Motor6D wins.
]]
function RigUtil.buildMissingJoints(model: Model): (number, { string })
	local have: { [string]: boolean } = {}
	for _, child in RigUtil.mapMotorChildren(model) do
		have[child.Name] = true
	end

	local skeleton = if RigUtil.rigTypeOf(model) == "R15" then R15_SKELETON else R6_SKELETON
	local built = 0
	--[[ Part names a joint needed and the model does not have. See the note where
	     these are collected. ]]
	local unbuildable: { string } = {}

	for _, spec in skeleton do
		if have[spec.child] then
			continue
		end
		local parent = namedPart(model, spec.parent)
		local child = namedPart(model, spec.child)
		--[[
			A missing PART cannot be jointed, and the caller is told which.

			Sometimes that is fine: plenty of rigs have no separate hands or feet,
			and inventing one would be worse than leaving the joint out. Sometimes
			it is the whole problem — an animation addresses JOINTS, and a joint
			cannot exist without the two parts it connects, so a model whose arm
			is called "LeftArm" or "Arm.L" instead of "Left Arm" gets no shoulder,
			plays a walk clip that drives a shoulder it does not have, and moves
			nothing. From the outside those two look identical, so the names go
			back to the caller and it decides what to say about them.
		]]
		if not parent then
			table.insert(unbuildable, spec.parent)
			continue
		end
		if not child then
			table.insert(unbuildable, spec.child)
			continue
		end

		for _, joint in child:GetJoints() do
			if joint:IsA("WeldConstraint") or joint:IsA("Weld") or joint:IsA("Snap") then
				joint:Destroy()
			end
		end

		local offset =
			Vector3.new(spec.at.X * parent.Size.X, spec.at.Y * parent.Size.Y, spec.at.Z * parent.Size.Z)
		local pivot = parent.CFrame * CFrame.new(offset)

		local motor = Instance.new("Motor6D")
		motor.Name = spec.joint
		motor.Part0 = parent
		motor.Part1 = child
		motor.C0 = parent.CFrame:ToObjectSpace(pivot)
		motor.C1 = child.CFrame:ToObjectSpace(pivot)
		motor.Parent = parent
		built += 1
	end

	return built, unbuildable
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
