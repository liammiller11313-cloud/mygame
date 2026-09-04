--!strict
--[[
	Tongue — the Smoker, renamed because Roblox's filter eats the word.

	A special nobody can type is a special nobody can call out, and calling it
	out is literally the counter: the victim cannot free themselves, so the only
	thing that saves them is a teammate hearing "tongue" and turning around.

	It never comes to you. It finds a sightline from sixty studs, drags one
	survivor out of the group, and holds them until somebody breaks the line or
	kills it. Everything below protects that shape:

	  * The grab needs LINE OF SIGHT and keeps needing it. Break the line — step
	    behind a wall, or put a teammate's body in the way — and the tongue
	    snaps. That is a second counter that costs no ammunition, and it is what
	    stops a Tongue in an open street from being unanswerable.
	  * The reel is a POSITION write, not a force. A survivor being dragged is a
	    survivor who has lost control, and physics that could be fought with
	    movement keys would make it a tug of war the Tongue always wins anyway,
	    slower and less legibly.
	  * It is fragile and slow. 250 health, walkSpeed 11: once you have found it
	    it dies, and the whole tension is the seconds before you do.

	The pin goes through SurvivorService like every other pin, so a shove frees
	the victim and this module polls the owner rather than being told. The
	counter never depends on the Tongue agreeing to let go.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Enums = require(Shared.Enums)
local InfectedConfig = require(Shared.Config.InfectedConfig)
local RaycastUtil = require(Shared.Util.RaycastUtil)
local Registry = require(Shared.Util.Registry)
local RigUtil = require(Shared.Util.RigUtil)

local Support = require(script.Parent.Support)

local DEFINITION = InfectedConfig.Definitions[Enums.Infected.Tongue]
local ATTACK = DEFINITION.attack

local PHASE = table.freeze({
	Stalk = "Stalk", -- the brain drives; we look for a sightline
	Aim = "Aim", -- rooted, rasping, about to throw
	Reel = "Reel", -- a survivor is being dragged in
	Hold = "Hold", -- they have arrived and are being constricted
	Recover = "Recover", -- stopped and vulnerable after losing them
})

--[[ The tell. Shorter than a Charger's because the Tongue is not asking you to
     dodge — you cannot dodge it — it is asking you to LOOK. The window is for
     the team, not the victim. ]]
local AIM_TIME = 0.55

local GRAB_RANGE = 165
local GRAB_MIN_RANGE = 22 -- closer than this it should just walk up and claw
local GRAB_CONE = math.rad(40)
local GRAB_COOLDOWN = 11

-- How fast a caught survivor travels toward the Tongue, in studs a second.
local REEL_SPEED = 34
--[[ Where the reel stops. Not zero: dragging a body into the same space as the
     Tongue leaves two rigs interpenetrating and the camera inside a chest. ]]
local REEL_ARRIVE = 6
--[[ And a ceiling on the whole drag. A victim stuck on geometry would otherwise
     be reeled forever, which is a softlock rather than a pin. ]]
local REEL_TIMEOUT = 6

local MISS_RECOVERY = 2.2
local SCAN_INTERVAL = 0.25
local RASP_INTERVAL = 3.5

type State = {
	phase: string,
	phaseTime: number,
	nextGrabAt: number,
	nextRasp: number,
	scanClock: number,
	victim: Player?,
	nextHitAt: number,
	ignore: { Instance },
}

-- Weak keys: a Tongue despawned rather than killed never reaches onDeath.
local states = (setmetatable({}, { __mode = "k" }) :: any) :: { [Model]: State }

local function ensure(model: Model): State
	local state = states[model]
	if not state then
		state = {
			phase = PHASE.Stalk,
			phaseTime = 0,
			nextGrabAt = 0,
			nextRasp = 0,
			scanClock = 0,
			victim = nil,
			nextHitAt = 0,
			ignore = { model },
		}
		states[model] = state
	end
	return state
end

--[[ The line the tongue occupies, and the one thing that has to stay true for
     the whole pin. A teammate's body counts as breaking it, deliberately: putting
     yourself between the tongue and your friend is a real play and it should
     work. ]]
local function lineHolds(model: Model, root: BasePart, victim: Player): boolean
	local character, victimRoot = Support.rootOf(victim)
	if not character or not victimRoot then
		return false
	end
	return RaycastUtil.hasLineOfSight(root.Position, victimRoot.Position, { model, character })
end

--[[ The Hunter's isolation numbers. Every special that takes ONE survivor out
     of the fight is asking the same question and should get the same answer. ]]
local ISOLATION_FULL = 60
local ISOLATION_BIAS = 0.55

local function pickTarget(model: Model, root: BasePart): Player?
	local survivors: any = Registry.find("SurvivorService")
	if not survivors or typeof(survivors.getAliveSurvivors) ~= "function" then
		return nil
	end

	local candidates = survivors:getAliveSurvivors()
	local facing = root.CFrame.LookVector
	local best: Player? = nil
	local bestScore = math.huge

	for _, player in candidates do
		--[[ Never someone already held. Two Tongues on one survivor is two
		     specials spent on a player who was already out of the fight. ]]
		if typeof(survivors.getPinnedBy) == "function" and survivors:getPinnedBy(player) then
			continue
		end
		local character, victimRoot = Support.rootOf(player)
		if not character or not victimRoot then
			continue
		end
		local delta = victimRoot.Position - root.Position
		local distance = delta.Magnitude
		if distance < GRAB_MIN_RANGE or distance > GRAB_RANGE then
			continue
		end
		if facing:Dot(delta.Unit) < math.cos(GRAB_CONE) then
			continue
		end
		if not RaycastUtil.hasLineOfSight(root.Position, victimRoot.Position, { model, character }) then
			continue
		end

		--[[
			Nearest was the wrong read for this creature in particular.

			A Tongue's two counters are a teammate shooting it and a teammate's
			BODY breaking the line — and both of those are things that only exist
			if somebody is standing near the person being dragged. Grabbing out of
			the middle of a group is a rope that snaps in under a second on a
			special that walks at 11 and has 250 health. Grabbing the one who has
			drifted off is exactly the scenario the header describes: nobody can
			free them, so somebody has to hear it and come.

			Same isolation read the Hunter and the Jockey use, and the same claim
			bias, so three specials do not all commit to one survivor.
		]]
		local isolation = Support.isolationOf(candidates, player, victimRoot.Position, ISOLATION_FULL)
		local lonely = math.clamp(isolation / ISOLATION_FULL, 0, 1)
		local score = distance
			* (1 - ISOLATION_BIAS * lonely)
			* Support.claimBias(model, player)
			-- And a survivor who cannot see where the rope came from.
			* Support.blindBias(survivors, player)
		if score < bestScore then
			bestScore = score
			best = player
		end
	end
	return best
end

local function setSpeed(model: Model, speed: number)
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.WalkSpeed = speed
	end
end

--[[ Lets go of whoever is held and stands still for a moment. Every exit from
     every phase goes through here, which is what guarantees a Tongue can never
     be left holding a pin it has stopped thinking about. ]]
local function release(model: Model, brain: any, state: State, now: number, recovery: number)
	local victim = state.victim
	if victim then
		local survivors: any = Registry.find("SurvivorService")
		if survivors and typeof(survivors.setPinned) == "function" then
			pcall(survivors.setPinned, survivors, victim, nil, nil)
		end
	end

	state.victim = nil
	state.phase = PHASE.Recover
	state.phaseTime = 0
	state.nextGrabAt = now + math.max(recovery, GRAB_COOLDOWN)
	setSpeed(model, DEFINITION.walkSpeed)
	Support.resumeBrain(brain)
end

local function beginAim(model: Model, brain: any, state: State, root: BasePart, target: Player)
	state.phase = PHASE.Aim
	state.phaseTime = 0
	state.victim = target

	-- Rooted while it aims. A Tongue that closes during its own tell is a Tongue
	-- whose tell told you nothing.
	Support.pauseBrain(brain)
	setSpeed(model, 0)
	Support.playSound("TongueGrab", root)
end

local function beginReel(model: Model, state: State, root: BasePart, victim: Player)
	state.phase = PHASE.Reel
	state.phaseTime = 0

	local survivors: any = Registry.find("SurvivorService")
	if survivors and typeof(survivors.setPinned) == "function" then
		pcall(survivors.setPinned, survivors, victim, model, Enums.Infected.Tongue)
	end
	Support.playSound("TongueGrab", root)
end

local function stepAim(model: Model, brain: any, state: State, root: BasePart, dt: number, now: number)
	if Support.isStaggered(brain) then
		release(model, brain, state, now, MISS_RECOVERY)
		return
	end

	state.phaseTime += dt
	local victim = state.victim
	if not victim or not lineHolds(model, root, victim) then
		-- Broken during the tell. This is the cheapest counter in the game and
		-- it is supposed to be: step behind something.
		release(model, brain, state, now, MISS_RECOVERY)
		return
	end

	local _, victimRoot = Support.rootOf(victim)
	if victimRoot then
		Support.faceTowards(brain, root, victimRoot.Position, dt)
	end

	if state.phaseTime >= AIM_TIME then
		beginReel(model, state, root, victim)
	end
end

local function stepReel(model: Model, brain: any, state: State, root: BasePart, dt: number, now: number)
	local victim = state.victim
	if not victim or Support.isStaggered(brain) then
		release(model, brain, state, now, MISS_RECOVERY)
		return
	end

	state.phaseTime += dt
	if state.phaseTime >= REEL_TIMEOUT then
		-- Stuck on geometry. A drag that cannot finish is a softlock, not a pin.
		release(model, brain, state, now, MISS_RECOVERY)
		return
	end

	local survivors: any = Registry.find("SurvivorService")
	if not survivors or not Support.stillPinnedBy(survivors, victim, model) then
		-- Shoved off by a teammate. The counter never waits on us to agree.
		release(model, brain, state, now, MISS_RECOVERY)
		return
	end

	if not lineHolds(model, root, victim) then
		release(model, brain, state, now, MISS_RECOVERY)
		return
	end

	local _, victimRoot = Support.rootOf(victim)
	if not victimRoot then
		release(model, brain, state, now, MISS_RECOVERY)
		return
	end

	local delta = root.Position - victimRoot.Position
	local flat = Vector3.new(delta.X, 0, delta.Z)
	local distance = flat.Magnitude
	if distance <= REEL_ARRIVE then
		state.phase = PHASE.Hold
		state.phaseTime = 0
		state.nextHitAt = now + ATTACK.cooldown
		return
	end

	--[[ A position write rather than a force. A survivor being dragged has lost
	     control, and a velocity the movement keys could fight would turn the
	     whole mechanic into a tug of war the Tongue wins anyway — slower, and
	     without ever looking like it was supposed to. ]]
	local step = math.min(REEL_SPEED * dt, distance - REEL_ARRIVE)
	victimRoot.CFrame = victimRoot.CFrame + flat.Unit * step
end

local function stepHold(model: Model, brain: any, state: State, root: BasePart, dt: number, now: number)
	local victim = state.victim
	if not victim or Support.isStaggered(brain) then
		release(model, brain, state, now, MISS_RECOVERY)
		return
	end

	local survivors: any = Registry.find("SurvivorService")
	if not survivors or not Support.stillPinnedBy(survivors, victim, model) then
		release(model, brain, state, now, MISS_RECOVERY)
		return
	end

	local character, victimRoot = Support.rootOf(victim)
	if not character or not victimRoot then
		release(model, brain, state, now, MISS_RECOVERY)
		return
	end

	state.phaseTime += dt
	Support.faceTowards(brain, root, victimRoot.Position, dt)

	if now >= state.nextHitAt then
		state.nextHitAt = now + ATTACK.cooldown
		Support.damage(
			model,
			character,
			victimRoot,
			root.Position,
			Support.scaledDamage(model, ATTACK.damage)
		)
	end
end

local Tongue = {}

function Tongue.onSpawn(model: Model, brain: any)
	local state = ensure(model)
	state.ignore[1] = model
	state.nextGrabAt = os.clock() + GRAB_COOLDOWN * 0.4
	Support.resumeBrain(brain)
end

function Tongue.onUpdate(model: Model, brain: any, dt: number)
	local root = RigUtil.getRoot(model)
	if not root or not RigUtil.isAlive(model) then
		return
	end
	local state = ensure(model)
	local now = os.clock()

	if now >= state.nextRasp and state.phase == PHASE.Stalk then
		--[[ The idle carries 420 studs, which is further than it can act from.
		     That is the design: hearing it IS the counter, so it has to be
		     audible before it is dangerous. ]]
		state.nextRasp = now + RASP_INTERVAL
		Support.playSound("TongueIdle", root)
	end

	if state.phase == PHASE.Aim then
		stepAim(model, brain, state, root, dt, now)
		return
	elseif state.phase == PHASE.Reel then
		stepReel(model, brain, state, root, dt, now)
		return
	elseif state.phase == PHASE.Hold then
		stepHold(model, brain, state, root, dt, now)
		return
	elseif state.phase == PHASE.Recover then
		state.phaseTime += dt
		if state.phaseTime >= MISS_RECOVERY then
			state.phase = PHASE.Stalk
			state.phaseTime = 0
		end
		return
	end

	if now < state.nextGrabAt or Support.isStaggered(brain) then
		return
	end

	state.scanClock += dt
	if state.scanClock < SCAN_INTERVAL then
		return
	end
	state.scanClock = 0

	local target = pickTarget(model, root)
	--[[ Renewed on every scan, and cleared when there is nobody in the cone —
	     which for a Tongue is most of the time. See Support.claim. ]]
	Support.claim(model, target)
	if target then
		beginAim(model, brain, state, root, target)
	end
end

function Tongue.onDeath(model: Model, brain: any, _ctx: any)
	--[[ Killing it frees whoever it had, immediately and unconditionally. A pin
	     held by a corpse is the worst bug this system can have. ]]
	local state = states[model]
	if state then
		release(model, brain, state, os.clock(), 0)
	end
	Support.resumeBrain(brain)
	Support.unclaim(model)
	states[model] = nil
end

return Tongue
