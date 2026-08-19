--!strict
--[[
	MapConfig — the map roster, the ammo crates, and the end-of-round vote.

	Maps live in ServerStorage, not Workspace. Only the one being played is in the
	world at any moment, which is what makes swapping between rounds fast: the
	replacement is already assembled in memory and the swap is two reparents, not
	a rebuild.

	Adding a map is one entry here plus a model in ServerStorage.Maps. No code.
]]

local MapConfig = {}

--[[ Where the server looks for maps, and where the live one is parented. Both
     are created on first use if they do not exist. ]]
MapConfig.StorageFolder = "Maps" -- ServerStorage.Maps
MapConfig.LiveFolder = "CurrentMap" -- Workspace.CurrentMap

export type MapDefinition = {
	id: string, -- must match the model name in ServerStorage.Maps
	displayName: string,
	blurb: string, -- one line, shown on the vote card
}

MapConfig.Maps = {
	{
		id = "Zombieville",
		displayName = "ZOMBIEVILLE",
		blurb = "Open streets. Long sightlines. Nowhere to hide.",
	},
	{
		id = "Clinton",
		displayName = "CLINTON",
		blurb = "Tight corridors. Close quarters. Bring the shotgun.",
	},
} :: { MapDefinition }

MapConfig.DefaultMap = "Zombieville"

--[[
	Ammo crates.

	Discovered by NAME rather than by tag, so a level designer never has to
	remember to tag anything: put a folder called "Ammo Crate" in the map, drop
	six models called "Ammo Crate 1" through "Ammo Crate 6" in it, done. The
	service tags them itself on load.

	One use each. Taking a crate removes it for RespawnSeconds, which is the whole
	tactical point — the team has to spread out across the map rather than
	camping one resupply, and a crate you already burned is a hole in your plan
	for nearly three minutes.
]]
MapConfig.AmmoCrates = table.freeze({
	FolderName = "Ammo Crate",
	Tag = "FL_AmmoCrate",

	RespawnSeconds = 165,
	UseSeconds = 2.5, -- hold time; long enough to be a commitment in a fight
	Range = 12,

	-- A crate refills the primary's reserve completely. Partial refills read as
	-- stingy and make players hoard crates instead of using them.
	RefillFraction = 1.0,
	-- And tops the magazine up too, so you walk away actually ready rather than
	-- having to reload immediately.
	RefillMagazine = true,

	-- Presentation while it is spent, so the spot still reads as "a crate lives
	-- here" rather than as empty floor.
	LeaveGhost = true,
	GhostTransparency = 0.82,
	GhostColor = Color3.fromRGB(58, 54, 48),
})

--[[ The end-of-round vote. Short on purpose: the scoreboard is already up, and
     a long vote is dead time between two rounds. ]]
MapConfig.Vote = table.freeze({
	DurationSeconds = 20,
	-- With one map in the roster there is nothing to decide; with two, a tie is
	-- broken by whichever was NOT just played, so the game never repeats a map
	-- purely because a vote split evenly.
	BreakTiesAwayFromCurrent = true,
	AllowChangingVote = true,
})

function MapConfig.get(id: string): MapDefinition?
	for _, map in MapConfig.Maps do
		if map.id == id then
			return map
		end
	end
	return nil
end

function MapConfig.ids(): { string }
	local ids = {}
	for _, map in MapConfig.Maps do
		table.insert(ids, map.id)
	end
	return ids
end

return MapConfig
