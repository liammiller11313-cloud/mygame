--!nonstrict
--[[
	MedkitService — the medkits that live in the map.

	Eleven per map, found by NAME rather than by tag: a folder called "Medkits"
	holding models called "Medkit 1" through "Medkit 11". Same contract as the
	ammo crates, for the same reason — a level designer names things anyway, and
	tagging is one more thing to forget.

	── WHY A CARRIED ITEM, NOT A STATION ────────────────────────────────────────
	A crate is a place you go. A medkit is a thing you HOLD, and that difference
	is the whole design. You pick one up and it rides on your back where the rest
	of the team can see it, which turns "who has a kit" into something you read
	off a silhouette rather than something you ask in chat. Then the interesting
	part: it is one heal, for anybody, and the decision of when to spend it — and
	on whom — is most of what makes a team feel like a team.

	── WHEN A SPAWN POINT REFILLS ───────────────────────────────────────────────
	Thirty seconds after the kit it produced is SPENT. Not thirty seconds after
	it is taken: carrying an unused kit around should not quietly restock the map
	behind you, or a team that hoards would end up with more medkits than a team
	that uses them.

	Four things can empty a Health slot — healing with the kit, dropping it,
	swapping it for another, and dying — and only the first is a spend. The other
	three leave the kit somewhere in the world, so refilling on those would print
	medkits. InventoryService.itemConsumed fires for the first and only the first,
	which is why this listens to that rather than to the slot change.

	The one case that needs a safety net is a carrier who leaves the server: the
	kit goes with them, nothing is consumed, and the map is one medkit poorer for
	the rest of the round. That refills too, on the same clock.
]]

local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attributes = require(Shared.Net.Attributes)
local Enums = require(Shared.Enums)
local MapConfig = require(Shared.Config.MapConfig)
local Registry = require(Shared.Util.Registry)
local Trove = require(Shared.Util.Trove)

local KIT = MapConfig.Medkits
local PICKUP = Attributes.Pickup

local MedkitService = {}

local serviceTrove = Trove.new()

--[[ One spawn point. `template` is a pristine copy parked outside the world, so
     a refill is a clone rather than an attempt to resurrect the instance
     InventoryService destroyed when somebody picked it up. ]]
type Spot = {
	index: number,
	name: string,
	cframe: CFrame,
	--[[ The folder the kit was found in, and where both the ghost and every
	     refill go back. It has to be this rather than Workspace: everything
	     inside the live map is destroyed when the map unloads, and a ghost
	     parented to the world root would outlive its map and stack up one copy
	     per round for the life of the server. ]]
	folder: Instance,
	template: Model,
	live: Model?, -- the kit currently sitting here, if any
	ghost: Model?, -- the faint outline shown while it is gone
	refillAt: number, -- 0 = not waiting on a clock
	carrier: Player?, -- who took it, until they spend or lose it
}

local spots: { Spot } = {}
local parkFolder: Folder? = nil
local accumulator = 0

-- Half a second. The respawn is measured in tens of seconds, so a kit arriving
-- a quarter-second late is not something anybody can perceive, and one timer for
-- eleven spots beats eleven task.delays that a map swap then has to chase down.
local TICK_INTERVAL = 0.5

local function serverNow(): number
	return Workspace:GetServerTimeNow()
end

local function park(): Folder
	if parkFolder and parkFolder.Parent then
		return parkFolder
	end
	local folder = Instance.new("Folder")
	folder.Name = "FL_MedkitTemplates"
	folder.Parent = ServerStorage
	parkFolder = folder
	serviceTrove:add(folder)
	return folder
end

--[[ Everything a pickup has to be for the rest of the game to recognise it.
     SurvivorService routes anything carrying Pickup.Slot down the instant-pickup
     path, and InventoryService reads the item id off the same model. ]]
local function dressAsPickup(model: Model, index: number)
	model:SetAttribute(PICKUP.Slot, Enums.Slot.Health)
	model:SetAttribute(PICKUP.ItemId, Enums.HealthItem.Medkit)
	model:SetAttribute("FL_MedkitSpot", index)
	CollectionService:AddTag(model, KIT.Tag)

	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") then
			--[[ Anchored, not welded: a kit that can be shot across the room is a
			     kit somebody loses under the geometry. CanCollide stays off so it
			     never blocks a doorway, and CanQuery stays ON because the interact
			     prompt finds it with a raycast. ]]
			part.Anchored = true
			part.CanCollide = false
			part.CanTouch = false
		end
	end
end

--[[ The faint outline left where a kit was. Cloned from the template and stripped
     of everything that makes it a pickup, so nothing can interact with it and
     nothing downstream mistakes it for the real thing. ]]
local function makeGhost(spot: Spot): Model?
	if not KIT.LeaveGhost then
		return nil
	end
	local ghost = spot.template:Clone()
	ghost.Name = spot.name .. " (taken)"
	for _, part in ghost:GetDescendants() do
		if part:IsA("BasePart") then
			part.Anchored = true
			part.CanCollide = false
			part.CanQuery = false
			part.CanTouch = false
			part.Transparency = KIT.GhostTransparency
			part.CastShadow = false
		end
	end
	ghost:PivotTo(spot.cframe)
	ghost.Parent = spot.folder
	return ghost
end

local function clearGhost(spot: Spot)
	if spot.ghost then
		spot.ghost:Destroy()
		spot.ghost = nil
	end
end

--[[ Puts a kit back at a spot. Idempotent: called from the tick, so it has to be
     safe to reach with a kit already there. Returns false when the spot's folder
     has gone, which means the map it belonged to was unloaded and this spot is
     about to be rebuilt out of existence anyway. ]]
local function place(spot: Spot): boolean
	if spot.live and spot.live.Parent then
		return true
	end
	if not spot.folder or not spot.folder.Parent then
		return false
	end
	clearGhost(spot)

	local model = spot.template:Clone()
	model.Name = spot.name
	model:PivotTo(spot.cframe)
	dressAsPickup(model, spot.index)
	model.Parent = spot.folder

	spot.live = model
	spot.refillAt = 0
	spot.carrier = nil
	return true
end

--[[ Marks a spot empty. The clock does not start here — `taken` is the state
     between somebody picking the kit up and them doing something with it, which
     may be the rest of the round. ]]
local function markTaken(spot: Spot, carrier: Player?)
	spot.live = nil
	spot.carrier = carrier
	spot.refillAt = 0
	if not spot.ghost then
		spot.ghost = makeGhost(spot)
	end
end

local function startRefill(spot: Spot)
	if spot.live or spot.refillAt > 0 then
		return
	end
	spot.carrier = nil
	spot.refillAt = serverNow() + KIT.RespawnSeconds
end

--[[ Through MapConfig.folderMatches, exactly like the crate lookup — and now
     literally the same function rather than a second copy of the same idea.
     "Medkits", "medkits", "Med Kits" and "Medkit" all find the folder, because
     the alternative is somebody losing an hour to a capital letter. ]]
local function findFolder(root: Instance): Instance?
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("Folder") or descendant:IsA("Model") then
			if MapConfig.folderMatches(descendant.Name, KIT.FolderName) then
				return descendant
			end
		end
	end
	return nil
end

-- Trailing digits in the name. "Medkit 7" -> 7, and anything without a number
-- keeps its discovery order rather than being dropped.
local function indexFromName(name: string, fallback: number): number
	local digits = string.match(name, "(%d+)%s*$")
	return tonumber(digits) or fallback
end

-- ── public API ──────────────────────────────────────────────────────────────

--[[ Rediscovers every medkit in whatever map is live. Called on boot and on
     every map swap; the previous map's spots are gone with the map, so this
     starts from nothing each time rather than trying to reconcile. ]]
function MedkitService:rebuild(): number
	for _, spot in spots do
		clearGhost(spot)
		if spot.template then
			spot.template:Destroy()
		end
	end
	table.clear(spots)

	local mapService = Registry.find("MapService")
	local root = mapService and mapService:getCurrentRoot() or Workspace
	if not root then
		return 0
	end

	local folder = findFolder(root)
	if not folder then
		warn(
			string.format(
				"[MedkitService] no %q folder in the live map — there will be no medkits to find. "
					.. "Add one holding models named %q through %q. "
					.. "The map's top-level folders are: %s",
				KIT.FolderName,
				"Medkit 1",
				"Medkit " .. KIT.ExpectedCount,
				MapConfig.folderNamesIn(root)
			)
		)
		return 0
	end

	local store = park()
	local order = 0

	for _, child in folder:GetChildren() do
		if not child:IsA("Model") and not child:IsA("BasePart") then
			continue
		end
		order += 1

		-- A kit may be a Model or a lone Part; wrap a part so everything below
		-- only ever deals with a Model.
		local model: Model
		if child:IsA("Model") then
			model = child
		else
			local wrapper = Instance.new("Model")
			wrapper.Name = child.Name
			wrapper.Parent = folder
			child.Parent = wrapper
			wrapper.PrimaryPart = child
			model = wrapper
		end

		--[[ The template is taken BEFORE the live copy is dressed as a pickup, so
		     a refill starts from the model the designer built rather than from
		     one already carrying pickup attributes and a tag. ]]
		local template = model:Clone()
		template.Parent = store

		local spot: Spot = {
			index = indexFromName(model.Name, order),
			name = model.Name,
			cframe = model:GetPivot(),
			folder = folder,
			template = template,
			live = model,
			ghost = nil,
			refillAt = 0,
			carrier = nil,
		}
		dressAsPickup(model, spot.index)
		table.insert(spots, spot)
	end

	table.sort(spots, function(a, b)
		return a.index < b.index
	end)

	if #spots > 0 then
		print(string.format("[MedkitService] %d medkit spawn point(s) in the live map", #spots))
	end
	return #spots
end

--[[ The kit a carried medkit came from, or nil. Used by the carry visual so the
     thing on a survivor's back is the model the designer built rather than a
     generic stand-in. ]]
function MedkitService:getCarryTemplate(): Model?
	for _, spot in spots do
		if spot.template and spot.template.Parent then
			return spot.template
		end
	end
	return nil
end

--[[ How many kits are on the floor right now. The Director does not use this
     yet; it is here because "how much healing is left in the map" is exactly the
     kind of thing a difficulty system eventually wants to know. ]]
function MedkitService:getAvailableCount(): number
	local count = 0
	for _, spot in spots do
		if spot.live and spot.live.Parent then
			count += 1
		end
	end
	return count
end

function MedkitService:_onPickedUp(player: Player, slot: string, _itemId: string, model: Instance)
	if slot ~= Enums.Slot.Health then
		return
	end
	local index = model:GetAttribute("FL_MedkitSpot")
	if typeof(index) ~= "number" then
		return
	end
	for _, spot in spots do
		if spot.index == index and spot.live == model then
			markTaken(spot, player)
			return
		end
	end
end

function MedkitService:_onConsumed(player: Player, slot: string, _itemId: string)
	if slot ~= Enums.Slot.Health then
		return
	end
	for _, spot in spots do
		if spot.carrier == player then
			startRefill(spot)
			-- Only one: a survivor can carry exactly one kit, so the first spot
			-- that names them is the one that just emptied.
			return
		end
	end
end

function MedkitService:_step()
	local now = serverNow()

	for _, spot in spots do
		--[[ A carrier who left took the kit with them and will never spend it.
		     Without this the map loses a medkit per disconnect for the rest of
		     the round, which over seventeen minutes is most of them. ]]
		if spot.carrier and spot.carrier.Parent == nil then
			startRefill(spot)
		end

		if spot.refillAt > 0 and now >= spot.refillAt then
			place(spot)
		end
	end
end

-- ── lifecycle ───────────────────────────────────────────────────────────────

function MedkitService:init()
	-- Nothing to do until a map is live; rebuild() is driven from start().
end

function MedkitService:start()
	local mapService = Registry.find("MapService")
	if mapService and mapService.mapChanged then
		serviceTrove:add(mapService.mapChanged:connect(function()
			self:rebuild()
		end))
	end

	local inventory = Registry.find("InventoryService")
	if inventory then
		if inventory.pickedUp then
			serviceTrove:add(inventory.pickedUp:connect(function(...)
				self:_onPickedUp(...)
			end))
		end
		if inventory.itemConsumed then
			serviceTrove:add(inventory.itemConsumed:connect(function(...)
				self:_onConsumed(...)
			end))
		end
	else
		warn("[MedkitService] no InventoryService; medkit spawn points will never refill")
	end

	--[[ A carrier leaving is picked up by the tick rather than by
	     PlayerRemoving. The tick already has to cope with a carrier who is gone
	     without that event ever firing — a teleport between places, a session
	     that dies — so one rule in one place beats two that can disagree. ]]

	self:rebuild()

	serviceTrove:connect(RunService.Heartbeat, function(dt: number)
		accumulator += dt
		if accumulator < TICK_INTERVAL then
			return
		end
		accumulator = 0
		self:_step()
	end)
end

function MedkitService:destroy()
	serviceTrove:destroy()
	table.clear(spots)
end

Registry.register("MedkitService", MedkitService)

return MedkitService
