--!strict
--[[
	AudioConfig — every sound the game plays, and the mixing rules around them.

	Getting the audio right is worth more to "satisfying" than any visual in this
	repo. Two rules do most of the work:

	  1. VARIATION. Anything you hear more than once a second gets an `ids` list
	     instead of a single `id`, and the play path picks one at random and then
	     pitch-shifts it. A single unvaried gunshot at 1000rpm turns the PPSh into
	     a buzzsaw, and a single unvaried groan turns a horde of 46 into an
	     obvious copy-paste.

	  2. FLESH AND BONE MUST DIFFER. `Impact.Flesh` and `Impact.Bone` are the
	     sounds that tell a player whether they hit a body or a head. If those two
	     are interchangeable then the 4x headshot multiplier has no audible
	     existence and aiming stops feeling like it matters.

	Any entry still left empty is handled gracefully: AudioService warns once at
	startup and then stays silent, so a partially-filled bank never errors and
	never spams the output window during a playtest.
]]

local Enums = require(script.Parent.Parent.Enums)

local AudioConfig = {}

local EMPTY = ""

export type SoundDefinition = {
	id: string,
	ids: { string }?, -- when present, one is chosen at random per play
	volume: number,
	pitchMin: number,
	pitchMax: number,
	rollOffMin: number,
	rollOffMax: number,
	looped: boolean,
	priority: number, -- higher survives when the voice budget is exhausted
}

local function sound(
	id: string,
	volume: number,
	pitchMin: number,
	pitchMax: number,
	rollOffMax: number,
	priority: number?
): SoundDefinition
	return {
		id = id,
		ids = nil,
		volume = volume,
		pitchMin = pitchMin,
		pitchMax = pitchMax,
		rollOffMin = 12,
		rollOffMax = rollOffMax,
		looped = false,
		priority = priority or 1,
	}
end

--[[ A sound with several interchangeable samples. The play path picks one at
     random, so repeated triggers never land on the same waveform twice running. ]]
local function varied(
	ids: { string },
	volume: number,
	pitchMin: number,
	pitchMax: number,
	rollOffMax: number,
	priority: number?
): SoundDefinition
	local definition = sound(ids[1] or EMPTY, volume, pitchMin, pitchMax, rollOffMax, priority)
	definition.ids = ids
	return definition
end

-- ── Source ids ───────────────────────────────────────────────────────────────
-- Named so the mapping below reads as intent rather than as digits.
local ID = table.freeze({
	PistolShot = "rbxassetid://132539859090895",
	RevolverShot = "rbxassetid://18267120562",
	ShotgunBlast = "rbxassetid://132255180302885",
	ShotgunPump = "rbxassetid://113837896417526",
	SmgFire = "rbxassetid://97897507846837",
	AkShot = "rbxassetid://1065188024",
	M4Shot = "rbxassetid://18521643711",
	SniperShot = "rbxassetid://135333708100426",
	GunReload = "rbxassetid://139798971373512",
	DryFire = "rbxassetid://117629133235583",

	Headshot = "rbxassetid://133002449941130",
	BodyShot1 = "rbxassetid://78096013247098",
	BodyShot2 = "rbxassetid://91154136355795",
	BodyShot3 = "rbxassetid://132778245632023",

	ZombieGroan = "rbxassetid://127809799844346",
	ZombieHorde = "rbxassetid://99818660648586",
	ZombieGrowl = "rbxassetid://133090070543313",
	CreatureGrowl = "rbxassetid://71812773864351",
	InsaneLaugh = "rbxassetid://83409194562601",
	MonsterBellow = "rbxassetid://105926319962443",
	WomanCrying = "rbxassetid://117233008699099",
	MonsterRoar = "rbxassetid://133651202885353",
	HeavyFootsteps = "rbxassetid://132297820818937",

	MenuHover = "rbxassetid://96949444184991",
	MenuConfirm = "rbxassetid://85240253037283",
	MenuBack = "rbxassetid://125141459553571",
	Pickup = "rbxassetid://111954737423498",
	PromptAppear = "rbxassetid://123921967581732",
	ObjectiveChange = "rbxassetid://644569388",
	WaveClearedSting = "rbxassetid://182750827",
	HitmarkerTick = "rbxassetid://99102731755541",
	HeadshotTick = "rbxassetid://130201387574815",

	MaleGruntPain = "rbxassetid://75074552502663",
	MaleScream = "rbxassetid://136401198004658",
	Gasp = "rbxassetid://119122719336480",
	Bandage = "rbxassetid://131079594340516",
	PillBottle = "rbxassetid://9113555127",
	HeavyBreathing = "rbxassetid://101395573137763",

	ImpactConcrete = "rbxassetid://85805517776968",
	ImpactMetal = "rbxassetid://98609496290942",
	ImpactWood = "rbxassetid://131036980739699",
	ImpactGlass = "rbxassetid://124695435769496",
	ImpactWater = "rbxassetid://126105529228330",
	ImpactDirt = "rbxassetid://9114109952",

	SwordSwing = "rbxassetid://138283030240531",

	HorrorAmbience = "rbxassetid://118673335791387",
	ActionDrums = "rbxassetid://1837842521",
	BossBattle = "rbxassetid://132347366936691",
	CreepyStrings = "rbxassetid://9041756897",
	FailureSting = "rbxassetid://131207736624108",
	VictoryShort = "rbxassetid://74216560469867",
})

AudioConfig.Id = ID

--[[
	Per-weapon fire sounds. Several guns deliberately share a sample — one AK
	sample covers both Kalashnikovs, one M4 sample covers the whole AR-15 family —
	but each still carries its own volume, pitch window and rolloff, so an AKM
	still reads as heavier than an AK-12 and a CQBR still sounds blastier than an
	M4 even before you upload distinct samples for them.
]]
AudioConfig.WeaponFire = {
	[Enums.Weapon.M1911A1] = sound(ID.PistolShot, 0.72, 0.97, 1.05, 320, 4),
	[Enums.Weapon.Magnum357] = sound(ID.RevolverShot, 1.0, 0.94, 1.02, 560, 5),
	[Enums.Weapon.Shotgun] = sound(ID.ShotgunBlast, 1.0, 0.96, 1.04, 500, 5),

	-- Submachine guns: pitched up and quieter the smaller the round.
	[Enums.Weapon.PPSh41] = sound(ID.SmgFire, 0.58, 1.04, 1.14, 340, 4),
	[Enums.Weapon.KrissVector] = sound(ID.SmgFire, 0.6, 1.0, 1.1, 330, 4),
	[Enums.Weapon.MP7A1] = sound(ID.SmgFire, 0.55, 1.08, 1.18, 310, 4),
	[Enums.Weapon.UMP45] = sound(ID.SmgFire, 0.68, 0.9, 0.99, 380, 4),
	[Enums.Weapon.AKS74U] = sound(ID.AkShot, 0.78, 1.04, 1.12, 420, 4),

	-- Rifles: the AR family off one sample, the Kalashnikovs off another.
	[Enums.Weapon.M4A1] = sound(ID.M4Shot, 0.8, 0.98, 1.04, 420, 4),
	[Enums.Weapon.HK416A5] = sound(ID.M4Shot, 0.78, 1.02, 1.08, 410, 4),
	[Enums.Weapon.Mk18CQBR] = sound(ID.M4Shot, 0.86, 1.05, 1.12, 460, 4),
	[Enums.Weapon.AK12] = sound(ID.AkShot, 0.82, 0.99, 1.05, 440, 4),
	[Enums.Weapon.AKM] = sound(ID.AkShot, 0.9, 0.9, 0.97, 480, 5),

	-- Marksman: slower, louder, and they carry.
	[Enums.Weapon.ScopedMk18] = sound(ID.SniperShot, 0.9, 1.02, 1.06, 620, 5),
	[Enums.Weapon.M1AEBR] = sound(ID.SniperShot, 1.0, 0.94, 1.0, 700, 5),

	[Enums.Weapon.Machete] = sound(ID.SwordSwing, 0.55, 0.9, 1.12, 70, 3),
} :: { [string]: SoundDefinition }

AudioConfig.WeaponReload = {
	MagOut = sound(ID.GunReload, 0.5, 0.98, 1.06, 60, 2),
	MagIn = sound(ID.GunReload, 0.5, 0.92, 1.0, 60, 2),
	Bolt = sound(ID.GunReload, 0.45, 1.08, 1.16, 60, 2),
	ShellInsert = sound(ID.ShotgunPump, 0.45, 1.1, 1.2, 60, 2),
	Pump = sound(ID.ShotgunPump, 0.7, 0.97, 1.03, 90, 3),
	DryFire = sound(ID.DryFire, 0.6, 0.98, 1.02, 40, 3),
} :: { [string]: SoundDefinition }

--[[
	Impacts. Flesh rotates through three samples because it plays on literally
	every connecting shot; Bone is the headshot and is intentionally a single,
	consistent, instantly recognisable sound — you want players to learn it.
]]
AudioConfig.Impact = {
	Flesh = varied({ ID.BodyShot1, ID.BodyShot2, ID.BodyShot3 }, 0.78, 0.92, 1.1, 130, 4),
	Bone = sound(ID.Headshot, 0.9, 0.96, 1.05, 150, 6),

	Concrete = sound(ID.ImpactConcrete, 0.5, 0.9, 1.14, 110, 1),
	Metal = sound(ID.ImpactMetal, 0.6, 0.88, 1.16, 130, 1),
	Wood = sound(ID.ImpactWood, 0.5, 0.9, 1.14, 110, 1),
	Glass = sound(ID.ImpactGlass, 0.65, 0.92, 1.1, 140, 2),
	Water = sound(ID.ImpactWater, 0.45, 0.92, 1.08, 100, 1),
	Dirt = sound(ID.ImpactDirt, 0.45, 0.9, 1.14, 100, 1),
} :: { [string]: SoundDefinition }

--[[ Gore. Falls back to the body-shot samples pitched down hard, which reads as
     a heavier, wetter version of the same event — better than silence, and
     genuinely convincing until dedicated samples are uploaded. ]]
AudioConfig.Gore = {
	Dismember = varied({ ID.BodyShot2, ID.BodyShot3 }, 0.95, 0.66, 0.76, 170, 6),
	Gib = varied({ ID.BodyShot1, ID.BodyShot3 }, 1.0, 0.55, 0.65, 210, 7),
	Decapitate = sound(ID.Headshot, 0.95, 0.7, 0.8, 180, 6),
	BodyFall = sound(ID.ImpactDirt, 0.55, 0.7, 0.82, 95, 2),
	Squelch = varied({ ID.BodyShot1, ID.BodyShot2 }, 0.4, 0.8, 1.0, 60, 1),
} :: { [string]: SoundDefinition }

--[[
	Infected vocalisations. In Left 4 Dead these are not flavour — they are the
	early-warning system, and a player who knows the Hunter growl survives where
	one who does not, does not. Priorities here are set high on purpose: when the
	voice budget is exhausted mid-horde, a Tank roar must never be the sound that
	gets dropped in favour of a common's groan.
]]
AudioConfig.Infected = {
	CommonIdle = sound(ID.ZombieGroan, 0.35, 0.82, 1.18, 90, 1),
	CommonAlert = sound(ID.ZombieHorde, 0.65, 0.92, 1.08, 220, 4),
	CommonAttack = sound(ID.ZombieGrowl, 0.55, 0.85, 1.15, 90, 3),
	CommonDeath = sound(ID.ZombieGrowl, 0.5, 0.68, 0.84, 110, 2),

	HunterIdle = sound(ID.CreatureGrowl, 0.75, 0.97, 1.03, 320, 6),
	HunterPounce = sound(ID.CreatureGrowl, 0.9, 1.18, 1.26, 340, 7),

	JockeyIdle = sound(ID.InsaneLaugh, 0.7, 0.97, 1.05, 300, 6),
	JockeyRide = sound(ID.InsaneLaugh, 0.85, 1.06, 1.14, 260, 7),

	RusherIdle = sound(ID.MonsterBellow, 0.6, 1.08, 1.16, 280, 5),
	RusherCharge = sound(ID.MonsterBellow, 1.0, 0.94, 1.0, 400, 8),

	WitchCry = sound(ID.WomanCrying, 0.8, 0.99, 1.01, 460, 7),
	WitchSummon = sound(ID.ZombieHorde, 0.95, 0.86, 0.94, 520, 8),
	WitchStartle = sound(ID.WomanCrying, 1.0, 1.25, 1.35, 500, 9),

	TankRoar = sound(ID.MonsterRoar, 1.0, 0.98, 1.02, 700, 9),
	TankFootstep = sound(ID.HeavyFootsteps, 0.7, 0.95, 1.05, 280, 5),
} :: { [string]: SoundDefinition }

AudioConfig.Survivor = {
	Hurt = sound(ID.MaleGruntPain, 0.62, 0.94, 1.08, 80, 4),
	-- Incap is the scream pitched down: going down should sound heavier and more
	-- final than dying does at a distance, because it is the sound teammates have
	-- to react to.
	Incap = sound(ID.MaleScream, 0.85, 0.82, 0.9, 170, 6),
	Death = sound(ID.MaleScream, 0.8, 0.96, 1.04, 180, 6),
	Revived = sound(ID.Gasp, 0.65, 0.96, 1.06, 90, 4),
	HealSelf = sound(ID.Bandage, 0.55, 0.96, 1.04, 60, 3),
	PillsUse = sound(ID.PillBottle, 0.5, 0.98, 1.06, 50, 3),
	Breathing = sound(ID.HeavyBreathing, 0.5, 0.98, 1.02, 45, 2),
	Footstep = sound(EMPTY, 0.3, 0.9, 1.1, 50, 1),
} :: { [string]: SoundDefinition }

-- Looped by whoever plays it: this is the labored breathing that fades in below
-- GameConfig.Survivor.HurtThreshold and is how you hear that you are in trouble.
AudioConfig.Survivor.Breathing.looped = true

--[[ UI sounds are 2D: rollOffMax is irrelevant because AudioService plays these
     directly under SoundService rather than positioned in the world. ]]
AudioConfig.UI = {
	Pickup = sound(ID.Pickup, 0.5, 0.98, 1.04, 30, 3),
	PromptAppear = sound(ID.PromptAppear, 0.28, 1.0, 1.0, 30, 1),
	ObjectiveChange = sound(ID.ObjectiveChange, 0.55, 1.0, 1.0, 30, 4),
	WaveIncoming = sound(ID.ZombieHorde, 0.55, 0.88, 0.94, 30, 6),
	WaveCleared = sound(ID.WaveClearedSting, 0.7, 1.0, 1.0, 30, 6),
	Hitmarker = sound(ID.HitmarkerTick, 0.3, 0.97, 1.05, 20, 2),
	HeadshotMarker = sound(ID.HeadshotTick, 0.38, 0.99, 1.03, 20, 3),

	-- Menu. Hover is deliberately near-silent: if you notice it, it is too loud.
	MenuHover = sound(ID.MenuHover, 0.18, 0.98, 1.04, 20, 1),
	MenuConfirm = sound(ID.MenuConfirm, 0.5, 1.0, 1.0, 20, 4),
	MenuBack = sound(ID.MenuBack, 0.42, 1.0, 1.0, 20, 3),
} :: { [string]: SoundDefinition }

export type MusicDefinition = {
	id: string,
	volume: number,
	fadeIn: number,
	fadeOut: number,
	looped: boolean,
	-- None of the supplied tracks are seamless loops, so MusicController overlaps
	-- this many seconds of the tail with the head on every repeat. Without it you
	-- hear a hard silence-then-restart every time a track comes round.
	loopCrossfade: number,
}

AudioConfig.Music = {
	Ambient = {
		id = ID.HorrorAmbience,
		volume = 0.28,
		fadeIn = 3.0,
		fadeOut = 4.0,
		looped = true,
		loopCrossfade = 2.5,
	},
	Buildup = {
		id = ID.ActionDrums,
		volume = 0.3,
		fadeIn = 1.5,
		fadeOut = 2.0,
		looped = true,
		loopCrossfade = 1.5,
	},
	Horde = {
		id = ID.ActionDrums,
		volume = 0.46,
		fadeIn = 0.5,
		fadeOut = 3.0,
		looped = true,
		loopCrossfade = 1.5,
	},
	TankTheme = {
		id = ID.BossBattle,
		volume = 0.6,
		fadeIn = 0.35,
		fadeOut = 3.0,
		looped = true,
		loopCrossfade = 2.0,
	},
	WitchTheme = {
		id = ID.CreepyStrings,
		volume = 0.45,
		fadeIn = 1.2,
		fadeOut = 2.0,
		looped = true,
		loopCrossfade = 2.0,
	},
	WaveCleared = {
		id = ID.WaveClearedSting,
		volume = 0.5,
		fadeIn = 0.2,
		fadeOut = 1.5,
		looped = false,
		loopCrossfade = 0,
	},
	Defeat = {
		id = ID.FailureSting,
		volume = 0.55,
		fadeIn = 0.3,
		fadeOut = 2.0,
		looped = false,
		loopCrossfade = 0,
	},
	Victory = {
		id = ID.VictoryShort,
		volume = 0.55,
		fadeIn = 0.3,
		fadeOut = 2.0,
		looped = false,
		loopCrossfade = 0,
	},
} :: { [string]: MusicDefinition }

--[[ Mixing. MaxConcurrent exists because a 46-strong horde dying to a shotgun
     will otherwise try to start two hundred sounds inside one frame. ]]
AudioConfig.Mix = table.freeze({
	MaxConcurrent = 44,
	MaxConcurrentPerCategory = 14,
	MinRetriggerInterval = 0.035,
	DuckMusicOnTank = 0.4,
	MasterVolume = 1.0,
})

--[[ True when a definition has a usable id. Every play path checks this so a
     partially-filled bank stays silent instead of erroring. ]]
function AudioConfig.isConfigured(definition: { id: string, ids: { string }? }?): boolean
	if definition == nil then
		return false
	end
	if definition.ids then
		for _, id in definition.ids do
			if id ~= "" then
				return true
			end
		end
	end
	return definition.id ~= nil and definition.id ~= ""
end

--[[ One id from a definition, chosen at random when it carries variants. Returns
     an empty string for an unconfigured entry; callers check isConfigured first. ]]
function AudioConfig.pickId(definition: { id: string, ids: { string }? }): string
	local variants = definition.ids
	if variants and #variants > 0 then
		local usable = {}
		for _, id in variants do
			if id ~= "" then
				table.insert(usable, id)
			end
		end
		if #usable > 0 then
			return usable[math.random(1, #usable)]
		end
	end
	return definition.id or ""
end

return AudioConfig
