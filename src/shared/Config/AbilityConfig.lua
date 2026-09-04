--!strict
--[[
	AbilityConfig — the permanent unlocks, and every number the five of them read.

	── WHAT AN ABILITY IS, AND WHAT IT IS NOT ──────────────────────────────────
	This game now has three things that change a round, and they are deliberately
	not the same thing. Keeping them apart is the whole reason this file exists
	separately from the other two:

	  ABILITY      bought once with Dollars, owned forever, equipped BEFORE a
	               match, and actively pressed during one. It is a verb the
	               player performs. This file.
	  REQUISITION  bought with Scrip DURING a match, at a breather, applies to
	               the whole team for the rest of that round, and then is gone.
	               Shared/Config/RequisitionConfig.
	  MODIFIER     not bought at all. One rule rolled at the top of a round that
	               changes what the round IS.
	               Shared/Config/ModifierConfig.

	A player can be under FAST ZOMBIES (modifier), holding INCENDIARY ROUNDS the
	team bought at wave 4 (requisition), and pressing TURRET (ability) in the
	same second. None of the three knows the others exist.

	── AND WHY ABILITIES ARE PAID FOR IN DOLLARS ───────────────────────────────
	Because they are permanent unlocks, and Dollars is what this game already
	charges for permanent unlocks — the whole weapon roster. Scrip buys things
	that are spent (the pass track, a round's requisitions); Dollars buys things
	you keep. Putting abilities on the other currency would have made the two
	mean nothing in particular.

	They are priced WELL under the guns on purpose. The cheapest weapon is $900
	and the roster is $157,000; the whole ability set is $6,500. An ability
	changes how you play and a rifle changes what you can kill, and a player
	should be able to reach the first one early enough that it shapes how they
	learn the game.

	── ADDING ONE ─────────────────────────────────────────────────────────────
	A definition here, a module under server/Abilities/Abilities named for its
	id, and an Enums.Ability entry. Nothing else: the shop, the loadout screen,
	the HUD, the cooldown clock and the input dispatch are all driven off this
	table. `tuning` is deliberately an opaque table — the service never reads
	inside it, only the ability's own module does — so a new ability's numbers
	cannot require a change to anything that is not that ability.
]]

local Attributes = require(script.Parent.Parent.Net.Attributes)
local Enums = require(script.Parent.Parent.Enums)

local PA = Attributes.Player

export type Ability = {
	id: string,
	displayName: string,
	blurb: string, -- one line, what it DOES; read on a shop row
	price: number, -- Dollars
	--[[ Seconds, and the server owns the clock.

	     Five minutes for all five, which against a 1020-second round is three or
	     four uses of one ability in a whole match. That is the point: at
	     thirty seconds a Shield was something you pressed whenever it was lit,
	     and the interesting question about an ability is not whether to use it
	     but WHEN. A number this long makes every activation a decision the
	     player will remember making, and makes bringing two of them a real
	     choice rather than a formality.

	     It is per-ability rather than one shared constant so the spread can come
	     back if it turns out an Airstrike and a Field Medic do not want the same
	     clock. Today they all do. ]]
	cooldown: number,
	--[[ Whether activating it needs a point on the ground. The two that do put
	     the client into a targeting mode first; the three that do not fire on
	     the keypress. The SERVER re-validates the point either way. ]]
	targeted: boolean,
	--[[ How far from the player a target may be. Meaningless for an untargeted
	     ability, and the server clamps to it rather than refusing — a player who
	     aimed slightly too far gets the edge of their range, not nothing. ]]
	range: number,
	--[[ The Assets/Abilities model to draw as a ghost while choosing a spot, or
	     nil to show only the reticle. Deployables have one; a cryo field and an
	     airstrike are marks on the floor and do not. ]]
	preview: string?,
	-- Read only by this ability's own module. See ADDING ONE.
	tuning: { [string]: any },
}

local AbilityConfig = {}

--[[
	How many abilities a player may take into a match.

	Two, and it is here rather than spelled out anywhere else: the loadout, the
	HUD, the input dispatch and the server's slot validation all read this. The
	one place that cannot be fully derived from it is the keymap, which needs a
	physical key per slot — InputController holds a list of them and binds
	`math.min(MaxSlots, #keys)`, so raising this is a one-line change there and
	nothing at all anywhere else.
]]
--[[ The CollectionService tag a deployed turret carries. Here rather than in
     either half, because the server adds it and the client watches for it, and a
     tag spelled two ways is a health bar that never appears with nothing in any
     log to say why. ]]
AbilityConfig.TurretTag = "FL_Turret"

AbilityConfig.MaxSlots = 2

--[[ The ceiling the attribute names go up to. Raising MaxSlots past this needs
     new Attributes.Player rows, which is the one thing that cannot be generated
     — an attribute name is a literal string on both sides of the wire. ]]
AbilityConfig.SlotCeiling = 4

local DEFINITIONS: { Ability } = {
	table.freeze({
		id = Enums.Ability.Shield,
		displayName = "SHIELD",
		blurb = "A bubble that eats damage for you. Not for long.",
		price = 500,
		cooldown = 300,
		targeted = false,
		range = 0,
		tuning = table.freeze({
			Duration = 6.0,
			--[[ How much damage it swallows before it pops. 120 against a
			     survivor's 100 health is deliberately more than one life: the
			     shield is for the ten seconds you spend being wrong, not for a
			     fight you were always going to win. It ends on whichever comes
			     first, the damage or the clock. ]]
			DamageAbsorption = 120,
			Radius = 6.5,
		}),
	}),
	table.freeze({
		id = Enums.Ability.Turret,
		displayName = "TURRET",
		blurb = "Drops a gun that watches an angle you cannot.",
		price = 1_000,
		cooldown = 300,
		--[[ Targeted, so it is PLACED rather than dropped at your feet. Where a
		     turret stands is the whole skill of the ability — an angle it can see
		     and the horde cannot reach — and an ability that put it in front of
		     you took that decision away.

		     A short range on purpose. This is "just there", not "across the
		     street": a turret you can post somewhere you are not is a turret
		     covering a flank you never have to walk to. ]]
		targeted = true,
		range = 45,
		--[[ The model to show as a placement ghost, under
		     ReplicatedStorage/Assets/Abilities. Nil for the abilities whose
		     target is a patch of ground rather than an object. ]]
		preview = "Turret",
		tuning = table.freeze({
			--[[ 14 a shot at 3 a second is 42 a second, which kills a Common in
			     just over a second and does nothing meaningful to a Tank. That
			     is the intent: a turret holds a corridor against the horde and
			     is never the answer to a boss. ]]
			Damage = 14,
			FireRate = 3.0,
			Range = 70,
			Health = 250,
			--[[
				Seventy-five seconds, up from thirty.

				Thirty was sized for a thing you dropped and walked away from: long
				enough to cover one push, and the clock rather than the horde was
				usually what ended it. Manning it changed what the number is for.
				A gun you SIT IN is a position you commit to, and committing to one
				for half a minute — on a five-minute cooldown — was a worse deal
				than not using the ability at all.

				Seventy-five spans a wave and the breather after it, which is the
				unit a defensive position is actually worth measuring in. It is
				still a quarter of the cooldown, so a turret is a thing a team has
				sometimes rather than a thing they have.

				Its health did NOT go up with it. Placement is the skill, and a
				turret in a bad spot should still be taken apart in seconds — the
				extra time is for the one somebody put somewhere sensible.
			]]
			Lifetime = 75,
			--[[ Per player, not per server. Two players who both took Turret
			     should get two turrets; one player should not get four by
			     waiting out a cooldown twice. ]]
			MaximumActiveTurrets = 1,

			--[[
				MANNED. Sit in it and you pick the targets.

				The same damage per shot, deliberately. Manning it is already
				worth doing — the automatic gun shoots the nearest thing it can
				see, and a player shoots the Smoker on the roof, the Tank, or the
				body about to reach a downed teammate — and pricing that in
				damage as well would make sitting in it the only correct play.
				What you get is CADENCE: a person on the trigger runs it half as
				fast again, which is the difference between holding a corridor
				and holding a corridor confidently.

				The cost is the whole point of the trade: you are stationary, you
				cannot use your own weapon, and everything in the map knows
				exactly where you are.
			]]
			ManualFireRate = 4.5,

			--[[
				How close a body has to be before it turns on the turret, and how
				many of them one turret can pull off the survivors at once.

				A cap, because a turret that diverted an entire horde would be a
				better crowd-control tool than any of the ones designed to be one,
				and because a wave that walks past four survivors to punch a box is
				a wave that stopped being a threat. Five bodies is enough that a
				badly-placed turret dies in seconds and a well-placed one buys the
				team a corridor's worth of breathing room.

				A body that has already committed keeps its place regardless — the
				cap only refuses NEW diversions — so nothing lets go of a turret it
				is standing on top of. See Turret.nearest for how that is counted,
				and for why counting bodies near the turret instead cannot work.
			]]
			AggroRadius = 22,
			MaxAttackers = 5,

			--[[
				What a swing takes out of it, as a multiple of what that body
				would take out of a person.

				A separate number from the barricade scale, which is 3 against
				wood measured in hundreds of hit points. Set so five Commons take
				a turret apart in about four and a half seconds — 4 damage on a
				0.9s cooldown is 4.4 a second each, times five, times this —
				which is the number the old proximity damage was tuned to and the
				one the ability was balanced around.

				It also means a Tank ends a turret in three seconds, which is
				correct: a turret is never the answer to a boss and standing
				behind one while a Tank walks up should not feel like it is.
			]]
			AttackDamageScale = 2.5,
		}),
	}),
	table.freeze({
		id = Enums.Ability.FieldMedic,
		displayName = "FIELD MEDIC",
		blurb = "Patches up everyone standing near you, including you.",
		price = 1_000,
		cooldown = 300,
		targeted = false,
		range = 0,
		tuning = table.freeze({
			--[[ 35 is a third of a health bar, and it is PERMANENT health rather
			     than the draining kind pills give. That is what stops this being
			     a worse medkit: a medkit heals one person for most of a bar and
			     costs a slot and five seconds standing still, and this heals
			     four people for a third of one, instantly, from cover. ]]
			HealAmount = 35,
			Radius = 26,
		}),
	}),
	table.freeze({
		id = Enums.Ability.CryoBlast,
		displayName = "CRYO BLAST",
		blurb = "Freezes a doorway solid. Buys the seconds you needed.",
		price = 2_000,
		cooldown = 300,
		targeted = true,
		range = 90,
		tuning = table.freeze({
			Radius = 22,
			--[[ 0.82 leaves a Common at about 4 studs a second — crawling, still
			     coming, still shootable. Not zero: an enemy frozen in place
			     stops being frightening and starts being scenery, and the point
			     of this is that the horde is still arriving, slowly. ]]
			SlowPercent = 0.82,
			Duration = 7.0,
			--[[ A Tank keeps most of its legs. The counter to a Tank is running,
			     and an ability that simply switched one off would replace that
			     with a button. It still slows — being able to buy four seconds
			     against a Tank is worth a slot — it just does not stop one. ]]
			BossResistance = 0.65,
		}),
	}),
	table.freeze({
		id = Enums.Ability.Airstrike,
		displayName = "AIRSTRIKE",
		blurb = "Marks a spot. Everything standing on it stops standing.",
		price = 3_000,
		cooldown = 300,
		targeted = true,
		range = 140,
		tuning = table.freeze({
			Damage = 260,
			Radius = 16,
			NumberOfExplosions = 5,
			--[[ Two and a half seconds of a marker on the ground before the
			     first one lands. That window is the entire balance of this
			     ability: it is long enough that a Tank walks out of it, which is
			     why the answer to a Tank is still a Tank's answer, and long
			     enough that a team standing in it has been warned. ]]
			WarningTime = 2.5,
			SpreadTime = 1.1, -- the explosions walk across the area, not at once

			--[[
				── THE FLYOVER ──────────────────────────────────────────────────
				Meshes, and the geometry of the run that drops the shells. All of
				it is COSMETIC: the jet is drawn on each client from the marker
				broadcast, it has no collision, no Humanoid and no explosion of
				its own, and the damage is the server's shells either way. A
				player who never sees the jet takes and deals exactly the same
				damage as one who does.

				The meshes are Roblox catalogue assets. If one fails to load the
				jet falls back to a plain wedge — the flyover still happens,
				because the flyover is the tell that the shells are coming and
				losing it to a missing mesh would cost the player information.
			]]
			JetMeshId = "rbxassetid://88775328",
			JetTextureId = "rbxassetid://88775716",
			BombMeshId = "rbxassetid://88782666",
			BombTextureId = "rbxassetid://88782631",
			--[[ How high it passes and how far out it starts. 200 studs up is
			     above every map's roofline, so the run is never interrupted by
			     the building the strike is called on. ]]
			JetHeight = 200,
			JetRunway = 900,
			--[[ How long the plane takes to cross its whole run. Everything else
			     about the flyover is derived from this, from JetHeight and from
			     WarningTime — when the plane launches, where the bombs leave it,
			     how long they fall — so none of it has to be re-tuned when the
			     warning changes. See AbilityEffects.flyover. ]]
			JetCrossSeconds = 3.4,
		}),
	}),
}

AbilityConfig.Definitions = table.freeze(DEFINITIONS) :: { Ability }

local BY_ID: { [string]: Ability } = {}
for _, entry in DEFINITIONS do
	BY_ID[entry.id] = entry
end

--[[ Looks one up, nil for an unknown id. Ids arrive from remotes and from
     stored profiles, so an unknown one must be a plain nil. ]]
function AbilityConfig.get(id: any): Ability?
	if typeof(id) ~= "string" or id == "" then
		return nil
	end
	return BY_ID[id]
end

--[[ The two attribute names for a slot, or nil for a slot outside the ceiling.
     Generated from the index so the HUD, the service and the client mirror
     cannot disagree about which attribute a slot writes. ]]
function AbilityConfig.attributesFor(slot: number): (string?, string?)
	if typeof(slot) ~= "number" or slot ~= slot then
		return nil, nil
	end
	local index = math.floor(slot)
	if index < 1 or index > AbilityConfig.SlotCeiling then
		return nil, nil
	end
	return (PA :: any)["Ability" .. index .. "Id"], (PA :: any)["Ability" .. index .. "ReadyAt"]
end

--[[ Whether a slot number is one this game actually has. The single test every
     path uses — the remote handler, the loadout setter and the HUD — so a slot
     that is legal in one is legal in all of them. ]]
function AbilityConfig.isSlot(slot: any): boolean
	return typeof(slot) == "number"
		and slot == slot
		and slot >= 1
		and slot <= AbilityConfig.MaxSlots
		and math.floor(slot) == slot
end

--[[ A stored or received slot list, made safe: the right length, every entry a
     real ability id or "", and no ability equipped in two slots at once.
     `owned` filters it when supplied — a profile that lost an ability should
     not keep it equipped, and a client asking for one it does not own is the
     thing this exists to refuse. ]]
function AbilityConfig.sanitiseSlots(slots: any, owned: { [string]: boolean }?): { string }
	local result: { string } = {}
	local seen: { [string]: boolean } = {}
	for index = 1, AbilityConfig.MaxSlots do
		local id = if typeof(slots) == "table" then slots[index] else nil
		local entry = AbilityConfig.get(id)
		local ok = entry ~= nil and not seen[id]
		if ok and owned and not owned[id] then
			ok = false
		end
		if ok then
			seen[id] = true
			result[index] = id
		else
			result[index] = ""
		end
	end
	return result
end

--[[ Every ability a fresh profile has. Empty: nothing is free, and the first
     one costing $500 is what makes it a decision rather than a default. ]]
function AbilityConfig.defaultOwned(): { [string]: boolean }
	return {}
end

return AbilityConfig
