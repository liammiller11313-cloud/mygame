--!strict
--[[
	SpawnPlacement — where the Director is allowed to put an infected.

	This module is most of what makes a Director feel FAIR rather than cheap. A
	horde that comes out of the dark end of a corridor is pressure. The same
	horde fading into existence twelve studs in front of a player is a bug
	report, and no amount of good pacing survives one of those. Every rule here
	exists to keep the first thing happening and to make the second impossible:

	  * a distance band, so nothing appears in your lap or half a map away;
	  * a flow window, so the horde is mostly AHEAD of the team and therefore
	    walks into them, rather than trailing behind and arriving as stragglers;
	  * an out-of-sight test that is a camera cone AND a line-of-sight ray.
	    Either alone is wrong: the cone alone rejects a perfectly legal spawn
	    that happens to be behind a wall you are facing, and the ray alone
	    accepts a spawn directly in front of you across an open room;
	  * a ground test, so nothing spawns half-buried in a floor or a stud above
	    it, waiting to fall.

	`find` allocates almost nothing, orders its tests cheapest-first so a bad
	candidate is rejected before it costs a raycast, bails out after
	`MaxSpawnAttempts`, and returns a reason string when it fails. That string is
	the difference between a Director that is visibly starving for spawn room and
	one that silently does nothing for a minute.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local DirectorConfig = require(Shared.Config.DirectorConfig)
local RaycastUtil = require(Shared.Util.RaycastUtil)
local Registry = require(Shared.Util.Registry)
local RigUtil = require(Shared.Util.RigUtil)
local Types = require(Shared.Types)

type SpawnOptions = Types.SpawnOptions

local SPAWNING = DirectorConfig.Spawning

-- Half the cone, as a cosine, computed once. This is compared against a dot
-- product per survivor per attempt, and math.cos in that loop is pure waste.
local SIGHT_COS = math.cos(math.rad(SPAWNING.SightCheckFovDegrees * 0.5))

--[[
	How far up and down `groundAt` looks from a sampled point. Sampled points are
	generated at survivor height, and a legal spawn is very often a storey below
	or above the survivor who anchored the sample — a stairwell, a rooftop, the
	street outside a first-floor window. Not a tuning number; it is the size of
	the search, and it only has to be larger than a plausible floor-to-floor gap.
]]
local GROUND_SEARCH_HEIGHT = 80

--[[
	Steeper than this and it is a wall, not a floor. Geometry sanity, not
	balance: ~60 degrees. A rig placed on a steep face slides off it immediately
	and reads as a physics glitch rather than as an enemy arriving.
]]
local MIN_GROUND_NORMAL_Y = 0.5

--[[ Spawn nodes are static level geometry, so the tag query is cached. The TTL
     is short enough that a map streamed in mid-round is picked up anyway. ]]
local NODE_CACHE_TIME = 2

--[[ Share of the attempt budget spent on tagged nodes before falling back to
     sampling. A map with plenty of nodes should use them, but a map whose nodes
     are all currently in view must still be able to place a spawn. ]]
local NODE_ATTEMPT_SHARE = 0.75

local SpawnPlacement = {}

local random = Random.new()

-- ════════════════════════════════════════════════════════════════════════════
--  Reused buffers
--
--  find() runs several times a second during a horde. None of these tables is
--  ever reallocated: they are cleared and refilled, so a peak-intensity
--  Director produces no garbage from spawn placement at all.
-- ════════════════════════════════════════════════════════════════════════════

type Survey = {
	character: Model,
	position: Vector3,
	eye: Vector3,
	look: Vector3,
}

local survey: { Survey } = {}
local surveyCount = 0

local ignore: { Instance } = {}
local nodeOrder: { BasePart } = {}

local nodeCache: { BasePart } = {}
local nodeCacheAt = -math.huge

local DEFAULT_OPTIONS: SpawnOptions = {
	minDistance = SPAWNING.MinDistanceFromSurvivor,
	maxDistance = SPAWNING.MaxDistanceFromSurvivor,
	requireOutOfSight = SPAWNING.RequireOutOfSight,
	minFlowAhead = SPAWNING.MinFlowAhead,
	maxFlowAhead = SPAWNING.MaxFlowAhead,
	attempts = SPAWNING.MaxSpawnAttempts,
}

local function distanceSquared(a: Vector3, b: Vector3): number
	local delta = a - b
	return delta:Dot(delta)
end

--[[
	Snapshots every survivor's position, eye point and facing.

	The server has no camera. A character's head faces where its owner's camera
	faces in first person and in shift-lock, which is how this game is played, so
	the head's LookVector is the server's honest read on what a player can see.
	`SightCheckFovDegrees` is deliberately wider than any real camera FOV to
	absorb the error in that assumption — being slightly too strict here costs a
	spawn attempt, and being slightly too loose costs the whole illusion.
]]
local function buildSurvey(survivors: { Model }): number
	surveyCount = 0
	for _, character in survivors do
		if typeof(character) ~= "Instance" or not character:IsA("Model") then
			continue
		end
		if not character:IsDescendantOf(Workspace) then
			continue
		end
		local root = RigUtil.getRoot(character)
		if not root then
			continue
		end

		local head = character:FindFirstChild("Head")
		local eyePart: BasePart = if head and head:IsA("BasePart") then head else root

		surveyCount += 1
		local entry = survey[surveyCount]
		if entry then
			entry.character = character
			entry.position = root.Position
			entry.eye = eyePart.Position
			entry.look = eyePart.CFrame.LookVector
		else
			survey[surveyCount] = {
				character = character,
				position = root.Position,
				eye = eyePart.Position,
				look = eyePart.CFrame.LookVector,
			}
		end
	end
	return surveyCount
end

--[[ Everything a placement raycast must not be stopped by: the survivors
     themselves and every body already in the world. A spawn point behind a
     crowd of zombies is still a spawn point. ]]
local function buildIgnoreList()
	table.clear(ignore)
	for index = 1, surveyCount do
		table.insert(ignore, survey[index].character)
	end
	local infectedFolder = Workspace:FindFirstChild("Infected")
	if infectedFolder then
		table.insert(ignore, infectedFolder)
	end
end

local function refreshNodes()
	local now = os.clock()
	if now - nodeCacheAt < NODE_CACHE_TIME then
		return
	end
	nodeCacheAt = now
	table.clear(nodeCache)

	-- find(), not get(): a map with no LevelService still gets sampled spawns,
	-- which is exactly what a test place or a broken level load needs.
	local level = Registry.find("LevelService")
	if not level or typeof(level.getSpawnNodes) ~= "function" then
		return
	end
	local ok, nodes = pcall(level.getSpawnNodes, level)
	if not ok or typeof(nodes) ~= "table" then
		return
	end
	for _, node in nodes :: { any } do
		if typeof(node) == "Instance" and node:IsA("BasePart") and node:IsDescendantOf(Workspace) then
			table.insert(nodeCache, node)
		end
	end
end

--[[ Shuffles the node list into `nodeOrder`. Without this the Director walks
     the same nodes in the same order every time and a horde always arrives from
     the same doorway, which players read as a spawn closet within one round. ]]
local function shuffleNodes()
	table.clear(nodeOrder)
	for _, node in nodeCache do
		table.insert(nodeOrder, node)
	end
	for index = #nodeOrder, 2, -1 do
		local swap = random:NextInteger(1, index)
		nodeOrder[index], nodeOrder[swap] = nodeOrder[swap], nodeOrder[index]
	end
end

--[[ A point on the ring around `origin`, at a random bearing and a random
     distance inside the band. Flat: the ground raycast owns the vertical. ]]
local function sampleAround(origin: Vector3, minDistance: number, maxDistance: number): Vector3
	local bearing = random:NextNumber() * math.pi * 2
	-- sqrt keeps the samples area-uniform instead of bunching them at minDistance.
	local span = math.max(maxDistance - minDistance, 0)
	local distance = minDistance + span * math.sqrt(random:NextNumber())
	return origin + Vector3.new(math.cos(bearing) * distance, 0, math.sin(bearing) * distance)
end

--[[ True when any survivor can plausibly see this point right now. ]]
local function isVisible(point: Vector3): boolean
	for index = 1, surveyCount do
		local entry = survey[index]
		local delta = point - entry.eye
		local distance = delta.Magnitude
		if distance < 1e-3 then
			return true
		end
		-- Cone first: it is three multiplies, and it rejects most candidates
		-- before the raycast that would otherwise dominate this function.
		if delta.Unit:Dot(entry.look) >= SIGHT_COS then
			if RaycastUtil.hasLineOfSight(entry.eye, point, ignore) then
				return true
			end
		end
	end
	return false
end

-- ════════════════════════════════════════════════════════════════════════════
--  find
-- ════════════════════════════════════════════════════════════════════════════

--[[
	Searches for a legal spawn position.

	Returns `(position, nil)` on success — a point ON THE GROUND, which is the
	same convention `InfectedService:spawn` expects, so the rig is lifted by its
	own bounding box exactly once and only in one place.

	Returns `(nil, reason)` on failure. The reason names the rules that did the
	rejecting, so a starving Director logs "18 in sight, 4 too close" instead of
	"could not spawn".

	`options.anchor` searches around a point instead of around the team — a
	Boomer's bile splash, a panic event's trigger, a boss zone. An anchored
	search deliberately drops the flow window: flow describes the team's progress
	through the level, and asking a bile horde to also arrive from ahead of the
	team would make most anchored spawns impossible. The minimum distance from
	every survivor and the out-of-sight rule still apply, which are the two rules
	that actually protect the illusion.
]]
function SpawnPlacement.find(survivors: { Model }, options: SpawnOptions?): (Vector3?, string?)
	local opts = options or DEFAULT_OPTIONS

	if buildSurvey(survivors) == 0 then
		return nil, "no survivor has a character to spawn around"
	end
	buildIgnoreList()

	local anchor = opts.anchor
	local minDistance = opts.minDistance or SPAWNING.MinDistanceFromSurvivor
	local maxDistance = opts.maxDistance or SPAWNING.MaxDistanceFromSurvivor
	local minDistanceSquared = minDistance * minDistance
	local maxDistanceSquared = maxDistance * maxDistance
	local attempts = math.max(1, math.floor(opts.attempts or SPAWNING.MaxSpawnAttempts))
	local requireOutOfSight = if opts.requireOutOfSight == nil
		then SPAWNING.RequireOutOfSight
		else opts.requireOutOfSight

	-- The flow window is skipped entirely for an anchored search (see above) and
	-- whenever the level cannot answer flow questions yet.
	local level = if anchor then nil else Registry.find("LevelService")
	local teamFlow: number? = nil
	local minFlowAhead = opts.minFlowAhead or SPAWNING.MinFlowAhead
	local maxFlowAhead = opts.maxFlowAhead or SPAWNING.MaxFlowAhead
	if level and typeof(level.getSurvivorFlow) == "function" then
		local ok, value = pcall(level.getSurvivorFlow, level)
		if ok and typeof(value) == "number" then
			teamFlow = value
		end
	end

	refreshNodes()
	local useNodes = #nodeCache > 0
	if useNodes then
		shuffleNodes()
	end
	local nodeBudget = if useNodes then math.max(1, math.floor(attempts * NODE_ATTEMPT_SHARE)) else 0

	local tooClose, tooFar, outOfFlow, noGround, steep, blocked, inSight = 0, 0, 0, 0, 0, 0, 0
	local nodeIndex = 0

	for attempt = 1, attempts do
		local candidate: Vector3?

		if useNodes and attempt <= nodeBudget then
			nodeIndex += 1
			local node = nodeOrder[nodeIndex]
			if node then
				candidate = node.Position
			end
		end
		if not candidate then
			local origin = anchor
			if not origin then
				origin = survey[random:NextInteger(1, surveyCount)].position
			end
			candidate = sampleAround(origin :: Vector3, minDistance, maxDistance)
		end
		local point = candidate :: Vector3

		-- ── free tests ──────────────────────────────────────────────────────
		local nearestSquared = math.huge
		for index = 1, surveyCount do
			local squared = distanceSquared(survey[index].position, point)
			if squared < nearestSquared then
				nearestSquared = squared
			end
		end
		if nearestSquared < minDistanceSquared then
			tooClose += 1
			continue
		end
		-- With an anchor the ceiling belongs to the anchor: a panic wave is
		-- bounded by its own radius, not by how far the team has spread out.
		if anchor then
			if distanceSquared(anchor, point) > maxDistanceSquared then
				tooFar += 1
				continue
			end
		elseif nearestSquared > maxDistanceSquared then
			tooFar += 1
			continue
		end

		-- ── one raycast: is there a floor here at all ───────────────────────
		local ground, normal = RaycastUtil.groundAt(point, GROUND_SEARCH_HEIGHT, ignore)
		if not ground or not normal then
			noGround += 1
			continue
		end
		if normal.Y < MIN_GROUND_NORMAL_Y then
			steep += 1
			continue
		end

		-- The ground point can be a long way below the sample, so the band is
		-- re-checked against where the body would actually stand.
		local groundedNearest = math.huge
		for index = 1, surveyCount do
			local squared = distanceSquared(survey[index].position, ground)
			if squared < groundedNearest then
				groundedNearest = squared
			end
		end
		if groundedNearest < minDistanceSquared then
			tooClose += 1
			continue
		end

		-- ── flow window ─────────────────────────────────────────────────────
		if teamFlow and level and typeof(level.getFlowDistance) == "function" then
			local ok, flow = pcall(level.getFlowDistance, level, ground)
			if ok and typeof(flow) == "number" then
				local ahead = flow - teamFlow
				if ahead < minFlowAhead or ahead > maxFlowAhead then
					outOfFlow += 1
					continue
				end
			end
		end

		-- ── headroom ────────────────────────────────────────────────────────
		local clearance = SPAWNING.SpawnGroundClearance
		local headroom = Workspace:Raycast(
			ground + Vector3.new(0, 0.1, 0),
			Vector3.new(0, clearance, 0),
			RaycastUtil.excluding(ignore)
		)
		if headroom then
			blocked += 1
			continue
		end

		-- ── the rule that matters ───────────────────────────────────────────
		-- Tested at body height, not at the floor: a floor point can be hidden
		-- behind a crate whose top half is in plain view, and it is the body the
		-- player would see appear.
		if requireOutOfSight and isVisible(ground + Vector3.new(0, clearance, 0)) then
			inSight += 1
			continue
		end

		return ground, nil
	end

	local parts = {}
	if inSight > 0 then
		table.insert(parts, string.format("%d in sight", inSight))
	end
	if tooClose > 0 then
		table.insert(parts, string.format("%d too close", tooClose))
	end
	if tooFar > 0 then
		table.insert(parts, string.format("%d too far", tooFar))
	end
	if outOfFlow > 0 then
		table.insert(parts, string.format("%d outside the flow window", outOfFlow))
	end
	if noGround > 0 then
		table.insert(parts, string.format("%d with no ground", noGround))
	end
	if steep > 0 then
		table.insert(parts, string.format("%d on a slope", steep))
	end
	if blocked > 0 then
		table.insert(parts, string.format("%d with no headroom", blocked))
	end
	if #parts == 0 then
		table.insert(parts, "no candidates generated")
	end

	return nil,
		string.format(
			"no spawn point in %d attempts (%s%s)",
			attempts,
			table.concat(parts, ", "),
			if useNodes then string.format("; %d tagged nodes", #nodeCache) else "; no tagged nodes"
		)
end

return SpawnPlacement
