--!nonstrict
--[[
	LobbyService — playing with people you already know.

	MatchmakingService answers "put me in a round" and answers it well: it fills
	servers rather than spreading them, it prefers the one you are already in, and
	it never leaves a developer in Studio without a round. What it cannot answer is
	"put me in a round with THESE four people", because every route it has is a
	sort over strangers.

	That is this file. Three verbs, and they are genuinely different questions:

	  CREATE   open a PARTY here, on the server you are already standing in.
	           Nobody is moved. See THE PARTY below.
	  JOIN     look a code up and go to the server behind it.
	  FIND     the public browser MatchmakingService already keeps, handed to the
	           player as a LIST instead of being sorted and auto-picked.

	── THE PARTY, AND WHY CREATE STOPPED TELEPORTING ───────────────────────────
	CREATE used to reserve a server and send the host to it alone, immediately.
	Everything after that was the host reading a code out and hoping. The person
	they wanted to play with was usually standing next to them in the lobby they
	had just left, and the game's answer to "play with him" was "leave, then tell
	him a password".

	So the reserved server is made LAST. A party is assembled here — invite the
	people in this lobby, watch them accept, pick the mode — and pressing start is
	the single moment anything is reserved, minted or teleported, and it moves
	everybody at once. The code still exists and is still handed to the host on
	launch, because somebody in ANOTHER server has no other way in; it is just no
	longer the only way to play with a friend.

	One party per host, one party per player. Invites are offered to a UserId
	rather than a code because there is nothing to look up — the invitee is in
	this server, which is the entire premise.

	── WHY RESERVED SERVERS AND NOT "THIS SERVER, PRIVATELY" ────────────────────
	A private lobby that is the server you are standing in is not private: whoever
	else is already here is in it, and Roblox will keep sending it strangers. The
	only thing on the platform that means "a server nobody arrives at by accident"
	is a reserved one, so that is what a lobby is.

	It also makes the code meaningful. `TeleportService:ReserveServer` returns an
	access code, the code the player reads out is a short handle for it, and the
	map from one to the other is the entire mechanism.

	── IT MUST STILL DEGRADE INTO A PLAYABLE ROUND ─────────────────────────────
	MatchmakingService's rule, inherited wholesale: MemoryStoreService and
	TeleportService are both unavailable in Studio and both throw. Every call into
	either is wrapped, and every failure answers the player in words rather than
	silently doing nothing. In Studio, creating a lobby tells you it cannot and
	leaves you where you are — which is a server you can already press Play on.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TeleportService = game:GetService("TeleportService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared.Config.GameConfig)
local GameModeConfig = require(Shared.Config.GameModeConfig)
local Registry = require(Shared.Util.Registry)
local Remotes = require(Shared.Net.Remotes)
local Trove = require(Shared.Util.Trove)

local MM = GameModeConfig.Matchmaking
local MODES = GameModeConfig.Modes

--[[ Same guarded lookup MatchmakingService does, and for the same reason: asking
     for a service that is not on this platform throws, so even the lookup is a
     pcall and everything downstream treats a missing map as "no lobbies". ]]
local memoryStoreService: any = nil
do
	local ok, service = pcall(game.GetService, game, "MemoryStoreService")
	if ok then
		memoryStoreService = service
	end
end

--[[ The three things a cross-server anything needs. Decided once at boot so that
     nothing below ever calls out in Studio — see the header. ]]
local IS_LIVE = not RunService:IsStudio() and game.JobId ~= "" and game.PlaceId ~= 0

local LobbyService = {}

local serviceTrove = Trove.new()
local random = Random.new()

--[[ Last request per player, for the cooldown. Weak-keyed so a player who leaves
     does not pin their Player instance for the life of the server. ]]
local lastRequestAt: { [Player]: number } = setmetatable({}, { __mode = "k" }) :: any

-- ── helpers ─────────────────────────────────────────────────────────────────

local warned: { [string]: boolean } = {}
local function warnOnce(key: string, message: string)
	if warned[key] then
		return
	end
	warned[key] = true
	warn("[LobbyService] " .. message)
end

--[[ The answer, always. Every path through this file ends here — including the
     ones that fail — because a button that was pressed and produced nothing is
     indistinguishable from a button that is broken. ]]
local function answer(player: Player, action: string, ok: boolean, reason: string, code: string?)
	if not player.Parent then
		return
	end
	Remotes.Event.LobbyResult:FireClient(player, {
		action = action,
		ok = ok,
		reason = reason,
		code = code,
	})
end

local function lobbyMap(): any?
	if not memoryStoreService or not IS_LIVE then
		return nil
	end
	local ok, map = pcall(memoryStoreService.GetHashMap, memoryStoreService, MM.LobbyMapName)
	if not ok then
		warnOnce("hashmap", "MemoryStoreService:GetHashMap failed; private lobbies are unavailable")
		return nil
	end
	return map
end

local function normalizeMode(value: any): string
	if typeof(value) ~= "string" then
		return MODES.Classic
	end
	for _, mode in MODES do
		if mode == value then
			return mode
		end
	end
	return MODES.Classic
end

--[[ A code the player will have to read out loud. See GameModeConfig for why the
     alphabet is missing six letters. ]]
local function mintCode(): string
	local alphabet = MM.LobbyCodeAlphabet
	local out = table.create(MM.LobbyCodeLength)
	for _ = 1, MM.LobbyCodeLength do
		local at = random:NextInteger(1, #alphabet)
		table.insert(out, string.sub(alphabet, at, at))
	end
	return table.concat(out)
end

--[[
	What a player typed, made comparable.

	Upper-cased and stripped of everything that is not in the alphabet, so
	"abc-123" and "ABC123" are the same code and a pasted string with a space on
	the end still works. Bounded first: a code is six characters and anything
	longer is not a near miss, it is somebody seeing what the server will hold.
]]
local function cleanCode(value: any): string?
	if typeof(value) ~= "string" or #value > 64 then
		return nil
	end
	local upper = string.upper(value)
	local kept = {}
	for index = 1, #upper do
		local char = string.sub(upper, index, index)
		if string.find(MM.LobbyCodeAlphabet, char, 1, true) then
			table.insert(kept, char)
		end
	end
	local code = table.concat(kept)
	if #code ~= MM.LobbyCodeLength then
		return nil
	end
	return code
end

--[[ One request per player per cooldown, across all three verbs together. They
     are all network calls to a rate-limited backend and all three are one button
     press; sharing the budget stops a client cycling between them. ]]
local function admit(player: Player): boolean
	local now = os.clock()
	if lastRequestAt[player] and now - lastRequestAt[player] < MM.LobbyRequestCooldown then
		return false
	end
	lastRequestAt[player] = now
	return true
end

-- ── create ──────────────────────────────────────────────────────────────────

--[[
	Writes a code, but only if nobody else has it.

	UpdateAsync rather than SetAsync: two servers minting the same six characters
	in the same second is unlikely and not impossible, and the loser of that race
	would silently take over the winner's lobby — everybody typing the code would
	land in the wrong server. Returning nil from the transform aborts the write,
	which is how "taken" is expressed without a separate read.
]]
local function claimCode(map: any, code: string, entry: any): boolean
	local taken = false
	local ok, err = pcall(map.UpdateAsync, map, code, function(existing)
		if existing ~= nil then
			taken = true
			return nil
		end
		taken = false
		return entry
	end, MM.LobbyTtl)

	if not ok then
		warnOnce("claim", "MemoryStoreHashMap:UpdateAsync failed: " .. tostring(err))
		return false
	end
	return not taken
end

-- ── the party ───────────────────────────────────────────────────────────────

--[[
	Every party open on this server, keyed by its HOST.

	Keyed by the host rather than by an id because a host is what a party is: it
	ends when they leave, there is exactly one per host, and every question worth
	asking ("is this mine", "may I start it") is a comparison against that one
	field. An id would be a second thing to keep in step for no gain.

	Weak keys on both tables, so a party whose host disconnects and a membership
	whose player disconnects both fall out without anything having to notice.
]]
type Party = {
	host: Player,
	mode: string,
	members: { Player },
	--[[ Offered but not answered. A set rather than a list: the only questions
	     are "is this player invited" and "stop being invited", and both are one
	     lookup. ]]
	pending: { [Player]: boolean },
}

local parties = (setmetatable({}, { __mode = "k" }) :: any) :: { [Player]: Party }
--[[ The party a player is IN, host included, so membership is one lookup rather
     than a walk over every party's roster. Every write to a party's `members`
     writes here too; nothing else may. ]]
local partyOf = (setmetatable({}, { __mode = "k" }) :: any) :: { [Player]: Party }
--[[ Who has offered this player a place, so a response knows whose party it is
     answering without the client naming one. Cleared on accept, decline, and on
     the inviter's party ending. ]]
local invitedBy = (setmetatable({}, { __mode = "k" }) :: any) :: { [Player]: Player }

local function partyNames(party: Party): { string }
	local names = {}
	for _, member in party.members do
		if member.Parent then
			table.insert(names, member.Name)
		end
	end
	return names
end

--[[ Pushes the party's state to one player. Sent to people with no party too —
     an empty state is what closes the panel on somebody who just left, and a
     client that had to infer that from silence would keep a stale roster. ]]
local function pushParty(player: Player)
	if not player.Parent then
		return
	end
	local party = partyOf[player]
	local offer = invitedBy[player]
	Remotes.Event.PartyState:FireClient(player, {
		inParty = party ~= nil,
		host = if party then party.host.Name else "",
		members = if party then partyNames(party) else {},
		mode = if party then party.mode else "",
		--[[ Nil unless there is an offer waiting AND the party behind it still
		     exists. A host who left between the invite and this redraw would
		     otherwise leave a prompt on screen for a party nobody can join. ]]
		invitedBy = if offer and offer.Parent and parties[offer] then offer.Name else nil,
	})
end

local function pushToParty(party: Party)
	for _, member in party.members do
		pushParty(member)
	end
	for invitee in party.pending do
		pushParty(invitee)
	end
end

--[[ Takes a player out of whatever party they are in, and closes the party
     entirely if they were hosting it.

     A host leaving DISBANDS rather than promoting somebody. Promotion sounds
     kinder and is not: the party exists because one person is assembling it, and
     handing it to whoever happens to be next in a table gives a stranger the
     button that spends everybody's next twenty minutes. Everyone is told, and
     anybody can open a new one. ]]
local function removeFromParty(player: Player)
	local party = partyOf[player]
	if not party then
		return
	end

	if party.host == player then
		parties[player] = nil
		for _, member in party.members do
			partyOf[member] = nil
		end
		for invitee in party.pending do
			invitedBy[invitee] = nil
		end
		--[[ After the state is torn down, not before: pushParty reads these
		     tables, and telling somebody about a party mid-disband would send
		     them a roster that is half gone. ]]
		for _, member in party.members do
			pushParty(member)
		end
		for invitee in party.pending do
			pushParty(invitee)
		end
		return
	end

	local index = table.find(party.members, player)
	if index then
		table.remove(party.members, index)
	end
	partyOf[player] = nil
	pushParty(player)
	pushToParty(party)
end

--[[
	Opens a party on THIS server, with the caller hosting it.

	Nothing is reserved, nothing is minted and nobody moves — see THE PARTY in
	the header. All of that happens in launchParty, once the host has the people
	they wanted.

	Works in Studio, and that is a real gain rather than an accident: the old
	CREATE could not do anything at all without TeleportService, so the whole
	feature was untestable without publishing. A party is in-memory state on one
	server, so it can be built and torn down anywhere; only pressing start needs
	the platform.
]]
function LobbyService:createLobby(player: Player, mode: string): boolean
	local wanted = normalizeMode(mode)

	--[[ Already in one. Re-pressed rather than a second party: a host who presses
	     CREATE twice means "show me my party", and silently making a new one
	     would strand everybody who had already accepted into the first. ]]
	local existing = partyOf[player]
	if existing then
		if existing.host == player then
			existing.mode = wanted
			pushToParty(existing)
			answer(player, "Create", true, "ok")
			return true
		end
		answer(player, "Create", false, "inparty")
		return false
	end

	local party: Party = {
		host = player,
		mode = wanted,
		members = { player },
		pending = {},
	}
	parties[player] = party
	partyOf[player] = party

	--[[ An offer this player was sitting on is dropped. Hosting one party and
	     holding an invitation to another is a state with no correct answer, and
	     the one they just acted on is the one they meant. ]]
	local offer = invitedBy[player]
	if offer then
		invitedBy[player] = nil
		local theirs = parties[offer]
		if theirs then
			theirs.pending[player] = nil
			pushToParty(theirs)
		end
	end

	answer(player, "Create", true, "ok")
	pushParty(player)
	return true
end

--[[
	Offers somebody in this server a place.

	The invitee is named by UserId and found in this server's player list, which
	is the premise of the whole feature: they are standing in the same lobby. A
	UserId that is not here is not an error worth a message — it is a stale click
	on a list that has since changed.
]]
function LobbyService:inviteToParty(player: Player, userId: any): boolean
	local party = parties[player]
	if not party or party.host ~= player then
		answer(player, "Invite", false, "nothost")
		return false
	end
	if #party.members >= GameConfig.MaxSurvivors then
		answer(player, "Invite", false, "full")
		return false
	end

	local id = tonumber(userId)
	if not id then
		return false
	end
	local target: Player? = nil
	for _, other in Players:GetPlayers() do
		if other.UserId == id then
			target = other
			break
		end
	end
	if not target or target == player then
		return false
	end
	--[[ Somebody already in a party — including this one — is not invitable. The
	     alternative is an invite that would have to steal them out of a roster
	     somebody else is counting on. ]]
	if partyOf[target] then
		answer(player, "Invite", false, "busy")
		return false
	end
	if invitedBy[target] then
		answer(player, "Invite", false, "pending")
		return false
	end

	party.pending[target] = true
	invitedBy[target] = player
	answer(player, "Invite", true, "ok")
	pushParty(target)
	pushToParty(party)
	return true
end

--[[ Yes or no to whatever offer is outstanding. The party is looked up from
     `invitedBy` rather than named by the client, so a response can only ever
     answer the invitation this server actually sent. ]]
function LobbyService:respondToParty(player: Player, accept: boolean): boolean
	local host = invitedBy[player]
	invitedBy[player] = nil
	if not host then
		pushParty(player)
		return false
	end

	local party = parties[host]
	if not party then
		--[[ The host left, or launched without them. Nothing to join and nothing
		     to apologise for; the prompt just goes. ]]
		pushParty(player)
		return false
	end
	party.pending[player] = nil

	if not accept or partyOf[player] or #party.members >= GameConfig.MaxSurvivors then
		pushParty(player)
		pushToParty(party)
		return false
	end

	table.insert(party.members, player)
	partyOf[player] = party
	pushToParty(party)
	return true
end

function LobbyService:leaveParty(player: Player): boolean
	--[[ Declining a pending offer is leaving, from the player's side: one button
	     that means "I am not part of this", whichever half of it they are in. ]]
	if invitedBy[player] and not partyOf[player] then
		return self:respondToParty(player, false)
	end
	removeFromParty(player)
	return true
end

--[[
	The one moment anything leaves this server.

	Reserves a server, mints a code for it and teleports the WHOLE ROSTER in one
	call. One call matters: TeleportToPrivateServer takes a list, and Roblox
	keeps a group sent together together — teleporting four people one at a time
	is four chances to land in a different place than the person beside you.

	The code is still minted and still handed to the host, because somebody in
	another server has no other way to reach this one. It is no longer the
	mechanism, it is the fallback.
]]
function LobbyService:launchParty(player: Player): boolean
	local party = parties[player]
	if not party or party.host ~= player then
		answer(player, "Launch", false, "nothost")
		return false
	end

	if not IS_LIVE then
		--[[ Studio. The party itself worked and can be inspected; only the
		     platform half is missing, and saying which is the difference between
		     a developer debugging their code and debugging their environment. ]]
		answer(player, "Launch", false, "studio")
		return false
	end

	local map = lobbyMap()
	if not map then
		answer(player, "Launch", false, "unavailable")
		return false
	end

	local ok, accessCode = pcall(TeleportService.ReserveServer, TeleportService, game.PlaceId)
	if not ok or typeof(accessCode) ~= "string" then
		warnOnce("reserve", "TeleportService:ReserveServer failed: " .. tostring(accessCode))
		answer(player, "Launch", false, "unavailable")
		return false
	end

	local entry = {
		accessCode = accessCode,
		placeId = game.PlaceId,
		mode = party.mode,
		host = player.UserId,
		createdAt = os.time(),
	}

	local code: string? = nil
	for _ = 1, MM.LobbyCodeAttempts do
		local candidate = mintCode()
		if claimCode(map, candidate, entry) then
			code = candidate
			break
		end
	end
	if not code then
		answer(player, "Launch", false, "unavailable")
		return false
	end

	--[[ Everybody still here, gathered before the teleport rather than during
	     it: a member who left while the reserve was in flight must not be handed
	     to TeleportToPrivateServer, which throws on a Player that has gone. ]]
	local going: { Player } = {}
	for _, member in party.members do
		if member.Parent then
			table.insert(going, member)
		end
	end
	if #going == 0 then
		answer(player, "Launch", false, "unavailable")
		return false
	end

	--[[ Told BEFORE the teleport, for the reason it always was: the call does
	     not return on success, so anything said afterwards is said to nobody. ]]
	answer(player, "Launch", true, "ok", code)

	local sent = pcall(
		TeleportService.TeleportToPrivateServer,
		TeleportService,
		game.PlaceId,
		accessCode,
		going,
		nil,
		{ lobbyCode = code, lobbyMode = party.mode }
	)
	if not sent then
		warnOnce("teleportlaunch", "TeleportToPrivateServer failed for a party we just reserved")
		answer(player, "Launch", false, "teleport", code)
		return false
	end
	return true
end

-- ── join ────────────────────────────────────────────────────────────────────

function LobbyService:joinLobby(player: Player, rawCode: string): boolean
	local code = cleanCode(rawCode)
	if not code then
		--[[ Refused before any network call. A malformed code cannot match
		     anything, and spending a MemoryStore read to find that out is a read
		     an exploiter can spend for us. ]]
		answer(player, "Join", false, "badcode")
		return false
	end

	if not IS_LIVE then
		answer(player, "Join", false, "studio")
		return false
	end

	local map = lobbyMap()
	if not map then
		answer(player, "Join", false, "unavailable")
		return false
	end

	local ok, entry = pcall(map.GetAsync, map, code)
	if not ok then
		warnOnce("getlobby", "MemoryStoreHashMap:GetAsync failed: " .. tostring(entry))
		answer(player, "Join", false, "unavailable")
		return false
	end
	if typeof(entry) ~= "table" or typeof(entry.accessCode) ~= "string" then
		--[[ Expired or never existed, and the player cannot tell the difference —
		     which is correct. Saying "that lobby has expired" for a code nobody
		     ever minted would confirm the format to somebody guessing. ]]
		answer(player, "Join", false, "notfound")
		return false
	end

	answer(player, "Join", true, "ok")

	local sent = pcall(
		TeleportService.TeleportToPrivateServer,
		TeleportService,
		entry.placeId or game.PlaceId,
		entry.accessCode,
		{ player },
		nil,
		{ lobbyCode = code, lobbyMode = entry.mode }
	)
	if not sent then
		warnOnce("teleportjoin", "TeleportToPrivateServer failed for an existing lobby")
		answer(player, "Join", false, "teleport")
		return false
	end
	return true
end

-- ── find ────────────────────────────────────────────────────────────────────

--[[
	The public browser, as a list.

	MatchmakingService already keeps this — it advertises every joinable server
	into a MemoryStore sorted map and reads it back to decide where to send
	somebody. The only thing this adds is showing the player the same rows and
	letting them pick, which is a different promise: the sort answers "where is
	the best round", and a list answers "where are my friends".

	Nothing is filtered out that MatchmakingService would have taken. A row the
	player can see is a row they can join.
]]
function LobbyService:listServers(player: Player, mode: string)
	local wanted = normalizeMode(mode)
	local rows = {}

	local matchmaking = Registry.find("MatchmakingService")
	if matchmaking and typeof(matchmaking.browseServers) == "function" then
		local ok, found = pcall(matchmaking.browseServers, matchmaking, wanted)
		if ok and typeof(found) == "table" then
			rows = found
		end
	end

	if not player.Parent then
		return
	end
	Remotes.Event.ServerListUpdated:FireClient(player, { mode = wanted, servers = rows })
end

-- ── lifecycle ───────────────────────────────────────────────────────────────

function LobbyService:init() end

function LobbyService:start()
	--[[ A party is same-server state, so it dies with the server and with the
	     player. The weak tables would drop these on their own eventually; doing
	     it on the signal means the ROSTER everyone else is looking at updates the
	     moment somebody leaves rather than whenever Luau next collects. ]]
	serviceTrove:connect(Players.PlayerRemoving, function(player: Player)
		local offer = invitedBy[player]
		invitedBy[player] = nil
		if offer then
			local theirs = parties[offer]
			if theirs then
				theirs.pending[player] = nil
				pushToParty(theirs)
			end
		end
		removeFromParty(player)
	end)

	serviceTrove:connect(Remotes.Event.PartyInvite.OnServerEvent, function(player: Player, userId: any)
		if admit(player) then
			LobbyService:inviteToParty(player, userId)
		end
	end)

	serviceTrove:connect(Remotes.Event.PartyRespond.OnServerEvent, function(player: Player, accept: any)
		LobbyService:respondToParty(player, accept == true)
	end)

	serviceTrove:connect(Remotes.Event.PartyLeave.OnServerEvent, function(player: Player)
		LobbyService:leaveParty(player)
	end)

	serviceTrove:connect(Remotes.Event.PartyLaunch.OnServerEvent, function(player: Player)
		if admit(player) then
			LobbyService:launchParty(player)
		end
	end)

	serviceTrove:connect(Remotes.Event.CreateLobby.OnServerEvent, function(player: Player, mode: any)
		if not admit(player) then
			return
		end
		LobbyService:createLobby(player, mode)
	end)

	serviceTrove:connect(Remotes.Event.JoinLobby.OnServerEvent, function(player: Player, code: any)
		if not admit(player) then
			return
		end
		LobbyService:joinLobby(player, code)
	end)

	serviceTrove:connect(Remotes.Event.RequestServerList.OnServerEvent, function(player: Player, mode: any)
		if not admit(player) then
			return
		end
		LobbyService:listServers(player, mode)
	end)

	serviceTrove:connect(Players.PlayerRemoving, function(player: Player)
		lastRequestAt[player] = nil
	end)
end

function LobbyService:destroy()
	serviceTrove:destroy()
end

Registry.register("LobbyService", LobbyService)

return LobbyService
