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
	[Enums.Infected.Rusher] = {
		id = Enums.Infected.Rusher,
		displayName = "Rusher",
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
		-- Two, because wave 7 releases a pair and the finale announces it. A
		-- single-Tank ceiling made the second release silently fail while the
		-- callout still promised two.
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
