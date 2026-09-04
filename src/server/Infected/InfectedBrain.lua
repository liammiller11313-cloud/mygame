--!nonstrict
--[[
	InfectedBrain — the Common's head.

	The design target is a very specific feeling: a Common should be RELENTLESS
	and slightly stupid. It picks the survivor it wants, commits, and closes. It
	does not flank, it does not retreat, it does not out-think you. Everything
	clever in here exists to stop the AI from LOOKING broken — flip-flopping
	between two targets, freezing in a doorway, swinging with no telegraph — and
	nothing in here exists to make it play well.

	Two rules drive most of the code below:

	  1. A Common that stops moving is far worse than one that walks into a wall.
	     Every failure path — no path, path pending, path exhausted, stuck —
	     falls back to walking straight at the target.

	  2. Nothing here may cost a frame. 46 of these run at once, so the brain does
	     no per-frame allocation, never owns a RunService connection (InfectedService
	     ticks it), never calls ComputeAsync inline, and re-issues Humanoid:MoveTo
	     only when the destination has actually moved.

	── PUBLIC SURFACE FOR SPECIAL INFECTED MODULES ─────────────────────────────
	Six Infected/Specials/*.lua modules drive their own behaviour on top of this
	brain and are written against exactly this surface. Treat it as frozen:

	    brain.state          : string, one of InfectedBrain.State.* (read-only)
	    brain.model          : Model
	    brain.definition     : InfectedDefinition
	    brain.humanoid       : Humanoid
	    brain.root           : BasePart
	    brain.data           : {[string]: any} — scratch table owned by the special
	                           module. The brain never reads or writes it.

	    brain:getTarget()          -> Model?   current victim's character
	    brain:setTarget(model?)              force a victim (or clear it)
	    brain:pause()                        STOP the common AI. No pathing, no
	                                         attacking, no wandering. update() does
	                                         nothing until resume(). This is how a
	                                         Hunter pounce or a Charger charge takes
	                                         over movement.
	    brain:resume()                       hand control back
	    brain:isPaused()           -> boolean
	    brain:moveTo(position)               direct Humanoid:MoveTo, throttled, and
	                                         it clears any cached path. Safe to call
	                                         every frame while paused.
	    brain:stop()                         drop the move order and the path
	    brain:faceTowards(position, dt)      yaw toward a point, honouring the
	                                         definition's turnSpeed (this is what
	                                         makes a Charger clumsy). Disables
	                                         Humanoid.AutoRotate; resume() and the
	                                         end of an attack restore it.
	    brain:stagger(duration)              interrupt everything for `duration`
	    brain:isStaggered()        -> boolean
	    brain:lureTo(position, duration)     go stand at a point (pipe bomb, bile
	                                         splash on geometry) and ignore survivors
	    brain:distanceTo(model)    -> number  planar-ish distance, vertical penalised

	`onUpdate(model, brain, dt)` is called by InfectedService immediately after
	brain:update(). IMPORTANT: it does NOT run every frame for a Common — the
	service staggers common updates by distance. Specials and bosses ARE ticked
	every frame, so a special module may rely on frame-rate updates; `dt` is the
	real elapsed time since that entity's previous tick either way.
]]

local PathfindingService = game:GetService("PathfindingService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local AbilityConfig = require(Shared.Config.AbilityConfig)
local Attributes = require(Shared.Net.Attributes)
local BarricadeConfig = require(Shared.Config.BarricadeConfig)
local Enums = require(Shared.Enums)
local RaycastUtil = require(Shared.Util.RaycastUtil)
local ModifierConfig = require(Shared.Config.ModifierConfig)
local Registry = require(Shared.Util.Registry)
local InfectedAnimator = require(script.Parent.InfectedAnimator)
local RigUtil = require(Shared.Util.RigUtil)
local Trove = require(Shared.Util.Trove)
local Types = require(Shared.Types)

local InfectedBrain = {}
InfectedBrain.__index = InfectedBrain

--[[ The states a special module may see in `brain.state`. Controlled means a
     special has taken over and the common AI is standing down. ]]
InfectedBrain.State = table.freeze({
	Idle = "Idle", -- standing around, no target
	Wander = "Wander", -- shambling to a nearby point, no target
	Chase = "Chase", -- committed to a target and closing
	Attack = "Attack", -- inside the windup of a swing
	Stagger = "Stagger", -- shoved or knocked; nothing else happens
	Controlled = "Controlled", -- paused; a special module owns the body
})

local State = InfectedBrain.State

-- ── Awareness ───────────────────────────────────────────────────────────────
-- 160 degrees, not a human 100: a Common that ignores a survivor standing at
-- its shoulder reads as broken, and "slightly stupid" is meant to describe its
-- decisions, not its senses.
local SIGHT_COS = math.cos(math.rad(160 * 0.5))
-- Inside this, facing stops mattering entirely — you are close enough to smell.
local CONTACT_RADIUS = 14
-- How long a gunshot keeps pulling after it was fired.
local NOISE_MEMORY = 2.5

-- ── Target scoring ──────────────────────────────────────────────────────────
-- Everything is expressed as a multiplier on an "effective distance", so the
-- lowest number wins and every weight reads as "this looks N times closer".
--
-- Height is penalised because a survivor on a catwalk four studs overhead is a
-- long walk away, and a horde that picks them reads as a horde milling about
-- under a ledge instead of chasing the reachable player next to it.
local VERTICAL_PENALTY = 2.2
-- A downed survivor is what a horde converges on. That is the whole reason
-- being incapacitated alone is frightening.
local INCAP_ATTRACTION = 0.5
-- Hysteresis. A new candidate must look 28% closer than the current target to
-- steal it; without this, two survivors standing together make the whole horde
-- oscillate, and flip-flopping AI reads as broken faster than bad AI does.
local TARGET_STICKINESS = 0.72
local RETARGET_MIN, RETARGET_MAX = 0.45, 0.85

--[[
	How far away a turret can pull a body off the survivors, and how often this
	body bothers to look.

	Read once from the ability's own tuning rather than duplicated here, so
	changing what a turret is worth attacking is one number in AbilityConfig and
	not two files that quietly disagree. Defaulted, because an install with the
	Turret ability removed from the config must still boot.

	The interval is what keeps this cheap: a look costs a walk of the turret list
	— at most one per player — and it happens four times a second per body rather
	than sixty. A turret does not appear fast enough for that to matter.
]]
local TURRET_TUNING = (AbilityConfig.get(Enums.Ability.Turret) or {}).tuning or {}
local TURRET_AGGRO = TURRET_TUNING.AggroRadius or 22
local TURRET_LOOK_INTERVAL = 0.25
local TURRET_DAMAGE_SCALE = TURRET_TUNING.AttackDamageScale or 2.5

-- ── Pathing budget ──────────────────────────────────────────────────────────
-- Re-path between 0.6s and 1.2s, jittered per entity at construction so 46
-- zombies never spend ComputeAsync on the same frame.
local REPATH_MIN, REPATH_MAX = 0.6, 1.2
-- With line of sight, at a sane height difference, inside this range, we skip
-- pathfinding entirely and walk straight at the target. Most of a firefight
-- happens here, so this is the single biggest saving in the whole system — and
-- it also looks better, because a path smooths a charge into a curve.
local DIRECT_CHASE_RANGE = 130
local MAX_DIRECT_HEIGHT_DELTA = 16
local WAYPOINT_RADIUS = 3.5
-- After this many consecutive failures the target is somewhere the navmesh
-- cannot reach; stop paying for ComputeAsync and just walk at them.
local PATH_FAILURE_LIMIT = 3
local PATH_BACKOFF_TIME = 4

-- ── Movement ────────────────────────────────────────────────────────────────
-- Humanoid:MoveTo is not free and it replicates a state change. Re-issue only
-- when the destination genuinely moved, or often enough to defeat the engine's
-- 8-second MoveTo timeout, which otherwise stops a zombie mid-corridor.
local MOVE_REISSUE_DISTANCE = 1.5
local MOVE_REISSUE_INTERVAL = 3

-- ── Stuck detection ─────────────────────────────────────────────────────────
local STUCK_SPEED = 1.5 -- studs/second below which we are not really moving
local STUCK_TIME = 0.9
-- After coming unstuck, insist on a real path for a while. Whatever the body
-- walked into is still there, and going straight at the target again would just
-- wedge it against the same crate.
local STUCK_PATH_WINDOW = 4

-- ── Wandering ───────────────────────────────────────────────────────────────
-- Idle Commons alternate between standing and shuffling a short distance. They
-- always shamble at walkSpeed even if this one is a sprinter: sprinting is what
-- the crowd does once it has seen you, and that contrast is the alarm.
local WANDER_RADIUS = 34
local WANDER_MIN, WANDER_MAX = 2.5, 6.0
local IDLE_MIN, IDLE_MAX = 1.5, 4.5
local IDLE_VOCAL_CHANCE = 0.35

-- ── Attacking ───────────────────────────────────────────────────────────────
-- The windup is a telegraph, so the body must visibly commit to it: it slows
-- almost to a stop and rears its arms back for `definition.attack.windup`.
local ATTACK_WINDUP_SPEED = 0.25
-- A little grace on the range check when the swing lands. Zero grace means a
-- single back-step always beats a swing that had already committed; too much
-- means the telegraph is a lie. This makes dodging a timing read, not a race.
local ATTACK_WHIFF_TOLERANCE = 1.15
local SWING_POSE_ANGLE = math.rad(-115)
local SWING_POSE_PARTS = { "RightUpperArm", "LeftUpperArm", "Right Arm", "Left Arm" }

local EPSILON = 1e-4

-- One shared Random for every brain in the game: 46 Random objects to jitter a
-- timer is 46 objects too many, and nothing here needs an independent stream.
local random = Random.new()

local function horizontalDistance(a: Vector3, b: Vector3): number
	local dx, dz = a.X - b.X, a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
end

--[[
	Constructs a brain for an already-built, already-parented rig.

	The caller (InfectedService) owns the update tick. Nothing in here connects
	to RunService, on purpose and permanently.
]]
function InfectedBrain.new(model: Model, definition: any)
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local root = RigUtil.getRoot(model)
	assert(humanoid, "InfectedBrain.new: model has no Humanoid")
	assert(root, "InfectedBrain.new: model has no root part")

	local trove = Trove.new()
	local now = os.clock()

	local self = setmetatable({
		model = model,
		definition = definition,
		--[[ Per BODY, not per archetype. A Common's claw is scaled by the tier of
		     the model it happens to be wearing — see InfectedConfig.CommonTiers —
		     so a riot body hits harder than the shambler beside it despite the
		     two sharing every other number. InfectedService writes it after
		     construction; this is the archetype's value until it does. ]]
		attackDamage = definition.attack.damage,
		humanoid = humanoid,
		root = root,
		trove = trove,

		state = State.Idle,
		-- Scratch space owned entirely by this kind's special module.
		data = {},

		destroyed = false,
		paused = false,

		target = nil :: Model?,
		targetPlayer = nil :: Player?,
		-- Last moment the target was genuinely perceived. loseInterestTime is
		-- measured from here, so a survivor who breaks line of sight is chased
		-- for a while rather than instantly forgotten.
		lastAwareAt = 0,

		--[[ sprintChance is rolled ONCE, here. The mix of shamblers and sprinters
		     inside one crowd is what makes a horde read as a crowd rather than a
		     formation, and a zombie that changes its mind mid-street breaks it.

		     FAST ZOMBIES replaces the odds rather than nudging them: at 1.0 there
		     is no mix left, which is the modifier saying so out loud. ]]
		sprints = random:NextNumber() < ModifierConfig.sprintChance(Workspace, definition.sprintChance or 0),

		-- Timers, all jittered so a batch of zombies spawned on one frame never
		-- does the same expensive thing on the same later frame.
		retargetAt = now + random:NextNumber(0, RETARGET_MAX),
		repathAt = now + random:NextNumber(0, REPATH_MAX),
		wanderUntil = now + random:NextNumber(IDLE_MIN, IDLE_MAX),

		--[[ Built lazily below. nil means this rig shipped no usable animation
		     ids, which is survivable — it just slides instead of walking. ]]
		animator = nil,

		path = nil,
		waypoints = nil :: { PathWaypoint }?,
		waypointIndex = 1,
		pathPending = false,
		pathFailures = 0,
		pathBlockedUntil = 0,

		moveIssued = nil :: Vector3?,
		moveIssuedAt = 0,

		lastPosition = root.Position,
		stuckFor = 0,
		forcePathUntil = 0,

		attackReadyAt = now,
		swinging = false,
		windupEnds = 0,
		posed = false,
		armMotors = nil,
		--[[ The wood this body is currently swinging at, if the thing in its way
		     is wood rather than a person. Set for exactly the length of one
		     windup: it is what tells the landing which of the two swings this
		     was, and _cancelSwing drops it along with everything else. ]]
		barricade = nil :: BasePart?,
		--[[ And WHERE it was aiming when it committed — the survivor's position at
		     the moment the probe found the wood.

		     Kept because the landing re-probes, and a re-probe down a different
		     line than the one that chose the target is a swing that can miss what
		     it is standing against. Facing the part's own Position instead looks
		     obvious and is wrong for a big one: the centre of a thirty-stud wall
		     is off to the side, a body turning to face it aims along a diagonal,
		     and the wall's surface down that diagonal can be further away than its
		     reach. The probe then finds nothing, no damage is paid, and the next
		     tick starts the identical swing — a body beating on a wall forever
		     without ever marking it. ]]
		barricadeAim = nil :: Vector3?,
		--[[ The turret this body has broken off to attack, if any. Held ACROSS
		     ticks rather than for one windup like `barricade`, because attacking
		     an emplacement is a whole errand — walk to it, then swing at it —
		     rather than something that happens to be in the way of the errand it
		     was already on. See _stepEmplacement. ]]
		emplacement = nil :: Model?,
		emplacementRoot = nil :: BasePart?,
		emplacementLookAt = 0,

		staggerUntil = 0,
		lurePosition = nil :: Vector3?,
		lureUntil = 0,

		speed = -1,
		autoRotate = true,
	}, InfectedBrain)

	--[[
		FAST ZOMBIES, applied at the ONE place every speed this brain sets passes
		through — see _setSpeed.

		InfectedService scales the Humanoid's WalkSpeed at spawn, and that write
		would be gone within a frame: the brain re-asserts a speed off the
		definition every time it changes state, so a modifier applied only at
		spawn is a modifier that lasts until the body first sees somebody. It has
		to live on the brain because the brain is what keeps writing.

		Commons only. The specials drive their own bodies through their own
		modules and a Charger at 53 studs a second is not a horde modifier.
	]]
	self.speedScale = if definition.id == Enums.Infected.Common
		then ModifierConfig.commonSpeedScale(Workspace)
		else 1

	--[[ CRYO BLAST's hold on this body: a multiplier and the clock it expires on.
	     Separate from speedScale rather than folded into it, because they are
	     different lifetimes — the modifier's scale is fixed for the whole round
	     and this one is a few seconds — and multiplying them keeps a chilled
	     Common under FAST ZOMBIES correctly both. ]]
	self.chillScale = 1
	self.chillUntil = 0

	self.chaseSpeed = if self.sprints then definition.runSpeed else definition.walkSpeed

	-- One Path instance per brain, reused for every ComputeAsync. Creating one
	-- per re-path would allocate an Instance a second per zombie.
	local path = PathfindingService:CreatePath({
		AgentRadius = 2.2 * (definition.scale or 1),
		AgentHeight = 5.4 * (definition.scale or 1),
		AgentCanJump = true,
	})
	self.path = trove:add(path)

	humanoid.AutoRotate = true
	self:_setSpeed(definition.walkSpeed)

	--[[ Loaded once, here, rather than the first time the body moves.
	     Animator:LoadAnimation yields on an id the server has not seen before,
	     and paying that cost lazily means a frame spike per new zombie during
	     exactly the moment a horde is arriving. ]]
	self.animator = InfectedAnimator.new(model, definition.id)

	return self
end

-- ════════════════════════════════════════════════════════════════════════════
--  Public surface
-- ════════════════════════════════════════════════════════════════════════════

function InfectedBrain:getTarget(): Model?
	return self.target
end

--[[
	Forces a victim. Passing nil clears it and drops the brain back to idle.

	A forced target survives at least `definition.loseInterestTime`, even one the
	brain cannot see or hear — after that the brain re-decides for itself. A
	special that needs a victim held indefinitely should pause() and drive.
]]
function InfectedBrain:setTarget(target: Model?)
	if self.target == target then
		return
	end

	self:_cancelSwing()
	self.target = target
	self.targetPlayer = if target then Players:GetPlayerFromCharacter(target) else nil
	self.waypoints = nil
	self.moveIssued = nil
	-- Give the new victim a fair chance to be pathed to right away rather than
	-- waiting out a re-path window that belonged to the previous one.
	self.repathAt = 0
	self.pathFailures = 0

	if target then
		self.lastAwareAt = os.clock()
		self:_setState(State.Chase)
		self:_setSpeed(self.chaseSpeed)
	else
		self:_setState(State.Idle)
		self:_setSpeed(self.definition.walkSpeed)
	end

	-- Written on change only. This attribute replicates to every client, so
	-- writing it per frame during a horde would be a genuine bandwidth cost.
	local model = self.model
	if model.Parent then
		model:SetAttribute(
			Attributes.Infected.Target,
			if self.targetPlayer then tostring(self.targetPlayer.UserId) else ""
		)
	end
end

--[[ Stands the common AI down so a special module can drive the body. ]]
function InfectedBrain:pause()
	if self.paused then
		return
	end
	self.paused = true
	self:_cancelSwing()
	self.waypoints = nil
	self.moveIssued = nil
	self:_setState(State.Controlled)
end

function InfectedBrain:resume()
	if not self.paused then
		return
	end
	self.paused = false
	self.stuckFor = 0
	self.forcePathUntil = 0
	self.repathAt = 0
	self.retargetAt = 0
	self:_setAutoRotate(true)
	self:_setState(if self.target then State.Chase else State.Idle)
end

function InfectedBrain:isPaused(): boolean
	return self.paused
end

--[[ Direct movement for a special module. Clears the cached path so the common
     AI does not fight it on the next tick, and is safe to call every frame. ]]
function InfectedBrain:moveTo(position: Vector3)
	self.waypoints = nil
	self:_moveTo(position, os.clock())
end

function InfectedBrain:stop()
	self.waypoints = nil
	self.moveIssued = nil
	if self.root then
		self.humanoid:MoveTo(self.root.Position)
	end
end

--[[
	Yaws toward a point at the definition's turnSpeed. This is the field that
	makes a Charger dodgeable (90 deg/s) and a Common not (540 deg/s), so it is
	applied honestly rather than snapping.
]]
function InfectedBrain:faceTowards(position: Vector3, dt: number)
	local root = self.root
	if not root or not root.Parent then
		return
	end

	local delta = position - root.Position
	local flat = Vector3.new(delta.X, 0, delta.Z)
	if flat.Magnitude < EPSILON then
		return
	end

	-- The Humanoid would fight a manual rotation, so manual facing owns it while
	-- it lasts. resume() and the end of a swing hand it back.
	self:_setAutoRotate(false)

	local current = root.CFrame
	local desired = CFrame.lookAt(current.Position, current.Position + flat.Unit)
	local maxStep = math.rad(self.definition.turnSpeed or 360) * math.max(dt, 0)
	if maxStep <= 0 then
		return
	end

	local angle = select(2, (current:ToObjectSpace(desired)):ToAxisAngle())
	if angle <= maxStep then
		root.CFrame = desired
	else
		root.CFrame = current:Lerp(desired, maxStep / angle)
	end
end

--[[
	Interrupts everything for `duration`. Called by InfectedService:stagger,
	which the shove path and the specials both go through; the caller has
	already scaled the duration by stumbleResistance.
]]
--[[
	Slows this body for a while. `scale` is a multiplier on every speed it sets,
	`duration` is how long in seconds.

	Deliberately not a stagger. A stagger interrupts what the body is DOING —
	it is the answer to a shove and it stops an attack mid-swing — and a chilled
	infected is still coming, still swinging, just slowly. That difference is the
	whole of CRYO BLAST: an enemy frozen solid stops being frightening and starts
	being scenery.

	The strongest chill wins rather than the newest, so a second blast landing on
	a body already deep in the first cannot thaw it. The clock, though, always
	extends: standing in two overlapping fields should last longer than one.
]]
function InfectedBrain:chill(scale: number, duration: number)
	if typeof(scale) ~= "number" or scale ~= scale or typeof(duration) ~= "number" then
		return
	end
	local now = os.clock()
	local clamped = math.clamp(scale, 0.05, 1)
	if now >= self.chillUntil or clamped < self.chillScale then
		self.chillScale = clamped
	end
	self.chillUntil = math.max(self.chillUntil, now + math.max(duration, 0))
	--[[ Re-asserted now rather than on the next state change. A body already
	     walking would otherwise keep its old speed until it happened to want a
	     new one, which for a Common chasing somebody can be several seconds. ]]
	self:_setSpeed(self.speed / math.max(self.speedScale * self.chillScale, 1e-3) * self.chillScale)
end

function InfectedBrain:stagger(duration: number)
	if duration <= 0 then
		return
	end
	local now = os.clock()
	self.staggerUntil = math.max(self.staggerUntil, now + duration)
	self:_cancelSwing()
	-- A shove invalidates the path: the body is somewhere else now.
	self.waypoints = nil
	self.moveIssued = nil
	self:_setState(State.Stagger)
	self:_setSpeed(0)
	self:_setAutoRotate(true)
	if self.root then
		self.humanoid:MoveTo(self.root.Position)
	end
	-- No free swing on the frame the stumble ends. Recovering from a shove and
	-- immediately connecting is the thing that makes shove feel like it did not
	-- work, which would break the game's only panic button.
	self.attackReadyAt = math.max(self.attackReadyAt, self.staggerUntil)
end

function InfectedBrain:isStaggered(): boolean
	return os.clock() < self.staggerUntil
end

--[[
	Sends this one to a point and makes it ignore survivors until it arrives or
	the timer runs out. A pipe bomb and a bile splash on geometry are both this.
]]
function InfectedBrain:lureTo(position: Vector3, duration: number)
	self.lurePosition = position
	self.lureUntil = os.clock() + math.max(duration, 0)
	self:setTarget(nil)
	self.waypoints = nil
	self.repathAt = 0
	self:_setState(State.Wander)
	self:_setSpeed(self.chaseSpeed)
end

--[[ Distance with height penalised the same way target selection penalises it,
     so a special asking "how far" gets the answer the brain is acting on. ]]
function InfectedBrain:distanceTo(model: Model): number
	local root = self.root
	local other = model and RigUtil.getRoot(model)
	if not root or not other then
		return math.huge
	end
	local delta = other.Position - root.Position
	return delta.Magnitude + math.abs(delta.Y) * (VERTICAL_PENALTY - 1)
end

--[[
	Plays the body's death clip and reports how long it runs, or 0 for none.

	Called from InfectedService:_retire BEFORE destroy(), which is the only
	window it fits in: the animator goes down with the brain, and death is the
	thing that takes the brain down. GoreService holds the ragdoll for the
	returned time so the collapse is animated rather than replaced.
]]
function InfectedBrain:playDeath(): number
	local animator = self.animator
	if not animator or typeof(animator.playDeath) ~= "function" then
		return 0
	end
	local ok, seconds = pcall(animator.playDeath, animator)
	return if ok and typeof(seconds) == "number" then seconds else 0
end

function InfectedBrain:destroy()
	if self.destroyed then
		return
	end
	self.destroyed = true

	if self.animator then
		self.animator:destroy()
		self.animator = nil
	end

	-- Put the arms back before anything else touches the rig: GoreService is
	-- about to swap every Motor6D for a constraint, and a corpse frozen in a
	-- windup pose ragdolls with its arms in the wrong place.
	self:_setSwingPose(false)

	if self.humanoid and self.humanoid.Parent and self.root and self.root.Parent then
		self.humanoid:MoveTo(self.root.Position)
	end

	self.trove:destroy()
	self.target = nil
	self.targetPlayer = nil
	self.waypoints = nil
	self.armMotors = nil
	self.path = nil
end

-- ════════════════════════════════════════════════════════════════════════════
--  The tick
-- ════════════════════════════════════════════════════════════════════════════

--[[
	One brain step. `dt` is the real time since this brain last ran, which is NOT
	the frame time — InfectedService staggers common updates by distance, so dt
	can be anything from one frame to three quarters of a second.

	`snapshot` is InfectedService's shared survivor list. It is passed in rather
	than fetched so that 46 brains share one build of it per frame; the Registry
	fallback exists only for a brain being driven outside the service's loop.
]]
function InfectedBrain:update(dt: number, snapshot: any)
	if self.destroyed then
		return
	end

	local model = self.model
	if not model.Parent then
		return
	end

	local root = self.root
	if not root or not root.Parent then
		return
	end

	--[[ A chill wearing off. Here rather than on a timer of its own: this runs
	     every tick anyway, and a body that thaws needs its speed re-asserted at
	     the moment it thaws rather than whenever it next changes state. ]]
	if self.chillScale < 1 and os.clock() >= self.chillUntil then
		self.chillScale = 1
		self:_setSpeed(self.baseSpeed)
	end

	--[[
		THE ANIMATOR TICKS EVEN WHILE THE BRAIN IS PAUSED, and that ordering is the
		whole point of it sitting here rather than below the pause guard.

		A pause stands the AI down so something else can drive the body — a
		special's scripted phase, a Versus player, a support hook. The body is
		still moving; it is just not this brain deciding where. But the gait was
		chosen below the guard, so a paused body kept whatever it was last playing
		— or, if it was paused before its first tick, nothing at all, and stood in
		its rest pose while being flown around the map.

		Safe above the guard because InfectedAnimator.update reads the HUMANOID and
		nothing else: Health, GetState, and MoveDirection * WalkSpeed. It has no
		opinion about the AI state and never asks for one. It does need the guards
		above it, though — destroy() nils this field, and a body whose model or
		root has gone is not one to ask about its own speed.

		One vector compare per body per tick, on the loop that is already running.
	]]
	if self.animator then
		-- Scaled with the body, or a sprinting Common under FAST ZOMBIES skates.
		self.animator:update(self.definition.runSpeed * self.speedScale)
	end

	if self.paused then
		return
	end

	local now = os.clock()

	-- Staggered bodies do nothing at all. That is the point of a stagger.
	if now < self.staggerUntil then
		return
	elseif self.state == State.Stagger then
		self:_setState(if self.target then State.Chase else State.Idle)
		self:_setSpeed(if self.target then self.chaseSpeed else self.definition.walkSpeed)
	end

	if not snapshot then
		local service = Registry.find("InfectedService")
		snapshot = service and service:getSurvivorSnapshot()
	end

	self:_trackStuck(dt, now)

	-- A lure outranks survivors entirely: that is what makes a pipe bomb work.
	if self.lurePosition then
		if
			now >= self.lureUntil
			or horizontalDistance(root.Position, self.lurePosition) < WAYPOINT_RADIUS * 2
		then
			self.lurePosition = nil
			self.wanderUntil = 0
		else
			self:_travelTo(self.lurePosition, now)
			return
		end
	end

	if snapshot and now >= self.retargetAt then
		self.retargetAt = now + random:NextNumber(RETARGET_MIN, RETARGET_MAX)
		self:_selectTarget(snapshot, now)
	end

	local target = self.target
	if target then
		local targetRoot = RigUtil.getRoot(target)
		if not targetRoot or not target.Parent or not RigUtil.isAlive(target) then
			self:setTarget(nil)
		else
			--[[ A turret nearer than this survivor outranks them. Ahead of the
			     chase rather than inside it, so a body that has broken off never
			     also swings at the person it broke off from. ]]
			if self:_stepEmplacement(now, dt, (targetRoot.Position - root.Position).Magnitude) then
				return
			end
			self:_chase(target, targetRoot, now, dt)
			return
		end
	end

	--[[ And with nobody to chase, any turret in range will do — which is what
	     makes a turret left behind in an empty corridor still get taken apart. ]]
	if self:_stepEmplacement(now, dt, math.huge) then
		return
	end

	self:_wander(now)
end

-- ════════════════════════════════════════════════════════════════════════════
--  Target selection
-- ════════════════════════════════════════════════════════════════════════════

--[[
	Picks a victim from the shared snapshot.

	Scoring is an effective distance that every preference divides into, so the
	whole rule set reads as "this one LOOKS closer": a downed survivor looks half
	as far, a survivor who just fired looks closer still, a survivor overhead
	looks further, and the one we are already chasing gets a 28% discount that
	stops the horde oscillating between two players standing together.
]]
function InfectedBrain:_selectTarget(snapshot: any, now: number)
	local root = self.root
	local origin = root.Position
	local definition = self.definition

	local best: Model? = nil
	local bestScore = math.huge

	for index = 1, snapshot.count do
		local entry = snapshot.entries[index]
		if not entry or not entry.character or not entry.character.Parent then
			continue
		end

		local delta = entry.position - origin
		local distance = delta.Magnitude
		local heard = entry.noiseAt > 0
			and now - entry.noiseAt <= NOISE_MEMORY
			and distance <= definition.hearingRange

		if not self:_isAwareOf(entry, delta, distance, heard) then
			continue
		end

		local score = distance + math.abs(delta.Y) * (VERTICAL_PENALTY - 1)
		if entry.incapacitated then
			score *= INCAP_ATTRACTION
		end
		if heard then
			-- The weight is the noise's own: a gunshot pulls a little, a Boomer's
			-- bile pulls hard enough to override anything else in the room.
			score /= (1 + entry.noiseWeight)
		end
		if entry.character == self.target then
			score *= TARGET_STICKINESS
		end

		if score < bestScore then
			bestScore = score
			best = entry.character
		end
	end

	if best then
		self.lastAwareAt = now
		if best ~= self.target then
			self:setTarget(best)
			self:_alert()
		end
		return
	end

	-- Nothing perceivable. Keep chasing the last known victim until interest
	-- runs out, so breaking line of sight buys a few seconds and not safety.
	if self.target and now - self.lastAwareAt > definition.loseInterestTime then
		self:setTarget(nil)
	end
end

--[[ Sight (a cone plus a real line-of-sight ray), hearing (gunfire and bile),
     or simple contact range where facing stops mattering. ]]
function InfectedBrain:_isAwareOf(entry: any, delta: Vector3, distance: number, heard: boolean): boolean
	if heard or distance <= CONTACT_RADIUS then
		return true
	end
	if distance > self.definition.sightRange or distance < EPSILON then
		return false
	end

	-- Facing check before the raycast: a dot product costs nothing and rejects
	-- most of the population before anything touches the physics scene.
	local look = self.root.CFrame.LookVector
	if look:Dot(delta.Unit) < SIGHT_COS then
		return false
	end

	-- Both bodies are excluded so the ray is asking about the wall between them
	-- and not about the target's own chest.
	return RaycastUtil.hasLineOfSight(self.root.Position, entry.position, { self.model, entry.character })
end

--[[ The crowd noise that tells the player they have been seen. Specials own
     their own vocalisations — those are the game's early-warning system and
     belong to the module that knows what the creature is doing. ]]
function InfectedBrain:_alert()
	if self.definition.isSpecial then
		return
	end
	local audio = Registry.find("AudioService")
	if audio then
		audio:play("Infected", "CommonAlert", self.root)
	end
end

-- ════════════════════════════════════════════════════════════════════════════
--  Chasing and attacking
-- ════════════════════════════════════════════════════════════════════════════

function InfectedBrain:_chase(target: Model, targetRoot: BasePart, now: number, dt: number)
	local attack = self.definition.attack
	local distance = (targetRoot.Position - self.root.Position).Magnitude

	-- Mid-windup: hold position, keep facing, and land or whiff when it expires.
	if self.swinging then
		--[[ A swing already committed to wood finishes against the wood. Falling
		     through to the survivor here would land a claw on somebody standing
		     safely behind a door this body has not got through yet. ]]
		local wood = self.barricade
		if wood then
			--[[ Along the line the probe used, not at the part's centre. See
			     barricadeAim. It is also the better-looking of the two: a body
			     swinging at what is between it and you, rather than turning to
			     address the middle of a wall. ]]
			self:faceTowards(self.barricadeAim or wood.Position, dt)
			if now >= self.windupEnds then
				self:_landBarricadeSwing(wood, now)
			end
			return
		end
		self:faceTowards(targetRoot.Position, dt)
		if now >= self.windupEnds then
			self:_landSwing(target, targetRoot, now, distance)
		end
		return
	end

	--[[
		Wood in the way outranks the survivor behind it, and it is tested BEFORE
		the range check rather than after.

		After would mean a survivor standing on the far side of a door, within
		claw range through it, being hit through the door — which is both the
		obvious exploit and the obvious bug report. Ahead of it, the only thing
		this body can reach is the thing actually between them.
	]]
	if now >= self.attackReadyAt then
		local aim = targetRoot.Position
		local wood = self:_blockingBarricade(aim)
		if wood then
			self.barricade = wood
			self.barricadeAim = aim
			self:_beginSwing(wood, now, dt)
			return
		end
	end

	if distance <= attack.range and now >= self.attackReadyAt then
		self:_beginSwing(targetRoot, now, dt)
		return
	end

	if self.state ~= State.Chase then
		self:_setState(State.Chase)
	end
	self:_setSpeed(self.chaseSpeed)
	self:_travelTo(targetRoot.Position, now)
end

function InfectedBrain:_beginSwing(targetRoot: BasePart, now: number, dt: number)
	self.swinging = true
	self.windupEnds = now + math.max(self.definition.attack.windup, 0)
	self:_setState(State.Attack)
	-- Nearly stopped, arms back. The telegraph has to be legible from across a
	-- room or the windup is just latency.
	self:_setSpeed(self.chaseSpeed * ATTACK_WINDUP_SPEED)
	self:_setSwingPose(true)
	-- If the rig shipped an attack animation, play it over the windup so the
	-- telegraph InfectedConfig asks for is something the player can actually see
	-- rather than a body standing still for a fifth of a second.
	if self.animator then
		self.animator:playOnce(
			"attack",
			self.definition.attack.windup + self.definition.attack.cooldown * 0.5
		)
	end
	self:faceTowards(targetRoot.Position, dt)
	self.waypoints = nil
	self.moveIssued = nil
	self.humanoid:MoveTo(self.root.Position)

	if not self.definition.isSpecial then
		local audio = Registry.find("AudioService")
		if audio then
			audio:play("Infected", "CommonAttack", self.root)
		end
	end
end

function InfectedBrain:_landSwing(target: Model, targetRoot: BasePart, now: number, distance: number)
	self.swinging = false
	self.barricade = nil
	self.barricadeAim = nil
	self.emplacement = nil
	self.emplacementRoot = nil
	self:_setSwingPose(false)
	self:_setAutoRotate(true)
	self.attackReadyAt = now + self.definition.attack.cooldown
	self:_setState(State.Chase)
	self:_setSpeed(self.chaseSpeed)

	-- Re-checked at the moment of impact, not at the moment of commitment. This
	-- is what makes the windup a real telegraph: back out of the arc in time and
	-- the swing genuinely misses.
	if distance > self.definition.attack.range * ATTACK_WHIFF_TOLERANCE then
		return
	end
	if not target.Parent or not RigUtil.isAlive(target) then
		return
	end

	local origin = self.root.Position
	local delta = targetRoot.Position - origin
	local direction = if delta.Magnitude > EPSILON then delta.Unit else self.root.CFrame.LookVector

	-- All damage in the game goes through the funnel, including claws. The
	-- server owns the number; nothing here pre-multiplies anything.
	Registry.get("DamageService"):applyDamage(
		target,
		self.attackDamage,
		Types.newDamageContext({
			attackerModel = self.model,
			damageType = Enums.DamageType.Special,
			region = Enums.HitRegion.Torso,
			hitPosition = targetRoot.Position,
			hitNormal = -direction,
			direction = direction,
			distance = distance,
		})
	)
end

--[[
	Breaking off to attack a turret, and everything that has to be true first.

	── WHY IT IS A DIVERSION AND NOT A TARGET ──────────────────────────────────
	A turret is not a victim. _selectTarget scores survivors, everything
	downstream of a target calls RigUtil.getRoot and RigUtil.isAlive on it, and
	the kill feed, the gore and the Director all assume the thing being chased is
	a person. Making a Model with no Humanoid into a `target` would have meant a
	guard in every one of those places.

	So it sits beside target selection instead, in exactly the seat the pipe bomb
	lure already occupies: something more interesting than the survivor, for as
	long as it is there. The lure outranks it, because a pipe bomb has to work.

	── THE THREE THINGS THAT BOUND IT ──────────────────────────────────────────
	1. RANGE. A turret has to be inside AggroRadius. Nothing walks across the map
	   for one.
	2. CLOSER THAN THE PERSON. `bar` is how far away the survivor this body is
	   already chasing is; a turret further than that is ignored. Without this a
	   body with a survivor in claw range would turn round and walk to a turret
	   twenty studs behind it, which is not a horde defending itself — it is a
	   horde that has stopped working.
	3. THE CAP. Turret.nearest refuses a turret that already has MaxAttackers
	   bodies on it — enforced there rather than here on purpose, because the cap
	   is a fact about the turret and every body would otherwise have to count its
	   neighbours for itself. See its header for why the test is proximity rather
	   than a registry of claims.

	Returns true when it has taken the frame, exactly like the lure branch: the
	caller must not then also chase.
]]
function InfectedBrain:_stepEmplacement(now: number, dt: number, bar: number): boolean
	--[[ A swing already committed to a turret finishes against the turret, for
	     the same reason one committed to a barricade does — falling through would
	     land a claw on whoever is standing behind it. ]]
	if self.swinging then
		--[[ A swing already committed to a PERSON finishes against the person.
		     Without this the look below could start a turret swing on top of one
		     already in its windup — a body that reared back at a survivor and then
		     turned and hit a box instead, sparing the hit the telegraph promised.
		     The whole reason the telegraph is worth having is that it is kept. ]]
		local model = self.emplacement
		if not model then
			return false
		end
		local part = self.emplacementRoot
		if not part or not model.Parent then
			self:_cancelSwing()
			return false
		end
		self:faceTowards(part.Position, dt)
		if now >= self.windupEnds then
			self:_landEmplacementSwing(model, part, now)
		end
		return true
	end

	if now >= self.emplacementLookAt then
		self.emplacementLookAt = now + TURRET_LOOK_INTERVAL
		self.emplacement = nil
		self.emplacementRoot = nil

		local service = Registry.find("AbilityService")
		if service and typeof(service.nearestTurret) == "function" then
			local ok, model, part, distance =
				pcall(service.nearestTurret, service, self.root.Position, TURRET_AGGRO, self.model)
			--[[ The compare against `bar` happens HERE rather than every frame,
			     so a body that committed on this look keeps walking for a quarter
			     of a second instead of flickering between the two the moment the
			     survivor it was chasing steps a stud closer. ]]
			if ok and model and part and distance < bar then
				self.emplacement = model
				self.emplacementRoot = part
			end
		end
	end

	local model = self.emplacement
	local part = self.emplacementRoot
	if not model or not part or not model.Parent then
		self.emplacement = nil
		self.emplacementRoot = nil
		return false
	end

	--[[ The same reach the barricade path uses. A turret is a waist-high box and
	     claw range alone leaves a body standing just outside it, shuffling. ]]
	local reach =
		math.min(self.definition.attack.range + BarricadeConfig.ReachBonus, BarricadeConfig.ProbeRange)
	if (part.Position - self.root.Position).Magnitude <= reach and now >= self.attackReadyAt then
		self:_beginSwing(part, now, dt)
		return true
	end

	self:_travelTo(part.Position, now)
	return true
end

--[[
	A landed swing against a turret.

	Re-checked at impact rather than trusted from the windup, for the reason every
	other landing here is: the windup is a real telegraph and the world may change
	during it. Somebody else's swing can finish the turret, and paying damage into
	one that is already gone would let a crowd keep hitting a hole in the air.

	AbilityService answers rather than the ability module, so the AI never depends
	on whether Abilities/Turret.lua is installed — a build with the ability removed
	simply never finds a turret to swing at in the first place.
]]
function InfectedBrain:_landEmplacementSwing(model: Model, part: BasePart, now: number)
	self.swinging = false
	self.emplacement = nil
	self.emplacementRoot = nil
	self:_setSwingPose(false)
	self:_setAutoRotate(true)
	self.attackReadyAt = now + self.definition.attack.cooldown
	self:_setState(State.Chase)
	self:_setSpeed(self.chaseSpeed)

	if not model.Parent then
		return
	end
	local reach =
		math.min(self.definition.attack.range + BarricadeConfig.ReachBonus, BarricadeConfig.ProbeRange)
	--[[ Shoved, staggered or charged away during the windup. Barricades re-probe
	     down the committed line for this; a turret is a compact object rather than
	     a wall, so its distance is the honest test and there is no diagonal to get
	     wrong. ]]
	if (part.Position - self.root.Position).Magnitude > reach then
		return
	end

	local service = Registry.find("AbilityService")
	if not service or typeof(service.damageTurret) ~= "function" then
		return
	end
	--[[ Scaled from what this body does to a person, so the roster's hierarchy
	     carries across without a second damage table: a Tank ends a turret and a
	     Common needs help. See AbilityConfig's AttackDamageScale for the sums. ]]
	service:damageTurret(model, self.attackDamage * TURRET_DAMAGE_SCALE)
end

--[[
	The breakable thing between this body and whoever it is chasing.

	BarricadeService owns the raycast and the include-list; this only decides how
	far to look. Reach rather than sight: a door across the room is not something
	to stop and swing at, and the config's own probe range caps it so a Tank's
	long arms cannot start chewing on carpentry from further away than the
	feature was designed for.

	Nil whenever the service is absent, which is the honest answer during a boot
	that has not reached Level/BarricadeService yet.
]]
function InfectedBrain:_blockingBarricade(targetPosition: Vector3): BasePart?
	local service = Registry.find("BarricadeService")
	if not service then
		return nil
	end
	local reach =
		math.min(self.definition.attack.range + BarricadeConfig.ReachBonus, BarricadeConfig.ProbeRange)
	return service:blocking(self.root.Position, targetPosition, reach)
end

--[[
	A landed swing against wood.

	Re-probed at the moment of impact rather than trusting the part chosen at the
	start of the windup, for exactly the reason the swing at a survivor re-checks
	its distance: the windup is a real telegraph and the world is allowed to
	change during it. Somebody else's swing can finish the door first, and paying
	damage into a barricade that is already down would let a horde keep eating a
	hole that is no longer there.

	Along the body's own LookVector, because it spent the whole windup turning to
	face this thing.
]]
function InfectedBrain:_landBarricadeSwing(part: BasePart, now: number)
	local aim = self.barricadeAim
	self.swinging = false
	self.barricade = nil
	self.barricadeAim = nil
	self:_setSwingPose(false)
	self:_setAutoRotate(true)
	self.attackReadyAt = now + self.definition.attack.cooldown
	self:_setState(State.Chase)
	self:_setSpeed(self.chaseSpeed)

	local service = Registry.find("BarricadeService")
	if not service or not part.Parent then
		return
	end

	local origin = self.root.Position
	local reach =
		math.min(self.definition.attack.range + BarricadeConfig.ReachBonus, BarricadeConfig.ProbeRange)
	--[[ Down the same line the probe used when it chose this, so a swing that was
	     legitimate when it started cannot miss on geometry alone. See
	     barricadeAim; the LookVector is only the fallback for a swing that
	     somehow arrived here without one. ]]
	local towards = aim or (origin + self.root.CFrame.LookVector * reach)
	local still = service:blocking(origin, towards, reach)
	if still ~= part then
		return
	end

	--[[ Scaled from what this body would do to a person, so the roster's own
	     hierarchy carries over without a second damage table to keep in step. ]]
	service:damage(part, self.attackDamage * BarricadeConfig.InfectedDamageScale)
end

--[[ Aborts a windup without paying its damage — used by stagger, pause and
     death, all of which must leave the arms where they started. ]]
function InfectedBrain:_cancelSwing()
	if not self.swinging then
		return
	end
	self.swinging = false
	self.barricade = nil
	self.barricadeAim = nil
	self.emplacement = nil
	self.emplacementRoot = nil
	self:_setSwingPose(false)
	self:_setAutoRotate(true)
end

--[[
	Rears the arms back by rotating the shoulder joints.

	Two property writes at the start of a windup and two at the end — no
	per-frame animation cost, and Motor6D.C0 replicates, so every client sees the
	tell.

	Skipped entirely when the rig has a real attack clip. Both rotate the same
	shoulders — the clip through Transform, this through C0 — and the engine
	composes them, so doing both rears the arms back twice and the swing starts
	from somewhere behind the body. The clip is the better telegraph where one
	exists; this is what stands in when none does.
]]
function InfectedBrain:_setSwingPose(on: boolean)
	if self.posed == on then
		return
	end
	local animator = self.animator
	if animator and typeof(animator.has) == "function" and animator:has("attack") then
		return
	end

	local poses = self.armMotors
	if poses == nil then
		poses = {}
		for _, partName in SWING_POSE_PARTS do
			local motor = RigUtil.findMotorForPart(self.model, partName)
			if motor then
				table.insert(poses, { motor = motor, c0 = motor.C0 })
			end
		end
		self.armMotors = poses
	end

	for _, pose in poses do
		local motor = pose.motor
		if motor.Parent then
			motor.C0 = if on then pose.c0 * CFrame.Angles(SWING_POSE_ANGLE, 0, 0) else pose.c0
		end
	end
	self.posed = on
end

-- ════════════════════════════════════════════════════════════════════════════
--  Movement
-- ════════════════════════════════════════════════════════════════════════════

--[[
	Walks toward a point. Pathfinding is a BUDGET, not a per-frame service:

	  * With line of sight, a survivable height difference and a sane range, no
	    path is computed at all — we walk straight at them. This is both the
	    cheapest and the best-looking option, because a navmesh path smooths a
	    charge down a corridor into a polite curve.
	  * Otherwise a path is requested at most once per re-path window, off the
	    hot path in a task.spawn, because ComputeAsync yields and yielding inside
	    the shared update loop would stall every other zombie in the game.
	  * If there is no path yet, or the path failed, or it ran out of waypoints,
	    we walk straight at them anyway. A Common that stops moving is far worse
	    than one that walks into a wall.
]]
function InfectedBrain:_travelTo(destination: Vector3, now: number)
	local root = self.root

	if now >= self.repathAt then
		self.repathAt = now + random:NextNumber(REPATH_MIN, REPATH_MAX)

		local delta = destination - root.Position
		local canGoDirect = now >= self.forcePathUntil
			and delta.Magnitude <= DIRECT_CHASE_RANGE
			and math.abs(delta.Y) <= MAX_DIRECT_HEIGHT_DELTA
			and RaycastUtil.hasLineOfSight(root.Position, destination, { self.model, self.target })

		if canGoDirect then
			self.waypoints = nil
			self.pathFailures = 0
		elseif now >= self.pathBlockedUntil then
			self:_requestPath(destination)
		end
	end

	local waypoints = self.waypoints
	if waypoints then
		local index = self.waypointIndex
		local waypoint = waypoints[index]
		-- Consume every waypoint already reached; a fast sprinter can clear two
		-- in one tick, and stopping to visit each one produces a stutter-walk.
		while waypoint and horizontalDistance(root.Position, waypoint.Position) < WAYPOINT_RADIUS do
			index += 1
			waypoint = waypoints[index]
		end
		self.waypointIndex = index

		if waypoint then
			if waypoint.Action == Enum.PathWaypointAction.Jump then
				self.humanoid.Jump = true
			end
			self:_moveTo(waypoint.Position, now)
			return
		end
		-- Ran out: the path is stale, fall through and walk at them.
		self.waypoints = nil
	end

	self:_moveTo(destination, now)
end

--[[ ComputeAsync yields, so it never runs on the caller's thread. The result is
     applied only if the brain still exists and still wants that destination. ]]
function InfectedBrain:_requestPath(destination: Vector3)
	if self.pathPending or not self.path then
		return
	end
	self.pathPending = true

	local origin = self.root.Position
	task.spawn(function()
		local path = self.path
		local ok = path ~= nil and pcall(function()
			path:ComputeAsync(origin, destination)
		end)

		self.pathPending = false
		if self.destroyed then
			return
		end

		if ok and path.Status == Enum.PathStatus.Success then
			self.waypoints = path:GetWaypoints()
			-- Waypoint 1 is where we already are.
			self.waypointIndex = 2
			self.pathFailures = 0
		else
			self.waypoints = nil
			self.pathFailures += 1
			if self.pathFailures >= PATH_FAILURE_LIMIT then
				-- Somewhere the navmesh cannot reach. Stop paying for it and
				-- keep walking; the fallback is the whole point of the fallback.
				self.pathFailures = 0
				self.pathBlockedUntil = os.clock() + PATH_BACKOFF_TIME
			end
		end
	end)
end

function InfectedBrain:_moveTo(position: Vector3, now: number)
	local last = self.moveIssued
	if
		last
		and (position - last).Magnitude < MOVE_REISSUE_DISTANCE
		and now - self.moveIssuedAt < MOVE_REISSUE_INTERVAL
	then
		return
	end
	self.moveIssued = position
	self.moveIssuedAt = now
	self.humanoid:MoveTo(position)
end

--[[ A zombie wedged on a crate must never just stand there. When nothing has
     moved for STUCK_TIME we jump, throw the path away and force a re-path. ]]
function InfectedBrain:_trackStuck(dt: number, now: number)
	local position = self.root.Position
	local moved = (position - self.lastPosition).Magnitude
	self.lastPosition = position

	if self.state ~= State.Chase and self.state ~= State.Wander then
		self.stuckFor = 0
		return
	end

	if moved < STUCK_SPEED * math.max(dt, EPSILON) then
		self.stuckFor += dt
		if self.stuckFor >= STUCK_TIME then
			self.stuckFor = 0
			self.humanoid.Jump = true
			self.waypoints = nil
			self.moveIssued = nil
			-- Re-path on the very next tick, and refuse to go direct for a
			-- while: whatever it walked into has not moved.
			self.repathAt = 0
			self.pathBlockedUntil = 0
			self.forcePathUntil = now + STUCK_PATH_WINDOW
		end
	else
		self.stuckFor = 0
	end
end

-- ════════════════════════════════════════════════════════════════════════════
--  Idling
-- ════════════════════════════════════════════════════════════════════════════

--[[
	With nothing to chase, alternate between standing around and shuffling to a
	nearby point. Both at walkSpeed even for a sprinter: an idle crowd that
	shambles and then breaks into a run the instant it notices you is the entire
	silhouette of a Left 4 Dead horde.
]]
function InfectedBrain:_wander(now: number)
	if now < self.wanderUntil then
		return
	end

	self:_setSpeed(self.definition.walkSpeed)
	self:_setAutoRotate(true)

	if self.state == State.Wander then
		self.state = State.Idle
		self.wanderUntil = now + random:NextNumber(IDLE_MIN, IDLE_MAX)
		self.humanoid:MoveTo(self.root.Position)
		self.moveIssued = nil

		if not self.definition.isSpecial and random:NextNumber() < IDLE_VOCAL_CHANCE then
			local audio = Registry.find("AudioService")
			if audio then
				audio:play("Infected", "CommonIdle", self.root)
			end
		end
		return
	end

	self.state = State.Wander
	self.wanderUntil = now + random:NextNumber(WANDER_MIN, WANDER_MAX)

	-- No pathfinding for wandering. Walking into a wall while idle costs the
	-- player nothing and costs the server a ComputeAsync it does not need.
	local angle = random:NextNumber(0, math.pi * 2)
	local radius = random:NextNumber(WANDER_RADIUS * 0.25, WANDER_RADIUS)
	self.waypoints = nil
	self:_moveTo(self.root.Position + Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius), now)
end

-- ════════════════════════════════════════════════════════════════════════════
--  Small setters that exist only to avoid redundant property writes
-- ════════════════════════════════════════════════════════════════════════════

function InfectedBrain:_setState(state: string)
	self.state = state
end

function InfectedBrain:_setSpeed(speed: number)
	local scaled = speed * self.speedScale * self.chillScale
	-- Humanoid.WalkSpeed replicates on every assignment. During a horde that is
	-- 46 property replications a frame for values that did not change.
	if math.abs(self.speed - scaled) < 0.01 then
		return
	end
	self.speed = scaled
	self.humanoid.WalkSpeed = scaled
end

function InfectedBrain:_setAutoRotate(enabled: boolean)
	if self.autoRotate == enabled then
		return
	end
	self.autoRotate = enabled
	self.humanoid.AutoRotate = enabled
end

return InfectedBrain
