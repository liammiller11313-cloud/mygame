--!nonstrict
--[[
	InfectedService — the horde's owner.

	Everything that is alive and trying to eat a survivor was created here, is
	ticked here, and dies here. There are three jobs:

	  1. Build an infected: rig, health, speed, collision group, attributes,
	     brain, and the special module for its kind.
	  2. Tick every brain in the game from ONE shared loop.
	  3. Apply damage, fire, staggers and death, and keep the per-kind counts the
	     Director reads every second.

	── THE UPDATE BUDGET ───────────────────────────────────────────────────────
	This is the constraint the whole file is shaped around. 46 infected are alive
	during SustainPeak (DirectorConfig.Population), and giving each one a
	RunService connection is exactly how a Roblox horde game dies: 46 connections
	firing every frame, each doing its own player scan, each calling MoveTo.

	So there is ONE Heartbeat connection, and it spends a fixed budget:

	  * The survivor snapshot is built ONCE per frame and shared by every brain,
	    instead of 46 brains each asking who is alive. Its membership is rebuilt
	    a few times a second; positions refresh every frame. Entry tables are
	    reused forever, so the loop allocates nothing.

	  * Specials and bosses tick EVERY frame, unconditionally. There are at most
	    DirectorConfig.Specials.MaxAliveTotal + a boss of them, and a Hunter
	    pounce or a Charger charge is a physics event that has to be smooth.

	  * Commons tick on a round-robin with a per-frame cap, at a rate set by how
	    far the nearest survivor is:

	        <= 55 studs    every visit   in your face; must feel frame-accurate
	        <= 140 studs   10 Hz         visible, but you cannot read its feet
	        <= 320 studs   4 Hz          a shape moving in the distance
	        beyond         1.33 Hz       nobody can see it; it just needs to arrive

	    A tick's dt is the real elapsed time since that entity last ran, so a 4 Hz
	    brain moves at the same speed as a 60 Hz one — it just decides less often.
	    The cap means a full 46-strong horde standing on the team is updated over
	    two frames rather than one; 16ms of decision latency on a shambling crowd
	    is invisible, and a blown frame budget is not.

	  * The distance band itself is recomputed only when an entity ticks, so the
	    scheduler's per-frame work is one number comparison per infected.

	── WHAT THIS SERVICE DOES NOT DO ───────────────────────────────────────────
	It never ragdolls, gibs or cleans up a corpse: on death it marks the body,
	retires the brain and hands off. DamageService drives GoreService, which owns
	the corpse from that moment. The one exception is a Debris fallback timed off
	InfectedConfig.corpseLifetime, so a body still disappears if gore is switched
	off in GoreConfig or GoreService fails.
]]

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local AnimationCache = require(Shared.Util.AnimationCache)
local AnimationConfig = require(Shared.Config.AnimationConfig)
local Attributes = require(Shared.Net.Attributes)
local Enums = require(Shared.Enums)
local GameConfig = require(Shared.Config.GameConfig)
local GoreConfig = require(Shared.Config.GoreConfig)
local InfectedConfig = require(Shared.Config.InfectedConfig)
local ModifierConfig = require(Shared.Config.ModifierConfig)
local Registry = require(Shared.Util.Registry)
local RaycastUtil = require(Shared.Util.RaycastUtil)
local RigUtil = require(Shared.Util.RigUtil)
local Signal = require(Shared.Util.Signal)
local Trove = require(Shared.Util.Trove)
local Types = require(Shared.Types)

local InfectedBrain = require(script.Parent.InfectedBrain)

local InfectedService = {}

--[[ How many burning bodies currently carry their own light. See
     BURN_LIGHT_MAX. Declared here rather than in init so it is never nil on the
     first ignition — a `nil < 12` comparison would throw out of a molotov. ]]
InfectedService._burnLights = 0

--[[ (model: Model, kind: string) — fired after the rig is parented and its
     brain and special module are live. ]]

--[[ (model: Model, kind: string, ctx: DamageContext?) — fired once, after the
     body is flagged dead and its brain is gone, before GoreService touches it. ]]
InfectedService.died = Signal.new()

--[[ (position: Vector3, fromSpawn: boolean, spawnedAt: number, window: number)
     — a common was taken off the board because it could not reach anybody. See
     MAROON_TIME.

     `fromSpawn` is true when it never closed ANY ground, which means the place
     it was put was never reachable. The last two are what make that actionable
     and were missing from this line: the Director blames the node nearest where
     the body was PUT rather than where it was reaped, so it needs the spawn
     time, and `window` is how long the body was given before being judged. ]]
InfectedService.marooned = Signal.new()

-- ── Update budget (see the header) ──────────────────────────────────────────
local MAX_COMMON_UPDATES_PER_FRAME = 24
local UPDATE_BANDS = {
	{ distance = 55, interval = 0 },
	{ distance = 140, interval = 0.1 },
	{ distance = 320, interval = 0.25 },
}
local DISTANT_INTERVAL = 0.75

-- Membership changes when someone dies, spawns or leaves — several times a
-- minute, not several times a second. Positions inside it refresh every frame.
local SNAPSHOT_MEMBERSHIP_INTERVAL = 0.25

-- ── Fire ────────────────────────────────────────────────────────────────────
-- Burning is applied in ticks rather than continuously so a burning horde costs
-- a bounded number of damage calls. Each tick charges the real elapsed time, so
-- the DPS is exactly InfectedConfig.burnDamagePerSecond whatever the tick rate.
local BURN_TICK_INTERVAL = 0.25
-- The flame outlives the body for a moment; a corpse whose fire snaps off the
-- instant it dies reads as a bug.
local BURN_CORPSE_LINGER = 3

-- No config owns a flame colour (GoreConfig covers blood, UITheme covers the
-- HUD), so these live here. Sized off the definition's scale, because a burning
-- Tank should be a bonfire and a burning Common a torch.
local FIRE_COLOR = Color3.fromRGB(255, 148, 48)
local FIRE_SECONDARY_COLOR = Color3.fromRGB(180, 42, 16)
local FIRE_SIZE = 5.5
local FIRE_HEAT = 14
local FIRE_LIGHT_RANGE = 16
local FIRE_LIGHT_BRIGHTNESS = 2.2

--[[
	How many burning bodies may carry their own light at once.

	A molotov into a horde ignites everything it touches, and every ignition
	built its own PointLight with no ceiling anywhere — the only guard was
	per-body, against re-igniting the same one. Against a sixty-Common cap that
	is sixty dynamic lights arriving on one frame, replicated to every client,
	which is the single worst thing this game can do to a phone and it happens on
	the most spectacular moment in it.

	Twelve, and the FIRE is never capped: every burning body still visibly burns,
	because the flame is what says "this one is on fire" and it is per-body
	information. The light is atmosphere — a burning body lighting the corridor —
	and twelve of them light a corridor exactly as well as sixty do. What is lost
	past the cap is a body glowing on its own in the dark, which is the least
	load-bearing thing here and the most expensive.
]]
local BURN_LIGHT_MAX = 12

-- ── Misc ────────────────────────────────────────────────────────────────────
-- A stagger's little hop. Deliberately a fraction of a full shove: MeleeService
-- applies GameConfig.Shove.Force itself on top of calling stagger(), and the
-- other callers (a Charger's impact, a Tank's punch) want an interruption that
-- reads as physical rather than a second shove.
local STAGGER_IMPULSE = GameConfig.Shove.Force * 0.3

-- A hair of daylight under a freshly spawned rig, so it settles onto the floor
-- instead of spawning intersecting it and being shoved out by the solver.
local SPAWN_CLEARANCE = 0.15

-- Longer than GoreService's own Debris grace, so this only ever fires when the
-- gore system did not take the body at all.
local CORPSE_FALLBACK_GRACE = 12

-- A brain that throws every tick is a bug in a special module, and warning once
-- per frame per zombie would bury it. After this many it gets despawned.
local MAX_BRAIN_ERRORS = 5

--[[
	── MAROONED BODIES ─────────────────────────────────────────────────────────
	SpawnField lets the Director place a horde anywhere in the map, which is what
	makes "a horde comes out of the building you are about to reach" possible. It
	is deliberately not a navmesh — it knows where a body FITS, not where a body
	can WALK TO — so some of what it offers is a rooftop, a sealed courtyard, or
	the far side of a fence.

	Nothing used to notice. A body that cannot reach anyone walks into a wall
	forever, and it is still a live rig: it holds a brain tick, a pathfinding
	slot, a replicated model, and — worst — a slot against the Director's
	population target. Enough of them and the Director believes it has delivered
	a horde while nothing is arriving, which reads as the game being broken and
	as the server dropping frames, both at once.

	So a body that is far away, out of every survivor's sight, and has not got
	one stud closer to anyone in this long, is taken off the board. The Director
	is under target again on its next tick and spawns a replacement somewhere
	that works. This is what L4D2 does with commons you have left behind, and for
	the same reason.

	The three gates are all necessary:
	  * MAROON_DISTANCE — never reap something that could be on screen. A body
	    pressed against the safe-room door is not making progress either.
	  * line of sight — a player watching a zombie blink out of existence is a
	    worse bug than the one this fixes.
	  * MAROON_PROGRESS measured from where the window OPENED, not from the last
	    sample, so a body shuffling back and forth on a rooftop cannot keep
	    resetting its own clock a stud at a time.
]]
local MAROON_TIME = 25
local MAROON_DISTANCE = 90
local MAROON_PROGRESS = 6
local SIGHT_IGNORE_REFRESH = 1.0

--[[ Specials and bosses are a scripted beat the Director paid for and the round
     is pacing around; a Tank that took a wrong turn is a problem to fix rather
     than a body to silently delete. Commons only. ]]

-- What a gunshot is worth in target selection, and how long it keeps pulling.
-- Boomer bile passes its own, much larger, weight through reportNoise.
local GUNSHOT_NOISE_WEIGHT = 0.45
local GUNSHOT_NOISE_DURATION = 2.0

-- Ammo attributes whose value dropping means "that survivor just fired".
local AMMO_ATTRIBUTES = { Attributes.Loadout.PrimaryAmmo, Attributes.Loadout.SecondaryAmmo }

local EPSILON = 1e-4

local random = Random.new()
local warned: { [string]: boolean } = {}

local function warnOnce(key: string, message: string)
	if warned[key] then
		return
	end
	warned[key] = true
	warn("[InfectedService] " .. message)
end

-- ════════════════════════════════════════════════════════════════════════════
--  Lifecycle
-- ════════════════════════════════════════════════════════════════════════════

function InfectedService:init()
	self._records = {} :: { [Model]: any }
	self._alive = {} :: { any } -- dense array of records; the round-robin walks it
	self._priority = {} :: { any } -- specials and bosses; ticked every frame
	self._paused = false -- see setPaused: the whole horde, stood down
	self._countByKind = {} :: { [string]: number }
	self._cursor = 0

	self._specials = {} :: { [string]: any } -- module cache; false means "missing"
	self._noise = {} :: { [Player]: any }
	self._ammo = {} :: { [Player]: { [string]: number } }
	self._playerTroves = {} :: { [Player]: any }

	-- Reused forever. Rebuilding these tables 60 times a second is exactly the
	-- kind of allocation that turns into a garbage-collection spike mid-horde.
	self._snapshot = { count = 0, entries = {}, builtAt = 0, updatedAt = 0 }

	--[[ What a line-of-sight test is allowed to pass through. Rebuilt on a timer
	     rather than per query for the same reason as the snapshot above. ]]
	self._sightIgnore = {} :: { Instance }
	self._sightIgnoreAt = -math.huge

	self._trove = Trove.new()

	local folder = Workspace:FindFirstChild("Infected")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "Infected"
		folder.Parent = Workspace
	end
	self._folder = folder

	self:_publishCounts()
end

function InfectedService:start()
	--[[
		Fetch every animation the game declares, once, before the first horde.

		An AnimationTrack whose asset has not arrived plays NOTHING — it reports
		itself as playing, its Length is zero, and the body does not move. Forty
		zombies spawn inside the first ten seconds of a round, so without this the
		opening wave animates only for whichever clips happened to be cached
		already. It is the difference between "sometimes my animations do not
		load" and "they load".

		Every id from AnimationConfig, including the survivors' hold pose, because
		this is the one place with a start() early enough to warm them and the
		call costs the same whether it is one id or twenty. It does not yield —
		see AnimationCache.preload.
	]]
	AnimationCache.preload(AnimationConfig.allIds())

	-- THE loop. One connection for the entire horde, forever.
	self._trove:connect(RunService.Heartbeat, function()
		self:_step()
	end)

	for _, player in Players:GetPlayers() do
		self:_watchPlayer(player)
	end
	self._trove:connect(Players.PlayerAdded, function(player)
		self:_watchPlayer(player)
	end)
	self._trove:connect(Players.PlayerRemoving, function(player)
		local trove = self._playerTroves[player]
		if trove then
			trove:destroy()
		end
		self._playerTroves[player] = nil
		self._ammo[player] = nil
		self._noise[player] = nil
	end)
end

-- ════════════════════════════════════════════════════════════════════════════
--  Spawning
-- ════════════════════════════════════════════════════════════════════════════

--[[
	Builds one infected and puts it in the world.

	`position` (or `cframe.Position`) is treated as a point ON THE GROUND: the
	rig is lifted by the height of its own bounding box so its feet land there.
	Spawn placement hands us a floor point, and every caller left to invent this
	lift would invent a different fudge factor for it.

	Returns nil — without erroring — when the kind is unknown, the kind is
	already at its `maxAlive`, or the rig could not be built. The Director calls
	this in a loop and a failed spawn must never take a batch down with it.
]]
--[[ `eliteId` is an InfectedConfig.EliteTiers id, or nil for an ordinary body.
     It is a per-SPAWN modifier rather than a property of the kind — the finale
     asks for a Tank and an "Apex" alongside it — so it arrives here as an
     argument and is written onto the model, which is what every later read
     (the brain's claw, the client's boss bar) goes back to. ]]
function InfectedService:spawn(kind: string, position: Vector3, cframe: CFrame?, eliteId: string?): Model?
	local definition = InfectedConfig.get(kind)
	if not definition then
		warnOnce("kind:" .. tostring(kind), string.format("spawn(%q): no such infected kind", tostring(kind)))
		return nil
	end

	if typeof(position) ~= "Vector3" then
		if typeof(cframe) == "CFrame" then
			position = cframe.Position
		else
			return nil
		end
	end

	--[[ The Director owns the population budget, but the server owns the truth.
	     The ceiling is asked for rather than read, because EXPLODER INVASION
	     raises the Boomer's — and this is the check that would otherwise refuse
	     the third one while the Director cheerfully kept asking. ]]
	if (self._countByKind[kind] or 0) >= ModifierConfig.maxAliveFor(Workspace, kind, definition.maxAlive) then
		return nil
	end

	-- find() rather than get(): a broken asset factory is a loud, named failure
	-- that must not turn every Director spawn tick into a thrown error.
	local factory = Registry.find("PlaceholderFactory")
	if not factory then
		warnOnce("nofactory", "PlaceholderFactory is not registered; nothing can be spawned")
		return nil
	end

	local ok, model = pcall(factory.buildInfectedRig, factory, kind)
	if not ok or typeof(model) ~= "Instance" or not model:IsA("Model") then
		warnOnce(
			"rig:" .. kind,
			string.format("PlaceholderFactory:buildInfectedRig(%q) failed: %s", kind, tostring(model))
		)
		return nil
	end

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local root = RigUtil.getRoot(model)
	if not humanoid or not root then
		warnOnce(
			"rigshape:" .. kind,
			string.format("buildInfectedRig(%q) returned a model with no Humanoid or no root part", kind)
		)
		model:Destroy()
		return nil
	end

	if not model.PrimaryPart then
		model.PrimaryPart = root
	end

	--[[ Written before the rig is scaled and before health is set, because both
	     of those read it. An unknown id is nil and the body is an ordinary one,
	     which is the only safe way for a value that comes out of a config. ]]
	local elite = InfectedConfig.elite(eliteId)
	if elite then
		model:SetAttribute(Attributes.Infected.Elite, elite.id)
	end

	-- Scale first: HipHeight and part sizes below are read after it.
	RigUtil.scaleRig(model, definition.scale * (if elite then elite.scale else 1))

	--[[
		The tier the model itself carries. See InfectedConfig.CommonTiers: the
		horde is one archetype with many models, and the visibly armoured ones
		are actually armoured rather than wearing the art of it. Nil for every
		special and for any Common whose model name has no number on the end,
		which is the safe default — a new model dropped into the folder is a
		regular until somebody numbers it into a band.

		Applied here, before the Humanoid is given its health, so a riot body is
		never briefly a shambler; the matching damage scale rides on the brain,
		which is built further down.
	]]
	local tier = InfectedConfig.tierForVariant(kind, model:GetAttribute("FL_Variant") :: string?)
	local health = definition.health
	if tier then
		health = math.floor(definition.health * tier.health + 0.5)
		model:SetAttribute(Attributes.Infected.Tier, tier.id)
	end
	if elite then
		health = math.floor(health * elite.health + 0.5)
	end
	--[[ ARMORED. Commons only: the modifier is about the horde, and a Tank that
	     had also doubled would be a different modifier nobody asked for. It
	     stacks on top of the tier multiplier rather than replacing it, so a riot
	     body under ARMORED is the hardest thing in the game that is not a boss —
	     and a headshot still kills it in one, because headshotAlwaysKills sits
	     above every multiplier here. ]]
	if kind == Enums.Infected.Common then
		health = math.floor(health * ModifierConfig.commonHealthScale(Workspace) + 0.5)
	end

	humanoid.MaxHealth = health
	humanoid.Health = health
	humanoid.WalkSpeed = definition.walkSpeed
		* (if elite then elite.speed else 1)
		* (if kind == Enums.Infected.Common then ModifierConfig.commonSpeedScale(Workspace) else 1)
	humanoid.UseJumpPower = true
	humanoid.JumpPower = definition.jumpPower
	humanoid.AutoRotate = true
	-- BreakJointsOnDeath would shatter the rig the instant health hits zero,
	-- before GoreService can decide whether this body ragdolls, loses a limb or
	-- comes apart entirely. RequiresNeck would kill it outright the moment a
	-- headshot severs the neck joint, which is a decapitation, not a bug.
	humanoid.BreakJointsOnDeath = false
	humanoid.RequiresNeck = false
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid.HealthDisplayDistance = 0
	humanoid.NameDisplayDistance = 0

	-- Contract: infected never collide with each other. A self-colliding horde
	-- wedges solid in the first doorway and the players never see it arrive.
	RigUtil.setCollisionGroup(model, "Infected")

	local level = Registry.find("LevelService")
	local flow = 0
	if level and typeof(level.getFlowDistance) == "function" then
		local flowOk, value = pcall(level.getFlowDistance, level, position)
		if flowOk and typeof(value) == "number" then
			flow = value
		end
	end

	model:SetAttribute(Attributes.Infected.Kind, kind)
	--[[ `health`, not `definition.health`. These two used to publish the
	     archetype's number while the Humanoid carried the tiered one, so a Riot
	     Infected reported 50/50 with 160 in the tank. Nothing read them at the
	     time, which is exactly how it survived; the boss bar reads them now. ]]
	model:SetAttribute(Attributes.Infected.Health, health)
	model:SetAttribute(Attributes.Infected.MaxHealth, health)
	model:SetAttribute(Attributes.Infected.IsBoss, definition.isBoss)
	model:SetAttribute(Attributes.Infected.IsDead, false)
	model:SetAttribute(Attributes.Infected.Target, "")
	model:SetAttribute(Attributes.Infected.SpawnFlow, flow)
	--[[ The body's gait variation, rolled once here so every client animates this
	     zombie the same way. It cannot be derived on the client: the only
	     per-instance identity a client can see is GetDebugId, which needs plugin
	     capability and throws in a game script. ]]
	model:SetAttribute(Attributes.Infected.Seed, random:NextInteger(1, 2147483647))
	model:SetAttribute(Attributes.Infected.Burning, false)

	-- The caller's point is a FLOOR point, so the rig is lifted by the distance
	-- from its pivot to the bottom of its own bounding box. Measured rather than
	-- assumed, because that distance depends on rig type and on the scale
	-- applied above, and a Tank spawning knee-deep in the ground is the kind of
	-- bug that only shows up on one of seven archetypes.
	local base = cframe or CFrame.new(position)
	local boxCFrame, boxSize = model:GetBoundingBox()
	local lift = (model:GetPivot().Position.Y - (boxCFrame.Position.Y - boxSize.Y * 0.5)) + SPAWN_CLEARANCE
	model:PivotTo(base + Vector3.new(0, lift, 0))
	model.Parent = self._folder

	--[[
		A rig with no joints is a pile of loose parts, and it has to be caught HERE
		rather than at the template.

		PlaceholderFactory audits every template at boot, but a legacy R6 model
		genuinely has no Motor6Ds at that point — Roblox builds them when the body
		is parented into Workspace, which is the line directly above this one. So
		the template audit cannot tell "welded, will never work" apart from "R6,
		not built yet", and it says so.

		This is the first moment the answer is real, and the failure it catches is
		spectacular: the parts are unanchored and unjoined, so the Humanoid holds
		the HumanoidRootPart up at HipHeight while everything else falls or hangs
		where it was placed. A zombie floating in pieces — and worse, one whose
		ROOT is still being driven at the team by a brain that neither knows nor
		cares that the visible body is somewhere else. That is damage arriving
		from a zombie that is not where it looks like it is.

		Welding is not a fix for the model, and it is not meant to be. It is the
		difference between a body that comes apart in mid-air and one that walks
		up to you as a rigid slab: still wrong, still worth fixing in Studio, but
		playable and honest about where the hitbox is.
	]]
	self:_boltTogether(model, kind)

	local record = {
		model = model,
		kind = kind,
		definition = definition,
		humanoid = humanoid,
		root = root,
		trove = Trove.new(),
		index = 0,
		dead = false,
		priority = definition.isSpecial or definition.isBoss,
		errors = 0,

		lastUpdate = os.clock(),
		interval = 0,
		nearest = math.huge,

		--[[ Where this body was PUT. Kept because the reap below reports where a
		     body ended up, and those are different places — a body that never
		     closed ground on the team can still have wandered a long way
		     sideways. Blaming the spawn node nearest the REAPED position is how
		     a report ends up saying "no node within 40 studs" about a body that
		     came out of one. ]]
		spawnedAt = if root then root.Position else Vector3.zero,

		--[[ How far away this body was when its current no-progress window
		     opened, and how long that window has been running. See MAROON_TIME.
		     `progressed` stays false for a body that never closed any ground at
		     all, which is the signature of a spawn point that was never
		     reachable. ]]
		progressFrom = math.huge,
		maroonedFor = 0,
		progressed = false,

		unlisted = false,
		burning = false,
		burnSource = nil :: Player?,
		burnLastAt = 0,
		burnNextAt = 0,
		fire = nil :: Fire?,
		light = nil :: PointLight?,

		deathContext = nil :: any,
		brain = nil :: any,
		special = nil :: any,
	}

	record.brain = InfectedBrain.new(model, definition)

	--[[ The other half of the tier. Health went on the Humanoid in _configure;
	     this is the claw, and it lives on the brain because the brain is what
	     swings it. Read back off the model rather than threaded through, so the
	     two halves cannot disagree about which body this is. ]]
	local tier = InfectedConfig.tierForVariant(kind, model:GetAttribute("FL_Variant") :: string?)
	local elite = InfectedConfig.elite(model:GetAttribute(Attributes.Infected.Elite) :: string?)
	if tier or elite then
		record.brain.attackDamage = definition.attack.damage
			* (if tier then tier.damage else 1)
			* (if elite then elite.damage else 1)
	end

	-- Anything that kills this humanoid without going through damage() — a fall
	-- out of the world, a stray Humanoid:TakeDamage — still has to retire the
	-- brain and free the count. _retire is idempotent, so the two paths are safe
	-- together.
	record.trove:connect(humanoid.Died, function()
		self:_retire(record, record.deathContext)
	end)

	self._records[model] = record
	table.insert(self._alive, record)
	record.index = #self._alive
	if record.priority then
		table.insert(self._priority, record)
	end
	self._countByKind[kind] = (self._countByKind[kind] or 0) + 1
	self:_publishCounts()

	if definition.isSpecial then
		local special = self:_loadSpecial(kind)
		if special then
			record.special = special
			if typeof(special.onSpawn) == "function" then
				local spawnOk, err = pcall(special.onSpawn, model, record.brain)
				if not spawnOk then
					warnOnce("onSpawn:" .. kind, string.format("%s.onSpawn failed: %s", kind, tostring(err)))
				end
			end
		end
	end

	return model
end

--[[ Loads Infected/Specials/<Kind>.lua once and caches it. A missing or broken
     module downgrades that kind to plain common AI rather than failing the
     spawn — the six special modules are large and are worth having partially. ]]
function InfectedService:_loadSpecial(kind: string): any?
	local cached = self._specials[kind]
	if cached ~= nil then
		return cached or nil
	end

	local folder = script.Parent:FindFirstChild("Specials")
	local moduleScript = folder and folder:FindFirstChild(kind)
	if not moduleScript or not moduleScript:IsA("ModuleScript") then
		self._specials[kind] = false
		warnOnce(
			"nospecial:" .. kind,
			string.format("no ModuleScript at Infected/Specials/%s; %s will use common AI", kind, kind)
		)
		return nil
	end

	local ok, result = pcall(require, moduleScript)
	if not ok or typeof(result) ~= "table" then
		self._specials[kind] = false
		warnOnce("special:" .. kind, string.format("Specials/%s failed to load: %s", kind, tostring(result)))
		return nil
	end

	self._specials[kind] = result
	return result
end

--[[ Removes an infected with no death, no gore and no signal. This is the
     Director culling something nobody can see, not something being killed. ]]
function InfectedService:despawn(model: Model)
	local record = self._records[model]
	if not record then
		if typeof(model) == "Instance" then
			model:Destroy()
		end
		return
	end

	record.dead = true
	self:_unlist(record)
	self:_stopBurning(record, 0)
	if record.brain then
		record.brain:destroy()
	end
	record.trove:destroy()
	self._records[model] = nil
	model:Destroy()
	self:_publishCounts()
end

--[[ Clears the board. Round reset only. ]]
function InfectedService:despawnAll(kind: string?)
	for index = #self._alive, 1, -1 do
		local record = self._alive[index]
		if record and (kind == nil or record.kind == kind) then
			self:despawn(record.model)
		end
	end
end

-- ════════════════════════════════════════════════════════════════════════════
--  Damage and death
-- ════════════════════════════════════════════════════════════════════════════

--[[
	Applies damage that DamageService has already fully resolved.

	`amount` arrives post-region, post-falloff, post-resistance and post-headshot
	rule. Nothing is recalculated here; this is the write, not the decision.
]]
function InfectedService:damage(model: Model, amount: number, ctx: any): any
	local record = self._records[model]
	local humanoid = if record then record.humanoid else model:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return Types.blockedResult()
	end
	if not RigUtil.isAlive(model) then
		return Types.blockedResult(math.max(humanoid.Health, 0))
	end
	if typeof(amount) ~= "number" or amount ~= amount or amount <= 0 then
		return Types.blockedResult(math.max(humanoid.Health, 0))
	end

	--[[
		A window this body has opened on itself.

		The definition's damageResistance is a constant and is applied upstream in
		DamageService; this is the temporary half, and it exists so a boss can have
		a RHYTHM rather than a health bar. Metallic's charge leaves it overheating
		and defenceless for a couple of seconds, and the fight is about earning
		that window and then filling it.

		Clamped rather than trusted. It is an attribute, so anything at all can
		write it, and a NaN or a negative here would either heal the body or make
		the next bullet kill it.
	]]
	local vulnerable = tonumber(model:GetAttribute(Attributes.Infected.Vulnerable))
	if vulnerable and vulnerable == vulnerable then
		amount *= math.clamp(vulnerable, 0, 10)
		if amount <= 0 then
			return Types.blockedResult(math.max(humanoid.Health, 0))
		end
	end

	local before = math.max(humanoid.Health, 0)
	local remaining = math.max(before - amount, 0)
	local killed = remaining <= 0

	if killed and record then
		-- FL_IsDead goes up BEFORE the health write, and before anything else at
		-- all. RigUtil.isAlive gates on it, so this is what stops the other nine
		-- pellets of the same shotgun blast — which resolve on this same frame —
		-- from killing the body nine more times and spending nine gore budgets.
		model:SetAttribute(Attributes.Infected.IsDead, true)
		record.deathContext = ctx
	end

	humanoid.Health = remaining
	model:SetAttribute(Attributes.Infected.Health, remaining)

	if killed then
		if record then
			self:_retire(record, ctx)
		else
			model:SetAttribute(Attributes.Infected.IsDead, true)
		end
	end

	return {
		dealt = math.min(amount, before),
		blocked = false,
		killed = killed,
		overkill = math.max(amount - before, 0),
		-- GoreService decides the level; DamageService writes it into this table
		-- on the way back out. Guessing here would just be overwritten.
		goreLevel = Enums.GoreLevel.None,
		severedPart = nil,
		remainingHealth = remaining,
	}
end

--[[
	Builds whatever standard joints a body is missing, and says so once per
	variant.

	── IT USED TO GIVE UP ON A PARTIALLY RIGGED BODY ───────────────────────────
	The first version bailed the moment a rig had any Motor6D at all, reasoning
	that a partly rigged model is one whose author made choices worth respecting.
	The boot log disproved that: a Common variant turned up with joints for
	`Left Leg, Right Leg, Torso` and nothing else — hips and the root, no
	shoulders, no neck. That is not a choice, it is a rig somebody stopped
	building.

	And it fails in a way that looks like the animation being broken rather than
	the model: an R6 walk clip addresses Left/Right Shoulder and Left/Right Hip,
	so a body with hips and no shoulders walks with its arms nailed to its sides,
	and one missing hips too just slides. "Some of them drag around" is exactly
	that, and no amount of animation work could have fixed it.

	RigUtil.buildMissingJoints only ever fills genuine gaps — it skips a role that
	already has a joint, and skips one whose PART does not exist, so a rig with no
	separate hands keeps not having them. That makes it safe to run on every body,
	which is what it does now.

	Still not a fix for the MODEL. The joints are placed at standard fractions of
	each part's size, which is right for a humanoid and a guess for anything
	stylised, and they are rebuilt on every single spawn. Run
	studio-scripts/RigDoctor once, in Studio, where the result is visible and
	saved.
]]
function InfectedService:_boltTogether(model: Model, kind: string)
	local before = #RigUtil.getMotors(model)
	local variant = tostring(model:GetAttribute("FL_Variant") or model.Name)

	--[[
		RIVAL WELDS FIRST, because a rig that has this wrong passes every other
		test in this file and in every diagnostic script in the repo.

		Two rigid joints between the same two parts over-constrains the assembly.
		Roblox pins the pair; the Motor6D is still there and the animation still
		writes its Transform every frame, and the limb does not move because the
		weld beside it is holding the offset and winning.

		Nothing catches it. buildMissingJoints below clears rival welds only off a
		limb whose joint it is about to build — inside the loop, after the skip for
		a limb that already has one — so it fires exactly when there is no Motor6D
		to be over-constrained by. RigDoctor says "fully jointed". CheckAnimations
		says every id is fine. The rig type is right, the clip is right, the joints
		are all present, and the body slides around in its rest pose.

		That is "some of the common infected just drag around", and it is what you
		get for free by assembling a model in Studio, where dragging parts together
		welds them.
	]]
	--[[
		DUPLICATE MOTOR6Ds FIRST, because until very recently this code created
		them itself and a model saved in that state still carries them.

		buildMissingJoints decided which joints a rig already had from a graph
		walk; the walk needed a root; RigUtil.getRoot was shallow while every
		other lookup in that file was deep. So a rig whose parts sit in a Folder —
		an entirely ordinary way to assemble one — reported NO joints and got a
		complete second skeleton laid over its first, on every spawn. Two rigid
		joints on a pair over-constrains the assembly: the clip drives one, the
		other holds the limb, and the body slides around in its rest pose.

		It was SOME of the Commons and not all of them because the discriminator
		is how each individual model happens to be organised. A flat rig was fine.
		A foldered one was not. Thirty-five models assembled by hand are a mix.
	]]
	--[[ A joint somebody switched off. Enabled is serialized, defaults to true,
	     and is invisible unless you select that exact Motor6D and read the
	     Properties pane — so a disabled one satisfies every "fully jointed" check
	     in the project while the engine quietly refuses to drive it. ]]
	local reEnabled, reEnabledNames = RigUtil.enableMotors(model)
	if reEnabled > 0 then
		warnOnce(
			"disabled:" .. variant,
			string.format(
				"%s variant %q had %d joint(s) with Enabled set to false (%s). Roblox will not drive "
					.. "a disabled Motor6D, so those limbs never moved while every check called the "
					.. "rig complete. Switched back on at spawn; fix it in the model in Studio.",
				kind,
				variant,
				reEnabled,
				RigUtil.tally(reEnabledNames)
			)
		)
	end

	local dupesCut, dupePairs = RigUtil.clearDuplicateJoints(model)
	if dupesCut > 0 then
		table.sort(dupePairs)
		warnOnce(
			"duplicates:" .. variant,
			string.format(
				"%s variant %q arrived with %d duplicate joint(s) — a second Motor6D across a pair "
					.. "that already had one (%s). That over-constrains the assembly, so the "
					.. "animation drove one joint while the other held the limb still and the body "
					.. "slid around in its rest pose. Thinned at spawn. Run "
					.. "studio-scripts/RigDoctor to remove them from the model itself.",
				kind,
				variant,
				dupesCut,
				RigUtil.tally(dupePairs)
			)
		)
	end

	local weldsCut, cutPairs = RigUtil.clearRivalJoints(model)
	if weldsCut > 0 then
		table.sort(cutPairs)
		warnOnce(
			"welded:" .. variant,
			string.format(
				"%s variant %q had %d weld(s) holding pairs that already have a Motor6D (%s). Two "
					.. "rigid joints on one pair pins it, so the animation drove those limbs and "
					.. "nothing moved. Cut at spawn, which fixes the body and not the model: run "
					.. "studio-scripts/RigDoctor to cut them where it saves.",
				kind,
				variant,
				weldsCut,
				RigUtil.tally(cutPairs)
			)
		)
	end

	--[[
		BACKWARDS JOINTS NEXT, because a backwards joint is not a missing one and
		nothing below would ever notice it either.

		Roblox's animator treats each Motor6D's Part1 as the bone and drives the
		pose with that part's name. A shoulder built the other way round —
		Part0 = Left Arm, Part1 = Torso — therefore offers the animator a bone
		called "Torso" and no bone called "Left Arm", so an R6 walk clip keys a
		shoulder that, as far as the engine is concerned, is not there. Every
		other joint in the rig animates perfectly, which is what makes it read as
		"the animation is broken" rather than "the model is".

		It is also completely silent: the joint exists, so buildMissingJoints
		correctly leaves it alone; the parts are named correctly, so the report
		below says nothing; the body holds together and walks around. Dragging
		with one dead arm is the only symptom.

		Fixing it here rather than only reporting it is deliberate. The swap is
		exact — see RigUtil.normalizeMotorDirection — so there is no judgement
		call to leave to a person, and a rig assembled by hand in Studio gets
		this wrong far too easily to be worth a round of broken bodies first.
	]]
	local flipped, backwards = RigUtil.normalizeMotorDirection(model)
	if flipped > 0 then
		table.sort(backwards)
		warnOnce(
			"backwards:" .. variant,
			string.format(
				"%s variant %q had %d joint(s) wired backwards (%s) — Part0 and Part1 the wrong "
					.. "way round, so an animation that drives those parts moved nothing. Turned "
					.. "round at spawn, which fixes the body but not the model: run "
					.. "studio-scripts/RigDoctor once in Studio to fix it where it saves.",
				kind,
				variant,
				flipped,
				RigUtil.tally(backwards)
			)
		)
	end

	local built, unbuildable = RigUtil.buildMissingJoints(model)

	--[[
		AXES LAST, so it judges the rig every repair above has finished with:
		duplicates thinned, backwards joints turned round, missing ones built.

		This is the fault none of the others could see. An animation's rotations
		are applied INSIDE a Motor6D's C0, so they are read in the joint's own
		axes — and Roblox's R6 shoulders and hips are turned a quarter-turn about
		Y, which is what every R6 clip was keyed against. A joint built from a
		pivot with no rotation puts the limb in EXACTLY the right place at rest
		and then reads the clip in the wrong axes: the shoulder swing that should
		carry the arm forward carries it out sideways instead, so the arm sticks
		out left or right and stays there while the hips splay rather than step
		and the body slides along the floor.

		Every check in this sequence passed on those bodies. The rig is jointed,
		nothing is duplicated, welded, backwards or disabled, and it sits in a
		flawless rest pose — the fault only exists while the clip is playing, and
		no rest-pose diagnostic can see it. It is why "some of the Commons just
		drag around with an arm out" survived every fix before this one.
	]]
	local reframed, skewed = RigUtil.reframeJoints(model)
	if reframed > 0 then
		warnOnce(
			"skewed:" .. variant,
			string.format(
				"%s variant %q had %d joint(s) whose axes pointed the wrong way (%s). The rest pose "
					.. "was perfect, so every other check called the rig clean — but an animation is "
					.. "read in the joint's own axes, so those limbs swung sideways instead of "
					.. "forward and the body dragged with an arm sticking out. Turned round at "
					.. "spawn, which fixes the body and not the model: run studio-scripts/RigDoctor "
					.. "once in Studio to fix it where it saves.",
				kind,
				variant,
				reframed,
				RigUtil.tally(skewed)
			)
		)
	end

	--[[
		Joints that could not be built because the PART is not there.

		Reported separately and first, because it is the one failure that no
		amount of running RigDoctor will fix and the one that looks exactly like
		"the animation is broken". An animation addresses JOINTS; a joint needs
		the two parts it connects; so a model whose arm is called "LeftArm" or
		"Arm.L" instead of "Left Arm" never gets a shoulder, plays a walk clip
		that drives a shoulder it does not have, and stands still.

		Deduplicated, because a skeleton asks for the same torso six times.
	]]
	if #unbuildable > 0 then
		local seen, names = {}, {}
		for _, name in unbuildable do
			if not seen[name] then
				seen[name] = true
				table.insert(names, name)
			end
		end
		table.sort(names)
		warnOnce(
			"noparts:" .. variant,
			string.format(
				"%s variant %q has no part(s) named: %s — so those joints cannot be built, and "
					.. "an animation that drives them moves nothing. Rename the parts in Studio to "
					.. "the standard %s names. (Hands and feet are not listed here — a rig without "
					.. "them is a styling choice. Everything named below is not.)",
				kind,
				variant,
				table.concat(names, ", "),
				RigUtil.rigTypeOf(model)
			)
		)
	end

	if built == 0 then
		return
	end

	warnOnce(
		"unrigged:" .. variant,
		string.format(
			"%s variant %q was missing %d joint(s) and they were built at spawn — %s. It will "
				.. "animate now, but the joints are placed by proportion rather than by whoever "
				.. "built the model, and this happens again for every body of this variant. Run "
				.. "studio-scripts/RigDoctor to do it properly, once.",
			kind,
			variant,
			built,
			if before == 0
				then "it arrived with none at all, so it would otherwise come apart in mid-air"
				else string.format(
					"it arrived with %d, so the limbs those drive moved and the rest did not",
					before
				)
		)
	)
end

--[[ One death, exactly once. The body is left standing for GoreService. ]]
function InfectedService:_retire(record: any, ctx: any)
	if record.dead then
		return
	end
	record.dead = true

	local model = record.model
	local kind = record.kind

	if model.Parent then
		model:SetAttribute(Attributes.Infected.IsDead, true)
		model:SetAttribute(Attributes.Infected.Health, 0)
		model:SetAttribute(Attributes.Infected.Target, "")
	end

	self:_unlist(record)
	self._records[model] = nil

	-- onDeath runs FIRST, while the brain is still whole: a special's death
	-- handler has to be able to read brain.data and release whatever it was
	-- holding — a pin the team cannot answer is a bug, and a pin held by a
	-- corpse is the worst kind.
	if record.special and typeof(record.special.onDeath) == "function" then
		local ok, err = pcall(record.special.onDeath, model, record.brain, ctx)
		if not ok then
			warnOnce("onDeath:" .. kind, string.format("%s.onDeath failed: %s", kind, tostring(err)))
		end
	end

	--[[
		The death clip, before the brain that owns the animator is torn down.

		This is the only window it fits in. GoreService is about to disable every
		Motor6D in the rig, and a keyframe has nothing left to drive after that —
		so the clip has to start first, and the ragdoll has to wait for it. The
		length is written where GoreService can read it rather than passed,
		because the two are reached by different paths from applyDamage and
		neither calls the other.

		Zero, or no brain at all, means ragdoll immediately: exactly the old
		behaviour, which is what a body with no death clip should still get.
	]]
	if record.brain and model.Parent then
		local seconds = record.brain:playDeath()
		if seconds > 0 then
			model:SetAttribute(Attributes.Infected.DeathHold, seconds)
		end
	end

	-- Then the brain goes, before anything else touches the rig: a dead zombie
	-- must not spend one more frame issuing MoveTo, and GoreService is about to
	-- replace every Motor6D this brain holds a reference to.
	if record.brain then
		record.brain:destroy()
	end
	self:_stopBurning(record, BURN_CORPSE_LINGER)
	record.trove:destroy()

	-- Specials own their own vocalisations: those are the game's early-warning
	-- system and belong to the module that knows what the creature is doing.
	if not record.definition.isSpecial and record.root.Parent then
		local audio = Registry.find("AudioService")
		if audio then
			audio:play("Infected", "CommonDeath", record.root)
		end
	end

	self.died:fire(model, kind, ctx)
	self:_publishCounts()

	--[[ GoreService owns the corpse and schedules its own removal with a longer
	     grace. This only ever fires when it did not get the body at all — gore
	     disabled in GoreConfig, or the service erroring — because a level that
	     slowly fills with standing corpses is worse than no gore.

	     Through GoreConfig.corpseLifetime rather than off the definition
	     directly, because this timer is a CEILING on every corpse and not only on
	     the ones it was written for: two Debris items watch the same model and the
	     shorter one wins. A headshot Jockey would have been swept at 32 seconds
	     while the ragdoll record still believed it had 35. ]]
	local region = if typeof(ctx) == "table" then ctx.region else nil
	Debris:AddItem(
		model,
		GoreConfig.corpseLifetime(record.definition.corpseLifetime, region) + CORPSE_FALLBACK_GRACE
	)
end

--[[ Drops a record out of every live list. Idempotent: death and despawn can
     both reach it, and the per-kind count must not be decremented twice. ]]
function InfectedService:_unlist(record: any)
	if record.unlisted then
		return
	end
	record.unlisted = true

	local list = self._alive
	local index = record.index
	if index and list[index] == record then
		local last = #list
		local moved = list[last]
		list[index] = moved
		list[last] = nil
		if moved and moved ~= record then
			moved.index = index
		end
	end
	record.index = nil

	if record.priority then
		local priority = self._priority
		local at = table.find(priority, record)
		if at then
			table.remove(priority, at)
		end
	end

	local count = self._countByKind[record.kind]
	if count then
		self._countByKind[record.kind] = math.max(count - 1, 0)
	end
end

-- ════════════════════════════════════════════════════════════════════════════
--  Stagger and fire
-- ════════════════════════════════════════════════════════════════════════════

--[[
	Interrupts an infected for `duration` and knocks it back a little.

	The caller has already scaled `duration` by the definition's
	stumbleResistance — a Tank passing 0 here is a Tank that does not stumble,
	and this function must not second-guess that.
]]
function InfectedService:stagger(model: Model, direction: Vector3, duration: number)
	local record = self._records[model]
	if not record or record.dead then
		return
	end
	if typeof(duration) ~= "number" or duration <= 0 then
		return
	end

	record.brain:stagger(duration)

	local root = record.root
	if root and root.Parent and typeof(direction) == "Vector3" and direction.Magnitude > EPSILON then
		-- Scaled by mass so a Common and a Charger answer the same push
		-- differently instead of both sliding the same distance.
		root:ApplyImpulse(direction.Unit * (STAGGER_IMPULSE * root.AssemblyMass))
	end
end

--[[
	Sets an infected on fire.

	Burning runs until the body dies, with no timer — that is deliberate, and it
	is the reason InfectedConfig gives a Tank burnDamagePerSecond = 150 while
	giving it 4000 health. Fire is the intended answer to a Tank: a molotov that
	expired after a few seconds would deal a fraction of that and turn the one
	counter the team has into a decoration.

	`source` is the player who lit it, kept for kill credit.
]]
function InfectedService:ignite(model: Model, source: Player?)
	local record = self._records[model]
	if not record or record.dead then
		return
	end

	if typeof(source) == "Instance" and source:IsA("Player") then
		record.burnSource = source
	end

	if record.burning then
		return -- already alight; re-igniting must not stack flames or damage
	end
	record.burning = true

	local now = os.clock()
	record.burnLastAt = now
	-- Jittered: one molotov lights a dozen commons on the same frame, and their
	-- damage ticks must not then land on the same frame forever after.
	record.burnNextAt = now + random:NextNumber(0, BURN_TICK_INTERVAL)

	local model_ = record.model
	model_:SetAttribute(Attributes.Infected.Burning, true)

	local host = model_:FindFirstChild("UpperTorso") or model_:FindFirstChild("Torso") or record.root
	if host and host:IsA("BasePart") then
		local scale = record.definition.scale

		local fire = Instance.new("Fire")
		fire.Name = "FL_Burning"
		fire.Color = FIRE_COLOR
		fire.SecondaryColor = FIRE_SECONDARY_COLOR
		fire.Size = FIRE_SIZE * scale
		fire.Heat = FIRE_HEAT
		fire.Parent = host
		record.fire = fire

		--[[ A burning zombie in a dark corridor has to light the corridor, or the
		     molotov reads as a texture rather than an event. Up to BURN_LIGHT_MAX
		     of them: past that the body burns without its own light, which is
		     invisible in a crowd and is the whole cost. ]]
		if self._burnLights < BURN_LIGHT_MAX then
			local light = Instance.new("PointLight")
			light.Name = "FL_BurningLight"
			light.Color = FIRE_COLOR
			light.Range = FIRE_LIGHT_RANGE * scale
			light.Brightness = FIRE_LIGHT_BRIGHTNESS
			light.Shadows = false
			light.Parent = host
			record.light = light
			self._burnLights += 1
		end
	end
end

--[[ Puts a fire out. `linger` keeps the flame on a corpse for a moment. ]]
function InfectedService:_stopBurning(record: any, linger: number)
	if record.model.Parent then
		record.model:SetAttribute(Attributes.Infected.Burning, false)
	end
	record.burning = false

	--[[ Released as the record lets go of it, not when the instance is finally
	     destroyed: with a linger the instance outlives the body by a moment, and
	     holding the budget for that moment would let a long fight ratchet the
	     count up until nothing new could ever light again. ]]
	if record.light then
		self._burnLights = math.max(self._burnLights - 1, 0)
	end

	--[[ The FLAME lingers on a corpse; the LIGHT does not.

	     They used to linger together, and that quietly broke the cap above. The
	     budget slot is released the moment the record lets go — it has to be, or
	     a long fight ratchets the count until nothing can light again — so a
	     lingering light is a light nobody is counting. With bodies dying in
	     clumps that is a steady population of uncounted lights sitting on
	     corpses, which is exactly the ceiling the cap exists to impose.

	     Nothing is lost visually. The corpse still burns, because the Fire is
	     what says "this body is on fire", and a dead body that no longer casts
	     its own glow is not a read anyone was using. ]]
	local fire = record.fire
	record.fire = nil
	if fire then
		if linger > 0 then
			Debris:AddItem(fire, linger)
		else
			fire:Destroy()
		end
	end

	local light = record.light
	record.light = nil
	if light then
		light:Destroy()
	end
end

--[[ One burn tick. Charges the real elapsed time so the DPS is honest whatever
     rate the entity is being updated at. ]]
function InfectedService:_stepBurn(record: any, now: number)
	if now < record.burnNextAt then
		return
	end

	local elapsed = now - record.burnLastAt
	record.burnLastAt = now
	record.burnNextAt = now + BURN_TICK_INTERVAL

	local amount = record.definition.burnDamagePerSecond * elapsed
	if amount <= 0 then
		return
	end

	-- The igniter is only named on the tick that actually kills, so a molotov
	-- still earns the kill without firing a hitmarker at whoever threw it four
	-- times a second for every body in the fire.
	local source = record.burnSource
	local lethal = record.humanoid.Health <= amount
	if not (lethal and source and source.Parent) then
		source = nil
	end

	Registry.get("DamageService"):applyDamage(
		record.model,
		amount,
		Types.newDamageContext({
			attacker = source,
			damageType = Enums.DamageType.Fire,
			region = Enums.HitRegion.Torso,
			hitPosition = record.root.Position,
			hitNormal = Vector3.yAxis,
			-- Fire pushes nothing. Straight up keeps the gore system's impulse
			-- maths sane without launching a burning body sideways.
			direction = Vector3.yAxis,
			distance = 0,
		})
	)
end

-- ════════════════════════════════════════════════════════════════════════════
--  Queries
-- ════════════════════════════════════════════════════════════════════════════

--[[ Live infected, optionally of one kind. Returns a fresh array; the caller
     may hold it across a frame, and entries may die while they do — check
     RigUtil.isAlive if that matters to you. ]]
function InfectedService:getAlive(kind: string?): { Model }
	local models = table.create(#self._alive)
	for _, record in self._alive do
		if kind == nil or record.kind == kind then
			table.insert(models, record.model)
		end
	end
	return models
end

--[[ O(1). The Director asks this several times a second. ]]
function InfectedService:getCount(kind: string?): number
	if kind == nil then
		return #self._alive
	end
	return self._countByKind[kind] or 0
end

--[[ The brain driving a model, or nil for a corpse or a stranger. ]]
function InfectedService:getBrain(model: Model): any?
	local record = self._records[model]
	return record and record.brain
end

--[[ True while this model is a live infected this service owns. False for a
     corpse, for a survivor, and for scenery. ]]
function InfectedService:isTracked(model: Model): boolean
	return self._records[model] ~= nil
end

--[[
	The shared survivor list every brain reads. READ ONLY, and iterate by index:

	    local snapshot = InfectedService:getSurvivorSnapshot()
	    for i = 1, snapshot.count do
	        local entry = snapshot.entries[i]  -- player, character, root,
	    end                                    -- position, incapacitated,
	                                           -- noiseAt, noiseWeight

	`entries` is longer than `count` whenever the team has shrunk: the tables are
	reused rather than reallocated, so anything past `count` is stale. Never use
	#entries.
]]
function InfectedService:getSurvivorSnapshot(): any
	return self._snapshot
end

--[[
	Records that a survivor made a noise worth walking toward.

	Every listener applies its OWN InfectedConfig.hearingRange, so this has no
	radius: a Tank hears a shot at 600 studs and a Boomer does not, which is the
	config's business and not the caller's.

	`weight` is how much closer it makes that survivor look during target
	selection — gunfire is a nudge, Boomer bile should pass something large
	enough to override everything else in the room.
]]
function InfectedService:reportNoise(character: Model, weight: number?, duration: number?)
	if typeof(character) ~= "Instance" then
		return
	end
	local player = Players:GetPlayerFromCharacter(character)
	if not player then
		return
	end

	local now = os.clock()
	local entry = self._noise[player]
	if not entry then
		entry = { at = 0, weight = 0, expiresAt = 0 }
		self._noise[player] = entry
	end

	local newWeight = weight or GUNSHOT_NOISE_WEIGHT
	-- A loud noise is not cancelled by a quiet one that follows it.
	if now < entry.expiresAt and entry.weight > newWeight then
		entry.at = now
		return
	end
	entry.at = now
	entry.weight = newWeight
	entry.expiresAt = now + (duration or GUNSHOT_NOISE_DURATION)
end

--[[
	Pulls every common within `radius` to a point and makes them ignore
	survivors until they arrive. A pipe bomb is exactly this call.
]]
--[[
	The same idea as lure, with a ceiling and Commons only.

	The Boomer's burst is what needs it, and the two differences from lure are
	both the burst's. A CAP, because "every Common within a hundred and seventy
	studs" is a wipe rather than a punishment and would spend the Director's
	whole population on one death — where the Witch's summon is SUPPOSED to be
	everything nearby, because she is a boss and that is the fight.

	And Commons only rather than everything-but-a-boss: a special has its own
	reason for being where it is, and a Charger that could be whistled across
	the map by a dying Boomer is a Charger whose approach nobody can read.

	Sends them to a PLACE, not at a player — the horde converges on where the
	noise was, so a team that moves after being covered survives and a team that
	stands still does not. That is the whole lesson a Boomer teaches, and
	targeting the victim directly would delete it.

	Returns how many actually heard it.
]]
function InfectedService:lureCapped(
	position: Vector3,
	radius: number,
	duration: number,
	limit: number
): number
	if typeof(position) ~= "Vector3" then
		return 0
	end
	local budget = math.max(math.floor(limit or 0), 0)
	local radiusSquared = radius * radius
	local called = 0

	for _, record in self._alive do
		if called >= budget then
			break
		end
		if record.dead or record.definition.isSpecial then
			continue
		end
		local root = record.root
		if root and root.Parent and (root.Position - position).Magnitude ^ 2 <= radiusSquared then
			record.brain:lureTo(position, duration)
			called += 1
		end
	end

	return called
end

function InfectedService:lure(position: Vector3, radius: number, duration: number)
	local radiusSquared = radius * radius
	for _, record in self._alive do
		if record.dead or record.definition.isBoss then
			continue
		end
		local root = record.root
		if root and root.Parent and (root.Position - position).Magnitude ^ 2 <= radiusSquared then
			record.brain:lureTo(position, duration)
		end
	end
end

-- ════════════════════════════════════════════════════════════════════════════
--  The shared update loop
-- ════════════════════════════════════════════════════════════════════════════

--[[
	Stands the whole horde down while the game is genuinely paused.

	One flag on the loop rather than a pause on each brain, and that is a
	deliberate choice rather than the lazy one: InfectedBrain.pause is ALREADY
	owned by the specials, which use it to take over their own bodies for a
	pounce or a charge. Pausing every brain here would be fine; RESUMING every
	brain here would hand a mid-pounce Hunter back to the common AI, and the
	pounce would never finish. The loop not running is the same freeze with
	nothing to put back.

	Burning stops with it, because _stepBurn is ticked from this loop — which is
	the honest reading of a pause: a player who paused while on fire should not
	come back to a corpse.
]]
function InfectedService:setPaused(on: boolean)
	self._paused = on == true
end

function InfectedService:isPaused(): boolean
	return self._paused == true
end

function InfectedService:_step()
	if self._paused then
		return
	end

	local now = os.clock()
	self:_refreshSnapshot(now)

	-- Specials and bosses first and unconditionally. There are at most four of
	-- them and their modules drive pounces, charges and tongues — physics that
	-- must not be sampled at 4 Hz.
	local priority = self._priority
	for index = #priority, 1, -1 do
		local record = priority[index]
		if record then
			self:_tick(record, now)
		end
	end

	local list = self._alive
	local budget = MAX_COMMON_UPDATES_PER_FRAME
	local cursor = self._cursor
	-- At most one pass over the population per frame, whatever the budget: an
	-- empty or all-idle horde must not spin this loop.
	local passes = #list

	while budget > 0 and passes > 0 do
		passes -= 1
		local count = #list
		if count == 0 then
			break
		end
		cursor += 1
		if cursor > count then
			cursor = 1
		end

		local record = list[cursor]
		-- The dueness test is the ONLY per-infected work this loop does every
		-- frame: one subtraction and one compare.
		if
			record
			and not record.priority
			and not record.dead
			and now - record.lastUpdate >= record.interval
		then
			budget -= 1
			self:_tick(record, now)
		end
	end

	self._cursor = cursor
end

function InfectedService:_tick(record: any, now: number)
	local model = record.model
	if record.dead then
		return
	end
	if not model.Parent or not record.root.Parent then
		-- Destroyed out from under us (streamed out, fell out of the world).
		self:despawn(model)
		return
	end

	local elapsed = now - record.lastUpdate
	record.lastUpdate = now

	-- Recomputed only on a tick, so the scheduler above never pays for it.
	local nearest = self:_nearestSurvivorDistance(record.root.Position)
	record.nearest = nearest
	record.interval = if record.priority then 0 else self:_intervalFor(nearest)

	if self:_trackMaroon(record, nearest, elapsed) then
		return
	end

	if record.burning then
		self:_stepBurn(record, now)
		-- The burn tick can kill: everything below would be running on a corpse.
		if record.dead then
			return
		end
	end

	local ok, err = pcall(record.brain.update, record.brain, elapsed, self._snapshot)
	if not ok then
		self:_brainError(record, err)
		return
	end

	local special = record.special
	if special and typeof(special.onUpdate) == "function" then
		local specialOk, specialErr = pcall(special.onUpdate, model, record.brain, elapsed)
		if not specialOk then
			self:_brainError(record, specialErr)
		end
	end
end

--[[ A brain or special that throws is a bug in a module being written right
     now. Report it once, and retire the body if it keeps happening, so one bad
     module cannot spam output at 60 Hz or stall the rest of the horde. ]]
function InfectedService:_brainError(record: any, err: any)
	record.errors += 1
	warnOnce("brain:" .. record.kind, string.format("%s brain update failed: %s", record.kind, tostring(err)))
	if record.errors >= MAX_BRAIN_ERRORS then
		self:despawn(record.model)
	end
end

--[[ Bodies, gore and impact debris must not count as cover: a zombie standing
     behind the rest of its own horde is in plain sight, and treating the horde
     as a wall would let this reap the one body a player is aiming at. ]]
function InfectedService:_refreshSightIgnore()
	local now = os.clock()
	if now - self._sightIgnoreAt < SIGHT_IGNORE_REFRESH then
		return
	end
	self._sightIgnoreAt = now
	local ignore = self._sightIgnore
	table.clear(ignore)
	for _, name in { "Infected", "FL_Gore", "FL_Impacts" } do
		local folder = Workspace:FindFirstChild(name)
		if folder then
			table.insert(ignore, folder)
		end
	end
	for _, player in Players:GetPlayers() do
		if player.Character then
			table.insert(ignore, player.Character)
		end
	end
end

--[[
	True when nothing solid stands between this body and any live survivor.

	Only ever called from the maroon check, which has already established that
	the body is far away and has been going nowhere for half a minute — so this
	is a handful of casts a minute across the whole horde, not a per-tick cost.
]]
function InfectedService:_isSeen(position: Vector3): boolean
	self:_refreshSightIgnore()
	local snapshot = self._snapshot
	for index = 1, snapshot.count do
		local entry = snapshot.entries[index]
		local root = entry.root
		if root and root.Parent then
			if RaycastUtil.hasLineOfSight(root.Position, position, self._sightIgnore) then
				return true
			end
		end
	end
	return false
end

--[[
	Takes a body off the board when it has proved it can never reach anyone.

	Returns true if the record was despawned, in which case the caller must stop
	touching it — everything after this in the tick would be running on a corpse.

	The clock only runs while the body is beyond MAROON_DISTANCE. A horde piled
	against a safe-room door is not making progress either, and reaping that is
	the opposite of what anyone wants.
]]
function InfectedService:_trackMaroon(record: any, nearest: number, elapsed: number): boolean
	if record.priority or record.dead then
		return false
	end
	--[[ No survivors alive means every distance is infinite and nothing can make
	     progress. Wiping the horde on a team wipe is the round's job. ]]
	if nearest >= math.huge then
		return false
	end

	--[[ First tick. The distance it spawned at opens the window; it is not
	     progress, or every body would clear `math.huge` on its first comparison
	     and flag itself as having closed ground it never closed. ]]
	if record.progressFrom >= math.huge then
		record.progressFrom = nearest
		return false
	end

	--[[ Real ground closed since the window opened. Note that progressFrom is
	     NOT nudged down by smaller gains: a body walking in at four studs a
	     second improves by about one stud per tick, and letting each of those
	     move the reference means the threshold is never crossed and a body that
	     is plainly doing its job gets reaped mid-approach. ]]
	if nearest < record.progressFrom - MAROON_PROGRESS then
		record.progressFrom = nearest
		record.maroonedFor = 0
		record.progressed = true
		return false
	end

	--[[ Close enough to be somebody's problem. A horde piled against a safe-room
	     door is not making progress either, and reaping that is the opposite of
	     what anyone wants — and being here at all proves the body could reach
	     the team from wherever it started. ]]
	if nearest < MAROON_DISTANCE then
		record.progressFrom = nearest
		record.maroonedFor = 0
		record.progressed = true
		return false
	end

	record.maroonedFor += elapsed
	if record.maroonedFor < MAROON_TIME then
		return false
	end
	--[[ Restart the window whatever happens next, so a body that survives on the
	     sight check does not re-test it on every tick from here on. ]]
	record.maroonedFor = 0
	record.progressFrom = nearest

	local position = record.root.Position
	if self:_isSeen(position) then
		return false
	end

	--[[ Both places, and the window they span. Where it was PUT is what a spawn
	     node can be blamed for; where it ENDED UP is how far it managed to get;
	     and the window is what makes that distance mean anything — twenty-six
	     studs is a lot for a second and nothing at all for twenty-five. ]]
	self.marooned:Fire(position, not record.progressed, record.spawnedAt, MAROON_TIME)
	self:despawn(record.model)
	return true
end

function InfectedService:_intervalFor(distance: number): number
	for _, band in UPDATE_BANDS do
		if distance <= band.distance then
			return band.interval
		end
	end
	return DISTANT_INTERVAL
end

function InfectedService:_nearestSurvivorDistance(position: Vector3): number
	local snapshot = self._snapshot
	local nearest = math.huge
	for index = 1, snapshot.count do
		local entry = snapshot.entries[index]
		local distance = (entry.position - position).Magnitude
		if distance < nearest then
			nearest = distance
		end
	end
	return nearest
end

--[[
	Rebuilds the shared survivor view.

	Membership (who is alive, which character) changes a few times a minute, so
	it is rebuilt on a timer. Position and state change constantly, so they are
	refreshed every frame — over at most four entries, which is nothing, and it
	means 46 brains share four property reads instead of making 184 of their own.
]]
function InfectedService:_refreshSnapshot(now: number)
	local snapshot = self._snapshot
	local survivors = Registry.find("SurvivorService")

	if now - snapshot.builtAt >= SNAPSHOT_MEMBERSHIP_INTERVAL then
		snapshot.builtAt = now

		local players: { Player }
		if survivors and typeof(survivors.getAliveSurvivors) == "function" then
			players = survivors:getAliveSurvivors()
		else
			players = Players:GetPlayers()
		end

		local count = 0
		for _, player in players do
			local character = player.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if not root or not RigUtil.isAlive(character) then
				continue
			end

			count += 1
			local entry = snapshot.entries[count]
			if not entry then
				entry = { player = nil, character = nil, root = nil, position = Vector3.zero }
				snapshot.entries[count] = entry
			end
			entry.player = player
			entry.character = character
			entry.root = root
			entry.position = root.Position
			entry.incapacitated = false
			entry.noiseAt = 0
			entry.noiseWeight = 0
		end
		snapshot.count = count
	end

	snapshot.updatedAt = now
	for index = 1, snapshot.count do
		local entry = snapshot.entries[index]
		local root = entry.root
		if root and root.Parent then
			entry.position = root.Position
		end

		if survivors and typeof(survivors.isIncapacitated) == "function" then
			entry.incapacitated = survivors:isIncapacitated(entry.player) == true
		end

		local noise = self._noise[entry.player]
		if noise and now < noise.expiresAt then
			entry.noiseAt = noise.at
			entry.noiseWeight = noise.weight
		else
			entry.noiseAt = 0
			entry.noiseWeight = 0
		end
	end
end

-- ════════════════════════════════════════════════════════════════════════════
--  Gunfire detection
-- ════════════════════════════════════════════════════════════════════════════

--[[
	Firing a gun is the loudest thing a survivor does, and it is what pulls a
	horde onto them. Rather than requiring every weapon system to remember to
	tell the AI, this watches the ammo attributes InventoryService already
	mirrors for the HUD: a magazine count that went DOWN is a shot fired.

	Reloading raises the count and is ignored. Dropping a weapon zeroes it and
	registers as one harmless noise ping at the owner's own position.
]]
function InfectedService:_watchPlayer(player: Player)
	if self._playerTroves[player] then
		return
	end

	local trove = Trove.new()
	self._playerTroves[player] = trove
	self._ammo[player] = {}

	for _, attribute in AMMO_ATTRIBUTES do
		self._ammo[player][attribute] = player:GetAttribute(attribute) or 0
		trove:connect(player:GetAttributeChangedSignal(attribute), function()
			local value = player:GetAttribute(attribute)
			if typeof(value) ~= "number" then
				return
			end
			local previous = self._ammo[player][attribute] or 0
			self._ammo[player][attribute] = value
			if value < previous and player.Character then
				self:reportNoise(player.Character, GUNSHOT_NOISE_WEIGHT, GUNSHOT_NOISE_DURATION)
			end
		end)
	end
end

--[[
	Global counts for the music system and the debug overlay. Written on spawn
	and death only — never on a heartbeat.

	TankActive is misnamed and means "a boss the team has to stand and fight is
	on the map": the Tank and the Metallic, per InfectedConfig.PeakBosses, and
	not the Witch, who is a hazard you walk around rather than a fight worth
	changing the music for.

	THIS IS THE ONLY WRITER. The two specials used to set it themselves on spawn
	and clear it on death, each with its own "unless another one is still
	standing" scan — and this line then quietly overwrote both of them from the
	Tank count alone on the very next spawn or death. A Metallic fought without a
	Tank present therefore lost its music to whichever Common happened to die
	next. Counting it in one place, off the counts that are already authoritative
	for everything else, removes the second writer rather than teaching it about
	a third kind.

	The ordering works out on both sides: _unlist decrements before the special's
	onDeath runs, and the increment happens before onSpawn, so this is correct
	the instant it is called rather than one event behind.
]]
function InfectedService:_publishCounts()
	Workspace:SetAttribute(Attributes.Game.InfectedAlive, #self._alive)

	local bosses = 0
	for kind in InfectedConfig.PeakBosses do
		bosses += self._countByKind[kind] or 0
	end
	Workspace:SetAttribute(Attributes.Game.TankActive, bosses > 0)
end

Registry.register("InfectedService", InfectedService)

return InfectedService
