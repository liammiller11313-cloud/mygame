--!nonstrict
--[[
	RigDoctor — finds every unrigged infected model, and can rig them for you.

	Paste into the Roblox Studio COMMAND BAR and press Enter.

	It runs in REPORT mode first and changes nothing. Read what it says, then set
	REPAIR to true at the top and run it again to have it build the missing
	joints. Repairs are one undo away (Ctrl+Z) because they happen inside a
	ChangeHistoryService waypoint.

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

	The game now welds a jointless body together at spawn so it cannot come apart
	in mid-air. That is a bandage, not a fix — a welded body still cannot animate
	and still cannot be dismembered. This is the fix.

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

local function inspect(model, label)
	local children = mapChildren(model)
	local have = {}
	for _, child in children do
		have[child.Name] = true
	end

	local isR6 = partIn(model, "UpperTorso") == nil
	local skeleton = if isR6 then R6 else R15

	local missing, built, welds = {}, 0, 0
	for _, spec in skeleton do
		if have[spec.child] then
			continue
		end
		local parent, child = partIn(model, spec.parent), partIn(model, spec.child)
		if not parent or not child then
			-- The part itself is absent. Not something this can fix, and not
			-- necessarily wrong: plenty of rigs have no separate hands or feet.
			continue
		end
		table.insert(missing, spec.joint)
		if REPAIR then
			welds += clearWelds(parent, child)
			buildJoint(spec, parent, child)
			built += 1
		end
	end

	local rig = if isR6 then "R6" else "R15"
	if #missing == 0 then
		print(string.format("  OK    %-28s %s, fully jointed", label, rig))
		return 0, 0
	end
	if REPAIR then
		print(
			string.format(
				"  FIXED %-28s %s, built %d joint(s)%s: %s",
				label,
				rig,
				built,
				if welds > 0 then string.format(" (removed %d weld(s))", welds) else "",
				table.concat(missing, ", ")
			)
		)
	else
		print(string.format("  NEEDS %-28s %s, missing: %s", label, rig, table.concat(missing, ", ")))
	end
	return #missing, built
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

local totalMissing, totalBuilt, scanned = 0, 0, 0
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
			local missing, built = inspect(model, kindFolder.Name .. "/" .. model.Name)
			totalMissing += missing
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
	print("Play-test now. Re-run in REPORT mode to confirm everything reads OK.")
elseif totalMissing == 0 then
	print(string.format("Scanned %d model(s). Every one is fully jointed — nothing to do.", scanned))
else
	print(string.format("Scanned %d model(s), %d joint(s) missing in total.", scanned, totalMissing))
	print("Set REPAIR = true at the top of this script and run it again to build them.")
end

if recording then
	ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
end
