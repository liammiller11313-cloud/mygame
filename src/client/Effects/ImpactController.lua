--!nonstrict
--[[
	ImpactController — the quarter of a second between the trigger and the wall.

	Three jobs, all of them pure decoration and all of them the difference
	between a hitscan weapon that feels like a laser pointer and one that feels
	like a gun:

	  TRACERS       a thin hot line from the muzzle to wherever the round stopped
	  SURFACE HITS  sparks, dust, debris and a hole, chosen by what was struck
	  REMOTE FIRE   a teammate's muzzle flash, so you can see who is engaging

	── WHY MATERIALS MATTER MORE THAN THEY LOOK LIKE THEY SHOULD ───────────────
	A firefight only feels like it is happening in a PLACE if the place answers
	back differently. Concrete coughs dust, metal throws sparks that bounce and
	die, wood spits splinters, glass shatters bright and leaves almost nothing,
	water jumps straight up the normal and leaves no mark at all. The MATERIALS
	table below is the whole of that idea, and it is the single highest-value
	thing in this file. The Roblox material -> class mapping mirrors
	BallisticsService's MATERIAL_SOUND exactly so that what you see and what you
	hear never disagree about what you just shot.

	── AUDIO IS NOT MINE ───────────────────────────────────────────────────────
	BallisticsService already plays AudioConfig.Impact[class] through
	AudioService at the hit position, and MeleeService does the same for a swing
	that lands on geometry. Those are world sounds; every client in range hears
	them. Playing the same definition again here would double every impact in
	the game, so this controller is deliberately silent. If per-listener impact
	audio is ever wanted (it would dodge AudioService's global voice cap), the
	server-side call is the one to delete, not this comment.

	── PERFORMANCE ─────────────────────────────────────────────────────────────
	An SMG at 900rpm is fifteen tracers a second PER SHOOTER, and a shotgun is
	several impacts from one trigger pull. Nothing here allocates per shot that
	it can avoid:
	  * every visual comes out of a fixed-size ring buffer, so "cap concurrent
	    effects and drop the oldest" is not a check, it is the data structure
	  * ParticleEmitters are created once, per pooled node, and re-aimed rather
	    than rebuilt; the ColorSequences and NumberSequences they need are built
	    once at module load and assigned by reference
	  * an impact node whose material class has not changed skips its property
	    writes entirely, which is the common case when a firefight settles into
	    one room
	  * ONE RenderStepped connection drives every fade in the file

	Every pooled part is CanQuery = false. A spent tracer or a bullet hole that
	answered a raycast would eat the next round fired through the same space,
	and the player would never find out why their shot missed.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Enums = require(Shared.Enums)
local GoreConfig = require(Shared.Config.GoreConfig)
local Registry = require(Shared.Util.Registry)
local Remotes = require(Shared.Net.Remotes)
local Trove = require(Shared.Util.Trove)
local WeaponConfig = require(Shared.Config.WeaponConfig)

local DAMAGE = Enums.DamageType

--[[ Effects past here are never drawn. The same distance the server uses to
     decide whether to send them at all (GoreConfig.Budget.CullDistance), so a
     client that receives an event from just inside the radius and then turns
     around does not keep paying for it. ]]
local CULL_DISTANCE = GoreConfig.Budget.CullDistance
local CULL_DISTANCE_SQUARED = CULL_DISTANCE * CULL_DISTANCE

--[[ A tracer is a suggestion of a round in flight, not a projectile. Long
     enough to register in peripheral vision, short enough that eight of them
     never turn the screen into a light show. No config owns this: WeaponConfig
     carries the tracer's width and colour, its lifetime is presentation. ]]
local TRACER_FADE = 0.05
local TRACER_TRANSPARENCY = 0.15
local TRACER_POOL = 32

-- Below this a tracer is a dot on the muzzle, and CFrame.lookAt has nothing to
-- aim at. Point-blank shots get the muzzle flash and the impact instead.
local MIN_TRACER_LENGTH = 1.5

-- Impact nodes hold their particles for the longest lifetime in MATERIALS plus
-- slack. Twenty-four is comfortably more than a four-player firefight produces
-- inside that window, so a node is never re-aimed while its last burst is
-- still bright.
local IMPACT_POOL = 24

--[[ Bullet holes. GoreConfig owns blood decal lifetimes; nothing owns these,
     because a hole in a wall is not gore. They outlive the fight that made
     them by design — a room you have already fought through should look like
     it. ]]
local HOLE_POOL = 56
local HOLE_LIFETIME = 26
local HOLE_FADE = 5
local HOLE_THICKNESS = 0.06
local HOLE_OFFSET = 0.02 -- lifted off the surface so it cannot z-fight

-- A remote muzzle flash is one frame of light in somebody else's hands. Longer
-- than this and a teammate firing an SMG looks like they are holding a torch.
local FLASH_TIME = 0.05
local FLASH_POOL = 10
local FLASH_LIGHT_RANGE = 14
local FLASH_LIGHT_BRIGHTNESS = 3.2

--[[ How much of an effect a given kind of damage earns. A shotgun lands up to
     four impact events from one trigger pull and they must add up to one blast
     rather than four rifle hits; an explosion is allowed to be enormous. ]]
local DAMAGE_SCALE: { [string]: number } = {
	[DAMAGE.Bullet] = 1.0,
	[DAMAGE.Pellet] = 0.55,
	[DAMAGE.Melee] = 0.7,
	[DAMAGE.Explosive] = 1.7,
}
local DEFAULT_DAMAGE_SCALE = 1.0

-- Engine textures, not marketplace assets: these ship with the client and are
-- always available, unlike everything in AudioConfig.
local SPARK_TEXTURE = "rbxasset://textures/particles/sparkles_main.dds"
local DUST_TEXTURE = "rbxasset://textures/particles/smoke_main.dds"

local random = Random.new()

-- ── material classes ────────────────────────────────────────────────────────

local function solid(color: Color3): ColorSequence
	return ColorSequence.new(color)
end

local function twoTone(from: Color3, to: Color3): ColorSequence
	return ColorSequence.new({
		ColorSequenceKeypoint.new(0, from),
		ColorSequenceKeypoint.new(1, to),
	})
end

--[[ Particles start at their size and shrink to nothing rather than popping
     out of existence, which is most of what separates a puff of dust from a
     handful of confetti. ]]
local function shrink(start: number, peak: number): NumberSequence
	return NumberSequence.new({
		NumberSequenceKeypoint.new(0, start),
		NumberSequenceKeypoint.new(0.35, peak),
		NumberSequenceKeypoint.new(1, 0),
	})
end

local function fadeOut(start: number): NumberSequence
	return NumberSequence.new({
		NumberSequenceKeypoint.new(0, start),
		NumberSequenceKeypoint.new(0.7, start),
		NumberSequenceKeypoint.new(1, 1),
	})
end

--[[
	One entry per surface class. `spark` is the fast, bright, gravity-bound
	layer that reads at the instant of the hit; `dust` is the slow cloud that
	tells you what the wall is made of half a second later.

	The colours here are the only invented numbers in this file. No config
	describes what concrete dust looks like, because no gameplay decision
	depends on it — if one ever does, this table is the place it moves from.
]]
local GRAVITY_PULL = Vector3.new(0, -84, 0)
local NO_PULL = Vector3.zero

local MATERIALS = {
	Concrete = {
		sparkCount = 4,
		sparkColor = twoTone(Color3.fromRGB(255, 236, 196), Color3.fromRGB(150, 142, 128)),
		sparkSize = shrink(0.09, 0.06),
		sparkSpeed = NumberRange.new(9, 20),
		sparkLifetime = NumberRange.new(0.14, 0.3),
		sparkLight = 0.6,
		sparkSpread = 42,
		sparkDrag = 3,
		sparkAcceleration = GRAVITY_PULL,

		dustCount = 11,
		dustColor = twoTone(Color3.fromRGB(184, 178, 166), Color3.fromRGB(122, 117, 108)),
		dustSize = shrink(0.5, 1.5),
		dustSpeed = NumberRange.new(2.5, 7),
		dustLifetime = NumberRange.new(0.35, 0.75),
		dustSpread = 62,
		dustTransparency = fadeOut(0.35),

		holeColor = Color3.fromRGB(52, 49, 45),
		holeSize = 0.42,
	},

	Metal = {
		sparkCount = 16,
		sparkColor = twoTone(Color3.fromRGB(255, 246, 214), Color3.fromRGB(226, 108, 24)),
		sparkSize = shrink(0.1, 0.05),
		sparkSpeed = NumberRange.new(20, 46),
		sparkLifetime = NumberRange.new(0.16, 0.42),
		sparkLight = 1,
		sparkSpread = 54,
		sparkDrag = 1.5,
		sparkAcceleration = GRAVITY_PULL,

		dustCount = 3,
		dustColor = solid(Color3.fromRGB(96, 92, 88)),
		dustSize = shrink(0.35, 0.9),
		dustSpeed = NumberRange.new(2, 5),
		dustLifetime = NumberRange.new(0.25, 0.5),
		dustSpread = 50,
		dustTransparency = fadeOut(0.55),

		holeColor = Color3.fromRGB(34, 32, 31),
		holeSize = 0.3,
	},

	Wood = {
		-- Splinters, not sparks: slower, no light, and they tumble out flat.
		sparkCount = 9,
		sparkColor = twoTone(Color3.fromRGB(176, 132, 78), Color3.fromRGB(96, 66, 36)),
		sparkSize = shrink(0.16, 0.1),
		sparkSpeed = NumberRange.new(7, 17),
		sparkLifetime = NumberRange.new(0.3, 0.65),
		sparkLight = 0,
		sparkSpread = 46,
		sparkDrag = 2,
		sparkAcceleration = GRAVITY_PULL,

		dustCount = 6,
		dustColor = twoTone(Color3.fromRGB(168, 136, 94), Color3.fromRGB(108, 86, 58)),
		dustSize = shrink(0.4, 1.1),
		dustSpeed = NumberRange.new(2, 6),
		dustLifetime = NumberRange.new(0.3, 0.6),
		dustSpread = 58,
		dustTransparency = fadeOut(0.4),

		holeColor = Color3.fromRGB(38, 27, 18),
		holeSize = 0.38,
	},

	Glass = {
		-- Glass is all shard and no cloud, and it barely marks.
		sparkCount = 18,
		sparkColor = twoTone(Color3.fromRGB(236, 250, 255), Color3.fromRGB(158, 198, 214)),
		sparkSize = shrink(0.13, 0.07),
		sparkSpeed = NumberRange.new(14, 34),
		sparkLifetime = NumberRange.new(0.3, 0.7),
		sparkLight = 0.75,
		sparkSpread = 70,
		sparkDrag = 1,
		sparkAcceleration = GRAVITY_PULL,

		dustCount = 2,
		dustColor = solid(Color3.fromRGB(214, 230, 236)),
		dustSize = shrink(0.25, 0.6),
		dustSpeed = NumberRange.new(1.5, 4),
		dustLifetime = NumberRange.new(0.2, 0.4),
		dustSpread = 40,
		dustTransparency = fadeOut(0.7),

		holeColor = Color3.fromRGB(206, 224, 232),
		holeSize = 0.5,
	},

	Water = {
		-- Straight up the normal, and it leaves nothing behind.
		sparkCount = 13,
		sparkColor = twoTone(Color3.fromRGB(226, 244, 250), Color3.fromRGB(140, 176, 194)),
		sparkSize = shrink(0.14, 0.09),
		sparkSpeed = NumberRange.new(10, 24),
		sparkLifetime = NumberRange.new(0.25, 0.55),
		sparkLight = 0.35,
		sparkSpread = 26,
		sparkDrag = 2.5,
		sparkAcceleration = GRAVITY_PULL,

		dustCount = 6,
		dustColor = solid(Color3.fromRGB(206, 226, 234)),
		dustSize = shrink(0.45, 1.2),
		dustSpeed = NumberRange.new(2, 6),
		dustLifetime = NumberRange.new(0.3, 0.6),
		dustSpread = 44,
		dustTransparency = fadeOut(0.5),

		holeColor = nil,
		holeSize = 0,
	},

	Dirt = {
		sparkCount = 6,
		sparkColor = twoTone(Color3.fromRGB(122, 96, 64), Color3.fromRGB(72, 56, 38)),
		sparkSize = shrink(0.2, 0.12),
		sparkSpeed = NumberRange.new(6, 15),
		sparkLifetime = NumberRange.new(0.3, 0.6),
		sparkLight = 0,
		sparkSpread = 40,
		sparkDrag = 3,
		sparkAcceleration = GRAVITY_PULL,

		dustCount = 13,
		dustColor = twoTone(Color3.fromRGB(140, 116, 84), Color3.fromRGB(84, 68, 48)),
		dustSize = shrink(0.55, 1.7),
		dustSpeed = NumberRange.new(2, 6),
		dustLifetime = NumberRange.new(0.4, 0.85),
		dustSpread = 66,
		dustTransparency = fadeOut(0.3),

		holeColor = Color3.fromRGB(42, 33, 24),
		holeSize = 0.55,
	},
}

--[[ Roblox material -> class. Mirrors BallisticsService's MATERIAL_SOUND so the
     sparks and the sound always agree on what was hit. If a material is added
     there, add it here; the two tables are one idea in two places because
     Shared owns no material taxonomy to put it in. ]]
local MATERIAL_CLASS: { [Enum.Material]: string } = {
	[Enum.Material.Concrete] = "Concrete",
	[Enum.Material.Brick] = "Concrete",
	[Enum.Material.Cobblestone] = "Concrete",
	[Enum.Material.Rock] = "Concrete",
	[Enum.Material.Slate] = "Concrete",
	[Enum.Material.Pavement] = "Concrete",
	[Enum.Material.Limestone] = "Concrete",
	[Enum.Material.Metal] = "Metal",
	[Enum.Material.DiamondPlate] = "Metal",
	[Enum.Material.CorrodedMetal] = "Metal",
	[Enum.Material.Foil] = "Metal",
	[Enum.Material.Wood] = "Wood",
	[Enum.Material.WoodPlanks] = "Wood",
	[Enum.Material.Glass] = "Glass",
	[Enum.Material.Ice] = "Glass",
	[Enum.Material.Water] = "Water",
	[Enum.Material.Grass] = "Dirt",
	[Enum.Material.LeafyGrass] = "Dirt",
	[Enum.Material.Ground] = "Dirt",
	[Enum.Material.Mud] = "Dirt",
	[Enum.Material.Sand] = "Dirt",
	[Enum.Material.Snow] = "Dirt",
}
local DEFAULT_CLASS = "Concrete"

-- ── state ───────────────────────────────────────────────────────────────────

local ImpactController = {}

local trove = Trove.new()

local folder: Folder
local enabled = true

type TracerSlot = { part: BasePart, until_: number }
type ImpactSlot = { part: BasePart, spark: ParticleEmitter, dust: ParticleEmitter, class: string? }
type HoleSlot = { part: BasePart, bornAt: number, transparency: number }
type FlashSlot = { part: BasePart, light: PointLight, until_: number }

local tracers: { TracerSlot } = table.create(TRACER_POOL)
local impacts: { ImpactSlot } = table.create(IMPACT_POOL)
local holes: { HoleSlot } = table.create(HOLE_POOL)
local flashes: { FlashSlot } = table.create(FLASH_POOL)

local tracerCursor = 0
local impactCursor = 0
local holeCursor = 0
local flashCursor = 0

-- Cached lookups, resolved lazily because controllers register in any order.
local weapons: any = nil

--[[ Muzzle sources for other players' guns, keyed by player. Rebuilt when
     their character changes and re-probed at most once a second, because at
     900rpm a remote SMG would otherwise search a rig fifteen times a second. ]]
local muzzles: { [Player]: { character: Model?, attachment: Attachment?, nextProbe: number } } = {}

-- ── helpers ─────────────────────────────────────────────────────────────────

--[[ A CFrame whose LookVector is `direction`, safe when the direction is
     straight up or down (CFrame.lookAt with the default up vector is degenerate
     there and produces NaN, which propagates into a part position and kills the
     whole effect silently). ]]
local function faceAlong(position: Vector3, direction: Vector3): CFrame
	local up = if math.abs(direction.Y) > 0.99 then Vector3.xAxis else Vector3.yAxis
	return CFrame.lookAt(position, position + direction, up)
end

local function cameraPosition(): Vector3?
	local camera = Workspace.CurrentCamera
	return if camera then camera.CFrame.Position else nil
end

local function tooFar(position: Vector3): boolean
	local eye = cameraPosition()
	if not eye then
		return true
	end
	local delta = position - eye
	return delta:Dot(delta) > CULL_DISTANCE_SQUARED
end

local function weaponController(): any
	if weapons == nil then
		weapons = Registry.find("WeaponController") or false
	end
	return weapons or nil
end

local function newEffectPart(name: string): BasePart
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Locked = true
	part.Transparency = 1
	part.Size = Vector3.one
	part.Parent = folder
	return part
end

-- ── tracers ─────────────────────────────────────────────────────────────────

local function tracerSlot(): TracerSlot
	tracerCursor = (tracerCursor % TRACER_POOL) + 1
	local slot = tracers[tracerCursor]
	if not slot then
		slot = { part = newEffectPart("FL_Tracer"), until_ = 0 }
		slot.part.Material = Enum.Material.Neon
		tracers[tracerCursor] = slot
	end
	return slot
end

--[[
	The line the round travelled. Drawn as one stretched Neon box rather than a
	Beam: a Beam needs two Attachments and therefore two more instances per
	shot, and at 900rpm that is forty-five instances a second for something on
	screen for three frames.
]]
function ImpactController:drawTracer(origin: Vector3, endPosition: Vector3, weaponId: string)
	if not enabled or typeof(origin) ~= "Vector3" or typeof(endPosition) ~= "Vector3" then
		return
	end
	local definition = WeaponConfig.get(weaponId)
	if not definition or definition.tracerWidth <= 0 then
		return
	end

	local delta = endPosition - origin
	local length = delta.Magnitude
	if length < MIN_TRACER_LENGTH or tooFar(endPosition) then
		return
	end

	local slot = tracerSlot()
	local part = slot.part
	local width = definition.tracerWidth
	part.Size = Vector3.new(width, width, length)
	part.CFrame = faceAlong(origin + delta * 0.5, delta / length)
	part.Color = definition.tracerColor
	part.Transparency = TRACER_TRANSPARENCY
	slot.until_ = os.clock() + TRACER_FADE
end

local function updateTracers(now: number)
	for _, slot in tracers do
		if slot.until_ > 0 then
			local remaining = slot.until_ - now
			if remaining <= 0 then
				slot.until_ = 0
				slot.part.Transparency = 1
			else
				local alpha = remaining / TRACER_FADE
				slot.part.Transparency = 1 - (1 - TRACER_TRANSPARENCY) * alpha
			end
		end
	end
end

-- ── surface impacts ─────────────────────────────────────────────────────────

local function newEmitter(host: BasePart, name: string, texture: string): ParticleEmitter
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = name
	emitter.Texture = texture
	-- Emit along the part's front face, which faceAlong points down the normal.
	emitter.EmissionDirection = Enum.NormalId.Front
	emitter.Enabled = false
	emitter.Rate = 0
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.RotSpeed = NumberRange.new(-180, 180)
	emitter.Parent = host
	return emitter
end

local function impactSlot(): ImpactSlot
	impactCursor = (impactCursor % IMPACT_POOL) + 1
	local slot = impacts[impactCursor]
	if not slot then
		local part = newEffectPart("FL_Impact")
		part.Size = Vector3.new(0.1, 0.1, 0.1)
		slot = {
			part = part,
			spark = newEmitter(part, "Spark", SPARK_TEXTURE),
			dust = newEmitter(part, "Dust", DUST_TEXTURE),
			class = nil,
		}
		impacts[impactCursor] = slot
	end
	return slot
end

--[[ Every property that describes the surface, applied only when the pooled
     node is being reused for a DIFFERENT material. A firefight in one room hits
     the same class over and over, so this skips almost every write. ]]
local function applyClass(slot: ImpactSlot, className: string, class: any)
	if slot.class == className then
		return
	end
	slot.class = className

	local spark = slot.spark
	spark.Color = class.sparkColor
	spark.Size = class.sparkSize
	spark.Speed = class.sparkSpeed
	spark.Lifetime = class.sparkLifetime
	spark.LightEmission = class.sparkLight
	spark.SpreadAngle = Vector2.new(class.sparkSpread, class.sparkSpread)
	spark.Drag = class.sparkDrag
	spark.Acceleration = class.sparkAcceleration

	local dust = slot.dust
	dust.Color = class.dustColor
	dust.Size = class.dustSize
	dust.Speed = class.dustSpeed
	dust.Lifetime = class.dustLifetime
	dust.Transparency = class.dustTransparency
	dust.SpreadAngle = Vector2.new(class.dustSpread, class.dustSpread)
	dust.Drag = 4
	dust.Acceleration = NO_PULL
end

local function holeSlot(): HoleSlot
	holeCursor = (holeCursor % HOLE_POOL) + 1
	local slot = holes[holeCursor]
	if not slot then
		local part = newEffectPart("FL_BulletHole")
		part.Shape = Enum.PartType.Cylinder
		part.Material = Enum.Material.SmoothPlastic
		slot = { part = part, bornAt = 0, transparency = 0 }
		holes[holeCursor] = slot
	end
	return slot
end

--[[ A flat disc pressed against the surface. A Decal would be the obvious tool
     and it is the wrong one: a Decal needs a Texture asset id, and this project
     deliberately ships with no asset ids at all. A thin cylinder needs nothing,
     reads correctly at every distance a player will see it from, and can be
     recycled like everything else here. ]]
local function spawnHole(position: Vector3, normal: Vector3, class: any, scale: number)
	if not class.holeColor or class.holeSize <= 0 then
		return
	end
	local slot = holeSlot()
	local part = slot.part
	local diameter = class.holeSize * scale * random:NextNumber(0.8, 1.25)

	part.Size = Vector3.new(HOLE_THICKNESS, diameter, diameter)
	-- Rotate the lookAt frame so the cylinder's flat face (its local X axis)
	-- lies along the surface normal, then spin it so no two holes match.
	part.CFrame = faceAlong(position + normal * HOLE_OFFSET, normal)
		* CFrame.Angles(0, math.pi * 0.5, 0)
		* CFrame.Angles(random:NextNumber(0, math.pi * 2), 0, 0)
	part.Color = class.holeColor
	slot.transparency = random:NextNumber(0.12, 0.32)
	part.Transparency = slot.transparency
	slot.bornAt = os.clock()
end

local function updateHoles(now: number)
	for _, slot in holes do
		if slot.bornAt > 0 then
			local age = now - slot.bornAt
			if age >= HOLE_LIFETIME then
				slot.bornAt = 0
				slot.part.Transparency = 1
			elseif age > HOLE_LIFETIME - HOLE_FADE then
				local alpha = (age - (HOLE_LIFETIME - HOLE_FADE)) / HOLE_FADE
				slot.part.Transparency = slot.transparency + (1 - slot.transparency) * alpha
			end
		end
	end
end

--[[
	One round landing on the world. Public so that any future system with its
	own idea of an impact — a thrown pipe bomb, a Charger hitting a wall — can
	spend the same pool instead of inventing a second one.
]]
function ImpactController:spawnImpact(
	position: Vector3,
	normal: Vector3,
	material: Enum.Material?,
	damageType: string?
)
	if not enabled or typeof(position) ~= "Vector3" then
		return
	end
	if tooFar(position) then
		return
	end

	local surface = if typeof(normal) == "Vector3" and normal.Magnitude > 0
		then normal.Unit
		else Vector3.yAxis
	local className = DEFAULT_CLASS
	if typeof(material) == "EnumItem" then
		className = MATERIAL_CLASS[material] or DEFAULT_CLASS
	end
	local class = MATERIALS[className]
	local scale = DAMAGE_SCALE[damageType or ""] or DEFAULT_DAMAGE_SCALE

	local slot = impactSlot()
	applyClass(slot, className, class)
	slot.part.CFrame = faceAlong(position, surface)

	-- Counts scale with the damage; a shotgun's four impact events must add up
	-- to one blast rather than four separate rifle hits.
	local sparks = math.max(1, math.floor(class.sparkCount * scale + 0.5))
	local dust = math.max(1, math.floor(class.dustCount * scale + 0.5))
	slot.spark:Emit(sparks)
	slot.dust:Emit(dust)

	spawnHole(position, surface, class, scale)
end

-- ── remote muzzle flashes ───────────────────────────────────────────────────

local function flashSlot(): FlashSlot
	flashCursor = (flashCursor % FLASH_POOL) + 1
	local slot = flashes[flashCursor]
	if not slot then
		local part = newEffectPart("FL_RemoteFlash")
		part.Material = Enum.Material.Neon
		local light = Instance.new("PointLight")
		light.Shadows = false
		light.Enabled = false
		light.Parent = part
		slot = { part = part, light = light, until_ = 0 }
		flashes[flashCursor] = slot
	end
	return slot
end

--[[
	Where another player's gun actually is.

	Nothing currently welds a world weapon model to a survivor's hand, so the
	honest answer is "in front of their hands, along the shot". The lookup still
	prefers a real Muzzle attachment first, because the moment somebody does
	attach PlaceholderFactory:buildWeaponModel to a character, the flash should
	move to the barrel with no change here. Cached per character: a remote SMG
	would otherwise search a rig fifteen times a second.
]]
local MUZZLE_FORWARD = 2.2
local MUZZLE_DROP = 0.4

local MUZZLE_PROBE_INTERVAL = 1

local function muzzleCFrame(shooter: Player, origin: Vector3, direction: Vector3): CFrame
	local character = shooter.Character
	local record = muzzles[shooter]
	if not record or record.character ~= character then
		record = { character = character, attachment = nil, nextProbe = 0 }
		muzzles[shooter] = record
	end

	local attachment = record.attachment
	if attachment and attachment.Parent then
		return attachment.WorldCFrame
	end

	-- A gun can be equipped long after the character spawned, so keep looking —
	-- slowly. Once found, the search never runs again for that character.
	local now = os.clock()
	if character and now >= record.nextProbe then
		record.nextProbe = now + MUZZLE_PROBE_INTERVAL
		local found = character:FindFirstChild("Muzzle", true)
		if found and found:IsA("Attachment") then
			record.attachment = found
			return found.WorldCFrame
		end
	end
	-- Down the barrel from the shooter's eye, dropped to roughly hand height so
	-- the flash reads as coming from a gun rather than from their forehead.
	return faceAlong(origin + direction * MUZZLE_FORWARD - Vector3.new(0, MUZZLE_DROP, 0), direction)
end

--[[ Somebody else pulled a trigger. Visual only — AudioService already plays
     the shot at the same origin for everyone in range. ]]
function ImpactController:muzzleFlash(position: CFrame | Vector3, direction: Vector3, weaponId: string)
	if not enabled then
		return
	end
	local definition = WeaponConfig.get(weaponId)
	if not definition or definition.muzzleFlashSize <= 0 then
		return
	end

	local frame = if typeof(position) == "CFrame" then position else faceAlong(position, direction)
	if tooFar(frame.Position) then
		return
	end

	local slot = flashSlot()
	local size = definition.muzzleFlashSize
	local part = slot.part
	part.Size = Vector3.new(0.42 * size, 0.42 * size, 0.62 * size)
	part.CFrame = frame
	part.Color = definition.tracerColor
	part.Transparency = 0.1
	slot.light.Color = definition.tracerColor
	slot.light.Range = FLASH_LIGHT_RANGE * size
	slot.light.Brightness = FLASH_LIGHT_BRIGHTNESS
	slot.light.Enabled = true
	slot.until_ = os.clock() + FLASH_TIME
end

local function updateFlashes(now: number)
	for _, slot in flashes do
		if slot.until_ > 0 and now >= slot.until_ then
			slot.until_ = 0
			slot.part.Transparency = 1
			slot.light.Enabled = false
		end
	end
end

-- ── remote handlers ─────────────────────────────────────────────────────────

local function onTracerEffect(payload: any)
	if typeof(payload) ~= "table" then
		return
	end
	--[[ BallisticsService range-culls tracers rather than excluding the shooter,
	     so our own shots come back to us a round trip after we drew them. Drawing
	     both makes a shotgun look like it fired twice, the second time late. ]]
	local controller = weaponController()
	if controller and typeof(controller.isPredictedTracer) == "function" then
		local ok, predicted = pcall(controller.isPredictedTracer, controller, payload.origin)
		if ok and predicted then
			return
		end
	end
	ImpactController:drawTracer(payload.origin, payload.endPosition, payload.weaponId)
end

local function onImpactEffect(payload: any)
	if typeof(payload) ~= "table" then
		return
	end
	ImpactController:spawnImpact(payload.position, payload.normal, payload.material, payload.damageType)
end

local function onWeaponFired(payload: any)
	if typeof(payload) ~= "table" then
		return
	end
	local shooter = payload.shooter
	local origin = payload.origin
	local direction = payload.direction
	if typeof(origin) ~= "Vector3" or typeof(direction) ~= "Vector3" or direction.Magnitude <= 0 then
		return
	end

	local frame = if typeof(shooter) == "Instance" and shooter:IsA("Player")
		then muzzleCFrame(shooter, origin, direction.Unit)
		else faceAlong(origin, direction.Unit)
	ImpactController:muzzleFlash(frame, direction.Unit, payload.weaponId)
end

-- ── public API ──────────────────────────────────────────────────────────────

function ImpactController:setEnabled(value: boolean)
	enabled = value == true
	if not enabled then
		local now = os.clock()
		updateTracers(now + TRACER_FADE)
		updateFlashes(now + FLASH_TIME)
	end
end

function ImpactController:isEnabled(): boolean
	return enabled
end

--[[ Live pool occupancy, for a debug overlay. Counts what is currently drawn,
     not what has been drawn. ]]
function ImpactController:getCounts(): { tracers: number, holes: number, flashes: number }
	local liveTracers, liveHoles, liveFlashes = 0, 0, 0
	for _, slot in tracers do
		if slot.until_ > 0 then
			liveTracers += 1
		end
	end
	for _, slot in holes do
		if slot.bornAt > 0 then
			liveHoles += 1
		end
	end
	for _, slot in flashes do
		if slot.until_ > 0 then
			liveFlashes += 1
		end
	end
	return { tracers = liveTracers, holes = liveHoles, flashes = liveFlashes }
end

-- ── lifecycle ───────────────────────────────────────────────────────────────

local function update(_deltaTime: number)
	local now = os.clock()
	updateTracers(now)
	updateFlashes(now)
	updateHoles(now)
end

function ImpactController:init()
	folder = Instance.new("Folder")
	folder.Name = "FL_Impacts"
	folder.Parent = Workspace
	trove:add(folder)

	trove:connect(Players.PlayerRemoving, function(leaving: Player)
		muzzles[leaving] = nil
	end)
end

function ImpactController:start()
	trove:connect(Remotes.Event.TracerEffect.OnClientEvent, onTracerEffect)
	trove:connect(Remotes.Event.ImpactEffect.OnClientEvent, onImpactEffect)
	trove:connect(Remotes.Event.WeaponFired.OnClientEvent, onWeaponFired)
	trove:connect(RunService.RenderStepped, update)
end

function ImpactController:destroy()
	trove:destroy()
	table.clear(tracers)
	table.clear(impacts)
	table.clear(holes)
	table.clear(flashes)
	table.clear(muzzles)
end

Registry.register("ImpactController", ImpactController)

return ImpactController
