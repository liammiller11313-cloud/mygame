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

	--[[
		What a chunk of somebody looks like, as opposed to a chunk of anything.

		Every gib used to be the same flat colour in the same box, so a body burst
		into a handful of identical red dice. Three cheap things fix most of that,
		and none of them costs a draw call:

		MeshShare   how many chunks are LUMPS rather than boxes. A SpecialMesh set
		            to Sphere costs nothing — it is a primitive, not an asset — and
		            since gib sizes already vary per axis it comes out as an
		            irregular blob rather than a ball. A mix reads best: all boxes
		            is rubble, all blobs is bubbles, and the two together read as
		            something torn apart.
		DarkMixMax  how far toward the dark blood colour a chunk may sit. Deep
		            tissue is nearly black and surface flesh is bright, and having
		            both in one burst is most of what makes it look like a body
		            instead of a colour.
		Wetness     a little reflectance. Meat is wet; matte chunks read as brick.
		            Small on purpose — anything higher turns them into mirrors under
		            a flashlight, which is the lighting these are usually seen in.
	]]
	MeshShare = 0.5,
	DarkMixMax = 0.85,
	Wetness = 0.08,

	--[[
		The mark a chunk leaves where it comes to rest.

		Gibs used to fly, land, lie there for twelve seconds and vanish leaving the
		floor exactly as clean as before — so a room you had gibbed six bodies in
		looked, a quarter of a minute later, like nowhere anything had happened.
		Decals already exist for the walls behind a shot; this is the same idea for
		the ground under the pieces, and it is most of what makes a fought-through
		room read as fought-through.

		A fraction rather than all of them. Marks come out of the same ceiling as
		every other red mark in the level — MaxActiveDecals — so a chunk that
		leaves one is spending the budget a wall splatter would otherwise have, and
		ninety chunks each claiming a slot would push the actual gunfight off the
		walls. A third is enough to read as accumulation.

		Small, too: this is a smear under a piece of meat, not the pool a whole body
		bleeds. The scale multiplies DecalSizeMin..Max, so a third of the smallest
		wall mark is about right.
	]]
	LandMarkChance = 0.33,
	LandMarkScale = 0.35,

	--[[
		And they go sooner than a wall mark does, which is what keeps them from
		taking the level over.

		Decals live 45 seconds and a gib lives 12, so at a saturated gib pool the
		marks outlive nearly four full turnovers of the chunks that made them:
		ninety gibs a third of which mark, three and three-quarter times over, is
		about a hundred and ten marks out of a hundred and sixty. The gunfight
		would have been pushed off the walls by the debris on the floor.

		Fourteen seconds holds the share at roughly a fifth of the ring — and it
		holds it there on every device, because the gib pool and the decal ring are
		scaled by the same device budget, so the arithmetic comes out the same on a
		phone as on a desktop.

		It is also just correct: this is a smear under one piece of meat, and it has
		no business outlasting the pool a whole body bled.
	]]
	LandMarkLifetime = 14,
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

	--[[
		The heavy layer: gouts.

		Spray is a fine mist of fast droplets and mist is the cloud it leaves —
		together they read as "a red puff", which is fine for a graze and wrong
		for a body coming apart. Gouts are the third answer: few, large, slow, and
		fully gravity-bound, so they arc out of the wound and fall. They are what
		makes a gib look like it had mass.

		Deliberately a small count. Six heavy droplets that visibly travel read as
		more violent than forty that do not, and they are the expensive ones — big
		particles that live a full second are the layer that costs fill rate.
	]]
	--[[
		The second and third beats of a wound.

		A cut artery does not puff once and stop, and one burst is what every wound
		in this game was: a single frame of spray at the moment of the cut, then a
		limb tumbling away clean. Two smaller, later bursts at the same point turn
		that into something that pumps — which is what the eye reads as a body
		still emptying rather than an effect that has finished playing.

		Only on a body coming APART. A clean kill is a clean kill, and putting an
		arterial spurt on every Common that falls over would spend the difference
		this is meant to create.
	]]
	SpurtDelays = { 0.22, 0.52 },
	SpurtFalloff = 0.55,

	GoutParticles = 6,
	GoutSpeed = 20,
	GoutSpread = 38,
	GoutLifetime = 1.05,
	GoutSize = 0.5,

	--[[ The squib: a single bright pop on the frame of impact, gone in three.
	     It is the cheapest readability win in the whole system — the eye finds
	     the wound before it finds the blood, and without it a hit at distance
	     reads as a miss. ]]
	SquibParticles = 3,
	SquibLifetime = 0.07,
	SquibSize = 0.7,

	-- Decals are sprayed onto whatever is behind the target, along the shot line.
	DecalEnabled = true,
	DecalMaxDistance = 20,
	DecalSizeMin = 1.2,
	DecalSizeMax = 4.5,
	DecalLifetime = 45,
	DecalFadeTime = 6,

	--[[
		How long a mark takes to go from fresh to dried.

		Blood does this in life — bright red oxidises to near-black within a
		couple of minutes — and it is worth having because it puts AGE on the
		floor. A room you fought through five seconds ago and a room you fought
		through a minute ago used to look identical until the decals began to
		fade out entirely; now the fresh ones are bright and the old ones are
		dark, so the trail behind a team reads as a trail.

		Twelve seconds rather than a literal two minutes: a decal only lives 45,
		and drying that outlasted the mark would never be seen finishing.
	]]
	DecalDryTime = 12,
	DecalChanceOnHit = 0.55,
	DecalChanceOnKill = 1.0,

	-- Pooling under a body that has stopped moving.
	PoolEnabled = true,
	PoolGrowTime = 2.5,
	PoolMaxSize = 6.5,

	--[[
		How long a stain under a body lasts, as opposed to a mark on a wall.

		Pools used to take DecalLifetime, the full 45 seconds, and that quietly
		crowded everything else off the level. A pool is created for every body
		that settles, so during a sustained horde — a kill every 350ms into a
		48-slot corpse ring — they arrive at nearly three a second, and at 45
		seconds that is about 130 live pools out of a 160-decal ceiling. Add the
		gib landing marks and the ring was over-subscribed before the gunfight had
		put a single splatter on a wall: the floor was a solid carpet of overlapping
		circles and the walls were clean, which is the opposite of what a room that
		has been fought through looks like.

		22 seconds holds pools at about 40% of the ring and leaves a third of it
		free for the fight itself. It is also long enough to outlive the body — the
		corpse ring recycles at around 16 seconds under that same pressure — so the
		blood is still there after the body has gone, which is the point.
	]]
	PoolLifetime = 22,

	--[[
		How much a body bleeds, by what was done to it.

		Every corpse used to leave the same stain: a clean headshot and a body torn
		open at the shoulder produced identical circles of identical size, which is
		the one place the gore system said the same thing about two events it had
		spent everything else distinguishing.

		Multiplies the pool only — the grow time is unchanged, so a bigger stain
		spreads faster rather than lingering half-formed. A burned body pools least
		of all: cauterised is the whole point of burning, and a charred corpse in a
		wide red pool reads as the two effects not knowing about each other.

		Gibbing is absent on purpose. A gibbed body is replaced by chunks and never
		ragdolls, so it never reaches the pool at all; the chunks leave their own
		marks where they land.
	]]
	PoolScale = {
		Dismember = 1.7,
		Incinerate = 0.4,
	},

	--[[ The stain a severed limb leaves where it comes to rest.

	     Small and short-lived, and both of those are budget rather than taste:
	     marks come out of the same MaxActiveDecals ceiling as the wall splatter
	     from the gunfight, and forty limbs each holding a full-size, full-length
	     pool would push that fight off the walls. A limb only lives LimbLifetime
	     anyway, so a stain that outlasted it by thirty seconds would be a puddle
	     with nothing in it. ]]
	LimbPoolScale = 0.32,
	LimbPoolLifetime = 16,
})

--[[
	How long a body a player EARNED stays on the floor.

	A headshot is the point of this game — it is why the head multiplier is 4x and
	why the crosshair exists — and until now it produced exactly the same corpse as
	a burst into the shins, gone on the same clock. The body is the receipt, so a
	headshot leaves one that outlasts the fight it happened in.

	A FLOOR, not a replacement. Several archetypes already lie there longer than
	this — the Tank is 60 and the Witch 45 — and shortening those to make a
	headshot "special" would be the feature taking something away. It only ever
	raises: the Jockey's 20 becomes 35, the Tank's 60 stays 60.

	Protected from recycling too, and that is not a detail. MaxRagdolls is 48 and a
	horde fills it in seconds, so the FIFO is what actually decides how long a body
	lasts; a lifetime nothing defends is a number in a config file. Headshot bodies
	are the last to be recycled rather than never — see GoreService.ragdoll for why
	"never" would be worse.
]]
GoreConfig.Corpse = table.freeze({
	HeadshotLifetime = 35,

	--[[
		How much of the ragdoll ring headshot bodies may hold before they stop
		being passed over.

		Without a cap the feature eats the floor. Simulated against a sustained
		horde — a kill every 350ms into a 48-slot ring — an unlimited protection
		held headshot bodies for their full 35 seconds and dropped everything else
		to 1.7, so the room emptied of ordinary corpses to keep the earned ones.
		That is the gore system getting visibly thinner in exchange for a feature
		meant to make it richer.

		Past this share the recycling reverts to plain oldest-first — deliberately
		NOT to recycling protected bodies first, which was the obvious fix and is
		wrong: at a high headshot rate it INVERTED, holding the ordinary bodies
		while the earned ones cycled out fastest. Reverting to FIFO instead
		degrades smoothly to exactly the old behaviour, which is the correct floor.

		At half the ring, with the same simulation:

		  10% headshots   35s earned / 10s ordinary   (was 16s / 16s)
		  30% headshots   25s earned / 12s ordinary
		  50% headshots   17s earned / 15s ordinary
		  90% headshots   16s earned / 17s ordinary   — plain FIFO, as it should be
	]]
	ProtectedShare = 0.5,
})

--[[ The one place that decides it, because two Debris timers watch every corpse
     — GoreService's and InfectedService's fallback — and the SHORTER one wins.
     Computed independently in both, the Jockey's 20-second body would have been
     destroyed by the fallback at 32 while the ragdoll record still believed it
     had 35, and the feature would have silently not worked on exactly the
     archetypes it was most visible on. ]]
function GoreConfig.corpseLifetime(base: number, region: string?): number
	if region == Enums.HitRegion.Head then
		return math.max(base, GoreConfig.Corpse.HeadshotLifetime)
	end
	return base
end

--[[ Screen-space feedback for the player who is being hit, not the one shooting.
     Kept restrained; a full-screen red wash every time a Common connects makes
     the game unreadable exactly when reading it matters most. ]]
GoreConfig.ScreenBlood = table.freeze({
	Enabled = true,
	DropletsPerHit = 3,
	MaxDroplets = 14,
	FadeTime = 4.0,
	BoomerBileFadeTime = 12.0,

	--[[
		Blood on the lens from a kill you made, not one made on you.

		This layer only ever fired when the PLAYER was hit, which left the most
		violent thing in the game — putting a shotgun through a Common's chest at
		contact range — entirely off the camera. Standing inside the spray and
		catching none of it is the one moment the gore system was not selling.

		Only for a body coming APART (gib or dismember), and only within
		SplashDistance. Every hit would be a permanently red screen, and a kill
		across the room is not something you would wear.

		SplashCooldown exists because a horde dies in clumps. Three bodies gibbed
		in the same tenth of a second is one event to the eye and should be one
		splash; without the gate it is three, and three lands as a wash that
		hides the next Common.
	]]
	SplashOnKill = true,
	SplashDistance = 9,
	SplashDroplets = 2,
	SplashCooldown = 0.35,
})

--[[ Hit-stop: the single cheapest trick in the satisfaction toolbox. Freezing
     everything for two frames on a kill makes the kill land physically. ]]
GoreConfig.HitStop = table.freeze({
	Enabled = true,
	NormalHitSeconds = 0.0,
	--[[
		A melee blow that CONNECTS, which is the one impact in the game that had no
		freeze at all.

		A gun's feedback is its recoil, its muzzle flash and its report — three
		things that fire whether or not the bullet found anything. A machete has
		none of that: the swing looks identical in an empty corridor and buried in
		a Common's chest, so without a freeze on contact there is nothing anywhere
		telling the player the difference. That is most of why melee reads as
		weightless next to shooting.

		Shorter than a kill freeze, because a machete swings two and a half times a
		second and a kill-length hold on each would be a slideshow. Only on a hit
		that does NOT kill — a lethal one already gets the bigger freeze through
		GoreService, and stacking them would double the longest one.
	]]
	MeleeHitSeconds = 0.045,
	KillSeconds = 0.035,
	HeadshotKillSeconds = 0.06,
	GibSeconds = 0.09,
	BossHitSeconds = 0.02,
	TimeScale = 0.06, -- how far the world slows during the freeze
})

--[[ Performance ceilings. Gore is the first thing to blow a frame budget, and a
     zombie game that stutters during a horde has failed at the one moment it
     needed to hold up. These caps are not optional. ]]
--[[
	The death animation, and the one rule that keeps it from breaking anything.

	A death clip and a ragdoll both want the same Motor6Ds, and the ragdoll wins
	by disabling them — so the clip goes first and the ragdoll is held for its
	length. MaxHold is the safety: a clip that is long, mis-authored, or
	reporting a nonsense length can never leave a body standing upright waiting
	on an animation that is not coming. Past MaxHold the body ragdolls whatever
	the clip thinks it is doing.

	Only ever applies to a clean kill. Dismemberment, gibbing and incineration
	ragdoll on the frame they always did: a body coming apart at the shoulder
	does not first perform a tidy collapse.

	Enabled = false restores exactly the old behaviour — every death ragdolls
	immediately — and is the one switch to reach for if a clip misbehaves.
]]
GoreConfig.DeathAnimation = table.freeze({
	Enabled = true,
	MaxHold = 1.1,
})

GoreConfig.Budget = table.freeze({
	MaxActiveGibs = 90,
	MaxActiveLimbs = 40,
	MaxActiveDecals = 160,
	--[[ Kept equal to GameConfig.Corpses.MaxRagdolls on purpose: GoreService
	     takes the TIGHTER of the two, so raising one and not the other is a
	     change that does nothing and looks like it worked. Both are 48 now,
	     which settled corpses being anchored is what pays for — see the note on
	     GameConfig.Corpses.MaxRagdolls for why that is affordable. ]]
	MaxActiveRagdolls = 48,
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
	--[[ A tablet is not a phone. It has a real GPU and four times the screen, so
	     a phone's budget wastes it — but it is still a handheld with a shared
	     memory budget, so a desktop's does not fit either. It was folded into
	     Mobile until Device gained the class; before that, ANY class this table
	     did not recognise fell through `or 1.0` to the full desktop load, so
	     naming a new one without a row here would have been worse than not
	     naming it at all. ]]
	Tablet = 0.55,
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
function GoreConfig.budgetFor(deviceClass: string): { gibs: number, decals: number, particles: number }
	local scale = GoreConfig.BudgetScale[deviceClass] or 1.0
	return {
		gibs = math.max(math.floor(GoreConfig.Budget.MaxActiveGibs * scale), 12),
		decals = math.max(math.floor(GoreConfig.Budget.MaxActiveDecals * scale), 24),

		--[[
			A multiplier on particle COUNTS, not a cap on layers.

			Every device gets all four layers of a blood burst, because dropping
			one changes what the effect reads as rather than only what it costs —
			a hit with no squib reads as a miss at distance, and one with no gouts
			reads as a graze. What scales is how many particles each layer emits,
			which is the term that actually decides whether a handset holds its
			frame during a horde.

			Softer than the gib and decal scale. Those are persistent objects that
			accumulate; particles are transient, and cutting them as hard would
			leave a phone with a two-droplet spray that looks broken rather than
			cheap. Square-rooting the device scale halves the cut.
		]]
		particles = math.max(math.sqrt(scale), 0.45),
	}
end

return table.freeze(GoreConfig)
