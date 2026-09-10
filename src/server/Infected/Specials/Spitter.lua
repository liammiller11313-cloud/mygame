--!strict
--[[
	Spitter — the only infected that attacks the FLOOR.

	Everything else in this game threatens a body. The Spitter threatens a place,
	and that difference is the whole reason it exists: it is the answer to a team
	that has found a corner and stopped moving. Acid does not care how good your
	aim is. It cares that you are standing still.

	  * The pool is the weapon. The Spitter's own claw is an afterthought and its
	    health is the second lowest in the roster — it is meant to spit and be
	    punished for it, and the pool is what remains after it dies.
	  * It damages over TIME and it hurts more the longer you stand in it. A flat
	    tick teaches nothing; a ramp teaches "move", which is the lesson.
	  * It never blocks a corridor permanently. POOL_SECONDS is short enough that
	    waiting it out is a real option and long enough that waiting is a
	    decision with a cost, because the horde is still arriving.

	── AND IT KITES BETWEEN SPITS ──────────────────────────────────────────────
	The cooldown is thirteen seconds and the health is the second lowest in the
	roster, so for thirteen seconds this used to sprint at the nearest survivor
	like a Common and die there with nothing to attack with. It backs off while
	it is reloading now, and only while it is reloading — see KEEP_DISTANCE. The
	creature is still meant to be punished for spitting; it is not meant to
	delete itself between spits.

	── WHY THE POOL IS A PART AND NOT AN EFFECT ────────────────────────────────
	A survivor has to be able to SEE exactly where the acid is, from any angle,
	including through their own teammates. A client-side effect would be
	beautiful and would kill people unfairly. One flat, bright, server-owned part
	is the honest version, and it is the same part the damage test uses — so what
	you see is precisely what hurts.
]]

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Enums = require(Shared.Enums)
local InfectedConfig = require(Shared.Config.InfectedConfig)
local RaycastUtil = require(Shared.Util.RaycastUtil)
local Registry = require(Shared.Util.Registry)
local RigUtil = require(Shared.Util.RigUtil)
local Types = require(Shared.Types)

local Support = require(script.Parent.Support)

local DEFINITION = InfectedConfig.Definitions[Enums.Infected.Spitter]

local PHASE = table.freeze({
	Stalk = "Stalk",
	Spit = "Spit", -- rooted, rearing back, about to arc one out
	Recover = "Recover",
})

local SPIT_WINDUP = 0.6
local SPIT_RANGE = 90
local SPIT_MIN_RANGE = 14
local SPIT_CONE = math.rad(45)
local SPIT_COOLDOWN = 13
local MISS_RECOVERY = 1.4
local SCAN_INTERVAL = 0.25

--[[ The pool. Wide enough that stepping around it is a real detour, shallow
     enough that it is obviously a puddle rather than a wall. ]]
local POOL_RADIUS = 11
local POOL_SECONDS = 9
local POOL_HEIGHT = 0.25

--[[ Damage per second, at the start and at full ramp, and how long the ramp
     takes. Standing in it briefly is a mistake; standing in it is a death. ]]
local ACID_DPS_MIN = 6
local ACID_DPS_MAX = 22
local ACID_RAMP = 3.0
local ACID_TICK = 0.4

--[[ How far above and below the pool's own surface a body still counts as
     standing in it. Asymmetric on purpose — see the test in sweepPools. ]]
local ACID_BELOW = -1.5
local ACID_ABOVE = 6.5

--[[ How many pools may exist at once, across every Spitter on the server. Two
     Spitters and a corridor is a corridor nobody crosses, and that is a wipe
     rather than pressure. ]]
local MAX_POOLS = 4

--[[
	── KITING ──────────────────────────────────────────────────────────────────
	A Spitter's cooldown is thirteen seconds and its health is the second lowest
	in the roster. For those thirteen seconds it used to do exactly what a Common
	does: sprint at the nearest survivor and swing a claw worth four damage. It
	arrived inside shotgun range with nothing to attack with and died there, over
	and over, and the acid — the entire reason the creature exists — never got
	spat a second time.

	The header above already says what this thing is: it attacks the FLOOR, from
	range, and it is meant to be punished for spitting. Punished for SPITTING.
	Walking into the guns between spits is not that; it is the creature deleting
	itself before it can threaten anything.

	So while it is reloading it backs off, and only while it is reloading. The
	moment the acid is ready it closes again like anything else, which is when it
	is supposed to be shootable. KEEP_DISTANCE sits comfortably inside SPIT_RANGE
	(90) so the retreat never takes it out of its own reach — a Spitter that
	kited itself out of range would be worse than one that suicided.
]]
local KEEP_DISTANCE = 44
local RETREAT_STEP = 20
local RETREAT_INTERVAL = 0.2

--[[ Fallback headings when the way back is a wall, in degrees off straight
     away. A Spitter that only ever retreats directly backwards reverses into
     the first corner it finds and stands in it. Capped at 80 rather than fanned
     further: past ninety a "retreat" has a component pointing at the thing it
     is retreating from, which is not a retreat. ]]
local RETREAT_FANS = { 0, 45, -45, 80, -80 }

--[[ How far the ground under a retreat step may drop before it stops counting
     as a step. Backing off a roof is not a kite, and this creature spends its
     whole life walking backwards without looking. ]]
local RETREAT_MAX_DROP = 8

local POOL_COLOR = Color3.fromRGB(150, 190, 62)

type Pool = {
	part: BasePart,
	expiresAt: number,
	nextTick: number,
	standing: { [Player]: number }, -- how long each survivor has been in it
}

type State = {
	phase: string,
	phaseTime: number,
	nextSpitAt: number,
	scanClock: number,
	target: Player?,
	--[[ Whether the brain is currently stood down so this module can walk the
	     body backwards. Tracked rather than inferred so pauseBrain is called on
	     the transition and not every frame — it also issues a stop(), and a stop
	     every frame is a body that never goes anywhere. ]]
	retreating: boolean,
	retreatClock: number,
	--[[ The retreat's own cast, which is NOT the sightline cast the spit uses.
	     RaycastUtil.hasLineOfSight runs with RespectCanCollide false so that a
	     pane of glass blocks a spit, and it takes a plain ignore list — which
	     during a horde means every Common between here and the wall counts as
	     the wall, and the Spitter would decide it was cornered and never kite at
	     the exact moment kiting matters. This one respects CanCollide and
	     excludes the whole Infected folder, so only real geometry stops it. ]]
	probe: RaycastParams,
	probeFolder: Instance?,
	ignore: { Instance },
}

local states = (setmetatable({}, { __mode = "k" }) :: any) :: { [Model]: State }

--[[ Server-wide, not per Spitter. The cap is a property of the LEVEL — how much
     of it is currently on fire — and a per-creature cap would let three Spitters
     put down three times as much acid as the number that was tuned. ]]
local pools: { Pool } = {}

local function ensure(model: Model): State
	local state = states[model]
	if not state then
		local probe = RaycastParams.new()
		probe.FilterType = Enum.RaycastFilterType.Exclude
		probe.FilterDescendantsInstances = { model }
		probe.IgnoreWater = true
		probe.RespectCanCollide = true

		state = {
			phase = PHASE.Stalk,
			phaseTime = 0,
			nextSpitAt = 0,
			scanClock = 0,
			target = nil,
			retreating = false,
			retreatClock = 0,
			probe = probe,
			probeFolder = nil,
			ignore = { model },
		}
		states[model] = state
	end
	return state
end

local function setSpeed(model: Model, speed: number)
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.WalkSpeed = speed
	end
end

--[[ Lays a pool on the ground under a point. Returns nothing: a spit that finds
     no floor simply does not land, which is correct — acid arcing into a void
     should not pool in midair. ]]
local function placePool(origin: Vector3, attacker: Model)
	local ground, normal = RaycastUtil.groundAt(origin, 40, { attacker })
	if not ground or not normal then
		return
	end

	-- FIFO past the ceiling. The oldest pool goes, never the newest: the one a
	-- player is standing next to right now is the one that matters.
	while #pools >= MAX_POOLS do
		local oldest = table.remove(pools, 1)
		if oldest and oldest.part then
			oldest.part:Destroy()
		end
	end

	local part = Instance.new("Part")
	part.Name = "FL_AcidPool"
	part.Shape = Enum.PartType.Cylinder
	part.Size = Vector3.new(POOL_HEIGHT, POOL_RADIUS * 2, POOL_RADIUS * 2)
	--[[ Laid flat on the surface it found, so a pool on a ramp is on the ramp
	     rather than hovering over it at an angle nobody can read. ]]
	part.CFrame = CFrame.new(ground + normal * (POOL_HEIGHT * 0.5), ground + normal)
		* CFrame.Angles(0, 0, math.rad(90))
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Material = Enum.Material.Neon
	part.Color = POOL_COLOR
	part.Transparency = 0.35
	part.Parent = Workspace

	--[[ Debris as well as the sweep below. If this module ever stops ticking —
	     the service errors, the round ends mid-spit — a permanent acid puddle in
	     the middle of the map is far worse than one that vanishes early. ]]
	Debris:AddItem(part, POOL_SECONDS + 1)

	local now = os.clock()
	table.insert(pools, {
		part = part,
		expiresAt = now + POOL_SECONDS,
		nextTick = now + ACID_TICK,
		standing = {},
	})
end

--[[ One tick of every live pool. Called from onUpdate rather than from a loop of
     its own, and guarded so it runs once per frame no matter how many Spitters
     are alive — the pools are shared, so ticking them per creature would double
     the damage the moment a second Spitter spawned. ]]
local lastSweepAt = 0

local function sweepPools(now: number)
	if now <= lastSweepAt then
		return
	end
	lastSweepAt = now

	local survivors: any = Registry.find("SurvivorService")
	local damageService: any = Registry.find("DamageService")
	local alive = if survivors and typeof(survivors.getAliveSurvivors) == "function"
		then survivors:getAliveSurvivors()
		else {}

	for index = #pools, 1, -1 do
		local pool = pools[index]
		if not pool.part.Parent or now >= pool.expiresAt then
			table.remove(pools, index)
			pool.part:Destroy()
			continue
		end
		if now < pool.nextTick then
			continue
		end
		pool.nextTick = now + ACID_TICK

		local centre = pool.part.Position
		local inside: { [Player]: boolean } = {}

		for _, player in alive do
			local character, root = Support.rootOf(player)
			if not character or not root then
				continue
			end
			--[[
				Flat distance, and only from ABOVE.

				A survivor on a catwalk over a pool is not standing in it, and
				neither is one in the room below it. The old test was a symmetric
				six studs, which is more than a floor is thick — so acid on the
				ground floor burned anyone directly above it through the boards,
				and that is damage arriving from nothing the player can see.

				The band is the height of a body standing on the surface: a little
				below to allow for a pool on a slope, and one body's worth above.
			]]
			local delta = root.Position - centre
			if delta.Y < ACID_BELOW or delta.Y > ACID_ABOVE then
				continue
			end
			if Vector3.new(delta.X, 0, delta.Z).Magnitude > POOL_RADIUS then
				continue
			end

			inside[player] = true
			local held = (pool.standing[player] or 0) + ACID_TICK
			pool.standing[player] = held

			--[[ The ramp. A flat tick teaches nothing; this teaches "move", which
			     is the entire point of the creature. ]]
			local ramp = math.clamp(held / ACID_RAMP, 0, 1)
			local dps = ACID_DPS_MIN + (ACID_DPS_MAX - ACID_DPS_MIN) * ramp

			if damageService then
				damageService:applyDamage(
					character,
					dps * ACID_TICK,
					Types.newDamageContext({
						damageType = Enums.DamageType.Special,
						region = Enums.HitRegion.Torso,
						hitPosition = root.Position,
						hitNormal = Vector3.yAxis,
						--[[ The pool, not the survivor standing in it. Without
						     this the source resolves to the victim's own
						     position — there is no attacker on an acid tick —
						     and an arrow pointing at where you already are draws
						     dead ahead, telling a player the threat is in front
						     of them while they burn. ]]
						sourcePosition = centre,
						direction = -Vector3.yAxis,
						distance = 0,
					})
				)
			end
		end

		-- Stepping out resets the ramp. Hopping through a pool should cost the
		-- first tick and nothing more.
		for player in pool.standing do
			if not inside[player] then
				pool.standing[player] = nil
			end
		end
	end
end

--[[ The nearest survivor and how far away they are, or nil. The retreat only
     ever cares about the closest one: backing away from the average of a team
     is how you back into the middle of it. ]]
local function nearestSurvivor(origin: Vector3): (Player?, number)
	local survivors: any = Registry.find("SurvivorService")
	if not survivors or typeof(survivors.getAliveSurvivors) ~= "function" then
		return nil, math.huge
	end
	local best: Player? = nil
	local bestDistance = math.huge
	for _, player in survivors:getAliveSurvivors() do
		local _, victimRoot = Support.rootOf(player)
		if victimRoot then
			local distance = (victimRoot.Position - origin).Magnitude
			if distance < bestDistance then
				bestDistance = distance
				best = player
			end
		end
	end
	return best, bestDistance
end

--[[ Hands the body back to the brain. Idempotent, and called from every path
     that stops retreating — including death and stagger — because a Spitter left
     paused is a Spitter standing still in a fight forever. ]]
local function endRetreat(model: Model, brain: any, state: State)
	if not state.retreating then
		return
	end
	state.retreating = false
	setSpeed(model, DEFINITION.walkSpeed)
	Support.resumeBrain(brain)
end

--[[ One step of backing off, throttled. Returns nothing: whether it retreated
     or gave up, the caller's next action is the same. ]]
local function stepRetreat(model: Model, brain: any, state: State, root: BasePart, dt: number)
	state.retreatClock -= dt
	if state.retreatClock > 0 then
		return
	end
	state.retreatClock = RETREAT_INTERVAL

	local threat, distance = nearestSurvivor(root.Position)
	local _, threatRoot = Support.rootOf(threat)
	if not threatRoot or distance >= KEEP_DISTANCE then
		endRetreat(model, brain, state)
		return
	end

	local away =
		Vector3.new(root.Position.X - threatRoot.Position.X, 0, root.Position.Z - threatRoot.Position.Z)
	if away.Magnitude < 0.05 then
		endRetreat(model, brain, state)
		return
	end
	away = away.Unit

	--[[ The whole Infected folder, refreshed only when the body is re-parented,
	     which happens once. Other zombies are not walls: a Spitter that treats
	     the horde it arrived with as geometry is a Spitter that never backs up. ]]
	local folder = model.Parent
	if folder and state.probeFolder ~= folder then
		state.probeFolder = folder
		state.probe.FilterDescendantsInstances = { folder }
	end

	--[[ Straight back first, then fanned to either side, cast at the body's own
	     height so a Spitter does not walk into the wall it is standing against. ]]
	local destination: Vector3? = nil
	for _, degrees in RETREAT_FANS do
		local heading = if degrees == 0
			then away
			else (CFrame.fromAxisAngle(Vector3.yAxis, math.rad(degrees)) * away).Unit
		local candidate = root.Position + heading * RETREAT_STEP
		if Workspace:Raycast(root.Position, candidate - root.Position, state.probe) then
			continue
		end
		--[[ And there has to be a floor at the far end. A clear horizontal ray is
		     exactly what a ledge looks like. ]]
		local floor = Workspace:Raycast(candidate, Vector3.new(0, -RETREAT_MAX_DROP, 0), state.probe)
		if floor then
			destination = candidate
			break
		end
	end

	--[[ Cornered. Stand and fight rather than grind into geometry: a body wedged
	     against a wall reads as broken, and being caught out of position is a
	     fair thing to happen to a Spitter that spat from the wrong place. ]]
	if not destination then
		endRetreat(model, brain, state)
		return
	end

	if not state.retreating then
		state.retreating = true
		Support.pauseBrain(brain)
		setSpeed(model, DEFINITION.runSpeed)
	end
	if brain and typeof(brain.moveTo) == "function" then
		brain:moveTo(destination)
	end
end

local function pickTarget(model: Model, root: BasePart): Player?
	local survivors: any = Registry.find("SurvivorService")
	if not survivors or typeof(survivors.getAliveSurvivors) ~= "function" then
		return nil
	end

	local facing = root.CFrame.LookVector
	local best: Player? = nil
	local bestDistance = math.huge

	for _, player in survivors:getAliveSurvivors() do
		local character, victimRoot = Support.rootOf(player)
		if not character or not victimRoot then
			continue
		end
		local delta = victimRoot.Position - root.Position
		local distance = delta.Magnitude
		if distance < SPIT_MIN_RANGE or distance > SPIT_RANGE or distance >= bestDistance then
			continue
		end
		if facing:Dot(delta.Unit) < math.cos(SPIT_CONE) then
			continue
		end
		if not RaycastUtil.hasLineOfSight(root.Position, victimRoot.Position, { model, character }) then
			continue
		end
		best = player
		bestDistance = distance
	end
	return best
end

local Spitter = {}

function Spitter.onSpawn(model: Model, brain: any)
	local state = ensure(model)
	state.ignore[1] = model
	state.nextSpitAt = os.clock() + SPIT_COOLDOWN * 0.4
	Support.resumeBrain(brain)
end

--[[
	The pools, ticked whether or not a Spitter is alive to tick them.

	This used to run at the top of onUpdate, ahead of that function's own
	`isAlive` return, with a comment explaining that pools outlive the Spitter
	that made them. The comment was right about the intent and wrong about the
	mechanism: InfectedService skips every record marked dead, so onUpdate is not
	called for a dead Spitter, so the pools of the last one to die simply stopped
	burning people. They kept their glow — the Debris backstop in placePool still
	took the part away on time — which makes the symptom worse than litter would
	have been: a hazard that looks exactly as dangerous as it did a second
	earlier, and is not.

	`onWorldStep` is called once a frame per special KIND, alive or not, which is
	the shape this always needed. The once-per-frame guard inside sweepPools is
	kept: it is now guaranteed by the caller rather than by luck, and a guarantee
	somebody can read at both ends is worth two lines.
]]
function Spitter.onWorldStep(now: number)
	sweepPools(now)
end

function Spitter.onUpdate(model: Model, brain: any, dt: number)
	local now = os.clock()
	local root = RigUtil.getRoot(model)
	if not root or not RigUtil.isAlive(model) then
		return
	end
	local state = ensure(model)

	if state.phase == PHASE.Spit then
		if Support.isStaggered(brain) then
			state.phase = PHASE.Recover
			state.phaseTime = 0
			setSpeed(model, DEFINITION.walkSpeed)
			Support.resumeBrain(brain)
			state.nextSpitAt = now + SPIT_COOLDOWN
			return
		end

		state.phaseTime += dt
		local target = state.target
		local _, victimRoot = Support.rootOf(target)
		if victimRoot then
			Support.faceTowards(brain, root, victimRoot.Position, dt)
		end

		if state.phaseTime >= SPIT_WINDUP then
			--[[ Aimed where they ARE at the moment it lands, not where they were
			     when it started. Walking out of the wind-up is the dodge, and a
			     spit that used the old position would make that dodge free. ]]
			local landed = if victimRoot then victimRoot.Position else nil
			if landed then
				Support.playSound("SpitterSpit", root)
				placePool(landed, model)
			end
			state.phase = PHASE.Recover
			state.phaseTime = 0
			state.target = nil
			state.nextSpitAt = now + SPIT_COOLDOWN
			setSpeed(model, DEFINITION.walkSpeed)
			Support.resumeBrain(brain)
		end
		return
	end

	if state.phase == PHASE.Recover then
		state.phaseTime += dt
		if state.phaseTime >= MISS_RECOVERY then
			state.phase = PHASE.Stalk
			state.phaseTime = 0
		end
		return
	end

	--[[ A shove owns the body outright: it must not be walked anywhere by this
	     module while it is reeling, and the brain has to have it back by the
	     time the stagger ends. ]]
	if Support.isStaggered(brain) then
		endRetreat(model, brain, state)
		return
	end

	--[[ Reloading. This is the whole kite: back off while there is no acid to
	     throw, and only while there is none. See KEEP_DISTANCE. ]]
	if now < state.nextSpitAt then
		stepRetreat(model, brain, state, root, dt)
		return
	end

	-- Loaded again, so the body goes back to the brain and closes like anything
	-- else. This is the window in which a Spitter is supposed to be shootable.
	endRetreat(model, brain, state)

	state.scanClock += dt
	if state.scanClock < SCAN_INTERVAL then
		return
	end
	state.scanClock = 0

	local target = pickTarget(model, root)
	if target then
		state.phase = PHASE.Spit
		state.phaseTime = 0
		state.target = target
		Support.pauseBrain(brain)
		setSpeed(model, 0)
		Support.playSound("SpitterIdle", root)
	end
end

function Spitter.onDeath(model: Model, brain: any, _ctx: any)
	--[[ Its pools are NOT cleaned up. Acid on the floor outliving the thing that
	     spat it is the point — killing a Spitter does not un-poison the ground,
	     and a team that shoots one at their own feet has still lost that corner
	     for nine seconds. ]]
	local state = states[model]
	if state then
		state.retreating = false
	end
	Support.resumeBrain(brain)
	states[model] = nil
end

return Spitter
