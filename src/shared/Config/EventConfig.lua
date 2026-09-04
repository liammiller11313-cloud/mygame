--!strict
--[[
	EventConfig — the random event catalogue, and every number the director reads.

	── WHAT A RANDOM EVENT IS, AND WHAT IT IS NOT ──────────────────────────────
	This game now has four things that change a round and they are deliberately
	not the same thing. Keeping them apart is why this file exists separately
	from the other three:

	  MODIFIER      rolled ONCE at the top of a round and true for all of it.
	                It changes what the round IS. ModifierConfig.
	  REQUISITION   bought with Scrip at a breather, chosen by the team, lasts
	                the rest of the round. RequisitionConfig.
	  ABILITY       a permanent unlock, equipped before a match, pressed during
	                one. AbilityConfig.
	  RANDOM EVENT  nobody chooses it, nobody buys it, it arrives at a time
	                nobody can predict, it lasts a minute or two and then it is
	                over. This file.

	A round can be under FAST ZOMBIES, holding INCENDIARY ROUNDS, with a player
	pressing TURRET, in the middle of a BLACKOUT. None of the four knows the
	others exist.

	── THE GAME IS THE DIRECTOR ────────────────────────────────────────────────
	The map does not decide when an event happens or which one. The game does.
	A map only provides the OBJECTS an event needs — the lights a blackout turns
	off, the places a supply drop can land — and an event with no objects to work
	with on the current map simply is not offered. See `MapFolders` below and
	docs/RANDOM_EVENTS.md.

	That split is the whole architecture. Adding a map costs nothing here.
	Adding an event costs a row here and a module under server/Events/Events; the
	director itself never changes.

	── WHY WEIGHTS RATHER THAN AN EQUAL ROLL ───────────────────────────────────
	Because these are not equally good. Weather is the texture of the mode and
	should be common; a surge is a real difficulty spike and should not be. An
	equal roll over eight events would land the two aggressive ones a quarter of
	the time, which is a different game.

	── AND WHY EVERY EVENT HAS A WINDOW ────────────────────────────────────────
	`minTime`/`minWave` keep the opening minutes clean. A blackout in wave 1,
	before anybody has found a gun, is not tension — it is the game taking the
	round away before the player has been given it. `maxTime` keeps the last
	stretch clean for the opposite reason: the finale is already the hardest part
	of the round and does not need help.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Enums = require(Shared.Enums)

export type EventDefinition = {
	id: string,
	displayName: string, -- what the banner says
	--[[ The line the team hears. Written as a broadcast rather than as a UI
	     string, because it is read out over the top of a fight and the player is
	     not looking at it. ]]
	announcement: string,
	--[[ Relative likelihood among everything eligible at that moment. Not a
	     percentage: the pool changes every time, so the same weight is worth
	     more in a round where fewer events qualify. ]]
	weight: number,
	duration: number, -- seconds it runs for
	--[[ Seconds before this specific event may be chosen AGAIN. Separate from
	     the director's own gap, which governs how often ANY event happens. ]]
	cooldown: number,
	minTime: number, -- seconds into the round, inclusive
	maxTime: number, -- and the last moment it may START
	minWave: number,
	maxWave: number,
	--[[ Whether a round may see it more than once at all. The broadcast is
	     once-only because its whole value is that it is a surprise, and a second
	     one is a radio station. ]]
	repeatable: boolean,
	--[[ Ids that may not be running at the same time as this. Symmetric by
	     convention and checked both ways by the director anyway, so a one-sided
	     entry still works. ]]
	conflicts: { string },
	--[[ 0-1, roughly how much harder this makes the next minute. Read by the
	     director's own pacing guard rather than by any event: two heavy events
	     back to back is a spike nobody asked for, whatever the dice said. ]]
	intensity: number,
}

local EventConfig = {}

--[[ The whole system, off in one place, for a playtest that wants a quiet
     round. ]]
EventConfig.Enabled = true

--[[
	How long the director waits before it considers anything, and between events.

	The first window is longer than the gap on purpose: the opening of a round is
	a loadout screen, a ready gate and a wave the team is still finding its feet
	in, and an event landing on top of that is noise rather than a surprise.

	These are the ONLY timing numbers in the system. Everything else about when
	an event happens falls out of them, the per-event windows, and a uniform roll
	— which is what makes the answer to "when is the next one" genuinely nobody's
	to know, the server included, until it rolls.
]]
EventConfig.FirstDelayMin = 150
EventConfig.FirstDelayMax = 330
EventConfig.GapMin = 120
EventConfig.GapMax = 360

--[[ Nothing starts inside the last stretch of a round. The finale is the hardest
     part of the mode already; an event landing at 16:30 either does nothing
     worth noticing or decides the round, and neither is good. ]]
EventConfig.NoStartAfter = 900

--[[
	Back-to-back heavy events are blocked even when the dice allow them.

	Two 0.8-intensity events in a row is a difficulty spike that no configuration
	asked for and that reads, correctly, as the game piling on. If the last event
	was at or above this, the next roll drops everything at or above it from the
	pool — once. The weather is always still there to be chosen.
]]
EventConfig.HeavyIntensity = 0.6

--[[
	Where a map keeps the things events need.

	Names, not references. A designer makes a folder, drops parts in it, and the
	event finds them — the same contract the medkits, the ammo crates, the vault
	props and the barricades all use, matched through MapConfig.folderMatches so
	case, spacing, punctuation and a trailing plural are all folded away.

	    Clinton
	      Events
	        Lights            every light a blackout may take
	        EmergencyLights   the few that come ON when it does
	        SupplyDrops       parts marking where a drop can land

	A map with no Events folder is not broken. It just never sees the events that
	need one — see each module's `supported`. That is the point of the split: the
	global system is the same everywhere and the map says what it can host.
]]
EventConfig.MapFolders = table.freeze({
	Root = "Events",
	Lights = "Lights",
	EmergencyLights = "EmergencyLights",
	SupplyDrops = "SupplyDrops",
})

--[[ Ids. A table rather than bare strings for the same reason Enums exists: a
     typo in a conflicts list should be a nil index at load, not an event that
     quietly never conflicts with anything. ]]
EventConfig.Id = table.freeze({
	HeavyRain = "HeavyRain",
	DenseFog = "DenseFog",
	Blackout = "Blackout",
	Thunderstorm = "Thunderstorm",
	PowerFailure = "PowerFailure",
	ZombieSurge = "ZombieSurge",
	SupplyDrop = "SupplyDrop",
	EmergencyBroadcast = "EmergencyBroadcast",
})

local ID = EventConfig.Id

local DEFINITIONS: { EventDefinition } = {
	--[[ The common one, and the one that is nearly all texture. Rain is what
	     makes the other events feel like weather rather than like scripting. ]]
	table.freeze({
		id = ID.HeavyRain,
		displayName = "HEAVY RAIN",
		announcement = "WEATHER WARNING: HEAVY RAIN",
		weight = 20,
		duration = 120,
		cooldown = 300,
		minTime = 60,
		maxTime = 900,
		minWave = 1,
		maxWave = 99,
		repeatable = true,
		--[[ Not the thunderstorm, which is rain with the volume up: both at once
		     is one storm described twice. ]]
		conflicts = { ID.Thunderstorm },
		intensity = 0.2,
	}),
	table.freeze({
		id = ID.DenseFog,
		displayName = "DENSE FOG",
		announcement = "VISIBILITY DROPPING — FOG ROLLING IN",
		weight = 15,
		duration = 105,
		cooldown = 300,
		--[[ Not before wave 2. Fog is the one event that takes information away
		     rather than adding pressure, and taking sight lines off a team that
		     has not found its second gun yet is the version of this that is not
		     fair. ]]
		minTime = 120,
		maxTime = 900,
		minWave = 2,
		maxWave = 99,
		repeatable = true,
		conflicts = {},
		intensity = 0.35,
	}),
	table.freeze({
		id = ID.Blackout,
		displayName = "BLACKOUT",
		announcement = "WARNING: POWER FAILURE — LIGHTS OUT",
		weight = 10,
		duration = 90,
		cooldown = 420,
		minTime = 180,
		maxTime = 900,
		minWave = 3,
		maxWave = 99,
		repeatable = true,
		conflicts = { ID.PowerFailure },
		intensity = 0.5,
	}),
	table.freeze({
		id = ID.Thunderstorm,
		displayName = "THUNDERSTORM",
		announcement = "SEVERE WEATHER WARNING: ELECTRICAL STORM",
		weight = 12,
		duration = 135,
		cooldown = 420,
		minTime = 180,
		maxTime = 880,
		minWave = 3,
		maxWave = 99,
		repeatable = true,
		conflicts = { ID.HeavyRain },
		intensity = 0.35,
	}),
	--[[ The blackout's louder sibling: the lights go out in stages, the emergency
	     set comes on, and it takes longer to come back. Rarer for the same
	     reason it is longer. ]]
	table.freeze({
		id = ID.PowerFailure,
		displayName = "POWER FAILURE",
		announcement = "GRID FAILURE — EMERGENCY LIGHTING ONLY",
		weight = 8,
		duration = 120,
		cooldown = 480,
		minTime = 300,
		maxTime = 880,
		minWave = 4,
		maxWave = 99,
		repeatable = true,
		conflicts = { ID.Blackout },
		intensity = 0.55,
	}),
	--[[ The one that is genuinely harder rather than darker. Weighted low and
	     gated late, and the director's heavy guard keeps it away from the other
	     aggressive ones. ]]
	table.freeze({
		id = ID.ZombieSurge,
		displayName = "ZOMBIE SURGE",
		announcement = "WARNING: LARGE GROUP INBOUND",
		weight = 12,
		duration = 60,
		cooldown = 420,
		minTime = 240,
		maxTime = 860,
		minWave = 3,
		maxWave = 99,
		repeatable = true,
		conflicts = {},
		intensity = 0.85,
	}),
	table.freeze({
		id = ID.SupplyDrop,
		displayName = "SUPPLY DROP",
		announcement = "SUPPLY DROP DETECTED — GRID REFERENCE INCOMING",
		weight = 8,
		--[[ Long, because the whole event is a decision about whether to go and
		     get it. A drop that expires before a pinned team can move is a
		     punishment dressed as a reward. ]]
		duration = 150,
		cooldown = 420,
		minTime = 180,
		maxTime = 840,
		minWave = 2,
		maxWave = 99,
		repeatable = true,
		conflicts = {},
		intensity = 0.1,
	}),
	--[[ Once a round, and it is the only one that does nothing at all. It is here
	     because a world that occasionally talks to you is a world, and because
	     the first time it happens nobody knows it is harmless. ]]
	table.freeze({
		id = ID.EmergencyBroadcast,
		displayName = "EMERGENCY BROADCAST",
		announcement = "INCOMING RADIO TRANSMISSION",
		weight = 15,
		duration = 30,
		cooldown = 0,
		minTime = 90,
		maxTime = 900,
		minWave = 1,
		maxWave = 99,
		repeatable = false,
		conflicts = {},
		intensity = 0,
	}),
}

EventConfig.Definitions = table.freeze(DEFINITIONS) :: { EventDefinition }

local BY_ID: { [string]: EventDefinition } = {}
for _, entry in DEFINITIONS do
	BY_ID[entry.id] = entry
end

function EventConfig.get(id: any): EventDefinition?
	return if typeof(id) == "string" then BY_ID[id] else nil
end

--[[ Whether two events may be up at once. Asked in both directions so a
     one-sided conflicts list still works — a definition that names the other
     one is enough, and neither has to remember to name it back. ]]
function EventConfig.conflict(a: EventDefinition, b: EventDefinition): boolean
	for _, id in a.conflicts do
		if id == b.id then
			return true
		end
	end
	for _, id in b.conflicts do
		if id == a.id then
			return true
		end
	end
	return false
end

--[[
	The lines the emergency broadcast can play, and nothing reads them but that
	event.

	Deliberately unresolved. None of these answers anything, because the moment
	one of them does the event becomes a hint system and every player who hears a
	different line feels they got the wrong one. They are a world talking past
	you, which is the only thing a radio in an empty city can honestly be.
]]
EventConfig.Broadcasts = table.freeze({
	table.freeze({
		speaker = "RADIO",
		lines = table.freeze({
			"Attention. Anyone still receiving this transmission.",
			"Evacuation corridors are no longer being maintained.",
			"Do not wait for transport. There is no transport.",
		}),
	}),
	table.freeze({
		speaker = "RADIO",
		lines = table.freeze({
			"...repeating. The relief point at the Fried Chicken is not staffed.",
			"Anyone holding there should not expect a resupply.",
			"We are sorry. Good luck.",
		}),
	}),
	table.freeze({
		speaker = "RADIO",
		lines = table.freeze({
			"If you are hearing this, you are further out than we thought.",
			"Stay off the main roads after dark. They move differently at night.",
			"...that is all we know. That is all anyone knows.",
		}),
	}),
	table.freeze({
		speaker = "RADIO",
		lines = table.freeze({
			"Day forty-one. Still broadcasting on the emergency band.",
			"Nobody has answered in eleven days.",
			"I will keep the transmitter running as long as the generator holds.",
		}),
	}),
})

--[[ Enums is required for the round-state comparison the director makes, and
     naming it here keeps that comparison spelled the same way in both files. ]]
EventConfig.RunningState = Enums.RoundState.InProgress

return table.freeze(EventConfig)
