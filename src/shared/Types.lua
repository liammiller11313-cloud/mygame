--!strict
--[[
	Types — the shapes that cross system boundaries.

	Damage is the busiest interface in the game: the ballistics code produces it,
	the damage funnel transforms it, the gore system reads it, the HUD reacts to
	it, and every special infected contributes to it. Declaring the shapes once,
	here, is what keeps eight subsystems agreeing on what a hit is.
]]

local Types = {}

--[[
	Everything known about an incoming hit at the moment it is applied.

	`attacker` is nil for environmental damage and for infected attacks; in the
	latter case `attackerModel` is set instead. Both nil means the world did it
	(falling, fire with no owner), which is legal and must not crash anything.
]]
export type DamageContext = {
	attacker: Player?,
	attackerModel: Model?,
	weaponId: string?,
	damageType: string, -- Enums.DamageType
	region: string, -- Enums.HitRegion
	hitPart: BasePart?,
	hitPosition: Vector3,
	hitNormal: Vector3,
	direction: Vector3, -- unit vector along the shot's travel
	distance: number,
	piercedCount: number, -- how many bodies this round already passed through
	isFriendlyFire: boolean,
}

--[[ What the damage funnel decided. Returned by every damage entry point. ]]
export type DamageResult = {
	dealt: number,
	blocked: boolean, -- true when the hit was rejected before any damage
	killed: boolean,
	overkill: number, -- damage past zero, drives the gore roll
	goreLevel: string, -- Enums.GoreLevel
	severedPart: string?, -- set only when goreLevel is Dismember
	remainingHealth: number,
}

--[[ One resolved impact from a single trigger pull. A shotgun blast produces
     up to `pellets` of these; the client turns them into hitmarker feedback. ]]
export type HitRecord = {
	model: Model,
	part: BasePart,
	position: Vector3,
	normal: Vector3,
	distance: number,
	region: string,
	result: DamageResult,
}

--[[ A survivor's carried equipment, mirrored into attributes for the HUD. ]]
export type Loadout = {
	[string]: {
		itemId: string,
		ammo: number,
		reserve: number,
	}?,
}

--[[ Options handed to the Director's spawn placement search. ]]
export type SpawnOptions = {
	minDistance: number,
	maxDistance: number,
	requireOutOfSight: boolean,
	minFlowAhead: number?,
	maxFlowAhead: number?,
	attempts: number?,
	anchor: Vector3?, -- search around this point instead of the survivors
}

--[[ A builder for a DamageContext that fills in the boring fields. Every call
     site was otherwise writing the same eight defaults by hand and getting
     `piercedCount` wrong. ]]
function Types.newDamageContext(overrides: { [string]: any }?): DamageContext
	local context: DamageContext = {
		attacker = nil,
		attackerModel = nil,
		weaponId = nil,
		damageType = "Bullet",
		region = "Torso",
		hitPart = nil,
		hitPosition = Vector3.zero,
		hitNormal = Vector3.yAxis,
		direction = Vector3.zero,
		distance = 0,
		piercedCount = 0,
		isFriendlyFire = false,
	}

	if overrides then
		for key, value in overrides do
			(context :: any)[key] = value
		end
	end
	return context
end

--[[ The result every rejected hit should return, so callers never branch on nil. ]]
function Types.blockedResult(remainingHealth: number?): DamageResult
	return {
		dealt = 0,
		blocked = true,
		killed = false,
		overkill = 0,
		goreLevel = "None",
		severedPart = nil,
		remainingHealth = remainingHealth or 0,
	}
end

return Types
