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
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local DirectorConfig = require(Shared.Config.DirectorConfig)
local RaycastUtil = require(Shared.Util.RaycastUtil)
local Registry = require(Shared.Util.Registry)

local SpawnVolume = require(script.Parent.SpawnVolume)

local FIELD = DirectorConfig.Field

local SpawnField = {}

--[[ Points, keyed by grid cell so the same spot cannot be stored twice however
     it was learned. `list` is the same set in an array, because sampling wants
     an index and a hash map has none. ]]
local cells: { [string]: boolean } = {}
local list: { Vector3 } = {}

local origin: Vector3? = nil
local spanX, spanZ = 0, 0
local cursor = 0
local cellCount = 0
local swept = false

local ignore: { Instance } = {}
local ignoreAt = -math.huge

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

local function store(position: Vector3): boolean
	local id = key(position)
	if cells[id] then
		return false
	end
	cells[id] = true
	table.insert(list, position)
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
	local hit =
		Workspace:Raycast(from, Vector3.new(0, -SpawnField._dropLength, 0), RaycastUtil.excluding(ignore))
	if not hit then
		return false
	end
	if hit.Normal.Y < FIELD.MinGroundNormalY then
		return false
	end
	if not SpawnVolume.fits(hit.Position, SpawnVolume.largestSize(), ignore) then
		return false
	end
	return store(hit.Position)
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

--[[ A survivor is standing here, so a body fits here. The cheapest and most
     trustworthy source there is, and the one that covers the route the level
     really has. ]]
function SpawnField.remember(position: Vector3)
	store(position)
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
function SpawnField.stats(): { known: number, explored: number, total: number, done: boolean }
	return { known = #list, explored = cursor, total = cellCount, done = swept }
end

--[[ A new map is a new field. Nothing here survives a round change, and a point
     from the previous map is a point in empty space. ]]
function SpawnField.reset()
	table.clear(cells)
	table.clear(list)
	origin = nil
	cursor = 0
	cellCount = 0
	swept = false
	ignoreAt = -math.huge
end

SpawnField._dropLength = 512

return SpawnField
