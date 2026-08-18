--!strict
--[[
	Smoker — the tongue.

	The Smoker is a legibility problem before it is a combat problem. A survivor
	being dragged out of a room by an invisible force is a bug report; a survivor
	being dragged along a visible line that everyone can trace back to a coughing
	silhouette on a balcony is the best moment in the game. So the tongue is a
	real part in the world, not an effect: it is drawn every frame between the
	Smoker and its victim, and — because it is parented INTO the Smoker's model —
	a bullet that hits it resolves as a hit on the Smoker. Shooting the tongue and
	shooting the Smoker are the same counter, which is exactly how it reads.

	Everything that can break the tongue is polled here rather than pushed at us:
	  * a teammate's shove clears the pin through SurvivorService
	  * geometry between the two ends snaps it (this is the reason to run for a
	    corner rather than to stand and shoot)
	  * the victim going down clears the pin, and so does the Smoker dying
	  * distance past attack.range, and a hard time cap, as backstops

	The Smoker is rooted for the whole grab. That is not a limitation, it is the
	trade: it reels you in and cannot move while it does, so the tongue points
	straight at the thing the team needs to shoot.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attributes = require(Shared.Net.Attributes)
local Enums = require(Shared.Enums)
local GoreConfig = require(Shared.Config.GoreConfig)
local InfectedConfig = require(Shared.Config.InfectedConfig)
local RaycastUtil = require(Shared.Util.RaycastUtil)
local Registry = require(Shared.Util.Registry)
local Remotes = require(Shared.Net.Remotes)
local RigUtil = require(Shared.Util.RigUtil)
local Types = require(Shared.Types)

local DEFINITION = InfectedConfig.Definitions[Enums.Infected.Smoker]
local ATTACK = DEFINITION.attack

local PHASE = table.freeze({
	Idle = "Idle", -- the brain drives; we look for a sightline
	Windup = "Windup", -- rooted, coughing, tongue not out yet
	Drag = "Drag", -- tongue attached, reeling the victim in
})

-- Drag speed. Below a survivor's walk speed on purpose: the victim visibly loses
-- ground rather than being teleported, and a teammate who reacts immediately can
-- close the gap and shove before the Smoker gets them round a corner.
local DRAG_SPEED = 15

-- How close the victim is reeled before the Smoker just holds them there.
local DRAG_CONTACT = 6

local CHOKE_INTERVAL = 1.0 -- attack.damage per tick; attack.cooldown is the tongue's own clock
local MAX_DRAG_TIME = 14 -- backstop only; every real release comes from the list above
local OWNERSHIP_WATCHDOG_SLACK = 2 -- grace before the ownership backstop fires
local LOS_INTERVAL = 0.15 -- sightline re-check while dragging
local SCAN_INTERVAL = 0.35
local COUGH_INTERVAL = 6.0 -- the idle tell, audible long before the tongue

local TONGUE_THICKNESS = 0.45
local TONGUE_NAME = "Tongue"
-- Flesh, not the Smoker's green: the tongue has to read as the same material as
-- the blood the game is already covered in, or players do not recognise it as
-- something they can shoot.
local TONGUE_COLOR = GoreConfig.Blood.DarkColor

-- The death cloud. It is a vision blocker first and a decoration second, which is
-- why it is a particle volume rather than a translucent ball: particles genuinely
-- occlude, a 44-stud sphere just tints the room.
local SMOKE_RADIUS = 22
local SMOKE_EMIT_TIME = 4.0
local SMOKE_LIFETIME = 14
local SMOKE_TEXTURE = "rbxasset://textures/particles/smoke_main.dds"

local GRAB_CAMERA_IMPULSE = table.freeze({
	position = Vector3.new(0, -0.2, 0.7),
	rotation = Vector3.new(-6, 2.5, 0),
	decay = 6,
})

type State = {
	phase: string,
	phaseTime: number,
	readyAt: number,
	nextScan: number,
	nextCough: number,
	nextChoke: number,
	nextLos: number,
	target: Player?, -- who the tongue would take, if the line is clear
	chase: Player?, -- who it walks at meanwhile; not always the same player
	victim: Player?,
	tongue: BasePart?,
	dragTime: number,
	ignore: { Instance },
	probe: RaycastParams,
}

-- Weak keys: a Smoker despawned rather than killed never reaches onDeath.
local states = (setmetatable({}, { __mode = "k" }) :: any) :: { [Model]: State }

local function ensure(model: Model): State
	local state = states[model]
	if not state then
		local probe = RaycastParams.new()
		probe.FilterType = Enum.RaycastFilterType.Exclude
		probe.FilterDescendantsInstances = { model }
		probe.IgnoreWater = true
		probe.RespectCanCollide = false

		state = {
			phase = PHASE.Idle,
			phaseTime = 0,
			readyAt = 0,
			nextScan = 0,
			nextCough = 0,
			nextChoke = 0,
			nextLos = 0,
			target = nil,
			chase = nil,
			victim = nil,
			tongue = nil,
			dragTime = 0,
			ignore = { model },
			probe = probe,
		}
		states[model] = state
	end
	return state
end

-- The brain is InfectedService's object and arrives as an opaque handle; every
-- call into it is guarded so a missing hook degrades to ordinary behaviour.
local function pauseBrain(brain: any)
	if not brain then
		return
	end
	if typeof(brain.pause) == "function" then
		brain:pause()
	end
	-- pause() stands the common AI down but does not cancel a Humanoid:MoveTo it
	-- already issued, and a stale walk order keeps steering the body for several
	-- seconds. stop() is the brain's own way to drop it.
	if typeof(brain.stop) == "function" then
		brain:stop()
	end
end

local function resumeBrain(brain: any)
	if brain and typeof(brain.resume) == "function" then
		brain:resume()
	end
end

local function setBrainTarget(brain: any, target: Model?)
	if brain and typeof(brain.setTarget) == "function" then
		brain:setTarget(target)
	end
end

--[[ A shove has to answer a special exactly the way it answers a Common: whatever
     it was doing stops. InfectedService:stagger scales the duration by
     stumbleResistance and hands it to the brain, which freezes the body — but it
     cannot interrupt a scripted phase from the outside, so the phase has to ask.
     Nothing on this path restores WalkSpeed: the stumble owns it, and the brain
     puts it back when the stumble ends. ]]
local function isStaggered(brain: any): boolean
	return brain ~= nil and typeof(brain.isStaggered) == "function" and brain:isStaggered() == true
end

--[[ Yaw toward a point at the definition's turnSpeed. The brain owns rotation —
     including Humanoid.AutoRotate, which manual facing has to switch off — so
     this defers to it and only snaps if that hook is missing. ]]
local function faceTowards(brain: any, root: BasePart, position: Vector3, dt: number)
	if brain and typeof(brain.faceTowards) == "function" then
		brain:faceTowards(position, dt)
		return
	end
	local flat = Vector3.new(position.X - root.Position.X, 0, position.Z - root.Position.Z)
	if flat.Magnitude > 0.05 then
		root.CFrame = CFrame.lookAt(root.Position, root.Position + flat.Unit)
	end
end

local function playSound(key: string, part: BasePart)
	local audio: any = Registry.find("AudioService")
	if audio then
		audio:play("Infected", key, part)
	end
end

local function rootOf(player: Player?): (Model?, BasePart?)
	if not player then
		return nil, nil
	end
	local character = player.Character
	if not character or not character.Parent then
		return nil, nil
	end
	return character, RigUtil.getRoot(character)
end

--[[ Polled, not pushed: the shove clears a pin through SurvivorService and never
     tells us. getPinnedBy is not in the architecture's public list, so the
     replicated attribute is the fallback. ]]
local function stillPinnedBy(survivors: any, player: Player, model: Model): boolean
	if typeof(survivors.getPinnedBy) == "function" then
		return survivors:getPinnedBy(player) == model
	end
	return Attributes.get(player, Attributes.Player.PinnedBy, "") ~= ""
end

local function isGrabbable(survivors: any, player: Player): boolean
	local state = survivors:getState(player)
	return state == Enums.SurvivorState.Healthy or state == Enums.SurvivorState.Hurt
end

--[[ Where the tongue leaves the body. The head reads better than the root: the
     line starts at the silhouette players are aiming at. ]]
local function mouthOf(model: Model, root: BasePart): Vector3
	local head = model:FindFirstChild("Head")
	if head and head:IsA("BasePart") then
		return head.Position
	end
	return root.Position + Vector3.new(0, 1.5, 0)
end

--[[
	The tongue part. It lives inside the Smoker's model on purpose: RigUtil walks
	a struck part up to the model that owns it, so a round that hits the tongue is
	resolved as a round that hit the Smoker. It is anchored and welded to nothing,
	so it cannot drag the rig's assembly around, and it is massless and
	non-collidable so it never shoves anybody.
]]
local function makeTongue(model: Model): BasePart
	local part = Instance.new("Part")
	part.Name = TONGUE_NAME
	part.Shape = Enum.PartType.Cylinder
	part.Size = Vector3.new(1, TONGUE_THICKNESS, TONGUE_THICKNESS)
	part.Color = TONGUE_COLOR
	part.Material = Enum.Material.Glass
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = true -- the entire point: it must be shootable
	part.Massless = true
	part.CastShadow = false
	part.Locked = true
	part.Parent = model
	return part
end

local function drawTongue(part: BasePart, from: Vector3, to: Vector3)
	local delta = to - from
	local length = delta.Magnitude
	if length < 0.1 then
		return
	end
	part.Size = Vector3.new(length, TONGUE_THICKNESS, TONGUE_THICKNESS)
	-- A cylinder's length runs along its X axis, so the look CFrame is rotated a
	-- quarter turn to lay it along the line.
	part.CFrame = CFrame.lookAt(from + delta * 0.5, to) * CFrame.Angles(0, math.pi * 0.5, 0)
end

--[[ Hands the survivor's physics back. Taking ownership is what makes the drag
     authoritative — without it the victim's own client keeps simulating and
     simply walks out of the tongue. ]]
local function restoreOwnership(root: BasePart)
	pcall(function()
		root:SetNetworkOwnershipAuto()
	end)
end

local function takeOwnership(root: BasePart)
	pcall(function()
		root:SetNetworkOwner(nil)
	end)
end

--[[
	Ownership has to come back even if this Smoker never runs another frame.

	InfectedService:despawn destroys a model without calling onDeath — a round
	reset, or the Director clearing the board — and a survivor left permanently
	server-simulated feels laggy to the person playing them for the rest of the
	map. The drag cannot outlive MAX_DRAG_TIME, so a single one-shot check past
	that is enough to guarantee it.
]]
local function armOwnershipWatchdog(model: Model, player: Player, root: BasePart)
	task.delay(MAX_DRAG_TIME + OWNERSHIP_WATCHDOG_SLACK, function()
		if root.Parent == nil then
			return
		end
		local survivors: any = Registry.find("SurvivorService")
		if survivors and stillPinnedBy(survivors, player, model) then
			return -- still a live grab; release() owns the restore
		end
		pcall(function()
			root:SetNetworkOwnershipAuto()
		end)
	end)
end

local function backToIdle(model: Model, brain: any, state: State, delay: number, keepSpeed: boolean?)
	state.phase = PHASE.Idle
	state.phaseTime = 0
	state.dragTime = 0
	state.readyAt = os.clock() + delay

	if not keepSpeed then
		local humanoid = model:FindFirstChildOfClass("Humanoid")
		if humanoid then
			humanoid.WalkSpeed = DEFINITION.walkSpeed
		end
	end
	resumeBrain(brain)
end

--[[ Every way the tongue ends runs through here: shove, geometry, distance,
     death, the victim going down. One release path means one place that can
     leave a survivor stuck. ]]
local function release(model: Model, brain: any, state: State, delay: number, keepSpeed: boolean?)
	local victim = state.victim
	if victim then
		local survivors: any = Registry.find("SurvivorService")
		if survivors and stillPinnedBy(survivors, victim, model) then
			survivors:setPinned(victim, nil)
		end
		local _, victimRoot = rootOf(victim)
		if victimRoot then
			restoreOwnership(victimRoot)
		end
	end
	state.victim = nil

	local tongue = state.tongue
	if tongue then
		tongue:Destroy()
		state.tongue = nil
	end

	backToIdle(model, brain, state, delay, keepSpeed)
end

local function choke(model: Model, root: BasePart, character: Model, victimRoot: BasePart)
	local damageService: any = Registry.find("DamageService")
	if not damageService then
		return
	end

	local delta = victimRoot.Position - root.Position
	local distance = delta.Magnitude
	local direction = if distance > 0.05 then delta.Unit else Vector3.yAxis

	damageService:applyDamage(
		character,
		ATTACK.damage,
		Types.newDamageContext({
			attackerModel = model,
			damageType = Enums.DamageType.Special,
			region = Enums.HitRegion.Torso,
			hitPosition = victimRoot.Position,
			hitNormal = -direction,
			direction = direction,
			distance = distance,
		})
	)
end

-- ─── phases ──────────────────────────────────────────────────────────────────

--[[
	Picks two survivors: the one the tongue can actually take, and the one to walk
	at otherwise. They differ whenever every reachable survivor is already down or
	already held — a Smoker with no grab still has to close in and be a threat
	rather than idling in a stairwell.

	The grab candidate is the nearest survivor with a clear line, because the
	tongue's whole counter is that line existing.
]]
local function pickTarget(model: Model, root: BasePart, state: State): (Player?, Player?)
	local survivors: any = Registry.find("SurvivorService")
	if not survivors then
		return nil, nil
	end

	local mouth = mouthOf(model, root)
	local best: Player? = nil
	local bestDistance = math.huge
	local nearest: Player? = nil
	local nearestDistance = math.huge

	for _, player in survivors:getAliveSurvivors() do
		local character, victimRoot = rootOf(player)
		if not character or not victimRoot then
			continue
		end

		local distance = (victimRoot.Position - mouth).Magnitude
		if distance < nearestDistance then
			nearestDistance = distance
			nearest = player
		end

		if not isGrabbable(survivors, player) or distance > ATTACK.range or distance >= bestDistance then
			continue
		end

		state.ignore[2] = character
		local visible = RaycastUtil.hasLineOfSight(mouth, victimRoot.Position, state.ignore)
		state.ignore[2] = nil
		if visible then
			bestDistance = distance
			best = player
		end
	end

	return best, nearest
end

local function stepIdle(model: Model, brain: any, state: State, root: BasePart, now: number)
	if now >= state.nextCough then
		state.nextCough = now + COUGH_INTERVAL
		-- The cough is the Smoker's whole early warning. It plays whether or not
		-- it has a target, because hearing it and not finding it is the point.
		playSound("SmokerIdle", root)
	end

	if now < state.nextScan then
		return
	end
	state.nextScan = now + SCAN_INTERVAL

	local target, nearest = pickTarget(model, root, state)
	state.target = target
	state.chase = target or nearest
	local chase = state.chase
	setBrainTarget(brain, if chase then chase.Character else nil)

	if not target or now < state.readyAt then
		return
	end

	-- Rooted for the windup. The tongue is a committed attack, and standing still
	-- while it charges is what makes the Smoker shootable.
	pauseBrain(brain)
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.WalkSpeed = 0
	end
	-- The cough IS the windup. It fires here, at the start, so the tell always
	-- precedes the tongue by attack.windup rather than arriving with it.
	playSound("SmokerIdle", root)
	state.nextCough = now + COUGH_INTERVAL

	state.phase = PHASE.Windup
	state.phaseTime = 0
end

local function stepWindup(model: Model, brain: any, state: State, root: BasePart, dt: number)
	local target = state.target
	local character, victimRoot = rootOf(target)
	if not target or not character or not victimRoot then
		backToIdle(model, brain, state, ATTACK.cooldown)
		return
	end

	local mouth = mouthOf(model, root)
	faceTowards(brain, root, victimRoot.Position, dt)

	if state.phaseTime < ATTACK.windup then
		return
	end

	-- Re-checked at the moment of firing, never only at the decision. Stepping
	-- behind a pillar during the windup HAS to work, or the cough stops being
	-- information the team can act on.
	local survivors: any = Registry.find("SurvivorService")
	state.ignore[2] = character
	local hit = RaycastUtil.hasLineOfSight(mouth, victimRoot.Position, state.ignore)
	state.ignore[2] = nil

	if
		not hit
		or not survivors
		or not isGrabbable(survivors, target)
		or (victimRoot.Position - mouth).Magnitude > ATTACK.range
	then
		backToIdle(model, brain, state, ATTACK.cooldown)
		return
	end

	-- setPinned refuses anyone who is not upright, and it is the authority on
	-- that — never this module's own read of their state.
	if survivors:setPinned(target, model, Enums.Infected.Smoker) ~= true then
		backToIdle(model, brain, state, ATTACK.cooldown)
		return
	end

	state.victim = target
	state.tongue = makeTongue(model)
	state.probe.FilterDescendantsInstances = { model, character }
	state.dragTime = 0
	state.phase = PHASE.Drag
	state.phaseTime = 0
	state.nextChoke = os.clock() + CHOKE_INTERVAL

	takeOwnership(victimRoot)
	armOwnershipWatchdog(model, target, victimRoot)
	drawTongue(state.tongue :: BasePart, mouth, victimRoot.Position)
	playSound("SmokerTongue", root)
	Remotes.Event.CameraImpulse:FireClient(target, GRAB_CAMERA_IMPULSE)
end

local function stepDrag(model: Model, brain: any, state: State, root: BasePart, dt: number, now: number)
	local victim = state.victim
	local survivors: any = Registry.find("SurvivorService")
	local character, victimRoot = rootOf(victim)

	if
		not victim
		or not survivors
		or not character
		or not victimRoot
		or not stillPinnedBy(survivors, victim, model)
	then
		release(model, brain, state, ATTACK.cooldown)
		return
	end

	state.dragTime += dt

	local mouth = mouthOf(model, root)
	local delta = mouth - victimRoot.Position
	local distance = delta.Magnitude

	if distance > ATTACK.range or state.dragTime >= MAX_DRAG_TIME then
		release(model, brain, state, ATTACK.cooldown)
		return
	end

	-- Geometry snapping the tongue is the survivor-side counter, so it is checked
	-- on its own short clock rather than once per grab.
	if now >= state.nextLos then
		state.nextLos = now + LOS_INTERVAL
		state.ignore[2] = character
		local visible = RaycastUtil.hasLineOfSight(mouth, victimRoot.Position, state.ignore)
		state.ignore[2] = nil
		if not visible then
			release(model, brain, state, ATTACK.cooldown)
			return
		end
	end

	local tongue = state.tongue
	if tongue then
		drawTongue(tongue, mouth, victimRoot.Position)
	end

	-- Reel in. The step is flattened and wall-probed so a dragged survivor slides
	-- along geometry instead of being pulled into it, and the CFrame is offset
	-- rather than rebuilt so gravity keeps owning their Y.
	if distance > DRAG_CONTACT then
		local flat = Vector3.new(delta.X, 0, delta.Z)
		if flat.Magnitude > 0.05 then
			local heading = flat.Unit
			local step = math.min(DRAG_SPEED * dt, distance - DRAG_CONTACT)
			local blocked = Workspace:Raycast(victimRoot.Position, heading * (step + 1.5), state.probe)
			if blocked then
				step = math.max(blocked.Distance - 1.5, 0)
			end
			if step > 0 then
				victimRoot.CFrame = victimRoot.CFrame + heading * step
			end
		end
	end

	if now >= state.nextChoke then
		state.nextChoke = now + CHOKE_INTERVAL
		choke(model, root, character, victimRoot)
	end
end

--[[ The parting gift: a cloud that the team has to either wait out or walk
     through blind, dropped exactly where the Smoker was standing — which is
     usually the doorway they wanted to move through next. ]]
local function spawnSmokeCloud(position: Vector3)
	local anchor = Instance.new("Part")
	anchor.Name = "FL_SmokeCloud"
	anchor.Size = Vector3.one
	anchor.CFrame = CFrame.new(position)
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.CastShadow = false
	anchor.Transparency = 1
	anchor.Locked = true

	local emitter = Instance.new("ParticleEmitter")
	emitter.Texture = SMOKE_TEXTURE
	emitter.Color = ColorSequence.new(DEFINITION.accentColor)
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, SMOKE_RADIUS * 0.35),
		NumberSequenceKeypoint.new(1, SMOKE_RADIUS),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.15, 0.35),
		NumberSequenceKeypoint.new(0.8, 0.5),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Lifetime = NumberRange.new(SMOKE_LIFETIME * 0.6, SMOKE_LIFETIME)
	emitter.Rate = 10
	emitter.Speed = NumberRange.new(1, 3)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Drag = 3
	emitter.LightInfluence = 1
	emitter.Parent = anchor

	anchor.Parent = Workspace
	-- The emitter stops long before the anchor goes: particles already in the air
	-- have to be allowed to live out their lifetime or the cloud pops.
	Debris:AddItem(anchor, SMOKE_EMIT_TIME + SMOKE_LIFETIME)
	task.delay(SMOKE_EMIT_TIME, function()
		if anchor.Parent then
			emitter.Enabled = false
		end
	end)
end

-- ─── module surface ──────────────────────────────────────────────────────────

local Smoker = {}

function Smoker.onSpawn(model: Model, brain: any)
	local state = ensure(model)
	state.ignore[1] = model
	state.probe.FilterDescendantsInstances = { model }

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.WalkSpeed = DEFINITION.walkSpeed
	end

	local root = RigUtil.getRoot(model)
	if root then
		playSound("SmokerIdle", root)
		state.nextCough = os.clock() + COUGH_INTERVAL
	end
	setBrainTarget(brain, nil)
end

function Smoker.onUpdate(model: Model, brain: any, dt: number)
	local state = states[model] or ensure(model)
	local root = RigUtil.getRoot(model)
	if not root then
		return
	end

	local now = os.clock()
	state.phaseTime += dt

	if state.phase ~= PHASE.Idle and isStaggered(brain) then
		-- Shoved mid-tongue. The grab ends, the survivor is free, and the Smoker
		-- coughs its way through a fresh cooldown before it tries again.
		release(model, brain, state, ATTACK.cooldown, true)
		return
	end

	if state.phase == PHASE.Drag then
		stepDrag(model, brain, state, root, dt, now)
	elseif state.phase == PHASE.Windup then
		stepWindup(model, brain, state, root, dt)
	else
		stepIdle(model, brain, state, root, now)
	end
end

function Smoker.onDeath(model: Model, brain: any, _ctx: any)
	local state = states[model]
	if state then
		release(model, brain, state, 0)
		states[model] = nil
	end

	local root = RigUtil.getRoot(model)
	if root then
		spawnSmokeCloud(root.Position + Vector3.new(0, 2, 0))
	end
end

return Smoker
