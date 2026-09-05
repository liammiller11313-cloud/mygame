--!nonstrict
--[[
	LoadoutService — which two weapons a survivor spawns holding.

	Three saved loadouts per player, one of them active, each one a primary and a
	sidearm. InventoryService asks this service what to hand out; everything else
	about the loadout screen is drawing.

	── WHY THIS IS NOT PART OF InventoryService ─────────────────────────────────
	That service owns what you are CARRYING: ammo counts, reloads, what happens
	when you pick a shotgun up off the floor. This one owns what you START with,
	which is a persistence question rather than a combat one — the answer lives in
	a DataStore and has to survive being wrong. Keeping them apart means a
	profile that failed to load cannot take the inventory down with it.

	── THE CLIENT ASKS; THE SERVER DECIDES ──────────────────────────────────────
	A SetLoadout request carries an index and a table of slots. Both are put
	through LoadoutConfig.sanitise against the player's OWN unlock set before
	anything is stored, so the worst a crafted request can do is set a loadout to
	something the player already owns. Asking for a weapon you have not bought
	gets you the default for that slot, not a refusal — see that file's header for
	why silently falling back beats rejecting.

	── WHEN IT APPLIES ──────────────────────────────────────────────────────────
	At the moment InventoryService grants a starting loadout, which is on every
	spawn — plus one extra case. Changing your loadout while the round has NOT
	started re-arms you on the spot, because the picker appears exactly when a
	player is deciding what to spawn with and their character is usually already
	standing in the lobby; a choice that visibly did nothing would read as broken.

	Once a round is running, it waits for your next spawn. That is the same line
	the two-slot limit draws: the shop is not a way to re-arm mid-fight, and the
	map's weapon pickups are.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local LoadoutConfig = require(Shared.Config.LoadoutConfig)
local Registry = require(Shared.Util.Registry)
local Remotes = require(Shared.Net.Remotes)
local Signal = require(Shared.Util.Signal)
local Trove = require(Shared.Util.Trove)

local LoadoutService = {}

--[[ (player: Player, index: number) — after the active loadout changes. For the
     lobby picker's confirmation and for anything that wants to announce it. ]]
LoadoutService.activeChanged = Signal.new()

local serviceTrove = Trove.new()

--[[
	How often one player may change their loadouts.

	Every change is a profile write and a re-sync. A player dragging through the
	roster on the loadout screen would otherwise be one DataStore write per
	weapon they looked at, so the client is expected to send only on confirm and
	this is the backstop for one that does not.
]]
local EDIT_COOLDOWN = 0.25
local lastEditAt: { [Player]: number } = setmetatable({}, { __mode = "k" }) :: any

local function throttled(player: Player): boolean
	local now = os.clock()
	local last = lastEditAt[player]
	if last and now - last < EDIT_COOLDOWN then
		return true
	end
	lastEditAt[player] = now
	return false
end

-- ── public API ──────────────────────────────────────────────────────────────

--[[
	The two weapons this player should spawn with.

	Always returns a complete, legal loadout — LoadoutConfig guarantees that — so
	a caller never has to handle "no loadout". A player whose profile has not
	loaded gets the default, which is the same UMP-45 and M1911 the game has
	always started people with.
]]
function LoadoutService:getSpawnLoadout(player: Player): LoadoutConfig.Loadout
	local profiles = Registry.find("ProfileService")
	if not profiles or not profiles:isReady(player) then
		return LoadoutConfig.sanitise(nil, nil)
	end
	return profiles:activeLoadout(player)
end

function LoadoutService:getActiveIndex(player: Player): number
	local profiles = Registry.find("ProfileService")
	local profile = profiles and profiles:get(player)
	return if profile then profile.active else 1
end

--[[ Sets one of the three, server-side, from a request that has already been
     sanitised. Public so a developer command or a future preset can use the
     same path a client does. ]]
function LoadoutService:setLoadout(player: Player, index: number, slots: any): boolean
	local profiles = Registry.find("ProfileService")
	if not profiles or not profiles:isReady(player) then
		return false
	end
	return profiles:setLoadout(player, index, slots)
end

function LoadoutService:setActive(player: Player, index: number): boolean
	local profiles = Registry.find("ProfileService")
	if not profiles or not profiles:isReady(player) then
		return false
	end
	local changed = profiles:setActiveLoadout(player, index)
	if changed then
		LoadoutService.activeChanged:fire(player, LoadoutConfig.clampIndex(index))
	end
	return changed
end

-- ── lifecycle ───────────────────────────────────────────────────────────────

function LoadoutService:init() end

--[[
	Hands a player the loadout they just chose, if the round has not started.

	Without this, changing your active loadout in the lobby does nothing until
	you die — which is technically consistent and reads as broken, because the
	picker appears at exactly the moment a player is deciding what to spawn with
	and their character is usually already standing there.

	Refused once a round is RUNNING, deliberately and for the same reason the
	loadout only covers two slots: the shop is not a way to re-arm mid-fight. The
	map's weapon pickups are.
]]
local function reapply(player: Player)
	local round = Registry.find("RoundService")
	if round and typeof(round.isRunning) == "function" then
		local ok, running = pcall(round.isRunning, round)
		if ok and running then
			return
		end
	end

	local inventory = Registry.find("InventoryService")
	if not inventory or typeof(inventory.giveStartingLoadout) ~= "function" then
		return
	end
	--[[ Only for somebody who has a body to put it in. A player still in the
	     menu with no character gets it on their next spawn, which is the same
	     path and one they cannot miss. ]]
	if player.Character then
		pcall(inventory.giveStartingLoadout, inventory, player)
	end
end

function LoadoutService:start()
	serviceTrove:add(LoadoutService.activeChanged:connect(reapply))

	--[[
		A profile can land AFTER the player has already spawned.

		A DataStore read takes a moment; joining a server that is already in its
		lobby spawns you immediately. Without this, that player stands there
		holding the default UMP-45 while their profile — which says they spawn
		with an AK-12 — arrives a second later and changes nothing until they die.
	]]
	local profiles = Registry.find("ProfileService")
	if profiles and profiles.loaded then
		serviceTrove:add(profiles.loaded:connect(function(player: Player)
			reapply(player)
		end))
	end

	serviceTrove:connect(Remotes.Event.SetLoadout.OnServerEvent, function(player, payload)
		if typeof(payload) ~= "table" or throttled(player) then
			return
		end
		if self:setLoadout(player, payload.index, payload.slots) then
			--[[ Editing the loadout you are currently spawning with is the same
			     event as switching to a different one, from the player's point
			     of view: they changed what they are holding. ]]
			if LoadoutConfig.clampIndex(payload.index) == self:getActiveIndex(player) then
				reapply(player)
			end
		end
	end)

	--[[ Renaming. Through the same throttle as the other two edits: a TextBox
	     that fires on every keystroke would otherwise be a datastore write per
	     character. It does NOT reapply — a name is not something a survivor is
	     holding. ]]
	serviceTrove:connect(Remotes.Event.SetLoadoutName.OnServerEvent, function(player, payload)
		if typeof(payload) ~= "table" or throttled(player) then
			return
		end
		local store = Registry.find("ProfileService")
		if store and typeof(store.setLoadoutName) == "function" then
			store:setLoadoutName(player, payload.index, payload.name)
		end
	end)

	serviceTrove:connect(Remotes.Event.SetActiveLoadout.OnServerEvent, function(player, index)
		if throttled(player) then
			return
		end
		self:setActive(player, index)
	end)

	serviceTrove:connect(Players.PlayerRemoving, function(player: Player)
		lastEditAt[player] = nil
	end)
end

function LoadoutService:destroy()
	serviceTrove:destroy()
end

Registry.register("LoadoutService", LoadoutService)

return LoadoutService
