--!strict
--[[
	GameConfig — global rules that are not weapon-specific or enemy-specific.

	Survivor health, revive timings, friendly fire, and the hit-region multipliers
	that make headshots the point of the game.
]]

local Enums = require(script.Parent.Parent.Enums)

local GameConfig = {}

GameConfig.MaxSurvivors = 4
GameConfig.RespawnClosetsEnabled = true

--[[
	Damage multiplier per body region. The 4x head is the number that makes the
	whole combat loop work: it means a careful player kills a Common in one shot
	with anything, and a careless one burns a magazine on the same crowd.
]]
GameConfig.HitRegionMultipliers = table.freeze({
	[Enums.HitRegion.Head] = 4.0,
	[Enums.HitRegion.Torso] = 1.0,
	[Enums.HitRegion.Arm] = 0.72,
	[Enums.HitRegion.Leg] = 0.78,
})

--[[
	Maps Roblox rig part names onto hit regions. Covers R6 and R15 so the combat
	code never has to care which rig type a model uses. Anything not listed here
	falls back to Torso, which is the safe, unsurprising default.
]]
GameConfig.PartRegions = table.freeze({
	Head = Enums.HitRegion.Head,
	UpperTorso = Enums.HitRegion.Torso,
	LowerTorso = Enums.HitRegion.Torso,
	Torso = Enums.HitRegion.Torso,
	HumanoidRootPart = Enums.HitRegion.Torso,

	LeftUpperArm = Enums.HitRegion.Arm,
	LeftLowerArm = Enums.HitRegion.Arm,
	LeftHand = Enums.HitRegion.Arm,
	RightUpperArm = Enums.HitRegion.Arm,
	RightLowerArm = Enums.HitRegion.Arm,
	RightHand = Enums.HitRegion.Arm,
	["Left Arm"] = Enums.HitRegion.Arm,
	["Right Arm"] = Enums.HitRegion.Arm,

	LeftUpperLeg = Enums.HitRegion.Leg,
	LeftLowerLeg = Enums.HitRegion.Leg,
	LeftFoot = Enums.HitRegion.Leg,
	RightUpperLeg = Enums.HitRegion.Leg,
	RightLowerLeg = Enums.HitRegion.Leg,
	RightFoot = Enums.HitRegion.Leg,
	["Left Leg"] = Enums.HitRegion.Leg,
	["Right Leg"] = Enums.HitRegion.Leg,
})

--[[ Survivor health model, lifted from L4D2 because it is very well balanced. ]]
GameConfig.Survivor = table.freeze({
	MaxHealth = 100,
	StartHealth = 100,

	-- Below this you limp, breathe hard, and every infected can hear you.
	HurtThreshold = 40,
	LimpWalkSpeed = 11,
	NormalWalkSpeed = 16,
	SprintSpeed = 22,
	SprintStaminaDrain = 26, -- per second
	SprintStaminaRegen = 18, -- per second
	MaxStamina = 100,

	-- Temp (white) health decays. Pills give a lot that drains; adrenaline gives
	-- less but drains faster and makes everything else quicker.
	PillHealth = 50,
	PillDecayPerSecond = 0.55,
	AdrenalineHealth = 25,
	AdrenalineDecayPerSecond = 1.4,
	AdrenalineDuration = 15,
	AdrenalineSpeedBonus = 1.25,
	AdrenalineUseSpeedBonus = 1.5, -- heals and revives are faster under adrenaline

	MedkitHealPercent = 0.8, -- heals 80% of health missing, like L4D2
	MedkitUseTime = 5.0,
	MedkitAllyUseTime = 5.0,

	-- Incapacitation
	IncapHealth = 300,
	IncapBleedPerSecond = 2.0,
	IncapWeapon = Enums.Weapon.M1911A1,
	ReviveTime = 5.0,
	ReviveHealth = 30, -- temp health you stand up with
	MaxIncapsBeforeDeath = 2, -- the third down kills you
	BlackAndWhiteHealth = 50, -- forced health cap while black & white

	LedgeHangTime = 60,
	LedgeHangDamagePerSecond = 1.0,
	LedgePullTime = 1.0,

	-- Friendly fire. Non-zero on purpose: it is what makes a horde scary in a
	-- doorway. Scaled well below 1 so it punishes carelessness without griefing.
	FriendlyFireMultiplier = 0.25,
	FriendlyFireMeleeMultiplier = 0.0,

	DefibReviveHealth = 50,
	DefibUseTime = 3.0,
	ClosetRescueTime = 1.5,
})

--[[ The shove. L4D's most underrated verb: costs nothing, buys you a second. ]]
GameConfig.Shove = table.freeze({
	Range = 12,
	Arc = 70, -- degrees of cone in front of the player
	Cooldown = 0.55,
	StumbleDuration = 0.9,
	Force = 55,
	MaxTargets = 6,
	FatigueShoves = 4, -- consecutive shoves before the cooldown balloons
	FatigueWindow = 3.0,
	FatigueCooldown = 1.6,
	SelfDamageToPinned = 0, -- shoving a pinned teammate frees, never hurts them
})

--[[ Networked hit validation. The client raycasts for responsiveness and the
     server re-checks; these are the tolerances that keep that honest. ]]
GameConfig.HitValidation = table.freeze({
	MaxRewindTime = 0.25, -- how far back the server will rewind positions
	PositionTolerance = 18, -- studs of slack on a claimed hit position
	MaxShotsPerSecond = 22, -- hard rate cap; above this the shot is dropped
	MaxRangeSlack = 1.15, -- claimed distance may exceed weapon range by this much
	RequireLineOfSight = true,
})

GameConfig.Interaction = table.freeze({
	Range = 14,
	PickupRange = 10,
})

GameConfig.Corpses = table.freeze({
	MaxRagdolls = 26, -- oldest is recycled past this; keeps the framerate honest
	MaxGibs = 90,
	MaxBloodDecals = 160,
})

return table.freeze(GameConfig)
