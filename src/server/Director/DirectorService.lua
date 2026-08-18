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

--[[ Bosses excluded — they are scheduled by flow distance, never by the special
     budget. The config is frozen, so this list never changes and is built once
     rather than rebuilt (and re-sorted) on every Director tick. ]]
local SPECIAL_IDS = InfectedConfig.getSpecialIds()

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

local ANCHORED_OPTIONS = {
	minDistance = SPAWNING.MinDistanceFromSurvivor,
	maxDistance = PANIC.SpawnRadius,
	requireOutOfSight = SPAWNING.RequireOutOfSight,
	attempts = SPAWNING.MaxSpawnAttempts,
	anchor = Vector3.zero,
}

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
	self._publishedIntensity = -1

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

function DirectorService:start()
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
	self:_updatePacing(now)

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

--[[ The Director runs whenever there is somebody left to press. There is no
     round service in the contract, so a wipe or a victory is the only thing
     that silences it. ]]
function DirectorService:_isPlaying(): boolean
	if #self._survivors == 0 then
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
--  Intensity
-- ════════════════════════════════════════════════════════════════════════════

--[[
	Adds to (or removes from) one survivor's intensity.

	Callers pass an ALREADY WEIGHTED amount — DamageService multiplies damage by
	DamageTakenWeight itself, and passes -KillRelief on a kill — so this stays a
	single, honest accumulator with one clamp and no opinions of its own.
]]
function DirectorService:addIntensity(player: Player, amount: number)
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

function DirectorService:_populationTarget(): number
	local plan = POPULATION[self._state]
	if not plan then
		return 0
	end
	return math.floor(plan.target * self._profile.populationScale + 0.5)
end

function DirectorService:_updatePopulation(now: number)
	local plan = POPULATION[self._state]
	if not plan or now < self._nextPopulationAt then
		return
	end
	self._nextPopulationAt = now + plan.spawnInterval

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

	for _ = 1, math.min(plan.batchSize, deficit) do
		self:_enqueue(SOURCE_POPULATION, Enums.Infected.Common, nil, nil)
	end
end

-- ════════════════════════════════════════════════════════════════════════════
--  Specials
-- ════════════════════════════════════════════════════════════════════════════

function DirectorService:_rollSpecialInterval(): number
	return math.max(1, SPECIALS.BaseInterval + random:NextNumber(-1, 1) * SPECIALS.IntervalJitter)
end

--[[ Pacing scales the WAIT, not the roll, so a state change is felt immediately
     rather than at the next reroll: drop into Relax mid-countdown and the next
     special is pushed out, climb into a peak and it arrives sooner. ]]
function DirectorService:_specialIntervalMultiplier(): number
	local multiplier = self._profile.specialInterval
	if self._state == STATE.Relax then
		multiplier *= SPECIALS.RelaxMultiplier
	elseif self._state == STATE.SustainPeak then
		multiplier *= SPECIALS.PeakMultiplier
	end
	return multiplier
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
	says what each one is worth, so a Charger being twice a Boomer's problem
	makes it correspondingly rarer without a second table of weights to keep in
	agreement with the first.
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
	local sinceLast = now - self._lastSpecialAt
	if sinceLast < SPECIALS.MinIntervalBetweenAny then
		return
	end
	if sinceLast < self._specialRoll * self:_specialIntervalMultiplier() then
		return
	end
	if self:_aliveSpecials() >= SPECIALS.MaxAliveTotal then
		return
	end
	if self._specialsSpawned == 0 and self:_survivorFlow() < SPECIALS.MinFlowBeforeFirst then
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
	end
end

-- ════════════════════════════════════════════════════════════════════════════
--  Bosses
--
--  Placed by FLOW DISTANCE, never by a timer, so every playthrough of a map has
--  a Tank roughly where the map was designed for one and a team that rushes
--  does not skip the set piece it was built around.
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

function DirectorService:_enqueueBoss(kind: string, flow: number)
	local zone = self:_pickBossZone(flow)
	if zone then
		-- The zone's own footprint is the radius, floored at the minimum spawn
		-- distance so the sampler always has a legal ring to draw from.
		local extent = math.max(zone.Size.X, zone.Size.Z) * 0.5
		self:_enqueue(SOURCE_BOSS, kind, zone.Position, math.max(extent, SPAWNING.MinDistanceFromSurvivor))
	else
		self:_enqueue(SOURCE_BOSS, kind, nil, nil)
	end
end

-- ════════════════════════════════════════════════════════════════════════════
--  Panic events
-- ════════════════════════════════════════════════════════════════════════════

--[[
	Runs a bounded crescendo of waves at a position, on top of whatever the
	Director is already doing. An alarmed door, a lift, a car alarm — and every
	Boomer that hits somebody, which is why this merges rather than stacks: one
	burst can bile all four survivors and then explode, and four overlapping
	panic events would be four times the horde the design asks for.
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

function DirectorService:_enqueue(source: string, kind: string, anchor: Vector3?, radius: number?): boolean
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
	else
		options = POPULATION_OPTIONS
	end

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

	-- Two decimals. The raw value changes every tick and nothing reading it —
	-- a music mix, a debug overlay — can tell 0.6231 from 0.6234.
	local rounded = math.floor(self._teamIntensity * 100 + 0.5) / 100
	if rounded ~= self._publishedIntensity then
		self._publishedIntensity = rounded
		Workspace:SetAttribute(Attributes.Game.TeamIntensity, rounded)
	end

	-- InfectedService keeps this current on every spawn and death; this only
	-- catches a count that drifted, and costs nothing when it has not.
	local infected = Registry.find("InfectedService")
	if infected then
		setGameAttribute(Attributes.Game.InfectedAlive, infected:getCount())
	end
end

Registry.register("DirectorService", DirectorService)

return DirectorService
