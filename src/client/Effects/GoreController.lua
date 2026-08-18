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
local Registry = require(Shared.Util.Registry)
local Remotes = require(Shared.Net.Remotes)
local Trove = require(Shared.Util.Trove)
local UITheme = require(Shared.Config.UITheme)

local BLOOD = GoreConfig.Blood
local GIBS = GoreConfig.Gibs
local BUDGET = GoreConfig.Budget
local SCREEN = GoreConfig.ScreenBlood
local LEVEL = Enums.GoreLevel

--[[ GameConfig.Corpses restates two of GoreConfig.Budget's ceilings. Rather
     than pick a winner and let the other drift into a lie, take the tighter of
     each pair — the same rule GoreService applies on the server, so the two
     ledgers cannot disagree about what the budget is. ]]
local MAX_GIBS = math.min(BUDGET.MaxActiveGibs, GameConfig.Corpses.MaxGibs)
local MAX_DECALS = math.min(BUDGET.MaxActiveDecals, GameConfig.Corpses.MaxBloodDecals)

local CULL_DISTANCE_SQUARED = BUDGET.CullDistance * BUDGET.CullDistance

-- Blood spray and mist bursts are short. Twenty nodes is more than the server's
-- MaxGoreEventsPerSecond can fill inside one MistLifetime, so a node is never
-- re-aimed while its own mist is still hanging.
local SPRAY_POOL = 20

-- Expiry, fades and pool growth all run on human timescales. Sweeping at 20Hz
-- instead of 60 is the same behaviour for a third of the cost.
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
	},
}

-- ── state ───────────────────────────────────────────────────────────────────

local GoreController = {}

local player = Players.LocalPlayer
local trove = Trove.new()

local folder: Folder
local enabled = GoreConfig.Enabled

type SpraySlot = { part: BasePart, spray: ParticleEmitter, mist: ParticleEmitter, style: string? }
type GibSlot = { part: BasePart, expiresAt: number }
type DecalSlot = {
	part: BasePart,
	expiresAt: number,
	transparency: number,
	growUntil: number, -- 0 unless this is a pool that is still spreading
	targetSize: number,
	normal: Vector3,
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

local function newEmitter(host: BasePart, name: string, texture: string): ParticleEmitter
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = name
	emitter.Texture = texture
	-- Emit along the part's front face, which faceAlong aims down the normal.
	emitter.EmissionDirection = Enum.NormalId.Front
	emitter.Enabled = false
	emitter.Rate = 0
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.RotSpeed = NumberRange.new(-140, 140)
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
			spray = newEmitter(part, "Spray", SPRAY_TEXTURE),
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
	slot.spray:Emit(math.max(1, math.floor(BLOOD.SprayParticles * scale + 0.5)))
	slot.mist:Emit(math.max(1, math.floor(BLOOD.MistParticles * scale + 0.5)))
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
	part.Color = if random:NextNumber() < 0.5 then BLOOD.Color else BLOOD.DarkColor
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
local function projectDecal(position: Vector3, direction: Vector3, scale: number, body: Instance?)
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
	slot.expiresAt = os.clock() + BLOOD.DecalLifetime
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
		--[[ GoreConfig.Gibs.CollideWithPlayers is false, and the "Gib" group is
		     exactly that rule: it collides with Default and nothing else, so a
		     chunk bounces off the floor and never shoves a survivor. ]]
		local group = resolveGibGroup()
		if group then
			part.CollisionGroup = group
		end
		slot = { part = part, expiresAt = 0 }
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
		slot.expiresAt = os.clock() + GIBS.Lifetime
	end
end

local function retireGib(slot: GibSlot)
	slot.expiresAt = 0
	local part = slot.part
	part.Anchored = true
	part.Transparency = 1
	part.AssemblyLinearVelocity = Vector3.zero
	part.AssemblyAngularVelocity = Vector3.zero
end

local function updateGibs(now: number)
	for _, slot in gibs do
		if slot.expiresAt > 0 and now >= slot.expiresAt then
			retireGib(slot)
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
		local size = random:NextNumber(18, 56)
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
	if not SCREEN.Enabled then
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

function GoreController:init()
	folder = Instance.new("Folder")
	folder.Name = "FL_Gore"
	folder.Parent = Workspace
	trove:add(folder)

	decalParams.FilterType = Enum.RaycastFilterType.Exclude
	decalParams.IgnoreWater = true
	decalParams.RespectCanCollide = false
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
