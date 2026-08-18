--!strict
--[[
	WeaponConfig — every number that decides how a gun feels.

	Sixteen weapons, each tuned individually rather than dropped into an
	archetype. An AKM kicks harder than an AK-12, a Vector barely climbs at all,
	a PPSh-41 empties seventy-one rounds in four seconds and you feel every one
	of them. That per-gun identity is the whole reason to carry real models.

	Nothing about weapon behaviour is hard-coded anywhere else. Adding a weapon
	is: add a key to Enums.Weapon, add a block here, drop the model into
	ReplicatedStorage.Assets.Weapons. No new code.

	── MODEL NAMES ──────────────────────────────────────────────────────────────
	`modelName` is the literal name of the model in ReplicatedStorage.Assets.
	It is separate from the key because Roblox model names contain spaces, dots
	and parentheses that cannot be Luau identifiers — so the code says
	`AKS74U` and the artist keeps their file called "AKS-74U".

	── UNITS ────────────────────────────────────────────────────────────────────
	  damage        health removed by a torso hit at point-blank range
	  rpm           rounds per minute; fire delay is 60/rpm
	  spread        degrees of cone half-angle
	  recoil        degrees of camera kick
	  range         studs (roughly 28cm each at Roblox humanoid scale)
	  times         seconds

	── THE NUMBERS THAT MATTER ──────────────────────────────────────────────────
	A Common has 50 health, so `damage` reads directly as a shots-to-kill count,
	and that is how these are balanced:
	    marksman rifles   1 body shot
	    assault rifles    2 body shots
	    SMGs              3 body shots
	    the shotgun       1 blast, and it takes the body apart
	Every weapon kills a Common in ONE headshot regardless, because
	InfectedConfig.Common.headshotAlwaysKills is true. That rule is the game:
	it is what makes a horde readable instead of spongy, and it is worth more
	than any damage number in this file.

	── HOW DAMAGE IS COMPUTED ───────────────────────────────────────────────────
	  final = damage
	          * regionMultiplier      (GameConfig.HitRegionMultipliers, head 4x)
	          * falloffMultiplier     (lerped between falloffStart and falloffEnd)
	          * penetrationFalloff ^ (bodies already passed through)
]]

local Enums = require(script.Parent.Parent.Enums)

export type FireMode = "Semi" | "Auto" | "Pump" | "Melee"
export type WeaponClass = "Pistol" | "SMG" | "Rifle" | "Marksman" | "Shotgun" | "Melee"

export type WeaponDefinition = {
	id: string,
	displayName: string,
	modelName: string, -- name in ReplicatedStorage.Assets.Weapons / .Viewmodels
	slot: string,
	class: WeaponClass,
	fireMode: FireMode,

	damage: number,
	rpm: number,
	pellets: number, -- >1 turns the shot into a shotgun blast
	magSize: number,
	reserveMax: number, -- -1 means effectively infinite
	penetration: number, -- bodies one round passes through
	penetrationFalloff: number, -- damage retained per body pierced

	falloffStart: number,
	falloffEnd: number,
	falloffMin: number,
	maxRange: number,

	spreadHip: number,
	spreadAim: number,
	spreadMoving: number,
	spreadMax: number,
	bloomPerShot: number,
	bloomRecovery: number,

	recoilVertical: number,
	recoilHorizontal: number,
	recoilRecovery: number,
	kickback: number,

	reloadTime: number,
	reloadPerShell: number, -- >0 means shell-by-shell, interruptible by firing
	drawTime: number,
	aimTime: number,

	walkSpeedScale: number,
	aimWalkSpeedScale: number,
	aimFov: number,

	shakeMagnitude: number,
	shakeRoughness: number,
	tracerWidth: number,
	tracerColor: Color3,
	muzzleFlashSize: number,
	shellEject: boolean,

	gibPower: number,
	dismemberPower: number,
	knockback: number,
}

local WHITE_HOT = Color3.fromRGB(255, 236, 190)
local AMBER = Color3.fromRGB(255, 196, 92)

local WeaponConfig = {}

--[[
	Every weapon in the game. Iterate this table, never the module itself — the
	module also carries helper functions and mixing the two is how you end up
	reading `.damage` off a function.
]]
WeaponConfig.Definitions = {

	--[[ The sidearm everyone starts with. .45 ACP means two body shots on a
	     Common where a 9mm would take three, and the seven-round magazine is
	     what stops that from being strictly better than a primary. ]]
	[Enums.Weapon.M1911A1] = {
		id = Enums.Weapon.M1911A1,
		displayName = "M1911A1",
		modelName = "M1911A1",
		slot = Enums.Slot.Secondary,
		class = "Pistol",
		fireMode = "Semi",

		damage = 28,
		rpm = 400,
		pellets = 1,
		magSize = 8,
		reserveMax = -1,
		penetration = 1,
		penetrationFalloff = 0.5,

		falloffStart = 110,
		falloffEnd = 400,
		falloffMin = 0.55,
		maxRange = 900,

		spreadHip = 1.5,
		spreadAim = 0.3,
		spreadMoving = 0.9,
		spreadMax = 5.0,
		bloomPerShot = 0.6,
		bloomRecovery = 4.8,

		recoilVertical = 1.35,
		recoilHorizontal = 0.4,
		recoilRecovery = 9.0,
		kickback = 0.16,

		reloadTime = 1.7,
		reloadPerShell = 0,
		drawTime = 0.35,
		aimTime = 0.18,

		walkSpeedScale = 1.0,
		aimWalkSpeedScale = 0.72,
		aimFov = 62,

		shakeMagnitude = 0.65,
		shakeRoughness = 8,
		tracerWidth = 0.055,
		tracerColor = WHITE_HOT,
		muzzleFlashSize = 1.05,
		shellEject = true,

		gibPower = 0.08,
		dismemberPower = 0.3,
		knockback = 14,
	},

	--[[ Six rounds, and every one of them removes a Common from the world.
	     The trade is a two-second reload and recoil that throws your aim off
	     the target entirely — you do not spray a Magnum, you place it. ]]
	[Enums.Weapon.Magnum357] = {
		id = Enums.Weapon.Magnum357,
		displayName = ".357 Magnum",
		modelName = ".357 Magnum",
		slot = Enums.Slot.Secondary,
		class = "Pistol",
		fireMode = "Semi",

		damage = 68,
		rpm = 200,
		pellets = 1,
		magSize = 6,
		reserveMax = -1,
		penetration = 2,
		penetrationFalloff = 0.65,

		falloffStart = 180,
		falloffEnd = 520,
		falloffMin = 0.7,
		maxRange = 1100,

		spreadHip = 2.4,
		spreadAim = 0.2,
		spreadMoving = 1.2,
		spreadMax = 7.0,
		bloomPerShot = 1.6,
		bloomRecovery = 5.0,

		recoilVertical = 4.0,
		recoilHorizontal = 0.9,
		recoilRecovery = 6.5,
		kickback = 0.48,

		reloadTime = 2.4,
		reloadPerShell = 0,
		drawTime = 0.45,
		aimTime = 0.22,

		walkSpeedScale = 1.0,
		aimWalkSpeedScale = 0.7,
		aimFov = 58,

		shakeMagnitude = 2.0,
		shakeRoughness = 11,
		tracerWidth = 0.09,
		tracerColor = WHITE_HOT,
		muzzleFlashSize = 1.8,
		shellEject = true,

		gibPower = 0.4,
		dismemberPower = 0.85,
		knockback = 38,
	},

	--[[ The gore weapon. Ten pellets at contact range does not kill a Common,
	     it disassembles one. Falls off to almost nothing past a corridor's
	     length, which is exactly the trade it should make. Reloads shell by
	     shell, and firing mid-reload keeps whatever you already loaded — that
	     interruptibility is a real tactical decision under pressure. ]]
	[Enums.Weapon.Shotgun] = {
		id = Enums.Weapon.Shotgun,
		displayName = "Shotgun",
		modelName = "Shotgun",
		slot = Enums.Slot.Primary,
		class = "Shotgun",
		fireMode = "Pump",

		damage = 23,
		rpm = 75,
		pellets = 10,
		magSize = 8,
		reserveMax = 128,
		penetration = 2,
		penetrationFalloff = 0.55,

		falloffStart = 35,
		falloffEnd = 150,
		falloffMin = 0.18,
		maxRange = 260,

		spreadHip = 4.6,
		spreadAim = 3.4,
		spreadMoving = 0.8,
		spreadMax = 7.0,
		bloomPerShot = 0.6,
		bloomRecovery = 6.0,

		recoilVertical = 4.8,
		recoilHorizontal = 0.95,
		recoilRecovery = 6.5,
		kickback = 0.62,

		reloadTime = 0.7,
		reloadPerShell = 0.42,
		drawTime = 0.6,
		aimTime = 0.26,

		walkSpeedScale = 0.94,
		aimWalkSpeedScale = 0.66,
		aimFov = 66,

		shakeMagnitude = 2.5,
		shakeRoughness = 10,
		tracerWidth = 0.04,
		tracerColor = AMBER,
		muzzleFlashSize = 2.2,
		shellEject = true,

		gibPower = 1.0,
		dismemberPower = 1.0,
		knockback = 64,
	},

	--[[ Seventy-one rounds at a thousand a minute. It empties in four seconds
	     and it is glorious. Individually the weakest round in the game; the
	     answer to being surrounded is simply to hold the trigger down. ]]
	[Enums.Weapon.PPSh41] = {
		id = Enums.Weapon.PPSh41,
		displayName = "PPSh-41",
		modelName = "(71 Mag) PPSh-41",
		slot = Enums.Slot.Primary,
		class = "SMG",
		fireMode = "Auto",

		damage = 17,
		rpm = 1000,
		pellets = 1,
		magSize = 71,
		reserveMax = 426,
		penetration = 1,
		penetrationFalloff = 0.5,

		falloffStart = 80,
		falloffEnd = 300,
		falloffMin = 0.42,
		maxRange = 650,

		spreadHip = 2.4,
		spreadAim = 1.0,
		spreadMoving = 1.5,
		spreadMax = 8.5,
		bloomPerShot = 0.32,
		bloomRecovery = 7.5,

		recoilVertical = 0.55,
		recoilHorizontal = 0.5,
		recoilRecovery = 13.0,
		kickback = 0.09,

		reloadTime = 2.6,
		reloadPerShell = 0,
		drawTime = 0.5,
		aimTime = 0.22,

		walkSpeedScale = 0.97,
		aimWalkSpeedScale = 0.7,
		aimFov = 64,

		shakeMagnitude = 0.4,
		shakeRoughness = 14,
		tracerWidth = 0.05,
		tracerColor = AMBER,
		muzzleFlashSize = 0.95,
		shellEject = true,

		gibPower = 0.04,
		dismemberPower = 0.18,
		knockback = 8,
	},

	--[[ The Vector's real party trick is that its action drives the recoil
	     downward, so it barely climbs. Fastest cyclic rate in the game and the
	     easiest to hold on a target — paid for with a thirty-round magazine
	     that lasts about a second and a half. ]]
	[Enums.Weapon.KrissVector] = {
		id = Enums.Weapon.KrissVector,
		displayName = "Kriss Vector .45",
		modelName = "Kriss Vector .45",
		slot = Enums.Slot.Primary,
		class = "SMG",
		fireMode = "Auto",

		damage = 19,
		rpm = 1100,
		pellets = 1,
		magSize = 30,
		reserveMax = 390,
		penetration = 1,
		penetrationFalloff = 0.5,

		falloffStart = 75,
		falloffEnd = 280,
		falloffMin = 0.42,
		maxRange = 620,

		spreadHip = 2.0,
		spreadAim = 0.7,
		spreadMoving = 1.3,
		spreadMax = 6.5,
		bloomPerShot = 0.3,
		bloomRecovery = 8.0,

		recoilVertical = 0.34,
		recoilHorizontal = 0.44,
		recoilRecovery = 15.0,
		kickback = 0.07,

		reloadTime = 2.1,
		reloadPerShell = 0,
		drawTime = 0.42,
		aimTime = 0.18,

		walkSpeedScale = 0.99,
		aimWalkSpeedScale = 0.72,
		aimFov = 64,

		shakeMagnitude = 0.35,
		shakeRoughness = 15,
		tracerWidth = 0.05,
		tracerColor = AMBER,
		muzzleFlashSize = 0.85,
		shellEject = true,

		gibPower = 0.05,
		dismemberPower = 0.2,
		knockback = 9,
	},

	--[[ Tiny, fast and extremely controllable. The lowest damage per round of
	     anything here, which makes it the weapon you pick when you would
	     rather never miss than ever hit hard. ]]
	[Enums.Weapon.MP7A1] = {
		id = Enums.Weapon.MP7A1,
		displayName = "MP7A1",
		modelName = "MP7A1",
		slot = Enums.Slot.Primary,
		class = "SMG",
		fireMode = "Auto",

		damage = 16,
		rpm = 950,
		pellets = 1,
		magSize = 40,
		reserveMax = 480,
		penetration = 1,
		penetrationFalloff = 0.5,

		falloffStart = 70,
		falloffEnd = 260,
		falloffMin = 0.4,
		maxRange = 600,

		spreadHip = 1.9,
		spreadAim = 0.65,
		spreadMoving = 1.2,
		spreadMax = 6.0,
		bloomPerShot = 0.28,
		bloomRecovery = 8.5,

		recoilVertical = 0.42,
		recoilHorizontal = 0.34,
		recoilRecovery = 14.0,
		kickback = 0.07,

		reloadTime = 2.0,
		reloadPerShell = 0,
		drawTime = 0.4,
		aimTime = 0.16,

		walkSpeedScale = 1.0,
		aimWalkSpeedScale = 0.74,
		aimFov = 64,

		shakeMagnitude = 0.3,
		shakeRoughness = 15,
		tracerWidth = 0.045,
		tracerColor = AMBER,
		muzzleFlashSize = 0.8,
		shellEject = true,

		gibPower = 0.03,
		dismemberPower = 0.16,
		knockback = 7,
	},

	--[[ The SMG for people who want a rifle. Slow for its class, heavy per
	     round, and the .45 hits hard enough that three shots drop a Common
	     with room to spare. Kicks noticeably more than its siblings. ]]
	[Enums.Weapon.UMP45] = {
		id = Enums.Weapon.UMP45,
		displayName = "UMP-45",
		modelName = "UMP-45",
		slot = Enums.Slot.Primary,
		class = "SMG",
		fireMode = "Auto",

		damage = 24,
		rpm = 600,
		pellets = 1,
		magSize = 25,
		reserveMax = 325,
		penetration = 1,
		penetrationFalloff = 0.55,

		falloffStart = 95,
		falloffEnd = 330,
		falloffMin = 0.5,
		maxRange = 700,

		spreadHip = 2.2,
		spreadAim = 0.75,
		spreadMoving = 1.4,
		spreadMax = 7.0,
		bloomPerShot = 0.45,
		bloomRecovery = 6.5,

		recoilVertical = 0.95,
		recoilHorizontal = 0.45,
		recoilRecovery = 10.0,
		kickback = 0.15,

		reloadTime = 2.3,
		reloadPerShell = 0,
		drawTime = 0.48,
		aimTime = 0.2,

		walkSpeedScale = 0.97,
		aimWalkSpeedScale = 0.7,
		aimFov = 63,

		shakeMagnitude = 0.7,
		shakeRoughness = 12,
		tracerWidth = 0.055,
		tracerColor = AMBER,
		muzzleFlashSize = 1.1,
		shellEject = true,

		gibPower = 0.09,
		dismemberPower = 0.3,
		knockback = 13,
	},

	--[[ A rifle cut down until it stopped behaving like one. Loud, blasty,
	     wildly inaccurate past twenty metres, and completely at home in a
	     stairwell. Sits between the SMGs and the rifles on purpose. ]]
	[Enums.Weapon.AKS74U] = {
		id = Enums.Weapon.AKS74U,
		displayName = "AKS-74U",
		modelName = "AKS-74U",
		slot = Enums.Slot.Primary,
		class = "SMG",
		fireMode = "Auto",

		damage = 25,
		rpm = 700,
		pellets = 1,
		magSize = 30,
		reserveMax = 330,
		penetration = 1,
		penetrationFalloff = 0.55,

		falloffStart = 85,
		falloffEnd = 290,
		falloffMin = 0.45,
		maxRange = 700,

		spreadHip = 3.0,
		spreadAim = 0.95,
		spreadMoving = 1.8,
		spreadMax = 8.0,
		bloomPerShot = 0.6,
		bloomRecovery = 6.0,

		recoilVertical = 1.25,
		recoilHorizontal = 0.6,
		recoilRecovery = 9.0,
		kickback = 0.2,

		reloadTime = 2.4,
		reloadPerShell = 0,
		drawTime = 0.5,
		aimTime = 0.22,

		walkSpeedScale = 0.96,
		aimWalkSpeedScale = 0.68,
		aimFov = 62,

		shakeMagnitude = 0.95,
		shakeRoughness = 12,
		tracerWidth = 0.06,
		tracerColor = AMBER,
		muzzleFlashSize = 1.6,
		shellEject = true,

		gibPower = 0.1,
		dismemberPower = 0.35,
		knockback = 15,
	},

	--[[ The reference weapon. Nothing about it is best in class, which is the
	     point — it is the gun you can hold for a whole round without ever
	     regretting it, and every other rifle here is described by how it
	     differs from this one. ]]
	[Enums.Weapon.M4A1] = {
		id = Enums.Weapon.M4A1,
		displayName = "M4A1",
		modelName = "M4A1",
		slot = Enums.Slot.Primary,
		class = "Rifle",
		fireMode = "Auto",

		damage = 28,
		rpm = 750,
		pellets = 1,
		magSize = 30,
		reserveMax = 330,
		penetration = 2,
		penetrationFalloff = 0.6,

		falloffStart = 200,
		falloffEnd = 600,
		falloffMin = 0.62,
		maxRange = 1200,

		spreadHip = 2.5,
		spreadAim = 0.4,
		spreadMoving = 1.5,
		spreadMax = 6.5,
		bloomPerShot = 0.4,
		bloomRecovery = 6.5,

		recoilVertical = 0.95,
		recoilHorizontal = 0.38,
		recoilRecovery = 10.5,
		kickback = 0.17,

		reloadTime = 2.5,
		reloadPerShell = 0,
		drawTime = 0.5,
		aimTime = 0.22,

		walkSpeedScale = 0.96,
		aimWalkSpeedScale = 0.68,
		aimFov = 60,

		shakeMagnitude = 0.85,
		shakeRoughness = 12,
		tracerWidth = 0.06,
		tracerColor = WHITE_HOT,
		muzzleFlashSize = 1.25,
		shellEject = true,

		gibPower = 0.12,
		dismemberPower = 0.45,
		knockback = 17,
	},

	--[[ The M4 with the corners sharpened: a hundred more rounds a minute and
	     a little more climb to pay for it. Rewards short controlled bursts
	     over holding the trigger. ]]
	[Enums.Weapon.HK416A5] = {
		id = Enums.Weapon.HK416A5,
		displayName = "HK416A5",
		modelName = "HK416A5",
		slot = Enums.Slot.Primary,
		class = "Rifle",
		fireMode = "Auto",

		damage = 27,
		rpm = 850,
		pellets = 1,
		magSize = 30,
		reserveMax = 330,
		penetration = 2,
		penetrationFalloff = 0.6,

		falloffStart = 195,
		falloffEnd = 580,
		falloffMin = 0.62,
		maxRange = 1150,

		spreadHip = 2.5,
		spreadAim = 0.4,
		spreadMoving = 1.5,
		spreadMax = 6.8,
		bloomPerShot = 0.42,
		bloomRecovery = 6.8,

		recoilVertical = 1.05,
		recoilHorizontal = 0.42,
		recoilRecovery = 10.0,
		kickback = 0.18,

		reloadTime = 2.4,
		reloadPerShell = 0,
		drawTime = 0.48,
		aimTime = 0.21,

		walkSpeedScale = 0.96,
		aimWalkSpeedScale = 0.68,
		aimFov = 60,

		shakeMagnitude = 0.85,
		shakeRoughness = 13,
		tracerWidth = 0.06,
		tracerColor = WHITE_HOT,
		muzzleFlashSize = 1.25,
		shellEject = true,

		gibPower = 0.12,
		dismemberPower = 0.45,
		knockback = 17,
	},

	--[[ Ten inches of barrel. Handles like an SMG, hits like a rifle, and
	     gives all of it back at range — the falloff starts less than half as
	     far out as the M4's. Best rifle in the building, worst in the street. ]]
	[Enums.Weapon.Mk18CQBR] = {
		id = Enums.Weapon.Mk18CQBR,
		displayName = "Mk 18 CQBR",
		modelName = "Mk 18 CQBR",
		slot = Enums.Slot.Primary,
		class = "Rifle",
		fireMode = "Auto",

		damage = 26,
		rpm = 800,
		pellets = 1,
		magSize = 30,
		reserveMax = 330,
		penetration = 2,
		penetrationFalloff = 0.6,

		falloffStart = 95,
		falloffEnd = 340,
		falloffMin = 0.5,
		maxRange = 800,

		spreadHip = 2.1,
		spreadAim = 0.45,
		spreadMoving = 1.25,
		spreadMax = 6.5,
		bloomPerShot = 0.4,
		bloomRecovery = 7.5,

		recoilVertical = 1.15,
		recoilHorizontal = 0.45,
		recoilRecovery = 11.0,
		kickback = 0.2,

		reloadTime = 2.35,
		reloadPerShell = 0,
		drawTime = 0.42,
		aimTime = 0.19,

		walkSpeedScale = 0.98,
		aimWalkSpeedScale = 0.71,
		aimFov = 61,

		shakeMagnitude = 1.0,
		shakeRoughness = 13,
		tracerWidth = 0.06,
		tracerColor = WHITE_HOT,
		muzzleFlashSize = 1.5,
		shellEject = true,

		gibPower = 0.13,
		dismemberPower = 0.45,
		knockback = 18,
	},

	--[[ Modernised, and it shows: the same 7.62-class punch as the AKM with
	     most of the climb engineered out. Slower than the M4 and hits harder
	     for it. ]]
	[Enums.Weapon.AK12] = {
		id = Enums.Weapon.AK12,
		displayName = "AK-12",
		modelName = "AK-12",
		slot = Enums.Slot.Primary,
		class = "Rifle",
		fireMode = "Auto",

		damage = 30,
		rpm = 650,
		pellets = 1,
		magSize = 30,
		reserveMax = 300,
		penetration = 2,
		penetrationFalloff = 0.62,

		falloffStart = 205,
		falloffEnd = 610,
		falloffMin = 0.64,
		maxRange = 1200,

		spreadHip = 2.6,
		spreadAim = 0.4,
		spreadMoving = 1.55,
		spreadMax = 6.8,
		bloomPerShot = 0.48,
		bloomRecovery = 6.2,

		recoilVertical = 1.3,
		recoilHorizontal = 0.45,
		recoilRecovery = 9.5,
		kickback = 0.22,

		reloadTime = 2.6,
		reloadPerShell = 0,
		drawTime = 0.52,
		aimTime = 0.23,

		walkSpeedScale = 0.95,
		aimWalkSpeedScale = 0.67,
		aimFov = 60,

		shakeMagnitude = 1.0,
		shakeRoughness = 11,
		tracerWidth = 0.062,
		tracerColor = WHITE_HOT,
		muzzleFlashSize = 1.4,
		shellEject = true,

		gibPower = 0.16,
		dismemberPower = 0.5,
		knockback = 20,
	},

	--[[ The angriest gun in the set. Highest damage of any automatic here and
	     a vertical climb that will walk your sights off a target in half a
	     magazine. Fire it in threes and it is the best rifle in the game;
	     hold the trigger and it is the worst. ]]
	[Enums.Weapon.AKM] = {
		id = Enums.Weapon.AKM,
		displayName = "AKM",
		modelName = "AKM",
		slot = Enums.Slot.Primary,
		class = "Rifle",
		fireMode = "Auto",

		damage = 34,
		rpm = 600,
		pellets = 1,
		magSize = 30,
		reserveMax = 300,
		penetration = 2,
		penetrationFalloff = 0.65,

		falloffStart = 190,
		falloffEnd = 560,
		falloffMin = 0.62,
		maxRange = 1150,

		spreadHip = 3.0,
		spreadAim = 0.45,
		spreadMoving = 1.8,
		spreadMax = 7.5,
		bloomPerShot = 0.62,
		bloomRecovery = 5.5,

		recoilVertical = 1.85,
		recoilHorizontal = 0.62,
		recoilRecovery = 8.0,
		kickback = 0.3,

		reloadTime = 2.7,
		reloadPerShell = 0,
		drawTime = 0.55,
		aimTime = 0.25,

		walkSpeedScale = 0.94,
		aimWalkSpeedScale = 0.65,
		aimFov = 59,

		shakeMagnitude = 1.35,
		shakeRoughness = 11,
		tracerWidth = 0.065,
		tracerColor = WHITE_HOT,
		muzzleFlashSize = 1.7,
		shellEject = true,

		gibPower = 0.22,
		dismemberPower = 0.6,
		knockback = 24,
	},

	--[[ A Mk 18 with glass on it. Semi-automatic, punches through two bodies,
	     and the scope pulls in far enough to make headshots across the map a
	     genuine option for someone holding the back of the group. ]]
	[Enums.Weapon.ScopedMk18] = {
		id = Enums.Weapon.ScopedMk18,
		displayName = "Scoped Mk-18",
		modelName = "Scoped Mk-18",
		slot = Enums.Slot.Primary,
		class = "Marksman",
		fireMode = "Semi",

		damage = 52,
		rpm = 380,
		pellets = 1,
		magSize = 30,
		reserveMax = 240,
		penetration = 2,
		penetrationFalloff = 0.72,

		falloffStart = 320,
		falloffEnd = 1000,
		falloffMin = 0.8,
		maxRange = 1800,

		spreadHip = 3.6,
		spreadAim = 0.12,
		spreadMoving = 2.2,
		spreadMax = 8.0,
		bloomPerShot = 1.2,
		bloomRecovery = 5.0,

		recoilVertical = 2.1,
		recoilHorizontal = 0.45,
		recoilRecovery = 7.0,
		kickback = 0.36,

		reloadTime = 2.6,
		reloadPerShell = 0,
		drawTime = 0.6,
		aimTime = 0.28,

		walkSpeedScale = 0.94,
		aimWalkSpeedScale = 0.58,
		aimFov = 40,

		shakeMagnitude = 1.5,
		shakeRoughness = 10,
		tracerWidth = 0.07,
		tracerColor = WHITE_HOT,
		muzzleFlashSize = 1.5,
		shellEject = true,

		gibPower = 0.3,
		dismemberPower = 0.8,
		knockback = 26,
	},

	--[[ Full-power 7.62 in a semi-automatic rifle. One body shot per Common,
	     three bodies per round, and a corridor lined up correctly is a free
	     multi-kill. The reward for being the player who stops and aims. ]]
	[Enums.Weapon.M1AEBR] = {
		id = Enums.Weapon.M1AEBR,
		displayName = "M1A EBR",
		modelName = "M1A EBR",
		slot = Enums.Slot.Primary,
		class = "Marksman",
		fireMode = "Semi",

		damage = 88,
		rpm = 280,
		pellets = 1,
		magSize = 20,
		reserveMax = 180,
		penetration = 3,
		penetrationFalloff = 0.8,

		falloffStart = 400,
		falloffEnd = 1400,
		falloffMin = 0.85,
		maxRange = 2200,

		spreadHip = 4.2,
		spreadAim = 0.06,
		spreadMoving = 2.5,
		spreadMax = 9.0,
		bloomPerShot = 1.8,
		bloomRecovery = 4.2,

		recoilVertical = 3.0,
		recoilHorizontal = 0.5,
		recoilRecovery = 6.0,
		kickback = 0.5,

		reloadTime = 3.0,
		reloadPerShell = 0,
		drawTime = 0.65,
		aimTime = 0.3,

		walkSpeedScale = 0.92,
		aimWalkSpeedScale = 0.55,
		aimFov = 34,

		shakeMagnitude = 1.95,
		shakeRoughness = 9,
		tracerWidth = 0.075,
		tracerColor = WHITE_HOT,
		muzzleFlashSize = 1.6,
		shellEject = true,

		gibPower = 0.45,
		dismemberPower = 0.95,
		knockback = 32,
	},

	--[[ Costs no ammo and never runs dry, takes heads off cleanly, and moves
	     you faster than any gun does. To use it you have to be inside claw
	     range, which is the entire balance. Handled by MeleeService, not the
	     ballistics path — the round-related fields below are unused. ]]
	[Enums.Weapon.Machete] = {
		id = Enums.Weapon.Machete,
		displayName = "Machete",
		modelName = "Machete",
		slot = Enums.Slot.Secondary,
		class = "Melee",
		fireMode = "Melee",

		damage = 300,
		rpm = 85,
		pellets = 1,
		magSize = 0,
		reserveMax = 0,
		penetration = 3,
		penetrationFalloff = 0.9,

		falloffStart = 12,
		falloffEnd = 16,
		falloffMin = 1.0,
		maxRange = 16,

		spreadHip = 0,
		spreadAim = 0,
		spreadMoving = 0,
		spreadMax = 0,
		bloomPerShot = 0,
		bloomRecovery = 0,

		recoilVertical = 0,
		recoilHorizontal = 0,
		recoilRecovery = 0,
		kickback = 0.3,

		reloadTime = 0,
		reloadPerShell = 0,
		drawTime = 0.3,
		aimTime = 0.1,

		walkSpeedScale = 1.06,
		aimWalkSpeedScale = 1.0,
		aimFov = 70,

		shakeMagnitude = 1.1,
		shakeRoughness = 7,
		tracerWidth = 0,
		tracerColor = WHITE_HOT,
		muzzleFlashSize = 0,
		shellEject = false,

		gibPower = 0.2,
		dismemberPower = 1.0,
		knockback = 26,
	},
} :: { [string]: WeaponDefinition }

--[[
	Seconds between shots. Derived rather than stored so that editing `rpm` is
	always sufficient and the two can never disagree.
]]
function WeaponConfig.getFireDelay(definition: WeaponDefinition): number
	return 60 / math.max(definition.rpm, 1)
end

--[[
	Damage multiplier at a given distance, following the falloff curve described
	in the header. Clamped, so a shot past falloffEnd still does falloffMin rather
	than dropping to zero and feeling broken.
]]
function WeaponConfig.getFalloffMultiplier(definition: WeaponDefinition, distance: number): number
	if distance <= definition.falloffStart then
		return 1
	end
	if distance >= definition.falloffEnd then
		return definition.falloffMin
	end
	local span = definition.falloffEnd - definition.falloffStart
	local alpha = (distance - definition.falloffStart) / math.max(span, 1e-3)
	return 1 + (definition.falloffMin - 1) * alpha
end

--[[
	Looks up a weapon by id, returning nil for an unknown id rather than
	erroring — callers receive ids over the network and must handle garbage.
]]
function WeaponConfig.get(weaponId: string): WeaponDefinition?
	return WeaponConfig.Definitions[weaponId]
end

--[[ Every definition, keyed by weapon id. Safe to iterate. ]]
function WeaponConfig.all(): { [string]: WeaponDefinition }
	return WeaponConfig.Definitions
end

--[[ Every weapon id that lives in the given inventory slot. ]]
function WeaponConfig.idsForSlot(slot: string): { string }
	local ids = {}
	for id, definition in WeaponConfig.Definitions do
		if definition.slot == slot then
			table.insert(ids, id)
		end
	end
	table.sort(ids)
	return ids
end

--[[ Every weapon id in a class, e.g. every SMG. Used by item placement so the
     map offers a spread of weapon types rather than four rifles in a row. ]]
function WeaponConfig.idsForClass(class: WeaponClass): { string }
	local ids = {}
	for id, definition in WeaponConfig.Definitions do
		if definition.class == class then
			table.insert(ids, id)
		end
	end
	table.sort(ids)
	return ids
end

return WeaponConfig
