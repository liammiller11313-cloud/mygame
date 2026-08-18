--!strict
--[[
	AudioConfig — every sound the game plays, and the mixing rules around them.

	── READ THIS BEFORE YOU WONDER WHY IT IS QUIET ──────────────────────────────
	Every `rbxassetid://` below is intentionally EMPTY. Sound asset IDs are
	account-specific and cannot be invented — a made-up numeric ID either fails
	to load or, worse, loads somebody else's unrelated audio into your game.

	So: fill these in yourself. Upload or pick audio in Studio, then paste the id
	into the matching field. AudioService degrades gracefully in the meantime —
	it logs each missing id exactly once at startup and then stays silent, so an
	unfinished sound bank never spams the output window during a playtest.

	Getting the audio right is worth more to "satisfying" than any visual in this
	repo. The priority order, if you are filling these in one at a time:
	    1. Weapon fire        the sound you hear most, by an enormous margin
	    2. Flesh impact       the confirmation that you connected
	    3. Gib / dismember    the payoff
	    4. Special infected   the L4D audio tells; these ARE the warning system
	    5. Everything else
]]

local Enums = require(script.Parent.Parent.Enums)

local AudioConfig = {}

local EMPTY = "" -- see the header: fill these in from Studio

export type SoundDefinition = {
	id: string,
	volume: number,
	pitchMin: number,
	pitchMax: number,
	rollOffMin: number,
	rollOffMax: number,
	looped: boolean,
	priority: number, -- higher survives when the voice budget is exhausted
}

local function sound(
	volume: number,
	pitchMin: number,
	pitchMax: number,
	rollOffMax: number,
	priority: number?
)
	return {
		id = EMPTY,
		volume = volume,
		pitchMin = pitchMin,
		pitchMax = pitchMax,
		rollOffMin = 12,
		rollOffMax = rollOffMax,
		looped = false,
		priority = priority or 1,
	} :: SoundDefinition
end

--[[ Per-weapon fire sounds. A slight random pitch spread on every shot is what
     keeps a 900rpm SMG from turning into a machine-gun-shaped buzzsaw. ]]
AudioConfig.WeaponFire = {
	[Enums.Weapon.Pistol] = sound(0.7, 0.96, 1.04, 320, 4),
	[Enums.Weapon.Magnum] = sound(0.95, 0.95, 1.03, 520, 5),
	[Enums.Weapon.SMG] = sound(0.6, 0.94, 1.06, 340, 4),
	[Enums.Weapon.PumpShotgun] = sound(1.0, 0.97, 1.03, 480, 5),
	[Enums.Weapon.AutoShotgun] = sound(0.9, 0.96, 1.04, 460, 5),
	[Enums.Weapon.AssaultRifle] = sound(0.8, 0.95, 1.05, 420, 4),
	[Enums.Weapon.HuntingRifle] = sound(1.0, 0.97, 1.03, 620, 5),
	[Enums.Weapon.Machete] = sound(0.55, 0.9, 1.1, 60, 3),
} :: { [string]: SoundDefinition }

AudioConfig.WeaponReload = {
	MagOut = sound(0.5, 0.95, 1.05, 60, 2),
	MagIn = sound(0.5, 0.95, 1.05, 60, 2),
	Bolt = sound(0.55, 0.95, 1.05, 60, 2),
	ShellInsert = sound(0.5, 0.94, 1.06, 60, 2),
	Pump = sound(0.6, 0.96, 1.04, 80, 3),
	DryFire = sound(0.6, 0.98, 1.02, 40, 3),
} :: { [string]: SoundDefinition }

--[[ Impact sounds, chosen by what the round landed on. The flesh/bone split is
     the one that matters: a headshot must sound different from a body shot, or
     the 4x damage multiplier has no audible existence. ]]
AudioConfig.Impact = {
	Flesh = sound(0.75, 0.9, 1.12, 120, 4),
	Bone = sound(0.85, 0.92, 1.08, 140, 5), -- headshots
	Concrete = sound(0.5, 0.9, 1.12, 110, 1),
	Metal = sound(0.6, 0.9, 1.15, 130, 1),
	Wood = sound(0.5, 0.9, 1.12, 110, 1),
	Glass = sound(0.65, 0.92, 1.1, 140, 2),
	Water = sound(0.45, 0.92, 1.08, 100, 1),
	Dirt = sound(0.45, 0.9, 1.12, 100, 1),
} :: { [string]: SoundDefinition }

AudioConfig.Gore = {
	Dismember = sound(0.9, 0.92, 1.08, 160, 6),
	Gib = sound(1.0, 0.9, 1.1, 200, 7),
	Decapitate = sound(0.95, 0.94, 1.06, 170, 6),
	BodyFall = sound(0.5, 0.9, 1.1, 90, 2),
	Squelch = sound(0.4, 0.85, 1.15, 60, 1),
} :: { [string]: SoundDefinition }

--[[ Special infected vocalisations. In Left 4 Dead these are not flavour, they
     are the entire early-warning system — a player who knows the Hunter growl
     survives, and one who does not, does not. Treat them as gameplay. ]]
AudioConfig.Infected = {
	CommonIdle = sound(0.35, 0.85, 1.15, 90, 1),
	CommonAlert = sound(0.6, 0.9, 1.1, 200, 3),
	CommonAttack = sound(0.55, 0.88, 1.12, 90, 3),
	CommonDeath = sound(0.5, 0.85, 1.15, 110, 2),

	HunterIdle = sound(0.7, 0.97, 1.03, 300, 6),
	HunterPounce = sound(0.9, 1.0, 1.0, 320, 7),
	SmokerIdle = sound(0.7, 0.97, 1.03, 320, 6), -- the cough
	SmokerTongue = sound(0.8, 1.0, 1.0, 300, 7),
	BoomerIdle = sound(0.7, 0.97, 1.03, 260, 6),
	BoomerExplode = sound(1.0, 0.95, 1.05, 320, 8),
	ChargerIdle = sound(0.75, 0.97, 1.03, 320, 6),
	ChargerCharge = sound(0.95, 1.0, 1.0, 380, 8),
	WitchCry = sound(0.85, 0.99, 1.01, 420, 7), -- audible long before you see her
	WitchStartle = sound(1.0, 1.0, 1.0, 500, 9),
	TankRoar = sound(1.0, 1.0, 1.0, 700, 9),
	TankFootstep = sound(0.7, 0.95, 1.05, 260, 5),
} :: { [string]: SoundDefinition }

AudioConfig.Survivor = {
	Hurt = sound(0.6, 0.95, 1.05, 80, 4),
	Incap = sound(0.8, 1.0, 1.0, 160, 6),
	Death = sound(0.8, 1.0, 1.0, 180, 6),
	Revived = sound(0.6, 1.0, 1.0, 90, 4),
	HealSelf = sound(0.55, 1.0, 1.0, 60, 3),
	PillsUse = sound(0.5, 1.0, 1.0, 50, 3),
	Breathing = sound(0.5, 1.0, 1.0, 40, 2), -- looped while below the hurt line
	Footstep = sound(0.3, 0.9, 1.1, 50, 1),
} :: { [string]: SoundDefinition }

AudioConfig.UI = {
	Pickup = sound(0.5, 1.0, 1.0, 30, 3),
	PromptAppear = sound(0.3, 1.0, 1.0, 30, 1),
	ObjectiveChange = sound(0.6, 1.0, 1.0, 30, 4),
	SafeRoomReached = sound(0.8, 1.0, 1.0, 40, 6),
	Hitmarker = sound(0.35, 1.0, 1.0, 20, 2),
	HeadshotMarker = sound(0.45, 1.0, 1.0, 20, 3),
} :: { [string]: SoundDefinition }

--[[ Music. The Director drives these; each cue is looped and cross-faded rather
     than triggered, so pacing changes glide instead of cutting. ]]
AudioConfig.Music = {
	Ambient = { id = EMPTY, volume = 0.25, fadeIn = 3.0, fadeOut = 4.0, looped = true },
	Buildup = { id = EMPTY, volume = 0.35, fadeIn = 1.5, fadeOut = 2.5, looped = true },
	Horde = { id = EMPTY, volume = 0.5, fadeIn = 0.4, fadeOut = 3.0, looped = true },
	TankTheme = { id = EMPTY, volume = 0.6, fadeIn = 0.3, fadeOut = 3.0, looped = true },
	WitchTheme = { id = EMPTY, volume = 0.45, fadeIn = 1.0, fadeOut = 2.0, looped = true },
	SafeRoom = { id = EMPTY, volume = 0.4, fadeIn = 1.0, fadeOut = 2.0, looped = true },
	Defeat = { id = EMPTY, volume = 0.5, fadeIn = 0.5, fadeOut = 2.0, looped = false },
	Victory = { id = EMPTY, volume = 0.5, fadeIn = 0.5, fadeOut = 2.0, looped = false },
}

--[[ Mixing. `MaxConcurrent` exists because a 46-strong horde dying to an auto
     shotgun will otherwise try to start two hundred sounds in one frame. ]]
AudioConfig.Mix = table.freeze({
	MaxConcurrent = 44,
	MaxConcurrentPerCategory = 14,
	MinRetriggerInterval = 0.035, -- same sound cannot restart faster than this
	DuckMusicOnTank = 0.4,
	MasterVolume = 1.0,
})

--[[ True when an id has actually been filled in. Every play path checks this so
     an empty bank is silent rather than erroring. ]]
function AudioConfig.isConfigured(definition: { id: string }?): boolean
	return definition ~= nil and definition.id ~= nil and definition.id ~= ""
end

return AudioConfig
