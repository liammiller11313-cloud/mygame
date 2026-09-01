--!nonstrict
--[[
	LobbyService — playing with people you already know.

	MatchmakingService answers "put me in a round" and answers it well: it fills
	servers rather than spreading them, it prefers the one you are already in, and
	it never leaves a developer in Studio without a round. What it cannot answer is
	"put me in a round with THESE four people", because every route it has is a
	sort over strangers.

	That is this file. Three verbs, and they are genuinely different questions:

	  CREATE   reserve a private server, mint a code, go there. The code is a
	           password; only the person who made it is ever told what it is.
	  JOIN     look a code up and go to the server behind it.
	  FIND     the public browser MatchmakingService already keeps, handed to the
	           player as a LIST instead of being sorted and auto-picked.

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

function LobbyService:createLobby(player: Player, mode: string): boolean
	local wanted = normalizeMode(mode)

	if not IS_LIVE then
		--[[ Studio, or a server with no JobId. Said in words rather than failing
		     quietly: a developer pressing this needs to know it is the environment
		     and not their code, and they can still press Play. ]]
		answer(player, "Create", false, "studio")
		return false
	end

	local map = lobbyMap()
	if not map then
		answer(player, "Create", false, "unavailable")
		return false
	end

	local ok, accessCode = pcall(TeleportService.ReserveServer, TeleportService, game.PlaceId)
	if not ok or typeof(accessCode) ~= "string" then
		warnOnce("reserve", "TeleportService:ReserveServer failed: " .. tostring(accessCode))
		answer(player, "Create", false, "unavailable")
		return false
	end

	local entry = {
		accessCode = accessCode,
		placeId = game.PlaceId,
		mode = wanted,
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
		answer(player, "Create", false, "unavailable")
		return false
	end

	--[[ Told BEFORE the teleport, not after. TeleportToPrivateServer does not
	     return on success — the client is gone — so a code sent afterwards is a
	     code nobody receives. ]]
	answer(player, "Create", true, "ok", code)

	local sent = pcall(
		TeleportService.TeleportToPrivateServer,
		TeleportService,
		game.PlaceId,
		accessCode,
		{ player },
		nil,
		{ lobbyCode = code, lobbyMode = wanted }
	)
	if not sent then
		warnOnce("teleportcreate", "TeleportToPrivateServer failed for a lobby we just reserved")
		answer(player, "Create", false, "teleport", code)
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
