--!nonstrict
--[[
	RigDoctor — finds every infected model that cannot animate, and fixes it.

	Paste into the Roblox Studio COMMAND BAR and press Enter.

	It runs in REPORT mode first and changes nothing. Read what it says, then set
	REPAIR to true at the top and run it again. Repairs are one undo away
	(Ctrl+Z) because they happen inside a ChangeHistoryService waypoint.

	── THE FOUR REASONS A RIG DOES NOT ANIMATE ─────────────────────────────────
	  MISSING JOINT    the clip drives a Motor6D that is not there.       FIXABLE
	  BACKWARDS JOINT  it is there with Part0 and Part1 swapped. The animator
	                   reads Part1 as the bone, so the part the clip names is
	                   invisible to it and that one limb never moves.      FIXABLE
	  NO ANIMATOR      nothing under the Humanoid to load a track into, so
	                   the body plays no clip at all, ever.                FIXABLE
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
			return "R15"
		end
	end
	return "R6"
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
	local root = partIn(model, "HumanoidRootPart") or model.PrimaryPart
	if not root then
		return children, motors
	end
	local seen, queue, head = { [root] = true }, { root }, 1
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
local function clearWelds(parent, child)
	local removed = 0
	for _, d in parent.Parent:GetDescendants() do
		if d:IsA("WeldConstraint") or d:IsA("Weld") or d:IsA("Snap") then
			local a, b = d.Part0, d.Part1
			if d:IsA("WeldConstraint") then
				a, b = d.Part0, d.Part1
			end
			if (a == parent and b == child) or (a == child and b == parent) then
				d:Destroy()
				removed += 1
			end
		end
	end
	return removed
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

	local isR6 = rigTypeOf(model) == "R6"
	local rig = if isR6 then "R6" else "R15"
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
		table.insert(missing, spec.joint)
		if REPAIR then
			welds += clearWelds(parent, child)
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

	local issues = #missing + #backwards
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
