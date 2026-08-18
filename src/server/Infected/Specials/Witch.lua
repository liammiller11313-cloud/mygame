--!strict
--[[
	Witch — a hazard, not an enemy.

	She does nothing. That is the design and it has to be defended in code: no
	target acquisition, no wandering, no retaliation for being looked at from
	across a room. A good team hears her, finds her, turns their lights away and
	walks around, and the entire encounter is over without a shot. All of the
	tension lives in the approach, and every line below exists to keep it there.

	She startles on exactly three things:
	  * damage — any at all, from anyone
	  * attention inside sightRange: standing in front of her with a light on her
	    for long enough that it stops being an accident
	  * contact — somebody close enough to touch or shove her

	The third case is an approximation and worth naming. MeleeService's shove
	scales its effect by (1 - stumbleResistance), and the Witch's is 1.0, so a
	shove on her produces no observable signal anywhere. Proximity inside
	GameConfig.Shove.Range is the stand-in: anyone close enough to have shoved her
	has startled her, which is the same outcome from the player's side.

	Once startled she is faster than any survivor (runSpeed 48 against a sprint of
	22), takes one swing worth attack.damage 999 — an incapacitation in practice,
	never a survivable hit — and then leaves. She does not stay to fight the team,
	because a Witch that stays is just a Tank with a bad HP bar.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Enums = require(Shared.Enums)
local GameConfig = require(Shared.Config.GameConfig)
local InfectedConfig = require(Shared.Config.InfectedConfig)
local RaycastUtil = require(Shared.Util.RaycastUtil)
local Registry = require(Shared.Util.Registry)
local Remotes = require(Shared.Net.Remotes)
local RigUtil = require(Shared.Util.RigUtil)
local Types = require(Shared.Types)

local DEFINITION = InfectedConfig.Definitions[Enums.Infected.Witch]
local ATTACK = DEFINITION.attack

local PHASE = table.freeze({
	Sit = "Sit", -- crying, doing absolutely nothing
	Rise = "Rise", -- screaming, about to move; the last moment to run
	Chase = "Chase", -- sprinting at whoever did it
	Strike = "Strike", -- the swing
	Flee = "Flee", -- leaving, and then gone
})

-- How long sustained attention has to last before she takes it personally, and
-- how fast that reading falls off when nobody is looking. The decay is what lets
-- a player sweep a light past her by accident and get away with it.
local ATTENTION_TO_STARTLE = 2.4
local ATTENTION_DECAY = 0.7

-- Half-angle of "you are looking at me". Narrow: a survivor facing her is aiming
-- a torch at her, a survivor facing 45 degrees off is walking past.
local ATTENTION_HALF_ANGLE = 26

-- Anyone this close has startled her regardless of where they are looking. Read
-- from the shove range because a shove is one of the three canonical startles
-- and cannot be observed directly — see the header.
local CONTACT_RANGE = GameConfig.Shove.Range

local RISE_TIME = 0.7 -- the scream before she moves; the only warning there is
local STRIKE_RECOVER = 0.9 -- beat after the swing before she turns and runs
local FLEE_TIME = 6.0 -- how long she runs before despawning
local FLEE_LOOKAHEAD = 40 -- how far ahead she is told to run, re-issued every frame
local GIVE_UP_TIME = DEFINITION.loseInterestTime -- unreachable target: she leaves

local CRY_INTERVAL = 5.5 -- the sound that tells the team she exists at all
local SCAN_INTERVAL = 0.25

local STARTLE_CAMERA_IMPULSE = table.freeze({
	position = Vector3.new(0, 0.1, 0.2),
	rotation = Vector3.new(-2.5, 0, 0),
	decay = 7,
})

type State = {
	phase: string,
	phaseTime: number,
	nextCry: number,
	scanClock: number,
	hasStruck: boolean,
	attention: number,
	lastHealth: number,
	victim: Player?,
	chaseTime: number,
	fleeHeading: Vector3,
	ignore: { Instance },
}

-- Weak keys: a Witch despawned rather than killed never reaches onDeath.
local states = (setmetatable({}, { __mode = "k" }) :: any) :: { [Model]: State }

local function ensure(model: Model): State
	local state = states[model]
	if not state then
		local humanoid = model:FindFirstChildOfClass("Humanoid")
		state = {
			phase = PHASE.Sit,
			phaseTime = 0,
			nextCry = 0,
			scanClock = 0,
			hasStruck = false,
			attention = 0,
			lastHealth = if humanoid then humanoid.Health else DEFINITION.health,
			victim = nil,
			chaseTime = 0,
			fleeHeading = Vector3.zAxis,
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

--[[
	Watches the three startle conditions and returns whoever tripped one.

	Damage is detected by watching the Humanoid's health rather than by listening
	to DamageService.damageDealt: a signal connection made per Witch would outlive
	a Witch that is despawned instead of killed, and this file must not own a
	subscription it cannot guarantee it will clean up. The attacker is then read
	as the nearest survivor with a sightline — which is who shot her, in every
	case that is not a deliberate ricochet.
]]
local function checkStartle(model: Model, root: BasePart, state: State, dt: number): Player?
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local hurt = false
	if humanoid then
		if humanoid.Health < state.lastHealth - 0.01 then
			hurt = true
		end
		state.lastHealth = humanoid.Health
	end

	local survivors: any = Registry.find("SurvivorService")
	if not survivors then
		return nil
	end

	local origin = root.Position
	local closest: Player? = nil
	local closestDistance = math.huge
	local blamed: Player? = nil
	local blamedDistance = math.huge
	local attentionFrom: Player? = nil
	local contactFrom: Player? = nil

	for _, player in survivors:getAliveSurvivors() do
		local character, victimRoot = rootOf(player)
		if not character or not victimRoot then
			continue
		end

		local delta = victimRoot.Position - origin
		local distance = delta.Magnitude

		-- Tracked without any range or sightline filter, because a Witch shot
		-- from across the map is still a Witch that has been shot and she has to
		-- have somebody to blame for it.
		if distance < blamedDistance then
			blamedDistance = distance
			blamed = player
		end

		if distance > DEFINITION.sightRange then
			continue
		end

		state.ignore[2] = character
		local visible = RaycastUtil.hasLineOfSight(origin, victimRoot.Position, state.ignore)
		state.ignore[2] = nil
		if not visible then
			continue
		end

		if distance < closestDistance then
			closestDistance = distance
			closest = player
		end
		if distance <= CONTACT_RANGE then
			contactFrom = player
		end

		-- Facing her, with something between "walking past" and "staring".
		if distance > 0.05 then
			local facing = victimRoot.CFrame.LookVector
			local toWitch = (origin - victimRoot.Position).Unit
			local angle = math.deg(math.acos(math.clamp(facing:Dot(toWitch), -1, 1)))
			if angle <= ATTENTION_HALF_ANGLE then
				attentionFrom = player
			end
		end
	end

	if hurt then
		return closest or blamed
	end
	if contactFrom then
		return contactFrom
	end

	if attentionFrom then
		state.attention += dt
		if state.attention >= ATTENTION_TO_STARTLE then
			return attentionFrom
		end
	else
		state.attention = math.max(state.attention - ATTENTION_DECAY * dt, 0)
	end

	return nil
end

local function beginFlee(model: Model, brain: any, state: State, root: BasePart)
	pauseBrain(brain)
	setBrainTarget(brain, nil)

	-- Away from the nearest survivor, flattened. She is leaving, not pathing.
	local heading = -root.CFrame.LookVector
	local survivors: any = Registry.find("SurvivorService")
	if survivors then
		local origin = root.Position
		local nearest = math.huge
		for _, player in survivors:getAliveSurvivors() do
			local _, victimRoot = rootOf(player)
			if victimRoot then
				local delta = origin - victimRoot.Position
				local distance = delta.Magnitude
				if distance < nearest and distance > 0.05 then
					nearest = distance
					heading = delta
				end
			end
		end
	end

	local flat = Vector3.new(heading.X, 0, heading.Z)
	state.fleeHeading = if flat.Magnitude > 0.05 then flat.Unit else root.CFrame.LookVector
	state.victim = nil
	state.phase = PHASE.Flee
	state.phaseTime = 0

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.WalkSpeed = DEFINITION.runSpeed
	end
end

local function startle(model: Model, brain: any, state: State, root: BasePart, by: Player, dt: number)
	state.victim = by
	state.attention = 0
	state.chaseTime = 0
	state.phase = PHASE.Rise
	state.phaseTime = 0

	playSound("WitchStartle", root)
	Remotes.Event.CameraImpulse:FireClient(by, STARTLE_CAMERA_IMPULSE)

	local _, victimRoot = rootOf(by)
	if victimRoot then
		faceTowards(brain, root, victimRoot.Position, dt)
	end
end

-- ─── phases ──────────────────────────────────────────────────────────────────

local function stepSit(model: Model, brain: any, state: State, root: BasePart, dt: number, now: number)
	-- Re-asserted rather than set once at spawn. "She does not move" is the whole
	-- encounter, and it must not depend on the brain having honoured pause().
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.WalkSpeed ~= 0 then
		humanoid.WalkSpeed = 0
	end

	if now >= state.nextCry then
		state.nextCry = now + CRY_INTERVAL
		-- rollOffMax 420 in AudioConfig: she is meant to be heard two rooms away
		-- and located by ear before she is ever seen.
		playSound("WitchCry", root)
	end

	-- The sight tests are the only cost a sitting Witch has, so they run on their
	-- own clock. Attention is integrated over the whole interval rather than one
	-- frame, so the time it takes to startle her does not change with frame rate.
	state.scanClock += dt
	if state.scanClock < SCAN_INTERVAL then
		return
	end
	local elapsed = state.scanClock
	state.scanClock = 0

	local by = checkStartle(model, root, state, elapsed)
	if by then
		startle(model, brain, state, root, by, elapsed)
	end
end

local function stepRise(model: Model, brain: any, state: State, root: BasePart, dt: number)
	local _, victimRoot = rootOf(state.victim)
	if victimRoot then
		faceTowards(brain, root, victimRoot.Position, dt)
	end

	if state.phaseTime < RISE_TIME then
		return
	end

	local victim = state.victim
	if not victim then
		beginFlee(model, brain, state, root)
		return
	end

	-- The chase is handed BACK to the brain on purpose: it owns pathfinding, and
	-- a Witch that cannot follow you round a corner is a Witch you beat with a
	-- doorway. She only ever has one target and never re-picks.
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.WalkSpeed = DEFINITION.runSpeed
	end
	resumeBrain(brain)
	setBrainTarget(brain, victim.Character)

	state.phase = PHASE.Chase
	state.phaseTime = 0
	state.chaseTime = 0
end

local function stepChase(model: Model, brain: any, state: State, root: BasePart, dt: number)
	local victim = state.victim
	local character, victimRoot = rootOf(victim)
	if not victim or not character or not victimRoot then
		beginFlee(model, brain, state, root)
		return
	end

	state.chaseTime += dt
	if state.chaseTime >= GIVE_UP_TIME then
		-- Cornered on a rooftop or blocked by geometry. She leaves rather than
		-- grinding against a wall for the rest of the map.
		beginFlee(model, brain, state, root)
		return
	end

	-- The brain re-targets on its own schedule; this keeps it honest.
	setBrainTarget(brain, character)

	if (victimRoot.Position - root.Position).Magnitude > ATTACK.range then
		return
	end

	pauseBrain(brain)
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.WalkSpeed = 0
	end
	state.phase = PHASE.Strike
	state.phaseTime = 0
	state.hasStruck = false
end

local function stepStrike(model: Model, brain: any, state: State, root: BasePart, dt: number)
	local victim = state.victim
	local character, victimRoot = rootOf(victim)

	if state.phaseTime < ATTACK.windup then
		if victimRoot then
			faceTowards(brain, root, victimRoot.Position, dt)
		end
		return
	end

	if state.phaseTime >= ATTACK.windup + STRIKE_RECOVER then
		beginFlee(model, brain, state, root)
		return
	end

	if state.hasStruck then
		return -- one swing per phase; everything after it is recovery
	end
	state.hasStruck = true

	local damageService: any = Registry.find("DamageService")
	if not victim or not character or not victimRoot or not damageService then
		return
	end

	-- Still in reach? Sprinting out of her swing in the last tenth of a second is
	-- allowed to work; that is the only thing that ever saves you.
	local delta = victimRoot.Position - root.Position
	local distance = delta.Magnitude
	if distance > ATTACK.range * 1.25 then
		return
	end

	local direction = if distance > 0.05 then delta.Unit else Vector3.yAxis
	damageService:applyDamage(
		character,
		ATTACK.damage,
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

local function stepFlee(model: Model, brain: any, state: State, root: BasePart)
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.WalkSpeed = DEFINITION.runSpeed
		humanoid.AutoRotate = true
	end

	-- brain:moveTo is the sanctioned way for a special to drive a paused body: it
	-- throttles the MoveTo re-issue and clears any path the brain had cached.
	if brain and typeof(brain.moveTo) == "function" then
		brain:moveTo(root.Position + state.fleeHeading * FLEE_LOOKAHEAD)
	elseif humanoid then
		humanoid:Move(state.fleeHeading, false)
	end

	if state.phaseTime < FLEE_TIME then
		return
	end

	states[model] = nil
	local infected: any = Registry.find("InfectedService")
	if infected and typeof(infected.despawn) == "function" then
		infected:despawn(model)
	else
		model:Destroy()
	end
end

-- ─── module surface ──────────────────────────────────────────────────────────

local Witch = {}

function Witch.onSpawn(model: Model, brain: any)
	local state = ensure(model)
	state.ignore[1] = model

	-- Paused from the first frame. She is not an AI with a target list; she is a
	-- piece of level geometry that screams.
	pauseBrain(brain)
	setBrainTarget(brain, nil)

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.WalkSpeed = 0
		state.lastHealth = humanoid.Health
	end

	local root = RigUtil.getRoot(model)
	if root then
		playSound("WitchCry", root)
		state.nextCry = os.clock() + CRY_INTERVAL
	end
end

function Witch.onUpdate(model: Model, brain: any, dt: number)
	local state = states[model] or ensure(model)
	local root = RigUtil.getRoot(model)
	if not root then
		return
	end

	local now = os.clock()
	state.phaseTime += dt

	if state.phase == PHASE.Flee then
		stepFlee(model, brain, state, root)
	elseif state.phase == PHASE.Strike then
		stepStrike(model, brain, state, root, dt)
	elseif state.phase == PHASE.Chase then
		stepChase(model, brain, state, root, dt)
	elseif state.phase == PHASE.Rise then
		stepRise(model, brain, state, root, dt)
	else
		stepSit(model, brain, state, root, dt, now)
	end
end

function Witch.onDeath(model: Model, brain: any, _ctx: any)
	-- Killing a Witch is legitimate and expensive: 1000 health, stumbleResistance
	-- 1.0, and she is already sprinting at somebody by the time most teams commit
	-- to it. Nothing to unwind but the brain.
	resumeBrain(brain)
	states[model] = nil
end

return Witch
