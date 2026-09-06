--!nonstrict
--[[
	MapItemService — the items that live in the map.

	Medkits, pain pills and adrenaline shots. One contract for all three, laid
	out in MapConfig.MapItems: a folder named after the family, holding models
	numbered from one. Found by NAME rather than by tag, same as the ammo crates
	and for the same reason — a level designer names things anyway, and tagging
	is one more thing to forget.

	── WHY THE MAP AND NOT AN ASSET FOLDER ─────────────────────────────────────
	Two things fall out of doing it this way, and the second is the one that
	matters.

	The obvious one is placement: eleven kits, nine bottles and seven shots
	standing exactly where somebody decided they should stand, rather than
	wherever a spawner guessed. A health item you learn the location of is a
	health item you can plan a round around.

	The other is the ART. PlaceholderFactory copies whatever is standing in the
	live map instead of building its own version, so an item the Director drops
	on a pad partway through a wave is the same object the team has been walking
	past all round. Change the model in the map and the whole game changes with
	it — there is no second copy to keep in sync, and nothing that can drift.

	── WHEN A SPAWN POINT REFILLS ───────────────────────────────────────────────
	On the SPEND, and not before. Four things can empty a slot — using the item,
	dropping it, swapping it for another, and dying — and only the first destroys
	anything. The other three leave it lying in the world, so refilling on those
	would print items: carrying an unused kit around must not quietly restock the
	map behind you, or a team that hoards ends up with more than a team that
	uses. InventoryService.itemConsumed fires for the first and only the first,
	which is why this listens to that rather than to the slot change.

	The one case that needs a safety net is a carrier who leaves the server: the
	item goes with them, nothing is consumed, and the map is one poorer for the
	rest of the round. That refills too, on the same clock.
]]

local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attributes = require(Shared.Net.Attributes)
local MapConfig = require(Shared.Config.MapConfig)
local Registry = require(Shared.Util.Registry)
local Trove = require(Shared.Util.Trove)

--[[ Stamped on every model this service stands up, so a pickup coming back
     through InventoryService can be traced to the exact spot it left. Two
     attributes rather than one because both pill families share a Slot: the
     family narrows it to a list, the index to a spot in that list. ]]
local FAMILY_ATTRIBUTE = "FL_MapItemFamily"
local SPOT_ATTRIBUTE = "FL_MapItemSpot"

local MapItemService = {}

local serviceTrove = Trove.new()

--[[ One spawn point. `template` is a pristine copy parked outside the world, so
     a refill is a clone rather than an attempt to resurrect the instance
     InventoryService destroyed when somebody picked it up. ]]
type Spot = {
	family: MapConfig.MapItemFamily,
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

--[[ Every spot in the live map, all families in one list. One list rather than
     one per family because every consumer of it is a linear walk anyway and
     twenty-seven entries is nothing — and because the alternative is three
     places to forget to clear on a map swap. ]]
local spots: { Spot } = {}
local parkFolder: Folder? = nil
local accumulator = 0

-- Half a second. The respawn is measured in tens of seconds, so an item arriving
-- a quarter-second late is not something anybody can perceive, and one timer for
-- twenty-seven spots beats twenty-seven task.delays that a map swap then has to
-- chase down.
local TICK_INTERVAL = 0.5

local function serverNow(): number
	return Workspace:GetServerTimeNow()
end

local function park(): Folder
	if parkFolder and parkFolder.Parent then
		return parkFolder
	end
	local folder = Instance.new("Folder")
	folder.Name = "FL_MapItemTemplates"
	folder.Parent = ServerStorage
	parkFolder = folder
	serviceTrove:add(folder)
	return folder
end

--[[ Everything a pickup has to be for the rest of the game to recognise it.
     SurvivorService routes anything carrying Pickup.Slot down the instant-pickup
     path, and InventoryService reads the item id off the same model. ]]
local function dressAsPickup(model: Model, family: MapConfig.MapItemFamily, index: number)
	Attributes.markPickup(model, family.slot, family.itemId)
	model:SetAttribute(FAMILY_ATTRIBUTE, family.key)
	model:SetAttribute(SPOT_ATTRIBUTE, index)
	CollectionService:AddTag(model, family.tag)

	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") then
			--[[ Anchored, not welded: an item that can be shot across the room is
			     an item somebody loses under the geometry. CanCollide off so it
			     never blocks a doorway.

			     CanQuery is SET rather than left alone, and that is the one line
			     here that is about supplied models rather than about pickups. Both
			     ways the prompt finds a target — the crosshair raycast and the
			     arm's-reach sweep — skip a part with it off, so an imported mesh
			     that happens to have it cleared is an item nobody can pick up, with
			     nothing on screen to say why. A pill bottle is small enough that a
			     player would read that as their own aim. ]]
			part.Anchored = true
			part.CanCollide = false
			part.CanTouch = false
			part.CanQuery = true
		end
	end
end

--[[ The faint outline left where a kit was. Cloned from the template and stripped
     of everything that makes it a pickup, so nothing can interact with it and
     nothing downstream mistakes it for the real thing. ]]
local function makeGhost(spot: Spot): Model?
	if not spot.family.leaveGhost then
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
			part.Transparency = spot.family.ghostTransparency
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
	dressAsPickup(model, spot.family, spot.index)
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
	spot.refillAt = serverNow() + spot.family.respawnSeconds
end

--[[ Through MapConfig.folderMatches, exactly like the crate lookup — and now
     literally the same function rather than a second copy of the same idea.
     "Medkits", "medkits", "Med Kits" and "Medkit" all find the folder, because
     the alternative is somebody losing an hour to a capital letter. ]]
local function findFolder(root: Instance, folderName: string): Instance?
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("Folder") or descendant:IsA("Model") then
			if MapConfig.folderMatches(descendant.Name, folderName) then
				return descendant
			end
		end
	end
	return nil
end

-- Trailing digits in the name. "Adrenaline Shot 7" -> 7, and anything without a
-- number keeps its discovery order rather than being dropped.
local function indexFromName(name: string, fallback: number): number
	local digits = string.match(name, "(%d+)%s*$")
	return tonumber(digits) or fallback
end

-- ── public API ──────────────────────────────────────────────────────────────

--[[ Stands up every spot of one family. Returns how many it found; zero with no
     warning is impossible here, because a family whose folder is missing is a
     family whose items simply do not exist in this map and somebody has to be
     told which one. ]]
local function buildFamily(root: Instance, family: MapConfig.MapItemFamily): number
	local folder = findFolder(root, family.folderName)
	if not folder then
		warn(
			string.format(
				"[MapItemService] no %q folder in the live map — there will be no %s to find. "
					.. "Add one holding models named %q through %q. "
					.. "The map's top-level folders are: %s",
				family.folderName,
				family.itemId,
				family.modelName .. " 1",
				family.modelName .. " " .. family.expectedCount,
				MapConfig.folderNamesIn(root)
			)
		)
		return 0
	end

	local store = park()
	local order = 0
	local found = 0

	for _, child in folder:GetChildren() do
		if not child:IsA("Model") and not child:IsA("BasePart") then
			continue
		end
		order += 1

		-- An item may be a Model or a lone Part; wrap a part so everything below
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
		     one already carrying pickup attributes and a tag. It is also what
		     PlaceholderFactory copies for a Director-placed one. ]]
		local template = model:Clone()
		template.Parent = store

		local spot: Spot = {
			family = family,
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
		dressAsPickup(model, family, spot.index)
		table.insert(spots, spot)
		found += 1
	end

	return found
end

--[[
	Whether a scan has actually happened against a live map.

	Not the same question as "does this service exist", and the difference is a
	whole class of false warning. Every module in the game is required — and so
	registers — before ANY module's init() runs, but this service does not scan
	until its start(), a whole phase later. So there is a window in which
	`Registry.find("MapItemService")` answers yes and every getTemplate answers
	nil, and anything that reads the second as "this map places none" is wrong
	about a map that is full of them. PlaceholderFactory's boot prewarm sits
	squarely in that window; see the guard in buildPickup.

	Stays false when rebuild bails for want of a map root, because that is "could
	not look" and not "looked and found nothing".
]]
local scanned = false

--[[ Rediscovers every map item in whatever map is live. Called on boot and on
     every map swap; the previous map's spots are gone with the map, so this
     starts from nothing each time rather than trying to reconcile. ]]
function MapItemService:rebuild(): number
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

	local report: { string } = {}
	for _, family in MapConfig.MapItems do
		local found = buildFamily(root, family)
		if found > 0 then
			table.insert(report, string.format("%s x%d", family.key, found))
		end
	end
	--[[ Set here rather than at the end: everything below is sorting and
	     reporting, and a caller asking "have you looked" during that is owed a
	     yes. It is never unset — a later map with no items is a real answer. ]]
	scanned = true

	--[[ By family first and then by index, so the whole list stays in a stable
	     order a log line can be read against. Nothing depends on the order for
	     correctness — every lookup matches on both attributes. ]]
	table.sort(spots, function(a, b)
		if a.family.key ~= b.family.key then
			return a.family.key < b.family.key
		end
		return a.index < b.index
	end)

	if #spots > 0 then
		print(
			string.format(
				"[MapItemService] %d spawn point(s) in the live map: %s",
				#spots,
				table.concat(report, ", ")
			)
		)
	end
	return #spots
end

--[[ Whether this service has scanned a live map yet, so a caller can tell a
     genuine "this map places none" from a "nobody has looked". See `scanned`. ]]
function MapItemService:hasScanned(): boolean
	return scanned
end

--[[
	A pristine copy of one item's map model, or nil when this map places none.

	Two callers, both of which want the map's own art rather than a stand-in: the
	carry visual, so the thing on a survivor's back is the model the designer
	built, and PlaceholderFactory, so an item the Director drops on a pad matches
	the ones lying around the level.

	The FIRST template of that family, not a random one. A family's models are
	meant to be the same object placed in several rooms, and picking between them
	per pad would make the pads the odd ones out if they ever are not.
]]
function MapItemService:getTemplate(itemId: string): Model?
	for _, spot in spots do
		if spot.family.itemId == itemId and spot.template and spot.template.Parent then
			return spot.template
		end
	end
	return nil
end

--[[ How many of an item are on the floor right now, or of everything when asked
     for nothing in particular. The Director does not use this yet; it is here
     because "how much healing is left in the map" is exactly the kind of thing a
     difficulty system eventually wants to know. ]]
function MapItemService:getAvailableCount(itemId: string?): number
	local count = 0
	for _, spot in spots do
		if itemId == nil or spot.family.itemId == itemId then
			if spot.live and spot.live.Parent then
				count += 1
			end
		end
	end
	return count
end

function MapItemService:_onPickedUp(player: Player, _slot: string, _itemId: string, model: Instance)
	local key = model:GetAttribute(FAMILY_ATTRIBUTE)
	local index = model:GetAttribute(SPOT_ATTRIBUTE)
	if typeof(key) ~= "string" or typeof(index) ~= "number" then
		return -- not one of ours; a Director-placed pad item, or a dropped one
	end

	--[[ The spot this model came from is found by family AND index. Everything
	     the player was carrying in the SAME SLOT is then let go of, which is a
	     wider net than the same family on purpose: a slot holds one item, so
	     picking anything up into it means whatever was there is now on the floor.

	     Family alone was enough while the two pill types were the only pair
	     sharing a slot and swapping between them was rare. The throwables broke
	     it: molotovs and pipe bombs are different families in the same slot and
	     players trade one for the other constantly, so a molotov spot went on
	     naming somebody who had not held a molotov for ten minutes — and printed
	     a second one the moment they disconnected. ]]
	local taken: Spot? = nil
	for _, spot in spots do
		if spot.family.key == key and spot.index == index and spot.live == model then
			taken = spot
			markTaken(spot, player)
			break
		end
	end
	if not taken then
		return
	end

	for _, spot in spots do
		if spot ~= taken and spot.family.slot == taken.family.slot and spot.carrier == player then
			spot.carrier = nil
		end
	end
end

function MapItemService:_onConsumed(player: Player, _slot: string, itemId: string)
	--[[ Matched on the item id, not the slot. Pain pills and adrenaline share
	     Slot.Pills, so a slot match would refill whichever of the two spots
	     happened to come first in the list — the wrong bottle, in the wrong
	     room, on the wrong clock. ]]
	for _, spot in spots do
		if spot.carrier == player and spot.family.itemId == itemId then
			startRefill(spot)
			-- Only one: a survivor carries at most one of any item, so the first
			-- spot that names them is the one that just emptied.
			return
		end
	end
end

function MapItemService:_step()
	local now = serverNow()

	for _, spot in spots do
		--[[ A carrier who left took the item with them and will never spend it.
		     Without this the map loses one per disconnect for the rest of the
		     round, which over seventeen minutes is most of them. ]]
		if spot.carrier and spot.carrier.Parent == nil then
			startRefill(spot)
		end

		if spot.refillAt > 0 and now >= spot.refillAt then
			place(spot)
		end
	end
end

-- ── lifecycle ───────────────────────────────────────────────────────────────

function MapItemService:init()
	-- Nothing to do until a map is live; rebuild() is driven from start().
end

function MapItemService:start()
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
		warn("[MapItemService] no InventoryService; map item spawn points will never refill")
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

function MapItemService:destroy()
	serviceTrove:destroy()
	table.clear(spots)
end

Registry.register("MapItemService", MapItemService)

return MapItemService
