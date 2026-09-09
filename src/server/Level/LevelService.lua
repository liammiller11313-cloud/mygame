--!nonstrict
--[[
	LevelService — everything the game knows about the shape of the map.

	── THE POINT OF THIS MODULE ─────────────────────────────────────────────────
	Not one coordinate in this file. Every single thing the level does is
	discovered from CollectionService tags and Instance attributes, so a
	hand-built map — the user's own "Zombieville", or anything else dragged into
	Workspace — drops in and works with ZERO code changes. Build a level that
	carries these tags and this service will run it:

	    FL_FlowNode       a point on the level spline; ordered by its FL_Order
	                      attribute (any numbers, they only have to sort)
	    FL_SurvivorSpawn  where survivors start the round; its rotation is the
	                      direction they face. More than one is a fine idea —
	                      they are handed out round-robin
	    FL_SpawnNode      a legal infected spawn point
	    FL_ItemSpawn      a pickup pad; optional FL_Slot attribute forces its type
	    FL_PanicTrigger   a volume; walking into it starts a crescendo, once
	    FL_BossZone       an arena a Tank or a Witch may be placed in

	There are no safe rooms and no chapters. A round is fifteen waves on a fixed
	clock and RoundService owns that clock; this module owns geometry, and the two
	never write the same attribute.

	── FLOW DISTANCE ────────────────────────────────────────────────────────────
	The flow nodes form a polyline, and `getFlowDistance` projects a point onto it
	and returns the arc length to that projection. That number is the backbone of
	the Director: what counts as "ahead of the team", whether a spawn point is in
	front of the survivors or behind them, and which boss zone is the next one.
	It is a scalar for a 3D world, and it is the reason a directed map feels
	directed rather than random.

	── WHEN THE MAP IS NOT TAGGED YET ───────────────────────────────────────────
	Every discovery in here degrades to something playable and says so LOUDLY,
	once, naming the tag that is missing and what it does. A map with no flow
	nodes still spawns survivors and still runs a round; it just cannot tell the
	Director which way is forward. Silence would be the actual failure: it is why
	an untagged map used to drop everybody at the world origin.

	Tags are watched, not sampled: a map that streams in, or an author adding a
	node in Studio during a playtest, invalidates the cache and it rebuilds on the
	next question.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local AudioConfig = require(Shared.Config.AudioConfig)
local Attributes = require(Shared.Net.Attributes)
local DirectorConfig = require(Shared.Config.DirectorConfig)
local Enums = require(Shared.Enums)
local GameConfig = require(Shared.Config.GameConfig)
local RaycastUtil = require(Shared.Util.RaycastUtil)
local MapConfig = require(Shared.Config.MapConfig)
local Registry = require(Shared.Util.Registry)
local Remotes = require(Shared.Net.Remotes)
local Trove = require(Shared.Util.Trove)

local TAG_FLOW = "FL_FlowNode"
local TAG_SPAWN = "FL_SpawnNode"
local TAG_ITEM = "FL_ItemSpawn"
local TAG_PANIC = "FL_PanicTrigger"
local TAG_BOSS = "FL_BossZone"
local TAG_SURVIVOR_SPAWN = "FL_SurvivorSpawn"

local ATTR_ORDER = "FL_Order"

--[[ 5Hz. The only spatial question left in this module is whether one of four
     characters has walked into a panic volume, and that cannot change
     meaningfully inside 200ms. ]]
local TICK_INTERVAL = 0.2

--[[ getSurvivorFlow is asked for by the Director, by SpawnPlacement and by this
     module's own tick, several times per second each, and the answer cannot
     change much in a tenth of a second at survivor walking speed. ]]
local FLOW_CACHE_TIME = 0.1

--[[ Items are stocked this far ahead of the team. Borrowed from the Director's
     own spawn window on purpose: it is already the distance at which the game
     considers something "coming up", so items and infected agree about where the
     front of the level is. ]]
local POPULATE_LOOKAHEAD = DirectorConfig.Spawning.MaxFlowAhead

--[[ A character's root part sits about this far above the floor on both R6 and
     R15 rigs. Spawning at the floor point itself drops half a survivor through
     it and lets Roblox resolve the overlap, which it does by launching them. ]]
--[[ How far above the ground a survivor's root is placed. A HumanoidRootPart
     already sits about three studs up, so this is clearance ON TOP of that: a
     ground ray that lands on a thin ledge or a sloped mesh can be off by a stud
     or so, and spawning even slightly inside geometry is what the solver
     resolves by flinging the body out of it. ]]
local SPAWN_ROOT_HEIGHT = 6

--[[ How far apart survivors stand in a fallback spawn ring. Wide enough that
     four characters do not resolve their collisions by shoving each other off a
     ledge, tight enough that the team starts as a team. ]]
local SPAWN_RING_RADIUS = 6

--[[ How far up and down a spawn point looks for a floor. Generous because the
     anchor may be a flow node hanging in the air over a stairwell. ]]
local GROUND_SEARCH = 120

-- Objective copy for the panic window. Strings, not tuning — no config owns copy.
local TEXT_PANIC = "Survive the horde"

local LevelService = {}

local serviceTrove = Trove.new()

-- ── flow spline ─────────────────────────────────────────────────────────────
local flowPoints: { Vector3 } = {}
local flowStart: { number } = {} -- arc length at the start of segment i
local flowSegment: { number } = {} -- length of segment i
local flowTotal = 0
local flowDirty = true

local cachedSurvivorFlow = 0
local cachedSurvivorFlowAt = -math.huge

-- ── tagged instances ────────────────────────────────────────────────────────
local spawnNodes: { BasePart } = {}
local spawnDirty = true

local bossZones: { BasePart } = {}
local bossDirty = true

local survivorSpawns: { BasePart } = {}
local survivorSpawnDirty = true

local panicTriggers: { [BasePart]: boolean } = {} -- part -> already fired
local panicDirty = true

local sections: { any } = {}
local sectionsDirty = true

-- ── objective ───────────────────────────────────────────────────────────────
local objectiveText = ""
local accumulator = 0

local warned: { [string]: boolean } = {}
local function warnOnce(key: string, message: string)
	if warned[key] then
		return
	end
	warned[key] = true
	warn("[LevelService] " .. message)
end

-- ════════════════════════════════════════════════════════════════════════════
--  Tag caches
-- ════════════════════════════════════════════════════════════════════════════

local function taggedParts(tag: string): { BasePart }
	local parts = {}
	for _, instance in CollectionService:GetTagged(tag) do
		if instance:IsA("BasePart") and instance:IsDescendantOf(Workspace) then
			table.insert(parts, instance)
		end
	end
	return parts
end

--[[ A stable order for anything a level author might reasonably expect to be
     ordered: FL_Order if it has one, then name. Without it the round-robin of
     survivor spawns changes every time the map reloads. ]]
local function sortTagged(parts: { BasePart })
	table.sort(parts, function(a, b)
		local left = tonumber(a:GetAttribute(ATTR_ORDER)) or math.huge
		local right = tonumber(b:GetAttribute(ATTR_ORDER)) or math.huge
		if left == right then
			return a.Name < b.Name
		end
		return left < right
	end)
end

--[[
	Rebuilds the polyline from FL_FlowNode parts, ordered by FL_Order.

	A node with no FL_Order sorts to the end rather than being dropped: a half
	tagged map should still produce a usable spline, because "the Director stopped
	working" is a far worse failure than "one node is in the wrong place".
]]
local function rebuildFlow()
	flowDirty = false
	table.clear(flowPoints)
	table.clear(flowStart)
	table.clear(flowSegment)
	flowTotal = 0

	local nodes = taggedParts(TAG_FLOW)
	sortTagged(nodes)

	for _, node in nodes do
		table.insert(flowPoints, node.Position)
	end

	for index = 1, #flowPoints - 1 do
		local length = (flowPoints[index + 1] - flowPoints[index]).Magnitude
		flowStart[index] = flowTotal
		flowSegment[index] = length
		flowTotal += length
	end

	if #flowPoints < 2 then
		warnOnce(
			"noflow",
			string.format(
				"the map has %d %s part(s). Tag a chain of parts with %s and give each an %s "
					.. "attribute (1, 2, 3 …) to define the level spline. Until then flow distance is 0 "
					.. "everywhere: the Director cannot tell what is ahead of the team, so spawns fall "
					.. "back to distance-from-survivor only and boss zones are picked at random.",
				#flowPoints,
				TAG_FLOW,
				TAG_FLOW,
				ATTR_ORDER
			)
		)
	end
end

--[[
	Spawn candidates borrowed from the map's own item spots.

	A map with no FL_SpawnNode parts is the normal case rather than the excep-
	tion — tagging is deliberate work in Studio, and every map in this build has
	had none. The Director still works: SpawnPlacement falls back to sampling a
	ring around the survivors, which is honest and which its own warning
	describes as "works but ignores your doorways and alleys". It is the weaker
	half of the feature, and every map was running on it.

	The item folders are a free answer to that. MapItemService already places
	medkits, pills and throwables all over a level, and a designer put every one
	of those where a thing can sit on the floor — which is the same question a
	spawn node answers. Forty-odd points, spread through the map, on walkable
	ground, at no cost to anybody.

	── THEY ARE CANDIDATES, NOT PERMISSION ─────────────────────────────────────
	Nothing here bypasses a rule. Every point still goes through SpawnPlacement's
	whole filter — the distance band, the flow window, the camera cone AND the
	line-of-sight ray, the ground test and the volume test — so a borrowed node
	in a bad place is rejected exactly like a tagged one in a bad place. The only
	thing this changes is that the Director has somewhere in the LEVEL to try
	before it falls back to sampling around the team.

	Tagged nodes still win outright when a map has them: this runs only when
	there are none, and the warning still asks for them, because a person who
	knows which alley the horde should come out of will always beat a heuristic.
]]
local function borrowedSpawnNodes(): { BasePart }
	local out: { BasePart } = {}
	local mapService = Registry.find("MapService")
	local root = mapService
		and typeof(mapService.getCurrentRoot) == "function"
		and mapService:getCurrentRoot()
	if typeof(root) ~= "Instance" then
		return out
	end

	for _, family in MapConfig.MapItems do
		local folder: Instance? = nil
		for _, child in root:GetChildren() do
			if
				(child:IsA("Folder") or child:IsA("Model"))
				and MapConfig.folderMatches(child.Name, family.folderName)
			then
				folder = child
				break
			end
		end
		if folder then
			for _, child in folder:GetChildren() do
				--[[ The part a body would stand next to. A lone Part answers for
				     itself; a Model answers with whatever it is built around,
				     which is close enough — a spawn point is a place, and every
				     rule that matters is applied to it afterwards. ]]
				local part: BasePart? = if child:IsA("BasePart")
					then child
					elseif child:IsA("Model") then (child.PrimaryPart or child:FindFirstChildWhichIsA(
						"BasePart",
						true
					))
					else nil
				if part then
					table.insert(out, part)
				end
			end
		end
	end

	return out
end

local function rebuildSpawnNodes()
	spawnDirty = false
	spawnNodes = taggedParts(TAG_SPAWN)
	if #spawnNodes == 0 then
		spawnNodes = borrowedSpawnNodes()
	end
	if #spawnNodes == 0 then
		warnOnce(
			"nospawnnodes",
			string.format(
				"no %s parts in the map and no item folders to borrow from. Infected placement falls "
					.. "back to sampling the space around the survivors, which works but ignores your "
					.. "doorways and alleys — tag a few parts out of sight of the play space to "
					.. "control where the horde comes from.",
				TAG_SPAWN
			)
		)
	end
end

local function rebuildBossZones()
	bossDirty = false
	bossZones = taggedParts(TAG_BOSS)
	sortTagged(bossZones)
end

local function rebuildSurvivorSpawns()
	survivorSpawnDirty = false
	survivorSpawns = taggedParts(TAG_SURVIVOR_SPAWN)
	sortTagged(survivorSpawns)
end

local function rebuildPanicTriggers()
	panicDirty = false
	local seen: { [BasePart]: boolean } = {}
	for _, part in taggedParts(TAG_PANIC) do
		seen[part] = true
		if panicTriggers[part] == nil then
			panicTriggers[part] = false
		end
	end
	for part in panicTriggers do
		if not seen[part] then
			panicTriggers[part] = nil
		end
	end
end

--[[
	Groups FL_ItemSpawn pads into the containers a level designer already put them
	in — each pad's own ancestor that is a direct child of the map root — and
	records the flow distance of each group.

	ItemPlacer's populateSection wants "the part of the map the team is fighting
	in", and this derives that from the tags already in the map rather than
	demanding yet another tag. A map that is one flat folder of pads degrades to a
	single section, which stocks as a whole and is still perfectly playable.
]]
local function sectionContainerFor(pad: Instance): Instance?
	if not pad:IsDescendantOf(Workspace) then
		return nil
	end
	local root: Instance = pad
	while root.Parent and root.Parent ~= Workspace do
		root = root.Parent
	end
	if root == pad then
		return pad
	end
	local child: Instance = pad
	while child.Parent and child.Parent ~= root do
		child = child.Parent
	end
	return child
end

local function rebuildSections()
	sectionsDirty = false
	table.clear(sections)

	local byContainer: { [Instance]: { total: number, count: number } } = {}
	for _, pad in taggedParts(TAG_ITEM) do
		local container = sectionContainerFor(pad)
		if not container then
			continue
		end
		local entry = byContainer[container]
		if not entry then
			entry = { total = 0, count = 0 }
			byContainer[container] = entry
		end
		entry.total += LevelService:getFlowDistance(pad.Position)
		entry.count += 1
	end

	for container, entry in byContainer do
		table.insert(sections, {
			container = container,
			flow = entry.total / math.max(entry.count, 1),
		})
	end
	table.sort(sections, function(a, b)
		return a.flow < b.flow
	end)

	if #sections == 0 then
		warnOnce(
			"noitems",
			string.format(
				"no %s parts in the map, so no pills, medkits, throwables or ammo will ever appear. "
					.. "Tag a few flat surfaces (shelves, crates, counters) with %s; an optional FL_Slot "
					.. "attribute forces what a pad holds.",
				TAG_ITEM,
				TAG_ITEM
			)
		)
	end
end

-- ════════════════════════════════════════════════════════════════════════════
--  Flow
-- ════════════════════════════════════════════════════════════════════════════

--[[
	Arc length along the level spline of the closest point on it to `position`.

	Degenerate maps answer 0 rather than erroring: no nodes, one node, or two
	nodes in the same place are all things a half-built level does, and the
	Director asking a question the level cannot answer must never take a spawn
	tick down with it.
]]
function LevelService:getFlowDistance(position: Vector3): number
	if flowDirty then
		rebuildFlow()
	end
	local count = #flowPoints
	if count < 2 or typeof(position) ~= "Vector3" then
		return 0
	end

	local bestOffset = math.huge
	local bestFlow = 0

	for index = 1, count - 1 do
		local origin = flowPoints[index]
		local segment = flowPoints[index + 1] - origin
		local lengthSquared = segment:Dot(segment)
		local alpha = 0
		if lengthSquared > 1e-6 then
			alpha = math.clamp((position - origin):Dot(segment) / lengthSquared, 0, 1)
		end
		local delta = position - (origin + segment * alpha)
		local offset = delta:Dot(delta)
		if offset < bestOffset then
			bestOffset = offset
			bestFlow = flowStart[index] + flowSegment[index] * alpha
		end
	end

	return bestFlow
end

--[[ How far the FURTHEST-AHEAD living survivor has got. That is the number the
     Director steers by: the team's progress is set by whoever is pushing, not by
     the average, or a scout would never trigger anything. ]]
function LevelService:getSurvivorFlow(): number
	local now = os.clock()
	if now - cachedSurvivorFlowAt < FLOW_CACHE_TIME then
		return cachedSurvivorFlow
	end
	cachedSurvivorFlowAt = now

	local survivors = Registry.find("SurvivorService")
	if not survivors then
		cachedSurvivorFlow = 0
		return 0
	end

	local best = 0
	for _, character in survivors:getSurvivorCharacters() do
		local root = character:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			local flow = self:getFlowDistance(root.Position)
			if flow > best then
				best = flow
			end
		end
	end

	cachedSurvivorFlow = best
	return best
end

--[[ Total arc length of the spline. Zero on a map with no flow nodes, so every
     caller has to treat it as "unknown" rather than dividing by it blind. ]]
function LevelService:getFlowLength(): number
	if flowDirty then
		rebuildFlow()
	end
	return flowTotal
end

-- ════════════════════════════════════════════════════════════════════════════
--  Tagged geometry the Director asks for
-- ════════════════════════════════════════════════════════════════════════════

function LevelService:getSpawnNodes(): { BasePart }
	if spawnDirty then
		rebuildSpawnNodes()
	end
	-- A copy: this list is the Director's spawn table and a caller that sorted or
	-- shuffled it in place would quietly reorder the level's own cache.
	return table.clone(spawnNodes)
end

--[[ Arenas a Tank or a Witch may be placed in, in flow order. A map with none
     still gets bosses; they just arrive wherever the ordinary spawn rules allow
     rather than in the room that was built for them. ]]
function LevelService:getBossZones(): { BasePart }
	if bossDirty then
		rebuildBossZones()
	end
	return table.clone(bossZones)
end

-- ════════════════════════════════════════════════════════════════════════════
--  Items
-- ════════════════════════════════════════════════════════════════════════════

--[[ The pickup sections of the map, ordered by flow. ]]
function LevelService:getItemSections(): { Instance }
	if sectionsDirty then
		rebuildSections()
	end
	local containers = {}
	for _, section in sections do
		if section.container.Parent then
			table.insert(containers, section.container)
		end
	end
	return containers
end

--[[
	Re-arms every panic trigger for a new round.

	Each one fires once and then latches, which is correct inside a round. Nothing
	ever un-latched them: rebuildPanicTriggers only initialises entries it has
	never seen (`== nil`), MapService deliberately does not reload a map that has
	not changed, so the parts survive the round boundary carrying their fired
	flag — and the level's only authored set piece worked on the first round after
	a server booted and never again.

	Deliberately NOT folded into rebuildPanicTriggers. That function's preserve
	behaviour is load-bearing: it runs whenever the tag set changes, including mid
	round, and re-arming there would hand a second crescendo to anybody who edited
	a tag while the round was live.

	Mirrors AmmoCrateService.resetAll, and is called from the same place for the
	same reason: a new round must not open with half the level still spent.
]]
function LevelService:resetTriggers(): number
	local rearmed = 0
	for part, fired in panicTriggers do
		if fired then
			panicTriggers[part] = false
			rearmed += 1
		end
	end
	return rearmed
end

--[[
	Stocks the part of the map the team is fighting in, through ItemPlacer.

	Called by RoundService when a breather's itemDropChance roll comes up, and
	once during prep so there is something on the shelves to start with. The
	timing matters: ItemPlacer weights its roll by how the team is doing RIGHT
	NOW, so a map stocked at load would hand a healthy team the medkit a hurt team
	needed twelve minutes later.

	Re-stocking the same section is safe and is the point — ItemPlacer skips pads
	that are still holding something, so a breather tops up exactly what the team
	picked up during the wave.

	Returns the number of sections offered to ItemPlacer.
]]
function LevelService:restockItems(): number
	if sectionsDirty then
		rebuildSections()
	end
	local placer = Registry.find("ItemPlacer")
	if not placer or #sections == 0 then
		return 0
	end

	local teamFlow = self:getSurvivorFlow()
	local stocked = 0
	local nearest, nearestGap = nil, math.huge

	for _, section in sections do
		if not section.container.Parent then
			continue
		end
		local gap = math.abs(section.flow - teamFlow)
		if gap < nearestGap then
			nearestGap = gap
			nearest = section.container
		end
		-- Behind the team is still worth stocking: in a hold-out round the team
		-- doubles back constantly, and a map with no flow nodes reports every
		-- section at 0 anyway.
		if section.flow - teamFlow <= POPULATE_LOOKAHEAD then
			placer:populateSection(section.container)
			stocked += 1
		end
	end

	-- Every section is further ahead than the lookahead window: stock the closest
	-- one rather than nothing, because an empty map is not a difficulty setting.
	if stocked == 0 and nearest then
		placer:populateSection(nearest)
		stocked = 1
	end

	return stocked
end

-- ════════════════════════════════════════════════════════════════════════════
--  Survivor spawn placement
--
--  This used to require a safe room, which is exactly why an untagged map put
--  everybody at the world origin on empty terrain. It now falls back three
--  times before it gives up, and says which tag would have fixed it.
-- ════════════════════════════════════════════════════════════════════════════

--[[ Drops a point onto whatever floor is under it and lifts it to root height.
     Falls through to the point itself when nothing is below — a spawn hanging in
     the air is recoverable, a spawn inside the floor is not. ]]
--[[ Whether this surface, or any model it sits inside, is named as somewhere
     nothing may be placed. Walks the ancestors for the reason SpawnPlacement's
     copy does: a map keeps its geometry in a model called Walls holding models
     called section, and the parts underneath are named whatever the artist
     liked. Stops at the live map folder rather than at Workspace, so nothing
     outside the map can accidentally answer for it. ]]
local function blockedSurface(part: BasePart?): boolean
	if not part then
		return false
	end
	local stop = Workspace:FindFirstChild(MapConfig.LiveFolder)
	local node: Instance? = part
	while node and node ~= stop and node ~= Workspace do
		if MapConfig.isNeverStandOn(node.Name) then
			return true
		end
		node = node.Parent
	end
	return false
end

local function standOn(point: Vector3): Vector3
	--[[ Characters and debris are excluded from the cast. A ray that lands on a
	     teammate's head would place the next survivor standing on them, and the
	     two of them are then resolved apart at speed. ]]
	local ignore = {}
	for _, other in Players:GetPlayers() do
		if other.Character then
			table.insert(ignore, other.Character)
		end
	end
	local gore = Workspace:FindFirstChild("FL_Gore")
	if gore then
		table.insert(ignore, gore)
	end

	local ground, _normal, floor = RaycastUtil.groundAt(point, GROUND_SEARCH, ignore)
	--[[ And not onto a ceiling or a wall. Survivors reach this through the ring
	     that spreads a crew wider than the map has pads, and a ring point beside
	     a pad in a corridor lands on top of the wall as readily as on the floor —
	     the top of a wall being the best-looking floor in any map. The point it
	     came from is the fallback, which is a pad somebody chose.

	     By NAME, from MapConfig.NeverStandOn, which is the same answer
	     SpawnPlacement gives the horde. Two spawners, one rule, stated once. ]]
	if ground and not blockedSurface(floor) then
		return Vector3.new(ground.X, ground.Y + SPAWN_ROOT_HEIGHT, ground.Z)
	end
	return point + Vector3.new(0, SPAWN_ROOT_HEIGHT, 0)
end

--[[ A slot's position on a ring around a centre, so four survivors do not spawn
     inside one another and spend the first second of the round being pushed
     apart by the physics solver. ]]
local function ringPoint(centre: Vector3, slot: number): Vector3
	local count = math.max(GameConfig.MaxSurvivors, 1)
	local bearing = ((slot - 1) % count) * (math.pi * 2 / count)
	return centre
		+ Vector3.new(math.cos(bearing) * SPAWN_RING_RADIUS, 0, math.sin(bearing) * SPAWN_RING_RADIUS)
end

--[[
	Every SpawnLocation inside the map that is actually loaded.

	Cached against the root it was built from, so it rebuilds by itself the
	moment a different map is underneath it and needs no signal to tell it — a
	map swap replaces the root, the comparison fails, and the next ask walks the
	new one. A round asks this a handful of times, so a descendants walk on a
	miss is not worth a subscription.

	Disabled ones are skipped, because that is what the property means and a
	designer who switched one off has said something.

	Sorted by name so the round-robin below is STABLE. GetDescendants order is
	whatever the file happened to be saved in, and six survivors who each get a
	different spawn every round is a team that cannot agree where "the start" is.
]]
local mapSpawnRoot: Instance? = nil
local mapSpawns: { SpawnLocation } = {}

local function mapSpawnPoints(): { SpawnLocation }
	local mapService = Registry.find("MapService")
	local root = mapService
		and typeof(mapService.getCurrentRoot) == "function"
		and mapService:getCurrentRoot()
	if typeof(root) ~= "Instance" then
		mapSpawnRoot = nil
		table.clear(mapSpawns)
		return mapSpawns
	end
	if root == mapSpawnRoot then
		--[[ Re-verified rather than trusted: a designer deleting a spawn mid-
		     session, or a map that streams its geometry in, would otherwise leave
		     a destroyed instance in this list forever. ]]
		for index = #mapSpawns, 1, -1 do
			if not mapSpawns[index].Parent then
				table.remove(mapSpawns, index)
			end
		end
		if #mapSpawns > 0 then
			return mapSpawns
		end
	end

	mapSpawnRoot = root
	table.clear(mapSpawns)

	--[[
		ENABLED IS A PREFERENCE, NOT A FILTER, AND THAT DISTINCTION WAS A BUG.

		This used to require `descendant.Enabled`, which reads as obviously
		correct and quietly discards the pads a CAREFUL author places. Setting
		Enabled = false on a map's SpawnLocations is the normal way to stop
		Roblox's own automatic spawning fighting a game that positions its own
		survivors — which is exactly what this game does, three lines later, with
		a PivotTo. So the better the map was authored, the more likely every one
		of its pads was skipped here.

		And skipping them all is not a small failure. With no map spawns, the
		branch below hunts Workspace for ANY SpawnLocation, finds the lobby's, and
		starts the round with the team standing outside the level. Everything
		downstream inherits that: the Director samples spawn candidates around the
		survivors, so the horde and the boss are placed around wherever the team
		actually is — which is how a Tank ends up on the roof of the Backrooms.
		One bug, three symptoms.

		So: enabled pads win if there are any, because disabling a few is how an
		author takes them out of rotation and that intention is real. If they are
		ALL disabled, they are still the map's spawn points and still beat
		anything outside the map.
	]]
	local disabled: { SpawnLocation } = {}
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("SpawnLocation") then
			if descendant.Enabled then
				table.insert(mapSpawns, descendant)
			else
				table.insert(disabled, descendant)
			end
		end
	end
	if #mapSpawns == 0 and #disabled > 0 then
		mapSpawns = disabled
		--[[ A note rather than a warning: this is a correct way to author a map
		     and the round is about to work. It is said once because "the team
		     started somewhere strange" is a question somebody will ask about this
		     map eventually, and this is the line that answers it. ]]
		warnOnce(
			"disabledspawns",
			"every SpawnLocation in the loaded map has Enabled = false, so they are being used "
				.. "anyway — this game positions survivors itself and does not need Roblox's "
				.. "automatic spawning, which is presumably why they were switched off. Nothing to "
				.. "fix; said once so it is not a mystery later."
		)
	end
	table.sort(mapSpawns, function(a: SpawnLocation, b: SpawnLocation): boolean
		if a.Name == b.Name then
			--[[ Six children all called "SpawnLocation" is the normal case, and
			     names alone cannot order them. Position does, and any consistent
			     answer is the whole requirement. ]]
			local left, right = a.Position, b.Position
			if left.X == right.X then
				return left.Z < right.Z
			end
			return left.X < right.X
		end
		return a.Name < b.Name
	end)
	return mapSpawns
end

local function flatLook(direction: Vector3): Vector3
	local flat = Vector3.new(direction.X, 0, direction.Z)
	if flat.Magnitude < 1e-3 then
		return Vector3.new(0, 0, -1)
	end
	return flat.Unit
end

--[[ The centre of the flow spline, and the direction it runs. The last-but-one
     fallback: a map with a spline has told us where the play space is even if
     nobody tagged a spawn. ]]
local function flowAnchor(): (Vector3?, Vector3?)
	if flowDirty then
		rebuildFlow()
	end
	if #flowPoints == 0 then
		return nil, nil
	end
	local sum = Vector3.zero
	for _, point in flowPoints do
		sum += point
	end
	local centre = sum / #flowPoints
	local direction = if #flowPoints > 1 then flowPoints[#flowPoints] - flowPoints[1] else nil
	return centre, direction
end

--[[
	Where survivor `slot` starts the round.

	In order of preference: a part tagged FL_SurvivorSpawn (handed out round-robin
	so one part works and four parts work better, and its rotation is the way the
	survivor faces), THE LOADED MAP'S OWN SpawnLocations on the same round-robin,
	a SpawnLocation anywhere in Workspace, the middle of the flow spline, and
	finally the ground under the world origin — which is a bad answer and says so
	in the log rather than pretending.

	── THE MAP'S OWN SPAWNS ARE A REAL ANSWER, NOT A FALLBACK ──────────────────
	The second branch used to be the third one, and it was wrong twice over.

	It searched the WHOLE of Workspace and took the first SpawnLocation it found.
	On a game that swaps maps in and out of Workspace, and that has other things
	parked beside them, "first" is descendant order — which is to say arbitrary,
	and routinely a spawn belonging to a map that is not loaded. That is a team
	starting the round outside the level, which is exactly how it was reported.

	And it used only ONE of them. A designer who places six SpawnLocations around
	a map has said where the six of them are; ringing everybody around whichever
	one came first throws away five of those decisions.

	So the map's own spawns are now their own branch, handed out round-robin like
	the tagged parts, each survivor standing on their own pad and facing the way
	it points. FL_SurvivorSpawn still wins when it is present, because tagging a
	part is a deliberate override of a native one — but a map with SpawnLocations
	in it and nothing tagged is a map that has answered the question, and it no
	longer gets warned at for it.
]]
--[[
	Where survivors will actually start, in words, for the boot banner.

	The banner used to print `#survivorSpawns`, which counts only TAGGED parts —
	and no map in this build has any, so it read "0 survivor spawns" on a map
	with six perfectly good SpawnLocations in it and told nobody anything. The
	number was true and the sentence was useless: it looked like the thing was
	broken when it was working, and it would have looked identical on the day it
	genuinely was.

	So it names the source that getSurvivorSpawnCFrame will actually reach, in
	the same order that function tries them. Checking that the team starts inside
	the level is now reading one line at boot rather than playing a round.
]]
local function survivorSpawnSummary(): string
	--[[ Before anything else, because at BOOT there is usually no map: they are
	     loaded per round, and this line runs from start() as well as from
	     rebuild(). Without this the banner reads "NONE anywhere — falling back to
	     the flow spline", which is an alarm about a situation that has not
	     happened yet, on every server, every time. A line that cries wolf at boot
	     is a line nobody reads at the one moment it is telling the truth. ]]
	local mapService = Registry.find("MapService")
	local loaded = mapService
		and typeof(mapService.getCurrentRoot) == "function"
		and mapService:getCurrentRoot()
	if typeof(loaded) ~= "Instance" then
		return "no map loaded yet"
	end

	if survivorSpawnDirty then
		rebuildSurvivorSpawns()
	end
	if #survivorSpawns > 0 then
		return string.format("%d tagged %s", #survivorSpawns, TAG_SURVIVOR_SPAWN)
	end
	local placed = mapSpawnPoints()
	if #placed > 0 then
		return string.format("%d SpawnLocation(s) in the map", #placed)
	end
	if Workspace:FindFirstChildWhichIsA("SpawnLocation", true) then
		return "NONE in the map — falling back to a SpawnLocation elsewhere in Workspace"
	end
	return "NONE anywhere — falling back to the flow spline or the map's centre"
end

--[[
	One survivor, standing on one pad.

	── WHY THIS IS NOT JUST "THE PAD'S POSITION" ───────────────────────────────
	Both pad branches wrapped with `((index - 1) % count) + 1` and stopped there,
	which is correct until there are more survivors than pads. Then the fifth
	player is handed pad one — the EXACT CFrame the first player already has —
	and two characters are spawned inside each other. Roblox resolves that
	overlap the only way it can, by ejecting one at speed, and on a map whose
	floor is thin that is straight through it.

	That is the whole of "in other maps I spawn under or away, but when I test on
	my own I spawn fine": alone nobody ever shares a pad, so the bug cannot
	happen, and the more people are in the round the likelier it is.

	So a survivor who is not the first on their pad is placed AROUND it instead of
	on it, using the same ring the untagged fallbacks already use, and dropped
	onto whatever floor is actually there — a ring point over a stairwell is a
	worse answer than the pad it came from, and standOn is what turns it back
	into a place a person can stand.
]]
local function padCFrame(pad: BasePart, index: number, count: number): CFrame
	local top = pad.Position + Vector3.new(0, pad.Size.Y * 0.5 + SPAWN_ROOT_HEIGHT, 0)
	local facing = flatLook(pad.CFrame.LookVector)
	--[[ Which time around the pads this is. Zero for everybody while there are
	     enough to go round, which is the ordinary case and costs nothing. ]]
	if index > count then
		top = standOn(ringPoint(top, index))
	end
	return CFrame.lookAt(top, top + facing)
end

function LevelService:getSurvivorSpawnCFrame(slot: number): CFrame
	if survivorSpawnDirty then
		rebuildSurvivorSpawns()
	end
	local index = math.max(math.floor(tonumber(slot) or 1), 1)

	if #survivorSpawns > 0 then
		local count = #survivorSpawns
		return padCFrame(survivorSpawns[((index - 1) % count) + 1], index, count)
	end

	--[[ The map's own, one survivor per pad, on top of it and facing the way it
	     points — the same treatment a tagged part gets, because a SpawnLocation
	     the author placed is the same statement. No warning: this is a correct
	     way to author a map, not a thing to be nagged out of. ]]
	local placed = mapSpawnPoints()
	if #placed > 0 then
		local count = #placed
		return padCFrame(placed[((index - 1) % count) + 1], index, count)
	end

	--[[ Anywhere at all, and now genuinely a last resort before the spline. The
	     map has none of its own, so this is a spawn belonging to something else
	     in Workspace — worth using rather than dropping somebody in the void, and
	     worth saying out loud, because it is almost certainly not where the
	     author meant. ]]
	local spawnLocation = Workspace:FindFirstChildWhichIsA("SpawnLocation", true)
	if spawnLocation then
		warnOnce(
			"nosurvivorspawn",
			string.format(
				"the loaded map contains no %s part and no SpawnLocation of its own, so survivors "
					.. "are starting at %q, which is somewhere else in Workspace. Put a SpawnLocation "
					.. "in the map, or tag a part with %s — either answers this, and its rotation is "
					.. "the direction the team faces.",
				TAG_SURVIVOR_SPAWN,
				spawnLocation:GetFullName(),
				TAG_SURVIVOR_SPAWN
			)
		)
		local point = standOn(ringPoint(spawnLocation.Position, index))
		return CFrame.lookAt(point, point + flatLook(spawnLocation.CFrame.LookVector))
	end

	local centre, direction = flowAnchor()
	if centre then
		warnOnce(
			"nosurvivorspawn",
			string.format(
				"no %s part and no SpawnLocation anywhere, so survivors are starting in the middle "
					.. "of the %s spline. Put a SpawnLocation in the map or tag a part with %s where "
					.. "you want the team to begin.",
				TAG_SURVIVOR_SPAWN,
				TAG_FLOW,
				TAG_SURVIVOR_SPAWN
			)
		)
		local point = standOn(ringPoint(centre, index))
		return CFrame.lookAt(point, point + flatLook(direction or Vector3.new(0, 0, -1)))
	end

	--[[
		Nothing in the map says where to stand, so stand on the map itself.

		This is the case that matters most in practice: a map that has been
		dropped in but not tagged yet. Every earlier branch needs the author to
		have marked something, and until they do, the old behaviour was to spawn
		at the world origin — which for a map built anywhere else is empty space,
		and presents as being flung off the world the instant a round starts.

		Measuring the loaded map's own bounding box and dropping the team onto the
		middle of it makes an untagged map playable immediately. It is not where
		the author would have chosen, and the warning says so, but it is on solid
		ground and that is the difference between "not tagged yet" and "broken".
	]]
	local mapService = Registry.find("MapService")
	local root = mapService and mapService:getCurrentRoot()
	if root then
		local ok, boxCFrame, size = pcall(function()
			return root:GetBoundingBox()
		end)
		if ok and boxCFrame and size and size.Magnitude > 1 then
			warnOnce(
				"nosurvivorspawn",
				string.format(
					"the map carries no %s part, no SpawnLocation and no %s parts, so survivors are "
						.. "being dropped onto the middle of the map's own geometry. Tag ONE part "
						.. "with %s where you want the team to begin — its rotation is the direction "
						.. "they face.",
					TAG_SURVIVOR_SPAWN,
					TAG_FLOW,
					TAG_SURVIVOR_SPAWN
				)
			)
			-- From above the box, so the ground cast lands on the highest surface
			-- rather than starting inside a building and finding its floor.
			local above = boxCFrame.Position + Vector3.new(0, size.Y * 0.5 + 8, 0)
			local point = standOn(ringPoint(above, index))
			return CFrame.lookAt(point, point + Vector3.new(0, 0, -1))
		end
	end

	warnOnce(
		"nosurvivorspawn",
		string.format(
			"the map carries no %s part, no SpawnLocation and no %s parts, and no map is loaded, so "
				.. "there is nothing that says where the team should stand. Survivors are being "
				.. "dropped onto whatever is under the world origin. Tag ONE part in your map with "
				.. "%s to fix this.",
			TAG_SURVIVOR_SPAWN,
			TAG_FLOW,
			TAG_SURVIVOR_SPAWN
		)
	)
	local point = standOn(ringPoint(Vector3.zero, index))
	return CFrame.lookAt(point, point + Vector3.new(0, 0, -1))
end

--[[ Hands every player their spawn point. Called by RoundService before it
     spawns the team, and on join so the bootstrap's own spawnSurvivor has a
     CFrame to use. ]]
function LevelService:placeSurvivors()
	local survivors = Registry.find("SurvivorService")
	if not survivors then
		return
	end
	local slot = 0
	for _, player in Players:GetPlayers() do
		slot += 1
		survivors:setSpawnCFrame(player, self:getSurvivorSpawnCFrame(slot))
	end
end

-- ════════════════════════════════════════════════════════════════════════════
--  Objective
-- ════════════════════════════════════════════════════════════════════════════

local function playUi(definition)
	local audio = Registry.find("AudioService")
	if not audio then
		return
	end
	for _, player in Players:GetPlayers() do
		audio:playForPlayer(player, definition)
	end
end

--[[ Writes the objective attribute and announces it once. Attribute AND remote
     on purpose: the attribute is the state a late joiner reads, the remote is
     the event a HUD animates. RoundService supplies the words — the round knows
     what the team is meant to be doing; the level knows where it is. ]]
function LevelService:setObjective(text: string)
	if typeof(text) ~= "string" or text == objectiveText then
		return
	end
	objectiveText = text
	Workspace:SetAttribute(Attributes.Game.ObjectiveText, text)

	local length = self:getFlowLength()
	local progress = if length > 0 then math.clamp(self:getSurvivorFlow() / length, 0, 1) else 0
	Remotes.Event.ObjectiveChanged:FireAllClients({ text = text, progress = progress })
	playUi(AudioConfig.UI.ObjectiveChange)
end

function LevelService:getObjective(): string
	return objectiveText
end

-- ════════════════════════════════════════════════════════════════════════════
--  The shared tick
-- ════════════════════════════════════════════════════════════════════════════

local function pointInside(box: CFrame, size: Vector3, position: Vector3): boolean
	local localPoint = box:PointToObjectSpace(position)
	return math.abs(localPoint.X) <= size.X * 0.5
		and math.abs(localPoint.Y) <= size.Y * 0.5
		and math.abs(localPoint.Z) <= size.Z * 0.5
end

--[[ Every survivor still in the fight, and where they are. Built once per tick
     into a reused table, because the tick runs five times a second forever and a
     fresh table each time is garbage the horde has to pay for later. ]]
local tickPositions: { Vector3 } = {}

local function gatherSurvivorPositions(): number
	table.clear(tickPositions)
	local survivors = Registry.find("SurvivorService")
	if not survivors then
		return 0
	end
	for _, character in survivors:getSurvivorCharacters() do
		local root = character:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			table.insert(tickPositions, root.Position)
		end
	end
	return #tickPositions
end

function LevelService:_checkPanic()
	if panicDirty then
		rebuildPanicTriggers()
	end
	if #tickPositions == 0 then
		return
	end

	-- A trigger arms once and only once, so it must not be burned by somebody
	-- wandering over it during the lobby or the prep window. The round state is
	-- read from the attribute rather than from RoundService, because geometry
	-- should not need to know which service is running the round.
	if Attributes.get(Workspace, Attributes.Game.RoundState, "") ~= Enums.RoundState.InProgress then
		return
	end

	for part, fired in panicTriggers do
		if fired or not part.Parent then
			continue
		end
		local hit = false
		for _, position in tickPositions do
			if pointInside(part.CFrame, part.Size, position) then
				hit = true
				break
			end
		end
		if not hit then
			continue
		end

		--[[ Armed once and once only WITHIN A ROUND. A crescendo that re-fires
		     every time somebody walks back over the generator is not a crescendo,
		     it is a spawn tap — but see resetTriggers: "once" used to mean once
		     per SERVER, because nothing ever put this back. ]]
		panicTriggers[part] = true

		-- find(), not get(): a level with a panic trigger and no Director should
		-- still be walkable, and this runs inside the shared loop where a throw
		-- would take the rest of the tick down with it.
		local director = Registry.find("DirectorService")
		if director then
			director:triggerPanicEvent(part.Position)
		else
			warnOnce("nodirector", "a panic trigger fired but DirectorService is not registered")
		end

		local restore = objectiveText
		self:setObjective(TEXT_PANIC)
		task.delay(DirectorConfig.PanicEvent.Duration, function()
			-- Only if nothing else has claimed the line since — RoundService
			-- rewrites it on every wave edge and the round outranks a trigger.
			if objectiveText == TEXT_PANIC then
				self:setObjective(restore)
			end
		end)
	end
end

function LevelService:_step()
	gatherSurvivorPositions()
	self:_checkPanic()
end

-- ════════════════════════════════════════════════════════════════════════════
--  Lifecycle
-- ════════════════════════════════════════════════════════════════════════════

function LevelService:init()
	-- Tags are watched rather than polled, so a level that streams in, or an
	-- author dragging a new flow node around in a live playtest, is picked up on
	-- the next question instead of never.
	for tag, invalidate in
		{
			[TAG_FLOW] = function()
				flowDirty = true
				sectionsDirty = true
			end,
			[TAG_SPAWN] = function()
				spawnDirty = true
			end,
			[TAG_ITEM] = function()
				sectionsDirty = true
			end,
			[TAG_PANIC] = function()
				panicDirty = true
			end,
			[TAG_BOSS] = function()
				bossDirty = true
			end,
			[TAG_SURVIVOR_SPAWN] = function()
				survivorSpawnDirty = true
			end,
		}
	do
		serviceTrove:connect(CollectionService:GetInstanceAddedSignal(tag), invalidate)
		serviceTrove:connect(CollectionService:GetInstanceRemovedSignal(tag), invalidate)
	end
end

--[[
	Re-reads the whole level from tags.

	MapService calls this the moment a map finishes loading, and it is not
	optional: without it the service keeps the PREVIOUS map's flow spline, spawn
	nodes and survivor spawn CFrames after a swap. Those point at instances that
	have been destroyed, so the Director spawns into nothing and survivors get
	placed at coordinates belonging to a map that no longer exists — which
	presents as being flung off the world the instant a round starts.

	Marking every cache dirty rather than rebuilding inline lets the existing lazy
	rebuilds do the work at the next question, which is also the only path that is
	safe to call while the level loop is mid-tick.
]]
function LevelService:rebuild()
	flowDirty = true
	spawnDirty = true
	sectionsDirty = true
	panicDirty = true
	bossDirty = true
	survivorSpawnDirty = true

	rebuildFlow()
	rebuildSpawnNodes()
	rebuildBossZones()
	rebuildSurvivorSpawns()
	rebuildPanicTriggers()
	rebuildSections()

	print(
		string.format(
			"[LevelService] rebuilt for the new map: %d flow nodes over %.0f studs, "
				.. "%d spawn nodes, %d boss zones, %d item sections; survivors start from %s",
			#flowPoints,
			flowTotal,
			#spawnNodes,
			#bossZones,
			#sections,
			survivorSpawnSummary()
		)
	)
end

function LevelService:start()
	rebuildFlow()
	rebuildSpawnNodes()
	rebuildBossZones()
	rebuildSurvivorSpawns()
	rebuildPanicTriggers()
	rebuildSections()

	-- One line, at boot, saying exactly what the map gave us. A map that is
	-- missing something should be obvious before the first zombie, not after
	-- twenty minutes of wondering why the Director is quiet.
	print(
		string.format(
			"[LevelService] %d flow nodes over %.0f studs, %d spawn nodes, %d boss zones, "
				.. "%d item sections, %d panic triggers; survivors start from %s",
			#flowPoints,
			flowTotal,
			#spawnNodes,
			#bossZones,
			#sections,
			#taggedParts(TAG_PANIC),
			survivorSpawnSummary()
		)
	)

	-- Before the bootstrap's own PlayerAdded handler, which is connected after
	-- every start() has run — so the CFrame is in place by the time
	-- SurvivorService calls LoadCharacter for a joining player.
	serviceTrove:connect(Players.PlayerAdded, function(player)
		local survivors = Registry.find("SurvivorService")
		if survivors then
			survivors:setSpawnCFrame(player, self:getSurvivorSpawnCFrame(#Players:GetPlayers()))
		end
	end)
	self:placeSurvivors()

	-- THE loop. One connection for the whole level, throttled to TICK_INTERVAL:
	-- everything in it is a spatial test against four characters and none of it
	-- gets a better answer for being asked sixty times a second.
	serviceTrove:connect(RunService.Heartbeat, function(delta)
		accumulator += delta
		if accumulator < TICK_INTERVAL then
			return
		end
		accumulator = 0
		self:_step()
	end)
end

function LevelService:destroy()
	serviceTrove:destroy()
end

Registry.register("LevelService", LevelService)

return LevelService
