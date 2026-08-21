--!nonstrict
--[[
	DirectorService — the pacing brain.

	This is the system that separates Fading Light from a wave shooter. It does
	not spawn on a timer. It reads how hard the team is being pressed, and when
	that read gets high it DELIBERATELY BACKS OFF, so the next horde lands on a
	team that has had just enough time to relax, heal, spread out and start
	talking again. The rhythm is the product; the zombies are just how the rhythm
	is delivered.

	Three loops run on top of each other:

	  intensity   a 0-1 per-survivor read of the last few seconds. It rises from
	              damage, pins, incaps, crowding and low health, and falls on its
	              own. The Director reads the TEAM'S PEAK rather than the average
	              — pacing should follow whoever is having the worst time, not be
	              diluted by the three people who are fine.

	  pacing      Relax -> BuildUp -> SustainPeak -> PeakFade -> Relax, with a
	              minimum dwell so the state cannot flicker and a maximum so a
	              turtling team cannot stall the map out forever.

	  population  each state names a TARGET number of commons. The Director
	              trickles toward it in small batches. A target is never a dump:
	              spawning forty bodies in one frame is both a framerate cliff
	              and a worse experience than a stream that keeps arriving from
	              somewhere you have to keep watching.

	Everything expensive is bounded. One Heartbeat connection drives the whole
	system at TICK_RATE (this is a strategic system, not a physics one), spawn
	requests drain through a single queue at a fixed rate per tick, and the
	intensity pass allocates nothing per survivor.

	── WAVES ────────────────────────────────────────────────────────────────────

	Fading Light is not a campaign. A round is seven waves on a fixed schedule,
	and RoundService owns that schedule. So the Director no longer invents WHEN
	pressure happens — it is handed a budget on every phase change and decides
	WHAT and HOW MUCH inside it:

	    DirectorService:setWaveBudget(budget)   populationScale, spawnRateScale,
	                                            maxSpecialsAlive, specialInterval,
	                                            waveIndex, isBreather
	    DirectorService:releaseBoss(kind)       a Tank or a Witch, placed now
	    DirectorService:setActive(active)       prep, post-round, lobby

	The wave sets the CEILING. Everything above still runs underneath it: the
	intensity read is unchanged, the pacing machine still moves between Relax and
	SustainPeak inside a wave, and the spawn rules still refuse to put a body in
	somebody's field of view. What the budget changes is the size of the room the
	Director gets to move around in.

	── THE BAND ─────────────────────────────────────────────────────────────────

	The Director's whole decision each tick is one scalar, `pressure`, and it is
	multiplied into BOTH the common-infected target and the spawn rate — so a
	single choice ("how hard am I leaning on these people") shows up as fewer
	bodies AND longer gaps between them, which together is what a player actually
	reads as the game easing off. One number, two effects, no way for them to
	disagree.

	    1.25   healthy team, quiet last few seconds   a quarter above the wave
	    1.00   the wave definition's own baseline
	    0.45   team at the hurt threshold, or intensity at PeakThreshold

	Why 0.45 at the bottom: roughly halving the horde is the smallest change that
	reads as relief from inside a fight. A gentler floor (0.7, 0.8) is invisible
	while you are shooting, which makes the entire mechanism pointless. Wave 6's
	SustainPeak ask of 46 x 1.35 — already past the roster's ceiling of 60 — falls
	to 28. The room visibly empties, the team gets to move, and it is still a wave.

	Why only 1.25 at the top: the wave schedule IS the difficulty curve. A
	Director that rewards a coasting team with 60% more bodies turns wave 3 into
	wave 5 and flattens the shape the whole round is built around. A quarter more
	is pressure a good team feels without the round losing its identity.

	Between those ends it is linear in `stress`, which is the WORSE of two reads,
	each normalised at the config's own line for it — the same reasoning that
	makes team intensity a peak rather than an average:

	    intensity   0 at rest, 1 at DirectorConfig PeakThreshold (0.80)
	    health      0 at full team health, 1 once SurvivorService's team fraction
	                has fallen to GameConfig HurtThreshold / MaxHealth (0.40)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attributes = require(Shared.Net.Attributes)
local DirectorConfig = require(Shared.Config.DirectorConfig)
local Enums = require(Shared.Enums)
local GameConfig = require(Shared.Config.GameConfig)
local InfectedConfig = require(Shared.Config.InfectedConfig)
local Registry = require(Shared.Util.Registry)
local Remotes = require(Shared.Net.Remotes)
local Signal = require(Shared.Util.Signal)
local Trove = require(Shared.Util.Trove)

local SpawnPlacement = require(script.Parent.SpawnPlacement)

local INTENSITY = DirectorConfig.Intensity
local PACING = DirectorConfig.Pacing
local POPULATION = DirectorConfig.Population
local SPAWNING = DirectorConfig.Spawning
local SPECIALS = DirectorConfig.Specials
local BOSSES = DirectorConfig.Bosses
local PANIC = DirectorConfig.PanicEvent

local STATE = Enums.PacingState

--[[ Bosses excluded — they are released by RoundService at wave start, never by
     the special budget. The config is frozen, so this list never changes and is
     built once rather than rebuilt (and re-sorted) on every Director tick. ]]
local SPECIAL_IDS = InfectedConfig.getSpecialIds()

--[[ The most specials that can physically be alive, summed from each kind's own
     maxAlive. A wave asking for more than the roster allows is asking for a
     number the game cannot produce, so the budget is clamped to it on the way in
     rather than silently starving the special timer every tick. ]]
local SPECIAL_ALIVE_CEILING = 0
for _, id in SPECIAL_IDS do
	local definition = InfectedConfig.get(id)
	if definition then
		SPECIAL_ALIVE_CEILING += definition.maxAlive
	end
end

--[[ The Director may never ask for more Commons than the roster allows alive.
     Wave 7's 1.6x on SustainPeak's 46 asks for 74 against InfectedConfig's
     ceiling of 60, and the difference is pure waste: the queue keeps running
     full placement searches for rigs InfectedService then refuses to build. ]]
local COMMON_CEILING = InfectedConfig.get(Enums.Infected.Common).maxAlive

--[[ The config's special jitter expressed as a FRACTION of its own base
     interval, so a wave that asks for one special every 18s gets the same ±38%
     variation the 26s baseline was tuned with, rather than a flat ±10s that
     would swamp a short interval and barely register on a long one. ]]
local SPECIAL_JITTER_FRACTION = SPECIALS.IntervalJitter / math.max(SPECIALS.BaseInterval, 1e-3)

-- The pressure band. See THE BAND in the header for why these two numbers.
local BAND_PUSH = 1.25
local BAND_BACKOFF = 0.45

--[[ Team health, normalised so that 1 is "the average survivor is as hurt as the
     game's own definition of hurt". Derived rather than invented: below
     HurtThreshold a survivor limps and every infected in the map can hear them. ]]
local HURT_FRACTION = GameConfig.Survivor.HurtThreshold / GameConfig.Survivor.MaxHealth
local HEALTH_STRESS_SPAN = math.max(1 - HURT_FRACTION, 1e-3)

--[[ 8Hz. Pacing decisions happen on the scale of seconds, so anything faster is
     spent CPU with no visible product; anything slower and a batch of seven at
     SustainPeak cannot be spread thinly enough to hide the cost. ]]
local TICK_RATE = 8
local TICK_INTERVAL = 1 / TICK_RATE

--[[ A server hitch must not hand every survivor a second of accumulated
     proximity intensity in one step. ]]
local MAX_TICK_DELTA = 0.5

--[[
	Rigs actually built per tick. At 8Hz this is 16 spawns a second, comfortably
	above the 12.7/s that SustainPeak's batch of 7 every 0.55s asks for, while
	still guaranteeing that no single frame ever pays for more than two rigs.
	This is the whole reason the spawn queue exists.
]]
local MAX_SPAWNS_PER_TICK = 2

--[[ A backlog larger than this means placement is starving, not that the
     Director is behind. Dropping requests is correct: the population deficit is
     recomputed every interval and will simply ask again. ]]
local MAX_QUEUED_SPAWNS = 64

--[[ Cosmetic only. A reused placement point (see VisibilityGracePeriod below)
     would otherwise stack a whole batch into one silhouette for the second
     before their brains pick different paths. The point was already validated
     for ground and clearance, and infected do not collide with each other, so a
     couple of studs of scatter is free. ]]
local SPAWN_SPREAD = 2.5

--[[ Placement failures are reported at most this often. A Director that cannot
     find room says so once every few seconds with a count, rather than turning
     the output window into a wall of identical warnings. ]]
local STARVATION_WARN_INTERVAL = 8

--[[
	Backoff after a failed placement search.

	A team standing in the open with clear sight lines in every direction can
	legitimately have nowhere legal to spawn, and without this the Director would
	re-run a 24-attempt search — up to a hundred raycasts — sixteen times a
	second for as long as they stand there. Nothing is lost by waiting: the
	population deficit is recomputed every interval and asks again.
]]
local PLACEMENT_BACKOFF = 0.35

--[[ How long a boss waits before trying again after a failed placement. A boss
     keeps its flow slot until it is actually standing in the level, so this is
     the difference between "the Tank arrives a second late" and "the Tank runs
     a full placement search eight times a second until the sight lines move". ]]
local BOSS_RETRY_INTERVAL = 1.5

--[[
	The DirectorEvent vocabulary. MusicController and any other presentation
	system must match these strings exactly; nothing else in the game decides
	what music plays.

	  Pacing        every state change, with the new state and the intensity
	  HordeIncoming entering SustainPeak — the horde cue
	  Calm          entering Relax — drop back to ambient
	  Boss          a Tank or a Witch was just placed
	  Special       a special was just placed (a sting, not a track)
	  Panic         a panic event started at a position
]]
local EVENT = table.freeze({
	Pacing = "Pacing",
	HordeIncoming = "HordeIncoming",
	Calm = "Calm",
	Boss = "Boss",
	Special = "Special",
	Panic = "Panic",
})

local SOURCE_POPULATION = "population"
local SOURCE_PANIC = "panic"
local SOURCE_SPECIAL = "special"
local SOURCE_BOSS = "boss"

--[[
	What RoundService hands over on every phase change. Every field is a CEILING
	or a BASELINE the Director works inside, never an order to spawn something.
]]
export type WaveBudget = {
	populationScale: number, -- multiplier on the pacing state's common target
	spawnRateScale: number, -- multiplier on how fast they arrive
	maxSpecialsAlive: number, -- hard cap on live specials, 0 for none
	specialInterval: number, -- seconds between specials during this wave
	waveIndex: number, -- 1-7, or 0 during prep
	isBreather: boolean, -- the calm between two waves
}

--[[ What the Director uses before RoundService says otherwise, and what it falls
     back to field by field when a budget arrives incomplete. These reproduce the
     pre-wave behaviour exactly, so a test place with no RoundService — pressing
     Play on the placeholder map — still gets a working Director. ]]
local DEFAULT_BUDGET: WaveBudget = table.freeze({
	populationScale = 1,
	spawnRateScale = 1,
	maxSpecialsAlive = SPECIALS.MaxAliveTotal,
	specialInterval = SPECIALS.BaseInterval,
	waveIndex = 0,
	isBreather = false,
})

local DirectorService = {}

--[[ (newState: string, oldState: string) ]]
DirectorService.pacingChanged = Signal.new()

local random = Random.new()

--[[
	Spawn option tables, reused. SpawnPlacement.find never retains the table it
	is handed, so mutating these in place is safe and keeps the busiest path in
	the Director allocation-free.
]]
local POPULATION_OPTIONS = {
	minDistance = SPAWNING.MinDistanceFromSurvivor,
	maxDistance = SPAWNING.MaxDistanceFromSurvivor,
	requireOutOfSight = SPAWNING.RequireOutOfSight,
	minFlowAhead = SPAWNING.MinFlowAhead,
	maxFlowAhead = SPAWNING.MaxFlowAhead,
	attempts = SPAWNING.MaxSpawnAttempts,
}

--[[
	The flank window: the same search, inverted, so the group forms BEHIND the
	team instead of ahead of it.

	Being cut off from the way you came is a genuinely different kind of pressure
	from being blocked, and a Director that only ever arrives from in front
	teaches a team to face one way and stop checking. Alternating between the two
	is most of what stops that.
]]
local FLANK_OPTIONS = {
	minDistance = SPAWNING.MinDistanceFromSurvivor,
	maxDistance = SPAWNING.MaxDistanceFromSurvivor,
	requireOutOfSight = SPAWNING.RequireOutOfSight,
	minFlowAhead = -SPAWNING.MaxFlowAhead,
	maxFlowAhead = -SPAWNING.MinDistanceFromSurvivor * 0.5,
	attempts = SPAWNING.MaxSpawnAttempts,
}

local ANCHORED_OPTIONS = {
	minDistance = SPAWNING.MinDistanceFromSurvivor,
	maxDistance = PANIC.SpawnRadius,
	requireOutOfSight = SPAWNING.RequireOutOfSight,
	attempts = SPAWNING.MaxSpawnAttempts,
	anchor = Vector3.zero,
}

--[[
	The round temperament's multiplier for one dimension, or 1 when the layer is
	not up. Looked up per call rather than cached: DirectorTemperament rerolls
	its mood between waves — and mid-wave when the round is Erratic — so a cached
	scalar would quietly freeze the personality in place.
]]
local function temperamentScale(dimension: string): number
	local temperament = Registry.find("DirectorTemperament")
	if not temperament then
		return 1
	end
	if dimension == "population" then
		return temperament:getPopulationScale()
	elseif dimension == "spawnRate" then
		return temperament:getSpawnRateScale()
	elseif dimension == "specialInterval" then
		return temperament:getSpecialIntervalScale()
	end
	return 1
end

local function broadcast(kind: string, payload: any?)
	Remotes.Event.DirectorEvent:FireAllClients({ kind = kind, payload = payload })
end

--[[ Attributes replicate on write, so a value that has not changed is pure
     network cost. Every global the Director owns goes through here. ]]
local function setGameAttribute(name: string, value: any)
	if Workspace:GetAttribute(name) ~= value then
		Workspace:SetAttribute(name, value)
	end
end

local function rollFlowInterval(interval: number, jitter: number): number
	return math.max(1, interval + random:NextNumber(-jitter, jitter))
end

-- ════════════════════════════════════════════════════════════════════════════
--  Lifecycle
-- ════════════════════════════════════════════════════════════════════════════

function DirectorService:init()
	self._trove = Trove.new()

	self._difficulty = DirectorConfig.DefaultDifficulty
	self._profile = DirectorConfig.Difficulty[DirectorConfig.DefaultDifficulty]

	self._state = STATE.Relax
	self._stateEnteredAt = os.clock()
	self._stateIntensity = 0
	self._teamIntensity = 0

	-- Wave state. `_waveMode` latches on the first setWaveBudget and never
	-- clears: it is how the Director knows a RoundService exists at all, and
	-- several campaign-era rules below are wrong the moment one does.
	self._budget = DEFAULT_BUDGET
	self._waveMode = false
	self._active = true

	self._pressure = 1
	self._healthStress = 0
	self._intensityStress = 0

	self._intensity = {} :: { [Player]: number }
	self._survivors = {} :: { Player }
	self._characters = {} :: { Model }
	self._positions = {} :: { Vector3 }
	self._nearby = {} :: { number }

	self._queue = {}
	self._queueHead = 1
	self._queueTail = 0
	self._dropped = 0

	-- A placement is expensive and a batch arriving from one doorway reads far
	-- better than a batch scattered around the room, so the last good point is
	-- reused for VisibilityGracePeriod seconds — which is precisely what that
	-- config field describes: newly spawned infected ignore the sight rule for a
	-- moment after a point has been cleared.
	self._placement = nil

	self._nextPopulationAt = 0
	self._lastSpecialAt = 0
	self._specialRoll = SPECIALS.BaseInterval
	self._specialsSpawned = 0

	self._nextTankFlow = rollFlowInterval(BOSSES.TankFlowInterval, BOSSES.TankFlowJitter)
	self._nextWitchFlow = rollFlowInterval(BOSSES.WitchFlowInterval, BOSSES.WitchFlowJitter)
	self._bossRetryAt = 0
	self._placementBackoffUntil = 0

	self._panic = {
		active = false,
		position = Vector3.zero,
		wavesLeft = 0,
		nextWaveAt = 0,
		endsAt = 0,
	}

	self._starved = 0
	self._starvedReason = ""
	self._starvedWarnedAt = -math.huge

	self._accumulator = 0
end

--[[ One line per stuck spot per round, keyed to a coarse grid cell. A node a
     body cannot leave produces a report every time the Director uses it, and a
     warning that repeats every half-minute is a warning nobody reads. ]]
--[[ How close a reaped body has to be to a spawn node before that node is what
     gets blamed. Wider than a body and narrower than a room: a body reaped well
     away from every node walked there under its own power. ]]
local NODE_BLAME_RADIUS = 40

--[[
	The two ends of "how far did it get", in studs of displacement.

	A Common walks nine studs a second and the maroon window is twenty-five, so a
	body free to move covers well over two hundred. Below CONFINED it never left
	the space it appeared in; above TRAVELLED it plainly went somewhere and then
	stopped. The gap between them is where the answer is genuinely ambiguous, and
	the report says so rather than picking one.
]]
local DRIFT_CONFINED = 24
local DRIFT_TRAVELLED = 90

local warned: { [string]: boolean } = {}

local function warnOnce(key: string, message: string)
	if warned[key] then
		return
	end
	warned[key] = true
	warn("[DirectorService] " .. message)
end

--[[
	The spawn node nearest a point, by NAME, or nil.

	Coordinates are true and nearly useless: finding "(-132, 52, 259)" in Studio
	means eyeballing the 3D view, while a name is something you can type into the
	Explorer's search box and be looking at in a second. The Director already
	knows every node — it spawns at them — so the report may as well say which
	one rather than making a person work it out.
]]
local function nearestNodeName(position: Vector3): string?
	local level = Registry.find("LevelService")
	if not level or typeof(level.getSpawnNodes) ~= "function" then
		return nil
	end
	local ok, nodes = pcall(level.getSpawnNodes, level)
	if not ok or typeof(nodes) ~= "table" then
		return nil
	end

	local best, bestSquared = nil, math.huge
	for _, node in nodes :: { BasePart } do
		if node and node.Parent then
			local squared = (node.Position - position).Magnitude ^ 2
			if squared < bestSquared then
				best, bestSquared = node, squared
			end
		end
	end
	--[[ Only when it is actually near. A body reaped a hundred studs from every
	     node walked there and got stuck on scenery, and naming the closest node
	     would send somebody to inspect a node that is fine. ]]
	if best and bestSquared <= NODE_BLAME_RADIUS * NODE_BLAME_RADIUS then
		return best.Name
	end
	return nil
end

function DirectorService:start()
	--[[
		A body that gets stuck is still worth hearing about.

		InfectedService says so when a common it placed has spent half a minute
		unable to close a single stud on anybody, and `fromSpawn` distinguishes
		"never went anywhere at all" from "chased, fell behind, gave up". The
		first one means a spawn node is somewhere a body cannot leave, and the
		only thing that can fix that is a person moving the node — so it is
		reported rather than worked around.

		This used to condemn the offending cell of a learned field. There is no
		field any more: the Director spawns at the level's tagged nodes, and
		silently retiring one a designer placed would hide exactly the problem
		they need to see.
	]]
	local infected = Registry.find("InfectedService")
	if infected and infected.marooned then
		self._trove:add(
			infected.marooned:connect(
				function(position: Vector3, fromSpawn: boolean, spawnedAt: Vector3?, window: number?)
					if not fromSpawn then
						return
					end

					--[[
					Blamed at the SPAWN point, reported from both, and honest about
					the middle.

					This looks for a node near where the body was PUT rather than
					where it was reaped: a body that never closed ground on the team
					can still have wandered sideways, and searching near the reaped
					position finds nothing and concludes, wrongly, that the body
					walked there on its own.

					How far it got is the diagnosis, but only at the ends of the
					range. A Common walks nine studs a second and the window is
					twenty-five, so a body free to move covers well over two
					hundred: barely moving means an enclosure, and going a long way
					means the node was fine and the route was not.

					In between it genuinely could be either a small courtyard or an
					early wedge just outside one. The first version of this said
					"the node is probably fine" about a body that managed
					twenty-six studs in twenty-five seconds, which is a coin flip
					dressed as a conclusion — "go and look" is worth more.
				]]
					local origin = spawnedAt or position
					local node = nearestNodeName(origin)
					local drifted = math.floor((position - origin).Magnitude)
					local seconds = math.floor(window or 0)

					local verdict
					if drifted < DRIFT_CONFINED then
						verdict = "It barely moved, so it is walled in where it appeared — check the "
							.. "node for a roof, a fence, or a sealed courtyard."
					elseif drifted < DRIFT_TRAVELLED then
						verdict = "That is not far enough to have gone anywhere and not near enough to "
							.. "be obviously walled in — either a small enclosure, or a wedge just "
							.. "outside one. Stand at the node in Studio and look for the way out."
					else
						verdict = "It travelled, so the node is probably fine and something on the "
							.. "route between there and the team is not."
					end

					warnOnce(
						string.format(
							"stuck:%s",
							node or string.format("%d:%d", origin.X // 16, origin.Z // 16)
						),
						if node
							then string.format(
								"bodies from the FL_SpawnNode named %q are not reaching the team. "
									.. "Spawned at (%d, %d, %d) and reaped %d stud(s) away after %ds "
									.. "without closing any ground on anybody. %s",
								node,
								origin.X,
								origin.Y,
								origin.Z,
								drifted,
								seconds,
								verdict
							)
							else string.format(
								"a body spawned near (%d, %d, %d) never closed any ground on the team "
									.. "in %ds, and no spawn node is within %d studs of where it "
									.. "started — so it was placed by the ring fallback rather than at "
									.. "a node, which means the map wants more FL_SpawnNode parts near "
									.. "the route.",
								origin.X,
								origin.Y,
								origin.Z,
								seconds,
								NODE_BLAME_RADIUS
							)
					)
				end
			)
		)
	end

	local now = os.clock()
	self._stateEnteredAt = now
	self._lastSpecialAt = now
	self._specialRoll = self:_rollSpecialInterval()
	self._nextPopulationAt = now

	local survivors = Registry.find("SurvivorService")
	if survivors then
		-- Incaps and pins are one-shot spikes rather than per-second pressure:
		-- the sustained part of being held is already paid for by the damage the
		-- attacker deals and by the crowd it draws, and stacking a per-second
		-- weight on top would pin the Director at peak for the whole rescue —
		-- exactly when it should be backing off so the rescue can happen.
		if survivors.stateChanged then
			self._trove:add(survivors.stateChanged:connect(function(player, newState)
				if newState == Enums.SurvivorState.Incapacitated then
					self:addIntensity(player, INTENSITY.IncapWeight)
				elseif newState == Enums.SurvivorState.Pinned then
					self:addIntensity(player, INTENSITY.PinnedWeight)
				elseif newState == Enums.SurvivorState.Dead or newState == Enums.SurvivorState.Spectating then
					self._intensity[player] = nil
				end
			end))
		end
	else
		warn("[DirectorService] SurvivorService is not registered; intensity will only read proximity")
	end

	self._trove:connect(Players.PlayerRemoving, function(player)
		self._intensity[player] = nil
	end)

	self:_publish()

	-- THE loop. One connection for the entire Director.
	self._trove:connect(RunService.Heartbeat, function(delta)
		self._accumulator += delta
		if self._accumulator < TICK_INTERVAL then
			return
		end
		local step = math.min(self._accumulator, MAX_TICK_DELTA)
		self._accumulator = 0
		self:_tick(step, os.clock())
	end)
end

function DirectorService:destroy()
	self._trove:destroy()
end

-- ════════════════════════════════════════════════════════════════════════════
--  Tick
-- ════════════════════════════════════════════════════════════════════════════

function DirectorService:_tick(dt: number, now: number)
	self:_refreshSurvivors()
	self:_updateIntensity(dt)
	self:_updatePressure()
	self:_updatePacing(now)

	--[[ The personality layer ticks first so every decision below this line sees
	     the same mood. Erratic rerolls itself here; everything else is a no-op. ]]
	local temperament = Registry.find("DirectorTemperament")
	if temperament then
		temperament:update()
		temperament:updateSkill(#self._characters)
	end

	if self:_isPlaying() then
		self:_updatePopulation(now)
		self:_updateSpecials(now)
		self:_updateBosses(now)
		self:_updatePanic(now)
		self:_drainQueue(now)
	end

	self:_publish()
	self:_reportStarvation(now)
end

--[[ The Director runs whenever there is somebody left to press and RoundService
     has not switched it off for prep or a scoreboard. The RoundState check stays
     as a backstop: a wipe must silence the horde even if nothing calls
     setActive, because a Director spawning over a dead team is unwatchable. ]]
function DirectorService:_isPlaying(): boolean
	if not self._active or #self._survivors == 0 then
		return false
	end
	local round = Attributes.get(Workspace, Attributes.Game.RoundState, Enums.RoundState.InProgress)
	return round ~= Enums.RoundState.TeamWipe and round ~= Enums.RoundState.Victory
end

function DirectorService:_refreshSurvivors()
	local service = Registry.find("SurvivorService")
	if not service then
		table.clear(self._survivors)
		table.clear(self._characters)
		return
	end
	self._survivors = service:getAliveSurvivors()
	self._characters = service:getSurvivorCharacters()
end

-- ════════════════════════════════════════════════════════════════════════════
--  Wave budget
--
--  RoundService owns the schedule; this is where it hands over. Everything
--  arriving here is treated as untrusted input even though it comes from
--  another server module: the two systems are built in parallel, and a Director
--  that throws on a missing field takes the whole round down with it.
-- ════════════════════════════════════════════════════════════════════════════

--[[ A finite number at or above `floor`, or the fallback. NaN is checked
     explicitly: it is the one value that survives every comparison below and
     would then poison every multiplication for the rest of the round. ]]
local function positive(value: any, fallback: number, floor: number): number
	if typeof(value) ~= "number" or value ~= value or value == math.huge then
		return fallback
	end
	return math.max(value, floor)
end

--[[
	Installs the budget for the phase RoundService just entered.

	Called on EVERY phase change — prep, each wave start, each breather. The
	Director keeps whatever it already had for any field that arrives malformed,
	so a partially-built RoundService degrades to the previous phase's pacing
	rather than to no pacing at all.

	Neither scale needs an upper clamp: the common target is clamped to the
	roster's own ceiling and the spawn interval is floored at the tick rate, so
	an absurd number produces a saturated Director rather than a broken one.
]]
--[[ RoundService calls this on every phase change, which makes it the natural
     place to reroll the per-wave mood: a new wave gets a new lean, and the
     breather that precedes it does not. ]]
function DirectorService:setWaveBudget(budget: WaveBudget?)
	-- The Director inits late in the boot order. A neighbour that announces a
	-- phase from its own init() must not take that init down with a nil index.
	if not self._budget then
		warn("[DirectorService] setWaveBudget before init(); call it from start() or later")
		return
	end
	if typeof(budget) ~= "table" then
		warn("[DirectorService] setWaveBudget expects a table; keeping the current budget")
		return
	end

	local previous = self._budget
	local isBreather = budget.isBreather == true
	local waveIndex = math.floor(positive(budget.waveIndex, previous.waveIndex, 0))

	self._budget = {
		populationScale = positive(budget.populationScale, previous.populationScale, 0),
		spawnRateScale = positive(budget.spawnRateScale, previous.spawnRateScale, 1e-3),
		maxSpecialsAlive = math.min(
			math.floor(positive(budget.maxSpecialsAlive, previous.maxSpecialsAlive, 0)),
			SPECIAL_ALIVE_CEILING
		),
		specialInterval = positive(budget.specialInterval, previous.specialInterval, 0),
		waveIndex = waveIndex,
		isBreather = isBreather,
	}
	self._waveMode = true

	--[[
		The phase boundary owns the pacing state; the intensity machine owns
		everything between two boundaries.

		Entering a breather drops straight to Relax so the horde and the music go
		quiet on the same frame — the calm is the entire reason the next wave
		lands, and a Relax state announced thirty seconds into it is a calm
		nobody got. Entering a wave starts at BuildUp so a wave never opens
		against Relax's 22-second minimum dwell, which on wave 1 would be a
		quarter of the wave spent at a target of four bodies.
	]]
	if isBreather then
		self:_setState(STATE.Relax)
		-- A special enqueued a moment before the horn is still a special landing
		-- during the calm. Population is dropped by _setState; this is the rest.
		self:_dropQueued(SOURCE_SPECIAL)
	elseif previous.isBreather or waveIndex ~= previous.waveIndex then
		self:_setState(STATE.BuildUp)
	end

	-- _setState only does this when the state actually moved, and a budget change
	-- inside the same state still invalidates every request sized for the old one.
	self:_dropQueued(SOURCE_POPULATION)
	self._nextPopulationAt = os.clock()
end

--[[ A copy, never the live table: a caller that mutated this would be changing
     the Director's ceiling from outside with nothing to say it had happened. ]]
function DirectorService:getWaveBudget(): WaveBudget
	return table.clone(self._budget)
end

--[[
	Switches spawning on and off wholesale. Prep, the post-round scoreboard and
	the lobby are all "the Director is not playing"; a breather is NOT — that is
	a budget, because the Director still trickles a handful of stragglers through
	it and still reads the team.

	Intensity, pacing and the published attributes keep running while inactive:
	the HUD and the music are still on screen during a scoreboard, and a frozen
	TeamIntensity is worse than a decaying one.
]]
function DirectorService:setActive(active: boolean)
	if self._panic == nil then
		warn("[DirectorService] setActive before init(); call it from start() or later")
		return
	end
	local wanted = active == true
	if self._active == wanted then
		return
	end
	self._active = wanted

	if not wanted then
		-- Everything queued belongs to a phase that no longer exists.
		self:_clearQueue()
		self._panic.active = false
		self:_setState(STATE.Relax)
	elseif self._state == STATE.Relax then
		-- Coming back live out of a Relax the machine cannot leave for another 22
		-- seconds would spend the top of a wave at a target of four.
		self:_setState(STATE.BuildUp)
	end
end

function DirectorService:isActive(): boolean
	return self._active
end

-- ════════════════════════════════════════════════════════════════════════════
--  Intensity
-- ════════════════════════════════════════════════════════════════════════════

--[[
	Adds to (or removes from) one survivor's intensity.

	Callers pass an ALREADY WEIGHTED amount — DamageService multiplies damage by
	DamageTakenWeight itself, and passes -KillRelief on a kill — so this stays a
	single, honest accumulator with one clamp and no opinions of its own.
]]
--[[ The slow skill read is fed from the same events that drive intensity, so it
     costs no new listeners. Damage and kills arrive here already. ]]
function DirectorService:_feedSkill(amount: number)
	local temperament = Registry.find("DirectorTemperament")
	if not temperament then
		return
	end
	if amount > 0 then
		temperament:recordDamage(amount / math.max(INTENSITY.DamageTakenWeight, 1e-6))
	else
		temperament:recordKill()
	end
end

function DirectorService:addIntensity(player: Player, amount: number)
	self:_feedSkill(amount)
	-- The Director inits last in the boot order; a neighbour that reports damage
	-- from its own init() must not take that init down with a nil index.
	if not self._intensity then
		return
	end
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return
	end
	if typeof(amount) ~= "number" or amount ~= amount then
		return
	end
	self._intensity[player] = math.clamp((self._intensity[player] or 0) + amount, 0, 1)
end

function DirectorService:getIntensity(player: Player): number
	return self._intensity[player] or 0
end

function DirectorService:getTeamIntensity(): number
	return self._teamIntensity
end

function DirectorService:_updateIntensity(dt: number)
	local survivors = self._survivors
	local count = #survivors
	local positions = self._positions
	local nearby = self._nearby

	table.clear(positions)
	table.clear(nearby)
	for index = 1, count do
		local character = survivors[index].Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root then
			positions[index] = root.Position
		end
		nearby[index] = 0
	end

	-- One pass over the horde, an inner loop over at most four survivors — the
	-- opposite order costs a FindFirstChild per zombie per survivor.
	local infected = Registry.find("InfectedService")
	if infected and count > 0 then
		local radiusSquared = INTENSITY.ProximityRadius * INTENSITY.ProximityRadius
		for _, model in infected:getAlive() do
			local part = model.PrimaryPart
			if not part then
				continue
			end
			local position = part.Position
			for index = 1, count do
				local target = positions[index]
				if target then
					local delta = position - target
					if delta:Dot(delta) <= radiusSquared then
						nearby[index] += 1
					end
				end
			end
		end
	end

	local decay = INTENSITY.DecayPerSecond * dt
	local proximityStep = INTENSITY.ProximityWeight * dt
	local lowHealthStep = INTENSITY.LowHealthWeight * dt
	local hurtThreshold = GameConfig.Survivor.HurtThreshold

	local peak = 0
	for index = 1, count do
		local player = survivors[index]
		local value = (self._intensity[player] or 0) - decay + proximityStep * nearby[index]

		local effective = Attributes.get(player, Attributes.Player.Health, 0)
			+ Attributes.get(player, Attributes.Player.TempHealth, 0)
		if effective < hurtThreshold then
			value += lowHealthStep
		end

		value = math.clamp(value, 0, 1)
		self._intensity[player] = value
		if value > peak then
			peak = value
		end
	end

	-- The team's PEAK, not its average. Pacing follows whoever is having the
	-- worst time; averaging is how a Director ends up ignoring the one player
	-- being eaten because the other three are standing in a safe room.
	self._teamIntensity = peak
end

--[[ SurvivorService's 0-1 read on the team, or 1 when it cannot answer. Failing
     OPTIMISTIC is deliberate: a Director that reads a missing service as "this
     team is dying" would quietly halve every horde in the game. ]]
function DirectorService:_teamHealthFraction(): number
	local survivors = Registry.find("SurvivorService")
	if not survivors or typeof(survivors.getTeamHealthFraction) ~= "function" then
		return 1
	end
	local ok, fraction = pcall(survivors.getTeamHealthFraction, survivors)
	if not ok or typeof(fraction) ~= "number" or fraction ~= fraction then
		return 1
	end
	return math.clamp(fraction, 0, 1)
end

--[[
	The band. See THE BAND in the header for the numbers and the reasoning.

	Two independent reads of "this team is in trouble", each normalised to 1 at
	the config's own line for it, and the Director follows whichever is worse.
	Kept as separate fields rather than folded immediately into one scalar
	because the special gate below needs the health read on its own.
]]
function DirectorService:_updatePressure()
	self._healthStress = math.clamp((1 - self:_teamHealthFraction()) / HEALTH_STRESS_SPAN, 0, 1)
	self._intensityStress = math.clamp(self._teamIntensity / math.max(INTENSITY.PeakThreshold, 1e-3), 0, 1)

	local stress = math.max(self._healthStress, self._intensityStress)
	self._pressure = BAND_PUSH + (BAND_BACKOFF - BAND_PUSH) * stress
end

--[[ Where inside the wave's band the Director currently sits. 1 is the wave's
     own baseline. Exposed for the debug overlay and for tests. ]]
function DirectorService:getPressure(): number
	return self._pressure
end

-- ════════════════════════════════════════════════════════════════════════════
--  Pacing
-- ════════════════════════════════════════════════════════════════════════════

function DirectorService:getPacingState(): string
	return self._state
end

--[[ Debug only. Skips every dwell rule, which is exactly what makes it useful
     for testing a horde and exactly what makes it wrong to call in gameplay. ]]
function DirectorService:forceState(state: string)
	if STATE[state] == nil then
		warn(string.format("[DirectorService] forceState(%q): not a pacing state", tostring(state)))
		return
	end
	self:_setState(state)
end

function DirectorService:_setState(newState: string)
	local previous = self._state
	if newState == previous then
		return
	end

	local now = os.clock()
	self._state = newState
	self._stateEnteredAt = now
	self._stateIntensity = self._teamIntensity

	-- The new state's spawnInterval applies immediately; inheriting the old
	-- state's countdown is how a horde ends up arriving during the lull.
	self._nextPopulationAt = now
	-- Population requests queued for the state we just left are stale. Panic,
	-- special and boss requests survive: they are events, not population.
	self:_dropQueued(SOURCE_POPULATION)

	setGameAttribute(Attributes.Game.PacingState, newState)
	self.pacingChanged:fire(newState, previous)
	broadcast(EVENT.Pacing, {
		state = newState,
		previous = previous,
		intensity = self._teamIntensity,
		-- Where inside the wave's band this state is being played. A music mix
		-- that reads only the state cannot tell a SustainPeak the Director is
		-- leaning into from one it is already backing out of.
		pressure = self._pressure,
		wave = self._budget.waveIndex,
		breather = self._budget.isBreather,
	})

	if newState == STATE.SustainPeak then
		broadcast(EVENT.HordeIncoming, { intensity = self._teamIntensity })
	elseif newState == STATE.Relax then
		broadcast(EVENT.Calm, nil)
	end
end

--[[
	The state machine.

	Minimums stop flicker, maximums stop a stall, and the intensity thresholds do
	everything in between. The one rule that overrides a minimum is crossing
	PeakThreshold: that is not flicker, that is the team being genuinely
	overwhelmed, and the Director owes them an acknowledgement of it.
]]
function DirectorService:_updatePacing(now: number)
	local state = self._state
	local intensity = self._teamIntensity

	if intensity >= INTENSITY.PeakThreshold and state ~= STATE.SustainPeak then
		self:_setState(STATE.SustainPeak)
		return
	end

	local window = PACING[state]
	if not window then
		return
	end
	local elapsed = now - self._stateEnteredAt
	if elapsed < window.min then
		return
	end

	if state == STATE.Relax then
		-- Relax ends when the team has actually recovered, or when they have had
		-- as long as anyone gets to stand still.
		if intensity <= INTENSITY.RelaxThreshold or elapsed >= window.max then
			self:_setState(STATE.BuildUp)
		end
	elseif state == STATE.BuildUp then
		-- Rising intensity promotes this through the PeakThreshold check above;
		-- the maximum is here for the team that clears everything instantly and
		-- would otherwise trickle forever.
		if elapsed >= window.max then
			self:_setState(STATE.SustainPeak)
		end
	elseif state == STATE.SustainPeak then
		if intensity < INTENSITY.PeakThreshold or elapsed >= window.max then
			self:_setState(STATE.PeakFade)
		end
	elseif state == STATE.PeakFade then
		if intensity < INTENSITY.RelaxThreshold then
			self:_setState(STATE.Relax)
		elseif elapsed >= window.max and intensity >= self._stateIntensity then
			-- The maximum does NOT force a lull. PeakFade only ends into Relax
			-- once intensity is genuinely under RelaxThreshold; the alternative
			-- is a "calm" state announced over a team still being chewed on.
			-- What the maximum catches is a fade that is not fading — intensity
			-- no lower than when the fade began — which means the fight never
			-- actually ended and the honest answer is to build back up.
			self:_setState(STATE.BuildUp)
		end
	end
end

-- ════════════════════════════════════════════════════════════════════════════
--  Population
-- ════════════════════════════════════════════════════════════════════════════

--[[
	The population plan in force.

	A breather borrows the Relax plan VERBATIM, ignoring the wave's scales
	entirely, so the calm between wave 6 and wave 7 is the same calm as the one
	after wave 1. That consistency is the point: a breather that scales with the
	wave it follows gets quieter and quieter in relative terms right when the
	team most needs to recognise it as their moment to heal and reload.
]]
function DirectorService:_plan()
	if self._budget.isBreather then
		return POPULATION[STATE.Relax]
	end
	return POPULATION[self._state]
end

function DirectorService:_populationTarget(): number
	local plan = self:_plan()
	if not plan then
		return 0
	end
	local scale = self._profile.populationScale * self._pressure
	if not self._budget.isBreather then
		scale *= self._budget.populationScale
	end
	--[[ The round's temperament and the slow skill read lean the number inside
	     the wave's ceiling. Applied last and still clamped, so no personality can
	     push the horde past what the wave allows — the lean is in where you sit
	     inside the budget, never in the budget itself. ]]
	scale *= temperamentScale("population")
	return math.clamp(math.floor(plan.target * scale + 0.5), 0, COMMON_CEILING)
end

--[[ Seconds between batches. The same pressure scalar that thins the horde
     stretches the gaps between what is left of it, so backing off is felt twice
     — floored at the tick rate, below which an interval means nothing. ]]
function DirectorService:_spawnInterval(plan): number
	local rate = self._pressure
	if not self._budget.isBreather then
		rate *= self._budget.spawnRateScale
	end
	rate *= temperamentScale("spawnRate")
	return math.max(plan.spawnInterval / math.max(rate, 1e-3), TICK_INTERVAL)
end

function DirectorService:_updatePopulation(now: number)
	local plan = self:_plan()
	if not plan or now < self._nextPopulationAt then
		return
	end
	self._nextPopulationAt = now + self:_spawnInterval(plan)

	local infected = Registry.find("InfectedService")
	if not infected then
		return
	end

	-- Only commons count against the population target. Specials and bosses have
	-- their own budgets and must never squeeze the horde out of the room.
	local alive = infected:getCount(Enums.Infected.Common)
	local deficit = self:_populationTarget() - alive - self:_queuedCount(SOURCE_POPULATION)
	if deficit <= 0 then
		return
	end

	--[[ Burstiness reshapes the batch without changing the target: a Patient
	     Director holds several batches back and sends them as one wall, a
	     Relentless one sends a thinner stream that never stops. Same total
	     population either way, and the difference between them is most of what
	     separates "busy" from "frightening". ]]
	local temperament = Registry.find("DirectorTemperament")
	local batch = plan.batchSize
	local flank = false
	if temperament then
		batch = math.max(1, math.floor(batch * temperament:getBurstScale() + 0.5))
		--[[ Decided ONCE for the whole batch. A batch split between in front and
		     behind is not a pincer, it is noise — the point of a flank is that
		     the whole group comes from somewhere the team was not watching. ]]
		flank = temperament:shouldFlank()
	end

	for _ = 1, math.min(batch, deficit) do
		self:_enqueue(SOURCE_POPULATION, Enums.Infected.Common, nil, nil, flank)
	end
end

-- ════════════════════════════════════════════════════════════════════════════
--  Specials
-- ════════════════════════════════════════════════════════════════════════════

--[[ The wave names the interval; the config still owns how much it wanders. ]]
function DirectorService:_rollSpecialInterval(): number
	local base = self._budget.specialInterval * temperamentScale("specialInterval")
	return math.max(1, base + random:NextNumber(-1, 1) * base * SPECIAL_JITTER_FRACTION)
end

--[[ Pacing scales the WAIT, not the roll, so a state change is felt immediately
     rather than at the next reroll: drop into Relax mid-countdown and the next
     special is pushed out, climb into a peak and it arrives sooner. Pressure
     rides on top of that — the same scalar that thins the horde stretches the
     wait, so at the bottom of the band wave 5's 24s becomes 53s. ]]
function DirectorService:_specialIntervalMultiplier(): number
	local multiplier = self._profile.specialInterval
	if self._state == STATE.Relax then
		multiplier *= SPECIALS.RelaxMultiplier
	elseif self._state == STATE.SustainPeak then
		multiplier *= SPECIALS.PeakMultiplier
	end
	return multiplier / math.max(self._pressure, 1e-3)
end

--[[
	Whether a NEW special may be requested at all.

	Health is a hard gate and intensity is only a soft one, and the asymmetry is
	about what each signal actually measures.

	Intensity is a few-seconds read dominated by ProximityWeight: 0.020/s per
	infected inside 30 studs against a 0.055/s decay, so any survivor with three
	or more bodies on them saturates at 1.0 and STAYS there for as long as the
	horde is in contact — which during waves 5-7 is most of the wave, by design.
	Hanging a binary "no specials" on that would mean the maxSpecialsAlive budget
	those waves are built around never spends at all. So intensity buys relief
	continuously instead, through the band: fewer commons, longer gaps, and a
	special wait stretched by the same factor.

	Team health does not saturate — it only falls when the team is genuinely
	losing — so it is the signal that gets to stop specials outright. A team
	averaging the game's own hurt threshold is not sent one more thing.

	The timer keeps running while suppressed, because _updateSpecials only
	charges _lastSpecialAt on a successful request. Clawing your way back over
	the threshold and immediately hearing a Hunter is the correct beat.
]]
function DirectorService:_specialsAllowed(): boolean
	if self._budget.isBreather or self._budget.maxSpecialsAlive <= 0 then
		return false
	end
	return self._healthStress < 1
end

function DirectorService:_aliveSpecials(): number
	local infected = Registry.find("InfectedService")
	if not infected then
		return 0
	end
	local total = 0
	for _, id in SPECIAL_IDS do
		total += infected:getCount(id)
	end
	return total
end

--[[
	Picks a special, weighted by the inverse of its spawnCost: the config already
	says what each one is worth, so a Charger at 28 turns up less often than a
	Jockey at 22 without a second table of weights to keep in agreement with the
	first.
]]
function DirectorService:_pickSpecial(): string?
	local infected = Registry.find("InfectedService")

	local total = 0
	local weights = {}
	for _, id in SPECIAL_IDS do
		local definition = InfectedConfig.get(id)
		if not definition then
			continue
		end
		if infected and infected:getCount(id) >= definition.maxAlive then
			continue
		end
		local weight = 1 / math.max(definition.spawnCost, 1)
		total += weight
		table.insert(weights, { id = id, weight = weight })
	end
	if total <= 0 then
		return nil
	end

	local roll = random:NextNumber() * total
	for _, entry in weights do
		roll -= entry.weight
		if roll <= 0 then
			return entry.id
		end
	end
	return weights[#weights].id
end

function DirectorService:_updateSpecials(now: number)
	if not self:_specialsAllowed() then
		return
	end

	local sinceLast = now - self._lastSpecialAt
	if sinceLast < SPECIALS.MinIntervalBetweenAny then
		return
	end
	if sinceLast < self._specialRoll * self:_specialIntervalMultiplier() then
		return
	end
	if self:_aliveSpecials() >= self._budget.maxSpecialsAlive then
		return
	end
	--[[ MinFlowBeforeFirst is a campaign rule — it stops a special landing in the
	     first corridor of a map. In wave mode the schedule already owns that
	     (wave 1 asks for zero specials), and an arena with no FlowNodes reports a
	     flow of 0 forever, which would silence specials for the entire round. ]]
	if
		not self._waveMode
		and self._specialsSpawned == 0
		and self:_survivorFlow() < SPECIALS.MinFlowBeforeFirst
	then
		return
	end

	local kind = self:_pickSpecial()
	if not kind then
		return
	end
	if self:_enqueue(SOURCE_SPECIAL, kind, nil, nil) then
		-- Charged at the request, not at the rig: a special that cannot be
		-- placed still costs its slot, otherwise a starved placement search
		-- turns into three specials arriving the instant one gets through.
		self._lastSpecialAt = now
		self._specialRoll = self:_rollSpecialInterval()

		--[[ Coordinated pairs. One special at a time is answerable by one
		     survivor turning around; two at once forces the team to split its
		     attention, which is the difference between an inconvenience and a
		     genuine problem. Still bounded by maxSpecialsAlive, so a pair can
		     never exceed what the wave allowed — it only spends the budget in
		     one moment instead of two. ]]
		local temperament = Registry.find("DirectorTemperament")
		if temperament and temperament:shouldPairSpecials() then
			if self:_aliveSpecials() + 1 < self._budget.maxSpecialsAlive then
				local partner = self:_pickSpecial()
				if partner then
					self:_enqueue(SOURCE_SPECIAL, partner, nil, nil)
				end
			end
		end
	end
end

-- ════════════════════════════════════════════════════════════════════════════
--  Bosses
--
--  In WAVE MODE, RoundService releases them: wave 4 is a Tank, wave 5 a Witch,
--  wave 7 two Tanks, and it calls releaseBoss at the top of each. The flow
--  scheduler below is the campaign model and is switched off the moment a wave
--  budget arrives — a Tank that shows up twice, once on schedule and once by
--  flow, is the worst possible bug to ship.
--
--  What does NOT change is HOW one is placed. A boss goes through exactly the
--  same SpawnPlacement rules as a Common — the distance band, every survivor's
--  view cone, a line-of-sight ray, ground and headroom — with an FL_BossZone
--  preferred when the map offers one. A Tank materialising inside somebody's
--  field of view destroys the illusion for the rest of the round; a Tank
--  arriving four seconds late destroys nothing at all.
-- ════════════════════════════════════════════════════════════════════════════

function DirectorService:_survivorFlow(): number
	local level = Registry.find("LevelService")
	if not level or typeof(level.getSurvivorFlow) ~= "function" then
		return 0
	end
	local ok, flow = pcall(level.getSurvivorFlow, level)
	if ok and typeof(flow) == "number" then
		return flow
	end
	return 0
end

--[[ The next FL_BossZone the team has not passed yet, so a Tank arrives in the
     arena the level designer built for it rather than in the corridor before
     it. Returns nil when the map has no zones; placement then falls back to the
     ordinary spawn rules, which is still a legal Tank. ]]
function DirectorService:_pickBossZone(teamFlow: number): BasePart?
	local level = Registry.find("LevelService")
	local canFlow = level ~= nil and typeof(level.getFlowDistance) == "function"

	local best: BasePart? = nil
	local bestScore = math.huge
	for _, zone in CollectionService:GetTagged("FL_BossZone") do
		if not zone:IsA("BasePart") or not zone:IsDescendantOf(Workspace) then
			continue
		end
		local score
		if canFlow then
			local ok, flow = pcall(level.getFlowDistance, level, zone.Position)
			if not ok or typeof(flow) ~= "number" then
				continue
			end
			-- Ahead of the team wins; behind them is a fallback, ranked worse
			-- the further back it is.
			local ahead = flow - teamFlow
			score = if ahead >= 0 then ahead else math.abs(ahead) * 4
		else
			score = random:NextNumber()
		end
		if score < bestScore then
			bestScore = score
			best = zone
		end
	end
	return best
end

function DirectorService:_updateBosses(now: number)
	-- RoundService owns boss releases as soon as one exists. See the section
	-- header: two schedulers for one Tank is two Tanks.
	if self._waveMode then
		return
	end

	local flow = self:_survivorFlow()
	if flow <= 0 then
		return
	end

	local infected = Registry.find("InfectedService")
	if not infected then
		return
	end

	-- One boss request in flight at a time, and a breather after a failed
	-- placement so a Tank that currently has nowhere to stand does not re-run
	-- the search every single tick.
	if self:_queuedCount(SOURCE_BOSS) > 0 or now < self._bossRetryAt then
		return
	end

	if flow >= self._nextTankFlow then
		-- A Tank on a team of one is not a set piece, it is an execution, and a
		-- second Tank on top of the first is not either. An opportunity the team
		-- is in no state to receive is PASSED, not held: holding it means the
		-- Tank arrives the instant somebody finishes a revive, which is the
		-- cheapest beat in the game.
		if
			#self._survivors >= BOSSES.MinSurvivorsAliveForTank
			and infected:getCount(Enums.Infected.Tank) == 0
		then
			self:_enqueueBoss(Enums.Infected.Tank, flow)
			return
		end
		self:_rerollBossFlow(Enums.Infected.Tank)
	end

	if flow >= self._nextWitchFlow then
		if infected:getCount(Enums.Infected.Witch) == 0 then
			self:_enqueueBoss(Enums.Infected.Witch, flow)
		else
			self:_rerollBossFlow(Enums.Infected.Witch)
		end
	end
end

--[[
	Rolls the next opportunity for a boss that has just been placed.

	Measured from where the team is standing NOW rather than added to the old
	threshold: a team that skipped a long stretch of map — a lift, a fall, a
	checkpoint — would otherwise burn several Tank opportunities in one second
	and then walk half a level with nothing behind them.
]]
function DirectorService:_rerollBossFlow(kind: string)
	local flow = self:_survivorFlow()
	if kind == Enums.Infected.Tank then
		self._nextTankFlow = flow + rollFlowInterval(BOSSES.TankFlowInterval, BOSSES.TankFlowJitter)
	elseif kind == Enums.Infected.Witch then
		self._nextWitchFlow = flow + rollFlowInterval(BOSSES.WitchFlowInterval, BOSSES.WitchFlowJitter)
	end
end

--[[ Where a boss search should be centred: the best FL_BossZone if the map has
     one, otherwise nothing, which leaves the ordinary team-relative rules — and
     that is still a perfectly legal Tank. ]]
function DirectorService:_bossAnchor(flow: number): (Vector3?, number?)
	local zone = self:_pickBossZone(flow)
	if not zone then
		return nil, nil
	end
	-- The zone's own footprint is the radius, floored at the minimum spawn
	-- distance so the sampler always has a legal ring to draw from.
	local extent = math.max(zone.Size.X, zone.Size.Z) * 0.5
	return zone.Position, math.max(extent, SPAWNING.MinDistanceFromSurvivor)
end

function DirectorService:_enqueueBoss(kind: string, flow: number)
	local anchor, radius = self:_bossAnchor(flow)
	self:_enqueue(SOURCE_BOSS, kind, anchor, radius)
end

--[[
	Releases one boss NOW, returning the model, or nil when there is nowhere
	legal to stand it right now.

	This is RoundService's entry point at the top of a wave whose definition
	lists a boss. Placement is synchronous rather than queued because the caller
	is announcing the wave in the same breath and a Tank that arrives a full
	spawn-queue drain later has already missed its cue.

	A nil return is "not yet", not "never": the request is handed to the ordinary
	spawn queue on the way out, so the boss still arrives as soon as the team's
	sight lines move. Callers should treat nil as informational and MUST NOT
	retry — a retry loop on top of this is how you get four Tanks.
]]
function DirectorService:releaseBoss(kind: string): Model?
	if not self._queue then
		warn("[DirectorService] releaseBoss before init(); call it from start() or later")
		return nil
	end
	if typeof(kind) ~= "string" or not InfectedConfig.get(kind) then
		warn(string.format("[DirectorService] releaseBoss(%q): no such infected kind", tostring(kind)))
		return nil
	end

	local infected = Registry.find("InfectedService")
	if not infected then
		warn("[DirectorService] releaseBoss: InfectedService is not registered")
		return nil
	end

	-- Called from outside the tick, so the survivor snapshot the placement rules
	-- read may be up to an eighth of a second stale — long enough for somebody to
	-- have turned around, which is the one thing this search exists to catch.
	self:_refreshSurvivors()
	if #self._characters == 0 then
		return nil
	end

	local now = os.clock()
	local anchor, radius = self:_bossAnchor(self:_survivorFlow())
	local position, failure =
		self:_placeFor({ source = SOURCE_BOSS, kind = kind, anchor = anchor, radius = radius }, now)

	if not position then
		-- A placement failure fixes itself the moment somebody turns around, so
		-- this one goes to the ordinary queue and the boss still arrives.
		self._starved += 1
		self._starvedReason = failure or "unknown"
		self:_enqueue(SOURCE_BOSS, kind, anchor, radius)
		return nil
	end

	local model = infected:spawn(kind, position)
	if not model then
		-- Not a placement problem, and waiting does not fix it: the roster is
		-- already at this kind's maxAlive, or the rig could not be built.
		-- Queueing a retry here would just burn placement searches forever.
		warn(
			string.format(
				"[DirectorService] releaseBoss(%q): InfectedService refused the spawn — "
					.. "most likely %d already alive against its maxAlive",
				kind,
				infected:getCount(kind)
			)
		)
		return nil
	end

	broadcast(EVENT.Boss, { kind = kind, position = position })
	-- A Tank IS the peak by definition; a Witch is a hazard the team can choose
	-- to walk around, so she does not move the pacing state.
	if kind == Enums.Infected.Tank then
		self:_setState(STATE.SustainPeak)
	end
	return model
end

-- ════════════════════════════════════════════════════════════════════════════
--  Panic events
-- ════════════════════════════════════════════════════════════════════════════

--[[
	Runs a bounded crescendo of waves at a position, on top of whatever the
	Director is already doing. An alarmed door, a lift, a car alarm — and every
	bile jar that lands on somebody, which is why this MERGES rather than stacks:
	one jar can cover all four survivors, and four overlapping panic events would
	be four times the horde the design asks for.

	Wave mode does not schedule these; they are player- and map-triggered, and a
	panic event a player caused during a breather is a panic event they earned.
]]
function DirectorService:triggerPanicEvent(position: Vector3, waves: number?)
	if not self._panic or typeof(position) ~= "Vector3" then
		return
	end
	local requested = math.clamp(math.floor(tonumber(waves) or PANIC.WaveCount), 1, PANIC.WaveCount)
	local now = os.clock()
	local panic = self._panic

	panic.position = position
	panic.endsAt = now + PANIC.Duration
	if panic.active then
		panic.wavesLeft = math.min(math.max(panic.wavesLeft, requested), PANIC.WaveCount)
		return
	end

	panic.active = true
	panic.wavesLeft = requested
	panic.nextWaveAt = now

	-- A panic event IS the peak. Announcing it while the pacing state still says
	-- Relax would leave the music calm over the loudest thing in the map.
	self:_setState(STATE.SustainPeak)
	broadcast(EVENT.Panic, { position = position, waves = requested })
end

function DirectorService:_updatePanic(now: number)
	local panic = self._panic
	if not panic.active then
		return
	end
	if now >= panic.endsAt or panic.wavesLeft <= 0 then
		panic.active = false
		return
	end
	if now < panic.nextWaveAt then
		return
	end

	panic.wavesLeft -= 1
	panic.nextWaveAt = now + PANIC.WaveInterval

	local scaled = math.max(1, math.floor(PANIC.WaveSize * self._profile.populationScale + 0.5))
	for _ = 1, scaled do
		if not self:_enqueue(SOURCE_PANIC, Enums.Infected.Common, panic.position, PANIC.SpawnRadius) then
			break
		end
	end
end

-- ════════════════════════════════════════════════════════════════════════════
--  Spawn queue
--
--  Every spawn in the game goes through here, and it drains at a fixed small
--  rate per tick. That is the only thing standing between "the horde arrives"
--  and "the server builds 46 rigs in one frame".
-- ════════════════════════════════════════════════════════════════════════════

function DirectorService:_enqueue(
	source: string,
	kind: string,
	anchor: Vector3?,
	radius: number?,
	flank: boolean?
): boolean
	if self._queueTail - self._queueHead + 1 >= MAX_QUEUED_SPAWNS then
		self._dropped += 1
		return false
	end
	self._queueTail += 1
	self._queue[self._queueTail] = {
		source = source,
		kind = kind,
		anchor = anchor,
		radius = radius,
		flank = flank,
	}
	return true
end

function DirectorService:_queuedCount(source: string?): number
	if not source then
		return self._queueTail - self._queueHead + 1
	end
	local total = 0
	for index = self._queueHead, self._queueTail do
		local request = self._queue[index]
		if request and request.source == source then
			total += 1
		end
	end
	return total
end

--[[ Removes every queued request from one source, compacting in place. ]]
function DirectorService:_dropQueued(source: string)
	local write = self._queueHead
	for index = self._queueHead, self._queueTail do
		local request = self._queue[index]
		self._queue[index] = nil
		if request and request.source ~= source then
			self._queue[write] = request
			write += 1
		end
	end
	self._queueTail = write - 1
	if self._queueTail < self._queueHead then
		self._queueHead = 1
		self._queueTail = 0
	end
end

--[[ Drops everything. Used when the Director goes inactive: prep, a scoreboard
     and a lobby all mean the phase that asked for these no longer exists. ]]
function DirectorService:_clearQueue()
	for index = self._queueHead, self._queueTail do
		self._queue[index] = nil
	end
	self._queueHead = 1
	self._queueTail = 0
end

function DirectorService:_dequeue()
	if self._queueHead > self._queueTail then
		return nil
	end
	local request = self._queue[self._queueHead]
	self._queue[self._queueHead] = nil
	self._queueHead += 1
	if self._queueHead > self._queueTail then
		self._queueHead = 1
		self._queueTail = 0
	end
	return request
end

function DirectorService:_placeFor(request, now: number): (Vector3?, string?)
	local characters = self._characters
	if #characters == 0 then
		return nil, "no survivor characters"
	end

	-- Reuse a recently cleared point for the rest of the batch. The point passed
	-- the sight and ground tests moments ago, and a batch that walks in from one
	-- doorway reads as a horde arriving; the same batch scattered around the
	-- room reads as zombies appearing.
	local cached = self._placement
	if
		cached
		and request.source ~= SOURCE_BOSS
		and cached.anchor == request.anchor
		and now - cached.at <= SPAWNING.VisibilityGracePeriod
	then
		local bearing = random:NextNumber() * math.pi * 2
		local spread = SPAWN_SPREAD * math.sqrt(random:NextNumber())
		return cached.position + Vector3.new(math.cos(bearing) * spread, 0, math.sin(bearing) * spread), nil
	end

	local options
	if request.anchor then
		options = ANCHORED_OPTIONS
		options.anchor = request.anchor
		options.maxDistance = request.radius or PANIC.SpawnRadius
	elseif request.flank then
		options = FLANK_OPTIONS
	else
		options = POPULATION_OPTIONS
	end

	--[[ The clearance test needs to know how big the body is. Set per call on the
	     reused option tables, exactly as anchor and maxDistance already are. ]]
	options.kind = request.kind

	local position, failure = SpawnPlacement.find(characters, options)
	if position then
		self._placement = { position = position, anchor = request.anchor, at = now }
	end
	return position, failure
end

function DirectorService:_drainQueue(now: number)
	if now < self._placementBackoffUntil then
		return
	end
	local infected = Registry.find("InfectedService")
	if not infected then
		return
	end

	for _ = 1, MAX_SPAWNS_PER_TICK do
		local request = self:_dequeue()
		if not request then
			break
		end

		local position, failure = self:_placeFor(request, now)
		if not position then
			-- Dropped, not retried. The population deficit is recomputed every
			-- interval and will ask again; retrying in place would spend the
			-- whole spawn budget re-running a search that just failed.
			self._starved += 1
			self._starvedReason = failure or "unknown"
			-- A boss is the exception: its flow threshold is only consumed on a
			-- successful placement, so _updateBosses will offer it again after
			-- the retry gap rather than losing the set piece entirely.
			if request.source == SOURCE_BOSS then
				self._bossRetryAt = now + BOSS_RETRY_INTERVAL
			end
			self._placementBackoffUntil = now + PLACEMENT_BACKOFF
			break
		end

		local model = infected:spawn(request.kind, position)
		if not model then
			if request.source == SOURCE_BOSS then
				self._bossRetryAt = now + BOSS_RETRY_INTERVAL
			end
			continue
		end

		if request.source == SOURCE_SPECIAL then
			self._specialsSpawned += 1
			broadcast(EVENT.Special, { kind = request.kind })
		elseif request.source == SOURCE_BOSS then
			self:_rerollBossFlow(request.kind)
			broadcast(EVENT.Boss, { kind = request.kind, position = position })
			-- A Tank is the peak by definition; a Witch is a hazard the team can
			-- walk around, so she does not move the pacing state.
			if request.kind == Enums.Infected.Tank then
				self:_setState(STATE.SustainPeak)
			end
		end
	end
end

function DirectorService:_reportStarvation(now: number)
	if self._starved == 0 and self._dropped == 0 then
		return
	end
	if now - self._starvedWarnedAt < STARVATION_WARN_INTERVAL then
		return
	end
	self._starvedWarnedAt = now
	warn(
		string.format(
			"[DirectorService] %d spawn(s) had nowhere to go and %d were dropped from a full queue "
				.. "in the last %ds — last reason: %s",
			self._starved,
			self._dropped,
			STARVATION_WARN_INTERVAL,
			self._starvedReason
		)
	)
	self._starved = 0
	self._dropped = 0
end

-- ════════════════════════════════════════════════════════════════════════════
--  Difficulty
-- ════════════════════════════════════════════════════════════════════════════

--[[ Scales infected damage, population and special frequency without touching
     any of the tuning above, so Advanced stays recognisably the same game as
     Normal. DamageService reads this every quarter second. ]]
function DirectorService:setDifficulty(name: string): boolean
	local profile = DirectorConfig.Difficulty[name]
	if not profile then
		warn(string.format("[DirectorService] setDifficulty(%q): no such preset", tostring(name)))
		return false
	end
	self._difficulty = name
	self._profile = profile
	return true
end

function DirectorService:getDifficulty(): string
	return self._difficulty
end

function DirectorService:getDifficultyProfile()
	return self._profile
end

-- ════════════════════════════════════════════════════════════════════════════
--  Replication
-- ════════════════════════════════════════════════════════════════════════════

function DirectorService:_publish()
	setGameAttribute(Attributes.Game.PacingState, self._state)
	setGameAttribute(Attributes.Game.AliveSurvivors, #self._survivors)

	--[[ Written every tick, so the HUD vignette and the music mix have a live
	     number to lerp against rather than a value that only moves on a state
	     change. Rounded to two decimals first — nothing reading this can tell
	     0.6231 from 0.6234 — and pushed through setGameAttribute, so a value
	     that has not actually moved costs no replication at all. ]]
	setGameAttribute(Attributes.Game.TeamIntensity, math.floor(self._teamIntensity * 100 + 0.5) / 100)

	-- InfectedService keeps this current on every spawn and death; this only
	-- catches a count that drifted, and costs nothing when it has not.
	local infected = Registry.find("InfectedService")
	if infected then
		setGameAttribute(Attributes.Game.InfectedAlive, infected:getCount())
	end
end

Registry.register("DirectorService", DirectorService)

return DirectorService
