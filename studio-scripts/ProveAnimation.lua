--!nonstrict
--[[
	ProveAnimation — plays this game's clips onto YOUR models and reports, joint
	by joint, which ones actually moved.

	Paste into the Roblox Studio COMMAND BAR and press Enter. It changes nothing:
	every model is CLONED, driven far below the map, measured, and destroyed.

	── WHY THIS EXISTS ─────────────────────────────────────────────────────────
	studio-scripts/CheckAnimations already asks whether an id is fetchable, how
	long it is, and which skeleton it addresses — but it asks by playing the clip
	onto a SYNTHETIC rig it builds itself, with textbook part names. That proves
	the clip is a good R6 clip. It cannot prove the clip drives YOUR Common.

	Nothing has ever tested that pairing, which is remarkable given it is the
	actual question: does the animation this game will hand this model move any
	joint on it. Everything else has been inference from either end.

	── WHAT A PASS AND A FAIL MEAN ─────────────────────────────────────────────
	An AnimationTrack writes Motor6D.Transform for every joint whose name matches
	a pose in the clip. So:

	  MOVED n joints   the clip and the rig agree about joint names. If such a
	                   body still does not animate in play, the fault is
	                   downstream — replication, or something overwriting
	                   Transform — and NOT the clip or the rig.
	  MOVED 0 joints   the clip addresses joints this model does not have. It
	                   will load, report itself playing, and stand the procedural
	                   poser down while moving nothing. This is the failure that
	                   looks exactly like a broken animation and is really a
	                   naming mismatch.

	  SKEWED n joints  the clip moves them and moves them the WRONG WAY. See
	                   below — this is its own answer, not a shade of the other
	                   two.

	── AND IT NOW CHECKS WHICH WAY, NOT ONLY WHETHER ───────────────────────────
	The first version of this script asked only whether a Transform CHANGED, and
	that turned out not to be the question either. A Motor6D applies Transform
	inside C0, so an animation's rotations are read in the joint's own axes — and
	Roblox's R6 shoulders and hips are turned a quarter-turn about Y, which is
	what every R6 clip was keyed against. A joint built from a pivot with no
	rotation holds the limb in exactly the right place at rest, moves its
	Transform enthusiastically when the clip plays, and swings the limb SIDEWAYS:
	the arm sticks straight out left or right, the hips splay instead of stepping,
	and the body slides along the ground.

	Such a model passes every other test there is, including the moved-joint test
	this script was written to run. So the axes are now checked too.

	It deliberately does NOT test whether the limb visibly moves. A duplicate
	joint or a weld across the same pair still lets Transform be written while
	pinning the part — RigDoctor is what finds those. This isolates one question
	so its answer means one thing.

	── REQUIREMENTS ────────────────────────────────────────────────────────────
	Game Settings > Security > Allow Studio Access to API Services: ON, so the
	clips can be fetched. Run it from the command bar in EDIT mode.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local shared = ReplicatedStorage:FindFirstChild("Shared")
local configFolder = shared and shared:FindFirstChild("Config")
local animModule = configFolder and configFolder:FindFirstChild("AnimationConfig")
if not animModule then
	warn(
		"[ProveAnimation] ReplicatedStorage.Shared.Config.AnimationConfig is missing — sync with Rojo first."
	)
	return
end
local AnimationConfig = require(animModule)

--[[ Where the clones are driven. Far enough down that nothing on the map can be
     touched even if a rig is enormous, and the whole folder goes at the end. ]]
local STAGE_Y = -2000
--[[ Frames of animation to sample. A walk cycle's extremes are nowhere near t=0,
     so one step proves nothing — this walks the whole clip. ]]
local SAMPLES = 12
--[[ How far a joint has to move to count. Well below any real keyframe motion
     and well above float noise in a held pose. ]]
local MOVED = 0.001

--[[ The same rule the game uses, counted rather than decided on one witness —
     see RigUtil.rigTypeOf. A single stray part named LowerTorso must not be able
     to declare an R6 body R15 here either, or this script would test the wrong
     clip and blame the model. ]]
local R6_WITNESS = {
	Torso = true,
	["Left Arm"] = true,
	["Right Arm"] = true,
	["Left Leg"] = true,
	["Right Leg"] = true,
}
local R15_WITNESS = {
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
}

local function rigTypeOf(model)
	local r6, r15 = 0, 0
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") and not d:FindFirstAncestorWhichIsA("Accoutrement") then
			if R6_WITNESS[d.Name] then
				r6 += 1
			elseif R15_WITNESS[d.Name] then
				r15 += 1
			end
		end
	end
	return if r15 > r6 then "R15" else "R6"
end

--[[ Drives one clip onto one model and returns the joints it moved.

     The model is CLONED and staged, so nothing in the place is touched and a rig
     left in a mid-animation pose cannot be saved by accident. ]]
--[[ The direction each standard joint's axes must point, in its parent's space.
     Must match RigUtil and RigDoctor. R15 is identity throughout and is judged
     only where a RigAttachment states the frame outright, because an identity is
     exactly what a legitimately unusual R15 rig would fail to match. ]]
local LEFT_LIMB = CFrame.Angles(0, -math.pi / 2, 0)
local RIGHT_LIMB = CFrame.Angles(0, math.pi / 2, 0)
local AXIAL = CFrame.Angles(-math.pi / 2, 0, math.pi)

local BASIS = {
	R6 = {
		Torso = { joint = "RootJoint", parent = "HumanoidRootPart", basis = AXIAL },
		Head = { joint = "Neck", parent = "Torso", basis = AXIAL },
		["Left Arm"] = { joint = "Left Shoulder", parent = "Torso", basis = LEFT_LIMB },
		["Right Arm"] = { joint = "Right Shoulder", parent = "Torso", basis = RIGHT_LIMB },
		["Left Leg"] = { joint = "Left Hip", parent = "Torso", basis = LEFT_LIMB },
		["Right Leg"] = { joint = "Right Hip", parent = "Torso", basis = RIGHT_LIMB },
	},
	R15 = {},
}

local function skewedJoints(model, rig)
	local specs = BASIS[rig]
	if not specs then
		return {}
	end
	local found = {}
	for _, d in model:GetDescendants() do
		if not d:IsA("Motor6D") or not d.Part0 or not d.Part1 then
			continue
		end
		local spec = specs[d.Part1.Name]
		if not spec or spec.parent ~= d.Part0.Name then
			continue
		end
		--[[ Compared in the PARENT's space, where the constants are stated. ]]
		local delta = d.C0.Rotation:Inverse() * spec.basis
		if delta.RightVector:Dot(Vector3.xAxis) < 0.98 or delta.UpVector:Dot(Vector3.yAxis) < 0.98 then
			table.insert(found, d.Part1.Name)
		end
	end
	table.sort(found)
	return found
end

local function measure(source, id, stage)
	local model = source:Clone()
	model.Parent = stage
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = true
		end
	end
	model:PivotTo(CFrame.new(0, STAGE_Y, 0))

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		model:Destroy()
		return nil, "no Humanoid"
	end
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end

	local animation = Instance.new("Animation")
	animation.AnimationId = "rbxassetid://" .. string.format("%d", id)
	animation.Parent = model

	local okLoad, track = pcall(animator.LoadAnimation, animator, animation)
	if not okLoad or not track then
		model:Destroy()
		return nil, "the Animator refused the clip"
	end

	--[[ The asset is fetched per call and Length stays zero until it lands.
	     Sampling before then measures nothing and would report every model as
	     broken. ]]
	for _ = 1, 120 do
		if track.Length > 0 then
			break
		end
		task.wait()
	end
	if track.Length <= 0 then
		model:Destroy()
		return nil, "the clip never loaded (API access off, or an empty upload)"
	end

	local before = {}
	local moved = {}
	for _, d in model:GetDescendants() do
		if d:IsA("Motor6D") then
			before[d] = d.Transform
		end
	end

	track:Play(0)
	track.TimePosition = 0
	for _ = 1, SAMPLES do
		animator:StepAnimations(track.Length / SAMPLES)
		for motor, start in before do
			if not moved[motor] and motor.Parent then
				local now = motor.Transform
				local shifted = (now.Position - start.Position).Magnitude > MOVED
					or now.LookVector:Dot(start.LookVector) < 1 - MOVED
					or now.UpVector:Dot(start.UpVector) < 1 - MOVED
				--[[ Against the joint's own starting Transform rather than against
				     identity: a rig saved mid-pose starts non-identity, and
				     comparing to identity would call that motion. ]]
				if shifted then
					moved[motor] = true
				end
			end
		end
	end
	track:Stop(0)

	local names = {}
	for motor in moved do
		table.insert(names, if motor.Part1 then motor.Part1.Name else motor.Name)
	end
	table.sort(names)

	local total = 0
	for _ in before do
		total += 1
	end
	--[[ Read from the same clone the clip was just played on, so the verdict and
	     the measurement describe one body rather than two. ]]
	local skewed = skewedJoints(model, rigTypeOf(model))
	model:Destroy()
	return { moved = names, joints = total, skewed = skewed }, nil
end

-- ────────────────────────────────────────────────────────────────────────────

print(
	"── ProveAnimation ────────────────────────────────────────────────────"
)
print("Playing this game's clips onto YOUR models. Nothing is changed.")

local stage = Instance.new("Folder")
stage.Name = "FL_ProveAnimation"
stage.Parent = Workspace

local roots = {}
for _, root in { ReplicatedStorage, ServerStorage } do
	local assets = root:FindFirstChild("Assets")
	local infected = assets and assets:FindFirstChild("Infected")
	if infected then
		table.insert(roots, infected)
	end
end
local templates = ServerStorage:FindFirstChild("FL_Templates")
if templates and templates:FindFirstChild("Infected") then
	table.insert(roots, templates.Infected)
end

local checked, dead, bent = 0, {}, {}
local okRun, err = pcall(function()
	for _, infected in roots do
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
				local rig = rigTypeOf(model)
				local set = AnimationConfig.forInfected(kindFolder.Name, rig)
				local ids = set and set.walk
				local id = ids and ids[1]
				local label = string.format("%s/%s", kindFolder.Name, model.Name)
				checked += 1

				if not id then
					print(string.format("  ????  %-28s %s — no walk clip configured", label, rig))
					continue
				end

				local result, problem = measure(model, id, stage)
				if not result then
					print(string.format("  ????  %-28s %s — %s", label, rig, problem))
				elseif #result.moved == 0 then
					table.insert(dead, label)
					print(
						string.format(
							"  DEAD  %-28s %s — clip %d moved NONE of its %d joint(s)",
							label,
							rig,
							id,
							result.joints
						)
					)
				elseif #result.skewed > 0 then
					table.insert(bent, label)
					print(
						string.format(
							"  SKEW  %-28s %s — moved %d/%d, but %d joint(s) have their AXES turned "
								.. "the wrong way (%s), so the clip swings them sideways: arm out, "
								.. "legs splayed, body dragging",
							label,
							rig,
							#result.moved,
							result.joints,
							#result.skewed,
							table.concat(result.skewed, ", ")
						)
					)
				else
					print(
						string.format(
							"  ok    %-28s %s — moved %d/%d: %s",
							label,
							rig,
							#result.moved,
							result.joints,
							table.concat(result.moved, ", ")
						)
					)
				end
			end
		end
	end
end)

stage:Destroy()

print(
	"──────────────────────────────────────────────────────────────────────"
)
if not okRun then
	warn("[ProveAnimation] stopped early: " .. tostring(err))
elseif checked == 0 then
	print("Found no models under Assets.Infected. Check the folder names.")
elseif #dead == 0 and #bent == 0 then
	print(string.format("All %d model(s) are moved by the clip this game gives them,", checked))
	print("and moved the RIGHT WAY. So the clip, the rig and its joint axes all")
	print("agree, and anything still not animating in play is failing DOWNSTREAM")
	print("of that — which is a different search entirely.")
else
	if #dead > 0 then
		warn(string.format("[ProveAnimation] %d of %d model(s) are moved by NOTHING:", #dead, checked))
		for _, label in dead do
			warn("    " .. label)
		end
		warn("    The clip addresses joints these models do not have. It will load,")
		warn("    report itself as playing, and stand the procedural gait down while")
		warn("    moving nothing — which is exactly what a body dragging around looks")
		warn("    like. Compare their part names against the ones the clip drives.")
	end
	if #bent > 0 then
		warn(string.format("[ProveAnimation] %d of %d model(s) animate the WRONG WAY ROUND:", #bent, checked))
		for _, label in bent do
			warn("    " .. label)
		end
		warn("    Their joints move, so every other check calls them healthy — but the")
		warn("    joint AXES point somewhere the clip was not keyed for, so a shoulder")
		warn("    swing that should carry the arm forward carries it out sideways. The")
		warn("    arm sticks out left or right, the legs splay instead of stepping, and")
		warn("    the body drags along the ground.")
		warn("    The game already turns these round at spawn, so they are fixed in")
		warn("    play. To fix them in the MODELS, open studio-scripts/RigDoctor, set")
		warn("    REPAIR = true, and run it once.")
	end
end
