--!strict
--[[
	Charger — the straight line.

	A charge is only fair if it can be dodged, and everything here is built around
	protecting that. turnSpeed is 90 degrees per second in InfectedConfig — a
	deliberately clumsy number — and this module steers the charge at exactly that
	rate and no faster. Sidestep late enough and the Charger cannot correct; that
	is the mechanic, not a shortcoming of it.

	The wind-up is the other half. ChargerCharge plays and the Charger stands
	still for attack.windup with its shoulder down before it moves an inch, so the
	whole team gets one clear beat to see where the line is going to be.

	One survivor is carried, everybody else in the path is thrown aside. Carrying
	the whole team would end the round on one attack; scattering them is what
	turns a charge into a formation problem instead of a coin flip.

	The brain is paused for the entire run: pathfinding fights a straight line by
	definition, and a Charger that curves around a corner mid-charge is a Charger
	nobody can read.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attributes = require(Shared.Net.Attributes)
local Enums = require(Shared.Enums)
local InfectedConfig = require(Shared.Config.InfectedConfig)
local RaycastUtil = require(Shared.Util.RaycastUtil)
local Registry = require(Shared.Util.Registry)
local Remotes = require(Shared.Net.Remotes)
local RigUtil = require(Shared.Util.RigUtil)
local Types = require(Shared.Types)

local DEFINITION = InfectedConfig.Definitions[Enums.Infected.Charger]
local ATTACK = DEFINITION.attack

local PHASE = table.freeze({
	Stalk = "Stalk", -- the brain drives
	Windup = "Windup", -- rooted, roaring, shoulder down
	Charge = "Charge", -- running the line
	Pummel = "Pummel", -- victim on the floor, taking hits on cooldown
})

-- Range band for committing to a charge. Too close and there is no dodge window
-- at all; too far and the Charger runs out of line before it arrives.
local CHARGE_MIN_RANGE = 18
local CHARGE_MAX_RANGE = 120

local CHARGE_MAX_TIME = 4.0 -- a charge that has not hit anything by now is over
local CARRY_MAX_TIME = 3.5 -- and a carry has to end even if the map has no walls

-- Contact radius while running. attack.range is the Charger's own reach and is
-- the honest number: if it could hit you standing still, it hits you running.
local CONTACT_RADIUS = ATTACK.range

-- Where the carried survivor rides. Far enough forward that the wall stops THEM
-- first, which is what sells the slam.
local CARRY_OFFSET = 4.0

-- Sideways velocity given to everyone bumped out of the path. This is a shove,
-- not a launch: they need to be scattered and back on their feet quickly, or the
-- Charger has effectively pinned the whole team.
local BUMP_SPEED = 42
local BUMP_LIFT = 12
-- How long the server keeps simulating a bumped survivor. Long enough for the
-- impulse to actually land, short enough that they never feel remote-controlled.
local BUMP_OWNERSHIP_TIME = 0.6

-- Forward probe distance for the wall check while charging.
local WALL_PROBE = 5.0

local RECOVERY_TIME = 1.6 -- winded after a charge; this is the punish window
local RELEASE_RECOVERY = 1.2 -- after being shoved off a pummel
local SPAWN_SETTLE = 1.2
local SCAN_INTERVAL = 0.3
local GROWL_INTERVAL = 5.5

local IMPACT_CAMERA_IMPULSE = table.freeze({
	position = Vector3.new(0, -0.5, 1.4),
	rotation = Vector3.new(-14, 4, 0),
	decay = 4,
})

local SLAM_CAMERA_IMPULSE = table.freeze({
	position = Vector3.new(0, -0.8, 0.6),
	rotation = Vector3.new(-18, 0, 0),
	decay = 3.5,
})

type State = {
	phase: string,
	phaseTime: number,
	readyAt: number,
	nextScan: number,
	nextGrowl: number,
	nextHit: number,
	target: Player?,
	victim: Player?,
	heading: Vector3,
	carryTime: number,
	bumped: { [Player]: boolean },
	ignore: { Instance },
	probe: RaycastParams,
}

-- Weak keys: a Charger despawned rather than killed never reaches onDeath.
local states = (setmetatable({}, { __mode = "k" }) :: any) :: { [Model]: State }

local function ensure(model: Model): State
	local state = states[model]
	if not state then
		local probe = RaycastParams.new()
		probe.FilterType = Enum.RaycastFilterType.Exclude
		probe.FilterDescendantsInstances = { model }
		probe.IgnoreWater = true
		probe.RespectCanCollide = false

		state = {
			phase = PHASE.Stalk,
			phaseTime = 0,
			readyAt = os.clock() + SPAWN_SETTLE,
			nextScan = 0,
			nextGrowl = 0,
			nextHit = 0,
			target = nil,
			victim = nil,
			heading = Vector3.zAxis,
			carryTime = 0,
			bumped = {},
			ignore = { model },
			probe = probe,
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

local function rootOf(player: Player?): (Model?, BasePart?)
	if not player then
		return nil, nil
	end
	local character = player.Character
	if not character or not character.Parent then
		return nil, nil
	end
	return character, RigUtil.getRoot(character)
end

--[[ Polled, not pushed: a shove clears the pin through SurvivorService and never
     tells us. getPinnedBy is not in the architecture's public list, so the
     replicated attribute is the fallback. ]]
local function stillPinnedBy(survivors: any, player: Player, model: Model): boolean
	if typeof(survivors.getPinnedBy) == "function" then
		return survivors:getPinnedBy(player) == model
	end
	return Attributes.get(player, Attributes.Player.PinnedBy, "") ~= ""
end

local function isUpright(survivors: any, player: Player): boolean
	local state = survivors:getState(player)
	return state == Enums.SurvivorState.Healthy or state == Enums.SurvivorState.Hurt
end

local function hit(model: Model, root: BasePart, character: Model, victimRoot: BasePart, amount: number)
	local damageService: any = Registry.find("DamageService")
	if not damageService then
		return
	end

	local delta = victimRoot.Position - root.Position
	local distance = delta.Magnitude
	local direction = if distance > 0.05 then delta.Unit else Vector3.yAxis

	damageService:applyDamage(
		character,
		amount,
		Types.newDamageContext({
			attackerModel = model,
			damageType = Enums.DamageType.Special,
			region = Enums.HitRegion.Torso,
			hitPosition = victimRoot.Position,
			hitNormal = -direction,
			direction = direction,
			distance = distance,
		})
	)
end

--[[
	Throws one survivor out of the path.

	The server has to own the physics for a moment or the victim's own client
	simply keeps simulating and absorbs the hit — so ownership is taken, the
	velocity is set, and ownership goes back on a timer. The timer is short: a
	character that stays server-simulated feels laggy to the player holding it.
]]
local function knockAside(root: BasePart, velocity: Vector3)
	pcall(function()
		root:SetNetworkOwner(nil)
	end)
	root.AssemblyLinearVelocity = velocity
	task.delay(BUMP_OWNERSHIP_TIME, function()
		if root.Parent then
			pcall(function()
				root:SetNetworkOwnershipAuto()
			end)
		end
	end)
end

local function backToStalk(model: Model, brain: any, state: State, delay: number)
	state.phase = PHASE.Stalk
	state.phaseTime = 0
	state.carryTime = 0
	state.victim = nil
	state.readyAt = os.clock() + delay
	table.clear(state.bumped)

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.WalkSpeed = DEFINITION.walkSpeed
	end
	resumeBrain(brain)
end

local function release(model: Model, brain: any, state: State, delay: number)
	local victim = state.victim
	if victim then
		local survivors: any = Registry.find("SurvivorService")
		if survivors and stillPinnedBy(survivors, victim, model) then
			survivors:setPinned(victim, nil)
		end
		local _, victimRoot = rootOf(victim)
		if victimRoot then
			pcall(function()
				victimRoot:SetNetworkOwnershipAuto()
			end)
		end
	end
	backToStalk(model, brain, state, delay)
end

-- ─── phases ──────────────────────────────────────────────────────────────────

local function pickTarget(root: BasePart): (Player?, BasePart?)
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
		if not victimRoot then
			continue
		end
		local distance = (victimRoot.Position - origin).Magnitude
		if distance < bestDistance and distance <= DEFINITION.sightRange then
			bestDistance = distance
			best = player
			bestRoot = victimRoot
		end
	end

	return best, bestRoot
end

local function stepStalk(model: Model, brain: any, state: State, root: BasePart, now: number)
	if now < state.nextScan then
		return
	end
	state.nextScan = now + SCAN_INTERVAL

	local target, targetRoot = pickTarget(root)
	state.target = target
	setBrainTarget(brain, if target then target.Character else nil)

	if not target or not targetRoot then
		return
	end

	if now >= state.nextGrowl then
		state.nextGrowl = now + GROWL_INTERVAL
		playSound("ChargerIdle", root)
	end

	if now < state.readyAt then
		return
	end

	local distance = (targetRoot.Position - root.Position).Magnitude
	if distance < CHARGE_MIN_RANGE or distance > CHARGE_MAX_RANGE then
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

	-- Rooted for the whole tell, and loud. Everything about the dodge window
	-- depends on this beat existing.
	pauseBrain(brain)
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.WalkSpeed = 0
	end
	playSound("ChargerCharge", root)

	local flat =
		Vector3.new(targetRoot.Position.X - root.Position.X, 0, targetRoot.Position.Z - root.Position.Z)
	state.heading = if flat.Magnitude > 0.05 then flat.Unit else root.CFrame.LookVector
	state.phase = PHASE.Windup
	state.phaseTime = 0
	table.clear(state.bumped)
end

local function stepWindup(model: Model, brain: any, state: State, root: BasePart)
	-- Aim right up to the moment of launch, then commit. Everything after this
	-- is steered at turnSpeed and nothing else.
	local _, targetRoot = rootOf(state.target)
	if targetRoot then
		local flat =
			Vector3.new(targetRoot.Position.X - root.Position.X, 0, targetRoot.Position.Z - root.Position.Z)
		if flat.Magnitude > 0.05 then
			state.heading = flat.Unit
			root.CFrame = CFrame.lookAt(root.Position, root.Position + state.heading)
		end
	end

	if state.phaseTime < ATTACK.windup then
		return
	end

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.WalkSpeed = DEFINITION.runSpeed
		humanoid.AutoRotate = true
	end
	state.phase = PHASE.Charge
	state.phaseTime = 0
	state.carryTime = 0
end

--[[ Rotates the charge heading toward the target by at most turnSpeed degrees
     this frame. This function is the dodge window. ]]
local function steer(state: State, root: BasePart, dt: number)
	local _, targetRoot = rootOf(state.target)
	if not targetRoot then
		return
	end

	local flat =
		Vector3.new(targetRoot.Position.X - root.Position.X, 0, targetRoot.Position.Z - root.Position.Z)
	if flat.Magnitude < 0.05 then
		return
	end

	local wanted = flat.Unit
	local dot = math.clamp(state.heading:Dot(wanted), -1, 1)
	local angle = math.acos(dot)
	local allowed = math.rad(DEFINITION.turnSpeed) * dt
	if angle <= allowed then
		state.heading = wanted
		return
	end

	-- Rotate about the vertical axis by the allowed amount, in whichever
	-- direction the target actually lies.
	local sign = if state.heading:Cross(wanted).Y >= 0 then 1 else -1
	state.heading = (CFrame.fromAxisAngle(Vector3.yAxis, allowed * sign) * state.heading).Unit
end

local function beginPummel(model: Model, state: State, root: BasePart, victim: Player)
	local character, victimRoot = rootOf(victim)
	if character and victimRoot then
		hit(model, root, character, victimRoot, ATTACK.damage)
		Remotes.Event.CameraImpulse:FireClient(victim, SLAM_CAMERA_IMPULSE)
		playSound("ChargerIdle", root)
	end
	state.phase = PHASE.Pummel
	state.phaseTime = 0
	state.nextHit = os.clock() + ATTACK.cooldown
end

local function stepCharge(model: Model, brain: any, state: State, root: BasePart, dt: number)
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		backToStalk(model, brain, state, RECOVERY_TIME)
		return
	end

	local survivors: any = Registry.find("SurvivorService")
	local victim = state.victim

	if victim then
		state.carryTime += dt
		local character, victimRoot = rootOf(victim)
		if
			not survivors
			or not character
			or not victimRoot
			or not stillPinnedBy(survivors, victim, model)
			or state.carryTime >= CARRY_MAX_TIME
		then
			-- Shoved off mid-run, or the victim went down on the way. Either way
			-- the carry is over and the Charger keeps its momentum.
			release(model, brain, state, RECOVERY_TIME)
			return
		end

		-- Carried out in front, held rigid. The server owns their physics for the
		-- duration, taken when the carry started.
		victimRoot.CFrame = CFrame.lookAt(
			root.Position + state.heading * CARRY_OFFSET + Vector3.new(0, 0.5, 0),
			root.Position + Vector3.new(0, 0.5, 0)
		)
		victimRoot.AssemblyLinearVelocity = Vector3.zero
	else
		steer(state, root, dt)
	end

	-- Facing is left to the Humanoid's own rotation. Writing root.CFrame every
	-- frame on a moving rig fights the character controller, and a Charger that
	-- catches on a kerb mid-charge is worse than one that turns a beat late.
	humanoid:Move(state.heading, false)

	-- The wall. Probed from chest height so a kerb does not end a charge.
	local from = root.Position + Vector3.new(0, 1, 0)
	local wall = Workspace:Raycast(from, state.heading * WALL_PROBE, state.probe)
	if wall then
		if victim then
			beginPummel(model, state, root, victim)
		else
			backToStalk(model, brain, state, RECOVERY_TIME)
		end
		return
	end

	if state.phaseTime >= CHARGE_MAX_TIME then
		if victim then
			beginPummel(model, state, root, victim)
		else
			backToStalk(model, brain, state, RECOVERY_TIME)
		end
		return
	end

	if not survivors then
		return
	end

	-- Contact. The first upright survivor in the way is carried; everyone else is
	-- thrown clear, once each per charge.
	local origin = root.Position
	for _, player in survivors:getAliveSurvivors() do
		if state.bumped[player] or player == state.victim then
			continue
		end
		local character, victimRoot = rootOf(player)
		if not character or not victimRoot then
			continue
		end
		if (victimRoot.Position - origin).Magnitude > CONTACT_RADIUS then
			continue
		end

		if not state.victim and isUpright(survivors, player) then
			if survivors:setPinned(player, model, Enums.Infected.Charger) == true then
				state.victim = player
				state.carryTime = 0
				state.bumped[player] = true
				pcall(function()
					victimRoot:SetNetworkOwner(nil)
				end)
				hit(model, root, character, victimRoot, ATTACK.damage)
				Remotes.Event.CameraImpulse:FireClient(player, IMPACT_CAMERA_IMPULSE)
				continue
			end
		end

		state.bumped[player] = true
		hit(model, root, character, victimRoot, ATTACK.damage)
		Remotes.Event.CameraImpulse:FireClient(player, IMPACT_CAMERA_IMPULSE)

		-- Thrown sideways relative to the charge, so the line stays clear behind
		-- the Charger and the scattered survivor is not simply run over again.
		local side = state.heading:Cross(Vector3.yAxis)
		if side.Magnitude < 0.05 then
			side = Vector3.xAxis
		end
		local away = victimRoot.Position - origin
		local sign = if side:Dot(away) >= 0 then 1 else -1
		knockAside(victimRoot, side.Unit * (BUMP_SPEED * sign) + Vector3.new(0, BUMP_LIFT, 0))
	end
end

local function stepPummel(model: Model, brain: any, state: State, root: BasePart, now: number)
	local victim = state.victim
	local survivors: any = Registry.find("SurvivorService")
	local character, victimRoot = rootOf(victim)

	if
		not victim
		or not survivors
		or not character
		or not victimRoot
		or not stillPinnedBy(survivors, victim, model)
	then
		release(model, brain, state, RELEASE_RECOVERY)
		return
	end

	-- Standing over them, facing down. Held rather than driven: the pummel is a
	-- stationary attack and the Charger must not wander off with the body.
	root.CFrame =
		CFrame.lookAt(victimRoot.Position - state.heading * 2.5 + Vector3.new(0, 0.5, 0), victimRoot.Position)
	root.AssemblyLinearVelocity = Vector3.zero
	victimRoot.AssemblyLinearVelocity = Vector3.zero

	if now >= state.nextHit then
		state.nextHit = now + ATTACK.cooldown
		hit(model, root, character, victimRoot, ATTACK.damage)
		Remotes.Event.CameraImpulse:FireClient(victim, SLAM_CAMERA_IMPULSE)
	end
end

-- ─── module surface ──────────────────────────────────────────────────────────

local Charger = {}

function Charger.onSpawn(model: Model, brain: any)
	local state = ensure(model)
	state.ignore[1] = model
	state.probe.FilterDescendantsInstances = { model }

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.WalkSpeed = DEFINITION.walkSpeed
	end

	local root = RigUtil.getRoot(model)
	if root then
		playSound("ChargerIdle", root)
		state.nextGrowl = os.clock() + GROWL_INTERVAL
	end
	setBrainTarget(brain, nil)
end

function Charger.onUpdate(model: Model, brain: any, dt: number)
	local state = states[model] or ensure(model)
	local root = RigUtil.getRoot(model)
	if not root then
		return
	end

	local now = os.clock()
	state.phaseTime += dt

	if state.phase == PHASE.Pummel then
		stepPummel(model, brain, state, root, now)
	elseif state.phase == PHASE.Charge then
		stepCharge(model, brain, state, root, dt)
	elseif state.phase == PHASE.Windup then
		stepWindup(model, brain, state, root)
	else
		stepStalk(model, brain, state, root, now)
	end
end

function Charger.onDeath(model: Model, brain: any, _ctx: any)
	local state = states[model]
	if not state then
		return
	end
	-- Immediate, so a Charger killed mid-pummel drops the survivor on the frame
	-- it dies rather than on SurvivorService's next heartbeat.
	release(model, brain, state, 0)
	states[model] = nil
end

return Charger
