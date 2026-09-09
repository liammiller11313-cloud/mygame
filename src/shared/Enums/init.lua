--!strict
--[[
	Enums — every symbolic constant in Fading Light lives here.

	These are plain string values (never numeric) so that anything crossing the
	network, landing in an Attribute, or showing up in a print() stays readable.
	Never compare against a string literal at a call site; always compare against
	the enum field so a rename is a single-file change.
]]

local Enums = {}

-- Which weapon a Weapon instance is. Keys must match WeaponConfig keys exactly.
-- These are code identifiers, not file names: the actual model in
-- ReplicatedStorage.Assets is named by WeaponConfig's `modelName` field, because
-- "Mk 18 CQBR" and "(71 Mag) PPSh-41" are not valid Luau identifiers.
Enums.Weapon = table.freeze({
	--[[ Secondary. Five, and the shape of the set is the point: the sidearm is
	     what you have when the primary runs dry and the only thing you have while
	     you are on the floor, so each one answers "twenty zombies, eight rounds"
	     differently — place it, spray it, or put both barrels through it. ]]
	M1911A1 = "M1911A1",
	Magnum357 = "Magnum357",
	DualBerettas = "DualBerettas",
	Glock18 = "Glock18",
	SawnOff = "SawnOff",
	--[[ The sixth, and not part of that set. The five above answer "twenty
	     zombies, eight rounds"; this answers "a Tank, and nothing else is
	     working". It is a secondary by slot only — priced, loaded and reloaded so
	     that carrying it means giving up the fallback the slot exists for. ]]
	RPG7 = "RPG7",
	--[[ Secondary: a signal pistol, and the cheapest way into the burn the
	     molotov owns. One shell, a long reload, and damage that barely troubles
	     a Common on impact — what it does is set them alight and light the room
	     doing it, in a game whose own title is about that running out. ]]
	FlareGun = "FlareGun",
	--[[ The seventh, from the supplied models. Capacity rather than punch — see
	     WeaponConfig. ]]
	M9 = "M9",

	--[[ Melee. Five, each with a different reason to carry it: reach, speed,
	     damage, how many bodies one swing goes through. Every one of them has a
	     real model in the place; nothing here is a placeholder. ]]
	Machete = "Machete",
	FireAxe = "FireAxe",
	BaseballBat = "BaseballBat",
	LeadPipe = "LeadPipe",
	Knife = "Knife",

	--[[ Brickbattler's Pack. Unlocked by a Robux game pass rather than bought
	     with Dollars, so none of them has a shop row — see PassConfig, and the
	     `passOnly` flag in WeaponConfig that tells audit.py this is a third way
	     to own a weapon alongside buying one and finding one. ]]
	ClassicSword = "ClassicSword",
	ClassicPaintballGun = "ClassicPaintballGun",
	ClassicSlingshot = "ClassicSlingshot",
	ClassicRocketLauncher = "ClassicRocketLauncher",

	--[[ Primary: shotguns. Four now, and they differ by how they FEED rather
	     than by damage: two pumps, a semi-auto, and a drum. ]]
	Shotgun = "Shotgun",
	TacticalShotty = "TacticalShotty",
	M1014 = "M1014",
	DAO12 = "DAO12",

	-- Primary: submachine guns
	PPSh41 = "PPSh41",
	KrissVector = "KrissVector",
	MP7A1 = "MP7A1",
	UMP45 = "UMP45",
	AKS74U = "AKS74U",

	-- Primary: rifles
	M4A1 = "M4A1",
	HK416A5 = "HK416A5",
	Mk18CQBR = "Mk18CQBR",
	AK12 = "AK12",
	AKM = "AKM",
	M16A4 = "M16A4",
	HK416D = "HK416D",
	HK417 = "HK417",

	--[[ Primary: light machine guns. A new shape rather than more of the same —
	     a hundred rounds is the only answer to a horde that does not stop. ]]
	M249 = "M249",
	M60E4 = "M60E4",

	--[[ Primary: not a gun. It fires a short cone of burning fuel and sets
	     everything it touches alight — the only weapon in the game whose damage
	     is mostly what happens AFTER it hits. Never sold: it lies on the floor of
	     the vault, behind the puzzle, and that is the whole of its distribution. ]]
	Flamethrower = "Flamethrower",

	--[[ Primary: also not a gun, and deliberately the opposite of the one above
	     it. The flamethrower is a wide short cone that sets a room alight and
	     keeps killing after you stop; this is a single bolt that goes exactly
	     where you point it and arcs straight down a line of bodies. One is area
	     denial, the other is a queue-deleter, and neither refills — both lie on
	     the floor of a room somebody had to earn.

	     Zombieville's, the way the Flamethrower is Clinton's. ]]
	TeslaRifle = "TeslaRifle",

	-- Primary: marksman
	ScopedMk18 = "ScopedMk18",
	M1AEBR = "M1AEBR",
	MK11 = "MK11",
	M24 = "M24",
})

-- Inventory slot. A survivor holds exactly one item per slot, L4D2 style.
Enums.Slot = table.freeze({
	Primary = "Primary", -- rifles, shotguns, SMGs
	Secondary = "Secondary", -- pistols
	--[[ Melee has its own slot rather than sharing Secondary with the pistols,
	     which is where the machete used to live.

	     That is a deliberate departure from Left 4 Dead 2, where picking up a
	     crowbar costs you your sidearm. It is the more generous rule: a melee you
	     always have is a tool for saving ammo and for the moment a Common is
	     already on top of you, and neither of those is a decision worth making at
	     the loadout screen. The cost is that a survivor is never truly out of
	     options, which for a co-op game is the right side to err on. ]]
	Melee = "Melee", -- machete, axe, bat, pipe, knife
	Throwable = "Throwable", -- pipe bomb, molotov, hazardous waste
	Health = "Health", -- medkit, defibrillator
	Pills = "Pills", -- pain pills, adrenaline
})

--[[
	The throwables. Every one of these is placed by hand in the map, in the
	folder MapConfig.MapItems names for it.

	The BILE JAR used to be here and was replaced by the hazardous waste rather
	than joined by it: both put a puddle on the floor that the horde walks to,
	and two items doing that is one item and a copy of it. The waste is the one
	that survived because it is the more interesting of the two — it is placed
	before a wave rather than thrown at one.

	The jar's other half, coating a survivor so the horde comes for the PERSON,
	was never really the item's: it is the Boomer's, and the Boomer still does
	it. See SurvivorService:applyBile.
]]
Enums.Throwable = table.freeze({
	PipeBomb = "PipeBomb",
	Molotov = "Molotov",
	HazardousWaste = "HazardousWaste",
})

Enums.HealthItem = table.freeze({
	Medkit = "Medkit",
	Defibrillator = "Defibrillator",
})

--[[
	Permanent abilities. Unlocked once, equipped before a match, activated during
	one — see Shared/Config/AbilityConfig for the whole argument about how these
	differ from a requisition and from a modifier.

	Ids are stable strings because they are persisted in a player's profile and
	sent over a remote. Renaming one orphans everybody who owned it.
]]
Enums.Ability = table.freeze({
	Shield = "Shield",
	Turret = "Turret",
	FieldMedic = "FieldMedic",
	CryoBlast = "CryoBlast",
	Airstrike = "Airstrike",
})

Enums.PillItem = table.freeze({
	PainPills = "PainPills",
	Adrenaline = "Adrenaline",
})

-- Infected archetypes. Keys must match InfectedConfig keys AND the folder names
-- under ReplicatedStorage.Assets.Infected exactly.
Enums.Infected = table.freeze({
	Common = "Common",

	--[[ The specials, in the order they earn their place. Hunter and Jockey take
	     ONE survivor out of the fight; Charger takes one and scatters the rest;
	     Tongue takes one from across the map; Boomer and Spitter take nobody and
	     are still the two that decide most fights, because they change where the
	     team is allowed to stand.

	     Tongue is the Smoker. The name is not a stylistic choice — Roblox's text
	     filter eats "Smoker" in chat and on any UI string that goes through it,
	     so a special nobody can name is a special nobody can call out. ]]
	Hunter = "Hunter",
	Jockey = "Jockey",
	Charger = "Charger",
	Tongue = "Tongue",
	Boomer = "Boomer",
	Spitter = "Spitter",

	Witch = "Witch",
	Tank = "Tank",
	--[[ Bigger than a Tank and built rather than turned: a mechanical thing on
	     drills. See InfectedConfig for the fight it is meant to be. ]]
	Metallic = "Metallic",
	--[[ The Backrooms' own finale, and the only creature in the roster that
	     belongs to ONE map — see MapConfig.finaleBoss. It attacks the answer none
	     of the other three do: standing still. ]]
	BacteriaMonster = "BacteriaMonster",
})

-- Survivor lifecycle. Drives the HUD, the Director, and revive logic.
Enums.SurvivorState = table.freeze({
	Healthy = "Healthy", -- upright, above the "hurt" threshold
	Hurt = "Hurt", -- upright, below the "hurt" threshold (limping, audible)
	Incapacitated = "Incapacitated", -- downed, firing a pistol, needs a revive
	LedgeHanging = "LedgeHanging", -- hanging off a ledge, needs a pull-up
	Pinned = "Pinned", -- held by a Hunter / Smoker / Charger
	Dead = "Dead", -- awaiting a defib or a closet rescue
	Spectating = "Spectating", -- no character
})

-- What a body part is worth when a bullet lands on it.
Enums.HitRegion = table.freeze({
	Head = "Head",
	Torso = "Torso",
	Arm = "Arm",
	Leg = "Leg",
})

Enums.DamageType = table.freeze({
	Bullet = "Bullet",
	Pellet = "Pellet",
	Melee = "Melee",
	Explosive = "Explosive",
	Fire = "Fire",
	Falling = "Falling",
	Special = "Special", -- special-infected attacks (claw, pummel, tongue)
	Environment = "Environment",
})

-- What happened to a body when it died. Drives GoreService's response.
Enums.GoreLevel = table.freeze({
	None = "None", -- clean kill, plain ragdoll
	Dismember = "Dismember", -- one or more limbs detached
	Gib = "Gib", -- torso destroyed, body replaced with chunks
	Incinerate = "Incinerate", -- burned down, charred ragdoll
})

-- The AI Director's pacing state machine. This is the heart of L4D pacing.
Enums.PacingState = table.freeze({
	Relax = "Relax", -- deliberately quiet; lets the team breathe and heal
	BuildUp = "BuildUp", -- trickling pressure, wandering commons
	SustainPeak = "SustainPeak", -- full horde / boss engagement
	PeakFade = "PeakFade", -- pressure released, stragglers only
})

-- Overall run state.
Enums.RoundState = table.freeze({
	Lobby = "Lobby",
	Starting = "Starting",
	InProgress = "InProgress",
	TeamWipe = "TeamWipe",
	Victory = "Victory",
})

Enums.Team = table.freeze({
	Survivor = "Survivor",
	Infected = "Infected",
})

return table.freeze(Enums)
