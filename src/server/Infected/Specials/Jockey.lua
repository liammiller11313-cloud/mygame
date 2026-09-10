--!strict
--[[
	Jockey — leaps onto your back and drives.

	The damage is a rounding error: attack.damage 4 on a 0.7s cooldown will not
	kill anybody on its own. The threat is that you stop being the one who
	decides where you go. The Jockey steers away from the team, toward a drop, or
	toward the Witch, and everything dangerous about a ride is a consequence of
	arriving somewhere you did not choose.

	The ride is a TUG OF WAR and not a cutscene, and that distinction is the
	whole module. The victim keeps their legs — SurvivorService's pin would
	normally zero their WalkSpeed and this file deliberately re-asserts a limp
	speed over it — while a force-limited LinearVelocity on their root pulls them
	along the Jockey's heading. The two movers fight it out in the physics solver
	on the victim's own machine, which is why the struggle feels like a struggle:
	the server never has to see which key is being held, and a player who pushes
	back genuinely drags the pair off the Jockey's line without ever being able to
	shake it off alone.

	Re-asserting WalkSpeed is a real coupling with SurvivorService, so both
	directions of it are handled deliberately:
	  * SurvivorService writes WalkSpeed only when its OWN computed value changes,
	    so the two are not fighting over the property every frame.
	  * Every release path goes through setPinned(victim, nil), and clearPinned
	    re-applies the survivor's true speed on the spot. The one path that does
	    not — going down, which drops the pin fields without clearing the pin — is
	    covered by zeroing the speed whenever the victim is no longer upright.

	The pin is answerable exactly the way every other pin in the game is: a
	teammate's shove (MeleeService clears the pin and staggers whatever was
	holding them), enough damage to a 250-health special, or the victim going
	down. This module polls the pin's owner every tick and lets go the instant it
	is no longer the owner, so no counter depends on the Jockey cooperating.

	The cackle is not flavour. AudioConfig gives JockeyRide a 260-stud rolloff and
	priority 7 because it is how the rest of the team finds a teammate who is
	being driven out of the room, so it plays on the Jockey's own root — which is
	sitting on the victim's shoulders — for the whole ride.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Enums = require(Shared.Enums)
local GameConfig = require(Shared.Config.GameConfig)
local InfectedConfig = require(Shared.Config.InfectedConfig)
local RaycastUtil = require(Shared.Util.RaycastUtil)
local Registry = require(Shared.Util.Registry)
local Remotes = require(Shared.Net.Remotes)
local RigUtil = require(Shared.Util.RigUtil)
local Types = require(Shared.Types)

local Support = require(script.Parent.Support)

local DEFINITION = InfectedConfig.Definitions[Enums.Infected.Jockey]
local ATTACK = DEFINITION.attack
local SURVIVOR = GameConfig.Survivor

local PHASE = table.freeze({
	Stalk = "Stalk", -- the brain drives; we only watch for an opening
	Gather = "Gather", -- rooted, cackling, telegraphing the leap
	Leap = "Leap", -- airborne, looking for a back to land on
	Ride = "Ride", -- steering a survivor, clawing on cooldown
})

-- The tell. Shorter than the Hunter's crouch because the leap is short and the
-- payoff is not damage — but never zero: a Jockey that arrives with no warning
-- turns "I got ridden off a roof" into something the player could not have
-- prevented, which is where a mechanic stops being funny.
local GATHER_TIME = 0.4

-- jumpPower 78 fixes the flight time at roughly 0.8s, so the speed cap is what
-- actually bounds the reach. The band is deliberately short: the Jockey is an
-- ambusher that comes round a corner, not a second Hunter.
local LEAP_MIN_RANGE = 10
local LEAP_MAX_RANGE = 30
local LEAP_MAX_SPEED = 46

-- Contact radius while airborne; attack.range is the claw's reach and is the
-- right number here too, since landing on someone means being close enough to
-- start clawing.
local CONTACT_RADIUS = ATTACK.range

-- Two rays rather than a swept parabola, exactly as the Hunter does it: the cost
-- of refusing a leap it could have made is far lower than the cost of spending a
-- horde's raycast budget on arcs.
local ARC_CLEARANCE = 8

local MIN_AIR_TIME = 0.2 -- ignore the floor for this long; we start on it
local MAX_AIR_TIME = 1.6 -- a leap that never lands went into geometry
local MISS_RECOVERY = 1.3 -- the punish window after a whiffed leap
local SPAWN_SETTLE = 1.0 -- never leap out of the spawn frame
local RELEASE_RECOVERY = 1.2 -- after being shaken off, before trying again

local SCAN_INTERVAL = 0.3 -- target re-selection; never per frame

--[[ How far from their nearest teammate a survivor counts as fully alone, and
     how hard that pulls the choice away from "nearest". The Hunter's numbers,
     because the two creatures are asking the same question: which one of these
     four can I take out of the fight for long enough to matter. ]]
local ISOLATION_FULL = 60
local ISOLATION_BIAS = 0.55
local CACKLE_INTERVAL = 4.0 -- the approach laugh, on its own clock
local RIDE_CACKLE_INTERVAL = 1.15 -- constant while riding: this is the beacon

--[[ The ride, in numbers.

     RIDE_SPEED is what the victim's own legs are worth while they are being
     driven; the limp speed is exactly the right feeling and it already exists as
     a tuned number. STEER_SPEED is the velocity the Jockey's mover asks for, and
     it is the Jockey's own walkSpeed — faster than the victim can counter-walk,
     so the pair always makes progress, slow enough that pushing back visibly
     drags the line. STEER_FORCE_G caps the mover at that many times the victim's
     body weight: much above three and the struggle stops being winnable at all. ]]
local RIDE_SPEED = SURVIVOR.LimpWalkSpeed
local STEER_SPEED = DEFINITION.walkSpeed
local STEER_FORCE_G = 2.5

-- A ride has to end even if nobody is left to shove. This is the last-survivor
-- guarantee, not a balance number: at 4 damage a claw it costs the victim about
-- fifty health, and it stops a solo player being driven around the map forever.
local RIDE_MAX_TIME = 14

--[[ Steering. The heading is re-chosen on its own clock — 8 probe directions,
     two rays each — and held between decisions, so the mover's target velocity is
     written only when the Jockey actually changes its mind rather than every
     frame. Weights are all "how many studs of preference": the Witch dominates,
     a ledge is worth more than open ground, and momentum stops the heading
     flickering between two equally good directions every scan. ]]
local STEER_INTERVAL = 0.35
local STEER_PROBE_COUNT = 8
local STEER_PROBE_RANGE = 16
local STEER_PROBE_LIFT = 2.0 -- probe from chest height, not from the floor
local STEER_GROUND_SEARCH = 40 -- how far down a probe looks for a floor
local STEER_LEDGE_DROP = 14 -- a fall this deep is worth steering into
local STEER_LEDGE_BONUS = 3.0
local STEER_AWAY_WEIGHT = 2.0
local STEER_WITCH_WEIGHT = 4.0
local STEER_WITCH_RANGE = 200
--[[
	Ground that hurts, and what it is worth aiming at.

	Between "away from the team" and the Witch, which is where it belongs: a
	Spitter's pool is a real cost and it is not a fight-ender, so it should beat
	open floor and lose to the one creature that removes a survivor outright.

	The range is short next to the Witch's two hundred, and deliberately. A Witch
	is worth crossing a map for; acid has nine seconds to live and a ride does
	not last long enough to reach one two rooms away. Steering at something the
	pair will never arrive at is a heading wasted on nothing.
]]
local STEER_HAZARD_WEIGHT = 2.5
local STEER_HAZARD_RANGE = 70
local STEER_MOMENTUM = 0.8

local MOUNT_CAMERA_IMPULSE = table.freeze({
	position = Vector3.new(0, 0.5, -0.6),
	rotation = Vector3.new(7, 12, 0),
	decay = 4,
})

-- Fixed compass of steering candidates, built once. Allocating eight vectors per
-- steer decision per Jockey is exactly the kind of thing that adds up at 46
-- bodies, and these never change.
local STEER_PROBES: { Vector3 } = (function()
	local probes = table.create(STEER_PROBE_COUNT)
	for index = 1, STEER_PROBE_COUNT do
		local angle = (index - 1) * (math.pi * 2 / STEER_PROBE_COUNT)
		probes[index] = Vector3.new(math.sin(angle), 0, math.cos(angle))
	end
	return table.freeze(probes)
end)()

type State = {
	phase: string,
	phaseTime: number,
	readyAt: number,
	nextScan: number,
	nextCackle: number,
	nextClaw: number,
	nextSteer: number,
	target: Player?, -- who this Jockey would leap at, given the chance
	chase: Player?, -- who it walks at meanwhile; not always the same player
	victim: Player?,
	rideTime: number,
	heading: Vector3,
	airTime: number,
	mover: LinearVelocity?,
	moverAttachment: Attachment?,
	ignore: { Instance },
}

-- Weak keys: a Jockey despawned rather than killed never reaches onDeath, and a
-- strong table here would hold its model alive forever.
local states = (setmetatable({}, { __mode = "k" }) :: any) :: { [Model]: State }

local function ensure(model: Model): State
	local state = states[model]
	if not state then
		state = {
			phase = PHASE.Stalk,
			phaseTime = 0,
			readyAt = os.clock() + SPAWN_SETTLE,
			nextScan = 0,
			nextCackle = 0,
			nextClaw = 0,
			nextSteer = 0,
			target = nil,
			chase = nil,
			victim = nil,
			rideTime = 0,
			heading = Vector3.zAxis,
			airTime = 0,
			mover = nil,
			moverAttachment = nil,
			-- Reused for every cast this Jockey ever runs, so neither the leap
			-- check nor the steering probes allocate an ignore list.
			ignore = { model },
		}
		states[model] = state
	end
	return state
end

local function isRideable(survivors: any, player: Player): boolean
	local state = survivors:getState(player)
	return state == Enums.SurvivorState.Healthy or state == Enums.SurvivorState.Hurt
end

-- ─── the mover ───────────────────────────────────────────────────────────────

--[[
	Builds the bias that makes the ride a struggle.

	Plane mode, world-relative, X and Z only: the Jockey may pull the victim
	across the ground and has no say at all over gravity, falls or the drop it is
	steering them toward. The force limit is what leaves the victim their half of
	the argument — the constraint asks for STEER_SPEED, the victim's Humanoid asks
	for RIDE_SPEED in whatever direction they are holding, and the solver splits
	the difference on the victim's own machine, which is why the fight is
	responsive rather than something they watch happen a ping later.
]]
local function attachMover(state: State, victimRoot: BasePart)
	local attachment = Instance.new("Attachment")
	attachment.Name = "FL_JockeySteer"
	attachment.Parent = victimRoot

	local mover = Instance.new("LinearVelocity")
	mover.Name = "FL_JockeySteer"
	mover.Attachment0 = attachment
	mover.RelativeTo = Enum.ActuatorRelativeTo.World
	mover.VelocityConstraintMode = Enum.VelocityConstraintMode.Plane
	mover.PrimaryTangentAxis = Vector3.xAxis
	mover.SecondaryTangentAxis = Vector3.zAxis
	mover.PlaneVelocity = Vector2.zero
	mover.ForceLimitMode = Enum.ForceLimitMode.Magnitude
	mover.ForceLimitsEnabled = true
	mover.MaxForce = victimRoot.AssemblyMass * Workspace.Gravity * STEER_FORCE_G
	mover.Parent = victimRoot

	state.mover = mover
	state.moverAttachment = attachment
end

local function detachMover(state: State)
	local mover = state.mover
	if mover then
		mover:Destroy()
		state.mover = nil
	end
	local attachment = state.moverAttachment
	if attachment then
		attachment:Destroy()
		state.moverAttachment = nil
	end
end

-- Written only when the heading actually changes. A constraint property is a
-- replicated write, and a ride that re-sent the same vector every frame would
-- cost bandwidth for nothing.
local function applyHeading(state: State)
	local mover = state.mover
	if mover then
		mover.PlaneVelocity = Vector2.new(state.heading.X * STEER_SPEED, state.heading.Z * STEER_SPEED)
	end
end

-- ─── steering ────────────────────────────────────────────────────────────────

--[[ Unit vector away from the nearest teammate, which is the entire "drag them
     off on their own" read. Zero when the victim is already alone. ]]
local function awayFromTeam(victim: Player, position: Vector3): Vector3
	local survivors: any = Registry.find("SurvivorService")
	if not survivors then
		return Vector3.zero
	end

	local nearest = math.huge
	local away = Vector3.zero
	for _, player in survivors:getAliveSurvivors() do
		if player == victim then
			continue
		end
		local _, otherRoot = Support.rootOf(player)
		if not otherRoot then
			continue
		end
		local delta = position - otherRoot.Position
		local flat = Vector3.new(delta.X, 0, delta.Z)
		local distance = flat.Magnitude
		if distance < nearest and distance > 0.05 then
			nearest = distance
			away = flat.Unit
		end
	end
	return away
end

--[[ Unit vector at a live Witch, if one is close enough to be worth the trip.
     Driving somebody into her is the best thing a Jockey can do with a ride, and
     it is free to check: bosses are at most one alive at a time. ]]
--[[
	The nearest ground an infected considers dangerous, as a direction.

	Nearest rather than first, unlike the Witch above — there is only ever one
	Witch worth steering at and there can easily be three pools, and picking
	whichever the tag list happened to return first would have a Jockey aim past
	the acid at its feet toward one across the room.

	Reads a tag rather than asking the Spitter, because the pools are private to
	that module and the next hazard will not be a Spitter's. See
	InfectedConfig.HazardTag.
]]
local function towardHazard(position: Vector3): Vector3
	local best: Vector3? = nil
	local bestDistance = STEER_HAZARD_RANGE

	for _, part in CollectionService:GetTagged(InfectedConfig.HazardTag) do
		if not part:IsA("BasePart") or not part.Parent then
			continue
		end
		local delta = part.Position - position
		local flat = Vector3.new(delta.X, 0, delta.Z)
		local distance = flat.Magnitude
		if distance > 0.05 and distance < bestDistance then
			bestDistance = distance
			best = flat.Unit
		end
	end
	return best or Vector3.zero
end

local function towardWitch(model: Model, position: Vector3): Vector3
	local infected: any = Registry.find("InfectedService")
	if not infected or typeof(infected.getAlive) ~= "function" then
		return Vector3.zero
	end

	for _, other in infected:getAlive(Enums.Infected.Witch) do
		if other == model or not RigUtil.isAlive(other) then
			continue
		end
		local witchRoot = RigUtil.getRoot(other)
		if not witchRoot then
			continue
		end
		local delta = witchRoot.Position - position
		local flat = Vector3.new(delta.X, 0, delta.Z)
		if flat.Magnitude > 0.05 and flat.Magnitude <= STEER_WITCH_RANGE then
			return flat.Unit
		end
	end
	return Vector3.zero
end

--[[
	Picks where the Jockey wants the pair to end up next.

	Eight candidate directions, scored: blocked ones are dropped outright, a drop
	beyond STEER_LEDGE_DROP is a prize, distance from the rest of the team is the
	standing goal, and a live Witch outranks both. Momentum is in the score so a
	Jockey commits to a line instead of re-deciding into a shimmy every third of a
	second.

	Runs on STEER_INTERVAL rather than per frame — sixteen rays a second per
	riding Jockey, of which there are at most two.
]]
local function chooseHeading(model: Model, state: State, victimCharacter: Model, victimRoot: BasePart)
	local victim = state.victim
	if not victim then
		return
	end

	local origin = victimRoot.Position + Vector3.new(0, STEER_PROBE_LIFT, 0)
	local away = awayFromTeam(victim, origin)
	local witch = towardWitch(model, origin)
	local hazard = towardHazard(origin)

	local best = state.heading
	local bestScore = -math.huge

	state.ignore[2] = victimCharacter
	for _, direction in STEER_PROBES do
		local ahead = origin + direction * STEER_PROBE_RANGE
		if not RaycastUtil.hasLineOfSight(origin, ahead, state.ignore) then
			continue
		end

		local score = direction:Dot(state.heading) * STEER_MOMENTUM
			+ direction:Dot(away) * STEER_AWAY_WEIGHT
			+ direction:Dot(witch) * STEER_WITCH_WEIGHT
			+ direction:Dot(hazard) * STEER_HAZARD_WEIGHT

		-- No floor found at all is a void, which is the best ledge there is.
		local ground = RaycastUtil.groundAt(ahead, STEER_GROUND_SEARCH, state.ignore)
		local drop = if ground then origin.Y - ground.Y else math.huge
		if drop >= STEER_LEDGE_DROP then
			score += STEER_LEDGE_BONUS
		end

		if score > bestScore then
			bestScore = score
			best = direction
		end
	end
	state.ignore[2] = nil

	if best ~= state.heading then
		state.heading = best
		applyHeading(state)
	end
end

-- ─── damage and release ──────────────────────────────────────────────────────

local function claw(model: Model, root: BasePart, victimCharacter: Model, victimRoot: BasePart)
	local damageService: any = Registry.find("DamageService")
	if not damageService then
		return
	end

	local delta = victimRoot.Position - root.Position
	local distance = delta.Magnitude
	local direction = if distance > 0.05 then delta.Unit else Vector3.yAxis

	damageService:applyDamage(
		victimCharacter,
		Support.scaledDamage(model, ATTACK.damage),
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

--[[ Hands the body back to the brain. Every exit from a scripted phase goes
     through here so there is exactly one place that can forget to resume. ]]
local function backToStalk(model: Model, brain: any, state: State, delay: number, keepSpeed: boolean?)
	state.phase = PHASE.Stalk
	state.phaseTime = 0
	state.airTime = 0
	state.rideTime = 0
	state.victim = nil
	state.readyAt = os.clock() + delay

	if not keepSpeed then
		local humanoid = model:FindFirstChildOfClass("Humanoid")
		if humanoid then
			humanoid.WalkSpeed = DEFINITION.runSpeed
		end
	end
	Support.resumeBrain(brain)
end

--[[
	Ends a ride and gives the victim their own legs back.

	The WalkSpeed hand-back is the delicate half. clearPinned re-applies the real
	speed itself for anybody who is still upright, so writing anything here would
	only overwrite a correct value with a stale one. A victim who is NOT upright
	got there through a path that dropped the pin fields without a speed pass —
	going down is the one that matters — and they must not keep walking at the
	ride speed while they crawl, so that case, and only that case, is zeroed and
	left for SurvivorService to correct when they stand back up.
]]
local function releaseVictim(model: Model, brain: any, state: State, delay: number, keepSpeed: boolean?)
	detachMover(state)

	local victim = state.victim
	if victim then
		local survivors: any = Registry.find("SurvivorService")
		if survivors then
			if Support.stillPinnedBy(survivors, victim, model) then
				survivors:setPinned(victim, nil)
			end
			if not isRideable(survivors, victim) then
				local character = victim.Character
				local humanoid = character and character:FindFirstChildOfClass("Humanoid")
				if humanoid and humanoid.WalkSpeed ~= 0 then
					humanoid.WalkSpeed = 0
				end
			end
		end
	end

	backToStalk(model, brain, state, delay, keepSpeed)
end

-- ─── phases ──────────────────────────────────────────────────────────────────

--[[
	Who to ride, and it is not simply the nearest.

	A ride is worth exactly as much as the distance it can cover before somebody
	shoots the Jockey off. Landing on the survivor in the middle of the group is
	three seconds and a free special kill; landing on the one who has drifted to
	the edge is a survivor dragged somewhere nobody can reach them, which is the
	whole reason this creature is in the game.

	So the same isolation read the Hunter uses, and for the same reason — see
	Support.isolationOf — plus Support.claimBias, so a Jockey does not go for
	somebody a Hunter has already committed to. Two specials on one survivor is
	one pin and one wasted special: the second one cannot even land, because
	isRideable refuses anybody already held.
]]
local function pickTarget(model: Model, root: BasePart): (Player?, Player?)
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
		local _, victimRoot = Support.rootOf(player)
		if not victimRoot then
			continue
		end

		local distance = (victimRoot.Position - origin).Magnitude
		if distance < nearestDistance then
			nearestDistance = distance
			nearest = player
		end

		-- Anybody already down or already held is not a ride: the Jockey's whole
		-- contribution is taking a working survivor out of the fight.
		if not isRideable(survivors, player) then
			continue
		end
		if distance > DEFINITION.sightRange then
			continue
		end

		local isolation = Support.isolationOf(candidates, player, victimRoot.Position, ISOLATION_FULL)
		local lonely = math.clamp(isolation / ISOLATION_FULL, 0, 1)
		local score = distance
			* (1 - ISOLATION_BIAS * lonely)
			* Support.claimBias(model, player)
			-- And a survivor who cannot see it coming. See Support.blindBias.
			* Support.blindBias(survivors, player)
		if score < bestScore then
			bestScore = score
			best = player
		end
	end

	return best, nearest
end

local function beginGather(
	model: Model,
	brain: any,
	state: State,
	root: BasePart,
	targetRoot: BasePart,
	dt: number
)
	Support.pauseBrain(brain)

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		-- Rooted for the tell. A Jockey that keeps closing while it laughs gives
		-- the target a warning they cannot act on.
		humanoid.WalkSpeed = 0
	end

	Support.faceTowards(brain, root, targetRoot.Position, dt)
	Support.playSound("JockeyIdle", root)

	state.phase = PHASE.Gather
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
	-- jumpPower is an initial upward velocity, so the flight time is fixed and
	-- the horizontal speed is what has to cover the gap.
	local flight = (2 * DEFINITION.jumpPower) / math.max(Workspace.Gravity, 1)

	local delta = targetRoot.Position - root.Position
	local flat = Vector3.new(delta.X, 0, delta.Z)
	local speed = math.min(flat.Magnitude / flight, LEAP_MAX_SPEED)
	local heading = if flat.Magnitude > 0.05 then flat.Unit else root.CFrame.LookVector

	Support.faceTowards(brain, root, targetRoot.Position, dt)
	root.AssemblyLinearVelocity = heading * speed + Vector3.new(0, DEFINITION.jumpPower, 0)

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
	end
	Support.playSound("JockeyRide", root)

	state.phase = PHASE.Leap
	state.phaseTime = 0
	state.airTime = 0
end

local function mount(model: Model, brain: any, state: State, root: BasePart, player: Player)
	local survivors: any = Registry.find("SurvivorService")
	local character, victimRoot = Support.rootOf(player)
	if not survivors or not character or not victimRoot then
		backToStalk(model, brain, state, MISS_RECOVERY)
		return
	end

	-- setPinned refuses anybody who is not upright, and that refusal is correct:
	-- steering a survivor who is already crawling would be a pin with no counter.
	if survivors:setPinned(player, model, Enums.Infected.Jockey) ~= true then
		backToStalk(model, brain, state, MISS_RECOVERY)
		return
	end

	state.phase = PHASE.Ride
	state.phaseTime = 0
	state.rideTime = 0
	state.victim = player
	state.nextClaw = os.clock() + ATTACK.cooldown
	state.nextSteer = 0

	-- Start the ride pointed where the victim was already facing, flattened: the
	-- first steer decision arrives on the next tick and momentum is scored
	-- against this, so it must be a planar unit vector from the outset.
	local facing = victimRoot.CFrame.LookVector
	local flat = Vector3.new(facing.X, 0, facing.Z)
	state.heading = if flat.Magnitude > 0.05 then flat.Unit else Vector3.zAxis

	attachMover(state, victimRoot)
	applyHeading(state)
	Remotes.Event.CameraImpulse:FireClient(player, MOUNT_CAMERA_IMPULSE)
	Support.playSound("JockeyRide", root)
end

local function stepStalk(model: Model, brain: any, state: State, root: BasePart, dt: number, now: number)
	if now >= state.nextScan then
		state.nextScan = now + SCAN_INTERVAL
		local rideable, nearest = pickTarget(model, root)
		state.target = rideable
		state.chase = rideable or nearest
		local chase = state.chase
		Support.setBrainTarget(brain, if chase then chase.Character else nil)
		-- Renewed while this Jockey is still going for them. See Support.claim.
		Support.claim(model, rideable)
	end

	local target = state.target
	local _, targetRoot = Support.rootOf(target)
	if not target or not targetRoot then
		return
	end

	local distance = (targetRoot.Position - root.Position).Magnitude

	-- The approach laugh, on its own clock rather than tied to the gather, so a
	-- Jockey working its way around the team is audible before it commits.
	if now >= state.nextCackle and distance <= DEFINITION.sightRange then
		state.nextCackle = now + CACKLE_INTERVAL
		Support.playSound("JockeyIdle", root)
	end

	if now < state.readyAt then
		return
	end
	if distance < LEAP_MIN_RANGE or distance > LEAP_MAX_RANGE then
		return
	end

	local character = target.Character
	if not character then
		return
	end

	state.ignore[2] = character
	local visible = RaycastUtil.hasLineOfSight(root.Position, targetRoot.Position, state.ignore)
	state.ignore[2] = nil
	if
		not visible
		or not Support.hasClearArc(state.ignore, root.Position, targetRoot.Position, character, ARC_CLEARANCE)
	then
		return
	end

	beginGather(model, brain, state, root, targetRoot, dt)
end

local function stepGather(model: Model, brain: any, state: State, root: BasePart, dt: number)
	local _, targetRoot = Support.rootOf(state.target)
	if not targetRoot then
		backToStalk(model, brain, state, 0.4)
		return
	end

	-- Tracking during the gather is what makes stepping aside a real answer: the
	-- Jockey may turn, turnSpeed decides how much of the dodge it keeps up with,
	-- and the leap itself commits to whatever it is facing when it goes.
	Support.faceTowards(brain, root, targetRoot.Position, dt)

	if state.phaseTime >= GATHER_TIME then
		launch(model, brain, state, root, targetRoot, dt)
	end
end

local function stepLeap(model: Model, brain: any, state: State, root: BasePart, dt: number)
	state.airTime += dt

	local survivors: any = Registry.find("SurvivorService")
	if survivors then
		local position = root.Position
		for _, player in survivors:getAliveSurvivors() do
			-- A survivor who is already down is not a landing. Passing through
			-- them costs the Jockey the leap; landing on them would cost it the
			-- leap AND leave it standing on a body it cannot ride.
			if not isRideable(survivors, player) then
				continue
			end
			local _, victimRoot = Support.rootOf(player)
			if victimRoot and (victimRoot.Position - position).Magnitude <= CONTACT_RADIUS then
				mount(model, brain, state, root, player)
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
		-- A missed leap is the reward for hearing the cackle and moving. The
		-- recovery is long enough to shoot a Jockey that guessed wrong.
		backToStalk(model, brain, state, MISS_RECOVERY)
	end
end

local function stepRide(model: Model, brain: any, state: State, root: BasePart, dt: number, now: number)
	local victim = state.victim
	local survivors: any = Registry.find("SurvivorService")
	if not victim or not survivors then
		releaseVictim(model, brain, state, RELEASE_RECOVERY)
		return
	end

	local character, victimRoot = Support.rootOf(victim)
	if not character or not victimRoot or not Support.stillPinnedBy(survivors, victim, model) then
		-- Shoved off, shot off, or the victim went down. All three are answers,
		-- and all three end here.
		releaseVictim(model, brain, state, RELEASE_RECOVERY)
		return
	end

	state.rideTime += dt
	if state.rideTime >= RIDE_MAX_TIME then
		releaseVictim(model, brain, state, RELEASE_RECOVERY)
		return
	end

	-- The victim keeps their legs. SurvivorService zeroed WalkSpeed when the pin
	-- landed and will not touch it again while the pin holds, so re-asserting the
	-- limp speed here is what turns a lockout into a steer. Guarded, because an
	-- unchanged property write still costs a replication check.
	local victimHumanoid = character:FindFirstChildOfClass("Humanoid")
	if victimHumanoid and victimHumanoid.WalkSpeed ~= RIDE_SPEED then
		victimHumanoid.WalkSpeed = RIDE_SPEED
	end

	if now >= state.nextSteer then
		state.nextSteer = now + STEER_INTERVAL
		chooseHeading(model, state, character, victimRoot)
	end

	-- Riding the victim's CFrame rather than pushing our own body around keeps
	-- every position the victim's client sees for its own character honest: the
	-- Jockey is furniture bolted to their shoulders for the duration.
	root.CFrame = victimRoot.CFrame * CFrame.new(0, 2.0, 0.7)
	root.AssemblyLinearVelocity = Vector3.zero

	if now >= state.nextCackle then
		state.nextCackle = now + RIDE_CACKLE_INTERVAL
		Support.playSound("JockeyRide", root)
	end

	if now >= state.nextClaw then
		state.nextClaw = now + ATTACK.cooldown
		claw(model, root, character, victimRoot)
	end
end

-- ─── module surface ──────────────────────────────────────────────────────────

local Jockey = {}

function Jockey.onSpawn(model: Model, brain: any)
	local state = ensure(model)
	state.ignore[1] = model

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.WalkSpeed = DEFINITION.runSpeed
	end

	local root = RigUtil.getRoot(model)
	if root then
		Support.playSound("JockeyIdle", root)
		-- The spawn cackle counts as this Jockey's first; without this the
		-- approach clock fires again on the very next frame.
		state.nextCackle = os.clock() + CACKLE_INTERVAL
	end
	Support.setBrainTarget(brain, nil)
end

function Jockey.onUpdate(model: Model, brain: any, dt: number)
	local state = states[model] or ensure(model)
	local root = RigUtil.getRoot(model)
	if not root then
		return
	end

	local now = os.clock()
	state.phaseTime += dt

	if state.phase ~= PHASE.Stalk and Support.isStaggered(brain) then
		releaseVictim(model, brain, state, RELEASE_RECOVERY, true)
		return
	end

	if state.phase == PHASE.Ride then
		stepRide(model, brain, state, root, dt, now)
	elseif state.phase == PHASE.Leap then
		stepLeap(model, brain, state, root, dt)
	elseif state.phase == PHASE.Gather then
		stepGather(model, brain, state, root, dt)
	else
		stepStalk(model, brain, state, root, dt, now)
	end
end

function Jockey.onDeath(model: Model, brain: any, _ctx: any)
	local state = states[model]
	if not state then
		return
	end
	-- Releasing here is belt-and-braces: SurvivorService drops a pin whose owner
	-- stops being alive on its own heartbeat. Doing it now frees the victim on
	-- the frame the Jockey dies rather than on the next one — and it is the only
	-- thing that destroys the mover, which must never outlive the ride.
	releaseVictim(model, brain, state, 0)
	Support.unclaim(model)
	states[model] = nil
end

return Jockey
