--!strict
--[[
	InfectedConfig — the enemy roster.

	Health values are deliberately close to Left 4 Dead 2's, because those numbers
	are load-bearing: a Common that dies to one rifle round and any headshot is
	what makes a horde readable, and a Tank that eats four thousand points is what
	makes a Tank an event rather than an obstacle.

	`headshotAlwaysKills` is the single most important field here. Without it a
	horde is an HP sponge; with it, aiming is the whole skill expression.
]]

local Enums = require(script.Parent.Parent.Enums)

export type AttackDefinition = {
	damage: number,
	range: number,
	cooldown: number,
	windup: number, -- telegraph time before damage lands; readable tells matter
}

export type InfectedDefinition = {
	id: string,
	displayName: string,
	health: number,
	isBoss: boolean,
	isSpecial: boolean,

	walkSpeed: number,
	runSpeed: number,
	sprintChance: number, -- 0-1 odds this Common sprints rather than shambles
	turnSpeed: number, -- degrees per second the model may rotate
	jumpPower: number,

	headshotAlwaysKills: boolean,
	damageResistance: number, -- multiplier applied to all incoming damage
	stumbleResistance: number, -- 0 stumbles to any shove, 1 never stumbles
	burnDamagePerSecond: number,

	attack: AttackDefinition,

	-- Awareness
	sightRange: number,
	hearingRange: number,
	loseInterestTime: number, -- seconds with no target before returning to idle

	-- What the Director pays to spawn one, and how many may live at once
	spawnCost: number,
	maxAlive: number,

	-- Presentation
	bodyColor: Color3,
	accentColor: Color3,
	scale: number,
	outlineColor: Color3, -- silhouette colour when highlighted through walls

	-- Gore tuning; see GoreConfig for how these combine with weapon gibPower
	gibThreshold: number, -- overkill damage past which the body comes apart
	dismemberable: boolean,
	corpseLifetime: number,
}

local InfectedConfig = {}

InfectedConfig.Definitions = {

	--[[ The horde. Individually trivial and that is the design: a Common exists
	     to be deleted in one satisfying motion, forty times a minute. ]]
	[Enums.Infected.Common] = {
		id = Enums.Infected.Common,
		displayName = "Infected",
		health = 50,
		isBoss = false,
		isSpecial = false,

		walkSpeed = 9,
		runSpeed = 21,
		sprintChance = 0.75,
		turnSpeed = 540,
		jumpPower = 32,

		headshotAlwaysKills = true,
		damageResistance = 1.0,
		stumbleResistance = 0.0,
		burnDamagePerSecond = 25,

		attack = { damage = 4, range = 6.5, cooldown = 0.9, windup = 0.22 },

		sightRange = 190,
		hearingRange = 320,
		loseInterestTime = 6,

		spawnCost = 1,
		maxAlive = 60,

		bodyColor = Color3.fromRGB(112, 118, 96),
		accentColor = Color3.fromRGB(78, 46, 42),
		scale = 1.0,
		outlineColor = Color3.fromRGB(214, 62, 48),

		gibThreshold = 45,
		dismemberable = true,
		--[[ 35, up from 22. The number is the one asked for, but the reason it
		     was reachable is GoreService freezing a corpse once it settles: a
		     ragdoll that has stopped moving is anchored and stops being a
		     simulation, so keeping it costs draw calls rather than physics. ]]
		corpseLifetime = 35,
	},

	--[[ Pounces from above and pins one survivor, dealing steady damage until a
	     teammate shoves or shoots it off. Punishes the player who walks alone. ]]
	[Enums.Infected.Hunter] = {
		id = Enums.Infected.Hunter,
		displayName = "Hunter",
		health = 250,
		isBoss = false,
		isSpecial = true,

		walkSpeed = 14,
		runSpeed = 30,
		sprintChance = 1.0,
		turnSpeed = 720,
		jumpPower = 95, -- the crouch-and-leap arc

		headshotAlwaysKills = false,
		damageResistance = 1.0,
		stumbleResistance = 0.25,
		burnDamagePerSecond = 30,

		attack = { damage = 6, range = 5, cooldown = 0.55, windup = 0.1 },

		sightRange = 320,
		hearingRange = 400,
		loseInterestTime = 12,

		spawnCost = 24,
		maxAlive = 2,

		bodyColor = Color3.fromRGB(64, 68, 74),
		accentColor = Color3.fromRGB(34, 36, 40),
		scale = 1.0,
		outlineColor = Color3.fromRGB(126, 84, 214),

		gibThreshold = 140,
		dismemberable = true,
		corpseLifetime = 30,
	},

	--[[ Reaches out from long range, drags a survivor away from the group, and
	     chokes them. The counter is cutting the tongue — so it wants to be shot
	     the moment you hear it cough. ]]

	--[[ Leaps onto a survivor's back and STEERS them — away from the team, off a
	     ledge, into a Witch. The damage is trivial; the danger is entirely that
	     you are no longer the one deciding where you go. Cackles constantly while
	     riding, which is how the rest of the team finds the victim. ]]
	[Enums.Infected.Jockey] = {
		id = Enums.Infected.Jockey,
		displayName = "Jockey",
		health = 250,
		isBoss = false,
		isSpecial = true,

		walkSpeed = 15,
		runSpeed = 28,
		sprintChance = 1.0,
		turnSpeed = 720,
		jumpPower = 78,

		headshotAlwaysKills = false,
		damageResistance = 1.0,
		stumbleResistance = 0.15,
		burnDamagePerSecond = 30,

		attack = { damage = 4, range = 5, cooldown = 0.7, windup = 0.1 },

		sightRange = 300,
		hearingRange = 380,
		loseInterestTime = 12,

		spawnCost = 22,
		maxAlive = 2,

		bodyColor = Color3.fromRGB(92, 74, 64),
		accentColor = Color3.fromRGB(58, 46, 40),
		scale = 0.82,
		outlineColor = Color3.fromRGB(196, 132, 224),

		gibThreshold = 140,
		dismemberable = true,
		corpseLifetime = 28,
	},

	--[[ Commits to a straight-line charge at speed and takes whoever it reaches
	     off their feet, scattering everyone else in the lane. Deliberately clumsy
	     to turn, so a charge CAN be dodged — the wind-up bellow is the tell, and
	     making that dodge is the most satisfying thing a survivor does. ]]
	[Enums.Infected.Charger] = {
		id = Enums.Infected.Charger,
		displayName = "Charger",
		health = 450,
		isBoss = false,
		isSpecial = true,

		walkSpeed = 13,
		runSpeed = 44, -- charge speed; terrifying in a corridor
		sprintChance = 1.0,
		turnSpeed = 95, -- clumsy on purpose: this is the dodge window
		jumpPower = 30,

		headshotAlwaysKills = false,
		damageResistance = 1.0,
		stumbleResistance = 0.7,
		burnDamagePerSecond = 30,

		attack = { damage = 11, range = 7, cooldown = 1.1, windup = 0.3 },

		sightRange = 340,
		hearingRange = 360,
		loseInterestTime = 12,

		spawnCost = 28,
		maxAlive = 2,

		bodyColor = Color3.fromRGB(118, 92, 74),
		accentColor = Color3.fromRGB(82, 62, 48),
		scale = 1.25,
		outlineColor = Color3.fromRGB(226, 132, 48),

		gibThreshold = 260,
		dismemberable = true,
		corpseLifetime = 36,
	},

	--[[
		Tongue — the Smoker, renamed because Roblox's filter eats the word.

		It never comes to you. It finds a sightline from sixty studs away, drags
		one survivor out of the group, and the only counter is a teammate: the
		victim cannot free themselves and everyone knows it. That is the whole
		design, and the numbers protect it — low health because it must die the
		moment it is found, and a sight range far beyond its pull so it can pick
		its spot before anyone can answer.

		Slow on the ground. A Tongue that can also chase is a Tongue with no
		weakness, and the tell is that you have time to find it.
	]]
	[Enums.Infected.Tongue] = {
		id = Enums.Infected.Tongue,
		displayName = "Tongue",
		health = 250,
		isBoss = false,
		isSpecial = true,

		walkSpeed = 11,
		runSpeed = 15,
		sprintChance = 0.2,
		turnSpeed = 200,
		jumpPower = 32,

		headshotAlwaysKills = false,
		damageResistance = 1.0,
		stumbleResistance = 0.15,
		burnDamagePerSecond = 34,

		-- The constrict, once a victim is reeled in. Low and relentless rather
		-- than spiky: the threat is the isolation, not the damage.
		attack = { damage = 5, range = 6, cooldown = 0.8, windup = 0.15 },

		sightRange = 420,
		hearingRange = 300,
		loseInterestTime = 14,

		spawnCost = 26,
		maxAlive = 2,

		bodyColor = Color3.fromRGB(84, 104, 62),
		accentColor = Color3.fromRGB(56, 70, 42),
		scale = 1.1,
		outlineColor = Color3.fromRGB(150, 196, 84),

		gibThreshold = 170,
		dismemberable = true,
		corpseLifetime = 32,
	},

	--[[
		Boomer — deals almost no damage and decides more fights than anything
		except the Tank.

		What it does is take away your VISION and hand your position to the
		horde, and it does it by dying. That inversion is the joke and the whole
		of the design: killing a Boomer badly is worse than not killing it, so
		the correct answer is to back up first and shoot it second, which is
		exactly the discipline a co-op zombie game wants to teach.

		Fat, slow, and fragile. It only has to get close once.
	]]
	[Enums.Infected.Boomer] = {
		id = Enums.Infected.Boomer,
		displayName = "Boomer",
		health = 125,
		isBoss = false,
		isSpecial = true,

		walkSpeed = 9,
		runSpeed = 13,
		sprintChance = 0.1,
		turnSpeed = 150,
		jumpPower = 20,

		headshotAlwaysKills = false,
		damageResistance = 1.0,
		stumbleResistance = 0.0, -- shoves off trivially; that IS the counter
		burnDamagePerSecond = 40,

		-- The vomit itself does no damage. This is the slap it throws if you let
		-- it reach you, which should sting and never kill.
		attack = { damage = 3, range = 6, cooldown = 1.0, windup = 0.25 },

		sightRange = 240,
		hearingRange = 260,
		loseInterestTime = 10,

		spawnCost = 22,
		maxAlive = 2,

		bodyColor = Color3.fromRGB(126, 122, 74),
		accentColor = Color3.fromRGB(88, 86, 50),
		scale = 1.35,
		outlineColor = Color3.fromRGB(198, 202, 96),

		--[[ Comes apart at the slightest provocation, and dismemberable is false
		     on purpose: a Boomer is one balloon, and taking an arm off it instead
		     of bursting it is the wrong read every time. ]]
		gibThreshold = 40,
		dismemberable = false,
		corpseLifetime = 20,
	},

	--[[
		Spitter — the only infected that attacks the FLOOR.

		Everything else in this game threatens a body. The Spitter threatens a
		place, which is what makes it the answer to a team that has found a
		corner and stopped moving: the acid does not care how good your aim is,
		it cares that you are standing still.

		The lowest health in the roster after the Boomer, and the longest range
		of anything that is not the Tongue. It is meant to spit and retreat, and
		to be punished the moment somebody turns around.
	]]
	[Enums.Infected.Spitter] = {
		id = Enums.Infected.Spitter,
		displayName = "Spitter",
		health = 110,
		isBoss = false,
		isSpecial = true,

		walkSpeed = 14,
		runSpeed = 26, -- runs AWAY well; that is what the speed is for
		sprintChance = 0.7,
		turnSpeed = 220,
		jumpPower = 34,

		headshotAlwaysKills = false,
		damageResistance = 1.0,
		stumbleResistance = 0.0,
		burnDamagePerSecond = 34,

		-- Its melee is an afterthought. The acid is the weapon and it lives in
		-- the Spitter module, not here, because a pool is not an attack on a body.
		attack = { damage = 4, range = 6, cooldown = 0.9, windup = 0.2 },

		sightRange = 380,
		hearingRange = 280,
		loseInterestTime = 12,

		spawnCost = 24,
		maxAlive = 2,

		bodyColor = Color3.fromRGB(96, 116, 66),
		accentColor = Color3.fromRGB(140, 168, 58),
		scale = 1.05,
		outlineColor = Color3.fromRGB(176, 214, 72),

		gibThreshold = 60,
		dismemberable = true,
		corpseLifetime = 26,
	},

	--[[ Not the Left 4 Dead witch. She sits and cries until something disturbs
	     her, and then she does two things at once: she SUMMONS, dragging every
	     Common within earshot toward the team, and she HUNTS the survivor who
	     woke her, faster than any of them can run.

	     That combination is why she is a boss rather than a hazard. Ignoring her
	     is no longer free, because the horde she calls arrives whether you engage
	     or not — but fighting her means fighting that horde at the same time. ]]
	[Enums.Infected.Witch] = {
		id = Enums.Infected.Witch,
		displayName = "Witch",
		health = 1000,
		isBoss = true,
		isSpecial = true,

		walkSpeed = 5,
		runSpeed = 30, -- faster than a sprinting survivor, but catchable-ish
		sprintChance = 1.0,
		turnSpeed = 420,
		jumpPower = 34,

		headshotAlwaysKills = false,
		damageResistance = 1.0,
		stumbleResistance = 1.0,
		burnDamagePerSecond = 45,

		attack = { damage = 45, range = 7.5, cooldown = 1.4, windup = 0.25 },

		sightRange = 220,
		hearingRange = 260,
		loseInterestTime = 25,

		spawnCost = 60,
		maxAlive = 1,

		bodyColor = Color3.fromRGB(196, 188, 176),
		accentColor = Color3.fromRGB(128, 42, 48),
		scale = 1.05,
		outlineColor = Color3.fromRGB(236, 96, 128),

		gibThreshold = 600,
		dismemberable = true,
		corpseLifetime = 45,
	},

	[Enums.Infected.Tank] = {
		id = Enums.Infected.Tank,
		displayName = "Tank",
		health = 4000,
		isBoss = true,
		isSpecial = true,

		walkSpeed = 16,
		runSpeed = 24,
		sprintChance = 1.0,
		turnSpeed = 150,
		jumpPower = 40,

		headshotAlwaysKills = false,
		damageResistance = 1.0,
		stumbleResistance = 1.0,
		burnDamagePerSecond = 150, -- fire is the intended answer to a Tank

		attack = { damage = 24, range = 11, cooldown = 1.4, windup = 0.4 },

		sightRange = 500,
		hearingRange = 600,
		loseInterestTime = 25,

		spawnCost = 100,
		--[[ Two. The finale releases ONE Tank now — an Apex one, see EliteTiers —
		     but the ceiling stays at two because the Director's own flow schedule
		     can still put an ordinary Tank on the map, and a ceiling of one would
		     make the finale's boss silently fail to arrive if it did. That is the
		     exact failure this number was raised to fix the first time. ]]
		maxAlive = 2,

		bodyColor = Color3.fromRGB(126, 98, 82),
		accentColor = Color3.fromRGB(88, 62, 52),
		scale = 2.35,
		outlineColor = Color3.fromRGB(232, 48, 32),

		gibThreshold = 2000,
		dismemberable = false, -- a Tank falls in one piece; it earned that
		corpseLifetime = 60,
	},
} :: { [string]: InfectedDefinition }

--[[
	── COMMON TIERS ────────────────────────────────────────────────────────────
	Not every Common is the same Common.

	The horde is one archetype with many MODELS, picked at random per body so a
	wave reads as a crowd rather than a clone army. Some of those models are
	obviously tougher than the rest — riot gear, body armour, a helmet — and a
	player who shoots one and watches it die like a shirtless shambler learns
	that the art is decoration. Making the armoured ones actually harder is what
	turns a variant list into information.

	Tiers are keyed by the TRAILING NUMBER in the model's name, because that is
	the one thing a folder of variants reliably has: "24", "Common24",
	"Common 24" and "Infected_24" all resolve to 24. A model whose name has no
	number in it is a regular, which is the safe default — a new model dropped in
	is never accidentally a mini-boss.

	The bands and what they mean:
	  *  1–23  regular. The baseline the whole game is tuned against.
	  * 28–34  reinforced. Noticeably harder than a regular, clearly softer than
	           police. These are the ones that make you stop spraying.
	  * 24–27  police. The hardest thing in the horde that is not a special:
	           three shots rather than one, and a hit that actually hurts.

	Scales rather than absolute numbers, so retuning the Common retunes all
	three and they can never drift apart. Damage is applied to `attack.damage`
	per body by InfectedService, health to MaxHealth.
]]
export type CommonTier = {
	id: string,
	displayName: string,
	from: number,
	to: number,
	health: number, -- multiplier on Common health
	damage: number, -- multiplier on Common attack damage
	outlineColor: Color3,
}

InfectedConfig.CommonTiers = table.freeze({
	table.freeze({
		id = "Reinforced",
		displayName = "Reinforced Infected",
		from = 28,
		to = 34,
		health = 2.0, -- 100 hp
		damage = 1.4, -- 5.6
		outlineColor = Color3.fromRGB(214, 176, 96),
	}),
	table.freeze({
		id = "Police",
		displayName = "Riot Infected",
		from = 24,
		to = 27,
		health = 3.2, -- 160 hp
		damage = 1.85, -- 7.4
		outlineColor = Color3.fromRGB(120, 168, 226),
	}),
}) :: { CommonTier }

--[[
	── ELITE TIERS ─────────────────────────────────────────────────────────────

	A modifier applied to a SPECIFIC spawn rather than to a kind. Same creature,
	same silhouette, same tells, same counters — more of it.

	The finale is the only user and the Apex Tank is the only tier. Wave 15 asks
	for a Tank the way waves 5 and 11 do, and passes `bossTier = "Apex"`
	alongside; DirectorService carries that through its placement queue and
	InfectedService applies it at spawn.

	── WHY A MODIFIER AND NOT A NEW KIND ───────────────────────────────────────
	A second Tank archetype would need its own rig, its own animations, its own
	Versus class row, its own audio and its own place in every table keyed by
	Enums.Infected. All of that to end up with a creature that does what a Tank
	does. The thing that makes a finale boss a boss is that the answer you spent
	the round learning stops being enough — you already know to spread out, to
	keep it off the person reviving, to not stand where it can reach; it just
	takes four times as long and you have four times as long to make a mistake.

	── WHY THE NUMBERS ARE WHAT THEY ARE ───────────────────────────────────────
	Health 3.0 puts it at 12,000. Four survivors killing a 4,000-health Tank take
	somewhere around thirty seconds of good shooting; this is a ninety-second
	fight inside a 144-second wave, which leaves room to lose people and still
	finish it, and no room at all to be careless.

	Damage 1.35 is 32 a hit rather than 24. Deliberately restrained: a survivor
	has 100 health, so an ordinary Tank needs five hits and this one needs four.
	Doubling it would have made the difference "you die instantly" rather than
	"you have less time than you thought", and instant death is not difficulty.

	Scale 1.12 is the only thing you can see across a street. Big enough to read
	as different, small enough that it still fits through the doors a Tank has to
	fit through — the rigs are scaled by RigUtil and a boss wedged in a doorway
	is a boss the team beats by standing still.
]]
export type EliteTier = {
	id: string,
	displayName: string,
	health: number, -- multiplier on the kind's health
	damage: number, -- multiplier on the kind's attack damage
	scale: number, -- multiplier on the kind's rig scale
	speed: number, -- multiplier on walk speed
	outlineColor: Color3,
}

InfectedConfig.EliteTiers = table.freeze({
	Apex = table.freeze({
		id = "Apex",
		displayName = "Apex Tank",
		health = 3.0,
		damage = 1.35,
		scale = 1.12,
		--[[ Not faster. A Tank is already the fastest thing in the game that can
		     one-shot you into the floor, and the counter to a Tank is running —
		     making an Apex outrun a survivor would delete the counter rather than
		     raise the bar. It gets health and reach; the team keeps its legs. ]]
		speed = 1.0,
		outlineColor = Color3.fromRGB(240, 92, 40),
	}),
}) :: { [string]: EliteTier }

--[[ An elite modifier by id, nil for an unknown one. Ids come out of wave
     definitions and off attributes, so an unknown one must be a no-op rather
     than an error: the worst outcome of a typo is an ordinary Tank. ]]
function InfectedConfig.elite(id: string?): EliteTier?
	if typeof(id) ~= "string" then
		return nil
	end
	return InfectedConfig.EliteTiers[id]
end

--[[ The number at the end of a variant's model name, or nil. Anchored to the
     END so "Common 24" reads 24 rather than finding some other digit earlier in
     the name — a folder called "Zombie2" full of models is not a folder of
     tier-2 bodies. ]]
local function variantNumber(name: string): number?
	local digits = string.match(name, "(%d+)%s*$")
	return if digits then tonumber(digits) else nil
end

--[[ The tier a Common variant belongs to, or nil for a regular.

     Only ever consulted for Commons. A special has one model and no tiers, and
     a special whose model happened to be called "Hunter24" must not quietly
     become a riot Hunter. ]]
function InfectedConfig.tierForVariant(kind: string, variantName: string?): CommonTier?
	if kind ~= Enums.Infected.Common or typeof(variantName) ~= "string" then
		return nil
	end
	local number = variantNumber(variantName)
	if not number then
		return nil
	end
	for _, tier in InfectedConfig.CommonTiers do
		if number >= tier.from and number <= tier.to then
			return tier
		end
	end
	return nil
end

--[[ Looks up an archetype, nil for an unknown id (ids arrive from attributes). ]]
function InfectedConfig.get(kind: string): InfectedDefinition?
	return InfectedConfig.Definitions[kind]
end

function InfectedConfig.all(): { [string]: InfectedDefinition }
	return InfectedConfig.Definitions
end

--[[ Every special the Director is allowed to spawn on its own, bosses excluded.
     Bosses are scheduled explicitly by flow distance, never by the spawn budget. ]]
function InfectedConfig.getSpecialIds(): { string }
	local ids = {}
	for id, definition in InfectedConfig.Definitions do
		if definition.isSpecial and not definition.isBoss then
			table.insert(ids, id)
		end
	end
	table.sort(ids)
	return ids
end

return InfectedConfig
