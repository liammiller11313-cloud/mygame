--!nonstrict
--[[
	RoundService — the seventeen minutes.

	A round is a fixed schedule: fifteen seconds of prep, then seven waves with a
	breather after each, totalling exactly GameModeConfig.Classic.TotalDuration.
	This service owns that clock and nothing else. It does not decide what spawns
	or where — the Director does, and keeps every bit of its intelligence — it
	decides WHEN pressure happens and hands the Director the budget it is allowed
	to spend inside each wave.

	── THE SCHEDULE IS ABSOLUTE ────────────────────────────────────────────────
	Every phase boundary is computed from the round's start time and
	GameModeConfig's own numbers, never accumulated tick by tick. A hitched
	server, a long LoadCharacter, a tick that lands 200ms late — none of them can
	push wave 7 out of place, because wave 7 starts when the clock says so and
	not when the previous phase happens to notice it is done.

	That is also why FL_WaveEndsAt and FL_RoundEndsAt are absolute
	workspace:GetServerTimeNow() stamps rather than remaining seconds. The client
	subtracts its own synchronised clock and renders a perfectly smooth countdown
	from a value that only changes when the phase does. A timer ticked over a
	remote would cost sixty messages a second to be less accurate.

	── THE BREATHER IS LOAD-BEARING ────────────────────────────────────────────
	It is not dead time between waves; it is the reason the next wave lands. Ammo
	comes back, the map restocks on a roll, and the dead come back at
	RespawnHealth. What does NOT happen is a free pickup for anyone who is down —
	being incapacitated has to stay expensive or the horde stops being frightening
	and starts being scenery. GameModeConfig.Classic.BreatherHealsIncapped is the
	switch, and it is off.

	── CALLOUTS ────────────────────────────────────────────────────────────────
	Nothing else on the server fires Remotes.Event.Subtitle. This service is its
	producer: waves, bosses, the last thirty seconds, teammates going down, and
	how the round ended. The client SubtitleController owns queueing and speaker
	colour; all that is sent is a speaker, a line, and how long it should hold.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attributes = require(Shared.Net.Attributes)
local AudioConfig = require(Shared.Config.AudioConfig)
local Enums = require(Shared.Enums)
local GameModeConfig = require(Shared.Config.GameModeConfig)
local InfectedConfig = require(Shared.Config.InfectedConfig)
local Registry = require(Shared.Util.Registry)
local Remotes = require(Shared.Net.Remotes)
local Signal = require(Shared.Util.Signal)
local Trove = require(Shared.Util.Trove)
local WeaponConfig = require(Shared.Config.WeaponConfig)

local CLASSIC = GameModeConfig.Classic

--[[ The four values of Attributes.Game.WavePhase. "Over" covers both the lobby
     and the result screen: it answers "what is the wave doing", and
     FL_RoundState is what answers "what is the round doing". ]]
local PHASE = table.freeze({
	Prep = "Prep",
	Active = "Active",
	Breather = "Breather",
	Over = "Over",
})

--[[ DirectorService's music vocabulary. These strings are its contract with
     MusicController; RoundService borrows two of them so that a wave landing and
     a breather starting move the music, and defines none of its own. ]]
local DIRECTOR_EVENT = table.freeze({
	HordeIncoming = "HordeIncoming",
	Calm = "Calm",
})

--[[ 4Hz. The only thing this loop does is notice that a deadline has passed and
     that the team is still alive; the countdown itself is drawn client-side from
     an absolute stamp, so asking sixty times a second would buy nothing but a
     quarter of a second of announcement latency nobody can perceive. ]]
local TICK_INTERVAL = 0.25

--[[ How long before the end of the round the finale callout goes out. Long
     enough that a team can decide to fall back to a corner, short enough that it
     still reads as "nearly there" rather than as a countdown. ]]
local FINAL_WARNING = 30

--[[ Bosses in the same wave are requested this far apart. Two Tanks asked for in
     the same frame get placed against the same sight lines and arrive shoulder
     to shoulder through one doorway, which is a wall, not a set piece. ]]
local BOSS_STAGGER = 3

-- Subtitle dwell times. SubtitleController clamps these; they are the intent.
local SAY_ANNOUNCE = 3.2
local SAY_CALLOUT = 2.2

local RoundService = {}

--[[ (index: number, definition: WaveDefinition) ]]
RoundService.waveChanged = Signal.new()
--[[ (isBreather: boolean, index: number) ]]
RoundService.phaseChanged = Signal.new()
--[[ (outcome: string) — Enums.RoundState.Victory or .TeamWipe ]]
RoundService.roundEnded = Signal.new()

local serviceTrove = Trove.new()
local random = Random.new()

-- ── round state ─────────────────────────────────────────────────────────────
local mode = GameModeConfig.DefaultMode
local roundState = Enums.RoundState.Lobby
local phase = PHASE.Over
local waveIndex = 0

local startedAt = 0 -- absolute server time the prep window opened
local roundEndsAt = 0 -- absolute server time the schedule runs out
local phaseEndsAt = 0 -- absolute server time the current phase ends

local schedule: { any } = {}
local cursor = 0
local generation = 0 -- invalidates every delayed callback from an older round

local sawLivingSurvivor = false
local warnedFinal = false
local accumulator = 0

local warned: { [string]: boolean } = {}
local function warnOnce(key: string, message: string)
	if warned[key] then
		return
	end
	warned[key] = true
	warn("[RoundService] " .. message)
end

local function serverNow(): number
	return Workspace:GetServerTimeNow()
end

--[[ Attributes replicate on write, so writing a value that has not changed is
     pure network cost for every client in the server. ]]
local function setGameAttribute(name: string, value: any)
	if Workspace:GetAttribute(name) ~= value then
		Workspace:SetAttribute(name, value)
	end
end

-- ════════════════════════════════════════════════════════════════════════════
--  Presentation
-- ════════════════════════════════════════════════════════════════════════════

--[[ The game's own voice. `speaker` is a player's name when a survivor is the
     one saying it — SubtitleController draws that name in their identity colour
     — and "" for a line that belongs to nobody in particular. ]]
local function say(speaker: string, text: string, duration: number?)
	Remotes.Event.Subtitle:FireAllClients({
		speaker = speaker,
		text = text,
		duration = duration or SAY_CALLOUT,
	})
end

local function broadcastDirectorEvent(kind: string, payload: any?)
	Remotes.Event.DirectorEvent:FireAllClients({ kind = kind, payload = payload })
end

local function playUi(definition: any)
	local audio = Registry.find("AudioService")
	if not audio then
		return
	end
	for _, player in Players:GetPlayers() do
		audio:playForPlayer(player, definition)
	end
end

--[[ The objective line belongs to LevelService — it owns the attribute and the
     remote — so the round supplies the words and never writes the field. ]]
local function setObjective(text: string)
	local level = Registry.find("LevelService")
	if level and typeof(level.setObjective) == "function" then
		level:setObjective(text)
	end
end

-- ════════════════════════════════════════════════════════════════════════════
--  Driving the Director
--
--  The Director keeps every bit of its intelligence: the intensity model, the
--  refusal to spawn inside somebody's field of view, health-weighted item
--  placement. All that changes is that its population and special budgets now
--  come from the wave instead of from its own pacing. Nothing here spawns
--  anything itself.
-- ════════════════════════════════════════════════════════════════════════════

--[[
	Hands the Director the ceiling for this phase.

	`populationScale` and `spawnRateScale` multiply its own per-pacing-state
	target and spawn rate; `maxSpecialsAlive` and `specialInterval` replace
	DirectorConfig.Specials outright, and zero specials means zero.

	A breather is handed a scale of 1 rather than 0 on purpose: the Director drops
	to Relax on `isBreather`, and Relax already describes the lull — a handful of
	wandering commons, six seconds apart, from DirectorConfig.Population. Zeroing
	it would empty the map, and an empty map between waves is where a team stops
	being afraid. What the breather does forbid is specials: the calm is for
	reloading, not for eating a Hunter.
]]
local function setWaveBudget(
	populationScale: number,
	spawnRateScale: number,
	maxSpecials: number,
	specialInterval: number,
	isBreather: boolean
)
	local director = Registry.find("DirectorService")
	if not director then
		return
	end
	if typeof(director.setWaveBudget) ~= "function" then
		warnOnce(
			"nobudget",
			"DirectorService has no setWaveBudget(budget) — waves cannot scale population or "
				.. "specials, so the Director is running its own pacing inside the wave clock"
		)
		return
	end

	-- A fresh table per phase change (roughly fifteen a round, never in a hot
	-- path), because the Director is entitled to hold on to the one it is given.
	director:setWaveBudget({
		populationScale = populationScale,
		spawnRateScale = spawnRateScale,
		maxSpecialsAlive = maxSpecials,
		specialInterval = specialInterval,
		waveIndex = waveIndex,
		isBreather = isBreather,
	})
end

--[[ Spawning on and off wholesale. Prep, the lobby and the scoreboard are all
     "not playing"; a breather is NOT — that is a budget, because the Director is
     still reading the team and still trickling through the lull. ]]
local function setDirectorActive(active: boolean)
	local director = Registry.find("DirectorService")
	if not director then
		return
	end
	if typeof(director.setActive) ~= "function" then
		warnOnce(
			"noactive",
			"DirectorService has no setActive(active) — the horde cannot be switched off for prep "
				.. "or for the scoreboard, so it will keep spawning outside the waves"
		)
		return
	end
	director:setActive(active)
end

--[[ Asks the Director to place a boss. It picks the FL_BossZone, honours the
     sight rules and fires its own Boss music cue — this only says "now". ]]
local function releaseBoss(kind: string)
	local director = Registry.find("DirectorService")
	if not director then
		warnOnce("noboss", "DirectorService is not registered, so wave bosses will never arrive")
		return
	end
	if typeof(director.releaseBoss) ~= "function" then
		warnOnce(
			"norelease",
			"DirectorService has no releaseBoss(kind) — wave bosses cannot be placed. The round "
				.. "will not spawn one itself: placement is the Director's job and duplicating it "
				.. "would put a Tank in somebody's field of view"
		)
		return
	end
	director:releaseBoss(kind)
end

--[[ "TANK!" for one, "TANK! 2 of them." for a wave that opens with a pair. The
     wave's own announcement already sets the tone; this is the specific. ]]
local function bossCallout(bosses: { string }): string?
	local order: { string } = {}
	local counts: { [string]: number } = {}
	for _, kind in bosses do
		if not counts[kind] then
			counts[kind] = 0
			table.insert(order, kind)
		end
		counts[kind] += 1
	end

	local parts: { string } = {}
	for _, kind in order do
		local definition = InfectedConfig.get(kind)
		local name = string.upper(if definition then definition.displayName else kind)
		if counts[kind] > 1 then
			table.insert(parts, string.format("%s! %d of them.", name, counts[kind]))
		else
			table.insert(parts, string.format("%s!", name))
		end
	end
	if #parts == 0 then
		return nil
	end
	return table.concat(parts, " ")
end

-- ════════════════════════════════════════════════════════════════════════════
--  The schedule
-- ════════════════════════════════════════════════════════════════════════════

--[[
	Prep, then every wave and its breather, as offsets from the start of the
	round. Built from GameModeConfig alone, so the only way to change the shape of
	a round is to change that file.
]]
local function buildSchedule(): { any }
	local entries = {}
	local at = 0

	table.insert(
		entries,
		{ phase = PHASE.Prep, index = 0, wave = nil, startsAt = 0, endsAt = CLASSIC.PrepDuration }
	)
	at = CLASSIC.PrepDuration

	for _, wave in GameModeConfig.Waves do
		table.insert(entries, {
			phase = PHASE.Active,
			index = wave.index,
			wave = wave,
			startsAt = at,
			endsAt = at + wave.duration,
		})
		at += wave.duration

		-- Wave 7 has no breather; the schedule simply ends and the team has won.
		if wave.breather > 0 then
			table.insert(entries, {
				phase = PHASE.Breather,
				index = wave.index,
				wave = wave,
				startsAt = at,
				endsAt = at + wave.breather,
			})
			at += wave.breather
		end
	end

	return entries
end

-- ════════════════════════════════════════════════════════════════════════════
--  Phase entry
-- ════════════════════════════════════════════════════════════════════════════

function RoundService:_publishPhase(entry)
	phase = entry.phase
	waveIndex = entry.index
	phaseEndsAt = startedAt + entry.endsAt

	setGameAttribute(Attributes.Game.WaveIndex, waveIndex)
	setGameAttribute(Attributes.Game.WavePhase, phase)
	setGameAttribute(Attributes.Game.WaveEndsAt, phaseEndsAt)
end

function RoundService:_publishRoundState(state: string, payload: { [string]: any }?)
	roundState = state
	setGameAttribute(Attributes.Game.RoundState, state)
	Remotes.Event.RoundStateChanged:FireAllClients({ state = state, payload = payload })
end

--[[ One remote for every phase edge, carrying the absolute stamp the client
     counts down to. `isBreather` is what tells a HUD whether to draw "WAVE 3" or
     "WAVE 3 CLEARED — 0:25". ]]
function RoundService:_announceWave(entry, isBreather: boolean)
	local wave = entry.wave
	Remotes.Event.WaveChanged:FireAllClients({
		index = entry.index,
		name = if wave then wave.name else "",
		announcement = if wave then wave.announcement else "",
		isBreather = isBreather,
		endsAt = phaseEndsAt,
	})
end

function RoundService:_enterPrep(entry)
	self:_publishPhase(entry)
	self:_publishRoundState(Enums.RoundState.Starting, { phase = phase, waveIndex = waveIndex })

	-- Nothing spawns during prep. The window exists so a team can find a gun and
	-- find each other, and a Director trickling commons into it spends it.
	setWaveBudget(0, 1, 0, 0, false)
	setDirectorActive(false)

	setObjective(string.format("Gear up — first wave in %d seconds", math.floor(CLASSIC.PrepDuration)))
	say(
		"",
		string.format(
			"%d minutes until the lights come back on. Find a weapon.",
			math.floor(CLASSIC.TotalDuration / 60)
		),
		SAY_ANNOUNCE
	)

	-- The one stocking pass that is not a breather roll: the prep window is
	-- worthless if there is nothing on the shelves to pick up.
	local level = Registry.find("LevelService")
	if level and typeof(level.restockItems) == "function" then
		level:restockItems()
	end
end

function RoundService:_enterWave(entry)
	local wave = entry.wave
	self:_publishPhase(entry)
	if roundState ~= Enums.RoundState.InProgress then
		self:_publishRoundState(Enums.RoundState.InProgress, { phase = phase, waveIndex = waveIndex })
	end

	setWaveBudget(
		wave.populationScale,
		wave.spawnRateScale,
		wave.maxSpecialsAlive,
		wave.specialInterval,
		false
	)
	setDirectorActive(true)

	self:_announceWave(entry, false)
	self.waveChanged:fire(entry.index, wave)
	self.phaseChanged:fire(false, entry.index)

	broadcastDirectorEvent(DIRECTOR_EVENT.HordeIncoming, { waveIndex = entry.index })
	playUi(AudioConfig.UI.WaveIncoming)

	setObjective(string.format("Wave %d of %d — %s", entry.index, GameModeConfig.getWaveCount(), wave.name))
	say("", wave.announcement, SAY_ANNOUNCE)

	--[[ Boss releases are staggered and generation-guarded: a Tank requested for
	     wave 7 must not walk in three seconds after a team wipe ended the round. ]]
	if #wave.bosses > 0 then
		local callout = bossCallout(wave.bosses)
		if callout then
			say("", callout, SAY_ANNOUNCE)
		end
		local mine = generation
		for order, kind in wave.bosses do
			if order == 1 then
				releaseBoss(kind)
			else
				task.delay((order - 1) * BOSS_STAGGER, function()
					if mine == generation and roundState == Enums.RoundState.InProgress then
						releaseBoss(kind)
					end
				end)
			end
		end
	end
end

function RoundService:_enterBreather(entry)
	local wave = entry.wave
	self:_publishPhase(entry)

	-- The wave's own pressure stops here: no specials, and the Director's Relax
	-- state decides what little is still wandering around for the team to clear.
	setWaveBudget(1, 1, 0, 0, true)

	self:_announceWave(entry, true)
	self.phaseChanged:fire(true, entry.index)

	broadcastDirectorEvent(DIRECTOR_EVENT.Calm, { waveIndex = entry.index })
	playUi(AudioConfig.UI.WaveCleared)

	local seconds = math.floor(wave.breather + 0.5)
	setObjective(string.format("Regroup — wave %d in %d seconds", entry.index + 1, seconds))
	say("", string.format("Wave %d down. %d seconds — reload.", entry.index, seconds), SAY_ANNOUNCE)

	-- Off the tick: respawning yields on LoadCharacter and the shared loop must
	-- not be held open waiting for four characters to stream in.
	local mine = generation
	task.spawn(function()
		if mine == generation then
			self:_restock(wave)
		end
	end)
end

--[[
	The breather's actual work.

	Ammo, a roll for a map restock, and the dead back on their feet at
	RespawnHealth. Every one of those is behind its own GameModeConfig flag,
	including BreatherHealsIncapped — which is false, and which is the reason
	going down still costs the team something after the wave is over.
]]
function RoundService:_restock(wave)
	local survivors = Registry.find("SurvivorService")
	local inventory = Registry.find("InventoryService")

	if CLASSIC.BreatherRestocksAmmo and inventory then
		for _, player in Players:GetPlayers() do
			for _, slot in { Enums.Slot.Primary, Enums.Slot.Secondary } do
				local itemId = inventory:getItem(player, slot)
				local definition = if itemId then WeaponConfig.get(itemId) else nil
				if definition then
					-- Re-giving the same weapon IS the ammo pile: full magazine,
					-- full reserve, nothing else about the loadout disturbed.
					inventory:giveWeapon(player, itemId, definition.magSize, definition.reserveMax)
				end
			end
		end
	end

	-- The wave's own odds decide whether the map gets anything back. Wave 4 (the
	-- first Tank) is 0.7 and wave 7 is 0, which is the difficulty curve doing its
	-- work quietly rather than through a number on the screen.
	if random:NextNumber() < wave.itemDropChance then
		local level = Registry.find("LevelService")
		if level and typeof(level.restockItems) == "function" then
			local placed = level:restockItems()
			if placed > 0 then
				say("", "Supplies are out there. Grab what you need.", SAY_CALLOUT)
			end
		end
	end

	if not survivors then
		return
	end

	-- The slot is the player's place in the roster, not a running count of the
	-- dead: two survivors coming back in the same breather must not be handed the
	-- same spawn point and spend it pushing each other out of it.
	local slot = 0
	for _, player in Players:GetPlayers() do
		slot += 1
		local state = survivors:getState(player)
		local isGone = state == Enums.SurvivorState.Dead or state == Enums.SurvivorState.Spectating

		if isGone and CLASSIC.BreatherRespawnsDead then
			self:_respawnSurvivor(survivors, player, slot)
			say(player.DisplayName, "I'm back.", SAY_CALLOUT)
		elseif CLASSIC.BreatherHealsIncapped and survivors:isIncapacitated(player) then
			survivors:revive(player)
		end
	end
end

--[[
	Puts a dead survivor back in the fight at RespawnHealth.

	SurvivorService owns respawning; this only chooses the health and the spot.
	The private `_respawn` is used when there is no public equivalent, because the
	alternative — spawnSurvivor — returns a survivor at FULL health, which would
	make dying during a wave strictly better than being hurt by it.
]]
function RoundService:_respawnSurvivor(survivors, player: Player, slot: number)
	local cframe: CFrame? = nil
	local level = Registry.find("LevelService")
	if level and typeof(level.getSurvivorSpawnCFrame) == "function" then
		cframe = level:getSurvivorSpawnCFrame(slot)
	end

	if typeof(survivors.respawn) == "function" then
		survivors:respawn(player, cframe, CLASSIC.RespawnHealth)
		return
	end

	if typeof(survivors._respawn) == "function" then
		if typeof(survivors._releaseBody) == "function" then
			-- The corpse is a defib target; leaving it behind a living survivor
			-- means a teammate can spend a defibrillator on somebody who is
			-- standing next to them.
			survivors:_releaseBody(player)
		end
		survivors:_respawn(player, cframe, CLASSIC.RespawnHealth)
		return
	end

	warnOnce(
		"norespawn",
		string.format(
			"SurvivorService exposes no respawn(player, cframe, health); breather respawns fall back "
				.. "to spawnSurvivor and arrive at full health instead of %d",
			CLASSIC.RespawnHealth
		)
	)
	if cframe then
		survivors:setSpawnCFrame(player, cframe)
	end
	survivors:spawnSurvivor(player)
end

function RoundService:_enter(entry)
	if entry.phase == PHASE.Prep then
		self:_enterPrep(entry)
	elseif entry.phase == PHASE.Active then
		self:_enterWave(entry)
	else
		self:_enterBreather(entry)
	end
end

-- ════════════════════════════════════════════════════════════════════════════
--  Lifecycle
-- ════════════════════════════════════════════════════════════════════════════

--[[ Starts a round. `mode` is a GameModeConfig.Modes key; the wave schedule is
     the same in every mode, which is what makes Versus fair — both teams are
     measured against the same seven waves. ]]
function RoundService:startRound(requestedMode: string?)
	if roundState == Enums.RoundState.Starting or roundState == Enums.RoundState.InProgress then
		return
	end

	mode = if typeof(requestedMode) == "string" and GameModeConfig.Modes[requestedMode]
		then requestedMode
		else GameModeConfig.DefaultMode

	generation += 1

	schedule = buildSchedule()
	cursor = 1
	startedAt = serverNow()
	roundEndsAt = startedAt + CLASSIC.TotalDuration
	sawLivingSurvivor = false
	warnedFinal = false

	setGameAttribute(Attributes.Game.Mode, mode)
	setGameAttribute(Attributes.Game.RoundEndsAt, roundEndsAt)

	local level = Registry.find("LevelService")
	if level and typeof(level.placeSurvivors) == "function" then
		level:placeSurvivors()
	end

	-- Everyone starts this round on their feet, including whoever was dead when
	-- the last one ended.
	local survivors = Registry.find("SurvivorService")
	if survivors then
		for _, player in Players:GetPlayers() do
			survivors:spawnSurvivor(player)
		end
	end

	self:_enter(schedule[cursor])
end

--[[
	Ends the round now.

	A team wipe does not run out the clock: the moment the last survivor is down
	for good, the round is over and the result screen is up. Sitting on an empty
	map for nine more minutes is not tension, it is a bug with a timer.
]]
function RoundService:endRound(outcome: string)
	if roundState ~= Enums.RoundState.Starting and roundState ~= Enums.RoundState.InProgress then
		return
	end

	local victory = outcome == Enums.RoundState.Victory
	local elapsed = self:getElapsed()
	generation += 1

	phase = PHASE.Over
	local now = serverNow()
	setGameAttribute(Attributes.Game.WavePhase, phase)
	setGameAttribute(Attributes.Game.WaveEndsAt, now)
	setGameAttribute(Attributes.Game.RoundEndsAt, now)
	phaseEndsAt = now
	roundEndsAt = now

	-- The Director stops on FL_RoundState too, but saying so explicitly is what
	-- clears its queue: a horde already in flight must not walk into a scoreboard.
	setDirectorActive(false)
	setWaveBudget(0, 1, 0, 0, false)

	self:_publishRoundState(outcome, {
		phase = phase,
		waveIndex = waveIndex,
		outcome = outcome,
		elapsed = elapsed,
	})

	Remotes.Event.RoundEnded:FireAllClients({
		outcome = outcome,
		waveReached = waveIndex,
		elapsed = elapsed,
		scores = self:_buildScores(),
	})

	if victory then
		setObjective("You held out.")
		say("", "That's it. We held.", SAY_ANNOUNCE)
	else
		setObjective("The team is down.")
		say("", "They're all down.", SAY_ANNOUNCE)
	end

	self.roundEnded:fire(outcome)

	-- A server that sits on a result screen forever cannot be playtested twice.
	-- MatchmakingService owns this decision when it exists; until then the round
	-- comes back on its own.
	local mine = generation
	task.delay(GameModeConfig.Matchmaking.PostRoundDuration, function()
		if mine ~= generation then
			return
		end
		self:_returnToLobby()
		self:_startIfReady()
	end)
end

--[[ Per-player facts a scoreboard can render. Read from attributes rather than
     from service calls: this runs on the frame a round ends, when half the
     services are already tearing state down. ]]
function RoundService:_buildScores(): { [string]: any }
	local scores = {}
	for _, player in Players:GetPlayers() do
		local state = Attributes.get(player, Attributes.Player.State, Enums.SurvivorState.Spectating)
		scores[player.Name] = {
			state = state,
			alive = state ~= Enums.SurvivorState.Dead and state ~= Enums.SurvivorState.Spectating,
			incaps = Attributes.get(player, Attributes.Player.IncapCount, 0),
		}
	end
	return scores
end

function RoundService:_returnToLobby()
	generation += 1
	cursor = 0
	waveIndex = 0
	phase = PHASE.Over
	startedAt = 0
	roundEndsAt = 0
	phaseEndsAt = 0

	setGameAttribute(Attributes.Game.WaveIndex, 0)
	setGameAttribute(Attributes.Game.WavePhase, phase)
	setGameAttribute(Attributes.Game.WaveEndsAt, 0)
	setGameAttribute(Attributes.Game.RoundEndsAt, 0)

	local infected = Registry.find("InfectedService")
	if infected then
		infected:despawnAll()
	end

	self:_publishRoundState(Enums.RoundState.Lobby, { phase = phase, waveIndex = 0 })
	setObjective("Waiting for survivors")
end

--[[ Starts a round if nobody else owns that decision. MatchmakingService runs
     the lobby countdown and calls startRound itself when it exists; a developer
     pressing Play with no matchmaking must still get a round. ]]
function RoundService:_startIfReady()
	if roundState ~= Enums.RoundState.Lobby then
		return
	end
	if Registry.find("MatchmakingService") then
		return
	end
	if #Players:GetPlayers() < CLASSIC.MinPlayersToStart then
		return
	end
	self:startRound(mode)
end

-- ════════════════════════════════════════════════════════════════════════════
--  The tick
-- ════════════════════════════════════════════════════════════════════════════

--[[ Nobody left standing ends the round immediately. Read from survivor STATE
     rather than from whether a character exists: a character is briefly nil
     across every respawn, and a wipe declared in that gap would end a round the
     team was still winning. ]]
function RoundService:_checkWipe(): boolean
	if not CLASSIC.EndOnTeamWipe then
		return false
	end
	local survivors = Registry.find("SurvivorService")
	if not survivors then
		return false
	end

	if #survivors:getAliveSurvivors() > 0 then
		sawLivingSurvivor = true
		return false
	end
	if not sawLivingSurvivor or #Players:GetPlayers() == 0 then
		return false
	end

	self:endRound(Enums.RoundState.TeamWipe)
	return true
end

function RoundService:_step()
	if roundState ~= Enums.RoundState.Starting and roundState ~= Enums.RoundState.InProgress then
		return
	end

	-- An empty server is not a wipe and not a victory. Put the round back in the
	-- lobby so the next person to join gets a fresh seventeen minutes rather than
	-- dropping into the middle of one nobody played.
	if #Players:GetPlayers() == 0 then
		self:_returnToLobby()
		return
	end

	if self:_checkWipe() then
		return
	end

	local elapsed = serverNow() - startedAt

	if not warnedFinal and CLASSIC.TotalDuration - elapsed <= FINAL_WARNING then
		warnedFinal = true
		say("", string.format("%d seconds! Hold on!", FINAL_WARNING), SAY_ANNOUNCE)
	end

	-- Phase boundaries are compared against the SCHEDULE, never accumulated, so a
	-- hitch that swallows two boundaries at once still runs both in order.
	while cursor <= #schedule do
		if elapsed < schedule[cursor].endsAt then
			return
		end
		cursor += 1
		if cursor > #schedule then
			-- Reaching the end of wave 7 alive is the win, at four survivors or
			-- at one: VictoryRequiresAllAlive is false and means it.
			self:endRound(Enums.RoundState.Victory)
			return
		end
		self:_enter(schedule[cursor])
	end
end

-- ════════════════════════════════════════════════════════════════════════════
--  Public reads
-- ════════════════════════════════════════════════════════════════════════════

function RoundService:getState(): string
	return roundState
end

function RoundService:getMode(): string
	return mode
end

function RoundService:getPhase(): string
	return phase
end

function RoundService:getWaveIndex(): number
	return waveIndex
end

--[[ The wave being fought, or the one just cleared during a breather. Clamped by
     GameModeConfig, so it is never nil — a caller in the lobby gets wave 1 and
     has FL_WavePhase to tell it that the round has not started. ]]
function RoundService:getWave(): any
	return GameModeConfig.getWave(math.max(waveIndex, 1))
end

function RoundService:isBreather(): boolean
	return phase == PHASE.Breather
end

function RoundService:isRunning(): boolean
	return roundState == Enums.RoundState.Starting or roundState == Enums.RoundState.InProgress
end

--[[ Seconds to the end of the whole round. Zero outside one, so a HUD can render
     it blind. ]]
function RoundService:getTimeRemaining(): number
	if not self:isRunning() then
		return 0
	end
	return math.max(roundEndsAt - serverNow(), 0)
end

--[[ Seconds to the end of the current phase — the wave, or the breather. ]]
function RoundService:getWaveTimeRemaining(): number
	if not self:isRunning() then
		return 0
	end
	return math.max(phaseEndsAt - serverNow(), 0)
end

function RoundService:getElapsed(): number
	if not self:isRunning() then
		return 0
	end
	return math.max(serverNow() - startedAt, 0)
end

-- ════════════════════════════════════════════════════════════════════════════
--  Boot
-- ════════════════════════════════════════════════════════════════════════════

function RoundService:init()
	-- GameModeConfig ships a validator and says to run it once at boot. If the
	-- waves and TotalDuration ever disagree the round timer and the waves drift
	-- apart, and the symptom (wave 7 ending before the clock does) is miles from
	-- the cause.
	local ok, problem = GameModeConfig.validate()
	if not ok then
		warn("[RoundService] GameModeConfig is inconsistent: " .. tostring(problem))
	end

	setGameAttribute(Attributes.Game.Mode, mode)
	setGameAttribute(Attributes.Game.RoundState, roundState)
	setGameAttribute(Attributes.Game.WaveIndex, 0)
	setGameAttribute(Attributes.Game.WavePhase, phase)
	setGameAttribute(Attributes.Game.WaveEndsAt, 0)
	setGameAttribute(Attributes.Game.RoundEndsAt, 0)
end

function RoundService:start()
	local survivors = Registry.find("SurvivorService")
	if survivors then
		--[[ Callouts for the two things a team must hear over gunfire. The line
		     is spoken BY the survivor it happened to, so SubtitleController draws
		     their name in the same colour as their HUD panel and their outline. ]]
		if survivors.stateChanged then
			serviceTrove:add(survivors.stateChanged:connect(function(player, newState, oldState)
				if not self:isRunning() then
					return
				end
				if newState == oldState then
					return
				end
				if newState == Enums.SurvivorState.Incapacitated then
					say(player.DisplayName, "I'm down!", SAY_CALLOUT)
				elseif newState == Enums.SurvivorState.LedgeHanging then
					say(player.DisplayName, "I'm hanging! Help!", SAY_CALLOUT)
				end
			end))
		end
		if survivors.died then
			serviceTrove:add(survivors.died:connect(function(player)
				if self:isRunning() then
					say("", string.format("%s is dead.", player.DisplayName), SAY_CALLOUT)
				end
			end))
		end
	end

	serviceTrove:connect(Players.PlayerAdded, function()
		self:_startIfReady()
	end)

	-- The lobby is quiet on purpose. The Director starts life active, so without
	-- this it runs its own pacing against a round nobody has started yet.
	setWaveBudget(0, 1, 0, 0, false)
	setDirectorActive(false)

	-- THE loop. One connection for the whole round, throttled: everything in it
	-- is a deadline comparison and a list length.
	serviceTrove:connect(RunService.Heartbeat, function(delta)
		accumulator += delta
		if accumulator < TICK_INTERVAL then
			return
		end
		accumulator = 0
		self:_step()
	end)

	self:_startIfReady()
end

function RoundService:destroy()
	generation += 1
	serviceTrove:destroy()
end

Registry.register("RoundService", RoundService)

return RoundService
