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
	-- Secondary
	M1911A1 = "M1911A1",
	Magnum357 = "Magnum357",
	Machete = "Machete",

	-- Primary: shotgun
	Shotgun = "Shotgun",

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

	-- Primary: marksman
	ScopedMk18 = "ScopedMk18",
	M1AEBR = "M1AEBR",
})

-- Inventory slot. A survivor holds exactly one item per slot, L4D2 style.
Enums.Slot = table.freeze({
	Primary = "Primary", -- rifles, shotguns, SMGs
	Secondary = "Secondary", -- pistols, melee
	Throwable = "Throwable", -- pipe bomb, molotov, bile
	Health = "Health", -- medkit, defibrillator
	Pills = "Pills", -- pain pills, adrenaline
})

Enums.Throwable = table.freeze({
	PipeBomb = "PipeBomb",
	Molotov = "Molotov",
	BileJar = "BileJar",
})

Enums.HealthItem = table.freeze({
	Medkit = "Medkit",
	Defibrillator = "Defibrillator",
})

Enums.PillItem = table.freeze({
	PainPills = "PainPills",
	Adrenaline = "Adrenaline",
})

-- Infected archetypes. Keys must match InfectedConfig keys AND the folder names
-- under ReplicatedStorage.Assets.Infected exactly.
Enums.Infected = table.freeze({
	Common = "Common",
	Hunter = "Hunter",
	Jockey = "Jockey",
	Rusher = "Rusher",
	Witch = "Witch",
	Tank = "Tank",
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
