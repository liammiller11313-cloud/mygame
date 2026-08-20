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

--[[
	Medkits placed in the map.

	Found the same way the crates are — a folder called "Medkits" holding models
	called "Medkit 1" through "Medkit 11" — for the same reason: naming is
	something a level designer already does, and tagging is something they have to
	remember to do.

	Unlike a crate, a medkit is CARRIED. You take it, it rides on your back where
	the rest of the team can see it, and it stays yours until you spend it. That
	visibility is most of the point: in Left 4 Dead the single most useful thing
	you know about a teammate is whether they still have a kit, and you learn it
	by looking at them rather than by opening a menu.

	The spawn point refills thirty seconds after the kit it produced is spent —
	not thirty seconds after it is TAKEN. Carrying a kit you have not used yet
	should not also be quietly restocking the map behind you.
]]
MapConfig.Medkits = table.freeze({
	FolderName = "Medkits",
	Tag = "FL_Medkit",

	--[[ Only used in the "you have not set this up yet" warning, so it names the
	     right range of models. Nothing enforces a count — eleven or three or
	     twenty all work. ]]
	ExpectedCount = 11,

	RespawnSeconds = 30,

	--[[ There is deliberately no Range here. A medkit is a PICKUP, not a
	     station, so both the prompt and the server's reach come from
	     GameConfig.Interaction.PickupRange — the same number every other pickup
	     in the game uses. A second copy of it would only ever be the one that
	     was forgotten. ]]

	--[[ A taken spawn point leaves a faint ghost, exactly as a spent crate does.
	     A player who has learned the map should be able to plan around a kit that
	     is not there yet. ]]
	LeaveGhost = true,
	GhostTransparency = 0.86,

	--[[ How the kit sits on a survivor's back. Studs, in torso space: back from
	     the spine, up towards the shoulders, and turned so the flat face of the
	     kit lies against them rather than the edge.

	     Scale shrinks a map-sized prop down to something a person could actually
	     wear — the supplied models are built to be seen on the floor from three
	     studs away, not strapped to a shoulder blade. ]]
	CarryOffset = CFrame.new(0, 0.35, 0.85) * CFrame.Angles(0, math.rad(180), 0),
	CarryScale = 0.7,

	--[[ Above this size in studs the kit is scaled to fit rather than by
	     CarryScale. A supplied prop that happens to be huge would otherwise
	     become a wardrobe on somebody's back. ]]
	CarryMaxSize = 2.6,
})

--[[ The end-of-round vote. Short on purpose: the scoreboard is already up, and
     a long vote is dead time between two rounds. ]]
MapConfig.Vote = table.freeze({
	DurationSeconds = 20,

	--[[
		Whether a vote also runs while the lobby is counting down toward the first
		round of a fresh server.

		This was off, and the reason was real: "the lobby is counting down" used
		not to be a signal that anybody had decided anything. MatchmakingService
		counts a player who has picked nothing as a vote for the default mode, so
		the countdown began within a second of the first join — the whole of it
		was time the player was sitting on the main menu reading the mode list,
		and a vote thrown over that is a vote thrown over the menu.

		That is no longer true. The lobby now waits for somebody to actually
		choose a mode before it claims anything or starts a clock, so a running
		countdown IS a commitment to going in — which makes it exactly the right
		moment to ask which map. MapVoteService already gated the idle vote on a
		live countdown for this reason; the gate now means what it says.

		So the first round of a server is voted for like every other round. The
		vote covers the screen while it runs (see UI/MapVoteController) because
		choosing where you are about to spend seventeen minutes deserves more
		than a strip along the bottom of the HUD.
	]]
	OnFreshServer = true,

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
