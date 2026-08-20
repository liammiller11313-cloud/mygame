--!nonstrict
--[[
	InventoryService — five slots, and the ammo behind them.

	The slot layout is L4D2's and it is a design, not a container: one primary,
	one secondary you can never lose, one throwable, one health item, one set of
	pills. Every pickup is therefore a trade, and the team's kit is a running
	negotiation instead of a backpack.

	Two behaviours in here are load-bearing and must not be "tidied":

	  * Shell-by-shell reloads commit ONE shell at a time and firing cancels the
	    rest. Standing in a doorway deciding between two more shells and shooting
	    now is one of the best decisions L4D gives a player.
	  * Pistol reserve is infinite (reserveMax -1). The secondary is the promise
	    that you are never completely out of answers.

	The server owns every number here. Clients predict their own ammo count for
	responsiveness and reconcile from Attributes.Loadout.*; nothing a client sends
	is trusted beyond "I would like to".

	PERFORMANCE: one Heartbeat connection drives every reload and item use for
	every player. No timers, no per-weapon connections.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")

local AudioConfig = require(Shared.Config.AudioConfig)
local Attributes = require(Shared.Net.Attributes)
local Enums = require(Shared.Enums)
local GameConfig = require(Shared.Config.GameConfig)
local Registry = require(Shared.Util.Registry)
local Remotes = require(Shared.Net.Remotes)
local Signal = require(Shared.Util.Signal)
local Trove = require(Shared.Util.Trove)
local WeaponConfig = require(Shared.Config.WeaponConfig)

local S = GameConfig.Survivor
local LA = Attributes.Loadout
local PICKUP = Attributes.Pickup

-- Which enum table legitimately fills each non-weapon slot. A slot that is not
-- in here holds a weapon, and WeaponConfig decides what may go in it.
local SLOT_ITEMS = table.freeze({
	[Enums.Slot.Throwable] = Enums.Throwable,
	[Enums.Slot.Health] = Enums.HealthItem,
	[Enums.Slot.Pills] = Enums.PillItem,
})

--[[ What a survivor walks into the first chapter carrying: the pistol they can
     never lose, plus an SMG — the forgiving primary, so a new player's first
     horde is survivable while they learn what the shotgun is for. ]]
local STARTING_PRIMARY = Enums.Weapon.UMP45
local STARTING_SECONDARY = Enums.Weapon.M1911A1
--[[ And a knife, so the melee key does something on the very first spawn. A
     slot that starts empty is a control that teaches a new player it is broken.
     Mirrors LoadoutConfig.Default — these two are the same promise stated on
     both sides of the wire. ]]
local STARTING_MELEE = Enums.Weapon.Knife

-- Reload phases. "Tail" is the pump-and-ready after the last shell goes in.
local PHASE_LOAD = "Load"
local PHASE_TAIL = "Tail"

-- Anti-spam on the intent remotes. Not balance; a client cannot be trusted to
-- send at a sane rate and every one of these touches replicated state.
local REQUEST_INTERVAL = 0.05

-- How far in front of the survivor a dropped weapon lands.
local DROP_FORWARD = 3.5
local DROP_UP = 1.5

local InventoryService = {}

InventoryService.changed = Signal.new() -- (player, slot)

--[[ (player, slot, itemId, model) — fired the instant a world pickup is taken,
     while the model is still alive. Anything that owns the SPOT a pickup came
     from needs to know it went and who has it, and by the time the slot change
     lands the model has already been destroyed. ]]
InventoryService.pickedUp = Signal.new()

--[[ (player, slot, itemId) — fired when an item is SPENT, as opposed to dropped,
     swapped away or lost on death. All four end with an empty slot and a
     `changed`, and a medkit spawn point may only refill for the first: the other
     three leave the kit somewhere in the world, and restocking on those would
     quietly print medkits. ]]
InventoryService.itemConsumed = Signal.new()

local records: { [Player]: any } = {}
local serviceTrove = Trove.new()

local function playAt(definition, part: BasePart?)
	if not part then
		return
	end
	local audio = Registry.find("AudioService")
	if audio then
		audio:playOn(definition, part)
	end
end

local function rootOf(player: Player): BasePart?
	local character = player.Character
	if not character then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	return root and root:IsA("BasePart") and root or nil
end

-- ─── records ─────────────────────────────────────────────────────────────────

function InventoryService:_ensureRecord(player: Player)
	local record = records[player]
	if record then
		return record
	end

	record = {
		player = player,
		trove = Trove.new(),
		slots = {}, -- [Enums.Slot] = { itemId, ammo, reserve }
		activeSlot = Enums.Slot.Secondary,
		reload = nil,
		use = nil,
		stashedSecondary = nil, -- what the incap pistol displaced
		restoreSlot = nil,
		lastRequest = {},
		warnedThrow = false,
		pub = {},
	}
	records[player] = record

	record.trove:connect(player.CharacterAdded, function()
		-- Respawning with nothing is a bug the player cannot fix; a survivor who
		-- comes back from a closet or a defib always has something to shoot with.
		if next(record.slots) == nil then
			self:giveStartingLoadout(player)
		else
			self:_publish(record)
		end
	end)

	self:_publish(record)
	return record
end

function InventoryService:_destroyRecord(player: Player)
	local record = records[player]
	if not record then
		return
	end
	record.trove:destroy()
	records[player] = nil
end

--[[ Rate limit for one kind of client request. ]]
function InventoryService:_throttled(record, key: string): boolean
	local now = os.clock()
	local last = record.lastRequest[key]
	if last and now - last < REQUEST_INTERVAL then
		return true
	end
	record.lastRequest[key] = now
	return false
end

-- ─── attribute mirror ────────────────────────────────────────────────────────

local function setAttribute(record, key: string, name: string, value: any)
	if record.pub[key] == value then
		return
	end
	record.pub[key] = value
	record.player:SetAttribute(name, value)
end

--[[
	Mirrors the loadout into Attributes.Loadout.*, which is the only thing the
	ammo counter reads. Note there is no SecondaryReserve field in the contract,
	and there should not be: a secondary is a pistol, and every pistol in this
	game has infinite reserve. Melee has neither field for the same reason in
	reverse — it has no ammo at all.
]]
function InventoryService:_publish(record)
	local slots = record.slots

	local primary = slots[Enums.Slot.Primary]
	setAttribute(record, "pid", LA.PrimaryId, primary and primary.itemId or "")
	setAttribute(record, "pammo", LA.PrimaryAmmo, primary and primary.ammo or 0)
	setAttribute(record, "pres", LA.PrimaryReserve, primary and primary.reserve or 0)

	local secondary = slots[Enums.Slot.Secondary]
	setAttribute(record, "sid", LA.SecondaryId, secondary and secondary.itemId or "")
	setAttribute(record, "sammo", LA.SecondaryAmmo, secondary and secondary.ammo or 0)

	--[[ No ammo counterpart, and there will not be one. A melee never runs out,
	     which is most of why it is worth a slot of its own. ]]
	local melee = slots[Enums.Slot.Melee]
	setAttribute(record, "mid", LA.MeleeId, melee and melee.itemId or "")

	local throwable = slots[Enums.Slot.Throwable]
	setAttribute(record, "tid", LA.ThrowableId, throwable and throwable.itemId or "")

	local health = slots[Enums.Slot.Health]
	setAttribute(record, "hid", LA.HealthItemId, health and health.itemId or "")

	local pills = slots[Enums.Slot.Pills]
	setAttribute(record, "kid", LA.PillItemId, pills and pills.itemId or "")

	setAttribute(record, "active", LA.ActiveSlot, record.activeSlot)
	setAttribute(record, "reloading", LA.IsReloading, record.reload ~= nil)
end

--[[ Announces a discrete slot change. Ammo counts ride the attributes instead —
     a remote per round fired would be the single noisiest thing in the game. ]]
function InventoryService:_announce(record, slot: string)
	local entry = record.slots[slot]
	Remotes.Event.InventoryChanged:FireClient(record.player, {
		slot = slot,
		itemId = entry and entry.itemId or "",
		ammo = entry and entry.ammo or 0,
		reserve = entry and entry.reserve or 0,
	})
	self.changed:fire(record.player, slot)
end

-- ─── public API ──────────────────────────────────────────────────────────────

--[[ The live loadout table. Read it; do not mutate it — every writer in this
     file also publishes attributes, and a silent edit desynchronises the HUD. ]]
function InventoryService:getLoadout(player: Player)
	return self:_ensureRecord(player).slots
end

function InventoryService:getItem(player: Player, slot: string): string?
	local record = records[player]
	local entry = record and record.slots[slot]
	return entry and entry.itemId or nil
end

function InventoryService:hasItem(player: Player, slot: string, itemId: string): boolean
	return self:getItem(player, slot) == itemId
end

function InventoryService:isReloading(player: Player): boolean
	local record = records[player]
	return record ~= nil and record.reload ~= nil
end

--[[
	Puts a weapon in the slot its definition names. `ammo` and `reserve` are for
	transferring a part-used gun from a pickup; left out, the weapon arrives full.
	A reserve of -1 stays -1: that is the infinite-reserve marker, not a count.
]]
function InventoryService:giveWeapon(
	player: Player,
	weaponId: string,
	ammo: number?,
	reserve: number?
): boolean
	local definition = WeaponConfig.get(weaponId)
	if not definition then
		return false
	end

	local record = self:_ensureRecord(player)
	local slot = definition.slot
	local magazine = math.clamp(ammo or definition.magSize, 0, math.max(definition.magSize, 0))
	local spare = reserve or definition.reserveMax
	if definition.reserveMax >= 0 then
		spare = math.clamp(spare, 0, definition.reserveMax)
	else
		spare = -1
	end

	record.slots[slot] = { itemId = weaponId, ammo = magazine, reserve = spare }
	if record.reload and record.reload.slot == slot then
		self:_endReload(record)
	end

	self:_publish(record)
	self:_announce(record, slot)
	return true
end

--[[ Puts a non-weapon item in a slot, validating that the item actually belongs
     there. Weapon ids are forwarded to giveWeapon so callers have one door. ]]
function InventoryService:giveItem(player: Player, slot: string, itemId: string): boolean
	if typeof(slot) ~= "string" or typeof(itemId) ~= "string" then
		return false
	end
	if WeaponConfig.get(itemId) then
		return self:giveWeapon(player, itemId)
	end

	local allowed = SLOT_ITEMS[slot]
	if not allowed or allowed[itemId] == nil then
		return false
	end

	local record = self:_ensureRecord(player)
	record.slots[slot] = { itemId = itemId, ammo = 0, reserve = 0 }
	self:_publish(record)
	self:_announce(record, slot)
	return true
end

--[[
	What a survivor spawns holding.

	Asks LoadoutService, which reads the player's saved active loadout out of
	their profile. The constants above are the fallback and stay the fallback:
	a profile that has not loaded, a service that is not registered, or a
	loadout that sanitised to nothing all end here holding the same UMP-45 and
	M1911 the game has always started people with.

	The primary is granted LAST, which is not arbitrary — `setActiveSlot` below
	selects it, and granting in this order means the last thing to touch the
	inventory is the thing the player will be looking at.
]]
function InventoryService:giveStartingLoadout(player: Player)
	local primary, secondary = STARTING_PRIMARY, STARTING_SECONDARY
	local melee = STARTING_MELEE

	local loadouts = Registry.find("LoadoutService")
	if loadouts and typeof(loadouts.getSpawnLoadout) == "function" then
		local ok, chosen = pcall(loadouts.getSpawnLoadout, loadouts, player)
		if ok and typeof(chosen) == "table" then
			primary = chosen[Enums.Slot.Primary] or primary
			secondary = chosen[Enums.Slot.Secondary] or secondary
			melee = chosen[Enums.Slot.Melee] or melee
		end
	end

	self:giveWeapon(player, melee)
	self:giveWeapon(player, secondary)
	self:giveWeapon(player, primary)
	self:setActiveSlot(player, Enums.Slot.Primary)
end

function InventoryService:getActiveWeapon(player: Player): (string?, any)
	local record = records[player]
	if not record then
		return nil, nil
	end
	local entry = record.slots[record.activeSlot]
	if not entry then
		return nil, nil
	end
	local definition = WeaponConfig.get(entry.itemId)
	if not definition then
		return nil, nil
	end
	return entry.itemId, definition
end

--[[ Switching stows whatever was happening: a half-finished reload does not
     survive a slot change, and neither does a half-applied medkit. ]]
function InventoryService:setActiveSlot(player: Player, slot: string): boolean
	if typeof(slot) ~= "string" or Enums.Slot[slot] == nil then
		return false
	end

	local record = self:_ensureRecord(player)
	if not record.slots[slot] then
		return false
	end

	-- On the floor you hold the incap weapon. That is the whole of your options.
	local survivors = Registry.find("SurvivorService")
	if survivors and survivors:isIncapacitated(player) then
		return false
	end

	if record.activeSlot == slot then
		return true
	end

	self:_endReload(record)
	self:cancelUse(player)
	record.activeSlot = slot
	self:_publish(record)
	self:_announce(record, slot)
	return true
end

--[[
	Spends rounds from the magazine of the active weapon. Called by
	BallisticsService for every trigger pull — and, critically, it is also the
	signal that the player fired, which is what interrupts a shell reload.
]]
function InventoryService:consumeAmmo(player: Player, count: number): boolean
	local record = records[player]
	if not record then
		return false
	end
	local entry = record.slots[record.activeSlot]
	if not entry then
		return false
	end
	local definition = WeaponConfig.get(entry.itemId)
	if not definition then
		return false
	end

	-- Melee has no magazine and never runs dry; nothing to spend, nothing to cut.
	if definition.magSize <= 0 then
		return true
	end

	local rounds = math.max(math.floor(tonumber(count) or 1), 1)
	if entry.ammo < rounds then
		return false
	end
	entry.ammo -= rounds

	-- Firing keeps the shells already loaded and drops the rest of the reload.
	if record.reload then
		self:_endReload(record)
	end
	self:cancelUse(player)

	self:_publish(record)
	return true
end

--[[ Starts a reload if one would do anything. Returns false rather than warning:
     the client asks optimistically every time the player taps R. ]]
function InventoryService:beginReload(player: Player): boolean
	local record = records[player]
	if not record or record.reload then
		return false
	end
	local slot = record.activeSlot
	local entry = record.slots[slot]
	if not entry then
		return false
	end
	local definition = WeaponConfig.get(entry.itemId)
	if not definition or definition.magSize <= 0 then
		return false
	end
	if entry.ammo >= definition.magSize or entry.reserve == 0 then
		return false
	end

	self:cancelUse(player)
	record.reload = {
		slot = slot,
		weaponId = entry.itemId,
		perShell = definition.reloadPerShell > 0,
		phase = PHASE_LOAD,
		timer = 0,
	}
	self:_publish(record)
	playAt(AudioConfig.WeaponReload.MagOut, rootOf(player))
	return true
end

--[[
	Uses whatever is in a slot.

	Medkits run on a clock (and heal a share of what is MISSING, so the kit is
	worth most to whoever is worst off). Pills and adrenaline are instant, because
	the config gives them no use time and the panic of swallowing pills mid-horde
	is the point. A defibrillator needs a body, so it goes through BeginInteract
	rather than through here.
]]
function InventoryService:useItem(player: Player, slot: string): boolean
	if typeof(slot) ~= "string" or Enums.Slot[slot] == nil then
		return false
	end

	local record = records[player]
	if not record then
		return false
	end
	local entry = record.slots[slot]
	if not entry then
		return false
	end

	local survivors = Registry.find("SurvivorService")
	if survivors and not survivors:isAlive(player) then
		return false
	end
	if survivors and survivors:isIncapacitated(player) then
		return false
	end

	if slot == Enums.Slot.Pills then
		if not survivors or not survivors:applyPills(player, entry.itemId) then
			return false
		end
		self:_clearSlot(record, slot)
		self.itemConsumed:fire(player, slot, entry.itemId)
		return true
	end

	if slot == Enums.Slot.Health then
		if entry.itemId == Enums.HealthItem.Defibrillator then
			-- Nothing to point it at from here; the target picks the interaction.
			return false
		end
		if record.use then
			return false
		end
		local multiplier = survivors and survivors:getUseSpeedMultiplier(player) or 1
		local duration = S.MedkitUseTime / multiplier
		self:_endReload(record)
		record.use = { slot = slot, itemId = entry.itemId, elapsed = 0, duration = duration }
		Remotes.Event.InteractPromptChanged:FireClient(player, {
			visible = true,
			verb = "Healing",
			subject = "",
			duration = duration,
		})
		return true
	end

	if slot == Enums.Slot.Throwable then
		-- Pressing the throwable key equips it; the throw itself is a separate
		-- intent (Remotes.Event.ThrowItem) owned by whatever handles projectiles.
		if record.activeSlot ~= slot then
			return self:setActiveSlot(player, slot)
		end
		local projectiles = Registry.find("ProjectileService")
		if not projectiles then
			if not record.warnedThrow then
				record.warnedThrow = true
				warn("[InventoryService] no ProjectileService registered; throwable not consumed")
			end
			return false
		end
		if projectiles:throw(player, entry.itemId) then
			self:_clearSlot(record, slot)
			self.itemConsumed:fire(player, slot, entry.itemId)
			return true
		end
		return false
	end

	-- Primary and secondary are fired, not used.
	return false
end

--[[ Removes a specific item from a slot. Used by the interaction code when a
     medkit or defib is spent on somebody else. ]]
function InventoryService:consumeSlot(player: Player, slot: string, expectedItemId: string?): boolean
	local record = records[player]
	local entry = record and record.slots[slot]
	if not entry then
		return false
	end
	if expectedItemId and entry.itemId ~= expectedItemId then
		return false
	end
	self:_clearSlot(record, slot)
	return true
end

--[[ Cancels a medkit that is partway through. Costs the player the time, never
     the kit — a heal interrupted by a Hunter has already punished them enough. ]]
function InventoryService:cancelUse(player: Player)
	local record = records[player]
	if not record or not record.use then
		return
	end
	record.use = nil
	Remotes.Event.InteractPromptChanged:FireClient(player, { visible = false })
end

--[[
	Drops a slot on the floor as a pickup, carrying its remaining ammo with it.
	This is what makes an ammo-starved primary a real decision instead of a chore:
	the gun you put down is still the gun somebody else finds.
]]
--[[
	Tops a survivor back up from an ammo crate.

	Returns the number of rounds actually given, and gives NOTHING when there was
	nothing to give — which is what lets AmmoCrateService refuse to spend a crate
	on a player who is already full. Walking into a resupply at full ammo and
	burning it for nothing would be a genuinely infuriating way to lose one.

	Infinite-reserve secondaries are skipped for the same reason: a pistol can
	never be topped up, so it must never count toward "this crate did something".
]]
function InventoryService:refillReserve(player: Player, fraction: number, alsoMagazine: boolean): number
	local record = records[player]
	if not record then
		return 0
	end

	local given = 0
	local share = math.clamp(fraction or 1, 0, 1)

	for slot, entry in record.slots do
		if not entry or entry.itemId == "" then
			continue
		end
		local definition = WeaponConfig.get(entry.itemId)
		-- Melee has no ammunition, and reserveMax below zero is the
		-- infinite-reserve marker rather than a count.
		if not definition or definition.magSize <= 0 or definition.reserveMax < 0 then
			continue
		end

		local missingReserve = definition.reserveMax - entry.reserve
		if missingReserve > 0 then
			local amount = math.floor(definition.reserveMax * share + 0.5)
			amount = math.min(amount, missingReserve)
			entry.reserve += amount
			given += amount
		end

		if alsoMagazine then
			local missingMagazine = definition.magSize - entry.ammo
			if missingMagazine > 0 then
				local fromReserve = math.min(missingMagazine, entry.reserve)
				entry.ammo += fromReserve
				entry.reserve -= fromReserve
				given += fromReserve
			end
		end

		if given > 0 then
			self:_announce(record, slot)
		end
	end

	if given > 0 then
		self:_publish(record)
	end
	return given
end

function InventoryService:dropWeapon(player: Player, slot: string): Model?
	local record = records[player]
	local entry = record and record.slots[slot]
	if not entry then
		return nil
	end

	local model = Registry.get("PlaceholderFactory"):buildPickup(slot, entry.itemId)
	if not model then
		return nil
	end

	model:SetAttribute(PICKUP.Slot, slot)
	model:SetAttribute(PICKUP.ItemId, entry.itemId)
	model:SetAttribute(PICKUP.Ammo, entry.ammo)
	model:SetAttribute(PICKUP.Reserve, entry.reserve)

	local root = rootOf(player)
	if root then
		model:PivotTo(root.CFrame * CFrame.new(0, DROP_UP, -DROP_FORWARD))
	end
	model.Parent = workspace

	self:_clearSlot(record, slot)
	return model
end

--[[ Takes a pickup off the floor. Picking up a weapon for an occupied slot drops
     the old one where the new one was, so nothing is ever silently destroyed. ]]
function InventoryService:pickup(player: Player, model: Instance): boolean
	if typeof(model) ~= "Instance" or model.Parent == nil then
		return false
	end
	local slot = model:GetAttribute(PICKUP.Slot)
	local itemId = model:GetAttribute(PICKUP.ItemId)
	if typeof(slot) ~= "string" or typeof(itemId) ~= "string" or Enums.Slot[slot] == nil then
		return false
	end

	local record = self:_ensureRecord(player)
	local existing = record.slots[slot]
	local granted: boolean

	if WeaponConfig.get(itemId) then
		local ammo = tonumber(model:GetAttribute(PICKUP.Ammo))
		local reserve = tonumber(model:GetAttribute(PICKUP.Reserve))
		if existing then
			self:dropWeapon(player, slot)
		end
		granted = self:giveWeapon(player, itemId, ammo, reserve)
	else
		if existing then
			self:dropWeapon(player, slot)
		end
		granted = self:giveItem(player, slot, itemId)
	end

	if not granted then
		return false
	end

	-- Before the Destroy, not after: a listener that wants to know where this
	-- came from has to be able to read the model.
	self.pickedUp:fire(player, slot, itemId, model)

	model:Destroy()
	playAt(AudioConfig.UI.Pickup, rootOf(player))
	return true
end

--[[
	Called by SurvivorService when a survivor goes down or stands up. A downed
	survivor holds GameConfig.Survivor.IncapWeapon and cannot switch away from
	it — the pistol from the floor is the whole of their contribution, and a
	machete would not be.
]]
function InventoryService:setIncapacitated(player: Player, downed: boolean)
	local record = records[player]
	if not record then
		return
	end

	if downed then
		self:_endReload(record)
		self:cancelUse(player)
		record.restoreSlot = record.activeSlot

		--[[ A downed survivor fires a pistol and nothing else.

		     This used to also catch a machete in the secondary slot, which is where
		     melee lived before it got a slot of its own — that branch is
		     unreachable now and the check is only "is the slot empty". It is kept
		     rather than dropped because an empty secondary is still possible: a
		     loadout that sanitised to nothing, or a weapon whose model failed to
		     build. On the floor with no gun at all is the one state this must not
		     leave anybody in. ]]
		local secondary = record.slots[Enums.Slot.Secondary]
		local definition = secondary and WeaponConfig.get(secondary.itemId)
		if not definition or definition.fireMode == "Melee" then
			local incap = WeaponConfig.get(S.IncapWeapon)
			if incap then
				record.stashedSecondary = secondary
				record.slots[Enums.Slot.Secondary] = {
					itemId = S.IncapWeapon,
					ammo = incap.magSize,
					reserve = incap.reserveMax,
				}
			end
		end
		record.activeSlot = Enums.Slot.Secondary
	else
		if record.stashedSecondary then
			record.slots[Enums.Slot.Secondary] = record.stashedSecondary
			record.stashedSecondary = nil
		end
		if record.restoreSlot and record.slots[record.restoreSlot] then
			record.activeSlot = record.restoreSlot
		end
		record.restoreSlot = nil
	end

	self:_publish(record)
	self:_announce(record, Enums.Slot.Secondary)
end

--[[ Everything goes when you do. Coming back from a defib or a closet means
     starting again with the basics, which is what makes a death cost something
     beyond the thirty seconds it took to revive you. ]]
function InventoryService:clearAll(player: Player)
	local record = records[player]
	if not record then
		return
	end
	self:_endReload(record)
	self:cancelUse(player)
	record.stashedSecondary = nil
	record.restoreSlot = nil
	for slot in Enums.Slot do
		if record.slots[slot] then
			record.slots[slot] = nil
			self:_announce(record, slot)
		end
	end
	record.activeSlot = Enums.Slot.Secondary
	self:_publish(record)
end

-- ─── internals ───────────────────────────────────────────────────────────────

function InventoryService:_clearSlot(record, slot: string)
	if not record.slots[slot] then
		return
	end
	record.slots[slot] = nil
	if record.reload and record.reload.slot == slot then
		self:_endReload(record)
	end
	if record.activeSlot == slot then
		-- Never leave a survivor holding an empty hand: fall back to the pistol
		-- slot, then to anything at all.
		local fallback = record.slots[Enums.Slot.Secondary] and Enums.Slot.Secondary or nil
		if not fallback then
			for candidate in Enums.Slot do
				if record.slots[candidate] then
					fallback = candidate
					break
				end
			end
		end
		record.activeSlot = fallback or Enums.Slot.Secondary
	end
	self:_publish(record)
	self:_announce(record, slot)
end

function InventoryService:_endReload(record)
	if not record.reload then
		return
	end
	record.reload = nil
	self:_publish(record)
end

--[[ One shell. Returns false when there is nothing left to chamber, which is
     what moves a shell reload into its pump-and-ready tail. ]]
function InventoryService:_loadShell(record, entry, definition): boolean
	if entry.ammo >= definition.magSize then
		return false
	end
	if entry.reserve == 0 then
		return false
	end
	entry.ammo += 1
	if entry.reserve > 0 then
		entry.reserve -= 1
	end
	self:_publish(record)
	playAt(AudioConfig.WeaponReload.ShellInsert, rootOf(record.player))
	return true
end

function InventoryService:_loadMagazine(record, entry, definition)
	local need = definition.magSize - entry.ammo
	if need <= 0 then
		return
	end
	local taken = need
	if entry.reserve >= 0 then
		taken = math.min(need, entry.reserve)
		entry.reserve -= taken
	end
	entry.ammo += taken
	self:_publish(record)
	playAt(AudioConfig.WeaponReload.MagIn, rootOf(record.player))
end

function InventoryService:_stepReload(record, dt: number)
	local reload = record.reload
	if not reload then
		return
	end

	local entry = record.slots[reload.slot]
	local definition = entry and WeaponConfig.get(entry.itemId)
	-- The weapon that started this reload is gone (dropped, swapped, stashed).
	if not entry or not definition or entry.itemId ~= reload.weaponId then
		self:_endReload(record)
		return
	end

	reload.timer += dt

	if reload.phase == PHASE_LOAD then
		if reload.perShell then
			-- A long frame must commit every shell it earned, not just one.
			while reload.timer >= definition.reloadPerShell do
				reload.timer -= definition.reloadPerShell
				if not self:_loadShell(record, entry, definition) then
					reload.phase = PHASE_TAIL
					reload.timer = 0
					break
				end
				if entry.ammo >= definition.magSize then
					reload.phase = PHASE_TAIL
					reload.timer = 0
					break
				end
			end
		elseif reload.timer >= definition.reloadTime then
			self:_loadMagazine(record, entry, definition)
			self:_endReload(record)
			return
		end
	end

	if reload.phase == PHASE_TAIL and reload.timer >= definition.reloadTime then
		playAt(AudioConfig.WeaponReload.Pump, rootOf(record.player))
		self:_endReload(record)
	end
end

function InventoryService:_stepUse(record, dt: number, survivors)
	local use = record.use
	if not use then
		return
	end

	local player = record.player
	local entry = record.slots[use.slot]
	if not entry or entry.itemId ~= use.itemId then
		self:cancelUse(player)
		return
	end

	use.elapsed += dt
	if use.elapsed < use.duration then
		return
	end

	record.use = nil
	Remotes.Event.InteractPromptChanged:FireClient(player, { visible = false })
	if survivors and survivors:applyMedkitHeal(player) then
		self:_clearSlot(record, use.slot)
		self.itemConsumed:fire(player, use.slot, use.itemId)
	end
end

--[[
	One pass over everyone with something in flight. Idle players cost a single
	table lookup, which is what keeps this loop honest with four survivors and a
	horde already eating the frame budget.
]]
function InventoryService:_step(dt: number)
	local survivors = Registry.find("SurvivorService")
	for _, record in records do
		if record.reload or record.use then
			local state = survivors and survivors:getState(record.player) or Enums.SurvivorState.Healthy
			local upright = state == Enums.SurvivorState.Healthy or state == Enums.SurvivorState.Hurt
			local downed = state == Enums.SurvivorState.Incapacitated
				or state == Enums.SurvivorState.LedgeHanging

			if not upright and not downed then
				-- Pinned, dead or gone: both hands are busy with something else.
				self:_endReload(record)
				self:cancelUse(record.player)
			else
				-- Reloading from the floor is allowed, and is most of what a
				-- downed survivor can usefully do. Healing from the floor is not.
				self:_stepReload(record, dt)
				if upright then
					self:_stepUse(record, dt, survivors)
				else
					self:cancelUse(record.player)
				end
			end
		end
	end
end

-- ─── lifecycle ───────────────────────────────────────────────────────────────

function InventoryService:init()
	serviceTrove:connect(Players.PlayerAdded, function(player)
		self:_ensureRecord(player)
	end)
	serviceTrove:connect(Players.PlayerRemoving, function(player)
		self:_destroyRecord(player)
	end)
	for _, player in Players:GetPlayers() do
		self:_ensureRecord(player)
	end
end

function InventoryService:start()
	local survivors = Registry.get("SurvivorService")

	serviceTrove:add(survivors.died:connect(function(player)
		self:clearAll(player)
	end))

	serviceTrove:connect(Remotes.Event.SwitchSlot.OnServerEvent, function(player, slot)
		local record = records[player]
		if not record or typeof(slot) ~= "string" or self:_throttled(record, "switch") then
			return
		end
		self:setActiveSlot(player, slot)
	end)

	serviceTrove:connect(Remotes.Event.UseItem.OnServerEvent, function(player, slot)
		local record = records[player]
		if not record or typeof(slot) ~= "string" or self:_throttled(record, "use") then
			return
		end
		self:useItem(player, slot)
	end)

	serviceTrove:connect(Remotes.Event.ReloadWeapon.OnServerEvent, function(player)
		local record = records[player]
		if not record or self:_throttled(record, "reload") then
			return
		end
		self:beginReload(player)
	end)

	serviceTrove:add(RunService.Heartbeat:Connect(function(dt)
		self:_step(dt)
	end))
end

Registry.register("InventoryService", InventoryService)

return InventoryService
