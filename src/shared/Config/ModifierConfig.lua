--!strict
--[[
	ModifierConfig — the one condition a round is fought under.

	A round is fifteen waves on a fixed schedule against a roster whose numbers
	do not move. That is a good round and it is the SAME round, and the tenth
	time a player reaches wave 11 they are reaching a wave 11 they have already
	solved. A modifier is the answer to that: one named rule, rolled at the top
	of the round, announced, and true for the whole seventeen minutes.

	── ONE, NOT A STACK ────────────────────────────────────────────────────────
	Exactly one per round. Not because two could not be interesting but because
	two cannot be REASONED about: Fast Zombies and Double Spawn together is a
	round nobody finishes, and a player who loses to a combination they were
	handed learns nothing from it. One rule is a rule you can plan around, and
	planning around it is the entire point.

	── AND ONLY IN CLASSIC ─────────────────────────────────────────────────────
	Versus gets none, and that is a fairness rule rather than an oversight. The
	whole reason that mode works is that both halves face the same fifteen waves
	— see VersusService — and a modifier rolled per half would measure two teams
	against two different games. A per-MATCH roll that survived the swap would be
	the way to have them there, and it is not what this does.

	── WHAT A MODIFIER IS ALLOWED TO TOUCH ─────────────────────────────────────
	Anything about the infected, the light, the supply of ammunition, and how
	much of all of it arrives. Nothing about the SURVIVOR: no modifier moves
	health, speed, damage or reload, because those are the numbers every other
	system is balanced against and because a round that nerfs the player is not a
	condition, it is a punishment. The team's answer to a modifier should be
	playing differently, not being smaller.

	`headshotAlwaysKills` in particular survives everything here, which is why
	ARMORED works: it doubles what a body shot costs and leaves a headshot at
	exactly one round. The modifier that makes the horde tankiest is the one that
	rewards aim hardest.
]]

local Attributes = require(script.Parent.Parent.Net.Attributes)
local Enums = require(script.Parent.Parent.Enums)

export type Modifier = {
	id: string,
	displayName: string,
	blurb: string, -- one line, shown on the prep card and in the HUD

	--[[ Every field below is optional and defaults to "no change". A modifier
	     lists only what it moves, so reading one tells you the whole of what it
	     does — and adding a knob to the type does not silently change six
	     existing modifiers. ]]
	commonSpeedScale: number?, -- multiplier on Common walk and run speed
	commonSprintChance: number?, -- replaces the definition's, 0-1
	commonHealthScale: number?, -- multiplier on Common health
	populationScale: number?, -- multiplier on every wave's horde target
	spawnRateScale: number?, -- multiplier on how fast they arrive
	atmosphereFloor: number?, -- 0-1, how far into nightfall the round STARTS
	eliteBosses: boolean?, -- every boss arrives as an Apex
	blocksRestock: boolean?, -- breathers stop restocking the map
	blocksCrateRespawn: boolean?, -- a spent ammo crate stays spent
	specialWeights: { [string]: number }?, -- multipliers on the Director's pick
	specialCaps: { [string]: number }?, -- multipliers on a kind's maxAlive
}

local ModifierConfig = {}

--[[ The odds a round gets one at all. 1.0 — every Classic round is fought under
     something, because a system that fires four times in five reads as broken
     the fifth time rather than as variety. Turn it down to see the tuned
     baseline more often. ]]
ModifierConfig.Chance = 1.0

local CATALOGUE: { Modifier } = {
	table.freeze({
		id = "Fast",
		displayName = "FAST ZOMBIES",
		blurb = "Every one of them sprints, and they are almost as fast as you.",
		--[[ 21 becomes 25.2 against a survivor's SprintSpeed of 26. Deliberately
		     just under: a horde you cannot outrun at all is a horde you can only
		     answer by killing, which deletes movement as a tool. Under by less
		     than a stud means running still works and costs you every scrap of
		     stamina you have, which is the version worth playing. ]]
		commonSpeedScale = 1.2,
		-- And all of them, rather than three in four.
		commonSprintChance = 1.0,
	}),
	table.freeze({
		id = "Armored",
		displayName = "ARMORED ZOMBIES",
		blurb = "Body shots barely register. Aim higher.",
		--[[ 50 health becomes 110, so an M4A1 round goes from two body shots to
		     four — and a headshot stays at exactly one, because
		     headshotAlwaysKills is above every multiplier in this file. That is
		     the whole modifier: it does not make the horde harder to kill, it
		     makes SPRAYING harder and leaves aiming untouched. ]]
		commonHealthScale = 2.2,
	}),
	table.freeze({
		id = "DoubleSpawn",
		displayName = "DOUBLE SPAWN",
		blurb = "Twice the horde, arriving twice as fast.",
		--[[ Honest about its own ceiling: InfectedConfig caps Commons at 60
		     alive and the Director clamps to that, so the last few waves were
		     already saturated and this cannot make them denser. What it changes
		     is everything before them — wave 3 arrives like wave 12 — and that
		     is a bigger difference than doubling a number that was already
		     hitting the roof. The cap is not raised: the brain's own header
		     budgets for a few dozen bodies at once, and a modifier that quietly
		     doubles the server's frame cost is a modifier that ends the round
		     for reasons nobody can see. ]]
		populationScale = 2.0,
		--[[ 1.6 rather than a matching 2.0. The population TARGET is what makes a
		     street feel full; the rate only decides how fast the map refills once
		     you have cleared it, and doubling both is how a team ends up unable
		     to reload between bodies rather than merely surrounded. ]]
		spawnRateScale = 1.6,
	}),
	table.freeze({
		id = "Darkness",
		displayName = "DARKNESS",
		blurb = "The sun is already gone. You have a torch and that is all.",
		--[[ The round's light ramp normally runs a full evening into night over
		     seventeen minutes. This starts it two thirds of the way down, so
		     wave 1 opens at the look wave 9 usually has and the finale is darker
		     still — the ramp is preserved rather than flattened, because a round
		     that is uniformly black has no arc and stops being frightening about
		     four minutes in. ]]
		atmosphereFloor = 0.66,
	}),
	table.freeze({
		id = "Elite",
		displayName = "ELITE WAVE",
		blurb = "Every boss this round is an Apex.",
		--[[ Waves 5, 8 and 11 get what wave 15 already had. It is the harshest
		     modifier in the list by some distance — three times the health on
		     four separate encounters — and it is the one a team can most
		     directly answer, because a Tank is a movement problem and the answer
		     to a bigger one is the same answer for longer. ]]
		eliteBosses = true,
	}),
	table.freeze({
		id = "NoAmmo",
		displayName = "NO AMMO DROPS",
		blurb = "Nothing restocks. What you find is what you get.",
		--[[ The breather stops resupplying the map and a spent ammo crate stays
		     spent. The AIRDROP requisition still works, deliberately — this
		     modifier is the one that makes it worth buying, and a rule with no
		     counter is a rule that only takes things away. ]]
		blocksRestock = true,
		blocksCrateRespawn = true,
	}),
	table.freeze({
		id = "Exploders",
		displayName = "EXPLODER INVASION",
		blurb = "Boomers, everywhere. Watch what you shoot.",
		--[[ The Director picks specials weighted by the inverse of spawnCost;
		     this multiplies the Boomer's share by six and lets five be alive at
		     once instead of two. It is the one modifier that makes the game
		     EASIER if you play it right and much harder if you do not: a Boomer
		     is three damage and a burst you caused, so a team that keeps its
		     discipline is fighting the cheapest special in the game five at a
		     time, and a team that panic-sprays is permanently blind. ]]
		specialWeights = { [Enums.Infected.Boomer] = 6 },
		specialCaps = { [Enums.Infected.Boomer] = 2.5 },
	}),
}

ModifierConfig.Catalogue = table.freeze(CATALOGUE) :: { Modifier }

local BY_ID: { [string]: Modifier } = {}
for _, entry in CATALOGUE do
	BY_ID[entry.id] = entry
end

--[[ The attribute the round's choice rides on. Workspace rather than a remote,
     for the reason every other piece of round state is: it replicates to
     everybody for free, and the six places that read it are spread across the
     server and the client. ]]
ModifierConfig.Attribute = Attributes.Game.Modifier

function ModifierConfig.get(id: any): Modifier?
	if typeof(id) ~= "string" or id == "" then
		return nil
	end
	return BY_ID[id]
end

--[[
	The modifier in force, or nil.

	Takes the root rather than reaching for `workspace`, the same as
	RequisitionConfig does and for the same reason: this module is required from
	both sides and from other configs, and a global lookup inside a shared module
	works right up until something requires it from a context without one.
]]
function ModifierConfig.active(root: Instance): Modifier?
	return ModifierConfig.get(root:GetAttribute(ModifierConfig.Attribute))
end

--[[ Picks one at random, or nil when the roll says none. Handed a Random so a
     caller that needs a reproducible round can supply its own. ]]
function ModifierConfig.roll(random: Random): Modifier?
	if #CATALOGUE == 0 then
		return nil
	end
	if random:NextNumber() >= ModifierConfig.Chance then
		return nil
	end
	return CATALOGUE[random:NextInteger(1, #CATALOGUE)]
end

-- ── the readers ─────────────────────────────────────────────────────────────
-- One per thing a modifier can move, so a call site asks a question rather than
-- testing an id. Adding a modifier never touches a call site.

local function scalar(root: Instance, field: string, default: number): number
	local entry = ModifierConfig.active(root)
	if not entry then
		return default
	end
	local value = (entry :: any)[field]
	return if typeof(value) == "number" then value else default
end

local function flag(root: Instance, field: string): boolean
	local entry = ModifierConfig.active(root)
	if not entry then
		return false
	end
	return (entry :: any)[field] == true
end

function ModifierConfig.commonSpeedScale(root: Instance): number
	return scalar(root, "commonSpeedScale", 1)
end

--[[ The odds a Common sprints. Takes the definition's own value, because a
     modifier that does not mention sprinting must not flatten the mix of
     shamblers and runners that makes a horde read as a crowd. ]]
function ModifierConfig.sprintChance(root: Instance, base: number): number
	return scalar(root, "commonSprintChance", base)
end

function ModifierConfig.commonHealthScale(root: Instance): number
	return scalar(root, "commonHealthScale", 1)
end

function ModifierConfig.populationScale(root: Instance): number
	return scalar(root, "populationScale", 1)
end

function ModifierConfig.spawnRateScale(root: Instance): number
	return scalar(root, "spawnRateScale", 1)
end

--[[ How far into the round's light ramp it STARTS, 0 for normal. See the
     Darkness entry: this raises the floor rather than replacing the curve. ]]
function ModifierConfig.atmosphereFloor(root: Instance): number
	return scalar(root, "atmosphereFloor", 0)
end

function ModifierConfig.eliteBosses(root: Instance): boolean
	return flag(root, "eliteBosses")
end

function ModifierConfig.blocksRestock(root: Instance): boolean
	return flag(root, "blocksRestock")
end

function ModifierConfig.blocksCrateRespawn(root: Instance): boolean
	return flag(root, "blocksCrateRespawn")
end

function ModifierConfig.specialWeightScale(root: Instance, kind: string): number
	local entry = ModifierConfig.active(root)
	if not entry or not entry.specialWeights then
		return 1
	end
	return entry.specialWeights[kind] or 1
end

--[[ How many of a kind may be alive, given the roster's own ceiling. Rounded
     rather than floored so a x2.5 on a cap of 2 is five and not four. ]]
function ModifierConfig.maxAliveFor(root: Instance, kind: string, base: number): number
	local entry = ModifierConfig.active(root)
	if not entry or not entry.specialCaps then
		return base
	end
	local scale = entry.specialCaps[kind]
	if not scale then
		return base
	end
	return math.max(math.floor(base * scale + 0.5), base)
end

return ModifierConfig
