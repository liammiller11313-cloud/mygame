--[[
	TagMap — paste into the Roblox Studio COMMAND BAR and press Enter.

	Your maps are currently untagged, which means the whole level system is
	running on fallbacks: the Director cannot tell what is ahead of the team, so
	it spawns purely by distance from whoever it can see; items scatter instead of
	stocking the route; and survivors spawn in a ring at whatever the fallback
	decides rather than where you want a round to start.

	This works the tags out from the geometry itself. It rasterises the map's
	floor with downward rays, keeps the cells a person could actually stand in,
	finds the largest connected walkable region, and then measures the LONGEST
	route across it. That route is the level's spine — for a street map it lands
	on the street — and everything else is placed relative to it:

	    FL_FlowNode      a chain along that route, numbered with FL_Order
	    FL_SurvivorSpawn four spots at one end of it
	    FL_SpawnNode     walkable cells off to the sides, where a horde comes from
	    FL_ItemSpawn     walkable cells spread along it, offset from the middle

	Everything it creates goes in one folder called FL_Nodes inside the map, and
	re-running deletes the previous folder first — so it is safe to run twice,
	and deleting that one folder undoes it completely. It does not touch, move or
	modify a single part of your build.

	It is a starting point, not a level designer. Look at where the flow nodes
	landed and drag them; the numbers in FL_Order are what decides the order, not
	the positions, so moving one never breaks the chain.

	── HOW TO USE ──────────────────────────────────────────────────────────────
	Paste and press Enter. It does every map in ServerStorage.Maps (and any of
	them still sitting in Workspace). To do one map only, change MAP_FILTER
	below to its name, e.g. local MAP_FILTER = "Clinton".
]]

local MAP_FILTER = nil -- nil = every map; or a name like "Clinton"

--[[ Which end of the route the round starts at — where the survivor spawns go
     and where FL_Order 1 sits. The script cannot know which end of a street you
     meant to be the beginning, so it picks the corner nearest the world origin
     and prints both endpoints. If the team starts at the wrong end, set this to
     true and run it again. ]]
local REVERSE_ROUTE = false

local CollectionService = game:GetService("CollectionService")
local ServerStorage = game:GetService("ServerStorage")
local ChangeHistoryService = game:GetService("ChangeHistoryService")
local Workspace = game:GetService("Workspace")

-- ── tuning ──────────────────────────────────────────────────────────────────

-- Grid pitch in studs. Smaller finds narrower alleys and costs more rays; 6 is
-- about a doorway's width, which is the smallest gap worth pathing through.
local CELL = 6

-- Clear space needed above a floor point for it to count as standing room. A
-- character is 5 studs tall, so this also rejects the top of a low wall.
local HEADROOM = 7

-- The biggest height difference two neighbouring cells can have and still be
-- connected. About a staircase step; above this they are a wall or a ledge, and
-- the flood fill must not walk up the side of a building.
local STEP = 4

-- Rays start this far above the map's ceiling and run to this far below its
-- floor, so a map on a hill is covered end to end.
local RAY_PAD = 40

-- How many cells the grid may be on its longest side. A cap, not a target: a
-- huge map gets a coarser pitch rather than a hundred thousand raycasts.
local MAX_CELLS = 180

local FLOW_SPACING = 42 -- studs between flow nodes along the route
local FLOW_MIN = 4 -- refuse to write a spline shorter than this
local SURVIVOR_SPAWNS = 4
local SPAWN_NODES = 16 -- infected spawn points
local ITEM_SPAWNS = 18

-- An infected spawn node belongs off the route, but still in the same place.
local SPAWN_MIN_OFF_ROUTE = 22
local SPAWN_MAX_OFF_ROUTE = 110

-- Items sit near the route without being on top of it.
local ITEM_MIN_OFF_ROUTE = 6
local ITEM_MAX_OFF_ROUTE = 55

local NODE_FOLDER = "FL_Nodes"

-- ── helpers ─────────────────────────────────────────────────────────────────

local function collectMaps()
	local found = {}
	local storage = ServerStorage:FindFirstChild("Maps")
	if storage then
		for _, child in storage:GetChildren() do
			if child:IsA("Model") then
				table.insert(found, child)
			end
		end
	end
	--[[ Only fall back to Workspace if the storage folder is not set up yet.
	     Tagging both a map in storage AND a stale copy of it in the world would
	     print the same name twice and tag a model that gets destroyed the next
	     time a round loads. Run OrganizeAssets first and this branch never
	     applies. ]]
	if #found == 0 then
		for _, child in Workspace:GetChildren() do
			if child:IsA("Model") and (child.Name == "Zombieville" or child.Name == "Clinton") then
				table.insert(found, child)
			end
		end
	end
	if MAP_FILTER then
		local filtered = {}
		for _, model in found do
			if model.Name == MAP_FILTER then
				table.insert(filtered, model)
			end
		end
		return filtered
	end
	return found
end

local function newNode(name: string, position: Vector3, parent: Instance, tag: string): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = Vector3.new(2, 2, 2)
	part.Position = position
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = 1
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	CollectionService:AddTag(part, tag)
	return part
end

-- ── the walkable grid ───────────────────────────────────────────────────────

--[[
	Casts one ray down per cell and keeps the ones with standing room.

	The filter is the map model itself, so nothing outside it — the baseplate,
	another map, the nodes from a previous run — can register as floor. The
	second ray is the headroom test: a floor point with a ceiling three studs
	over it is the underside of a staircase, not somewhere to stand.
]]
local function buildGrid(model: Model)
	local cframe, size = model:GetBoundingBox()
	local centre = cframe.Position
	local half = size * 0.5

	local minX, maxX = centre.X - half.X, centre.X + half.X
	local minZ, maxZ = centre.Z - half.Z, centre.Z + half.Z
	local top = centre.Y + half.Y + RAY_PAD
	local reach = size.Y + RAY_PAD * 2

	-- Widen the pitch rather than the ray budget on a very large map.
	local pitch = CELL
	local spanX, spanZ = maxX - minX, maxZ - minZ
	local longest = math.max(spanX, spanZ)
	if longest / pitch > MAX_CELLS then
		pitch = longest / MAX_CELLS
	end

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { model }
	params.IgnoreWater = true

	local columns = math.max(math.floor(spanX / pitch), 1)
	local rows = math.max(math.floor(spanZ / pitch), 1)

	local cells = {} -- key "x,z" -> { x, z, position }
	local rays = 0

	for ix = 0, columns do
		for iz = 0, rows do
			local x = minX + ix * pitch
			local z = minZ + iz * pitch
			rays += 1
			local hit = Workspace:Raycast(Vector3.new(x, top, z), Vector3.new(0, -reach, 0), params)
			if hit then
				local above = Workspace:Raycast(
					hit.Position + Vector3.new(0, 0.5, 0),
					Vector3.new(0, HEADROOM, 0),
					params
				)
				if not above then
					cells[ix .. "," .. iz] = { ix = ix, iz = iz, position = hit.Position }
				end
			end
		end
	end

	return { cells = cells, pitch = pitch, columns = columns, rows = rows, rays = rays }
end

local NEIGHBOURS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }

local function neighboursOf(grid, cell)
	local out = {}
	for _, offset in NEIGHBOURS do
		local other = grid.cells[(cell.ix + offset[1]) .. "," .. (cell.iz + offset[2])]
		if other and math.abs(other.position.Y - cell.position.Y) <= STEP then
			table.insert(out, other)
		end
	end
	return out
end

--[[ Breadth-first from one cell. Returns the visited set, the cell furthest
     from the start, and the parent map needed to walk a path back. ]]
local function flood(grid, start)
	local seen = { [start] = true }
	local parent = {}
	local queue = { start }
	local head = 1
	local last = start

	while head <= #queue do
		local cell = queue[head]
		head += 1
		last = cell
		for _, other in neighboursOf(grid, cell) do
			if not seen[other] then
				seen[other] = true
				parent[other] = cell
				table.insert(queue, other)
			end
		end
	end

	return seen, last, parent
end

--[[
	The longest route across the walkable space.

	Two floods: one from anywhere to find a genuine extremity, then one from that
	extremity to find the far end. It is the standard way to measure the long
	axis of a connected space, and on a street map it lands on the street rather
	than cutting through the buildings, because the buildings were never walkable
	cells to begin with.
]]
local function longestRoute(grid)
	-- Start from the largest connected region, not from an arbitrary cell: a map
	-- with a rooftop or a sealed interior has more than one, and the biggest is
	-- always the one the round is played in.
	local unvisited = {}
	for _, cell in grid.cells do
		unvisited[cell] = true
	end

	local best, bestSize = nil, 0
	while next(unvisited) do
		local seed = next(unvisited)
		local region = flood(grid, seed)
		local size = 0
		for cell in region do
			size += 1
			unvisited[cell] = nil
		end
		if size > bestSize then
			best, bestSize = seed, size
		end
	end
	if not best then
		return nil, 0
	end

	local _, farA = flood(grid, best)
	local _, farB, parent = flood(grid, farA)

	local path = {}
	local node = farB
	while node do
		table.insert(path, 1, node)
		node = parent[node]
	end

	--[[ Which end is the START is not something the geometry can answer, and
	     leaving it to whichever extremity the flood reached first would move the
	     team's spawn to the other side of the map on an unrelated edit. So it is
	     pinned to something stable: the end nearer the world origin. Wrong half
	     the time by construction, which is what REVERSE_ROUTE is for — but wrong
	     the SAME way every run, which is the part that matters. ]]
	local head, tail = path[1].position, path[#path].position
	local flip = (head.X + head.Z) > (tail.X + tail.Z)
	if REVERSE_ROUTE then
		flip = not flip
	end
	if flip then
		local reversed = {}
		for index = #path, 1, -1 do
			table.insert(reversed, path[index])
		end
		path = reversed
	end

	return path, bestSize
end

--[[ Thins a cell-by-cell path down to nodes roughly SPACING apart, always
     keeping both ends. Walking distance, not straight-line: a route that doubles
     back around a block should get nodes on both legs. ]]
local function thin(path, spacing)
	local out = { path[1] }
	local travelled = 0
	for index = 2, #path do
		travelled += (path[index].position - path[index - 1].position).Magnitude
		if travelled >= spacing then
			travelled = 0
			table.insert(out, path[index])
		end
	end
	if out[#out] ~= path[#path] then
		table.insert(out, path[#path])
	end
	return out
end

-- Distance from a point to the nearest node on the route.
local function distanceToRoute(position: Vector3, route): number
	local best = math.huge
	for _, cell in route do
		local d = (cell.position - position).Magnitude
		if d < best then
			best = d
		end
	end
	return best
end

--[[ Picks `count` cells that pass `accept`, spread out rather than clustered:
     each pick has to be at least `apart` studs from every pick before it. Falls
     back to relaxing that distance rather than returning too few. ]]
local function spread(candidates, count, apart)
	local chosen = {}
	local gap = apart

	while #chosen < count and gap > 4 do
		for _, cell in candidates do
			if #chosen >= count then
				break
			end
			local ok = true
			for _, taken in chosen do
				if (taken.position - cell.position).Magnitude < gap then
					ok = false
					break
				end
			end
			if ok then
				table.insert(chosen, cell)
			end
		end
		gap *= 0.6
	end

	return chosen
end

-- ── per map ─────────────────────────────────────────────────────────────────

local function tagMap(model: Model)
	print(
		string.format(
			"\n── %s ──────────────────────────────",
			model.Name
		)
	)

	local existing = model:FindFirstChild(NODE_FOLDER)
	if existing then
		existing:Destroy()
		print("  removed the previous " .. NODE_FOLDER .. " folder")
	end

	--[[ Raycasts only see Workspace, so a map in ServerStorage is brought into
	     the world for the duration and put back afterwards. Wrapped so an error
	     halfway through cannot leave it stranded in Workspace. ]]
	local originalParent = model.Parent
	local moved = not model:IsDescendantOf(Workspace)
	if moved then
		model.Parent = Workspace
	end

	local ok, err = pcall(function()
		local grid = buildGrid(model)
		local walkable = 0
		for _ in grid.cells do
			walkable += 1
		end
		print(
			string.format(
				"  %d rays at %.1f-stud pitch, %d walkable cell(s)",
				grid.rays,
				grid.pitch,
				walkable
			)
		)

		if walkable < FLOW_MIN * 4 then
			warn(
				string.format(
					"  [%s] only %d walkable cells — the map may be mostly sealed, or its parts may be "
						.. "CanCollide off. Nothing tagged.",
					model.Name,
					walkable
				)
			)
			return
		end

		local path, regionSize = longestRoute(grid)
		if not path or #path < FLOW_MIN then
			warn(string.format("  [%s] could not find a route across the map. Nothing tagged.", model.Name))
			return
		end

		local route = thin(path, FLOW_SPACING)
		local routeLength = 0
		for index = 2, #route do
			routeLength += (route[index].position - route[index - 1].position).Magnitude
		end

		local folder = Instance.new("Folder")
		folder.Name = NODE_FOLDER
		folder.Parent = model

		-- ── flow ──────────────────────────────────────────────────────────
		local flowFolder = Instance.new("Folder")
		flowFolder.Name = "Flow"
		flowFolder.Parent = folder
		for index, cell in route do
			local node = newNode(
				string.format("Flow%02d", index),
				cell.position + Vector3.new(0, 3, 0),
				flowFolder,
				"FL_FlowNode"
			)
			node:SetAttribute("FL_Order", index)
		end

		-- ── survivor spawns, at the start of the route ────────────────────
		local start = route[1].position
		local nearStart = {}
		for _, cell in grid.cells do
			local d = (cell.position - start).Magnitude
			if d <= 26 then
				table.insert(nearStart, cell)
			end
		end
		table.sort(nearStart, function(a, b)
			return (a.position - start).Magnitude < (b.position - start).Magnitude
		end)

		local spawnFolder = Instance.new("Folder")
		spawnFolder.Name = "SurvivorSpawns"
		spawnFolder.Parent = folder
		local survivorCells = spread(nearStart, SURVIVOR_SPAWNS, 7)
		for index, cell in survivorCells do
			newNode(
				string.format("SurvivorSpawn%d", index),
				cell.position + Vector3.new(0, 3, 0),
				spawnFolder,
				"FL_SurvivorSpawn"
			):SetAttribute("FL_Order", index)
		end

		-- ── infected spawn nodes, off the route ───────────────────────────
		local offRoute = {}
		local nearRoute = {}
		for _, cell in grid.cells do
			local d = distanceToRoute(cell.position, route)
			if d >= SPAWN_MIN_OFF_ROUTE and d <= SPAWN_MAX_OFF_ROUTE then
				table.insert(offRoute, cell)
			end
			if d >= ITEM_MIN_OFF_ROUTE and d <= ITEM_MAX_OFF_ROUTE then
				table.insert(nearRoute, cell)
			end
		end

		local hordeFolder = Instance.new("Folder")
		hordeFolder.Name = "InfectedSpawns"
		hordeFolder.Parent = folder
		local hordeCells = spread(offRoute, SPAWN_NODES, 40)
		for index, cell in hordeCells do
			newNode(
				string.format("SpawnNode%02d", index),
				cell.position + Vector3.new(0, 3, 0),
				hordeFolder,
				"FL_SpawnNode"
			)
		end

		-- ── item spawns, spread along the route ───────────────────────────
		local itemFolder = Instance.new("Folder")
		itemFolder.Name = "ItemSpawns"
		itemFolder.Parent = folder
		local itemCells = spread(nearRoute, ITEM_SPAWNS, 34)
		for index, cell in itemCells do
			--[[ Flush with the floor, unlike the other node kinds. ItemPlacer
			     puts the pickup on the pad's TOP surface so that a medkit on a
			     shelf sits on the shelf, which means a pad floating three studs
			     up floats the medkit with it. ]]
			newNode(string.format("ItemSpawn%02d", index), cell.position, itemFolder, "FL_ItemSpawn")
		end

		local finish = route[#route].position
		print(
			string.format(
				"  region %d cells · route %.0f studs\n"
					.. "  tagged  %d flow · %d survivor spawn · %d infected spawn · %d item spawn\n"
					.. "  starts at (%.0f, %.0f, %.0f) and ends at (%.0f, %.0f, %.0f)\n"
					.. "  — if the team should start at the OTHER end, set REVERSE_ROUTE = true and re-run",
				regionSize,
				routeLength,
				#route,
				#survivorCells,
				#hordeCells,
				#itemCells,
				start.X,
				start.Y,
				start.Z,
				finish.X,
				finish.Y,
				finish.Z
			)
		)

		if #survivorCells < SURVIVOR_SPAWNS then
			warn(
				string.format(
					"  [%s] only %d survivor spawn(s) fitted at the start of the route. Drag a few more "
						.. "into %s/SurvivorSpawns if the team starts on top of each other.",
					model.Name,
					#survivorCells,
					NODE_FOLDER
				)
			)
		end
		if #hordeCells < 6 then
			warn(
				string.format(
					"  [%s] only %d infected spawn node(s). The Director will fall back to sampling "
						.. "around the survivors, which works but ignores your alleys.",
					model.Name,
					#hordeCells
				)
			)
		end
	end)

	if moved then
		model.Parent = originalParent
	end
	if not ok then
		warn(string.format("  [%s] failed: %s", model.Name, tostring(err)))
	end
end

-- ── run ─────────────────────────────────────────────────────────────────────

local maps = collectMaps()
if #maps == 0 then
	warn(
		"[TagMap] no maps found. Expected model(s) in ServerStorage.Maps "
			.. "(or a Zombieville / Clinton model in Workspace). Run OrganizeAssets first."
	)
	return
end

ChangeHistoryService:SetWaypoint("TagMap: before")
print(string.rep("=", 68))
print(string.format("[TagMap] %d map(s)", #maps))
for _, model in maps do
	tagMap(model)
end
print("\n" .. string.rep("=", 68))
print("[TagMap] done. Everything created is in the FL_Nodes folder inside each map;")
print("delete that folder to undo, or re-run this to rebuild it.")
print("The nodes are invisible and non-collidable — turn on transparency in the")
print("Explorer's property view, or just select the folder, to see where they went.")
print(string.rep("=", 68))
ChangeHistoryService:SetWaypoint("TagMap: after")
