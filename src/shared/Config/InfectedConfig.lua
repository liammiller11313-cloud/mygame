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
		corpseLifetime = 22,
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
	[Enums.Infected.Smoker] = {
		id = Enums.Infected.Smoker,
		displayName = "Smoker",
		health = 250,
		isBoss = false,
		isSpecial = true,

		walkSpeed = 12,
		runSpeed = 17,
		sprintChance = 0.2,
		turnSpeed = 360,
		jumpPower = 32,

		headshotAlwaysKills = false,
		damageResistance = 1.0,
		stumbleResistance = 0.2,
		burnDamagePerSecond = 30,

		attack = { damage = 4, range = 220, cooldown = 3.5, windup = 0.65 },

		sightRange = 420,
		hearingRange = 380,
		loseInterestTime = 14,

		spawnCost = 24,
		maxAlive = 2,

		bodyColor = Color3.fromRGB(74, 92, 62),
		accentColor = Color3.fromRGB(46, 58, 38),
		scale = 1.12,
		outlineColor = Color3.fromRGB(96, 176, 84),

		gibThreshold = 140,
		dismemberable = true,
		corpseLifetime = 30,
	},

	--[[ Almost no health, almost no damage, and by far the most dangerous thing
	     in the game: it coats you in bile and every Common within earshot comes.
	     Killing it up close is the mistake — it explodes. ]]
	[Enums.Infected.Boomer] = {
		id = Enums.Infected.Boomer,
		displayName = "Boomer",
		health = 50,
		isBoss = false,
		isSpecial = true,

		walkSpeed = 8,
		runSpeed = 12,
		sprintChance = 0.1,
		turnSpeed = 240,
		jumpPower = 20,

		headshotAlwaysKills = false,
		damageResistance = 1.0,
		stumbleResistance = 0.0,
		burnDamagePerSecond = 40,

		attack = { damage = 0, range = 34, cooldown = 6, windup = 0.5 },

		sightRange = 180,
		hearingRange = 260,
		loseInterestTime = 10,

		spawnCost = 20,
		maxAlive = 1,

		bodyColor = Color3.fromRGB(128, 122, 74),
		accentColor = Color3.fromRGB(92, 88, 44),
		scale = 1.35,
		outlineColor = Color3.fromRGB(148, 166, 62),

		gibThreshold = 1, -- a Boomer always comes apart. That is the joke.
		dismemberable = true,
		corpseLifetime = 8,
	},

	--[[ Runs in a straight line, picks one survivor up, carries them out of the
	     room, and beats them into the floor. Scatters everyone else on the way. ]]
	[Enums.Infected.Charger] = {
		id = Enums.Infected.Charger,
		displayName = "Charger",
		health = 600,
		isBoss = false,
		isSpecial = true,

		walkSpeed = 12,
		runSpeed = 42, -- charge speed; terrifying in a corridor
		sprintChance = 1.0,
		turnSpeed = 90, -- deliberately clumsy, so a charge can be dodged
		jumpPower = 28,

		headshotAlwaysKills = false,
		damageResistance = 1.0,
		stumbleResistance = 0.75,
		burnDamagePerSecond = 30,

		attack = { damage = 12, range = 7, cooldown = 1.1, windup = 0.3 },

		sightRange = 340,
		hearingRange = 360,
		loseInterestTime = 12,

		spawnCost = 30,
		maxAlive = 1,

		bodyColor = Color3.fromRGB(120, 96, 78),
		accentColor = Color3.fromRGB(84, 64, 50),
		scale = 1.45,
		outlineColor = Color3.fromRGB(214, 132, 48),

		gibThreshold = 320,
		dismemberable = true,
		corpseLifetime = 40,
	},

	--[[ Does nothing at all until disturbed, then kills whoever disturbed her and
	     leaves. A hazard rather than an enemy — the tension is entirely in the
	     approach, and a good team simply walks around her. ]]
	[Enums.Infected.Witch] = {
		id = Enums.Infected.Witch,
		displayName = "Witch",
		health = 1000,
		isBoss = true,
		isSpecial = true,

		walkSpeed = 4,
		runSpeed = 48, -- once startled she is faster than any survivor
		sprintChance = 1.0,
		turnSpeed = 540,
		jumpPower = 34,

		headshotAlwaysKills = false,
		damageResistance = 1.0,
		stumbleResistance = 1.0,
		burnDamagePerSecond = 45,

		attack = { damage = 999, range = 7, cooldown = 1.5, windup = 0.15 },

		sightRange = 60, -- she is not looking for you
		hearingRange = 90,
		loseInterestTime = 20,

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

	--[[ The set piece. Four thousand health, throws chunks of the level at you,
	     and cannot be outrun by anyone who stops to shoot. The whole team has to
	     move and fire at once, which is the most cooperative the game ever gets. ]]
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
		maxAlive = 1,

		bodyColor = Color3.fromRGB(126, 98, 82),
		accentColor = Color3.fromRGB(88, 62, 52),
		scale = 2.35,
		outlineColor = Color3.fromRGB(232, 48, 32),

		gibThreshold = 2000,
		dismemberable = false, -- a Tank falls in one piece; it earned that
		corpseLifetime = 60,
	},
} :: { [string]: InfectedDefinition }

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
