--!strict
--[[
	Charger — winds up, commits, and cannot change its mind.

	The charge is a contract with the player: you get a bellow and a visible
	wind-up, the Charger turns at 95 degrees a second while it winds up and NOT AT
	ALL once it launches, and from that moment it is a 44 stud/second object
	travelling in a straight line. Dodging it is one of the best things a survivor
	does in this game, and every rule below exists to protect that moment.

	  * The tell comes first. ChargerCharge plays at the START of the wind-up, not
	    at the launch — a warning that arrives with the attack is not a warning.
	  * The heading is sampled once, at launch, and then frozen. There is no
	    mid-charge correction anywhere in this file. A Charger that homes is a
	    Charger nobody can dodge, and it would quietly delete the whole mechanic.
	  * A miss is punished. The charge overshoots to the end of its lane and the
	    Charger then stands there, stopped and doing nothing, for MISS_RECOVERY.
	    That window is the reward for reading the tell.

	The first survivor in the lane is carried; everyone else is thrown clear
	rather than collected, because a charge that pins the whole team is a wipe
	rather than a threat. The carry ends against the first wall, which is where
	the damage actually is: the slam, and then a pummel on attack.cooldown until
	somebody answers it.

	The pin runs through SurvivorService like every other pin, so a teammate's
	shove frees the victim and staggers the Charger — stumbleResistance 0.7 makes
	that stagger short, which is the Charger's compensation for being so easy to
	sidestep. This module polls the pin's owner every tick and lets go the instant
	it stops being the owner: the counter never depends on the Charger agreeing.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Enums = require(Shared.Enums)
local InfectedConfig = require(Shared.Config.InfectedConfig)
local RaycastUtil = require(Shared.Util.RaycastUtil)
local Registry = require(Shared.Util.Registry)
local Remotes = require(Shared.Net.Remotes)
local RigUtil = require(Shared.Util.RigUtil)

local Support = require(script.Parent.Support)

local DEFINITION = InfectedConfig.Definitions[Enums.Infected.Charger]
local ATTACK = DEFINITION.attack

local PHASE = table.freeze({
	Stalk = "Stalk", -- the brain drives; we only look for a lane
	WindUp = "WindUp", -- rooted, bellowing, turning at a clumsy 95 deg/s
	Charge = "Charge", -- committed, straight, no steering of any kind
	Pummel = "Pummel", -- a victim is on the floor and being hit on cooldown
	Recover = "Recover", -- stopped and vulnerable, whether it hit or missed
})

-- The tell. Long enough to hear, turn, and step out of the lane; it is the
-- single most important number in the file. attack.windup (0.3) is the pummel's
-- tell and is far too short to dodge a charge from.
local WINDUP_TIME = 0.85

-- Range band. Inside the minimum there is no lane to run and the brain's ordinary
-- swing is the right attack; past the maximum the charge expires before it
-- arrives and the team gets a free 450-health target walking in a straight line.
local CHARGE_MIN_RANGE = 24
local CHARGE_MAX_RANGE = 130

-- The lane. Time and distance both cap it, so a charge into open ground ends on
-- the clock and a charge downhill ends on the odometer.
local CHARGE_MAX_TIME = 3.0
local CHARGE_MAX_DISTANCE = 120
local CHARGE_LOOKAHEAD = 40 -- how far ahead the move order is re-issued

--[[ The lane, for scoring a charge before committing to one. Half-width is the
     body plus a little, because a survivor clipped at the edge is still thrown;
     the overrun is there because the charge does not stop at the target and
     anybody standing just behind them is in it too. LANE_BONUS is how much each
     extra body discounts the distance — 0.35 makes a two-body lane worth about a
     third further to walk to, which is a preference rather than an obsession. ]]
local LANE_HALF_WIDTH = 7
local LANE_OVERRUN = 30
local LANE_BONUS = 0.35
-- attack.range is the reach of the arm doing the collecting, which is exactly
-- what the lane is: anybody inside it is hit, anybody outside it watched it pass.
local LANE_RADIUS = ATTACK.range

-- Everyone who is not the first survivor hit gets thrown out of the way. Lower
-- than the Tank's swing on purpose — this is a body-check in passing, not the
-- game's biggest melee attack.
local KNOCK_SPEED = 46
local KNOCK_LIFT = 22
-- The server has to own a victim's physics for a throw or a carry to survive
-- their own simulation. Kept as short as it can be: a character that stays
-- server-simulated feels laggy to play.
local OWNERSHIP_RESTORE_TIME = 0.8

-- Where a carried survivor rides: off the ground, in front, in the way. -Z is
-- forward in object space, so this is the arm's length ahead of the chest.
local CARRY_OFFSET = CFrame.new(0, 0.6, -3.4)

-- The slam is where a charge's damage actually is. Twice attack.damage — the
-- carry itself deals nothing, so this is the whole cost of being collected, and
-- it is survivable from full health on purpose.
local SLAM_MULTIPLIER = 2.0

-- Wall detection. The forward probe covers the ground about to be crossed plus a
-- margin, and the stall check catches the walls a ray slides along instead of
-- hitting: a Charger grinding a corner has stopped charging either way.
local WALL_PROBE_MARGIN = 3.5
local STALL_SPEED = DEFINITION.runSpeed * 0.35
local STALL_TIME = 0.35
-- A Humanoid does not reach 44 studs a second on the frame it is told to. The
-- stall check is blind for this long after the launch, or every charge would
-- diagnose its own acceleration as a wall.
local CHARGE_SPINUP = 0.4

local MISS_RECOVERY = 2.0 -- the punish window; the reward for dodging
local SLAM_RECOVERY = 0.7 -- after a pummel ends, before it is a threat again
local CHARGE_COOLDOWN = 7.0 -- between charges, so a lane is not a treadmill
local SPAWN_SETTLE = 1.2 -- never charge out of the spawn frame

local SCAN_INTERVAL = 0.3 -- target re-selection; never per frame
local BELLOW_INTERVAL = 5.0 -- the approach vocalisation, on its own clock
--[[ And the same clock, faster, while it is pummelling somebody into the floor.
     A pinned survivor cannot free themselves — that is the whole design — so the
     bellow is not flavour, it is the only thing that tells a teammate which way
     to run, and it has to keep saying so until the pummel stops. ]]
local PUMMEL_BELLOW_INTERVAL = 1.5

local IMPACT_CAMERA_IMPULSE = table.freeze({
	position = Vector3.new(0, -0.5, 1.4),
	rotation = Vector3.new(-14, 6, 0),
	decay = 4,
})

local SLAM_CAMERA_IMPULSE = table.freeze({
	position = Vector3.new(0, -1.1, 0.6),
	rotation = Vector3.new(-22, 0, 0),
	decay = 3,
})

type State = {
	phase: string,
	phaseTime: number,
	readyAt: number,
	nextScan: number,
	nextBellow: number,
	nextPummel: number,
	target: Player?,
	victim: Player?,
	carrying: boolean,
	owned: BasePart?, -- the root whose ownership we took, so we always give it back
	carried: Model?, -- the character whose collisions and pose we changed
	heading: Vector3, -- frozen at launch; never rewritten mid-charge
	launchFrom: Vector3,
	stallTime: number,
	recoverFor: number,
	hit: { [Player]: boolean }, -- who this charge has already thrown aside
	ignore: { Instance },
	probe: RaycastParams,
}

-- Weak keys: a Charger despawned rather than killed never reaches onDeath, and a
-- strong table here would hold its model alive forever.
local states = (setmetatable({}, { __mode = "k" }) :: any) :: { [Model]: State }

local function ensure(model: Model): State
	local state = states[model]
	if not state then
		-- The ignore list and its RaycastParams are built once per Charger and
		-- then reused for every cast it ever makes: the wall probe runs every
		-- frame of every charge, and a params object per frame is exactly the
		-- allocation the horde cannot afford.
		local ignore: { Instance } = { model }
		state = {
			phase = PHASE.Stalk,
			phaseTime = 0,
			readyAt = os.clock() + SPAWN_SETTLE,
			nextScan = 0,
			nextBellow = 0,
			nextPummel = 0,
			target = nil,
			victim = nil,
			carrying = false,
			owned = nil,
			carried = nil,
			heading = Vector3.zAxis,
			launchFrom = Vector3.zero,
			stallTime = 0,
			recoverFor = MISS_RECOVERY,
			hit = {},
			ignore = ignore,
			probe = RaycastUtil.excluding(ignore),
		}
		states[model] = state
	end
	return state
end

-- FilterDescendantsInstances copies the array it is given, so the params have to
-- be re-pointed at the ignore list whenever its contents change.
local function refreshProbe(state: State)
	state.probe.FilterDescendantsInstances = state.ignore
end

local function isCarriable(survivors: any, player: Player): boolean
	local state = survivors:getState(player)
	return state == Enums.SurvivorState.Healthy or state == Enums.SurvivorState.Hurt
end

-- ─── ownership ───────────────────────────────────────────────────────────────

--[[ Takes a survivor's physics off their own machine. Nothing the server does to
     a character's velocity or CFrame survives otherwise, so both the throw and
     the carry need this — and both of them have to give it back. ]]
local function takeOwnership(state: State, root: BasePart)
	state.owned = root
	pcall(function()
		root:SetNetworkOwner(nil)
	end)
end

local function returnOwnership(root: BasePart?)
	if not root or not root.Parent then
		return
	end
	pcall(function()
		root:SetNetworkOwnershipAuto()
	end)
end

local function releaseOwnership(state: State)
	local owned = state.owned
	state.owned = nil
	returnOwnership(owned)
end

--[[
	Picks a survivor up.

	Two things besides ownership have to change or the carry fights itself. The
	victim goes into the Debris collision group, which collides with the level and
	with nothing else, because a body held one arm's length in front of a charging
	Charger is otherwise a body the Charger is walking into — it would brake against
	its own victim and the stall check would read that as a wall. And PlatformStand
	stands their Humanoid down, so its balance controller stops arguing with a
	CFrame that moves 44 studs a second.

	Both are undone in endCarry, which every release path runs through.
]]
local function beginCarry(state: State, character: Model, victimRoot: BasePart)
	state.carrying = true
	state.carried = character
	takeOwnership(state, victimRoot)

	pcall(RigUtil.setCollisionGroup, character, "Debris")

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.PlatformStand = true
	end
end

local function endCarry(state: State)
	local character = state.carried
	state.carried = nil
	state.carrying = false
	releaseOwnership(state)

	if not character or not character.Parent then
		return
	end

	pcall(RigUtil.setCollisionGroup, character, "Survivor")

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.PlatformStand = false
	end
end

--[[ Throws a survivor clear of the lane. Same shape as the Tank's swing: take
     ownership, set the velocity, hand ownership back a beat later. ]]
local function knockAside(state: State, root: BasePart, velocity: Vector3)
	if state.owned == root then
		return -- the carried victim is not also thrown
	end
	pcall(function()
		root:SetNetworkOwner(nil)
	end)
	root.AssemblyLinearVelocity = velocity
	task.delay(OWNERSHIP_RESTORE_TIME, function()
		returnOwnership(root)
	end)
end

-- ─── phase transitions ───────────────────────────────────────────────────────

--[[ Hands the body back to the brain. Every exit from a scripted phase goes
     through here so there is exactly one place that can forget to resume. ]]
local function backToStalk(model: Model, brain: any, state: State, delay: number, keepSpeed: boolean?)
	state.phase = PHASE.Stalk
	state.phaseTime = 0
	state.stallTime = 0
	state.carrying = false
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

--[[ Drops whoever is being held or pummelled and unwinds everything that was
     done to them: the pin, the ignore-list entry, and above all the network
     ownership, which would leave a survivor permanently server-simulated if it
     ever leaked. ]]
local function releaseVictim(model: Model, state: State)
	endCarry(state)

	local victim = state.victim
	if victim then
		local survivors: any = Registry.find("SurvivorService")
		if survivors and Support.stillPinnedBy(survivors, victim, model) then
			survivors:setPinned(victim, nil)
		end
	end

	state.victim = nil
	state.carrying = false
	if state.ignore[2] ~= nil then
		state.ignore[2] = nil
		refreshProbe(state)
	end
end

--[[ Stopped, empty-handed and doing nothing for `delay`. Both endings use it:
     the overshoot after a miss, and the beat after a pummel ends. Standing still
     with 450 health in the open IS the vulnerability — there is no damage
     multiplier anywhere in the game and there should not be one here. ]]
local function beginRecover(model: Model, brain: any, state: State, delay: number)
	releaseVictim(model, state)

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.WalkSpeed = 0
	end
	if brain and typeof(brain.stop) == "function" then
		brain:stop()
	end

	state.phase = PHASE.Recover
	state.phaseTime = 0
	state.stallTime = 0
	state.recoverFor = delay
	state.readyAt = os.clock() + delay + CHARGE_COOLDOWN
end

-- ─── target selection ────────────────────────────────────────────────────────

--[[
	How many survivors this lane would actually go through.

	The charge carries the FIRST body it touches and throws every other one
	clear, and the throw is half the value: a team that has been scattered has
	stopped shooting whatever else is in the room. So a lane is worth more the
	more of them are standing in it, and this counts them the way the charge will
	find them — projected onto the heading, inside the width of the body, and out
	past the target, because the charge does not stop where the target is.

	Cheap on purpose. It runs once per candidate on a quarter-second scan with at
	most four survivors on the server, so it is a dozen dot products.
]]
local function laneCount(candidates: { Player }, origin: Vector3, target: Vector3): number
	local flat = Vector3.new(target.X - origin.X, 0, target.Z - origin.Z)
	local length = flat.Magnitude
	if length < 0.05 then
		return 1
	end
	local heading = flat.Unit
	local reach = length + LANE_OVERRUN

	local count = 0
	for _, player in candidates do
		local _, victimRoot = Support.rootOf(player)
		if not victimRoot then
			continue
		end
		local delta = Vector3.new(victimRoot.Position.X - origin.X, 0, victimRoot.Position.Z - origin.Z)
		local along = delta:Dot(heading)
		if along < 0 or along > reach then
			continue
		end
		if (delta - heading * along).Magnitude <= LANE_HALF_WIDTH then
			count += 1
		end
	end
	return count
end

--[[
	Who to charge, which is a question about the LANE and not about the person.

	It used to be whoever was nearest, which is the one read that ignores what a
	charge does. A Charger that picks the closest survivor picks the one standing
	at the front of the group and takes a lane that leaves the other three
	untouched behind it; a Charger that picks a lane THROUGH the group carries
	one of them and throws the rest across the room, which is the same charge
	worth three times as much.

	So distance still decides — a charge has a minimum range and a wind-up, and
	crossing a map to reach a marginally better lane is a charge that never
	happens — but each extra body the lane clips discounts it, and somebody
	another special has already committed to costs extra. See Support.claimBias.
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

		-- Somebody already down is not worth a charge: they cannot be collected,
		-- and the lane would be spent scattering the people reviving them.
		if not isCarriable(survivors, player) then
			continue
		end
		if distance > DEFINITION.sightRange then
			continue
		end

		local extra = laneCount(candidates, origin, victimRoot.Position) - 1
		local score = distance
			/ (1 + LANE_BONUS * math.max(extra, 0))
			* Support.claimBias(model, player)
			-- And a survivor who cannot see the lane. See Support.blindBias.
			* Support.blindBias(survivors, player)
		if score < bestScore then
			bestScore = score
			best = player
		end
	end

	return best, nearest
end

-- ─── the charge ──────────────────────────────────────────────────────────────

local function beginWindUp(
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
		-- Rooted for the whole tell. A Charger that keeps closing while it winds
		-- up is a Charger that arrives before the warning has finished playing.
		humanoid.WalkSpeed = 0
	end

	Support.faceTowards(brain, root, targetRoot.Position, dt)
	-- The dodge cue. Priority 8 and a 400-stud rolloff in AudioConfig: this is
	-- meant to cut through a firefight two rooms away.
	Support.playSound("ChargerCharge", root)

	state.phase = PHASE.WindUp
	state.phaseTime = 0
end

local function launch(model: Model, brain: any, state: State, root: BasePart)
	-- The heading is taken HERE and never again. Everything about the dodge
	-- depends on this line being the last decision the Charger makes.
	local facing = root.CFrame.LookVector
	local flat = Vector3.new(facing.X, 0, facing.Z)
	state.heading = if flat.Magnitude > 0.05 then flat.Unit else Vector3.zAxis
	state.launchFrom = root.Position
	state.stallTime = 0
	state.carrying = false
	table.clear(state.hit)

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.WalkSpeed = DEFINITION.runSpeed
		-- faceTowards turned AutoRotate off for the wind-up; the charge wants the
		-- body pointed down its own lane, which is where it is walking anyway.
		humanoid.AutoRotate = true
	end

	state.phase = PHASE.Charge
	state.phaseTime = 0
end

--[[ Collects the first upright survivor in the lane and throws the rest clear.
     "First" is per charge, not per frame: state.hit remembers who has already
     been dealt with so nobody is body-checked twice by one pass. ]]
local function sweepLane(model: Model, state: State, root: BasePart)
	local survivors: any = Registry.find("SurvivorService")
	if not survivors then
		return
	end

	local origin = root.Position
	for _, player in survivors:getAliveSurvivors() do
		if state.hit[player] or player == state.victim then
			continue
		end

		local character, victimRoot = Support.rootOf(player)
		if not character or not victimRoot then
			continue
		end

		local delta = victimRoot.Position - origin
		if Vector3.new(delta.X, 0, delta.Z).Magnitude > LANE_RADIUS then
			continue
		end

		state.hit[player] = true

		-- The first one is carried, if they are in a state that can be pinned.
		-- setPinned refusing is not a failure: it means they were already down,
		-- and a pin on somebody who is already crawling has no answer.
		if not state.carrying and isCarriable(survivors, player) then
			if survivors:setPinned(player, model, Enums.Infected.Charger) == true then
				state.victim = player
				-- The wall probe must not stop on the body it is carrying.
				state.ignore[2] = character
				refreshProbe(state)
				beginCarry(state, character, victimRoot)
				Remotes.Event.CameraImpulse:FireClient(player, IMPACT_CAMERA_IMPULSE)
				continue
			end
		end

		-- Everybody else is knocked out of the lane rather than collected: a
		-- charge that pinned the whole team would be a wipe, not a threat. The
		-- push is the part of their offset that is ACROSS the lane, so they end
		-- up beside the charge rather than punted along it — somebody directly in
		-- front, with no lateral offset to use, goes over whichever shoulder the
		-- lane's perpendicular points at.
		Support.damage(model, character, victimRoot, origin, Support.scaledDamage(model, ATTACK.damage))
		local flatDelta = Vector3.new(delta.X, 0, delta.Z)
		local lateral = flatDelta - state.heading * flatDelta:Dot(state.heading)
		local push = if lateral.Magnitude > 0.5 then lateral.Unit else state.heading:Cross(Vector3.yAxis).Unit
		knockAside(state, victimRoot, push * KNOCK_SPEED + Vector3.new(0, KNOCK_LIFT, 0))
		Remotes.Event.CameraImpulse:FireClient(player, IMPACT_CAMERA_IMPULSE)
	end
end

--[[ True when the ground about to be crossed ends in a wall. Other bodies are
     not walls: charging through the horde is normal, and a Common in the way must
     never end a charge that was aimed past it. ]]
local function hitWall(state: State, root: BasePart, travel: number): boolean
	local distance = math.max(travel, 0) + WALL_PROBE_MARGIN
	local result = Workspace:Raycast(root.Position, state.heading * distance, state.probe)
	if not result then
		return false
	end
	local character = RigUtil.getCharacterFromPart(result.Instance)
	return character == nil
end

--[[ The end of a carry: the victim goes into the wall and then onto the floor,
     and the Charger settles in to pummel. This is where a collected survivor
     actually loses health, so it is loud, it is a camera event, and it is
     survivable from full. ]]
local function slam(model: Model, brain: any, state: State, root: BasePart)
	local victim = state.victim
	local character, victimRoot = Support.rootOf(victim)
	if not victim or not character or not victimRoot then
		state.carrying = false
		return
	end

	-- The charge is over: drop the move order and the speed with it, or the
	-- Humanoid keeps walking its old lane and drags the pummel down the corridor.
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.WalkSpeed = 0
	end
	if brain and typeof(brain.stop) == "function" then
		brain:stop()
	end

	-- Put them on the ground at the Charger's feet before ownership goes back, so
	-- the position their own client wakes up with is the one the server chose.
	local landing = root.CFrame * CFrame.new(0, -1.0, -3.0)
	victimRoot.CFrame = CFrame.new(landing.Position)
	victimRoot.AssemblyLinearVelocity = Vector3.zero
	-- The carry is over the moment they touch the floor: they stand back up into
	-- their own collisions and their own physics, and the pin is what holds them
	-- there for the pummel.
	endCarry(state)

	Support.damage(
		model,
		character,
		victimRoot,
		root.Position,
		Support.scaledDamage(model, ATTACK.damage) * SLAM_MULTIPLIER
	)
	Remotes.Event.CameraImpulse:FireClient(victim, SLAM_CAMERA_IMPULSE)
	Support.playSound("ChargerCharge", root)

	state.carrying = false
	state.phase = PHASE.Pummel
	state.phaseTime = 0
	local now = os.clock()
	state.nextPummel = now + ATTACK.cooldown
	-- The slam counts as the first one; reusing the approach clock keeps one
	-- Charger to one voice, since it can never be stalking and pummelling at once.
	state.nextBellow = now + PUMMEL_BELLOW_INTERVAL
end

-- ─── phases ──────────────────────────────────────────────────────────────────

local function stepStalk(model: Model, brain: any, state: State, root: BasePart, dt: number, now: number)
	if now >= state.nextScan then
		state.nextScan = now + SCAN_INTERVAL
		local chargeable, nearest = pickTarget(model, root)
		state.target = chargeable
		local chase = chargeable or nearest
		Support.setBrainTarget(brain, if chase then chase.Character else nil)
		-- Renewed while this Charger is still going for them. See Support.claim.
		Support.claim(model, chargeable)
	end

	local target = state.target
	local _, targetRoot = Support.rootOf(target)
	if not target or not targetRoot then
		return
	end

	local distance = (targetRoot.Position - root.Position).Magnitude
	if now >= state.nextBellow and distance <= DEFINITION.sightRange then
		state.nextBellow = now + BELLOW_INTERVAL
		Support.playSound("ChargerIdle", root)
	end

	if now < state.readyAt then
		return
	end
	if distance < CHARGE_MIN_RANGE or distance > CHARGE_MAX_RANGE then
		return
	end

	local character = target.Character
	if not character then
		return
	end

	-- A charge into a wall is a wasted charge, so it needs a real sightline to
	-- the target before it commits to one.
	state.ignore[2] = character
	local visible = RaycastUtil.hasLineOfSight(root.Position, targetRoot.Position, state.ignore)
	state.ignore[2] = nil
	if not visible then
		return
	end

	beginWindUp(model, brain, state, root, targetRoot, dt)
end

local function stepWindUp(model: Model, brain: any, state: State, root: BasePart, dt: number)
	local _, targetRoot = Support.rootOf(state.target)
	if not targetRoot then
		backToStalk(model, brain, state, 0.5)
		return
	end

	-- The only tracking a charge ever gets, and it is deliberately bad. A player
	-- who strafes during the wind-up is aimed at where they used to be, which is
	-- exactly the dodge the 95 deg/s turnSpeed exists to sell.
	Support.faceTowards(brain, root, targetRoot.Position, dt)

	if state.phaseTime >= WINDUP_TIME then
		launch(model, brain, state, root)
	end
end

local function stepCharge(model: Model, brain: any, state: State, root: BasePart, dt: number)
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.WalkSpeed ~= DEFINITION.runSpeed then
		humanoid.WalkSpeed = DEFINITION.runSpeed
	end

	-- brain:moveTo is the sanctioned way to drive a paused body: it throttles the
	-- MoveTo re-issue and clears any path the brain had cached. The destination
	-- is always straight down the frozen heading, so this cannot steer.
	local ahead = root.Position + state.heading * CHARGE_LOOKAHEAD
	if brain and typeof(brain.moveTo) == "function" then
		brain:moveTo(ahead)
	elseif humanoid then
		humanoid:Move(state.heading, false)
	end

	sweepLane(model, state, root)

	if state.carrying then
		local victim = state.victim
		local survivors: any = Registry.find("SurvivorService")
		local _, victimRoot = Support.rootOf(victim)
		if
			not victim
			or not victimRoot
			or not survivors
			or not Support.stillPinnedBy(survivors, victim, model)
		then
			-- Shoved out of its arms mid-charge. The charge itself continues:
			-- the Charger has committed, and that is the whole point of it.
			releaseVictim(model, state)
		else
			victimRoot.CFrame = root.CFrame * CARRY_OFFSET
			victimRoot.AssemblyLinearVelocity = Vector3.zero
		end
	end

	local velocity = root.AssemblyLinearVelocity
	local planar = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
	if planar < STALL_SPEED and state.phaseTime >= CHARGE_SPINUP then
		state.stallTime += dt
	else
		state.stallTime = 0
	end

	local travelled = (root.Position - state.launchFrom).Magnitude
	local blocked = state.stallTime >= STALL_TIME or hitWall(state, root, planar * dt)
	local spent = state.phaseTime >= CHARGE_MAX_TIME or travelled >= CHARGE_MAX_DISTANCE

	if not blocked and not spent then
		return
	end

	if state.carrying then
		-- Anything that ends the charge with somebody in its arms is a slam,
		-- including running out of lane: they get put down hard either way.
		slam(model, brain, state, root)
		return
	end

	-- Nothing collected. It overshoots to a stop and stands there, which is the
	-- entire reward for having dodged it.
	beginRecover(model, brain, state, MISS_RECOVERY)
end

local function stepPummel(model: Model, brain: any, state: State, root: BasePart, now: number)
	local victim = state.victim
	local survivors: any = Registry.find("SurvivorService")
	if not victim or not survivors then
		beginRecover(model, brain, state, SLAM_RECOVERY)
		return
	end

	local character, victimRoot = Support.rootOf(victim)
	if not character or not victimRoot or not Support.stillPinnedBy(survivors, victim, model) then
		-- Shoved off, shot off, or the survivor went down. All three are answers,
		-- and all three end here.
		beginRecover(model, brain, state, SLAM_RECOVERY)
		return
	end

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.WalkSpeed ~= 0 then
		humanoid.WalkSpeed = 0
	end

	if now >= state.nextBellow then
		state.nextBellow = now + PUMMEL_BELLOW_INTERVAL
		Support.playSound("ChargerPummel", root)
	end

	if now >= state.nextPummel then
		state.nextPummel = now + ATTACK.cooldown
		Support.damage(
			model,
			character,
			victimRoot,
			root.Position,
			Support.scaledDamage(model, ATTACK.damage)
		)
		Remotes.Event.CameraImpulse:FireClient(victim, IMPACT_CAMERA_IMPULSE)
	end
end

local function stepRecover(model: Model, brain: any, state: State)
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.WalkSpeed ~= 0 then
		humanoid.WalkSpeed = 0
	end

	-- readyAt already carries the charge cooldown, so handing the body back the
	-- moment the daze ends does not let it wind up again immediately.
	if state.phaseTime >= state.recoverFor then
		backToStalk(model, brain, state, 0)
	end
end

-- ─── module surface ──────────────────────────────────────────────────────────

local Charger = {}

function Charger.onSpawn(model: Model, brain: any)
	local state = ensure(model)
	state.ignore[1] = model
	refreshProbe(state)

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.WalkSpeed = DEFINITION.runSpeed
	end

	local root = RigUtil.getRoot(model)
	if root then
		Support.playSound("ChargerIdle", root)
		-- The spawn bellow counts as this Charger's first; without this the
		-- approach clock fires again on the very next frame.
		state.nextBellow = os.clock() + BELLOW_INTERVAL
	end
	Support.setBrainTarget(brain, nil)
end

function Charger.onUpdate(model: Model, brain: any, dt: number)
	local state = states[model] or ensure(model)
	local root = RigUtil.getRoot(model)
	if not root then
		return
	end

	local now = os.clock()
	state.phaseTime += dt

	-- A shove during a wind-up cancels the charge outright, which is the cheapest
	-- answer in the game to the most expensive attack in it. stumbleResistance
	-- 0.7 is what stops that being a hard counter: the stagger is brief.
	if state.phase ~= PHASE.Stalk and Support.isStaggered(brain) then
		releaseVictim(model, state)
		backToStalk(model, brain, state, MISS_RECOVERY, true)
		return
	end

	if state.phase == PHASE.Charge then
		stepCharge(model, brain, state, root, dt)
	elseif state.phase == PHASE.Pummel then
		stepPummel(model, brain, state, root, now)
	elseif state.phase == PHASE.WindUp then
		stepWindUp(model, brain, state, root, dt)
	elseif state.phase == PHASE.Recover then
		stepRecover(model, brain, state)
	else
		stepStalk(model, brain, state, root, dt, now)
	end
end

function Charger.onDeath(model: Model, brain: any, _ctx: any)
	local state = states[model]
	if not state then
		return
	end
	-- Ownership is the one thing here that MUST be handed back. A survivor left
	-- server-simulated because the thing carrying them died would stay that way
	-- for the rest of the round.
	releaseVictim(model, state)
	Support.resumeBrain(brain)
	Support.unclaim(model)
	states[model] = nil
end

return Charger
