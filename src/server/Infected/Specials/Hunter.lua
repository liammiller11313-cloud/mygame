--!strict
--[[
	Hunter — crouch, coil, leap, pin.

	Everything here exists to make one moment fair: the leap. A Hunter that
	pounces silently is a random death; a Hunter that growls, crouches for half a
	second and then crosses a room is a mistake the team can see coming and
	answer. AudioConfig.Infected.HunterIdle plays at the START of the crouch,
	never at the launch — a warning that arrives with the attack is not a warning.

	Pounce damage scales with the distance travelled, the way it does in Left 4
	Dead. That is what stops a Hunter camping a doorway and pouncing the instant
	somebody rounds the corner: the distance is measured from the launch point at
	the moment of CONTACT, so a point-blank pounce earns almost nothing and a leap
	across a warehouse genuinely hurts.

	The pin is answerable three ways, and all three run through SurvivorService
	rather than through this file: a teammate's shove (MeleeService calls
	setPinned(player, nil)), killing the Hunter (onDeath), and the survivor going
	down (incapacitate clears the pin itself). This module polls the pin's owner
	every frame and lets go the instant it is no longer the owner — the counter
	must never depend on this module agreeing to release.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attributes = require(Shared.Net.Attributes)
local Enums = require(Shared.Enums)
local InfectedConfig = require(Shared.Config.InfectedConfig)
local RaycastUtil = require(Shared.Util.RaycastUtil)
local Registry = require(Shared.Util.Registry)
local Remotes = require(Shared.Net.Remotes)
local RigUtil = require(Shared.Util.RigUtil)
local Types = require(Shared.Types)

local DEFINITION = InfectedConfig.Definitions[Enums.Infected.Hunter]
local ATTACK = DEFINITION.attack

local PHASE = table.freeze({
	Stalk = "Stalk", -- the brain drives; we only watch for an opening
	Crouch = "Crouch", -- rooted, growling, telegraphing the leap
	Pounce = "Pounce", -- airborne, looking for contact
	Pin = "Pin", -- riding a survivor, clawing on cooldown
})

-- The tell. Deliberately longer than attack.windup (0.1s, which is the claw's
-- tell, not the leap's): this is the only half second the target has to turn
-- around, and shortening it is the fastest way to make the Hunter feel cheap.
local CROUCH_TIME = 0.55

-- A leap has a useful range band. Below the minimum a Hunter should just walk
-- up and claw; above the maximum the arc flattens into a sprint and the target
-- has ten studs of warning, which reads as a bug rather than as a pounce.
local POUNCE_MIN_RANGE = 16
local POUNCE_MAX_RANGE = 85

-- Horizontal speed cap for the leap. jumpPower fixes the flight time, so this is
-- what actually bounds the reach; it is set just above POUNCE_MAX_RANGE / flight
-- so a maximum-range pounce is exactly at the limit rather than clipped by it.
local POUNCE_MAX_SPEED = 95

-- Damage multipliers applied to attack.damage at zero distance and at
-- POUNCE_FULL_DISTANCE. 0.5x -> 5x over 75 studs turns attack.damage 6 into a
-- 3-to-30 spread: a bump, or most of a survivor's health bar for crossing a room.
local POUNCE_MIN_MULTIPLIER = 0.5
local POUNCE_MAX_MULTIPLIER = 5.0
local POUNCE_FULL_DISTANCE = 75

-- Contact radius while airborne. attack.range is the claw's reach and is the
-- right number here too: the pounce lands when the Hunter is close enough to
-- start clawing.
local POUNCE_CONTACT_RADIUS = ATTACK.range

-- The arc test raises the sightline this far before checking the far half, which
-- is roughly where the parabola sits at its midpoint. Two rays, not a swept
-- parabola: a Hunter that refuses to leap through a doorway it could clear is a
-- far smaller problem than one that spends a horde's worth of raycasts.
local ARC_CLEARANCE = 12

local MIN_AIR_TIME = 0.25 -- ignore the floor for this long; we start on it
local MAX_AIR_TIME = 2.5 -- a leap that never lands was a leap into geometry
local MISS_RECOVERY = 1.4 -- the punish window after a whiffed pounce
local SPAWN_SETTLE = 1.0 -- never pounce out of the spawn frame
local RELEASE_RECOVERY = 0.9 -- after being shoved off, before trying again

local SCAN_INTERVAL = 0.3 -- target re-selection; never per frame
local GROWL_INTERVAL = 4.5 -- the approach vocalisation, on its own clock

-- How far a survivor has to be from their nearest teammate to count as fully
-- isolated, and how much that discounts their distance when the Hunter chooses.
-- The Hunter is the game's punishment for wandering off; this is where that
-- lives.
local ISOLATION_FULL = 60
local ISOLATION_BIAS = 0.55

local PIN_CAMERA_IMPULSE = table.freeze({
	position = Vector3.new(0, -0.35, 0.9),
	rotation = Vector3.new(-9, 0, 0),
	decay = 5,
})

type State = {
	phase: string,
	phaseTime: number,
	readyAt: number,
	nextScan: number,
	nextGrowl: number,
	nextClaw: number,
	target: Player?, -- who this Hunter would pounce, if it gets the chance
	chase: Player?, -- who it walks at meanwhile; not always the same player
	victim: Player?,
	launchFrom: Vector3,
	airTime: number,
	ignore: { Instance },
}

-- Weak keys: a Hunter that is despawned rather than killed never reaches
-- onDeath, and a strong table here would hold its model alive forever.
local states = (setmetatable({}, { __mode = "k" }) :: any) :: { [Model]: State }

local function ensure(model: Model): State
	local state = states[model]
	if not state then
		state = {
			phase = PHASE.Stalk,
			phaseTime = 0,
			readyAt = os.clock() + SPAWN_SETTLE,
			nextScan = 0,
			nextGrowl = 0,
			nextClaw = 0,
			target = nil,
			chase = nil,
			victim = nil,
			launchFrom = Vector3.zero,
			airTime = 0,
			-- Reused for every sight test this Hunter ever runs, so the pounce
			-- check costs no allocation at all.
			ignore = { model },
		}
		states[model] = state
	end
	return state
end

-- The brain is InfectedService's object and arrives here as an opaque handle.
-- Every call into it is guarded so that a special still behaves like an ordinary
-- infected if a hook it expects is not there.
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

--[[ True while SurvivorService still names this model as the pin's owner. The
     shove clears a pin through SurvivorService, not through us, so polling is
     how the Hunter learns it has been answered. getPinnedBy is not in the
     architecture's public list for SurvivorService, so the replicated attribute
     is the fallback. ]]
local function stillPinnedBy(survivors: any, player: Player, model: Model): boolean
	if typeof(survivors.getPinnedBy) == "function" then
		return survivors:getPinnedBy(player) == model
	end
	return Attributes.get(player, Attributes.Player.PinnedBy, "") ~= ""
end

local function isPinnable(survivors: any, player: Player): boolean
	local state = survivors:getState(player)
	return state == Enums.SurvivorState.Healthy or state == Enums.SurvivorState.Hurt
end

--[[
	Picks two survivors: the one worth pouncing, and the one to walk at.

	They differ when everybody who could be pinned is already down or already
	held — a Hunter with no pounce target still has to go and claw somebody,
	rather than standing in a corridor doing nothing while the team bleeds out.

	The pounce choice is the nearest pinnable survivor DISCOUNTED by how far they
	have strayed from the rest of the team: the Hunter is the game's punishment
	for walking alone, and this is where that lives. Runs on SCAN_INTERVAL.
]]
local function pickTarget(root: BasePart): (Player?, Player?)
	local survivors: any = Registry.find("SurvivorService")
	if not survivors then
		return nil, nil
	end

	local candidates = survivors:getAliveSurvivors()
	local origin = root.Position
	local best: Player? = nil
	local bestScore = math.huge
	local nearest: Player? = nil
	local nearestDistance = math.huge

	for _, player in candidates do
		local character = player.Character
		local victimRoot = if character then RigUtil.getRoot(character) else nil
		if not victimRoot then
			continue
		end

		local range = (victimRoot.Position - origin).Magnitude
		if range < nearestDistance then
			nearestDistance = range
			nearest = player
		end

		if not isPinnable(survivors, player) then
			continue
		end

		local distance = range
		if distance > DEFINITION.sightRange then
			continue
		end

		-- Distance to their nearest teammate, which is the whole isolation read.
		local isolation = ISOLATION_FULL
		for _, other in candidates do
			if other == player then
				continue
			end
			local otherCharacter = other.Character
			local otherRoot = if otherCharacter then RigUtil.getRoot(otherCharacter) else nil
			if otherRoot then
				isolation = math.min(isolation, (otherRoot.Position - victimRoot.Position).Magnitude)
			end
		end

		local lonely = math.clamp(isolation / ISOLATION_FULL, 0, 1)
		local score = distance * (1 - ISOLATION_BIAS * lonely)
		if score < bestScore then
			bestScore = score
			best = player
		end
	end

	return best, nearest
end

local function targetRootOf(player: Player?): BasePart?
	if not player then
		return nil
	end
	local character = player.Character
	if not character or not character.Parent then
		return nil
	end
	return RigUtil.getRoot(character)
end

--[[ Range band, sightline, and enough headroom to clear the ground on the way
     out. The arc test is two rays: straight up out of the crouch, then across
     from the raised point to the target's chest. ]]
local function hasClearArc(state: State, from: Vector3, to: Vector3, targetCharacter: Model): boolean
	state.ignore[2] = targetCharacter
	local raised = from + Vector3.new(0, ARC_CLEARANCE, 0)
	local clear = RaycastUtil.hasLineOfSight(from, raised, state.ignore)
		and RaycastUtil.hasLineOfSight(raised, to, state.ignore)
	state.ignore[2] = nil
	return clear
end

--[[ Hands the Hunter back to the brain. Every exit from a scripted phase goes
     through here so there is exactly one place that can forget to resume. ]]
local function backToStalk(model: Model, brain: any, state: State, delay: number, keepSpeed: boolean?)
	state.phase = PHASE.Stalk
	state.phaseTime = 0
	state.airTime = 0
	state.victim = nil
	state.readyAt = os.clock() + delay

	if not keepSpeed then
		local humanoid = model:FindFirstChildOfClass("Humanoid")
		if humanoid then
			humanoid.WalkSpeed = DEFINITION.runSpeed
		end
	end
	resumeBrain(brain)
end

local function releaseVictim(model: Model, brain: any, state: State, delay: number, keepSpeed: boolean?)
	local victim = state.victim
	if victim then
		local survivors: any = Registry.find("SurvivorService")
		if survivors and stillPinnedBy(survivors, victim, model) then
			survivors:setPinned(victim, nil)
		end
	end
	backToStalk(model, brain, state, delay, keepSpeed)
end

local function pounceDamage(travelled: number): number
	local reach = math.clamp(travelled / POUNCE_FULL_DISTANCE, 0, 1)
	local multiplier = POUNCE_MIN_MULTIPLIER + (POUNCE_MAX_MULTIPLIER - POUNCE_MIN_MULTIPLIER) * reach
	return ATTACK.damage * multiplier
end

local function claw(
	model: Model,
	root: BasePart,
	victimCharacter: Model,
	victimRoot: BasePart,
	amount: number
)
	local damageService: any = Registry.find("DamageService")
	if not damageService then
		return
	end

	local delta = victimRoot.Position - root.Position
	local distance = delta.Magnitude
	local direction = if distance > 0.05 then delta.Unit else Vector3.yAxis

	damageService:applyDamage(
		victimCharacter,
		amount,
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

local function beginCrouch(
	model: Model,
	brain: any,
	state: State,
	root: BasePart,
	targetRoot: BasePart,
	dt: number
)
	pauseBrain(brain)

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		-- Rooted for the whole tell. A Hunter that keeps closing while it growls
		-- gives the target a warning it cannot act on.
		humanoid.WalkSpeed = 0
	end

	faceTowards(brain, root, targetRoot.Position, dt)
	playSound("HunterIdle", root)

	state.phase = PHASE.Crouch
	state.phaseTime = 0
end

local function launch(
	model: Model,
	brain: any,
	state: State,
	root: BasePart,
	targetRoot: BasePart,
	dt: number
)
	local gravity = Workspace.Gravity
	-- jumpPower is an initial upward velocity, so the flight time is fixed and
	-- the horizontal speed is what has to cover the gap.
	local flight = (2 * DEFINITION.jumpPower) / math.max(gravity, 1)

	local delta = targetRoot.Position - root.Position
	local flat = Vector3.new(delta.X, 0, delta.Z)
	local speed = math.min(flat.Magnitude / flight, POUNCE_MAX_SPEED)
	local heading = if flat.Magnitude > 0.05 then flat.Unit else root.CFrame.LookVector

	faceTowards(brain, root, targetRoot.Position, dt)
	root.AssemblyLinearVelocity = heading * speed + Vector3.new(0, DEFINITION.jumpPower, 0)

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
	end
	playSound("HunterPounce", root)

	state.phase = PHASE.Pounce
	state.phaseTime = 0
	state.airTime = 0
	state.launchFrom = root.Position
end

local function land(model: Model, brain: any, state: State, root: BasePart, player: Player, travelled: number)
	local survivors: any = Registry.find("SurvivorService")
	local character = player.Character
	local victimRoot = targetRootOf(player)
	if not survivors or not character or not victimRoot then
		backToStalk(model, brain, state, MISS_RECOVERY)
		return
	end

	local damage = pounceDamage(travelled)

	-- setPinned refuses anyone who is not upright. Somebody who went down while
	-- the Hunter was in the air still eats the landing; they just are not pinned,
	-- which is correct — a pin on a downed survivor is unanswerable.
	local pinned = survivors:setPinned(player, model, Enums.Infected.Hunter) == true
	claw(model, root, character, victimRoot, damage)

	if not pinned then
		backToStalk(model, brain, state, MISS_RECOVERY)
		return
	end

	Remotes.Event.CameraImpulse:FireClient(player, PIN_CAMERA_IMPULSE)

	state.phase = PHASE.Pin
	state.phaseTime = 0
	state.victim = player
	state.nextClaw = os.clock() + ATTACK.cooldown
end

local function stepStalk(model: Model, brain: any, state: State, root: BasePart, dt: number, now: number)
	if now >= state.nextScan then
		state.nextScan = now + SCAN_INTERVAL
		local pounceable, nearest = pickTarget(root)
		state.target = pounceable
		state.chase = pounceable or nearest
		local chase = state.chase
		setBrainTarget(brain, if chase then chase.Character else nil)
	end

	local target = state.target
	local targetRoot = targetRootOf(target)
	if not target or not targetRoot then
		return
	end

	local distance = (targetRoot.Position - root.Position).Magnitude

	-- The approach growl. It is on its own clock rather than tied to the crouch
	-- so a Hunter circling the team is audible before it ever commits.
	if now >= state.nextGrowl and distance <= DEFINITION.sightRange then
		state.nextGrowl = now + GROWL_INTERVAL
		playSound("HunterIdle", root)
	end

	if now < state.readyAt then
		return
	end
	if distance < POUNCE_MIN_RANGE or distance > POUNCE_MAX_RANGE then
		return
	end

	local character = target.Character
	if not character then
		return
	end

	state.ignore[2] = character
	local visible = RaycastUtil.hasLineOfSight(root.Position, targetRoot.Position, state.ignore)
	state.ignore[2] = nil
	if not visible then
		return
	end
	if not hasClearArc(state, root.Position, targetRoot.Position, character) then
		return
	end

	beginCrouch(model, brain, state, root, targetRoot, dt)
end

local function stepCrouch(model: Model, brain: any, state: State, root: BasePart, dt: number)
	local targetRoot = targetRootOf(state.target)
	if not targetRoot then
		backToStalk(model, brain, state, 0.4)
		return
	end

	-- Tracking during the crouch is what makes strafing away a real answer: the
	-- Hunter can turn, but turnSpeed decides how much of the dodge it keeps up
	-- with, and the leap itself commits to whatever it is facing.
	faceTowards(brain, root, targetRoot.Position, dt)

	if state.phaseTime >= CROUCH_TIME then
		launch(model, brain, state, root, targetRoot, dt)
	end
end

local function stepFlight(model: Model, brain: any, state: State, root: BasePart, dt: number)
	state.airTime += dt

	local survivors: any = Registry.find("SurvivorService")
	if survivors then
		local position = root.Position
		for _, player in survivors:getAliveSurvivors() do
			local victimRoot = targetRootOf(player)
			if victimRoot and (victimRoot.Position - position).Magnitude <= POUNCE_CONTACT_RADIUS then
				land(model, brain, state, root, player, (position - state.launchFrom).Magnitude)
				return
			end
		end
	end

	if state.airTime < MIN_AIR_TIME then
		return
	end

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local landed = humanoid ~= nil and humanoid.FloorMaterial ~= Enum.Material.Air
	if landed or state.airTime >= MAX_AIR_TIME then
		-- A missed pounce is the whole reason the tell exists. The recovery is
		-- long enough to shoot a Hunter that guessed wrong.
		backToStalk(model, brain, state, MISS_RECOVERY)
	end
end

local function stepPin(model: Model, brain: any, state: State, root: BasePart, now: number)
	local victim = state.victim
	local survivors: any = Registry.find("SurvivorService")
	if not victim or not survivors then
		releaseVictim(model, brain, state, RELEASE_RECOVERY)
		return
	end

	local character = victim.Character
	local victimRoot = targetRootOf(victim)
	if not character or not victimRoot or not stillPinnedBy(survivors, victim, model) then
		-- Shoved off, shot off, or the survivor went down. All three are
		-- answers, and all three end here.
		releaseVictim(model, brain, state, RELEASE_RECOVERY)
		return
	end

	-- Ride the victim. Driving the Hunter's CFrame rather than the survivor's
	-- keeps every position the client sees for its own character honest.
	local facing = victimRoot.CFrame.LookVector
	root.CFrame = CFrame.lookAt(
		victimRoot.Position + Vector3.new(0, 1.1, 0) + facing * 1.2,
		victimRoot.Position - Vector3.new(0, 1, 0)
	)
	root.AssemblyLinearVelocity = Vector3.zero

	if now >= state.nextClaw then
		state.nextClaw = now + ATTACK.cooldown
		claw(model, root, character, victimRoot, ATTACK.damage)
	end
end

-- ─── module surface ──────────────────────────────────────────────────────────

local Hunter = {}

function Hunter.onSpawn(model: Model, brain: any)
	local state = ensure(model)
	state.ignore[1] = model

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.WalkSpeed = DEFINITION.runSpeed
	end

	local root = RigUtil.getRoot(model)
	if root then
		playSound("HunterIdle", root)
		-- The spawn growl counts as this Hunter's first one; without this the
		-- approach clock fires again on the very next frame.
		state.nextGrowl = os.clock() + GROWL_INTERVAL
	end
	setBrainTarget(brain, nil)
end

function Hunter.onUpdate(model: Model, brain: any, dt: number)
	local state = states[model] or ensure(model)
	local root = RigUtil.getRoot(model)
	if not root then
		return
	end

	local now = os.clock()
	state.phaseTime += dt

	if state.phase ~= PHASE.Stalk and isStaggered(brain) then
		releaseVictim(model, brain, state, RELEASE_RECOVERY, true)
		return
	end

	if state.phase == PHASE.Pin then
		stepPin(model, brain, state, root, now)
	elseif state.phase == PHASE.Pounce then
		stepFlight(model, brain, state, root, dt)
	elseif state.phase == PHASE.Crouch then
		stepCrouch(model, brain, state, root, dt)
	else
		stepStalk(model, brain, state, root, dt, now)
	end
end

function Hunter.onDeath(model: Model, brain: any, _ctx: any)
	local state = states[model]
	if not state then
		return
	end
	-- Releasing here is belt-and-braces: SurvivorService drops a pin whose owner
	-- stops being alive on its own heartbeat. Doing it now means the survivor is
	-- free on the frame the Hunter dies rather than on the next one.
	releaseVictim(model, brain, state, 0)
	states[model] = nil
end

return Hunter
