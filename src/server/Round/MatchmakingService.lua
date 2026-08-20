--!nonstrict
--[[
	MatchmakingService — which round you are in, and when it starts.

	One place, one round per server. A player opens the main menu, picks a mode,
	and this service answers exactly one question: do they play HERE, or somewhere
	else? Left 4 Dead answers it the same way, and the order matters more than the
	mechanism:

	  1. Here, if here will have them. The server is idle, or it is already running
	     that mode and is still inside JoinInProgressUntilWave with room. No
	     teleport, no network round trip — this is the overwhelmingly common case
	     and it has to feel like the menu closed, not like a matchmaker ran.
	  2. Somebody else's server, found in the MemoryStore browser and reached with
	     TeleportToPlaceInstance.
	  3. Nobody's server. This one claims the mode and counts down.

	── FILL SERVERS, DO NOT SPREAD THEM ────────────────────────────────────────
	The browser is sorted so the FULLEST joinable server wins. Spreading eight
	players across eight servers gives eight people a lonely map and a Director
	with nothing to work with; putting all eight in one gives them a horde. That
	single sort direction is most of what makes the game feel populated.

	── IT MUST DEGRADE INTO A PLAYABLE ROUND ───────────────────────────────────
	MemoryStoreService is unavailable in Studio and throws. TeleportService fails
	there too. Every call into either is wrapped, and every failure path leads to
	the same place: run it on this server. A developer pressing Play must always
	get a round, because a matchmaking error is a game that cannot be tested, and
	an untestable game stops being worked on.

	RoundService owns the round itself — the waves, the clock, the Director's
	budget. This service decides WHICH round a player is in and WHEN one starts,
	and then gets out of the way.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TeleportService = game:GetService("TeleportService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local AudioConfig = require(Shared.Config.AudioConfig)
local Enums = require(Shared.Enums)
local GameModeConfig = require(Shared.Config.GameModeConfig)
local Registry = require(Shared.Util.Registry)
local Remotes = require(Shared.Net.Remotes)
local Trove = require(Shared.Util.Trove)

local MM = GameModeConfig.Matchmaking
local MODES = GameModeConfig.Modes

--[[ MemoryStoreService does not exist on every platform this code can be run on
     (and asking for a service that is not there throws), so even the lookup is
     guarded. Everything downstream treats a missing map as "no other servers". ]]
local memoryStoreService: any = nil
do
	local ok, service = pcall(game.GetService, game, "MemoryStoreService")
	if ok then
		memoryStoreService = service
	end
end

--[[ Cross-server matchmaking needs three things that only a live server has: a
     MemoryStore backend, a JobId to advertise, and a PlaceId to teleport within.
     Deciding this once, at boot, is what makes pressing Play in Studio produce a
     round instead of a stack trace — nothing below ever calls out at all. ]]
local IS_LIVE = not RunService:IsStudio() and game.JobId ~= "" and game.PlaceId ~= 0

--[[ 4Hz, the same clock RoundService runs. Everything in the loop is a deadline
     comparison; the countdown is a number the menu renders, so polling faster
     would buy nothing but traffic. ]]
local TICK_INTERVAL = 0.25

--[[ Repeat the lobby state on this cadence even when nothing changed. A client
     that was still loading when the last change went out would otherwise sit on
     an empty menu forever, and this is four numbers to at most eight people. ]]
local RESEND_INTERVAL = 5

--[[ Seconds between teleport attempts, multiplied by the attempt number. The
     wait is not politeness: a server that refused a join because it was full is
     still full a frame later, and this gives it time to drain a slot. ]]
local TELEPORT_BACKOFF = 0.75

--[[ A client can fire RequestMode as fast as it can send, and every request can
     cost a MemoryStore read and a teleport. One per player per second is faster
     than anyone can click and slow enough that the quota is never at risk. ]]
local REQUEST_COOLDOWN = 1

--[[ How many advertised servers to pull per browse. The map hands them back
     fullest first, so the tail of a longer page is servers we would never pick. ]]
local BROWSE_COUNT = 24

--[[ A state change re-advertises immediately instead of waiting out
     AdvertiseInterval, but never faster than this — player counts churn, and the
     browser does not need to see every single one. ]]
local MIN_ADVERTISE_GAP = 5

--[[ Consecutive MemoryStore failures before cross-server matchmaking gives up
     for the life of the server. One failure is a blip and deserves a retry;
     three in a row is an outage, and retrying an outage every thirty seconds
     just fills the log while every player still gets a round here. ]]
local REMOTE_FAILURE_LIMIT = 3

local MatchmakingService = {}

local serviceTrove = Trove.new()

-- ── lobby state ─────────────────────────────────────────────────────────────
local claimedMode: string? = nil
local countdownEndsAt = 0 -- absolute server time the lobby countdown fires
local lobbyHoldUntil = 0 -- the post-round scoreboard window; no countdown until then

local desired: { [Player]: string } = {} -- the last mode each player asked for
local lastRequestAt: { [Player]: number } = {}
local teleporting: { [Player]: boolean } = {}

-- ── cross-server state ──────────────────────────────────────────────────────
local sortedMap: any = nil
local remoteDisabled = not IS_LIVE
local sortKeySupported = true
local remoteFailures = 0
local advertised = false
local advertiseDirty = true
local advertiseInFlight = false
-- One interval in the past, so the first tick writes rather than waiting out a
-- cadence measured from a process clock that did not start at zero.
local lastAdvertiseAt = -MM.AdvertiseInterval

-- ── loop bookkeeping ────────────────────────────────────────────────────────
local accumulator = 0
local wasRunning = false
local lastWaveIndex = -1
local warned: { [string]: boolean } = {}

local sentMode = ""
local sentCountdown = -1
local sentPlayers = -1
local sentCanStart = false
local sentAwaiting = false
local sentRunning = false
local sentAt = 0

-- ════════════════════════════════════════════════════════════════════════════
--  Small reads
-- ════════════════════════════════════════════════════════════════════════════

local function warnOnce(key: string, message: string)
	if warned[key] then
		return
	end
	warned[key] = true
	warn("[MatchmakingService] " .. message)
end

local function serverNow(): number
	return Workspace:GetServerTimeNow()
end

local function playerCount(): number
	return #Players:GetPlayers()
end

--[[ Each mode carries its own headcount rules — Versus needs four people to be a
     mode at all. An unknown mode falls back to Classic's, which is the permissive
     pair, so a new mode added to the config without limits still starts. ]]
local function modeConfig(mode: string): any
	return if mode == MODES.Versus then GameModeConfig.Versus else GameModeConfig.Classic
end

local function maxPlayersFor(mode: string): number
	return modeConfig(mode).MaxPlayers
end

local function minPlayersFor(mode: string): number
	return modeConfig(mode).MinPlayersToStart
end

--[[ A client can put anything at all in a RequestMode payload: a number, a
     table, a mode that has not existed since the campaign build. Only a value
     that is a key of GameModeConfig.Modes gets past here. ]]
local function normalizeMode(value: any): string?
	if typeof(value) ~= "string" then
		return nil
	end
	return MODES[value]
end

-- ── RoundService, read defensively ──────────────────────────────────────────
-- Every one of these tolerates RoundService being absent or half-loaded. This
-- service must be able to run a lobby on a server where the round system failed
-- to boot, because otherwise one broken module takes matchmaking with it.

local function round(): any
	return Registry.find("RoundService")
end

local function roundState(): string
	local service = round()
	if service and typeof(service.getState) == "function" then
		local ok, state = pcall(service.getState, service)
		if ok and typeof(state) == "string" then
			return state
		end
	end
	return Enums.RoundState.Lobby
end

local function roundIsRunning(): boolean
	local state = roundState()
	return state == Enums.RoundState.Starting or state == Enums.RoundState.InProgress
end

local function roundMode(): string
	local service = round()
	if service and typeof(service.getMode) == "function" then
		local ok, mode = pcall(service.getMode, service)
		if ok and typeof(mode) == "string" and MODES[mode] then
			return mode
		end
	end
	return claimedMode or GameModeConfig.DefaultMode
end

local function roundWaveIndex(): number
	local service = round()
	if service and typeof(service.getWaveIndex) == "function" then
		local ok, index = pcall(service.getWaveIndex, service)
		if ok and typeof(index) == "number" then
			return index
		end
	end
	return 0
end

--[[ Whether a round already under way would still take somebody. Wave
     JoinInProgressUntilWave is the last one that accepts joiners: past it a
     newcomer arrives with a pistol, no team and a Tank, which is not a game, so
     they wait for the next round instead. ]]
local function acceptsJoinInProgress(): boolean
	return roundIsRunning() and roundWaveIndex() <= MM.JoinInProgressUntilWave
end

--[[ Case 1 of the resolution order, as one question. In the lobby the answer is
     about the claim (one round per server, so one mode at a time); mid-round it
     is about the wave and the headcount. ]]
local function isJoinableHere(mode: string): boolean
	if roundIsRunning() then
		return roundMode() == mode and acceptsJoinInProgress() and playerCount() <= maxPlayersFor(mode)
	end
	return claimedMode == nil or claimedMode == mode
end

-- ════════════════════════════════════════════════════════════════════════════
--  The cross-server browser
-- ════════════════════════════════════════════════════════════════════════════

local function noteRemoteFailure(what: string, err: any)
	remoteFailures += 1
	if remoteFailures < REMOTE_FAILURE_LIMIT or remoteDisabled then
		return
	end
	remoteDisabled = true
	warn(
		string.format(
			"[MatchmakingService] %s failed %d times in a row (%s). Cross-server matchmaking is off for "
				.. "the life of this server; everyone who picks a mode now plays it here.",
			what,
			remoteFailures,
			tostring(err)
		)
	)
end

local function memoryMap(): any?
	if remoteDisabled then
		return nil
	end
	if sortedMap then
		return sortedMap
	end
	if not memoryStoreService then
		remoteDisabled = true
		return nil
	end
	local ok, map = pcall(memoryStoreService.GetSortedMap, memoryStoreService, MM.MemoryStoreMapName)
	if not ok or not map then
		noteRemoteFailure("MemoryStoreService:GetSortedMap", map)
		return nil
	end
	sortedMap = map
	return map
end

--[[ Marks the advertisement stale. The write itself happens on the tick, off the
     caller's thread: SetAsync yields, and nothing that changes state here should
     ever be waiting on a network round trip. ]]
local function requestAdvertise()
	advertiseDirty = true
end

--[[ Would this advertised server take a player right now? Read from the entry
     alone — it is a snapshot up to MemoryStoreTtl old, and a teleport into a
     round that has since closed is better handled by that server sending them
     back than by trusting a fresher number we do not have. ]]
local function isEntryJoinable(entry: any, mode: string): boolean
	if typeof(entry) ~= "table" then
		return false
	end
	if typeof(entry.jobId) ~= "string" or entry.jobId == "" or entry.jobId == game.JobId then
		return false
	end
	if entry.mode ~= mode then
		return false
	end
	if typeof(entry.players) ~= "number" or entry.players >= maxPlayersFor(mode) then
		return false
	end

	local state = entry.state
	if state == Enums.RoundState.Lobby or state == Enums.RoundState.Starting then
		return true
	end
	if state == Enums.RoundState.InProgress then
		return typeof(entry.waveIndex) == "number" and entry.waveIndex <= MM.JoinInProgressUntilWave
	end
	-- TeamWipe and Victory are result screens. Sending someone into one lands
	-- them on a scoreboard for a round they never played.
	return false
end

--[[ Every other server running `mode` that would have this player, fullest
     first. Returns an empty list in Studio, during an outage, and whenever the
     browser genuinely has nothing — all three mean the same thing to the caller. ]]
local function browse(mode: string): { any }
	local map = memoryMap()
	if not map then
		return {}
	end

	local ok, page = pcall(map.GetRangeAsync, map, Enum.SortDirection.Descending, BROWSE_COUNT)
	if not ok or typeof(page) ~= "table" then
		noteRemoteFailure("MemoryStoreSortedMap:GetRangeAsync", page)
		return {}
	end
	remoteFailures = 0

	local candidates = {}
	for _, item in page do
		local entry = if typeof(item) == "table" then item.value else nil
		if isEntryJoinable(entry, mode) then
			table.insert(candidates, entry)
		end
	end

	-- The map is already ordered by player count, but only within the page it
	-- returned and only where the sort key took. Sorting the handful that came
	-- back guarantees the fullest server wins either way.
	table.sort(candidates, function(a, b)
		return a.players > b.players
	end)
	return candidates
end

--[[
	Writes this server into the cross-server browser, or removes it when the
	round has closed to joining.

	The sort key is the player count and the browser reads descending, so the
	FULLEST joinable server wins. Filling one server to eight beats scattering
	eight players across eight empty ones — that is the difference between a
	horde and a lonely map, and it is decided entirely by this one number.
]]
function MatchmakingService:advertise()
	lastAdvertiseAt = os.clock()
	advertiseDirty = false

	local map = memoryMap()
	if not map then
		return
	end

	local running = roundIsRunning()
	local mode = if running then roundMode() else claimedMode
	local players = playerCount()
	local joinable = mode ~= nil
		and players < maxPlayersFor(mode)
		and (not running or acceptsJoinInProgress())

	if not joinable then
		if not advertised then
			return
		end
		local removed, err = pcall(map.RemoveAsync, map, game.JobId)
		if removed then
			advertised = false
			remoteFailures = 0
		else
			noteRemoteFailure("MemoryStoreSortedMap:RemoveAsync", err)
		end
		return
	end

	local entry = {
		jobId = game.JobId,
		mode = mode,
		state = roundState(),
		players = players,
		waveIndex = roundWaveIndex(),
	}

	local ok, err
	if sortKeySupported then
		ok, err = pcall(map.SetAsync, map, game.JobId, entry, MM.MemoryStoreTtl, players)
		if not ok then
			-- Older MemoryStore builds have no sort-key parameter. Losing the key
			-- costs ordering across pages, not correctness, so it is a fallback
			-- rather than an outage.
			sortKeySupported = false
			ok, err = pcall(map.SetAsync, map, game.JobId, entry, MM.MemoryStoreTtl)
		end
	else
		ok, err = pcall(map.SetAsync, map, game.JobId, entry, MM.MemoryStoreTtl)
	end

	if ok then
		advertised = true
		remoteFailures = 0
	else
		noteRemoteFailure("MemoryStoreSortedMap:SetAsync", err)
	end
end

local function withdrawAdvertisement()
	if remoteDisabled or not advertised or not sortedMap then
		return
	end
	pcall(sortedMap.RemoveAsync, sortedMap, game.JobId)
	advertised = false
end

-- ════════════════════════════════════════════════════════════════════════════
--  The lobby
-- ════════════════════════════════════════════════════════════════════════════

--[[
	One round per server, so the lobby's mode is a vote.

	Every player present counts, and anyone who has not picked is counted for the
	default rather than abstaining: one person choosing Versus must not be able to
	drag three silent players into it, and a room that actually wants Versus still
	gets it.

	A mode nobody could start at this headcount is not eligible. Three people who
	all want Versus (MinPlayersToStart 4) get a Classic round instead of a
	countdown that never reaches zero — an unplayable lobby is a worse answer than
	the wrong mode.

	── NOBODY HAS CHOSEN YET IS NOT A VOTE FOR THE DEFAULT ─────────────────────
	Silence counts as a vote for the default ONCE somebody has actually picked
	something — that is what stops one player dragging three quiet ones into
	Versus. It must not be what STARTS the lobby, and for a while it was: a
	server with one player who had touched nothing claimed the default mode and
	began counting down within a second of them spawning in.

	From the player's side that is the menu shoving them into a round while they
	are still reading it. There is a shop, a loadout screen and a gunsmith on
	that menu and no time to open any of them, which is the whole complaint.

	So the lobby waits. Until at least one person has said what they want to
	play, this returns nil, the claim stays empty and there is no clock. The
	countdown is a consequence of somebody choosing — which is also what makes it
	mean anything when it appears.
]]
local function anyoneHasChosen(): boolean
	for _, player in Players:GetPlayers() do
		if desired[player] then
			return true
		end
	end
	return false
end

local function tallyPreferredMode(): string?
	local players = Players:GetPlayers()
	local count = #players
	if count == 0 then
		return nil
	end
	if not anyoneHasChosen() then
		return nil
	end

	local votes: { [string]: number } = {}
	local anyEligible = false
	for _, mode in MODES do
		if count >= minPlayersFor(mode) then
			votes[mode] = 0
			anyEligible = true
		end
	end
	if not anyEligible then
		return nil
	end

	for _, player in players do
		local vote = desired[player] or GameModeConfig.DefaultMode
		if votes[vote] then
			votes[vote] += 1
		end
	end

	local best: string? = nil
	local bestVotes = -1
	for mode, tally in votes do
		-- Ties keep whatever the lobby is already counting down to, then the
		-- default. Flipping the claim resets the clock, and a lobby that re-rolls
		-- its clock every time somebody joins never starts.
		local wins = tally > bestVotes
			or (
				tally == bestVotes
				and (mode == claimedMode or (best ~= claimedMode and mode == GameModeConfig.DefaultMode))
			)
		if wins then
			best = mode
			bestVotes = tally
		end
	end
	return best
end

local function countdownSeconds(): number
	if roundIsRunning() or not claimedMode then
		return 0
	end
	return math.max(math.ceil(countdownEndsAt - serverNow()), 0)
end

--[[ Everything the main menu needs to draw itself. `endsAt` is an absolute
     workspace:GetServerTimeNow() stamp for the same reason FL_WaveEndsAt is: the
     menu renders a smooth countdown from a value that only changes when the
     lobby does, rather than from a number ticked over the wire. ]]
local function buildPayload(): { [string]: any }
	local running = roundIsRunning()
	local mode = if running then roundMode() else (claimedMode or GameModeConfig.DefaultMode)
	local players = playerCount()
	return {
		mode = mode,
		countdown = countdownSeconds(),
		endsAt = if running or not claimedMode then 0 else countdownEndsAt,
		players = players,
		maxPlayers = maxPlayersFor(mode),
		canStart = claimedMode ~= nil and players >= minPlayersFor(mode),
		--[[ True while the lobby is deliberately not counting down because nobody
		     has picked a mode. The menu needs this to say CHOOSE A MODE rather
		     than WAITING FOR SURVIVORS: one is an instruction and the other is a
		     lie about whose turn it is. ]]
		awaitingChoice = not running and claimedMode == nil,
		inProgress = running,
		waveIndex = roundWaveIndex(),
		joinable = isJoinableHere(mode),
	}
end

--[[ Broadcasts only when something a human could see has changed, plus a slow
     repeat so a client that loaded late still finds a menu with numbers in it. ]]
local function broadcastLobbyState(force: boolean?)
	local payload = buildPayload()
	local now = os.clock()

	local unchanged = payload.mode == sentMode
		and payload.countdown == sentCountdown
		and payload.players == sentPlayers
		and payload.canStart == sentCanStart
		and payload.awaitingChoice == sentAwaiting
		and payload.inProgress == sentRunning
	if not force and unchanged and now - sentAt < RESEND_INTERVAL then
		return
	end

	sentMode, sentCountdown, sentPlayers = payload.mode, payload.countdown, payload.players
	sentCanStart, sentRunning, sentAt = payload.canStart, payload.inProgress, now
	sentAwaiting = payload.awaitingChoice
	Remotes.Event.LobbyStateChanged:FireAllClients(payload)
end

--[[ The current state to one player, for someone who arrived after the last
     broadcast and has nothing on their menu yet. ]]
local function push(player: Player)
	if not player.Parent then
		return
	end
	Remotes.Event.LobbyStateChanged:FireClient(player, buildPayload())
end

--[[ The same payload, to one player, carrying the sentence that explains what
     just happened to their request. A menu that closes with no explanation and a
     menu that never closes are the same bug from the player's side. ]]
local function tell(player: Player, message: string, joined: boolean)
	-- A player can leave mid-request, and every path in requestMode ends in one
	-- of these.
	if not player.Parent then
		return
	end
	local payload = buildPayload()
	payload.message = message
	payload.joined = joined
	Remotes.Event.LobbyStateChanged:FireClient(player, payload)
end

--[[ Recomputes which mode this server's lobby belongs to, resetting the clock
     only when the answer actually changed. Never runs during a round: the mode
     is settled the moment the first wave lands. ]]
local function refreshClaim()
	if roundIsRunning() then
		return
	end
	local preferred = tallyPreferredMode()
	if preferred == claimedMode then
		return
	end

	claimedMode = preferred
	if preferred then
		countdownEndsAt = math.max(serverNow(), lobbyHoldUntil) + MM.LobbyCountdown
	else
		countdownEndsAt = 0
	end
	requestAdvertise()
	broadcastLobbyState(true)
end

-- ════════════════════════════════════════════════════════════════════════════
--  Putting a player into a round
-- ════════════════════════════════════════════════════════════════════════════

--[[
	Spawns a player into a round that is already under way.

	They arrive on their feet at full health, which is deliberately NOT what the
	breather does for a dead teammate (RespawnHealth, and it hurts): this player
	was not in the round to lose the health, and taxing them for joining late is
	how a join-in-progress slot goes unused.
]]
local function spawnIntoRound(player: Player)
	-- Versus decides which team a joiner lands on; there is no sensible default
	-- this service could pick, so it hands the player over when it can.
	if roundMode() == MODES.Versus then
		local versus = Registry.find("VersusService")
		if versus and typeof(versus.assignTeam) == "function" then
			local assigned = pcall(versus.assignTeam, versus, player)
			if assigned then
				return
			end
		end
	end

	local survivors = Registry.find("SurvivorService")
	if not survivors then
		warnOnce(
			"nosurvivors",
			"SurvivorService is not registered, so a join-in-progress player has no character."
		)
		return
	end

	local level = Registry.find("LevelService")
	if
		level
		and typeof(level.getSurvivorSpawnCFrame) == "function"
		and typeof(survivors.setSpawnCFrame) == "function"
	then
		local slot = table.find(Players:GetPlayers(), player) or 1
		local ok, cframe = pcall(level.getSurvivorSpawnCFrame, level, slot)
		if ok and typeof(cframe) == "CFrame" then
			survivors:setSpawnCFrame(player, cframe)
		end
	end

	local spawned, err = pcall(survivors.spawnSurvivor, survivors, player)
	if not spawned then
		warnOnce("spawnfailed", "SurvivorService:spawnSurvivor threw for a joiner: " .. tostring(err))
	end
end

--[[ Puts a player into whatever this server is doing. No teleport and no
     network round trip on this path — it is the overwhelmingly common one, and
     it has to feel like the menu closed rather than like a matchmaker ran. ]]
local function admit(player: Player, mode: string)
	desired[player] = mode

	local survivors = Registry.find("SurvivorService")
	if survivors and typeof(survivors.setReady) == "function" then
		survivors:setReady(player, true)
	end

	local audio = Registry.find("AudioService")
	if audio then
		audio:playForPlayer(player, AudioConfig.UI.MenuConfirm)
	end

	if roundIsRunning() then
		spawnIntoRound(player)
		tell(
			player,
			string.format("Dropping into wave %d. Find the team.", math.max(roundWaveIndex(), 1)),
			true
		)
		return
	end

	refreshClaim()
	tell(player, string.format("%s round starting.", claimedMode or mode), true)
end

--[[ Hands the round over to RoundService. Every failure here leaves the lobby
     counting down again rather than wedged: a server stuck at zero with no round
     is invisible to the players in it and looks like the game crashed. ]]
local function beginRound(mode: string)
	local service = round()
	if not service or typeof(service.startRound) ~= "function" then
		warnOnce("noround", "RoundService is not registered, so there is no round to start.")
		countdownEndsAt = serverNow() + MM.LobbyCountdown
		return
	end

	local ok, err = pcall(service.startRound, service, mode)
	if not ok then
		warnOnce("startfailed", "RoundService:startRound threw: " .. tostring(err))
		countdownEndsAt = serverNow() + MM.LobbyCountdown
		return
	end

	if mode == MODES.Versus then
		local versus = Registry.find("VersusService")
		if versus and typeof(versus.startVersus) == "function" then
			-- After the round starts, not before: startRound spawns everyone as a
			-- survivor, and VersusService is what decides which half of them
			-- should not have been. A Versus round that fails to split is still a
			-- playable round; one that fails to start is not.
			local split, splitErr = pcall(versus.startVersus, versus)
			if not split then
				warnOnce("versusfailed", "VersusService:startVersus threw: " .. tostring(splitErr))
			end
		else
			warnOnce(
				"noversus",
				"VersusService is not registered; running the wave schedule with everyone as a survivor."
			)
		end
	end

	requestAdvertise()
	broadcastLobbyState(true)
end

--[[
	Moves a player to another server instance.

	Retries TeleportRetries times, walking down the candidate list as it goes so a
	single full server does not eat every attempt. Every failure path ends in the
	same place: the player back at the menu with a sentence. Someone left staring
	at a loading screen with nothing behind it is the worst outcome in this file.
]]
local function teleportTo(player: Player, candidates: { any }): boolean
	if remoteDisabled or #candidates == 0 then
		return false
	end

	teleporting[player] = true
	local lastError: any = nil

	for attempt = 1, MM.TeleportRetries do
		if not player.Parent then
			-- They left mid-retry. Nothing to return to a menu, and nothing failed.
			teleporting[player] = nil
			return true
		end

		local target = candidates[math.min(attempt, #candidates)]
		local ok, err = pcall(
			TeleportService.TeleportToPlaceInstance,
			TeleportService,
			game.PlaceId,
			target.jobId,
			player
		)
		if ok then
			-- Still not home: the move can fail asynchronously, which is what the
			-- TeleportInitFailed handler is for. teleporting[player] stays set
			-- until they are gone or that fires.
			return true
		end

		lastError = err
		task.wait(TELEPORT_BACKOFF * attempt)
	end

	teleporting[player] = nil
	warnOnce("teleport", "TeleportToPlaceInstance failed every attempt: " .. tostring(lastError))
	return false
end

-- ════════════════════════════════════════════════════════════════════════════
--  Public API
-- ════════════════════════════════════════════════════════════════════════════

--[[
	The resolution order, in order. Yields only in step 2, and only on a server
	that has already failed to seat the player locally.
]]
function MatchmakingService:requestMode(player: Player, requested: string): boolean
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return false
	end

	local mode = normalizeMode(requested)
	if not mode then
		-- Not an error and not a kick: a client can send anything, and the honest
		-- answer to nonsense is the menu it came from.
		tell(player, "That mode does not exist.", false)
		return false
	end

	if teleporting[player] then
		return false
	end

	desired[player] = mode
	refreshClaim()

	-- 1. Here, if here will have them.
	if isJoinableHere(mode) then
		admit(player, mode)
		return true
	end

	-- 2. Somebody else's server. This is the only yielding branch.
	local candidates = browse(mode)
	if #candidates > 0 and teleportTo(player, candidates) then
		return true
	end

	-- 3. Nothing anywhere. The browse yielded, so ask again before giving up —
	--    a round can have ended or a slot opened while we were waiting.
	refreshClaim()
	if isJoinableHere(mode) then
		admit(player, mode)
		return true
	end

	if roundIsRunning() then
		local running = roundMode()
		if running == mode then
			tell(player, string.format("This %s round is too far in. You are in the next one.", mode), false)
		else
			tell(
				player,
				string.format("This server is running %s. You are in the next round.", running),
				false
			)
		end
	else
		tell(
			player,
			string.format(
				"No %s server had room. This one is starting %s.",
				mode,
				claimedMode or GameModeConfig.DefaultMode
			),
			false
		)
	end
	return false
end

--[[ What the lobby looks like right now. Safe to call from anywhere: it reads
     state and allocates one table, and never touches the network. ]]
function MatchmakingService:getLobbyState(): { [string]: any }
	return buildPayload()
end

-- ════════════════════════════════════════════════════════════════════════════
--  The loop
-- ════════════════════════════════════════════════════════════════════════════

--[[ The lobby clock. Held rather than ticked whenever starting would be wrong,
     so there is exactly one moment a round can begin: the countdown reaching
     zero with enough people to play it. ]]
local function stepLobby()
	refreshClaim()

	local mode = claimedMode
	if not mode then
		return
	end

	local now = serverNow()

	-- The scoreboard is not a lobby. Nobody is reading a countdown behind their
	-- own end-of-round stats.
	if now < lobbyHoldUntil then
		countdownEndsAt = lobbyHoldUntil + MM.LobbyCountdown
		return
	end

	local players = playerCount()
	if players < minPlayersFor(mode) then
		-- Held at full. A countdown that reaches zero with nobody to play is how a
		-- server ends up running seventeen minutes of waves for an empty map.
		countdownEndsAt = now + MM.LobbyCountdown
		return
	end

	-- A full server has nothing left to wait for, so it stops waiting.
	if players >= maxPlayersFor(mode) then
		countdownEndsAt = math.min(countdownEndsAt, now + MM.LobbyCountdownWithFullServer)
	end

	if now >= countdownEndsAt then
		beginRound(mode)
	end
end

--[[ Everything this service does on a clock, in one connection. Round state is
     polled rather than subscribed so that load order cannot matter: RoundService
     may register after this module, and a missed signal would leave the lobby
     dead for the life of the server. ]]
function MatchmakingService:_step()
	local running = roundIsRunning()
	if running ~= wasRunning then
		wasRunning = running
		requestAdvertise()
		if not running then
			-- The round just ended. Clear the claim so the next one is voted for
			-- from scratch, and hold the clock through the scoreboard.
			claimedMode = nil
			countdownEndsAt = 0
			lobbyHoldUntil = serverNow() + MM.PostRoundDuration

			local survivors = Registry.find("SurvivorService")
			if survivors and typeof(survivors.setReady) == "function" then
				for _, player in Players:GetPlayers() do
					survivors:setReady(player, false)
				end
			end
		end
	end

	-- Crossing JoinInProgressUntilWave closes the door, and the browser has to
	-- hear about it before it sends anyone else.
	local wave = roundWaveIndex()
	if wave ~= lastWaveIndex then
		lastWaveIndex = wave
		requestAdvertise()
	end

	if not running then
		stepLobby()
	end
	broadcastLobbyState(false)

	if remoteDisabled or advertiseInFlight then
		return
	end
	local elapsed = os.clock() - lastAdvertiseAt
	if elapsed >= MM.AdvertiseInterval or (advertiseDirty and elapsed >= MIN_ADVERTISE_GAP) then
		advertiseInFlight = true
		-- Spawned, because SetAsync yields and a lobby clock must never wait on a
		-- network round trip to notice that a countdown hit zero.
		task.spawn(function()
			local ok, err = pcall(self.advertise, self)
			if not ok then
				warnOnce("advertise", "advertise() threw: " .. tostring(err))
			end
			advertiseInFlight = false
		end)
	end
end

function MatchmakingService:start()
	serviceTrove:connect(Remotes.Event.RequestMode.OnServerEvent, function(player: Player, mode: any)
		local now = os.clock()
		local last = lastRequestAt[player]
		-- Dropped silently rather than answered: a client mashing the menu must
		-- not be able to spend this server's MemoryStore quota.
		if last and now - last < REQUEST_COOLDOWN then
			return
		end
		lastRequestAt[player] = now
		self:requestMode(player, mode)
	end)

	-- Both of these only mark state dirty. PlayerRemoving fires while the player
	-- is still in Players:GetPlayers(), so any count taken here is off by one;
	-- the tick recomputes with the real number a quarter of a second later.
	serviceTrove:connect(Players.PlayerAdded, function(player: Player)
		requestAdvertise()
		push(player)
	end)

	serviceTrove:connect(Players.PlayerRemoving, function(player: Player)
		desired[player] = nil
		lastRequestAt[player] = nil
		teleporting[player] = nil
		requestAdvertise()
	end)

	serviceTrove:connect(
		TeleportService.TeleportInitFailed,
		function(player: Player, result: any, message: any)
			if not teleporting[player] then
				return
			end
			teleporting[player] = nil
			local reason = if typeof(result) == "EnumItem" then result.Name else tostring(message)
			tell(
				player,
				string.format("Could not reach that server (%s). Pick a mode to play here.", reason),
				false
			)
		end
	)

	--[[ A stale entry outlives the server unless something removes it, and every
	     stale jobId in the browser is a real player's failed teleport. ]]
	game:BindToClose(function()
		withdrawAdvertisement()
	end)

	serviceTrove:connect(RunService.Heartbeat, function(delta: number)
		accumulator += delta
		if accumulator < TICK_INTERVAL then
			return
		end
		accumulator = 0
		self:_step()
	end)

	if remoteDisabled then
		print(
			"[MatchmakingService] no cross-server browser here (Studio or no JobId) — "
				.. "every mode request runs on this server."
		)
	end

	self:_step()

	--[[
		Last statement on purpose. The bootstrap pcalls start(), so anything that
		throws above leaves this false, and RoundService reads it to decide
		whether matchmaking is actually driving the lifecycle or whether it has
		to start rounds itself. Being *registered* is not the same as working:
		a service that died halfway through start() has a RequestMode listener
		that never attached, and gating on Registry.find alone meant the one
		degraded path the bootstrap exists to rescue would stall forever.
	]]
	self.started = true
end

function MatchmakingService:destroy()
	withdrawAdvertisement()
	serviceTrove:destroy()
end

Registry.register("MatchmakingService", MatchmakingService)

return MatchmakingService
