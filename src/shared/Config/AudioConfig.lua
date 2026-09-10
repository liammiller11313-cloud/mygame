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
	ShotgunBlast = "rbxassetid://7244956099",
	ShotgunPump = "rbxassetid://113837896417526",
	--[[ The shotgun's own reload. It is the only shell-by-shell weapon in the
	     game, so ShellInsert below is already exclusively its — if a second one
	     is ever added, that entry needs splitting rather than sharing. ]]
	ShotgunShell = "rbxassetid://799917192",
	SmgFire = "rbxassetid://97897507846837",
	--[[ Two halves of one weapon, because the flamethrower is the only thing in
	     the game that makes a CONTINUOUS noise. The burst is per shot the way
	     every other gun's is; the loop is a sustained bed under it that starts
	     when the trigger goes down and stops when it comes up. Either alone is
	     wrong: ten bursts a second with no bed is a nailgun, and a loop with no
	     bursts has no attack. ]]
	FlamethrowerBurst = "rbxassetid://129504465599355",
	FlamethrowerLoop = "rbxassetid://108835547890095",
	--[[
		The Tesla Rifle, in six pieces — the only weapon in the game with a voice
		of its own rather than a shot and a share of the common reload bank.

		It earns that because none of the shared cues are true of it. It has no
		magazine to drop and no bolt to release, so MagOut and MagIn would be a
		gun noise from a gun that is not there; it has no round to fail to
		chamber, so the dry click is wrong; and it is the one weapon a player
		picks up ONCE a round, off the floor of a room they walked five
		generators for, which is a moment worth a sound.

		See AudioConfig.WeaponVoice for how they are wired, and note the rule
		there: a weapon with a voice uses ONLY that voice. Nothing here falls
		back to the common bank, because falling back is how a weapon with no
		magazine ends up dropping one.
	]]
	TeslaArc = "rbxassetid://7554632797",
	TeslaCharge = "rbxassetid://87894569924328",
	TeslaRecharge = "rbxassetid://118206070547709",
	TeslaHum = "rbxassetid://109938838638994",
	TeslaEmpty = "rbxassetid://17871250897",
	TeslaDraw = "rbxassetid://130114397986399",

	--[[ Zombieville's generators, and the room they open. Seven cues, and the
	     first three of them are the ones that matter: before these the objective
	     sounded like a MENU — every breaker thrown was the same tick as scrolling
	     a shop row, and a generator coming online made no noise in the world at
	     all, so three teammates across the map learned about it from a counter
	     and a subtitle. ]]
	GeneratorStart = "rbxassetid://136132917853307",
	GeneratorRun = "rbxassetid://86780554044335",
	GateOpen = "rbxassetid://6326763024",
	PanelPress = "rbxassetid://9119717523",
	PanelFault = "rbxassetid://85047859986879",
	PanelSolved = "rbxassetid://4612374393",
	PanelOpen = "rbxassetid://86103958267078",
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
	--[[ The kill. This was the last cue still borrowing another sample — it was
	     HitmarkerTick pitched down to 0.74-0.80 to fake a heavier version of the
	     hit it had to be told apart from. ]]
	KillThump = "rbxassetid://9119319842",

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

	--[[ Melee. One swing per weapon rather than one shared whoosh pitched five
	     ways, which is what these replaced — an axe and a knife cutting air are
	     not the same sound, and no amount of pitch-shifting made them one.
	     SwordSwing is kept as the fallback for a melee added without its own. ]]
	SwordSwing = "rbxassetid://138283030240531",
	AxeSwing = "rbxassetid://101868407541328",
	PipeSwing = "rbxassetid://135932118153895",
	BatSwing = "rbxassetid://9113305619",
	KnifeSlash = "rbxassetid://101542904500316",
	MacheteSwing = "rbxassetid://115206275821196",

	--[[ What a melee sounds like when it LANDS, split by what did the landing.
	     Every melee hit used to be the generic body-shot sample, so a pipe and a
	     machete connecting were the same event to the ear. ]]
	BluntFlesh = "rbxassetid://94957229024343",
	BladeFlesh = "rbxassetid://135341970445862",

	--[[ A Tank or a Witch going down: long enough to be a moment rather than a
	     tick, and played for the whole team, not just whoever landed the shot. ]]
	BossKillSting = "rbxassetid://72245120500468",
	MeleeDraw = "rbxassetid://117878219790008",
	MenuPage = "rbxassetid://9120984892",

	--[[ Random events. The siren is the one the whole system announces itself
	     with and is a real upload; the other two are stand-ins named honestly —
	     see AudioConfig.Event, which is where to put real ids when there are
	     any. ]]
	EventSiren = "rbxassetid://121756878891042",

	--[[ Footsteps. Two ids, because a walk and a run are different sounds rather
	     than the same sound played faster — see AudioConfig.Footstep. ]]
	FootstepWalk = "rbxassetid://4416041299",
	FootstepSprint = "rbxassetid://79250663775359",

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
	--[[ A held roar rather than a shot. Rolls off shorter than a rifle because
	     the weapon does — nobody two streets away should hear a flamethrower —
	     and the voice budget is low so twelve pellets a shot cannot each try to
	     be a sound. ]]
	--[[ The per-shot half. Quiet and low-priority on purpose: it fires ten times
	     a second, so it is a texture over the loop rather than the sound of the
	     weapon, and a budget of 2 means the ones that would have stacked are
	     dropped instead of turning into a wall. ]]
	[Enums.Weapon.Flamethrower] = sound(ID.FlamethrowerBurst, 0.38, 0.96, 1.04, 120, 2),
	--[[ Loud, high and carrying. The opposite mix to the flamethrower above it
	     for the same reason the weapons are opposites: this fires under three
	     times a second, so each one IS the sound of the weapon rather than a
	     texture, and it reaches as far as the bolt does. Priority 5, so a crack
	     is never the voice that gets dropped.

	     The pitch window sits either side of 1.0 now. It was 1.24-1.40 while the
	     id was the glass-impact stand-in, which needed pitching up hard to read
	     as electrical at all — with a real arc that would be shifting a sample
	     away from the register it was recorded in for no reason. A narrow window
	     rather than none, because two cracks a second at exactly one pitch is a
	     machine rather than a weapon. ]]
	[Enums.Weapon.TeslaRifle] = sound(ID.TeslaArc, 0.85, 0.95, 1.06, 520, 5),
	--[[ The shotgun sample, pitched a long way down and thrown a long way out.

	     Black powder is the loudest thing in this game and the sample nearest to
	     it is the 12-gauge; dropped into the 0.72-0.80 window it stops reading as
	     buckshot and starts reading as a charge going off in a tube. 620 studs
	     is further than anything else fires, deliberately — one player firing
	     this in a maze of identical corridors should be a thing the other three
	     hear and can walk towards. ]]
	[Enums.Weapon.FlintLock] = sound(ID.ShotgunBlast, 1.0, 0.72, 0.8, 620, 5),
	[Enums.Weapon.M1911A1] = sound(ID.PistolShot, 0.72, 0.97, 1.05, 320, 4),
	[Enums.Weapon.Magnum357] = sound(ID.RevolverShot, 1.0, 0.94, 1.02, 560, 5),
	--[[ These four shipped with no row and this table is indexed directly — no
	     fallback, no warning — so all four fired in silence. The Berettas and the
	     Glock are the pistol sample pitched up for 9mm; the Sawn-Off is a shotgun
	     with both barrels, which is the loudest thing a sidearm does. ]]
	[Enums.Weapon.M9] = sound(ID.PistolShot, 0.68, 1.06, 1.14, 300, 4),
	[Enums.Weapon.DualBerettas] = sound(ID.PistolShot, 0.66, 1.08, 1.18, 300, 4),
	[Enums.Weapon.Glock18] = sound(ID.PistolShot, 0.62, 1.12, 1.22, 290, 4),
	[Enums.Weapon.SawnOff] = sound(ID.ShotgunBlast, 1.0, 1.02, 1.1, 480, 5),
	--[[ A flare gun is a hollow THUMP, not a crack — a low-pressure shell
	     lobbing a lit stick. The shotgun sample dropped a long way and quietened
	     is the closest thing in the bank: the blast's body without its snap. It
	     also carries further than its volume suggests (420) on purpose, because
	     the flare that follows is visible across the whole street and a team
	     should hear where it came from before they see it land. ]]
	[Enums.Weapon.FlareGun] = sound(ID.ShotgunBlast, 0.62, 0.72, 0.78, 420, 4),
	[Enums.Weapon.Shotgun] = sound(ID.ShotgunBlast, 1.0, 0.96, 1.04, 500, 5),
	--[[ One shotgun sample, four guns, pitched apart. The DAO-12 sits highest
	     because twelve rapid shells reading as twelve of the same boom is a wall
	     of noise; the Tactical is the heaviest of the pumps. ]]
	[Enums.Weapon.TacticalShotty] = sound(ID.ShotgunBlast, 1.0, 0.93, 1.0, 510, 5),
	[Enums.Weapon.M1014] = sound(ID.ShotgunBlast, 0.92, 1.0, 1.08, 470, 5),
	[Enums.Weapon.DAO12] = sound(ID.ShotgunBlast, 0.86, 1.06, 1.14, 450, 4),

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
	-- The rest of the AR-15 family on the M4 sample, and the 7.62 rifle pitched
	-- down onto the AK one because that is what a heavier round sounds like.
	[Enums.Weapon.M16A4] = sound(ID.M4Shot, 0.84, 0.96, 1.02, 440, 4),
	[Enums.Weapon.HK416D] = sound(ID.M4Shot, 0.8, 1.0, 1.06, 420, 4),
	[Enums.Weapon.HK417] = sound(ID.AkShot, 0.94, 0.86, 0.93, 520, 5),

	--[[ Machine guns. Loudest and furthest-carrying things in the roster short of
	     the launcher — an LMG opening up is meant to be audible from wherever the
	     rest of the team is standing, because it tells them where the line is. ]]
	[Enums.Weapon.M249] = sound(ID.M4Shot, 0.92, 0.92, 0.98, 560, 5),
	[Enums.Weapon.M60E4] = sound(ID.AkShot, 1.0, 0.82, 0.89, 620, 5),

	-- Marksman: slower, louder, and they carry.
	[Enums.Weapon.ScopedMk18] = sound(ID.SniperShot, 0.9, 1.02, 1.06, 620, 5),
	[Enums.Weapon.M1AEBR] = sound(ID.SniperShot, 1.0, 0.94, 1.0, 700, 5),
	[Enums.Weapon.MK11] = sound(ID.SniperShot, 0.95, 0.98, 1.04, 680, 5),
	--[[ The bolt gun carries furthest of anything that is not an explosion. One
	     shot a second from across a map should be a landmark rather than a
	     texture. ]]
	[Enums.Weapon.M24] = sound(ID.SniperShot, 1.0, 0.88, 0.94, 780, 5),

	--[[ The launch, not the blast — ProjectileService plays Impact.Explosion at
	     the far end when the rocket lands. Without a row here the loudest weapon
	     in the game left the tube in total silence. ]]
	[Enums.Weapon.RPG7] = sound(ID.ShotgunBlast, 1.0, 0.7, 0.76, 900, 6),

	--[[
		Melee swings — one sample each.

		These briefly all shared ID.SwordSwing across five non-overlapping pitch
		bands, which was the best available answer to "five weapons, one whoosh":
		heavier lower, knife higher, and at least tellable apart by ear. They are
		real samples now, so the pitch is back to a natural few percent of
		variation and the DISTINCTION lives in the recording, where it belongs.

		Volume and roll-off still carry the weight, because those are properties of
		the swing rather than of the file: the axe is the loudest and carries the
		furthest, the knife is the quietest and barely leaves your own hands.

		The impact is separate and now split by what did the landing — see
		AudioConfig.MeleeImpact below.
	]]
	[Enums.Weapon.Machete] = sound(ID.MacheteSwing, 0.55, 0.95, 1.06, 70, 3),

	--[[ Brickbattler's Pack. Every one is an existing sample re-pitched rather
	     than a dedicated upload, and named honestly for it — when real classic
	     audio exists, only the ids below change.

	     The slingshot is pitched high and quiet because it fires a pebble; the
	     paintball gun is quieter still and carries barely at all, which is the
	     other half of its trade — a weapon that sprays a thousand rounds a
	     minute must not also be the loudest thing on the street. ]]
	[Enums.Weapon.ClassicSword] = sound(ID.MacheteSwing, 0.6, 1.18, 1.3, 70, 3),
	[Enums.Weapon.ClassicPaintballGun] = sound(ID.SmgFire, 0.4, 1.35, 1.5, 130, 3),
	[Enums.Weapon.ClassicSlingshot] = sound(ID.PistolShot, 0.45, 1.55, 1.7, 150, 3),
	[Enums.Weapon.ClassicRocketLauncher] = sound(ID.ShotgunBlast, 0.95, 0.82, 0.9, 700, 6),
	[Enums.Weapon.FireAxe] = sound(ID.AxeSwing, 0.72, 0.94, 1.04, 80, 3),
	[Enums.Weapon.LeadPipe] = sound(ID.PipeSwing, 0.66, 0.94, 1.06, 75, 3),
	[Enums.Weapon.BaseballBat] = sound(ID.BatSwing, 0.6, 0.95, 1.07, 75, 3),
	[Enums.Weapon.Knife] = sound(ID.KnifeSlash, 0.42, 0.96, 1.1, 55, 2),
} :: { [string]: SoundDefinition }

--[[
	Sounds that hold while a trigger is held, by weapon.

	One entry, and it needs its own table rather than a flag on WeaponFire
	because the two are played by completely different rules: WeaponFire is
	fired once per shot and forgotten, and this is started on an edge and
	stopped on the opposite one. A weapon with no row here simply has no bed,
	which is every gun in the game.

	First-person only. Teammates hear the per-shot bursts through the ordinary
	world audio; a looping emitter per shooter is a stream nobody asked for.
]]
AudioConfig.WeaponLoop = {
	[Enums.Weapon.Flamethrower] = {
		id = ID.FlamethrowerLoop,
		ids = nil,
		volume = 0.55,
		pitchMin = 1.0,
		pitchMax = 1.0,
		rollOffMin = 12,
		rollOffMax = 120,
		looped = true,
		priority = 3,
	},
	--[[
		Two entries now, and they are doing opposite jobs.

		The flamethrower's loop IS the weapon: it fires ten times a second, so
		the bursts are a texture over the bed and the bed is what you hear.

		The Tesla Rifle's is the opposite — a capacitor bank idling under three
		cracks a second that are each loud enough to be the sound of the weapon
		on their own. So it is quiet, and it is here for one reason: the loop
		starts on the trigger going DOWN, which is the same instant the charge
		begins, and the spool is the half-second where the weapon is doing
		something the player cannot otherwise hear. Without it a cold start is a
		charge cue and then silence until the shot.

		Rolls off half as far as the flamethrower's. A teammate should hear the
		cracks from across a street and the hum only if they are next to you.
	]]
	[Enums.Weapon.TeslaRifle] = {
		id = ID.TeslaHum,
		ids = nil,
		volume = 0.3,
		pitchMin = 1.0,
		pitchMax = 1.0,
		rollOffMin = 8,
		rollOffMax = 60,
		looped = true,
		priority = 2,
	},
}

--[[
	A weapon's OWN cues, where the shared bank would be a lie.

	Every gun in the game shares one reload bank — a magazine out, a magazine in,
	a bolt, a dry click — and that is right, because they are all magazine-fed
	guns and thirty separate reload sets would be thirty chances for one of them
	to be missing.

	It stops being right for a weapon that has no magazine. The Tesla Rifle drops
	nothing, chambers nothing and clicks on nothing; played the shared bank it
	sounds like a rifle pretending, which is worse than silence because the
	player can hear the pretending.

	── A VOICE REPLACES THE BANK, IT DOES NOT PATCH IT ─────────────────────────
	A weapon with a row here uses ONLY that row. Keys it does not name are
	SILENT, not inherited — which is the whole point: the failure this table
	exists to prevent is a weapon with no magazine dropping one because nobody
	remembered to override the key that does it. Opt in to each sound you want,
	and the ones you say nothing about say nothing.

	`Charge` and `Draw` have no shared counterpart at all. Nothing else in the
	game charges, and only the melee has a draw cue — see WeaponController, which
	deliberately does not make every slot switch a noise.
]]
AudioConfig.WeaponVoice = {
	--[[
		The flintlock, which names one key and is therefore silent for the rest.

		It cannot reload — eight balls, no reserve, and an ammo crate tops up to
		`reserveMax` which is zero — so MagOut and MagIn would never fire today
		anyway. The row is here because of what this table is FOR: the failure it
		exists to prevent is a weapon with no magazine dropping one because
		nobody remembered to override the key that does it, and a muzzleloader is
		the most literal example of that weapon the game will ever have. Saying
		so now means a future round that hands one out with spare shot inherits
		the silence rather than a magazine clacking out of a wooden stock.

		DryFire stays, and is the one cue this weapon genuinely wants: a click on
		an empty pan is exactly the sound a flintlock makes when it is out.
	]]
	[Enums.Weapon.FlintLock] = {
		DryFire = sound(ID.DryFire, 0.6, 0.9, 0.96, 40, 3),
	},
	[Enums.Weapon.TeslaRifle] = {
		--[[ The capacitor spooling, on the first shot of a burst. See
		     WeaponConfig's spinUp: this plays at the instant the trigger goes
		     down and the shot lands a third of a second later, so the sound is
		     not decoration on the delay — it is the only warning the player gets
		     that the delay is happening. ]]
		Charge = sound(ID.TeslaCharge, 0.6, 0.98, 1.03, 90, 4),
		--[[ Picking it up off the floor of the loot room. The one weapon in the
		     game that gets a draw cue for a reason other than being a toggle:
		     you find exactly one a round, and it should power on in your
		     hands. ]]
		Draw = sound(ID.TeslaDraw, 0.65, 1.0, 1.0, 70, 4),
		--[[ The whole 3.6-second reload in one sample, played at the start.
		     MagIn is deliberately absent — see the header. There is nothing to
		     seat at the end of it, and a clack there would be the shared bank
		     leaking back in through the one key somebody forgot. ]]
		MagOut = sound(ID.TeslaRecharge, 0.7, 1.0, 1.0, 80, 4),
		--[[ Out of charge. A fizzle rather than a click, because there is no
		     firing pin to fall on nothing. ]]
		DryFire = sound(ID.TeslaEmpty, 0.6, 0.98, 1.04, 45, 3),
	},
}

--[[
	The generator objective, world and panel in one table.

	Four of these are UI and three are world sounds, which normally would put
	them in two different places — and they are here together because they are
	one FEATURE, and the thing that goes wrong with this kind of audio is a cue
	somebody could not find to change. A designer retuning how the generators
	sound should not have to know which half of the file each of them lives in.

	── THE THREE WORLD ONES ARE THE POINT ──────────────────────────────────────
	`Start`, `Run` and `Gate` are played through AudioService at the machine, so
	everybody hears them from where they actually are. That is the whole reason
	this table exists: five generators spread across open streets is a job four
	people split up to do, and before these the only evidence a teammate had that
	the objective moved was a number changing on a card.

	`Run` is LOOPED and is the one with a lifetime. AudioService leaves a looped
	voice alone until its Sound is destroyed — see its sweep — so PuzzleService
	holds each one in a trove and takes it down with the round. A generator still
	humming into the next round would be a machine nobody powered.
]]
AudioConfig.Generator = {
	--[[ It turns over. Carries 260 studs, which is far — deliberately: this is
	     the cue that tells somebody three streets away that the team advanced,
	     and a start-up nobody hears is the problem it was added to fix. ]]
	Start = sound(ID.GeneratorStart, 0.85, 0.96, 1.04, 260, 5),
	--[[ And settles into a hum. Quiet and short-range, because five of these
	     running at once is the end state of every successful round and it must
	     read as the map coming alive rather than as a drone over the horde. ]]
	Run = {
		id = ID.GeneratorRun,
		ids = nil,
		volume = 0.3,
		pitchMin = 0.97,
		pitchMax = 1.03,
		rollOffMin = 10,
		rollOffMax = 85,
		looped = true,
		priority = 2,
	},
	--[[ The loot-room gate. The payoff for a five-minute objective, and it used
	     to be the menu-confirm tick. Reaches further than the start-up because
	     it happens once a round and everybody should hear it land. ]]
	Gate = sound(ID.GateOpen, 0.9, 0.97, 1.03, 320, 6),

	--[[
		And the panel, which is UI and is played on the client through UiSound.

		These four replace MenuHover, MenuBack and MenuConfirm. The swap matters
		more than it sounds: a player throws about twenty switches per generator
		run, and hearing the shop's hover tick every time is what made the panels
		read as a menu drawn over a machine rather than as the machine's own
		front. Rolloff and priority are ignored on this path — UiSound is 2D —
		and are filled in anyway so a cue moved to the world later is not a
		silent surprise.
	]]
	Press = sound(ID.PanelPress, 0.45, 0.95, 1.07, 30, 2),
	Fault = sound(ID.PanelFault, 0.55, 0.98, 1.04, 30, 3),
	Solved = sound(ID.PanelSolved, 0.6, 0.99, 1.02, 30, 4),
	Open = sound(ID.PanelOpen, 0.5, 0.99, 1.02, 30, 3),
}

AudioConfig.WeaponReload = {
	MagOut = sound(ID.GunReload, 0.5, 0.98, 1.06, 60, 2),
	MagIn = sound(ID.GunReload, 0.5, 0.92, 1.0, 60, 2),
	Bolt = sound(ID.GunReload, 0.45, 1.08, 1.16, 60, 2),
	ShellInsert = sound(ID.ShotgunShell, 0.55, 0.96, 1.06, 60, 2),
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

--[[
	Wood coming apart under the horde.

	Both rows are the existing impact sample, and deliberately so: a break is the
	same material making the same kind of noise, louder and lower. Swapping in a
	dedicated splintering sample later is two ids here and nothing else, which is
	the point of the row existing at all rather than the service reaching for
	Impact.Wood itself.

	The hit is quiet and low priority — six bodies on one door is six of these a
	second, and at full volume that is a wall of clicking rather than an event.
	The break is loud and high priority because it happens once and it is the
	thing the team has to hear over the horde that caused it.
]]
--[[
	Random events.

	Siren is the announcement every event shares — one sound for "something is
	happening", so the banner and the noise arrive together and a player who has
	heard it once knows to read the top of the screen.

	Thunder and Radio are STAND-INS, and named as such rather than quietly
	borrowed: the sting is a low boom that passes for distant thunder and the
	objective blip passes for a transmission opening. Both are one id here away
	from being the real thing. Rain is deliberately SILENT rather than
	approximated — there is no sample in this project that sounds like rain, and
	a wrong loop running for two minutes is worse than none.
]]
AudioConfig.Event = {
	Siren = sound(ID.EventSiren, 0.65, 0.98, 1.02, 200, 8),
	Thunder = sound(ID.FailureSting, 0.8, 0.55, 0.75, 400, 6),
	Radio = sound(ID.ObjectiveChange, 0.5, 0.9, 1.0, 90, 4),
	RainLoop = sound(EMPTY, 0.5, 0.98, 1.02, 120, 2),
} :: { [string]: SoundDefinition }
AudioConfig.Event.RainLoop.looped = true

--[[
	Footsteps, replacing Roblox's default running sound.

	Two loops rather than one pitched two ways. The default behaviour — one
	sample whose PlaybackSpeed scales with velocity — is why every Roblox
	character sounds like it is walking on the same floor at the same weight, and
	the difference between a survivor moving carefully and one committing to a
	run is most of what the crouch and sprint controls are FOR. Hearing it is how
	a player knows a teammate just broke cover.

	Quiet and short-ranged on purpose. This plays on every survivor in earshot at
	once, continuously, and it is competing with gunfire and a horde — a footstep
	that is loud enough to notice on its own is one that is far too loud when
	four people are running.
]]
AudioConfig.Footstep = {
	Walk = sound(ID.FootstepWalk, 0.35, 0.94, 1.06, 42, 1),
	Sprint = sound(ID.FootstepSprint, 0.45, 0.96, 1.04, 60, 1),
} :: { [string]: SoundDefinition }
AudioConfig.Footstep.Walk.looped = true
AudioConfig.Footstep.Sprint.looped = true

AudioConfig.Barricade = {
	Hit = sound(ID.ImpactWood, 0.42, 0.86, 1.12, 90, 1),
	Break = sound(ID.ImpactWood, 0.95, 0.55, 0.68, 170, 6),
} :: { [string]: SoundDefinition }

--[[
	What a melee sounds like landing on a body, by what did the landing.

	Every melee hit used to play Impact.Flesh — the same generic body-shot sample
	a bullet uses — so a lead pipe and a machete connecting were indistinguishable
	events. They should not be: a blade is the sound that goes with a body coming
	apart, and a blunt weapon is the sound that goes with one being thrown.

	Keyed by weapon rather than by a field on WeaponConfig, because this is purely
	an audio decision and WeaponConfig is about what a weapon DOES. `meleeImpact`
	below resolves it, and anything unlisted falls back to the bullet sound rather
	than to silence.
]]
AudioConfig.MeleeImpact = {
	Blunt = sound(ID.BluntFlesh, 0.82, 0.92, 1.08, 140, 5),
	Blade = sound(ID.BladeFlesh, 0.78, 0.94, 1.06, 140, 5),
} :: { [string]: SoundDefinition }

local MELEE_IMPACT_KIND: { [string]: string } = {
	[Enums.Weapon.BaseballBat] = "Blunt",
	[Enums.Weapon.LeadPipe] = "Blunt",
	[Enums.Weapon.Machete] = "Blade",
	[Enums.Weapon.FireAxe] = "Blade",
	[Enums.Weapon.Knife] = "Blade",
}

--[[ The impact for a weapon, or the generic flesh hit for anything that is not
     a melee at all — which is what the shove, and any melee added without a row
     above, should sound like rather than nothing. ]]
function AudioConfig.meleeImpact(weaponId: string?): SoundDefinition
	local kind = if typeof(weaponId) == "string" then MELEE_IMPACT_KIND[weaponId] else nil
	return if kind then AudioConfig.MeleeImpact[kind] else AudioConfig.Impact.Flesh
end

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

	ChargerIdle = sound(ID.MonsterBellow, 0.6, 1.08, 1.16, 280, 5),
	ChargerCharge = sound(ID.MonsterBellow, 1.0, 0.94, 1.0, 400, 8),

	--[[
		The pins, while they are killing somebody.

		A pinned survivor cannot free themselves — that is the entire design, and
		it makes the rescue somebody else's job. Four specials hold a survivor
		down, and JockeyRide above was the only one of the four that could be
		heard doing it: the Hunter clawed, the Charger pummelled and the Tongue
		constricted in silence, so a teammate two rooms away had a HUD marker and
		nothing to turn toward. These are the missing three.

		Deliberately louder and further-carrying than each creature's own idle,
		and priority 8: this is a call for help, and it is the last sound that
		should be dropped when the voice budget runs out mid-horde. Pitched off
		the same samples the creature already uses, so a Hunter on your friend
		still reads as a Hunter.
	]]
	HunterClaw = sound(ID.CreatureGrowl, 0.95, 1.3, 1.42, 380, 8),
	ChargerPummel = sound(ID.MonsterBellow, 0.95, 1.2, 1.3, 380, 8),
	TongueDrag = sound(ID.CreatureGrowl, 0.9, 0.66, 0.74, 400, 8),

	--[[ The three "you are standing in the wrong place" specials. Every one of
	     them is a warning first and a threat second, so the idle carries further
	     than the creature can act: a Tongue you cannot hear is a Tongue nobody
	     can answer, and hearing it IS the counter. ]]
	TongueIdle = sound(ID.CreatureGrowl, 0.7, 0.82, 0.9, 420, 6),
	TongueGrab = sound(ID.CreatureGrowl, 0.95, 0.74, 0.82, 460, 8),

	BoomerIdle = sound(ID.ZombieGroan, 0.75, 0.7, 0.78, 300, 6),
	BoomerBurst = sound(ID.MonsterBellow, 1.0, 1.3, 1.42, 420, 9),

	SpitterIdle = sound(ID.CreatureGrowl, 0.7, 1.24, 1.34, 320, 6),
	SpitterSpit = sound(ID.CreatureGrowl, 0.9, 1.36, 1.48, 380, 7),

	WitchCry = sound(ID.WomanCrying, 0.8, 0.99, 1.01, 460, 7),
	WitchSummon = sound(ID.ZombieHorde, 0.95, 0.86, 0.94, 520, 8),
	WitchStartle = sound(ID.WomanCrying, 1.0, 1.25, 1.35, 500, 9),

	TankRoar = sound(ID.MonsterRoar, 1.0, 0.98, 1.02, 700, 9),
	TankFootstep = sound(ID.HeavyFootsteps, 0.7, 0.95, 1.05, 280, 5),
	--[[ A swing that hit nobody, and the window that opens behind it. A DIFFERENT
	     sample from the roar on purpose: the roar means "it is here" and carries
	     700 studs to say so, and this one means "hit it now" and is only worth
	     hearing by the people close enough to. Pitched above the Tank's own cues
	     rather than under them — everything below a Tank's register in this file
	     is a bigger thing, and this is the one moment the Tank is a smaller one. ]]
	TankStagger = sound(ID.MonsterBellow, 0.95, 1.14, 1.22, 420, 8),

	--[[ The Metallic. Every one of these is an existing sample re-pitched rather
	     than a dedicated upload, and they are named honestly for that reason —
	     when real drill and servo audio exists, only the ids below change.

	     The pitches are not decoration. This thing is bigger than a Tank, so it
	     sits a full step under the Tank's cues and rolls off further; a player
	     who knows the Tank has to be able to hear at once that this is not one.
	     The two cues that gate the fight — Wind before a charge, Vent when the
	     back plates open — carry the highest priority in the table, because a
	     dropped Wind is an unavoidable charge and a dropped Vent is a window
	     nobody knew was open. ]]
	MetallicRoar = sound(ID.MonsterRoar, 1.0, 0.66, 0.72, 900, 10),
	MetallicStep = sound(ID.HeavyFootsteps, 0.85, 0.68, 0.76, 400, 6),
	MetallicWind = sound(ID.ImpactMetal, 0.95, 0.5, 0.56, 560, 10),
	MetallicCharge = sound(ID.MonsterBellow, 1.0, 0.68, 0.74, 640, 9),
	MetallicSlam = sound(ID.ImpactConcrete, 1.0, 0.54, 0.62, 580, 9),
	MetallicVent = sound(ID.FlamethrowerBurst, 0.95, 0.6, 0.68, 500, 10),

	--[[ The Bacteria Monster. Same approach as the Metallic above it — existing
	     samples re-pitched rather than new uploads — and pitched the other way:
	     everything this creature does is WET and low, where the Metallic is dry
	     and metallic. It never roars a challenge; it announces itself by being
	     already in the room, which is why its loudest cue is the one that
	     carries furthest and the rest are close and quiet.

	     `Bloom` is the cue that matters: a colony taking root under the team's
	     feet. It has to be audible over gunfire from the middle of a firefight,
	     because a player who cannot hear the ground going bad has to look down
	     to learn it, and looking down in this fight is how you die. ]]
	BacteriaRoar = sound(ID.MonsterBellow, 1.0, 0.52, 0.6, 820, 10),
	BacteriaStep = sound(ID.ImpactWater, 0.7, 0.6, 0.7, 260, 5),
	BacteriaBloom = sound(ID.ImpactWater, 0.9, 0.85, 1.0, 340, 8),
	BacteriaDeath = sound(ID.MonsterRoar, 1.0, 0.5, 0.58, 700, 10),
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
	--[[ Not the pill bottle. Both items used to share that rattle, and a teammate
	     who hears one of the two has learned something quite different about what
	     is about to happen — pills are somebody buying time, a shot is somebody
	     about to run at something.

	     The gasp rather than a needle, pitched under Revived's, because it is the
	     survivor's reaction that reads at a distance and this project has no
	     injector sample. Named honestly as a stand-in in docs/AUDIO_NEEDED.md;
	     only the id changes when there is a real one. Carries further than the
	     pills do, on purpose: this is the cue worth hearing across a room. ]]
	AdrenalineUse = sound(ID.Gasp, 0.72, 0.84, 0.92, 85, 4),
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

	--[[
		The kill.

		Until now a kill sounded exactly like a hit, which meant the game's most
		important single piece of feedback — did that thing die — had to be read
		off the crosshair instead of heard. In a horde, where the crosshair is
		covered in bodies, that is the same as not being told.

		Both are their own samples now. They began as the hit ticks pitched down —
		the honest stopgap when this project had no kill-specific upload — with
		non-overlapping pitch bands doing the work of telling them apart. That is
		no longer load-bearing and the pitch is back to a natural few percent,
		because the difference is in the recording where it belongs.

		verify_feel still enforces the underlying rule: two cues that SHARE a
		sample must not share a pitch band. It applies to nothing here today, and
		it is what would catch a future cue quietly borrowing one of these.
	]]
	KillMarker = sound(ID.KillThump, 0.5, 0.96, 1.04, 26, 4),

	--[[ Drawing the melee. Short, and quiet enough that toggling it twice in a
	     panic is not louder than the thing that caused the panic. ]]
	MeleeDraw = sound(ID.MeleeDraw, 0.4, 0.97, 1.05, 20, 2),
	--[[ The main menu turning a page. Near-silent by design — it confirms the
	     press happened, it is not an event. ]]
	MenuPage = sound(ID.MenuPage, 0.3, 0.98, 1.04, 20, 2),
	--[[ A Tank or a Witch. A real stinger rather than a tick, long enough to be a
	     moment, and played for the WHOLE TEAM rather than only for whoever landed
	     the last shot — see the boss branch in HudController's Notice handler.
	     Four people fight a Tank; four people should hear it stop. ]]
	BossKillMarker = sound(ID.BossKillSting, 0.7, 0.98, 1.02, 90, 6),

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
--[[
	One cue for a weapon, by name.

	The single place the replace-don't-patch rule at WeaponVoice is enforced, so no caller
	has to remember it. A weapon with a voice gets that voice and nothing else; a
	weapon without one gets the shared bank; a name neither has is nil, and every
	play path in the game already treats nil as silence.
]]
function AudioConfig.weaponCue(weaponId: string?, name: string): any
	local voice = if typeof(weaponId) == "string" then AudioConfig.WeaponVoice[weaponId] else nil
	if voice then
		return voice[name]
	end
	return (AudioConfig.WeaponReload :: any)[name]
end

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
