--!nonstrict
--[[
	ProjectileService — the three things you throw.

	Pipe bombs, molotovs and bile jars are placed by ItemPlacer, picked up by
	InventoryService and drawn in the HUD, and until this module existed none of
	them could ever be used: InputController sent Remotes.Event.ThrowItem and
	nobody was listening. This is the listener.

	── WHAT EACH ONE IS FOR ────────────────────────────────────────────────────
	They are not three flavours of grenade. Each answers a different problem, and
	a team that reads which one they are holding correctly survives a wave they
	otherwise would not.

	  PIPE BOMB  deletes a horde by MOVING it first. Every common inside a wide
	             radius abandons the survivors and runs at the beeping light, and
	             then the light goes away and so do they. The gathering is the
	             whole item: a pipe bomb thrown at a wall you are backing away
	             from buys ten seconds that no amount of ammunition can.
	  MOLOTOV    denies ground. It is not damage, it is a wall you can put
	             anywhere, and it is the intended counter to a Tank —
	             InfectedConfig gives a Tank burnDamagePerSecond 150 against 4000
	             health precisely so that a Tank walking through fire is a Tank
	             the team can beat.
	  BILE JAR   is the Boomer effect without the Boomer: it makes something else
	             more interesting than you are. Thrown at the floor it is a
	             gathering point; thrown at a teammate it is a very funny mistake.

	── AUTHORITY ───────────────────────────────────────────────────────────────
	The client sends an origin, a direction and a power, and every one of those
	is a suggestion. The origin is checked against where the server thinks the
	thrower's head is (GameConfig.HitValidation.PositionTolerance) and replaced
	when it is out of tolerance rather than rejected — a laggy player still gets
	their throw, they just do not get to pick where it comes from. The item comes
	out of the inventory through InventoryService:consumeSlot, which is what
	proves they were holding it at all.

	── DAMAGE ──────────────────────────────────────────────────────────────────
	Nothing here touches a Humanoid. The blast goes through
	DamageService:applyExplosion (which is what makes GoreConfig's
	ExplosiveAlwaysGibs true of everything a pipe bomb kills), fire on infected
	goes through InfectedService:ignite (which owns the burn, its damage and its
	kill credit), and fire on survivors goes through DamageService:applyDamage
	like any other source.

	── PERFORMANCE AND CLEANUP ─────────────────────────────────────────────────
	One Heartbeat connection drives every live projectile, every fire pool and
	every bile zone. Contact is a swept raycast between steps rather than a
	.Touched connection per object, the area effects re-test bodies four times a
	second rather than every frame off ONE shared list of the living, and every
	instance any of this creates belongs to a Trove that is destroyed on a hard
	deadline. A molotov that leaks its fire parts would still be burning through
	the framerate two waves later.
]]

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attributes = require(Shared.Net.Attributes)
local AudioConfig = require(Shared.Config.AudioConfig)
local Enums = require(Shared.Enums)
local GameConfig = require(Shared.Config.GameConfig)
local GoreConfig = require(Shared.Config.GoreConfig)
local InfectedConfig = require(Shared.Config.InfectedConfig)
local RaycastUtil = require(Shared.Util.RaycastUtil)
local Registry = require(Shared.Util.Registry)
local Remotes = require(Shared.Net.Remotes)
local RigUtil = require(Shared.Util.RigUtil)
local Trove = require(Shared.Util.Trove)
local Types = require(Shared.Types)
local UITheme = require(Shared.Config.UITheme)

local THROWABLE = Enums.Throwable
local VALIDATION = GameConfig.HitValidation
local COLOR = UITheme.Color

--[[
	Throwables have no config module of their own. That is deliberate: they are
	three items rather than a roster, and every number below governs behaviour
	that is only visible in this file. Anything that DOES already have an owner —
	blast falloff, burn damage per second, friendly fire, the gore roll, how far
	a Common can hear — is read from the config that owns it and never restated.
]]

-- A player can only throw what they are holding, so this is anti-spam on the
-- remote rather than balance: without it a client can ask several hundred times
-- a second and make the server do the inventory walk every time.
local THROW_INTERVAL = 0.4

-- Hard ceiling on objects in flight. Unreachable in a real round (one throwable
-- per survivor), so hitting it means something is wrong and the oldest is
-- retired rather than the newest refused.
local MAX_LIVE_PROJECTILES = 12

-- Muzzle velocity at power 1, plus the lob that makes a throw arc instead of
-- travelling like a bullet. The lift is what lets a player put one over a car.
local THROW_SPEED = 86
local THROW_LIFT = 16
local THROW_TUMBLE = 9 -- rad/s of spin, purely so it reads as thrown
local THROW_FORWARD_OFFSET = 2.2 -- spawned clear of the thrower's own shoulder

-- Nothing lives forever. A throwable that somehow never lands is still gone by
-- this point, and the fuse timers below are all well under it.
local MAX_FLIGHT_TIME = 12

-- The area effects re-test bodies at this rate off one shared list of the
-- living. Four times a second is imperceptible for walking into fire and a
-- fifteenth of the work of doing it every frame.
local ZONE_INTERVAL = 0.25

-- ── pipe bomb ───────────────────────────────────────────────────────────────

local PIPE_FUSE = 4.4

--[[ The lure radius is a Common's own hearing range, so the promise the item
     makes is exactly "every infected that could have heard you can hear this
     instead". Retuning how far a horde hears retunes the pipe bomb with it. ]]
local COMMON_DEFINITION = InfectedConfig.get(Enums.Infected.Common)
local PIPE_LURE_RADIUS = if COMMON_DEFINITION then COMMON_DEFINITION.hearingRange else 320

-- Re-issued rather than set once: commons that spawn, or that finish being
-- staggered, during the fuse have to join the crowd too, and the bomb is still
-- rolling, so the gathering point moves with it.
local PIPE_LURE_REFRESH = 0.35

--[[ Enough to erase a packed horde and to genuinely hurt a special, and not
     remotely enough to threaten a Tank — fire is the answer to a Tank, and a
     pipe bomb that also solved that problem would flatten the whole item
     triangle. Falloff to nothing at the rim is DamageService's. ]]
local PIPE_BLAST_RADIUS = 34
local PIPE_BLAST_DAMAGE = 480

-- The beep accelerates from the first interval to the last across the fuse.
-- This is the entire readout: how long you have, and where they are all going.
local PIPE_BEEP_SLOW = 0.6
local PIPE_BEEP_FAST = 0.08
local PIPE_LIGHT_RANGE = 26
local PIPE_LIGHT_BRIGHTNESS = 4

local PIPE_FLASH_TIME = 0.32
local PIPE_SHAKE_RADIUS = 90 -- studs within which the blast moves the camera
local PIPE_SHAKE_POSITION = 3.4
local PIPE_SHAKE_ROTATION = 5.0
local PIPE_SHAKE_DECAY = 9
local PIPE_ATMOSPHERE_FLASH = 0.35

-- ── molotov ─────────────────────────────────────────────────────────────────

-- A jar that never hits anything still breaks; glass does.
local MOLOTOV_FUSE = 8

--[[ The pool is the item. Twenty-two seconds is long enough to be a decision
     about ground rather than a burst of damage, and short enough that a team
     can take the corridor back before the wave that needed it is over. ]]
local FIRE_LIFETIME = 22
local FIRE_RADIUS_START = 7
local FIRE_RADIUS_MAX = 21
local FIRE_SPREAD_TIME = 3.5
local FIRE_HEIGHT = 9 -- vertical reach; fire on the floor below must not burn you

--[[ Survivors burn too, and that is not an oversight — a molotov you cannot
     stand in is what makes it a wall. DamageService then applies the difficulty's
     friendly-fire scale on top, so this is the Expert number and Normal quarters
     it. Infected are NOT damaged from here: InfectedService:ignite owns burning,
     including the 150/s that makes fire the answer to a Tank. ]]
local FIRE_SURVIVOR_DPS = 34

-- Ceiling on simultaneous pools. The oldest is retired rather than a new throw
-- refused, because an item the player spent must always do something.
local MAX_FIRE_POOLS = 4
local FIRE_CELLS = 9

local FIRE_COLOR = Color3.fromRGB(255, 148, 48)
local FIRE_SECONDARY_COLOR = Color3.fromRGB(180, 42, 16)
local FIRE_CELL_SIZE = 5.5
local FIRE_CELL_HEAT = 12
local FIRE_LIGHT_RANGE = 30
local FIRE_LIGHT_BRIGHTNESS = 2.6
local FIRE_FADE_TIME = 2.5 -- the pool dies down rather than blinking out

-- ── bile jar ────────────────────────────────────────────────────────────────

local BILE_FUSE = 8
local BILE_DURATION = 20
local BILE_SPLASH_RADIUS = 16 -- who gets coated
local BILE_LURE_RADIUS = PIPE_LURE_RADIUS -- who comes running; the same earshot
local BILE_LURE_REFRESH = 0.5
local BILE_HEIGHT = 12

--[[ How hard a coated survivor outranks everyone else in target selection.
     InfectedConfig's noise weights put a gunshot at 0.45; the brain divides a
     candidate's score by (1 + weight), so this makes a biled teammate roughly
     ten times more attractive than the person standing next to them. That is
     the joke and the mechanic at once. ]]
local BILE_NOISE_WEIGHT = 9.0

local BILE_POOL_SIZE = 12
local BILE_CELLS = 7
local BILE_MIST_RATE = 14
local BILE_FADE_TIME = 2.0

-- Same ceiling and same reasoning as the fire pools: the oldest splash is
-- retired rather than a thrown jar refused.
local MAX_BILE_ZONES = 4

-- ── shared visuals ──────────────────────────────────────────────────────────

-- Engine textures rather than marketplace assets: they ship with every client
-- and cannot fail to load mid-round.
local SMOKE_TEXTURE = "rbxasset://textures/particles/smoke_main.dds"
local SPARK_TEXTURE = "rbxasset://textures/particles/sparkles_main.dds"

local GROUND_SEARCH = 24 -- how far down a shatter looks for a floor to sit on

local EPSILON = 1e-4

--[[
	The bank has no explosion, no glass-shatter and no beep sample yet. Rather
	than stay silent, each of these borrows the closest thing in AudioConfig.Id
	and re-shapes it: a shotgun blast dropped more than an octave reads as an
	explosion, and the impact-glass sample is already exactly a bottle breaking.
	When real samples are uploaded, only the ids here change.
]]
local function localSound(
	id: string,
	volume: number,
	pitchMin: number,
	pitchMax: number,
	rollOffMax: number,
	priority: number
)
	return {
		id = id,
		ids = nil,
		volume = volume,
		pitchMin = pitchMin,
		pitchMax = pitchMax,
		rollOffMin = 12,
		rollOffMax = rollOffMax,
		looped = false,
		priority = priority,
	}
end

local SOUND = table.freeze({
	Explosion = localSound(AudioConfig.Id.ShotgunBlast, 1.0, 0.42, 0.5, 900, 9),
	Beep = localSound(AudioConfig.Id.PromptAppear, 0.55, 1.5, 1.55, 150, 5),
	Shatter = AudioConfig.Impact.Glass,
	HordeCall = AudioConfig.Infected.CommonAlert,
})

local random = Random.new()

local ProjectileService = {}

ProjectileService._trove = Trove.new()
ProjectileService._folder = nil :: Folder?
ProjectileService._live = {} :: { any }
ProjectileService._fires = {} :: { any }
ProjectileService._biles = {} :: { any }
ProjectileService._lastThrow = {} :: { [Player]: number }
ProjectileService._zoneAccumulator = 0

-- ════════════════════════════════════════════════════════════════════════════
--  Small helpers
-- ════════════════════════════════════════════════════════════════════════════

local function isFiniteVector(value: any): boolean
	if typeof(value) ~= "Vector3" then
		return false
	end
	return value.X == value.X and value.Y == value.Y and value.Z == value.Z and value.Magnitude < math.huge
end

local function audio(): any?
	return Registry.find("AudioService")
end

local function playAt(definition: any, position: Vector3)
	local service = audio()
	if service then
		service:playAt(definition, position)
	end
end

--[[ Distance in the plane, with height treated separately. A fire pool on the
     floor below has to be harmless, and a straight radius check would set light
     to somebody standing on the walkway above it. ]]
local function withinColumn(from: Vector3, to: Vector3, radius: number, height: number): boolean
	local delta = to - from
	if math.abs(delta.Y) > height then
		return false
	end
	local flat = Vector3.new(delta.X, 0, delta.Z)
	return flat.Magnitude <= radius
end

--[[
	Drops a point onto whatever is under it, so a shatter puddles on the floor
	instead of hanging in the air where the bottle happened to break.

	Deliberately NOT RaycastUtil.groundAt: that one starts its cast above the
	point it is given, which indoors finds the top of the ceiling and puts the
	fire on the floor above the fight. This starts a stud over the impact — high
	enough not to begin inside the surface it just hit, low enough that the first
	thing it finds is the ground the player is standing on.

	The params are reused rather than rebuilt, the same way hasLineOfSight reuses
	its own: nothing between the filter assignment and the cast yields, so no
	other caller can observe the filter mid-cast.
]]
local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Exclude
groundParams.IgnoreWater = true
groundParams.RespectCanCollide = false

local function groundedAt(position: Vector3, ignore: { Instance }): Vector3
	groundParams.FilterDescendantsInstances = ignore
	local result =
		Workspace:Raycast(position + Vector3.yAxis, Vector3.new(0, -GROUND_SEARCH, 0), groundParams)
	return if result then result.Position else position
end

local function decorate(part: BasePart)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Locked = true
	part.CollisionGroup = "Debris"
end

-- ════════════════════════════════════════════════════════════════════════════
--  Lifecycle
-- ════════════════════════════════════════════════════════════════════════════

function ProjectileService:init()
	self:_container()
end

--[[ One folder in Workspace holding every part this service is responsible for,
     so a developer can see at a glance what is still burning — and so a bad boot
     order can never leave a thrown object unparented and silently gone. ]]
function ProjectileService:_container(): Instance
	local folder = self._folder
	if folder and folder.Parent then
		return folder
	end

	folder = Workspace:FindFirstChild("FL_Projectiles")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "FL_Projectiles"
		folder.Parent = Workspace
	end
	self._folder = folder
	return folder
end

function ProjectileService:start()
	-- THE loop. Every projectile, every fire pool and every bile zone, forever.
	self._trove:connect(RunService.Heartbeat, function(deltaTime: number)
		self:_step(deltaTime)
	end)

	self._trove:connect(Remotes.Event.ThrowItem.OnServerEvent, function(player: Player, payload: any)
		if typeof(payload) ~= "table" then
			return
		end
		-- itemId is deliberately not read off the payload: what the player is
		-- holding is the server's business and the client is not asked.
		self:throw(player, nil, payload.origin, payload.direction, payload.power)
	end)

	self._trove:connect(Players.PlayerRemoving, function(player: Player)
		self._lastThrow[player] = nil
	end)
end

-- ════════════════════════════════════════════════════════════════════════════
--  Throwing
-- ════════════════════════════════════════════════════════════════════════════

--[[
	Throws whatever the player is holding in their throwable slot.

	`itemId`, `origin`, `direction` and `power` are all optional: InventoryService
	calls this with nothing but the item id when the throw key is pressed on an
	already-equipped throwable, and the remote calls it with everything but the
	id. Anything missing is taken from the server's own view of the character.

	Returns true only when an object actually left the hand and the item was
	spent, because InventoryService clears the slot on that answer.
]]
function ProjectileService:throw(
	player: Player,
	itemId: string?,
	origin: Vector3?,
	direction: Vector3?,
	power: number?
): boolean
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return false
	end

	local now = os.clock()
	local last = self._lastThrow[player]
	if last and now - last < THROW_INTERVAL then
		return false
	end

	local survivors = Registry.find("SurvivorService")
	if survivors then
		if not survivors:isAlive(player) or survivors:isIncapacitated(player) then
			return false
		end
	end

	local character = player.Character
	local head = character and character:FindFirstChild("Head")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return false
	end
	local muzzle = if head and head:IsA("BasePart") then head.Position else root.Position

	local inventory = Registry.find("InventoryService")
	if not inventory then
		return false
	end

	local held = inventory:getItem(player, Enums.Slot.Throwable)
	if typeof(held) ~= "string" or THROWABLE[held] == nil then
		return false
	end
	-- A caller that named an item has to have named the one being held. Nothing
	-- in the game can throw a molotov out of a bile jar's slot.
	if itemId ~= nil and itemId ~= held then
		return false
	end

	--[[ Out of tolerance is not cheating so much as latency, and dropping the
	     throw would cost the player an item they will swear they threw. The
	     claim is replaced with the server's own muzzle instead. ]]
	local from = muzzle
	if isFiniteVector(origin) then
		local claimed = origin :: Vector3
		if (claimed - muzzle).Magnitude <= VALIDATION.PositionTolerance then
			from = claimed
		end
	end

	local aim = root.CFrame.LookVector
	if isFiniteVector(direction) then
		local aimed = direction :: Vector3
		if aimed.Magnitude > EPSILON then
			aim = aimed.Unit
		end
	end

	local strength = 1
	if typeof(power) == "number" and power == power then
		strength = math.clamp(power, 0, 1)
	end

	-- The spend is the last thing that can fail. If it does, they were not
	-- holding it and nothing was created.
	if not inventory:consumeSlot(player, Enums.Slot.Throwable, held) then
		return false
	end

	self._lastThrow[player] = now
	self:_spawnProjectile(player, held, from + aim * THROW_FORWARD_OFFSET, aim, strength, character)
	return true
end

--[[ The thrown object itself. A pipe bomb bounces (it is a pipe, and rolling to
     the wrong place is part of the risk); a bottle does not survive its first
     contact, so it is left non-collidable and the swept raycast in _step is the
     only thing that stops it. ]]
function ProjectileService:_spawnProjectile(
	owner: Player,
	kind: string,
	position: Vector3,
	aim: Vector3,
	strength: number,
	character: Model?
)
	if #self._live >= MAX_LIVE_PROJECTILES then
		self:_retireProjectile(1)
	end

	local trove = Trove.new()
	local bounces = kind == THROWABLE.PipeBomb

	local body = Instance.new("Part")
	body.Name = "FL_Throwable_" .. kind
	body.Shape = Enum.PartType.Cylinder
	body.Size = Vector3.new(1.5, 0.5, 0.5)
	body.CFrame = CFrame.new(position)
	body.Anchored = false
	body.CanCollide = bounces
	body.CanQuery = false
	body.CanTouch = false
	body.CastShadow = false
	body.Locked = true
	body.CollisionGroup = "Debris"
	-- Elastic enough to bounce off a wall and rough enough to stop rolling; a
	-- pipe bomb that skates across the whole room is a pipe bomb nobody can aim.
	body.CustomPhysicalProperties = PhysicalProperties.new(2.5, 0.6, 0.35, 1, 1)

	local light: PointLight? = nil
	--[[ The pipe bomb's blinking head, kept so a supplied model can hide it. See
	     the dressing block below: the LIGHT is gameplay and stays either way, the
	     little neon ball it hangs on is only there because the grey-box needs
	     something to be. ]]
	local lampPart: BasePart? = nil

	if kind == THROWABLE.PipeBomb then
		body.Color = COLOR.BorderBright
		body.Material = Enum.Material.Metal

		local lamp = Instance.new("Part")
		lamp.Name = "Light"
		lamp.Shape = Enum.PartType.Ball
		lamp.Size = Vector3.new(0.4, 0.4, 0.4)
		lamp.Color = COLOR.Danger
		lamp.Material = Enum.Material.Neon
		lamp.CFrame = body.CFrame * CFrame.new(0.85, 0, 0)
		lamp.Anchored = false
		lamp.CanCollide = false
		lamp.CanQuery = false
		lamp.CanTouch = false
		lamp.CastShadow = false
		lamp.Locked = true
		lamp.Massless = true
		lamp.CollisionGroup = "Debris"
		lamp.Parent = body
		lampPart = lamp

		local weld = Instance.new("WeldConstraint")
		weld.Part0 = body
		weld.Part1 = lamp
		weld.Parent = body

		--[[ The light is not decoration. The map is dark by wave four and the
		     crowd running at the bomb is the payoff of the whole item; without
		     something lighting them, the best moment in the game happens in the
		     dark and nobody sees it. ]]
		local glow = Instance.new("PointLight")
		glow.Color = COLOR.Danger
		glow.Range = PIPE_LIGHT_RANGE
		glow.Brightness = PIPE_LIGHT_BRIGHTNESS
		glow.Shadows = false
		glow.Parent = lamp
		light = glow
	elseif kind == THROWABLE.Molotov then
		body.Color = COLOR.Warning
		body.Material = Enum.Material.Glass
	else
		body.Color = COLOR.Bile
		body.Material = Enum.Material.Neon
	end

	--[[
		The user's own model, when they have supplied one.

		Dressing only: the procedural part stays and keeps being the physics body,
		it is simply made invisible. That is deliberate rather than lazy — the
		bounce of a pipe bomb is tuned on this part's CustomPhysicalProperties and
		its collision shape, and a supplied model whose geometry decided how it
		skidded would make every user's bombs handle differently from every
		other's.

		Everything hung on it is massless and non-collidable for the same reason,
		and non-queryable because a bottle in flight that stops a bullet meant for
		the Common behind it is the worst kind of bug: invisible, and it costs a
		kill.

		Attached BEFORE the velocity below. Welding into an assembly after its
		velocity is assigned invites the engine to recompute the body around the
		new mass and lose the throw.
	]]
	local factory = Registry.find("PlaceholderFactory")
	local dressing = factory
		and typeof(factory.buildThrowableModel) == "function"
		and factory:buildThrowableModel(kind)
	if dressing then
		body.Transparency = 1
		--[[ The light survives, its neon ball does not: a real pipe bomb model
		     carries its own head, and a spare glowing sphere parked where the
		     grey-box's used to be would be floating beside it. ]]
		if lampPart then
			lampPart.Transparency = 1
		end
		dressing:PivotTo(body.CFrame)
		for _, part in dressing:GetDescendants() do
			if part:IsA("BasePart") then
				part.Massless = true
				part.CanCollide = false
				part.CanQuery = false
				part.CanTouch = false
				part.CollisionGroup = "Debris"
				local hold = Instance.new("WeldConstraint")
				hold.Part0 = body
				hold.Part1 = part
				hold.Parent = part
			end
		end
		dressing.Parent = body
	end

	body.Parent = self:_container()
	trove:add(body)

	body.AssemblyLinearVelocity = aim * (THROW_SPEED * strength) + Vector3.yAxis * THROW_LIFT
	body.AssemblyAngularVelocity = Vector3.new(
		random:NextNumber(-1, 1),
		random:NextNumber(-1, 1),
		random:NextNumber(-1, 1)
	) * THROW_TUMBLE

	-- Server-owned physics. A client that owned its own grenade could stop it in
	-- mid-air, and the blast position is a damage decision.
	pcall(function()
		body:SetNetworkOwner(nil)
	end)

	--[[ Built once per throw rather than per step: the ignore list never changes
	     for the life of the object, and a fresh RaycastParams sixty times a
	     second per projectile is exactly the allocation this codebase forbids. ]]
	local ignore: { Instance } = { body }
	if character then
		table.insert(ignore, character)
	end
	local params = RaycastUtil.excluding(ignore)

	local fuse = if kind == THROWABLE.PipeBomb
		then PIPE_FUSE
		elseif kind == THROWABLE.Molotov then MOLOTOV_FUSE
		else BILE_FUSE

	table.insert(self._live, {
		kind = kind,
		owner = owner,
		body = body,
		light = light,
		trove = trove,
		params = params,
		lastPosition = position,
		spawnedAt = os.clock(),
		endsAt = os.clock() + fuse,
		lureAt = 0,
		beepAt = 0,
		lit = false,
		-- A bottle ends on its first contact; a pipe bomb ends on its fuse and
		-- contact only decides where it rolls to next.
		shattersOnContact = not bounces,
	})
end

-- ════════════════════════════════════════════════════════════════════════════
--  The shared loop
-- ════════════════════════════════════════════════════════════════════════════

function ProjectileService:_step(deltaTime: number)
	local now = os.clock()

	local live = self._live
	for index = #live, 1, -1 do
		self:_stepProjectile(live[index], index, now)
	end

	self._zoneAccumulator += deltaTime
	if self._zoneAccumulator >= ZONE_INTERVAL then
		local elapsed = self._zoneAccumulator
		self._zoneAccumulator = 0
		self:_stepZones(now, elapsed)
	end
end

function ProjectileService:_stepProjectile(record: any, index: number, now: number)
	local body = record.body
	if not body or not body.Parent then
		self:_retireProjectile(index)
		return
	end

	local position = body.Position

	if record.kind == THROWABLE.PipeBomb then
		self:_stepPipeBomb(record, position, now)
	end

	--[[ Contact is a swept ray between steps, not a .Touched connection. Touched
	     fires on a physics thread, misses fast movers, and would be one
	     connection per object for something the loop can answer exactly. ]]
	if record.shattersOnContact then
		local delta = position - record.lastPosition
		local travelled = delta.Magnitude
		if travelled > EPSILON then
			local result = Workspace:Raycast(record.lastPosition, delta, record.params)
			if result then
				self:_detonate(record, index, result.Position + result.Normal * 0.2)
				return
			end
		end
	end

	record.lastPosition = position

	if now >= record.endsAt or now - record.spawnedAt >= MAX_FLIGHT_TIME then
		self:_detonate(record, index, position)
	end
end

--[[ The beep, the blink and the gathering. Every one of them is a readout of the
     same number — how long is left — and they are what turn a thrown object into
     a countdown the whole team can hear. ]]
function ProjectileService:_stepPipeBomb(record: any, position: Vector3, now: number)
	local remaining = math.max(record.endsAt - now, 0)

	if now >= record.lureAt then
		record.lureAt = now + PIPE_LURE_REFRESH
		local infected = Registry.find("InfectedService")
		if infected then
			--[[ Held only until the bomb goes off. A lure that outlived the blast
			     would leave the survivors of it standing at an empty spot
			     wondering why they walked there. ]]
			infected:lure(position, PIPE_LURE_RADIUS, remaining + PIPE_LURE_REFRESH)
		end
	end

	if now >= record.beepAt then
		local alpha = 1 - math.clamp(remaining / PIPE_FUSE, 0, 1)
		record.beepAt = now + (PIPE_BEEP_SLOW + (PIPE_BEEP_FAST - PIPE_BEEP_SLOW) * alpha)
		record.lit = not record.lit
		playAt(SOUND.Beep, position)

		local light = record.light
		if light then
			light.Brightness = if record.lit then PIPE_LIGHT_BRIGHTNESS * 2.4 else PIPE_LIGHT_BRIGHTNESS
		end
	end
end

--[[ Whatever a projectile turns into when it stops being one. ]]
function ProjectileService:_detonate(record: any, index: number, position: Vector3)
	local kind = record.kind
	local owner = record.owner

	if kind == THROWABLE.PipeBomb then
		self:_explode(owner, position)
	elseif kind == THROWABLE.Molotov then
		self:_spawnFirePool(owner, position, record.body)
	else
		self:_spawnBileZone(owner, position, record.body)
	end

	self:_retireProjectile(index)
end

function ProjectileService:_retireProjectile(index: number)
	local record = self._live[index]
	if not record then
		return
	end
	table.remove(self._live, index)
	record.trove:destroy()
end

-- ════════════════════════════════════════════════════════════════════════════
--  Pipe bomb: the blast
-- ════════════════════════════════════════════════════════════════════════════

function ProjectileService:_explode(owner: Player?, position: Vector3)
	self:detonate(owner, position, PIPE_BLAST_RADIUS, PIPE_BLAST_DAMAGE, THROWABLE.PipeBomb)
end

--[[
	An explosion, anywhere, from anything.

	The pipe bomb was the only thing in the game that exploded, so its blast and
	its numbers were the same eighty lines. The RPG-7 needs the same blast with
	different numbers, and the wrong way to get it is a second copy that drifts —
	the camera falloff, the atmosphere flash and the gib rule are the parts that
	make an explosion read as one, and they are not per-weapon decisions.

	So the numbers are arguments and everything else is shared. `_explode` is now
	one line calling this with the pipe bomb's radius and damage.

	The SHAKE is deliberately not parameterised. A blast twenty studs away and one
	eighty studs away already differ by the falloff below; making a big explosion
	also shake harder per stud would mean the two weapons taught the player
	different things about the same distance.
]]
function ProjectileService:detonate(
	owner: Player?,
	position: Vector3,
	radius: number,
	damage: number,
	weaponId: string
)
	if typeof(position) ~= "Vector3" or typeof(radius) ~= "number" or typeof(damage) ~= "number" then
		return
	end
	if radius <= 0 or damage <= 0 then
		return
	end

	local damageService = Registry.find("DamageService")
	if damageService then
		--[[ Straight through the funnel, which is what makes GoreConfig's
		     ExplosiveAlwaysGibs true here: everything an explosion kills comes
		     apart, and the crowd it just gathered comes apart all at once. ]]
		damageService:applyExplosion(
			position,
			radius,
			damage,
			Types.newDamageContext({
				attacker = owner,
				weaponId = weaponId,
				damageType = Enums.DamageType.Explosive,
				region = Enums.HitRegion.Torso,
				hitPosition = position,
				hitNormal = Vector3.yAxis,
				sourcePosition = position,
				direction = Vector3.yAxis,
			})
		)
	end

	self:_blastEffect(position)
	playAt(SOUND.Explosion, position)

	--[[ Scaled per player rather than fired in range: a blast twenty studs away
	     and one eighty studs away are different events, and a flat shake for
	     both makes distance stop meaning anything. ]]
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if not root or not root:IsA("BasePart") then
			continue
		end
		local distance = (root.Position - position).Magnitude
		if distance > PIPE_SHAKE_RADIUS then
			continue
		end
		local falloff = 1 - distance / PIPE_SHAKE_RADIUS
		local away = root.Position - position
		local push = if away.Magnitude > EPSILON then away.Unit else Vector3.yAxis
		Remotes.Event.CameraImpulse:FireClient(player, {
			position = push * (PIPE_SHAKE_POSITION * falloff),
			rotation = Vector3.new(
				random:NextNumber(-1, 1),
				random:NextNumber(-1, 1),
				random:NextNumber(-1, 1)
			) * (PIPE_SHAKE_ROTATION * falloff),
			decay = PIPE_SHAKE_DECAY,
		})
	end

	-- The game is called Fading Light; an explosion is one of the few things
	-- that gets to argue with that, briefly.
	local atmosphere = Registry.find("AtmosphereService")
	if atmosphere and typeof(atmosphere.flash) == "function" then
		atmosphere:flash(PIPE_ATMOSPHERE_FLASH, 1)
	end
end

--[[ The visual. Tweened rather than stepped: the engine can interpolate a size
     and a transparency without this file spending a frame on it, and an
     explosion is over before the next zone tick would even have run. ]]
function ProjectileService:_blastEffect(position: Vector3)
	local flash = Instance.new("Part")
	flash.Name = "FL_Blast"
	flash.Shape = Enum.PartType.Ball
	flash.Size = Vector3.new(3, 3, 3)
	flash.Color = COLOR.AccentBright
	flash.Material = Enum.Material.Neon
	flash.Position = position
	decorate(flash)
	flash.Parent = self:_container()

	local glow = Instance.new("PointLight")
	glow.Color = COLOR.AccentBright
	glow.Range = PIPE_BLAST_RADIUS
	glow.Brightness = 8
	glow.Shadows = false
	glow.Parent = flash

	local emitter = Instance.new("ParticleEmitter")
	emitter.Texture = SMOKE_TEXTURE
	emitter.Color = ColorSequence.new(COLOR.AccentBright, GoreConfig.Blood.DarkColor)
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 4),
		NumberSequenceKeypoint.new(1, 14),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.25),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Lifetime = NumberRange.new(0.7, 1.5)
	emitter.Speed = NumberRange.new(24, 60)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Rate = 0
	emitter.Parent = flash

	local sparks = Instance.new("ParticleEmitter")
	sparks.Texture = SPARK_TEXTURE
	sparks.Color = ColorSequence.new(COLOR.AccentBright, COLOR.Danger)
	sparks.Size = NumberSequence.new(0.9, 0)
	sparks.Lifetime = NumberRange.new(0.3, 0.8)
	sparks.Speed = NumberRange.new(50, 110)
	sparks.SpreadAngle = Vector2.new(180, 180)
	sparks.Rate = 0
	sparks.Parent = flash

	emitter:Emit(38)
	sparks:Emit(46)

	local info = TweenInfo.new(PIPE_FLASH_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(flash, info, {
		Size = Vector3.new(1, 1, 1) * (PIPE_BLAST_RADIUS * 1.2),
		Transparency = 1,
	}):Play()
	TweenService:Create(glow, info, { Brightness = 0 }):Play()

	-- Outlives the flash by the particle lifetime so the smoke is not cut off
	-- with the ball that threw it.
	Debris:AddItem(flash, PIPE_FLASH_TIME + 2)
end

-- ════════════════════════════════════════════════════════════════════════════
--  Molotov: the fire pool
-- ════════════════════════════════════════════════════════════════════════════

function ProjectileService:_spawnFirePool(owner: Player?, position: Vector3, body: BasePart?)
	if #self._fires >= MAX_FIRE_POOLS then
		self:_retireFire(1)
	end

	local ignore: { Instance } = if body then { body } else {}
	local origin = groundedAt(position, ignore) + Vector3.new(0, 0.4, 0)

	local trove = Trove.new()
	local anchor = Instance.new("Part")
	anchor.Name = "FL_FirePool"
	anchor.Size = Vector3.new(1, 1, 1)
	anchor.Transparency = 1
	anchor.Position = origin
	decorate(anchor)
	anchor.Parent = self:_container()
	trove:add(anchor)

	local light = Instance.new("PointLight")
	light.Color = FIRE_COLOR
	light.Range = FIRE_LIGHT_RANGE
	light.Brightness = FIRE_LIGHT_BRIGHTNESS
	light.Shadows = false
	light.Parent = anchor

	--[[ The pool is a ring of cells laid out once and switched on as the fire
	     reaches them, rather than parts that move or grow. Spreading is then a
	     handful of boolean writes a second instead of a CFrame write per cell
	     per frame, and it reads exactly the same. ]]
	local cells = table.create(FIRE_CELLS)
	for index = 1, FIRE_CELLS do
		local alpha = if index == 1 then 0 else (index - 1) / (FIRE_CELLS - 1)
		local spread = FIRE_RADIUS_START + (FIRE_RADIUS_MAX - FIRE_RADIUS_START) * alpha
		local angle = random:NextNumber(0, math.pi * 2)
		local reach = if index == 1 then 0 else spread * random:NextNumber(0.55, 1)
		local offset = Vector3.new(math.cos(angle) * reach, 0, math.sin(angle) * reach)

		local cell = Instance.new("Part")
		cell.Name = "Cell"
		cell.Size = Vector3.new(2, 1, 2)
		cell.Transparency = 1
		cell.Position = groundedAt(origin + offset, ignore) + Vector3.new(0, 0.5, 0)
		decorate(cell)
		cell.Parent = anchor

		local fire = Instance.new("Fire")
		fire.Color = FIRE_COLOR
		fire.SecondaryColor = FIRE_SECONDARY_COLOR
		fire.Size = FIRE_CELL_SIZE
		fire.Heat = FIRE_CELL_HEAT
		fire.Enabled = index == 1
		fire.Parent = cell

		cells[index] = { fire = fire, spread = if index == 1 then 0 else reach }
	end

	playAt(SOUND.Shatter, origin)

	table.insert(self._fires, {
		owner = owner,
		origin = origin,
		trove = trove,
		light = light,
		cells = cells,
		startedAt = os.clock(),
		endsAt = os.clock() + FIRE_LIFETIME,
		radius = FIRE_RADIUS_START,
	})
end

function ProjectileService:_stepFire(record: any, index: number, now: number, elapsed: number, bodies: any)
	if now >= record.endsAt then
		self:_retireFire(index)
		return
	end

	local age = now - record.startedAt
	local alpha = math.clamp(age / FIRE_SPREAD_TIME, 0, 1)
	record.radius = FIRE_RADIUS_START + (FIRE_RADIUS_MAX - FIRE_RADIUS_START) * alpha

	for _, cell in record.cells do
		if not cell.fire.Enabled and cell.spread <= record.radius then
			cell.fire.Enabled = true
		end
	end

	--[[ The last seconds are a burn-down, not a switch. A pool that vanishes on
	     a frame boundary tells the team the ground is safe before it looks it,
	     which is how somebody walks into the last two seconds of a molotov. ]]
	local remaining = record.endsAt - now
	if remaining <= FIRE_FADE_TIME then
		local fade = math.clamp(remaining / FIRE_FADE_TIME, 0, 1)
		record.light.Brightness = FIRE_LIGHT_BRIGHTNESS * fade
		for _, cell in record.cells do
			cell.fire.Size = FIRE_CELL_SIZE * fade
		end
	end

	local infected = Registry.find("InfectedService")
	if infected then
		for _, model in bodies.infected do
			if withinColumn(record.origin, bodies.positions[model], record.radius, FIRE_HEIGHT) then
				--[[ ignite, never damage. InfectedService owns burning: it
				     applies the per-kind burnDamagePerSecond, keeps the flame on
				     the body, and credits the kill to whoever lit it. ]]
				infected:ignite(model, record.owner)
			end
		end
	end

	local damage = Registry.find("DamageService")
	if damage then
		for _, entry in bodies.survivors do
			if not withinColumn(record.origin, entry.position, record.radius, FIRE_HEIGHT) then
				continue
			end
			damage:applyDamage(
				entry.character,
				FIRE_SURVIVOR_DPS * elapsed,
				Types.newDamageContext({
					attacker = record.owner,
					weaponId = THROWABLE.Molotov,
					damageType = Enums.DamageType.Fire,
					region = Enums.HitRegion.Torso,
					hitPosition = entry.position,
					hitNormal = Vector3.yAxis,
					--[[ The pool, not the person who threw it. The arrow has to
					     point at the thing you can step out of. ]]
					sourcePosition = record.origin,
					direction = Vector3.yAxis,
				})
			)
		end
	end
end

function ProjectileService:_retireFire(index: number)
	local record = self._fires[index]
	if not record then
		return
	end
	table.remove(self._fires, index)
	record.trove:destroy()
end

-- ════════════════════════════════════════════════════════════════════════════
--  Bile jar: the gathering point
-- ════════════════════════════════════════════════════════════════════════════

function ProjectileService:_spawnBileZone(owner: Player?, position: Vector3, body: BasePart?)
	if #self._biles >= MAX_BILE_ZONES then
		self:_retireBile(1)
	end

	local ignore: { Instance } = if body then { body } else {}
	local origin = groundedAt(position, ignore) + Vector3.new(0, 0.2, 0)

	local trove = Trove.new()
	local anchor = Instance.new("Part")
	anchor.Name = "FL_BileZone"
	anchor.Shape = Enum.PartType.Cylinder
	anchor.Size = Vector3.new(0.3, BILE_POOL_SIZE, BILE_POOL_SIZE)
	-- Cylinders point down their X axis, so a puddle is one laid on its side.
	anchor.CFrame = CFrame.new(origin) * CFrame.Angles(0, 0, math.rad(90))
	anchor.Color = COLOR.Bile
	anchor.Material = Enum.Material.Neon
	anchor.Transparency = 0.35
	decorate(anchor)
	anchor.Parent = self:_container()
	trove:add(anchor)

	for _ = 1, BILE_CELLS do
		local angle = random:NextNumber(0, math.pi * 2)
		local reach = random:NextNumber(0, BILE_SPLASH_RADIUS * 0.8)
		local splat = Instance.new("Part")
		splat.Name = "Splat"
		splat.Shape = Enum.PartType.Cylinder
		local size = random:NextNumber(2.5, 6)
		splat.Size = Vector3.new(0.2, size, size)
		splat.CFrame = CFrame.new(
			groundedAt(origin + Vector3.new(math.cos(angle) * reach, 0, math.sin(angle) * reach), ignore)
				+ Vector3.new(0, 0.15, 0)
		) * CFrame.Angles(0, 0, math.rad(90))
		splat.Color = COLOR.Bile
		splat.Material = Enum.Material.Neon
		splat.Transparency = 0.45
		decorate(splat)
		splat.Parent = anchor
	end

	local mist = Instance.new("ParticleEmitter")
	mist.Texture = SMOKE_TEXTURE
	mist.Color = ColorSequence.new(COLOR.Bile)
	mist.Size = NumberSequence.new(6)
	mist.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.6),
		NumberSequenceKeypoint.new(1, 1),
	})
	mist.Lifetime = NumberRange.new(1.5, 3)
	mist.Rate = BILE_MIST_RATE
	mist.Speed = NumberRange.new(1, 4)
	mist.SpreadAngle = Vector2.new(60, 60)
	mist.Parent = anchor

	playAt(SOUND.Shatter, origin)
	-- The horde's own alert call, at the splash rather than at a survivor. It is
	-- the tell: something over there just became the most interesting thing.
	playAt(SOUND.HordeCall, origin)

	table.insert(self._biles, {
		owner = owner,
		origin = origin,
		trove = trove,
		anchor = anchor,
		mist = mist,
		startedAt = os.clock(),
		endsAt = os.clock() + BILE_DURATION,
		lureAt = 0,
		coated = {} :: { [Player]: number },
	})
end

function ProjectileService:_stepBile(record: any, index: number, now: number, bodies: any)
	if now >= record.endsAt then
		self:_retireBile(index)
		return
	end

	local remaining = record.endsAt - now
	local infected = Registry.find("InfectedService")

	if infected and now >= record.lureAt then
		record.lureAt = now + BILE_LURE_REFRESH
		--[[ Re-issued for the same reason a pipe bomb's is: commons that spawn
		     into the wave after the jar broke have to come running too. The hold
		     shrinks with the splash, so the crowd releases as it dries. ]]
		infected:lure(record.origin, BILE_LURE_RADIUS, remaining)
	end

	if remaining <= BILE_FADE_TIME then
		local fade = math.clamp(remaining / BILE_FADE_TIME, 0, 1)
		record.mist.Rate = BILE_MIST_RATE * fade
		record.anchor.Transparency = 1 - 0.65 * fade
	end

	for _, entry in bodies.survivors do
		if not withinColumn(record.origin, entry.position, BILE_SPLASH_RADIUS, BILE_HEIGHT) then
			continue
		end

		--[[ Coated once per zone. Re-firing the screen effect every quarter
		     second would reset the fade forever and the player would never see
		     out of it again. ]]
		if record.coated[entry.player] then
			continue
		end
		record.coated[entry.player] = now

		Remotes.Event.ScreenEffect:FireClient(entry.player, {
			effect = "Bile",
			duration = GoreConfig.ScreenBlood.BoomerBileFadeTime,
			intensity = 1,
		})

		--[[ And the actual mechanic: a coated survivor becomes the loudest thing
		     in the room. reportNoise is the hook InfectedConfig documents for
		     exactly this — every listener applies its own hearing range, so who
		     comes running is the config's decision and not this file's. ]]
		if infected then
			infected:reportNoise(entry.character, BILE_NOISE_WEIGHT, remaining)
		end
	end
end

function ProjectileService:_retireBile(index: number)
	local record = self._biles[index]
	if not record then
		return
	end
	table.remove(self._biles, index)
	record.trove:destroy()
end

-- ════════════════════════════════════════════════════════════════════════════
--  Area effects, four times a second, off one list of the living
-- ════════════════════════════════════════════════════════════════════════════

--[[ Every pool and every zone tests against the SAME snapshot. Asking
     InfectedService for the horde once per pool per tick would be four walks of
     forty-six bodies where one will do, and the answer cannot change in between
     because nothing here yields. ]]
function ProjectileService:_collectBodies(): any
	local snapshot = {
		infected = {},
		positions = {},
		survivors = {},
	}

	if #self._fires > 0 then
		local infected = Registry.find("InfectedService")
		if infected then
			for _, model in infected:getAlive() do
				local root = RigUtil.getRoot(model)
				if
					root
					and RigUtil.isAlive(model)
					and model:GetAttribute(Attributes.Infected.Burning) ~= true
				then
					-- Already burning bodies are skipped here rather than inside
					-- ignite, so a full horde standing in a pool is one table
					-- lookup each instead of a service call each.
					table.insert(snapshot.infected, model)
					snapshot.positions[model] = root.Position
				end
			end
		end
	end

	local survivors = Registry.find("SurvivorService")
	if survivors then
		for _, player in survivors:getAliveSurvivors() do
			local character = player.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if root and root:IsA("BasePart") then
				table.insert(snapshot.survivors, {
					player = player,
					character = character,
					position = root.Position,
				})
			end
		end
	end

	return snapshot
end

function ProjectileService:_stepZones(now: number, elapsed: number)
	if #self._fires == 0 and #self._biles == 0 then
		return
	end

	local bodies = self:_collectBodies()

	for index = #self._fires, 1, -1 do
		self:_stepFire(self._fires[index], index, now, elapsed, bodies)
	end
	for index = #self._biles, 1, -1 do
		self:_stepBile(self._biles[index], index, now, bodies)
	end
end

-- ════════════════════════════════════════════════════════════════════════════
--  Queries and teardown
-- ════════════════════════════════════════════════════════════════════════════

--[[ True while any fire pool covers a point. Anything that wants to keep an AI
     out of a molotov — or to decide a spawn point is a bad one — asks here
     rather than reaching into the pool list. ]]
function ProjectileService:isOnFire(position: Vector3): boolean
	if typeof(position) ~= "Vector3" then
		return false
	end
	for _, record in self._fires do
		if withinColumn(record.origin, position, record.radius, FIRE_HEIGHT) then
			return true
		end
	end
	return false
end

--[[ For the debug overlay and for a round teardown that wants to know whether
     anything is still burning. ]]
function ProjectileService:getActiveCounts(): { projectiles: number, fires: number, bile: number }
	return {
		projectiles = #self._live,
		fires = #self._fires,
		bile = #self._biles,
	}
end

--[[ Wipes everything in flight and everything burning, with no detonation. For
     a round reset: the next round must not begin inside the last one's fire. ]]
function ProjectileService:clearAll()
	for index = #self._live, 1, -1 do
		self:_retireProjectile(index)
	end
	for index = #self._fires, 1, -1 do
		self:_retireFire(index)
	end
	for index = #self._biles, 1, -1 do
		self:_retireBile(index)
	end
	table.clear(self._lastThrow)
end

function ProjectileService:destroy()
	self:clearAll()
	self._trove:destroy()
end

Registry.register("ProjectileService", ProjectileService)

return ProjectileService
