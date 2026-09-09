--!nonstrict
--[[
	RoundService — the seventeen minutes.

	A round is a fixed schedule: fifteen seconds of prep, then fifteen waves with a
	breather after each, totalling exactly GameModeConfig.Classic.TotalDuration.
	This service owns that clock and nothing else. It does not decide what spawns
	or where — the Director does, and keeps every bit of its intelligence — it
	decides WHEN pressure happens and hands the Director the budget it is allowed
	to spend inside each wave.

	── THE SCHEDULE IS ABSOLUTE ────────────────────────────────────────────────
	Every phase boundary is computed from the round's start time and
	GameModeConfig's own numbers, never accumulated tick by tick. A hitched
	server, a long LoadCharacter, a tick that lands 200ms late — none of them can
	push the finale out of place, because wave 15 starts when the clock says so
	and not when the previous phase happens to notice it is done.

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

	The random events have things to say too — a radio transmission, a supply
	drop's location — and they ASK, through `announce` below, rather than firing
	the remote themselves. One producer is worth keeping: it is what lets the
	queueing, the pacing and the speaker colours stay one problem instead of two.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attributes = require(Shared.Net.Attributes)
local AudioConfig = require(Shared.Config.AudioConfig)
local Enums = require(Shared.Enums)
local GameConfig = require(Shared.Config.GameConfig)
local GameModeConfig = require(Shared.Config.GameModeConfig)
local MapConfig = require(Shared.Config.MapConfig)
local InfectedConfig = require(Shared.Config.InfectedConfig)
local ModifierConfig = require(Shared.Config.ModifierConfig)
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

--[[ The one source of chance in the wave schedule. Its own generator rather than
     math.random so nothing else in the round can perturb the sequence of bosses
     a server hands out, and so a future "seeded round" only has to reseed here. ]]
local bossRng = Random.new()

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
--[[ Map the next round will load, decided by the vote as the last one ended. ]]
local pendingMap = ""
local phase = PHASE.Over
local waveIndex = 0

local startedAt = 0 -- absolute server time the prep window opened
local roundEndsAt = 0 -- absolute server time the schedule runs out
local phaseEndsAt = 0 -- absolute server time the current phase ends

local schedule: { any } = {}
local cursor = 0
local generation = 0 -- invalidates every delayed callback from an older round

--[[ The round's one condition, or nil. Kept alongside the attribute so this
     file can announce it and read its flags without a lookup per wave; the
     ATTRIBUTE is what every other file reads. ]]
local activeModifier: any = nil

--[[
	The pre-round ready gate.

	`holdUntil` is an absolute stamp: the latest moment wave 1 will wait. While
	the hold is on, `_step` pushes startedAt forward instead of advancing the
	schedule — which freezes the ROUND rather than pausing a phase, so every
	wave, the boss, and the round's own end time all move together and none of
	the arithmetic downstream has to know the gate exists.

	`holdSince` is the last moment that shift was applied. The push is computed
	from the gap between steps rather than accumulated per frame, so a server
	hitch during the hold does not quietly eat seconds off the round.
]]
--[[ When the round's clock stopped, or 0. Owned by PauseService, which decides
     WHETHER a pause is allowed; this only knows how to hold the schedule still
     while one is on. ]]
local pausedSince = 0

local holdUntil = 0
local holdSince = 0

--[[ False until every module's start() has run. _startIfReady refuses to do
     anything before then; see the comment there for why that matters. ]]
local bootComplete = false

local sawLivingSurvivor = false
--[[ When the team stopped being able to recover, or 0 while it still can. The
     wipe is declared CLASSIC.TeamWipeGrace after this rather than on the frame
     it happens — see _checkWipe. ]]
local downSince = 0
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
	--[[ The round's modifier, applied HERE rather than inside the Director. This
	     is the one place a wave's numbers cross from the schedule into the thing
	     that spends them, so a modifier that scales the horde only has to be
	     right once — and the Director keeps its own clamps, which is what stops
	     DOUBLE SPAWN asking for more Commons than the roster can produce. ]]
	--[[
		And how many people are actually here.

		Applied in the same place and for the same reason the modifier is: this
		is the one seam a wave's numbers cross on their way to the thing that
		spends them, so a scale that has to be right has to be right once.

		Every number in the wave table is written against a full team, and until
		now nothing divided them by anything — a solo player got four players'
		horde and, far worse, four players' specials. See
		GameModeConfig.Headcount: a pin needs a teammate to break, so alone the
		first Hunter of the round ends it.

		Counted off the ROSTER rather than off who is still upright. Scaling on
		the living would soften the round the moment somebody went down, which
		pays a team for losing people.
	]]
	local crew = GameModeConfig.headcountRow(#Players:GetPlayers())

	director:setWaveBudget({
		populationScale = populationScale * ModifierConfig.populationScale(Workspace) * crew.population,
		spawnRateScale = spawnRateScale * ModifierConfig.spawnRateScale(Workspace) * crew.spawnRate,
		--[[ Floored at one. A wave that declared specials must be able to send
		     one of them, or a solo round quietly loses the entire special
		     roster and becomes a Common simulator. ]]
		maxSpecialsAlive = if maxSpecials > 0
			then math.max(1, math.floor(maxSpecials * crew.specials + 0.5))
			else 0,
		--[[ DIVIDED: this is seconds between specials, so a crew factor below one
		     has to make the gap longer rather than shorter. ]]
		specialInterval = specialInterval / math.max(crew.specialPace, 0.05),
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

--[[
	Rolls the round's one condition, publishes it, and lets everything that cares
	read it off Workspace.

	Classic only. Versus works because both halves face the same fifteen waves,
	and a modifier rolled per half would measure two teams against two different
	games — see the header of Shared/Config/ModifierConfig. It is cleared rather
	than left, so a Versus match that follows a Classic round on the same server
	does not inherit one.

	Called from startRound BEFORE the schedule is built and before anybody
	spawns, because the atmosphere, the Director's budget and the first Common's
	health all read it and all of them happen after.
]]
local function rollModifier()
	local chosen: any = nil
	if mode == GameModeConfig.Modes.Classic then
		chosen = ModifierConfig.roll(random)
	end
	setGameAttribute(Attributes.Game.Modifier, if chosen then chosen.id else "")
	activeModifier = chosen
end

--[[ Asks the Director to place a boss. It picks the FL_BossZone, honours the
     sight rules and fires its own Boss music cue — this only says "now". ]]
local function releaseBoss(kind: string, elite: string?)
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
	director:releaseBoss(kind, elite)
end

--[[ "TANK!" for one, "TANK! 2 of them." for a wave whose pack roll came up. The
     wave's own announcement already sets the tone; this is the specific.

     Grouped by kind AND tier rather than by kind alone, because a wave can now
     release two different things and only one of them may be elite. ]]
local function bossCallout(releases: { GameModeConfig.BossRelease }): string?
	local order: { string } = {}
	local counts: { [string]: number } = {}
	local labels: { [string]: string } = {}

	for _, release in releases do
		local kind = release.kind
		local definition = InfectedConfig.get(kind)
		local plain = if definition then definition.displayName else kind

		--[[ An elite boss is called out by the TIER's name, not the kind's: the
		     wave that releases an Apex Tank shouts "APEX TANK!", because a team
		     that hears the same word it heard on wave 5 will bring the same
		     plan. ]]
		local eliteTier = InfectedConfig.elite(release.tier)
		local label = if eliteTier then eliteTier.titlePrefix .. " " .. plain else plain
		local key = label

		if not counts[key] then
			counts[key] = 0
			labels[key] = string.upper(label)
			table.insert(order, key)
		end
		counts[key] += 1
	end

	local parts: { string } = {}
	for _, key in order do
		if counts[key] > 1 then
			table.insert(parts, string.format("%s! %d of them.", labels[key], counts[key]))
		else
			table.insert(parts, string.format("%s!", labels[key]))
		end
	end
	if #parts == 0 then
		return nil
	end
	return table.concat(parts, " ")
end

--[[ How many people are on their feet right now. This is what the Tank pack roll
     scales against, rather than the size of the lobby: four in the match with two
     of them on the floor is a team of two for as long as that lasts, and a second
     Tank landing on it is not a harder wave, it is the end of the round. ]]
local function uprightCount(): number
	local survivors: any = Registry.find("SurvivorService")
	if not survivors then
		return 0
	end
	if typeof(survivors.getRescueCounts) == "function" then
		local _, upright = survivors:getRescueCounts()
		return upright
	end
	return #survivors:getAliveSurvivors()
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

		-- The last wave has no breather; the schedule simply ends and the team has won.
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

--[[
	Who the ready gate is waiting on, and how many of them have answered.

	Everyone who is IN the round, not everyone in the server: a spectator has no
	stake in the requisitions being chosen and nothing to ready up for, and
	waiting on one is how a gate with a cap turns into a gate that always runs
	the cap.

	Counted rather than tracked, because both halves can change under the gate —
	a player joins during prep, a player leaves — and a running tally that had to
	be corrected on both edges is a tally that will eventually be wrong.
]]
local function readyTally(): (number, number)
	local survivors = Registry.find("SurvivorService")
	if not survivors or typeof(survivors.getAliveSurvivors) ~= "function" then
		return 0, 0
	end
	local ok, alive = pcall(survivors.getAliveSurvivors, survivors)
	if not ok or typeof(alive) ~= "table" then
		return 0, 0
	end
	local ready = 0
	for _, player in alive do
		if player:GetAttribute(Attributes.Player.Ready) == true then
			ready += 1
		end
	end
	return ready, #alive
end

local function publishReady(holding: boolean)
	local ready, needed = readyTally()
	setGameAttribute(Attributes.Game.ReadyHold, holding)
	setGameAttribute(Attributes.Game.ReadyCount, ready)
	setGameAttribute(Attributes.Game.ReadyNeeded, needed)
end

--[[ Every answer wiped, at the top of every prep. Last round's "ready" is not
     this round's, and a flag that survived would start the new one instantly
     for anyone who had not touched it since. ]]
local function clearReady()
	for _, player in Players:GetPlayers() do
		player:SetAttribute(Attributes.Player.Ready, false)
	end
end

--[[ Whether the gate should let go. An empty roster releases immediately rather
     than waiting out the cap — with nobody in the round there is nobody to wait
     for, and holding would just delay the wipe check that ends it. ]]
local function readySatisfied(): boolean
	local ready, needed = readyTally()
	return needed == 0 or ready >= needed
end

function RoundService:_enterPrep(entry)
	self:_publishPhase(entry)
	self:_publishRoundState(Enums.RoundState.Starting, { phase = phase, waveIndex = waveIndex })

	--[[ The gate opens here and `_step` closes it. Wave 1 waits for the team, or
	     for CLASSIC.ReadyCap, whichever comes first — see that constant for why
	     the cap is what makes waiting safe. ]]
	clearReady()
	holdSince = serverNow()
	holdUntil = holdSince + CLASSIC.ReadyCap
	publishReady(true)
	--[[ The client counts down THIS rather than the prep clock while the hold is
	     on, so the number on screen is the honest one: how long until the round
	     stops waiting. _releaseHold puts the prep clock back. ]]
	setGameAttribute(Attributes.Game.WaveEndsAt, holdUntil)

	-- Nothing spawns during prep. The window exists so a team can find a gun and
	-- find each other, and a Director trickling commons into it spends it.
	setWaveBudget(0, 1, 0, 0, false)
	setDirectorActive(false)

	--[[ The gate's line, not prep's. While the round is holding, "first wave in
	     15 seconds" is simply untrue — the wave is waiting on the team, and the
	     clock on screen is counting the cap. _releaseHold puts the prep line
	     back when the wait is actually over. ]]
	setObjective("Requisition and ready up — the round is waiting on you")
	say(
		"",
		string.format(
			"%d minutes until the lights come back on. Spend what you have, then call it.",
			math.floor(CLASSIC.TotalDuration / 60)
		),
		SAY_ANNOUNCE
	)

	--[[ And what is different about tonight. After the opening line rather than
	     instead of it: the first says what the round IS and is the same every
	     time, and this says what it is not. A modifier a player finds out about
	     by being caught by it is a modifier that reads as the game being broken. ]]
	if activeModifier then
		say("", string.upper(activeModifier.displayName) .. " — " .. activeModifier.blurb, SAY_ANNOUNCE)
	end

	-- The one stocking pass that is not a breather roll: the prep window is
	-- worthless if there is nothing on the shelves to pick up.
	local level = Registry.find("LevelService")
	if level and typeof(level.restockItems) == "function" then
		level:restockItems()
	end
end

function RoundService:_enterWave(entry)
	local temperament = Registry.find("DirectorTemperament")
	if temperament then
		temperament:beginWave(entry.index or 0)
	end

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
	     the finale must not walk in three seconds after a team wipe ended the
	     round. ]]
	if #wave.bosses > 0 then
		--[[ Rolled once, here, and everything downstream reads the RESULT: the
		     callout, the stagger and the spawns all have to agree, and a wave
		     that announced a Witch and sent a Tank would be a bug rather than a
		     surprise. See GameModeConfig.rollBosses for what can vary. ]]
		--[[ ELITE WAVE's promotion goes IN rather than being applied to what comes
		     out. rollBosses has to know about it before it rolls the pack: a
		     promoted boss does not get one, and promoting the list afterwards
		     would hand a full team three Apex Tanks on a single wave. ]]
		local promotion = if ModifierConfig.eliteBosses(Workspace) then "Apex" else nil
		--[[ The map's own finale, looked up HERE rather than inside rollBosses:
		     GameModeConfig requires Enums and nothing else on purpose, and the
		     map that is loaded is a fact this service already holds. Nil on every
		     map but the Backrooms, and nil is the ordinary answer. ]]
		local mapService = Registry.find("MapService")
		local mapId = mapService
			and typeof(mapService.getCurrentId) == "function"
			and mapService:getCurrentId()
		local finale = MapConfig.finaleBossFor(if typeof(mapId) == "string" then mapId else nil)
		local releases = GameModeConfig.rollBosses(wave, uprightCount(), bossRng, promotion, finale)

		local callout = bossCallout(releases)
		if callout then
			say("", callout, SAY_ANNOUNCE)
		end

		local mine = generation
		for order, release in releases do
			if order == 1 then
				releaseBoss(release.kind, release.tier)
			else
				task.delay((order - 1) * BOSS_STAGGER, function()
					if mine == generation and roundState == Enums.RoundState.InProgress then
						releaseBoss(release.kind, release.tier)
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

	-- The wave's own odds decide whether the map gets anything back. Wave 5 (the
	-- first Tank) is 0.7 and wave 15 is 0, which is the difficulty curve doing its
	-- work quietly rather than through a number on the screen.
	--[[ NO AMMO DROPS suppresses this and only this. The AIRDROP requisition
	     calls restockItems directly and still works, which is the point: the
	     modifier makes it worth buying rather than making it impossible. ]]
	if not ModifierConfig.blocksRestock(Workspace) and random:NextNumber() < wave.itemDropChance then
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
		--[[
			Only a real in-round death counts. Spectating is NOT a synonym for
			dead here: SurvivorService reports it for anyone with no record at
			all, which covers a Versus player who is currently an infected ghost
			and anyone who joined mid-round and is still sitting in the menu.
			Treating those as dead conscripted them into the survivor team every
			single breather — destroying the ghost's body, and dropping a player
			who was reading the menu into the middle of a wave.
		]]
		local state = survivors:getState(player)
		--[[ And not somebody who is out of lives for the round. The check is here
		     as well as inside _respawn, and both are wanted: the one there refuses
		     the respawn, and this one stops the body being released and the team
		     hearing "I'm back" from a player who is not. ]]
		local eliminated = typeof(survivors.isEliminated) == "function" and survivors:isEliminated(player)
		local isGone = state == Enums.SurvivorState.Dead and not eliminated

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
	It calls the PRIVATE `_respawn` deliberately: the public alternative,
	spawnSurvivor, returns a survivor at FULL health, which would make dying
	during a wave strictly better than being hurt by it.

	There used to be a `survivors.respawn` branch ahead of this one, tried first
	and never taken because no such method has ever existed. It was worse than
	dead: it omitted the _releaseBody call below, so the day anybody added a
	public respawn it would have quietly started leaving a defib-able corpse
	behind a living survivor. A guard for a method nobody has written is not
	future-proofing.
]]
function RoundService:_respawnSurvivor(survivors, player: Player, slot: number)
	local cframe: CFrame? = nil
	local level = Registry.find("LevelService")
	if level and typeof(level.getSurvivorSpawnCFrame) == "function" then
		cframe = level:getSurvivorSpawnCFrame(slot)
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
			"SurvivorService exposes no _respawn(player, cframe, health); breather respawns fall back "
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
     measured against the same fifteen waves. ]]
--[[ Whoever in this server has not walked out. The roster a round is actually
     for, as opposed to everybody connected to it. ]]
local function playersInTheMatch(): number
	local count = 0
	for _, player in Players:GetPlayers() do
		if player:GetAttribute(Attributes.Player.LeftMatch) ~= true then
			count += 1
		end
	end
	return count
end

function RoundService:startRound(requestedMode: string?)
	if roundState == Enums.RoundState.Starting or roundState == Enums.RoundState.InProgress then
		return
	end

	--[[
		A round with nobody in it never starts, and this is the guard that keeps
		LeftMatch from being worse than the bug it fixes.

		Skipping the spawn for a player who walked out means `sawLivingSurvivor`
		never becomes true, and the wipe check reads that — correctly — as "the
		round has not begun yet" rather than as a wipe. So a round started for a
		server where everyone had left would not end: it would run its full
		seventeen minutes with a Director sending waves at an empty map, and only
		the clock would stop it.

		Staying in the lobby is the honest answer. Somebody picking a mode clears
		their own flag and the next tick starts the round properly.
	]]
	if playersInTheMatch() == 0 then
		return
	end

	--[[ The Director's temperament for this round, rolled here because this is
	     where a round begins and nowhere else was calling it.

	     beginRound is the only caller of rollTemperament, and nothing called
	     beginRound — so state.temperament sat on its initialiser, Temperaments[1]
	     = "Measured", for the entire life of the server. Every round anybody has
	     ever played has had the same Director personality, and the boot line
	     claiming one was rolled printed for a roll that never happened. The wave
	     hook beside it (beginWave) was wired; the round hook was not. ]]
	local temperament = Registry.find("DirectorTemperament")
	if temperament and typeof(temperament.beginRound) == "function" then
		pcall(temperament.beginRound, temperament)
	end

	mode = if typeof(requestedMode) == "string" and GameModeConfig.Modes[requestedMode]
		then requestedMode
		else GameModeConfig.DefaultMode

	generation += 1
	rollModifier()

	schedule = buildSchedule()
	cursor = 1
	pausedSince = 0
	startedAt = serverNow()
	roundEndsAt = startedAt + CLASSIC.TotalDuration
	sawLivingSurvivor = false
	downSince = 0
	warnedFinal = false

	--[[
		Claim the round BEFORE anything below yields. spawnSurvivor ends in
		player:LoadCharacter(), which yields once per player and can hold this
		function for a quarter of a second on a full server — long enough for
		MatchmakingService's own tick to see Lobby again and call startRound a
		second time, which would bump the generation, cancel in-flight boss
		releases, and re-LoadCharacter everyone. _enterPrep re-publishes the same
		value, and setGameAttribute skips an unchanged write, so this costs
		nothing.
	]]
	roundState = Enums.RoundState.Starting

	-- A scoreboard showing last round's kills is worse than one showing none.
	local statsService = Registry.find("StatsService")
	if statsService then
		statsService:reset()
	end

	--[[ Swap to whatever the vote landed on. `ensure` is a no-op when the winner
	     is already live, so voting to replay a map costs nothing rather than
	     throwing away a perfectly good world and paying for a reload. ]]
	local vote = Registry.find("MapVoteService")
	if vote then
		if vote:isActive() then
			-- Forced start before the clock ran out: honour the vote as it stands
			-- rather than discarding it.
			pendingMap = vote:finishNow()
		end
		--[[ Spend the decision. Clearing it here is what lets the next lull open a
		     fresh vote instead of the server believing the map was already
		     chosen for every subsequent round. ]]
		local decided = vote:consumeDecision()
		if decided ~= "" then
			pendingMap = decided
		end
	end

	local maps = Registry.find("MapService")
	if maps then
		maps:ensure(if pendingMap ~= "" then pendingMap else MapConfig.DefaultMap)
	end
	pendingMap = ""

	-- Every crate back, so a new round never opens with half its resupply still
	-- on cooldown from the last one.
	local crates = Registry.find("AmmoCrateService")
	if crates then
		crates:resetAll()
	end

	--[[ And every crescendo back, for exactly the same reason. A panic trigger
	     latches when it fires and nothing used to put it back, so the map's only
	     set piece ran on the first round after a server booted and never again. ]]
	local level = Registry.find("LevelService")
	if level and typeof(level.resetTriggers) == "function" then
		level:resetTriggers()
	end

	setGameAttribute(Attributes.Game.Mode, mode)
	setGameAttribute(Attributes.Game.RoundEndsAt, roundEndsAt)

	local level = Registry.find("LevelService")
	if level and typeof(level.placeSurvivors) == "function" then
		level:placeSurvivors()
	end

	--[[ Everyone starts this round on their feet, including whoever was dead when
	     the last one ended — but NOT whoever walked out. A player sitting in the
	     main menu having deliberately left is the one person in the server who
	     has said they do not want this, and spawning them anyway is how "return
	     to main menu" turned out to mean "return to main menu until the next
	     round starts". They come back by picking a mode. ]]
	local survivors = Registry.find("SurvivorService")
	if survivors then
		local expected = {}
		for _, player in Players:GetPlayers() do
			if player:GetAttribute(Attributes.Player.LeftMatch) ~= true then
				survivors:spawnSurvivor(player)
				table.insert(expected, player)
			end
		end

		--[[
			And then check it actually happened.

			spawnSurvivor resets health, temp health, both ledgers and the rescue
			queue and then calls LoadCharacter, so a round is meant to open with
			every player upright at full strength whatever the last one left
			behind. This says so out loud when it does not.

			The STATE and the health, not the character: LoadCharacter has not
			finished by the time this runs and never will have, so testing for a
			body would fail every single round. What is being verified is that the
			service agreed to the spawn — which is the half that can silently not
			happen, and the half everything else reads.
		]]
		local wrong = {}
		for _, player in expected do
			local state = survivors:getState(player)
			local health = player:GetAttribute(Attributes.Player.Health) or 0
			if state ~= Enums.SurvivorState.Healthy or health < GameConfig.Survivor.MaxHealth then
				table.insert(wrong, string.format("%s (%s, %d hp)", player.Name, state, health))
			end
		end
		if #wrong > 0 then
			warn(
				string.format(
					"[RoundService] the round started with %d player(s) not upright at full health: %s "
						.. "— every one of them should have been reset by SurvivorService.spawnSurvivor",
					#wrong,
					table.concat(wrong, ", ")
				)
			)
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

	--[[ The gate goes down with the round. A round that ended DURING the hold —
	     everyone left, or the last survivor quit — would otherwise leave
	     ReadyHold lit on Workspace with nothing left to release it. ]]
	holdUntil = 0
	holdSince = 0
	publishReady(false)

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

	local mine = generation

	--[[
		The result gets the screen to itself, and THEN the vote.

		This used to open the vote on the same frame the round ended, so a card
		asking about the next map landed on top of the moment a team found out
		whether they held. Whatever the round was worth went with it.

		The winner is still cloned into storage the moment it is known, so the
		swap at the start of the next round is a reparent either way — the delay
		costs presentation time, not loading time.
	]]
	task.delay(GameModeConfig.Matchmaking.ResultsDuration, function()
		if mine ~= generation then
			return
		end

		--[[
			A WIPE ENDS THE RUN, NOT JUST THE ROUND.

			The team died. There is no next map for them to vote on and no reason
			to hold everybody in a lobby waiting to be spawned into another one —
			so once the scoreboard has had its eight seconds, the server sends
			them back to the main menu, which is the same place RETURN TO MAIN MENU
			puts them and by the same mechanism.

			LeftMatch is the flag that makes it stick. It outlives the round, so
			the post-round _startIfReady below finds nobody in the match and does
			not start one; picking a mode again is what clears it, which is
			MatchmakingService's job and the reason coming back is a decision.

			A VICTORY is deliberately not this. Holding out earns the next map, and
			the vote is the thing that offers it.
		]]
		if outcome == Enums.RoundState.TeamWipe then
			local survivors = Registry.find("SurvivorService")
			for _, player in Players:GetPlayers() do
				player:SetAttribute(Attributes.Player.LeftMatch, true)
				player:SetAttribute(Attributes.Player.Ready, false)
				if survivors and typeof(survivors.leaveRound) == "function" then
					survivors:leaveRound(player)
				end
			end
			Remotes.Event.ReturnToMenu:FireAllClients({ reason = outcome })
			return
		end

		local vote = Registry.find("MapVoteService")
		if vote then
			pendingMap = vote:beginVote()
		end
	end)

	-- A server that sits on a result screen forever cannot be playtested twice.
	-- MatchmakingService owns this decision when it exists; until then the round
	-- comes back on its own.
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
	-- Folded in rather than replaced: the attribute-derived fields below are
	-- readable even while services are tearing down, and the tally is a bonus
	-- when it is there rather than something the scoreboard depends on.
	local tally = {}
	local statsService = Registry.find("StatsService")
	if statsService then
		local ok, snapshot = pcall(function()
			return statsService:snapshot()
		end)
		if ok and typeof(snapshot) == "table" then
			tally = snapshot
		end
	end

	local scores = {}
	for _, player in Players:GetPlayers() do
		local state = Attributes.get(player, Attributes.Player.State, Enums.SurvivorState.Spectating)
		local row = {
			state = state,
			alive = state ~= Enums.SurvivorState.Dead and state ~= Enums.SurvivorState.Spectating,
			incaps = Attributes.get(player, Attributes.Player.IncapCount, 0),
		}
		local counted = tally[player.Name]
		if typeof(counted) == "table" then
			for key, value in counted do
				if row[key] == nil then
					row[key] = value
				end
			end
		end
		scores[player.Name] = row
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

	--[[ And the ready gate, for the same reason endRound clears it: an empty
	     server during the hold must not leave ReadyHold lit for whoever joins
	     next. ]]
	holdUntil = 0
	holdSince = 0
	pausedSince = 0
	publishReady(false)

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

	--[[
		Nothing auto-starts until the server has finished booting.

		This is the whole reason the main menu kept vanishing, and it took two
		goes to get right because there are two callers. The check below asks
		whether MatchmakingService has `started`, and during the boot the honest
		answer is "not yet" — it starts several entries after this one, and that
		stays true however the list is reordered because a service cannot have
		started before the phase reaches it. (The exact positions used to be
		written down here and drifted the first time a module was inserted
		between them.) Read as "there is no matchmaking here", that starts a
		round in the middle of boot.

		Deferring the call at the end of start() fixed only that one caller.
		Players.PlayerAdded is the other, and in Studio's Play Solo the player
		joins WHILE modules are still starting, so it walked straight through the
		same hole. Gating the function itself covers every caller there will ever
		be, including the next one somebody adds.
	]]
	if not bootComplete then
		return
	end

	--[[
		Only stand down for a matchmaking service that actually finished starting.
		It sets `started` as the final statement of its own start(), which the
		bootstrap pcalls — so a service that threw partway through is registered
		but inert, and if we deferred to it nothing would ever start a round.
	]]
	local matchmaking = Registry.find("MatchmakingService")
	if matchmaking and matchmaking.started then
		return
	end
	if #Players:GetPlayers() < CLASSIC.MinPlayersToStart then
		return
	end

	--[[ Said out loud, because it is the unusual path. A round beginning without
	     anybody choosing a mode is correct only when there is genuinely no
	     matchmaking on this server, and if that is ever wrong again this line is
	     what says so in the first second of the log. ]]
	print(
		string.format(
			"[RoundService] starting %s directly — no MatchmakingService is running, %d player(s) present",
			mode,
			#Players:GetPlayers()
		)
	)
	self:startRound(mode)
end

-- ════════════════════════════════════════════════════════════════════════════
--  The tick
-- ════════════════════════════════════════════════════════════════════════════

--[[
	A team that cannot recover ends the round.

	Read from survivor STATE rather than from whether a character exists: a
	character is briefly nil across every respawn, and a wipe declared in that
	gap would end a round the team was still winning.

	── WHY THIS IS NOT "EVERYBODY DEAD" ────────────────────────────────────────
	It used to be. getAliveSurvivors counts anyone who is not Dead and not
	Spectating, which includes every INCAPACITATED survivor — so four people on
	the floor calling for help was not a wipe, and the round ran until the last
	of them bled out. At IncapBleedPerSecond against IncapHealth that is a
	hundred and fifty seconds each, with nobody able to do anything about it:
	a revive, a pull-up and a defibrillator are interactions only an UPRIGHT
	survivor may begin, and there were none.

	So the question is not "is anyone alive" but "can anyone still change the
	outcome", which SurvivorService.canTeamRecover answers — and which
	deliberately still counts a PINNED survivor, because a downed teammate can
	shoot the thing holding them.

	`sawLivingSurvivor` still guards the start: every survivor is Spectating for
	the moment before the first spawn, and that must not read as a wipe.
]]
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
	end
	if not sawLivingSurvivor or #Players:GetPlayers() == 0 then
		downSince = 0
		return false
	end

	if survivors:canTeamRecover() then
		downSince = 0
		return false
	end

	--[[ Held for a beat. There is nothing to recover from — the check above
	     already said so — but the last survivor going down is a moment, and
	     cutting to a scoreboard on the same frame reads as the game looking
	     away from it. ]]
	local now = os.clock()
	if downSince == 0 then
		downSince = now
		return false
	end
	if now - downSince < CLASSIC.TeamWipeGrace then
		return false
	end

	self:endRound(Enums.RoundState.TeamWipe)
	return true
end

--[[
	Holds wave 1 while the team decides, and returns true while it is holding.

	It works by pushing `startedAt` FORWARD rather than by pausing a phase. That
	distinction is the whole design: everything about a round — every wave
	boundary, the boss releases, the round's own end — is an offset from
	startedAt, so moving it moves all of them together and not one line of the
	arithmetic downstream has to learn that a gate exists. Pausing the prep phase
	alone would have started wave 1 late and then run the remaining fourteen on
	the original clock.

	Released by the team readying up, or by CLASSIC.ReadyCap, whichever comes
	first. The cap is what makes this safe to ship: see GameModeConfig.

	The push is measured between steps rather than added per frame, so a hitch
	during the hold cannot quietly cost the round seconds.
]]
--[[
	Holds the entire schedule still while the game is paused.

	The same trick the ready gate uses, and reusing it is the reason a pause did
	not need a single line of new arithmetic anywhere downstream: every wave
	boundary, every boss release and the round's own end are offsets from
	`startedAt`, so pushing that forward pushes all of them together. See
	_stepHold, which explains it at length and has been carrying it since before
	pausing existed.

	Measured between steps rather than added per frame, so a hitch during a pause
	cannot quietly cost the round seconds — and so a pause that outlives a server
	hiccup is still exactly as long as it looked.
]]
function RoundService:_stepPause(): boolean
	if pausedSince == 0 then
		return false
	end

	local now = serverNow()
	local shift = math.max(now - pausedSince, 0)
	pausedSince = now
	startedAt += shift
	roundEndsAt += shift
	phaseEndsAt += shift
	--[[ The ready gate can be up when the pause starts — a solo player pausing
	     during prep is the single most likely time for this to happen at all —
	     and its own deadline is in the same clock. ]]
	if holdUntil > 0 then
		holdUntil += shift
		holdSince += shift
	end

	setGameAttribute(Attributes.Game.RoundEndsAt, roundEndsAt)
	setGameAttribute(Attributes.Game.WaveEndsAt, if holdUntil > 0 then holdUntil else phaseEndsAt)
	return true
end

--[[ Starts and stops the hold above. PauseService owns the policy — who may
     pause, and when — and calls this; RoundService owns nothing but the clock. ]]
function RoundService:setClockPaused(on: boolean)
	if on == true then
		if pausedSince == 0 then
			pausedSince = serverNow()
		end
		return
	end

	if pausedSince == 0 then
		return
	end
	--[[ One last shift on the way out, so the tail of the pause between the most
	     recent step and this moment is paid for as well. Without it every pause
	     quietly costs the round up to one tick — bounded rather than
	     accumulating, but a player who pauses often enough would still be handed
	     a shorter round than one who never does, and there is no reason to make
	     them pay for it. ]]
	self:_stepPause()
	pausedSince = 0
end

function RoundService:_stepHold(): boolean
	if holdUntil <= 0 then
		return false
	end

	local now = serverNow()
	if readySatisfied() or now >= holdUntil then
		self:_releaseHold()
		return false
	end

	local shift = math.max(now - holdSince, 0)
	holdSince = now
	startedAt += shift
	roundEndsAt += shift
	phaseEndsAt += shift
	setGameAttribute(Attributes.Game.RoundEndsAt, roundEndsAt)

	--[[ Republished every step because a player joining or leaving changes the
	     denominator, and a gate showing "2 / 4" to a team of three is a gate
	     nobody trusts. It is one attribute write on an unchanged value, which
	     setGameAttribute skips. ]]
	publishReady(true)
	return true
end

--[[ Lets the round go. The prep clock is put back to a full PrepDuration from
     NOW rather than from the original start, so a team that readied instantly
     still gets its fifteen seconds to find a gun — the gate buys deliberation
     time, it does not spend the run-up. ]]
function RoundService:_releaseHold()
	if holdUntil <= 0 then
		return
	end
	holdUntil = 0
	holdSince = 0
	publishReady(false)

	local entry = schedule[cursor]
	if not entry then
		return
	end
	phaseEndsAt = startedAt + entry.endsAt
	setGameAttribute(Attributes.Game.WaveEndsAt, phaseEndsAt)
	setObjective(string.format("Gear up — first wave in %d seconds", math.floor(CLASSIC.PrepDuration)))
	say("", "Move out.", SAY_ANNOUNCE)
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

	--[[ Ahead of the wipe check on purpose. Nothing can hurt anybody while the
	     game is paused, so the only thing _checkWipe could do with a paused round
	     is trip its own grace timer on a team that went down before the pause and
	     call it a wipe they never had a chance to answer. ]]
	if self:_stepPause() then
		return
	end

	if self:_checkWipe() then
		return
	end

	if self:_stepHold() then
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
			-- Reaching the end of the last wave alive is the win, at four survivors
			-- or at one. Unconditional, and deliberately: GameModeConfig has a
			-- VictoryRequiresAllAlive flag set false, but nothing reads it, so
			-- naming it here read as "this line honours the flag" when in fact
			-- flipping it would change nothing at all. Either wire it up or drop
			-- it; until then the behaviour is stated rather than delegated.
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

--[[ The game's voice, for another service that has a line to deliver. The same
     `say` the waves and the bosses use — see the header on callouts — so an
     event's transmission queues behind a wave announcement instead of landing on
     top of it. ]]
function RoundService:announce(speaker: any, text: any, duration: any)
	if typeof(text) ~= "string" or text == "" then
		return
	end
	say(
		if typeof(speaker) == "string" then speaker else "",
		text,
		if typeof(duration) == "number" then duration else nil
	)
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
	-- apart, and the symptom (the last wave ending before the clock does) is miles from
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
	--[[
		The team's answer to the ready gate.

		The only thing a client sends about it, and it decides nothing on its
		own: it sets one boolean and `_stepHold` re-reads the whole roster on the
		next step. A client that spams it, sends a non-boolean, or claims to be
		ready while spectating changes nothing — readyTally only counts players
		SurvivorService says are in the round.

		Accepted only while the gate is actually open. Outside it a "ready" flag
		means nothing and setting one would leave the attribute lit through a
		round for no reason.
	]]
	serviceTrove:connect(Remotes.Event.SetReady.OnServerEvent, function(player: Player, ready: any)
		if holdUntil <= 0 then
			return
		end
		player:SetAttribute(Attributes.Player.Ready, ready == true)
		publishReady(true)
	end)

	--[[
		Leaving a match in progress.

		Drops the sender out of the round and back to the lobby. It does NOT put
		them in another server: the mode entries on the main menu are how a player
		moves servers here, and this is the smaller thing — stop playing THIS
		round, keep the connection, be here for the next one.

		SurvivorService owns what that means to a body, so this asks rather than
		reaching in. The round carries on for everybody else; if the leaver was
		the last one standing, the wipe check on the next step ends it exactly as
		it would have if they had died.
	]]
	serviceTrove:connect(Remotes.Event.LeaveMatch.OnServerEvent, function(player: Player)
		--[[
			Marked BEFORE the running check, and that ordering is the whole fix.

			The guard used to cover this entire handler, which meant leaving was a
			no-op in exactly the state a player is most likely to do it from: the
			result screen after a wipe. RoundState is TeamWipe there, isRunning is
			false, nothing happened — and then the next round started and spawned
			everybody in the server, which put somebody who had walked out back in
			a match with the menu still fading off their screen.

			The flag is what makes RETURN TO MAIN MENU mean it. It outlives the
			round, and picking a mode again is what clears it — see
			MatchmakingService.requestMode. Leaving is a decision, so coming back
			is one too.
		]]
		player:SetAttribute(Attributes.Player.LeftMatch, true)

		--[[ Their vote no longer counts toward the gate. Without this, one player
		     leaving during prep could leave the tally at 3/4 forever — the
		     denominator drops with them, but only if it is recounted. ]]
		player:SetAttribute(Attributes.Player.Ready, false)

		--[[
			And out of the survivor roster, in EVERY state.

			This used to return early unless a round was running, on the reasoning
			that taking a body out needs a round to take it out of. The body, yes.
			The RECORD, no — records outlive rounds, and that is the whole bug.

			Victory, TeamWipe and Lobby all report isRunning() false, and the
			results screen is exactly where this remote gets fired: the client
			sends LeaveMatch on every dismissal of the poster. So a player who
			clicked through their victory screen kept a record in Healthy for the
			rest of the server's life, with no body and no intention of playing.
			canTeamRecover then answers true forever on their behalf, _checkWipe
			can never fire, and the NEXT round cannot end when its real survivors
			go down — it runs its full seventeen minutes with somebody bleeding
			out on the floor and nobody left to reach them.

			leaveRound already returns false for a player who is Spectating, so
			calling it in the lobby is a no-op rather than a special case. The
			lines below it still need a live round, and still say so.
		]]
		local survivors = Registry.find("SurvivorService")
		if survivors and typeof(survivors.leaveRound) == "function" then
			survivors:leaveRound(player)
		end

		if not self:isRunning() then
			return
		end

		if holdUntil > 0 then
			publishReady(true)
		end
		say("", string.format("%s has left the match.", player.DisplayName), SAY_CALLOUT)
	end)

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

	--[[
		Deferred, not called here.

		This runs during the bootstrap's start phase, and MatchmakingService is
		further down the list — so at this instant its `started` flag is still
		false and _startIfReady cannot tell "no matchmaking on this server" from
		"matchmaking has not had its turn yet". It read the second as the first
		and started a round at boot. (How MANY entries further down was written
		here once and stopped being true the moment one was inserted between
		them; what matters is only that it is after.)

		Live servers hid it: players arrive after the boot completes, so the
		PlayerAdded path always saw a started matchmaking. Studio's Play Solo does
		not — the player is already there while modules are still starting, Classic
		needs one player, and the round began before the client had drawn its main
		menu. The menu then opened onto a round already in progress and
		immediately closed itself, which looks exactly like the menu being gone.

		task.defer puts this after the whole start phase, which is the earliest
		moment the flag means what it says.
	]]
	--[[ task.defer lands after the bootstrap's synchronous start phase, which is
	     the earliest moment MatchmakingService's `started` flag means what it
	     says. Everything that wants to auto-start a round waits for this. ]]
	local booted = generation
	task.defer(function()
		-- Not if the service was torn down in between; destroy() bumps generation.
		if generation ~= booted then
			return
		end
		bootComplete = true
		self:_startIfReady()
	end)
end

function RoundService:destroy()
	generation += 1
	bootComplete = false
	serviceTrove:destroy()
end

Registry.register("RoundService", RoundService)

return RoundService
