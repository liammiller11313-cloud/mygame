--!nonstrict
--[[
	LevelService — everything the game knows about the shape of the map.

	── THE POINT OF THIS MODULE ─────────────────────────────────────────────────
	Not one coordinate in this file. Every single thing the level does is
	discovered from CollectionService tags and Instance attributes, so the user's
	own hand-built map drops in and works with ZERO code changes. Build a level
	that carries these tags and this service will run it:

	    FL_FlowNode      a point on the level spline; ordered by its FL_Order
	                     attribute (any numbers, they only have to sort)
	    FL_SpawnNode     a legal infected spawn point
	    FL_ItemSpawn     a pickup pad; optional FL_Slot attribute forces its type
	    FL_SafeRoom      a Model containing a part named "Door"; FL_Index
	                     attribute orders the chapters, highest index is the end
	    FL_PanicTrigger  a volume; walking into it starts a crescendo, once
	    FL_BossZone      read by the Director, not by this service

	The one optional extra: a Door may carry an FL_OpenOffset Vector3 attribute,
	which is the LOCAL-space vector the door slides along to open. Without it a
	door slides straight up by its own height, which is the sane default for a
	shutter and wrong for nothing much.

	── FLOW DISTANCE ────────────────────────────────────────────────────────────
	The flow nodes form a polyline, and `getFlowDistance` projects a point onto it
	and returns the arc length to that projection. That number is the backbone of
	the whole Director: what counts as "ahead of the team", where a Tank is due,
	whether a spawn point is in front of the survivors or behind them, and how far
	through the chapter the HUD says you are. It is a scalar for a 3D world, and
	it is the reason a Left 4 Dead map feels directed rather than random.

	Tags are watched, not sampled: a map that streams in, or an author adding a
	node in Studio during a playtest, invalidates the cache and it rebuilds on the
	next question.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
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
local Signal = require(Shared.Util.Signal)
local Trove = require(Shared.Util.Trove)
local WeaponConfig = require(Shared.Config.WeaponConfig)

local TAG_FLOW = "FL_FlowNode"
local TAG_SPAWN = "FL_SpawnNode"
local TAG_ITEM = "FL_ItemSpawn"
local TAG_SAFEROOM = "FL_SafeRoom"
local TAG_PANIC = "FL_PanicTrigger"

local ATTR_ORDER = "FL_Order"
local ATTR_INDEX = "FL_Index"
local ATTR_OPEN_OFFSET = "FL_OpenOffset"

--[[ 5Hz. Safe-room entry and panic triggers are spatial questions about four
     characters; asking them every frame would cost sixty times as much for an
     answer that cannot change meaningfully inside 200ms. ]]
local TICK_INTERVAL = 0.2

--[[ How far inside a safe room's own bounding box a survivor has to be before
     they count as inside it. The box includes the walls, so without an inset a
     player leaning on the outside of the room would complete the chapter. ]]
local SAFEROOM_MARGIN = 4

--[[ getSurvivorFlow is asked for by the Director, by SpawnPlacement and by this
     module's own tick, several times per second each, and the answer cannot
     change much in a tenth of a second at survivor walking speed. ]]
local FLOW_CACHE_TIME = 0.1

--[[ How long a safe-room door takes to travel. Deliberately not read from
     UITheme.Motion: that table is the interface's timing language, and a blast
     door is not a HUD element. ]]
local DOOR_TWEEN = TweenInfo.new(1.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

--[[
	Two timings the contract has no config home for, kept local and named rather
	than sprinkled as literals. If a round service is ever written, they belong in
	GameConfig next to the rest of the round rules.
]]
local START_DELAY = 3 -- lobby -> in progress, so a joining team is together
local RESTART_DELAY = 14 -- how long a wipe or a victory screen holds before a reset

--[[ Items are stocked this far ahead of the team. Borrowed from the Director's
     own spawn window on purpose: it is already the distance at which the game
     considers something "coming up", so items and infected agree about where the
     front of the level is. ]]
local POPULATE_LOOKAHEAD = DirectorConfig.Spawning.MaxFlowAhead

-- Objective lines. Strings, not tuning — no config owns copy.
local TEXT = table.freeze({
	FirstLeg = "Fight your way to the checkpoint",
	NextLeg = "Move up to the next safe room",
	FinalLeg = "Get to the safe room",
	Panic = "Survive the horde",
	Victory = "You made it.",
	Wipe = "The team is down.",
	Lobby = "Waiting for survivors",
})

local LevelService = {}

--[[ Fired as (chapterIndex, safeRoomModel, isFinal) each time the team completes
     a leg by sealing themselves into a safe room. ]]
LevelService.chapterChanged = Signal.new()

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

local safeRooms: { any } = {} -- ordered by FL_Index
local roomByModel: { [Model]: any } = {}
local safeDirty = true

local panicTriggers: { [BasePart]: boolean } = {} -- part -> already fired
local panicDirty = true

local sections: { any } = {}
local sectionsDirty = true

-- ── round ───────────────────────────────────────────────────────────────────
local roundState = Enums.RoundState.Lobby
local roundGeneration = 0
local currentChapter = 0
local sawLivingSurvivor = false
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
	table.sort(nodes, function(a, b)
		local left = tonumber(a:GetAttribute(ATTR_ORDER)) or math.huge
		local right = tonumber(b:GetAttribute(ATTR_ORDER)) or math.huge
		if left == right then
			return a.Name < b.Name
		end
		return left < right
	end)

	for _, node in nodes do
		table.insert(flowPoints, node.Position)
	end

	for index = 1, #flowPoints - 1 do
		local length = (flowPoints[index + 1] - flowPoints[index]).Magnitude
		flowStart[index] = flowTotal
		flowSegment[index] = length
		flowTotal += length
	end

	if #flowPoints == 0 then
		warnOnce(
			"noflow",
			"no FL_FlowNode parts in Workspace — flow distance is 0 everywhere, so the "
				.. "Director cannot tell what is ahead of the team"
		)
	end
end

local function rebuildSpawnNodes()
	spawnDirty = false
	spawnNodes = taggedParts(TAG_SPAWN)
end

--[[ The rooms, ordered by FL_Index, each with its door captured in the closed
     pose it was authored in and the bounding box it had before that door ever
     moved. Both are snapshots on purpose: an open door must not enlarge the
     volume that decides who is inside. ]]
local function rebuildSafeRooms()
	safeDirty = false
	-- Carried over rather than rebuilt: a tag edit anywhere in the map must not
	-- silently un-complete a chapter the team has already earned, and the door's
	-- closed pose must be the one it was AUTHORED in, not wherever it is now.
	local previous = roomByModel
	safeRooms = {}
	roomByModel = {}

	for _, instance in CollectionService:GetTagged(TAG_SAFEROOM) do
		if not instance:IsA("Model") or not instance:IsDescendantOf(Workspace) then
			continue
		end
		local carried = previous[instance]
		local door = instance:FindFirstChild("Door", true)
		local box, size = instance:GetBoundingBox()
		local record = {
			model = instance,
			index = tonumber(instance:GetAttribute(ATTR_INDEX)) or (#safeRooms + 1),
			order = 0,
			door = if door and door:IsA("BasePart") then door else nil,
			closedCFrame = nil,
			openCFrame = nil,
			doorOpen = if carried then carried.doorOpen else false,
			box = if carried then carried.box else box,
			size = if carried then carried.size else size,
			completed = if carried then carried.completed else false,
		}
		if record.door then
			record.closedCFrame = if carried and carried.closedCFrame
				then carried.closedCFrame
				else record.door.CFrame
			local offset = record.door:GetAttribute(ATTR_OPEN_OFFSET)
			if typeof(offset) ~= "Vector3" then
				offset = Vector3.new(0, record.door.Size.Y + 0.2, 0)
			end
			record.openCFrame = record.closedCFrame * CFrame.new(offset)
		else
			warnOnce(
				"nodoor:" .. instance.Name,
				string.format("safe room %q has no part named Door; it can never be sealed", instance.Name)
			)
		end
		table.insert(safeRooms, record)
		roomByModel[instance] = record
	end

	table.sort(safeRooms, function(a, b)
		return a.index < b.index
	end)
	for order, record in safeRooms do
		-- Position in the chain, which is what "the last one" means. FL_Index only
		-- has to sort: a hand-built map is free to number its rooms 10, 20, 30.
		record.order = order
	end

	if #safeRooms == 0 then
		warnOnce("norooms", "no FL_SafeRoom models in Workspace — the round can never be won")
	end
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

	ItemPlacer's populateSection wants "the section the team is committing to",
	and this derives that from the tags already in the map rather than demanding
	yet another tag. A map that is one flat folder of pads degrades to a single
	section, which stocks once and is still perfectly playable.
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
			stocked = false,
		})
	end
	table.sort(sections, function(a, b)
		return a.flow < b.flow
	end)
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

function LevelService:getSpawnNodes(): { BasePart }
	if spawnDirty then
		rebuildSpawnNodes()
	end
	-- A copy: this list is the Director's spawn table and a caller that sorted or
	-- shuffled it in place would quietly reorder the level's own cache.
	return table.clone(spawnNodes)
end

function LevelService:getSafeRooms(): { Model }
	if safeDirty then
		rebuildSafeRooms()
	end
	local models = {}
	for _, record in safeRooms do
		table.insert(models, record.model)
	end
	return models
end

-- ════════════════════════════════════════════════════════════════════════════
--  Objective and round state
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
     the event a HUD animates. ]]
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

--[[
	Publishes the round state.

	Also fired, with the state unchanged, on a chapter boundary: the payload is
	what the client's overlay reads to throw up a chapter card, and inventing a
	second remote for "the same round, one leg further on" would put two events on
	the wire that always travel together.
]]
function LevelService:_publishRound(state: string, payload: { [string]: any }?)
	roundState = state
	Workspace:SetAttribute(Attributes.Game.RoundState, state)
	Remotes.Event.RoundStateChanged:FireAllClients({ state = state, payload = payload })
end

function LevelService:getRoundState(): string
	return roundState
end

-- ════════════════════════════════════════════════════════════════════════════
--  Safe rooms
-- ════════════════════════════════════════════════════════════════════════════

local function pointInside(box: CFrame, size: Vector3, position: Vector3, margin: number): boolean
	local localPoint = box:PointToObjectSpace(position)
	return math.abs(localPoint.X) <= math.max(size.X * 0.5 - margin, 0)
		and math.abs(localPoint.Y) <= math.max(size.Y * 0.5, 0)
		and math.abs(localPoint.Z) <= math.max(size.Z * 0.5 - margin, 0)
end

function LevelService:_setDoor(record, open: boolean)
	if not record.door or not record.openCFrame or record.doorOpen == open then
		return
	end
	record.doorOpen = open
	TweenService:Create(record.door, DOOR_TWEEN, {
		CFrame = if open then record.openCFrame else record.closedCFrame,
	}):Play()
end

--[[ A standing spot inside a room, found by dropping onto its floor rather than
     assuming one — a hand-built safe room's bounding box bottom is wherever its
     lowest wall happens to end. ]]
local function standingCFrame(record, slot: number): CFrame
	local centre = record.box.Position
	local bearing = (slot - 1) * (math.pi * 2 / math.max(GameConfig.MaxSurvivors, 1))
	local spread = math.min(record.size.X, record.size.Z) * 0.22
	local point = centre + Vector3.new(math.cos(bearing) * spread, 0, math.sin(bearing) * spread)

	local ground = RaycastUtil.groundAt(point, record.size.Y, {})
	local y = if ground then ground.Y else record.box.Position.Y - record.size.Y * 0.5
	local stand = Vector3.new(point.X, y + 3.5, point.Z)

	local door = record.door
	if door then
		local facing = Vector3.new(door.Position.X, stand.Y, door.Position.Z)
		if (facing - stand).Magnitude > 1 then
			return CFrame.lookAt(stand, facing)
		end
	end
	return CFrame.new(stand)
end

--[[
	Resupply. A safe room is the game's only guaranteed breather, so it undoes
	everything a chapter did to the team that a chapter is allowed to undo:
	everyone who is down gets up, everyone who died comes back, wounds close and
	magazines and reserves refill.

	It deliberately does NOT clear black and white. That state is cleared by a
	medkit and only by a medkit, which is why the shelves in here are tagged with
	FL_Slot = Health — the way out is an item the team has to choose to spend.
]]
function LevelService:_resupply(record)
	local survivors = Registry.find("SurvivorService")
	local inventory = Registry.find("InventoryService")
	if not survivors then
		return
	end

	local slot = 0
	for _, player in Players:GetPlayers() do
		slot += 1
		local cframe = standingCFrame(record, slot)
		survivors:setSpawnCFrame(player, cframe)

		local state = survivors:getState(player)
		if state == Enums.SurvivorState.Dead or state == Enums.SurvivorState.Spectating then
			-- A chapter boundary is where Left 4 Dead gives a dead survivor back.
			survivors:spawnSurvivor(player)
		elseif survivors:isIncapacitated(player) then
			survivors:revive(player)
		end

		survivors:heal(player, GameConfig.Survivor.MaxHealth, false)

		if inventory then
			for _, weaponSlot in { Enums.Slot.Primary, Enums.Slot.Secondary } do
				local itemId = inventory:getItem(player, weaponSlot)
				local definition = itemId and WeaponConfig.get(itemId)
				if definition then
					-- Re-giving the same weapon is the ammo pile: full magazine,
					-- full reserve, nothing else about the loadout disturbed.
					inventory:giveWeapon(player, itemId, definition.magSize, definition.reserveMax)
				end
			end
		end
	end

	local placer = Registry.find("ItemPlacer")
	if placer then
		placer:populateSection(record.model)
	end
end

--[[
	The team has sealed itself into `room`.

	Idempotent per room: a survivor who steps out and back in has not completed
	the chapter twice, and the Victory path in particular must fire exactly once.
]]
function LevelService:onSafeRoomReached(room: Model)
	if safeDirty then
		rebuildSafeRooms()
	end
	local record = roomByModel[room]
	if not record or record.completed then
		return
	end
	record.completed = true
	currentChapter = record.index

	self:_setDoor(record, false)
	self:_resupply(record)
	playUi(AudioConfig.UI.SafeRoomReached)

	local isFinal = record.order >= #safeRooms
	self.chapterChanged:fire(record.index, room, isFinal)

	if isFinal then
		self:_finishRound(Enums.RoundState.Victory, TEXT.Victory)
		return
	end

	self:_publishRound(roundState, { chapter = record.index, safeRoom = room, final = false })

	-- The door the team just came through closes; the one out of the far side of
	-- the room is whatever the next leg opens for them.
	local remaining = #safeRooms - record.order
	self:setObjective(if remaining <= 1 then TEXT.FinalLeg else TEXT.NextLeg)
end

-- ════════════════════════════════════════════════════════════════════════════
--  Round lifecycle
-- ════════════════════════════════════════════════════════════════════════════

function LevelService:_openStartRoom()
	if safeDirty then
		rebuildSafeRooms()
	end
	for _, record in safeRooms do
		self:_setDoor(record, record.order == 1)
	end
end

function LevelService:_beginRound()
	if roundState == Enums.RoundState.Starting or roundState == Enums.RoundState.InProgress then
		return
	end
	if #Players:GetPlayers() == 0 then
		return
	end

	roundGeneration += 1
	local generation = roundGeneration

	if safeDirty then
		rebuildSafeRooms()
	end
	sectionsDirty = true
	for _, record in safeRooms do
		record.completed = false
		self:_setDoor(record, false)
	end
	for part in panicTriggers do
		panicTriggers[part] = false
	end

	currentChapter = if safeRooms[1] then safeRooms[1].index else 0
	sawLivingSurvivor = false

	self:_publishRound(Enums.RoundState.Starting, { chapter = currentChapter })
	self:setObjective(TEXT.Lobby)

	task.delay(START_DELAY, function()
		if generation ~= roundGeneration then
			return
		end
		self:_openStartRoom()
		self:_publishRound(Enums.RoundState.InProgress, { chapter = currentChapter })
		self:setObjective(if #safeRooms > 2 then TEXT.FirstLeg else TEXT.FinalLeg)
	end)
end

--[[ Ends the round and schedules a reset. There is no round service in the
     contract, and a server that sits on a wipe screen forever is a server nobody
     can playtest twice, so the level owns the loop. ]]
function LevelService:_finishRound(state: string, text: string)
	if roundState == state then
		return
	end
	self:_publishRound(state, { chapter = currentChapter })
	self:setObjective(text)

	roundGeneration += 1
	local generation = roundGeneration

	task.delay(RESTART_DELAY, function()
		if generation ~= roundGeneration then
			return
		end
		local infected = Registry.find("InfectedService")
		if infected then
			infected:despawnAll()
		end

		local survivors = Registry.find("SurvivorService")
		local first = safeRooms[1]
		if survivors and first then
			local slot = 0
			for _, player in Players:GetPlayers() do
				slot += 1
				survivors:setSpawnCFrame(player, standingCFrame(first, slot))
				survivors:spawnSurvivor(player)
			end
		end

		roundState = Enums.RoundState.Lobby
		self:_beginRound()
	end)
end

--[[ Sets a joining player's first spawn to the start safe room. Connected in
     start(), which runs before the bootstrap's own PlayerAdded handler, so the
     CFrame is in place by the time SurvivorService calls LoadCharacter. ]]
function LevelService:_placePlayer(player: Player)
	if safeDirty then
		rebuildSafeRooms()
	end
	local first = safeRooms[1]
	local survivors = Registry.find("SurvivorService")
	if first and survivors then
		survivors:setSpawnCFrame(player, standingCFrame(first, #Players:GetPlayers()))
	end
end

-- ════════════════════════════════════════════════════════════════════════════
--  The shared tick
-- ════════════════════════════════════════════════════════════════════════════

--[[ Every survivor still in the fight, and where they are. Built once per tick
     and reused by the safe-room test and the panic test, because both want the
     same four positions and a character lookup is not free. ]]
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

	for part, fired in panicTriggers do
		if fired or not part.Parent then
			continue
		end
		local hit = false
		for _, position in tickPositions do
			if pointInside(part.CFrame, part.Size, position, 0) then
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
		-- would take the safe-room check down with it.
		local director = Registry.find("DirectorService")
		if director then
			director:triggerPanicEvent(part.Position)
		else
			warnOnce("nodirector", "a panic trigger fired but DirectorService is not registered")
		end

		local restore = objectiveText
		self:setObjective(TEXT.Panic)
		task.delay(DirectorConfig.PanicEvent.Duration, function()
			if objectiveText == TEXT.Panic then
				self:setObjective(restore)
			end
		end)
	end
end

function LevelService:_checkSafeRooms()
	if safeDirty then
		rebuildSafeRooms()
	end
	if #tickPositions == 0 then
		return
	end

	for _, record in safeRooms do
		if record.completed or record.index <= currentChapter then
			continue
		end
		local everyone = true
		for _, position in tickPositions do
			if not pointInside(record.box, record.size, position, SAFEROOM_MARGIN) then
				everyone = false
				break
			end
		end
		if everyone then
			self:onSafeRoomReached(record.model)
			return
		end
	end
end

--[[ Stocks the section the team is walking into. Deliberately late: ItemPlacer
     weights its roll by how the team is doing RIGHT NOW, so a section stocked at
     map load would hand a healthy team the medkit a hurt team needed. ]]
function LevelService:_checkSections(teamFlow: number)
	if sectionsDirty then
		rebuildSections()
	end
	local placer = Registry.find("ItemPlacer")
	if not placer then
		return
	end
	for _, section in sections do
		if not section.stocked and teamFlow + POPULATE_LOOKAHEAD >= section.flow then
			section.stocked = true
			if section.container.Parent then
				placer:populateSection(section.container)
			end
		end
	end
end

function LevelService:_step()
	if roundState ~= Enums.RoundState.InProgress then
		return
	end

	local living = gatherSurvivorPositions()
	if living > 0 then
		sawLivingSurvivor = true
	elseif sawLivingSurvivor and #Players:GetPlayers() > 0 then
		-- Nobody left standing and nobody in a closet to be let out of.
		self:_finishRound(Enums.RoundState.TeamWipe, TEXT.Wipe)
		return
	end

	self:_checkSafeRooms()
	self:_checkPanic()
	self:_checkSections(self:getSurvivorFlow())
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
			[TAG_SAFEROOM] = function()
				safeDirty = true
			end,
			[TAG_PANIC] = function()
				panicDirty = true
			end,
		}
	do
		serviceTrove:connect(CollectionService:GetInstanceAddedSignal(tag), invalidate)
		serviceTrove:connect(CollectionService:GetInstanceRemovedSignal(tag), invalidate)
	end
end

function LevelService:start()
	rebuildFlow()
	rebuildSpawnNodes()
	rebuildSafeRooms()
	rebuildPanicTriggers()

	print(
		string.format(
			"[LevelService] %d flow nodes over %.0f studs, %d spawn nodes, %d safe rooms",
			#flowPoints,
			flowTotal,
			#spawnNodes,
			#safeRooms
		)
	)

	serviceTrove:connect(Players.PlayerAdded, function(player)
		self:_placePlayer(player)
		self:_beginRound()
	end)
	for _, player in Players:GetPlayers() do
		self:_placePlayer(player)
	end

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

	self:_beginRound()
end

function LevelService:destroy()
	serviceTrove:destroy()
end

Registry.register("LevelService", LevelService)

return LevelService
