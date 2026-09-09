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
local MapConfig = require(Shared.Config.MapConfig)
local RaycastUtil = require(Shared.Util.RaycastUtil)
local Registry = require(Shared.Util.Registry)
local SpawnVolume = require(script.Parent.SpawnVolume)
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
	How far ABOVE a candidate the ground ray starts.

	Deliberately tiny, and it is the difference between a horde and a rooftop
	display. Candidates are generated at a SURVIVOR'S OWN HEIGHT — a place a
	person is standing — so the floor that belongs to them is a few studs below,
	never above. A generous rise here does not find that floor more reliably; it
	finds the roof of whatever the candidate is standing next to, and the body is
	placed on it.

	Five studs covers a node pushed into a kerb and nothing taller than a step.
]]
local GROUND_RISE = 5

--[[
	Steeper than this and it is a wall, not a floor. Geometry sanity, not
	balance: ~60 degrees. A rig placed on a steep face slides off it immediately
	and reads as a physics glitch rather than as an enemy arriving.
]]
local MIN_GROUND_NORMAL_Y = 0.5

--[[
	── OVERHEAD COVER ──────────────────────────────────────────────────────────

	How far up to look for a roof, from the team and from a candidate alike.

	THE BUG THIS EXISTS FOR: a Tank arrived on top of the Backrooms. Everything
	that was supposed to prevent that did its job and none of it applied.
	MaxHeightFromSurvivor is the rule written to keep bodies off roofs, and it is
	twenty-five studs — chosen against a city map, where a roof is far enough up
	that twenty-five excludes it. An interior ceiling is about twelve studs over
	your head, so the roof of the building the team is standing INSIDE sits well
	within the band, and the guard never fired. The ground test did not object
	either: a roof is a flat surface with an upward normal, which is the entire
	definition of a floor.

	Height cannot answer this, because a mezzanine and a roof are at the same
	height. This asks the question that can: IS THE TEAM UNDER SOMETHING, AND IS
	THIS CANDIDATE UNDER IT TOO. Inside the Backrooms the answer is yes and no,
	and the candidate is rejected. On the roof itself — a team that fought its way
	up there — the answer is no and no, and nothing changes.

	── IT COSTS NOTHING ON AN OUTDOOR MAP ──────────────────────────────────────
	The team's own cover is sampled once per search, not per attempt. On Clinton
	or Zombieville the team is under open sky, the rule switches itself off, and
	the per-candidate ray never runs. It is one extra raycast per candidate on
	exactly the maps where a roof is reachable and indistinguishable by height,
	which is where it is worth paying for.

	── WHY NOT A MAP FLAG ──────────────────────────────────────────────────────
	`enclosed = true` in MapConfig would be simpler and would be wrong twice: a
	street map with an underpass has covered stretches, and an interior map with
	an atrium has open ones. The team's own position answers per-moment what a
	flag could only answer per-map, and it needs no author to remember it.
]]
local COVER_HEIGHT = 60

--[[
	How far ABOVE the team an uncovered candidate has to be before cover means
	anything.

	Without this the rule has a false positive that matters more than the bug it
	was written for. "The team is indoors and this candidate is not" is true of a
	roof AND of the street outside the shop the team just walked into — and a
	zombie coming in off that street through the door is the single most ordinary
	thing this game does. On a map like Clinton the team goes indoors constantly,
	and a rule that switched the street off every time would starve spawning for
	most of a round.

	Height alone cannot tell a mezzanine from a roof. Cover alone cannot tell a
	roof from a street. Together they can: a roof is uncovered AND above you, a
	street is uncovered and beside you. Four studs is a step and a kerb — enough
	that a pavement slightly higher than a shop floor is still a pavement.
]]
local COVER_RISE = 4

--[[ Spawn nodes are static level geometry, so the tag query is cached. The TTL
     is short enough that a map streamed in mid-round is picked up anyway. ]]
local NODE_CACHE_TIME = 2

--[[
	── WHERE CANDIDATES COME FROM ──────────────────────────────────────────────

	Two sources, and the split between them is one number.

	A tagged FL_SpawnNode is a person saying "a zombie may come from here", which
	is information no query produces. The ring is a guess: a point on a doughnut
	around the team, tested against every rule below before it is used.

	── WHY IT IS 0.75 AND NOT 0.9 ──────────────────────────────────────────────
	It was briefly 0.9, on the reasoning that a deliberate place beats a guessed
	one. That is true per candidate and wrong in aggregate, because a node can be
	unusable for reasons that have nothing to do with whether it is a good place:
	too far from the team right now, outside the flow window, currently in
	somebody's view, or occupied. A real map showed it — sixteen nodes, and a
	search reporting "11 too far, 4 outside the flow window, 6 with no ground"
	with the nearest node 388 studs away. Spawning starved while the pressure
	kept climbing.

	The ring does not starve. It generates a fresh point per attempt near the
	team by construction, and every rule that protects the illusion still applies
	to it — minimum distance, out of sight, ground, headroom, the body's own box.
	A ring point that passes all of those is not a worse spawn than a node that
	passes all of those; it is the same spawn without a person having chosen it.

	So nodes get the larger share and first refusal, and the ring gets enough of
	the budget to keep the horde arriving when the nodes cannot. That is what the
	number was before the map-wide field experiment, and the experiment is what
	made it look like the ring was the part worth cutting.
]]
local NODE_ATTEMPT_SHARE = 0.75

--[[
	Attempts the ring is guaranteed, whatever the share works out to.

	The share alone is not enough, and the arithmetic is worth stating because it
	is not obvious. `nodeOrder` is walked ONCE per pass — each node is offered at
	most once — so a node budget larger than the node count simply exhausts, and
	every attempt past it falls through to the ring anyway. On a sixteen-node map
	with twenty-four attempts, a share of 0.9 and a share of 0.75 both leave the
	ring exactly eight. Changing the share there does nothing at all.

	Where it DOES bite is a map with plenty of nodes: forty nodes at 0.75 leaves
	the ring six attempts, and if those nodes are clustered away from the route
	the horde starves while the search politely re-tests places it cannot use.

	So the ring gets a floor. Nodes still get first refusal and the larger share;
	this only guarantees that some of the budget is always spent looking near the
	team, which is where the players are and therefore where a spawn is most
	likely to be both legal and useful.
]]
local RING_MIN_ATTEMPTS = 6

--[[
	How much room a node needs to itself before it may be used again.

	MinDistanceFromSurvivor already keeps bodies away from the team, and the
	relaxation ladder deliberately never gives it up. This is a second, smaller
	rule that answers a different question: is this specific node OCCUPIED right
	now.

	It matters for two cases the distance ceiling does not cover.

	A caller may pass its own `minDistance` — a bile horde or a panic event
	names its own radius — and nothing stopped that being smaller than a body.
	This does not read that field, so a survivor standing on a node keeps it
	from being used no matter what radius the event asked for.

	And a wave is many bodies through one call. With sixteen nodes and a horde
	of twelve, nothing kept two bodies off the same node on the same tick, so
	they materialised inside each other and shoved themselves apart — which
	looks exactly like the spawn-into-geometry bug and is not one.
]]
local NODE_OCCUPIED_RADIUS = 9
local NODE_OCCUPIED_SQUARED = NODE_OCCUPIED_RADIUS * NODE_OCCUPIED_RADIUS

--[[ How long a node stays spoken for after a body is placed on it. Long enough
     for that body to walk off it, short enough that a small map does not run
     out of places to spawn during a sustained horde. ]]
local NODE_COOLDOWN = 1.5

--[[ How many broken nodes the failure message names before it stops. Enough to
     act on, few enough that a map whose nodes are all in the air does not print
     a paragraph every eight seconds. ]]
local BROKEN_NODES_NAMED = 4

--[[ When each node last had a body put on it, keyed by the node instance. Weak
     keys: a map swap destroys the nodes and this must not hold them alive. ]]
local nodeUsedAt = (setmetatable({}, { __mode = "k" }) :: any) :: { [Instance]: number }

--[[
	How far the ceiling opens when the strict search finds nothing at all.

	1.75x, once. Not a slider and not a loop that keeps widening: past roughly
	this the body has so far to walk that it arrives after the moment it was
	spawned for, and a Director that always eventually succeeds is a Director
	that has stopped telling you your map is wrong.
]]
local RELAX_DISTANCE = 1.75

local warned: { [string]: boolean } = {}
local function warnOnce(key: string, message: string)
	if warned[key] then
		return
	end
	warned[key] = true
	warn("[SpawnPlacement] " .. message)
end

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

--[[ Reused by isCovered. Built once and refiltered per call, like every other
     buffer here — a RaycastParams allocated inside the candidate loop would be
     garbage generated several times a second during a horde. ]]
local coverParams = RaycastParams.new()
coverParams.FilterType = Enum.RaycastFilterType.Exclude
coverParams.IgnoreWater = true
--[[ Deliberately NOT RespectCanCollide. A non-colliding roof is still a roof —
     it is the thing that tells you which side of the building you are on, and a
     body cannot walk down through it whether it collides or not. ]]
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

--[[ Whether a node is free right now: nobody standing on it, and nothing placed
     on it in the last breath. Deliberately independent of every rule in the
     relaxation ladder — a ladder gives up rules to find somewhere at all, and
     "somewhere at all" must never mean on top of a player. ]]
local function nodeIsFree(node: Instance, position: Vector3, now: number): boolean
	if now - (nodeUsedAt[node] or -math.huge) < NODE_COOLDOWN then
		return false
	end
	for index = 1, surveyCount do
		if distanceSquared(survey[index].position, position) < NODE_OCCUPIED_SQUARED then
			return false
		end
	end
	return true
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

--[[ Is anything solid within COVER_HEIGHT above this point. See OVERHEAD COVER.

     Started two studs up so the floor the body would stand on is never itself
     the thing found, and filtered by the same ignore list every other test uses
     so a survivor or another body overhead is not mistaken for a ceiling. ]]
local function isCovered(point: Vector3): boolean
	coverParams.FilterDescendantsInstances = ignore
	local hit = Workspace:Raycast(point + Vector3.new(0, 2, 0), Vector3.new(0, COVER_HEIGHT, 0), coverParams)
	return hit ~= nil
end

--[[
	The loaded map's root, or nil when there is not one.

	Resolved per search rather than cached: a map swap replaces it, and a stale
	root would reject every candidate in the new level rather than the old one.
	One Registry lookup per find, which is a table read.
]]
local function mapRoot(): Instance?
	local mapService: any = Registry.find("MapService")
	if not mapService or typeof(mapService.getCurrentRoot) ~= "function" then
		return nil
	end
	local ok, root = pcall(mapService.getCurrentRoot, mapService)
	return if ok and typeof(root) == "Instance" then root else nil
end

--[[
	Does this floor belong to the level.

	The strongest of the three placement guards and the cheapest, because the
	raycast that found the floor already knew the answer — see RaycastUtil.groundAt,
	which now returns the instance for this one caller.

	It rules out every surface that is not the map: the lobby, a baseplate, a
	barricade somebody welded together this round, a dropped medkit, and whatever
	else is sitting in Workspace. "Actually in the map" is the plainest possible
	statement of what a spawn has to be, and until now nothing anywhere asserted
	it — SpawnVolume's own header says it does not check reachability and hands
	the question to "whatever is choosing candidate points", and no chooser
	picked it up.

	Terrain is allowed explicitly. It is never a descendant of the map model —
	it is a single Workspace-wide object — so a map whose floor is terrain would
	otherwise fail every candidate it has.

	No map root means no test. A test place with geometry and no MapService is a
	legitimate way to work on this game, and a rule that turned it into a place
	where nothing spawns would be a rule people delete.
]]
--[[
	May a body be placed on this surface at all.

	The one guard here that is not an inference. Every other rule in this file
	reasons about geometry — how high it is, whether there is a roof over it,
	whether it is part of the map — and each of them can be fooled by an unusual
	room. This asks the level designer, who named the thing.

	── IT WALKS THE ANCESTORS, NOT JUST THE PART ───────────────────────────────
	Which is the whole reason it works on a real map. The Backrooms keeps its
	geometry in a model called Walls holding models called section, whose PARTS
	are named whatever the artist felt like — so testing the part alone answers
	nothing and testing the part plus everything above it answers all of them
	from one entry. Stops at the map root: a Workspace or a folder called
	something unlucky is not a statement about this surface.

	See MapConfig.NeverStandOn for the names and why "Celing" is spelled twice.
]]
local function isFloorSurface(part: BasePart?, root: Instance?): boolean
	if not part then
		return true
	end
	local node: Instance? = part
	while node and node ~= root and node ~= Workspace do
		if MapConfig.isNeverStandOn(node.Name) then
			return false
		end
		node = node.Parent
	end
	return true
end

local function belongsToMap(part: BasePart?, root: Instance?): boolean
	if not root or not part then
		return true
	end
	if part:IsA("Terrain") then
		return true
	end
	return part:IsDescendantOf(root)
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

	A search that finds nothing does NOT simply fail. It gives up its softest
	rules one at a time and tries again — see the relaxation ladder inside — so
	a map whose spawn nodes all sit outside the ceiling produces infected that
	walk further than intended rather than a round with no infected in it. The
	minimum distance and the out-of-sight rule never relax.

	`options.anchor` searches around a point instead of around the team — a
	Boomer's bile splash, a panic event's trigger, a boss zone. An anchored
	search deliberately drops the flow window: flow describes the team's progress
	through the level, and asking a bile horde to also arrive from ahead of the
	team would make most anchored spawns impossible. The minimum distance from
	every survivor and the out-of-sight rule still apply, which are the two rules
	that actually protect the illusion.
]]
--[[
	Re-validates a point that was DERIVED from a legal one.

	The Director scatters a batch a couple of studs around one cleared placement
	so they do not all appear inside one silhouette, and for a long time the
	comment on that scatter said the offset was free because "the point was
	already validated for ground and clearance". The CENTRE was. The offset was
	not, and it was never tested by anything.

	Two and a half studs is most of a body. Scattered off a cleared point next to
	a wall, a car, a railing or a stair riser — which is most of a street map —
	the body appears with its torso inside the geometry, where no client can see
	it and its brain drives it at the team anyway. That is damage arriving from a
	zombie that is not visibly there, and it is why this function exists.

	Cheap on purpose: one downward ray and one box test, run per spawn only on
	the scatter path. Returns the settled floor point, or nil for a caller that
	should fall back to the point it derived this one from.
]]
function SpawnPlacement.settle(point: Vector3, kind: string?): Vector3?
	if typeof(point) ~= "Vector3" then
		return nil
	end
	--[[ The same ignore list the search itself uses — survivor characters and
	     the Infected folder — so a body standing where this one is going does not
	     count as the floor, or as the thing blocking it. It is rebuilt by every
	     `find`, and a scatter only ever happens moments after one. ]]
	local ground, normal, floor = RaycastUtil.groundAt(point, GROUND_SEARCH_HEIGHT, ignore, GROUND_RISE)
	if not ground or not normal or normal.Y < MIN_GROUND_NORMAL_Y then
		return nil
	end
	--[[ The scatter is small — two and a half studs — and that is exactly enough
	     to walk off the edge of a cleared point onto the top of the wall beside
	     it. The centre was tested; this is the same test on the offset. ]]
	local root = mapRoot()
	if not belongsToMap(floor, root) or not isFloorSurface(floor, root) then
		return nil
	end
	if not SpawnVolume.fitsKind(ground, kind, ignore) then
		return nil
	end
	return ground
end

function SpawnPlacement.find(survivors: { Model }, options: SpawnOptions?): (Vector3?, string?)
	local opts = options or DEFAULT_OPTIONS

	if buildSurvey(survivors) == 0 then
		return nil, "no survivor has a character to spawn around"
	end
	buildIgnoreList()

	local anchor = opts.anchor
	local minDistance = opts.minDistance or SPAWNING.MinDistanceFromSurvivor
	local maxDistance = opts.maxDistance or SPAWNING.MaxDistanceFromSurvivor
	local maxHeight = SPAWNING.MaxHeightFromSurvivor
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

	--[[
		Is the TEAM under a roof right now.

		Once per search, not per candidate, and it is what switches the whole rule
		on and off: outdoors this is false, the per-candidate ray never runs, and
		nothing about an outdoor map changes at all.

		ANY survivor being covered counts, rather than all of them. A team spread
		across a doorway has one person out in the rain, and the honest reading of
		"we are inside the building" is that somebody is — the alternative rejects
		nothing for as long as one player stands in the entrance.
	]]
	local root = mapRoot()

	local teamCovered = false
	--[[ The HIGHEST survivor, which is what "above the team" is measured from.
	     Highest rather than nearest: a team spread over a staircase has somebody
	     at the top of it, and a candidate below THEM is still inside the building
	     rather than on top of it. ]]
	local highestSurvivorY = -math.huge
	for index = 1, surveyCount do
		local entry = survey[index]
		if entry.position.Y > highestSurvivorY then
			highestSurvivorY = entry.position.Y
		end
		if not teamCovered and isCovered(entry.position) then
			teamCovered = true
		end
	end

	refreshNodes()
	local useNodes = #nodeCache > 0
	if useNodes then
		shuffleNodes()
	end
	--[[ Capped so the ring keeps its floor. See RING_MIN_ATTEMPTS: without this
	     a well-tagged map can spend its whole budget on nodes and starve when
	     none of them happen to be usable right now. ]]
	local nodeBudget = if useNodes
		then math.clamp(
			math.floor(attempts * NODE_ATTEMPT_SHARE),
			1,
			math.max(attempts - RING_MIN_ATTEMPTS, 1)
		)
		else 0

	local tooClose, tooFar, outOfFlow, noGround, steep, blocked, inSight = 0, 0, 0, 0, 0, 0, 0
	--[[ Candidates whose ground sat too far above or below the team — a roof, a
	     gantry, the bottom of a shaft. See where this is counted. ]]
	local tooHigh = 0
	--[[ Candidates above the team and out under open sky. See OVERHEAD COVER —
	     this is the counter that says "your map has a reachable roof", which is a
	     different sentence from "too far above the team" and was the one nobody
	     could read before. ]]
	local uncovered = 0
	--[[ Candidates whose floor was not part of the level. See belongsToMap. ]]
	local offMap = 0
	--[[ Candidates standing on a ceiling or a wall, by NAME. See isFloorSurface —
	     this is the counter that means "your map told us and we listened", which
	     is a different and much better sentence than any of the guesses above. ]]
	local notFloor = 0
	--[[ Nodes the walk stepped straight past because they are outside the band.
	     Counted rather than merged into `tooFar` because they are a different
	     fact about the map: `tooFar` is candidates this search generated and
	     rejected, this is places a designer tagged that are nowhere near the
	     team. See where nodes are picked for why they are skipped and not
	     tested. ]]
	local nodesOutOfRange = 0
	local nodeIndex = 0

	--[[
		── THE RELAXATION LADDER ───────────────────────────────────────────────
		A map whose spawn nodes all sit outside the ceiling produces a Director
		that never spawns anything at all. That is not hypothetical: a test place
		logged "16 too far ... 16 tagged nodes" every eight seconds while the
		pressure escalated from 1 to 6 and not one body arrived, because every
		node was farther from the team than MaxDistanceFromSurvivor and the search
		had nothing softer to give up.

		So a failed strict search gives up its rules in order of how much they
		matter, one pass at a time:

		  1. everything                       — what we actually want
		  2. minus the flow window            — spawning behind the team reads
		                                        worse than spawning nothing? no.
		  3. minus the distance ceiling       — they walk further than ideal

		The two rules that protect the ILLUSION never relax. A body still may not
		appear inside MinDistanceFromSurvivor and still may not appear in anyone's
		view, because a zombie materialising in front of a player is the one
		failure worse than an empty corridor.

		A pass that cannot change the outcome is skipped, so the ordinary case
		costs exactly one pass and the degenerate case is bounded at three.

		── WHAT THIS COSTS, AND WHY THAT IS ACCEPTABLE ─────────────────────────
		On a map where the strict search succeeds — which is every map that is
		authored correctly — this is free: pass 1 returns and passes 2 and 3 never
		run. On a map where it does not, every placement pays up to three times the
		raycasts, permanently, because the strict pass keeps failing for the same
		reason it failed the first time.

		That is deliberately NOT cached away behind a "this map is bad" flag. The
		cost is the price of a map that needs fixing, it is bounded, and the
		warning above says exactly what to fix — whereas a cache would make the
		symptom quiet and the map stay wrong. Spawning nothing at all, which is
		what happened before, was not cheaper in any sense that matters.
	]]
	--[[ Once per search rather than per attempt: the kind cannot change inside a
	     find, and sizeFor walks the config.

	     An absent kind takes the LARGEST body, which is the safe direction and
	     is not the cheap one it reads as. That used to be a Tank, and "a gap
	     that fits a Tank fits everything" was true and comfortable; the largest
	     body is now the Metallic at seventeen studs, a quarter taller again, and
	     a map with no gap that big returns nothing at all. Pass a kind whenever
	     you have one — a caller who knows it is asking for a Jockey and does not
	     say so is asking for a hole two body-widths too big. ]]
	local bodySize = if opts.kind then SpawnVolume.sizeFor(opts.kind) else SpawnVolume.largestSize()

	--[[ Overhead cover is NOT on the ladder, and belongs with the two rules that
	     never relax rather than with the two that do. Widening a radius does not
	     make a roof reachable; it finds more roof. A search that rejected every
	     candidate for this reason correctly returns nothing and says so, and the
	     Director queues the request and tries again a moment later — which is the
	     same thing it does for every other placement failure. ]]
	local strictMaxSquared = maxDistanceSquared
	local relaxedFlow = false
	local relaxedDistance = false

	for pass = 1, 3 do
		if pass == 2 then
			-- Nothing to give up if flow was never applied or never rejected
			-- anything.
			if teamFlow == nil or outOfFlow == 0 then
				continue
			end
			teamFlow = nil
			relaxedFlow = true
		elseif pass == 3 then
			-- An anchored search keeps its radius: a bile horde that arrives from
			-- outside the bile is not the event any more, and PANIC.SpawnRadius is
			-- that event's own definition rather than a global default.
			--[[ tooHigh votes for this pass too, because pass 3 widens the height
			     band along with the ceiling — so a map whose only reachable ground
			     is a storey up would otherwise be refused a relaxation that exists
			     precisely for it. ]]
			if anchor or (tooFar == 0 and nodesOutOfRange == 0 and tooHigh == 0) then
				continue
			end
			--[[ BOTH, and that is the point. `maxDistanceSquared` is what the
			     acceptance test uses and `maxDistance` is what sampleAround
			     generates inside, so widening only the first would open the ceiling
			     for the tagged nodes and leave every ring sample drawn from the
			     original band — a pass that tests new ground for nodes and re-tests
			     identical ground for everything else. ]]
			maxDistance *= RELAX_DISTANCE
			maxDistanceSquared = maxDistance * maxDistance
			--[[ The height band widens with the ceiling rather than staying put.
			     They are the same concession — "they walk further than ideal" — and
			     a map that genuinely needs the wider radius is usually the one whose
			     route also climbs. Still nowhere near a roof eighty studs up. ]]
			maxHeight *= RELAX_DISTANCE
			relaxedDistance = true
		end

		tooClose, tooFar, outOfFlow, noGround, steep, blocked, inSight = 0, 0, 0, 0, 0, 0, 0
		tooHigh = 0
		uncovered = 0
		offMap = 0
		notFloor = 0
		nodesOutOfRange = 0
		nodeIndex = 0

		for attempt = 1, attempts do
			local candidate: Vector3?
			--[[ Which node this candidate came from, or nil for a ring sample.
			     Carried down to the accept so the node can be marked used — a
			     node is only spoken for once a body actually goes on it, never
			     because it was merely considered. ]]
			local chosenNode: Instance? = nil
			local now = os.clock()

			if useNodes and attempt <= nodeBudget then
				--[[
					Walks past nodes it cannot use rather than spending the attempt
					on one. A node with somebody standing on it is not a near miss to
					be tested and rejected; it is simply not this tick's node.

					── AND PAST NODES THAT ARE NOWHERE NEAR THE TEAM ────────────────
					This is what "the old way" actually was, and losing it is what
					starved the Director.

					Every node used to be offered, tested and counted, which is fine
					when a node is a plausible candidate and wasteful when it cannot
					possibly be one. A real map showed the cost: sixteen tagged nodes,
					the nearest of them 388 studs from the team, a ceiling of far less
					than that — so sixteen of twenty-four attempts were spent
					re-deriving that sixteen fixed points had not moved, and the ring
					got whatever was left. Tuning the node/ring SHARE does nothing
					about that, because nodeOrder is walked once per pass: a share
					above the node count simply exhausts, and 0.9 and 0.75 leave the
					ring exactly the same eight attempts.

					Skipping is the fix, and it costs one squared distance compare —
					cheaper than the acceptance test it replaces, which raycast. When
					some nodes are in range they still get first refusal and the ring
					still gets its floor; when NONE are, the whole budget falls
					through to the ring on the first attempt and the horde arrives
					from around the team exactly as it did before there were nodes at
					all.

					It stays inside the relaxation ladder rather than sidestepping it:
					the band read here is the CURRENT pass's, so pass 3's wider
					ceiling puts the distant nodes back in play instead of hiding them
					from the one pass that was widened to reach them.
				]]
				while nodeIndex < #nodeOrder do
					nodeIndex += 1
					local node = nodeOrder[nodeIndex]
					if not node then
						continue
					end
					if not nodeIsFree(node, node.Position, now) then
						continue
					end

					local position = node.Position
					local nearest = math.huge
					for index = 1, surveyCount do
						local squared = distanceSquared(survey[index].position, position)
						if squared < nearest then
							nearest = squared
						end
					end
					--[[ Too CLOSE is counted apart from too far, and not into
					     nodesOutOfRange, because the two ask for opposite things.
					     Widening the ceiling in pass 3 cannot rescue a node parked
					     next to the team — that rule never relaxes — so letting it
					     vote for the relaxation would buy two more passes of
					     identical work on the way to the same failure. ]]
					if nearest < minDistanceSquared then
						tooClose += 1
						continue
					end
					--[[ With an anchor the ceiling belongs to the anchor, matching
					     the acceptance test below: a panic wave is bounded by its own
					     radius rather than by how far the team has spread out. ]]
					local ceiling = if anchor then distanceSquared(anchor, position) else nearest
					if ceiling > maxDistanceSquared then
						nodesOutOfRange += 1
						continue
					end

					candidate = position
					chosenNode = node
					break
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
			local ground, normal, floor =
				RaycastUtil.groundAt(point, GROUND_SEARCH_HEIGHT, ignore, GROUND_RISE)
			if not ground or not normal then
				noGround += 1
				continue
			end
			if normal.Y < MIN_GROUND_NORMAL_Y then
				steep += 1
				continue
			end
			--[[ Before every other test, because it is free — the ray already
			     found this part — and because it is the one that answers "is this
			     even in the level". ]]
			if not belongsToMap(floor, root) then
				offMap += 1
				continue
			end
			--[[ And is it a surface anybody said may be stood on. Last of the
			     three because it is the only one that can be answered wrong by a
			     map rather than by this code: a designer who names nothing gets
			     the geometric guards above and nothing worse. ]]
			if not isFloorSurface(floor, root) then
				notFloor += 1
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

			--[[
				── HOW FAR UP OR DOWN ──────────────────────────────────────────────
				The distance band is a SPHERE, so without this a point ninety studs
				overhead and a hundred and fifty out is a perfectly legal spawn. On a
				map with buildings that is a roof, and what players see is zombies
				standing in the air that never arrive — while the ones that did
				arrive are thin, because the stuck ones hold their slots for the full
				maroon window.

				Measured against the nearest survivor's own height rather than an
				absolute, so a vertical map costs nothing: a team on a rooftop
				finale gets rooftop spawns because the rule moves with them.

				Against the GROUND point, not the sample — the sample was generated
				at survivor height by construction, so testing it would always pass
				and answer nothing.
			]]
			local heightGap = math.huge
			for index = 1, surveyCount do
				local gap = math.abs(survey[index].position.Y - ground.Y)
				if gap < heightGap then
					heightGap = gap
				end
			end
			if heightGap > maxHeight then
				tooHigh += 1
				continue
			end

			--[[
				── UNDER THE SAME ROOF, AND ABOVE IT ───────────────────────────────
				The height rule above cannot tell a mezzanine from a roof, because
				they are at the same height. Cover alone cannot tell a roof from the
				street outside the shop the team walked into. Both together can: a
				roof is uncovered AND above you; a street is uncovered and beside
				you, and a zombie coming in off it through the door is the most
				ordinary thing in this game.

				Applied only when the team itself is covered, so an outdoor map
				never reaches this line at all. The reverse is deliberately NOT
				tested — a covered candidate while the team is outside is a doorway,
				a porch or an underpass, which is a perfectly good place for a
				zombie to come from and the single most atmospheric one.
			]]
			if teamCovered and ground.Y > highestSurvivorY + COVER_RISE and not isCovered(ground) then
				uncovered += 1
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

			--[[ ── does a body actually FIT here ─────────────────────────────────
			     This was a single upward ray three studs long, which answers "is
			     there a ceiling overhead" and nothing else. A point one stud from
			     a wall passed it and the rig appeared with its torso inside the
			     wall — a zombie that shoves against geometry forever and never
			     reaches anyone. SpawnVolume asks about the whole box the body
			     stands in, sized from the kind's own scale, so a Tank is told the
			     truth about a gap that fits a Common. ]]
			if not SpawnVolume.fits(ground, bodySize, ignore) then
				blocked += 1
				continue
			end
			local clearance = SPAWNING.SpawnGroundClearance

			-- ── the rule that matters ───────────────────────────────────────────
			-- Tested at body height, not at the floor: a floor point can be hidden
			-- behind a crate whose top half is in plain view, and it is the body the
			-- player would see appear.
			if requireOutOfSight and isVisible(ground + Vector3.new(0, clearance, 0)) then
				inSight += 1
				continue
			end

			if relaxedDistance then
				warnOnce(
					"relaxed:distance",
					string.format(
						"no legal spawn within %d studs of the team — placing at up to %d instead. "
							.. "Every spawn node this search could see is outside the ceiling, which "
							.. "means the infected walk a long way before they reach anyone. Move some "
							.. "FL_SpawnNode parts nearer the route, or raise "
							.. "DirectorConfig.Spawning.MaxDistanceFromSurvivor.",
						math.floor(math.sqrt(strictMaxSquared)),
						math.floor(math.sqrt(maxDistanceSquared))
					)
				)
			elseif relaxedFlow then
				warnOnce(
					"relaxed:flow",
					"no legal spawn inside the flow window — placing without it. The horde will "
						.. "arrive from behind the team as often as from ahead until the level's "
						.. "flow nodes cover the route they actually take."
				)
			end
			--[[ Marked here and nowhere else: the moment a body is actually
			     placed. Every earlier exit from this attempt leaves the node free
			     for the next one. ]]
			if chosenNode then
				nodeUsedAt[chosenNode] = now
			end
			return ground, nil
		end
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
	if nodesOutOfRange > 0 then
		table.insert(parts, string.format("%d node visit(s) skipped as out of range", nodesOutOfRange))
	end
	if notFloor > 0 then
		table.insert(parts, string.format("%d on a ceiling or a wall", notFloor))
	end
	if offMap > 0 then
		table.insert(parts, string.format("%d standing on something that is not the map", offMap))
	end
	if uncovered > 0 then
		table.insert(parts, string.format("%d above the team and out under open sky — a roof", uncovered))
	end
	if tooHigh > 0 then
		table.insert(parts, string.format("%d too far above or below the team", tooHigh))
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
		table.insert(parts, string.format("%d too tight for the body", blocked))
	end
	if #parts == 0 then
		table.insert(parts, "no candidates generated")
	end

	--[[
		How far the nearest node actually is, and which nodes the world rejected.

		The counts above say which RULE fired; they do not say what to go and do
		about it. "11 too far" invites moving nodes without saying how much
		nearer they need to be, and "6 with no ground" names a broken node
		without naming WHICH — and a node with nothing under it is a node
		somebody dragged into the air or inside a wall, which is a thirty-second
		fix once you know its name.

		Both are computed here, on the failure path only, so a search that
		succeeds pays nothing for them.
	]]
	local nearestNode = math.huge
	local broken: { string } = {}
	for _, node in nodeCache do
		if not node.Parent then
			continue
		end
		for index = 1, surveyCount do
			local squared = distanceSquared(survey[index].position, node.Position)
			if squared < nearestNode then
				nearestNode = squared
			end
		end
		if #broken < BROKEN_NODES_NAMED then
			local ground, normal =
				RaycastUtil.groundAt(node.Position, GROUND_SEARCH_HEIGHT, ignore, GROUND_RISE)
			if not ground or not normal then
				table.insert(broken, node.Name .. " (nothing under it)")
			elseif normal.Y < MIN_GROUND_NORMAL_Y then
				table.insert(broken, node.Name .. " (on a slope)")
			elseif not SpawnVolume.fits(ground, bodySize, ignore) then
				table.insert(broken, node.Name .. " (no room for a body)")
			end
		end
	end

	local diagnosis = ""
	if nearestNode < math.huge then
		diagnosis =
			string.format("; nearest node is %d studs from the team", math.floor(math.sqrt(nearestNode)))
	end
	if #broken > 0 then
		diagnosis ..= "; unusable right now: " .. table.concat(broken, ", ")
	end

	--[[ Naming the relaxations that were already tried is the point of this
	     string: "24 attempts, all too far" invites raising the ceiling, and
	     "even with the ceiling opened" says the ceiling was never the problem. ]]
	local gaveUp = ""
	if relaxedDistance then
		gaveUp = "; even with the ceiling opened to " .. tostring(math.floor(math.sqrt(maxDistanceSquared)))
	elseif relaxedFlow then
		gaveUp = "; even without the flow window"
	end

	return nil,
		string.format(
			"no spawn point in %d attempts (%s%s%s)",
			attempts,
			table.concat(parts, ", "),
			--[[ The node count is the actionable half of this message. A map with
			     no tagged nodes, or with sixteen that are all in view, is a map
			     that wants more FL_SpawnNode parts — and that is a thing a person
			     can go and do. ]]
			(
				if useNodes
					then string.format("; %d tagged node(s)", #nodeCache)
					else "; NO tagged nodes — add FL_SpawnNode parts to the map"
			) .. diagnosis,
			gaveUp
		)
end

return SpawnPlacement
