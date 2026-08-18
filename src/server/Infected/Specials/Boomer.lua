--!strict
--[[
	Boomer — fifty health, zero damage, and the most dangerous thing in the game.

	The Boomer never hurts anybody. It blinds you and then it calls everything in
	the building down on top of you, and those two facts together are worth more
	than a Tank. Every number below is chosen to protect that read:

	  * The bile does no damage at all (attack.damage is 0 and stays 0). Anything
	    it took directly would muddy what actually killed you.
	  * The horde is the payload. DirectorService:triggerPanicEvent is called at
	    the biled survivor's own position, not at the Boomer's, so the swarm
	    converges on the player who is blind rather than on the corpse.
	  * Killing it at point-blank range is the mistake, and that trade is the
	    whole character: it bursts on death and biles everything close enough to
	    have been comfortable. The burst radius is deliberately TIGHTER than the
	    vomit cone — the vomit is aimed and the burst is not, so backing off two
	    steps before firing has to be a real answer.

	gibThreshold is 1 in InfectedConfig: a Boomer always comes apart. That is
	GoreService's job, not this file's; nothing here touches the corpse.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Enums = require(Shared.Enums)
local GoreConfig = require(Shared.Config.GoreConfig)
local InfectedConfig = require(Shared.Config.InfectedConfig)
local RaycastUtil = require(Shared.Util.RaycastUtil)
local Registry = require(Shared.Util.Registry)
local Remotes = require(Shared.Net.Remotes)
local RigUtil = require(Shared.Util.RigUtil)

local DEFINITION = InfectedConfig.Definitions[Enums.Infected.Boomer]
local ATTACK = DEFINITION.attack

local PHASE = table.freeze({
	Waddle = "Waddle", -- the brain drives it toward the nearest survivor
	Windup = "Windup", -- rooted, swelling, audible
	Vent = "Vent", -- the cone is live for a beat after the burp
})

-- Half-angle of the vomit cone. Wide enough that a huddled team eats it
-- together — a Boomer that biles exactly one of four survivors has failed.
local CONE_HALF_ANGLE = 35

-- The bile screen effect. Its duration is GoreConfig's, not a number invented
-- here, so the client's overlay and the server's horde window agree.
local BILE_DURATION = GoreConfig.ScreenBlood.BoomerBileFadeTime
local BILE_EFFECT = "Bile"

-- The vomit sprays for this long after the burp, so walking through the stream
-- catches you and the Boomer cannot be dodged by a single sidestep at the
-- instant of firing.
local VENT_TIME = 0.45
local VENT_RETICK = 0.15 -- re-test the cone this often while venting

-- The death burst. Half the aimed range: see the header.
local BURST_RADIUS = ATTACK.range * 0.5

-- One wave, not DirectorConfig.PanicEvent.WaveCount. A bile is a swarm, not a
-- scripted crescendo, and stacking full panic events would let one Boomer
-- outspend every other pressure source the Director has.
local PANIC_WAVES = 1

local SCAN_INTERVAL = 0.3
local BURP_INTERVAL = 5.0 -- the idle tell; a Boomer you can hear is a Boomer you can back away from

local BILE_CAMERA_IMPULSE = table.freeze({
	position = Vector3.new(0, -0.15, 0.35),
	rotation = Vector3.new(-4, 0, 0),
	decay = 8,
})

type State = {
	phase: string,
	phaseTime: number,
	readyAt: number,
	nextScan: number,
	nextBurp: number,
	nextVentTick: number,
	target: Player?,
	biled: { [Player]: boolean },
	ignore: { Instance },
}

-- Weak keys: a Boomer despawned rather than killed never reaches onDeath.
local states = (setmetatable({}, { __mode = "k" }) :: any) :: { [Model]: State }

local function ensure(model: Model): State
	local state = states[model]
	if not state then
		state = {
			phase = PHASE.Waddle,
			phaseTime = 0,
			readyAt = 0,
			nextScan = 0,
			nextBurp = 0,
			nextVentTick = 0,
			target = nil,
			-- Who this vomit has already covered. Reused per vent so a two-second
			-- stream does not fire four panic events at the same survivor.
			biled = {},
			ignore = { model },
		}
		states[model] = state
	end
	return state
end

-- The brain is InfectedService's object and arrives as an opaque handle; every
-- call into it is guarded so a missing hook degrades to ordinary behaviour.
local function pauseBrain(brain: any)
	if not brain then
		return
	end
	if typeof(brain.pause) == "function" then
		brain:pause()
	end
	-- pause() stands the common AI down but does not cancel a Humanoid:MoveTo it
	-- already issued, and a stale walk order keeps steering the body for several
	-- seconds. stop() is the brain's own way to drop it.
	if typeof(brain.stop) == "function" then
		brain:stop()
	end
end

local function resumeBrain(brain: any)
	if brain and typeof(brain.resume) == "function" then
		brain:resume()
	end
end

local function setBrainTarget(brain: any, target: Model?)
	if brain and typeof(brain.setTarget) == "function" then
		brain:setTarget(target)
	end
end

--[[ A shove has to answer a special exactly the way it answers a Common: whatever
     it was doing stops. InfectedService:stagger scales the duration by
     stumbleResistance and hands it to the brain, which freezes the body — but it
     cannot interrupt a scripted phase from the outside, so the phase has to ask.
     Nothing on this path restores WalkSpeed: the stumble owns it, and the brain
     puts it back when the stumble ends. ]]
local function isStaggered(brain: any): boolean
	return brain ~= nil and typeof(brain.isStaggered) == "function" and brain:isStaggered() == true
end

--[[ Yaw toward a point at the definition's turnSpeed. The brain owns rotation —
     including Humanoid.AutoRotate, which manual facing has to switch off — so
     this defers to it and only snaps if that hook is missing. ]]
local function faceTowards(brain: any, root: BasePart, position: Vector3, dt: number)
	if brain and typeof(brain.faceTowards) == "function" then
		brain:faceTowards(position, dt)
		return
	end
	local flat = Vector3.new(position.X - root.Position.X, 0, position.Z - root.Position.Z)
	if flat.Magnitude > 0.05 then
		root.CFrame = CFrame.lookAt(root.Position, root.Position + flat.Unit)
	end
end

local function playSound(key: string, part: BasePart)
	local audio: any = Registry.find("AudioService")
	if audio then
		audio:play("Infected", key, part)
	end
end

local function rootOf(player: Player): (Model?, BasePart?)
	local character = player.Character
	if not character or not character.Parent then
		return nil, nil
	end
	return character, RigUtil.getRoot(character)
end

--[[
	Coats one survivor.

	Two things happen and they are equally important: the screen goes green for
	the player, and the Director is told to send a wave at the position they are
	standing in. The panic call is what makes the Boomer the Boomer — without it
	this is a screen effect, with it, it is the reason the team scatters.
]]
local function bile(player: Player, position: Vector3)
	Remotes.Event.ScreenEffect:FireClient(player, {
		effect = BILE_EFFECT,
		duration = BILE_DURATION,
		intensity = 1,
	})
	Remotes.Event.CameraImpulse:FireClient(player, BILE_CAMERA_IMPULSE)

	local director: any = Registry.find("DirectorService")
	if director and typeof(director.triggerPanicEvent) == "function" then
		director:triggerPanicEvent(position, PANIC_WAVES)
	end
end

--[[ Everyone inside the cone with a sightline, skipping anyone this vomit has
     already covered. Returns how many were newly biled. ]]
local function spray(model: Model, root: BasePart, state: State): number
	local survivors: any = Registry.find("SurvivorService")
	if not survivors then
		return 0
	end

	local origin = root.Position
	local facing = root.CFrame.LookVector
	local hit = 0

	for _, player in survivors:getAliveSurvivors() do
		if state.biled[player] then
			continue
		end
		local character, victimRoot = rootOf(player)
		if not character or not victimRoot then
			continue
		end

		local delta = victimRoot.Position - origin
		local distance = delta.Magnitude
		if distance > ATTACK.range or distance < 0.05 then
			continue
		end
		if math.deg(math.acos(math.clamp(delta.Unit:Dot(facing), -1, 1))) > CONE_HALF_ANGLE then
			continue
		end

		state.ignore[2] = character
		local visible = RaycastUtil.hasLineOfSight(origin, victimRoot.Position, state.ignore)
		state.ignore[2] = nil
		if not visible then
			continue
		end

		state.biled[player] = true
		bile(player, victimRoot.Position)
		hit += 1
	end

	return hit
end

local function backToWaddle(model: Model, brain: any, state: State, delay: number)
	state.phase = PHASE.Waddle
	state.phaseTime = 0
	state.readyAt = os.clock() + delay
	table.clear(state.biled)

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.WalkSpeed = DEFINITION.walkSpeed
	end
	resumeBrain(brain)
end

-- ─── phases ──────────────────────────────────────────────────────────────────

local function nearestSurvivor(root: BasePart): (Player?, BasePart?)
	local survivors: any = Registry.find("SurvivorService")
	if not survivors then
		return nil, nil
	end

	local origin = root.Position
	local best: Player? = nil
	local bestRoot: BasePart? = nil
	local bestDistance = math.huge

	for _, player in survivors:getAliveSurvivors() do
		local _, victimRoot = rootOf(player)
		if victimRoot then
			local distance = (victimRoot.Position - origin).Magnitude
			if distance < bestDistance then
				bestDistance = distance
				best = player
				bestRoot = victimRoot
			end
		end
	end

	return best, bestRoot
end

local function stepWaddle(model: Model, brain: any, state: State, root: BasePart, now: number)
	if now >= state.nextBurp then
		state.nextBurp = now + BURP_INTERVAL
		playSound("BoomerIdle", root)
	end

	if now < state.nextScan then
		return
	end
	state.nextScan = now + SCAN_INTERVAL

	local target, targetRoot = nearestSurvivor(root)
	state.target = target
	setBrainTarget(brain, if target then target.Character else nil)

	if not target or not targetRoot or now < state.readyAt then
		return
	end

	local delta = targetRoot.Position - root.Position
	local distance = delta.Magnitude
	if distance > ATTACK.range or distance < 0.05 then
		return
	end
	if math.deg(math.acos(math.clamp(delta.Unit:Dot(root.CFrame.LookVector), -1, 1))) > CONE_HALF_ANGLE then
		return
	end

	local character = target.Character
	if not character then
		return
	end
	state.ignore[2] = character
	local visible = RaycastUtil.hasLineOfSight(root.Position, targetRoot.Position, state.ignore)
	state.ignore[2] = nil
	if not visible then
		return
	end

	-- Rooted while it swells. A Boomer that keeps waddling through its own
	-- windup arrives in melee range before the burp finishes, and the tell stops
	-- being a chance to shoot it from a safe distance.
	pauseBrain(brain)
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.WalkSpeed = 0
	end
	playSound("BoomerIdle", root)

	state.phase = PHASE.Windup
	state.phaseTime = 0
	table.clear(state.biled)
end

local function stepWindup(model: Model, brain: any, state: State, root: BasePart)
	local target = state.target
	local victimRoot: BasePart? = nil
	if target then
		local _, found = rootOf(target)
		victimRoot = found
	end

	if victimRoot then
		local flat = Vector3.new(victimRoot.Position.X - root.Position.X, 0, victimRoot.Position.Z - root.Position.Z)
		if flat.Magnitude > 0.05 then
			root.CFrame = CFrame.lookAt(root.Position, root.Position + flat.Unit)
		end
	end

	if state.phaseTime < ATTACK.windup then
		return
	end

	spray(model, root, state)
	state.phase = PHASE.Vent
	state.phaseTime = 0
	state.nextVentTick = os.clock() + VENT_RETICK
end

local function stepVent(model: Model, brain: any, state: State, root: BasePart, now: number)
	if now >= state.nextVentTick then
		state.nextVentTick = now + VENT_RETICK
		spray(model, root, state)
	end
	if state.phaseTime >= VENT_TIME then
		backToWaddle(model, brain, state, ATTACK.cooldown)
	end
end

-- ─── module surface ──────────────────────────────────────────────────────────

local Boomer = {}

function Boomer.onSpawn(model: Model, brain: any)
	local state = ensure(model)
	state.ignore[1] = model

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.WalkSpeed = DEFINITION.walkSpeed
	end

	local root = RigUtil.getRoot(model)
	if root then
		playSound("BoomerIdle", root)
		state.nextBurp = os.clock() + BURP_INTERVAL
	end
	setBrainTarget(brain, nil)
end

function Boomer.onUpdate(model: Model, brain: any, dt: number)
	local state = states[model] or ensure(model)
	local root = RigUtil.getRoot(model)
	if not root then
		return
	end

	local now = os.clock()
	state.phaseTime += dt

	if state.phase == PHASE.Vent then
		stepVent(model, brain, state, root, now)
	elseif state.phase == PHASE.Windup then
		stepWindup(model, brain, state, root)
	else
		stepWaddle(model, brain, state, root, now)
	end
end

--[[
	The burst.

	No damage, no explosion damage, no friendly fire — just bile on everyone who
	was standing close enough, the loudest sound the Boomer owns, and a wave
	called down on the spot where it died. A team that shot it from across the
	room gets none of this, which is the entire lesson.
]]
function Boomer.onDeath(model: Model, brain: any, _ctx: any)
	local state = states[model]
	local root = RigUtil.getRoot(model)

	if state then
		backToWaddle(model, brain, state, 0)
		states[model] = nil
	end
	if not root then
		return
	end

	local origin = root.Position
	playSound("BoomerExplode", root)

	local survivors: any = Registry.find("SurvivorService")
	if survivors then
		local ignore = { model }
		for _, player in survivors:getAliveSurvivors() do
			local character = player.Character
			local victimRoot = if character then RigUtil.getRoot(character) else nil
			if not character or not victimRoot then
				continue
			end
			if (victimRoot.Position - origin).Magnitude > BURST_RADIUS then
				continue
			end
			-- A wall between you and the burst protects you, exactly as it does
			-- for every other radial effect in the game.
			ignore[2] = character
			if RaycastUtil.hasLineOfSight(origin, victimRoot.Position, ignore) then
				bile(player, victimRoot.Position)
			end
		end
	end

	-- Called even when the burst caught nobody: the noise of a Boomer dying is
	-- itself supposed to bring company.
	local director: any = Registry.find("DirectorService")
	if director and typeof(director.triggerPanicEvent) == "function" then
		director:triggerPanicEvent(origin, PANIC_WAVES)
	end
end

return Boomer
