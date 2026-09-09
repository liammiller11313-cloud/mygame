--!nonstrict
--[[
	LeaderboardService — the global boards, published and served.

	Three OrderedDataStores, one per board, holding every player who has ever
	finished a round in this game. This file writes to them at the end of a round
	and reads pages out of them when somebody opens the panel, and does nothing
	else at all.

	── WHY AN OrderedDataStore AND NOT A DataStore ─────────────────────────────
	Because "the top hundred" is a question a plain DataStore cannot answer. It
	stores values by key and can hand back the one you name; it cannot hand back
	the largest hundred. GetSortedAsync exists for exactly this and costs one
	request for a page, which is the difference between a leaderboard and a
	fantasy about iterating every player who has ever joined.

	The cost is that an OrderedDataStore holds ONE signed integer per key. So
	there is one store per board rather than one store with a row in it, and
	nothing but a number can live in them — the name and the tag on a row are
	resolved separately, below.

	── WHAT IS WRITTEN, AND WHEN ──────────────────────────────────────────────
	At the end of a round, for every player who was actually in it: fold the round
	into their lifetime totals, and publish the fields that MOVED. Not all of
	them — ProfileService.recordLifetime returns which changed, and a Best that
	was not beaten did not change. Three boards, four players, one round every
	seventeen minutes; publishing only what moved keeps that comfortably inside a
	budget that is measured per minute.

	Nothing is published mid-round. A board that updated live would be a board
	that has a player on it for a wave they died on.

	── WHAT IS READ, AND HOW OFTEN ────────────────────────────────────────────
	Once per board per CacheSeconds, at most, and only when somebody asks. There
	is no timer in this file: an empty lobby fetches nothing, and ten players
	opening the panel at once share one fetch rather than spending ten of the
	server's read budget on a list that has not moved.

	── NAMES ARE RESOLVED AT SERVE TIME, NOT STORED ───────────────────────────
	The store holds UserIds. Turning one into a name costs a web call
	(GetNameFromUserIdAsync), which is cached here for the lifetime of the server
	because a UserId's name changes rarely and a stale one for an hour is a much
	smaller problem than a hundred web calls per panel open.

	Tags are the other half and they are NOT resolved here: a callsign lives on
	the player's own attributes, which every client already has for everybody in
	the server — and for the ninety-odd rows belonging to players who are not
	here, there is nothing to look up. So a row carries the tag when the player is
	present and nothing when they are not, which is the honest answer and costs
	no requests at all. See LeaderboardConfig's note on the tag.

	── IT IS ALLOWED TO NOT WORK ──────────────────────────────────────────────
	Studio has no DataStore access unless it is switched on, and a live server can
	be told no. Every call is pcalled and every failure ends in an empty board
	with a reason on it rather than an error: a leaderboard is the least important
	screen in the game and must never be the thing that stops a round starting.
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attributes = require(Shared.Net.Attributes)
local Enums = require(Shared.Enums)
local LeaderboardConfig = require(Shared.Config.LeaderboardConfig)
local Registry = require(Shared.Util.Registry)
local Remotes = require(Shared.Net.Remotes)
local Trove = require(Shared.Util.Trove)

local GA = Attributes.Game

local LeaderboardService = {}

local serviceTrove = Trove.new()

--[[ Seconds between one player's requests. A panel with three tabs is three
     legitimate requests in quick succession, so this is short — it exists to
     stop a crafted client asking a thousand times, not to slow down tabbing. ]]
local REQUEST_THROTTLE = 0.4

--[[ One cached page per board: the rows, when they were fetched, and whether the
     fetch worked. `at = 0` means never fetched, which is not the same as fetched
     and empty — a brand new board legitimately has no rows in it. ]]
type Page = {
	rows: { any },
	at: number,
	ok: boolean,
	reason: string,
}

local pages: { [string]: Page } = {}
--[[ Boards currently being fetched. Two players asking at once must produce one
     request; the second waits for the first rather than starting a second. ]]
local fetching: { [string]: boolean } = {}

local stores: { [string]: OrderedDataStore } = {}
local names: { [number]: string } = {}
local lastRequestAt: { [Player]: number } = setmetatable({}, { __mode = "k" }) :: any

--[[ Who was actually in the round. Same rule and the same reason as
     ProgressionService's own roster: somebody who joined during the results
     screen did not survive to wave nine and must not be published as having. ]]
local present: { [Player]: boolean } = {}

local warned: { [string]: boolean } = {}
local function warnOnce(tag: string, message: string)
	if warned[tag] then
		return
	end
	warned[tag] = true
	warn("[LeaderboardService] " .. message)
end

--[[ The store for a board, opened once. A failure here is not fatal and not
     retried per call: DataStoreService:GetOrderedDataStore throws only on a bad
     name or an API that is switched off, and neither gets better by asking
     again. ]]
local function storeFor(board: any): OrderedDataStore?
	local existing = stores[board.id]
	if existing then
		return existing
	end
	local ok, store = pcall(function()
		return DataStoreService:GetOrderedDataStore(LeaderboardConfig.storeName(board))
	end)
	if not ok or not store then
		warnOnce("store", "cannot open the boards; global ranks are off this session")
		return nil
	end
	stores[board.id] = store
	return store
end

--[[ A UserId's display name, cached for the life of the server. Falls back to
     the id itself, which is ugly and true — a row with no name at all reads as a
     bug, and the player it belongs to would rather be a number than absent. ]]
local function nameFor(userId: number): string
	local cached = names[userId]
	if cached then
		return cached
	end
	local ok, name = pcall(function()
		return Players:GetNameFromUserIdAsync(userId)
	end)
	local resolved = if ok and typeof(name) == "string" and name ~= "" then name else ("USER " .. userId)
	names[userId] = resolved
	return resolved
end

-- ── publishing ──────────────────────────────────────────────────────────────

--[[
	Writes one player's value to one board.

	SetAsync rather than UpdateAsync, and that is a real decision. UpdateAsync
	would let the store itself arbitrate a Best — "keep the larger of these two" —
	which sounds safer and is not: the profile is already the authority on this
	number, two servers cannot hold the same profile at once (see ProfileService's
	lock), and an UpdateAsync costs the same budget while adding a read. The store
	is a published copy of a number the profile owns, so it is written, not
	negotiated.
]]
local function publish(board: any, userId: number, value: number)
	local store = storeFor(board)
	if not store then
		return
	end
	local clean = math.clamp(math.floor(value), 0, LeaderboardConfig.MaxValue)
	if clean <= 0 then
		--[[ Zero is not a rank. A player who has won nothing does not belong on
		     the victories board, and writing them there fills a hundred-row page
		     with people tied at nothing. ]]
		return
	end
	local ok, err = pcall(function()
		store:SetAsync(tostring(userId), clean)
	end)
	if not ok then
		warnOnce("publish", "could not publish " .. board.id .. ": " .. tostring(err))
	end
end

--[[ The round, folded into every present player's lifetime totals and published.
     Runs in its own task per player: a SetAsync yields, and three of them for
     four players inside the round-ended handler would hold up everything else
     listening to that signal. ]]
local function onRoundEnded(outcome: string)
	local victory = outcome == Enums.RoundState.Victory
	local waveReached = math.max(math.floor(tonumber(Attributes.get(Workspace, GA.WaveIndex, 0)) or 0), 0)

	local profiles = Registry.find("ProfileService")
	local stats = Registry.find("StatsService")
	if not profiles then
		table.clear(present)
		return
	end

	local rows = {}
	if stats then
		local ok, snapshot = pcall(function()
			return stats:snapshot()
		end)
		if ok and typeof(snapshot) == "table" then
			rows = snapshot
		end
	end

	for _, player in Players:GetPlayers() do
		if not present[player] or not profiles:isReady(player) then
			continue
		end
		--[[ A profile that could not be read must not be published FROM. Its
		     lifetime row is whatever a blank profile starts at, and publishing
		     that would overwrite a real player's real rank with a zero. ]]
		if profiles:isDegraded(player) then
			continue
		end

		local row = rows[player.Name]
		local contribution = {
			rounds = 1,
			victories = if victory then 1 else 0,
			bestWave = waveReached,
			kills = if typeof(row) == "table" then row.kills else 0,
			specialKills = if typeof(row) == "table" then row.specialKills else 0,
			bossKills = if typeof(row) == "table" then row.bossKills else 0,
			headshots = if typeof(row) == "table" then row.headshots else 0,
			revives = if typeof(row) == "table" then row.revives else 0,
		}

		local moved = profiles:recordLifetime(player, contribution)
		if not next(moved) then
			continue
		end

		local userId = player.UserId
		task.spawn(function()
			for _, board in LeaderboardConfig.Boards do
				local value = moved[board.stat]
				if value then
					publish(board, userId, value)
				end
			end
		end)
	end

	table.clear(present)
end

local function markPresent()
	for _, player in Players:GetPlayers() do
		present[player] = true
	end
end

-- ── serving ─────────────────────────────────────────────────────────────────

--[[ Fetches one board's top page. Called only from behind the cache check and
     the `fetching` guard, so it is never running twice for one board. ]]
local function fetch(board: any)
	local store = storeFor(board)
	if not store then
		pages[board.id] = { rows = {}, at = os.clock(), ok = false, reason = "OFFLINE" }
		return
	end

	local ok, result = pcall(function()
		--[[ false = descending, which is the whole point: the top of a board is
		     the largest values. Same number for the page size and the row count
		     because a page is exactly what gets drawn. ]]
		return store:GetSortedAsync(false, LeaderboardConfig.Rows):GetCurrentPage()
	end)

	if not ok or typeof(result) ~= "table" then
		warnOnce("fetch", "could not read " .. board.id .. ": " .. tostring(result))
		pages[board.id] = { rows = {}, at = os.clock(), ok = false, reason = "UNAVAILABLE" }
		return
	end

	local rows = {}
	for index, entry in result do
		local userId = tonumber(entry.key)
		if not userId then
			continue
		end
		table.insert(rows, {
			rank = index,
			userId = userId,
			name = nameFor(userId),
			value = math.max(math.floor(tonumber(entry.value) or 0), 0),
		})
	end

	pages[board.id] = { rows = rows, at = os.clock(), ok = true, reason = "" }
end

--[[ This player's own standing, which is NOT on the page for most people.

     Read straight off their profile rather than searched for in the store: the
     value is the same number the store holds, the profile is already in memory,
     and there is no request in the world that answers "what rank is this one
     player" on an OrderedDataStore without walking it. So the panel shows YOUR
     NUMBER always and your RANK only when you are on the page — which is the
     honest version, and the one every game this is imitating actually does. ]]
local function selfRowFor(player: Player, board: any): any?
	local profiles = Registry.find("ProfileService")
	if not profiles or not profiles:isReady(player) then
		return nil
	end
	local lifetime = profiles:getLifetime(player)
	local value = math.max(math.floor(tonumber(lifetime[board.stat]) or 0), 0)
	return { userId = player.UserId, name = player.Name, value = value }
end

local function onRequest(player: Player, boardId: any)
	local now = os.clock()
	if lastRequestAt[player] and now - lastRequestAt[player] < REQUEST_THROTTLE then
		return
	end
	lastRequestAt[player] = now

	local board = LeaderboardConfig.get(if typeof(boardId) == "string" then boardId else nil)
	if not board then
		return
	end

	local cached = pages[board.id]
	local stale = not cached or (os.clock() - cached.at) >= LeaderboardConfig.CacheSeconds
	if stale and not fetching[board.id] then
		fetching[board.id] = true
		--[[ Spawned, so the remote handler returns immediately. The client is
		     already drawing "LOADING"; a handler that yielded on a web call
		     would hold the remote's thread for the duration. ]]
		task.spawn(function()
			fetch(board)
			fetching[board.id] = nil

			--[[ Answered to EVERYBODY waiting rather than to the one who asked.
			     Ten players in a lobby opening the panel together produce one
			     fetch, and all ten want the answer to it. ]]
			local page = pages[board.id]
			for _, other in Players:GetPlayers() do
				if other.Parent then
					Remotes.Event.LeaderboardPage:FireClient(other, {
						board = board.id,
						rows = page.rows,
						ok = page.ok,
						reason = page.reason,
						me = selfRowFor(other, board),
					})
				end
			end
		end)
		return
	end

	if cached then
		Remotes.Event.LeaderboardPage:FireClient(player, {
			board = board.id,
			rows = cached.rows,
			ok = cached.ok,
			reason = cached.reason,
			me = selfRowFor(player, board),
		})
	end
end

-- ── lifecycle ───────────────────────────────────────────────────────────────

function LeaderboardService:init()
	serviceTrove:connect(Players.PlayerRemoving, function(player: Player)
		present[player] = nil
		lastRequestAt[player] = nil
	end)
end

function LeaderboardService:start()
	serviceTrove:connect(Remotes.Event.RequestLeaderboard.OnServerEvent, onRequest)

	local round = Registry.find("RoundService")
	if round then
		if round.roundEnded then
			serviceTrove:add(round.roundEnded:connect(onRoundEnded))
		end
		--[[ Every wave edge, so a mid-round joiner is on the roster from the
		     next wave. Mirrors ProgressionService exactly, and has to: a player
		     paid for a round they were in should be ranked for it too. ]]
		if round.waveChanged then
			serviceTrove:add(round.waveChanged:connect(markPresent))
		end
	else
		warn("[LeaderboardService] no RoundService; nothing will ever be published")
	end
end

function LeaderboardService:destroy()
	serviceTrove:destroy()
	table.clear(pages)
	table.clear(fetching)
	table.clear(stores)
	table.clear(present)
end

Registry.register("LeaderboardService", LeaderboardService)

return LeaderboardService
