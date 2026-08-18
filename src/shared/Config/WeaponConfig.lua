--!strict
--[[
	WeaponConfig — every number that decides how a gun feels.

	Nothing about weapon behaviour is hard-coded anywhere else. If a gun should
	kick harder, reload slower, or gib more, the change belongs in this file and
	only this file. Adding a whole new weapon is: add a key here, add it to
	Enums.Weapon, drop a model in ReplicatedStorage.Assets.Weapons under the same
	name. No new code.

	── UNITS ────────────────────────────────────────────────────────────────────
	  damage        health points removed from a torso hit at point-blank range
	  rpm           rounds per minute; the fire delay is 60/rpm
	  spread        degrees of cone half-angle
	  recoil        degrees of camera kick
	  range         studs (1 stud is roughly 28cm at Roblox humanoid scale)
	  times         seconds

	── HOW DAMAGE IS COMPUTED ───────────────────────────────────────────────────
	  final = damage
	          * regionMultiplier   (GameConfig.HitRegionMultipliers)
	          * falloffMultiplier  (lerped between falloffStart and falloffEnd)
	          * penetrationMultiplier ^ (bodies already passed through)
	  A headshot on a Common is a guaranteed kill regardless of the arithmetic —
	  see InfectedConfig.Common.headshotAlwaysKills. That rule is what makes
	  aiming feel like it matters, and it is worth more than any damage number.
]]

local Enums = require(script.Parent.Parent.Enums)

export type FireMode = "Semi" | "Auto" | "Pump" | "Melee"

export type WeaponDefinition = {
	id: string,
	displayName: string,
	slot: string,
	fireMode: FireMode,

	damage: number,
	rpm: number,
	pellets: number, -- >1 turns the shot into a shotgun blast
	magSize: number,
	reserveMax: number, -- -1 means effectively infinite (pistols)
	penetration: number, -- how many bodies one round passes through
	penetrationFalloff: number, -- damage retained per body pierced

	-- Damage stays at 100% until falloffStart, then lerps down to falloffMin
	-- by falloffEnd. Shotguns fall off brutally; rifles barely at all.
	falloffStart: number,
	falloffEnd: number,
	falloffMin: number,
	maxRange: number,

	-- Cone of fire. Every shot adds `bloomPerShot` up to `spreadMax`, and the
	-- cone shrinks by `bloomRecovery` degrees per second once you stop firing.
	spreadHip: number,
	spreadAim: number,
	spreadMoving: number, -- added while the player is moving
	spreadMax: number,
	bloomPerShot: number,
	bloomRecovery: number,

	-- Camera kick. `recoilVertical` is the punch up, `recoilHorizontal` the random
	-- sway either side. `recoilRecovery` is how fast the camera settles back.
	recoilVertical: number,
	recoilHorizontal: number,
	recoilRecovery: number,
	kickback: number, -- viewmodel punch, studs

	reloadTime: number,
	reloadPerShell: number, -- >0 means shell-by-shell (interruptible by firing)
	drawTime: number,
	aimTime: number,

	walkSpeedScale: number, -- multiplier while holding this weapon
	aimWalkSpeedScale: number, -- multiplier while aiming down sights
	aimFov: number, -- camera FOV while aiming

	-- Presentation
	shakeMagnitude: number,
	shakeRoughness: number,
	tracerWidth: number,
	tracerColor: Color3,
	muzzleFlashSize: number,
	shellEject: boolean,

	-- Gore bias. `gibPower` is added to the gore roll, so a point-blank shotgun
	-- blast tears a body apart where a pistol round would not.
	gibPower: number,
	dismemberPower: number,
	knockback: number, -- studs/sec impulse applied to a killed ragdoll
}

local WHITE_HOT = Color3.fromRGB(255, 236, 190)
local AMBER = Color3.fromRGB(255, 196, 92)

local WeaponConfig = {}

--[[
	Every weapon in the game. Iterate this table, never the module itself —
	the module also carries helper functions and mixing the two is how you end
	up trying to read `.damage` off a function.
]]
WeaponConfig.Definitions = {

	--[[ The gun you always have. Weak, but infinite reserve means it is the
	     answer when everything else is dry, and a headshot still drops a Common. ]]
	[Enums.Weapon.Pistol] = {
		id = Enums.Weapon.Pistol,
		displayName = "9mm Pistol",
		slot = Enums.Slot.Secondary,
		fireMode = "Semi",

		damage = 24,
		rpm = 420,
		pellets = 1,
		magSize = 15,
		reserveMax = -1,
		penetration = 1,
		penetrationFalloff = 0.5,

		falloffStart = 120,
		falloffEnd = 420,
		falloffMin = 0.55,
		maxRange = 900,

		spreadHip = 1.6,
		spreadAim = 0.35,
		spreadMoving = 0.9,
		spreadMax = 5.0,
		bloomPerShot = 0.55,
		bloomRecovery = 4.5,

		recoilVertical = 1.15,
		recoilHorizontal = 0.35,
		recoilRecovery = 9.0,
		kickback = 0.14,

		reloadTime = 1.6,
		reloadPerShell = 0,
		drawTime = 0.35,
		aimTime = 0.18,

		walkSpeedScale = 1.0,
		aimWalkSpeedScale = 0.72,
		aimFov = 62,

		shakeMagnitude = 0.55,
		shakeRoughness = 8,
		tracerWidth = 0.055,
		tracerColor = WHITE_HOT,
		muzzleFlashSize = 1.0,
		shellEject = true,

		gibPower = 0.05,
		dismemberPower = 0.25,
		knockback = 12,
	},

	--[[ Loud, slow, and it hits like a truck. The reward for trading your rifle
	     slot away is that a Magnum headshot deletes anything short of a boss. ]]
	[Enums.Weapon.Magnum] = {
		id = Enums.Weapon.Magnum,
		displayName = ".50 Magnum",
		slot = Enums.Slot.Secondary,
		fireMode = "Semi",

		damage = 62,
		rpm = 260,
		pellets = 1,
		magSize = 8,
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
		bloomPerShot = 1.4,
		bloomRecovery = 5.0,

		recoilVertical = 3.4,
		recoilHorizontal = 0.8,
		recoilRecovery = 7.0,
		kickback = 0.42,

		reloadTime = 2.1,
		reloadPerShell = 0,
		drawTime = 0.42,
		aimTime = 0.22,

		walkSpeedScale = 1.0,
		aimWalkSpeedScale = 0.7,
		aimFov = 58,

		shakeMagnitude = 1.7,
		shakeRoughness = 11,
		tracerWidth = 0.085,
		tracerColor = WHITE_HOT,
		muzzleFlashSize = 1.7,
		shellEject = true,

		gibPower = 0.35,
		dismemberPower = 0.8,
		knockback = 34,
	},

	--[[ The panic weapon. Enormous magazine, forgiving to spray, but the damage
	     per round is low enough that a horde will still reach you. ]]
	[Enums.Weapon.SMG] = {
		id = Enums.Weapon.SMG,
		displayName = "Tactical SMG",
		slot = Enums.Slot.Primary,
		fireMode = "Auto",

		damage = 20,
		rpm = 900,
		pellets = 1,
		magSize = 50,
		reserveMax = 650,
		penetration = 1,
		penetrationFalloff = 0.5,

		falloffStart = 90,
		falloffEnd = 340,
		falloffMin = 0.45,
		maxRange = 700,

		spreadHip = 2.2,
		spreadAim = 0.85,
		spreadMoving = 1.4,
		spreadMax = 7.5,
		bloomPerShot = 0.34,
		bloomRecovery = 7.0,

		recoilVertical = 0.62,
		recoilHorizontal = 0.42,
		recoilRecovery = 12.0,
		kickback = 0.1,

		reloadTime = 2.2,
		reloadPerShell = 0,
		drawTime = 0.45,
		aimTime = 0.2,

		walkSpeedScale = 0.98,
		aimWalkSpeedScale = 0.7,
		aimFov = 64,

		shakeMagnitude = 0.42,
		shakeRoughness = 13,
		tracerWidth = 0.05,
		tracerColor = AMBER,
		muzzleFlashSize = 0.9,
		shellEject = true,

		gibPower = 0.05,
		dismemberPower = 0.2,
		knockback = 9,
	},

	--[[ The gore weapon. Ten pellets at contact range does more than kill a
	     Common — it removes it from the world. Falls off to nearly nothing past
	     a corridor's length, which is exactly the trade it should make. ]]
	[Enums.Weapon.PumpShotgun] = {
		id = Enums.Weapon.PumpShotgun,
		displayName = "Pump Shotgun",
		slot = Enums.Slot.Primary,
		fireMode = "Pump",

		damage = 24,
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

		recoilVertical = 4.6,
		recoilHorizontal = 0.9,
		recoilRecovery = 6.5,
		kickback = 0.6,

		reloadTime = 0.7, -- the pump-and-ready tail after the last shell
		reloadPerShell = 0.42,
		drawTime = 0.6,
		aimTime = 0.26,

		walkSpeedScale = 0.94,
		aimWalkSpeedScale = 0.66,
		aimFov = 66,

		shakeMagnitude = 2.4,
		shakeRoughness = 10,
		tracerWidth = 0.04,
		tracerColor = AMBER,
		muzzleFlashSize = 2.2,
		shellEject = true,

		gibPower = 1.0,
		dismemberPower = 1.0,
		knockback = 62,
	},

	--[[ Trades the pump's per-shell devastation for rate of fire. Better against
	     a Charger bearing down on you; worse at clearing a doorway in one hit. ]]
	[Enums.Weapon.AutoShotgun] = {
		id = Enums.Weapon.AutoShotgun,
		displayName = "Auto Shotgun",
		slot = Enums.Slot.Primary,
		fireMode = "Semi",

		damage = 19,
		rpm = 190,
		pellets = 10,
		magSize = 10,
		reserveMax = 128,
		penetration = 1,
		penetrationFalloff = 0.5,

		falloffStart = 30,
		falloffEnd = 140,
		falloffMin = 0.16,
		maxRange = 240,

		spreadHip = 5.2,
		spreadAim = 4.0,
		spreadMoving = 0.9,
		spreadMax = 8.5,
		bloomPerShot = 0.9,
		bloomRecovery = 6.5,

		recoilVertical = 2.6,
		recoilHorizontal = 0.85,
		recoilRecovery = 8.0,
		kickback = 0.38,

		reloadTime = 0.65,
		reloadPerShell = 0.36,
		drawTime = 0.6,
		aimTime = 0.26,

		walkSpeedScale = 0.94,
		aimWalkSpeedScale = 0.66,
		aimFov = 66,

		shakeMagnitude = 1.6,
		shakeRoughness = 11,
		tracerWidth = 0.04,
		tracerColor = AMBER,
		muzzleFlashSize = 1.8,
		shellEject = true,

		gibPower = 0.85,
		dismemberPower = 0.95,
		knockback = 44,
	},

	--[[ The all-rounder. Nothing about it is best-in-class, which is the point:
	     it is the weapon you can hold for a whole map without regret. ]]
	[Enums.Weapon.AssaultRifle] = {
		id = Enums.Weapon.AssaultRifle,
		displayName = "Assault Rifle",
		slot = Enums.Slot.Primary,
		fireMode = "Auto",

		damage = 34,
		rpm = 660,
		pellets = 1,
		magSize = 50,
		reserveMax = 360,
		penetration = 2,
		penetrationFalloff = 0.6,

		falloffStart = 200,
		falloffEnd = 600,
		falloffMin = 0.62,
		maxRange = 1200,

		spreadHip = 2.6,
		spreadAim = 0.4,
		spreadMoving = 1.5,
		spreadMax = 6.5,
		bloomPerShot = 0.4,
		bloomRecovery = 6.0,

		recoilVertical = 1.05,
		recoilHorizontal = 0.4,
		recoilRecovery = 10.0,
		kickback = 0.18,

		reloadTime = 2.6,
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

		gibPower = 0.15,
		dismemberPower = 0.5,
		knockback = 18,
	},

	--[[ Rewards the player who holds the back of the group and picks targets.
	     Punches through three bodies, so a lined-up corridor is a free multi-kill. ]]
	[Enums.Weapon.HuntingRifle] = {
		id = Enums.Weapon.HuntingRifle,
		displayName = "Hunting Rifle",
		slot = Enums.Slot.Primary,
		fireMode = "Semi",

		damage = 92,
		rpm = 240,
		pellets = 1,
		magSize = 15,
		reserveMax = 180,
		penetration = 3,
		penetrationFalloff = 0.8,

		falloffStart = 400,
		falloffEnd = 1400,
		falloffMin = 0.85,
		maxRange = 2200,

		spreadHip = 4.5,
		spreadAim = 0.05,
		spreadMoving = 2.5,
		spreadMax = 9.0,
		bloomPerShot = 1.8,
		bloomRecovery = 4.0,

		recoilVertical = 3.0,
		recoilHorizontal = 0.5,
		recoilRecovery = 6.0,
		kickback = 0.5,

		reloadTime = 3.0,
		reloadPerShell = 0,
		drawTime = 0.65,
		aimTime = 0.3,

		walkSpeedScale = 0.93,
		aimWalkSpeedScale = 0.55,
		aimFov = 32, -- proper scope pull-in

		shakeMagnitude = 1.9,
		shakeRoughness = 9,
		tracerWidth = 0.075,
		tracerColor = WHITE_HOT,
		muzzleFlashSize = 1.6,
		shellEject = true,

		gibPower = 0.45,
		dismemberPower = 0.95,
		knockback = 30,
	},

	--[[ Melee. Costs no ammo and never runs dry, and it takes heads off cleanly,
	     but it puts you inside claw range to do it. Handled by MeleeService, not
	     the ballistics path — the fields below that mention rounds are unused. ]]
	[Enums.Weapon.Machete] = {
		id = Enums.Weapon.Machete,
		displayName = "Machete",
		slot = Enums.Slot.Secondary,
		fireMode = "Melee",

		damage = 300, -- deletes a Common, meaningful chunk of a special
		rpm = 85,
		pellets = 1,
		magSize = 0,
		reserveMax = 0,
		penetration = 3, -- cleaves through a small crowd in one arc
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

		walkSpeedScale = 1.06, -- melee is the fast loadout, as it should be
		aimWalkSpeedScale = 1.0,
		aimFov = 70,

		shakeMagnitude = 1.1,
		shakeRoughness = 7,
		tracerWidth = 0,
		tracerColor = WHITE_HOT,
		muzzleFlashSize = 0,
		shellEject = false,

		gibPower = 0.2,
		dismemberPower = 1.0, -- the machete's whole identity
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

return WeaponConfig
