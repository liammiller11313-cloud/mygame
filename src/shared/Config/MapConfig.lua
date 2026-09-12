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

--[[
	The two halves of the map handshake, in one place because their ORDER is the
	whole point.

	A joining body is anchored until its client says it can see the map. The
	client gives up waiting after `ClientWait` and confirms anyway — an honest "I
	tried" — and the server gives up holding after ClientWait + ServerGrace.

	Those two numbers used to live in two files, one at twelve and one at twenty,
	which is the wrong way round: the server stopped holding eight seconds BEFORE
	the client stopped waiting. A player on a slow connection — the only kind
	that ever needed the hold — was released onto a map they were still
	downloading, which is the exact fall the whole mechanism exists to prevent,
	arriving twelve seconds later than it used to.

	So the server's patience is derived from the client's rather than written
	beside it. The grace is a round trip and a little slack: the client's
	confirmation has to be able to LAND while the server is still listening, or
	the hold ends on a timeout instead of on an answer and the difference is
	invisible until somebody falls.
]]
MapConfig.Handshake = table.freeze({
	ClientWait = 20,
	ServerGrace = 4,
	--[[
		Whether the handshake narrates itself into the output.

		On because three fixes have been aimed at this and the last one cannot be
		proved from here: it needs a real client on a real connection, and the
		only thing that survives that trip is the log. Each side prints one line
		per player per map — how long the client waited, how many parts it had
		against how many it should have, whether the body was held at all, and
		which of the two paths let it go.

		Turn OFF once a live round reads clean. Nothing branches on this except
		the printing, so flipping it changes no behaviour, only how much the
		output says.
	]]
	Trace = true,
})

function MapConfig.serverHoldSeconds(): number
	return MapConfig.Handshake.ClientWait + MapConfig.Handshake.ServerGrace
end

--[[ Set by MapService on a map's own Sound once it has been adopted into
     SoundService, and read by MusicController so it can duck it. Here rather
     than in either of them because it is the one string they have to agree on,
     and a map author's Sound can be called anything. ]]
MapConfig.MusicAttribute = "FL_MapMusic"

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

	--[[
		A boss this map, and only this map, ends on.

		Present on one map. When it is set, the FINAL wave releases this instead
		of whatever the wave table declared — and instead of whatever its
		substitution pool would have rolled, because a boss that is exclusive to
		a map is not exclusive if a coin flip can replace it with a Metallic.

		Here rather than in GameModeConfig because the wave table is the round's
		SHAPE and is deliberately the same everywhere: a boss lands on 5, 8, 11
		and 15, and a team that has played four rounds can feel that rhythm
		coming whatever they voted for. What changes per map is a fact about the
		map, and this file is where facts about maps live.

		It replaces the finale's TIER as well as its kind — see
		GameModeConfig.rollBosses, which drops the Apex multiplier for the same
		reason it drops it from a substitute: the multiplier exists to make a
		Tank into a finale, and a creature that already is one does not need
		tripling.
	]]
	finaleBoss: string?,

	--[[
		This map's own Sound IS the music, and the round soundtrack stands down.

		Normally a map's Sound is a BED that plays under the wave soundtrack —
		ambient, buildup, horde — and the two are mixed together. On one map that
		is wrong: the Backrooms is a place whose whole character is a room tone
		nobody wrote a melody over, and a horde cue rising through it turns it
		into a level in an action game.

		So the map says so, and MusicController drops its three wave beds while
		this map is loaded. What it keeps is deliberate and is the whole reason
		this is a flag rather than "turn the music off":

		  KEPT     the Tank and Witch themes, and the Victory and Defeat stings.
		           A boss arriving must still be announced — it is the one thing
		           the music says that the player cannot see coming — and the end
		           of a round is a moment, not a mood.
		  DROPPED  Ambient, Buildup, Horde, and any panic override. Those are the
		           soundtrack this map is replacing.

		The map's Sound is also DUCKED under a boss theme, on the same rule the
		wave beds already follow: a drone at full volume under a Tank theme is two
		tracks arguing rather than one rising over the other.
	]]
	replacesMusic: boolean?,
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
	{
		id = "Backrooms",
		--[[ The one map with a finale of its own. See finaleBoss above, and
		     InfectedConfig for why this creature belongs here rather than in the
		     general roster: it attacks standing still, and identical rooms with
		     no landmarks is the one place where being moved actually costs
		     something. ]]
		finaleBoss = Enums.Infected.BacteriaMonster,
		displayName = "BACKROOMS",
		--[[ A different SHAPE of blurb from the other three, deliberately. Those
		     are three fragments naming what the map is and what to bring, which
		     is the right thing to say about a street or a corridor. This map's
		     whole idea is not knowing, so its line is a hook rather than a
		     briefing. The author's own words, with an "an" and one fewer full
		     stop. ]]
		blurb = "It's an endless maze, there is no exit... or is there?",
		image = "rbxassetid://3254834849",
		--[[ The one map with a voice of its own. Its Sound — Backrooms_Ambience,
		     sitting in the model — is the whole soundtrack here, and the wave
		     cues stand down for it. Bosses still get their themes. See the field
		     for what is kept and what is dropped. ]]
		replacesMusic = true,
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

--[[ The boss a map ends on, or nil — which is the answer for every map but
     one. Nil means "whatever the wave table declared", which is the whole
     roster's normal behaviour and must never read as a mistake. ]]
function MapConfig.finaleBossFor(mapId: string?): string?
	if typeof(mapId) ~= "string" then
		return nil
	end
	for _, map in MapConfig.Maps do
		if map.id == mapId then
			return map.finaleBoss
		end
	end
	return nil
end

--[[
	── SURFACES NOTHING MAY BE SPAWNED ON ──────────────────────────────────────

	A raycast cannot tell a floor from a ceiling: both are flat, both have an
	upward normal from the side you hit them, and the top of a wall is the best
	looking floor in any map. That is how a Tank ended up on the roof of the
	Backrooms and how bodies end up standing on top of a wall they cannot get
	down from.

	SpawnPlacement has geometric guards for this — a height band, an overhead
	cover test, a check that the floor belongs to the loaded map — and every one
	of them is an inference. This is the other kind of answer: a level designer
	naming the thing. It costs nothing, it cannot be fooled by an unusual room,
	and the names below are ones people already use.

	── HOW A NAME IS MATCHED ───────────────────────────────────────────────────
	Folded the same way a map's item folders are, so case, spaces, punctuation
	and a single trailing "s" all stop mattering: Wall, walls, WALLS and "Wall_"
	are one name. And it is matched against the part AND every model it sits
	inside up to the map root — a model called Walls full of models called
	section, which is exactly how the Backrooms is built, is answered by the one
	entry rather than by listing everything underneath it.

	── ON "CELING" ─────────────────────────────────────────────────────────────
	Spelled both ways on purpose. A real map in this game has it with one E, and
	a rule that only recognised the correct spelling would silently not apply to
	the map it was written for — which is a worse outcome than a list with a typo
	in it. The fold cannot help here: it removes punctuation and a plural, not a
	missing letter.

	── AND WHAT IT DOES NOT DO ─────────────────────────────────────────────────
	It does not make anything non-collidable and it does not stop a body WALKING
	onto a wall it can reach. It answers one question — may a spawn be placed
	here — which is the question that was being answered by guessing.
]]
MapConfig.NeverStandOn = table.freeze({
	"Ceiling",
	"Celing",
	"Roof",
	"Wall",
})

--[[ Whether a name means "not a floor". Case, punctuation and a trailing plural
     are folded away first; see NeverStandOn. ]]
function MapConfig.isNeverStandOn(name: string): boolean
	if typeof(name) ~= "string" then
		return false
	end
	local folded = foldFolderName(name)
	for _, blocked in MapConfig.NeverStandOn do
		if folded == foldFolderName(blocked) then
			return true
		end
	end
	return false
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

--[[
	Models an explosion must not be able to take apart, by name, in any map.

	── WHY THIS EXISTS, AND WHY IT IS A LIST OF NAMES ──────────────────────────
	The classic rocket launcher's blast is a real Roblox `Explosion` with
	`DestroyJointRadiusPercent` at the classic 1, which breaks every legacy joint
	inside the radius. That is the weapon working: wrecking the place is most of
	what a brickbattle rocket is for, and on Crossroads — the one map built out
	of parts loose enough to notice — you can see it happen.

	The loot room is the exception. It is the payoff for four beacons held alight
	at once, and a team that blows the walls off it has skipped the objective
	rather than beaten it. `LostTemple` is Crossroads', and the reward is behind
	its `Gate`.

	Protection is anchoring, applied when the map loads. An anchored part is one
	an explosion can neither move nor drop when its joints go, so the model is
	simply immune — no per-blast bookkeeping, nothing to get wrong at the moment
	a rocket lands. It is safe here because the loot room's gate is DESTROYED
	when the puzzle is solved rather than swung open (see PuzzleConfig's
	CrossroadsBeacons entry), so nothing in this model was ever going to move.

	A name rather than a tag because that is how every other map contract in this
	file works — the item folders, the ammo crates, the ledges. A level designer
	names things anyway; tagging is one more thing to forget.
]]
MapConfig.Indestructible = table.freeze({
	"LostTemple",
})

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
	--[[
		A number for the WARNING to quote, and nothing else.

		MapItemService walks `folder:GetChildren()` — it never counts up to this
		and never stops at it — so a designer who adds three more medkits to a map
		gets three more medkits with no code change, which is the behaviour you
		want from a build that is edited far more often than this file is.

		Which means these numbers drift, and are allowed to: they are here so the
		message a missing folder prints can say "no Medkit 1 through Medkit 11"
		instead of "no medkits", and being a couple out makes that sentence
		slightly less precise rather than wrong. The maps currently carry a few
		more of everything than the figures below. Do not treat this as a budget.
	]]
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

	--[[
		THE THROWABLES, which used to come out of an assets folder and now come
		out of the map like everything else here.

		That is a design decision rather than a tidying one. A throwable in an
		assets folder is something the Director hands you; a throwable standing on
		a shelf is a reason to go and look at the shelf. It is the cheapest thing
		a level can do to make its own rooms worth walking into, and it is most of
		why exploring a Left 4 Dead map is worth the time it costs.

		More of them than there are medkits, and they refill faster, because they
		are meant to be SPENT. A pipe bomb somebody is saving for later is a pipe
		bomb doing nothing, and a map that makes you feel rich in them is a map
		where you throw one at the horde instead of backing down a corridor.

		Every throwable in the game has a family here. A new one joins them with
		a folder and an entry and nothing else has to change — and until it has
		both, ItemPlacer will still place it off the built-in model, so it works
		before its models exist rather than after.
	]]
	table.freeze({
		key = "Molotovs",
		folderName = "Molotovs",
		modelName = "Molotov",
		expectedCount = 6,
		slot = Enums.Slot.Throwable,
		itemId = Enums.Throwable.Molotov,
		tag = "FL_MolotovPickup",
		respawnSeconds = 40,
		leaveGhost = true,
		ghostTransparency = 0.9,
	}),
	table.freeze({
		key = "PipeBombs",
		folderName = "Pipe Bombs",
		modelName = "Pipe Bomb",
		expectedCount = 7,
		slot = Enums.Slot.Throwable,
		itemId = Enums.Throwable.PipeBomb,
		tag = "FL_PipeBombPickup",
		respawnSeconds = 40,
		leaveGhost = true,
		ghostTransparency = 0.9,
	}),

	--[[ Seven, matching the pipe bombs rather than the molotovs' six, because
	     this is the throwable a team is most likely to spend without a target
	     in front of them — a leak put down before a wave arrives is the whole
	     point of it, and an item you place ahead of time gets used more often
	     than one you throw in a panic.

	     Sixty seconds rather than forty. The zone itself runs for fifty, so a
	     forty-second respawn would let one player keep a permanent leak going
	     somewhere on the map with nothing but patience. The refill
	     clock and the zone's own duration are the two halves of how often this
	     item can be on the floor at all. ]]
	table.freeze({
		key = "HazardousWastes",
		folderName = "Hazardous Wastes",
		modelName = "Hazardous Waste",
		expectedCount = 7,
		slot = Enums.Slot.Throwable,
		itemId = Enums.Throwable.HazardousWaste,
		tag = "FL_HazardousWastePickup",
		respawnSeconds = 60,
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
