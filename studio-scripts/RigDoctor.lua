--!nonstrict
--[[
	RigDoctor — finds every infected model that cannot animate, and fixes it.

	Paste into the Roblox Studio COMMAND BAR and press Enter.

	It runs in REPORT mode first and changes nothing. Read what it says, then set
	REPAIR to true at the top and run it again. Repairs are one undo away
	(Ctrl+Z) because they happen inside a ChangeHistoryService waypoint.

	── THE SEVEN REASONS A RIG DOES NOT ANIMATE ────────────────────────────────
	  MISSING JOINT    the clip drives a Motor6D that is not there.       FIXABLE
	  BACKWARDS JOINT  it is there with Part0 and Part1 swapped. The animator
	                   reads Part1 as the bone, so the part the clip names is
	                   invisible to it and that one limb never moves.      FIXABLE
	  NO ANIMATOR      nothing under the Humanoid to load a track into, so
	                   the body plays no clip at all, ever.                FIXABLE
	  DUPLICATE JOINT  two Motor6Ds across the same pair. The assembly is
	                   over-constrained, so the clip drives one and the other
	                   holds the limb. Reads as "fully jointed" everywhere.  FIXABLE
	  DISABLED JOINT   Motor6D.Enabled is false. Serialized, defaults to true,
	                   invisible unless you select that exact joint — and the
	                   engine will not drive it.                            FIXABLE
	  NOT A CHARACTER  the parts are inside a Folder instead of directly under
	                   the Model. Roblox resolves a rig by name among the
	                   HUMANOID'S SIBLINGS, so Humanoid.RootPart is nil and the
	                   body is not a character at all. Every joint present,
	                   every name right, and nothing animates.                 YOU
	  MISSING PART     the joint needs two parts and one of them is called
	                   something else — "LeftArm" instead of "Left Arm".      YOU

	The last one is printed and never touched. Renaming a part is a judgement
	only the person who built the model can make; guessing which lump was meant
	to be the left arm would break more rigs than it fixed.

	── WHAT A "JOINT" IS AND WHY THIS MATTERS ──────────────────────────────────
	A Roblox rig is parts connected by Motor6Ds. That is what an animation drives,
	what the ragdoll replaces with constraints, and what dismemberment cuts. A
	model whose parts are WELDED — or not connected at all — looks completely
	normal in Studio and is completely broken in play:

	  * with no joints, the parts are loose. The Humanoid holds the root up at
	    hip height and everything else falls or hangs where it was placed. That
	    is the floating zombie, and because the brain drives the ROOT, it is also
	    a body that claws you while its mesh is somewhere else entirely.
	  * with SOME joints, the limbs that have one animate and the rest do not,
	    and only the jointed limbs can ever be blown off.

	The game repairs all three fixable faults at spawn, every spawn, so a broken
	model is playable rather than embarrassing. That is a bandage: the repair is
	guessed from standard proportions, it is thrown away with the body, and it is
	paid for again on the next one. Running this once writes the fix into the
	model, where it is exact and free.

	── WHY THE REPAIR CANNOT MOVE YOUR MODEL ───────────────────────────────────
	Both ends of every joint it builds are derived from where the parts ALREADY
	ARE. A Motor6D holds Part1 at `Part0.CFrame * C0 * C1:Inverse()`; setting C0
	and C1 from the same world pivot makes that expression evaluate to exactly
	the limb's current CFrame. So the pose you posed is the pose you keep, at any
	size and any proportion — this does not assume a 2x2x1 torso.
]]

-- ────────────────────────────────────────────────────────────────────────────
local REPAIR = false -- set to true to actually build the missing joints
-- ────────────────────────────────────────────────────────────────────────────

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

--[[ The R6 skeleton, parent -> child, with the pivot expressed in the PARENT's
     own space as fractions of the two parts' sizes. Fractions rather than studs
     so a half-scale Common and a 2.35x Tank both get their shoulder in the right
     place without a table per size. ]]
local R6 = {
	{ joint = "RootJoint", parent = "HumanoidRootPart", child = "Torso", at = Vector3.new(0, 0, 0) },
	{ joint = "Neck", parent = "Torso", child = "Head", at = Vector3.new(0, 0.5, 0) },
	{ joint = "Left Shoulder", parent = "Torso", child = "Left Arm", at = Vector3.new(-0.5, 0.25, 0) },
	{ joint = "Right Shoulder", parent = "Torso", child = "Right Arm", at = Vector3.new(0.5, 0.25, 0) },
	{ joint = "Left Hip", parent = "Torso", child = "Left Leg", at = Vector3.new(-0.25, -0.5, 0) },
	{ joint = "Right Hip", parent = "Torso", child = "Right Leg", at = Vector3.new(0.25, -0.5, 0) },
}

local R15 = {
	{ joint = "Root", parent = "HumanoidRootPart", child = "LowerTorso", at = Vector3.new(0, 0, 0) },
	{ joint = "Waist", parent = "LowerTorso", child = "UpperTorso", at = Vector3.new(0, 0.5, 0) },
	{ joint = "Neck", parent = "UpperTorso", child = "Head", at = Vector3.new(0, 0.5, 0) },
	{ joint = "LeftShoulder", parent = "UpperTorso", child = "LeftUpperArm", at = Vector3.new(-0.5, 0.4, 0) },
	{ joint = "LeftElbow", parent = "LeftUpperArm", child = "LeftLowerArm", at = Vector3.new(0, -0.5, 0) },
	{ joint = "LeftWrist", parent = "LeftLowerArm", child = "LeftHand", at = Vector3.new(0, -0.5, 0) },
	{
		joint = "RightShoulder",
		parent = "UpperTorso",
		child = "RightUpperArm",
		at = Vector3.new(0.5, 0.4, 0),
	},
	{ joint = "RightElbow", parent = "RightUpperArm", child = "RightLowerArm", at = Vector3.new(0, -0.5, 0) },
	{ joint = "RightWrist", parent = "RightLowerArm", child = "RightHand", at = Vector3.new(0, -0.5, 0) },
	{ joint = "LeftHip", parent = "LowerTorso", child = "LeftUpperLeg", at = Vector3.new(-0.5, -0.5, 0) },
	{ joint = "LeftKnee", parent = "LeftUpperLeg", child = "LeftLowerLeg", at = Vector3.new(0, -0.5, 0) },
	{ joint = "LeftAnkle", parent = "LeftLowerLeg", child = "LeftFoot", at = Vector3.new(0, -0.5, 0) },
	{ joint = "RightHip", parent = "LowerTorso", child = "RightUpperLeg", at = Vector3.new(0.5, -0.5, 0) },
	{ joint = "RightKnee", parent = "RightUpperLeg", child = "RightLowerLeg", at = Vector3.new(0, -0.5, 0) },
	{ joint = "RightAnkle", parent = "RightLowerLeg", child = "RightFoot", at = Vector3.new(0, -0.5, 0) },
}

local function partIn(model, name)
	local found = model:FindFirstChild(name, true)
	return if found and found:IsA("BasePart") then found else nil
end

--[[
	"R6" or "R15", by the same rule RigUtil.rigTypeOf uses.

	It has to be the same rule. This script decides which SKELETON to build and
	the game decides which CLIP SET to play, and an animation addresses named
	joints — so the two disagreeing means clips aimed at joints the rig does not
	have. They load, report themselves as playing, and move nothing.

	Searches, so parts grouped into a Folder while a model was being assembled
	still read as the R15 rig they are. Skips Accessories, so a hat carrying a
	part named UpperTorso cannot decide what the body underneath it animates
	with.
]]
local function rigTypeOf(model)
	for _, d in model:GetDescendants() do
		if not d:IsA("BasePart") then
			continue
		end
		if d.Name ~= "UpperTorso" and d.Name ~= "LowerTorso" then
			continue
		end
		if not d:FindFirstAncestorWhichIsA("Accessory") then
			--[[ The verdict AND the part that decided it. R15 is a positive test
			     with exactly one piece of evidence behind it, and that evidence is
			     the only useful reply to "but I built that as R6": one stray mesh
			     named LowerTorso inside an otherwise-R6 model is the whole bug,
			     and it hands the rig a clip set aimed at joints it does not have.
			     R6 is the absence of evidence and has none to give. ]]
			return "R15", d.Name
		end
	end
	return "R6", nil
end

--[[ Which end of each existing Motor6D is the child, by walking the rig outward
     from the root. The same rule the game uses — see RigUtil.mapMotorChildren —
     because a report that disagreed with the game about which joints a rig has
     would be worse than no report. ]]
local function mapChildren(model)
	local motors, touching, children = {}, {}, {}
	for _, d in model:GetDescendants() do
		if d:IsA("Motor6D") and d.Part0 and d.Part1 and d.Part0 ~= d.Part1 then
			table.insert(motors, d)
			touching[d.Part0] = touching[d.Part0] or {}
			touching[d.Part1] = touching[d.Part1] or {}
			table.insert(touching[d.Part0], d)
			table.insert(touching[d.Part1], d)
		end
	end
	--[[ NO EARLY RETURN. This used to be `if not root then return children end`,
	     which handed back an EMPTY map — and the caller reads that map to decide
	     which joints already exist, so an empty one says "none" and REPAIR MODE
	     then writes a complete duplicate skeleton into the saved place. Falling
	     through leaves the Part1 convention below to answer. ]]
	local root = partIn(model, "HumanoidRootPart") or model.PrimaryPart
	local seen, queue, head = {}, {}, 1
	if root then
		seen[root] = true
		table.insert(queue, root)
	end
	while head <= #queue do
		local part = queue[head]
		head += 1
		for _, motor in touching[part] or {} do
			if not children[motor] then
				local other = if motor.Part0 == part then motor.Part1 else motor.Part0
				if other and not seen[other] then
					seen[other] = true
					children[motor] = other
					table.insert(queue, other)
				end
			end
		end
	end
	--[[ Anything the walk never reached falls back to the convention, so a rig
	     with no root — or a limb not connected to it — still resolves rather than
	     silently vanishing from the map. ]]
	for _, d in motors do
		if not children[d] then
			children[d] = d.Part1
		end
	end
	return children, motors
end

--[[ Builds one joint without moving anything. The pivot is chosen in the
     parent's space and then BOTH C0 and C1 are measured to it from where the
     parts currently are, so the limb's world CFrame is unchanged. ]]
local function buildJoint(spec, parent, child)
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
	return motor
end

--[[ Welds between two rig parts are the usual reason a model has no joints: it
     was built by dragging parts together and Studio welded them. They have to
     GO — a weld and a Motor6D on the same pair fight, and the weld wins. ]]
local function clearWelds(model, parent, child)
	local removed = 0
	--[[ The MODEL, not `parent.Parent`. A weld does not have to live inside
	     either part it joins, and on a rig whose parts were grouped into a Folder
	     — the case rigTypeOf was widened to handle — the container is not the
	     model and half the welds are outside the search. ]]
	for _, d in model:GetDescendants() do
		if d:IsA("WeldConstraint") or d:IsA("Weld") or d:IsA("Snap") then
			-- All three expose Part0/Part1; there used to be a WeldConstraint
			-- branch here re-reading the same two fields, which did nothing.
			local a, b = d.Part0, d.Part1
			if (a == parent and b == child) or (a == child and b == parent) then
				d:Destroy()
				removed += 1
			end
		end
	end
	return removed
end

--[[
	A SECOND Motor6D across a pair that already has one.

	Until this was fixed, the game created these itself: buildMissingJoints
	decided which joints a rig already had from a graph walk, the walk needed a
	root, and RigUtil.getRoot searched only the model's direct children while
	every other lookup in that file searched descendants. So a rig whose parts sit
	inside a Folder — an ordinary way to assemble one — reported NO joints and got
	a complete second skeleton laid over its first.

	Two rigid joints on a pair over-constrains the assembly: the animation drives
	one and the other holds the limb, so the body slides in its rest pose. And
	every check ever written here called such a rig "fully jointed", because it
	is. It has too many joints, not too few.

	The first one in descendant order is kept — the model's own, since added ones
	are parented later.
]]
local function duplicateJoints(model, repair)
	local kept, found = {}, {}
	for _, d in model:GetDescendants() do
		if not (d:IsA("Motor6D") and d.Part0 and d.Part1 and d.Part0 ~= d.Part1) then
			continue
		end
		local spanned = kept[d.Part0]
		if spanned and spanned[d.Part1] then
			table.insert(found, d.Part0.Name .. "/" .. d.Part1.Name)
			if repair then
				d:Destroy()
			end
			continue
		end
		kept[d.Part0] = kept[d.Part0] or {}
		kept[d.Part1] = kept[d.Part1] or {}
		kept[d.Part0][d.Part1] = true
		kept[d.Part1][d.Part0] = true
	end
	table.sort(found)
	return found
end

--[[
	Welds that duplicate a Motor6D — the fault every other check here is blind to.

	Two rigid joints between the same two parts over-constrains the assembly.
	Roblox spans the rigid-joint graph and one of them decides the relative
	CFrame; when it is the weld, the animation writes the Motor6D's Transform
	every frame and the limb does not move. Which one wins is not guaranteed, so
	the symptom can be intermittent — a limb that animates in one place and not
	another, which reads as a flaky animation rather than a broken model.

	Reported for every rig, repaired only in REPAIR mode. Strictly PAIR-scoped:
	the test is "do these two parts already have a Motor6D between them", which
	is true only of a duplicate. A hat welded to a head, a weapon welded to a
	hand, the Boomer's hump welded to its torso — none of those pairs has a
	Motor6D, so none of them is touched.
]]
local function rivalWelds(model, repair)
	local jointed = {}
	for _, d in model:GetDescendants() do
		if d:IsA("Motor6D") and d.Part0 and d.Part1 and d.Part0 ~= d.Part1 then
			jointed[d.Part0] = jointed[d.Part0] or {}
			jointed[d.Part1] = jointed[d.Part1] or {}
			jointed[d.Part0][d.Part1] = true
			jointed[d.Part1][d.Part0] = true
		end
	end

	local found = {}
	for _, d in model:GetDescendants() do
		if not (d:IsA("Weld") or d:IsA("WeldConstraint") or d:IsA("Snap")) then
			continue
		end
		local a, b = d.Part0, d.Part1
		if not a or not b or not jointed[a] or not jointed[a][b] then
			continue
		end
		table.insert(found, a.Name .. "/" .. b.Name)
		if repair then
			d:Destroy()
		end
	end
	table.sort(found)
	return found
end

--[[
	Everything that stops a rig animating, in one pass. There are four, and only
	the first was ever checked:

	  1. a MISSING joint — the animation drives a Motor6D that is not there;
	  2. a BACKWARDS joint — it is there, wired the wrong way round, and the
	     animator therefore cannot see the part it is supposed to drive;
	  3. a MISSING PART — the joint cannot exist because one of the two parts it
	     connects is called something non-standard, or is absent;
	  4. no ANIMATOR under the Humanoid, so no track ever loads at all.

	Only 1, 2 and 4 are repairable from here. 3 is a rename, and it has to be a
	person doing it, because only they know which part was meant to be the arm.
]]
local function inspect(model, label)
	local children = mapChildren(model)
	local have = {}
	for _, child in children do
		have[child.Name] = true
	end

	local detected, decidedBy = rigTypeOf(model)
	local isR6 = detected == "R6"
	local rig = if isR6 then "R6" else string.format("R15 (has a part named %s)", decidedBy)
	local skeleton = if isR6 then R6 else R15
	local notes, fixes = {}, {}

	--[[
		BACKWARDS JOINTS. Roblox's animator takes each Motor6D's Part1 to be the
		bone and drives the pose named after that part, so a shoulder built
		Part0 = Left Arm, Part1 = Torso offers a bone called "Torso" and none
		called "Left Arm". The clip keys a shoulder the engine cannot find and the
		arm never moves, while the rest of the body animates perfectly — which is
		why this reads as a broken animation rather than a broken model.

		Swapping the parts AND swapping C0 with C1 leaves
		`Part0.CFrame * C0 == Part1.CFrame * C1` saying exactly what it said
		before, so nothing moves by a stud.
	]]
	--[[ Before anything else, because a rig with this fault passes every other
	     test in this file: the joints are all present, the parts are all named,
	     and the body still does not animate. ]]
	--[[ Parts that are not direct children of the Model. Roblox resolves a
	     character's rig by name among the HUMANOID'S SIBLINGS, so a rig assembled
	     inside a Folder has Humanoid.RootPart == nil and is not a character at
	     all — every joint present, every name right, and nothing can animate it.
	     Reported here and flattened by the game at boot; fixing it in the model
	     is the permanent version. ]]
	local nested = 0
	for _, d in model:GetDescendants() do
		if
			(d:IsA("BasePart") or d:IsA("Motor6D"))
			and d.Parent ~= model
			and not d:FindFirstAncestorWhichIsA("Accessory")
			and not (d:IsA("Motor6D") and d.Parent and d.Parent:IsA("BasePart"))
		then
			nested += 1
		end
	end
	if nested > 0 then
		table.insert(
			notes,
			string.format(
				"%d part(s) NOT directly under the Model — Humanoid.RootPart cannot resolve, so this "
					.. "is not a character and nothing can animate it. Move them up out of the Folder.",
				nested
			)
		)
	end
	if not model:FindFirstChild("HumanoidRootPart") then
		table.insert(notes, "no part called HumanoidRootPart directly under the Model")
	end

	--[[ Enabled is serialized, defaults to true, and is invisible unless you
	     select that exact joint. A disabled Motor6D satisfies every "fully
	     jointed" check and the engine refuses to drive it. ]]
	local disabled = {}
	for _, d in model:GetDescendants() do
		if d:IsA("Motor6D") and not d.Enabled then
			table.insert(disabled, if d.Part1 then d.Part1.Name else d.Name)
			if REPAIR then
				d.Enabled = true
			end
		end
	end
	if #disabled > 0 then
		table.sort(disabled)
		local line = string.format("%d DISABLED joint(s) (%s)", #disabled, table.concat(disabled, ", "))
		table.insert(if REPAIR then fixes else notes, if REPAIR then "re-enabled " .. line else line)
	end

	local dupes = duplicateJoints(model, REPAIR)
	if #dupes > 0 then
		local line = string.format("%d duplicate joint(s) (%s)", #dupes, table.concat(dupes, ", "))
		table.insert(if REPAIR then fixes else notes, if REPAIR then "removed " .. line else line)
	end

	local rivals = rivalWelds(model, REPAIR)
	if #rivals > 0 then
		local line =
			string.format("%d weld(s) duplicating a Motor6D (%s)", #rivals, table.concat(rivals, ", "))
		table.insert(if REPAIR then fixes else notes, if REPAIR then "cut " .. line else line)
	end

	local backwards = {}
	for motor, child in children do
		if motor.Part1 == child or motor.Part0 ~= child then
			continue
		end
		table.insert(backwards, child.Name)
		if REPAIR then
			local part0, part1 = motor.Part0, motor.Part1
			local c0, c1 = motor.C0, motor.C1
			motor.Part0 = part1
			motor.Part1 = part0
			motor.C0 = c1
			motor.C1 = c0
		end
	end
	if #backwards > 0 then
		table.sort(backwards)
		local line = string.format("%d backwards (%s)", #backwards, table.concat(backwards, ", "))
		table.insert(if REPAIR then fixes else notes, line)
	end

	--[[ NO ANIMATOR. Roblox makes one for a player's character and for nothing
	     else, so a rig assembled in Studio has one only if whatever it was copied
	     from happened to ship with it. Without it not a single track loads, and
	     the body walks, swings and dies in complete silence. ]]
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid and not humanoid:FindFirstChildOfClass("Animator") then
		if REPAIR then
			local animator = Instance.new("Animator")
			animator.Parent = humanoid
			table.insert(fixes, "added the missing Animator")
		else
			table.insert(notes, "no Animator under the Humanoid")
		end
	end

	--[[ The same hard guard the runtime uses: ask the two ACTUAL parts whether a
	     Motor6D already spans them. A name lookup can be defeated by an unusual
	     rig; this cannot, and in REPAIR mode the cost of being wrong is written
	     into the place. ]]
	local jointedPairs = {}
	for _, d in model:GetDescendants() do
		if d:IsA("Motor6D") and d.Part0 and d.Part1 and d.Part0 ~= d.Part1 then
			jointedPairs[d.Part0] = jointedPairs[d.Part0] or {}
			jointedPairs[d.Part1] = jointedPairs[d.Part1] or {}
			jointedPairs[d.Part0][d.Part1] = true
			jointedPairs[d.Part1][d.Part0] = true
		end
		if d:IsA("Motor6D") and d.Part1 then
			have[d.Part1.Name] = true
		end
	end

	local missing, built, welds, absent, absentSeen = {}, 0, 0, {}, {}
	for _, spec in skeleton do
		if have[spec.child] then
			continue
		end
		local parent, child = partIn(model, spec.parent), partIn(model, spec.child)
		--[[ The PART is absent, so there is nothing to joint. Sometimes that is
		     fine — plenty of rigs have no separate hands or feet — and sometimes
		     it is the whole problem, because a model whose arm is called
		     "LeftArm" instead of "Left Arm" gets no shoulder and plays a walk
		     clip that drives a shoulder it does not have. From here the two look
		     identical, so both are named and the reader decides. ]]
		if not parent or not child then
			--[[ Named one at a time rather than through a list: a table
			     constructor holding a nil ends a generic-for at the hole, so
			     "the parent is fine and the child is missing" would report
			     nothing at all. ]]
			if not parent and not absentSeen[spec.parent] then
				absentSeen[spec.parent] = true
				table.insert(absent, spec.parent)
			end
			if not child and not absentSeen[spec.child] then
				absentSeen[spec.child] = true
				table.insert(absent, spec.child)
			end
			continue
		end
		local spanned = jointedPairs[parent]
		if spanned and spanned[child] then
			continue
		end
		table.insert(missing, spec.joint)
		if REPAIR then
			welds += clearWelds(model, parent, child)
			buildJoint(spec, parent, child)
			built += 1
		end
	end

	if #missing > 0 then
		if REPAIR then
			table.insert(
				fixes,
				string.format(
					"built %d joint(s)%s: %s",
					built,
					if welds > 0 then string.format(" (removed %d weld(s))", welds) else "",
					table.concat(missing, ", ")
				)
			)
		else
			table.insert(notes, "missing: " .. table.concat(missing, ", "))
		end
	end
	if #absent > 0 then
		table.sort(absent)
		--[[ Always a note, never a fix: renaming a part is a judgement only the
		     person who built the model can make. ]]
		table.insert(notes, "NO PART NAMED " .. table.concat(absent, ", ") .. " — rename in Studio")
	end

	local issues = #missing + #backwards + #rivals + #dupes + #disabled
	if #notes == 0 and #fixes == 0 then
		print(string.format("  OK    %-28s %s, fully jointed", label, rig))
		return 0, 0
	end
	if #fixes > 0 then
		print(string.format("  FIXED %-28s %s, %s", label, rig, table.concat(fixes, "; ")))
	end
	if #notes > 0 then
		print(string.format("  NEEDS %-28s %s, %s", label, rig, table.concat(notes, "; ")))
	end
	return issues, built
end

-- ────────────────────────────────────────────────────────────────────────────

local recording = if REPAIR then ChangeHistoryService:TryBeginRecording("RigDoctor") else nil

print(
	"── RigDoctor ─────────────────────────────────────────────────────────"
)
print(
	if REPAIR
		then "REPAIR MODE — building joints. Ctrl+Z undoes all of it."
		else "REPORT ONLY — nothing is being changed."
)

local totalIssues, totalBuilt, scanned = 0, 0, 0
for _, root in { ReplicatedStorage, ServerStorage } do
	local assets = root:FindFirstChild("Assets")
	local infected = assets and assets:FindFirstChild("Infected")
	if not infected then
		continue
	end
	for _, kindFolder in infected:GetChildren() do
		local models = {}
		if kindFolder:IsA("Model") then
			table.insert(models, kindFolder)
		else
			for _, child in kindFolder:GetChildren() do
				if child:IsA("Model") then
					table.insert(models, child)
				end
			end
		end
		for _, model in models do
			scanned += 1
			local issues, built = inspect(model, kindFolder.Name .. "/" .. model.Name)
			totalIssues += issues
			totalBuilt += built
		end
	end
end

--[[
	── THE PREPARED TEMPLATES, AND THE BODIES THAT ARE ACTUALLY WALKING ────────

	Everything above inspects the RAW models you supplied, and every diagnostic
	this project has ever run has stopped there. The bodies in a round are two
	transformations further on:

	  1. PlaceholderFactory:adoptRig clones each source ONCE AT BOOT, unanchors
	     it, sets collision groups, scales it, strips its scripts, and parks the
	     result in ServerStorage.FL_Templates.Infected — deliberately NOT under
	     Assets, so nothing above sees it;
	  2. InfectedService clones THAT per spawn into Workspace.Infected, repairs
	     its joints, and loads its tracks.

	A fault introduced at either step is invisible to a scan of the assets, and
	both steps are where the interesting faults live. So both are scanned, and
	the live pass also dumps the four facts that decide whether a body animates
	and which nothing else reports: whether it has an Animator, how many tracks
	are actually playing on it, what the Humanoid thinks its state is, and
	whether it is standing on anything.

	RUN THIS FROM THE SERVER CONTEXT. During a playtest Studio's command bar
	defaults to the CLIENT, where ServerStorage does not exist and the infected
	Animator — which is server-side — has no tracks to report. Use the dropdown
	at the bottom-right of the Output window, or the Run/Play context switcher,
	and choose Server first.
]]
local function liveReport(model, label)
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
	local playing = {}
	if animator then
		local ok, tracks = pcall(animator.GetPlayingAnimationTracks, animator)
		if ok and typeof(tracks) == "table" then
			for _, t in tracks do
				table.insert(playing, string.format("%s@%.2fx", t.Name, t.Speed))
			end
		end
	end

	local verdict
	if not humanoid then
		verdict = "NO HUMANOID"
	elseif not animator then
		verdict = "NO ANIMATOR — cannot play a clip at all; the procedural poser is driving it"
	elseif #playing == 0 then
		verdict = "ANIMATOR PRESENT BUT NOTHING PLAYING — poser is driving it"
	else
		verdict = table.concat(playing, ", ")
	end

	local state = if humanoid then tostring(humanoid:GetState()) else "?"
	local floor = if humanoid then tostring(humanoid.FloorMaterial) else "?"
	print(string.format("  LIVE  %-28s %s", label, verdict))
	print(string.format("        %-28s state %s, floor %s", "", state, floor))
end

local live = 0
for _, folder in { ServerStorage:FindFirstChild("FL_Templates"), Workspace:FindFirstChild("Infected") } do
	local infected = if folder and folder.Name == "FL_Templates"
		then folder:FindFirstChild("Infected")
		else folder
	if not infected then
		continue
	end
	local where = if infected.Parent and infected.Parent.Name == "FL_Templates" then "template" else "live"
	for _, descendant in infected:GetChildren() do
		local models = {}
		if descendant:IsA("Model") then
			table.insert(models, descendant)
		else
			for _, child in descendant:GetChildren() do
				if child:IsA("Model") then
					table.insert(models, child)
				end
			end
		end
		for _, model in models do
			live += 1
			scanned += 1
			local issues, built = inspect(model, where .. ":" .. descendant.Name .. "/" .. model.Name)
			totalIssues += issues
			totalBuilt += built
			if where == "live" then
				liveReport(model, descendant.Name .. "/" .. model.Name)
			end
		end
	end
end
if live == 0 then
	print("")
	print("No prepared templates and no live bodies were visible from here.")
	print("ServerStorage.FL_Templates.Infected exists only after the server has booted,")
	print("and Workspace.Infected only while a round is running — so to inspect the")
	print("bodies that actually walk around, press Play, let a horde spawn, switch the")
	print("command bar to the SERVER context, and run this again.")
end

print(
	"──────────────────────────────────────────────────────────────────────"
)
if scanned == 0 then
	print("Found no models under Assets.Infected. Check the folder names.")
elseif REPAIR then
	print(string.format("Scanned %d model(s), built %d joint(s).", scanned, totalBuilt))
	print("Anything printed as NEEDS above is a RENAME, which this cannot do for you.")
	print("Play-test now. Re-run in REPORT mode to confirm everything reads OK.")
elseif totalIssues == 0 then
	print(string.format("Scanned %d model(s). Every one is rigged correctly — nothing to do.", scanned))
else
	print(string.format("Scanned %d model(s), %d repairable joint problem(s).", scanned, totalIssues))
	print("Set REPAIR = true at the top of this script and run it again to fix them.")
end

if recording then
	ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
end
