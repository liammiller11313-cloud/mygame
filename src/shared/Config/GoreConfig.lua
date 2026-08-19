--!strict
--[[
	GoreConfig — how bodies come apart.

	This is the payoff system. Everything else in the combat loop exists to lead
	up to the quarter-second after a trigger pull, and this file decides what
	happens in it.

	Three escalating outcomes, chosen by how much damage landed relative to what
	the target had left:

	  Clean kill   the body ragdolls, takes an impulse along the bullet, bleeds
	  Dismember    the struck limb detaches, spurts, and tumbles separately
	  Gib          the body is replaced by chunks and a burst of blood

	The roll that picks between them is deliberately weighted toward the weapon
	that earned it: a point-blank shotgun blast should gib, a pistol round to the
	shin should not, and the player should be able to feel the difference without
	ever being told the rule.
]]

local Enums = require(script.Parent.Parent.Enums)

local GoreConfig = {}

GoreConfig.Enabled = true

--[[
	The gore roll:
	    score = overkillRatio * OverkillWeight
	          + weapon.gibPower * WeaponGibWeight
	          + regionBonus
	          + contactBonus        (added when the shot was inside ContactRange)
	    gib       when score >= GibScore
	    dismember when score >= DismemberScore and the region is a limb or head
	    otherwise a clean ragdoll kill

	`overkillRatio` is (damage dealt - health remaining) / maxHealth, so hitting a
	Common for 300 with a machete reads as enormous overkill and takes the head
	clean off, while chipping the last 2 HP off a Tank does not.
]]
GoreConfig.Scoring = table.freeze({
	OverkillWeight = 0.55,
	WeaponGibWeight = 0.75,
	ContactRange = 22,
	ContactBonus = 0.35,

	GibScore = 1.15,
	DismemberScore = 0.45,

	RegionBonus = {
		[Enums.HitRegion.Head] = 0.40,
		[Enums.HitRegion.Torso] = 0.15,
		[Enums.HitRegion.Arm] = 0.25,
		[Enums.HitRegion.Leg] = 0.25,
	},

	-- An explosion always gibs whatever it kills, no roll required.
	ExplosiveAlwaysGibs = true,
	-- Fire never gibs; a burned body should stay recognisably a body.
	FireNeverGibs = true,
})

--[[ Which rig parts may be severed, and what stays attached to what. Severing a
     parent takes its children with it: blowing off an upper arm takes the whole
     arm, which is what a player expects and what looks right. ]]
GoreConfig.Dismemberment = table.freeze({
	Severable = {
		"Head",
		"LeftUpperArm",
		"LeftLowerArm",
		"LeftHand",
		"RightUpperArm",
		"RightLowerArm",
		"RightHand",
		"LeftUpperLeg",
		"LeftLowerLeg",
		"LeftFoot",
		"RightUpperLeg",
		"RightLowerLeg",
		"RightFoot",
		-- R6 equivalents
		"Left Arm",
		"Right Arm",
		"Left Leg",
		"Right Leg",
	},

	-- Cutting a part off also frees everything downstream of it.
	Children = {
		LeftUpperArm = { "LeftLowerArm", "LeftHand" },
		LeftLowerArm = { "LeftHand" },
		RightUpperArm = { "RightLowerArm", "RightHand" },
		RightLowerArm = { "RightHand" },
		LeftUpperLeg = { "LeftLowerLeg", "LeftFoot" },
		LeftLowerLeg = { "LeftFoot" },
		RightUpperLeg = { "RightLowerLeg", "RightFoot" },
		RightLowerLeg = { "RightFoot" },
	},

	-- A decapitation is always lethal, whatever the damage arithmetic said.
	DecapitationIsLethal = true,
	LimbLifetime = 14,
	LimbImpulse = 26,
	LimbSpin = 14,
})

--[[ Gibbing. The body is hidden and replaced with chunks thrown along the shot
     direction, with enough randomness that no two gibs read as identical. ]]
GoreConfig.Gibs = table.freeze({
	CountMin = 5,
	CountMax = 9,
	SizeMin = 0.35,
	SizeMax = 1.15,
	Lifetime = 12,
	ImpulseMin = 22,
	ImpulseMax = 58,
	UpwardBias = 0.45,
	SpinMax = 30,
	Color = Color3.fromRGB(122, 26, 26),
	CollideWithPlayers = false, -- gibs are decoration; never let them shove you
})

--[[ Blood. Split into three layers that read at different distances: a spray you
     see at the moment of impact, a mist that hangs for an instant, and a decal
     that stays on the wall so the room remembers the fight. ]]
GoreConfig.Blood = table.freeze({
	Color = Color3.fromRGB(104, 16, 16),
	DarkColor = Color3.fromRGB(58, 8, 8),

	SprayParticles = 14,
	SpraySpeed = 34,
	SpraySpread = 26, -- degrees around the surface normal
	SprayLifetime = 0.55,

	MistParticles = 8,
	MistLifetime = 0.9,
	MistSize = 1.8,

	-- Decals are sprayed onto whatever is behind the target, along the shot line.
	DecalEnabled = true,
	DecalMaxDistance = 20,
	DecalSizeMin = 1.2,
	DecalSizeMax = 4.5,
	DecalLifetime = 45,
	DecalFadeTime = 6,
	DecalChanceOnHit = 0.55,
	DecalChanceOnKill = 1.0,

	-- Pooling under a body that has stopped moving.
	PoolEnabled = true,
	PoolGrowTime = 2.5,
	PoolMaxSize = 6.5,
})

--[[ Screen-space feedback for the player who is being hit, not the one shooting.
     Kept restrained; a full-screen red wash every time a Common connects makes
     the game unreadable exactly when reading it matters most. ]]
GoreConfig.ScreenBlood = table.freeze({
	Enabled = true,
	DropletsPerHit = 3,
	MaxDroplets = 14,
	FadeTime = 4.0,
	BoomerBileFadeTime = 12.0,
})

--[[ Hit-stop: the single cheapest trick in the satisfaction toolbox. Freezing
     everything for two frames on a kill makes the kill land physically. ]]
GoreConfig.HitStop = table.freeze({
	Enabled = true,
	NormalHitSeconds = 0.0,
	KillSeconds = 0.035,
	HeadshotKillSeconds = 0.06,
	GibSeconds = 0.09,
	BossHitSeconds = 0.02,
	TimeScale = 0.06, -- how far the world slows during the freeze
})

--[[ Performance ceilings. Gore is the first thing to blow a frame budget, and a
     zombie game that stutters during a horde has failed at the one moment it
     needed to hold up. These caps are not optional. ]]
GoreConfig.Budget = table.freeze({
	MaxActiveGibs = 90,
	MaxActiveLimbs = 40,
	MaxActiveDecals = 160,
	MaxActiveRagdolls = 26,
	MaxGoreEventsPerSecond = 26, -- server-side throttle during a full horde
	CullDistance = 260, -- gore beyond this is never sent to a client
})

--[[
	The ceilings above are what a desktop can push. A phone cannot.

	Ninety loose gibs, forty limbs and a hundred and sixty blood decals is a lot
	of draw calls and a lot of physics bodies, and on a handset it is the single
	most likely thing to take the frame rate down during exactly the moment the
	game is trying to be exciting. Gore that arrives at fifteen frames a second is
	not more gore, it is less game.

	Scaled per client rather than lowered for everyone: the desktop numbers are
	the ones the effect was designed around and there is no reason to spend them.
	Console sits in between — fixed hardware, real GPU, but a shared memory budget
	and a player sitting three metres from the screen who will not miss the
	hundred and sixtieth decal.

	The event throttle and the cull distance are deliberately NOT scaled. Both are
	server-side decisions about what to SEND, and one client's hardware cannot be
	allowed to change what every other client receives.
]]
GoreConfig.BudgetScale = table.freeze({
	Desktop = 1.0,
	Console = 0.7,
	Mobile = 0.4,
})

--[[
	The client-side ceilings for a device class.

	Gibs and decals only, deliberately. Limbs and ragdolls are counted on the
	SERVER — they are physics bodies every client shares — so there is no
	per-device version of them to return, and offering one here would be a number
	that looked authoritative and changed nothing.

	Floored rather than merely scaled, so even the smallest device still shows
	gore instead of a clean kill. The entire point of the system is that killing
	is satisfying; a budget that rounded toward zero would quietly delete the
	feature on the platform with the most players.
]]
function GoreConfig.budgetFor(deviceClass: string): { gibs: number, decals: number }
	local scale = GoreConfig.BudgetScale[deviceClass] or 1.0
	return {
		gibs = math.max(math.floor(GoreConfig.Budget.MaxActiveGibs * scale), 12),
		decals = math.max(math.floor(GoreConfig.Budget.MaxActiveDecals * scale), 24),
	}
end

return table.freeze(GoreConfig)
