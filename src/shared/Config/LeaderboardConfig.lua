--!strict
--[[
	LeaderboardConfig — the global boards, and what a row on one says.

	Three boards, every server in the universe, all time. They are the only thing
	in this game that compares a player to somebody they will never meet, and that
	is worth being careful about: a leaderboard is the one screen where a player
	can discover that the thing they spent a week on does not count.

	── WHY THREE, AND WHY THESE THREE ──────────────────────────────────────────
	A single board answers one question and tells everybody who cannot win it that
	they are nobody. Three boards, deliberately measuring different virtues:

	  FURTHEST     the best single round anybody has had. Skill and nerve, in one
	               number, and the only one where a first-time player can take a
	               top rank in one afternoon. GameModeConfig's own header says the
	               wave number IS the score, so this is the headline board.
	  VICTORIES    how many rounds finished. Persistence, which is a different
	               thing from skill and deserves its own column.
	  BODY COUNT   lifetime kills. The big number. It rewards nothing but time and
	               everybody knows it, which is exactly why it should not be the
	               only board and exactly why it should exist.

	── BEST AND TOTAL ARE DIFFERENT SHAPES ─────────────────────────────────────
	`mode` is the difference between "your best ever" and "all of them added up",
	and it decides what publishing does: a Best is written only when this round
	beat the stored one, a Total is written every round because it moved. Getting
	that backwards would either freeze a total at its first value or let a bad
	round lower somebody's record.

	── THE TAG ─────────────────────────────────────────────────────────────────
	A row is a rank, a TAG, a name and a number. The tag is the callsign the
	player earned on the pass track, drawn in the accent colour they earned with
	it — so the board is also an advertisement for the thing that unlocks them,
	and a player scrolling it can see what the ranks above them are wearing.

	It is EARNED rather than typed, which is the deliberate half. Free text on a
	global leaderboard is a moderation surface, and one that renders to every
	player in the game before anybody looks at it. The intention is to let players
	choose their own tag later; when that lands, it lands as a CHOICE among things
	they have unlocked, and this file is where the two meet.
]]

local ProgressionConfig = require(script.Parent.ProgressionConfig)

local LeaderboardConfig = {}

--[[
	The season. Part of every store's name, and the only lever that resets a board.

	An OrderedDataStore cannot be emptied — there is no "delete everything" call —
	so the only way to start a board over is to stop reading the old one. Bumping
	this number does exactly that, and leaves the previous season's data intact
	underneath in case it turns out the reset was the mistake.

	Change it for a reset and for nothing else. In particular do NOT change it
	because a stat's meaning changed: that is a reason to change the board's `id`,
	which is a smaller and more honest break.
]]
LeaderboardConfig.Season = 1

--[[ Prefix on every store name. Long and specific because a DataStore namespace
     is shared with every other system in the game and a name like "Kills" is a
     collision waiting for somebody to write one. ]]
LeaderboardConfig.StorePrefix = "FL_Leaderboard"

--[[ How many rows a board serves. One hundred is the number every game this one
     is imitating uses, and it is a real constraint rather than a round number:
     GetSortedAsync pages, and a page this size is one request. ]]
LeaderboardConfig.Rows = 100

--[[
	How long a fetched board stays good, in seconds.

	Not a refresh rate — nothing polls. It is how stale a cached page may be
	before the next player who asks for it triggers a fetch. Two minutes because
	GetSortedAsync is budgeted per server rather than per player: a board that
	re-fetched per request would let ten players in a lobby spend the whole
	server's read budget looking at a list that has not moved.

	The cost of the staleness is that a player who just finished a round may not
	see their new rank for two minutes. That is worth saying on the screen, and
	the panel does.
]]
LeaderboardConfig.CacheSeconds = 120

--[[ The ceiling an OrderedDataStore value may not cross. It stores a signed
     64-bit integer, and this is far below that — but it is also far above any
     honest number this game produces, so a value at this ceiling is a bug and
     clamping to it makes the bug visible instead of throwing. ]]
LeaderboardConfig.MaxValue = 1_000_000_000

export type Board = {
	id: string,
	displayName: string,
	--[[ One line, under the tab. What the number MEANS, because "5" on a board
	     called FURTHEST is meaningless to somebody who has not played fifteen
	     waves yet. ]]
	blurb: string,
	--[[ Which field of a profile's lifetime row this ranks. Every one of them is
	     a number ProfileService already persists — a board that needed new
	     bookkeeping would be a board that can silently stop counting, which is
	     the same rule the quest pool is written under. ]]
	stat: string,
	--[[ "Best" keeps the highest ever seen; "Total" keeps a running sum. Decides
	     both what the profile does with a round's number and whether publishing
	     writes at all. ]]
	mode: "Best" | "Total",
	--[[ Drawn after the value. "" for a plain count. ]]
	unit: string,
}

local BOARDS: { Board } = table.freeze({
	table.freeze({
		id = "BestWave",
		displayName = "FURTHEST",
		blurb = "The highest wave reached in a single round.",
		stat = "bestWave",
		mode = "Best" :: "Best",
		unit = "",
	}),
	table.freeze({
		id = "Victories",
		displayName = "VICTORIES",
		blurb = "Rounds survived to the end. All fifteen waves.",
		stat = "victories",
		mode = "Total" :: "Total",
		unit = "",
	}),
	table.freeze({
		id = "Kills",
		displayName = "BODY COUNT",
		blurb = "Infected put down, since the first round you played.",
		stat = "kills",
		mode = "Total" :: "Total",
		unit = "",
	}),
}) :: { Board }

LeaderboardConfig.Boards = BOARDS

--[[ A board by id, or nil. Ids arrive off a remote, so an unknown one has to be
     a nil rather than an error — the worst outcome of a stale client asking for
     a board that was renamed is an empty panel. ]]
function LeaderboardConfig.get(id: string?): Board?
	if typeof(id) ~= "string" then
		return nil
	end
	for _, board in BOARDS do
		if board.id == id then
			return board
		end
	end
	return nil
end

--[[ The OrderedDataStore name for a board. Season is in the middle rather than
     at the end so a sorted listing of the namespace groups a season together,
     which is what somebody looking at this in the console actually wants. ]]
function LeaderboardConfig.storeName(board: Board): string
	return string.format("%s_v%d_%s", LeaderboardConfig.StorePrefix, LeaderboardConfig.Season, board.id)
end

--[[
	The blank lifetime row.

	Declared HERE rather than in ProfileService, because the fields it holds are
	the fields the boards rank and the two must not be able to drift. A board
	naming a stat this table does not have would be a board that reads nil and
	publishes nothing, silently, for everybody, forever.

	More fields than there are boards on purpose. `rounds`, `bossKills` and the
	rest are not ranked by anything today and are cheap to keep — a lifetime
	counter that was never started cannot be started retroactively, and the day
	somebody wants a board for boss kills is a day it matters whether the number
	has been counting since launch or since that afternoon.
]]
function LeaderboardConfig.blankLifetime(): { [string]: number }
	return {
		rounds = 0,
		victories = 0,
		kills = 0,
		specialKills = 0,
		bossKills = 0,
		headshots = 0,
		revives = 0,
		bestWave = 0,
	}
end

--[[ Whether a lifetime field is a running total rather than a high-water mark.
     Derived from the boards where one says, and defaulting to Total — every
     unranked field in the blank row above is a count of things that happened,
     and a count that stopped summing is a count that is wrong. ]]
function LeaderboardConfig.isBest(stat: string): boolean
	for _, board in BOARDS do
		if board.stat == stat then
			return board.mode == "Best"
		end
	end
	return false
end

--[[
	The tag and colour for a player's row, from the two pass attributes every
	client already has for every other player.

	Returns "" and nil for somebody wearing nothing, which is most people most of
	the time — a caller that draws whatever it gets is correct. Lives here rather
	than in the panel so the in-round scoreboard and the global board cannot end
	up describing the same player two different ways.
]]
function LeaderboardConfig.tagFor(callsignId: string?, accentId: string?): (string, Color3?)
	local callsign = if typeof(callsignId) == "string" and callsignId ~= ""
		then ProgressionConfig.getReward("Callsign", callsignId)
		else nil
	local accent = if typeof(accentId) == "string" and accentId ~= ""
		then ProgressionConfig.getReward("Accent", accentId)
		else nil
	return (if callsign then callsign.label else ""), (if accent then accent.color else nil)
end

return LeaderboardConfig
