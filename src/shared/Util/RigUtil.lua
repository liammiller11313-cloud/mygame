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
--[[
	── THIS SEARCHES DESCENDANTS, AND IT HAS TO ────────────────────────────────
	It used to use FindFirstChild and FindFirstChildWhichIsA with no recursive
	flag, while rigTypeOf and namedPart in this same file search every descendant.
	That inconsistency was not cosmetic — it was the bug.

	Group a rig's parts into a Folder in Studio, which is a completely ordinary
	thing to do while assembling one, and this returned nil. mapMotorChildren then
	took its `if not root then return children end` exit and handed back an EMPTY
	joint map. buildMissingJoints reads that map to decide which joints already
	exist, found none, and — using namedPart, which IS deep and therefore found
	every part — built a SECOND COMPLETE SKELETON on top of the first. Two
	Motor6Ds on every pair, rebuilt on every spawn.

	A pair with two rigid joints is an over-constrained assembly. The animation
	writes Transform on one of them and the other holds the limb where it is, so
	the body slides around in its rest pose. That is "some of them just drag
	around", and it was SOME because it depended on how each individual model
	happened to be organised: a flat rig was fine, a foldered one was not.

	Forty-five other callers ask this for a body's root — targeting, damage, gore,
	melee, the brain's own steering. Every one of them was getting nil for such a
	rig too.

	Order: the real HumanoidRootPart first wherever it lives, because PrimaryPart
	is frequently set to something else or not set at all; then PrimaryPart; then
	a torso; then anything. Accessories are skipped throughout — a hat's Handle is
	not a body's root.
]]
function RigUtil.getRoot(model: Model): BasePart?
	local torso: BasePart? = nil
	local anyPart: BasePart? = nil

	for _, descendant in model:GetDescendants() do
		if not descendant:IsA("BasePart") then
			continue
		end
		if descendant:FindFirstAncestorWhichIsA("Accoutrement") then
			continue
		end
		local name = descendant.Name
		if name == "HumanoidRootPart" then
			return descendant
		end
		if not torso and (name == "Torso" or name == "UpperTorso") then
			torso = descendant
		end
		if not anyPart then
			anyPart = descendant
		end
	end

	if model.PrimaryPart then
		return model.PrimaryPart
	end
	return torso or anyPart
end

--[[
	Every BasePart in a rig, excluding accessories. Used by the ragdoll and
	dismemberment code, which must not try to weld a hat.

	── ACCOUTREMENT, NOT ACCESSORY ─────────────────────────────────────────────
	Every one of these tests said "Accessory", which misses the legacy `Hat`
	class: Hat and Accessory are SIBLINGS under Accoutrement, so IsA("Accessory")
	is false for a Hat. A rig wearing a legacy hat — which is most zombie models
	old enough to be R6 — therefore had its hat's Handle counted as a body part
	here, offered as a possible ROOT by getRoot, and allowed to vote on whether
	the rig is R6 or R15 in rigTypeOf.

	That is a per-model difference between two rigs that look identical, which is
	the shape of every real fault in this investigation. Testing the base class
	covers Hat, Accessory and anything else Roblox adds under it.
]]
function RigUtil.getBodyParts(model: Model): { BasePart }
	local parts = {}
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") and not descendant:FindFirstAncestorWhichIsA("Accoutrement") then
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

	--[[ NO EARLY RETURN. This used to be `if not root then return children end`,
	     which handed back an EMPTY map — and buildMissingJoints reads this map to
	     decide which joints already exist, so an empty one told it the rig had
	     none and it built a duplicate skeleton. Falling through leaves the
	     conventional Part1 reading below to answer, which is right for every
	     normally-wired rig and is never worse than nothing. ]]
	local root = RigUtil.getRoot(model)
	local seen: { [BasePart]: boolean } = {}
	if root then
		seen[root] = true
	end
	local queue: { BasePart } = if root then { root } else {}
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
	Whether this instance is a rigid joint that could pin a pair a Motor6D
	already drives.

	ONE definition, because there were three and they disagreed. The spawn repair
	took every JointInstance; the boot report and the Studio script took Weld,
	WeldConstraint and Snap. So the game cut Glues, Motors and Rotates that
	neither of the other two would ever mention — a report that reads clean while
	the game is still repairing something on every spawn, and a REPAIR mode that
	under-fixes what the report promised. Three answers to one question is worse
	than any one of them being wrong.

	Motor6D is excluded deliberately: a second one of those is a duplicate JOINT,
	and clearDuplicateJoints owns it because "which survives" has a different
	right answer there.

	WeldConstraint is named separately because it is NOT a JointInstance — it
	descends from Instance directly, which is exactly the sort of detail that
	makes three hand-written copies of a predicate drift apart.
]]
function RigUtil.isRivalJoint(instance: Instance): boolean
	if instance:IsA("Motor6D") then
		return false
	end
	return instance:IsA("JointInstance") or instance:IsA("WeldConstraint")
end

--[[
	Destroys SECOND and subsequent Motor6Ds spanning the same pair of parts, and
	returns how many, with the pairs it thinned.

	── WHY A RIG CAN HAVE TWO OF THE SAME JOINT ────────────────────────────────
	Most often because this code built them. buildMissingJoints decided which
	joints a rig already had from a graph walk that needed a root, and the root
	lookup was shallow — so a rig whose parts sit inside a Folder reported no
	joints at all and got a complete second skeleton laid over the first, at every
	spawn. Both of those are fixed and buildMissingJoints now refuses on the pair
	directly, but a model somebody saved in that state, or one hand-built with a
	spare joint, still arrives carrying them.

	── WHY IT MATTERS ──────────────────────────────────────────────────────────
	Two rigid joints on one pair over-constrains the assembly. Roblox spans the
	rigid-joint graph and one of them decides the relative CFrame; the animation
	writes Transform on whichever Motor6D the animator resolved by name, and if
	that is not the one holding the pair, the limb does not move. Which one wins
	is not something to rely on, so the symptom can differ between two bodies of
	the same model — and every diagnostic still reports the rig as fully jointed,
	because it is. It has too many joints, not too few.

	── WHICH ONE SURVIVES ──────────────────────────────────────────────────────
	The first one seen in descendant order, which is the model's own, because the
	ones this code adds are parented later. Nothing tries to be cleverer than
	that: any survivor is correct once the rest are gone, and preferring the
	author's is the least surprising rule.
]]
--[[
	Re-enables Motor6Ds somebody switched off, and returns which.

	Motor6D.Enabled is a serialized property that defaults to true and is
	invisible in the Explorer — you only see it by selecting that exact joint and
	reading the Properties pane. A disabled one is still a Motor6D: it is counted
	by every check in this project, it reports its Part0 and Part1, it satisfies
	"fully jointed", and the engine will not drive it. The limb does not move and
	nothing anywhere says why.

	It gets switched off by ragdoll code, by plugins, and by hand while somebody
	is debugging a rig. It is the cheapest possible fault to fix and was the
	hardest to see.
]]
function RigUtil.enableMotors(model: Model): (number, { string })
	local fixed = 0
	local names: { string } = {}
	for _, motor in RigUtil.getMotors(model) do
		if motor.Enabled then
			continue
		end
		motor.Enabled = true
		fixed += 1
		table.insert(names, if motor.Part1 then motor.Part1.Name else motor.Name)
	end
	table.sort(names)
	return fixed, names
end

function RigUtil.clearDuplicateJoints(model: Model): (number, { string })
	--[[ The joint kept for each pair, not merely the fact that one was kept: the
	     survivor has to be re-posed before its rival is destroyed. ]]
	local kept: { [BasePart]: { [BasePart]: Motor6D } } = {}
	local removed = 0
	local thinned: { string } = {}

	for _, motor in RigUtil.getMotors(model) do
		local part0, part1 = motor.Part0, motor.Part1
		if not part0 or not part1 or part0 == part1 then
			continue
		end
		local spanned = kept[part0]
		if spanned then
			local survivor = spanned[part1]
			if survivor then
				--[[
					THE SURVIVOR IS RE-DERIVED FROM THE POSE ON SCREEN, and skipping
					this would let a repair visibly deform the body.

					Only ONE of two joints on a pair is the assembly's tree edge, and
					that is the one deciding where the limb actually is. The other is
					redundant and its C0/C1 can say something completely different —
					they were authored at different times, by different hands, or one
					of them was generated from standard proportions by this very
					codebase. Destroy the tree edge and the limb snaps to whatever
					the survivor happened to believe.

					Which of the two is the tree edge is not something to reason
					about, so this does not try. Both C0 and C1 are recomputed from
					where the two parts ARE, which makes Part0.CFrame * C0 ==
					Part1.CFrame * C1 true for the current pose by construction — the
					same trick buildMissingJoints uses, and it holds whichever joint
					was load-bearing.

					Correct at spawn specifically, which is when this runs: the body
					is still in its authored rest pose, so the pose captured here is
					the rest pose the animation should offset from.

					── AND THE AXES COME FROM THE SKELETON, NOT FROM THE PARTS ─────
					This used to write `C0 = part0:ToObjectSpace(part1), C1 =
					identity`. That is pose-preserving, which is what made it look
					right, but it pins the joint's axes to the parent's — and an R6
					clip is keyed against a shoulder turned a quarter-turn about Y.
					A survivor framed that way holds the arm in exactly the right
					place and then swings it out sideways the moment the clip plays.
					Neither rival's numbers are trusted for the axes any more than
					for the pose; both come from the standard skeleton.
				]]
				local spec = RigUtil.jointSpec(model, part1.Name)
				if spec and spec.parent == part0.Name then
					RigUtil.frameMotor(
						survivor,
						part0.CFrame,
						part1.CFrame,
						(RigUtil.jointFrame(part0, part1, spec))
					)
				else
					--[[ A joint no standard skeleton describes. There is no basis to
					     impose, so keep the old pose-only derivation. ]]
					survivor.C0 = part0.CFrame:ToObjectSpace(part1.CFrame)
					survivor.C1 = CFrame.identity
				end

				table.insert(thinned, string.format("%s/%s", part0.Name, part1.Name))
				motor:Destroy()
				removed += 1
				continue
			end
		end
		kept[part0] = kept[part0] or {}
		kept[part1] = kept[part1] or {}
		kept[part0][part1] = motor
		kept[part1][part0] = motor
	end

	return removed, thinned
end

--[[
	Destroys any Weld, WeldConstraint or Snap that duplicates a Motor6D, and
	returns how many, with the pairs it cut.

	── THIS IS THE ONE THAT LOOKS LIKE NOTHING IS WRONG ────────────────────────
	Two rigid joints between the same two parts is an over-constrained assembly,
	and Roblox resolves it by pinning the pair. The Motor6D is still there, the
	animation still writes its Transform every frame, and the limb does not move
	— because the weld beside it is holding the two parts at a fixed offset and
	winning.

	Every diagnostic this project has says such a rig is FINE. RigDoctor reports
	"fully jointed", because the joints genuinely are all present.
	CheckAnimations reports every id ok, because the clips genuinely are. The
	boot summary reports the right rig, because it is. Nothing warns, and the
	body slides around the map in its rest pose — which is exactly the symptom
	reported as "they just drag around".

	── WHY buildMissingJoints DOES NOT ALREADY DO THIS ─────────────────────────
	It clears rival welds, but only off a limb whose joint it is about to BUILD,
	inside the loop and after the `if have[spec.child] then continue end` that
	skips a limb already jointed. So it fires precisely when there is no Motor6D
	to be over-constrained by, and never in the case that needs it. On a rig that
	reports fully jointed, that loop never executes at all.

	── WHY IT CANNOT EAT A LEGITIMATE WELD ─────────────────────────────────────
	The test is not "is this a weld on a rig part". It is "are these two parts
	ALREADY connected by a Motor6D" — which is true only for a duplicate. A hat
	welded to a head, a weapon welded to a hand, a prop welded to a torso: none
	of those pairs has a Motor6D, so none of them is touched. That is why this is
	safe to run on every body of every rig, including ones nobody has a problem
	with.
]]
function RigUtil.clearRivalJoints(model: Model): (number, { string })
	local motors = RigUtil.getMotors(model)
	if #motors == 0 then
		return 0, {}
	end

	--[[ Every pair a Motor6D already connects, both ways round, because a weld
	     is free to name the same two parts in the opposite order. ]]
	local jointed: { [BasePart]: { [BasePart]: boolean } } = {}
	for _, motor in motors do
		local part0, part1 = motor.Part0, motor.Part1
		if not part0 or not part1 or part0 == part1 then
			continue
		end
		jointed[part0] = jointed[part0] or {}
		jointed[part1] = jointed[part1] or {}
		jointed[part0][part1] = true
		jointed[part1][part0] = true
	end

	local removed = 0
	local cut: { string } = {}
	for _, descendant in model:GetDescendants() do
		--[[
			EVERY rigid joint class, not the three that were obvious.

			This tested Weld, WeldConstraint and Snap. A model assembled with
			legacy surface joints gets Glue and Snap; one built from an old rig
			carries Motor or Rotate; and all of them hold two parts together
			exactly as hard as a Weld does. The one that survives the sweep is the
			one that pins the limb, so a partial list is a sweep that reports
			success and changes nothing.

			Motor6D is deliberately absent: a second one of those is a duplicate
			JOINT rather than a rival, and clearDuplicateJoints owns that case
			because "which one survives" has a different right answer there.
		]]
		if not RigUtil.isRivalJoint(descendant) then
			continue
		end
		--[[ They carry Part0/Part1 but share no superclass that declares both, so
		     the read is done through a cast rather than through a branch each. ]]
		local joint: any = descendant
		local part0, part1 = joint.Part0, joint.Part1
		if not part0 or not part1 then
			continue
		end
		local sameAsMotor = jointed[part0]
		if not sameAsMotor or not sameAsMotor[part1] then
			continue
		end

		table.insert(cut, string.format("%s/%s", part0.Name, part1.Name))
		descendant:Destroy()
		removed += 1
	end

	return removed, cut
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
	The standard skeletons, parent -> child. Each entry carries the two things a
	joint needs: WHERE it pivots, and WHICH WAY its axes point.

	`at` is the pivot in the PARENT's own space, as fractions of its size —
	fractions rather than studs so a half-scale Common and a Tank at 2.35 both get
	their shoulder in the right place without a table per size.

	── `basis` IS NOT DECORATION ───────────────────────────────────────────────
	A Motor6D poses its child at

	    Part0.CFrame * C0 * Transform * C1:Inverse()

	and `Transform` is what an AnimationTrack writes. It sits INSIDE C0, so it is
	expressed in the frame C0 defines: an animation's rotations are read in the
	joint's own axes, not the parent's. Roblox's R6 shoulders and hips are turned
	a quarter-turn about Y, its neck and root are tipped onto their backs, and
	every R6 clip ever authored was keyed against those axes.

	Build the same joint from a pivot with no rotation and the rig looks PERFECT.
	The rest pose is identical to the stud, every part is exactly where the author
	left it, and every check in this file — jointed, not duplicated, not welded,
	not backwards, not disabled — passes. Then the clip plays, and a shoulder
	swing that should carry the arm fore-and-aft along Z carries it out sideways
	along X instead, because the axes it was authored in are not the axes it is
	being read in. The arm ends up sticking straight out to the side; the hips
	share the fault, so the legs splay instead of stepping and the body slides
	along the floor with nothing bending.

	That is the "some of them just drag around with an arm out" bug. It is
	invisible to every rest-pose diagnostic there is, which is why it outlived so
	many of them.

	R15 needs no such turn — its joint frames are axis-aligned with the character,
	which is why the R15 table below is all identity. Where a real
	`*RigAttachment` exists it is preferred over this table anyway; see jointFrame.
]]
--[[ A quarter turn about Y, the R6 limb basis: the joint's X runs along the
     character's Z, so a rotation about the joint's Z swings the limb
     fore-and-aft rather than out to the side. ]]
local LEFT_LIMB_BASIS = CFrame.Angles(0, -math.pi / 2, 0)
local RIGHT_LIMB_BASIS = CFrame.Angles(0, math.pi / 2, 0)
--[[ The R6 neck and root basis: tipped onto its back and turned round. ]]
local AXIAL_BASIS = CFrame.Angles(-math.pi / 2, 0, math.pi)

local R6_SKELETON = table.freeze({
	table.freeze({
		joint = "RootJoint",
		parent = "HumanoidRootPart",
		child = "Torso",
		at = Vector3.zero,
		basis = AXIAL_BASIS,
	}),
	table.freeze({
		joint = "Neck",
		parent = "Torso",
		child = "Head",
		at = Vector3.new(0, 0.5, 0),
		basis = AXIAL_BASIS,
	}),
	table.freeze({
		joint = "Left Shoulder",
		parent = "Torso",
		child = "Left Arm",
		at = Vector3.new(-0.5, 0.25, 0),
		basis = LEFT_LIMB_BASIS,
	}),
	table.freeze({
		joint = "Right Shoulder",
		parent = "Torso",
		child = "Right Arm",
		at = Vector3.new(0.5, 0.25, 0),
		basis = RIGHT_LIMB_BASIS,
	}),
	--[[ The hip pivot is the torso's SIDE face, not half way in. Roblox's own
	     Left Hip C0 is (-1, -1, 0) on a two-stud-wide torso; this table said
	     -0.25, which hinged the whole leg half a stud inboard of where the clip
	     expects it to. ]]
	table.freeze({
		joint = "Left Hip",
		parent = "Torso",
		child = "Left Leg",
		at = Vector3.new(-0.5, -0.5, 0),
		basis = LEFT_LIMB_BASIS,
	}),
	table.freeze({
		joint = "Right Hip",
		parent = "Torso",
		child = "Right Leg",
		at = Vector3.new(0.5, -0.5, 0),
		basis = RIGHT_LIMB_BASIS,
	}),
})

local R15_SKELETON = table.freeze({
	table.freeze({
		joint = "Root",
		parent = "HumanoidRootPart",
		child = "LowerTorso",
		at = Vector3.zero,
		basis = CFrame.identity,
	}),
	table.freeze({
		joint = "Waist",
		parent = "LowerTorso",
		child = "UpperTorso",
		at = Vector3.new(0, 0.5, 0),
		basis = CFrame.identity,
	}),
	table.freeze({
		joint = "Neck",
		parent = "UpperTorso",
		child = "Head",
		at = Vector3.new(0, 0.5, 0),
		basis = CFrame.identity,
	}),
	table.freeze({
		joint = "LeftShoulder",
		parent = "UpperTorso",
		child = "LeftUpperArm",
		at = Vector3.new(-0.5, 0.4, 0),
		basis = CFrame.identity,
	}),
	table.freeze({
		joint = "LeftElbow",
		parent = "LeftUpperArm",
		child = "LeftLowerArm",
		at = Vector3.new(0, -0.5, 0),
		basis = CFrame.identity,
	}),
	table.freeze({
		joint = "LeftWrist",
		parent = "LeftLowerArm",
		child = "LeftHand",
		at = Vector3.new(0, -0.5, 0),
		basis = CFrame.identity,
	}),
	table.freeze({
		joint = "RightShoulder",
		parent = "UpperTorso",
		child = "RightUpperArm",
		at = Vector3.new(0.5, 0.4, 0),
		basis = CFrame.identity,
	}),
	table.freeze({
		joint = "RightElbow",
		parent = "RightUpperArm",
		child = "RightLowerArm",
		at = Vector3.new(0, -0.5, 0),
		basis = CFrame.identity,
	}),
	table.freeze({
		joint = "RightWrist",
		parent = "RightLowerArm",
		child = "RightHand",
		at = Vector3.new(0, -0.5, 0),
		basis = CFrame.identity,
	}),
	table.freeze({
		joint = "LeftHip",
		parent = "LowerTorso",
		child = "LeftUpperLeg",
		at = Vector3.new(-0.5, -0.5, 0),
		basis = CFrame.identity,
	}),
	table.freeze({
		joint = "LeftKnee",
		parent = "LeftUpperLeg",
		child = "LeftLowerLeg",
		at = Vector3.new(0, -0.5, 0),
		basis = CFrame.identity,
	}),
	table.freeze({
		joint = "LeftAnkle",
		parent = "LeftLowerLeg",
		child = "LeftFoot",
		at = Vector3.new(0, -0.5, 0),
		basis = CFrame.identity,
	}),
	table.freeze({
		joint = "RightHip",
		parent = "LowerTorso",
		child = "RightUpperLeg",
		at = Vector3.new(0.5, -0.5, 0),
		basis = CFrame.identity,
	}),
	table.freeze({
		joint = "RightKnee",
		parent = "RightUpperLeg",
		child = "RightLowerLeg",
		at = Vector3.new(0, -0.5, 0),
		basis = CFrame.identity,
	}),
	table.freeze({
		joint = "RightAnkle",
		parent = "RightLowerLeg",
		child = "RightFoot",
		at = Vector3.new(0, -0.5, 0),
		basis = CFrame.identity,
	}),
})

--[[
	Every part name Roblox's own character resolution cares about.

	Used to decide which parts MUST be direct children of the Model. Roblox
	resolves a character's rig by name among the Humanoid's siblings, so these
	have to sit there — and nothing else does.

	The distinction is not academic. The first version of the flatten moved
	anything nested, and the very first real boot showed what that means: eleven
	Commons reported "1 part inside a Folder", and the part was `Hair (was in
	Head)`. A hair mesh parented inside a head is a completely ordinary way to
	build a model, it has nothing to do with Humanoid.RootPart, and hoisting it to
	the Model turns a cosmetic into something getBodyParts counts as a limb — so
	the ragdoll constrains it and dismemberment can pick it. The repair was
	inventing a fault and then causing a real one.
]]
local STANDARD_PARTS = table.freeze({
	HumanoidRootPart = true,
	-- R6
	Torso = true,
	Head = true,
	["Left Arm"] = true,
	["Right Arm"] = true,
	["Left Leg"] = true,
	["Right Leg"] = true,
	-- R15
	LowerTorso = true,
	UpperTorso = true,
	LeftUpperArm = true,
	LeftLowerArm = true,
	LeftHand = true,
	RightUpperArm = true,
	RightLowerArm = true,
	RightHand = true,
	LeftUpperLeg = true,
	LeftLowerLeg = true,
	LeftFoot = true,
	RightUpperLeg = true,
	RightLowerLeg = true,
	RightFoot = true,
})

--[[ Whether this name is one Roblox's character resolution looks for among the
     Humanoid's siblings. Anything else is the model author's business and must
     be left exactly where they put it. ]]
function RigUtil.isStandardPart(name: string): boolean
	return STANDARD_PARTS[name] == true
end

--[[
	Parts a rig is allowed not to have.

	Plenty of R15 models end the arm at the forearm and the leg at the shin, and
	that is a styling choice rather than a fault — the existing note on
	buildMissingJoints says so. Without this the boot report would open by telling
	somebody that all eight of their specials are missing four parts each, which
	is the fastest way to teach a person to ignore a report.

	Nothing on an R6 rig is optional: six parts and a root is the whole skeleton.
]]
local OPTIONAL_PARTS = table.freeze({
	LeftHand = true,
	RightHand = true,
	LeftFoot = true,
	RightFoot = true,
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
--[[ Part names that belong to exactly one build. Names both rigs share — Head,
     HumanoidRootPart — say nothing and are deliberately absent. ]]
local R6_WITNESS = table.freeze({
	Torso = true,
	["Left Arm"] = true,
	["Right Arm"] = true,
	["Left Leg"] = true,
	["Right Leg"] = true,
})
local R15_WITNESS = table.freeze({
	UpperTorso = true,
	LowerTorso = true,
	LeftUpperArm = true,
	RightUpperArm = true,
	LeftLowerArm = true,
	RightLowerArm = true,
	LeftUpperLeg = true,
	RightUpperLeg = true,
	LeftLowerLeg = true,
	RightLowerLeg = true,
})

function RigUtil.rigTypeOf(model: Model): (string, string?)
	--[[
		── COUNTED, NOT DECIDED BY THE FIRST THING SEEN ────────────────────────
		This returned R15 the moment it met ONE part named UpperTorso or
		LowerTorso. One stray mesh with that name — a leftover from an R15 donor
		body, a cosmetic somebody copied in, a part renamed while experimenting —
		therefore handed an otherwise-perfect R6 Common the R15 clip set. Those
		clips address LeftUpperArm and RightLowerLeg, which that rig does not
		have, so they load, report themselves playing, move nothing, and the
		fallback stands down for a body it should be driving.

		It is a per-model property, so it hit SOME of the thirty-five and not the
		others, and it is invisible: the boot log said [R6] because that verdict
		is stored per KIND and the last variant to be prepared overwrote it.

		Counting witnesses instead makes it take five parts to outvote five parts.
		A real R15 rig has ten distinctive names and a real R6 rig has five, so
		the honest cases are never close — and one stray part loses 5-to-1 instead
		of winning outright.
	]]
	local r6, r15 = 0, 0
	local firstR15: string? = nil
	for _, descendant in model:GetDescendants() do
		if not descendant:IsA("BasePart") then
			continue
		end
		if descendant:FindFirstAncestorWhichIsA("Accoutrement") then
			continue
		end
		local name = descendant.Name
		if R6_WITNESS[name] then
			r6 += 1
		elseif R15_WITNESS[name] then
			r15 += 1
			if not firstR15 then
				firstR15 = name
			end
		end
	end

	if r15 > r6 then
		return "R15", firstR15
	end
	--[[ Ties and empties both fall to R6, which is this game's overwhelming
	     majority and the build buildMissingJoints can repair from the fewest
	     parts. A rig with no distinctive names at all is one nothing can help. ]]
	return "R6", nil
end

export type JointSpec = {
	joint: string,
	parent: string,
	child: string,
	at: Vector3,
	basis: CFrame,
}

--[[ This model's skeleton keyed on the CHILD part, with the rig type that chose
     it. Keyed on the child because that is the end an animation addresses and
     the end every other lookup in this file is keyed on.

     Returned as a map, once, rather than answered one part at a time: choosing
     the skeleton means calling rigTypeOf, and that walks every descendant of the
     model. Asked per joint it was a dozen full walks per body per spawn. ]]
function RigUtil.jointSpecs(model: Model): ({ [string]: JointSpec }, string)
	local rig = RigUtil.rigTypeOf(model)
	local byChild: { [string]: JointSpec } = {}
	for _, spec in (if rig == "R15" then R15_SKELETON else R6_SKELETON) do
		byChild[spec.child] = spec
	end
	return byChild, rig
end

--[[ One entry, for the callers that need exactly one. ]]
function RigUtil.jointSpec(model: Model, childName: string): JointSpec?
	return (RigUtil.jointSpecs(model))[childName]
end

--[[
	Where a joint's own axes belong in the world, and whether that answer came
	from the rig itself or from the table.

	`pivot` overrides the position only. Pass it when correcting an EXISTING
	joint: the hinge point is the author's decision and there is no evidence it
	is wrong, so a repair aimed at the axes should not quietly move it. Leave it
	out when building or re-deriving one, where the table's is the only figure
	available.

	A `*RigAttachment` on the parent beats both. It is the rig's own statement of
	where this joint is and which way it points, it is what Roblox's own rig
	builder reads, and on a resized or reproportioned R15 body it is right where
	a table of fractions is approximate. R6 rigs carry no attachment under these
	names, so R6 always falls through to the table — which is fine, because the
	R6 constants are Roblox's own and universal.
]]
function RigUtil.jointFrame(
	parent: BasePart,
	child: BasePart,
	spec: JointSpec,
	pivot: Vector3?
): (CFrame, boolean)
	local attachment = parent:FindFirstChild(spec.joint .. "RigAttachment")
	if attachment and attachment:IsA("Attachment") then
		return parent.CFrame * attachment.CFrame, true
	end
	local position = pivot
	if not position then
		local offset =
			Vector3.new(spec.at.X * parent.Size.X, spec.at.Y * parent.Size.Y, spec.at.Z * parent.Size.Z)
		position = (parent.CFrame * CFrame.new(offset)).Position
	end
	return CFrame.new(position :: Vector3) * parent.CFrame.Rotation * spec.basis, false
end

--[[
	Writes a Motor6D's C0 and C1 from one world joint frame.

	── THE POSE IS PRESERVED FOR ANY FRAME, EXACTLY ────────────────────────────
	A Motor6D holds its child at `Part0.CFrame * C0 * Transform * C1:Inverse()`.
	With `C0 = parentCF⁻¹ * J` and `C1 = childCF⁻¹ * J` that becomes, at rest,

	    parentCF * parentCF⁻¹ * J * J⁻¹ * childCF  ==  childCF

	for every J. So the joint holds its child in exactly the same place whatever
	frame is chosen — at any size, any proportion, and whether or not the limb was
	modelled square to its parent. J decides only which way the joint's axes
	point, which is to say which way the ANIMATION will bend it.

	That is the whole reason this exists rather than the old
	`C0 = parent:ToObjectSpace(child), C1 = identity`. That pair is also exactly
	pose-preserving, which is what made it look correct and survive so long — but
	it pins the joint's axes to the parent's, and no R6 clip was authored in the
	parent's axes.

	── WHY IT TAKES CFRAMES AND NOT THE TWO PARTS ──────────────────────────────
	Because where the child part IS and where the joint HOLDS it are two different
	things the moment anything is animating. Transform is applied after C0, so a
	joint mid-clip has its child somewhere the joint's own rest maths never put
	it — and Transform is serialized, so a model saved mid-pose arrives that way
	before a single clip has played. Reading `child.CFrame` there would bake the
	pose of the moment in as the new rest pose and deform the body permanently.

	Callers correcting an EXISTING joint pass its rest pose,
	`parentCF * C0 * C1:Inverse()`, which is exactly what the joint holds the
	child at with Transform taken out. Callers building a NEW one have no
	Transform to discount and pass the child's CFrame directly.
]]
function RigUtil.frameMotor(motor: Motor6D, parentCF: CFrame, childCF: CFrame, frame: CFrame)
	motor.C0 = parentCF:ToObjectSpace(frame)
	motor.C1 = childCF:ToObjectSpace(frame)
end

--[[ Where a joint holds its child with any animation discounted — the pose it
     would snap back to the instant every track stopped. ]]
function RigUtil.restPose(motor: Motor6D): CFrame?
	local parent = motor.Part0
	if not parent then
		return nil
	end
	return parent.CFrame * motor.C0 * motor.C1:Inverse()
end

--[[ Two rotations agreeing to within about a degree. Compared through their
     axes rather than through an angle so there is no branch on how a CFrame
     chose to decompose itself. ]]
local BASIS_EPSILON = 0.02

local function basisMatches(a: CFrame, b: CFrame): boolean
	local delta = a.Rotation:ToObjectSpace(b.Rotation)
	return delta.RightVector:Dot(Vector3.xAxis) > 1 - BASIS_EPSILON
		and delta.UpVector:Dot(Vector3.yAxis) > 1 - BASIS_EPSILON
end

--[[
	The frame a standard joint SHOULD have if its axes are pointing the wrong
	way, or nil if they are already right — or if there is no trustworthy answer.

	Shared by the repair and the report so the boot summary, RigDoctor and the
	spawn fix can never disagree about whether a given joint is skewed.

	── WHY R15 IS ONLY JUDGED FROM ITS OWN ATTACHMENTS ─────────────────────────
	The R6 constants are Roblox's, they are universal, and a hand-built R6 rig
	that departs from them cannot play an R6 clip at all — so departing from them
	is the fault, and correcting it is safe. R15 is a table of identities here,
	and an identity is exactly what a legitimately unusual R15 rig would fail to
	match. So R15 gets corrected only where a RigAttachment states the intended
	frame outright; without one this declines to guess, and the joint is left
	alone.
]]
local function skewedFrame(specs: { [string]: JointSpec }, rig: string, motor: Motor6D): CFrame?
	local parent, child = motor.Part0, motor.Part1
	if not parent or not child or parent == child then
		return nil
	end
	local spec = specs[child.Name]
	if not spec or spec.parent ~= parent.Name then
		return nil
	end
	--[[ The joint's CURRENT hinge point is kept and only its direction judged:
	     where a limb pivots is the author's decision and no clip contradicts it. ]]
	local frame, authoritative = RigUtil.jointFrame(parent, child, spec, (parent.CFrame * motor.C0).Position)
	if not authoritative and rig == "R15" then
		return nil
	end
	if basisMatches(parent.CFrame * motor.C0, frame) then
		return nil
	end
	return frame
end

function RigUtil.skewedJointFrame(model: Model, motor: Motor6D): CFrame?
	local specs, rig = RigUtil.jointSpecs(model)
	return skewedFrame(specs, rig, motor)
end

--[[
	Turns every standard joint's AXES the right way round, and returns which.

	── THE FAULT NO REST-POSE CHECK CAN SEE ────────────────────────────────────
	An AnimationTrack writes `Transform`, and a Motor6D applies it INSIDE C0:

	    Part1.CFrame = Part0.CFrame * C0 * Transform * C1:Inverse()

	so a clip's rotations are read in the joint's own axes. Roblox's R6 shoulders
	and hips are turned a quarter-turn about Y and every R6 clip was keyed against
	that. A joint built from a pivot and no rotation — by an author dragging parts
	together in Studio, by a plugin, or by earlier versions of buildMissingJoints
	and clearDuplicateJoints in this very file — holds the limb in EXACTLY the
	right place at rest and reads the clip in the wrong axes.

	The result is a shoulder swing delivered sideways: the arm sticks straight out
	left or right and stays there, the hips splay instead of stepping, and the
	body slides along the ground. Meanwhile the rig passes every check there is,
	because it is jointed, not duplicated, not welded, not backwards, not
	disabled, and sitting in a perfect rest pose. Nothing before this could see
	it, which is why the symptom outlived so many fixes.

	── WHY THE HINGE POINT IS LEFT WHERE IT IS ─────────────────────────────────
	Only the axes are provably wrong; where a joint hinges is the author's
	decision and the clip does not contradict it. So the correction keeps the
	existing pivot and changes nothing but the direction — see jointFrame.
]]
function RigUtil.reframeJoints(model: Model): (number, { string })
	local specs, rig = RigUtil.jointSpecs(model)
	local fixed = 0
	local names: { string } = {}
	for _, motor in RigUtil.getMotors(model) do
		local frame = skewedFrame(specs, rig, motor)
		if not frame then
			continue
		end
		local parent, child = motor.Part0, motor.Part1
		local rest = RigUtil.restPose(motor)
		if not parent or not child or not rest then
			continue
		end
		--[[ The joint's REST pose, not the child's current CFrame: a body saved or
		     caught mid-clip has its child somewhere Transform put it, and baking
		     that in would deform it permanently. See frameMotor. ]]
		RigUtil.frameMotor(motor, parent.CFrame, rest, frame)
		fixed += 1
		table.insert(names, child.Name)
	end
	table.sort(names)
	return fixed, names
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
	--[[
		── TWO INDEPENDENT GUARDS, BECAUSE ONE OF THEM ALREADY FAILED ──────────
		This used to decide "does this limb already have a joint" from
		mapMotorChildren alone. That map is derived from a graph walk, the walk
		needed a root, the root lookup was shallow, and for a rig whose parts sit
		in a Folder the map came back EMPTY — so every limb looked unjointed and
		this function built a second complete skeleton over the first, on every
		single spawn. Two Motor6Ds on a pair is an over-constrained assembly: the
		clip drives one and the other holds the limb, and the body slides around
		in its rest pose.

		The root lookup is fixed and the map no longer comes back empty. Neither
		of those is allowed to be the only thing standing between this function
		and that outcome again, so the real guard is now read straight off the
		Motor6Ds themselves:

		  PAIRS   the two parts this spec would join are already joined. This is
		          the exact condition for a duplicate and it needs no walk at all.
		  CLAIMED the child part is already the child end of some joint, even a
		          differently-shaped one. Keeps a rig whose author jointed a limb
		          somewhere unconventional from being second-guessed.
	]]
	local jointedPairs: { [BasePart]: { [BasePart]: boolean } } = {}
	local have: { [string]: boolean } = {}
	for _, motor in RigUtil.getMotors(model) do
		local part0, part1 = motor.Part0, motor.Part1
		if not part0 or not part1 or part0 == part1 then
			continue
		end
		jointedPairs[part0] = jointedPairs[part0] or {}
		jointedPairs[part1] = jointedPairs[part1] or {}
		jointedPairs[part0][part1] = true
		jointedPairs[part1][part0] = true
		--[[ By NAME, from the raw endpoint. normalizeMotorDirection runs before
		     this in _boltTogether, so Part1 is the child by then; and even if it
		     did not, claiming one extra name only ever declines to build, which
		     is the safe direction. ]]
		have[part1.Name] = true
	end
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
		--[[ OPTIONAL_PARTS are filtered out here for the same reason diagnose
		     filters them: an R15 rig that ends the arm at the forearm is a styling
		     choice, and reporting four of those per special teaches people to
		     ignore the message that also carries the real ones. ]]
		if not parent then
			if not OPTIONAL_PARTS[spec.parent] then
				table.insert(unbuildable, spec.parent)
			end
			continue
		end
		if not child then
			if not OPTIONAL_PARTS[spec.child] then
				table.insert(unbuildable, spec.child)
			end
			continue
		end

		--[[ The hard guard. Everything above this line is a name lookup and can
		     be defeated by an unusual rig; this cannot, because it asks the two
		     actual parts whether a Motor6D already spans them. ]]
		local spanned = jointedPairs[parent]
		if spanned and spanned[child] then
			continue
		end

		--[[
			Only a joint holding THIS PAIR, not every joint touching the limb.

			This destroyed anything weld-shaped attached to the child part, which
			is far more than it needed and takes cosmetics with it: a hat welded to
			a Head on a rig with no Neck, a prop welded to an arm on a rig with no
			shoulder. Those are exactly the rigs this branch runs on, so the
			over-reach fired precisely where it did the most damage.

			A weld between the two parts about to be jointed genuinely has to go —
			a weld and a Motor6D on one pair fight, and the weld wins. A weld
			anywhere else is somebody's model.
		]]
		for _, joint in child:GetJoints() do
			if joint:IsA("Motor6D") then
				continue
			end
			local held: any = joint
			local a, b = held.Part0, held.Part1
			if (a == parent and b == child) or (a == child and b == parent) then
				joint:Destroy()
			end
		end

		local motor = Instance.new("Motor6D")
		motor.Name = spec.joint
		motor.Part0 = parent
		motor.Part1 = child
		--[[ Frame and pivot both from the spec: a joint that does not exist yet
		     has no hinge point of its own to keep. ]]
		RigUtil.frameMotor(motor, parent.CFrame, child.CFrame, (RigUtil.jointFrame(parent, child, spec)))
		motor.Parent = parent
		built += 1
	end

	return built, unbuildable
end

export type RigReport = {
	rig: string,
	rootName: string?,
	motorCount: number,
	hasHumanoid: boolean,
	hasAnimator: boolean,
	duplicates: { string },
	disabled: { string },
	rivalWelds: { string },
	backwards: { string },
	skewed: { string },
	missingJoints: { string },
	missingParts: { string },
}

--[[
	Everything wrong with a rig, without changing any of it.

	── WHY THIS EXISTS SEPARATELY FROM THE REPAIRS ─────────────────────────────
	The repairs run at SPAWN, on a clone, and each warns once per variant — so
	they only ever describe a variant that has actually spawned, and only after
	somebody has played long enough for it to. With thirty-five Commons and a
	Director that picks at random, "which of my models is broken" was a question
	you answered by playing until it came up.

	This is the same set of tests with nothing destroyed, so it can be run at BOOT
	over every prepared template and answer that question in one block of the
	startup log — the log people already paste when they ask for help.

	It must not mutate. Templates are shared by every body of a kind, and the
	repairs are deliberately per-body: a report that quietly fixed things would
	make the boot log disagree with what the game is actually doing.
]]
function RigUtil.diagnose(model: Model): RigReport
	local rig = RigUtil.rigTypeOf(model)
	local root = RigUtil.getRoot(model)
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local motors = RigUtil.getMotors(model)

	--[[ Pairs, for the two faults that are defined on a pair rather than on a
	     part: a second Motor6D across one, and a weld beside one. ]]
	local seenPair: { [BasePart]: { [BasePart]: boolean } } = {}
	local duplicates: { string } = {}
	for _, motor in motors do
		local part0, part1 = motor.Part0, motor.Part1
		if not part0 or not part1 or part0 == part1 then
			continue
		end
		local spanned = seenPair[part0]
		if spanned and spanned[part1] then
			table.insert(duplicates, string.format("%s/%s", part0.Name, part1.Name))
			continue
		end
		seenPair[part0] = seenPair[part0] or {}
		seenPair[part1] = seenPair[part1] or {}
		seenPair[part0][part1] = true
		seenPair[part1][part0] = true
	end

	local rivals: { string } = {}
	for _, descendant in model:GetDescendants() do
		--[[ The SAME predicate the spawn repair uses. These were two hand-written
		     lists and they disagreed, so the report could call a rig clean while
		     the game went on cutting a Glue off it at every spawn. ]]
		if not RigUtil.isRivalJoint(descendant) then
			continue
		end
		local joint: any = descendant
		local part0, part1 = joint.Part0, joint.Part1
		if not part0 or not part1 then
			continue
		end
		local spanned = seenPair[part0]
		if spanned and spanned[part1] then
			table.insert(rivals, string.format("%s/%s", part0.Name, part1.Name))
		end
	end

	local disabled: { string } = {}
	for _, motor in motors do
		if not motor.Enabled then
			table.insert(disabled, if motor.Part1 then motor.Part1.Name else motor.Name)
		end
	end

	--[[ Joints whose axes point the wrong way. Read-only here and computed by
	     exactly the predicate the repair uses, so the report and the fix can
	     never disagree — see RigUtil.skewedJointFrame for why no other check in
	     this function can see the fault. ]]
	local skewed: { string } = {}
	local specs = RigUtil.jointSpecs(model)
	for _, motor in motors do
		if skewedFrame(specs, rig, motor) and motor.Part1 then
			table.insert(skewed, (motor.Part1 :: BasePart).Name)
		end
	end

	local backwards: { string } = {}
	local have: { [string]: boolean } = {}
	for motor, child in RigUtil.mapMotorChildren(model) do
		have[child.Name] = true
		if motor.Part1 ~= child and motor.Part0 == child then
			table.insert(backwards, child.Name)
		end
	end
	for _, motor in motors do
		if motor.Part1 then
			have[motor.Part1.Name] = true
		end
	end

	local skeleton = if rig == "R15" then R15_SKELETON else R6_SKELETON
	local missingJoints: { string } = {}
	local missingParts: { string } = {}
	local seenPartName: { [string]: boolean } = {}
	for _, spec in skeleton do
		if have[spec.child] then
			continue
		end
		local parent = namedPart(model, spec.parent)
		local child = namedPart(model, spec.child)
		if not parent or not child then
			for _, name in { spec.parent, spec.child } do
				local present = if name == spec.parent then parent else child
				if not present and not seenPartName[name] and not OPTIONAL_PARTS[name] then
					seenPartName[name] = true
					table.insert(missingParts, name)
				end
			end
			continue
		end
		local spanned = seenPair[parent]
		if spanned and spanned[child] then
			continue
		end
		table.insert(missingJoints, spec.joint)
	end

	table.sort(duplicates)
	table.sort(disabled)
	table.sort(rivals)
	table.sort(backwards)
	table.sort(skewed)
	table.sort(missingParts)

	return {
		rig = rig,
		rootName = if root then root.Name else nil,
		motorCount = #motors,
		hasHumanoid = humanoid ~= nil,
		hasAnimator = humanoid ~= nil and humanoid:FindFirstChildOfClass("Animator") ~= nil,
		duplicates = duplicates,
		disabled = disabled,
		rivalWelds = rivals,
		backwards = backwards,
		skewed = skewed,
		missingJoints = missingJoints,
		missingParts = missingParts,
	}
end

--[[
	A list of names collapsed into "name xN", sorted, for a message a person reads.

	The first real boot produced a line containing "Right Arm/Torso" ten times in
	a row, then "Torso/Left Arm" five times — twenty-eight repeats on one model.
	That is accurate and unreadable, and an unreadable report is one nobody acts
	on. The count is the information; the repetition is not.
]]
function RigUtil.tally(names: { string }): string
	local counts: { [string]: number } = {}
	local order: { string } = {}
	for _, name in names do
		if not counts[name] then
			counts[name] = 0
			table.insert(order, name)
		end
		counts[name] += 1
	end
	table.sort(order)

	local parts: { string } = {}
	for _, name in order do
		local n = counts[name]
		table.insert(parts, if n > 1 then string.format("%s x%d", name, n) else name)
	end
	return table.concat(parts, ", ")
end

--[[ The report as one human sentence, or nil when the rig is clean. Kept beside
     diagnose so the wording of a fault lives in one place rather than once per
     caller — the boot summary and the Studio script must not describe the same
     rig differently. ]]
function RigUtil.describeFaults(report: RigReport): string?
	local parts: { string } = {}
	if not report.hasHumanoid then
		table.insert(parts, "NO HUMANOID")
	elseif not report.hasAnimator then
		table.insert(parts, "no Animator (cannot play any clip)")
	end
	if report.motorCount == 0 then
		table.insert(parts, "NO JOINTS AT ALL")
	end
	if #report.duplicates > 0 then
		table.insert(
			parts,
			string.format("%d duplicate joint(s): %s", #report.duplicates, RigUtil.tally(report.duplicates))
		)
	end
	if #report.disabled > 0 then
		table.insert(
			parts,
			string.format("%d DISABLED joint(s): %s", #report.disabled, RigUtil.tally(report.disabled))
		)
	end
	if #report.rivalWelds > 0 then
		table.insert(
			parts,
			string.format(
				"%d weld(s) beside a joint: %s",
				#report.rivalWelds,
				RigUtil.tally(report.rivalWelds)
			)
		)
	end
	if #report.backwards > 0 then
		table.insert(
			parts,
			string.format("%d backwards joint(s): %s", #report.backwards, RigUtil.tally(report.backwards))
		)
	end
	if #report.skewed > 0 then
		table.insert(
			parts,
			string.format(
				"%d joint(s) with their axes turned the wrong way: %s — the rest pose is correct, "
					.. "so the clip swings those limbs sideways instead of forward",
				#report.skewed,
				RigUtil.tally(report.skewed)
			)
		)
	end
	if #report.missingJoints > 0 then
		table.insert(parts, "missing " .. table.concat(report.missingJoints, ", "))
	end
	if #report.missingParts > 0 then
		table.insert(parts, "NO PART NAMED " .. table.concat(report.missingParts, ", "))
	end
	if #parts == 0 then
		return nil
	end
	return table.concat(parts, "; ")
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
