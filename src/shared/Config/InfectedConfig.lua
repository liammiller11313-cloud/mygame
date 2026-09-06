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

	--[[ The folder under Assets/Infected this kind's models live in, when it is
	     not simply the id. The same escape hatch weapons have as `modelName`, and
	     for the same reason: an artist's folder is called what they called it,
	     and "Metallic Boss" holding a rig called "Metallic" is a perfectly
	     ordinary way to have organised it. Nil means the id is the folder. ]]
	modelFolder: string?,

	-- What the Director pays to spawn one, and how many may live at once
	spawnCost: number,
	maxAlive: number,

	-- Presentation
	bodyColor: Color3,
	accentColor: Color3,
	--[[ A blind multiplier on whatever the rig already is. Correct for the
	     grey boxes, which this project lays out itself and therefore knows the
	     size of — and a guess for anything an artist supplied, because the same
	     2.35 that makes a standard rig into a Tank makes an already-huge model
	     into something that does not fit down a street. See targetHeight. ]]
	scale: number,
	--[[ How tall this thing should END UP, in studs, whatever it arrived as.

	     Set it and the supplied-rig pipeline measures the model and works out the
	     multiplier itself, ignoring `scale`. That is the right question to be
	     asking for anything whose size is load-bearing: a boss has to read as
	     bigger than the last boss and still fit through the doors the last one
	     fits through, and neither of those is a fact about the artist's units.

	     Nil means "trust scale", which is every kind but the Metallic — the
	     Commons and the specials are all standard-sized rigs where a multiplier
	     means what it says. ]]
	targetHeight: number?,
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

		--[[
			200, and it was 45 — which against 50 health did not mean "past which
			the body comes apart" but "any headshot at all".

			The arithmetic nobody did: a head hit is multiplied by four, so the
			WEAKEST gun in the game puts 96 into a 50-health Common and overkills
			by 46. Every rifle in the roster cleared 45 on a headshot, gibThreshold
			is a SUFFICIENT condition rather than an extra gate, and gib() deletes
			the body outright. So the ordinary kill in this game — a headshot on a
			Common — never left anything behind, and the 35-second protected
			corpse a headshot is supposed to EARN had never once been created.
			Two features pointed at the same moment, and this one silently won.

			200 sits in the gap between what the heaviest scoped rifle delivers to
			a head (158) and what a magnum does (222). So the gate now fires for
			hand cannons, sniper rifles and melee — the weapons whose whole
			identity is that the target stops being a shape — and rifle fire is
			handed back to the score, where the weapon rather than the arithmetic
			of a small body decides.

			It is a much bigger multiple of health than any other kind's, and that
			is not an inconsistency to tidy up: the Common is the only body small
			enough that one hit can overkill it several times over, and it is the
			one every other number in this file was never tested against.
		]]
		gibThreshold = 200,
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
		--[[ Three, which is exactly what GameModeConfig's pack roll can ask for on
		     a full team and not one more. A ceiling under that makes a boss the
		     wave announced silently fail to arrive, which is the exact failure
		     this number was raised to fix the first time.

		     Nothing else competes for the three. The Director's own flow schedule
		     refuses to walk a Tank in while ANY Tank is alive, so a wave's pack
		     never has to share the ceiling with it. And it is a ceiling, not a
		     target: the roll decides how many actually come, and under three
		     survivors it never fires at all. ]]
		maxAlive = 3,

		bodyColor = Color3.fromRGB(126, 98, 82),
		accentColor = Color3.fromRGB(88, 62, 52),
		scale = 2.35,
		outlineColor = Color3.fromRGB(232, 48, 32),

		gibThreshold = 2000,
		dismemberable = false, -- a Tank falls in one piece; it earned that
		corpseLifetime = 60,
	},

	--[[
		METALLIC — the thing above a Tank.

		A Tank is a body that got bigger. This is not a body: it is machinery on
		two drills, and every number here is chosen so it plays differently rather
		than harder. Bigger health and bigger damage on the same fight would just
		be a longer Tank, which is the one thing a second boss must not be.

		── WHAT MAKES IT A DIFFERENT FIGHT ─────────────────────────────────────
		SLOWER THAN A TANK, and that is deliberate. A Tank cannot be outrun by
		anybody who stops to shoot, which forces the team to move as one and fire
		in turns. This one CAN be walked away from — and then it closes the
		distance in one committed line (see Specials/Metallic: the drill charge),
		so the answer is not distance, it is not being in the lane. A team that
		learns to sidestep beats it; a team that backs up in a straight corridor
		does not.

		FIRE IS NOT THE ANSWER. burnDamagePerSecond is 25 against the Tank's 150,
		and that is the single most important number on this table. Fire is the
		Tank's counter and every team learns it; meeting the next boss with the
		same molotov and watching it walk through the flames is what tells them
		this is a different problem. What it is weak to instead is the window
		after its own charge — see the overheat in Specials/Metallic — which is
		earned rather than bought.

		HEALTH IS ONLY HALF AGAIN A TANK'S, not double. The fight is longer than a
		Tank's because of the phases, not because of the bar; 8000 would be four
		minutes of shooting the same silhouette.
	]]
	[Enums.Infected.Metallic] = {
		id = Enums.Infected.Metallic,
		displayName = "Metallic",
		--[[ Their folder, which holds a rig called "Metallic". See modelFolder in
		     the type above. ]]
		modelFolder = "Metallic Boss",
		health = 6000,
		isBoss = true,
		isSpecial = true,

		--[[ Walks slower than a survivor and runs slower than a Tank. The charge
		     is what closes distance, so the base speed is allowed to be honest
		     about how heavy it is. ]]
		walkSpeed = 13,
		runSpeed = 19,
		sprintChance = 1.0,
		--[[ Half a Tank's turn rate. It cannot follow somebody circling it, which
		     is exactly the counterplay the fight is built around. ]]
		turnSpeed = 75,
		jumpPower = 0,

		headshotAlwaysKills = false,
		damageResistance = 1.0,
		stumbleResistance = 1.0,
		burnDamagePerSecond = 25,

		--[[ Drills, not fists: less per hit than a Tank's swing and far more
		     often, so standing in front of it is a mistake that compounds rather
		     than one that throws you clear. ]]
		attack = { damage = 16, range = 12, cooldown = 0.75, windup = 0.3 },

		sightRange = 500,
		hearingRange = 600,
		loseInterestTime = 25,

		spawnCost = 160,
		--[[ One. There is no arrangement of a map or a team where two of these at
		     once is a fight rather than a formality. ]]
		maxAlive = 1,

		bodyColor = Color3.fromRGB(104, 108, 116),
		accentColor = Color3.fromRGB(58, 62, 68),
		--[[ Solved backwards from targetHeight, not chosen: the grey-box
		     proportions add up to 5.70 studs unscaled, and 5.70 x 2.98 is 17.0.
		     This number only ever builds the fallback rig, and the two are kept
		     in agreement so a grey-boxed Metallic is the same size as the real
		     one. Change targetHeight and this has to be re-solved. ]]
		scale = 2.98,
		--[[
			Seventeen studs, and the number it is measured against is a Tank.

			This was 14 for a while, on the reasoning that a Tank stands about
			10.6 so 14 is a third taller. That 10.6 was wrong, and wrong in a way
			worth writing down: it was the height of the GREY-BOX Tank, the
			fallback rig this file builds out of parts when nothing is supplied.
			The shipped game has never used it. A real Tank is an artist's rig
			and boots at 13.6 studs — so the Metallic at 14 was x1.03 of a Tank,
			which is to say the same size, and the one thing this creature has to
			do at a glance is not be a Tank.

			Seventeen is x1.25 of a measured Tank: unmistakable down a street,
			and every map is already laid out to pass a Tank with room. It is
			also under the boot-time ceiling in PlaceholderFactory, which is
			1.35x whatever the Tank actually measures.

			An Apex is a Tank's height whatever its tier says, because the x1.12
			it asks for is applied through Humanoid scale values the asset
			pipeline has already stripped — so it does not move this number.

			It is a HEIGHT rather than a multiplier because the rig is supplied.
			An artist asked for a giant mecho zombie and will build one at
			whatever size seemed right; multiplying that by anything is a guess
			about their units, and this is not a number worth guessing.
		]]
		targetHeight = 17,
		outlineColor = Color3.fromRGB(255, 154, 42),

		gibThreshold = 4000,
		dismemberable = false,
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
--[[
	The bosses a team has to STAND AND FIGHT, as opposed to the one it can walk
	around.

	All three of Witch, Tank and Metallic set `isBoss`, and for most purposes
	that is the right question. This is the other one, and enough places need it
	that it belongs here rather than being spelled out again in each: the Tank
	and the Metallic are fights, and the Witch is a hazard you are supposed to
	tiptoe past.

	It decides who gets a health bar — put one over the Witch and a team starts
	shooting her to watch it move, which is the opposite of the whole idea — and
	it decides whether an arrival pushes the Director to its peak pacing state,
	because a hazard the team chooses to avoid has not raised the pressure.
]]
InfectedConfig.PeakBosses = table.freeze({
	[Enums.Infected.Tank] = true,
	[Enums.Infected.Metallic] = true,
})

export type EliteTier = {
	id: string,
	--[[ A PREFIX, not a name. It used to be "Apex Tank" because the finale was
	     the only user; the ELITE WAVE modifier applies the same tier to a Witch,
	     and a Witch announced as an Apex Tank is a callout that gets somebody
	     killed. Composed with the kind's own displayName at every read. ]]
	titlePrefix: string,
	health: number, -- multiplier on the kind's health
	damage: number, -- multiplier on the kind's attack damage
	scale: number, -- multiplier on the kind's rig scale
	speed: number, -- multiplier on walk speed
	outlineColor: Color3,
}

InfectedConfig.EliteTiers = table.freeze({
	Apex = table.freeze({
		id = "Apex",
		titlePrefix = "Apex",
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
