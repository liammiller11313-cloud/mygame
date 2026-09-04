--!strict
--[[
	RequisitionConfig — what a team can buy into a round, and what it costs.

	── THE PROBLEM IT SOLVES ───────────────────────────────────────────────────
	Fifteen waves escalate. The team does not. From wave 1 to the Apex Tank the
	survivors' power curve is flat — the only in-round progression is finding a
	better gun on the floor — so the round is a single difficulty ramp that the
	player can only answer with skill. That is a fine game and it is missing a
	dimension: nothing the player DECIDES makes wave 12 different from the last
	time they played wave 12.

	── WHY THESE FIVE AND NOT STAT UPGRADES ────────────────────────────────────
	The obvious version of this is a stat shop: damage, health, movement speed,
	crit chance. Every one of those is load-bearing here and would quietly
	dismantle something:

	  * DAMAGE does nothing, and then breaks everything. A Common is 50 health
	    and an M4A1 round is 28, so it dies in two. +50% damage is still two.
	    The number is invisible on the body you shoot forty times a minute right
	    up until a big enough stack flips the breakpoint and the horde stops
	    existing. There is almost no useful range in between.
	  * MOVEMENT SPEED deletes the Tank. Survivor SprintSpeed is 26 and a Tank's
	    runSpeed is 24 — a two-stud margin, and that margin IS the Tank. It is
	    the reason the Apex was given health and reach and deliberately no speed.
	  * MAX HEALTH is the denominator of the whole survival system: HurtThreshold
	    40, PillHealth 50, "medkit heals 80% of what is missing", IncapHealth
	    300. Rescaling it rescales all of them at once.
	  * CRIT CHANCE is the RNG version of the thing this game asks you to earn
	    with your crosshair. `headshotAlwaysKills` is the skill expression;
	    selling a dice roll that does the same job devalues it.

	So none of them are here. What is here is HORIZONTAL: things that change how
	a round is played rather than how big its numbers are. Not one of these
	moves a breakpoint, a relative speed, or a health denominator.

	── ONE PAYS, EVERYBODY GETS IT ─────────────────────────────────────────────
	Requisitions are bought with Scrip — the progression currency, earned from
	levels and daily orders, the same one the battle pass wants — and they apply
	to the WHOLE TEAM for the rest of the round. That is the point rather than a
	convenience: it makes spending a personal, slowly-earned currency an act of
	generosity toward three other people, and it means a team of four can pool
	five requisitions across a round where one player alone could not.

	It also gives Scrip a second sink. A currency with exactly one thing to buy
	stops being interesting the moment you have bought it.

	── AND EACH IS BOUGHT ONCE ─────────────────────────────────────────────────
	No stacking, no levels, no scaling costs. Five switches, on or off, for the
	round. That caps the total power swing at something that can be reasoned
	about — and it is what turns the team's curve from flat into a staircase
	that rises alongside the Director's, paid for in a currency that took real
	time to earn.
]]

local Attributes = require(script.Parent.Parent.Net.Attributes)

local GA = Attributes.Game

export type Requisition = {
	id: string,
	displayName: string,
	blurb: string, -- one line, what it DOES; read under a breather clock
	cost: number, -- Scrip
	--[[ The Workspace attribute this sets. Every requisition has one even when
	     nothing reads it, because "has this been bought" is a question the panel
	     asks about all five. ]]
	attribute: string,
	order: number,
}

local RequisitionConfig = {}

--[[ How much a drilled reload takes off, and how much surplus adds to a
     reserve. Both are read in two places — the server's authoritative timer and
     the client's prediction for the reload, the pickup cap and the crate for
     the reserve — so they live here rather than in either of them. ]]
RequisitionConfig.DrillReloadScale = 0.75
RequisitionConfig.SurplusReserveScale = 1.5

--[[
	Bosses do not catch fire from a bullet.

	A Tank's burnDamagePerSecond is 150 against every other body's 25-45, because
	fire IS the intended answer to a Tank — that is the molotov's job and the
	reason a molotov is worth carrying. Incendiary ROUNDS keeping a Tank
	permanently alight for the price of shooting it would do 150 a second for
	free, which is 80 seconds of the Apex's 144-second wave and the finale
	solving itself. A tracer lights a body; it is not a bottle of petrol.
]]
RequisitionConfig.IncendiarySkipsBosses = true

--[[
	── WHAT THE SET COSTS ──────────────────────────────────────────────────────
	All five is 325 Scrip. The battle pass is 3,080, so a fully kitted round is
	about a tenth of the whole track — and three daily orders pay roughly 160, so
	the set is two days of orders and any single one is a fraction of a day.

	That is the intended weight. One requisition should be an easy yes on a round
	that matters; five should be a thing a team pooled for, and should cost
	somebody visible progress toward the pass. A price nobody feels is a decision
	nobody makes.
]]
local CATALOGUE: { Requisition } = {
	table.freeze({
		id = "Airdrop",
		displayName = "AIRDROP",
		blurb = "Restocks every ammo box and medkit on the map, right now.",
		cost = 40,
		--[[ Nothing reads this one — the airdrop happens at the moment of
		     purchase and leaves no state. It is set so the panel can grey the
		     row out. See Attributes.Game.ReqAirdrop. ]]
		attribute = GA.ReqAirdrop,
		order = 1,
	}),
	table.freeze({
		id = "Drill",
		displayName = "FIELD DRILL",
		blurb = "Everyone reloads a quarter faster for the rest of the round.",
		cost = 60,
		attribute = GA.ReqDrill,
		order = 2,
	}),
	table.freeze({
		id = "Surplus",
		displayName = "AMMO SURPLUS",
		blurb = "Half again the reserve you can carry, and a full top-up now.",
		cost = 60,
		attribute = GA.ReqSurplus,
		order = 3,
	}),
	table.freeze({
		id = "Spotter",
		displayName = "SPOTTER",
		blurb = "Specials and bosses outlined through walls, for everyone.",
		cost = 75,
		attribute = GA.ReqSpotter,
		order = 4,
	}),
	table.freeze({
		id = "Incendiary",
		displayName = "INCENDIARY ROUNDS",
		blurb = "Your bullets set the horde alight. Bosses are too big to light.",
		cost = 90,
		attribute = GA.ReqIncendiary,
		order = 5,
	}),
}

RequisitionConfig.Catalogue = table.freeze(CATALOGUE) :: { Requisition }

local BY_ID: { [string]: Requisition } = {}
for _, entry in CATALOGUE do
	BY_ID[entry.id] = entry
end
RequisitionConfig.ById = table.freeze(BY_ID) :: { [string]: Requisition }

--[[ Looks one up, nil for an unknown id. Ids arrive from a remote, so an
     unknown one must be a plain nil rather than an error. ]]
function RequisitionConfig.get(id: any): Requisition?
	if typeof(id) ~= "string" then
		return nil
	end
	return BY_ID[id]
end

--[[
	Whether a requisition is live right now, from the one place both sides read.

	Deliberately takes Workspace as an argument rather than reaching for the
	service: this module is required by the client and the server and by a config
	that must stay side-agnostic, and `workspace` inside a shared module is the
	kind of thing that works until something requires it from a context that does
	not have one.
]]
function RequisitionConfig.isActive(root: Instance, id: string): boolean
	local entry = BY_ID[id]
	if not entry then
		return false
	end
	return root:GetAttribute(entry.attribute) == true
end

--[[ The reload multiplier in force, for whoever is timing a reload. One
     function so the server's authoritative clock and the client's prediction
     can never disagree about what a drilled reload costs. ]]
function RequisitionConfig.reloadScale(root: Instance): number
	if RequisitionConfig.isActive(root, "Drill") then
		return RequisitionConfig.DrillReloadScale
	end
	return 1
end

--[[ How much reserve ammunition a weapon may hold. Passed the definition's own
     ceiling; -1 stays -1, because "infinite" does not get half again. ]]
function RequisitionConfig.reserveCap(root: Instance, reserveMax: number): number
	if reserveMax < 0 then
		return reserveMax
	end
	if RequisitionConfig.isActive(root, "Surplus") then
		return math.floor(reserveMax * RequisitionConfig.SurplusReserveScale + 0.5)
	end
	return reserveMax
end

--[[ Every attribute a round has to clear, so the reset has one source and
     cannot fall behind the catalogue. ]]
function RequisitionConfig.attributes(): { string }
	local names: { string } = {}
	for _, entry in CATALOGUE do
		table.insert(names, entry.attribute)
	end
	return names
end

return RequisitionConfig
