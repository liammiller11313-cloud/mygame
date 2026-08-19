--!strict
--[[
	LoadoutConfig — what a saved loadout is, and what it is allowed to contain.

	Three loadouts per player, each one a rifle, a sidearm and a melee, one of
	them active. You spawn with the active one. That is the whole feature, and
	this file is the contract both ends agree on: the client draws from it, the
	server validates against it, and neither has an opinion the other does not
	share.

	── WHY ONLY THESE THREE SLOTS ──────────────────────────────────────────────
	A loadout sets Primary, Secondary and Melee and nothing else. Medkits, pills
	and throwables stay where they are — on the floor of the map, found by
	looking.

	That is a deliberate line rather than a missing feature. The scavenging loop
	is most of what makes a Left 4 Dead map worth walking through slowly: the
	reason to open the side room is that there might be a kit in it. A loadout
	that could carry a medkit deletes that reason for every player who can afford
	one, and turns Dollars into a purchase of survivability rather than of
	preference. Guns are a preference. Health is the game.

	── WHY THREE ───────────────────────────────────────────────────────────────
	Enough for a shape each — something close-range, something long, and one you
	are experimenting with — and few enough that picking between them at the start
	of a round is a glance rather than a menu. A fourth would not be a fourth
	idea, it would be a second copy of one of the first three.

	── VALIDATION IS THE POINT ─────────────────────────────────────────────────
	`sanitise` is the only way a loadout enters the game, on either side. It takes
	whatever it is given — a saved profile from two versions ago, a table a client
	invented, nil — and returns something that is definitely a legal loadout for
	that player. Nothing downstream needs a second opinion, and nothing can equip
	a weapon it does not own by asking nicely.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local EconomyConfig = require(Shared.Config.EconomyConfig)
local Enums = require(Shared.Enums)
local WeaponConfig = require(Shared.Config.WeaponConfig)

local LoadoutConfig = {}

--[[ How many a player keeps. See the header — this is a design number, not a
     storage one, and raising it costs nothing technically. ]]
LoadoutConfig.MaxLoadouts = 3

--[[ The slots a loadout controls, and the ONLY ones. Written as a list so the
     UI can draw a row per slot without knowing which they are, and in the order
     they are drawn — which is also the order they are drawn from, longest reach
     to shortest. ]]
LoadoutConfig.Slots = table.freeze({ Enums.Slot.Primary, Enums.Slot.Secondary, Enums.Slot.Melee })

--[[
	What everybody starts with, and what an invalid loadout falls back to.

	The same UMP-45 and M1911 survivors have spawned with since the game was
	written, plus the knife — which is free for the same reason they are. A melee
	slot that starts empty would teach every new player that the melee key does
	nothing, and they would be right for as long as it took them to earn one.

	Nothing about a first round changes when the shop arrives, which is the point:
	the economy is added to the game rather than in front of it.
]]
LoadoutConfig.Default = table.freeze({
	[Enums.Slot.Primary] = Enums.Weapon.UMP45,
	[Enums.Slot.Secondary] = Enums.Weapon.M1911A1,
	[Enums.Slot.Melee] = Enums.Weapon.Knife,
})

export type Loadout = { [string]: string }

--[[ A readable name for a loadout the player has not named. They cannot rename
     them yet; when they can, this is the placeholder the field starts at. ]]
function LoadoutConfig.defaultName(index: number): string
	return string.format("LOADOUT %d", index)
end

--[[ Whether `weaponId` can legally sit in `slot`. The weapon's own definition
     decides — a Machete is a Melee because WeaponConfig says so, and this file
     does not get a second opinion about it. ]]
function LoadoutConfig.fits(slot: string, weaponId: string): boolean
	local definition = WeaponConfig.get(weaponId)
	return definition ~= nil and definition.slot == slot
end

--[[
	Every weapon that could go in a slot, in the order the shop lists them.

	Catalogue order rather than WeaponConfig's, which is alphabetical: the shop
	is grouped by class and then by price, and a player who has just seen the
	roster laid out that way should find it laid out the same way here. Anything
	in WeaponConfig but not in the catalogue is appended rather than dropped, so
	a weapon that is somehow not for sale is still equippable.

	Ownership is deliberately NOT considered. The loadout screen draws the whole
	roster and greys what you have not bought, because a list that hides what you
	cannot afford is a list that never tells you what to save for.
]]
function LoadoutConfig.candidates(slot: string): { string }
	local out = {}
	local seen: { [string]: boolean } = {}

	for _, entry in EconomyConfig.Catalogue do
		if not entry.soon and LoadoutConfig.fits(slot, entry.id) then
			table.insert(out, entry.id)
			seen[entry.id] = true
		end
	end
	for _, id in WeaponConfig.idsForSlot(slot) do
		if not seen[id] then
			table.insert(out, id)
		end
	end

	return out
end

--[[
	The one way a loadout enters the game.

	`owned` is the player's unlock set; a loadout naming a weapon they do not own
	falls back to the default for that slot rather than being rejected outright,
	because the common cause is a profile that predates a balance change and the
	right answer is "you spawn with something" rather than "you spawn with
	nothing". Pass nil to skip the ownership check — the client does, so it can
	draw a loadout it is in the middle of editing.

	Always returns a complete, legal loadout. There is no failure case by design.
]]
function LoadoutConfig.sanitise(loadout: any, owned: { [string]: boolean }?): Loadout
	local out: Loadout = {}
	local source = if typeof(loadout) == "table" then loadout else {}

	for _, slot in LoadoutConfig.Slots do
		local wanted = source[slot]
		local legal = typeof(wanted) == "string"
			and LoadoutConfig.fits(slot, wanted)
			and (owned == nil or owned[wanted] == true)
		out[slot] = if legal then wanted else LoadoutConfig.Default[slot]
	end

	return out
end

--[[ Three sanitised loadouts, whatever was stored. A profile with one loadout,
     five, or a string where a table should be all come back as exactly
     MaxLoadouts legal ones. ]]
function LoadoutConfig.sanitiseAll(loadouts: any, owned: { [string]: boolean }?): { Loadout }
	local out = {}
	local source = if typeof(loadouts) == "table" then loadouts else {}
	for index = 1, LoadoutConfig.MaxLoadouts do
		out[index] = LoadoutConfig.sanitise(source[index], owned)
	end
	return out
end

--[[ A loadout index clamped into range. Used on both sides of the wire: an
     out-of-range index is the shape a malformed request takes. ]]
function LoadoutConfig.clampIndex(index: any): number
	if typeof(index) ~= "number" or index ~= index then
		return 1
	end
	return math.clamp(math.floor(index), 1, LoadoutConfig.MaxLoadouts)
end

--[[ Whether two loadouts hold the same weapons. Used by the client to decide
     whether an edit is worth sending, and by the loadout screen to mark the
     active one — comparing tables by identity would mark nothing. ]]
function LoadoutConfig.equal(a: Loadout?, b: Loadout?): boolean
	if a == nil or b == nil then
		return a == b
	end
	for _, slot in LoadoutConfig.Slots do
		if a[slot] ~= b[slot] then
			return false
		end
	end
	return true
end

return table.freeze(LoadoutConfig)
