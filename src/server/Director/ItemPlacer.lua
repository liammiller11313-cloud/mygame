--!nonstrict
--[[
	ItemPlacer — what the Director decides you find.

	This is the quietest difficulty adjustment in the whole design and probably
	the most effective one. A team that is hurting finds pills in the next room;
	a team that is fine finds another gun and some ammo. Nobody notices it
	happening, everybody notices that the game seems to know when they are in
	trouble.

	The roll is a cascade of independent gates rather than a partition, because
	`DirectorConfig.ItemPlacement`'s base chances add up to more than one: each
	number is "the chance THIS spawn is a health item / pills / a throwable",
	tested in that order, and anything that falls through all three becomes a
	weapon — which is the ammo case. The hurt bonus is added to the first gate
	only, per its name, and pills sitting second in the cascade means a hurt team
	that missed the medkit roll still has a very good chance at the next best
	thing.

	Placement itself is dumb on purpose: FL_ItemSpawn parts are placed by hand by
	whoever built the map, and an item that appears somewhere a level designer
	did not put a pad is an item nobody finds.

	In wave mode there are no sections to walk into, so the BREATHER is when the
	map restocks — see restockForBreather. That timing is if anything better than
	the campaign one: the roll reads the team's health immediately after the wave
	that just hurt them, so what appears on the pads answers the fight they
	actually had rather than the one they are about to have.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attributes = require(Shared.Net.Attributes)
local DirectorConfig = require(Shared.Config.DirectorConfig)
local Enums = require(Shared.Enums)
local GameConfig = require(Shared.Config.GameConfig)
local Registry = require(Shared.Util.Registry)
local WeaponConfig = require(Shared.Config.WeaponConfig)

local PLACEMENT = DirectorConfig.ItemPlacement

local ITEM_SPAWN_TAG = "FL_ItemSpawn"
local SLOT_ATTRIBUTE = "FL_Slot"

--[[
	Team health at or below this fraction earns the full HurtTeamHealthItemBonus,
	and the bonus ramps in linearly from full health. Derived from the game's own
	definition of "hurt" rather than invented: below GameConfig's HurtThreshold a
	survivor limps and every infected can hear them, so a team averaging that is
	exactly the team the config means by "the team average is low".
]]
local HURT_FRACTION = GameConfig.Survivor.HurtThreshold / GameConfig.Survivor.MaxHealth

local ItemPlacer = {}

local random = Random.new()

local warned: { [string]: boolean } = {}

local function warnOnce(key: string, message: string)
	if warned[key] then
		return
	end
	warned[key] = true
	warn("[ItemPlacer] " .. message)
end

local function pick<T>(list: { T }): T?
	local count = #list
	if count == 0 then
		return nil
	end
	return list[random:NextInteger(1, count)]
end

--[[
	Pad -> the pickup model currently sitting on it. A pad whose item has been
	taken is free again, so re-entering a section (or a level that repopulates at
	a checkpoint) never stacks two medkits on one shelf.

	Module state rather than an init() field on purpose: LevelService builds the
	map during its own lifecycle, which runs BEFORE this module's would, and a
	populateSection call from there must not find a half-built service.
]]
local occupied: { [BasePart]: Model } = {}

-- ════════════════════════════════════════════════════════════════════════════
--  Weapon classes
--
--  Picking uniformly from every id in a slot is what put four rifles in a row
--  on a map. The Primary slot holds five rifles, five SMGs, two marksman rifles
--  and exactly one shotgun, so a uniform roll is a rifle 38% of the time and
--  the shotgun — a whole class carried by one gun — shows up on one pad in
--  thirteen.
--
--  So the roll draws a CLASS first, from a deck dealt without replacement. Over
--  any four Primary placements the map offers a shotgun, an SMG, a rifle and a
--  marksman rifle in some order, and the team gets a choice of weapon types
--  instead of a choice of rifles. The classes themselves are discovered from
--  WeaponConfig, so a new class is placeable the moment it is defined.
-- ════════════════════════════════════════════════════════════════════════════

local classesBySlot: { [string]: { string } } = {}
local idsBySlotClass: { [string]: { [string]: { string } } } = {}

do
	local seen: { [string]: { [string]: boolean } } = {}
	for _, definition in WeaponConfig.all() do
		local slot = definition.slot
		local slotSeen = seen[slot]
		if not slotSeen then
			slotSeen = {}
			seen[slot] = slotSeen
			classesBySlot[slot] = {}
			idsBySlotClass[slot] = {}
		end
		if slotSeen[definition.class] then
			continue
		end
		slotSeen[definition.class] = true
		table.insert(classesBySlot[slot], definition.class)

		-- idsForClass allocates and sorts. WeaponConfig is frozen, so this runs
		-- once per class at load rather than on every placement roll. The slot
		-- filter matters for a class that could legally span two slots.
		local ids = {}
		for _, id in WeaponConfig.idsForClass(definition.class) do
			local candidate = WeaponConfig.get(id)
			if candidate and candidate.slot == slot then
				table.insert(ids, id)
			end
		end
		idsBySlotClass[slot][definition.class] = ids
	end

	-- Sorted so the deck is dealt from a stable list; the shuffle owns the order.
	for _, classes in classesBySlot do
		table.sort(classes)
	end
end

--[[ One deck per slot, reshuffled when it runs out. Module state for the same
     reason `occupied` is: a map may be stocked before this module's lifecycle
     would have run. ]]
local decks: { [string]: { string } } = {}

local function drawClass(slot: string): string?
	local classes = classesBySlot[slot]
	if not classes or #classes == 0 then
		return nil
	end

	local deck = decks[slot]
	if not deck or #deck == 0 then
		deck = table.clone(classes)
		for index = #deck, 2, -1 do
			local swap = random:NextInteger(1, index)
			deck[index], deck[swap] = deck[swap], deck[index]
		end
		decks[slot] = deck
	end
	return table.remove(deck)
end

-- ════════════════════════════════════════════════════════════════════════════
--  The roll
-- ════════════════════════════════════════════════════════════════════════════

--[[ 0 when the team is healthy, 1 once its average has fallen to the hurt
     threshold. Everything below that stays at 1: there is nothing more the
     Director can do for you than hand you the best item it has. ]]
function ItemPlacer:_hurtFraction(): number
	local survivors = Registry.find("SurvivorService")
	if not survivors or typeof(survivors.getTeamHealthFraction) ~= "function" then
		return 0
	end
	local ok, fraction = pcall(survivors.getTeamHealthFraction, survivors)
	if not ok or typeof(fraction) ~= "number" then
		return 0
	end
	local span = 1 - HURT_FRACTION
	if span <= 0 then
		return if fraction <= HURT_FRACTION then 1 else 0
	end
	return math.clamp((1 - fraction) / span, 0, 1)
end

--[[ True when somebody is dead and waiting on a defibrillator. A team in that
     state finding a defib instead of a medkit is the single most valuable item
     swap the Director can make. ]]
local function someoneAwaitsRescue(): boolean
	local survivors = Registry.find("SurvivorService")
	if not survivors or typeof(survivors.getAwaitingRescue) ~= "function" then
		return false
	end
	local ok, waiting = pcall(survivors.getAwaitingRescue, survivors)
	return ok and typeof(waiting) == "table" and #waiting > 0
end

--[[ Which slot this pad should hold, weighted by how the team is doing. ]]
function ItemPlacer:_rollSlot(hurt: number): string
	if random:NextNumber() < PLACEMENT.BaseHealthItemChance + PLACEMENT.HurtTeamHealthItemBonus * hurt then
		return Enums.Slot.Health
	end
	if random:NextNumber() < PLACEMENT.BasePillChance then
		return Enums.Slot.Pills
	end
	if random:NextNumber() < PLACEMENT.BaseThrowableChance then
		return Enums.Slot.Throwable
	end
	return Enums.Slot.Primary
end

--[[ Which item within a slot. Weapons come from WeaponConfig so a new gun is
     placeable the moment it is defined, with no second list to keep in sync. ]]
function ItemPlacer:_rollItem(slot: string): string?
	if slot == Enums.Slot.Health then
		if someoneAwaitsRescue() then
			return Enums.HealthItem.Defibrillator
		end
		return Enums.HealthItem.Medkit
	elseif slot == Enums.Slot.Pills then
		return pick({ Enums.PillItem.PainPills, Enums.PillItem.Adrenaline })
	elseif slot == Enums.Slot.Throwable then
		return pick({ Enums.Throwable.PipeBomb, Enums.Throwable.Molotov, Enums.Throwable.BileJar })
	end

	-- Class first, then a gun inside it. See the Weapon classes section above.
	local class = drawClass(slot)
	local ids = class and idsBySlotClass[slot][class]
	if ids then
		return pick(ids)
	end
	-- A slot WeaponConfig has nothing for. Falling through to the flat list keeps
	-- a hand-authored FL_Slot from silently placing nothing.
	return pick(WeaponConfig.idsForSlot(slot))
end

-- ════════════════════════════════════════════════════════════════════════════
--  Placement
-- ════════════════════════════════════════════════════════════════════════════

--[[
	Builds one pickup and puts it in the world.

	`position` is a point ON THE GROUND — the same convention InfectedService
	uses — and the model is lifted by half its own bounding box so it rests on
	the surface rather than sinking into it.

	The attributes written here are the entire pickup contract: SurvivorService
	recognises a pickup by `FL_Slot` alone, and InventoryService reads the id and
	the ammo off the model when someone takes it.
]]
function ItemPlacer:spawnPickup(slot: string, itemId: string, position: Vector3): Model?
	if typeof(slot) ~= "string" or Enums.Slot[slot] == nil then
		warnOnce("slot:" .. tostring(slot), string.format("spawnPickup: %q is not a slot", tostring(slot)))
		return nil
	end
	if typeof(itemId) ~= "string" or itemId == "" or typeof(position) ~= "Vector3" then
		return nil
	end

	local factory = Registry.find("PlaceholderFactory")
	if not factory then
		warnOnce("nofactory", "PlaceholderFactory is not registered; no pickups can be built")
		return nil
	end

	local ok, model = pcall(factory.buildPickup, factory, slot, itemId)
	if not ok or typeof(model) ~= "Instance" or not model:IsA("Model") then
		warnOnce(
			"build:" .. slot .. ":" .. itemId,
			string.format("buildPickup(%q, %q) failed: %s", slot, itemId, tostring(model))
		)
		return nil
	end

	model:SetAttribute(Attributes.Pickup.Slot, slot)
	model:SetAttribute(Attributes.Pickup.ItemId, itemId)

	-- A placed weapon arrives full. Half a magazine on the floor is a rule that
	-- reads as a bug to everyone who has not seen the code.
	local weapon = WeaponConfig.get(itemId)
	if weapon then
		model:SetAttribute(Attributes.Pickup.Ammo, weapon.magSize)
		model:SetAttribute(Attributes.Pickup.Reserve, weapon.reserveMax)
	end

	local _, size = model:GetBoundingBox()
	model:PivotTo(CFrame.new(position + Vector3.new(0, size.Y * 0.5, 0)))
	model.Parent = Workspace

	return model
end

--[[ Every FL_ItemSpawn pad inside a section that is not already holding an
     item. A pad whose model was picked up or destroyed is free again. ]]
function ItemPlacer:_availablePads(sectionFolder: Instance): { BasePart }
	local pads = {}
	for _, tagged in CollectionService:GetTagged(ITEM_SPAWN_TAG) do
		if not tagged:IsA("BasePart") then
			continue
		end
		if tagged ~= sectionFolder and not tagged:IsDescendantOf(sectionFolder) then
			continue
		end
		local existing = occupied[tagged]
		if existing then
			if existing.Parent then
				continue
			end
			occupied[tagged] = nil
		end
		table.insert(pads, tagged)
	end
	return pads
end

--[[
	Fills some of `pads`, returning how many pickups actually landed.

	How MANY is health-weighted too, not just what: the config's range is the
	whole span, and a hurt team's roll starts at the top of it. A healthy team
	rolls the full Min..Max, a team at the hurt threshold rolls Max..Max. Same
	idea as the item roll — the amount is as quiet a lever as the kind, and it
	costs no tuning number the config does not already carry.
]]
function ItemPlacer:_stock(pads: { BasePart }): number
	-- Fisher-Yates: without it the first pads in tag order are stocked every
	-- time, and a replay of the same map puts every item back in the same room.
	for index = #pads, 2, -1 do
		local swap = random:NextInteger(1, index)
		pads[index], pads[swap] = pads[swap], pads[index]
	end

	local hurt = self:_hurtFraction()
	local span = PLACEMENT.MaxItemsPerSection - PLACEMENT.MinItemsPerSection
	local least = math.floor(PLACEMENT.MinItemsPerSection + span * hurt + 0.5)
	local wanted = random:NextInteger(least, PLACEMENT.MaxItemsPerSection)
	local count = math.min(wanted, #pads)
	local placed = 0

	for index = 1, count do
		local pad = pads[index]
		-- A pad may declare what it holds. A level designer who put a medkit
		-- shelf on a rooftop means it, and the Director does not argue.
		local declared = pad:GetAttribute(SLOT_ATTRIBUTE)
		local slot = if typeof(declared) == "string" and Enums.Slot[declared]
			then declared
			else self:_rollSlot(hurt)

		local itemId = self:_rollItem(slot)
		if itemId then
			-- The pad's top surface, so an item on a table is on the table.
			local top = pad.Position + Vector3.new(0, pad.Size.Y * 0.5, 0)
			local model = self:spawnPickup(slot, itemId, top)
			if model then
				occupied[pad] = model
				placed += 1
			end
		end
	end

	return placed
end

--[[
	Stocks one section of the level.

	Called by whoever owns level flow when the team commits to a new section, so
	the roll reflects how the team is doing NOW rather than how they were doing
	when the map loaded. That timing is the entire point of routing item choice
	through the Director instead of baking items into the map.
]]
function ItemPlacer:populateSection(sectionFolder: Instance)
	if typeof(sectionFolder) ~= "Instance" then
		return
	end

	local pads = self:_availablePads(sectionFolder)
	if #pads == 0 then
		return
	end
	self:_stock(pads)
end

--[[
	Restocks the map between two waves. RoundService's entry point.

	A wave-mode map has no sections to commit to — the team holds one arena for
	seventeen minutes — so every free FL_ItemSpawn pad in the Workspace is a
	candidate and the breather is the only moment new items appear. Pads still
	holding an untaken item are skipped, so a team that hoarded gets less than a
	team that spent everything, which is the correct answer to both.

	WHETHER to call this is RoundService's decision: `itemDropChance` lives on
	the wave definition and belongs to whoever owns the schedule. What appears
	once it does is this module's, and it is still weighted by how badly the team
	is hurting.

	Returns how many pickups landed, so a caller can tell "the map is already
	full" apart from "nothing spawned".
]]
function ItemPlacer:restockForBreather(): number
	local pads = self:_availablePads(Workspace)
	if #pads == 0 then
		return 0
	end
	return self:_stock(pads)
end

Registry.register("ItemPlacer", ItemPlacer)

return ItemPlacer
