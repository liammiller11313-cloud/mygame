--!nonstrict
--[[
	CheckAnimations — asks Roblox, for real, whether every animation this game
	declares will actually play in THIS place.

	── HOW TO RUN IT ───────────────────────────────────────────────────────────
	  1. Sync the place with Rojo first, so ReplicatedStorage.Shared exists.
	  2. Game Settings > Security > Allow Studio Access to API Services: ON.
	  3. View > Command Bar, paste this whole file in, press Enter.

	It creates nothing permanent. A temporary rig appears in Workspace for a
	second and is destroyed before the script returns, even if something errors.

	── WHY THIS EXISTS ─────────────────────────────────────────────────────────
	An animation Roblox refuses fails SILENTLY. LoadAnimation does not throw for
	an id that is private, deleted, moderated, or owned by another account — it
	returns a perfectly ordinary AnimationTrack that reports itself as playing,
	has a Length of zero, and moves nothing. Every pcall around it takes the
	success branch. The gun just does not animate, and you find out by watching.

	Roblox only plays an animation owned by the PLACE'S CREATOR or by Roblox
	itself. An id you uploaded under your personal account, in a game owned by a
	group, is the usual way this happens — the id is fine, your account owns it,
	and this place still cannot use it.

	── THE THREE THINGS IT CHECKS ──────────────────────────────────────────────
	  FETCH   ContentProvider reports the real asset status. This is the one that
	          catches an unauthorized id, and it is the one you care about.
	  LENGTH  A clip that fetched but is zero seconds long is an empty upload —
	          an animation that was published before any keyframes were saved.
	          It will "play" and do nothing, exactly like a refused one.
	  RIG     Which joint names the clip actually moves: R6, R15, or both.

	That last one is the quietest failure of the three. A Roblox animation
	addresses joints BY NAME. An R6 clip moves "Left Arm" and "Right Hip"; an
	R15 rig has no joints by those names, so the clip fetches, has a real
	length, reports itself playing, and moves nothing — and because
	InfectedPoseController stands down for any body with a track playing, that
	body is animated by neither the clip nor the fallback. The result is a
	T-pose that looks exactly like the bug all of this exists to fix.

	It is detected rather than declared. The clip's own KeyframeSequence is
	fetched and its Pose objects are read: a Pose is NAMED for the part it
	drives, so a clip with a "Left Arm" pose is R6 and one with "LeftUpperArm"
	is R15, with no interpretation involved. Where that fetch is refused — it
	can be, for an asset this account does not own — it falls back to playing
	the clip onto a throwaway rig of each build and reading which Motor6Ds
	actually moved. Either way it is ground truth; the `rig` field in
	AnimationConfig is a claim, and this is the check on it.

	── WHAT "MY GUN ANIMATIONS DO NOT SHOW UP" USUALLY MEANS ───────────────────
	Usually, that they are working.

	Weapon clips play on the CHARACTER, in third person. They are what your
	TEAMMATES see. You never see your own, and not by accident: the camera is
	CameraMode.LockFirstPerson, ViewmodelController hides your own body with
	LocalTransparencyModifier, and the first-person arms it puts there instead
	are anchored parts with every joint stripped out — they cannot play an
	animation at all, by construction. What kicks the gun in your own hands is
	procedural, and uses no assets.

	So to see them: Test > Clients and Servers > 2 players, and watch the OTHER
	window. If the clip still does nothing there, the rig column below is the
	thing to read.
]]

local ContentProvider = game:GetService("ContentProvider")
local KeyframeSequenceProvider = game:GetService("KeyframeSequenceProvider")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local shared = ReplicatedStorage:FindFirstChild("Shared")
local configFolder = shared and shared:FindFirstChild("Config")
local module = configFolder and configFolder:FindFirstChild("AnimationConfig")
if not module then
	warn(
		"[CheckAnimations] ReplicatedStorage.Shared.Config.AnimationConfig is missing — sync with Rojo first."
	)
	return
end

local AnimationConfig = require(module)

--[[ Every declared id with a HUMAN LABEL, because "111410151816711 failed" is
     not actionable and "Pistol fire failed" is. Built from the same tables
     AnimationConfig.allIds walks, so a set added there shows up here too. ]]
local labels: { [number]: { string } } = {}
local order: { number } = {}

local function note(id: any, label: string)
	if typeof(id) ~= "number" or id <= 0 then
		return
	end
	if not labels[id] then
		labels[id] = {}
		table.insert(order, id)
	end
	table.insert(labels[id], label)
end

for class, set in AnimationConfig.Weapon do
	for role, id in set do
		note(id, string.format("%s %s", class, role))
	end
end
for role, id in AnimationConfig.WeaponFallback do
	note(id, string.format("fallback %s", role))
end
for rig, id in AnimationConfig.SurvivorHold do
	note(id, string.format("survivor hold (%s)", rig))
end
for rig, set in AnimationConfig.ByRig do
	for role, ids in set do
		if role ~= "rig" and typeof(ids) == "table" then
			for _, id in ids do
				note(id, string.format("infected %s %s", rig, role))
			end
		end
	end
end
for kind, set in AnimationConfig.Infected do
	for role, ids in set do
		if role ~= "rig" and typeof(ids) == "table" then
			for _, id in ids do
				note(id, string.format("%s %s", kind, role))
			end
		end
	end
end

if #order == 0 then
	warn("[CheckAnimations] nothing declared — that is itself the bug.")
	return
end

print(string.format("[CheckAnimations] asking Roblox about %d ids...", #order))

--[[ One Animation instance per id, kept parented for the whole check. A
     destroyed instance leaves its track unable to resolve the asset fetch,
     which would make this script reproduce the very bug it is looking for. ]]
local holder = Instance.new("Folder")
holder.Name = "FL_CheckAnimations"
holder.Parent = Workspace

local animations: { [number]: Animation } = {}
local pending: { Animation } = {}
for _, id in order do
	local animation = Instance.new("Animation")
	animation.Name = tostring(id)
	animation.AnimationId = "rbxassetid://" .. string.format("%d", id)
	animation.Parent = holder
	animations[id] = animation
	table.insert(pending, animation)
end

local fetched: { [string]: boolean } = {}
local reason: { [string]: string } = {}

local okPreload, preloadErr = pcall(function()
	ContentProvider:PreloadAsync(pending, function(contentString: string, status: any)
		fetched[contentString] = status == Enum.AssetFetchStatus.Success
		reason[contentString] = tostring(status)
	end)
end)

--[[
	Two throwaway rigs to play the clips onto: one built with R6 joint names and
	one with R15. Only the NAMES matter — an animation looks up a Motor6D by
	name and writes its Transform, so a rig of plain blocks reports exactly what
	a real character would.

	Both are parked far under the map and destroyed before this script returns.
]]
local R6_JOINTS = {
	{ "RootJoint", "HumanoidRootPart", "Torso" },
	{ "Neck", "Torso", "Head" },
	{ "Left Shoulder", "Torso", "Left Arm" },
	{ "Right Shoulder", "Torso", "Right Arm" },
	{ "Left Hip", "Torso", "Left Leg" },
	{ "Right Hip", "Torso", "Right Leg" },
}

local R15_JOINTS = {
	{ "Root", "HumanoidRootPart", "LowerTorso" },
	{ "Waist", "LowerTorso", "UpperTorso" },
	{ "Neck", "UpperTorso", "Head" },
	{ "LeftShoulder", "UpperTorso", "LeftUpperArm" },
	{ "LeftElbow", "LeftUpperArm", "LeftLowerArm" },
	{ "RightShoulder", "UpperTorso", "RightUpperArm" },
	{ "RightElbow", "RightUpperArm", "RightLowerArm" },
	{ "LeftHip", "LowerTorso", "LeftUpperLeg" },
	{ "LeftKnee", "LeftUpperLeg", "LeftLowerLeg" },
	{ "RightHip", "LowerTorso", "RightUpperLeg" },
	{ "RightKnee", "RightUpperLeg", "RightLowerLeg" },
}

local function buildRig(name: string, joints: { { string } })
	local model = Instance.new("Model")
	model.Name = name

	local parts: { [string]: BasePart } = {}
	local function part(partName: string): BasePart
		local existing = parts[partName]
		if existing then
			return existing
		end
		local created = Instance.new("Part")
		created.Name = partName
		created.Size = Vector3.new(1, 1, 1)
		created.Anchored = false
		created.CanCollide = false
		created.Transparency = 1
		created.CFrame = CFrame.new(0, -600, 0)
		created.Parent = model
		parts[partName] = created
		return created
	end

	local root = part("HumanoidRootPart")
	root.Anchored = true
	model.PrimaryPart = root

	for _, entry in joints do
		local motor = Instance.new("Motor6D")
		motor.Name = entry[1]
		motor.Part0 = part(entry[2])
		motor.Part1 = part(entry[3])
		motor.Parent = motor.Part0
	end

	local humanoid = Instance.new("Humanoid")
	humanoid.Parent = model
	local animator = Instance.new("Animator")
	animator.Parent = humanoid
	model.Parent = Workspace

	return model, animator
end

local r6Model, r6Animator = buildRig("FL_CheckR6", R6_JOINTS)
local r15Model, r15Animator = buildRig("FL_CheckR15", R15_JOINTS)

--[[ Whether this clip moved anything on this rig.

     Stepped by hand rather than waited on: in edit mode nothing advances an
     Animator on its own, and StepAnimations is the supported way to drive one.
     Sampled at several points through the clip because a keyframe at t=0 that
     matches the rest pose would read as "moved nothing" from a single step. ]]
local IDENTITY = CFrame.new()
local function movesRig(animator: Animator, model: Model, animation: Animation): (boolean, number)
	local okLoad, track = pcall(animator.LoadAnimation, animator, animation)
	if not okLoad or not track then
		return false, 0
	end

	local length = 0
	for _ = 1, 30 do
		if track.Length > 0 then
			break
		end
		task.wait()
	end
	length = track.Length

	local moved = false
	pcall(function()
		track:Play(0)
		track.TimePosition = 0
		for step = 1, 8 do
			animator:StepAnimations(if length > 0 then length / 8 else 0.1)
			for _, descendant in model:GetDescendants() do
				if descendant:IsA("Motor6D") and descendant.Transform ~= IDENTITY then
					moved = true
					break
				end
			end
			if moved then
				break
			end
			if step == 8 then
				break
			end
		end
		track:Stop(0)
	end)
	track:Destroy()
	return moved, length
end

--[[
	The parts that belong to exactly one build. Names common to both — Head,
	HumanoidRootPart — are deliberately absent: a clip that keys only those says
	nothing about which rig it is for, and counting them would let a head-turn
	animation claim to be both.
]]
local R6_ONLY = {
	Torso = true,
	["Left Arm"] = true,
	["Right Arm"] = true,
	["Left Leg"] = true,
	["Right Leg"] = true,
}
local R15_ONLY = {
	UpperTorso = true,
	LowerTorso = true,
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
}

--[[ The clip's own keyframes, which name the parts they drive. This is the
     answer rather than an estimate of it — but the fetch can be refused for an
     asset this account does not own, so it reports "no answer" separately from
     "neither build" and lets the caller fall back. ]]
local function rigFromKeyframes(id: number): string?
	local ok, sequence = pcall(function()
		return KeyframeSequenceProvider:GetKeyframeSequenceAsync("rbxassetid://" .. string.format("%d", id))
	end)
	if not ok or not sequence then
		return nil
	end

	local sawR6, sawR15 = false, false
	for _, descendant in sequence:GetDescendants() do
		if descendant:IsA("Pose") then
			if R6_ONLY[descendant.Name] then
				sawR6 = true
			elseif R15_ONLY[descendant.Name] then
				sawR15 = true
			end
		end
	end
	sequence:Destroy()

	if sawR6 and sawR15 then
		return "both"
	elseif sawR6 then
		return "R6"
	elseif sawR15 then
		return "R15"
	end
	return nil
end

local lengths: { [number]: number } = {}
local rigs: { [number]: string } = {}
for _, id in order do
	local animation = animations[id]
	local onR6, lengthR6 = movesRig(r6Animator, r6Model, animation)
	local onR15, lengthR15 = movesRig(r15Animator, r15Model, animation)

	lengths[id] = math.max(lengthR6, lengthR15)

	--[[ The keyframes first, because they are the clip itself. The play test is
	     the fallback: StepAnimations is the only way to advance a track in edit
	     mode and it is the part of this most likely to be the thing that broke,
	     whereas a Pose named "Left Arm" cannot mean anything else. ]]
	local declared = rigFromKeyframes(id)
	if declared then
		rigs[id] = declared
	elseif onR6 and onR15 then
		rigs[id] = "both"
	elseif onR6 then
		rigs[id] = "R6"
	elseif onR15 then
		rigs[id] = "R15"
	else
		--[[ Not a verdict. A clip that fetched and has a length but moved
		     neither rig is either keying joints neither of these has, or the
		     step did not take — and calling that "broken" on this evidence would
		     be worse than saying so. ]]
		rigs[id] = "?"
	end
end

r6Model:Destroy()
r15Model:Destroy()
holder:Destroy()

if not okPreload then
	warn(string.format("[CheckAnimations] PreloadAsync itself failed: %s", tostring(preloadErr)))
	warn("[CheckAnimations] the usual cause is Studio Access to API Services being off.")
end

--[[ What rig each id is EXPECTED to address, from where it is declared — so a
     clip that turns out to be R15 sitting in the R6 set can be named as the
     mismatch it is rather than merely described. ]]
local expected: { [number]: string } = {}
for rig, set in AnimationConfig.ByRig do
	for role, ids in set do
		if role ~= "rig" and typeof(ids) == "table" then
			for _, id in ids do
				expected[id] = rig
			end
		end
	end
end
for _, set in AnimationConfig.Infected do
	if typeof(set.rig) == "string" then
		for role, ids in set do
			if role ~= "rig" and typeof(ids) == "table" then
				for _, id in ids do
					expected[id] = set.rig
				end
			end
		end
	end
end
for rig, id in AnimationConfig.SurvivorHold do
	expected[id] = rig
end

--[[
	Weapon clips play on the SURVIVOR, so the rig they have to match is whatever
	your players spawn as — R15 unless Game Settings > Avatar > Rig Type says
	otherwise, since that is Roblox's default and this place does not override it.

	AnimationConfig.Weapon declares no rig on purpose: a weapon clip addressing
	the wrong joints does not stand the procedural poser down the way an infected
	one does, so nothing is gated on it at runtime. Which makes it exactly the
	case worth checking HERE, because nothing else ever will.
]]
local SURVIVOR_RIG = "R15"
for _, set in AnimationConfig.Weapon do
	for _, id in set do
		if typeof(id) == "number" then
			expected[id] = SURVIVOR_RIG
		end
	end
end

local broken, empty, mismatched, unknown, good = {}, {}, {}, {}, 0

local RULE = string.rep("─", 70)

print("")
print("  status   id                 length  rig     what it is")
print("  " .. RULE)
for _, id in order do
	local key = "rbxassetid://" .. string.format("%d", id)
	local what = table.concat(labels[id], ", ")
	local length = lengths[id] or 0
	local rig = rigs[id] or "?"
	local want = expected[id]
	local status

	if fetched[key] == false then
		status = "REFUSED"
		table.insert(broken, string.format("%s (%s) — %s", tostring(id), what, reason[key] or "?"))
	elseif length <= 0 then
		status = "EMPTY  "
		table.insert(empty, string.format("%s (%s)", tostring(id), what))
	elseif want and rig ~= "?" and rig ~= "both" and rig ~= want then
		status = "WRONG  "
		table.insert(
			mismatched,
			string.format("%s (%s) is a %s clip, declared under %s", tostring(id), what, rig, want)
		)
	elseif rig == "?" then
		status = "?      "
		table.insert(unknown, string.format("%s (%s)", tostring(id), what))
	else
		status = "ok     "
		good += 1
	end

	print(string.format("  %s  %-18s %5.2fs  %-6s  %s", status, tostring(id), length, rig, what))
end

print("")
if #broken == 0 and #empty == 0 and #mismatched == 0 and #unknown == 0 then
	print(string.format("[CheckAnimations] all %d ids load and have real clips behind them.", good))
else
	if #broken > 0 then
		warn(string.format("[CheckAnimations] %d id(s) THIS PLACE MAY NOT USE:", #broken))
		for _, line in broken do
			warn("    " .. line)
		end
		warn("    Re-upload these under the account or group that owns this PLACE.")
		warn("    An id uploaded under your personal account cannot be used by a")
		warn("    group-owned game, and vice versa. The id is not the problem — who")
		warn("    owns it is.")
	end
	if #empty > 0 then
		warn(string.format("[CheckAnimations] %d id(s) fetched but are zero seconds long:", #empty))
		for _, line in empty do
			warn("    " .. line)
		end
		warn("    These were published with no keyframes saved. Open each in the")
		warn("    Animation Editor, check it actually has poses on the timeline, and")
		warn("    publish again.")
	end
	if #mismatched > 0 then
		warn(string.format("[CheckAnimations] %d id(s) address the WRONG RIG:", #mismatched))
		for _, line in mismatched do
			warn("    " .. line)
		end
		warn("    These load, have a real length, and move nothing on the bodies")
		warn("    they are given to. An animation addresses joints BY NAME, and an")
		warn('    R6 clip finds no "Left Arm" on an R15 rig. Worse, the procedural')
		warn("    poser stands down for any body with a track playing, so what you")
		warn("    get is a T-pose. Move the id to the other set in AnimationConfig,")
		warn("    or re-record it on a rig of the right build.")
		warn("    Weapon clips are expected to be " .. SURVIVOR_RIG .. ", because that is what")
		warn("    survivors spawn as. If yours were recorded on the same dummy as the")
		warn("    zombie clips, they are R6 — and that is exactly why the zombies")
		warn("    animate and the guns do not.")
	end
	if #unknown > 0 then
		warn(string.format("[CheckAnimations] %d id(s) moved neither test rig:", #unknown))
		for _, line in unknown do
			warn("    " .. line)
		end
		warn("    Not necessarily broken. These key joints that neither a stock R6")
		warn("    nor a stock R15 rig has — a custom rig with its own joint names is")
		warn("    the usual reason, and such a clip is fine on THAT rig and useless")
		warn("    on anything else. Check it against the model it was made for.")
	end
	print(string.format("[CheckAnimations] %d of %d are fine.", good, #order))
end
