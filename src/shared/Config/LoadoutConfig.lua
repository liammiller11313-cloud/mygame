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
local AbilityConfig = require(Shared.Config.AbilityConfig)
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
	And the ability slots, which live in the same flat table as the weapons.

	One map of key -> id rather than a weapons table beside an abilities table,
	because everything that already exists for a loadout — the wire format, the
	save, sanitise, equal, the copy-on-edit in the UI — then covers abilities for
	free. Nothing had to learn that a loadout has two kinds of thing in it.

	The keys are built from AbilityConfig.MaxSlots rather than written out, so
	the day a third ability slot is allowed the loadout carries it without an
	edit here.
]]
local ABILITY_SLOTS: { string } = {}
for index = 1, AbilityConfig.MaxSlots do
	table.insert(ABILITY_SLOTS, string.format("Ability%d", index))
end
LoadoutConfig.AbilitySlots = table.freeze(ABILITY_SLOTS)

--[[ What an ability slot holds when it holds nothing. "" rather than nil, so a
     loadout is always a complete table and the wire never has to distinguish
     "empty" from "the field was dropped in transit". ]]
LoadoutConfig.NoAbility = ""

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

--[[ A readable name for a loadout the player has not named. Also what an empty
     or unusable name falls back to — see sanitiseName. ]]
function LoadoutConfig.defaultName(index: number): string
	return string.format("LOADOUT %d", index)
end

--[[ Long enough for "CQC / TANK BUSTER" and short enough that the row it sits in
     never has to reflow. Enforced on the SERVER, because the client's TextBox
     limit is a courtesy and the wire is not. ]]
LoadoutConfig.MaxNameLength = 18

--[[
	A loadout name the game will store and draw.

	── WHAT THIS IS AND IS NOT ─────────────────────────────────────────────────
	It is a length cap, a control-character strip and a whitespace trim. It is
	NOT a content filter, and the difference decides where the name may ever be
	shown: these names are drawn to their OWNER and to nobody else, which is the
	only reason an unfiltered string is safe to render at all.

	If a name is ever put in front of another player — a lobby row, a scoreboard,
	a spectate card — it has to go through TextService:FilterStringAsync first,
	and this function is not that and cannot be made into it from here, because
	filtering is asynchronous and this is called from the middle of a write.

	Two classes of character go rather than being escaped. ASCII controls, because
	a newline in a single-line label draws as a name that is silently blank. And
	the Unicode BIDI overrides, because those are not control characters — Lua's
	%c does not match them, and U+202E in a name reorders the row it sits in
	around itself. They are stripped by their UTF-8 bytes, which is the only way
	to reach them from a byte pattern.
]]
--[[ U+202A..U+202E and U+2066..U+2069: the embedding, override and isolate
     marks. All of them encode as E2 80 xx / E2 81 xx, so one class each. ]]
local BIDI_PATTERNS = table.freeze({ "\226\128[\170-\174]", "\226\129[\166-\169]" })
function LoadoutConfig.sanitiseName(name: any, index: number): string
	if typeof(name) ~= "string" then
		return LoadoutConfig.defaultName(index)
	end
	--[[ %c is every control character including tab and newline; the second
	     pattern collapses the runs of spaces they leave behind, so "A\n\nB"
	     becomes "A B" rather than "A  B". ]]
	local cleaned = name
	for _, pattern in BIDI_PATTERNS do
		cleaned = string.gsub(cleaned, pattern, "")
	end
	cleaned = string.gsub(cleaned, "%c", " ")
	cleaned = string.gsub(cleaned, "%s+", " ")
	cleaned = string.match(cleaned, "^%s*(.-)%s*$") or ""
	if cleaned == "" then
		return LoadoutConfig.defaultName(index)
	end
	--[[ Bytes rather than characters, deliberately: it is what the datastore
	     budget is measured in, and cutting a multi-byte glyph in half is a
	     cosmetic problem where an unbounded string is a storage one. ]]
	if #cleaned > LoadoutConfig.MaxNameLength then
		cleaned = string.sub(cleaned, 1, LoadoutConfig.MaxNameLength)
	end
	return cleaned
end

--[[ All three names, whatever was stored. Mirrors sanitiseAll below: a profile
     saved before names existed has none, and every one of them comes back as its
     own default rather than as a hole. ]]
function LoadoutConfig.sanitiseNames(stored: any): { string }
	local out = table.create(LoadoutConfig.MaxLoadouts)
	for index = 1, LoadoutConfig.MaxLoadouts do
		local raw = if typeof(stored) == "table" then stored[index] else nil
		out[index] = LoadoutConfig.sanitiseName(raw, index)
	end
	return out
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
function LoadoutConfig.sanitise(
	loadout: any,
	owned: { [string]: boolean }?,
	abilitiesOwned: { [string]: boolean }?
): Loadout
	local out: Loadout = {}
	local source = if typeof(loadout) == "table" then loadout else {}

	for _, slot in LoadoutConfig.Slots do
		local wanted = source[slot]
		local legal = typeof(wanted) == "string"
			and LoadoutConfig.fits(slot, wanted)
			and (owned == nil or owned[wanted] == true)
		out[slot] = if legal then wanted else LoadoutConfig.Default[slot]
	end

	--[[ Abilities go through AbilityConfig's own list sanitiser rather than being
	     checked one at a time here, because the rule that matters is about the
	     PAIR: the same ability must not end up in both slots. Checking each key
	     in isolation cannot see that, and a loadout with Shield twice is a player
	     who has silently thrown away a slot.

	     Empty is a legal answer for an ability and is not for a weapon, which is
	     the one place these two halves genuinely differ: everybody spawns with a
	     gun, and nobody starts owning an ability. ]]
	local pair = {}
	for index, key in LoadoutConfig.AbilitySlots do
		pair[index] = source[key]
	end
	local cleaned = AbilityConfig.sanitiseSlots(pair, abilitiesOwned)
	for index, key in LoadoutConfig.AbilitySlots do
		out[key] = cleaned[index] or LoadoutConfig.NoAbility
	end

	return out
end

--[[ A loadout's abilities in the array shape AbilityConfig and the HUD think
     in. One direction only: the loadout is the storage, this is the view. ]]
function LoadoutConfig.abilitiesOf(loadout: Loadout?): { string }
	local out: { string } = {}
	for index, key in LoadoutConfig.AbilitySlots do
		local id = if loadout then loadout[key] else nil
		out[index] = if typeof(id) == "string" then id else LoadoutConfig.NoAbility
	end
	return out
end

--[[
	A COPY of `loadout` with one ability slot set, or cleared with "".

	Copied rather than written in place for the reason the whole loadout screen
	is: nothing edits a stored loadout, it builds a new one and sends it, so a
	refused edit leaves nothing half-changed behind it.

	Clearing the id from wherever it already was is what makes equipping slot 1's
	ability into slot 2 a MOVE. Without it the id sits in both, and sanitiseSlots
	— which keeps the first occurrence — silently undoes the half the player
	actually asked for.
]]
function LoadoutConfig.withAbility(loadout: Loadout?, slot: number, id: string): Loadout
	local out: Loadout = {}
	for key, value in (loadout or {}) do
		out[key] = value
	end

	if id ~= LoadoutConfig.NoAbility then
		for _, key in LoadoutConfig.AbilitySlots do
			if out[key] == id then
				out[key] = LoadoutConfig.NoAbility
			end
		end
	end

	local key = LoadoutConfig.AbilitySlots[slot]
	if key then
		out[key] = id
	end
	return out
end

--[[ Three sanitised loadouts, whatever was stored. A profile with one loadout,
     five, or a string where a table should be all come back as exactly
     MaxLoadouts legal ones. ]]
function LoadoutConfig.sanitiseAll(
	loadouts: any,
	owned: { [string]: boolean }?,
	abilitiesOwned: { [string]: boolean }?
): { Loadout }
	local out = {}
	local source = if typeof(loadouts) == "table" then loadouts else {}
	for index = 1, LoadoutConfig.MaxLoadouts do
		out[index] = LoadoutConfig.sanitise(source[index], owned, abilitiesOwned)
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
	--[[ Abilities count. Without this an edit that changed ONLY an ability
	     compared equal to what was stored, setLoadout returned false as "no
	     change", and the slot the player just picked was never saved. ]]
	for _, key in LoadoutConfig.AbilitySlots do
		if a[key] ~= b[key] then
			return false
		end
	end
	return true
end

return table.freeze(LoadoutConfig)
