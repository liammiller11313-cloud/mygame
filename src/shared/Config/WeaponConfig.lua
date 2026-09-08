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
export type WeaponClass = "Pistol" | "SMG" | "Rifle" | "LMG" | "Marksman" | "Shotgun" | "Melee" | "Launcher"

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

	--[[ Optional, and set together or not at all. A weapon with a blast radius
	     detonates where its shot lands, on top of whatever that shot already did
	     to the thing it hit — see BallisticsService. Absent on every weapon but
	     the RPG-7, and absent means "an ordinary gun", which is what all the
	     arithmetic above assumes. ]]
	blastRadius: number?,
	blastDamage: number?,

	--[[ Whether the Director may put this on the floor. nil means yes, which is
	     every weapon but one — the default has to be "placeable" or adding a gun
	     would silently mean adding a gun nobody ever finds.

	     False is for a weapon whose PRICE is the design. See the RPG-7: it costs
	     ten won rounds, and a Director that hands one out free on a shelf has not
	     made it a bit cheaper, it has made the price meaningless. ]]
	placeable: boolean?,

	--[[ Unlocked by a Robux game pass rather than bought with Dollars, so it has
	     no EconomyConfig row and never will. A third way to own a weapon beside
	     buying one and finding one on the floor, and audit.py check 16 knows all
	     three — without this flag it correctly reports the weapon as unreachable.

	     It is not an ownership check. ProfileService decides that, by merging
	     PassService's grants into the set it publishes and sanitises against;
	     this only says where the weapon is SUPPOSED to come from. ]]
	passOnly: boolean?,
	--[[ Whether landing a shot sets the target on fire, through the same
	     InfectedService:ignite the molotov and the Incendiary requisition use.
	     Nil on every gun: bullets do not light people, and a flag that defaulted
	     the other way would be a design change disguised as a type. ]]
	ignites: boolean?,
	--[[
		Whether this is a PAIR — two guns, one in each hand.

		A declaration rather than something the asset pipeline works out. The
		geometry alone cannot decide it: a rifle whose scope was modelled as a
		child Model containing a part called Handle looks identical from the
		outside, and treating that as a dual-wield would break one gun to fix
		another. So the config says which weapons are pairs and the pipeline
		checks whether the art can actually be split; when it cannot, the pair
		falls back to one gun in one hand and says so in the log.

		The magazine is the PAIR'S, not one gun's — see the note on the dual
		pistols' magSize. Nothing else in the weapon table changes meaning.
	]]
	dualWield: boolean?,
	--[[
		A hand-authored rotation for a model the pipeline gets wrong, in DEGREES
		about the model's own X, Y and Z.

		The pipeline measures which way a gun points and straightens it, and when
		it can measure — the model carries a `Muzzle` attachment the artist
		placed — it is exact. When it cannot, it guesses from the longest axis,
		and a guess has two ways to be wrong: it can pick the wrong axis, or it
		can decide the model is already correct and leave it alone. The second is
		the dangerous one, because nothing about it appears in the log unless you
		read the facing report at boot.

		This is the escape hatch for both. It is applied on top of whatever the
		pipeline concluded, in the model's own frame, in BOTH hands — so the
		first-person and world models cannot disagree.

		Was `modelRoll`, a single number about Z, which was enough for a gun that
		is upright but face-on and not enough for one that is pointing the wrong
		way entirely. Three axes cost nothing and cover every case.

		Prefer a `Muzzle` attachment where you can: it makes the measurement
		exact, and this stops being needed. This is for when the model is
		somebody else's and you cannot.
	]]
	modelRotation: Vector3?,
	--[[
		Whether this weapon is FOUND rather than bought.

		A floor-only weapon is deliberately absent from EconomyConfig.Catalogue —
		it cannot be purchased, cannot be put in a loadout, and exists in exactly
		one place in the world. InventoryService:pickup reads FL_Slot and
		FL_ItemId and never asks whether the player owns anything, so the pickup
		path works without a catalogue row; the LOADOUT path does not, which is
		the whole point.

		Declared rather than inferred, because "not in the catalogue" is far more
		often a mistake than an intention — audit.py fails every other weapon for
		it and honours this flag as the one way to say you meant it.
	]]
	floorOnly: boolean?,
}

local WHITE_HOT = Color3.fromRGB(255, 236, 190)
local AMBER = Color3.fromRGB(255, 196, 92)
--[[ Deeper and redder than a tracer, because it is not one. See the
     Flamethrower: twelve fat short ones of these a shot is the flame. ]]
local FLAME = Color3.fromRGB(255, 122, 40)

local WeaponConfig = {}

--[[
	Every weapon in the game. Iterate this table, never the module itself — the
	module also carries helper functions and mixing the two is how you end up
	reading `.damage` off a function.
]]
--[[
	How far into a pump gun's fire cycle the pump itself happens.

	Not at the shot and not at the end — a beat after the blast is where the hand
	actually moves, and it is what makes a pump shotgun feel worked rather than
	waited on.

	Shared rather than owned by the client, because THREE things now key off this
	instant and they have to be the same instant: the shooter's viewmodel kick,
	the pump sound, and — since the shotgun got a clip of its own — the pump
	animation on the character, which is what everyone ELSE sees. Two copies of
	0.45 in two files is two copies until somebody tunes one of them, and then it
	is a teammate whose hands work the action after the sound.
]]
WeaponConfig.PumpPoint = 0.45

WeaponConfig.Definitions = {

	--[[ The sidearm everyone starts with. .45 ACP means two body shots on a
	     Common where a 9mm would take three, and the seven-round magazine is
	     what stops that from being strictly better than a primary. ]]
	[Enums.Weapon.M1911A1] = {
		id = Enums.Weapon.M1911A1,
		displayName = "M1911A1",
		--[[ "M1911" rather than "M1911A1", because that is what the supplied model
		     is called. The loader tries modelName, then id, then displayName — the
		     last two are still M1911A1 — so a folder holding either name resolves,
		     and this one was grey-boxing a perfectly good model sitting in the
		     right place under a perfectly reasonable name. ]]
		modelName = "M1911",
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

	--[[ Beretta's answer to the same question the M1911 asks, and the reason to
	     carry it is capacity rather than punch. Fifteen rounds against seven, at
	     rather less per round — the 1911 ends an argument, this one has a longer
	     argument. Free-adjacent on purpose: it is the first thing a new player can
	     buy, and it should teach that a cheap sidegrade is a real choice. ]]
	[Enums.Weapon.M9] = {
		id = Enums.Weapon.M9,
		displayName = "M9",
		modelName = "M9",
		slot = Enums.Slot.Secondary,
		class = "Pistol",
		fireMode = "Semi",

		damage = 18,
		rpm = 450,
		pellets = 1,
		magSize = 15,
		reserveMax = -1,
		penetration = 1,
		penetrationFalloff = 0.55,

		falloffStart = 60,
		falloffEnd = 220,
		falloffMin = 0.42,
		maxRange = 500,

		spreadHip = 1.7,
		spreadAim = 0.45,
		spreadMoving = 1.1,
		spreadMax = 5.5,
		bloomPerShot = 0.5,
		bloomRecovery = 6.0,

		recoilVertical = 0.9,
		recoilHorizontal = 0.32,
		recoilRecovery = 11.0,
		kickback = 0.11,

		reloadTime = 1.7,
		reloadPerShell = 0,
		drawTime = 0.3,
		aimTime = 0.16,

		walkSpeedScale = 1.0,
		aimWalkSpeedScale = 0.78,
		aimFov = 66,

		shakeMagnitude = 0.45,
		shakeRoughness = 9,
		tracerWidth = 0.05,
		tracerColor = WHITE_HOT,
		muzzleFlashSize = 0.95,
		shellEject = true,

		gibPower = 0.03,
		dismemberPower = 0.15,
		knockback = 7,
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

	--[[
		The flare gun. A secondary that does almost no damage and is worth
		carrying anyway.

		Twelve on impact will not kill a Common — that is deliberate and it is
		the whole design. What it does is `ignites`, the same burn the molotov
		and the flamethrower own, so the shot is a fuse rather than a bullet:
		the body walks two more seconds and then goes down on fire, and the
		bodies behind it walk through what is left. Against a horde that is a
		slow answer and a bad one. Against a special coming down a corridor
		alone it is one shell.

		ONE SHELL, and a reload longer than a Magnum's. You break it, the spent
		case comes out, a new one goes in. Everything about the rhythm is meant
		to make the shot a decision — there is no second one for four seconds
		and nothing else in your hands until there is.

		AND IT LIGHTS THE ROOM. The flare burns where it lands. In a game called
		Fading Light, with a torch deliberately weaker than its own fog and a
		blackout event that kills every fixture in the map, this is the only
		thing a player carries that pushes the dark back — which is most of the
		reason to own one and none of the reason it is priced where it is.
	]]
	[Enums.Weapon.FlareGun] = {
		id = Enums.Weapon.FlareGun,
		displayName = "Flare Gun",
		modelName = "Flare Gun",
		slot = Enums.Slot.Secondary,
		class = "Pistol",
		fireMode = "Semi",

		damage = 12,
		rpm = 60,
		pellets = 1,
		magSize = 1,
		reserveMax = -1,
		-- A flare stops in the first thing it touches. It is a lit stick, not a
		-- bullet, and one that punched through two bodies would set neither.
		penetration = 0,
		penetrationFalloff = 1.0,

		--[[ No falloff worth the name. The impact damage is already negligible,
		     and the burn it starts does not care how far it travelled — so a
		     flare across a courtyard lights the thing it hits exactly as well as
		     one at arm's length. That is the one generous thing about it. ]]
		falloffStart = 300,
		falloffEnd = 900,
		falloffMin = 0.85,
		maxRange = 900,

		spreadHip = 2.0,
		spreadAim = 0.4,
		spreadMoving = 1.4,
		spreadMax = 5.0,
		bloomPerShot = 0,
		bloomRecovery = 5.0,

		recoilVertical = 2.2,
		recoilHorizontal = 0.5,
		recoilRecovery = 7.0,
		kickback = 0.22,

		--[[ Four seconds, break-action, one shell at a time. reloadPerShell is
		     what makes the hand carry a round to the breech rather than slap a
		     magazine in — see AmmoConfig.Magazines.FlareShell, which is the LIVE
		     shell, as against the spent case in Casings. ]]
		reloadTime = 4.0,
		reloadPerShell = 4.0,
		drawTime = 0.4,
		aimTime = 0.2,

		walkSpeedScale = 1.0,
		aimWalkSpeedScale = 0.75,
		aimFov = 62,

		shakeMagnitude = 1.2,
		shakeRoughness = 8,
		--[[ Fat, slow and hot. The one tracer in the game a player is supposed
		     to WATCH — it is how you know where the fire is about to start. ]]
		tracerWidth = 0.26,
		tracerColor = Color3.fromRGB(255, 138, 46),
		muzzleFlashSize = 2.2,
		shellEject = true,

		--[[ It sets things alight and it does not take them apart, exactly as
		     the flamethrower does not. A burned body stays a body. ]]
		gibPower = 0.0,
		dismemberPower = 0.0,
		knockback = 6,

		-- The whole weapon, in one field. See DamageService.
		ignites = true,
	},

	--[[ Two magazines' worth without a reload, and it is the reason the pair
	     exists: the 1911 places shots and this one keeps firing. Nine millimetre
	     means three body shots on a Common where the .45 takes two, so the
	     fifteen rounds are not free — they are the same total damage spread over
	     more trigger pulls and more time upright. ]]
	--[[ The enum id stays DualBerettas and the model is a Glock and a P220, which
	     looks like an oversight and is not: the id is what a PROFILE stores. It is
	     in every save's `owned` set and in the loadouts pointing at it, so
	     renaming it would un-buy this gun for everybody who has one. What the
	     player reads is displayName; what the asset pipeline looks for is
	     modelName; the id is a database key and nothing else. ]]
	[Enums.Weapon.DualBerettas] = {
		id = Enums.Weapon.DualBerettas,
		displayName = "Dual Pistols",
		modelName = "Dual Pistol",
		slot = Enums.Slot.Secondary,
		class = "Pistol",
		fireMode = "Semi",
		--[[ Two guns, one in each hand. The model is two child models with a
		     Handle each; the pipeline splits them, the world model welds one to
		     each hand, and the viewmodel poses an arm on each and alternates the
		     muzzle. See PlaceholderFactory.adoptDualWeapon. ]]
		dualWield = true,

		damage = 19,
		rpm = 620,
		pellets = 1,
		--[[ Fifteen for the PAIR, not fifteen each. Firing alternates hands, so
		     this is seven or eight trigger pulls per gun before the reload — and
		     that reload racks both at once, which is what makes 2.2 seconds fair
		     for two magazines. Doubling it because there are two guns would make
		     this the highest-capacity secondary in the game by a wide margin and
		     the .357 pointless. ]]
		magSize = 15,
		reserveMax = -1,
		penetration = 1,
		penetrationFalloff = 0.5,

		falloffStart = 90,
		falloffEnd = 340,
		falloffMin = 0.5,
		maxRange = 800,

		spreadHip = 2.1,
		spreadAim = 0.55,
		spreadMoving = 1.1,
		spreadMax = 6.0,
		bloomPerShot = 0.5,
		bloomRecovery = 5.6,

		recoilVertical = 0.9,
		recoilHorizontal = 0.55,
		recoilRecovery = 10.5,
		kickback = 0.12,

		reloadTime = 2.2,
		reloadPerShell = 0,
		drawTime = 0.35,
		aimTime = 0.2,

		walkSpeedScale = 1.0,
		aimWalkSpeedScale = 0.74,
		aimFov = 64,

		shakeMagnitude = 0.45,
		shakeRoughness = 8,
		tracerWidth = 0.05,
		tracerColor = WHITE_HOT,
		muzzleFlashSize = 0.95,
		shellEject = true,

		gibPower = 0.05,
		dismemberPower = 0.2,
		knockback = 10,
	},

	--[[ The panic button. Full auto out of a pistol frame, which means the
	     magazine is gone in under two seconds and the cone opens faster than you
	     can correct — it is not a weapon you aim, it is a weapon you use to buy
	     the two steps back that let you draw something else. ]]
	[Enums.Weapon.Glock18] = {
		id = Enums.Weapon.Glock18,
		displayName = "Glock 18",
		modelName = "Glock 18",
		slot = Enums.Slot.Secondary,
		class = "Pistol",
		fireMode = "Auto",

		damage = 17,
		rpm = 1100,
		pellets = 1,
		magSize = 18,
		reserveMax = -1,
		penetration = 1,
		penetrationFalloff = 0.5,

		falloffStart = 70,
		falloffEnd = 280,
		falloffMin = 0.45,
		maxRange = 700,

		spreadHip = 2.8,
		spreadAim = 0.9,
		spreadMoving = 1.4,
		spreadMax = 8.5,
		bloomPerShot = 0.85,
		bloomRecovery = 5.0,

		recoilVertical = 1.05,
		recoilHorizontal = 0.75,
		recoilRecovery = 9.5,
		kickback = 0.13,

		reloadTime = 1.9,
		reloadPerShell = 0,
		drawTime = 0.32,
		aimTime = 0.18,

		walkSpeedScale = 1.0,
		aimWalkSpeedScale = 0.76,
		aimFov = 66,

		shakeMagnitude = 0.5,
		shakeRoughness = 9,
		tracerWidth = 0.05,
		tracerColor = WHITE_HOT,
		muzzleFlashSize = 1.0,
		shellEject = true,

		gibPower = 0.04,
		dismemberPower = 0.18,
		knockback = 8,
	},

	--[[ Two barrels, both of them yours, and then two and a half seconds of
	     being unarmed. It is the only secondary that gibs, and the only one that
	     asks a real question — because the reload is longer than a Hunter needs
	     to cross a room, firing the second barrel is a decision rather than a
	     reflex. ]]
	[Enums.Weapon.SawnOff] = {
		id = Enums.Weapon.SawnOff,
		displayName = "Sawn-Off",
		modelName = "Sawn-Off",
		slot = Enums.Slot.Secondary,
		class = "Shotgun",
		fireMode = "Semi",

		damage = 21,
		rpm = 220,
		pellets = 8,
		magSize = 2,
		reserveMax = -1,
		penetration = 2,
		penetrationFalloff = 0.75,

		falloffStart = 22,
		falloffEnd = 95,
		falloffMin = 0.16,
		maxRange = 300,

		spreadHip = 7.5,
		spreadAim = 5.4,
		spreadMoving = 1.2,
		spreadMax = 11.0,
		bloomPerShot = 0.7,
		bloomRecovery = 4.0,

		recoilVertical = 3.4,
		recoilHorizontal = 0.9,
		recoilRecovery = 6.5,
		kickback = 0.4,

		reloadTime = 2.5,
		reloadPerShell = 0,
		drawTime = 0.42,
		aimTime = 0.26,

		walkSpeedScale = 1.0,
		aimWalkSpeedScale = 0.7,
		aimFov = 68,

		shakeMagnitude = 1.5,
		shakeRoughness = 11,
		tracerWidth = 0.06,
		tracerColor = WHITE_HOT,
		muzzleFlashSize = 1.5,
		shellEject = true,

		gibPower = 0.85,
		dismemberPower = 0.9,
		knockback = 46,
	},

	--[[
		The RPG-7. A secondary by slot and by nothing else.

		Everything about it is arranged so that taking it is a real cost rather
		than an upgrade. The other five secondaries exist to answer "the primary
		is dry and there are twenty of them"; this one cannot answer that at all —
		one rocket, four in total, four and a half seconds to reload, and a blast
		that will kill YOU at the range a Common gets to. Carry it and you have
		given up the fallback the slot is for, in exchange for the one thing no
		other weapon in the game does: deleting a Tank, or a whole horde, once.

		The direct hit is deliberately small. Sixty is less than the M1911 does to
		a head, and that is the point — the damage is the explosion, so a rocket
		that lands at somebody's feet is worth the same as one that hits them in
		the chest, and there is no reward for sniping with it. See
		BallisticsService, which detonates at wherever the shot lands.

		Not a Marksman and not a Shotgun: "Launcher" is its own class so the shop's
		stat bars do not normalise a 400-damage blast against a rifle roster and
		flatten every other gun's damage bar into nothing. That is the exact bug
		the melee/gun split in ShopController was written to fix.
	]]
	[Enums.Weapon.RPG7] = {
		id = Enums.Weapon.RPG7,
		displayName = "RPG-7",
		modelName = "RPG-7",
		slot = Enums.Slot.Secondary,
		class = "Launcher",
		fireMode = "Semi",

		damage = 60,
		--[[ The blast, which is the weapon. Radius is under the pipe bomb's 34
		     and damage under its 480, because a pipe bomb has to be thrown, has to
		     be found, and gathers the crowd before it goes off — this arrives on
		     demand and hits whatever you were already looking at. ]]
		blastRadius = 26,
		blastDamage = 400,

		rpm = 40,
		pellets = 1,
		magSize = 1,
		--[[ Three spare, four in total, and the ONLY secondary that is not
		     infinite — every other one is reserveMax -1, because the sidearm is the
		     promise that you are never truly empty. This one is not that promise.

		     A weapon that deletes a Tank has to run out, or the Tank stops being
		     an event. Ammo crates do refill it, on the same rule as any primary
		     (InventoryService gives a share of reserveMax), so the scarcity is
		     four shots BETWEEN crates rather than four a life. ]]
		reserveMax = 3,
		penetration = 1,
		penetrationFalloff = 1.0,

		--[[ No falloff at all. A rocket does not lose energy on the way, and
		     falloff on a blast weapon would be a rule the player cannot see: the
		     explosion is at the impact point either way. ]]
		falloffStart = 900,
		falloffEnd = 900,
		falloffMin = 1.0,
		maxRange = 900,

		spreadHip = 2.2,
		spreadAim = 0.4,
		spreadMoving = 2.0,
		spreadMax = 4.0,
		bloomPerShot = 0.0,
		bloomRecovery = 6.0,

		recoilVertical = 6.5,
		recoilHorizontal = 1.6,
		recoilRecovery = 4.5,
		kickback = 0.7,

		reloadTime = 4.5,
		reloadPerShell = 0,
		drawTime = 0.85,
		aimTime = 0.4,

		--[[ Slower carrying it, slower still aiming it. It is a tube on a
		     shoulder and the movement should say so before the player has fired
		     it once. ]]
		walkSpeedScale = 0.88,
		aimWalkSpeedScale = 0.55,
		aimFov = 60,

		shakeMagnitude = 2.6,
		shakeRoughness = 12,
		tracerWidth = 0.14,
		tracerColor = AMBER,
		muzzleFlashSize = 3.0,
		--[[ No casing. Nothing about an RPG ejects anything, and AmmoFactory would
		     otherwise throw a rifle shell out of the side of it. ]]
		shellEject = false,

		--[[ Zero, and not because it is gentle. GoreConfig.ExplosiveAlwaysGibs
		     means the blast already takes apart everything it kills; these fields
		     drive the DIRECT hit, and a rocket that dismembered on contact and
		     then gibbed the same body a frame later would be fighting itself. ]]
		gibPower = 0.0,
		dismemberPower = 0.0,
		knockback = 70,

		--[[ The only weapon in the game the Director may not place.

		     ItemPlacer discovers its classes from this file — "a new class is
		     placeable the moment it is defined", says its header — so adding a
		     Launcher class handed the Secondary deck a second entry, and a deck
		     of {Pistol, Launcher} dealt without replacement puts an RPG on every
		     other secondary pad. Free, on a map, against a shop price of ten won
		     rounds. ]]
		placeable = false,
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

	--[[ The pump gun with two more shells and a shorter reach than the Shotgun it
	     sits beside. Same rhythm, more of it before the reload — which is the
	     whole difference in a corridor, and nothing at all in the open. ]]
	[Enums.Weapon.TacticalShotty] = {
		id = Enums.Weapon.TacticalShotty,
		displayName = "Tactical Shotty",
		modelName = "Tactical Shotty",
		slot = Enums.Slot.Primary,
		class = "Shotgun",
		fireMode = "Pump",

		damage = 20,
		rpm = 75,
		pellets = 8,
		magSize = 6,
		reserveMax = 60,
		penetration = 2,
		penetrationFalloff = 0.7,

		falloffStart = 26,
		falloffEnd = 110,
		falloffMin = 0.18,
		maxRange = 320,

		spreadHip = 6.2,
		spreadAim = 4.2,
		spreadMoving = 1.3,
		spreadMax = 10.0,
		bloomPerShot = 0.6,
		bloomRecovery = 4.2,

		recoilVertical = 3.9,
		recoilHorizontal = 0.85,
		recoilRecovery = 6.8,
		kickback = 0.36,

		--[[
			UNSET, and deliberately, after two wrong guesses.

			This model was drawn standing on end. A quarter turn about Z was the
			first fix, which spun it about an axis that was itself vertical and
			turned its profile edge-on — a thinner wrong answer. Both attempts
			were made without being able to see the model, which is not a way to
			converge.

			The boot report now prints what the pipeline decided about this gun
			and on what evidence. Read that line first, then set the rotation
			this needs — or better, put a Muzzle attachment at the end of its
			barrel in Studio and delete this comment, because that makes the
			measurement exact and no rotation is needed at all.
		]]

		reloadTime = 0.75,
		reloadPerShell = 0.42,
		drawTime = 0.55,
		aimTime = 0.28,

		walkSpeedScale = 0.94,
		aimWalkSpeedScale = 0.66,
		aimFov = 64,

		shakeMagnitude = 1.4,
		shakeRoughness = 11,
		tracerWidth = 0.06,
		tracerColor = WHITE_HOT,
		muzzleFlashSize = 1.5,
		shellEject = true,

		gibPower = 0.55,
		dismemberPower = 0.7,
		knockback = 40,
	},

	--[[ Semi-automatic, which changes what a shotgun IS here. The pump guns make
	     you decide between each shell; this one lets you empty eight into a
	     Charger and asks for eight seconds back afterwards. Less per pellet to pay
	     for it. ]]
	[Enums.Weapon.M1014] = {
		id = Enums.Weapon.M1014,
		displayName = "M1014",
		modelName = "M1014",
		slot = Enums.Slot.Primary,
		class = "Shotgun",
		fireMode = "Semi",

		damage = 17,
		rpm = 200,
		pellets = 8,
		magSize = 8,
		reserveMax = 64,
		penetration = 2,
		penetrationFalloff = 0.68,

		falloffStart = 24,
		falloffEnd = 105,
		falloffMin = 0.17,
		maxRange = 310,

		spreadHip = 5.8,
		spreadAim = 4.0,
		spreadMoving = 1.35,
		spreadMax = 10.5,
		bloomPerShot = 0.75,
		bloomRecovery = 4.0,

		recoilVertical = 2.9,
		recoilHorizontal = 0.8,
		recoilRecovery = 7.5,
		kickback = 0.3,

		reloadTime = 0.7,
		reloadPerShell = 0.38,
		drawTime = 0.55,
		aimTime = 0.28,

		walkSpeedScale = 0.94,
		aimWalkSpeedScale = 0.66,
		aimFov = 64,

		shakeMagnitude = 1.25,
		shakeRoughness = 11,
		tracerWidth = 0.06,
		tracerColor = WHITE_HOT,
		muzzleFlashSize = 1.45,
		shellEject = true,

		gibPower = 0.45,
		dismemberPower = 0.62,
		knockback = 34,
	},

	--[[ Twelve shells in a drum, and the only shotgun that reloads as one piece
	     rather than shell by shell. That is the trade in both directions: nothing
	     else in the game holds a horde off for twelve continuous shots, and
	     nothing else leaves you standing there for three whole seconds when it
	     runs out. Weakest pellets of the four, because twelve of them is already
	     the strongest thing about it. ]]
	[Enums.Weapon.DAO12] = {
		id = Enums.Weapon.DAO12,
		displayName = "DAO-12",
		modelName = "DAO-12",
		slot = Enums.Slot.Primary,
		class = "Shotgun",
		fireMode = "Semi",

		damage = 15,
		rpm = 240,
		pellets = 8,
		magSize = 12,
		reserveMax = 72,
		penetration = 2,
		penetrationFalloff = 0.65,

		falloffStart = 22,
		falloffEnd = 100,
		falloffMin = 0.15,
		maxRange = 300,

		spreadHip = 6.6,
		spreadAim = 4.8,
		spreadMoving = 1.5,
		spreadMax = 11.0,
		bloomPerShot = 0.8,
		bloomRecovery = 3.8,

		recoilVertical = 2.6,
		recoilHorizontal = 0.9,
		recoilRecovery = 7.2,
		kickback = 0.28,

		reloadTime = 3.0,
		reloadPerShell = 0,
		drawTime = 0.65,
		aimTime = 0.3,

		walkSpeedScale = 0.92,
		aimWalkSpeedScale = 0.64,
		aimFov = 64,

		shakeMagnitude = 1.2,
		shakeRoughness = 11,
		tracerWidth = 0.06,
		tracerColor = WHITE_HOT,
		muzzleFlashSize = 1.4,
		shellEject = true,

		gibPower = 0.4,
		dismemberPower = 0.55,
		knockback = 30,
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

	--[[ The only semi-automatic rifle in the roster, and that is the point of it
	     rather than a limitation. Every round is aimed, hits harder than the M4's,
	     and costs nothing in bloom because you cannot hold the trigger anyway. A
	     player who lands headshots is better served by this than by anything
	     automatic; a player who panics is not. ]]
	[Enums.Weapon.M16A4] = {
		id = Enums.Weapon.M16A4,
		displayName = "M16A4",
		modelName = "M16A4",
		slot = Enums.Slot.Primary,
		class = "Rifle",
		fireMode = "Semi",

		damage = 34,
		rpm = 800,
		pellets = 1,
		magSize = 30,
		reserveMax = 300,
		penetration = 2,
		penetrationFalloff = 0.62,

		falloffStart = 220,
		falloffEnd = 650,
		falloffMin = 0.64,
		maxRange = 1300,

		spreadHip = 2.4,
		spreadAim = 0.32,
		spreadMoving = 1.45,
		spreadMax = 6.0,
		bloomPerShot = 0.45,
		bloomRecovery = 7.0,

		recoilVertical = 1.05,
		recoilHorizontal = 0.34,
		recoilRecovery = 11.0,
		kickback = 0.18,

		reloadTime = 2.4,
		reloadPerShell = 0,
		drawTime = 0.5,
		aimTime = 0.22,

		walkSpeedScale = 0.96,
		aimWalkSpeedScale = 0.68,
		aimFov = 58,

		shakeMagnitude = 0.9,
		shakeRoughness = 12,
		tracerWidth = 0.06,
		tracerColor = WHITE_HOT,
		muzzleFlashSize = 1.25,
		shellEject = true,

		gibPower = 0.14,
		dismemberPower = 0.48,
		knockback = 18,
	},

	--[[ The 416 with the barrel cut down: everything the HK416A5 does, half a
	     step quicker to bring up and aim, half a step worse past a courtyard. It
	     is a sidegrade and priced as one — the roster is meant to have weapons you
	     pick because they suit you, not only weapons that are better. ]]
	[Enums.Weapon.HK416D] = {
		id = Enums.Weapon.HK416D,
		displayName = "HK416D",
		modelName = "HK416D",
		slot = Enums.Slot.Primary,
		class = "Rifle",
		fireMode = "Auto",

		damage = 30,
		rpm = 800,
		pellets = 1,
		magSize = 30,
		reserveMax = 330,
		penetration = 2,
		penetrationFalloff = 0.62,

		falloffStart = 210,
		falloffEnd = 630,
		falloffMin = 0.63,
		maxRange = 1250,

		spreadHip = 2.45,
		spreadAim = 0.36,
		spreadMoving = 1.5,
		spreadMax = 6.4,
		bloomPerShot = 0.42,
		bloomRecovery = 6.8,

		recoilVertical = 1.0,
		recoilHorizontal = 0.36,
		recoilRecovery = 10.8,
		kickback = 0.17,

		reloadTime = 2.45,
		reloadPerShell = 0,
		drawTime = 0.5,
		aimTime = 0.22,

		walkSpeedScale = 0.96,
		aimWalkSpeedScale = 0.68,
		aimFov = 60,

		shakeMagnitude = 0.88,
		shakeRoughness = 12,
		tracerWidth = 0.06,
		tracerColor = WHITE_HOT,
		muzzleFlashSize = 1.25,
		shellEject = true,

		gibPower = 0.13,
		dismemberPower = 0.46,
		knockback = 17,
	},

	--[[ A 7.62 battle rifle: the bridge between the assault rifles and the
	     marksman guns, and the only automatic weapon that punches through three
	     bodies. Twenty rounds and real climb are what it pays for that — it is not
	     a rifle you spray, it is one you fire in threes down a corridor full of
	     them. ]]
	[Enums.Weapon.HK417] = {
		id = Enums.Weapon.HK417,
		displayName = "HK417",
		modelName = "HK417",
		slot = Enums.Slot.Primary,
		class = "Rifle",
		fireMode = "Auto",

		damage = 46,
		rpm = 600,
		pellets = 1,
		magSize = 20,
		reserveMax = 220,
		penetration = 3,
		penetrationFalloff = 0.7,

		falloffStart = 260,
		falloffEnd = 800,
		falloffMin = 0.7,
		maxRange = 1600,

		spreadHip = 2.8,
		spreadAim = 0.4,
		spreadMoving = 1.7,
		spreadMax = 7.0,
		bloomPerShot = 0.6,
		bloomRecovery = 6.0,

		recoilVertical = 1.9,
		recoilHorizontal = 0.5,
		recoilRecovery = 9.0,
		kickback = 0.26,

		reloadTime = 2.7,
		reloadPerShell = 0,
		drawTime = 0.58,
		aimTime = 0.26,

		walkSpeedScale = 0.94,
		aimWalkSpeedScale = 0.65,
		aimFov = 56,

		shakeMagnitude = 1.15,
		shakeRoughness = 12,
		tracerWidth = 0.07,
		tracerColor = AMBER,
		muzzleFlashSize = 1.4,
		shellEject = true,

		gibPower = 0.2,
		dismemberPower = 0.6,
		knockback = 24,
	},

	--[[ The first of two light machine guns, and a genuinely new shape in the
	     roster: a hundred rounds means you do not stop, and not stopping is the
	     only answer to a horde that does not stop either. Everything else about it
	     is the bill for that. It is the least accurate thing you can carry from
	     the hip, the slowest to bring up, and when it finally runs dry you are
	     unarmed for four and a half seconds — which is longer than a Hunter needs
	     to cross a room. ]]
	[Enums.Weapon.M249] = {
		id = Enums.Weapon.M249,
		displayName = "M249",
		modelName = "M249",
		slot = Enums.Slot.Primary,
		class = "LMG",
		fireMode = "Auto",

		damage = 28,
		rpm = 800,
		pellets = 1,
		magSize = 100,
		reserveMax = 400,
		penetration = 3,
		penetrationFalloff = 0.68,

		falloffStart = 200,
		falloffEnd = 700,
		falloffMin = 0.6,
		maxRange = 1400,

		spreadHip = 3.6,
		spreadAim = 0.9,
		spreadMoving = 2.4,
		spreadMax = 8.5,
		bloomPerShot = 0.35,
		bloomRecovery = 5.0,

		recoilVertical = 1.15,
		recoilHorizontal = 0.55,
		recoilRecovery = 8.5,
		kickback = 0.2,

		reloadTime = 4.6,
		reloadPerShell = 0,
		drawTime = 0.8,
		aimTime = 0.34,

		walkSpeedScale = 0.9,
		aimWalkSpeedScale = 0.58,
		aimFov = 62,

		shakeMagnitude = 1.0,
		shakeRoughness = 13,
		tracerWidth = 0.065,
		tracerColor = AMBER,
		muzzleFlashSize = 1.5,
		shellEject = true,

		gibPower = 0.15,
		dismemberPower = 0.5,
		knockback = 20,
	},

	--[[ The other one, and the heavier answer: 7.62 at two thirds the rate. Where
	     the M249 wins by never stopping, this wins by what each round does on the
	     way through — thirty-eight a hit through three bodies is a wall of fire
	     that a horde walks into rather than through. Slowest weapon in the game to
	     raise, aim, move with and reload; there is no version of carrying it that
	     is not a commitment. ]]
	[Enums.Weapon.M60E4] = {
		id = Enums.Weapon.M60E4,
		displayName = "M60E4",
		modelName = "M60E4",
		slot = Enums.Slot.Primary,
		class = "LMG",
		fireMode = "Auto",

		damage = 38,
		rpm = 550,
		pellets = 1,
		magSize = 100,
		reserveMax = 400,
		penetration = 3,
		penetrationFalloff = 0.72,

		falloffStart = 220,
		falloffEnd = 750,
		falloffMin = 0.65,
		maxRange = 1500,

		spreadHip = 3.9,
		spreadAim = 1.0,
		spreadMoving = 2.6,
		spreadMax = 9.0,
		bloomPerShot = 0.4,
		bloomRecovery = 4.6,

		recoilVertical = 1.7,
		recoilHorizontal = 0.65,
		recoilRecovery = 7.8,
		kickback = 0.28,

		reloadTime = 5.0,
		reloadPerShell = 0,
		drawTime = 0.9,
		aimTime = 0.38,

		walkSpeedScale = 0.88,
		aimWalkSpeedScale = 0.55,
		aimFov = 62,

		shakeMagnitude = 1.3,
		shakeRoughness = 13,
		tracerWidth = 0.07,
		tracerColor = AMBER,
		muzzleFlashSize = 1.7,
		shellEject = true,

		gibPower = 0.22,
		dismemberPower = 0.62,
		knockback = 26,
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

	--[[ Twenty rounds of marksman rifle, which is the whole argument against the
	     M1A beside it: slightly less per shot, and you can miss twice without it
	     mattering. The one marksman weapon that can hold a lane on its own. ]]
	[Enums.Weapon.MK11] = {
		id = Enums.Weapon.MK11,
		displayName = "MK11 Mod 0",
		modelName = "MK11 Mod 0",
		slot = Enums.Slot.Primary,
		class = "Marksman",
		fireMode = "Semi",

		damage = 78,
		rpm = 260,
		pellets = 1,
		magSize = 20,
		reserveMax = 180,
		penetration = 3,
		penetrationFalloff = 0.78,

		falloffStart = 300,
		falloffEnd = 1000,
		falloffMin = 0.78,
		maxRange = 2000,

		spreadHip = 3.2,
		spreadAim = 0.16,
		spreadMoving = 2.2,
		spreadMax = 7.5,
		bloomPerShot = 0.9,
		bloomRecovery = 5.5,

		recoilVertical = 2.4,
		recoilHorizontal = 0.5,
		recoilRecovery = 8.0,
		kickback = 0.32,

		reloadTime = 2.8,
		reloadPerShell = 0,
		drawTime = 0.62,
		aimTime = 0.3,

		walkSpeedScale = 0.93,
		aimWalkSpeedScale = 0.6,
		aimFov = 44,

		shakeMagnitude = 1.4,
		shakeRoughness = 12,
		tracerWidth = 0.08,
		tracerColor = AMBER,
		muzzleFlashSize = 1.6,
		shellEject = true,

		gibPower = 0.3,
		dismemberPower = 0.75,
		knockback = 30,
	},

	--[[ Bolt-action, in a game about being surrounded — which sounds like a joke
	     and is the most demanding weapon here. Fifty rounds a minute is one shot
	     roughly every second and a bit, and it has five before a reload. What it
	     buys is the hardest hit in the game and the tightest cone: at 95 a body
	     shot and 380 a head, it removes a Special from across a street before the
	     Special has decided who to jump.

	     Fifty RPM is the fire mode. There is no "Bolt" in FireMode and there does
	     not need to be — a Semi that can only be fired once a second IS a bolt
	     gun from the player's side of the screen, and inventing a fourth mode
	     would mean every service that switches on one growing a branch that
	     behaves exactly like Semi. ]]
	[Enums.Weapon.M24] = {
		id = Enums.Weapon.M24,
		displayName = "M24 Sniper",
		modelName = "M24 Sniper",
		slot = Enums.Slot.Primary,
		class = "Marksman",
		fireMode = "Semi",

		damage = 95,
		rpm = 50,
		pellets = 1,
		magSize = 5,
		reserveMax = 60,
		penetration = 3,
		penetrationFalloff = 0.85,

		falloffStart = 350,
		falloffEnd = 1200,
		falloffMin = 0.85,
		maxRange = 2400,

		spreadHip = 4.2,
		spreadAim = 0.1,
		spreadMoving = 3.0,
		spreadMax = 8.0,
		bloomPerShot = 1.2,
		bloomRecovery = 4.0,

		recoilVertical = 3.2,
		recoilHorizontal = 0.5,
		recoilRecovery = 6.5,
		kickback = 0.45,

		reloadTime = 3.2,
		reloadPerShell = 0,
		drawTime = 0.75,
		aimTime = 0.38,

		walkSpeedScale = 0.92,
		aimWalkSpeedScale = 0.55,
		aimFov = 36,

		shakeMagnitude = 1.8,
		shakeRoughness = 12,
		tracerWidth = 0.09,
		tracerColor = AMBER,
		muzzleFlashSize = 1.8,
		shellEject = true,

		gibPower = 0.35,
		dismemberPower = 0.85,
		knockback = 36,
	},

	--[[ Costs no ammo and never runs dry, takes heads off cleanly, and moves
	     you faster than any gun does. To use it you have to be inside claw
	     range, which is the entire balance. Handled by MeleeService, not the
	     ballistics path — the round-related fields below are unused. ]]
	[Enums.Weapon.Machete] = {
		id = Enums.Weapon.Machete,
		displayName = "Machete",
		modelName = "Machete",
		slot = Enums.Slot.Melee,
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

	--[[ Slow and enormous. One swing takes a Common apart at the shoulder and
	     keeps going into the one behind it. The heaviest thing here, and the
	     one most likely to get you killed if you miss. ]]
	[Enums.Weapon.FireAxe] = {
		id = Enums.Weapon.FireAxe,
		displayName = "Fire Axe",
		modelName = "Fire Axe",
		slot = Enums.Slot.Melee,
		class = "Melee",
		fireMode = "Melee",

		damage = 420,
		rpm = 55,
		pellets = 1,
		magSize = 0,
		reserveMax = 0,
		--[[ `penetration` is the target CAP for a swing, not armour piercing —
		     MeleeService reads it as how many bodies one arc goes through. It is
		     the single number that separates these five from each other. ]]
		penetration = 4,
		penetrationFalloff = 0.9,

		falloffStart = 13,
		falloffEnd = 17,
		falloffMin = 1.0,
		maxRange = 17,

		spreadHip = 0,
		spreadAim = 0,
		spreadMoving = 0,
		spreadMax = 0,
		bloomPerShot = 0,
		bloomRecovery = 0,

		recoilVertical = 0,
		recoilHorizontal = 0,
		recoilRecovery = 0,
		kickback = 0.5,

		reloadTime = 0,
		reloadPerShell = 0,
		drawTime = 0.3,
		aimTime = 0.1,

		walkSpeedScale = 1.02,
		aimWalkSpeedScale = 1.0,
		aimFov = 70,

		shakeMagnitude = 1.5,
		shakeRoughness = 7,
		tracerWidth = 0,
		tracerColor = WHITE_HOT,
		muzzleFlashSize = 0,
		shellEject = false,

		gibPower = 0.55,
		dismemberPower = 1.0,
		knockback = 34,
	},

	--[[ No edge, so nothing comes off — but it sends them. The bat is the
	     crowd-control melee: wide arc, real knockback, and the bodies it hits
	     land on the ones behind them. ]]
	[Enums.Weapon.BaseballBat] = {
		id = Enums.Weapon.BaseballBat,
		displayName = "Baseball Bat",
		modelName = "Baseball Bat",
		slot = Enums.Slot.Melee,
		class = "Melee",
		fireMode = "Melee",

		damage = 300,
		rpm = 80,
		pellets = 1,
		magSize = 0,
		reserveMax = 0,
		--[[ `penetration` is the target CAP for a swing, not armour piercing —
		     MeleeService reads it as how many bodies one arc goes through. It is
		     the single number that separates these five from each other, so the
		     roster runs 1 to 5 with no two sharing a value: knife 1, pipe 2,
		     machete 3, axe 4, bat 5. verify_melee fails the build if two ever
		     collide, which is how the axe and the machete were caught both
		     sitting on 3. ]]
		penetration = 5,
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
		kickback = 0.35,

		reloadTime = 0,
		reloadPerShell = 0,
		drawTime = 0.3,
		aimTime = 0.1,

		walkSpeedScale = 1.06,
		aimWalkSpeedScale = 1.0,
		aimFov = 70,

		shakeMagnitude = 1.2,
		shakeRoughness = 7,
		tracerWidth = 0,
		tracerColor = WHITE_HOT,
		muzzleFlashSize = 0,
		shellEject = false,

		gibPower = 0.15,
		dismemberPower = 0.0,
		knockback = 62,
	},

	--[[ Heavy and short. Fewer targets per swing than the bat and considerably
	     more damage into each of them — the one to carry if what keeps killing
	     you is a Hunter rather than a crowd. ]]
	[Enums.Weapon.LeadPipe] = {
		id = Enums.Weapon.LeadPipe,
		displayName = "Lead Pipe",
		modelName = "Pipe",
		slot = Enums.Slot.Melee,
		class = "Melee",
		fireMode = "Melee",

		damage = 380,
		rpm = 70,
		pellets = 1,
		magSize = 0,
		reserveMax = 0,
		--[[ `penetration` is the target CAP for a swing, not armour piercing —
		     MeleeService reads it as how many bodies one arc goes through. It is
		     the single number that separates these five from each other. ]]
		penetration = 2,
		penetrationFalloff = 0.9,

		falloffStart = 10,
		falloffEnd = 14,
		falloffMin = 1.0,
		maxRange = 14,

		spreadHip = 0,
		spreadAim = 0,
		spreadMoving = 0,
		spreadMax = 0,
		bloomPerShot = 0,
		bloomRecovery = 0,

		recoilVertical = 0,
		recoilHorizontal = 0,
		recoilRecovery = 0,
		kickback = 0.4,

		reloadTime = 0,
		reloadPerShell = 0,
		drawTime = 0.3,
		aimTime = 0.1,

		walkSpeedScale = 1.04,
		aimWalkSpeedScale = 1.0,
		aimFov = 70,

		shakeMagnitude = 1.3,
		shakeRoughness = 7,
		tracerWidth = 0,
		tracerColor = WHITE_HOT,
		muzzleFlashSize = 0,
		shellEject = false,

		gibPower = 0.3,
		dismemberPower = 0.35,
		knockback = 44,
	},

	--[[ The fastest swing in the game and the shortest reach in it. Almost
	     twice the machete's rate, one body at a time, and you have to be close
	     enough that being wrong about the timing is fatal. ]]
	[Enums.Weapon.Knife] = {
		id = Enums.Weapon.Knife,
		displayName = "Combat Knife",
		modelName = "Knife",
		slot = Enums.Slot.Melee,
		class = "Melee",
		fireMode = "Melee",

		damage = 260,
		rpm = 150,
		pellets = 1,
		magSize = 0,
		reserveMax = 0,
		--[[ `penetration` is the target CAP for a swing, not armour piercing —
		     MeleeService reads it as how many bodies one arc goes through. It is
		     the single number that separates these five from each other. ]]
		penetration = 1,
		penetrationFalloff = 0.9,

		falloffStart = 7,
		falloffEnd = 11,
		falloffMin = 1.0,
		maxRange = 11,

		spreadHip = 0,
		spreadAim = 0,
		spreadMoving = 0,
		spreadMax = 0,
		bloomPerShot = 0,
		bloomRecovery = 0,

		recoilVertical = 0,
		recoilHorizontal = 0,
		recoilRecovery = 0,
		kickback = 0.2,

		reloadTime = 0,
		reloadPerShell = 0,
		drawTime = 0.3,
		aimTime = 0.1,

		walkSpeedScale = 1.1,
		aimWalkSpeedScale = 1.0,
		aimFov = 70,

		shakeMagnitude = 0.7,
		shakeRoughness = 7,
		tracerWidth = 0,
		tracerColor = WHITE_HOT,
		muzzleFlashSize = 0,
		shellEject = false,

		gibPower = 0.1,
		dismemberPower = 0.85,
		knockback = 18,
	},
	--[[
		The flamethrower. Not sold anywhere, and the only weapon in the game whose
		damage is mostly what happens after it hits.

		── WHY IT IS AN "AUTO" AND NOT A FIFTH FIRE MODE ────────────────────────
		A continuous stream sounds like new machinery and is not. Twelve pellets a
		shot at 600rpm inside a 22-degree cone that stops at 42 studs IS a cone of
		fire, drawn by the tracer pool that already exists, hit-tested by the
		ballistics that already exist, and falling off at a range the config
		already understands. A fifth firing path would have bought a slightly
		better-looking flame and a second copy of every hit rule.

		── THE DAMAGE IS DELIBERATELY BAD ──────────────────────────────────────
		2 per pellet, eight pellets, ten times a second: 160 a second against a
		body that is touching you. The shotgun does 288 and the M249 does 373, so
		this is the WORST close-range weapon in the game measured the way weapons
		are usually measured — and by 42 studs falloffMin has taken it to 24.

		That is correct, and it is worth stating because the first version of
		these numbers was 480 and quietly made a vault reward the best gun in the
		building. The number that matters is `ignites`: a burning Common takes
		25-45 a second until it dies whatever you do next, and eight pellets
		cannot stack that because InfectedService:ignite refuses a body already
		alight. The weapon's job is to set a crowd on fire and get out of the way,
		not to kill the thing in front of it.

		It cannot light a boss — DamageService refuses that for the same reason
		the Incendiary requisition does, and the Apex is why.

		── AND IT HOLDS 100 WITH NO RESERVE ────────────────────────────────────
		A tank of fuel, and when it is gone it is gone: there is no flamethrower
		ammunition anywhere in the game and an ammo crate will not refill it. One
		vault, one tank, and the decision of which wave to spend it on.
	]]
	[Enums.Weapon.Flamethrower] = {
		id = Enums.Weapon.Flamethrower,
		displayName = "Flamethrower",
		modelName = "Flamethrower",
		slot = Enums.Slot.Primary,
		class = "Special",
		fireMode = "Auto",

		damage = 2,
		rpm = 600,
		--[[ Eight, not twelve. The cone reads the same and the arithmetic does
		     not: see the header for what twelve did. ]]
		pellets = 8,
		--[[ Ten seconds of fuel at 600rpm, and no way to get more. A burst of
		     power you found once, spent on the wave you chose. ]]
		magSize = 100,
		--[[ Nothing. See the header: an ammo crate refills a reserve, and a
		     flamethrower that could be topped up at a crate would be a permanent
		     upgrade rather than a thing you found once. ]]
		reserveMax = 0,
		penetration = 3,
		penetrationFalloff = 1.0,

		--[[ Falls off almost immediately and is worthless past forty studs. Fire
		     is a room-clearing weapon and a flamethrower that reached across a
		     street would replace every other primary. ]]
		falloffStart = 18,
		falloffEnd = 42,
		falloffMin = 0.15,
		maxRange = 42,

		--[[ A wide cone rather than a spread. Aiming does not tighten it much,
		     because pointing a flamethrower carefully is not a skill the weapon
		     has — the cone IS the weapon. ]]
		spreadHip = 11.0,
		spreadAim = 8.0,
		spreadMoving = 12.0,
		spreadMax = 13.0,
		bloomPerShot = 0.0,
		bloomRecovery = 8.0,

		--[[ Almost no recoil. There is no bullet leaving it, and a kick would
		     make the one thing it does — hold a cone on a doorway — fight the
		     player holding it. ]]
		recoilVertical = 0.12,
		recoilHorizontal = 0.06,
		recoilRecovery = 12.0,
		kickback = 0.05,

		reloadTime = 4.2,
		reloadPerShell = 0,
		drawTime = 1.0,
		aimTime = 0.4,

		walkSpeedScale = 0.9,
		aimWalkSpeedScale = 0.6,
		aimFov = 68,

		shakeMagnitude = 0.35,
		shakeRoughness = 6,
		--[[ Fat, short and orange. Eight of these a shot inside a 22-degree cone
		     is what makes the tracer pool read as fire rather than as gunfire. ]]
		tracerWidth = 0.5,
		tracerColor = FLAME,
		muzzleFlashSize = 2.4,
		shellEject = false,

		--[[ It sets things alight and it does not blow them apart. A body that
		     burned to death should be a charred body, which is what GoreConfig
		     already draws for a burn kill. ]]
		gibPower = 0.0,
		dismemberPower = 0.0,
		knockback = 4,

		--[[ The whole point of the weapon, and the one line that makes it one.
		     See DamageService: the same ignite the molotov uses. ]]
		ignites = true,

		--[[ Never on a shop shelf and never on an item pad. It exists in exactly
		     one place — the floor of the vault — and putting it anywhere else
		     would undo the reason anybody solves the puzzle. ]]
		placeable = false,
		floorOnly = true,
		price = 0,
	},

	--[[
		── BRICKBATTLER'S PACK ──────────────────────────────────────────────────
		Four of the seven classic tools, translated rather than transplanted.

		Their own numbers are brickbattle numbers — 5, 8, 25 — measured against a
		hundred-health PLAYER. A Common here has fifty health and `damage` reads
		directly as a shots-to-kill count, so porting them literally would make
		the paintball gun a ten-shot kill and the sword a joke. What is preserved
		is the RELATIONSHIP between them: the paintball sprays and barely stings,
		the slingshot is one flat precise shot, the sword is fast and close, the
		rocket removes a doorway.

		── DELIBERATELY SIDEGRADES ──────────────────────────────────────────────
		Every one of these is payable-for in Robux, which makes their power a
		fairness question rather than a taste one. So each sits BESIDE something
		already in the roster rather than above it: the paintball gun trades the
		MP7A1's damage for rate, the slingshot trades the Magnum's punch for a
		flat trajectory and no recoil, the sword trades the Machete's reach for
		speed, and the rocket is a smaller RPG-7 that does not delete a Tank.

		A hundred Robux buys VARIETY. It does not buy past the Dollars economy,
		and it must not: the RPG-7 costs ten won rounds and would be worth
		nothing the day a cheaper one could be bought with money.

		placeable = false on all four, for the reason the RPG-7 gives — a Director
		that leaves a paid weapon on a shelf has not made it cheaper, it has made
		the price meaningless.
	]]

	--[[ Fast, short and light. The Machete's damage at nearly twice the swing
	     rate, and it gives up all of the Machete's reach for it: this is a duel
	     weapon for a corridor, not a crowd-clearer. ]]
	[Enums.Weapon.ClassicSword] = {
		id = Enums.Weapon.ClassicSword,
		displayName = "Classic Sword",
		modelName = "ClassicSword",
		slot = Enums.Slot.Melee,
		class = "Melee",
		fireMode = "Melee",
		passOnly = true,
		placeable = false,

		damage = 300,
		rpm = 150,
		pellets = 1,
		magSize = 0,
		reserveMax = 0,
		penetration = 1,
		penetrationFalloff = 0.85,

		falloffStart = 9,
		falloffEnd = 12,
		falloffMin = 1.0,
		maxRange = 12,

		spreadHip = 0,
		spreadAim = 0,
		spreadMoving = 0,
		spreadMax = 0,
		bloomPerShot = 0,
		bloomRecovery = 0,

		recoilVertical = 0,
		recoilHorizontal = 0,
		recoilRecovery = 0,
		kickback = 0.22,

		reloadTime = 0,
		reloadPerShell = 0,
		drawTime = 0.22,
		aimTime = 0.1,

		walkSpeedScale = 1.1,
		aimWalkSpeedScale = 1.0,
		aimFov = 70,

		shakeMagnitude = 0.8,
		shakeRoughness = 6,
		tracerWidth = 0,
		tracerColor = WHITE_HOT,
		muzzleFlashSize = 0,
		shellEject = false,

		gibPower = 0.15,
		dismemberPower = 1.0,
		knockback = 18,
	},

	--[[ Sprays, and barely stings. Four body shots on a Common where an SMG
	     takes three, at a rate no other weapon in the roster matches — the gun
	     for somebody who would rather hold the trigger than aim. ]]
	[Enums.Weapon.ClassicPaintballGun] = {
		id = Enums.Weapon.ClassicPaintballGun,
		displayName = "Classic Paintball Gun",
		modelName = "ClassicPaintballGun",
		slot = Enums.Slot.Primary,
		class = "SMG",
		fireMode = "Auto",
		passOnly = true,
		placeable = false,

		damage = 13,
		rpm = 1000,
		pellets = 1,
		magSize = 60,
		reserveMax = 300,
		penetration = 1,
		penetrationFalloff = 0.6,

		falloffStart = 40,
		falloffEnd = 110,
		falloffMin = 0.45,
		maxRange = 220,

		spreadHip = 3.2,
		spreadAim = 1.5,
		spreadMoving = 1.6,
		spreadMax = 6.5,
		bloomPerShot = 0.22,
		bloomRecovery = 7,

		recoilVertical = 0.24,
		recoilHorizontal = 0.16,
		recoilRecovery = 11,
		kickback = 0.08,

		reloadTime = 2.4,
		reloadPerShell = 0,
		drawTime = 0.34,
		aimTime = 0.19,

		walkSpeedScale = 1.02,
		aimWalkSpeedScale = 0.85,
		aimFov = 62,

		shakeMagnitude = 0.35,
		shakeRoughness = 8,
		tracerWidth = 0.05,
		tracerColor = Color3.fromRGB(120, 220, 140),
		muzzleFlashSize = 0.6,
		shellEject = false,

		gibPower = 0.1,
		dismemberPower = 0.2,
		knockback = 4,
	},

	--[[ One shot, dead flat, no recoil at all — the pellet cancels its own
	     gravity, which is the whole trick and the reason this is a precision
	     weapon rather than a weak one. Two body shots or one head, and then a
	     long wait: the slowest-firing sidearm in the game by a distance. ]]
	[Enums.Weapon.ClassicSlingshot] = {
		id = Enums.Weapon.ClassicSlingshot,
		displayName = "Classic Slingshot",
		modelName = "ClassicSlingshot",
		slot = Enums.Slot.Secondary,
		class = "Pistol",
		fireMode = "Semi",
		passOnly = true,
		placeable = false,

		damage = 32,
		rpm = 75,
		pellets = 1,
		magSize = 12,
		reserveMax = -1,
		penetration = 1,
		penetrationFalloff = 0.7,

		--[[ No falloff worth the name. A pellet that ignores gravity ignores
		     distance too, and that is the sidegrade: it trades the Magnum's
		     stopping power for a shot that lands exactly where it is pointed. ]]
		falloffStart = 150,
		falloffEnd = 260,
		falloffMin = 0.9,
		maxRange = 300,

		spreadHip = 1.1,
		spreadAim = 0,
		spreadMoving = 0.9,
		spreadMax = 2.2,
		bloomPerShot = 0.1,
		bloomRecovery = 9,

		recoilVertical = 0,
		recoilHorizontal = 0,
		recoilRecovery = 14,
		kickback = 0.04,

		reloadTime = 1.6,
		reloadPerShell = 0,
		drawTime = 0.28,
		aimTime = 0.16,

		walkSpeedScale = 1.05,
		aimWalkSpeedScale = 0.9,
		aimFov = 55,

		shakeMagnitude = 0.2,
		shakeRoughness = 5,
		tracerWidth = 0.04,
		tracerColor = Color3.fromRGB(60, 60, 60),
		muzzleFlashSize = 0,
		shellEject = false,

		gibPower = 0.15,
		dismemberPower = 0.3,
		knockback = 6,
	},

	--[[ A smaller RPG-7, and smaller on purpose. That one costs ten won rounds
	     and deletes a Tank; this one clears a doorway and leaves the Tank angry.
	     Two rockets, no resupply beyond a crate's share, and a blast that will
	     take the user with it at close range — which is the classic rocket's own
	     oldest lesson and worth keeping. ]]
	[Enums.Weapon.ClassicRocketLauncher] = {
		id = Enums.Weapon.ClassicRocketLauncher,
		displayName = "Classic Rocket Launcher",
		modelName = "ClassicRocketLauncher",
		slot = Enums.Slot.Secondary,
		class = "Launcher",
		fireMode = "Semi",
		passOnly = true,
		placeable = false,

		blastRadius = 16,
		blastDamage = 170,

		damage = 90,
		rpm = 30,
		pellets = 1,
		magSize = 1,
		reserveMax = 2,
		penetration = 1,
		penetrationFalloff = 1.0,

		falloffStart = 200,
		falloffEnd = 320,
		falloffMin = 1.0,
		maxRange = 360,

		spreadHip = 1.4,
		spreadAim = 0,
		spreadMoving = 1.2,
		spreadMax = 2.6,
		bloomPerShot = 0,
		bloomRecovery = 6,

		recoilVertical = 2.4,
		recoilHorizontal = 0.5,
		recoilRecovery = 5,
		kickback = 1.1,

		reloadTime = 3.4,
		reloadPerShell = 0,
		drawTime = 0.62,
		aimTime = 0.38,

		walkSpeedScale = 0.9,
		aimWalkSpeedScale = 0.68,
		aimFov = 60,

		shakeMagnitude = 3.4,
		shakeRoughness = 9,
		tracerWidth = 0.12,
		tracerColor = Color3.fromRGB(255, 170, 90),
		muzzleFlashSize = 2.4,
		shellEject = false,

		gibPower = 1.0,
		dismemberPower = 1.0,
		knockback = 70,
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
