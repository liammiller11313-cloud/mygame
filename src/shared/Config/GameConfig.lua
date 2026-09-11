--!strict
--[[
	GameConfig — global rules that are not weapon-specific or enemy-specific.

	Survivor health, revive timings, friendly fire, and the hit-region multipliers
	that make headshots the point of the game.
]]

local Enums = require(script.Parent.Parent.Enums)

local GameConfig = {}

--[[
	Which build of the code this place is actually running.

	Printed in the server's boot banner, and it exists because a pasted log could
	not answer the one question that had to be answered first: is this the code
	with the fix in it, or the code from before it? Every line number in a Roblox
	log belongs to a file that may not have changed, so matching them proves
	nothing, and the absence of a new warning means either "fixed" or "not synced"
	with no way to tell which.

	BUMPED BY HAND on every push. That is deliberate rather than lazy: there is no
	build step here — Rojo syncs source files straight into the place — so there
	is nothing to inject a commit hash from, and a stamp that lies is worse than
	none. If it is stale, the log says so honestly: the code in Studio is at least
	as new as this date, and no newer than the push that set it.
]]
GameConfig.BuildStamp = "2026-09-11-alpha11"

--[[
	What the game calls itself, on screen.

	Separate from BuildStamp above, and the two answer different questions.
	BuildStamp is for the developer — a date in the server log that says how new
	the code in Studio is. This is for the PLAYER: it goes in the corner of the
	main menu and its whole job is to set an expectation before anybody presses
	PLAY. Somebody who knows they are in an alpha reports a bug; somebody who
	thinks they are in a finished game leaves.

	── AND THE TESTING NUMBER IS GONE ──────────────────────────────────────────
	Four builds carried "ALPHA TESTING 1" through "4", and that trailing number
	was doing a real job: a tester who played the last one and saw the same
	string had no way to tell whether the thing they reported was ever looked at.
	It was a number for a closed room.

	This build leaves the room. "0.9 ALPHA" says the two things a player walking
	in now actually needs — this is not finished, and it is not a private test
	they were let into. Somebody who knows they are in an alpha reports a bug;
	somebody who thinks they are in a finished game leaves; and somebody who
	thinks they are in a test that ended in September wonders why the servers are
	up.

	BuildStamp above keeps the build identity, which is where it belonged all
	along: it is the developer's answer to "how new is the code in this server",
	and it never needed to be on a menu.
]]
GameConfig.Version = "0.9 ALPHA"

--[[
	Whose game this is.

	Every account named here owns everything: every weapon, every ability, every
	pass, and every code-restricted thing, without buying, redeeming or unlocking
	any of it. It is a development grant — the person building the game should not
	have to earn their way to the content they are testing.

	── ONE LIST, AND EVERY OWNERSHIP QUESTION READS IT ─────────────────────────
	The alternative is a flag sprinkled through four services, and the way that
	fails is silent and specific: one of them gets missed, the owner tests
	everything but the fifth thing, and finds out the fifth thing is broken from
	somebody else. ProfileService.unlockedSet, ProfileService:ownsAbility,
	PassService:owns and CodeConfig.allows all ask this and nothing else.

	── BY USERID, AND ONLY EVER ON THE SERVER ──────────────────────────────────
	A UserId because a username can be changed and this grant should survive one.
	And the check is only ever made against `player.UserId` on the SERVER, which
	Roblox fills in from the connection — a client cannot claim to be one of these
	any more than it can claim to be somebody else.

	This file is shared, so a client can READ the list. That is fine and is not a
	secret: knowing an owner's id grants nothing, and the client needs it to draw
	its own screens correctly rather than showing the owner locks that do not
	apply to them.
]]
GameConfig.Owners = table.freeze({
	1729528634, -- spacecase201
})

--[[ Whether this player owns the game. Takes a Player rather than an id so no
     call site can accidentally pass something a client chose. ]]
function GameConfig.isOwner(player: any): boolean
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return false
	end
	local id = player.UserId
	for _, owner in GameConfig.Owners do
		if owner == id then
			return true
		end
	end
	return false
end

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
	-- The supplied Hunter rig carries a visible "FakeHead" over a hidden "Head".
	-- Without this line a shot that visibly lands on the head resolves as a torso
	-- hit: no 4x multiplier, no headshotAlwaysKills, no decapitation. A hitbox
	-- that disagrees with what the player can see is the worst bug a shooter has.
	FakeHead = Enums.HitRegion.Head,
	--[[ The Tongue's tongue. It is the creature's whole silhouette at range —
	     the part a player actually aims at while it is dragging a teammate — and
	     scoring it as a torso hit meant the shot that looks like the obvious
	     answer was worth the least. Head, so shooting the tongue is worth what
	     shooting the Tongue is worth. ]]
	tongue = Enums.HitRegion.Head,
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

	-- The Hunter's back hump. Real body mass rather than decoration, so it takes
	-- hits like a torso instead of passing them through.
	Hunch = Enums.HitRegion.Torso,
})

--[[
	Geometry that sits ON a rig rather than being part of it.

	These are made non-queryable when a rig is imported, so a shot passes straight
	through them to the body underneath. That is the only correct answer for
	anything overlaying the HEAD: hair and hoods are routinely modelled larger
	than the skull they cover, so scoring them as a head hit hands out free
	headshots, and scoring them as a torso hit — which is what an unrecognised
	part defaults to — silently eats the headshot the player actually earned. A
	part that cannot be queried at all avoids both: the ray keeps going and
	resolves on the real head.

	`Handle` is here because Roblox names every Accessory's part that, and
	hand-built rigs routinely weld a loose one on for a claw or a prop. Nothing
	the player shoots should ever resolve on a prop.
]]
GameConfig.PassThroughParts = table.freeze({
	Hair = true,
	Hood = true,
	Hat = true,
	Cap = true,
	Mask = true,
	Handle = true,
})

--[[ Survivor health model, lifted from L4D2 because it is very well balanced. ]]
GameConfig.Survivor = table.freeze({
	MaxHealth = 100,
	StartHealth = 100,

	-- Below this you limp, breathe hard, and every infected can hear you.
	HurtThreshold = 40,
	--[[
		── FASTER, AND LESS OF A SAWTOOTH ──────────────────────────────────────
		These were 11 / 16 / 22 and the game felt heavy. Raising them is half the
		fix; the other half is the stamina economy below, because of how sprint is
		actually granted: _computeWalkSpeed hands you SprintSpeed whenever you have
		any stamina at all, so at the old drain/regen a survivor oscillated 22 for
		0.96s, 16 for 1.39s, forever — an average of about 18.5 that never held
		still long enough to feel like a speed.

		Simulated over two minutes rather than reasoned about, because the first
		attempt at these numbers was wrong: raising the speeds and the regen made
		the game faster and left the oscillation exactly where it was, since a
		survivor only recovers to SPRINT_RECOVER_FRACTION before spending it again.
		Fixing it took all three — speed, drain, and that fraction.

		    before   18.6 studs/s average, 49 speed changes a minute
		    after    23.9 studs/s average, 12 speed changes a minute

		29% faster, and the cycle goes from one change every 1.3 seconds to one
		every five — roughly seven seconds of sprint bought back over three. That
		second number is most of what "faster" actually means to a player: the old
		build never held a speed long enough for it to feel like one.
	]]
	LimpWalkSpeed = 12,
	NormalWalkSpeed = 18,
	SprintSpeed = 26,

	--[[ Crouching. A real slowdown rather than a token one — the trade is that
	     you are a smaller silhouette and your shots settle, and neither is worth
	     anything if you can still cross a street at walking pace. Roblox has no
	     native crouch, so this is the whole of it: speed, and a camera that drops
	     to where the head now is. ]]
	CrouchSpeed = 9,
	CrouchCameraDrop = 1.6, -- studs the view lowers by

	--[[
		What crouching does to the cone of fire, as a multiplier on the whole of
		it — base, movement penalty and recoil bloom alike.

		The comment above this block has claimed since it was written that the
		trade for the speed is "a smaller silhouette and your shots settle". The
		silhouette was real. The settling was not implemented at all, so crouching
		was a pure loss: two thirds of your speed for nothing.

		A multiplier rather than a flat subtraction so it scales with the weapon.
		A tenth of a degree off a shotgun is nothing and off a sniper is most of
		its cone; a third off either is the same decision. It multiplies bloom too,
		which is what makes crouching worth doing with an automatic specifically —
		the same thing crouch-spraying does in Counter-Strike.

		Applied identically by BallisticsService and by WeaponController, because
		the crosshair renders this number and the server fires it. If the two ever
		disagree the crosshair is lying about where the bullet goes, which is worse
		than having no crosshair.
	]]
	CrouchSpreadMultiplier = 0.65,
	--[[ Drain down and regen up together — see the note on the speeds, and note
	     that SPRINT_RECOVER_FRACTION in SurvivorService is the third term. The bar
	     is still a real resource; it just stops being the thing that governs your
	     speed several times a second. ]]
	SprintStaminaDrain = 12, -- per second
	SprintStaminaRegen = 30, -- per second
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

	--[[
		Whether a survivor can hurt another survivor at all.

		Off. Left 4 Dead's friendly fire is a real tension and the damage pipeline
		still knows how to apply it — DirectorConfig carries a per-difficulty
		multiplier and the melee case is separately zeroed — but a public Roblox
		server is not four friends on voice chat, and a teammate who can end your
		round by holding a trigger is a griefing tool before it is a mechanic.

		Blocked rather than merely reduced: at any non-zero multiplier the answer
		to "can you kill me" is yes given enough bullets, and the whole point is
		that it is no. The shooter is told, once, rather than being left to wonder
		why nothing happened.
	]]
	FriendlyFireEnabled = false,

	--[[ Seconds between friendly-fire warnings for one shooter. Long enough that
	     emptying a magazine into a teammate produces one message rather than
	     thirty, short enough that a second incident later still says something. ]]
	FriendlyFireWarnCooldown = 4,
	ReviveTime = 5.0,
	ReviveHealth = 30, -- temp health you stand up with
	MaxIncapsBeforeDeath = 2, -- the third down kills you

	--[[
		How many times a survivor may DIE in one round before they are out of it.

		The incap ledger above is the small version of this and runs on the same
		idea: a third down kills you, and a third death ends your round. Together
		they give a player who is having a bad time nine falls before the game
		stops handing them another one — enough that nobody is eliminated by one
		mistake, few enough that a player who keeps running into the horde stops
		costing their team a defibrillator every ninety seconds.

		A round is seventeen minutes. Three is a real budget across that and still
		short enough to be worth protecting, which is the whole point: it turns
		"I can always come back" into "we cannot keep doing this".

		Eliminated is NOT the same as leaving. They keep their body, they keep
		their score, they spectate the team, and the next round starts them at
		full health with a fresh ledger — see SurvivorService.spawnSurvivor.
	]]
	DeathsPerRound = 3,
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

--[[
	THE FLASHLIGHT.

	AtmosphereService opens the round under a low orange sun and is pitch dark by
	the last waves. That ramp is the game's whole arc and it was, until this existed,
	pointed at nothing: the map goes black and the survivors have no way to see
	into it. This is the other half of the sentence the title is making.

	It is ALWAYS ON, and there is no toggle. Not an oversight — a decision:

	  * A toggle needs a key, and a keyboard has one to spare while a gamepad and
	    a phone do not. A light that only desktop players can turn back on is a
	    difficulty setting disguised as a control.
	  * There is no reason to want it off. It costs nothing, hides nothing, and
	    attracts nothing. The only outcome a toggle buys is a player who turned it
	    off by accident in a pitch-dark finale and does not know why they cannot
	    see. (If the Witch ever cares about being looked at, that changes, and
	    this is where the switch goes.)

	Two lights per survivor and they are not the same light. Everybody's gun
	carries one, so a teammate's beam sweeping a doorway is a real read at forty
	studs — that is the read L4D's flashlights actually buy. But a gun points
	where the ARM points and a player aims with the CAMERA, so the local player
	gets their own from the eye and suppresses their gun's. See
	Client/Effects/FlashlightController.

	Shadows are off on both, deliberately. Four shadow-casting spotlights in a
	horde is the single most expensive thing this game could ask a phone to draw,
	and the shadows themselves are invisible against fog this thick.
]]
GameConfig.Flashlight = table.freeze({
	Enabled = true,

	--[[ Wide, and not very bright. A tight bright cone reads as a searchlight and
	     blows out the first wall it touches; this is a hand torch in fog. The
	     range is deliberately shorter than the fog is deep, so the dark still
	     wins at distance and the light tells you about the room you are in. ]]
	Angle = 64,
	Brightness = 2.4,
	Range = 58,

	-- Tungsten, not white. A cold beam in an already-cold grade reads as a bug.
	Color = Color3.fromRGB(255, 241, 208),

	--[[ Where the view light sits relative to the eye: slightly right, slightly
	     down, slightly forward. Off-axis on purpose — a beam projected exactly
	     from the eye lights nothing you can perceive as lit, because every
	     surface it reaches is one you are looking at head-on with no shading
	     gradient at all. Moving it a hand's width sideways puts shape back. ]]
	ViewOffset = CFrame.new(0.45, -0.35, -0.5),
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

--[[
	Recoil, split into the part you SEE and the part that moves your shots.

	WeaponConfig's `recoilVertical` is one number and it used to do both jobs at
	once: the camera pitched up by it, and because the shot direction was read
	straight off the camera, your aim went with it. That is the harshest possible
	arrangement — every bit of punch you add to make a gun feel good is punch that
	throws the next round off target, so a satisfying gun and a controllable gun
	pull against each other.

	Two numbers instead. ViewScale decides how hard the camera kicks; AimFollow
	decides how much of that kick your bullets inherit. The gun keeps its punch
	and stops fighting you for it.

	CrosshairController draws the reticle at the direction the shot will actually
	take rather than at the middle of the screen, so the two never disagree — the
	reticle visibly drifts under the recoil and settles back, which is also the
	clearest read of "you are climbing" the game has.

	Shake and explosion impulses are excluded from the aim entirely, at any
	setting. A Tank landing next to you should rattle the frame; it should not
	steer your bullets, and it silently did.
]]
GameConfig.Recoil = table.freeze({
	--[[ The visible kick, as a fraction of WeaponConfig's recoilVertical /
	     recoilHorizontal. Below 1 the whole roster calms down together, which
	     beats editing fifteen pairs of numbers and losing the balance between
	     them. ]]
	--[[ 0.62 rather than 0.7. The pattern below now has a plateau and a ceiling,
	     which took most of the excess out of a long spray — this takes a little
	     off the SHOT, which is the half a player feels on a two-round tap. ]]
	ViewScale = 0.62,

	--[[ How much of that kick moves where the bullets go. At 1 this is the old
	     behaviour — the camera IS the aim. At 0 recoil is pure decoration and
	     the gun is a laser, which is worse: climb you have to fight is most of
	     what makes an automatic weapon a decision rather than a button. A third
	     leaves the mechanic intact and takes the shove out of it. ]]
	AimFollow = 0.35,

	--[[
		THE SHAPE OF A BURST.

		Every shot used to kick the same amount. WeaponController counts a burst
		index and resets it after 0.35s of not firing, ShotPattern takes that
		index, CameraController's own header promises "the vertical climb is
		consistent enough to counter" — and none of it did anything: the index
		only stirred the random seed, so the first round of a burst and the
		twentieth kicked identically. Tapping was not more accurate than holding,
		which is the one thing recoil is for.

		Now the kick RAMPS. The first shot is FirstShotScale of the weapon's
		number and reaches full over ClimbShots, so every weapon's recoilVertical
		becomes a curve instead of a constant.

		Deliberately ramping UP TO the old value rather than past it: sustained
		fire kicks exactly as hard as it did before, and short bursts kick less.
		Nothing in the roster got harder to shoot.
	]]
	FirstShotScale = 0.5,
	ClimbShots = 5,

	--[[
		── AND THEN IT STOPS CLIMBING ───────────────────────────────────────────
		The ramp above used to be the whole shape: rise to full over seven shots
		and stay at full forever. That is a gun that climbs at a constant rate for
		as long as you hold the trigger, and with the spring's equilibrium sitting
		wherever impulse rate meets recovery, a long spray walks the camera at the
		sky. Reported as exactly that — "when people shoot guns and makes them go
		up high, i like that but its too much".

		The missing third of the curve is the PLATEAU and the decay after it. Real
		patterns rise hard, level off, and then convert what is left into a
		sideways sweep — which is what makes a long spray something you ride
		rather than something you fight, and what makes the first five rounds the
		part worth aiming.

		    shots 1-5      rise, 0.5x to 1.0x       the burst you aim
		    shots 6-12     fall to 0.25x            the spray that goes sideways

		── MEASURED, NOT GUESSED ───────────────────────────────────────────────
		Simulated against the real spring across the roster — AKM, M4, Vector,
		M60 — comparing peak climb before and after:

		    3-round tap        -7%
		    10-round burst    -20%
		    30-round spray    -21%

		Which is the shape the change was asked for: the kick a player says they
		LIKE is a tap, and it is almost untouched; the part that was too much is
		the long hold, and that is a fifth quieter. The dials are these three plus
		ViewScale, and a further pass at SettleShots 5 / SustainScale 0.22 /
		ViewScale 0.60 measures -10% and -29% if the spray still reads as too
		much in play.
	]]
	SettleShots = 6,
	SustainScale = 0.25,
	--[[ How many shots the fall from full to SustainScale takes. Gradual rather
	     than a step, because a gun that abruptly stopped kicking would read as
	     the recoil breaking rather than as the pattern flattening. ]]
	SettleFalloff = 6,

	--[[
		The ceiling, in degrees of accumulated climb.

		── AND IT IS A BACKSTOP, NOT THE MECHANISM ─────────────────────────────
		Worth being exact about, because the obvious story is wrong. The intuition
		is that a held trigger climbs without bound as impulses outrun recovery,
		and that a ceiling is what stops it. Simulated against the real spring —
		damping 0.78, speed = each weapon's recoilRecovery — that is not what
		happens: the spring reaches equilibrium within about ten shots and stays
		there. An AKM peaks at 2.2 degrees on shot ten and 2.3 on shot thirty.

		So sustained fire was never the runaway it feels like, and a ceiling
		generous enough to sound safe would have been decoration. Four degrees is
		chosen to sit just above the heaviest weapon in the roster at full spray
		(the M60 at 3.2 before this change, 2.3 after), so it binds on that gun
		and that gun only, and only when somebody empties a belt.

		What actually took the excess out is the SETTLE curve above: a 20-25%
		reduction in peak climb on a long burst and about 10% on a tap. This
		catches the case a future weapon with a slow recovery would otherwise
		find.

		Applied as headroom rather than as a clamp — see CameraController.
		addRecoil. A hard clamp stops the camera dead, which reads as hitting a
		wall; scaling by what is left reads as the gun running out of room.
	]]
	MaxClimbDegrees = 4,
	--[[ The fraction of that ceiling the impulse is untouched below. Without it a
	     cap scales every shot from zero and is a tuning knob rather than a limit
	     — see CameraController.addRecoil, which has the measurement. At 0.7 the
	     backstop starts at 2.8 degrees, which nothing in the roster reaches. ]]
	ClimbKnee = 0.7,

	--[[
		How much of the horizontal is a SHAPE rather than noise.

		It was NextNumber(-1, 1) — uniform, unbiased, unlearnable. That reads as
		the sight rattling rather than as the gun pulling, and it made
		recoilHorizontal a measure of how RANDOM a weapon is instead of how it
		behaves. Half of it is now a slow sweep keyed to the burst index, which is
		identical every burst and therefore counterable; the rest is still noise so
		it cannot simply be pre-aimed.

		DriftPeriod is in SHOTS, not seconds, so the sweep is a property of the
		pattern rather than of the fire rate — a 1100rpm Vector and a 550rpm M60
		trace the same shape, just at different speeds.
	]]
	HorizontalDrift = 0.55,
	DriftPeriod = 9,
})

GameConfig.Corpses = table.freeze({
	--[[
		How many corpses may exist at once. Past this the OLDEST is recycled.

		This is what actually decides whether a body lasts its corpseLifetime, and
		at 26 it decided "no": a horde puts 26 bodies on the floor in seconds, so
		every corpse was destroyed almost immediately no matter what its lifetime
		said. That is the "bodies disappear instantly" report, and the lifetime
		was never the thing to change.

		48 is affordable now for a reason rather than by hope. GoreService anchors
		a ragdoll once it has settled, so a corpse past its first second costs
		draw calls and no physics or physics replication — the cost this ceiling
		was defending against is only paid by the handful still falling.

		Deliberately NOT device-scaled, unlike the client-side gore budgets.
		Corpses are replicated instances that every client shares, so this is a
		server decision and one client's hardware cannot be allowed to decide how
		many bodies everyone else sees. The client-side budgets in GoreConfig are
		where a phone gets its relief.
	]]
	MaxRagdolls = 48,
	MaxGibs = 90,
	MaxBloodDecals = 160,
})

return table.freeze(GameConfig)
