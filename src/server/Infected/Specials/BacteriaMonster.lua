--!strict
--[[
	Bacteria Monster — the Backrooms' finale, and the one boss that attacks
	standing still.

	── THE ANSWER IT TAKES AWAY ────────────────────────────────────────────────
	Every other boss in this game takes away one habit and leaves the rest.

	    TANK      -> keep moving. Stand together and it throws you apart.
	    WITCH     -> do not make noise. She is a hazard you route around.
	    METALLIC  -> read the arena. Back down a corridor and the charge has you.

	And a team beats all three the same way underneath, which is the thing none
	of them touch: pick a room, cover the one door, and put every gun on the
	same target. That is the real answer, on every map, in every fight.

	So this one takes the room.

	── HOW ─────────────────────────────────────────────────────────────────────
	It is SLOW. It never charges, never leaps, never closes a gap you did not
	give it, and it walks below survivor pace — so you can leave at any moment.
	What you cannot do is stay.

	It seeds COLONIES: growth on the floor that damages and slows whoever stands
	in it, and that keeps growing after it lands. Two ways one appears.

	  1. Where it WALKS, on a slow drip. That alone would be a Spitter with a
	     longer fuse.
	  2. Where it is SHOT. This is the mechanic. Every few hundred points of
	     damage it takes, a colony takes root at the point the damage came FROM
	     — which is to say, under the person who dealt it.

	Which turns the team's own answer into the clock. Four guns on one target
	from one doorway is the fastest possible way to make that doorway
	uninhabitable, and the better the team is at the fight they already know,
	the sooner they have to leave the place they were winning it from.

	── AND THE COUNTER IS FIRE ─────────────────────────────────────────────────
	While it BURNS it stops seeding, and its burnDamagePerSecond is 200 — the
	highest in the game, eight times the Metallic's. That is deliberate
	symmetry: the Metallic exists partly to take the opening molotov away from a
	team that throws one at every boss, and this hands it straight back as the
	whole answer. Fire hurts it most AND stops the floor spreading, which says
	"this is what you do" without a line of tutorial text.

	── WHAT IT IS NOT ──────────────────────────────────────────────────────────
	It is not a damage race. Three thousand health is under a Tank's and half a
	Metallic's, because the fight is a timer on the team's position rather than
	on its ammunition. Give it Metallic health and the colonies eat the whole
	floor before it dies, which is not pressure — it is a wipe with a longer
	preamble.
]]

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attributes = require(Shared.Net.Attributes)
local Enums = require(Shared.Enums)
local InfectedConfig = require(Shared.Config.InfectedConfig)
local RaycastUtil = require(Shared.Util.RaycastUtil)
local Registry = require(Shared.Util.Registry)
local RigUtil = require(Shared.Util.RigUtil)
local Types = require(Shared.Net.Types)

local Support = require(script.Parent.Support)

local BacteriaMonster = {}

local DEFINITION = InfectedConfig.get(Enums.Infected.BacteriaMonster)
local IA = Attributes.Infected
local PA = Attributes.Player

local random = Random.new()

-- ── the colonies ────────────────────────────────────────────────────────────

--[[ How wide a colony starts and how wide it is allowed to get, and how long it
     takes to get there. It starts small enough to step over and ends wide enough
     to close a doorway, which is the whole arc of the fight in one pair of
     numbers: the room is fine, then the room is survivable, then the room is
     gone. ]]
local SEED_RADIUS = 4.5
local FULL_RADIUS = 13
local GROW_SECONDS = 16
local COLONY_HEIGHT = 0.3

--[[ How long one lives. Long, because a colony that expired quickly would let a
     team hold a doorway by waiting — and the fight is about being moved, not
     about being patient. Not forever, because a wave that ends leaves the floor
     behind for whatever comes next. ]]
local COLONY_SECONDS = 34

--[[ Damage per second at the edge of a fresh colony and in the middle of a grown
     one, and how long standing in it takes to ramp. Lower than the Spitter's
     acid at every point on purpose: acid is a puddle you are punished for not
     noticing, and this is a floor you are being asked to leave. Something that
     killed as fast as acid would make relocating impossible rather than
     necessary. ]]
local COLONY_DPS_MIN = 4
local COLONY_DPS_MAX = 14
local COLONY_RAMP = 3.5
local COLONY_TICK = 0.4

--[[ How much slower you are while standing in one, as a multiple of your own
     speed. This is the half that makes the fight frightening rather than
     annoying: the ground that is hurting you is also the ground you cross more
     slowly, so a team that leaves late leaves much later than it meant to.

     Not a stop. A survivor who could not move at all would be dead rather than
     late, and the creature is slow precisely so that leaving is always
     possible. ]]
local COLONY_SLOW = 0.55

--[[ A body's height band above the surface, the same asymmetric test the acid
     pool uses and for the same reason: a survivor on the floor above is not
     standing in this. ]]
local COLONY_BELOW = -1.5
local COLONY_ABOVE = 6.5

--[[ How many exist at once. Twelve is a lot — the Spitter is capped at four —
     and it has to be, because this is the fight rather than an interruption in
     one. The cap exists so a very long finale cannot turn the whole floor into a
     single surface with no route through it. ]]
local MAX_COLONIES = 12

--[[ A new colony is refused within this of an existing one's centre. Without it
     a team holding one doorway would stack six colonies in one square metre —
     which is invisible, since they overlap exactly, and would multiply the
     damage there by six while leaving the rest of the room clean. The whole
     point is that the infested area SPREADS. ]]
local MIN_SEPARATION = 9

--[[ How far it walks between drips. Distance rather than time, so a creature
     that has been kited across a map leaves a trail and one that has been held
     in place does not carpet the spot it is standing on. ]]
local TRAIL_DISTANCE = 26

--[[ How much damage it takes before a colony takes root under whoever dealt it.
     Roughly a tenth of its health, so a clean fight seeds about ten — most of
     the cap, spread across wherever the team was standing when they earned
     them. ]]
local BLOOM_PER_DAMAGE = 300

--[[ How far from the shooter the bloom lands. Under their feet exactly would be
     unfair in a way the player cannot answer — there is no reaction to a colony
     that is already on you. A few studs out is a warning with a step in it. ]]
local BLOOM_OFFSET = 6

local COLONY_COLOR = Color3.fromRGB(150, 178, 96)

type Colony = {
	part: BasePart,
	origin: Vector3,
	bornAt: number,
	expiresAt: number,
	nextTick: number,
	standing: { [Player]: number },
}

type State = {
	--[[ Where it was when it last dripped, and how much damage it has taken
	     since the last bloom. Both are the fight's only memory. ]]
	lastTrail: Vector3?,
	damageBank: number,
	lastHealth: number,
	nextRoar: number,
}

local states: { [Model]: State } = {}

--[[ Shared across every body, because the colonies are shared: a second one of
     these would otherwise get its own cap and its own sweep, and the floor would
     fill twice as fast as the number that was tuned. There is only ever one —
     maxAlive is 1 — and this is what keeps that from being load-bearing. ]]
local colonies: { Colony } = {}
local lastSweepAt = 0

local function ensure(model: Model): State
	local state = states[model]
	if not state then
		local humanoid = model:FindFirstChildOfClass("Humanoid")
		state = {
			lastTrail = nil,
			damageBank = 0,
			lastHealth = if humanoid then humanoid.Health else 0,
			nextRoar = 0,
		}
		states[model] = state
	end
	return state
end

--[[ How wide a colony is right now. Grown from its own age rather than stepped,
     so it is correct on the frame it is asked whatever the sweep rate is — and
     the part's visible size is set from the same number, so what a player sees
     is exactly what damages them. ]]
local function radiusOf(colony: Colony, now: number): number
	local alpha = math.clamp((now - colony.bornAt) / GROW_SECONDS, 0, 1)
	return SEED_RADIUS + (FULL_RADIUS - SEED_RADIUS) * alpha
end

--[[ Lays one on the floor under a point, or does not.

     Refused in midair, and refused next to an existing colony — see
     MIN_SEPARATION. Both refusals are silent: a bloom that finds nowhere to grow
     is not an error, it is a shot fired over a stairwell. ]]
local function plant(origin: Vector3, source: Model)
	local ground, normal = RaycastUtil.groundAt(origin, 40, { source })
	if not ground or not normal then
		return
	end

	for _, existing in colonies do
		if (existing.origin - ground).Magnitude < MIN_SEPARATION then
			return
		end
	end

	--[[ FIFO past the ceiling, and the OLDEST goes — which here is also the
	     biggest, so the floor opens up where the team has already been rather
	     than where they are now. ]]
	while #colonies >= MAX_COLONIES do
		local oldest = table.remove(colonies, 1)
		if oldest and oldest.part then
			oldest.part:Destroy()
		end
	end

	local part = Instance.new("Part")
	part.Name = "FL_Bacteria"
	part.Shape = Enum.PartType.Cylinder
	part.Size = Vector3.new(COLONY_HEIGHT, SEED_RADIUS * 2, SEED_RADIUS * 2)
	--[[ Laid flat on the surface it found, so growth on a ramp is on the ramp
	     rather than hovering over it at an angle nobody can read. ]]
	part.CFrame = CFrame.new(ground + normal * (COLONY_HEIGHT * 0.5), ground + normal)
		* CFrame.Angles(0, 0, math.rad(90))
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Material = Enum.Material.Glass
	part.Color = COLONY_COLOR
	part.Transparency = 0.25
	part.Parent = Workspace

	--[[ Debris as well as the sweep. If this module ever stops ticking — the
	     service errors, the round ends mid-fight — a permanent growth in the
	     middle of the map is far worse than one that vanishes early. ]]
	Debris:AddItem(part, COLONY_SECONDS + 2)

	local now = os.clock()
	table.insert(colonies, {
		part = part,
		origin = ground,
		bornAt = now,
		expiresAt = now + COLONY_SECONDS,
		nextTick = now + COLONY_TICK,
		standing = {},
	})

	Support.playSound("BacteriaBloom", part)
end

--[[
	Slows a survivor, or stops.

	Through SurvivorService's own speed drag rather than by writing WalkSpeed —
	see Attributes.Player.SpeedDrag, which carries the whole reason. Short
	version: that service recomputes and writes the property every frame, so an
	outside write lasts until the player sprints and then silently loses, while
	this module would still be holding a stale number to put back.

	Setting nil rather than 1 when it ends, so "nothing is dragging" is the
	absence of the attribute rather than a value that has to be maintained.
]]
local function applySlow(player: Player, slowed: boolean)
	player:SetAttribute(PA.SpeedDrag, if slowed then COLONY_SLOW else nil)
end

--[[ One tick of every live colony.

     Called from onUpdate and guarded to run once a frame however many bodies are
     alive — the colonies are shared, so ticking them per creature would double
     the damage the instant a second one existed. ]]
local function sweepColonies(now: number)
	if now - lastSweepAt < COLONY_TICK then
		return
	end
	lastSweepAt = now

	local survivors = Registry.find("SurvivorService")
	local damageService = Registry.find("DamageService")
	local alive = {}
	if survivors and typeof(survivors.getAliveSurvivors) == "function" then
		local ok, list = pcall(survivors.getAliveSurvivors, survivors)
		if ok and typeof(list) == "table" then
			alive = list
		end
	end

	--[[
		Who is in ANY colony this tick, and the WORST of them — both gathered
		before anything is applied.

		Gathered rather than applied inline because colonies overlap, and by
		design: MIN_SEPARATION is 9 studs while a grown one reaches 13, so the
		infested area is meant to join up into a spreading surface rather than a
		field of separate discs. Damaging per colony would then multiply by
		however many happened to reach a player — three or four in the middle of
		a long fight, at four times the tuned rate, which is not a floor to leave
		but an instant death with no tell.

		The WORST rather than the sum, so standing where two colonies meet is as
		bad as the older of them and no worse. And a single slow, so overlapping
		growth cannot stack that either — or un-slow somebody the moment they
		step out of one while still standing in the next.
	]]
	local inAny: { [Player]: boolean } = {}
	local worst: { [Player]: number } = {}

	for index = #colonies, 1, -1 do
		local colony = colonies[index]
		if not colony.part.Parent or now >= colony.expiresAt then
			table.remove(colonies, index)
			colony.part:Destroy()
			continue
		end

		--[[ Grown on the same clock it is measured by, so the circle a player
		     can see is exactly the circle that hurts them. ]]
		local radius = radiusOf(colony, now)
		colony.part.Size = Vector3.new(COLONY_HEIGHT, radius * 2, radius * 2)

		if now < colony.nextTick then
			continue
		end
		colony.nextTick = now + COLONY_TICK

		for _, player in alive do
			local character, root = Support.rootOf(player)
			if not character or not root then
				continue
			end
			--[[ Flat distance, and only from above — the same band the acid pool
			     uses, and for the same reason: a survivor on the floor above is
			     not standing in this, and damage arriving through the boards is
			     damage from nothing they can see. ]]
			local delta = root.Position - colony.origin
			if delta.Y < COLONY_BELOW or delta.Y > COLONY_ABOVE then
				continue
			end
			if Vector3.new(delta.X, 0, delta.Z).Magnitude > radius then
				continue
			end

			inAny[player] = true
			local held = (colony.standing[player] or 0) + COLONY_TICK
			colony.standing[player] = held

			local ramp = math.clamp(held / COLONY_RAMP, 0, 1)
			local dps = COLONY_DPS_MIN + (COLONY_DPS_MAX - COLONY_DPS_MIN) * ramp
			worst[player] = math.max(worst[player] or 0, dps)
		end

		--[[ Anybody who left is forgotten, so stepping out and back in starts the
		     ramp again. Standing in it is what this punishes; having stood in it
		     once is not. ]]
		for player in colony.standing do
			if not inAny[player] then
				colony.standing[player] = nil
			end
		end
	end

	--[[ One damage application per player per tick, at the worst rate any colony
	     reaching them is running. See the gather above for why this is not a sum. ]]
	if damageService and typeof(damageService.applyDamage) == "function" then
		for player, dps in worst do
			local character, root = Support.rootOf(player)
			if character and root then
				pcall(
					damageService.applyDamage,
					damageService,
					character,
					dps * COLONY_TICK,
					Types.newDamageContext({
						damageType = Enums.DamageType.Special,
						region = Enums.HitRegion.Torso,
						hitPosition = root.Position,
					})
				)
			end
		end
	end

	--[[
		Slowed and un-slowed once per player per tick, from the gathered set.

		Over EVERY player, not the alive roster the damage loop used. Somebody who
		went down inside a colony is no longer "alive" by that roster's
		definition, so clearing only the living would leave them slowed through
		the revive and out the other side — up off the floor and walking at
		fifty-five percent for the rest of the round.

		Four entries. The cost of getting this wrong is much larger than the cost
		of the loop.
	]]
	for _, player in Players:GetPlayers() do
		applySlow(player, inAny[player] == true)
	end
end

--[[ Every colony gone, and every survivor's legs given back.

     Called when the creature dies and when the last one leaves. The floor
     clearing IS the reward: a team that has spent a minute being pushed around a
     building should get the building back the moment it drops, and a finale that
     left the map poisoned would make winning feel like losing more slowly. ]]
local function clearColonies()
	for _, colony in colonies do
		if colony.part then
			colony.part:Destroy()
		end
	end
	table.clear(colonies)

	--[[ Every player, not just the ones a roster call would return: somebody who
	     went down inside a colony is not "alive", and leaving them slowed for a
	     revive they then have to crawl away from would be the exact bug this
	     mechanism exists to make impossible. ]]
	for _, player in Players:GetPlayers() do
		applySlow(player, false)
	end
end

-- ── the creature ────────────────────────────────────────────────────────────

--[[ Whether it is currently on fire, which is the one thing that stops it
     seeding. Read off the attribute InfectedService publishes rather than kept
     here: burning is applied by molotovs, the flamethrower and the Incendiary
     requisition, and none of them know this module exists. ]]
local function isBurning(model: Model): boolean
	return model:GetAttribute(IA.Burning) == true
end

--[[ The drip. Distance-based, so being kited leaves a trail across a map and
     being held in place does not carpet one square of floor. ]]
local function stepTrail(model: Model, state: State, root: BasePart)
	local last = state.lastTrail
	if not last then
		state.lastTrail = root.Position
		return
	end
	if (root.Position - last).Magnitude < TRAIL_DISTANCE then
		return
	end
	state.lastTrail = root.Position
	plant(root.Position, model)
end

--[[
	The bloom, and the mechanic the whole fight is built on.

	Damage taken is banked, and every BLOOM_PER_DAMAGE of it plants a colony at
	the position of whoever is currently being chased — which in practice is
	whoever has been shooting hardest, because that is what the brain's threat
	target already means.

	Reading the target rather than the damage's own origin is a deliberate
	simplification and worth being honest about: a shot from a teammate across
	the room blooms under the person the creature is looking at, not under the
	shooter. In a fight where four people are in one doorway those are the same
	place, which is the case this exists for. In a fight where they are not, the
	team has already split up — which is the behaviour it is trying to teach.
]]
local function stepBloom(model: Model, brain: any, state: State, root: BasePart)
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end

	local health = humanoid.Health
	local taken = state.lastHealth - health
	state.lastHealth = health
	if taken <= 0 then
		return
	end
	--[[ Burning suppresses the bank rather than merely the bloom. Otherwise a
	     team could hold fire, burn it, and cash in the banked damage the moment
	     the flames went out — which would make the counter a delay instead of an
	     answer. ]]
	if isBurning(model) then
		state.damageBank = 0
		return
	end

	state.damageBank += taken
	if state.damageBank < BLOOM_PER_DAMAGE then
		return
	end
	state.damageBank -= BLOOM_PER_DAMAGE

	--[[ Under the player it is chasing, a few studs short of their feet. See
	     BLOOM_OFFSET: a colony that lands exactly on somebody is a colony there
	     was no answer to.

	     The brain's target is a CHARACTER MODEL, not a Player — Support.rootOf
	     takes the latter and would have quietly returned nil for every bloom in
	     the fight, planting all of them under the creature's own feet. Asked
	     through getTarget so this reads the same answer the brain acts on. ]]
	local target = if brain and typeof(brain.getTarget) == "function" then brain:getTarget() else nil
	local targetRoot = if typeof(target) == "Instance" and target:IsA("Model")
		then RigUtil.getRoot(target)
		else nil
	local at = if targetRoot then targetRoot.Position else root.Position
	if targetRoot then
		local away = targetRoot.Position - root.Position
		local flat = Vector3.new(away.X, 0, away.Z)
		if flat.Magnitude > 0.1 then
			at -= flat.Unit * BLOOM_OFFSET
		end
	end
	plant(at, model)
end

-- ── lifecycle ───────────────────────────────────────────────────────────────

function BacteriaMonster.onSpawn(model: Model, brain: any)
	local state = ensure(model)

	--[[ One speed, always. There is no sprint to roll and no charge to wind up:
	     the creature's entire threat is that it does not stop, and a boss that
	     sometimes moved faster would make "you can always walk away" a lie the
	     player only discovers once. ]]
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.WalkSpeed = Support.scaledSpeed(model, DEFINITION.walkSpeed)
		state.lastHealth = humanoid.Health
	end

	local root = RigUtil.getRoot(model)
	if root then
		Support.playSound("BacteriaRoar", root)
	end
	--[[ The floor starts clean. A previous one's colonies are cleared rather
	     than inherited, which matters on a map that can be replayed without
	     reloading. ]]
	clearColonies()
	state.lastTrail = if root then root.Position else nil
	Support.setBrainTarget(brain, nil)
end

function BacteriaMonster.onUpdate(model: Model, brain: any, _dt: number)
	local state = states[model] or ensure(model)
	local root = RigUtil.getRoot(model)
	if not root then
		return
	end

	local now = os.clock()

	--[[ The colonies tick whether or not the creature is doing anything, and
	     before it does: they are the fight, and a frame where the creature is
	     staggered is not a frame where the floor is safe. ]]
	sweepColonies(now)

	--[[ Nothing is seeded while it burns. Both halves of the counter are here in
	     one place so there is no way to have one without the other. ]]
	if not isBurning(model) then
		stepTrail(model, state, root)
		stepBloom(model, brain, state, root)
	else
		--[[ While it burns, both trackers follow it rather than pausing.

		     The trail mark, so putting the fire out does not immediately drip a
		     colony for every stud it walked while alight. And the health mark,
		     so the damage the FIRE did is not banked and cashed the moment the
		     flames go out — which would turn burning it into a way to DEFER the
		     blooms rather than a way to stop them. ]]
		state.lastTrail = root.Position
		local humanoid = model:FindFirstChildOfClass("Humanoid")
		if humanoid then
			state.lastHealth = humanoid.Health
		end
	end

	if now >= state.nextRoar then
		state.nextRoar = now + random:NextNumber(9, 15)
		Support.playSound("BacteriaRoar", root)
	end
end

function BacteriaMonster.onDeath(model: Model, brain: any, _ctx: any)
	states[model] = nil
	Support.resumeBrain(brain)

	local root = RigUtil.getRoot(model)
	if root then
		Support.playSound("BacteriaDeath", root)
	end

	--[[ And the building comes back. See clearColonies: the floor clearing is
	     the reward, and a finale that left the map poisoned after it died would
	     make winning feel like losing more slowly. ]]
	clearColonies()
end

return BacteriaMonster
