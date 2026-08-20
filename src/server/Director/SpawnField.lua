--!strict
--[[
	SpawnField — everywhere in this map a body could stand.

		SpawnField.remember(position)        -- a survivor stood here; it is valid
		SpawnField.step(budget)              -- explore a few more cells
		local point = SpawnField.sample(rng) -- somewhere, anywhere

	── WHY THIS EXISTS ─────────────────────────────────────────────────────────
	The Director could only put a horde in two kinds of place: on a part a level
	designer had tagged FL_SpawnNode, or on a random ring sampled around a
	survivor. A map with no tags therefore had one source, and that source only
	ever looks at the doughnut immediately around the team.

	On a real map that failed outright. A test place logged "16 too far ... 16
	tagged nodes" every eight seconds while pressure climbed and nothing arrived,
	because every tagged node was outside the distance ceiling and the ring
	samples kept landing on geometry. The relaxation ladder in SpawnPlacement
	stopped that being a dead round, but it treated the symptom: the Director
	still did not KNOW anywhere else to go.

	This is the map itself, learned at runtime, so "anywhere" is a real answer.

	── TWO SOURCES, BOTH CHEAP ─────────────────────────────────────────────────
	  * BREADCRUMBS. Where survivors have actually been. Free, and valid by
	    construction — a player is standing there, so a body fits there. It
	    covers the route the level really has rather than the one its geometry
	    suggests, including the parts a sweep would have to be lucky to find.

	  * A SWEEP. A grid over the map's bounding box, tested a few cells at a
	    time. This is what finds the rooms nobody has walked into yet, which is
	    most of what "spawn anywhere" means — a horde coming out of a building
	    the team is about to reach rather than out of the corridor behind them.

	Both are deduplicated into the same grid, so a cell learned either way is
	stored once and the two cannot fight.

	── WHY IT IS INCREMENTAL AND NOT BUILT UP FRONT ────────────────────────────
	A full sweep of a large map is thousands of raycasts plus a volume query
	each. Doing that at round start is a visible hitch at the exact moment the
	round begins; doing it in a coroutine is the same work with the hitch spread
	somewhere unpredictable. A budget per Director tick costs a bounded slice of
	one frame in eight, finishes in well under a minute, and is useful from the
	first cell — the field is sampled from whatever it has learned so far.

	── WHAT IT IS NOT ──────────────────────────────────────────────────────────
	Not a navmesh. It knows where a body FITS, not where a body can WALK TO. A
	sealed courtyard is somewhere a body fits and this will offer it. That is
	deliberately SpawnPlacement's problem — flow, distance and line of sight are
	the rules that decide whether a legal-looking point is a good one, and they
	already exist. This only widens what they get to choose from.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PathfindingService = game:GetService("PathfindingService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local DirectorConfig = require(Shared.Config.DirectorConfig)
local Registry = require(Shared.Util.Registry)

local SpawnVolume = require(script.Parent.SpawnVolume)

local FIELD = DirectorConfig.Field

--[[ The body the reachability check pretends to be. Generous on radius and mean
     on height: a path that only fits a slim agent is one a Charger will scrape
     along a wall, and a doorway a Tank cannot fit through is not this module's
     problem — the Director re-tests the real body's box at placement time. ]]
local AGENT_RADIUS = 2.5
local AGENT_HEIGHT = 5

local SpawnField = {}

--[[ Points, keyed by grid cell so the same spot cannot be stored twice however
     it was learned. The value is the point's index in `list`, which is the same
     set in an array because sampling wants an index and a hash map has none —
     and because `condemn` has to be able to pull one point back out without
     walking the whole array. ]]
local cells: { [string]: number } = {}
local list: { Vector3 } = {}

--[[ Cells a body was placed in and could never get out of. See `condemn`. Kept
     separate from `cells` so the sweep cannot re-learn one, and so a breadcrumb
     — which is proof a player walked there — can clear it. ]]
local condemned: { [string]: boolean } = {}

--[[
	Probed cells that have not yet PROVED a body can walk out of them.

	The sweep's own test is SpawnVolume, and SpawnVolume's header is explicit
	that it answers "does a body fit here" and deliberately not "can a body walk
	away from here". Nothing else answered the second question either, and the
	consequence is exactly what a downward ray produces on a real map: the top of
	a wall, the roof of a shed, a shipping container, the inside of a sealed
	courtyard. Every one of those is flat ground with clear headroom, so every
	one of them passed and went straight into the pool the Director samples from
	— and sixty per cent of spawn attempts draw from that pool first.

	So a probed cell is a CANDIDATE now. It waits here until PathfindingService
	says a body could actually walk from it to a survivor, and only then does it
	become somewhere the Director may use. One path per cell for the lifetime of
	the map: expensive per call, negligible amortised, and it is the difference
	between a horde arriving and a horde standing on a roof.

	Breadcrumbs never come through here — see `remember`. A survivor standing
	somewhere is better proof than any query.
]]
local pending: { Vector3 } = {}
local checking = false

local origin: Vector3? = nil
local spanX, spanZ = 0, 0
local cursor = 0
local cellCount = 0
local swept = false

local ignore: { Instance } = {}
local ignoreAt = -math.huge

--[[ One RaycastParams for the whole sweep, for the same reason RaycastUtil keeps
     one for line of sight: this is the hottest cast the server owns while a map
     is being learned, and RaycastUtil.excluding allocates a fresh params object
     every call. At a dozen cells on each of eight ticks a second that is a
     hundred throwaway objects a second feeding the collector for no reason.

     Safe because Luau is single-threaded and nothing between the filter
     assignment in probe() and the cast on the next line yields. ]]
local dropParams = RaycastParams.new()
dropParams.FilterType = Enum.RaycastFilterType.Exclude
dropParams.IgnoreWater = true
dropParams.RespectCanCollide = false

local function key(position: Vector3): string
	local size = FIELD.CellSize
	return string.format(
		"%d:%d:%d",
		math.floor(position.X / size),
		--[[ Y is part of the key at a COARSER grain. Two floors of a stairwell
		     are different places and must both be learnable, but a body standing
		     on a kerb is not a different place from one beside it. ]]
		math.floor(position.Y / FIELD.FloorHeight),
		math.floor(position.Z / size)
	)
end

--[[ Puts a point into the usable pool. Only ever called for something already
     known to be reachable: a breadcrumb, or a candidate the path check passed. ]]
local function store(position: Vector3): boolean
	local id = key(position)
	if cells[id] or condemned[id] then
		return false
	end
	table.insert(list, position)
	cells[id] = #list
	return true
end

--[[ Queues a probed point for the reachability check. Deduplicated against the
     same three sets `store` is, so a cell already known, already condemned, or
     already waiting is not queued twice. ]]
local function offer(position: Vector3): boolean
	local id = key(position)
	if cells[id] or condemned[id] then
		return false
	end
	for _, queued in pending do
		if key(queued) == id then
			return false
		end
	end
	table.insert(pending, position)
	return true
end

--[[ Rebuilt on a timer rather than per query. The contents change as bodies
     spawn and die, and rebuilding it for every one of a sweep's cells would be
     the most expensive thing here by a wide margin. ]]
local function refreshIgnore()
	local now = os.clock()
	if now - ignoreAt < FIELD.IgnoreRefresh then
		return
	end
	ignoreAt = now
	table.clear(ignore)
	for _, name in { "Infected", "FL_Gore", "FL_Impacts" } do
		local folder = Workspace:FindFirstChild(name)
		if folder then
			table.insert(ignore, folder)
		end
	end
	local players = game:GetService("Players")
	for _, player in players:GetPlayers() do
		if player.Character then
			table.insert(ignore, player.Character)
		end
	end
end

--[[ The map's own bounding box, once. Returns false while there is no map,
     which is every tick before the first one loads. ]]
local function resolveBounds(): boolean
	if origin then
		return true
	end
	local maps = Registry.find("MapService")
	local root = if maps and typeof(maps.getCurrentRoot) == "function" then maps:getCurrentRoot() else nil
	if not root then
		return false
	end
	local ok, boxCFrame, size = pcall(function()
		return (root :: Model):GetBoundingBox()
	end)
	if not ok or not boxCFrame or not size or size.Magnitude < 1 then
		return false
	end

	local centre = boxCFrame.Position
	local half = size * 0.5
	origin = Vector3.new(centre.X - half.X, centre.Y + half.Y + FIELD.SkyMargin, centre.Z - half.Z)
	spanX = math.max(math.ceil(size.X / FIELD.CellSize), 1)
	spanZ = math.max(math.ceil(size.Z / FIELD.CellSize), 1)
	cellCount = spanX * spanZ
	--[[ The drop has to clear the map from above its highest point to below its
	     lowest, or the top storey is the only floor ever found. ]]
	SpawnField._dropLength = size.Y + FIELD.SkyMargin * 2
	return true
end

--[[ One cell. Drops a ray from above the map, and if it lands on ground a body
     could stand on, remembers it. ]]
local function probe(cellX: number, cellZ: number): boolean
	local start = origin
	if not start then
		return false
	end
	local size = FIELD.CellSize
	--[[ Centred in the cell rather than on its corner: a corner sits on the
	     boundary between two rooms as often as inside one. ]]
	local from = Vector3.new(start.X + (cellX + 0.5) * size, start.Y, start.Z + (cellZ + 0.5) * size)

	refreshIgnore()
	dropParams.FilterDescendantsInstances = ignore
	local hit = Workspace:Raycast(from, Vector3.new(0, -SpawnField._dropLength, 0), dropParams)
	if not hit then
		return false
	end
	if hit.Normal.Y < FIELD.MinGroundNormalY then
		return false
	end
	if not SpawnVolume.fits(hit.Position, SpawnVolume.largestSize(), ignore) then
		return false
	end
	return offer(hit.Position)
end

--[[
	Explores up to `budget` more cells.

	Called from the Director's tick, which runs at 8Hz — so a budget of a dozen
	is a hundred cells a second and a large map is mapped in well under a minute,
	with each tick paying for a bounded slice.
]]
function SpawnField.step(budget: number?)
	if swept or not resolveBounds() then
		return
	end
	local todo = math.max(budget or FIELD.SweepBudget, 1)
	for _ = 1, todo do
		if cursor >= cellCount then
			swept = true
			return
		end
		probe(cursor % spanX, math.floor(cursor / spanX))
		cursor += 1
	end
end

--[[
	Takes one waiting candidate and asks whether a body could walk out of it.

	PathfindingService is the only thing that actually knows. It is also slow and
	it YIELDS, which is why exactly one check is ever in flight and why this is
	spawned rather than awaited: the Director's tick must never wait on a
	navmesh query, and a tick that did would stall every brain in the round.

	The path is computed to a survivor, not to the level's centre or to a node,
	because "can a body reach the people" is the actual question. A roof with no
	way down fails it. A sealed courtyard fails it. A ledge you can drop off but
	not climb back onto passes, correctly — a body only has to get OUT.

	AgentCanJump is false on purpose. Roblox will happily path a jump a Humanoid
	being driven by MoveTo will not reliably make, and a spawn point that is only
	reachable via a jump the body fluffs is the same stuck zombie by a longer
	route.

	A failure condemns the cell rather than re-queueing it. The sweep will not
	re-learn a condemned cell, so each one costs exactly one path query for the
	life of the map — and a breadcrumb can still clear the verdict if a player
	later stands there, which outranks anything this concluded.
]]
local function walkableFrom(from: Vector3, to: Vector3): boolean
	local path = PathfindingService:CreatePath({
		AgentRadius = AGENT_RADIUS,
		AgentHeight = AGENT_HEIGHT,
		AgentCanJump = false,
	})
	local ok = pcall(path.ComputeAsync, path, from + Vector3.new(0, 2, 0), to)
	local success = ok and path.Status == Enum.PathStatus.Success
	path:Destroy()
	return success
end

--[[ One candidate per call, at most one in flight. Called from the Director's
     own tick alongside `step`, so exploring and validating advance together
     rather than the map being fully swept into a queue nothing drains. ]]
function SpawnField.validate(target: Vector3?)
	if checking or #pending == 0 or not target then
		return
	end
	checking = true

	--[[ Oldest first. The sweep explores outward from the map origin, so the
	     front of the queue is also the part of the map most likely to matter
	     first — and a queue drained from the back would leave the earliest cells
	     waiting the longest for no reason. ]]
	local candidate = table.remove(pending, 1) :: Vector3

	task.spawn(function()
		--[[ The whole body is wrapped, and `checking` is released whatever
		     happens. A throw anywhere in here — the path object, the status read,
		     a Destroy on something already gone — would otherwise leave the flag
		     set forever, and validation would stop dead with a full queue and no
		     error anyone would connect to it. ]]
		local ok, reachable = pcall(walkableFrom, candidate, target)
		if ok and reachable then
			store(candidate)
		elseif ok then
			--[[ Not a temporary failure worth retrying. Geometry does not move,
			     so a cell a body cannot walk out of now is one it could not walk
			     out of next minute either. ]]
			condemned[key(candidate)] = true
		end
		--[[ A THROW is different from a refusal, so the cell goes back to the
		     queue rather than being condemned on the strength of an error that
		     might have been about the pathfinder rather than the place. ]]
		if not ok then
			table.insert(pending, candidate)
		end
		checking = false
	end)
end

--[[ A survivor is standing here, so a body fits here. The cheapest and most
     trustworthy source there is, and the one that covers the route the level
     really has. ]]
function SpawnField.remember(position: Vector3)
	--[[ A player walked here, which outranks anything this module concluded on
	     its own — including a condemnation. If a body once got stuck in this cell
	     and a survivor has since stood in it, the cell is reachable and the
	     earlier verdict was about that body, not about this place. ]]
	condemned[key(position)] = nil
	--[[ Straight into the pool, with no path check. A player is standing here, so
	     a body can stand here and a body can walk away from here — that is better
	     proof than any query, and it is free. ]]
	store(position)
end

--[[
	Never offer this cell again.

	InfectedService fires `marooned` when a common has spent half a minute unable
	to get one stud closer to anybody, and passes `fromSpawn` when that body never
	closed ANY ground since it appeared. That second case is this module being
	wrong: it offered a point that fits a body and that a body cannot leave — a
	rooftop, a sealed courtyard, the far side of a fence — because it tests
	geometry and not reachability, which is exactly what its header says it does.

	One reap is enough evidence. The cost of dropping a good cell by accident is
	one fewer place a horde can come from out of hundreds; the cost of keeping a
	bad one is every body sent there being deleted half a minute later while the
	Director believes it delivered a horde.
]]
function SpawnField.condemn(position: Vector3)
	local id = key(position)
	condemned[id] = true

	local index = cells[id]
	if not index then
		return
	end
	cells[id] = nil

	--[[ Swap-remove, so this is O(1) rather than a shift of everything after it.
	     The moved point's own key has to be re-pointed at its new index or the
	     next condemn would delete the wrong element. ]]
	local last = #list
	if index ~= last then
		local moved = list[last]
		list[index] = moved
		cells[key(moved)] = index
	end
	list[last] = nil
end

--[[ Somewhere in the map, or nil while nothing has been learned yet. The caller
     decides whether the point is a GOOD one — see the header. ]]
function SpawnField.sample(random: Random): Vector3?
	local count = #list
	if count == 0 then
		return nil
	end
	return list[random:NextInteger(1, count)]
end

--[[ For the Director's own diagnostics, and for a test to assert against. ]]
function SpawnField.stats(): {
	known: number,
	explored: number,
	total: number,
	done: boolean,
	condemned: number,
	pending: number,
}
	local bad = 0
	for _ in condemned do
		bad += 1
	end
	return {
		known = #list,
		explored = cursor,
		total = cellCount,
		done = swept and #pending == 0,
		condemned = bad,
		pending = #pending,
	}
end

--[[ A new map is a new field. Nothing here survives a round change, and a point
     from the previous map is a point in empty space. ]]
function SpawnField.reset()
	table.clear(cells)
	table.clear(list)
	table.clear(pending)
	table.clear(condemned)
	checking = false
	origin = nil
	cursor = 0
	cellCount = 0
	swept = false
	ignoreAt = -math.huge
end

SpawnField._dropLength = 512

return SpawnField
