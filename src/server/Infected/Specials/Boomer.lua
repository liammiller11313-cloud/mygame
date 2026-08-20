--!strict
--[[
	Boomer — the only infected whose attack is its own death.

	It deals three damage. That is not a typo and it is not a weakness: what a
	Boomer actually does is take your VISION away and hand your position to every
	Common that can hear it, and it does that by bursting. Killing one badly is
	worse than not killing it at all, which inverts the only instinct a shooter
	teaches — see it, shoot it — and turns a corridor into a decision.

	  * The burst is the point, and it fires on DEATH, whatever killed it. Shot,
	    burned, punched by a Tank, or gibbed: if a Boomer stops existing near you,
	    you are covered.
	  * Bile is not damage. It never has been and adding any would ruin it: the
	    threat is that you cannot see and the horde is coming, and a health bar
	    ticking down alongside that reads as the real threat when it is not.
	  * The horde call is the other half. A team that gets biled and stays put
	    dies; a team that moves lives. That is the lesson, and the call is what
	    teaches it.

	── WHY IT VOMITS AT ALL ────────────────────────────────────────────────────
	The burst alone would make it a walking trap that only ever punishes bad
	shooting. The ranged vomit gives it something to DO — a reason to close, a
	reason to be shot at from far away, and a way to be dangerous to a team that
	played the burst correctly. It is slow, telegraphed and short-ranged, and it
	is meant to land maybe one time in three.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attributes = require(Shared.Net.Attributes)
local Enums = require(Shared.Enums)
local InfectedConfig = require(Shared.Config.InfectedConfig)
local RaycastUtil = require(Shared.Util.RaycastUtil)
local Registry = require(Shared.Util.Registry)
local RigUtil = require(Shared.Util.RigUtil)

local Support = require(script.Parent.Support)

local DEFINITION = InfectedConfig.Definitions[Enums.Infected.Boomer]

local PHASE = table.freeze({
	Stalk = "Stalk", -- the brain drives; we watch for a vomit window
	Vomit = "Vomit", -- rooted, heaving, about to cover somebody
})

--[[ The tell, and it is generous. A Boomer is slow and loud and you should
     always have had time to back away — the ones that land should land on a
     team that was already committed to something else. ]]
local VOMIT_WINDUP = 0.7
local VOMIT_RANGE = 22
local VOMIT_CONE = math.rad(30)
local VOMIT_COOLDOWN = 9

--[[ How long a survivor stays covered, from a vomit and from a burst. The burst
     is worth more because you earned it by shooting the wrong thing. ]]
local BILE_SECONDS_VOMIT = 7
local BILE_SECONDS_BURST = 11

--[[ The radius the burst covers, and the much larger radius it is HEARD at.
     They are different numbers on purpose: the point of a burst is that the
     horde knows where you are, and the horde is not standing next to you. ]]
local BURST_RADIUS = 16
local BURST_CALL_RADIUS = 170

--[[ How many Commons a burst pulls. Capped, because "every Common on the map"
     is a wipe rather than a punishment, and because the Director's own budget
     has to still mean something afterwards. ]]
local BURST_CALL_MAX = 18

--[[ How long the called Commons keep walking at the spot. Long enough to
     actually arrive from 170 studs at a shamble, short enough that a team which
     moved is not still being followed a minute later. ]]
local BURST_CALL_SECONDS = 12

local SCAN_INTERVAL = 0.2

type State = {
	phase: string,
	phaseTime: number,
	nextVomitAt: number,
	scanClock: number,
	target: Player?,
	burst: boolean,
	ignore: { Instance },
}

-- Weak keys: a Boomer despawned rather than killed never reaches onDeath.
local states = (setmetatable({}, { __mode = "k" }) :: any) :: { [Model]: State }

local function ensure(model: Model): State
	local state = states[model]
	if not state then
		state = {
			phase = PHASE.Stalk,
			phaseTime = 0,
			nextVomitAt = 0,
			scanClock = 0,
			target = nil,
			burst = false,
			ignore = { model },
		}
		states[model] = state
	end
	return state
end

--[[ Covers one survivor. Everything about what that MEANS — the screen, the
     scream, how long it lasts — belongs to SurvivorService and the client;
     this only ever says who and for how long. ]]
local function bile(survivors: any, player: Player, seconds: number)
	if typeof(survivors.applyBile) == "function" then
		survivors:applyBile(player, seconds)
		return
	end
	--[[ The attribute is the contract either way. SurvivorService is the one that
	     ticks it down, but writing it here means a build without applyBile still
	     shows the player what happened rather than nothing at all. ]]
	Attributes.set(player, Attributes.Player.BiledUntil, Workspace:GetServerTimeNow() + seconds)
end

--[[ Every survivor inside a radius who is actually in the world. ]]
local function survivorsWithin(origin: Vector3, radius: number): { Player }
	local survivors: any = Registry.find("SurvivorService")
	local found: { Player } = {}
	if not survivors or typeof(survivors.getAliveSurvivors) ~= "function" then
		return found
	end
	for _, player in survivors:getAliveSurvivors() do
		local _, root = Support.rootOf(player)
		if root and (root.Position - origin).Magnitude <= radius then
			table.insert(found, player)
		end
	end
	return found
end

--[[
	The burst. Fires exactly once per body, from onDeath, whatever killed it.

	`state.burst` rather than a check on the model, because onDeath and a despawn
	can both reach here and a Boomer that bursts twice would double a punishment
	the player already took.
]]
local function burst(model: Model, root: BasePart)
	local state = ensure(model)
	if state.burst then
		return
	end
	state.burst = true

	Support.playSound("BoomerBurst", root)

	local origin = root.Position
	local survivors: any = Registry.find("SurvivorService")
	for _, player in survivorsWithin(origin, BURST_RADIUS) do
		local character = player.Character
		--[[ Through a wall does not count. Standing on the far side of a door
		     when a Boomer pops is exactly the play the burst is meant to reward,
		     and a radius with no sightline test would take that away. ]]
		local _, victimRoot = Support.rootOf(player)
		if victimRoot and RaycastUtil.hasLineOfSight(origin, victimRoot.Position, { model, character }) then
			bile(survivors, player, BILE_SECONDS_BURST)
		end
	end

	--[[ And the horde hears it. This is the half that actually kills people: bile
	     wears off, but the forty bodies now walking at the noise do not. ]]
	local infected: any = Registry.find("InfectedService")
	if infected and typeof(infected.lureCapped) == "function" then
		infected:lureCapped(origin, BURST_CALL_RADIUS, BURST_CALL_SECONDS, BURST_CALL_MAX)
	end
end

--[[ The closest survivor in front of the Boomer and within vomit range. Nil when
     there is nobody worth heaving at, which is most ticks. ]]
local function pickVomitTarget(model: Model, root: BasePart): Player?
	local facing = root.CFrame.LookVector
	local best: Player? = nil
	local bestDistance = math.huge

	for _, player in survivorsWithin(root.Position, VOMIT_RANGE) do
		local character, victimRoot = Support.rootOf(player)
		if not character or not victimRoot then
			continue
		end
		local delta = victimRoot.Position - root.Position
		local distance = delta.Magnitude
		if distance < 0.05 or distance >= bestDistance then
			continue
		end
		--[[ In front, and visible. A Boomer that vomits over its own shoulder
		     through a wall is a Boomer nobody can position against. ]]
		if facing:Dot(delta.Unit) < math.cos(VOMIT_CONE) then
			continue
		end
		if not RaycastUtil.hasLineOfSight(root.Position, victimRoot.Position, { model, character }) then
			continue
		end
		best = player
		bestDistance = distance
	end
	return best
end

local function beginVomit(model: Model, brain: any, state: State, root: BasePart, target: Player)
	state.phase = PHASE.Vomit
	state.phaseTime = 0
	state.target = target

	-- Rooted while it heaves. The tell is worthless if the Boomer can close the
	-- distance during it.
	Support.pauseBrain(brain)
	Support.playSound("BoomerIdle", root)
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.WalkSpeed = 0
	end
end

local function endVomit(model: Model, brain: any, state: State, now: number)
	state.phase = PHASE.Stalk
	state.phaseTime = 0
	state.target = nil
	state.nextVomitAt = now + VOMIT_COOLDOWN

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.WalkSpeed = DEFINITION.walkSpeed
	end
	Support.resumeBrain(brain)
end

local function stepVomit(model: Model, brain: any, state: State, root: BasePart, dt: number, now: number)
	-- A shove answers a Boomer completely. stumbleResistance is 0 for exactly
	-- this: it is the one special a single survivor can always deal with.
	if Support.isStaggered(brain) then
		endVomit(model, brain, state, now)
		return
	end

	state.phaseTime += dt

	local target = state.target
	local character, victimRoot = Support.rootOf(target)
	if not character or not victimRoot then
		endVomit(model, brain, state, now)
		return
	end

	-- Turning during the wind-up, at the definition's own clumsy rate. It can
	-- track you a little; it cannot follow you.
	Support.faceTowards(brain, root, victimRoot.Position, dt)

	if state.phaseTime < VOMIT_WINDUP then
		return
	end

	--[[ Re-tested at the moment it lands, not at the moment it started. Stepping
	     out of the cone during the wind-up is the dodge, and a vomit that checked
	     only at the start would make that dodge decorative. ]]
	local landed = pickVomitTarget(model, root)
	if landed then
		Support.playSound("BoomerIdle", root)
		bile(Registry.find("SurvivorService"), landed, BILE_SECONDS_VOMIT)
	end
	endVomit(model, brain, state, now)
end

local Boomer = {}

function Boomer.onSpawn(model: Model, brain: any)
	local state = ensure(model)
	state.ignore[1] = model
	state.nextVomitAt = os.clock() + VOMIT_COOLDOWN * 0.5
	Support.resumeBrain(brain)
end

function Boomer.onUpdate(model: Model, brain: any, dt: number)
	local root = RigUtil.getRoot(model)
	if not root or not RigUtil.isAlive(model) then
		return
	end
	local state = ensure(model)
	local now = os.clock()

	if state.phase == PHASE.Vomit then
		stepVomit(model, brain, state, root, dt, now)
		return
	end

	if now < state.nextVomitAt or Support.isStaggered(brain) then
		return
	end

	state.scanClock += dt
	if state.scanClock < SCAN_INTERVAL then
		return
	end
	state.scanClock = 0

	local target = pickVomitTarget(model, root)
	if target then
		beginVomit(model, brain, state, root, target)
	end
end

function Boomer.onDeath(model: Model, brain: any, _ctx: any)
	--[[ The burst goes first, before anything unwinds. Whatever killed this body
	     is about to ragdoll it, and a burst that fired after that would be a
	     corpse on the floor covering people. ]]
	local root = RigUtil.getRoot(model)
	if root then
		burst(model, root)
	end
	Support.resumeBrain(brain)
	states[model] = nil
end

return Boomer
