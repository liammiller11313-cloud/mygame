--!nonstrict
--[[
	MainMenuStats — what this client can honestly say about its own round.

	Split out of MainMenuController, which was at 181 top-level locals against
	Luau's hard limit of 200 per scope.

	This is bookkeeping, not presentation. It counts what the local player did —
	kills, headshots, damage taken, and the revives it has to INFER, because
	nothing on the wire says "you revived somebody" — and merges anything the
	server chooses to tell it on top, which always wins. The result screen reads
	the numbers; it does not produce them, and that is the line the split follows.

	Nothing here touches an instance. The menu owns every frame and label in the
	game and this owns four integers, which is why it could leave without a
	single reference being threaded back.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attributes = require(Shared.Net.Attributes)
local Enums = require(Shared.Enums)

local PA = Attributes.Player
local STATE = Enums.SurvivorState

local player = Players.LocalPlayer

local MainMenuStats = {}

--[[ How far through a revive counts as "about to finish". A help that stops
     short of this was somebody else's, or was interrupted; past it, the teammate
     coming back up within HELP_WINDOW is almost certainly ours. ]]
local HELP_NEAR_COMPLETE = 0.5

--[[ How long after a downed teammate stops being downed a nearby help still
     counts as ours. Long enough to cover the round trip that tells us they are
     up, short enough that somebody else's revive across the map is not. ]]
local HELP_WINDOW = 0.75

local NO_DATA = "—"

--[[ What this client can honestly say about itself. Reset when a round starts so
     a second round never inherits the first one's tally. ]]
local localStats = {
	kills = 0,
	headshots = 0,
	damageTaken = 0,
	revives = 0,
}

-- Anything the server chooses to tell us, keyed by player name. Always wins.
local serverStats: { [string]: any } = {}

local help = {
	progress = 0,
	finishedAt = 0,
}

local function resetStats()
	localStats.kills = 0
	localStats.headshots = 0
	localStats.damageTaken = 0
	localStats.revives = 0
	table.clear(serverStats)
	help.progress = 0
	help.finishedAt = 0
end

local STAT_KEYS = { "kills", "headshots", "damageTaken", "revives" }

--[[ Merges anything stat-shaped out of a payload. Both `StatsUpdated` and the
     `scores` table on `RoundEnded` are accepted, so whichever service grows a
     tally first lands on this screen with no change here. ]]
local function mergeStats(name: string, source: any)
	if typeof(source) ~= "table" then
		return
	end
	local record = serverStats[name]
	for _, key in STAT_KEYS do
		local value = tonumber(source[key])
		if value then
			record = record or {}
			record[key] = value
		end
	end
	if record then
		serverStats[name] = record
	end
end

--[[
	Credit for a revive, inferred.

	The server publishes FL_ReviveProgress on the rescuer as well as on the
	person on the floor, but it writes 1.00 and then 0.00 inside the same server
	frame, so the client never observes the completion — attribute writes are
	coalesced before they replicate. What it does observe is a hold bar that was
	most of the way full and then vanished.

	That alone is also true of a revive the player let go of, so it is only half
	the signal: the other half is a teammate actually standing up within a beat
	of it. Both together is a revive. Neither this nor the kill counters are the
	right long-term answer — a server-side tally through StatsUpdated is — but a
	scoreboard that only ever prints dashes is not worth shipping either.
]]
local function noteHelpProgress()
	local progress = Attributes.get(player, PA.ReviveProgress, 0)
	local previous = help.progress
	help.progress = progress

	if progress > 0 or previous < HELP_NEAR_COMPLETE then
		return
	end
	-- Only the person doing the reviving is on their feet.
	local mine = Attributes.get(player, PA.State, STATE.Spectating)
	if mine == STATE.Healthy or mine == STATE.Hurt then
		help.finishedAt = os.clock()
	end
end

local DOWNED_STATES = {
	[STATE.Incapacitated] = true,
	[STATE.LedgeHanging] = true,
	[STATE.Dead] = true,
}

local function onSurvivorStateChanged(payload: any)
	if typeof(payload) ~= "table" or payload.player == player then
		return
	end
	if not DOWNED_STATES[payload.previousState] or DOWNED_STATES[payload.state] then
		return
	end
	if help.finishedAt > 0 and os.clock() - help.finishedAt <= HELP_WINDOW then
		help.finishedAt = 0
		localStats.revives += 1
	end
end

local function onHitConfirmed(payload: any)
	if typeof(payload) ~= "table" or payload.killed ~= true then
		return
	end
	localStats.kills += 1
	if payload.isHeadshot == true then
		-- Headshot KILLS, not headshot hits: on a Common the two are the same
		-- thing by design, and on a Tank a graze is not worth a line on a board.
		localStats.headshots += 1
	end
end

local function onDamageTaken(payload: any)
	if typeof(payload) ~= "table" then
		return
	end
	localStats.damageTaken += math.max(tonumber(payload.amount) or 0, 0)
end

local function statText(name: string, key: string): string
	local record = serverStats[name]
	local value = record and record[key]
	if value == nil and name == player.Name then
		value = localStats[key]
	end
	if typeof(value) ~= "number" then
		return NO_DATA
	end
	return string.format("%d", math.floor(value + 0.5))
end

--[[ The public surface is deliberately verbs rather than the tables. The menu
     asks what to draw; it never reaches into the tally, which is what stops a
     screen quietly becoming the thing that owns the count. ]]
MainMenuStats.reset = resetStats
MainMenuStats.merge = mergeStats
MainMenuStats.noteHelpProgress = noteHelpProgress
MainMenuStats.onSurvivorStateChanged = onSurvivorStateChanged
MainMenuStats.onHitConfirmed = onHitConfirmed
MainMenuStats.onDamageTaken = onDamageTaken
MainMenuStats.text = statText

return MainMenuStats
