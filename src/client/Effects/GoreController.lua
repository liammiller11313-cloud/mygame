--!nonstrict
--[[
	GoreController — the client half of the payoff.

	GoreService owns everything four players have to agree on: ragdolls, severed
	limbs, the event throttle, the budgets. It owns none of the decoration,
	because decoration is an order of magnitude cheaper rendered locally and
	nobody has to agree on it. So a body coming apart arrives here as ONE
	GoreEvent packet and this file builds the rest:

	  blood spray along the surface normal, and a mist that hangs behind it
	  a blood decal projected down the shot line onto whatever was behind them
	  gib chunks, built from the server's seed so every client sees the same ones
	  a pool that grows under a body once it stops moving
	  screen blood, when the one being hit is you

	── THE SEED IS THE POINT ───────────────────────────────────────────────────
	Nine chunks per body across a 46-strong horde is thousands of networked
	physics objects for something that is on screen for twelve seconds. So gibs
	are not replicated: the server picks a count and a seed, and every client in
	range feeds that seed to Random.new() and builds the same chunks from the
	same shared GoreConfig. The explosion reads identically for everyone and
	costs one packet.

	── WHAT THIS FILE DELIBERATELY DOES NOT DO ─────────────────────────────────
	  * hit-stop — CameraController listens to GoreEvent itself and owns the
	    freeze; doing it here as well would double the effect on every kill
	  * ragdoll physics, severed limbs, corpse lifetimes — all server-owned
	  * screen blood, WHEN OverlayController is present. It already spawns
	    droplets from DamageTaken using the same GoreConfig.ScreenBlood numbers,
	    so this controller routes through it and only builds its own droplet
	    layer if that controller is missing. See :screenBlood below.

	── PERFORMANCE ─────────────────────────────────────────────────────────────
	A horde dying to an auto shotgun hammers this file harder than anything else
	in the project, so:
	  * ring buffers everywhere. Enforcing MaxActiveGibs / MaxActiveDecals by
	    recycling the oldest is not a check here, it is the data structure — and
	    recycling is the ONLY legal way to stay under a cap. A shot that produces
	    no gore feels broken, and feeling broken is worse than costing a frame.
	  * ParticleEmitters are created once per pooled node and re-aimed, never
	    created per hit. The sequences they read are built once at module load.
	  * anything past GoreConfig.Budget.CullDistance is dropped before it costs
	    an instance, a raycast or a property write.
	  * ONE Heartbeat connection, sweeping at SWEEP_HZ rather than every frame.
	    Decal fades run over seconds and pools grow over PoolGrowTime; neither
	    can tell the difference, and the horde can.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Enums = require(Shared.Enums)
local GameConfig = require(Shared.Config.GameConfig)
local GoreConfig = require(Shared.Config.GoreConfig)
local Device = require(Shared.Util.Device)
local Registry = require(Shared.Util.Registry)

--[[ For the screen-blood droplets: they lay out in offsets, so they have to be
     sized in the same reference pixels the rest of the interface uses. ]]
local ScaleLayer = require(script.Parent.Parent.UI.ScaleLayer)
local Remotes = require(Shared.Net.Remotes)
local Trove = require(Shared.Util.Trove)
local UITheme = require(Shared.Config.UITheme)

local BLOOD = GoreConfig.Blood
local GIBS = GoreConfig.Gibs
local BUDGET = GoreConfig.Budget
local SCREEN = GoreConfig.ScreenBlood
local LEVEL = Enums.GoreLevel

--[[
	What KIND of machine this is, for the gore budget below.

	Not InputController's scheme, which answers a different question: that one
	tracks what the player is holding, and a phone with a bluetooth controller
	paired to it reports Gamepad while still being a phone. This asks about the
	hardware, which does not change, and is read once at load because the ring
	buffers are sized from it.

	Detected here rather than borrowed from a service because this runs at module
	scope — before any controller has started — and three lines of duplication
	beats a load-order dependency that only breaks in the field.
]]
--[[ From Shared/Util/Device now, which is the same three checks this file used
     to own — with two bugs out of them. It tested `not KeyboardEnabled`, so a
     phone with a paired Bluetooth keyboard got the DESKTOP budget, permanently,
     because the answer was frozen at module scope. And it could not tell a
     tablet from a phone, because that needs the viewport and the camera does not
     exist this early. Device is lazy for exactly that reason. ]]
local DEVICE_BUDGET = GoreConfig.budgetFor(Device.get())

--[[ GameConfig.Corpses restates two of GoreConfig.Budget's ceilings. Rather
     than pick a winner and let the other drift into a lie, take the tighter of
     each pair — the same rule GoreService applies on the server, so the two
     ledgers cannot disagree about what the budget is.

     The device budget is a third voice in the same argument and wins the same
     way: whichever ceiling is lowest is the ceiling. A phone gets 36 gibs and 64
     decals where a desktop gets the full ninety and hundred and sixty, because
     ninety loose physics bodies is what takes a handset's frame rate down during
     exactly the moment the game is trying to be exciting. ]]
local MAX_GIBS = math.min(BUDGET.MaxActiveGibs, GameConfig.Corpses.MaxGibs, DEVICE_BUDGET.gibs)
local MAX_DECALS = math.min(BUDGET.MaxActiveDecals, GameConfig.Corpses.MaxBloodDecals, DEVICE_BUDGET.decals)

--[[
	Multiplies every particle count in a burst. See GoreConfig.budgetFor: all
	four layers survive on every device, at fewer particles each.

	Two inputs, and the SMALLER of them wins — which is what `setQuality`
	enforces. The device budget is what the hardware can push; the player's
	quality setting is what they want to look at. Somebody on a desktop who
	prefers a clean screen gets their LOW; somebody on a phone gets the device
	floor whatever they pick, because a setting cannot buy them a GPU.
]]
--[[ The two inputs to particleScale, kept separately because either can move
     on its own: the player changes the quality setting, or Device revises its
     answer once the camera exists. Multiplying them at the point of change and
     keeping only the product meant whichever moved second silently discarded
     the other. ]]
local qualityScale = 1
local particleScale = DEVICE_BUDGET.particles

--[[ The blood a flying chunk leaves behind it. Rate is per second and the window
     is short: a gib is airborne for well under a second of its twelve-second
     life, and an emitter left running past that is ninety of them bleeding into
     the floor. ]]
local GIB_TRAIL_RATE = 26
local GIB_TRAIL_SECONDS = 0.85

local CULL_DISTANCE_SQUARED = BUDGET.CullDistance * BUDGET.CullDistance

-- Blood spray and mist bursts are short. Twenty nodes is more than the server's
-- MaxGoreEventsPerSecond can fill inside one MistLifetime, so a node is never
-- re-aimed while its own mist is still hanging.
local SPRAY_POOL = 20

-- Expiry, fades and pool growth all run on human timescales. Sweeping at 20Hz
-- instead of 60 is the same behaviour for a third of the cost.
--[[ When a loose chunk stops counting as a physics body. See updateGibs. Both
     are generous: a gib nudged along the floor by a passing Common is still
     moving, and anchoring it mid-slide is the one way this could be seen. ]]
local GIB_SETTLE_SPEED = 1.5
local GIB_SETTLE_TIME = 0.5

local SWEEP_HZ = 20
local SWEEP_INTERVAL = 1 / SWEEP_HZ

local DECAL_THICKNESS = 0.05
local DECAL_OFFSET = 0.03 -- lifted off the surface so it cannot z-fight

--[[ A decal's shape. Blood does not land in circles: stretching one axis and
     spinning the disc is the whole difference between a splat and a coaster. ]]
local DECAL_STRETCH_MIN = 0.55
local DECAL_STRETCH_MAX = 1.0

-- Gib chunks are boxes with unequal sides. Perfectly cubic chunks read as dice.
local GIB_ASPECT_MIN = 0.55
local GIB_ASPECT_MAX = 1.0

--[[ Charred remains. Enums.GoreLevel.Incinerate exists and GoreService emits
     it, but no config describes what burning looks like — GoreConfig covers
     blood, gibs and screen blood only. These two colours are the invented ones
     in this file; everything else is read from config. ]]
local EMBER_COLOR = Color3.fromRGB(255, 148, 52)
local SMOKE_COLOR = Color3.fromRGB(46, 42, 40)

-- Engine textures, not marketplace assets: they ship with the client.
local SPRAY_TEXTURE = "rbxasset://textures/particles/sparkles_main.dds"
local MIST_TEXTURE = "rbxasset://textures/particles/smoke_main.dds"

--[[ The ScreenEffect verb OverlayController answers to for lens blood. The
     effect vocabulary lives in that controller rather than in Enums, so this is
     a string by necessity; if it is ever renamed, this is the other end. ]]
local OVERLAY_BLOOD_EFFECT = "Blood"

local random = Random.new()

-- ── particle styles ─────────────────────────────────────────────────────────

--[[ How far each layer is stretched along its own velocity. The spray is thin
     and fast, so it stretches hard; a gout is a heavy blob that deforms rather
     than becoming a line, so it stretches about half as much. Both relax back
     to round as they slow. ]]
local SPRAY_STREAK = 2.6
local GOUT_STREAK = 1.3

local function shrink(start: number, peak: number): NumberSequence
	return NumberSequence.new({
		NumberSequenceKeypoint.new(0, start),
		NumberSequenceKeypoint.new(0.3, peak),
		NumberSequenceKeypoint.new(1, 0),
	})
end

local function fadeOut(start: number): NumberSequence
	return NumberSequence.new({
		NumberSequenceKeypoint.new(0, start),
		NumberSequenceKeypoint.new(0.65, start),
		NumberSequenceKeypoint.new(1, 1),
	})
end

--[[ Two looks, built once. Blood darkens as it travels (fresh at the wound,
     nearly black by the time it lands), and char is the same shape of burst
     with the colour of a body that stopped being one. ]]
local STYLES = {
	Blood = {
		sprayColor = ColorSequence.new({
			ColorSequenceKeypoint.new(0, BLOOD.Color),
			ColorSequenceKeypoint.new(1, BLOOD.DarkColor),
		}),
		spraySize = shrink(0.34, 0.2),
		spraySpeed = NumberRange.new(BLOOD.SpraySpeed * 0.45, BLOOD.SpraySpeed),
		sprayLifetime = NumberRange.new(BLOOD.SprayLifetime * 0.6, BLOOD.SprayLifetime),
		sprayLight = 0,
		sprayAcceleration = Vector3.new(0, -96, 0),

		mistColor = ColorSequence.new(BLOOD.DarkColor),
		mistSize = shrink(BLOOD.MistSize * 0.4, BLOOD.MistSize),
		mistSpeed = NumberRange.new(1.5, 5),
		mistLifetime = NumberRange.new(BLOOD.MistLifetime * 0.55, BLOOD.MistLifetime),
		mistTransparency = fadeOut(0.42),

		--[[ Gouts keep the fresh colour the whole way. Spray darkens because it
		     is a fine mist oxidising in flight; a heavy droplet has not been in
		     the air long enough for that to be true, and darkening it just makes
		     it read as dirt. ]]
		goutColor = ColorSequence.new(BLOOD.Color),
		goutSize = NumberSequence.new({
			NumberSequenceKeypoint.new(0, BLOOD.GoutSize),
			NumberSequenceKeypoint.new(0.8, BLOOD.GoutSize * 0.85),
			NumberSequenceKeypoint.new(1, 0),
		}),
		goutSpeed = NumberRange.new(BLOOD.GoutSpeed * 0.35, BLOOD.GoutSpeed),
		goutLifetime = NumberRange.new(BLOOD.GoutLifetime * 0.6, BLOOD.GoutLifetime),
		-- Full gravity. This is the layer that is supposed to fall.
		goutAcceleration = Vector3.new(0, -110, 0),

		squibColor = ColorSequence.new(Color3.fromRGB(214, 74, 62)),
		squibLight = 1,
	},

	Char = {
		sprayColor = ColorSequence.new({
			ColorSequenceKeypoint.new(0, EMBER_COLOR),
			ColorSequenceKeypoint.new(1, SMOKE_COLOR),
		}),
		spraySize = shrink(0.26, 0.14),
		spraySpeed = NumberRange.new(BLOOD.SpraySpeed * 0.3, BLOOD.SpraySpeed * 0.7),
		sprayLifetime = NumberRange.new(BLOOD.SprayLifetime, BLOOD.SprayLifetime * 1.6),
		sprayLight = 1,
		sprayAcceleration = Vector3.new(0, -18, 0),

		mistColor = ColorSequence.new(SMOKE_COLOR),
		mistSize = shrink(BLOOD.MistSize * 0.5, BLOOD.MistSize * 1.6),
		mistSpeed = NumberRange.new(1, 4),
		mistLifetime = NumberRange.new(BLOOD.MistLifetime, BLOOD.MistLifetime * 1.8),
		mistTransparency = fadeOut(0.55),

		--[[ A burned body throws embers rather than gouts: same heavy arc, but
		     they glow and they cool on the way down, which is the whole reason
		     the gout layer is styled rather than shared. ]]
		goutColor = ColorSequence.new({
			ColorSequenceKeypoint.new(0, EMBER_COLOR),
			ColorSequenceKeypoint.new(1, SMOKE_COLOR),
		}),
		goutSize = NumberSequence.new({
			NumberSequenceKeypoint.new(0, BLOOD.GoutSize * 0.55),
			NumberSequenceKeypoint.new(1, 0),
		}),
		goutSpeed = NumberRange.new(BLOOD.GoutSpeed * 0.25, BLOOD.GoutSpeed * 0.7),
		goutLifetime = NumberRange.new(BLOOD.GoutLifetime, BLOOD.GoutLifetime * 1.7),
		goutAcceleration = Vector3.new(0, -42, 0),

		squibColor = ColorSequence.new(EMBER_COLOR),
		squibLight = 1,
	},
}

-- ── state ───────────────────────────────────────────────────────────────────

local GoreController = {}

local player = Players.LocalPlayer
local trove = Trove.new()

local folder: Folder
local enabled = GoreConfig.Enabled

type SpraySlot = {
	part: BasePart,
	squib: ParticleEmitter,
	spray: ParticleEmitter,
	gout: ParticleEmitter,
	mist: ParticleEmitter,
	style: string?,
}
type GibSlot = {
	part: BasePart,
	expiresAt: number,
	trail: ParticleEmitter,
	trailUntil: number,
	-- When this chunk stops being a physics body. 0 while it is still moving.
	settleAt: number,
	--[[ Whether this chunk leaves a mark where it lands. Decided when it is
	     thrown, from the shared seed, and spent once. ]]
	mark: boolean,
}
type DecalSlot = {
	part: BasePart,
	expiresAt: number,
	transparency: number,
	growUntil: number, -- 0 unless this is a pool that is still spreading
	targetSize: number,
	normal: Vector3,
	dryUntil: number, -- 0 once the mark has finished darkening
	dryTime: number,
}

local sprays: { SpraySlot } = table.create(SPRAY_POOL)
local gibs: { GibSlot } = table.create(MAX_GIBS)
local decals: { DecalSlot } = table.create(MAX_DECALS)

local sprayCursor = 0
local gibCursor = 0
local decalCursor = 0

local sweepAccumulator = 0

--[[ "Gib" is registered by the server bootstrap and collides with Default only,
     which is exactly what a chunk wants: it bounces off the floor and never
     shoves a survivor. Probed once because assigning an unregistered group name
     throws, and a client running against a server that never booted should lose
     its gib collisions rather than its gibs. ]]
local gibGroup: string? = nil
local gibGroupProbed = false

-- Screen blood. Owned by OverlayController when it exists; this is the fallback.
local overlayOwnsScreenBlood = false
local screenGui: ScreenGui? = nil
local droplets: { { frame: Frame, age: number, peak: number } } = {}
local dropletCursor = 0

--[[ One RaycastParams for every decal projection in the round, refiltered only
     when the target changes. A fresh one per hit is an allocation the GC
     eventually charges to a frame in the middle of a horde. ]]
local decalParams = RaycastParams.new()
local decalFilter: { Instance } = {}

-- ── helpers ─────────────────────────────────────────────────────────────────

local function unitOr(vector: any, fallback: Vector3): Vector3
	if typeof(vector) == "Vector3" and vector.Magnitude > 1e-4 then
		return vector.Unit
	end
	return fallback
end

--[[ A CFrame whose LookVector is `direction`, safe when the direction is
     straight up or down — CFrame.lookAt is degenerate there and produces NaN,
     which silently poisons every position derived from it. ]]
local function faceAlong(position: Vector3, direction: Vector3): CFrame
	local up = if math.abs(direction.Y) > 0.99 then Vector3.xAxis else Vector3.yAxis
	return CFrame.lookAt(position, position + direction, up)
end

local function tooFar(position: Vector3): boolean
	local camera = Workspace.CurrentCamera
	if not camera then
		return true
	end
	local delta = position - camera.CFrame.Position
	return delta:Dot(delta) > CULL_DISTANCE_SQUARED
end

local function newGorePart(name: string): BasePart
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.CanCollide = false
	-- Never queryable. A chunk of somebody that stops a bullet meant for the
	-- next zombie is the worst kind of bug: invisible, and it costs a kill.
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Locked = true
	part.Transparency = 1
	part.Material = Enum.Material.SmoothPlastic
	part.Parent = folder
	return part
end

-- ── spray and mist ──────────────────────────────────────────────────────────

--[[
	`streak` turns a particle from a facing-camera dot into something aligned with
	its own velocity and stretched along it.

	That single property is most of the difference between blood that looks like
	red confetti and blood that looks like liquid. A droplet moving at thirty
	studs a second IS a streak — it covers most of a frame's distance while the
	shutter is open — and drawing it as a circle is drawing it at rest. Rotation
	is dropped for those, because a particle already oriented by its velocity has
	nothing left to spin about that would not look like a wobble.
]]
local function newEmitter(host: BasePart, name: string, texture: string, streak: number?): ParticleEmitter
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = name
	emitter.Texture = texture
	-- Emit along the part's front face, which faceAlong aims down the normal.
	emitter.EmissionDirection = Enum.NormalId.Front
	emitter.Enabled = false
	emitter.Rate = 0

	if streak then
		emitter.Orientation = Enum.ParticleOrientation.VelocityParallel
		emitter.Squash = NumberSequence.new({
			NumberSequenceKeypoint.new(0, streak),
			-- Relaxes back toward round as it slows, so a droplet that has spent
			-- its speed stops pretending it is still travelling.
			NumberSequenceKeypoint.new(1, 0),
		})
	else
		emitter.Rotation = NumberRange.new(0, 360)
		emitter.RotSpeed = NumberRange.new(-140, 140)
	end

	emitter.Parent = host
	return emitter
end

local function spraySlot(): SpraySlot
	sprayCursor = (sprayCursor % SPRAY_POOL) + 1
	local slot = sprays[sprayCursor]
	if not slot then
		local part = newGorePart("FL_Blood")
		part.Size = Vector3.new(0.1, 0.1, 0.1)
		slot = {
			part = part,
			--[[ Four layers, front to back in the order the eye reads them: the
			     squib pops, the spray streaks out, the gouts arc and fall, the
			     mist hangs where it happened. Each one alone reads as an effect;
			     together they read as an event. ]]
			squib = newEmitter(part, "Squib", SPRAY_TEXTURE),
			spray = newEmitter(part, "Spray", SPRAY_TEXTURE, SPRAY_STREAK),
			gout = newEmitter(part, "Gout", SPRAY_TEXTURE, GOUT_STREAK),
			mist = newEmitter(part, "Mist", MIST_TEXTURE),
			style = nil,
		}
		sprays[sprayCursor] = slot
	end
	return slot
end

--[[ Applied only when a pooled node changes style, which during a horde it
     essentially never does. ]]
local function applyStyle(slot: SpraySlot, styleName: string)
	if slot.style == styleName then
		return
	end
	slot.style = styleName
	local style = STYLES[styleName]

	local spray = slot.spray
	spray.Color = style.sprayColor
	spray.Size = style.spraySize
	spray.Speed = style.spraySpeed
	spray.Lifetime = style.sprayLifetime
	spray.LightEmission = style.sprayLight
	spray.SpreadAngle = Vector2.new(BLOOD.SpraySpread, BLOOD.SpraySpread)
	spray.Drag = 1.5
	spray.Acceleration = style.sprayAcceleration
	spray.Transparency = NumberSequence.new(0)

	local gout = slot.gout
	gout.Color = style.goutColor
	gout.Size = style.goutSize
	gout.Speed = style.goutSpeed
	gout.Lifetime = style.goutLifetime
	gout.LightEmission = style.sprayLight
	gout.SpreadAngle = Vector2.new(BLOOD.GoutSpread, BLOOD.GoutSpread)
	--[[ Almost no drag, unlike the spray. A heavy droplet keeps its speed and
	     lets gravity do the work; dragging it would make it hang, and a gout that
	     hangs is just a slow mist. ]]
	gout.Drag = 0.3
	gout.Acceleration = style.goutAcceleration
	gout.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.85, 0),
		NumberSequenceKeypoint.new(1, 1),
	})

	--[[ The squib does not travel. It is a flash at the wound, so it barely
	     moves, barely lives, and is bright enough to find at any distance. ]]
	local squib = slot.squib
	squib.Color = style.squibColor
	squib.LightEmission = style.squibLight
	squib.LightInfluence = 0
	squib.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, BLOOD.SquibSize),
		NumberSequenceKeypoint.new(1, 0),
	})
	squib.Speed = NumberRange.new(0.5, 3)
	squib.Lifetime = NumberRange.new(BLOOD.SquibLifetime * 0.6, BLOOD.SquibLifetime)
	squib.SpreadAngle = Vector2.new(60, 60)
	squib.Drag = 8
	squib.Acceleration = Vector3.zero
	squib.Transparency = NumberSequence.new(0)

	local mist = slot.mist
	mist.Color = style.mistColor
	mist.Size = style.mistSize
	mist.Speed = style.mistSpeed
	mist.Lifetime = style.mistLifetime
	mist.Transparency = style.mistTransparency
	-- The mist hangs where the hit happened rather than following it out.
	mist.SpreadAngle = Vector2.new(90, 90)
	mist.Drag = 6
	mist.Acceleration = Vector3.zero
end

--[[
	The two airborne layers of GoreConfig.Blood. `scale` is the server's blood
	volume multiplier — 1.0 for an incidental hit, 2.6 for a gib — and it
	multiplies the particle COUNTS, never the config's own numbers.
]]
local function burst(position: Vector3, normal: Vector3, scale: number, styleName: string)
	local slot = spraySlot()
	applyStyle(slot, styleName)
	slot.part.CFrame = faceAlong(position, normal)

	--[[ Every count is scaled by the device as well as by the hit. A phone gets
	     the same four layers — dropping one would change what the effect READS
	     as, not just what it costs — at a fraction of the particle count, which
	     is the term that actually decides whether the frame holds. ]]
	local budget = scale * particleScale

	slot.squib:Emit(math.max(1, math.floor(BLOOD.SquibParticles * budget + 0.5)))
	slot.spray:Emit(math.max(1, math.floor(BLOOD.SprayParticles * budget + 0.5)))
	slot.gout:Emit(math.max(1, math.floor(BLOOD.GoutParticles * budget + 0.5)))
	slot.mist:Emit(math.max(1, math.floor(BLOOD.MistParticles * budget + 0.5)))
end

-- ── decals and pools ────────────────────────────────────────────────────────

local function decalSlot(): DecalSlot
	--[[ The ring buffer IS the budget: reaching MaxActiveDecals recycles the
	     oldest mark rather than refusing to draw a new one. ]]
	decalCursor = (decalCursor % MAX_DECALS) + 1
	local slot = decals[decalCursor]
	if not slot then
		local part = newGorePart("FL_BloodDecal")
		part.Shape = Enum.PartType.Cylinder
		slot = {
			part = part,
			expiresAt = 0,
			transparency = 0,
			growUntil = 0,
			targetSize = 0,
			normal = Vector3.yAxis,
			--[[ When this mark stops darkening, and over how long. Zero means it
			     is done and the colour is left alone — which is most of them most
			     of the time, and is why drying costs nothing past the first few
			     seconds of a mark's life. ]]
			dryUntil = 0,
			dryTime = BLOOD.DecalDryTime,
		}
		decals[decalCursor] = slot
	end
	return slot
end

--[[ Lays a disc flat against a surface. A Decal would be the obvious tool and
     it is the wrong one here: a Decal needs a Texture asset id and this project
     ships with none, so an untextured Decal would render nothing at all. A thin
     cylinder needs no asset, reads at every distance, and recycles. ]]
local function placeDisc(slot: DecalSlot, position: Vector3, normal: Vector3, diameter: number)
	local part = slot.part
	part.Size = Vector3.new(
		DECAL_THICKNESS,
		diameter,
		diameter * random:NextNumber(DECAL_STRETCH_MIN, DECAL_STRETCH_MAX)
	)
	part.CFrame = faceAlong(position + normal * DECAL_OFFSET, normal)
		* CFrame.Angles(0, math.pi * 0.5, 0)
		* CFrame.Angles(random:NextNumber(0, math.pi * 2), 0, 0)
	--[[ Always fresh, and it dries from here — which replaces the coin flip
	     between fresh and dark this used to do. That coin flip WAS the variety
	     mechanism, so the variety has to come from somewhere: it comes from age
	     now, which is better, because a bright mark next to a dark one means
	     something instead of being noise. Each one dries on its own slightly
	     different clock so two laid in the same instant do not move in lockstep. ]]
	part.Color = BLOOD.Color
	slot.dryTime = BLOOD.DecalDryTime * random:NextNumber(0.75, 1.35)
	slot.dryUntil = os.clock() + slot.dryTime
	slot.transparency = random:NextNumber(0.04, 0.2)
	part.Transparency = slot.transparency
	slot.normal = normal
end

--[[ The body itself must never catch its own spatter: a decal painted inside a
     corpse that is about to be cleaned up leaves the wall clean. The filter
     table is reused rather than rebuilt — assigning the property copies it, so
     one table serves every projection in the round. ]]
local function setDecalFilter(body: Instance?)
	local count = 0
	local character = player.Character
	if character then
		count += 1
		decalFilter[count] = character
	end
	if typeof(body) == "Instance" then
		count += 1
		decalFilter[count] = body
	end
	for index = #decalFilter, count + 1, -1 do
		decalFilter[index] = nil
	end
	decalParams.FilterDescendantsInstances = decalFilter
end

--[[
	The mark on the wall behind the target.

	The server rolled DecalChanceOnHit / OnKill already, so every client in range
	agrees on whether this hit left one; the projection raycast is ours because
	the geometry is identical here and it costs the server nothing.
]]
--[[ `lifetime` overrides how long the mark lasts. Gib land marks pass a short
     one: they are small smears under debris, they arrive in far greater numbers
     than wall splatter, and at the full DecalLifetime they would crowd the
     gunfight off the walls. Everything else takes the default. ]]
local function projectDecal(
	position: Vector3,
	direction: Vector3,
	scale: number,
	body: Instance?,
	lifetime: number?
)
	if not BLOOD.DecalEnabled then
		return
	end

	setDecalFilter(body)
	local result = Workspace:Raycast(position, direction * BLOOD.DecalMaxDistance, decalParams)
	if not result then
		return
	end

	local slot = decalSlot()
	local diameter = random:NextNumber(BLOOD.DecalSizeMin, BLOOD.DecalSizeMax) * math.min(scale, 2)
	placeDisc(slot, result.Position, result.Normal, diameter)
	slot.growUntil = 0
	slot.targetSize = diameter
	slot.expiresAt = os.clock() + (lifetime or BLOOD.DecalLifetime)
end

--[[ A body that has stopped moving starts bleeding into the floor. It spends a
     decal slot because that is what it is — the ceiling that matters is the
     total number of red marks in the level, not which kind they are. ]]
local function growPool(position: Vector3)
	if not BLOOD.PoolEnabled then
		return
	end
	setDecalFilter(nil)
	local result = Workspace:Raycast(position, Vector3.new(0, -BLOOD.DecalMaxDistance, 0), decalParams)
	local at = if result then result.Position else position
	local normal = if result then result.Normal else Vector3.yAxis

	local slot = decalSlot()
	placeDisc(slot, at, normal, BLOOD.DecalSizeMin)
	slot.targetSize = BLOOD.PoolMaxSize
	slot.growUntil = os.clock() + BLOOD.PoolGrowTime
	slot.expiresAt = os.clock() + BLOOD.DecalLifetime
end

local function updateDecals(now: number)
	for _, slot in decals do
		if slot.expiresAt <= 0 then
			continue
		end

		if slot.growUntil > 0 then
			local remaining = slot.growUntil - now
			if remaining <= 0 then
				slot.growUntil = 0
			end
			local alpha = math.clamp(1 - math.max(remaining, 0) / BLOOD.PoolGrowTime, 0, 1)
			local diameter = BLOOD.DecalSizeMin + (slot.targetSize - BLOOD.DecalSizeMin) * alpha
			local size = slot.part.Size
			slot.part.Size = Vector3.new(size.X, diameter, diameter)
		end

		--[[ Fresh blood is bright and old blood is nearly black. Only while it is
		     still drying: past that the colour is final and writing it every
		     frame would be a property write per decal forever for no change. ]]
		if slot.dryUntil > 0 then
			local left = slot.dryUntil - now
			if left <= 0 then
				slot.dryUntil = 0
				slot.part.Color = BLOOD.DarkColor
			else
				local dried = 1 - left / math.max(slot.dryTime, 0.01)
				slot.part.Color = BLOOD.Color:Lerp(BLOOD.DarkColor, math.clamp(dried, 0, 1))
			end
		end

		local remaining = slot.expiresAt - now
		if remaining <= 0 then
			slot.expiresAt = 0
			slot.part.Transparency = 1
		elseif remaining < BLOOD.DecalFadeTime then
			local alpha = 1 - remaining / BLOOD.DecalFadeTime
			slot.part.Transparency = slot.transparency + (1 - slot.transparency) * alpha
		end
	end
end

-- ── gibs ────────────────────────────────────────────────────────────────────

local function resolveGibGroup(): string?
	if gibGroupProbed then
		return gibGroup
	end
	gibGroupProbed = true
	local probe = Instance.new("Part")
	local ok = pcall(function()
		probe.CollisionGroup = "Gib"
	end)
	probe:Destroy()
	gibGroup = if ok then "Gib" else nil
	return gibGroup
end

local function gibSlot(): GibSlot
	-- Same rule as decals: the ring buffer is the budget, and the oldest chunk
	-- is the one that goes.
	gibCursor = (gibCursor % MAX_GIBS) + 1
	local slot = gibs[gibCursor]
	if not slot then
		local part = newGorePart("FL_Gib")
		part.Color = GIBS.Color
		--[[ Meat is wet. A matte chunk reads as brick, and these are usually seen
		     under a flashlight where the difference is most of the effect. ]]
		part.Reflectance = GIBS.Wetness

		--[[
			Some of the pool are LUMPS rather than boxes.

			Rolled once when the slot is BUILT, not per spawn: nothing is created
			or destroyed at the moment a body bursts, which is the one moment in
			this system that cannot afford it. The pool is then walked round-robin
			for the rest of the round, so a burst draws whatever mix the pool holds
			and every burst gets both.

			A Sphere SpecialMesh is a primitive and needs no asset. Because gib
			sizes already vary per axis it comes out as an irregular blob rather
			than a ball, which is what makes the mix read as something torn apart
			instead of as rubble.
		]]
		if math.random() < GIBS.MeshShare then
			local mesh = Instance.new("SpecialMesh")
			mesh.MeshType = Enum.MeshType.Sphere
			mesh.Parent = part
		end
		--[[ GoreConfig.Gibs.CollideWithPlayers is false, and the "Gib" group is
		     exactly that rule: it collides with Default and nothing else, so a
		     chunk bounces off the floor and never shoves a survivor. ]]
		local group = resolveGibGroup()
		if group then
			part.CollisionGroup = group
		end

		--[[
			A chunk that flies and leaves nothing behind reads as a prop being
			thrown. The trail is what makes it read as part of a body.

			Continuous rather than a burst, because the point is the LINE it draws
			through the air — and switched off after a short window rather than
			run for the gib's whole twelve-second lifetime, since a chunk that has
			come to rest on the floor should not still be bleeding upward. That
			window is the only reason this is affordable at ninety gibs.
		]]
		local trail = Instance.new("ParticleEmitter")
		trail.Name = "Trail"
		trail.Texture = SPRAY_TEXTURE
		trail.Enabled = false
		trail.Rate = GIB_TRAIL_RATE * particleScale
		trail.Color = ColorSequence.new(BLOOD.DarkColor)
		trail.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.16),
			NumberSequenceKeypoint.new(1, 0),
		})
		trail.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.15),
			NumberSequenceKeypoint.new(1, 1),
		})
		trail.Lifetime = NumberRange.new(0.2, 0.45)
		trail.Speed = NumberRange.new(0, 1.5)
		trail.SpreadAngle = Vector2.new(180, 180)
		trail.Acceleration = Vector3.new(0, -70, 0)
		trail.Drag = 1
		trail.LightEmission = 0
		trail.Parent = part

		slot = { part = part, expiresAt = 0, trail = trail, trailUntil = 0, settleAt = 0, mark = false }
		gibs[gibCursor] = slot
	end
	return slot
end

--[[
	The body, replaced by chunks.

	Every number comes from the shared seed, so four clients build four
	identical explosions from one packet. `count` is the server's, because only
	the server knows how much of the gib budget the rest of the horde has
	already spent.
]]
local function spawnGibs(position: Vector3, direction: Vector3, seed: number, count: number?)
	local rng = Random.new(seed)
	local wanted = count or rng:NextInteger(GIBS.CountMin, GIBS.CountMax)
	local total = math.clamp(wanted, GIBS.CountMin, GIBS.CountMax)
	local collides = resolveGibGroup() ~= nil

	for _ = 1, total do
		local slot = gibSlot()
		local part = slot.part

		--[[ Deep tissue is nearly black and surface flesh is bright; a burst
		     carrying both reads as a body, and one flat colour reads as a colour.
		     From the shared seed, so four clients tint the same chunk the same. ]]
		part.Color = GIBS.Color:Lerp(BLOOD.DarkColor, rng:NextNumber(0, GIBS.DarkMixMax))

		local size = rng:NextNumber(GIBS.SizeMin, GIBS.SizeMax)
		-- Chunks, not dice: unequal sides on every axis.
		part.Anchored = true
		part.Size = Vector3.new(
			size,
			size * rng:NextNumber(GIB_ASPECT_MIN, GIB_ASPECT_MAX),
			size * rng:NextNumber(GIB_ASPECT_MIN, GIB_ASPECT_MAX)
		)
		part.CFrame = CFrame.new(
			position
				+ Vector3.new(rng:NextNumber(-0.6, 0.6), rng:NextNumber(-0.4, 0.8), rng:NextNumber(-0.6, 0.6))
		) * CFrame.Angles(
			rng:NextNumber(0, math.pi * 2),
			rng:NextNumber(0, math.pi * 2),
			rng:NextNumber(0, math.pi * 2)
		)
		part.Transparency = 0
		part.CanCollide = collides

		--[[ Thrown along the shot with a scatter, plus UpwardBias so chunks
		     tumble instead of skidding along the floor. ]]
		local scatter = Vector3.new(rng:NextNumber(-1, 1), rng:NextNumber(-1, 1), rng:NextNumber(-1, 1))
		local heading = (direction + scatter * 0.55 + Vector3.yAxis * GIBS.UpwardBias)
		heading = if heading.Magnitude > 1e-3 then heading.Unit else Vector3.yAxis

		part.Anchored = false
		part.AssemblyLinearVelocity = heading * rng:NextNumber(GIBS.ImpulseMin, GIBS.ImpulseMax)
		part.AssemblyAngularVelocity = Vector3.new(
			rng:NextNumber(-GIBS.SpinMax, GIBS.SpinMax),
			rng:NextNumber(-GIBS.SpinMax, GIBS.SpinMax),
			rng:NextNumber(-GIBS.SpinMax, GIBS.SpinMax)
		)
		local now = os.clock()
		slot.expiresAt = now + GIBS.Lifetime
		--[[ A recycled slot can still be carrying the settle deadline of the
		     chunk before it, and a stale one already in the past would anchor
		     this chunk on the first frame its velocity dipped — mid-flight. ]]
		slot.settleAt = 0
		--[[ Only while it is actually travelling. Long enough to draw the arc,
		     short enough that a chunk which has landed is not still bleeding. ]]
		slot.trailUntil = now + GIB_TRAIL_SECONDS
		slot.trail.Enabled = true
		--[[ From the shared seed, so the same chunks mark the floor on every
		     client and four players walk through one room rather than four. ]]
		slot.mark = rng:NextNumber() < GIBS.LandMarkChance
	end
end

local function retireGib(slot: GibSlot)
	slot.expiresAt = 0
	slot.trailUntil = 0
	slot.settleAt = 0
	--[[ Cleared, or a chunk retired in mid-air would hand its unspent mark to
	     whatever the slot is thrown as next. ]]
	slot.mark = false
	slot.trail.Enabled = false
	local part = slot.part
	part.Anchored = true
	part.Transparency = 1
	part.AssemblyLinearVelocity = Vector3.zero
	part.AssemblyAngularVelocity = Vector3.zero
end

local function updateGibs(now: number)
	for _, slot in gibs do
		--[[ The trail stops long before the chunk does. A gib lives twelve
		     seconds and is airborne for well under one of them; leaving the
		     emitter running is ninety emitters bleeding into the floor. ]]
		if slot.trailUntil > 0 and now >= slot.trailUntil then
			slot.trailUntil = 0
			slot.trail.Enabled = false
		end
		if slot.expiresAt > 0 and now >= slot.expiresAt then
			retireGib(slot)
			continue
		end

		--[[
			A chunk that has come to rest stops being a physics body.

			Same trade GoreService makes for corpses, and for the same reason: a
			gib is airborne for well under a second and then lies on the floor for
			eleven more, and for those eleven the solver is still integrating it,
			resolving its contacts and waking it whenever something brushes past.
			Ninety of those is a constant physics load on the client for chunks
			that are, visibly, not going anywhere.

			Anchoring is invisible at the moment it happens because it only
			happens after the chunk has been under GIB_SETTLE_SPEED for
			GIB_SETTLE_TIME. Roblox's own sleeping does some of this, but a body
			resting on another body it can collide with is woken constantly during
			a horde, which is exactly when this needs to hold.
		]]
		if slot.expiresAt > 0 and not slot.part.Anchored then
			if slot.part.AssemblyLinearVelocity.Magnitude >= GIB_SETTLE_SPEED then
				slot.settleAt = 0
			elseif slot.settleAt == 0 then
				slot.settleAt = now + GIB_SETTLE_TIME
			elseif now >= slot.settleAt then
				slot.settleAt = 0
				slot.part.Anchored = true
				--[[ The moment it stops is the moment it has landed somewhere, and
				     the only moment worth a raycast: once per chunk, not once per
				     sweep. Straight down rather than along the shot, because what
				     is being marked is the floor it came to rest on. ]]
				if slot.mark then
					slot.mark = false
					projectDecal(
						slot.part.Position,
						-Vector3.yAxis,
						GIBS.LandMarkScale,
						nil,
						GIBS.LandMarkLifetime
					)
				end
			end
		end
	end
end

-- ── screen blood (fallback only) ────────────────────────────────────────────

--[[ Built ONLY when OverlayController is absent. It already owns lens blood,
     reading the same GoreConfig.ScreenBlood numbers off DamageTaken, and two
     droplet layers on one screen is twice the blood the config asked for. ]]
local function buildScreenLayer()
	local gui = Instance.new("ScreenGui")
	gui.Name = "FL_ScreenBlood"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = UITheme.DisplayOrder.Vignette
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = player:WaitForChild("PlayerGui")
	trove:add(gui)
	screenGui = gui

	for index = 1, SCREEN.MaxDroplets do
		local frame = Instance.new("Frame")
		frame.Name = "Droplet" .. index
		frame.AnchorPoint = Vector2.new(0.5, 0.5)
		frame.BackgroundColor3 = UITheme.Color.Blood
		frame.BackgroundTransparency = 1
		frame.BorderSizePixel = 0
		frame.Visible = false
		frame.Parent = gui

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0.5, 0)
		corner.Parent = frame

		droplets[index] = { frame = frame, age = SCREEN.FadeTime, peak = 0 }
	end
end

local function spawnDroplets(count: number)
	if not SCREEN.Enabled or #droplets == 0 then
		return
	end
	for _ = 1, count do
		dropletCursor = (dropletCursor % #droplets) + 1
		local entry = droplets[dropletCursor]
		--[[ Sized in REFERENCE pixels, like everything else that lays out in
		     offsets. Raw pixels made a droplet cover three times as much of a
		     phone as of a desktop — 14% of a handset's height at the top of the
		     range against 5% at 1080p — so being hit on mobile blacked out the
		     screen in a way it never did anywhere else. ]]
		local scale = ScaleLayer.getFactor()
		local size = random:NextNumber(18, 56) * scale
		entry.frame.Size = UDim2.fromOffset(size, size * random:NextNumber(0.5, 1.15))
		entry.frame.Position = UDim2.fromScale(random:NextNumber(0.04, 0.96), random:NextNumber(0.04, 0.96))
		entry.frame.Rotation = random:NextNumber(0, 180)
		entry.peak = random:NextNumber(0.25, 0.55)
		entry.age = 0
		entry.frame.BackgroundTransparency = entry.peak
		entry.frame.Visible = true
	end
end

local function updateDroplets(deltaTime: number)
	for _, entry in droplets do
		if entry.age < SCREEN.FadeTime then
			entry.age += deltaTime
			local alpha = math.clamp(entry.age / SCREEN.FadeTime, 0, 1)
			entry.frame.BackgroundTransparency = entry.peak + (1 - entry.peak) * alpha
			if alpha >= 1 then
				entry.frame.Visible = false
			end
		end
	end
end

-- ── the event ───────────────────────────────────────────────────────────────

--[[
	Blood on the lens from a kill YOU made.

	This layer only ever fired when the player was hit, which left the most
	violent thing in the game — a shotgun through a Common's chest at contact
	range — entirely off the camera. Standing inside the spray and catching none
	of it was the one moment the gore system was not selling.

	Only a body coming APART, and only close. Every hit would be a permanently
	red screen, and a kill across the room is not something you would wear.

	── THE COOLDOWN IS NOT POLISH ──────────────────────────────────────────────
	A horde dies in clumps. Three bodies gibbed inside the same tenth of a second
	are ONE event to the eye and should be one splash; ungated they are three,
	and three lands as a wash that hides the next Common walking through it. The
	gate is what keeps this a punctuation mark rather than a screen effect.
]]
local lastSplashAt = 0

local function splashLens(position: Vector3, level: string?)
	if not SCREEN.SplashOnKill then
		return
	end
	--[[ Incinerate is deliberately absent as well as everything below Dismember:
	     a burning body throws embers and smoke, and red on the lens from one
	     would read as a wound the player does not have. ]]
	if level ~= LEVEL.Gib and level ~= LEVEL.Dismember then
		return
	end

	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	local delta = position - camera.CFrame.Position
	if delta:Dot(delta) > SCREEN.SplashDistance * SCREEN.SplashDistance then
		return
	end

	local now = os.clock()
	if now - lastSplashAt < SCREEN.SplashCooldown then
		return
	end
	lastSplashAt = now

	--[[ Through the public method rather than straight to spawnDroplets, because
	     that is where the gore-off check and the OverlayController hand-off live,
	     and a player who turned gore off did not ask for a red screen. ]]
	GoreController:screenBlood(SCREEN.SplashDroplets)
end

local function onGoreEvent(payload: any)
	if not enabled or typeof(payload) ~= "table" then
		return
	end
	local position = payload.position
	if typeof(position) ~= "Vector3" or tooFar(position) then
		return
	end

	local scale = if typeof(payload.scale) == "number" then math.max(payload.scale, 0) else 1
	local normal = unitOr(payload.normal, Vector3.yAxis)
	local direction = unitOr(payload.direction, -normal)

	--[[ A settled body. No spray, no decal — just the stain spreading under it,
	     which is what makes a room look fought-in a minute later. ]]
	if payload.pool == true then
		growPool(position)
		return
	end

	local level = payload.level
	burst(position, normal, scale, if level == LEVEL.Incinerate then "Char" else "Blood")

	--[[ A stump throws blood along the bone rather than back down the bullet,
	     so it gets a second burst aimed away from the body. GoreConfig's own
	     BLOOD_SCALE_DISMEMBER is already in `scale`; this is the direction, not
	     more volume. ]]
	if level == LEVEL.Dismember then
		burst(position + normal * 0.35, normal, scale * 0.5, "Blood")
	end

	if payload.decal == true and level ~= LEVEL.Incinerate then
		projectDecal(position, direction, scale, payload.model)
	end

	if level == LEVEL.Gib then
		local seed = if typeof(payload.seed) == "number" then payload.seed else 0
		spawnGibs(position, direction, seed, payload.count)
	end

	splashLens(position, level)
end

-- ── public API ──────────────────────────────────────────────────────────────

--[[
	Blood on the lens, for the player being hit rather than the one shooting.

	Routed to OverlayController when it exists — it owns the vignette and the
	bile wash, and lens blood belongs on the same layer as those or it composites
	wrong. The local droplet pool below exists only so that a client running
	without that controller still gets the feedback.
]]
function GoreController:screenBlood(count: number?)
	--[[ `enabled` as well as the config flag: a player who turned gore off did
	     not ask for a clean kill and a red screen. The damage vignette is
	     OverlayController's and is untouched by the setting — that one is a
	     health readout, not gore. ]]
	if not SCREEN.Enabled or not enabled then
		return
	end
	local overlay = Registry.find("OverlayController")
	if overlay and typeof(overlay.screenEffect) == "function" then
		local ok = pcall(overlay.screenEffect, overlay, OVERLAY_BLOOD_EFFECT, nil, 1)
		if ok then
			return
		end
	end
	if not screenGui then
		buildScreenLayer()
	end
	spawnDroplets(count or SCREEN.DropletsPerHit)
end

--[[ Blood at a world position, for anything that wants some and has no gore
     event to ride on — a thrown bile jar, a melee finisher, a scripted set
     piece. `scale` multiplies GoreConfig.Blood's particle counts. ]]
function GoreController:spawnBlood(position: Vector3, normal: Vector3?, scale: number?)
	if not enabled or typeof(position) ~= "Vector3" or tooFar(position) then
		return
	end
	burst(position, unitOr(normal, Vector3.yAxis), math.max(scale or 1, 0), "Blood")
end

function GoreController:setEnabled(value: boolean)
	enabled = value == true and GoreConfig.Enabled
end

--[[
	Scales this client's particle budget by the player's quality setting.

	`scale` is 0-1 from SettingsConfig.Quality. It never RAISES the budget: the
	device ceiling is a hardware fact and the setting can only ask for less than
	it, so the two are multiplied rather than the setting replacing the ceiling.

	Only new bursts are affected. What is already on screen keeps the count it
	was born with, which is invisible — a burst lives under a second.
]]
function GoreController:setQuality(scale: number)
	qualityScale = if typeof(scale) == "number" and scale == scale then math.clamp(scale, 0, 1) else 1
	particleScale = DEVICE_BUDGET.particles * qualityScale
end

function GoreController:getQuality(): number
	return particleScale
end

function GoreController:isEnabled(): boolean
	return enabled
end

--[[ What is on screen right now, for a debug overlay. The mirror of
     GoreService:getActiveCounts, for the half of the gore this client owns. ]]
function GoreController:getActiveCounts(): { gibs: number, decals: number }
	local liveGibs, liveDecals = 0, 0
	for _, slot in gibs do
		if slot.expiresAt > 0 then
			liveGibs += 1
		end
	end
	for _, slot in decals do
		if slot.expiresAt > 0 then
			liveDecals += 1
		end
	end
	return { gibs = liveGibs, decals = liveDecals }
end

-- ── lifecycle ───────────────────────────────────────────────────────────────

local function update(deltaTime: number)
	-- Only ever non-empty when this controller owns the lens, but keyed off the
	-- pool rather than off the flag so a droplet can never be left frozen on
	-- screen by a late fallback.
	if #droplets > 0 then
		updateDroplets(deltaTime)
	end

	sweepAccumulator += deltaTime
	if sweepAccumulator < SWEEP_INTERVAL then
		return
	end
	sweepAccumulator = 0

	local now = os.clock()
	updateGibs(now)
	updateDecals(now)
end

--[[
	Re-reads the device budget and the ceilings that come off it.

	Called from init and again whenever Device.changed fires, and both matter for
	the same reason: at MODULE scope the camera may not exist yet, and Device
	deliberately answers Mobile in that case rather than guessing upward. Sizing
	a desktop's pools from that answer would be the low-budget bug in reverse —
	so the numbers above are a floor, and this is the measurement.

	Raising a ceiling afterwards is safe: `gibSlot` and `decalSlot` create their
	slots on demand, so a larger MAX simply lets the ring buffer grow into it.
	Lowering one leaves a few slots past the cursor that are never reused again,
	which is a handful of parts and not worth code to reclaim.
]]
local function adoptDeviceBudget()
	DEVICE_BUDGET = GoreConfig.budgetFor(Device.get())
	MAX_GIBS = math.min(BUDGET.MaxActiveGibs, GameConfig.Corpses.MaxGibs, DEVICE_BUDGET.gibs)
	MAX_DECALS = math.min(BUDGET.MaxActiveDecals, GameConfig.Corpses.MaxBloodDecals, DEVICE_BUDGET.decals)
	particleScale = DEVICE_BUDGET.particles * qualityScale
end

function GoreController:init()
	folder = Instance.new("Folder")
	folder.Name = "FL_Gore"
	folder.Parent = Workspace
	trove:add(folder)

	decalParams.FilterType = Enum.RaycastFilterType.Exclude
	decalParams.IgnoreWater = true
	decalParams.RespectCanCollide = false

	--[[ The camera exists by now, so this is the first answer worth trusting —
	     see adoptDeviceBudget. ]]
	adoptDeviceBudget()
	trove:add(Device.changed:connect(adoptDeviceBudget))
end

function GoreController:start()
	--[[ Decided once, here, rather than per hit: every controller has been
	     required by now, so a missing OverlayController is missing for good and
	     this client owns its own lens blood for the session. ]]
	local overlay = Registry.find("OverlayController")
	overlayOwnsScreenBlood = overlay ~= nil and typeof(overlay.screenEffect) == "function"
	if not overlayOwnsScreenBlood then
		buildScreenLayer()
		--[[ Only connected in the fallback case. OverlayController listens to
		     this same remote and spawns DropletsPerHit off it, so connecting
		     here as well would double the blood on every hit taken. ]]
		trove:connect(Remotes.Event.DamageTaken.OnClientEvent, function(payload: any)
			if typeof(payload) == "table" then
				spawnDroplets(SCREEN.DropletsPerHit)
			end
		end)
	end

	trove:connect(Remotes.Event.GoreEvent.OnClientEvent, onGoreEvent)
	trove:connect(RunService.Heartbeat, update)
end

function GoreController:destroy()
	trove:destroy()
	table.clear(sprays)
	table.clear(gibs)
	table.clear(decals)
	table.clear(droplets)
	screenGui = nil
end

Registry.register("GoreController", GoreController)

return GoreController
