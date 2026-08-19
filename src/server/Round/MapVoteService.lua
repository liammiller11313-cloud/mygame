--!nonstrict
--[[
	MapVoteService — the end-of-round map vote.

	Runs while the scoreboard is already on screen, so it costs no extra dead
	time. Twenty seconds, one vote each, changeable until the clock runs out.

	Two rules that matter more than they look:

	  A TIE BREAKS AWAY FROM THE CURRENT MAP. With two maps and an even split,
	  picking the one you just played would mean a coin-flip decides whether the
	  team plays the same map twice — and playing the same map twice because
	  nobody could agree feels like the game ignored the vote. Breaking away from
	  the current map means an even split always produces a change, which is what
	  people voting evenly actually want.

	  NOBODY VOTING IS NOT AN ERROR. An empty tally picks the map that is not
	  current, so a team that walks away between rounds still gets variety.

	The winner is prewarmed the moment it is known — cloned into ServerStorage
	while the scoreboard is still up — so the actual swap is a reparent and the
	loading screen is nearly instant.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local MapConfig = require(Shared.Config.MapConfig)
local Registry = require(Shared.Util.Registry)
local Remotes = require(Shared.Net.Remotes)
local Signal = require(Shared.Util.Signal)
local Trove = require(Shared.Util.Trove)

local VOTE = MapConfig.Vote

local MapVoteService = {}

MapVoteService.voteFinished = Signal.new() -- (winnerId: string)

local serviceTrove = Trove.new()

local active = false
local endsAt = 0
--[[ Cleared when a round starts, set when a vote resolves. It is what stops the
     idle check below from reopening a vote every tick once one has been held. ]]
local decided = false
local lastWinner = ""
local options: { string } = {}
local votes: { [Player]: string } = {}
local accumulator = 0

local TICK_INTERVAL = 0.25

local function serverNow(): number
	return Workspace:GetServerTimeNow()
end

local function tally(): { [string]: number }
	local counts = {}
	for _, id in options do
		counts[id] = 0
	end
	for player, id in votes do
		if player.Parent and counts[id] ~= nil then
			counts[id] += 1
		end
	end
	return counts
end

local function countVoters(): number
	local n = 0
	for player in votes do
		if player.Parent then
			n += 1
		end
	end
	return n
end

local function broadcastTally()
	Remotes.Event.MapVoteUpdated:FireAllClients({ tally = tally(), voters = countVoters() })
end

--[[ Resolves the vote. See the header for why a tie deliberately moves away from
     whatever was just played. ]]
local function resolve(): string
	local counts = tally()
	local mapService = Registry.find("MapService")
	local current = mapService and mapService:getCurrentId() or ""

	local best, bestCount = "", -1
	local tied: { string } = {}

	for _, id in options do
		local count = counts[id] or 0
		if count > bestCount then
			best, bestCount = id, count
			tied = { id }
		elseif count == bestCount then
			table.insert(tied, id)
		end
	end

	if #tied > 1 and VOTE.BreakTiesAwayFromCurrent then
		for _, id in tied do
			if id ~= current then
				return id
			end
		end
	end

	return if best ~= "" then best else (options[1] or MapConfig.DefaultMap)
end

function MapVoteService:isActive(): boolean
	return active
end

function MapVoteService:getOptions(): { string }
	return table.clone(options)
end

--[[ Opens a vote. Returns the id it will land on if nobody votes, so a caller
     that cannot run a vote (one map, no players) still knows what comes next. ]]
--[[ NOT called `start`: the bootstrap calls :start() on every registered
     service, and a vote that opened itself at boot would be running before there
     was ever a round to vote after. ]]
--[[ Called by RoundService as a round begins. The decision has been spent, so
     the next lull is allowed to open a fresh vote. ]]
function MapVoteService:consumeDecision(): string
	local winner = lastWinner
	decided = false
	lastWinner = ""
	return winner
end

function MapVoteService:hasDecided(): boolean
	return decided
end

function MapVoteService:beginVote(): string
	local mapService = Registry.find("MapService")
	options = if mapService then mapService:getAvailableIds() else MapConfig.ids()

	table.clear(votes)
	accumulator = 0

	-- Nothing to decide. Skip the ceremony rather than showing a vote with one
	-- button on it.
	if #options <= 1 then
		active = false
		local only = options[1] or MapConfig.DefaultMap
		self:_finish(only)
		return only
	end

	active = true
	endsAt = serverNow() + VOTE.DurationSeconds

	local cards = {}
	for _, id in options do
		local definition = MapConfig.get(id)
		table.insert(cards, {
			id = id,
			displayName = if definition then definition.displayName else string.upper(id),
			blurb = if definition then definition.blurb else "",
		})
	end

	Remotes.Event.MapVoteStarted:FireAllClients({ options = cards, endsAt = endsAt })
	broadcastTally()

	return resolve()
end

function MapVoteService:cast(player: Player, mapId: string)
	if not active then
		return
	end
	if typeof(mapId) ~= "string" or table.find(options, mapId) == nil then
		return
	end
	if votes[player] and not VOTE.AllowChangingVote then
		return
	end
	if votes[player] == mapId then
		return
	end
	votes[player] = mapId
	broadcastTally()
end

function MapVoteService:_finish(winner: string)
	active = false
	decided = true
	lastWinner = winner
	local counts = tally()

	Remotes.Event.MapVoteResult:FireAllClients({ winner = winner, tally = counts })

	--[[ Cloned NOW, while the scoreboard is still up and nobody is looking at the
	     world. By the time the round actually starts the clone already exists and
	     the swap is a reparent. ]]
	local mapService = Registry.find("MapService")
	if mapService then
		mapService:prewarm(winner)
	end

	MapVoteService.voteFinished:fire(winner)
end

--[[ Ends the vote early — used when a round is forced to start before the clock
     runs out, so the winner is still honoured rather than discarded. ]]
function MapVoteService:finishNow(): string
	if not active then
		return resolve()
	end
	local winner = resolve()
	self:_finish(winner)
	return winner
end

--[[
	Opens a vote on a fresh server, or after a round has been decided and the
	next one has not started.

	A server that boots straight into a default map never asks anybody what they
	wanted to play, which is the one moment a vote is most useful — the map is
	about to be loaded and nobody has any investment in it yet. So the same vote
	that runs between rounds also runs before the first one.

	Gated on there being somebody to ask: a vote held in an empty server would
	resolve to nothing and then block the first real player from getting one.
]]
function MapVoteService:_maybeOpenIdleVote()
	--[[ Off by default. See MapConfig.Vote.OnFreshServer: the lobby countdown
	     starts on its own, so every second of it is a second the player is on the
	     main menu, and a vote during it is a vote over the menu. ]]
	if not MapConfig.Vote.OnFreshServer then
		return
	end
	if active or decided then
		return
	end
	if #Players:GetPlayers() == 0 then
		return
	end

	local round = Registry.find("RoundService")
	if round and typeof(round.getState) == "function" then
		local roundState = round:getState()
		-- Only while nothing is being played. A vote over a live round would be
		-- deciding a map for a round that is already using one.
		if roundState ~= "Lobby" and roundState ~= "" then
			return
		end
	end

	--[[
		And only once somebody has actually committed to going in.

		"The round state is Lobby" is true from the moment the server boots, so
		this used to fire at a player who had joined and not yet decided
		anything — a map vote thrown over the main menu while they were still
		reading the mode list. A vote is a question about the round you are
		entering, and until a mode is claimed there is no round being entered.

		A live countdown is exactly that commitment: MatchmakingService starts it
		when a mode is claimed and reports zero otherwise, so this opens as the
		lobby begins counting down and resolves as it reaches zero. The vote and
		the countdown are both twenty seconds, which is not a coincidence — and
		if the lobby shortens itself for a full server, RoundService's finishNow
		honours the vote as it stands rather than discarding it.

		With no matchmaking at all — a developer pressing Play — there is no
		countdown to wait for and the old behaviour is right: open immediately,
		because the round is about to start on player count alone.
	]]
	local matchmaking = Registry.find("MatchmakingService")
	if matchmaking and matchmaking.started and typeof(matchmaking.getLobbyState) == "function" then
		local ok, lobby = pcall(matchmaking.getLobbyState, matchmaking)
		if not ok or typeof(lobby) ~= "table" then
			return
		end
		if lobby.inProgress or (tonumber(lobby.countdown) or 0) <= 0 then
			return
		end
	end

	self:beginVote()
end

function MapVoteService:_step()
	if not active then
		self:_maybeOpenIdleVote()
		return
	end
	if serverNow() >= endsAt then
		self:_finish(resolve())
	end
end

function MapVoteService:init()
	serviceTrove:connect(Remotes.Event.CastMapVote.OnServerEvent, function(player, mapId)
		self:cast(player, mapId)
	end)
	serviceTrove:connect(Players.PlayerRemoving, function(player)
		if votes[player] then
			votes[player] = nil
			if active then
				broadcastTally()
			end
		end
	end)
	serviceTrove:connect(RunService.Heartbeat, function(dt)
		accumulator += dt
		if accumulator < TICK_INTERVAL then
			return
		end
		accumulator = 0
		self:_step()
	end)
end

function MapVoteService:destroy()
	serviceTrove:destroy()
end

Registry.register("MapVoteService", MapVoteService)

return MapVoteService
