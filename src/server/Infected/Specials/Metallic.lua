--!strict
--[[
	Metallic — the boss above the Tank, and a different fight rather than a
	longer one.

	── THE PROBLEM A SECOND BOSS HAS ───────────────────────────────────────────
	Everything a team learns about a Tank is one lesson: move as a unit, fire in
	turns, and burn it. Put a bigger Tank in front of them and they win with the
	same three answers and a longer magazine, and the round has gained a health
	bar rather than an encounter. So every mechanic here is chosen against one of
	those three answers.

	    MOVE AS A UNIT   -> the POUND. A shockwave around its own feet. Standing
	                        together next to it is the mistake.
	    FIRE IN TURNS    -> the CHARGE. It cannot be outrun in a straight line
	                        and it does not need to be fast to catch you, so
	                        backing down a corridor is the mistake. Sidestepping
	                        is the answer, and only sidestepping.
	    BURN IT          -> nothing. burnDamagePerSecond is 25 against a Tank's
	                        150, and a team that opens with the molotov that
	                        always worked has spent it.

	── AND ONE THING THAT IS GIVEN BACK ────────────────────────────────────────
	The charge ends in an OVERHEAT: a few seconds rooted, defenceless, taking
	double damage, announced out loud. A boss with no window is a boss you shoot
	continuously, which is the same as a boss with more health; a boss with a
	window is a boss you bait. Almost all of this thing's damage is taken in
	those few seconds, and getting one is the point of surviving a charge.

	The charge also STOPS ON THE WORLD, and that is a mechanic rather than a
	safety check. Standing with a pillar behind you turns a dodge into a full
	overheat several seconds early, so a team that reads the arena beats this
	thing faster than a team that only reads the boss.

	── AND IT IS NOT A SEQUENCE ────────────────────────────────────────────────
	Which move comes next is a weighted roll re-taken every time, biased by the
	fight rather than fixed: it pounds when the team is close, charges when they
	are far, and does neither on a schedule. A boss whose pattern can be counted
	is a boss that is solved once and never fought again.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attributes = require(Shared.Net.Attributes)
local Enums = require(Shared.Enums)
local InfectedConfig = require(Shared.Config.InfectedConfig)
local Registry = require(Shared.Util.Registry)
local RigUtil = require(Shared.Util.RigUtil)
local Types = require(Shared.Types)

local Support = require(script.Parent.Support)

local DEFINITION = InfectedConfig.Definitions[Enums.Infected.Metallic]

local Metallic = {}

local PHASE = table.freeze({
	Pursue = "Pursue", -- the brain drives
	Wind = "Wind", -- rooted, drills spinning up, about to charge
	Charge = "Charge", -- driving forward in a committed straight line
	Overheat = "Overheat", -- rooted, defenceless, double damage
	Pound = "Pound", -- rooted, about to slam the ground
})

--[[ THE CHARGE. Long enough to cross a street, fast enough that a survivor
     running down its lane does not get out of the way — which is the point: the
     escape is sideways, and only sideways. ]]
local CHARGE_WIND = 1.05
local CHARGE_SPEED = 62
local CHARGE_TIME = 1.9
local CHARGE_HALF_WIDTH = 7.5
local CHARGE_DAMAGE = 46
local CHARGE_LAUNCH = 70
local CHARGE_LIFT = 30
--[[ THE WINDOW. Two and a half seconds of standing still at double damage, and
     those numbers are the whole balance of the fight: a four-player team doing
     roughly 400 a second lands about two thousand of its six thousand health in
     one window, so three landed windows is the kill. ]]
local OVERHEAT_TIME = 2.5
local OVERHEAT_MULTIPLIER = 2.0

--[[ THE POUND. Its answer to being surrounded. Short reach, no line of sight
     needed — it is a shockwave through the floor — and it hurts. ]]
local POUND_WIND = 0.7
local POUND_RADIUS = 18
local POUND_DAMAGE = 34
local POUND_RECOVER = 0.5

--[[ How often it considers doing something other than walking at you, and the
     odds it takes each. Re-rolled every time rather than cycled: see the header. ]]
local DECIDE_INTERVAL_MIN = 3.4
local DECIDE_INTERVAL_MAX = 6.2
--[[ Inside this, the pound is the only sensible move — there is no room to build
     up a charge — and beyond it the charge is. Between the two it rolls. ]]
local POUND_RANGE = 20
local CHARGE_MIN_DISTANCE = 26

--[[ The last quarter, and it is the same quarter the Tank enrages on and the
     same quarter the boss bar goes hot — one number across all three, so a team
     learns the tell once. What it does here is not "faster and angrier": it
     SHUTS THE DOOR. The vent window is the only thing that makes this fight
     winnable inside a wave, and the closer the thing is to dead the less of it
     you get. A team that has been trading the window well finishes it; a team
     that has been missing windows finds out the last one is the tightest. ]]
local ENRAGE_FRACTION = 0.25
local ENRAGE_OVERHEAT = 0.6 -- fraction of the window that survives the enrage
local ENRAGE_TEMPO = 0.65 -- multiplier on how long it waits between decisions

--[[ How high off the floor the charge looks ahead. Above a kerb and below the
     lintel of anything it could fit through, so it stops on walls and not on the
     ramps and thresholds it is supposed to run over. ]]
local CHARGE_PROBE_HEIGHT = 5

local SCAN_INTERVAL = 0.3
local FOOTSTEP_INTERVAL = 0.5
local ROAR_INTERVAL = 13

local random = Random.new()

type State = {
	phase: string,
	phaseTime: number,
	nextScan: number,
	nextDecide: number,
	nextRoar: number,
	nextFootstep: number,
	--[[ Where the charge is going. Locked at the END of the windup rather than
	     tracked through it, which is what makes the telegraph mean something: the
	     lane you see it line up on is the lane it commits to. ]]
	chargeDirection: Vector3?,
	--[[ Who this charge has already hit, so one pass cannot hit the same person
	     on sixty consecutive frames. ]]
	chargeHit: { [Player]: boolean },
	target: Player?,
	poundDamage: number,
	--[[ Set the frame the pound lands so the blast fires exactly once. Comparing
	     phaseTime against the windup cannot do this on its own: it steps by a
	     whole frame, so there is no instant where it equals the deadline. ]]
	landed: boolean,
	enraged: boolean,
	--[[ What the charge looks ahead with. Rebuilt at the start of every charge
	     rather than kept current, because the only things it has to ignore — the
	     survivors it is trying to run over, and the horde around them — are
	     exactly the things that move between one charge and the next. ]]
	probe: RaycastParams,
}

-- Weak keys: a body despawned rather than killed never reaches onDeath.
local states = (setmetatable({}, { __mode = "k" }) :: any) :: { [Model]: State }

local function ensure(model: Model): State
	local state = states[model]
	if not state then
		local probe = RaycastParams.new()
		probe.FilterType = Enum.RaycastFilterType.Exclude
		probe.FilterDescendantsInstances = { model }
		probe.IgnoreWater = true
		probe.RespectCanCollide = true

		state = {
			phase = PHASE.Pursue,
			phaseTime = 0,
			nextScan = 0,
			nextDecide = 0,
			nextRoar = 0,
			nextFootstep = 0,
			chargeDirection = nil,
			chargeHit = {},
			target = nil,
			poundDamage = POUND_DAMAGE,
			landed = false,
			enraged = false,
			probe = probe,
		}
		states[model] = state
	end
	return state
end

local function setPhase(state: State, phase: string)
	state.phase = phase
	state.phaseTime = 0
	state.landed = false
end

--[[ The nearest survivor it can see, and how far. Nearest rather than furthest:
     the charge picks its own lane from this and a boss that always charged the
     person at the back would be a boss that ignores whoever is fighting it. ]]
local function nearestSurvivor(root: BasePart): (Player?, BasePart?, number)
	local survivors: any = Registry.find("SurvivorService")
	if not survivors then
		return nil, nil, math.huge
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
				best, bestRoot, bestDistance = player, victimRoot, distance
			end
		end
	end
	return best, bestRoot, bestDistance
end

local function announce(text: string)
	local round: any = Registry.find("RoundService")
	if round and typeof(round.announce) == "function" then
		pcall(round.announce, round, "", text, 3)
	end
end

--[[ Opens or closes the window. The attribute is what InfectedService:damage
     multiplies by and what the HUD reads; 1 is "no window" and is written rather
     than cleared so nothing downstream has to treat nil as a special case. ]]
local function setVulnerable(model: Model, multiplier: number)
	model:SetAttribute(Attributes.Infected.Vulnerable, multiplier)
end

-- How long this body's vent window stays open, in its current condition.
local function overheatWindow(state: State): number
	return if state.enraged then OVERHEAT_TIME * ENRAGE_OVERHEAT else OVERHEAT_TIME
end

-- How long it waits between decisions, likewise.
local function decideDelay(state: State): number
	local delay = random:NextNumber(DECIDE_INTERVAL_MIN, DECIDE_INTERVAL_MAX)
	return if state.enraged then delay * ENRAGE_TEMPO else delay
end

--[[ Crosses into the last quarter once and never back. Said out loud, because a
     window that silently got shorter is a team wondering why the plan stopped
     working rather than a team being told the fight changed. ]]
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
	--[[ Pulled in, not reset: enraging must not GRANT a free move to a body that
	     has just committed to one. ]]
	state.nextDecide = math.min(state.nextDecide, os.clock() + DECIDE_INTERVAL_MIN * ENRAGE_TEMPO)
	Support.playSound("MetallicRoar", root)
	announce("IT'S VENTING FASTER — THE WINDOW IS CLOSING")
end

-- ── the moves ───────────────────────────────────────────────────────────────

local function beginPound(model: Model, brain: any, state: State)
	setPhase(state, PHASE.Pound)
	Support.pauseBrain(brain)
	local root = RigUtil.getRoot(model)
	if root then
		Support.playSound("MetallicWind", root)
	end
end

local function landPound(model: Model, state: State, root: BasePart)
	local damageService: any = Registry.find("DamageService")
	if damageService and typeof(damageService.applyExplosion) == "function" then
		--[[ Through the explosion path rather than a per-survivor loop, so cover
		     and falloff work the same way they do for every other blast in the
		     game and a survivor behind a car takes less. ]]
		damageService:applyExplosion(
			root.Position,
			POUND_RADIUS,
			state.poundDamage,
			Types.newDamageContext({
				attackerModel = model,
				damageType = Enums.DamageType.Special,
				hitPosition = root.Position,
			})
		)
	end
	Support.playSound("MetallicSlam", root)
end

local function beginWind(model: Model, brain: any, state: State)
	setPhase(state, PHASE.Wind)
	Support.pauseBrain(brain)
	table.clear(state.chargeHit)
	local root = RigUtil.getRoot(model)
	if root then
		Support.playSound("MetallicWind", root)
	end
end

--[[ Points the charge's probe at the WORLD and nothing else. Survivors and the
     rest of the horde are excluded on purpose: running them over is the move, so
     stopping on one would make a single Common a wall. ]]
local function aimProbe(model: Model, state: State)
	local exclude: { Instance } = { model }

	local survivors: any = Registry.find("SurvivorService")
	if survivors and typeof(survivors.getSurvivorCharacters) == "function" then
		for _, character in survivors:getSurvivorCharacters() do
			table.insert(exclude, character)
		end
	end

	--[[ The whole folder rather than a walk of it: it holds corpses as well as
	     bodies, and a charge that stopped dead on the Common it killed a second
	     ago would be the single worst way for this move to fail. ]]
	local horde = Workspace:FindFirstChild("Infected")
	if horde then
		table.insert(exclude, horde)
	end

	state.probe.FilterDescendantsInstances = exclude
end

local function beginCharge(model: Model, state: State, root: BasePart)
	setPhase(state, PHASE.Charge)
	aimProbe(model, state)
	--[[ Locked HERE, at the end of the windup, from where the body is facing.
	     The telegraph is the turn during the wind — so what it commits to is
	     what the players watched it line up on, and stepping out of that lane is
	     a decision they were given the information to make. ]]
	local look = root.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	state.chargeDirection = if flat.Magnitude > 0.05 then flat.Unit else Vector3.zAxis
	Support.playSound("MetallicCharge", root)
end

local function beginOverheat(model: Model, state: State, root: BasePart)
	setPhase(state, PHASE.Overheat)
	state.chargeDirection = nil
	setVulnerable(model, OVERHEAT_MULTIPLIER)
	Support.playSound("MetallicVent", root)
	announce("IT'S OVERHEATING — HIT IT NOW")
end

--[[ One frame of a charge: move, then hit whoever the body passed through.

     The sweep is a CYLINDER around the travel line rather than a raycast,
     because a raycast down the middle of a charging boss misses anybody standing
     beside its own shoulder — which, given how wide this thing is, is most of
     the people it plainly just ran over. ]]
local function stepCharge(model: Model, state: State, root: BasePart, dt: number): boolean
	local direction = state.chargeDirection
	if not direction then
		return false
	end

	local step = direction * (CHARGE_SPEED * dt)
	local from = root.Position

	--[[ Looked at BEFORE the move, not after. The body travels a whole stud a
	     frame at this speed, and a check that runs afterwards is a check that
	     runs from inside the wall it was supposed to stop at. ]]
	local ahead = from + Vector3.new(0, CHARGE_PROBE_HEIGHT, 0)
	local blocked = Workspace:Raycast(ahead, step, state.probe)
	if blocked then
		return true
	end

	model:PivotTo(model:GetPivot() + step)

	local survivors: any = Registry.find("SurvivorService")
	if not survivors then
		return
	end
	for _, player in survivors:getAliveSurvivors() do
		if state.chargeHit[player] then
			continue
		end
		local character, victimRoot = Support.rootOf(player)
		if not character or not victimRoot then
			continue
		end
		local delta = victimRoot.Position - from
		local along = delta:Dot(direction)
		--[[ Behind the shoulder, or further along than this frame reached: not
		     hit by THIS step. `along` past the step length is caught by a later
		     frame, which is what stops a fast charge tunnelling through somebody
		     between two frames. ]]
		if along < -CHARGE_HALF_WIDTH or along > step.Magnitude + CHARGE_HALF_WIDTH then
			continue
		end
		if (delta - direction * along).Magnitude > CHARGE_HALF_WIDTH then
			continue
		end

		state.chargeHit[player] = true
		Support.damage(model, character, victimRoot, from, Support.scaledDamage(model, CHARGE_DAMAGE))
		--[[ Thrown clear along the charge rather than away from the impact point:
		     being run over should put you where the thing was going, not neatly
		     to one side of it. ]]
		Support.launch(victimRoot, direction * CHARGE_LAUNCH + Vector3.new(0, CHARGE_LIFT, 0))
	end

	return false
end

--[[ What to do next, rolled rather than cycled.

     Distance decides which moves are on the table and chance decides between
     them, so the same distance twice does not produce the same move twice. ]]
local function decide(model: Model, brain: any, state: State, distance: number)
	if distance <= POUND_RANGE then
		--[[ Close in. The pound is the answer to being surrounded, but not every
		     time — a boss that pounds the instant anybody is near it is one you
		     simply never stand near, and then it has no melee at all. ]]
		if random:NextNumber() < 0.7 then
			beginPound(model, brain, state)
		end
		return
	end
	if distance >= CHARGE_MIN_DISTANCE then
		beginWind(model, brain, state)
		return
	end
	--[[ The middle band: too far to slam, too close to build up. It keeps
	     walking, which is the honest answer and is also the gap a team can use to
	     reposition. ]]
end

-- ── the phases ──────────────────────────────────────────────────────────────

local function stepPursue(model: Model, brain: any, state: State, root: BasePart, dt: number, now: number)
	if now >= state.nextScan then
		state.nextScan = now + SCAN_INTERVAL
		local player, _, distance = nearestSurvivor(root)
		state.target = player
		Support.setBrainTarget(brain, if player then player.Character else nil)

		if player and now >= state.nextDecide then
			state.nextDecide = now + decideDelay(state)
			decide(model, brain, state, distance)
		end
	end

	if now >= state.nextRoar then
		state.nextRoar = now + ROAR_INTERVAL
		Support.playSound("MetallicRoar", root)
	end
	if now >= state.nextFootstep then
		state.nextFootstep = now + FOOTSTEP_INTERVAL
		Support.playSound("MetallicStep", root)
	end
	local _ = dt
end

local function stepWind(model: Model, brain: any, state: State, root: BasePart, dt: number)
	--[[ Still turning during the wind, which IS the telegraph: the lane it ends
	     up facing is the lane it commits to, and a player watching it swing round
	     has been told where not to be. ]]
	local _, victimRoot = Support.rootOf(state.target)
	if victimRoot then
		Support.faceTowards(brain, root, victimRoot.Position, dt)
	end
	if state.phaseTime >= CHARGE_WIND then
		beginCharge(model, state, root)
	end
end

local function stepChargePhase(model: Model, brain: any, state: State, root: BasePart, dt: number)
	--[[ Either ending is the same ending. Running the charge out and slamming
	     into a pillar both leave it rooted and venting — the wall just gets the
	     team there sooner, which is the reward for having picked the ground. ]]
	local hitWall = stepCharge(model, state, root, dt)
	if hitWall or state.phaseTime >= CHARGE_TIME then
		beginOverheat(model, state, root)
	end
	local _ = brain
end

local function stepOverheat(model: Model, brain: any, state: State)
	if state.phaseTime >= overheatWindow(state) then
		setVulnerable(model, 1)
		setPhase(state, PHASE.Pursue)
		Support.resumeBrain(brain)
	end
end

local function stepPound(model: Model, brain: any, state: State, root: BasePart)
	if state.phaseTime < POUND_WIND then
		return
	end
	if not state.landed then
		state.landed = true
		landPound(model, state, root)
	end
	if state.phaseTime >= POUND_WIND + POUND_RECOVER then
		setPhase(state, PHASE.Pursue)
		Support.resumeBrain(brain)
	end
end

-- ── lifecycle ───────────────────────────────────────────────────────────────

function Metallic.onSpawn(model: Model, brain: any)
	local state = ensure(model)
	state.poundDamage = Support.scaledDamage(model, POUND_DAMAGE)
	setVulnerable(model, 1)

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.WalkSpeed = Support.scaledSpeed(model, DEFINITION.runSpeed)
	end

	--[[ The same flag a Tank raises. The music system asks one boolean "is there
	     a boss on the map", and giving this one its own would mean every reader
	     of that flag needing to learn about a second. ]]
	Workspace:SetAttribute(Attributes.Game.TankActive, true)

	local root = RigUtil.getRoot(model)
	if root then
		Support.playSound("MetallicRoar", root)
		state.nextRoar = os.clock() + ROAR_INTERVAL
	end
	--[[ The first decision is not immediate. Arriving and instantly charging
	     gives a team no time to see what has walked in. ]]
	state.nextDecide = os.clock() + random:NextNumber(DECIDE_INTERVAL_MIN, DECIDE_INTERVAL_MAX)
	Support.setBrainTarget(brain, nil)
end

function Metallic.onUpdate(model: Model, brain: any, dt: number)
	local state = states[model] or ensure(model)
	local root = RigUtil.getRoot(model)
	if not root then
		return
	end

	local now = os.clock()
	state.phaseTime += dt

	-- Checked in every phase: crossing the line mid-charge must still count.
	checkEnrage(model, state, root)

	if state.phase == PHASE.Wind then
		stepWind(model, brain, state, root, dt)
	elseif state.phase == PHASE.Charge then
		stepChargePhase(model, brain, state, root, dt)
	elseif state.phase == PHASE.Overheat then
		stepOverheat(model, brain, state)
	elseif state.phase == PHASE.Pound then
		stepPound(model, brain, state, root)
	else
		stepPursue(model, brain, state, root, dt, now)
	end
end

function Metallic.onDeath(model: Model, brain: any, _ctx: any)
	local state = states[model]
	if state then
		Support.resumeBrain(brain)
		states[model] = nil
	end
	--[[ The window closes with it. An attribute left at 2 on a corpse is
	     harmless today and is exactly the kind of thing a future reader of it
	     would be caught by. ]]
	setVulnerable(model, 1)

	--[[ Only the last boss on the map clears the music flag, and a Tank counts:
	     the flag means "a boss is here", so a Metallic dying while a Tank is
	     still standing must not stop the track. ]]
	local others = 0
	local infected: any = Registry.find("InfectedService")
	if infected and typeof(infected.getAlive) == "function" then
		for _, kind in { Enums.Infected.Metallic, Enums.Infected.Tank } do
			for _, other in infected:getAlive(kind) do
				if other ~= model and RigUtil.isAlive(other) then
					others += 1
				end
			end
		end
	end
	if others == 0 then
		Workspace:SetAttribute(Attributes.Game.TankActive, false)
	end

	local root = RigUtil.getRoot(model)
	if root then
		Support.playSound("MetallicRoar", root)
	end
end

return Metallic
