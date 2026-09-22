--!strict
--[[
	EnchantConfig — what a boss leaves behind.

	Kill a boss, it drops a book, you walk over it and it goes onto the weapon in
	your hands. That weapon then does something it could not do before, for the
	rest of the round.

	── WHY THIS IS ROUND-SCOPED, AND WHY THAT IS THE POINT ─────────────────────
	Nothing here is saved, sold or carried between matches. That is not a
	limitation waiting to be lifted — it is what makes the system safe to add to
	a game that already has a shop, a battle pass, a gamepass, redemption codes
	and a persistent profile.

	A permanent enchantment would have to answer all of those: is it buyable, does
	the pass grant it, does a code, what happens to a saved loadout that names one
	the player no longer owns, and what does it do to a weapon economy whose
	pacing is checked by a script on every commit. A round-scoped one answers none
	of them, because it never touches a profile. It is the same scope
	ModifierConfig already uses for the round's own modifier, and for the same
	reason.

	It is also better design. The drop is worth something BECAUSE it is
	temporary: a team that gets Ember on wave 5 plays the next ten waves
	differently, and next round they get something else and play differently
	again. A permanent one is a grind with a number on the end.

	── WHY EVERY EFFECT HERE IS SOMETHING THE GAME ALREADY DOES ────────────────
	Not one of the four introduces a new mechanic. Ember calls the same ignite a
	molotov does, Frostbite the same chill CryoBlast does, Leech the same heal a
	medkit does, and Savage moves a number that DamageService already multiplies
	four other things into. That is deliberate: each of those is already tuned,
	already networked, already visible to the player, and already understood by
	whoever has played a round. An enchantment that did something genuinely new
	would need its own art, its own feedback and its own balance pass, and would
	be the fifth system in the game that can kill a Tank.

	── THE BALANCE TRAP, WRITTEN DOWN SO IT IS NOT WALKED INTO AGAIN ───────────
	Fire is the Tank's designed weakness. Its burnDamagePerSecond is 150 against
	every ordinary body's 25-45, because a molotov is meant to be the answer to a
	Tank — see InfectedConfig, and see RequisitionConfig.IncendiarySkipsBosses,
	which is the same trap caught once already for the incendiary-rounds purchase.

	`ignite` reads the rate off the TARGET, so an Ember sword swung at a Tank
	would deliver a molotov's full 150 a second for the price of a swing, over and
	over, with no throw and no cooldown. That is not a strong enchantment, it is
	the boss fight deleted — and it would also undo the Metallic, which exists
	specifically to take the molotov away from a team that opens every boss with
	one.

	So Ember does not light bosses, exactly as incendiary rounds do not, and
	Frostbite is the anti-boss enchantment instead: it slows, which has no damage
	term at all and therefore no exploit, and it already has a boss-resistance
	number from CryoBlast to inherit.

	── FOUR, NOT TWELVE ────────────────────────────────────────────────────────
	One per thing a weapon can be made to do: burn, slow, feed you, or simply hit
	harder. A longer list is easy to write and hard to tell apart — twelve
	enchantments where four are variations on "+damage" is a drop table that
	mostly reads as "you got a number".
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Enums = require(Shared.Enums)

local EnchantConfig = {}

export type Enchant = {
	id: string,
	displayName: string,
	blurb: string,
	--[[ The colour the HUD tile, the book and the toast all take. One value, so
	     the thing on the floor and the tile it ends up on are recognisably the
	     same thing. ]]
	color: Color3,

	--[[ A blind multiplier on every point of damage this weapon deals. Applied
	     inside DamageService's funnel, after the hit region and the falloff and
	     before the target's resistance, so it scales what the weapon actually
	     achieved rather than what it claimed. ]]
	damageScale: number,

	-- Sets what it hits alight, through InfectedService:ignite.
	ignites: boolean?,
	--[[ Whether the ignition skips bosses. See the balance trap in the header:
	     for Ember this is true and it is not a tuning value. ]]
	igniteSkipsBosses: boolean?,

	--[[ The speed the target keeps, as a fraction, and for how long. 0.45 is a
	     Common at a little under half pace. Delivered through InfectedBrain:chill,
	     the same call CryoBlast makes. ]]
	chillScale: number?,
	chillSeconds: number?,
	--[[ How much of the slow a boss shrugs off, 0-1. CryoBlast's own is 0.65 and
	     this matches it: a Tank you can still outrun and cannot ignore. ]]
	chillBossResistance: number?,

	--[[ A share of the damage DEALT, returned to the attacker as health. Dealt
	     rather than rolled: a shot into a body with 4 health left heals for 4,
	     not for the rifle's 34, or a horde of nearly-dead Commons would be a
	     medkit. ]]
	siphon: number?,
	--[[ Most a single hit may return, in health. The cap is what stops a rocket
	     into a Tank from being a full heal. ]]
	siphonMaxPerHit: number?,

	--[[ Bodies this weapon kills always come apart. Purely the gore roll — no
	     damage term — so it costs nothing and is the clearest possible read that
	     the weapon in your hands is not the one you bought. ]]
	alwaysGibs: boolean?,
}

local DEFINITIONS: { [string]: Enchant } = {
	--[[
		EMBER — the horde answer.

		A swing or a shot sets the body alight, and a lit body dies on its own
		while you deal with the next one. Against a wave that is enormous: fire
		is area damage delivered one body at a time and paid for by the horde's
		own density.

		Never a boss. See the balance trap in the header — this is the one rule
		in this file that is not a number to be tuned.

		The damage bump is small on purpose. Ember's value is the burn, and a
		large direct bonus on top would make it the strict best pick rather than
		the crowd pick.
	]]
	[Enums.Enchant.Ember] = {
		id = Enums.Enchant.Ember,
		displayName = "EMBER",
		blurb = "What it hits burns. Not bosses.",
		color = Color3.fromRGB(240, 132, 48),
		damageScale = 1.1,
		ignites = true,
		igniteSkipsBosses = true,
	},

	--[[
		FROSTBITE — the boss answer, and the deliberate counterpart to Ember.

		It slows, and a slow has no damage term, which is exactly why it is the
		one enchantment allowed to work on a boss. A Tank at three quarters pace
		is a Tank the team can still kite; a Tank on fire for a molotov's rate
		per swing is no fight at all.

		Its numbers are CryoBlast's, softened. The ability lands 0.82 of a slow
		in a radius on a cooldown; this lands 0.55 on one body per hit with no
		cooldown at all, so the per-hit figure has to be the smaller one or a
		machete would be strictly better than an ability somebody paid 2,600 for.
	]]
	[Enums.Enchant.Frostbite] = {
		id = Enums.Enchant.Frostbite,
		displayName = "FROSTBITE",
		blurb = "What it hits slows. Bosses included.",
		color = Color3.fromRGB(122, 196, 226),
		damageScale = 1.05,
		chillScale = 0.45,
		--[[ Short, and re-applied by the next hit. A long chill off one bullet
		     would mean a rifle locks a lane down permanently; this one lasts
		     about as long as it takes to fire again, so the slow is something
		     you MAINTAIN rather than something you apply and walk away from. ]]
		chillSeconds = 2.2,
		chillBossResistance = 0.65,
	},

	--[[
		LEECH — the one that changes where you stand.

		Every other enchantment makes the fight end sooner. This one makes you
		able to be in it: a share of what you deal comes back as health, so the
		weapon rewards being close and firing constantly, which is the opposite
		of how this game otherwise teaches you to survive.

		That is its whole design. Fading Light's answer to damage is to back off
		and find a medkit; Leech is the one thing in the round that says stay.

		Capped per hit, because uncapped it is a rocket launcher that fully heals
		the person firing it into a Tank. The cap is what keeps the fraction
		meaningful on a rifle and harmless on a blast.
	]]
	[Enums.Enchant.Leech] = {
		id = Enums.Enchant.Leech,
		displayName = "LEECH",
		blurb = "A share of what you deal comes back as health.",
		color = Color3.fromRGB(140, 196, 96),
		damageScale = 1.0,
		--[[
			Six per cent, and the number is small because of SHOTGUNS.

			Every pellet is its own trip through DamageService, so this fraction
			is charged nine times by one shell — a blast that would heal you for
			its total damage heals you for nine separate slices of it, and the
			enchantment that reads as "a trickle" on a rifle reads as a full heal
			per trigger pull on a shotgun. That is the term to watch if this is
			ever retuned: the per-hit cap below is what bounds a single pellet,
			and the pellet COUNT is what multiplies it.

			At six per cent and a cap of four, a rifle round returns about two
			health and a point-blank shell about thirteen. Enough to matter while
			you are shooting and nowhere near enough to replace a medkit, which is
			exactly where this should sit: it changes where you stand, not whether
			you need healing.
		]]
		siphon = 0.06,
		siphonMaxPerHit = 4,
	},

	--[[
		SAVAGE — the honest one.

		No mechanic, just more. It exists because a drop table where every entry
		has a clever rule is a drop table with no baseline, and because the
		simple one is genuinely the right pick for a player who does not want to
		change how they are playing.

		It is the largest damage number here by a distance, and it gibs — which
		costs nothing, since the gore roll already exists, and is the loudest
		possible way to say the weapon is different now.
	]]
	[Enums.Enchant.Savage] = {
		id = Enums.Enchant.Savage,
		displayName = "SAVAGE",
		blurb = "Hits far harder, and takes bodies apart.",
		color = Color3.fromRGB(198, 62, 62),
		damageScale = 1.4,
		alwaysGibs = true,
	},
}

EnchantConfig.Definitions = table.freeze(DEFINITIONS) :: { [string]: Enchant }

--[[
	── WHAT EACH BOSS LEAVES ───────────────────────────────────────────────────
	Boss-specific, because it costs nothing — the death signal already names the
	kind — and because it gives the four boss waves an identity beyond "a big one
	turned up again". A team that wants Frostbite now has a reason to care which
	boss the wave rolled.

	Two each rather than one, so the same boss is not the same drop every round,
	and no boss drops all four, so no single kill is the jackpot.

	  Tank     brute force and fire: it is the boss fire was designed against, so
	           it hands you the fire you are not allowed to use on it.
	  Witch    the quiet one. Leech and Frostbite are both about control, which
	           is what she punishes you for not having.
	  Metallic the boss that takes the molotov away. It pointedly does not drop
	           Ember — see its note in InfectedConfig.
	  Bacteria the boss fire IS the answer to. It gives that back.

	A kind with no row here drops nothing, which is the correct default: a
	Common that somehow reached this table should not hand out a boss reward.
]]
EnchantConfig.DropTable = table.freeze({
	[Enums.Infected.Tank] = table.freeze({ Enums.Enchant.Ember, Enums.Enchant.Savage }),
	[Enums.Infected.Witch] = table.freeze({ Enums.Enchant.Leech, Enums.Enchant.Frostbite }),
	[Enums.Infected.Metallic] = table.freeze({ Enums.Enchant.Frostbite, Enums.Enchant.Savage }),
	[Enums.Infected.BacteriaMonster] = table.freeze({ Enums.Enchant.Ember, Enums.Enchant.Leech }),
})

EnchantConfig.Drop = table.freeze({
	--[[
		ONE BOOK PER WAVE, from the first boss in it that dies.

		Not one per boss. Waves 11 and 15 can release a PACK — up to three Tanks
		on a full team, see GameModeConfig.rollBosses — and a book each would mean
		a round handed out eight of them, which is every weapon on the team
		enchanted twice over by wave 12.

		Per wave, the round's four boss waves (5, 8, 11 and 15) give at most four
		books across about seventeen minutes. That is roughly one per player on a
		full team, and a real decision on a duo.
	]]
	OnePerWave = true,

	--[[ How long the book waits before it gives up and vanishes. Long enough to
	     finish the fight it dropped out of and walk back for it; short enough
	     that it is not still sitting there two waves later, which would let a
	     team bank them and apply four at once. ]]
	Lifetime = 90,

	--[[ How far above the body it appears, and how far it drifts. A book on the
	     floor under a Tank-sized corpse is a book nobody finds. ]]
	Rise = 3.5,
	--[[ The book turns and bobs. Movement is the only thing that separates a
	     small prop from the level's own scenery at a glance. ]]
	SpinSpeed = 45, -- degrees a second
	BobHeight = 0.45,
	BobSpeed = 1.6,
})

--[[ One enchantment, by id. Nil for anything that is not one, which is the
     answer every caller wants: an unknown id is an unenchanted weapon, not an
     error, because the id may have come off an attribute a round ago. ]]
function EnchantConfig.get(id: any): Enchant?
	if typeof(id) ~= "string" or id == "" then
		return nil
	end
	return DEFINITIONS[id]
end

--[[ What this kind of body drops, or nil. Deliberately returns the frozen row
     itself rather than a copy: callers pick one at random out of it and none of
     them may write to it. ]]
function EnchantConfig.dropsFor(kind: any): { string }?
	if typeof(kind) ~= "string" then
		return nil
	end
	return (EnchantConfig.DropTable :: any)[kind]
end

return table.freeze(EnchantConfig)
