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

	There are no safe rooms and no chapters. A round is seven waves on a fixed
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

local function rebuildSpawnNodes()
	spawnDirty = false
	spawnNodes = taggedParts(TAG_SPAWN)
	if #spawnNodes == 0 then
		warnOnce(
			"nospawnnodes",
			string.format(
				"no %s parts in the map. Infected placement falls back to sampling the space around "
					.. "the survivors, which works but ignores your doorways and alleys — tag a few "
					.. "parts out of sight of the play space to control where the horde comes from.",
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

	local ground = RaycastUtil.groundAt(point, GROUND_SEARCH, ignore)
	if ground then
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
	survivor faces), a SpawnLocation anywhere in Workspace, the middle of the flow
	spline, and finally the ground under the world origin — which is a bad answer
	and says so in the log rather than pretending.
]]
function LevelService:getSurvivorSpawnCFrame(slot: number): CFrame
	if survivorSpawnDirty then
		rebuildSurvivorSpawns()
	end
	local index = math.max(math.floor(tonumber(slot) or 1), 1)

	if #survivorSpawns > 0 then
		local pad = survivorSpawns[((index - 1) % #survivorSpawns) + 1]
		local top = pad.Position + Vector3.new(0, pad.Size.Y * 0.5 + SPAWN_ROOT_HEIGHT, 0)
		return CFrame.lookAt(top, top + flatLook(pad.CFrame.LookVector))
	end

	local spawnLocation = Workspace:FindFirstChildWhichIsA("SpawnLocation", true)
	if spawnLocation then
		warnOnce(
			"nosurvivorspawn",
			string.format(
				"no %s parts in the map, so survivors are starting at the SpawnLocation %q. Tag a part "
					.. "with %s where you want the team to begin the round — its rotation is the "
					.. "direction they face.",
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
				"no %s part and no SpawnLocation in the map, so survivors are starting in the middle "
					.. "of the %s spline. Tag a part with %s where you want the team to begin.",
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

		-- Armed once and once only. A crescendo that re-fires every time somebody
		-- walks back over the generator is not a crescendo, it is a spawn tap.
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
				.. "%d spawn nodes, %d boss zones, %d survivor spawns, %d item sections",
			#flowPoints,
			flowTotal,
			#spawnNodes,
			#bossZones,
			#survivorSpawns,
			#sections
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
				.. "%d survivor spawns, %d item sections, %d panic triggers",
			#flowPoints,
			flowTotal,
			#spawnNodes,
			#bossZones,
			#survivorSpawns,
			#sections,
			#taggedParts(TAG_PANIC)
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
