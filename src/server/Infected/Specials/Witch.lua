--!strict
--[[
	Witch — she cries, and then she calls.

	This is NOT the Left 4 Dead witch and nothing about the old hazard behaviour
	survives: she does not one-shot, she does not run away, and walking past her
	with your light off is no longer a free pass. InfectedConfig says what she is
	now — 1000 health, 45 damage, runSpeed 30 — and the shape of the encounter is
	the two things she does the moment she is disturbed, at the same time:

	  1. SUMMONS. Every Common inside her call drops what it was doing and walks
	     at the team, and the Director is told to run a panic on top of that. The
	     horde arrives whether or not anybody engages her, which is what makes
	     ignoring her no longer free.
	  2. HUNTS. She goes after whoever woke her at 30 studs a second: faster than
	     a survivor walks, slower than one sprints. Running IS the answer, but it
	     costs the team everything they were doing instead.

	The tension is that both halves are true at once. Fighting her means fighting
	the horde she called, and running from her means running through it. Both
	halves are made legible by sound, deliberately: WitchCry carries 460 studs so
	you always know she is there, WitchStartle tells the whole team the exact
	moment somebody made a mistake, and WitchSummon is loud, low and unmistakable
	because the team has to be able to connect "we heard that" with "here they
	come" without seeing anything.

	The hunt itself is the brain's job, not this file's. InfectedBrain already
	paths, re-paths, closes and swings on attack.cooldown with a visible windup,
	using this definition's numbers — so an awake Witch is handed straight back to
	it. Everything below is only the parts the brain has no concept of: sitting
	still, being woken, calling the horde, and giving up.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local DirectorConfig = require(Shared.Config.DirectorConfig)
local Enums = require(Shared.Enums)
local GameConfig = require(Shared.Config.GameConfig)
local InfectedConfig = require(Shared.Config.InfectedConfig)
local RaycastUtil = require(Shared.Util.RaycastUtil)
local Registry = require(Shared.Util.Registry)
local Remotes = require(Shared.Net.Remotes)
local RigUtil = require(Shared.Util.RigUtil)

local Support = require(script.Parent.Support)

local DEFINITION = InfectedConfig.Definitions[Enums.Infected.Witch]

local PHASE = table.freeze({
	Mourn = "Mourn", -- sitting, crying, doing nothing else
	Wake = "Wake", -- screaming, calling, about to move
	Hunt = "Hunt", -- the brain drives; she is coming
})

-- Anyone this close has disturbed her regardless of anything else. Read from the
-- shove range because a shove is one of the three canonical ways to wake her and
-- cannot be observed directly: MeleeService scales a shove by
-- (1 - stumbleResistance), and hers is 1.0, so a shove on the Witch produces no
-- signal anywhere. Proximity is the honest stand-in — anybody close enough to
-- have shoved her has woken her, which is the same outcome from their side.
local CONTACT_RANGE = GameConfig.Shove.Range

local WAKE_TIME = 0.9 -- the scream and the first call; the last moment to run
local CRY_INTERVAL = 5.5 -- the sound that tells the team she exists at all
local SCAN_INTERVAL = 0.25 -- her only cost while sitting; never per frame

--[[ The call.

     The first one goes out the instant she wakes, and one every SUMMON_INTERVAL
     after that for as long as she is awake. Twenty seconds is set against the
     Director's own panic shape — three waves nine seconds apart — so each call
     has finished arriving before the next one starts, and a team that kills her
     inside half a minute pays for exactly one horde.

     The radius is her hearingRange rather than a new number: that field already
     means "how far away this thing is aware of the world", and a call that
     reaches precisely as far as she can hear is the version a player can
     reason about. ]]
local SUMMON_INTERVAL = 20
local SUMMON_RADIUS = DEFINITION.hearingRange
-- How long a called Common ignores survivors and just walks. Short: they should
-- arrive and immediately be a horde, not stand at the anchor looking at it.
local SUMMON_LURE_TIME = 8

-- Degraded path only, for a server with no Director (a Studio test place, a
-- round that has not started). Small, and placed on the far side of her from the
-- team at the Director's own minimum spawn distance, so a fallback horde still
-- never materialises in somebody's face.
local FALLBACK_SPAWN_COUNT = 6
local FALLBACK_SPAWN_RADIUS = DirectorConfig.Spawning.MinDistanceFromSurvivor
local FALLBACK_SPAWN_ARC = math.rad(120)
local FALLBACK_GROUND_SEARCH = 40

-- With nobody inside sightRange for this long she sits back down and starts
-- again. She is a fixture of the map, not a roaming boss, and a Witch that
-- follows the team across the whole level stops being an encounter and becomes
-- weather. The horde she already called does not go away with her.
local GIVE_UP_TIME = DEFINITION.loseInterestTime

local STARTLE_CAMERA_IMPULSE = table.freeze({
	position = Vector3.new(0, 0.1, 0.2),
	rotation = Vector3.new(-2.5, 0, 0),
	decay = 7,
})

type State = {
	phase: string,
	phaseTime: number,
	nextCry: number,
	nextSummon: number,
	scanClock: number,
	lastHealth: number,
	victim: Player?,
	lostTime: number,
	ignore: { Instance },
}

-- Weak keys: a Witch despawned rather than killed never reaches onDeath.
local states = (setmetatable({}, { __mode = "k" }) :: any) :: { [Model]: State }

local function ensure(model: Model): State
	local state = states[model]
	if not state then
		local humanoid = model:FindFirstChildOfClass("Humanoid")
		state = {
			phase = PHASE.Mourn,
			phaseTime = 0,
			nextCry = 0,
			nextSummon = 0,
			scanClock = 0,
			lastHealth = if humanoid then humanoid.Health else DEFINITION.health,
			victim = nil,
			lostTime = 0,
			ignore = { model },
		}
		states[model] = state
	end
	return state
end

-- ─── the call ────────────────────────────────────────────────────────────────

--[[ Where the horde is being sent: the middle of the team, falling back to her
     own position when there is nobody left to converge on. ]]
local function hordeAnchor(root: BasePart): Vector3
	local survivors: any = Registry.find("SurvivorService")
	if not survivors then
		return root.Position
	end

	local sum = Vector3.zero
	local count = 0
	for _, player in survivors:getAliveSurvivors() do
		local _, victimRoot = Support.rootOf(player)
		if victimRoot then
			sum += victimRoot.Position
			count += 1
		end
	end

	return if count > 0 then sum / count else root.Position
end

--[[ Bodies out of nothing, for a server with no Director to ask. Ground-snapped
     and placed behind her, because InfectedService:spawn takes a floor point and
     trusts the caller to have chosen a sane one. ]]
local function spawnFallbackHorde(root: BasePart, state: State, anchor: Vector3)
	local infected: any = Registry.find("InfectedService")
	if not infected or typeof(infected.spawn) ~= "function" then
		return
	end

	local origin = root.Position
	local delta = origin - anchor
	local flat = Vector3.new(delta.X, 0, delta.Z)
	local away = if flat.Magnitude > 0.05 then flat.Unit else root.CFrame.LookVector

	for index = 1, FALLBACK_SPAWN_COUNT do
		local fraction = (index - 1) / math.max(FALLBACK_SPAWN_COUNT - 1, 1) - 0.5
		local direction = CFrame.fromAxisAngle(Vector3.yAxis, fraction * FALLBACK_SPAWN_ARC) * away
		local point = origin + direction * FALLBACK_SPAWN_RADIUS
		local ground = RaycastUtil.groundAt(point, FALLBACK_GROUND_SEARCH, state.ignore)
		if ground then
			infected:spawn(Enums.Infected.Common, ground)
		end
	end
end

--[[
	One call. Announced first, because the sound is the mechanic: the team has to
	be able to hear a summon and act on it before anything is visible.

	Both halves go out together. The lure drags the Commons that already exist —
	the ones the team walked past, the stragglers behind them — onto the anchor,
	and the Director's panic event supplies the ones that do not exist yet through
	its own spawn placement, which means they still arrive from somewhere legal
	and out of sight rather than appearing in the room.
]]
local function summon(root: BasePart, state: State, now: number)
	state.nextSummon = now + SUMMON_INTERVAL

	Support.playSound("WitchSummon", root)

	local anchor = hordeAnchor(root)

	local infected: any = Registry.find("InfectedService")
	if infected and typeof(infected.lure) == "function" then
		infected:lure(anchor, SUMMON_RADIUS, SUMMON_LURE_TIME)
	end

	local director: any = Registry.find("DirectorService")
	if director and typeof(director.triggerPanicEvent) == "function" then
		director:triggerPanicEvent(anchor)
	else
		spawnFallbackHorde(root, state, anchor)
	end
end

-- ─── waking ──────────────────────────────────────────────────────────────────

--[[
	Watches for a disturbance and returns whoever caused it.

	Damage is detected by watching the Humanoid's health rather than by listening
	to DamageService.damageDealt: a signal connection made per Witch would outlive
	a Witch that is despawned instead of killed, and this file must not own a
	subscription it cannot guarantee it will clean up. The attacker is then read as
	the nearest survivor with a sightline, which is who shot her in every case
	that is not a deliberate ricochet.

	Sight and contact are the other two. There is no "staring at her" grace period
	any more — she is not a trap to be tiptoed around, she is an enemy who notices
	you — so being inside sightRange with a clear line is enough.
]]
local function checkDisturbance(model: Model, root: BasePart, state: State): Player?
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local hurt = false
	if humanoid then
		if humanoid.Health < state.lastHealth - 0.01 then
			hurt = true
		end
		state.lastHealth = humanoid.Health
	end

	local survivors: any = Registry.find("SurvivorService")
	if not survivors then
		return nil
	end

	local origin = root.Position
	local seen: Player? = nil
	local seenDistance = math.huge
	local blamed: Player? = nil
	local blamedDistance = math.huge

	for _, player in survivors:getAliveSurvivors() do
		local character, victimRoot = Support.rootOf(player)
		if not character or not victimRoot then
			continue
		end

		local distance = (victimRoot.Position - origin).Magnitude

		-- Tracked with no range or sightline filter at all, because a Witch shot
		-- from across the map is still a Witch that has been shot and she has to
		-- have somebody to blame for it.
		if distance < blamedDistance then
			blamedDistance = distance
			blamed = player
		end

		-- Close enough to have shoved her, whatever is in the way.
		if distance <= CONTACT_RANGE then
			return player
		end

		if distance > DEFINITION.sightRange or distance >= seenDistance then
			continue
		end

		state.ignore[2] = character
		local visible = RaycastUtil.hasLineOfSight(origin, victimRoot.Position, state.ignore)
		state.ignore[2] = nil
		if visible then
			seenDistance = distance
			seen = player
		end
	end

	if hurt then
		return seen or blamed
	end
	return seen
end

local function wake(brain: any, state: State, root: BasePart, by: Player, dt: number, now: number)
	state.phase = PHASE.Wake
	state.phaseTime = 0
	state.victim = by
	state.lostTime = 0

	Support.playSound("WitchStartle", root)
	Remotes.Event.CameraImpulse:FireClient(by, STARTLE_CAMERA_IMPULSE)

	-- The horde is called on the same frame she stands up, not when she reaches
	-- somebody. Whoever woke her has already spent that; the only question left
	-- is whether the team fights her before it lands.
	summon(root, state, now)

	local _, victimRoot = Support.rootOf(by)
	if victimRoot then
		Support.faceTowards(brain, root, victimRoot.Position, dt)
	end
end

--[[ Back to the floor, wherever she happens to be standing. The brain goes back
     to sleep with her; the Commons she called do not. ]]
local function sitDown(model: Model, brain: any, state: State)
	Support.pauseBrain(brain)
	Support.setBrainTarget(brain, nil)

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.WalkSpeed = 0
		state.lastHealth = humanoid.Health
	end

	state.phase = PHASE.Mourn
	state.phaseTime = 0
	state.victim = nil
	state.lostTime = 0
	state.scanClock = 0
end

-- ─── phases ──────────────────────────────────────────────────────────────────

local function stepMourn(model: Model, brain: any, state: State, root: BasePart, dt: number, now: number)
	-- Re-asserted rather than set once at spawn. "She does not move until she is
	-- disturbed" is the whole first half of the encounter, and it must not depend
	-- on the brain having honoured pause().
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.WalkSpeed ~= 0 then
		humanoid.WalkSpeed = 0
	end

	if now >= state.nextCry then
		state.nextCry = now + CRY_INTERVAL
		Support.playSound("WitchCry", root)
	end

	-- The sight tests are the only cost a sitting Witch has, so they run on their
	-- own clock rather than every frame.
	state.scanClock += dt
	if state.scanClock < SCAN_INTERVAL then
		return
	end
	local elapsed = state.scanClock
	state.scanClock = 0

	local by = checkDisturbance(model, root, state)
	if by then
		wake(brain, state, root, by, elapsed, now)
	end
end

local function stepWake(model: Model, brain: any, state: State, root: BasePart, dt: number)
	local _, victimRoot = Support.rootOf(state.victim)
	if victimRoot then
		Support.faceTowards(brain, root, victimRoot.Position, dt)
	end

	if state.phaseTime < WAKE_TIME then
		return
	end

	-- Handed to the brain and left there. It owns pathing, and a Witch who cannot
	-- follow you round a corner is a Witch you beat with a doorway; it also owns
	-- the swing, which is already this definition's 45 damage on a 1.4s cooldown
	-- behind a 0.25s windup. Re-implementing either here would only add a way for
	-- them to disagree.
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.WalkSpeed = DEFINITION.runSpeed
	end
	Support.resumeBrain(brain)

	local victim = state.victim
	Support.setBrainTarget(brain, if victim then victim.Character else nil)

	state.phase = PHASE.Hunt
	state.phaseTime = 0
	state.lostTime = 0
end

local function stepHunt(model: Model, brain: any, state: State, root: BasePart, dt: number)
	state.scanClock += dt
	if state.scanClock < SCAN_INTERVAL then
		return
	end
	state.scanClock = 0

	local survivors: any = Registry.find("SurvivorService")
	if not survivors then
		sitDown(model, brain, state)
		return
	end

	local origin = root.Position
	local victim = state.victim
	local victimAlive = false
	local nearest: Player? = nil
	local nearestDistance = math.huge

	for _, player in survivors:getAliveSurvivors() do
		local _, victimRoot = Support.rootOf(player)
		if not victimRoot then
			continue
		end
		if player == victim then
			victimAlive = true
		end
		local distance = (victimRoot.Position - origin).Magnitude
		if distance < nearestDistance then
			nearestDistance = distance
			nearest = player
		end
	end

	-- She holds a grudge: whoever woke her stays the target for as long as they
	-- are on their feet. Only when they are gone does she take the nearest.
	if not victimAlive then
		state.victim = nearest
		victim = nearest
	end

	Support.setBrainTarget(brain, if victim then victim.Character else nil)

	if nearestDistance <= DEFINITION.sightRange then
		state.lostTime = 0
		return
	end

	state.lostTime += SCAN_INTERVAL
	if state.lostTime >= GIVE_UP_TIME then
		sitDown(model, brain, state)
	end
end

-- ─── module surface ──────────────────────────────────────────────────────────

local Witch = {}

function Witch.onSpawn(model: Model, brain: any)
	local state = ensure(model)
	state.ignore[1] = model

	-- Paused from the first frame. Until something disturbs her she is not an AI
	-- with a target list; she is a piece of level geometry that cries.
	Support.pauseBrain(brain)
	Support.setBrainTarget(brain, nil)

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.WalkSpeed = 0
		state.lastHealth = humanoid.Health
	end

	local root = RigUtil.getRoot(model)
	if root then
		Support.playSound("WitchCry", root)
		state.nextCry = os.clock() + CRY_INTERVAL
	end
end

function Witch.onUpdate(model: Model, brain: any, dt: number)
	local state = states[model] or ensure(model)
	local root = RigUtil.getRoot(model)
	if not root then
		return
	end

	local now = os.clock()
	state.phaseTime += dt

	-- The call runs on its own clock in every awake phase, so it survives her
	-- being staggered, cornered, or busy swinging at somebody. Once she is up,
	-- the horde is coming on a timer the team cannot interrupt except by killing
	-- her — which is the entire cost of having woken her.
	if state.phase ~= PHASE.Mourn and now >= state.nextSummon then
		summon(root, state, now)
	end

	if state.phase == PHASE.Hunt then
		stepHunt(model, brain, state, root, dt)
	elseif state.phase == PHASE.Wake then
		stepWake(model, brain, state, root, dt)
	else
		stepMourn(model, brain, state, root, dt, now)
	end

	-- Her cry keeps going while she hunts. It is the only way a team that ran
	-- knows how much distance they have actually made, and at 460 studs of
	-- rolloff it is the loudest thing on the map that is not a Tank.
	if state.phase ~= PHASE.Mourn and now >= state.nextCry then
		state.nextCry = now + CRY_INTERVAL
		Support.playSound("WitchCry", root)
	end
end

function Witch.onDeath(model: Model, brain: any, _ctx: any)
	-- Killing her is legitimate and expensive: 1000 health, stumbleResistance
	-- 1.0, and she is already on top of somebody by the time most teams commit to
	-- it. Nothing to unwind but the brain — the horde she called is not hers to
	-- take back, and that is the point of her.
	Support.resumeBrain(brain)
	states[model] = nil
end

return Witch
