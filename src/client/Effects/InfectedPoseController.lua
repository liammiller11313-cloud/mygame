--!nonstrict
--[[
	InfectedPoseController — the horde's walk cycle, generated rather than played.

	PlaceholderFactory strips every script out of a Toolbox rig before it enters
	the world, because a free model with `require(<id>)` in it runs with full
	server permissions. That takes the `Animate` script with it, and with it the
	walk cycle — so a body that has no harvested animation ids slides around the
	map in a T-pose. InfectedAnimator plays ids when a rig ships them. Most do
	not, which is what this is for.

	Nothing here is an uploaded asset. Every pose is arithmetic on the rig's own
	Motor6D joints, which means it works on any rig, R6 or R15, supplied or
	procedural, with no dependency on anyone's animation library.

	── WHY THIS IS BETTER THAN A CLIP, FOR ZOMBIES SPECIFICALLY ─────────────────
	A single uploaded walk cycle played on forty-six bodies is forty-six copies of
	the same silhouette moving in lockstep, and the eye picks that out instantly —
	it reads as one animation, not as a crowd. Every body here gets its own seed,
	and the seed moves the phase, the limb amplitudes, the head tilt, the lean and
	which leg drags. Two Commons walking side by side never match, which is most
	of what makes a horde read as a horde.

	── WHY THE CLIENT ──────────────────────────────────────────────────────────
	Motor6D.C0 replicates, which is why InfectedBrain can pose the attack windup
	from the server for the cost of two property writes. A CONTINUOUS gait is a
	different proposition: forty-six bodies times eight joints times sixty frames
	is a quarter of a million replicated property writes a second, which is not a
	budget, it is a denial of service.

	So the gait runs on each client, over its own joints, and costs no bandwidth
	at all. It also means a client only has to animate what it can see, which is
	where the distance cull below comes from.

	── HOW IT LAYERS ───────────────────────────────────────────────────────────
	This writes Motor6D.Transform; the server writes Motor6D.C0. The engine
	resolves a joint as `C0 * Transform * C1:Inverse()`, so the two compose: the
	brain's attack windup and this walk cycle are both visible at once, and
	neither has to know about the other.

	And when a rig DOES ship animation ids, InfectedAnimator's tracks own
	Transform — the Animator rewrites it every frame and would fight us. So a rig
	with anything playing is skipped entirely. This is the fallback, and it gets
	out of the way of the real thing.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attributes = require(Shared.Net.Attributes)
local InfectedConfig = require(Shared.Config.InfectedConfig)
local Device = require(Shared.Util.Device)
local Registry = require(Shared.Util.Registry)
--[[ For the rig lookups ONLY. The server and this file were resolving the same
     rig in different ways and getting different answers — see resolveJoints. ]]
local RigUtil = require(Shared.Util.RigUtil)
local Trove = require(Shared.Util.Trove)

local IA = Attributes.Infected

local InfectedPoseController = {}

local player = Players.LocalPlayer
local trove = Trove.new()

-- ── tuning ──────────────────────────────────────────────────────────────────

--[[
	── THESE THREE ARE THE WHOLE COST CONTROL, AND THEY WERE DEVICE-BLIND ───────
	This loop poses every live body every frame and the map allows sixty Commons
	at once, which makes it the largest single per-frame cost the client has. A
	phone was animating exactly the same 220-stud horde a desktop was.

	Scaled rather than capped. A cap — "pose the nearest N" — sounds equivalent
	and is worse: it needs a per-frame sort, it desynchronises stride from
	distance, and on a bad frame it can freeze the body that is currently chewing
	on you, which is the one body that must never stop moving. Shrinking the
	bands keeps the rule "closer bodies get more" intact and simply draws the
	circle tighter.

	At 130 studs a Common on a phone screen is a couple of pixels tall. At 50 the
	stride drop is invisible. Neither number changes what a player can SEE well
	enough to act on; they change how much is spent on what they cannot.
]]
local CULL_DISTANCE = 220
local CULL_DISTANCE_SQUARED = CULL_DISTANCE * CULL_DISTANCE
local NEAR_DISTANCE = 90
local NEAR_DISTANCE_SQUARED = NEAR_DISTANCE * NEAR_DISTANCE
local FAR_STRIDE = 3

--[[ Whether to take the dynamic shadow casters off each rig as it appears. See
     stripShadows. Declared HERE, above the function that assigns it: below it,
     `dropRigShadows = ...` is not in scope and silently writes a global instead
     — audit.py check 11 catches that, and caught this. ]]
local dropRigShadows = false

--[[ Re-read at start and whenever Device revises its answer. Not resolved at
     module scope: Device deliberately answers Mobile before the camera exists,
     and a desktop that asked too early would spend the round posing a 130-stud
     horde. The values above are the desktop defaults and the floor. ]]
local function adoptDeviceBands()
	CULL_DISTANCE = Device.pick({ Mobile = 130, Tablet = 170 }, 220)
	CULL_DISTANCE_SQUARED = CULL_DISTANCE * CULL_DISTANCE
	NEAR_DISTANCE = Device.pick({ Mobile = 50, Tablet = 70 }, 90)
	NEAR_DISTANCE_SQUARED = NEAR_DISTANCE * NEAR_DISTANCE
	--[[ Every fourth frame past the near band rather than every third. A walk
	     cycle at 15Hz reads fine at fifty studs on a five-inch screen, and this
	     is the term that scales with the number of bodies rather than with
	     distance. ]]
	FAR_STRIDE = Device.pick({ Mobile = 4, Tablet = 4 }, 3)
	dropRigShadows = Device.isHandheld()
end

--[[ Below this a body is standing. Deliberately generous: a zombie being shoved
     around by its own pathfinding drifts at one or two studs a second, and a
     walk cycle that flickers on and off at every nudge is worse than one that
     waits. ]]
local MOVING_EPSILON = 1.5

--[[ Strides per stud travelled. A gait tied to distance rather than to time is
     what stops the feet skating: walk slower, the legs swing slower, and the
     contact point stays under the body. ]]
local STRIDE_PER_STUD = 0.42

--[[ Radians. The shamble, at walking pace.

	The asymmetry is the whole character of it. A zombie does not walk, it falls
	forward and catches itself, so the legs swing unevenly, the arms hang rather
	than counter-swing properly, and the torso is already past where the feet
	are. Everything below is small — the difference between "shambling" and
	"doing callisthenics" is about fifteen degrees.
]]
local WALK = table.freeze({
	LegSwing = 0.62,
	ArmSwing = 0.30,
	ArmHang = 0.34, -- constant forward droop; zombies do not swing their arms back
	ElbowBend = 0.55, -- R15 only
	KneeBend = 0.42, -- R15 only
	TorsoLean = 0.14,
	TorsoRoll = 0.07, -- side-to-side lurch, once per full stride
	HeadLoll = 0.22,
	HeadBob = 0.06,
})

--[[ The run. Not "the walk, faster" — a sprinting infected is falling forward
     with its arms up, which is a different shape, and the Hunter and the Charger
     both cross into it at speed. ]]
local RUN = table.freeze({
	LegSwing = 0.95,
	ArmSwing = 0.52,
	ArmHang = 0.85, -- arms come up and forward, reaching
	ElbowBend = 1.05,
	KneeBend = 0.80,
	TorsoLean = 0.34,
	TorsoRoll = 0.10,
	HeadLoll = 0.16,
	HeadBob = 0.10,
})

--[[ Standing still. Almost nothing, on purpose: a body that sways obviously
     reads as idling, and an idle zombie should read as WAITING. The only real
     motion is the breath, and it is slow enough to be felt rather than seen. ]]
local IDLE = table.freeze({
	BreathRate = 1.15,
	BreathAmount = 0.045,
	SwaySpeed = 0.55,
	SwayAmount = 0.05,
	HeadLoll = 0.26,
})

-- How fast a body eases between standing, walking and running.
local BLEND_SPEED = 6.0

--[[ The blend from walk to run across the band between the two configured
     speeds. Below the walk speed it is all walk, above the run speed all run. ]]
local RUN_BLEND_FLOOR = 0.55

-- ── joints ──────────────────────────────────────────────────────────────────

--[[
	Both rig conventions, by Motor6D name.

	`sign` flips the swing for the limb on the other side, so one phase drives
	both. `lead` marks the joints that swing WITH the stride (legs, and the
	opposite arm) versus against it.
]]
--[[
	Keyed on the CHILD PART each joint drives, not on the joint's own name.

	These used to hold joint names — "Left Shoulder", "RightElbow" — and were
	looked up against Motor6D.Name. That is not how Roblox resolves an animation
	and never was: the engine takes each Motor6D's Part1 to be the bone and
	matches the pose named after that PART. A joint's own name is decoration.

	The consequence was silent and one-sided. A rig wired perfectly but with its
	joints called "LeftShoulder" instead of "Left Shoulder" — which is what you
	get by building an R6 rig from an R15 donor, and is invisible in the Explorer
	unless you look — animated correctly from its clips and could not be posed at
	all by this fallback. So it looked fine right up until the clips failed for
	some other reason, and then it had no safety net.

	Part names are also the thing every other check in the project keys on, so
	this is now one vocabulary across the server, the client and the tools.
]]
local R6_JOINTS = {
	{ part = "Right Arm", role = "arm", sign = 1 },
	{ part = "Left Arm", role = "arm", sign = -1 },
	{ part = "Right Leg", role = "leg", sign = -1 },
	{ part = "Left Leg", role = "leg", sign = 1 },
	{ part = "Head", role = "head", sign = 1 },
}

local R15_JOINTS = {
	{ part = "RightUpperArm", role = "arm", sign = 1 },
	{ part = "LeftUpperArm", role = "arm", sign = -1 },
	{ part = "RightLowerArm", role = "elbow", sign = 1 },
	{ part = "LeftLowerArm", role = "elbow", sign = -1 },
	{ part = "RightUpperLeg", role = "leg", sign = -1 },
	{ part = "LeftUpperLeg", role = "leg", sign = 1 },
	{ part = "RightLowerLeg", role = "knee", sign = -1 },
	{ part = "LeftLowerLeg", role = "knee", sign = 1 },
	{ part = "UpperTorso", role = "waist", sign = 1 },
	{ part = "Head", role = "head", sign = 1 },
}

-- ── state ───────────────────────────────────────────────────────────────────

type Joint = {
	motor: Motor6D,
	role: string,
	sign: number,
}

type Body = {
	model: Model,
	--[[ Which of a kind's models this body is, for the fallback report. Read once
	     at track time rather than per frame: it is written by PlaceholderFactory
	     at boot and cannot change. ]]
	variant: string,
	root: BasePart?,
	humanoid: Humanoid?,
	animator: Animator?,
	joints: { Joint },
	resolved: boolean,
	-- Per-body character, rolled once and never changed.
	phase: number,
	dragLeft: number, -- 0-1 scale on the left leg's swing
	dragRight: number,
	tilt: number, -- constant head loll, signed
	lean: number, -- extra forward lean multiplier
	rate: number, -- gait speed multiplier
	-- Live.
	stride: number,
	moveBlend: number, -- 0 standing, 1 moving
	runBlend: number, -- 0 walk, 1 run
	frame: number,
	posed: boolean, -- has this controller written a Transform since it last cleared
	trackOwned: boolean, -- cached answer from hasPlayingTracks
	trackCheckedAt: number,
}

local bodies: { [Model]: Body } = {}
local infectedFolder: Instance? = nil
local clock = 0

-- ── helpers ─────────────────────────────────────────────────────────────────

--[[
	The axis, in a joint's own frame, that swings its limb forward and back.

	Derived rather than assumed. Transform is applied inside C0's frame, and C0's
	rotation differs between R6 and R15 and again between rigs somebody built by
	hand — so `CFrame.Angles(theta, 0, 0)` swings an arm forward on one rig and
	out sideways on the next. Taking the parent's RIGHT axis and expressing it in
	the joint's frame gives the correct hinge every time, whatever the rig's
	convention, for the price of one inverse-rotate.

	Read live rather than cached because the server rotates C0 itself for the
	attack windup, and a cached axis would quietly drift wrong for the duration
	of every telegraph.
]]
local function hingeAxis(motor: Motor6D): Vector3
	return motor.C0.Rotation:Inverse() * Vector3.xAxis
end

--[[ The parent's UP axis in the joint's frame — the hinge for a head turn or a
     torso twist, as opposed to a nod. ]]
local function twistAxis(motor: Motor6D): Vector3
	return motor.C0.Rotation:Inverse() * Vector3.yAxis
end

--[[ The parent's FORWARD axis in the joint's frame — the hinge for a head loll
     or a side-to-side lurch. ]]
local function rollAxis(motor: Motor6D): Vector3
	return motor.C0.Rotation:Inverse() * Vector3.zAxis
end

--[[
	A stable per-body roll.

	Read from the attribute InfectedService stamps at spawn, so every client
	animates the same zombie the same way and a body keeps its gait for its whole
	life rather than being re-rolled by whoever happens to look at it.

	This was originally derived on the client from the model's own identity via
	GetDebugId, which is a plugin-only call: in a game script it throws, once per
	body per spawn, and the horde filled the output with it.

	The name hash is the fallback for a body that somehow has no attribute — same
	gait for every zombie sharing a variant name, which is worse variety but
	still a walk cycle.
]]
local function seedFor(model: Model): number
	local stamped = model:GetAttribute(IA.Seed)
	if typeof(stamped) == "number" then
		return stamped
	end

	local text = model.Name
	local hash = 2166136261
	for index = 1, #text do
		hash = bit32.bxor(hash, string.byte(text, index))
		hash = (hash * 16777619) % 4294967296
	end
	return hash
end

local function resolveJoints(body: Body)
	body.resolved = true
	local model = body.model

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	body.humanoid = humanoid
	body.animator = if humanoid then humanoid:FindFirstChildOfClass("Animator") else nil
	--[[
		── THREE LOOKUPS, ALL OF WHICH USED TO BE WRONG IN A DIFFERENT WAY ─────
		This is the safety net: it drives any body whose clips are not driving it.
		So a hole here does not degrade a body, it strands one — and every hole it
		had was in exactly the models most likely to need it.

		ROOT was `model:FindFirstChild("HumanoidRootPart")`, with no recursive
		flag. Group a rig's parts into a Folder in Studio and that is nil, poseBody
		bails, and the body is animated by nothing at all. That is the same shallow
		lookup that was just fixed in RigUtil.getRoot, and having it in both places
		meant a nested rig lost the clips AND the fallback.

		LAYOUT was `model:FindFirstChild("UpperTorso")`, shallow again, and it only
		tested one of the two R15 torso names. A nested R15 rig was posed with the
		R6 joint list, which matches nothing on it. RigUtil.rigTypeOf is the one
		answer the server already uses; there is no reason for a second opinion.

		JOINTS were keyed on Motor6D.Name. That is not how Roblox resolves a pose —
		the engine takes each Motor6D's Part1 to be the bone and matches the pose
		named after that PART. This file's own header says so. A rig wired
		perfectly but with joints named "LeftShoulder" instead of "Left Shoulder"
		therefore animated correctly from its clips and could not be posed at all
		by the fallback. Keying on the child part's name makes both systems agree
		about what a joint is called, which is the only way they can agree about
		whether one is missing.
	]]
	body.root = RigUtil.getRoot(model)

	local layout = if RigUtil.rigTypeOf(model) == "R15" then R15_JOINTS else R6_JOINTS

	--[[ One pass over the rig, not one per joint. A ten-joint R15 body against
	     forty descendants is four hundred comparisons done the other way, per
	     body, and a wave-seven horde resolves forty-six of them inside a few
	     frames of each other. ]]
	local motors: { [string]: Motor6D } = {}
	for motor, child in RigUtil.mapMotorChildren(model) do
		motors[child.Name] = motor
	end

	for _, entry in layout do
		local motor = motors[entry.part]
		if motor then
			table.insert(body.joints, { motor = motor, role = entry.role, sign = entry.sign })
		end
	end
end

--[[
	Takes the dynamic shadows off a rig, on a handheld only.

	PlaceholderFactory gives every built rig two shadow casters and every adopted
	one a single chosen part. That is right on a desktop — a horde with no
	shadows floats — but a dynamic caster is re-rendered into the shadow map
	every frame it moves, and sixty of them walking is the most expensive thing
	on screen that nobody is looking directly at.

	Done on the CLIENT, per rig, which is what makes it free of cost to everyone
	else: CastShadow is written once at build time on the server, so a later
	client write sticks, and it changes only this client's copy. A desktop player
	in the same round keeps every shadow.

	Deliberately NOT Lighting.GlobalShadows. Turning that off is a bigger win and
	a bigger change: it also drives Roblox's indoor/outdoor determination, so
	every interior would take OutdoorAmbient instead of Ambient and the warehouse
	and safe rooms would come up roughly twice as bright as they are authored.
	That is an art decision about how the game looks, not a performance fix, and
	it is not one to make silently.
]]
local function stripShadows(model: Instance)
	if not dropRigShadows then
		return
	end
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") and descendant.CastShadow then
			descendant.CastShadow = false
		end
	end
end

local function track(model: Instance)
	if not model:IsA("Model") or bodies[model] then
		return
	end
	if model:GetAttribute(IA.Kind) == nil then
		return
	end

	--[[ Here rather than in the pose loop: this is a one-shot per body, and the
	     loop is the thing the whole file exists to keep cheap. ]]
	stripShadows(model)

	local seed = seedFor(model)
	local random = Random.new(seed)

	bodies[model] = {
		model = model,
		variant = tostring(model:GetAttribute("FL_Variant") or model.Name),
		root = nil,
		humanoid = nil,
		animator = nil,
		joints = {},
		resolved = false,
		phase = random:NextNumber(0, math.pi * 2),
		--[[ One leg drags. Which one, and how much, is the single strongest cue
		     that these are not four dozen copies of one animation. ]]
		dragLeft = random:NextNumber(0.55, 1.0),
		dragRight = random:NextNumber(0.55, 1.0),
		tilt = random:NextNumber(-1, 1),
		lean = random:NextNumber(0.75, 1.35),
		rate = random:NextNumber(0.85, 1.18),
		stride = random:NextNumber(0, math.pi * 2),
		moveBlend = 0,
		runBlend = 0,
		frame = random:NextInteger(0, FAR_STRIDE - 1),
		posed = false,
		trackOwned = false,
		trackCheckedAt = -math.huge,
	}
end

--[[ Variants already named as falling back, so the message is one line per
     model rather than one per body. ]]
local reportedFallback: { [string]: boolean } = {}

local function untrack(model: Instance)
	bodies[model :: Model] = nil
end

-- ── the pose ────────────────────────────────────────────────────────────────

--[[
	True while something else owns this rig's Transform.

	A rig that shipped animation ids has InfectedAnimator playing real clips on
	it, and the Animator rewrites Transform every frame — two writers means a
	visible fight, so the procedural gait stands down and lets the clips win.

	Sampled twice a second rather than every frame. GetPlayingAnimationTracks
	allocates a fresh array on every call, and asking fifteen nearby bodies sixty
	times a second is nine hundred throwaway tables a second of pure GC pressure
	for an answer that changes when a zombie starts swinging.
]]
local TRACK_CHECK_INTERVAL = 0.5

local function hasPlayingTracks(body: Body): boolean
	--[[
		THE SERVER'S VERDICT FIRST, because this controller cannot reach it.

		Asking whether a track is PLAYING is not the same as asking whether
		anything is MOVING, and every way a rig can be broken produces the first
		without the second: an R6 clip on an R15 skeleton, a joint wired
		backwards, a duplicate Motor6D pinning the pair, a weld beside a joint, a
		disabled Motor6D, an empty upload, an asset that never fetched. In all of
		them the track loads, reports IsPlaying, and the body stands still — so
		this test handed the joints back and stood down for exactly the bodies
		that needed it. Not animated by the clip, not animated by the fallback,
		sliding around in its rest pose. That is "some of them just drag around".

		Measuring movement from here does not work either: while this controller
		is posing, the joints change every frame BECAUSE it is changing them, so a
		movement test reads "animated", stands down, then reads "not animated" and
		takes the rig back — a 2Hz oscillation, which is worse than the bug. That
		was simulated before it was written, and it is why this is an attribute
		instead.

		The server has the answer for free: it loaded the tracks and it is what
		throws the dead ones away. Absent means no opinion yet, which is treated
		as animated — seizing a rig on no evidence would fight a clip that is
		perfectly fine.
	]]
	if Attributes.get(body.model, IA.Animated, true) == false then
		body.trackOwned = false
		return false
	end

	local animator = body.animator
	if not animator then
		return false
	end
	if clock < body.trackCheckedAt + TRACK_CHECK_INTERVAL then
		return body.trackOwned
	end
	body.trackCheckedAt = clock

	local ok, tracks = pcall(animator.GetPlayingAnimationTracks, animator)
	body.trackOwned = ok and typeof(tracks) == "table" and #tracks > 0
	return body.trackOwned
end

--[[ Hands the joints back, once. Called every frame while a rig's own clips are
     playing, so the flag matters: eight property writes a frame for a body this
     controller is deliberately not driving is eight writes a frame of nothing. ]]
local function clearPose(body: Body)
	if not body.posed then
		return
	end
	body.posed = false
	for _, joint in body.joints do
		if joint.motor.Parent then
			joint.motor.Transform = CFrame.identity
		end
	end
end

--[[ Blends one WALK/RUN tuning value for a body's current gait.

     At module scope rather than as a closure inside poseBody, which is where it
     used to live: this loop runs over every live body every frame, and a closure
     declared inside it is one table allocation per body per frame — several
     thousand a second at the roster's ceiling, in the hottest loop the client
     owns, for a function that captures nothing it could not be handed. ]]
local function mixed(field: string, run: number, move: number): number
	return (WALK[field] + (RUN[field] - WALK[field]) * run) * move
end

local function poseBody(body: Body, dt: number)
	local root = body.root
	local humanoid = body.humanoid
	if not root or not root.Parent or not humanoid then
		return
	end

	--[[ A dead body belongs to GoreService, which is replacing its Motor6Ds with
	     constraints to ragdoll it. Writing a Transform into that is at best
	     ignored and at worst a corpse twitching its way across the floor. ]]
	if humanoid.Health <= 0 or body.model:GetAttribute(IA.IsDead) == true then
		return
	end

	local velocity = root.AssemblyLinearVelocity
	local planar = Vector3.new(velocity.X, 0, velocity.Z)
	local speed = planar.Magnitude

	-- Blend, rather than switch. A body that snaps between standing and walking
	-- pops one frame of a completely different silhouette.
	local movingTarget = if speed > MOVING_EPSILON then 1 else 0
	body.moveBlend += (movingTarget - body.moveBlend) * math.min(dt * BLEND_SPEED, 1)

	local definition = InfectedConfig.get(body.model:GetAttribute(IA.Kind))
	local walkSpeed = if definition then definition.walkSpeed else 9
	local runSpeed = if definition then definition.runSpeed else 21
	local band = math.max(runSpeed - walkSpeed, 1)
	local runTarget = math.clamp((speed - walkSpeed * RUN_BLEND_FLOOR) / band, 0, 1)
	body.runBlend += (runTarget - body.runBlend) * math.min(dt * BLEND_SPEED, 1)

	--[[ Advanced by DISTANCE, not by time. This is what stops the feet skating:
	     a body pushed slowly by pathfinding takes slow steps, and one sprinting
	     takes fast ones, without either needing to know its own speed. ]]
	body.stride += speed * dt * STRIDE_PER_STUD * body.rate

	local move = body.moveBlend
	local run = body.runBlend

	local swing = math.sin(body.stride + body.phase)
	local counter = math.sin(body.stride + body.phase + math.pi)
	-- Twice the stride rate: the body rolls once per STEP, not once per cycle.
	local lurch = math.sin((body.stride + body.phase) * 2)

	local legSwing = mixed("LegSwing", run, move)
	local armSwing = mixed("ArmSwing", run, move)
	local armHang = mixed("ArmHang", run, move)
	local elbow = mixed("ElbowBend", run, move)
	local knee = mixed("KneeBend", run, move)
	local lean = mixed("TorsoLean", run, move) * body.lean
	local roll = mixed("TorsoRoll", run, move)

	-- Idle motion, faded in as the movement fades out.
	local still = 1 - move
	local breath = math.sin(clock * IDLE.BreathRate + body.phase) * IDLE.BreathAmount * still
	local sway = math.sin(clock * IDLE.SwaySpeed + body.phase) * IDLE.SwayAmount * still
	local headLoll = body.tilt * (IDLE.HeadLoll * still + mixed("HeadLoll", run, move))
	local headBob = math.sin((body.stride + body.phase) * 2) * mixed("HeadBob", run, move)

	for _, joint in body.joints do
		local motor = joint.motor
		if not motor.Parent then
			continue
		end

		local sign = joint.sign
		local phase = if sign > 0 then swing else counter
		local drag = if sign > 0 then body.dragRight else body.dragLeft
		local transform: CFrame

		if joint.role == "leg" then
			transform = CFrame.fromAxisAngle(hingeAxis(motor), phase * legSwing * drag)
		elseif joint.role == "knee" then
			--[[ Knees only ever bend one way. Taking the negative half of the
			     sine and folding it gives a bend that deepens as the leg comes
			     through and straightens as it plants, which is the shape of a
			     step. ]]
			local bend = math.max(-phase, 0) * knee * drag
			transform = CFrame.fromAxisAngle(hingeAxis(motor), -bend)
		elseif joint.role == "arm" then
			--[[ Hang plus swing, never a symmetric swing. Arms that swing evenly
			     read as a person walking; a zombie's hang forward and are dragged
			     along by the shoulder. ]]
			transform = CFrame.fromAxisAngle(hingeAxis(motor), -(armHang + counter * armSwing * sign))
				* CFrame.fromAxisAngle(rollAxis(motor), sway * sign)
		elseif joint.role == "elbow" then
			transform = CFrame.fromAxisAngle(hingeAxis(motor), -(elbow + math.max(phase, 0) * elbow * 0.35))
		elseif joint.role == "waist" then
			transform = CFrame.fromAxisAngle(hingeAxis(motor), lean + breath)
				* CFrame.fromAxisAngle(rollAxis(motor), lurch * roll)
		else -- head
			transform = CFrame.fromAxisAngle(rollAxis(motor), headLoll)
				* CFrame.fromAxisAngle(hingeAxis(motor), headBob - lean * 0.45 + breath)
				* CFrame.fromAxisAngle(twistAxis(motor), sway * 1.6)
		end

		motor.Transform = transform
	end
	body.posed = true

	--[[ R6 has no waist, so the forward lean has to come from the root joint or
	     it has nowhere to live — and a shambling zombie that stands bolt upright
	     is just a person walking badly. ]]
	if lean ~= 0 then
		local rootJoint = root:FindFirstChild("RootJoint")
		if rootJoint and rootJoint:IsA("Motor6D") then
			rootJoint.Transform = CFrame.fromAxisAngle(hingeAxis(rootJoint), lean * 0.6 + breath)
				* CFrame.fromAxisAngle(rollAxis(rootJoint), lurch * roll * 0.5)
		end
	end
end

-- ── the loop ────────────────────────────────────────────────────────────────

local function step(dt: number)
	clock += dt

	local character = player.Character
	local viewer = character and character:FindFirstChild("HumanoidRootPart")
	local origin = if viewer
		then (viewer :: BasePart).Position
		else Workspace.CurrentCamera and Workspace.CurrentCamera.CFrame.Position
	if not origin then
		return
	end

	for model, body in bodies do
		if not model.Parent then
			bodies[model] = nil
			continue
		end

		if not body.resolved then
			resolveJoints(body)
			if #body.joints == 0 then
				-- Nothing to drive. Left in the table rather than dropped so the
				-- resolve is not retried every frame for a rig that has no joints.
				continue
			end
		end
		if #body.joints == 0 then
			continue
		end

		local root = body.root
		if not root or not root.Parent then
			continue
		end

		local offset = root.Position - origin
		local distanceSquared = offset:Dot(offset)
		if distanceSquared > CULL_DISTANCE_SQUARED then
			continue
		end

		--[[ Far bodies are stepped every third frame with three frames' worth of
		     dt, so the gait advances at the same rate — it is sampled coarsely,
		     not slowed down. ]]
		--[[ Checked at every distance, not just up close. A rig that ships real
		     animations owns its own Transform at ninety studs exactly as much as
		     at nine, and writing over it there would show as the far half of a
		     horde walking differently from the near half. ]]
		if hasPlayingTracks(body) then
			clearPose(body)
			continue
		end

		--[[
			SAY WHICH BODIES THIS IS DRIVING, once per variant.

			This controller is the fallback, and a body reaching it is a body whose
			real animation is not playing. That is the single most useful fact in
			diagnosing "some of them use the shamble instead of my walk" — and
			until now it was the one thing nobody could see, because the decision
			is made HERE, on the client, and every diagnostic written for this
			problem has run on the server.

			Once per variant, not per body: thirty-five Commons at a wave-seven
			horde would otherwise be a wall. And only for a body that HAS an
			Animator — one without is already reported at boot, and repeating it
			forty-six times a round adds nothing.
		]]
		if body.animator and not reportedFallback[body.variant] then
			reportedFallback[body.variant] = true
			warn(
				string.format(
					"[InfectedPoseController] %q is being animated by the procedural fallback, not by "
						.. "its clips — it has an Animator but nothing is playing on it. That is the "
						.. "shamble you see instead of the walk you uploaded.",
					body.variant
				)
			)
		end

		if distanceSquared > NEAR_DISTANCE_SQUARED then
			body.frame = (body.frame + 1) % FAR_STRIDE
			if body.frame ~= 0 then
				continue
			end
			poseBody(body, dt * FAR_STRIDE)
		else
			poseBody(body, dt)
		end
	end
end

-- ── lifecycle ───────────────────────────────────────────────────────────────

local function watchFolder(folder: Instance)
	infectedFolder = folder
	for _, child in folder:GetChildren() do
		track(child)
	end
	trove:connect(folder.ChildAdded, track)
	trove:connect(folder.ChildRemoved, untrack)
end

function InfectedPoseController:init()
	--[[ In init rather than at module scope, because the camera exists by now and
	     Device's answer is a measurement rather than its safe floor. ]]
	adoptDeviceBands()
	trove:add(Device.changed:connect(adoptDeviceBands))
end

function InfectedPoseController:start()
	local existing = Workspace:FindFirstChild("Infected")
	if existing then
		watchFolder(existing)
	else
		--[[ The folder is created by InfectedService the first time something
		     spawns, which on a fresh server is after the client has booted. One
		     connection, dropped the moment it fires. ]]
		local connection: RBXScriptConnection
		connection = Workspace.ChildAdded:Connect(function(child)
			if child.Name == "Infected" and not infectedFolder then
				connection:Disconnect()
				watchFolder(child)
			end
		end)
		trove:add(connection)
	end

	trove:connect(RunService.RenderStepped, step)
end

function InfectedPoseController:destroy()
	trove:destroy()
	table.clear(bodies)
end

Registry.register("InfectedPoseController", InfectedPoseController)

return InfectedPoseController
