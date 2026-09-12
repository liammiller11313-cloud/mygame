--!nonstrict
--[[
	AbilityEffects — what the five abilities look like.

	Every one of these is cosmetic and arrives after the fact. The damage, the
	healing, the slow and the turret's own body all happened on the server before
	the broadcast that gets here was sent, so nothing in this file can change an
	outcome and nothing in it needs to be trusted. That is why it can be as
	cheap and as fire-and-forget as it is.

	── WHAT IS DRAWN HERE AND WHAT IS NOT ──────────────────────────────────────
	The shield bubble and the turret are real server-made Instances: they have
	positions the whole server has to agree on, and Roblox replicates them for
	free. This file does not draw those. What it draws is everything with no
	physical existence — a tracer, a heal pulse, a frost field, an airstrike
	marker, a blast — because those are moments rather than objects.

	The airstrike marker is the important one. It is drawn from the same
	broadcast on every client at the same moment, which is what makes it a
	warning the whole team shares rather than a private one.

	── EVERYTHING CLEANS ITSELF UP ─────────────────────────────────────────────
	Each effect is a part with a Debris lifetime and a tween. There is no pool
	and no per-frame loop: these fire on the order of once every thirty seconds
	per player, and a pool for that is a cache that is always cold.
]]

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local AbilityConfig = require(Shared.Config.AbilityConfig)
local Enums = require(Shared.Enums)
local Registry = require(Shared.Util.Registry)
local Remotes = require(Shared.Net.Remotes)
local Trove = require(Shared.Util.Trove)
local UITheme = require(Shared.Config.UITheme)

local COLOR = UITheme.Color

local CRYO_COLOR = Color3.fromRGB(122, 196, 226)

--[[ The walrus breath. Built-in textures on purpose, the same two every other
     effect file in this folder uses: they ship with the engine, so there is no
     asset to fail to load on the one frame somebody needs to see a cone of fire
     coming at them. ]]
local FLAME_TEXTURE = "rbxasset://textures/particles/fire_main.dds"
local FLAME_SMOKE_TEXTURE = "rbxasset://textures/particles/smoke_main.dds"

--[[ How long the particle lives, and therefore how the speed is solved.

     The breath's REACH is a server number — AbilityConfig's FlameRange, which
     rides every broadcast — and a flame that stops short of what it is killing
     reads as a bug in the damage rather than a choice about the art. So the
     lifetime is fixed here and the speed is worked out from the range that
     arrived: range / lifetime, which puts the last particle at the last stud of
     the cone at the moment it dies. ]]
local FLAME_LIFETIME = 0.42

--[[ How long one broadcast keeps the flame lit.

     The server sends one of these per FlameTick (0.15s) while the button is
     held, so the flame has to survive the GAP between them or it strobes. A
     little over two ticks: long enough that a dropped packet does not blink it,
     short enough that letting go stops it inside a fifth of a second. ]]
local FLAME_HOLD = 0.34

--[[ How fast the emitter catches up to where the server last said the walrus
     was pointing, as a fraction per 60th of a second.

     Not a snap. Six updates a second against a head that can turn as fast as
     the mouse does means a snapped cone jumps in visible steps; lerping the
     WHOLE transform — position and facing together — turns those steps into the
     sweep the player is actually performing. ]]
local FLAME_FOLLOW = 0.35

--[[ The airstrike's own numbers, including the flyover meshes. Read once: this
     is a frozen table and re-reaching through the config on every strike is a
     table walk for values that cannot change. ]]
local STRIKE = AbilityConfig.get(Enums.Ability.Airstrike).tuning

local AbilityEffects = {}

local trove = Trove.new()

--[[ The folder everything here goes in. One place to look in the explorer, and
     one thing to destroy if this controller is ever torn down — a stray
     airstrike marker with no owner is the kind of thing that outlives a round
     and confuses everybody. ]]
local folder: Folder?

local function decorate(part: BasePart)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Parent = folder
end

--[[ A flat disc on the ground. The shape three of these five want — a heal
     radius, a frost field and an airstrike footprint are all "this circle of
     floor" — and a cylinder lying down is the cheapest honest way to say it. ]]
local function disc(position: Vector3, radius: number, color: Color3, transparency: number): BasePart
	local part = Instance.new("Part")
	part.Name = "FL_AbilityDisc"
	part.Shape = Enum.PartType.Cylinder
	part.Size = Vector3.new(0.4, radius * 2, radius * 2)
	--[[ Rotated onto its face: a Roblox cylinder's length runs down X, so a disc
	     lying flat is a quarter turn about Z. ]]
	part.CFrame = CFrame.new(position) * CFrame.Angles(0, 0, math.rad(90))
	part.Color = color
	part.Material = Enum.Material.Neon
	part.Transparency = transparency
	decorate(part)
	return part
end

local function fade(part: BasePart, seconds: number, from: number)
	part.Transparency = from
	TweenService:Create(part, TweenInfo.new(seconds, Enum.EasingStyle.Linear), { Transparency = 1 }):Play()
	Debris:AddItem(part, seconds + 0.1)
end

-- ── the effects ─────────────────────────────────────────────────────────────

--[[ One tracer per turret shot. A thin, short-lived beam rather than a
     projectile: the shot has already landed on the server, so anything that
     travels here would be a lie about when it hit. ]]
local function turretShot(payload: any)
	if typeof(payload.origin) ~= "Vector3" or typeof(payload.hit) ~= "Vector3" then
		return
	end
	local delta = payload.hit - payload.origin
	local distance = delta.Magnitude
	if distance < 0.5 then
		return
	end

	local beam = Instance.new("Part")
	beam.Name = "FL_TurretTracer"
	beam.Size = Vector3.new(0.12, 0.12, distance)
	beam.CFrame = CFrame.lookAt(payload.origin + delta * 0.5, payload.hit)
	beam.Color = COLOR.AccentBright
	beam.Material = Enum.Material.Neon
	decorate(beam)
	fade(beam, 0.09, 0.15)
end

--[[ A ring that grows out to the heal radius. Growing rather than appearing at
     full size, because the thing a player needs to read is "this reached me",
     and a circle that arrives already drawn does not say that. ]]
local function healPulse(payload: any)
	if typeof(payload.position) ~= "Vector3" then
		return
	end
	local radius = tonumber(payload.radius) or 20
	local part = disc(payload.position, radius * 0.2, COLOR.HealthGood, 0.55)
	TweenService:Create(part, TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(0.4, radius * 2, radius * 2),
		Transparency = 1,
	}):Play()
	Debris:AddItem(part, 0.6)
end

--[[ The frost field, for as long as the slow lasts. This one is NOT a moment —
     it is a place the team can stand behind and shoot into, so it holds for the
     ability's whole duration and then fades rather than pulsing. ]]
local function cryoField(payload: any)
	if typeof(payload.position) ~= "Vector3" then
		return
	end
	local radius = tonumber(payload.radius) or 20
	local duration = tonumber(payload.duration) or 6
	local part = disc(payload.position, radius, CRYO_COLOR, 0.9)

	TweenService:Create(part, TweenInfo.new(0.25), { Transparency = 0.62 }):Play()
	task.delay(math.max(duration - 0.6, 0), function()
		if part.Parent then
			fade(part, 0.6, part.Transparency)
		end
	end)
	Debris:AddItem(part, duration + 1)
end

--[[
	The plane that drops it, and the bombs falling out of it.

	Entirely cosmetic, and it is worth saying twice because this is the one
	effect in the file that LOOKS like it should be doing damage. It is not: no
	collision, no Humanoid, no Explosion instance, no Touched handler. The
	shells are the server's, they are already scheduled, and they land whether
	or not a single frame of this ever renders. Deleting this function changes
	how the airstrike looks and nothing about what it does.

	── EVERY TIME IN HERE IS DERIVED ───────────────────────────────────────────
	One number is chosen — how long the plane takes to cross its run — and the
	rest falls out of it, of the altitude, and of the warning the server already
	sent:

	  the bombs fall for  sqrt(2 * height / gravity)      — actual free-fall
	  so they are let go  that long before the shells land
	  the plane launches  half a crossing before the shells land, so it is
	                      overhead at the moment they do
	  and it lets go      wherever it has got to by then, which works out as
	                      exactly its own speed times the fall — the throw that
	                      carries the bombs from the plane to the marker

	Nothing here needs re-tuning when WarningTime changes, and none of those
	agreements can quietly drift apart, because there is only one of each.

	── THE BOMBS ARE UNANCHORED ON PURPOSE ─────────────────────────────────────
	They are given the plane's velocity and then left to Roblox's own gravity,
	which is the whole arc for free and is correct rather than approximated. A
	tween would have to fake the parabola, and this file has no per-frame loop
	to do it properly with.
]]
local function flyover(position: Vector3, warning: number, heading: Vector3)
	local flat = Vector3.new(heading.X, 0, heading.Z)
	local run = if flat.Magnitude > 0.05 then flat.Unit else Vector3.zAxis
	local cross = STRIKE.JetCrossSeconds
	local altitude = Vector3.new(0, STRIKE.JetHeight, 0)
	local from = position - run * STRIKE.JetRunway + altitude
	local to = position + run * STRIKE.JetRunway + altitude
	local speed = (STRIKE.JetRunway * 2) / cross

	--[[ Read rather than assumed: a map that sets its own gravity would
	     otherwise get bombs that miss by the difference. Guarded because zero
	     gravity would divide the fall time by nothing. ]]
	local gravity = math.max(Workspace.Gravity, 1)
	local fall = math.sqrt((2 * STRIKE.JetHeight) / gravity)

	--[[ Launched half a crossing before the shells, so it is over the target as
	     they land. Clamped at zero: a warning shorter than half a crossing gets
	     a plane that arrives late rather than one that needed to launch before
	     the player pressed the button. ]]
	task.delay(math.max(warning - cross * 0.5, 0), function()
		if not folder then
			return
		end
		local jet = Instance.new("Part")
		jet.Name = "FL_StrikeJet"
		--[[ The block under the mesh is the fallback silhouette. Roblox renders
		     nothing at all for a MeshId that fails to load, so the part's own
		     shape has to be something a player two hundred studs below would
		     still read as an aircraft crossing the sky. ]]
		jet.Size = Vector3.new(18, 4, 34)
		jet.Color = COLOR.Border
		jet.CFrame = CFrame.lookAt(from, from + run)
		decorate(jet)

		local mesh = Instance.new("SpecialMesh")
		mesh.MeshType = Enum.MeshType.FileMesh
		mesh.MeshId = STRIKE.JetMeshId
		mesh.TextureId = STRIKE.JetTextureId
		mesh.Scale = Vector3.new(10, 10, 10)
		mesh.Parent = jet

		--[[ A contrail, so the plane is findable in a dark sky — which is every
		     round past the first. Trail rather than Smoke: Smoke costs the same
		     whether it is two studs away or two hundred, and this is always two
		     hundred. ]]
		local ahead = Instance.new("Attachment")
		ahead.Position = Vector3.new(0, 0, 6)
		ahead.Parent = jet
		local behind = Instance.new("Attachment")
		behind.Position = Vector3.new(0, 0, 14)
		behind.Parent = jet

		local trail = Instance.new("Trail")
		trail.Attachment0 = ahead
		trail.Attachment1 = behind
		trail.Lifetime = 1.6
		trail.Transparency = NumberSequence.new(0.4, 1)
		trail.Color = ColorSequence.new(Color3.fromRGB(190, 190, 190))
		trail.LightEmission = 0.2
		trail.Parent = jet

		--[[ Linear, and deliberately not eased. An aircraft crossing the sky
		     does not accelerate into frame or settle out of it, and any easing
		     makes this look like a UI element shaped like a plane. ]]
		TweenService:Create(jet, TweenInfo.new(cross, Enum.EasingStyle.Linear), {
			CFrame = CFrame.lookAt(to, to + run),
		}):Play()
		Debris:AddItem(jet, cross + 0.5)
	end)

	--[[ Let go one fall before the shells land, from the point the plane's own
	     forward throw carries them to the marker. ]]
	task.delay(math.max(warning - fall, 0), function()
		if not folder then
			return
		end
		local dropFrom = position - run * (speed * fall) + altitude
		local velocity = run * speed
		--[[ A stick of three across the line of flight. One bomb is a dropped
		     object; three is a plane doing a job. They are Debris'd as the shells
		     land rather than exploding — the blast that follows is the server's,
		     and a second one here would be the client inventing damage it has no
		     ability to deal. ]]
		for index = -1, 1 do
			local bomb = Instance.new("Part")
			bomb.Name = "FL_StrikeBomb"
			bomb.Size = Vector3.new(1.5, 1.5, 5)
			bomb.Color = COLOR.Border
			bomb.CFrame = CFrame.lookAt(dropFrom + run * index * 12, dropFrom + run)
			decorate(bomb)
			--[[ decorate anchors everything, which is right for every other
			     effect in this file and wrong for the one thing here that is
			     meant to fall. Unanchored and uncollidable: gravity draws the
			     arc, nothing can be hit by it, and it is a client-local part so
			     it is simulated here and replicated nowhere. ]]
			bomb.Anchored = false
			bomb.AssemblyLinearVelocity = velocity

			local bombMesh = Instance.new("SpecialMesh")
			bombMesh.MeshType = Enum.MeshType.FileMesh
			bombMesh.MeshId = STRIKE.BombMeshId
			bombMesh.TextureId = STRIKE.BombTextureId
			bombMesh.Scale = Vector3.new(6, 6, 6)
			bombMesh.Parent = bomb

			Debris:AddItem(bomb, fall)
		end
	end)
end

--[[ The airstrike warning. The most important thing in this file: it is the
     only reason 260 damage across five shells is fair, and it has to be
     unmistakable from any angle and at any distance. ]]
local function marker(payload: any)
	if typeof(payload.position) ~= "Vector3" then
		return
	end
	local radius = tonumber(payload.radius) or 16
	local warning = tonumber(payload.warning) or 2.5

	--[[ The plane, if the server sent a heading. Older payloads and any other
	     ability that ever broadcasts a Marker simply do not get one, which is
	     why this is a check rather than a default — a jet flying over a cryo
	     field would be worse than no jet. ]]
	if typeof(payload.heading) == "Vector3" then
		flyover(payload.position, warning, payload.heading)
	end

	local ring = disc(payload.position, radius, COLOR.Danger, 0.5)
	--[[ Pulsing rather than steady. A static red circle reads as scenery on a
	     map that already has red in it; one that beats reads as a countdown, and
	     the beat is the only clock the player gets. ]]
	local pulse = TweenService:Create(
		ring,
		TweenInfo.new(0.35, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ Transparency = 0.82 }
	)
	pulse:Play()
	Debris:AddItem(ring, warning + 0.4)

	--[[ A column of light standing in it, so the marker is visible from cover
	     and from above rather than only by somebody looking at the floor. ]]
	local column = Instance.new("Part")
	column.Name = "FL_StrikeColumn"
	column.Size = Vector3.new(radius * 0.5, 90, radius * 0.5)
	column.CFrame = CFrame.new(payload.position + Vector3.new(0, 45, 0))
	column.Color = COLOR.Danger
	column.Material = Enum.Material.Neon
	column.Transparency = 0.93
	decorate(column)
	Debris:AddItem(column, warning + 0.2)
end

local function blast(payload: any)
	if typeof(payload.position) ~= "Vector3" then
		return
	end
	local radius = tonumber(payload.radius) or 16

	local ball = Instance.new("Part")
	ball.Name = "FL_Blast"
	ball.Shape = Enum.PartType.Ball
	ball.Size = Vector3.new(radius * 0.4, radius * 0.4, radius * 0.4)
	ball.CFrame = CFrame.new(payload.position)
	ball.Color = COLOR.AccentBright
	ball.Material = Enum.Material.Neon
	decorate(ball)
	TweenService:Create(ball, TweenInfo.new(0.32, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(radius * 2, radius * 2, radius * 2),
		Transparency = 1,
	}):Play()
	Debris:AddItem(ball, 0.4)

	--[[ No light flash. AtmosphereService owns the round's brightness and has a
	     pulse for exactly this, but it lives on the SERVER — calling it from here
	     would do nothing, and a second client-side brightness system would fight
	     the one that is already driving the sky. If an airstrike should light the
	     street, the flash belongs in the Airstrike module beside the explosion it
	     is lighting. ]]
end

--[[
	── THE WALRUS BREATH ───────────────────────────────────────────────────────
	The one effect in this file that is not a moment.

	Everything else here fires once and fades: a tracer, a heal pulse, a blast.
	The breath is HELD — the server re-broadcasts it every FlameTick for as long
	as the button is down — so drawing it the way the others are drawn would be
	six separate puffs a second with a visible gap between each one.

	So it is a lamp rather than a flash. One node per breathing player, kept
	alive between broadcasts, switched on by each one and switched off by a
	deadline that each one pushes forward. The broadcasts stop, the deadline
	passes, the flame goes out on its own. Nothing has to send a "stopped".

	── WHY IT FOLLOWS RATHER THAN JUMPS ────────────────────────────────────────
	The payload carries where the mouth was and which way it pointed at the
	instant the server charged a tick. Six of those a second is plenty to damage
	with and nowhere near enough to LOOK like a sweep: dropped straight onto the
	node it reads as a cone teleporting between six poses. The node lerps toward
	the last pose instead, so a player turning through a crowd draws the arc they
	are actually describing.

	── IT IS DRAWN FOR EVERYONE, INCLUDING THE WALRUS ──────────────────────────
	Deliberately. This is a third-person ability — the player is driving a body
	they can see — so the same cone that tells the team where not to stand is the
	cone the walrus is aiming with. There is no first-person case to special-case.
]]
type FlameNode = {
	part: BasePart,
	fire: ParticleEmitter,
	smoke: ParticleEmitter,
	light: PointLight,
	target: CFrame,
	until_: number,
	range: number,
	angle: number,
}

local flames: { [Player]: FlameNode } = {}
local flameStep: RBXScriptConnection? = nil

local function newFlameEmitter(host: BasePart, name: string, texture: string): ParticleEmitter
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = name
	emitter.Texture = texture
	-- Out of the node's front face, which is the face aimAt points down the cone.
	emitter.EmissionDirection = Enum.NormalId.Front
	emitter.Enabled = false
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.RotSpeed = NumberRange.new(-90, 90)
	emitter.LightEmission = 1
	emitter.LightInfluence = 0
	emitter.Parent = host
	return emitter
end

local function flameNode(player: Player): FlameNode?
	local existing = flames[player]
	if existing and existing.part.Parent then
		return existing
	end
	if not folder or not folder.Parent then
		return nil
	end

	local part = Instance.new("Part")
	part.Name = "FL_WalrusBreath"
	part.Size = Vector3.new(0.2, 0.2, 0.2)
	part.Transparency = 1
	decorate(part)

	local fire = newFlameEmitter(part, "Fire", FLAME_TEXTURE)
	fire.Lifetime = NumberRange.new(FLAME_LIFETIME * 0.7, FLAME_LIFETIME)
	--[[ Fat at the mouth, fatter down the cone, gone at the end. The widening is
	     what makes a stream of particles read as a CONE rather than a jet, and
	     it is the same shape the damage test uses. ]]
	fire.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1.6),
		NumberSequenceKeypoint.new(0.45, 7.0),
		NumberSequenceKeypoint.new(1, 11.0),
	})
	--[[ White-hot at the mouth through orange to a dull red at the tip. Colour
	     is doing the distance cue here: the hot end is where it kills. ]]
	fire.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 244, 214)),
		ColorSequenceKeypoint.new(0.3, Color3.fromRGB(255, 176, 62)),
		ColorSequenceKeypoint.new(0.75, Color3.fromRGB(224, 88, 32)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(112, 32, 18)),
	})
	fire.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.45),
		NumberSequenceKeypoint.new(0.25, 0.15),
		NumberSequenceKeypoint.new(1, 1),
	})
	fire.Rate = 190
	-- Dragged, so the tip of the cone slows and billows instead of ending flat.
	fire.Drag = 2.5
	fire.Acceleration = Vector3.new(0, 9, 0)

	local smoke = newFlameEmitter(part, "Smoke", FLAME_SMOKE_TEXTURE)
	smoke.Lifetime = NumberRange.new(FLAME_LIFETIME * 1.6, FLAME_LIFETIME * 2.6)
	smoke.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 3.0),
		NumberSequenceKeypoint.new(1, 15.0),
	})
	smoke.Color = ColorSequence.new(Color3.fromRGB(58, 48, 44))
	smoke.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.75),
		NumberSequenceKeypoint.new(0.4, 0.85),
		NumberSequenceKeypoint.new(1, 1),
	})
	--[[ A tenth of the fire's rate. Smoke is the tail that says the fire was
	     here a moment ago; any more of it and it fogs the thing you are aiming. ]]
	smoke.Rate = 22
	smoke.Drag = 4
	smoke.Acceleration = Vector3.new(0, 16, 0)
	smoke.LightEmission = 0

	local light = Instance.new("PointLight")
	light.Name = "Glow"
	light.Color = Color3.fromRGB(255, 158, 72)
	light.Range = 26
	light.Brightness = 2.4
	light.Shadows = false
	light.Enabled = false
	light.Parent = part

	local node: FlameNode = {
		part = part,
		fire = fire,
		smoke = smoke,
		light = light,
		target = part.CFrame,
		until_ = 0,
		range = 0,
		angle = 0,
	}
	flames[player] = node
	return node
end

local function douse(player: Player)
	local node = flames[player]
	flames[player] = nil
	if not node then
		return
	end
	node.part:Destroy()
end

--[[ One frame of every lit breath. Cheap by construction: this only runs while
     somebody is actually breathing, and it stops itself the moment the last
     flame goes out. ]]
local function stepFlames(delta: number)
	local now = os.clock()
	local lit = false

	for player, node in flames do
		if not node.part.Parent then
			flames[player] = nil
			continue
		end

		if now >= node.until_ then
			if node.fire.Enabled then
				node.fire.Enabled = false
				node.smoke.Enabled = false
				node.light.Enabled = false
			end
			--[[ The node stays. A breath is held in bursts — bonk, breathe, bonk,
			     breathe — and rebuilding four emitters and a light every time the
			     button comes up is work for nothing. It is destroyed when the
			     PLAYER goes, not when the fire does. ]]
			continue
		end

		lit = true
		--[[ Framerate-independent lerp. The naive `alpha = FLAME_FOLLOW` chases
		     at a rate that depends on how fast the machine is drawing, so the
		     same sweep looks different on two clients watching the same walrus. ]]
		local alpha = 1 - (1 - FLAME_FOLLOW) ^ (delta * 60)
		node.part.CFrame = node.part.CFrame:Lerp(node.target, math.clamp(alpha, 0, 1))
	end

	if not lit and flameStep then
		flameStep:Disconnect()
		flameStep = nil
	end
end

local function walrusFlame(payload: any)
	local player = payload.player
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return
	end
	if typeof(payload.origin) ~= "Vector3" or typeof(payload.direction) ~= "Vector3" then
		return
	end
	local direction = payload.direction
	if direction.Magnitude <= 0.001 or direction.X ~= direction.X then
		return
	end
	direction = direction.Unit

	local node = flameNode(player)
	if not node then
		return
	end

	--[[ Out of the mouth rather than out of the middle. The server measures the
	     cone from the root because that is where the body IS; the fire has to
	     leave the front of the head or it looks like the walrus is on fire
	     rather than breathing it. ]]
	local mouth = payload.origin + direction * 3.2 + Vector3.new(0, 1.1, 0)
	--[[ CFrame.lookAt puts -Z down the aim, and a ParticleEmitter emits down
	     +Z on the Front face, so the node is turned to face the other way. ]]
	node.target = CFrame.lookAt(mouth, mouth - direction)

	--[[ First tick of a fresh breath: put it there rather than lerping to it
	     from wherever the last breath ended, which could be across the map. ]]
	if node.until_ <= os.clock() then
		node.part.CFrame = node.target
	end
	node.until_ = os.clock() + FLAME_HOLD

	--[[ Speed and spread re-solved only when the server's numbers actually
	     change. They come off a frozen config and never do in practice, but they
	     ride the payload rather than being read from AbilityConfig here, so a
	     modifier that widened the cone one day would widen the art with it. ]]
	local range = if typeof(payload.range) == "number" then payload.range else 60
	local angle = if typeof(payload.angle) == "number" then payload.angle else 26
	if node.range ~= range then
		node.range = range
		local speed = range / FLAME_LIFETIME
		node.fire.Speed = NumberRange.new(speed * 0.8, speed)
		node.smoke.Speed = NumberRange.new(speed * 0.25, speed * 0.45)
	end
	if node.angle ~= angle then
		node.angle = angle
		--[[ The emitter's spread is the same half-angle the damage cone tests,
		     so what burns is what is drawn. ]]
		node.fire.SpreadAngle = Vector2.new(angle, angle)
		node.smoke.SpreadAngle = Vector2.new(angle * 0.7, angle * 0.7)
	end

	if not node.fire.Enabled then
		node.fire.Enabled = true
		node.smoke.Enabled = true
		node.light.Enabled = true
	end

	if not flameStep then
		flameStep = RunService.RenderStepped:Connect(stepFlames)
	end
end

-- ── lifecycle ───────────────────────────────────────────────────────────────

function AbilityEffects:init()
	folder = Instance.new("Folder")
	folder.Name = "FL_AbilityEffects"
	folder.Parent = Workspace
	trove:add(folder)
end

function AbilityEffects:start()
	trove:connect(Remotes.Event.AbilityEvent.OnClientEvent, function(payload: any)
		if typeof(payload) ~= "table" then
			return
		end
		--[[ Wrapped, because this is the one place in the client where a
		     malformed broadcast could stop every LATER effect from drawing.

		     The kinds with no branch here — ShieldUp, TurretUp and their downs —
		     are not missing. Those two abilities are real Instances the server
		     already made and Roblox already replicated, and drawing them a second
		     time is what would be wrong. ]]
		local kind = payload.kind
		local ok, err = pcall(function()
			if kind == "TurretShot" then
				turretShot(payload)
			elseif kind == "Heal" then
				healPulse(payload)
			elseif kind == "Cryo" then
				cryoField(payload)
			elseif kind == "Marker" then
				marker(payload)
			elseif kind == "Explosion" then
				blast(payload)
			elseif kind == "WalrusFlame" then
				walrusFlame(payload)
			end
		end)
		if not ok then
			warn("[AbilityEffects] " .. tostring(kind) .. " failed: " .. tostring(err))
		end
	end)

	--[[ A walrus who leaves mid-breath leaves a lit node behind, and nothing
	     would ever push its deadline again — so it would sit in the folder,
	     dark, forever. Destroyed with the player rather than swept on a timer. ]]
	trove:connect(Players.PlayerRemoving, douse)
end

function AbilityEffects:destroy()
	if flameStep then
		flameStep:Disconnect()
		flameStep = nil
	end
	--[[ The nodes live in `folder`, which the trove destroys below — but the
	     TABLE pointing at them does not, and a re-init would then find stale
	     entries whose `part.Parent` check is the only thing standing between it
	     and writing to a destroyed instance. Cleared here instead. ]]
	table.clear(flames)
	trove:destroy()
	--[[ Nil'd as well as destroyed. The flyover's two delayed callbacks fire up
	     to a few seconds after the marker and check this before building
	     anything; a variable still pointing at a DESTROYED folder passes a plain
	     truthiness check and then throws on the parent assignment, because a
	     destroyed instance is locked. ]]
	folder = nil
end

Registry.register("AbilityEffects", AbilityEffects)

return AbilityEffects
