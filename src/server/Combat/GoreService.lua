--!nonstrict
--[[
	GoreService — the quarter-second the rest of the combat loop exists to reach.

	Three outcomes, chosen by GoreConfig.Scoring and nothing else: a clean
	ragdoll, a limb coming off, or the body replaced by chunks. Nothing in this
	file invents a balance number; every threshold, count, lifetime and ceiling
	is read from GoreConfig, InfectedConfig or WeaponConfig.

	── WHO OWNS WHAT ───────────────────────────────────────────────────────────
	The server/client split here is deliberate, and it is the reason forty-six
	bodies can come apart in the same second without the frame budget dying.

	The SERVER owns everything four players must AGREE on:
	  * ragdoll physics — a corpse is a real object at a real position, and two
	    players looking at a different pile of bodies is a bug
	  * severed limbs — a leg on the floor is world state, not decoration
	  * every budget, every lifetime, and the outgoing event throttle

	The CLIENT owns pure decoration, which is an order of magnitude cheaper
	rendered locally and which nobody has to agree on:
	  * blood spray, mist, and the wall decals that make a room remember a fight
	  * blood pools under settled bodies
	  * gib chunks

	Gib chunks are the important one. Nine parts per body across a horde is
	thousands of networked physics objects for something that is on screen for
	twelve seconds. So a gib does NOT replicate as parts: the server hides the
	body, decides the chunk count against its own budget, and sends ONE
	GoreEvent carrying a seed. Every client in range builds the same chunks from
	the same shared GoreConfig and the same seed, so the explosion reads
	identically for everyone without a single replicated instance.

	── THE GoreEvent PAYLOAD ───────────────────────────────────────────────────
	Remotes.fireInRange("GoreEvent", position, GoreConfig.Budget.CullDistance, {
	    model     Model?    the body, nil for an incidental blood hit
	    level     string    Enums.GoreLevel — None / Dismember / Gib / Incinerate
	    part      string?   severed part name (Dismember), or the struck part
	    position  Vector3   where it happened; also the cull origin
	    normal    Vector3   surface normal at the impact, for spray direction
	    direction Vector3   unit direction of travel, for decal projection
	    force     number    impulse magnitude actually applied, studs/sec
	    scale     number    blood volume multiplier on GoreConfig.Blood counts
	    seed      number    deterministic chunk/spatter seed
	    count     number?   gib chunk count the server's budget allows
	    decal     boolean   the server already rolled DecalChance; just draw it
	    pool      boolean   a settled body: grow a pool here over PoolGrowTime
	    kill      boolean   false for an incidental hit
	    hitStop   number    seconds of freeze, 0 for none
	    timeScale number    how far the world slows during that freeze
	    attacker  Player?   ONLY this player freezes — see below
	})

	Hit-stop is the cheapest trick in the satisfaction toolbox and the reason a
	kill lands physically instead of just resolving. But it belongs to the player
	who earned it: freezing all four survivors every time one of them kills a
	Common would be unreadable during a horde. The event is fired in range to
	everyone because everyone needs the blood; `attacker` tells one client that
	the freeze is theirs.

	── PERFORMANCE ─────────────────────────────────────────────────────────────
	One Heartbeat connection for the whole subsystem, sweeping at SWEEP_INTERVAL.
	No per-corpse connection, no per-frame allocation, and every ceiling in
	GoreConfig.Budget enforced by recycling the OLDEST object rather than by
	refusing to render — a shot that produces no gore feels broken, and feeling
	broken is worse than costing a frame.
]]

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")

local AudioConfig = require(Shared.Config.AudioConfig)
local Attributes = require(Shared.Net.Attributes)
local Enums = require(Shared.Enums)
local GameConfig = require(Shared.Config.GameConfig)
local GoreConfig = require(Shared.Config.GoreConfig)
local InfectedConfig = require(Shared.Config.InfectedConfig)
local Registry = require(Shared.Util.Registry)
local Remotes = require(Shared.Net.Remotes)
local RigUtil = require(Shared.Util.RigUtil)
local Trove = require(Shared.Util.Trove)
local Types = require(Shared.Types)
local WeaponConfig = require(Shared.Config.WeaponConfig)

local SCORING = GoreConfig.Scoring
local LIMBS = GoreConfig.Dismemberment
local GIBS = GoreConfig.Gibs
local BLOOD = GoreConfig.Blood
local HITSTOP = GoreConfig.HitStop
local BUDGET = GoreConfig.Budget
local DEATH_ANIM = GoreConfig.DeathAnimation
local REGION = Enums.HitRegion
local LEVEL = Enums.GoreLevel

-- GameConfig.Corpses restates three of GoreConfig.Budget's ceilings, currently
-- with identical values. Rather than pick a winner and let the other drift into
-- a lie, take the tighter of each pair: whichever file is edited, the number
-- that protects the frame is the one that wins.
local MAX_RAGDOLLS = math.min(BUDGET.MaxActiveRagdolls, GameConfig.Corpses.MaxRagdolls)
local MAX_GIBS = math.min(BUDGET.MaxActiveGibs, GameConfig.Corpses.MaxGibs)
local MAX_DECALS = math.min(BUDGET.MaxActiveDecals, GameConfig.Corpses.MaxBloodDecals)

local random = Random.new()

-- ── constants that are physics or plumbing, not balance ─────────────────────
-- Anything a designer would want to tune lives in GoreConfig. These are the
-- numbers that exist only because Roblox physics needs them.

local GORE_FOLDER = "FL_Gore"

--[[
	dismemberPower's weight in the dismember gate.

	GoreConfig.Scoring weights gibPower and nothing else, so every weapon's
	dismemberPower — graded individually across all sixteen, and the machete's
	whole stated identity — was dead data and the machete gibbed every swing.
	GoreConfig has no field to hang a weight on and this file does not own it, so
	the weight is derived here.

	Deliberately under WeaponGibWeight (0.75): severing is the common outcome and
	should not become automatic on every limb kill, but it is large enough that
	the weapons WeaponConfig describes as cutting clear DismemberScore (0.45) on
	their own — the machete at 1.0 scores 0.50, the .357 at 0.85 scores 0.43 and
	needs only the limb's own region bonus, an MP7 at 0.16 scores 0.08 and still
	has to earn it with overkill.
]]
local DISMEMBER_WEIGHT = 0.5

--[[
	Above this, a weapon cuts rather than bursts and its dismemberment is tested
	BEFORE the gib gates instead of after them.

	The measure is dismemberPower MINUS gibPower, because that difference is the
	part of a weapon's identity gibPower cannot already express:

	    machete    1.00 - 0.20 = 0.80   cuts
	    M1A EBR    0.95 - 0.45 = 0.50   cuts
	    .357       0.85 - 0.40 = 0.45
	    AKM        0.60 - 0.22 = 0.38
	    PPSh-41    0.18 - 0.04 = 0.14
	    shotgun    1.00 - 1.00 = 0.00   bursts

	It has to be precedence and not more arithmetic. The machete deals 300 to a
	50-health Common, so overkillRatio alone is 5.0 on a chest hit and 23.0
	through the 4x head multiplier; no weighting that is added to or multiplied
	into the score survives numbers that size, and every swing keeps reading as a
	point-blank shotgun blast. 0.5 claims the machete and the two marksman
	rifles — the three weapons WeaponConfig describes as taking a head off
	cleanly — and leaves every automatic (0.38 and below) and the shotgun (0.00)
	scoring exactly as they did.
]]
local CUT_PRECEDENCE = 0.5

-- Corpses expire on human timescales, so sweeping at 5Hz instead of 60 is the
-- same behaviour for a twelfth of the cost.
local SWEEP_INTERVAL = 0.2

-- Roughly the mass of a default humanoid rig. WeaponConfig.knockback is
-- expressed in studs/sec against a body this heavy; a Charger, several times
-- heavier, moves proportionally less from the same round. This is the one
-- number that converts "knockback" into a velocity, and it is here rather than
-- in GoreConfig because it describes Roblox's mass units, not the game.
local REFERENCE_BODY_MASS = 14

-- A hard ceiling on launch speed. Without it a light or badly-scaled rig hit by
-- a shotgun leaves the map, and a corpse nobody can find is not gore.
local MAX_RAGDOLL_SPEED = 140

-- Bodies and limbs get a little lift so they tumble instead of sliding. Gibs
-- have GoreConfig.Gibs.UpwardBias for this; ragdolls need far less of it or a
-- kill reads as a cartoon launch.
local RAGDOLL_LIFT = 0.22

-- A limb never flies slower than LimbImpulse and never faster than this many
-- times it, no matter what the weapon's knockback claims.
local LIMB_IMPULSE_CEILING = 3

-- Blood volume multipliers handed to the client as `scale`. They multiply
-- GoreConfig.Blood's particle counts and decal size; the counts themselves stay
-- in the config where they belong.
local BLOOD_SCALE_HIT = 1.0
local BLOOD_SCALE_KILL = 1.35
local BLOOD_SCALE_DISMEMBER = 1.8
local BLOOD_SCALE_GIB = 2.6

-- A body is "settled" once it stops moving for this long, which is when a pool
-- starts growing under it.
local SETTLE_SPEED = 2.0
local SETTLE_TIME = 0.6

--[[
	The floor on how long a corpse gets to be a corpse before it becomes scenery.

	Freezing is measured from motion, and motion is not reliable at the instant
	of death. A Humanoid handing over to PlatformStand + Physics takes a frame or
	two to actually let go, and an assembly Roblox has put to sleep reports a
	velocity of exactly zero — so a body can read "still" while it is still
	standing up. Against a 5Hz sweep and a 0.6s window, three of those samples in
	a row is all it takes, and the body locks upright in its death pose.

	That is the whole of "they don't ragdoll on the ground". No amount of tuning
	SETTLE_SPEED fixes it, because the reading is not noisy — it is zero.
]]
local RAGDOLL_MIN_FALL = 1.2

--[[ How many of a rig's parts the settle test watches. Disabling the motors
     makes every limb its own assembly, so the root's velocity is not the body's:
     the torso is the heaviest and most constrained piece and comes to rest
     first, while the arms and legs are still swinging. Watching only the root
     froze bodies mid-collapse. Sampled rather than exhaustive because this runs
     per corpse per sweep and a dozen parts times a full graveyard is not free. ]]
local SETTLE_SAMPLE = 6

-- Slack past a managed lifetime before Debris takes over. The sweep normally
-- gets there first; this only matters if this service is ever torn down or
-- throws mid-round, and a severed arm that outlives the server is a haunting.
local DEBRIS_GRACE = 6

-- Kill-grade events may overdraw the throttle; incidental spray may not.
local PRIORITY_BLOOD = 1
local PRIORITY_KILL = 2

-- No infected kind attribute means no per-kind lifetime, so a stray body falls
-- back to the Common's rather than to a number invented here.
local FALLBACK_CORPSE_LIFETIME = InfectedConfig.Definitions[Enums.Infected.Common].corpseLifetime

--[[
	Ragdoll joint limits, keyed by Motor6D name so R6 and R15 both resolve.

	The point of the asymmetry is that a body should bend like a body. A uniform
	ball socket everywhere gives you the classic dropped-marionette corpse, with
	elbows folding the wrong way and a neck that rotates like an owl's — which
	reads as comedy at exactly the moment the game wants weight. Elbows and knees
	therefore get a narrow cone and a one-way twist range; shoulders and hips get
	room; the neck gets very little.

	Twist sign depends on the rig's C0 orientation. If a rig's knees hinge the
	wrong way, flip that row rather than widening it — a symmetric range hides
	the bug and brings the marionette back.
]]
local JOINT_LIMITS = table.freeze({
	Neck = { upper = 40, twistLow = -45, twistHigh = 45 },
	Waist = { upper = 26, twistLow = -30, twistHigh = 30 },

	LeftShoulder = { upper = 85, twistLow = -60, twistHigh = 60 },
	RightShoulder = { upper = 85, twistLow = -60, twistHigh = 60 },
	["Left Shoulder"] = { upper = 85, twistLow = -60, twistHigh = 60 },
	["Right Shoulder"] = { upper = 85, twistLow = -60, twistHigh = 60 },

	LeftElbow = { upper = 12, twistLow = -4, twistHigh = 95 },
	RightElbow = { upper = 12, twistLow = -4, twistHigh = 95 },
	LeftWrist = { upper = 28, twistLow = -25, twistHigh = 25 },
	RightWrist = { upper = 28, twistLow = -25, twistHigh = 25 },

	LeftHip = { upper = 62, twistLow = -35, twistHigh = 35 },
	RightHip = { upper = 62, twistLow = -35, twistHigh = 35 },
	["Left Hip"] = { upper = 62, twistLow = -35, twistHigh = 35 },
	["Right Hip"] = { upper = 62, twistLow = -35, twistHigh = 35 },

	LeftKnee = { upper = 10, twistLow = -100, twistHigh = 2 },
	RightKnee = { upper = 10, twistLow = -100, twistHigh = 2 },
	LeftAnkle = { upper = 24, twistLow = -20, twistHigh = 20 },
	RightAnkle = { upper = 24, twistLow = -20, twistHigh = 20 },
})

local DEFAULT_JOINT_LIMIT = table.freeze({ upper = 45, twistLow = -35, twistHigh = 35 })

-- The root joint is left alone: HumanoidRootPart is a collision box, not a body
-- part, and freeing it just adds a floating brick to every corpse.
local ROOT_JOINTS = table.freeze({ Root = true, RootJoint = true })

local SEVERABLE: { [string]: boolean } = {}
for _, name in LIMBS.Severable do
	SEVERABLE[name] = true
end
table.freeze(SEVERABLE)

--[[
	Which parts a region may cost you, best first. Uppers come first on purpose:
	taking the whole arm off is what a player expects from a hit anywhere on it,
	and it is what looks right.
]]
local REGION_PARTS = table.freeze({
	[REGION.Head] = table.freeze({ "Head" }),
	[REGION.Arm] = table.freeze({
		"RightUpperArm",
		"LeftUpperArm",
		"Right Arm",
		"Left Arm",
		"RightLowerArm",
		"LeftLowerArm",
	}),
	[REGION.Leg] = table.freeze({
		"RightUpperLeg",
		"LeftUpperLeg",
		"Right Leg",
		"Left Leg",
		"RightLowerLeg",
		"LeftLowerLeg",
	}),
})

local EMPTY_LIST = table.freeze({})

local function unitOr(vector: Vector3, fallback: Vector3): Vector3
	if vector.Magnitude < 1e-4 then
		return fallback
	end
	return vector.Unit
end

local function randomSpin(magnitude: number): Vector3
	local raw = Vector3.new(random:NextNumber(-1, 1), random:NextNumber(-1, 1), random:NextNumber(-1, 1))
	return unitOr(raw, Vector3.yAxis) * magnitude
end

--[[ One line per problem per kind, not one per corpse. A rig that cannot ragdoll
     produces a body every few seconds for the whole round, and a warning that
     repeats that often is a warning nobody reads. ]]
local warned: { [string]: boolean } = {}

local function warnOnce(key: string, message: string)
	if warned[key] then
		return
	end
	warned[key] = true
	warn("[GoreService] " .. message)
end

--[[ Walks a rig ONCE and returns its parts and its motors keyed by the part they
     hold on. Every path in this file that needs both would otherwise pay for two
     or three separate GetDescendants passes on every single death. ]]
local function collectRig(model: Model): ({ BasePart }, { [string]: Motor6D })
	local parts: { BasePart } = {}
	local motors: { [string]: Motor6D } = {}
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			if not descendant:FindFirstAncestorWhichIsA("Accessory") then
				table.insert(parts, descendant)
			end
		elseif descendant:IsA("Motor6D") then
			--[[ Not Part1 directly. See RigUtil.motorChild: a rig wired backwards
			     puts the TORSO on Part1 for every limb, so both shoulders would
			     land on the same key and one would be dropped — arms that never
			     ragdoll and never come off, on a rig where nothing is wrong. ]]
			local child = RigUtil.motorChild(descendant)
			if child then
				motors[child.Name] = descendant
			end
		end
	end
	return parts, motors
end

local GoreService = {}

GoreService._trove = Trove.new()
GoreService._folder = nil :: Folder?

-- FIFO, oldest first. Recycling means "destroy index 1", which is why these are
-- arrays and not sets.
GoreService._ragdolls = {} :: { any }
GoreService._limbs = {} :: { any }
GoreService._gibBatches = {} :: { any }
GoreService._decals = {} :: { any }

GoreService._gibCount = 0
GoreService._decalCount = 0

-- Survivor bodies are ragdolled but never recycled and never destroyed: they
-- are defibrillator targets, and deleting one deletes a teammate's only way
-- back into the round. Held as a list purely so the sweep can drop the ones
-- SurvivorService replaced on a respawn and keep the counts honest.
GoreService._survivorBodies = {} :: { Model }

-- Weak keys throughout: a model destroyed by another service must not pin its
-- bookkeeping in memory for the rest of the round.
GoreService._processed = setmetatable({}, { __mode = "k" })
GoreService._ragdolled = setmetatable({}, { __mode = "k" })
GoreService._joints = setmetatable({}, { __mode = "k" })
GoreService._decapitating = setmetatable({}, { __mode = "k" })

GoreService._tokens = BUDGET.MaxGoreEventsPerSecond
GoreService._tokensAt = os.clock()
GoreService._suppressed = 0
GoreService._sweepAccumulator = 0

-- ── lifecycle ───────────────────────────────────────────────────────────────

function GoreService:init()
	local folder = Workspace:FindFirstChild(GORE_FOLDER)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = GORE_FOLDER
		folder.Parent = Workspace
	end
	self._folder = folder :: Folder
	self._trove:add(folder)
end

function GoreService:start()
	-- ONE connection for every corpse, limb and pool in the game. Per-body
	-- connections are how a horde turns into a slideshow.
	self._trove:add(RunService.Heartbeat:Connect(function(deltaTime: number)
		self._sweepAccumulator += deltaTime
		if self._sweepAccumulator >= SWEEP_INTERVAL then
			local elapsed = self._sweepAccumulator
			self._sweepAccumulator = 0
			self:_sweep(elapsed)
		end
	end))
end

-- ── the roll ────────────────────────────────────────────────────────────────

--[[
	GoreConfig.Scoring's formula, verbatim:

	    score = overkillRatio * OverkillWeight
	          + weapon.gibPower * WeaponGibWeight
	          + RegionBonus[region]
	          + ContactBonus            (when distance < ContactRange)

	Everything after the arithmetic is a gate, in strict precedence order. The
	gates matter as much as the score: they are what keeps a Tank falling in one
	piece and a Boomer never doing so.

	The dismember gate additionally weights the weapon's `dismemberPower`, which
	GoreConfig's formula has no term for and which nothing was reading — see
	DISMEMBER_WEIGHT and CUT_PRECEDENCE above. A weapon that cuts far harder than
	it bursts is checked for a sever BEFORE the gib gates; everything else keeps
	GoreConfig's order exactly.
]]
function GoreService:evaluate(model: Model, ctx, overkill: number, maxHealth: number): (string, string?)
	if not GoreConfig.Enabled or not model then
		return LEVEL.None, nil
	end

	-- A survivor's corpse is a defibrillator target and a place their team
	-- remembers. It ragdolls and it bleeds, but it never comes apart, because a
	-- gibbed body is a teammate who cannot be brought back.
	if RigUtil.isSurvivor(model) then
		return LEVEL.None, nil
	end

	local definition = InfectedConfig.get(model:GetAttribute(Attributes.Infected.Kind) or "")
	local weapon = if ctx.weaponId then WeaponConfig.get(ctx.weaponId) else nil

	local overkillRatio = math.max(overkill, 0) / math.max(maxHealth, 1)
	local score = overkillRatio * SCORING.OverkillWeight
	if weapon then
		score += weapon.gibPower * SCORING.WeaponGibWeight
	end
	score += SCORING.RegionBonus[ctx.region] or 0
	if ctx.distance < SCORING.ContactRange then
		score += SCORING.ContactBonus
	end

	-- The same score, plus what the weapon brings to a clean cut specifically.
	-- Only the dismember gate reads this; the gib gate keeps GoreConfig's formula
	-- untouched, so nothing here can make a body burst that would not have.
	local cutPreference = 0
	local dismemberScore = score
	if weapon then
		cutPreference = math.clamp(weapon.dismemberPower - weapon.gibPower, 0, 1)
		dismemberScore += weapon.dismemberPower * DISMEMBER_WEIGHT
	end

	-- Fire never gibs and never severs: a burned body has to stay recognisably
	-- a body, which is the whole reason Incinerate is its own gore level. This
	-- gate runs first so that even a body which cannot come apart still reads as
	-- having burned rather than as having simply fallen over.
	if ctx.damageType == Enums.DamageType.Fire then
		return (if SCORING.FireNeverGibs then LEVEL.Incinerate else LEVEL.Gib), nil
	end

	-- A body that cannot come apart cannot come apart, and this beats every
	-- other rule including ExplosiveAlwaysGibs. "A Tank falls in one piece; it
	-- earned that" is a statement about the Tank, not about grenades.
	if definition and not definition.dismemberable then
		return LEVEL.None, nil
	end

	if ctx.damageType == Enums.DamageType.Explosive and SCORING.ExplosiveAlwaysGibs then
		return LEVEL.Gib, nil
	end

	-- A cutting weapon takes the limb it struck instead of bursting the body,
	-- however far past zero the hit went — that is what "the machete takes heads
	-- off cleanly" has to mean, and it is why this sits ahead of both gib gates
	-- rather than after them. It can only ever fire on a region that has
	-- something to sever, so a chest hit still bursts, and the shotgun never
	-- reaches it at all.
	if cutPreference >= CUT_PRECEDENCE and dismemberScore >= SCORING.DismemberScore then
		local part = self:_pickSeverablePart(model, ctx)
		if part then
			return LEVEL.Dismember, part
		end
	end

	-- gibThreshold is a SUFFICIENT condition, not an extra gate on the score:
	-- "overkill damage past which the body comes apart". Reading it as an extra
	-- AND would make the Boomer's threshold of 1 mean nothing, and the Boomer
	-- always coming apart is the joke that field was written for.
	if score >= SCORING.GibScore or (definition and overkill >= definition.gibThreshold) then
		return LEVEL.Gib, nil
	end

	if dismemberScore >= SCORING.DismemberScore then
		local part = self:_pickSeverablePart(model, ctx)
		if part then
			return LEVEL.Dismember, part
		end
	end

	return LEVEL.None, nil
end

--[[ Which part actually comes off. The struck part is always the best answer —
     a player who shot a forearm expects to see that forearm leave. ]]
function GoreService:_pickSeverablePart(model: Model, ctx): string?
	local candidates = REGION_PARTS[ctx.region]
	if not candidates then
		return nil -- torso hits do not sever anything; they gib or they do not
	end

	local _, motors = collectRig(model)

	local hitPart = ctx.hitPart
	if hitPart and SEVERABLE[hitPart.Name] and motors[hitPart.Name] then
		return hitPart.Name
	end

	-- Otherwise pick a limb of the right region that this rig actually has,
	-- starting at a random index so an unlucky ricochet does not always take the
	-- same arm off every zombie in the horde.
	local count = #candidates
	local start = random:NextInteger(1, count)
	for offset = 0, count - 1 do
		local name = candidates[(start + offset - 1) % count + 1]
		if motors[name] then
			return name
		end
	end
	return nil
end

-- ── the kill ────────────────────────────────────────────────────────────────

--[[
	Everything that happens to a body at the moment it stops working. Called by
	DamageService once per death, with the level already decided by evaluate.
]]
function GoreService:processKill(model: Model, ctx, result)
	if not GoreConfig.Enabled or not model or not model.Parent then
		return
	end
	-- A corpse must never be worth gore twice. Two pellets from the same blast
	-- land on the same frame, and both of them resolve as kills.
	if self._processed[model] then
		return
	end
	self._processed[model] = true

	ctx = ctx or Types.newDamageContext()
	local level = (result and result.goreLevel) or LEVEL.None
	local severed = result and result.severedPart

	-- The level normally arrives already decided by evaluate, but DamageService
	-- independently force-sets Gib for every explosive kill as a backstop. That
	-- would beat InfectedConfig.dismemberable, so the rule is re-checked on the
	-- way in: whoever names the level, a body that cannot come apart does not.
	local kind = model:GetAttribute(Attributes.Infected.Kind)
	local archetype = InfectedConfig.get(kind or "")
	if archetype and not archetype.dismemberable and level ~= LEVEL.Incinerate then
		level = LEVEL.None
		severed = nil
	end

	-- RigUtil.isAlive gates on this attribute, so a body that reaches here
	-- without it would keep absorbing bullets and producing more gore. The
	-- owning service normally sets it first; this is the belt to that braces.
	if
		kind ~= nil
		and model:GetAttribute(Attributes.Infected.IsDead) ~= true
		and RigUtil.isInfected(model)
	then
		model:SetAttribute(Attributes.Infected.IsDead, true)
	end

	local root = RigUtil.getRoot(model)
	local position = if ctx.hitPosition ~= Vector3.zero
		then ctx.hitPosition
		else (root and root.Position or Vector3.zero)
	local direction = unitOr(ctx.direction, Vector3.new(0, 0, -1))
	local normal = unitOr(ctx.hitNormal, -direction)

	local weapon = if ctx.weaponId then WeaponConfig.get(ctx.weaponId) else nil
	-- No weapon means fire, a fall or a special's claws. Those bodies crumple
	-- where they stand rather than flying, which is correct: nothing pushed them.
	local knockback = if weapon then weapon.knockback else 0

	if level == LEVEL.Gib then
		self:gib(model, position, direction, ctx.attacker)
		return
	end

	--[[
		The death clip gets the body first, and the ragdoll waits for it.

		InfectedService starts the clip in _retire, which runs off Humanoid.Died
		and therefore BEFORE this — and writes how long it runs. Ragdolling now
		would disable every Motor6D the clip is driving and the animation would
		be replaced by a sack falling over on the frame it started.

		Only for a tidy death. A body coming apart at the shoulder, bursting, or
		burning does not first perform a clean collapse, so those ragdoll on the
		same frame they always did.

		Capped, and the cap is the point: a clip that is long, mis-authored, or
		reporting a nonsense length must never leave a body standing there. Past
		the cap the ragdoll happens whatever the animation thinks.
	]]
	local hold = 0
	if level == LEVEL.None and DEATH_ANIM.Enabled then
		hold = math.clamp(
			tonumber(model:GetAttribute(Attributes.Infected.DeathHold)) or 0,
			0,
			DEATH_ANIM.MaxHold
		)
	end

	if hold > 0 then
		--[[ No impulse on a held ragdoll. The knockback is the body's REACTION to
		     being shot, and the clip is already performing one — applying it a
		     second later would jerk a corpse that had finished falling. ]]
		task.delay(hold, function()
			if model.Parent then
				self:ragdoll(model, nil)
			end
		end)
	end
	local applied = if hold > 0 then 0 else self:ragdoll(model, direction * knockback)

	if level == LEVEL.Dismember then
		severed = severed or self:_pickSeverablePart(model, ctx)
		if severed then
			-- The limb leaves faster than the body it came off, always.
			self:dismember(model, severed, direction, math.max(knockback, LIMBS.LimbImpulse), ctx.attacker)
		else
			level = LEVEL.None
		end
	end

	if level ~= LEVEL.Dismember then
		local audio = Registry.find("AudioService")
		if audio then
			audio:playAt(AudioConfig.Gore.BodyFall, position)
		end
		self:_emit({
			model = model,
			level = level,
			part = if ctx.hitPart then ctx.hitPart.Name else nil,
			position = position,
			normal = normal,
			direction = direction,
			force = applied,
			scale = BLOOD_SCALE_KILL,
			seed = random:NextInteger(1, 2 ^ 31 - 1),
			decal = self:_rollDecal(BLOOD.DecalChanceOnKill),
			pool = false,
			kill = true,
			hitStop = self:_hitStopFor(level, ctx),
			timeScale = HITSTOP.TimeScale,
			attacker = ctx.attacker,
		}, PRIORITY_KILL)
	end
end

--[[ Which freeze this kill earns. Gib beats headshot beats plain kill; the
     numbers themselves are GoreConfig.HitStop's and are not negotiable here. ]]
function GoreService:_hitStopFor(level: string, ctx): number
	if not HITSTOP.Enabled then
		return 0
	end
	if level == LEVEL.Gib then
		return HITSTOP.GibSeconds
	end
	if ctx.region == REGION.Head then
		return HITSTOP.HeadshotKillSeconds
	end
	return HITSTOP.KillSeconds
end

-- ── ragdoll ─────────────────────────────────────────────────────────────────

--[[
	Turns a rig into a corpse and returns the launch speed actually applied.

	Motor6Ds are DISABLED rather than destroyed. A disabled motor stops holding
	its joint exactly as a destroyed one would, but it survives for dismember()
	to destroy properly and leaves the door open to un-ragdolling a body later —
	which RigUtil's comments assume is possible.
]]
function GoreService:ragdoll(model: Model, impulse: Vector3?): number
	if not model or not model.Parent or self._ragdolled[model] then
		return 0
	end
	self._ragdolled[model] = true

	local parts, motors = collectRig(model)
	-- Mass is read BEFORE makeDebris, which marks parts massless. A Common and a
	-- Charger have to answer the same shot differently, and this is the number
	-- that makes them.
	local mass = RigUtil.getMass(model)

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		-- Every one of these matters: a Humanoid left enabled will fight the
		-- constraints, try to stand its corpse back up, and keep playing the
		-- walk animation on a body lying face down.
		humanoid.BreakJointsOnDeath = false
		humanoid.RequiresNeck = false
		humanoid.AutoRotate = false
		humanoid.PlatformStand = true
		humanoid.WalkSpeed = 0
		humanoid.JumpPower = 0
		humanoid:SetStateEnabled(Enum.HumanoidStateType.GettingUp, false)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Running, false)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Climbing, false)
		humanoid:ChangeState(Enum.HumanoidStateType.Physics)

		local animator = humanoid:FindFirstChildOfClass("Animator")
		if animator then
			for _, track in animator:GetPlayingAnimationTracks() do
				track:Stop(0)
			end
		end
	end

	local joints: { [string]: BallSocketConstraint } = {}
	for partName, motor in motors do
		if ROOT_JOINTS[motor.Name] then
			continue
		end
		local constraint = self:_replaceMotor(motor)
		if constraint then
			joints[partName] = constraint
		end
	end
	self._joints[model] = joints

	--[[ A rig that yielded no constraints cannot ragdoll — there is nothing to
	     bend. The body still goes limp-ish because the Humanoid is on
	     PlatformStand, but it stays one rigid slab and tips over as a statue,
	     which is exactly what "they don't ragdoll" looks like.

	     This used to fail in complete silence. PlaceholderFactory audits every
	     rig's joints when it prepares the template and says so loudly, but that
	     check runs once per KIND at boot, and it does not fire for a rig whose
	     joints exist under names GoreConfig does not list — that rig has motors,
	     passes the audit's severable test, and still lands here with none it is
	     allowed to replace. Warned once per kind, because the alternative is one
	     line per corpse for the rest of the round. ]]
	if next(joints) == nil then
		local rigKind = tostring(model:GetAttribute(Attributes.Infected.Kind) or model.Name)
		warnOnce(
			"noragdoll:" .. rigKind,
			string.format(
				"%s produced no ragdoll joints, so its corpses stay rigid. Every Motor6D on the "
					.. "rig was either absent, missing a Part0/Part1, or named as a root joint. "
					.. "Check the rig has Motor6Ds joining its limbs to the torso.",
				rigKind
			)
		)
	end

	-- Contract call: corpses must never block a doorway, answer a raycast meant
	-- for a live target, or shove a survivor off a ledge.
	RigUtil.makeDebris(model)

	local root = RigUtil.getRoot(model)
	local isSurvivorBody = RigUtil.isSurvivor(model)
	for _, part in parts do
		-- makeDebris clears CanCollide, which would drop every corpse through
		-- the floor. The Debris collision group already stops bodies colliding
		-- with survivors, infected, gibs and each other, so putting world
		-- collision back is what the group was for — it only restores the floor.
		if part ~= root then
			part.CanCollide = true
		end
		-- A dead survivor is an interaction target for the rest of the round, so
		-- their body stays queryable or the defib prompt can never find it.
		if isSurvivorBody then
			part.CanQuery = true
		end
	end

	local speed = 0
	if impulse and impulse.Magnitude > 0 then
		-- Distributing one velocity across the body, rather than an impulse on
		-- one part, is what stops a corpse tearing itself inside out on the
		-- frame it dies. Mass decides how much of the weapon's knockback the
		-- body actually takes.
		speed = math.min(impulse.Magnitude * (REFERENCE_BODY_MASS / mass), MAX_RAGDOLL_SPEED)
		local velocity = unitOr(impulse, Vector3.new(0, 0, -1)) * speed + Vector3.yAxis * speed * RAGDOLL_LIFT
		-- Adding to the velocity rather than setting it keeps the momentum a
		-- sprinting Common already had, so a body shot mid-stride carries. Once
		-- per ASSEMBLY though: parts that are still joined share one velocity,
		-- and applying it per part would multiply the launch by the number of
		-- them and fire the corpse out of the level.
		local boosted: { [BasePart]: boolean } = {}
		for _, part in parts do
			local assembly = part.AssemblyRootPart
			if assembly and not boosted[assembly] then
				boosted[assembly] = true
				assembly.AssemblyLinearVelocity += velocity
			end
		end
		if root then
			root.AssemblyAngularVelocity += randomSpin(speed * RAGDOLL_LIFT)
		end
	end

	if isSurvivorBody then
		table.insert(self._survivorBodies, model)
		return speed
	end

	local definition = InfectedConfig.get(model:GetAttribute(Attributes.Infected.Kind) or "")
	local lifetime = if definition then definition.corpseLifetime else FALLBACK_CORPSE_LIFETIME

	-- FIFO recycling. Past the ceiling the OLDEST body goes, never the newest:
	-- the corpse a player is looking at right now is the one that matters, and
	-- refusing to make it would read as the gore system being broken.
	while #self._ragdolls >= MAX_RAGDOLLS do
		local oldest = table.remove(self._ragdolls, 1)
		if oldest and oldest.model then
			oldest.model:Destroy()
		end
	end

	--[[ A spread across the rig rather than the first few, so the sample reaches
	     the extremities. `parts` comes off GetDescendants in tree order — torso
	     and root first, hands and feet last — and taking the head of that list
	     would watch exactly the pieces that stop moving first. ]]
	local watch: { BasePart } = {}
	if root then
		table.insert(watch, root)
	end
	local stride = math.max(math.floor(#parts / SETTLE_SAMPLE), 1)
	for i = 1, #parts, stride do
		local part = parts[i]
		if part ~= root then
			table.insert(watch, part)
		end
		if #watch >= SETTLE_SAMPLE then
			break
		end
	end

	local now = os.clock()
	table.insert(self._ragdolls, {
		model = model,
		root = root,
		watch = watch,
		expiresAt = now + lifetime,
		-- Not before this. See RAGDOLL_MIN_FALL.
		settleFrom = now + RAGDOLL_MIN_FALL,
		stillFor = 0,
		settled = false,
	})
	Debris:AddItem(model, lifetime + DEBRIS_GRACE)

	return speed
end

--[[ One Motor6D becomes one BallSocketConstraint at exactly the same place. The
     attachments are built from C0/C1 so the joint sits where the rig's author
     put it, whatever the rig type or scale. ]]
function GoreService:_replaceMotor(motor: Motor6D): BallSocketConstraint?
	local part0, part1 = motor.Part0, motor.Part1
	if not part0 or not part1 then
		return nil
	end
	--[[ Which end the limb is on, for the socket's parent below. The constraint
	     itself is symmetric and works either way; where it LIVES is not. ]]
	local child = RigUtil.motorChild(motor) or part1

	local a0 = Instance.new("Attachment")
	a0.Name = "FL_RagdollA0"
	a0.CFrame = motor.C0
	a0.Parent = part0

	local a1 = Instance.new("Attachment")
	a1.Name = "FL_RagdollA1"
	a1.CFrame = motor.C1
	a1.Parent = part1

	local limit = JOINT_LIMITS[motor.Name] or DEFAULT_JOINT_LIMIT
	local socket = Instance.new("BallSocketConstraint")
	socket.Name = "FL_Ragdoll"
	socket.Attachment0 = a0
	socket.Attachment1 = a1
	socket.LimitsEnabled = true
	socket.TwistLimitsEnabled = true
	socket.UpperAngle = limit.upper
	socket.TwistLowerAngle = limit.twistLow
	socket.TwistUpperAngle = limit.twistHigh
	-- Parented to the CHILD part so that severing that part takes its joint with
	-- it, and so a limb reparented out of the body carries its own constraints.
	-- On a backwards-wired rig that is Part0, not Part1 — leaving the socket on
	-- the torso is a constraint that outlives the limb it was holding.
	socket.Parent = child

	motor.Enabled = false
	return socket
end

-- ── dismemberment ───────────────────────────────────────────────────────────

--[[
	Takes a part off, along with everything downstream of it. Returns whether the
	limb actually came away, so callers can fall back to a plain ragdoll.

	`attacker` is optional and decides nothing about the physics — it is only who
	gets the hit-stop freeze. A caller outside processKill may leave it out; the
	limb still comes off, nobody's screen just stutters for it.
]]
function GoreService:dismember(
	model: Model,
	partName: string,
	direction: Vector3,
	force: number,
	attacker: Player?
): boolean
	if not GoreConfig.Enabled or not model or not model.Parent or not SEVERABLE[partName] then
		return false
	end

	local motor = RigUtil.findMotorForPart(model, partName)
	if not motor or not motor.Part1 or not motor.Part0 then
		return false
	end

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid and partName == "Head" then
		-- Roblox kills a Humanoid the instant it loses its head, which would take
		-- the death outside DamageService entirely: no kill feed, no Director
		-- intensity, no gore roll. The decapitation still kills — through the
		-- funnel, at the bottom of this function — but it kills on our terms.
		humanoid.RequiresNeck = false
	end

	local limbRoot = motor.Part1
	local anchorPart = motor.Part0
	-- The joint's own world position: a stump should bleed from the socket, not
	-- from the middle of the limb that just left.
	local stump = (anchorPart.CFrame * motor.C0).Position
	local away = unitOr(limbRoot.Position - anchorPart.Position, Vector3.yAxis)

	-- The whole chain leaves together. Blowing off an upper arm and leaving the
	-- forearm hanging in mid-air is the failure mode GoreConfig.Children exists
	-- to prevent.
	local freed: { BasePart } = { limbRoot }
	for _, childName in LIMBS.Children[partName] or EMPTY_LIST do
		local child = model:FindFirstChild(childName, true)
		if child and child:IsA("BasePart") then
			table.insert(freed, child)
		end
	end

	motor:Destroy()
	local joints = self._joints[model]
	if joints and joints[partName] then
		joints[partName]:Destroy()
		joints[partName] = nil
	end
	-- Backstop for a limb severed off a body that was never ragdolled: the
	-- constraint is always parented to the child part and always named.
	local stale = limbRoot:FindFirstChild("FL_Ragdoll")
	if stale then
		stale:Destroy()
	end

	-- Workspace is the fallback only if init() never ran; a limb parented to nil
	-- would vanish on the frame it was severed.
	local folder = self._folder or Workspace
	local speed = math.clamp(force, LIMBS.LimbImpulse, LIMBS.LimbImpulse * LIMB_IMPULSE_CEILING)
	local velocity = unitOr(direction, away) * speed
		+ away * speed * RAGDOLL_LIFT
		+ Vector3.yAxis * speed * RAGDOLL_LIFT
	local spin = randomSpin(LIMBS.LimbSpin)

	for _, part in freed do
		-- Out of the character and into the gore folder, so the limb outlives or
		-- outdies its body on its own LimbLifetime rather than being taken with
		-- the corpse whenever that gets recycled.
		part.Parent = folder
		part.CanCollide = true
		part.CanQuery = false
		part.CanTouch = false
		part.Massless = false
		part.CollisionGroup = "Debris"
		part.AssemblyLinearVelocity = velocity
		part.AssemblyAngularVelocity = spin
	end

	while #self._limbs >= BUDGET.MaxActiveLimbs do
		local oldest = table.remove(self._limbs, 1)
		if oldest then
			for _, part in oldest.parts do
				part:Destroy()
			end
		end
	end
	table.insert(self._limbs, { parts = freed, expiresAt = os.clock() + LIMBS.LimbLifetime })
	for _, part in freed do
		Debris:AddItem(part, LIMBS.LimbLifetime + DEBRIS_GRACE)
	end

	local isHead = partName == "Head"
	local audio = Registry.find("AudioService")
	if audio then
		audio:playAt(if isHead then AudioConfig.Gore.Decapitate else AudioConfig.Gore.Dismember, stump)
	end

	self:_emit({
		model = model,
		level = LEVEL.Dismember,
		part = partName,
		position = stump,
		normal = away,
		direction = unitOr(direction, away),
		force = speed,
		scale = BLOOD_SCALE_DISMEMBER,
		seed = random:NextInteger(1, 2 ^ 31 - 1),
		decal = self:_rollDecal(BLOOD.DecalChanceOnKill),
		pool = false,
		kill = true,
		hitStop = if HITSTOP.Enabled then HITSTOP.KillSeconds else 0,
		timeScale = HITSTOP.TimeScale,
		attacker = attacker,
	}, PRIORITY_KILL)

	if isHead and LIMBS.DecapitationIsLethal then
		self:_killByDecapitation(model, direction)
	end

	return true
end

--[[
	A body with no head is dead, whatever the damage arithmetic said. It has to
	die through the damage funnel and not by writing to a Humanoid, because every
	consumer of a death — the kill feed, the Director's intensity, the round
	tally — hangs off DamageService, and a body that quietly stopped existing
	would be invisible to all of them.
]]
function GoreService:_killByDecapitation(model: Model, direction: Vector3)
	if self._decapitating[model] or not RigUtil.isAlive(model) then
		return
	end
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end
	local damageService = Registry.find("DamageService")
	if not damageService then
		return
	end

	self._decapitating[model] = true
	local root = RigUtil.getRoot(model)
	local definition = InfectedConfig.get(model:GetAttribute(Attributes.Infected.Kind) or "")
	local resistance = if definition then math.max(definition.damageResistance, 0.01) else 1

	-- Region Torso, and exactly the health remaining once the funnel's own
	-- resistance multiplier has been divided back out. Lethal to the point and
	-- no further: the head is already off, and an inflated number here would
	-- roll an overkill big enough to gib a body that has just been dismembered.
	damageService:applyDamage(
		model,
		humanoid.Health / resistance,
		Types.newDamageContext({
			damageType = Enums.DamageType.Melee,
			region = REGION.Torso,
			hitPosition = if root then root.Position else Vector3.zero,
			hitNormal = -direction,
			direction = direction,
		})
	)
end

-- ── gibbing ─────────────────────────────────────────────────────────────────

--[[
	The body stops existing and becomes chunks. The chunks themselves are built
	on each client from the seed below — see the header for why they are not
	replicated parts. `attacker` is optional and only decides who freezes.
]]
function GoreService:gib(model: Model, origin: Vector3, direction: Vector3, attacker: Player?)
	if not GoreConfig.Enabled or not model or not model.Parent then
		return
	end

	local parts = collectRig(model)
	local root = RigUtil.getRoot(model)
	local position = if root then root.Position else origin
	local dir = unitOr(direction, Vector3.new(0, 0, -1))

	-- Hidden, not destroyed on the spot: the model is the client's handle for
	-- the body that just stopped existing, and destroying it in the same frame
	-- the event goes out can beat the event to the client.
	for _, part in parts do
		part.Transparency = 1
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
	end
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid:ChangeState(Enum.HumanoidStateType.Physics)
		humanoid.PlatformStand = true
	end

	-- A gibbed body is no longer a ragdoll and must not hold a ragdoll slot.
	self:_forgetRagdoll(model)
	self._ragdolled[model] = true
	Debris:AddItem(model, SWEEP_INTERVAL)

	-- The budget decides the count, and it decides it downward rather than
	-- refusing: fewer chunks still reads as an explosion, no chunks reads as a
	-- bug. Never below CountMin — the floor is what keeps a gib a gib.
	local wanted = random:NextInteger(GIBS.CountMin, GIBS.CountMax)
	local headroom = MAX_GIBS - self._gibCount
	local count = math.clamp(math.min(wanted, math.max(headroom, 0)), GIBS.CountMin, GIBS.CountMax)

	while self._gibCount + count > MAX_GIBS and #self._gibBatches > 0 do
		local oldest = table.remove(self._gibBatches, 1)
		self._gibCount -= oldest.count
	end
	self._gibCount += count
	table.insert(self._gibBatches, { count = count, expiresAt = os.clock() + GIBS.Lifetime })

	local audio = Registry.find("AudioService")
	if audio then
		audio:playAt(AudioConfig.Gore.Gib, position)
	end

	self:_emit({
		model = model,
		level = LEVEL.Gib,
		part = nil,
		position = position,
		normal = -dir,
		direction = dir,
		force = GIBS.ImpulseMax,
		scale = BLOOD_SCALE_GIB,
		seed = random:NextInteger(1, 2 ^ 31 - 1),
		count = count,
		decal = self:_rollDecal(BLOOD.DecalChanceOnKill),
		pool = false,
		kill = true,
		hitStop = if HITSTOP.Enabled then HITSTOP.GibSeconds else 0,
		timeScale = HITSTOP.TimeScale,
		attacker = attacker,
	}, PRIORITY_KILL)
end

-- ── blood ───────────────────────────────────────────────────────────────────

--[[
	The three layers of GoreConfig.Blood, from one event: spray along the surface
	normal, a mist that hangs for an instant, and a decal projected down the shot
	line onto whatever was behind the target.

	This is the incidental-hit entry point — DamageService calls it for every
	flesh hit that did not kill. Kills emit their own richer event rather than
	calling through here, so a single death is one packet and not three.
]]
function GoreService:spawnBlood(position: Vector3, normal: Vector3, direction: Vector3, scale: number)
	if not GoreConfig.Enabled then
		return
	end
	self:_emit({
		model = nil,
		level = LEVEL.None,
		part = nil,
		position = position,
		normal = unitOr(normal, Vector3.yAxis),
		direction = unitOr(direction, -unitOr(normal, Vector3.yAxis)),
		force = 0,
		scale = (scale or 1) * BLOOD_SCALE_HIT,
		seed = random:NextInteger(1, 2 ^ 31 - 1),
		decal = self:_rollDecal(BLOOD.DecalChanceOnHit),
		pool = false,
		kill = false,
		hitStop = if HITSTOP.Enabled then HITSTOP.NormalHitSeconds else 0,
		timeScale = HITSTOP.TimeScale,
		attacker = nil,
	}, PRIORITY_BLOOD)
end

--[[
	Rolls the decal chance ONCE, on the server, so every client in range agrees
	on whether this hit left a mark. The projection raycast itself happens on the
	client — it is the same geometry there and it costs the server nothing.

	Returns false when the decal ceiling is full rather than recycling a specific
	decal: the client owns the actual instances and applies the same FIFO cap
	from the same shared config, so the ledger here only has to stay honest for
	getActiveCounts and for the throttle.
]]
function GoreService:_rollDecal(chance: number): boolean
	if not BLOOD.DecalEnabled or random:NextNumber() > chance then
		return false
	end
	while self._decalCount >= MAX_DECALS and #self._decals > 0 do
		table.remove(self._decals, 1)
		self._decalCount -= 1
	end
	self._decalCount += 1
	table.insert(self._decals, os.clock() + BLOOD.DecalLifetime)
	return true
end

-- ── throttle and sweep ──────────────────────────────────────────────────────

--[[
	MaxGoreEventsPerSecond, as a token bucket with an overdraft.

	During a 46-strong horde dying to an auto shotgun this is the difference
	between a firefight and a network stall. But a throttle that drops kills
	would delete the payoff exactly when there is most of it, so kills may
	overdraw the bucket by a full second's worth and incidental spray may not.
	The debt is real: a horde wipe borrows against the next second, and what goes
	quiet is background blood, which nobody was looking at anyway.
]]
function GoreService:_takeToken(priority: number): boolean
	local now = os.clock()
	local rate = BUDGET.MaxGoreEventsPerSecond
	self._tokens = math.min(rate, self._tokens + (now - self._tokensAt) * rate)
	self._tokensAt = now

	local floor = if priority >= PRIORITY_KILL then -rate else 0
	if self._tokens - 1 < floor then
		self._suppressed += 1
		return false
	end
	self._tokens -= 1
	return true
end

function GoreService:_emit(payload, priority: number): boolean
	if not self:_takeToken(priority) then
		return false
	end
	-- Gore beyond CullDistance is never sent: a firefight across the map must
	-- not cost a client bandwidth and particles for something it cannot see.
	Remotes.fireInRange("GoreEvent", payload.position, BUDGET.CullDistance, payload)
	return true
end

function GoreService:_forgetRagdoll(model: Model)
	for index, record in self._ragdolls do
		if record.model == model then
			table.remove(self._ragdolls, index)
			return
		end
	end
end

--[[ The one loop. Expiry for corpses, limbs and ledger entries, plus the pool
     check — a few dozen records at 5Hz, allocating nothing except on the frame
     a body actually settles and sends its pool event. ]]
--[[
	Turns a settled corpse from a physics body into scenery.

	A ragdoll that has stopped moving is still a full simulation: a dozen parts
	with BallSocketConstraints between them, solved every frame and replicated to
	every client, for a body that is not going anywhere. That cost is why the
	corpse ceiling was 26, and 26 is a few seconds during a horde — which is the
	whole of "bodies disappear instantly".

	Anchoring is invisible at the moment it happens, because the only bodies that
	reach here have been below SETTLE_SPEED for SETTLE_TIME. What it buys is that
	a corpse past this point costs draw calls and nothing else, which is what
	makes keeping them for thirty-five seconds affordable rather than a trade
	against the frame rate.

	The constraints are left in place rather than destroyed. They are inert
	against anchored parts, removing them is a dozen more Instance operations on
	a frame that just did some, and leaving them means a corpse can be unfrozen
	later — for a body a Tank punts across the room, if that is ever wanted —
	without rebuilding the ragdoll.
]]
local function freezeCorpse(model: Model)
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
		end
	end

	--[[ And the state machine with it. A Humanoid keeps evaluating its own state
	     every frame whether or not the body under it can move, and forty-eight of
	     them is forty-eight state machines running on the server for corpses that
	     are, by this point, scenery bolted to the floor.

	     `ragdoll` already disabled the states that could stand a body back up and
	     put it into Physics; this is the evaluation itself, and it is only safe
	     here — a body still falling needs its state machine to know it landed. ]]
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.EvaluateStateMachine = false
	end
end

function GoreService:_sweep(deltaTime: number)
	local now = os.clock()

	for index = #self._ragdolls, 1, -1 do
		local record = self._ragdolls[index]
		local model = record.model
		if not model or not model.Parent then
			table.remove(self._ragdolls, index)
			continue
		end
		if now >= record.expiresAt then
			table.remove(self._ragdolls, index)
			model:Destroy()
			continue
		end

		--[[ Settling. Two separate things happen the moment a body stops moving,
		     and they must not be wired together:

		       * It is ANCHORED, always. This is the budget. MAX_RAGDOLLS is 48
		         because a settled corpse costs draw calls and nothing else; if
		         freezing were optional then so is that ceiling, and a room full
		         of bodies is 48 live simulations instead of scenery.

		       * It bleeds into the floor, IF pools are enabled. That is a
		         cosmetic setting a player or a low-end preset can turn off, and
		         turning off a decal must never quietly turn off the physics
		         budget with it. ]]
		if not record.settled and now >= record.settleFrom then
			local moving = false
			for _, part in record.watch do
				if part.Parent and part.AssemblyLinearVelocity.Magnitude >= SETTLE_SPEED then
					moving = true
					break
				end
			end
			if not moving then
				record.stillFor += deltaTime
				if record.stillFor >= SETTLE_TIME then
					record.settled = true
					freezeCorpse(model)
					local root = record.root
					if BLOOD.PoolEnabled and root and root.Parent then
						self:_emit({
							model = model,
							level = LEVEL.None,
							part = nil,
							position = root.Position,
							normal = Vector3.yAxis,
							direction = Vector3.yAxis * -1,
							force = 0,
							scale = BLOOD_SCALE_HIT,
							seed = random:NextInteger(1, 2 ^ 31 - 1),
							decal = false,
							pool = true,
							kill = false,
							hitStop = 0,
							timeScale = HITSTOP.TimeScale,
							attacker = nil,
						}, PRIORITY_BLOOD)
					end
				end
			else
				record.stillFor = 0
			end
		end
	end

	for index = #self._survivorBodies, 1, -1 do
		local body = self._survivorBodies[index]
		if not body or not body.Parent then
			table.remove(self._survivorBodies, index)
		end
	end

	for index = #self._limbs, 1, -1 do
		local record = self._limbs[index]
		if now >= record.expiresAt then
			table.remove(self._limbs, index)
			for _, part in record.parts do
				part:Destroy()
			end
		end
	end

	-- The ledgers hold no instances, only counts: the client owns the chunks and
	-- decals themselves and expires them from the same shared config.
	while #self._gibBatches > 0 and now >= self._gibBatches[1].expiresAt do
		local oldest = table.remove(self._gibBatches, 1)
		self._gibCount -= oldest.count
	end
	while #self._decals > 0 and now >= self._decals[1] do
		table.remove(self._decals, 1)
		self._decalCount -= 1
	end
end

-- ── introspection ───────────────────────────────────────────────────────────

--[[ What the budget is currently holding. Cheap enough for a debug overlay to
     poll; `suppressed` is the count of gore events the throttle has ever
     dropped, which is the number to watch if a horde ever looks bloodless. ]]
function GoreService:getActiveCounts()
	return {
		ragdolls = #self._ragdolls + #self._survivorBodies,
		gibs = self._gibCount,
		limbs = #self._limbs,
		decals = self._decalCount,
		suppressed = self._suppressed,
	}
end

Registry.register("GoreService", GoreService)

return GoreService
