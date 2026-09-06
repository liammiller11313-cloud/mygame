--!strict
--[[
	MapConfig — the map roster, the ammo crates, and the end-of-round vote.

	Maps live in ServerStorage, not Workspace. Only the one being played is in the
	world at any moment, which is what makes swapping between rounds fast: the
	replacement is already assembled in memory and the swap is two reparents, not
	a rebuild.

	Adding a map is one entry here plus a model in ServerStorage.Maps. No code.
]]

local Enums = require(script.Parent.Parent.Enums)

local MapConfig = {}

--[[ Where the server looks for maps, and where the live one is parented. Both
     are created on first use if they do not exist. ]]
MapConfig.StorageFolder = "Maps" -- ServerStorage.Maps
MapConfig.LiveFolder = "CurrentMap" -- Workspace.CurrentMap

export type MapDefinition = {
	id: string, -- must match the model name in ServerStorage.Maps
	displayName: string,
	blurb: string, -- one line, shown on the vote card
	--[[
		The vote card's picture. Optional, and a map without one is not broken —
		it draws exactly the card it drew before there were any, which is what
		makes adding the second and third safe to do one at a time.

		A rbxassetid the uploader owns, or the game does. Roblox refuses to render
		an image belonging to somebody else, and it refuses SILENTLY: the card
		comes up empty with nothing in the output to say why. If a picture is
		blank in-game and the id is right, that is the first thing to check.
	]]
	image: string?,
	--[[
		A scale on whatever volume the map's own background Sound was authored at,
		or nil to leave it alone.

		A map that ships its own music is mixing against nothing — the author
		hears it on its own, not under a horde, a Tank's roar and thirty
		gunshots. This is the one number that reconciles the two without going
		back into the map and re-saving the Sound, and it is a SCALE rather than
		an absolute so the author's own relative choices survive it.
	]]
	musicVolume: number?,
}

MapConfig.Maps = {
	{
		id = "Zombieville",
		displayName = "ZOMBIEVILLE",
		blurb = "Open streets. Long sightlines. Nowhere to hide.",
		image = "rbxassetid://133615664807337",
	},
	{
		id = "Clinton",
		displayName = "CLINTON",
		blurb = "Tight corridors. Close quarters. Bring the shotgun.",
		image = "rbxassetid://83650761275509",
	},
	{
		id = "Crossroads",
		displayName = "CROSSROADS",
		--[[ Written blind — nobody has described this map to the code yet. It says
		     something true of anywhere called a crossroads and nothing that could
		     be wrong about the geometry; replace it once the map has been played,
		     the way the other two blurbs name what you should bring. ]]
		blurb = "Four ways in. Four ways out. Watch all of them.",
		image = "rbxassetid://111409477664761",
		--[[ Its own track came in loud enough to sit on top of the round rather
		     than under it. Just under half, which puts it where the other two
		     maps' silence leaves the horde: audible, and not the thing you are
		     listening to. Tune it here rather than in the map. ]]
		musicVolume = 0.45,
	},
} :: { MapDefinition }

--[[
	Whether a folder somebody put in their map is the one a system is looking for.

	Two services had a copy of this each, and both copies folded case and stripped
	spaces — which handles "ammocrate" and "Ammo Crate" and does NOT handle
	"Ammo Crates". A trailing S is the single most likely way a hand-typed folder
	name differs from a config one, because the folder holds six of the thing and
	naming it in the plural is what a person does. The config says "Ammo Crate";
	the map said "Ammo Crates"; nothing matched, and the map ran with no resupply
	at all and one warning nobody was looking at.

	So: case, whitespace and punctuation folded away, and a single trailing S
	dropped from BOTH sides so it does not matter which one is plural. Living here
	rather than in either service because this file owns the FolderName constants
	— a rule about how those are compared belongs with them, and one copy cannot
	drift from the other.
]]
local function foldFolderName(name: string): string
	local folded = string.lower(string.gsub(name, "[^%w]", ""))
	--[[ Only a trailing one, and only when something is left. "s" itself folds to
	     "s" rather than to nothing, so a folder actually called that still
	     compares as itself. ]]
	if #folded > 1 and string.sub(folded, -1) == "s" then
		folded = string.sub(folded, 1, -2)
	end
	return folded
end

function MapConfig.folderMatches(name: string, wanted: string): boolean
	if typeof(name) ~= "string" or typeof(wanted) ~= "string" then
		return false
	end
	return foldFolderName(name) == foldFolderName(wanted)
end

--[[
	The folder names a map actually contains, for a warning that has to say why it
	found nothing.

	"No 'Ammo Crate' folder in the live map" is true and useless: it does not say
	whether the folder is missing, misspelled, nested somewhere unexpected, or
	named in the plural — which is what it actually was. Listing what IS there
	turns that into one glance. Top level only, because a designer's own folders
	are at the top and the hundreds nested inside props are noise.
]]
function MapConfig.folderNamesIn(root: Instance?): string
	if not root then
		return "nothing"
	end
	local names: { string } = {}
	for _, child in root:GetChildren() do
		if (child:IsA("Folder") or child:IsA("Model")) and #names < 12 then
			table.insert(names, string.format("%q", child.Name))
		end
	end
	if #names == 0 then
		return "no folders at all"
	end
	return table.concat(names, ", ")
end

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
--[[
	── EVERY ITEM THE MAP ITSELF SUPPLIES ──────────────────────────────────────

	Three families now, and the contract is one contract: a folder named after
	the family, holding models numbered from one. `MapItemService` finds them,
	turns each into a pickup where it stands, and refills that spot on a clock
	once the item it produced has actually been spent.

	Naming rather than tagging, for the same reason as the ammo crates: a level
	designer names things anyway, and a tag is one more thing to forget. The
	match is loose — `folderMatches` folds case, spaces and a trailing plural —
	so "Pain Pills", "pain pills" and "PainPill" all find the same folder.

	The models are also where the game's ART for these items comes from.
	PlaceholderFactory copies whatever is standing in the map rather than
	building its own, so an item the Director drops on a pad is the same object
	the player has been walking past all round. There is no second place to
	update when the model changes.

	── WHY THE REFILL CLOCK STARTS WHERE IT DOES ───────────────────────────────
	On the SPEND, not on the pickup. Four things empty a slot — using the item,
	dropping it, swapping it, and dying — and only the first destroys anything.
	The other three leave the item lying in the world, so refilling on those
	would print items. Carrying an unspent kit around must not quietly restock
	the map behind you.
]]
export type MapItemFamily = {
	key: string, -- stamped on every spawned model, so a pickup knows its family
	folderName: string,
	--[[ What one model inside is called, for the warning that fires when the
	     folder is missing. Nothing enforces the count — nine or three or twenty
	     all work, and a model with no trailing number keeps discovery order. ]]
	modelName: string,
	expectedCount: number,
	slot: string,
	itemId: string,
	tag: string,
	respawnSeconds: number,
	--[[ A taken spawn point leaves a faint outline, exactly as a spent crate
	     does. A player who has learned the map should be able to plan around an
	     item that is not there yet. ]]
	leaveGhost: boolean,
	ghostTransparency: number,
}

MapConfig.MapItems = table.freeze({
	table.freeze({
		key = "Medkits",
		folderName = "Medkits",
		modelName = "Medkit",
		expectedCount = 11,
		slot = Enums.Slot.Health,
		itemId = Enums.HealthItem.Medkit,
		tag = "FL_Medkit",
		respawnSeconds = 30,
		leaveGhost = true,
		ghostTransparency = 0.86,
	}),

	--[[ Nine and seven, against the medkit's eleven, and the split is the point.
	     Pills are the consolation prize a hurt team finds when there is no kit,
	     so there should be a few of them; adrenaline is a tool rather than a
	     heal — you take it to DO something — and finding one should feel like a
	     decision about the next thirty seconds.

	     Both refill slower than a medkit. A kit is the thing a round is planned
	     around and the map should not run out of them; a pill bottle that came
	     back every half minute would make the buffer free. ]]
	table.freeze({
		key = "PainPills",
		folderName = "Pain Pills",
		modelName = "Pain Pills",
		expectedCount = 9,
		slot = Enums.Slot.Pills,
		itemId = Enums.PillItem.PainPills,
		tag = "FL_PainPills",
		respawnSeconds = 45,
		leaveGhost = true,
		ghostTransparency = 0.9,
	}),
	table.freeze({
		key = "Adrenaline",
		folderName = "Adrenaline Shots",
		modelName = "Adrenaline Shot",
		expectedCount = 7,
		slot = Enums.Slot.Pills,
		itemId = Enums.PillItem.Adrenaline,
		tag = "FL_Adrenaline",
		respawnSeconds = 55,
		leaveGhost = true,
		ghostTransparency = 0.9,
	}),
}) :: { MapItemFamily }

--[[ The family that supplies an item id, or nil for one the map does not place.
     Both pill families share a Slot, so the id is the only thing that separates
     them and every lookup has to go through the id rather than the slot. ]]
function MapConfig.mapItemFor(itemId: string?): MapItemFamily?
	if typeof(itemId) ~= "string" then
		return nil
	end
	for _, family in MapConfig.MapItems do
		if family.itemId == itemId then
			return family
		end
	end
	return nil
end

--[[
	── LEDGES YOU CAN SURVIVE ──────────────────────────────────────────────────

	A drop marked with a catch volume does not kill a survivor who walks off it.
	They grab the lip instead, hang there bleeding on a clock, and a teammate has
	to stop shooting and pull them up — which is the same shape as being
	incapacitated and is deliberately more frightening, because the person who
	comes to help is standing at the edge of the thing that just nearly took you.

	── HOW A DESIGNER MARKS ONE ────────────────────────────────────────────────
	Tag a Part `FL_LedgeCatch` and lay it along the lip of the drop, hanging down
	over the edge. Anything falling through that box is caught. That is all — no
	attributes, no orientation to get right, no script.

	Size it generously, and OUT as well as down. It is a net rather than a line:
	the check samples the path a body actually took, so depth costs nothing and
	a shallow box still catches a fall from any height. What a shallow box cannot
	catch is a fast one going SIDEWAYS — modelled, a survivor charged off an edge
	at 44 studs a second, or launched by a Tank, clears a net that only reaches
	six studs out from the lip and never touches it. Sixteen out catches every
	way there is to leave a ledge, including both of those.

	Length along the lip matters for the same reason and is easier to get right:
	cover the whole edge somebody can walk off.

	The top of the box is the LIP, and that is load-bearing. A survivor is only
	caught once their origin is below it, which is what stops a catch volume
	overlapping the walkway beside it from grabbing anybody who jumps near the
	edge — and they will, constantly, because the edge is where the fighting is.

	The parts are made invisible and inert on load — no collision, no queries —
	so a catch volume can never block a shot or a shove. That is why the test is
	arithmetic against the box rather than a raycast: a volume a bullet can hit
	is a volume that eats bullets, and an invisible wall in front of a drop is a
	worse bug than the one this feature fixes.

	── WHAT IT IS NOT FOR ──────────────────────────────────────────────────────
	Not every drop. A ledge you can be pulled off of is a place a team has to
	commit somebody to, and that only means something if most drops still simply
	kill you. Mark the ones you want to be a moment.
]]
MapConfig.Ledges = table.freeze({
	Tag = "FL_LedgeCatch",

	--[[ Studs per second of DOWNWARD speed before a survivor counts as falling.
	     Above a walk and below a step off a kerb, so crossing a catch volume on
	     a walkway that runs through one does not grab you. ]]
	MinFallSpeed = 14,

	--[[ How far the body's origin sits below the lip. A survivor's root is about
	     three studs off the floor when standing, so this is roughly "hands on the
	     edge, feet in the air". ]]
	HangDrop = 2.6,

	--[[ Where a survivor ends up when the hang ends — this far back from the lip,
	     on the solid side. Used for BOTH endings, and the second one is the
	     reason it exists: a survivor who lets go is incapacitated rather than
	     killed (see SurvivorService), and incapacitating them in mid-air over the
	     drop they just fell down means a body nobody can reach and a timer the
	     team can only watch. They collapse at the edge instead. ]]
	RecoveryInset = 3.5,
	RecoveryRise = 4.0, -- how far above the lip to search downward from
	RecoveryProbe = 14, -- how far down to look for the floor before giving up

	--[[ Seconds before the same survivor can be caught again. Without it a
	     survivor placed back at the lip is inside the volume they were just
	     rescued from, and one step in the wrong direction is a second hang
	     before the first has finished replicating. ]]
	Grace = 2.0,

	--[[ How far apart the path is sampled. The check walks the line from where a
	     body was to where it is; at terminal velocity that line is longer than a
	     shallow catch volume is deep, so testing only the endpoints would let a
	     fast fall pass straight through the net. ]]
	SampleStep = 1.5,
})

--[[
	How a medkit rides on a survivor's back.

	Only the medkit: it is the one carried item big enough to read as a
	silhouette across a room, and that visibility is most of why it is carried at
	all. A pill bottle on someone's shoulder would be three pixels.

	There is deliberately no Range in here either. A medkit is a PICKUP, not a
	station, so both the prompt and the server's reach come from
	GameConfig.Interaction.PickupRange — the same number every other pickup in
	the game uses. A second copy of it would only ever be the one that was
	forgotten.
]]
MapConfig.Medkits = table.freeze({
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
