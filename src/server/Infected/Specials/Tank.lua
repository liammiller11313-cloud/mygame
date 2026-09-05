--!strict
--[[
	Tank — the set piece.

	Four thousand health, immune to stagger, and faster than a survivor who stops
	to shoot. That last clause is the whole design: the Tank cannot be outrun by
	anybody who wants to damage it, so the team has to move as a unit and fire in
	turns. It is the most cooperative the game ever gets, and every number here
	protects that shape rather than trying to be difficult on its own.

	Two attacks:
	  * The swing. attack.damage in a wide arc that throws survivors clear, which
	    is what stops the team clumping in a doorway and taking it down as a
	    firing squad.
	  * The rock. It tears a chunk out of the world and arcs it at whoever is
	    furthest away, so distance is not a solution either. Damage lands through
	    DamageService:applyExplosion, so cover genuinely works against it.

	Fire is the intended counter — burnDamagePerSecond is 150, six times a
	Common's — and that lives in InfectedService's ignite path, not here.

	The music reacts to Attributes.Game.TankActive, which InfectedService owns and
	writes off its own live counts. This file used to set and clear it too, with a
	scan for "is another one still standing" — and that was a second writer racing
	one that already knew the answer.

	Getting stuck is the failure mode that would ruin the encounter, so there is
	an explicit answer: if the Tank makes no progress toward its target for a few
	seconds, it stops pathing and smashes straight at it.

	── WHY NO TWO OF THEM ARE THE SAME ─────────────────────────────────────────
	Everything above describes one Tank. A team that has fought six of them has
	fought the same one six times, and once a set piece is memorised it stops
	being a set piece. Three things vary per body, and none of them change how
	hard it is — only what it does first and when.

	  * THE OPENING. Rolled on spawn, and it owns roughly the first ten seconds.
	    It either walks in roaring, opens at range with a rock before anyone has
	    seen it, or arrives quietly at walking pace and does not announce itself
	    until it is already close. See OPENINGS.
	  * THE TEMPO. A per-body multiplier on every cooldown. Its real job is the
	    pack: two Tanks released three seconds apart on the same tempo swing in
	    unison, which reads as one enormous attack rather than two, and a team
	    that dodges one dodges both.
	  * THE ENRAGE. Below a quarter health it gets faster and acts oftener. This
	    is deliberately the same quarter at which the boss bar goes hot, so the
	    readout a team is already watching is the warning rather than a second
	    thing to learn.
]]

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Enums = require(Shared.Enums)
local InfectedConfig = require(Shared.Config.InfectedConfig)
local RaycastUtil = require(Shared.Util.RaycastUtil)
local Registry = require(Shared.Util.Registry)
local Remotes = require(Shared.Net.Remotes)
local RigUtil = require(Shared.Util.RigUtil)
local Types = require(Shared.Types)

local Support = require(script.Parent.Support)

local DEFINITION = InfectedConfig.Definitions[Enums.Infected.Tank]
local ATTACK = DEFINITION.attack

local PHASE = table.freeze({
	Pursue = "Pursue", -- the brain drives
	Swing = "Swing", -- rooted, arm back, arc about to land
	Tear = "Tear", -- rooted, ripping a chunk out of the floor
	Direct = "Direct", -- pathing gave up; walking straight at the target
})

-- Half-angle of the melee arc. Wide enough that standing shoulder to shoulder
-- gets the whole team hit, which is the entire reason to spread out.
local SWING_HALF_ANGLE = 70
-- Reach is attack.range plus a little slack, so a survivor backpedalling at the
-- instant of impact still eats it. Anything tighter makes the swing feel like it
-- passed through them.
local SWING_REACH = ATTACK.range * 1.15
local SWING_RECOVER = 0.35

-- Being thrown is the point of the swing: it breaks up the firing line and costs
-- the survivor the time it takes to get up and re-aim.
local LAUNCH_SPEED = 62
local LAUNCH_LIFT = 34
-- The server has to own the victim's physics for the throw to land at all; kept
-- short because a character that stays server-simulated feels laggy to play.
local LAUNCH_OWNERSHIP_TIME = 0.8

-- The rock. Interval is jittered so a team cannot count seconds between throws.
local ROCK_INTERVAL_MIN = 9
local ROCK_INTERVAL_MAX = 15
local ROCK_MIN_RANGE = 26 -- inside this it just swings
local ROCK_MAX_RANGE = 220
local ROCK_TEAR_TIME = 1.1 -- visible, audible, and long enough to break sightline
local ROCK_SIZE = 5.5
local ROCK_SPEED = 130 -- studs per second of flight time budget, not muzzle speed
local ROCK_MIN_FLIGHT = 0.45
local ROCK_MAX_FLIGHT = 2.4
local ROCK_LIFETIME = 6
local ROCK_BLAST_RADIUS = 14
-- How far ahead of a moving survivor the throw aims. Not a full lead: a Tank that
-- never misses a running target is a Tank you cannot dodge.
local ROCK_LEAD = 0.55

-- Stuck detection. Sampled on a slow clock; three bad samples in a row and it
-- stops trusting the path.
local STUCK_SAMPLE = 1.0
local STUCK_PROGRESS = 1.5 -- studs of closing per sample that counts as progress
local STUCK_SAMPLES_TO_GIVE_UP = 3
local DIRECT_TIME = 3.0 -- how long it smashes straight ahead before pathing again
local DIRECT_PROBE = 4.0

local FOOTSTEP_INTERVAL = 0.42
local ROAR_INTERVAL = 11
local SCAN_INTERVAL = 0.3

--[[ How this body opens. Rolled once on spawn and spent within about ten
     seconds; after that every Tank behaves the same, which is the point — the
     variation is in the arrival, not in the fight. ]]
local OPENING = table.freeze({
	-- Straight in, roaring, no rock until the first interval is up. The
	-- classic, and the one wave 5 wants a team to meet first.
	Charge = "Charge",
	-- Opens with the rock. A team hears the roar and then takes a hit from
	-- somewhere they have not looked yet.
	Artillery = "Artillery",
	-- Walks in at survivor pace and says nothing. The scariest of the three by
	-- some distance, because the audio cue a team relies on to locate a Tank is
	-- simply not there until it is already inside the room.
	Stalk = "Stalk",
})
local OPENINGS = table.freeze({ OPENING.Charge, OPENING.Artillery, OPENING.Stalk })

local STALK_TIME = 6.5 -- how long the quiet lasts before it announces itself
local STALK_SPEED = 0.62 -- fraction of run speed while stalking

--[[ Per-body cooldown multiplier. Deliberately not centred on 1: a Tank that is
     slightly slower than the book is still a Tank, and the pack only needs the
     two bodies to disagree with each other. ]]
local TEMPO_MIN = 0.85
local TEMPO_MAX = 1.18

--[[ The enrage. The fraction is shared with BossBarController's NEARLY_DEAD on
     purpose — the bar going hot IS this, rather than a second tell nobody was
     taught. Modest numbers: the last quarter of a Tank should be the hardest
     quarter, not a different creature. ]]
local ENRAGE_FRACTION = 0.25
local ENRAGE_SPEED = 1.10
local ENRAGE_TEMPO = 0.62 -- multiplier on every cooldown, so it acts oftener

local random = Random.new()

local SWING_CAMERA_IMPULSE = table.freeze({
	position = Vector3.new(0, -0.6, 1.1),
	rotation = Vector3.new(-16, 5, 0),
	decay = 4,
})

type State = {
	phase: string,
	phaseTime: number,
	nextScan: number,
	nextSwing: number,
	nextRock: number,
	nextRoar: number,
	nextFootstep: number,
	swung: boolean,
	target: Player?,
	rock: BasePart?,
	rockFrom: Vector3,
	rockLife: number,
	--[[ This body's own hit, which is the definition's unless it is an Apex. See
	     Support.eliteOf: the swing and the rock read the config directly, so the
	     elite multiplier has to be resolved once here or it never applies to the
	     two things a Tank actually kills anybody with. ]]
	damage: number,
	--[[ This body's opening, and the clock it runs out on. See OPENINGS. The
	     deadline is absolute rather than counted down so nothing has to remember
	     to tick it. ]]
	opening: string,
	openingUntil: number,
	tempo: number,
	enraged: boolean,
	stuckClock: number,
	stuckSamples: number,
	lastDistance: number,
	ignore: { Instance },
	probe: RaycastParams,
}

-- Weak keys: a Tank despawned rather than killed never reaches onDeath.
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
			phase = PHASE.Pursue,
			phaseTime = 0,
			nextScan = 0,
			nextSwing = 0,
			nextRock = os.clock() + ROCK_INTERVAL_MIN,
			nextRoar = 0,
			nextFootstep = 0,
			swung = false,
			damage = ATTACK.damage,
			opening = OPENING.Charge,
			openingUntil = 0,
			tempo = 1,
			enraged = false,
			target = nil,
			rock = nil,
			rockFrom = Vector3.zero,
			rockLife = 0,
			stuckClock = 0,
			stuckSamples = 0,
			lastDistance = math.huge,
			ignore = { model },
			probe = probe,
		}
		states[model] = state
	end
	return state
end

--[[
	How fast this body should be moving.

	Every place that writes WalkSpeed goes through here, and that is the whole
	reason it exists: the three that used to write DEFINITION.runSpeed straight
	were quietly undoing the elite tier's multiplier every time the Tank finished
	a swing. That was a no-op only because the Apex tier's speed happens to be
	1.0 — it would not have stayed one, and the enrage below would have been
	eaten by it within a second of landing.

	`allowStalk` is false for the anti-stuck path: a Tank that has given up on
	pathing is already the worst state this encounter has, and it does not get to
	be slow on top of it.
]]
local function cruiseSpeed(model: Model, state: State, allowStalk: boolean): number
	local speed = Support.scaledSpeed(model, DEFINITION.runSpeed)
	if state.enraged then
		speed *= ENRAGE_SPEED
	end
	if allowStalk and state.opening == OPENING.Stalk and os.clock() < state.openingUntil then
		speed *= STALK_SPEED
	end
	return speed
end

--[[ The multiplier on every cooldown this body waits out: its own tempo, halved
     again once it is enraged. ]]
local function cadence(state: State): number
	local factor = state.tempo
	if state.enraged then
		factor *= ENRAGE_TEMPO
	end
	return factor
end

--[[ Crosses into the enrage once, at a quarter health, and never back. Faster,
     acting oftener, and it says so — the roar is the audible half of the tell
     the boss bar is already showing. ]]
local function checkEnrage(model: Model, state: State, root: BasePart)
	if state.enraged then
		return
	end
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.MaxHealth <= 0 then
		return
	end
	if humanoid.Health / humanoid.MaxHealth > ENRAGE_FRACTION then
		return
	end

	state.enraged = true
	state.nextRoar = 0
	--[[ The stalk is over whatever its clock says. A Tank cannot be quietly
	     sneaking up on a team that has already taken three quarters of it off. ]]
	state.openingUntil = 0
	--[[ Pulled in rather than reset, so enraging does not GRANT a rock to a Tank
	     that has just thrown one. ]]
	state.nextRock = math.min(state.nextRock, os.clock() + ROCK_INTERVAL_MIN * cadence(state))

	--[[ Only in Pursue. Swing and Tear hold WalkSpeed at zero on purpose and
	     writing over that mid-attack slides the Tank out of its own animation;
	     backToPursue reads the new speed the moment the attack ends. ]]
	if state.phase == PHASE.Pursue and humanoid.WalkSpeed > 0 then
		humanoid.WalkSpeed = cruiseSpeed(model, state, true)
	end
	Support.playSound("TankRoar", root)
end

local function nearestSurvivor(root: BasePart): (Player?, BasePart?)
	local survivors: any = Registry.find("SurvivorService")
	if not survivors then
		return nil, nil
	end

	local origin = root.Position
	local best: Player? = nil
	local bestRoot: BasePart? = nil
	local bestDistance = math.huge

	for _, player in survivors:getAliveSurvivors() do
		local _, victimRoot = Support.rootOf(player)
		if victimRoot then
			local distance = (victimRoot.Position - origin).Magnitude
			if distance < bestDistance and distance <= DEFINITION.sightRange then
				bestDistance = distance
				best = player
				bestRoot = victimRoot
			end
		end
	end

	return best, bestRoot
end

-- ─── the rock ────────────────────────────────────────────────────────────────

local function destroyRock(state: State)
	local rock = state.rock
	if rock then
		rock:Destroy()
		state.rock = nil
	end
end

local function detonateRock(model: Model, state: State, position: Vector3)
	local rock = state.rock
	if not rock then
		return
	end
	destroyRock(state)

	local damageService: any = Registry.find("DamageService")
	if damageService then
		-- Radial, sightline-checked, and falling off to nothing at the rim: cover
		-- is a real answer to a rock, which is what makes the Tank a movement
		-- problem rather than a pure damage race.
		damageService:applyExplosion(
			position,
			ROCK_BLAST_RADIUS,
			state.damage,
			Types.newDamageContext({
				attackerModel = model,
				damageType = Enums.DamageType.Explosive,
				region = Enums.HitRegion.Torso,
				hitPosition = position,
				direction = Vector3.yAxis,
			})
		)
	end

	local audio: any = Registry.find("AudioService")
	if audio then
		audio:play("Impact", "Concrete", position)
	end
end

--[[
	Steps the rock in flight from the Tank's own update, so a projectile never
	costs a RunService connection of its own. The segment between where it was and
	where it is now is raycast, which catches a hit on a wall or a survivor the
	frame it happens regardless of how fast the rock is moving.
]]
local function stepRock(model: Model, state: State, dt: number)
	local rock = state.rock
	if not rock or rock.Anchored then
		return -- still being held; the throw has not happened yet
	end

	state.rockLife += dt
	local position = rock.Position
	local delta = position - state.rockFrom
	local travelled = delta.Magnitude

	if travelled > 0.05 then
		local hit = Workspace:Raycast(state.rockFrom, delta, state.probe)
		if hit then
			detonateRock(model, state, hit.Position)
			return
		end
	end

	state.rockFrom = position
	if state.rockLife >= ROCK_LIFETIME then
		detonateRock(model, state, position)
	end
end

local function tearRock(model: Model, root: BasePart, state: State)
	local rock = Instance.new("Part")
	rock.Name = "FL_TankRock"
	rock.Size = Vector3.one * ROCK_SIZE
	rock.Color = DEFINITION.accentColor
	rock.Material = Enum.Material.Slate
	rock.Anchored = true
	rock.CanCollide = false
	rock.CanQuery = false
	rock.CanTouch = false
	rock.CastShadow = true
	rock.Locked = true
	rock.CollisionGroup = "Debris"
	rock.Parent = Workspace

	state.rock = rock
	state.rockLife = 0
	state.rockFrom = root.Position
	Debris:AddItem(rock, ROCK_TEAR_TIME + ROCK_LIFETIME + 1)
end

local function throwRock(model: Model, root: BasePart, state: State, targetRoot: BasePart)
	local rock = state.rock
	if not rock then
		return
	end

	local origin = rock.Position
	local lead = targetRoot.AssemblyLinearVelocity * ROCK_LEAD
	local aim = targetRoot.Position + Vector3.new(lead.X, 0, lead.Z)
	local delta = aim - origin
	local flight = math.clamp(delta.Magnitude / ROCK_SPEED, ROCK_MIN_FLIGHT, ROCK_MAX_FLIGHT)

	-- Solve the launch velocity that lands on `aim` after `flight` seconds under
	-- the world's gravity. This is what gives the throw its arc instead of a flat
	-- line, and the arc is what makes an incoming rock readable.
	local gravity = Vector3.new(0, -Workspace.Gravity, 0)
	local velocity = (delta - gravity * (0.5 * flight * flight)) / flight

	rock.Anchored = false
	rock.AssemblyLinearVelocity = velocity
	rock.AssemblyAngularVelocity = Vector3.new(math.random(-6, 6), math.random(-6, 6), math.random(-6, 6))
	state.rockFrom = origin
	state.rockLife = 0
	-- The rock must not detonate on the arm that threw it.
	state.probe.FilterDescendantsInstances = { model, rock }
end

-- ─── phases ──────────────────────────────────────────────────────────────────

local function backToPursue(model: Model, brain: any, state: State)
	state.phase = PHASE.Pursue
	state.phaseTime = 0
	state.swung = false

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.WalkSpeed = cruiseSpeed(model, state, true)
	end
	Support.resumeBrain(brain)
end

local function stepPursue(model: Model, brain: any, state: State, root: BasePart, dt: number, now: number)
	--[[ Silent for as long as the stalk lasts, and the FIRST thing it does when
	     that runs out is roar — the opening's whole payoff is the moment a team
	     finds out how close it already is. ]]
	if now >= state.nextRoar and now >= state.openingUntil then
		state.nextRoar = now + ROAR_INTERVAL
		Support.playSound("TankRoar", root)
		--[[ Spent. Without this the stalk keeps slowing it down for as long as
		     its clock runs, which would be a Tank that roars and then ambles. ]]
		state.openingUntil = 0
		local humanoid = model:FindFirstChildOfClass("Humanoid")
		if humanoid and humanoid.WalkSpeed > 0 then
			humanoid.WalkSpeed = cruiseSpeed(model, state, true)
		end
	end

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.MoveDirection.Magnitude > 0.1 and now >= state.nextFootstep then
		-- Footsteps are how a Tank is located through a wall. They are on the
		-- movement state rather than on a timer so a stationary Tank is silent.
		state.nextFootstep = now + FOOTSTEP_INTERVAL
		Support.playSound("TankFootstep", root)
	end

	if now >= state.nextScan then
		state.nextScan = now + SCAN_INTERVAL
		local target = nearestSurvivor(root)
		state.target = target
		Support.setBrainTarget(brain, if target then target.Character else nil)
	end

	local target = state.target
	local character, targetRoot = Support.rootOf(target)
	if not target or not character or not targetRoot then
		return
	end

	local distance = (targetRoot.Position - root.Position).Magnitude

	-- Progress check. A Tank that cannot find a path is worse than no Tank at
	-- all, so failing to close is treated as a fault and answered directly.
	state.stuckClock += dt
	if state.stuckClock >= STUCK_SAMPLE then
		state.stuckClock = 0
		if distance > SWING_REACH and distance > state.lastDistance - STUCK_PROGRESS then
			state.stuckSamples += 1
		else
			state.stuckSamples = 0
		end
		state.lastDistance = distance

		if state.stuckSamples >= STUCK_SAMPLES_TO_GIVE_UP then
			state.stuckSamples = 0
			Support.pauseBrain(brain)
			if humanoid then
				humanoid.WalkSpeed = cruiseSpeed(model, state, false)
				humanoid.AutoRotate = true
			end
			state.phase = PHASE.Direct
			state.phaseTime = 0
			Support.playSound("TankRoar", root)
			return
		end
	end

	if distance <= SWING_REACH and now >= state.nextSwing then
		Support.pauseBrain(brain)
		if humanoid then
			humanoid.WalkSpeed = 0
		end
		state.phase = PHASE.Swing
		state.phaseTime = 0
		state.swung = false
		return
	end

	if now >= state.nextRock and distance >= ROCK_MIN_RANGE and distance <= ROCK_MAX_RANGE then
		state.ignore[2] = character
		local visible = RaycastUtil.hasLineOfSight(root.Position, targetRoot.Position, state.ignore)
		state.ignore[2] = nil
		if visible and not state.rock then
			Support.pauseBrain(brain)
			if humanoid then
				humanoid.WalkSpeed = 0
			end
			tearRock(model, root, state)
			Support.playSound("TankRoar", root)
			state.phase = PHASE.Tear
			state.phaseTime = 0
		end
	end
end

local function stepSwing(model: Model, brain: any, state: State, root: BasePart, dt: number)
	local _, targetRoot = Support.rootOf(state.target)
	if targetRoot and state.phaseTime < ATTACK.windup then
		-- Tracking during the wind-up, at turnSpeed. 150 degrees a second is fast
		-- enough that standing still is fatal and slow enough that running past
		-- its shoulder is not.
		Support.faceTowards(brain, root, targetRoot.Position, dt)
	end

	if state.phaseTime < ATTACK.windup then
		return
	end

	if not state.swung then
		state.swung = true
		state.nextSwing = os.clock() + ATTACK.cooldown * cadence(state)

		--[[ A stalk is spent the moment it connects, whatever its clock says, and
		     the roar it was holding lands on the way out of the swing. Getting hit
		     by something you never heard and THEN hearing it is the whole payoff;
		     staying quiet and 38% slower after that is just a Tank you outrun. ]]
		state.openingUntil = 0
		state.nextRoar = 0

		local survivors: any = Registry.find("SurvivorService")
		if survivors then
			local origin = root.Position
			local facing = root.CFrame.LookVector
			for _, player in survivors:getAliveSurvivors() do
				local character, victimRoot = Support.rootOf(player)
				if not character or not victimRoot then
					continue
				end

				local delta = victimRoot.Position - origin
				local distance = delta.Magnitude
				if distance > SWING_REACH or distance < 0.05 then
					continue
				end
				if math.deg(math.acos(math.clamp(delta.Unit:Dot(facing), -1, 1))) > SWING_HALF_ANGLE then
					continue
				end

				Support.damage(model, character, victimRoot, origin, state.damage)
				local away = Vector3.new(delta.X, 0, delta.Z)
				local heading = if away.Magnitude > 0.05 then away.Unit else facing
				Support.launch(
					victimRoot,
					heading * LAUNCH_SPEED + Vector3.new(0, LAUNCH_LIFT, 0),
					LAUNCH_OWNERSHIP_TIME
				)
				Remotes.Event.CameraImpulse:FireClient(player, SWING_CAMERA_IMPULSE)
			end
		end
	end

	if state.phaseTime >= ATTACK.windup + SWING_RECOVER then
		backToPursue(model, brain, state)
	end
end

local function stepTear(model: Model, brain: any, state: State, root: BasePart, dt: number)
	local rock = state.rock
	local _, targetRoot = Support.rootOf(state.target)

	if not rock or not targetRoot then
		destroyRock(state)
		state.nextRock = os.clock() + ROCK_INTERVAL_MIN * cadence(state)
		backToPursue(model, brain, state)
		return
	end

	Support.faceTowards(brain, root, targetRoot.Position, dt)
	local facing = root.CFrame.LookVector

	-- Held overhead through the whole tell. The rock being visible in its hands
	-- before it leaves them is the only reason a survivor can react to one.
	rock.CFrame = CFrame.new(root.Position + Vector3.new(0, ROCK_SIZE * 0.9, 0) + facing * 2)

	if state.phaseTime < ROCK_TEAR_TIME then
		return
	end

	throwRock(model, root, state, targetRoot)
	state.nextRock = os.clock() + random:NextNumber(ROCK_INTERVAL_MIN, ROCK_INTERVAL_MAX) * cadence(state)
	backToPursue(model, brain, state)
end

--[[ Pathing gave up, so it walks the straight line and jumps anything low enough
     to jump. A Tank standing still against a crate is the single worst outcome in
     this encounter — worse than one that arrives too early. ]]
local function stepDirect(model: Model, brain: any, state: State, root: BasePart, now: number)
	local _, targetRoot = Support.rootOf(state.target)
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if not targetRoot or not humanoid then
		backToPursue(model, brain, state)
		return
	end

	local flat =
		Vector3.new(targetRoot.Position.X - root.Position.X, 0, targetRoot.Position.Z - root.Position.Z)
	if flat.Magnitude > 0.05 then
		local heading = flat.Unit

		-- brain:moveTo is the sanctioned way for a special to drive a paused body:
		-- it throttles the MoveTo re-issue and drops the path the brain could not
		-- finish, which is the whole reason we are here.
		if brain and typeof(brain.moveTo) == "function" then
			brain:moveTo(targetRoot.Position)
		else
			humanoid:Move(heading, false)
		end

		local blocked =
			Workspace:Raycast(root.Position + Vector3.new(0, 1, 0), heading * DIRECT_PROBE, state.probe)
		if blocked then
			humanoid.Jump = true
		end
	end

	if humanoid.MoveDirection.Magnitude > 0.1 and now >= state.nextFootstep then
		state.nextFootstep = now + FOOTSTEP_INTERVAL
		Support.playSound("TankFootstep", root)
	end

	if flat.Magnitude <= SWING_REACH or state.phaseTime >= DIRECT_TIME then
		state.lastDistance = math.huge
		backToPursue(model, brain, state)
	end
end

-- ─── module surface ──────────────────────────────────────────────────────────

local Tank = {}

function Tank.onSpawn(model: Model, brain: any)
	local state = ensure(model)
	state.ignore[1] = model
	state.probe.FilterDescendantsInstances = { model }
	state.damage = Support.scaledDamage(model, ATTACK.damage)

	local now = os.clock()

	--[[ The dice, and they are thrown exactly here: a body's opening and tempo
	     are decided when it stands up and never re-rolled, so a Tank does not
	     change its mind about what kind of Tank it is halfway through a fight. ]]
	state.opening = OPENINGS[random:NextInteger(1, #OPENINGS)]
	state.tempo = random:NextNumber(TEMPO_MIN, TEMPO_MAX)
	state.enraged = false
	state.openingUntil = if state.opening == OPENING.Stalk then now + STALK_TIME else 0

	if state.opening == OPENING.Artillery then
		-- Ready to throw as soon as it has a target in range and in sight.
		state.nextRock = 0
	elseif state.opening == OPENING.Charge then
		-- No rock at all through the arrival: this one is pure ground pressure.
		state.nextRock = now + ROCK_INTERVAL_MAX * cadence(state)
	else
		state.nextRock = now + ROCK_INTERVAL_MIN * cadence(state)
	end

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		--[[ Through cruiseSpeed rather than straight off the definition. This
		     line runs AFTER InfectedService applied the elite's speed to the
		     Humanoid and would otherwise put it back — which for the Apex is a
		     no-op today (its multiplier is 1.0, on purpose: outrunning a Tank is
		     the counter) but would silently eat any future tier's. ]]
		humanoid.WalkSpeed = cruiseSpeed(model, state, true)
	end

	local root = RigUtil.getRoot(model)
	if root then
		--[[ A stalking Tank arrives without a sound and the roar is held until
		     its clock runs out; everything else announces itself on the spot. ]]
		if state.opening == OPENING.Stalk then
			state.nextRoar = state.openingUntil
		else
			Support.playSound("TankRoar", root)
			state.nextRoar = now + ROAR_INTERVAL
		end
	end
	Support.setBrainTarget(brain, nil)
end

function Tank.onUpdate(model: Model, brain: any, dt: number)
	local state = states[model] or ensure(model)
	local root = RigUtil.getRoot(model)
	if not root then
		return
	end

	local now = os.clock()
	state.phaseTime += dt

	-- Checked in every phase: crossing the line mid-swing must still count.
	checkEnrage(model, state, root)

	-- The rock flies on the Tank's clock, in every phase, so a throw is not
	-- cancelled by the Tank moving on to something else.
	stepRock(model, state, dt)

	if state.phase == PHASE.Swing then
		stepSwing(model, brain, state, root, dt)
	elseif state.phase == PHASE.Tear then
		stepTear(model, brain, state, root, dt)
	elseif state.phase == PHASE.Direct then
		stepDirect(model, brain, state, root, now)
	else
		stepPursue(model, brain, state, root, dt, now)
	end
end

function Tank.onDeath(model: Model, brain: any, _ctx: any)
	local state = states[model]
	if state then
		-- A rock still in the air when the Tank dies goes with it: a detonation
		-- from a corpse's projectile reads as a bug even when it is fair.
		destroyRock(state)
		Support.resumeBrain(brain)
		states[model] = nil
	end

	local root = RigUtil.getRoot(model)
	if root then
		Support.playSound("TankRoar", root)
	end
end

return Tank
