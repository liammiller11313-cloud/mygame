--!nonstrict
--[[
	ProfileService — the only thing in Fading Light that remembers you.

	Dollars, what you own, and your three loadouts. Everything else in this game
	is round-scoped and dies with the server; this is the one file where a bug
	costs a player something they cannot get back, so it is written defensively
	and the defensiveness is the interesting part.

	── THE ONE RULE ─────────────────────────────────────────────────────────────
	A profile that failed to LOAD is never SAVED.

	Every other rule here follows from that one. If the DataStore is down, or API
	access is off, or the read timed out, this service hands the player a working
	default profile and marks it `degraded` — they can play, buy and equip for the
	session — and then never writes a byte. The alternative is a transient outage
	silently replacing somebody's forty rounds of progress with a starting
	balance, which is the single worst thing this file could do.

	── SESSION LOCKING ──────────────────────────────────────────────────────────
	Roblox will happily run the same player in two servers at once — a teleport
	that is mid-flight, a rejoin before the old server noticed they left. Without
	a lock, both write, and the last writer wins with a stale copy: money spent in
	one server reappears in the other.

	So the profile carries `lock = { jobId, at }`. Loading takes the lock inside
	an UpdateAsync (which is atomic per key), refuses while somebody else's lock
	is FRESH, and steals it once it has gone stale. The lock is refreshed on every
	autosave, so "stale" means "that server stopped saving", which means it is
	gone. A server that cannot refresh its lock stops trusting it and stops
	writing.

	── WHY UpdateAsync FOR EVERYTHING ───────────────────────────────────────────
	Never Get-then-Set. Between a read and a write another server can take the
	lock, and a Set has no way to notice. UpdateAsync is the only operation on
	this key, on every path, including release.

	── WHAT IS ACTUALLY STORED ──────────────────────────────────────────────────
	    version   the shape number, so an old profile can be migrated rather than
	              discarded — see `migrate`
	    dollars   clamped into EconomyConfig's range on the way in AND out
	    owned     { [itemId] = true }; unknown ids are dropped on load, so a
	              weapon removed from the game does not haunt a save forever
	    loadouts  three, each sanitised against `owned` by LoadoutConfig
	    active    which of the three you spawn with
	    lock      the session lock above; never handed to the rest of the game

	Nothing else. Stats, cosmetics and settings are deliberately absent: this key
	is read and written on every join and leave, and every field added to it is
	weight on the one operation a player waits for.
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attributes = require(Shared.Net.Attributes)
local EconomyConfig = require(Shared.Config.EconomyConfig)
local LoadoutConfig = require(Shared.Config.LoadoutConfig)
local Registry = require(Shared.Util.Registry)
local Remotes = require(Shared.Net.Remotes)
local Signal = require(Shared.Util.Signal)
local Trove = require(Shared.Util.Trove)

local PA = Attributes.Player

--[[ Bumped only when the stored SHAPE changes in a way `migrate` has to know
     about. Renaming a weapon does not need it; moving `owned` from a list to a
     set would. ]]
local PROFILE_VERSION = 1

--[[ The store name carries the version too. If a migration is ever too complex
     to do in `migrate`, a new store is the escape hatch that leaves every old
     profile intact and readable. ]]
local STORE_NAME = "FL_Profiles_v1"
local KEY_PREFIX = "player_"

--[[
	How long a lock is trusted after its last refresh.

	Longer than AUTOSAVE_INTERVAL by a wide margin, because the cost of the two
	being close is a server stealing a lock from a healthy server that was merely
	slow. Four missed autosaves is not slowness, it is a server that is gone.
]]
local AUTOSAVE_INTERVAL = 60
local LOCK_TTL = 300

--[[ How many times a load or a save is retried before giving up, and how long
     the wait grows between attempts. DataStore failures are overwhelmingly
     transient — a throttle, a brief outage — and a profile that gave up after
     one attempt would degrade a lot of sessions that did not need to be. ]]
local MAX_ATTEMPTS = 5
local RETRY_BASE = 1.5

--[[ A load that takes longer than this hands the player a degraded profile
     rather than leaving them staring at a menu that will not open. They can
     still play; nothing will be written. ]]
local LOAD_TIMEOUT = 30

--[[ How often one client may ask for its profile. A booting client asks once;
     anything faster than this is not a booting client. ]]
local REQUEST_COOLDOWN = 1.0

local ProfileService = {}

--[[ (player: Player, profile: Profile) — fired once per player, after their
     profile is in memory and their attributes are published. Anything that
     needs to know what a player owns waits on this rather than polling. ]]
ProfileService.loaded = Signal.new()

--[[ (player: Player, profile: Profile) — after anything changed. The one place
     the client is re-synced from. ]]
ProfileService.changed = Signal.new()

export type Profile = {
	version: number,
	dollars: number,
	owned: { [string]: boolean },
	loadouts: { LoadoutConfig.Loadout },
	active: number,
	--[[ Not persisted. True when this profile could not be read and must never
	     be written — see THE ONE RULE. ]]
	degraded: boolean,
	--[[ Not persisted. Set by anything that changes the profile; cleared by a
	     successful save, so a quiet session costs no DataStore writes at all. ]]
	dirty: boolean,
}

local serviceTrove = Trove.new()
local profiles: { [Player]: Profile } = {}

--[[ Players whose load is still in flight. A second load for the same player —
     a rejoin inside one server's lifetime — must not race the first. ]]
local loading: { [Player]: boolean } = {}

--[[ When each player's next save is due, as os.clock(). Held outside the
     profile because it is scheduling rather than state, and a profile is a
     thing that gets serialised. ]]
local dueAt: { [Player]: number } = {}

local store: DataStore? = nil
local storeAvailable = false

--[[ This server's identity for the lock. JobId is empty in Studio, where there
     is only ever one server, so a constant is both correct and obvious in a
     stored profile somebody is inspecting by hand. ]]
local JOB_ID = if game.JobId ~= "" then game.JobId else "studio"

local function keyFor(player: Player): string
	return KEY_PREFIX .. tostring(player.UserId)
end

local warned: { [string]: boolean } = {}
local function warnOnce(tag: string, message: string)
	if warned[tag] then
		return
	end
	warned[tag] = true
	warn("[ProfileService] " .. message)
end

-- ── the shape ───────────────────────────────────────────────────────────────

local function blankProfile(): Profile
	return {
		version = PROFILE_VERSION,
		dollars = EconomyConfig.StartingDollars,
		owned = EconomyConfig.defaultOwned(),
		loadouts = LoadoutConfig.sanitiseAll(nil, nil),
		active = 1,
		degraded = false,
		dirty = false,
	}
end

--[[
	Whatever came out of the DataStore, turned into something this game can use.

	Everything is checked rather than trusted, and not because a player can write
	here — they cannot. A stored profile is old code's output: it was written by
	a version of this game that may have had different weapons, a different
	starting balance, and a different idea of how many loadouts there are.

	The free weapons are re-granted on every load rather than only at creation.
	If a weapon's price is ever dropped to zero, everybody gets it immediately,
	and a profile saved before that weapon existed is not permanently missing it.
]]
local function migrate(stored: any): Profile
	local profile = blankProfile()
	if typeof(stored) ~= "table" then
		return profile
	end

	if typeof(stored.dollars) == "number" and stored.dollars == stored.dollars then
		profile.dollars = math.clamp(math.floor(stored.dollars), 0, EconomyConfig.MaxDollars)
	end

	if typeof(stored.owned) == "table" then
		for id, value in stored.owned do
			--[[ Dropped rather than kept: an id no longer in the catalogue is a
			     weapon that was removed, and carrying it forever means every
			     future load pays to parse it. ]]
			if value == true and typeof(id) == "string" and EconomyConfig.get(id) then
				profile.owned[id] = true
			end
		end
	end
	-- Free things are free, retroactively. See the note above.
	for id in EconomyConfig.defaultOwned() do
		profile.owned[id] = true
	end

	profile.loadouts = LoadoutConfig.sanitiseAll(stored.loadouts, profile.owned)
	profile.active = LoadoutConfig.clampIndex(stored.active)
	return profile
end

--[[ The part of a profile that is written. Deliberately built by hand rather
     than by copying the table: `degraded` and `dirty` are session state and
     writing either of them into a save would be a bug that outlived the
     session. ]]
local function serialise(profile: Profile, lock: any): any
	return {
		version = PROFILE_VERSION,
		dollars = math.clamp(math.floor(profile.dollars), 0, EconomyConfig.MaxDollars),
		owned = profile.owned,
		loadouts = profile.loadouts,
		active = profile.active,
		lock = lock,
	}
end

-- ── the store ───────────────────────────────────────────────────────────────

--[[
	Whether a stored lock still belongs to somebody.

	Ours is always free to take. Somebody else's is respected until it goes
	stale, because a fresh lock means that server is still autosaving, which
	means it is still playing.
]]
local function lockIsFree(lock: any): boolean
	if typeof(lock) ~= "table" then
		return true
	end
	if lock.jobId == JOB_ID then
		return true
	end
	if typeof(lock.at) ~= "number" then
		return true
	end
	return os.time() - lock.at > LOCK_TTL
end

--[[ One UpdateAsync, retried with a growing wait. Returns the transform's
     result, or nil after MAX_ATTEMPTS — which every caller treats as "do not
     proceed" rather than as "there was nothing there". ]]
local function update(key: string, transform: (any) -> any?): (boolean, any)
	if not store then
		return false, nil
	end
	for attempt = 1, MAX_ATTEMPTS do
		local ok, result = pcall(function()
			return (store :: DataStore):UpdateAsync(key, transform)
		end)
		if ok then
			return true, result
		end
		warnOnce(
			"update:" .. tostring(result),
			string.format("UpdateAsync failed (attempt %d/%d): %s", attempt, MAX_ATTEMPTS, tostring(result))
		)
		if attempt < MAX_ATTEMPTS then
			task.wait(RETRY_BASE ^ attempt)
		end
	end
	return false, nil
end

-- ── loading ─────────────────────────────────────────────────────────────────

--[[ The balance, as an attribute, which is how every client learns it. There is
     deliberately no "profile is ready" attribute alongside it: `isReady` on this
     service is the server's gate and `ProfileSynced` is the client's, and a
     third answer to the same question is a third thing that can disagree. ]]
local function publish(player: Player, profile: Profile)
	if not player.Parent then
		return
	end
	player:SetAttribute(PA.Dollars, profile.dollars)
end

--[[ The whole profile, to the one client it belongs to. Sent on load and after
     every change; there is no partial update, because every screen that reads
     this needs all of it and a half-synced shop draws a half-truth. ]]
function ProfileService:sync(player: Player)
	local profile = profiles[player]
	if not profile or not player.Parent then
		return
	end
	Remotes.Event.ProfileSynced:FireClient(player, {
		dollars = profile.dollars,
		owned = profile.owned,
		loadouts = profile.loadouts,
		active = profile.active,
		degraded = profile.degraded,
	})
end

--[[
	Records a change, and tells the client about it in the cheapest way that
	works.

	`structural` is the whole distinction, and getting it wrong is expensive. A
	balance move is one number and rides the attribute, which Roblox replicates
	for nothing; a change to what you OWN or what your loadouts are has no
	attribute and needs the full profile.

	This was `sync` on every path at first, which meant every kill fired the
	entire profile — the unlock set and all three loadouts — at that client.
	Three hundred kills a round, four players, to say a number that was already
	on its way as an attribute. It is exactly the thing Shared/Net/Remotes' own
	header says not to do.
]]
local function markChanged(player: Player, profile: Profile, structural: boolean)
	profile.dirty = true
	publish(player, profile)
	if structural then
		ProfileService:sync(player)
	end
	ProfileService.changed:fire(player, profile)
end

--[[
	Takes the lock and reads the profile, in one atomic operation.

	Returning nil from an UpdateAsync transform ABORTS the write, which is how a
	locked profile is refused without touching it. The retry loop above then
	tries again — so a player joining a moment after leaving another server waits
	for that server's release rather than being handed a stale copy.
]]
local function acquire(player: Player): Profile?
	local key = keyFor(player)
	local refused = false
	--[[ Carried out of the transform rather than re-derived from what
	     UpdateAsync returned. Migrating the serialised result would work —
	     `migrate` is idempotent on its own output — but it would run the whole
	     validation pass twice on every join for no reason, and it would hide the
	     fact that these are the same object. ]]
	local acquired: Profile? = nil

	local ok = update(key, function(old)
		if not lockIsFree(old and old.lock) then
			refused = true
			acquired = nil
			return nil
		end
		refused = false
		acquired = migrate(old)
		return serialise(acquired :: Profile, { jobId = JOB_ID, at = os.time() })
	end)

	if not ok or refused then
		return nil
	end
	return acquired
end

local function loadProfile(player: Player)
	if profiles[player] or loading[player] then
		return
	end
	loading[player] = true

	task.spawn(function()
		local profile: Profile? = nil
		local deadline = os.clock() + LOAD_TIMEOUT

		if storeAvailable then
			while os.clock() < deadline and player.Parent do
				profile = acquire(player)
				if profile then
					break
				end
				--[[ Refused because somebody else holds a fresh lock. Wait and
				     try again rather than stealing: the other server is almost
				     always this player's previous session, releasing right now. ]]
				task.wait(2)
			end
		end

		loading[player] = nil
		if not player.Parent then
			return
		end

		if not profile then
			--[[ THE ONE RULE. A profile we could not read is a profile we must
			     never write, so this one is marked and the save path skips it
			     for the rest of the session. The player can still play, buy and
			     equip; none of it survives the server. ]]
			profile = blankProfile()
			profile.degraded = true
			warnOnce(
				"degraded",
				string.format(
					"could not load a profile for %s — running in memory for this session, "
						.. "and NOTHING will be saved. Check that Studio API access is enabled, "
						.. "or that DataStores are not currently failing.",
					player.Name
				)
			)
		end

		profiles[player] = profile
		--[[ Staggered from the moment they joined rather than from server start,
		     which is what spreads four players' writes apart. ]]
		dueAt[player] = os.clock() + AUTOSAVE_INTERVAL
		publish(player, profile)
		ProfileService:sync(player)
		ProfileService.loaded:fire(player, profile)
	end)
end

-- ── saving ──────────────────────────────────────────────────────────────────

--[[
	Writes a profile back, refreshing or dropping the lock.

	Refuses in three cases, all of them "we do not have the right to write this":
	the profile is degraded, the store is unavailable, or the stored lock now
	belongs to another server — which means ours went stale and somebody else
	took it, and whatever they have is newer than whatever we have.
]]
local function saveProfile(player: Player, profile: Profile, release: boolean): boolean
	if profile.degraded or not storeAvailable then
		return false
	end
	if not profile.dirty and not release then
		return true
	end

	local lostLock = false
	local ok = update(keyFor(player), function(old)
		local lock = old and old.lock
		if typeof(lock) == "table" and lock.jobId ~= JOB_ID and not lockIsFree(lock) then
			--[[ Another server holds a fresh lock on this key. Ours expired and
			     was stolen, which means that session is authoritative now. Write
			     nothing: our copy is the stale one. ]]
			lostLock = true
			return nil
		end
		return serialise(profile, if release then nil else { jobId = JOB_ID, at = os.time() })
	end)

	if lostLock then
		warnOnce(
			"lostlock",
			string.format(
				"another server took the session lock for %s; this server stopped saving them",
				player.Name
			)
		)
		profile.degraded = true
		return false
	end
	if ok then
		profile.dirty = false
	end
	return ok
end

local function releaseProfile(player: Player)
	local profile = profiles[player]
	profiles[player] = nil
	loading[player] = nil
	dueAt[player] = nil
	if profile then
		saveProfile(player, profile, true)
	end
end

-- ── public API ──────────────────────────────────────────────────────────────

function ProfileService:get(player: Player): Profile?
	return profiles[player]
end

--[[ Whether this player's profile is in memory. Everything that spends, grants
     or equips checks this first: a purchase against a profile that has not
     loaded is a purchase against somebody's real balance a second later. ]]
function ProfileService:isReady(player: Player): boolean
	return profiles[player] ~= nil
end

function ProfileService:owns(player: Player, itemId: string): boolean
	local profile = profiles[player]
	return profile ~= nil and profile.owned[itemId] == true
end

function ProfileService:getDollars(player: Player): number
	local profile = profiles[player]
	return if profile then profile.dollars else 0
end

--[[ Adds (or, with a negative amount, removes) Dollars. Returns the new
     balance. Clamped at both ends: a balance can never go negative and never
     past the storage ceiling, whatever the caller believes. ]]
function ProfileService:addDollars(player: Player, amount: number): number
	local profile = profiles[player]
	if not profile or typeof(amount) ~= "number" or amount ~= amount or amount == 0 then
		return if profile then profile.dollars else 0
	end
	profile.dollars = math.clamp(math.floor(profile.dollars + amount), 0, EconomyConfig.MaxDollars)
	--[[ Not structural: the balance is an attribute and is already on its way.
	     See markChanged — this is the call that fires on every kill. ]]
	markChanged(player, profile, false)
	return profile.dollars
end

--[[ Spends, atomically from the caller's point of view: either the money left
     the balance and this returned true, or nothing happened. Nothing else in
     the codebase may write `dollars` down. ]]
function ProfileService:trySpend(player: Player, amount: number): boolean
	local profile = profiles[player]
	if not profile or typeof(amount) ~= "number" or amount ~= amount or amount < 0 then
		return false
	end
	if profile.dollars < amount then
		return false
	end
	profile.dollars -= math.floor(amount)
	markChanged(player, profile, false)
	return true
end

--[[ Marks something owned. Idempotent: granting what a player already has is a
     no-op rather than a second write, so a re-grant on every load costs
     nothing. ]]
function ProfileService:grant(player: Player, itemId: string): boolean
	local profile = profiles[player]
	if not profile or typeof(itemId) ~= "string" or profile.owned[itemId] then
		return false
	end
	profile.owned[itemId] = true
	markChanged(player, profile, true)
	return true
end

function ProfileService:getLoadouts(player: Player): { LoadoutConfig.Loadout }
	local profile = profiles[player]
	return if profile then profile.loadouts else LoadoutConfig.sanitiseAll(nil, nil)
end

--[[ The loadout this player spawns with. Sanitised again on the way out, not
     out of paranoia: a weapon can leave the catalogue between a save and a
     spawn, and this is the last point at which that can be caught before
     somebody spawns holding nothing. ]]
function ProfileService:activeLoadout(player: Player): LoadoutConfig.Loadout
	local profile = profiles[player]
	if not profile then
		return LoadoutConfig.sanitise(nil, nil)
	end
	return LoadoutConfig.sanitise(profile.loadouts[profile.active], profile.owned)
end

function ProfileService:setLoadout(player: Player, index: number, loadout: any): boolean
	local profile = profiles[player]
	if not profile then
		return false
	end
	local slot = LoadoutConfig.clampIndex(index)
	local cleaned = LoadoutConfig.sanitise(loadout, profile.owned)
	if LoadoutConfig.equal(profile.loadouts[slot], cleaned) then
		return false
	end
	profile.loadouts[slot] = cleaned
	markChanged(player, profile, true)
	return true
end

function ProfileService:setActiveLoadout(player: Player, index: number): boolean
	local profile = profiles[player]
	if not profile then
		return false
	end
	local wanted = LoadoutConfig.clampIndex(index)
	if profile.active == wanted then
		return false
	end
	profile.active = wanted
	markChanged(player, profile, true)
	return true
end

--[[ Whether this session's profile is running in memory only. The shop reads it
     to say so rather than letting a player buy things that will not be there
     tomorrow without warning them. ]]
function ProfileService:isDegraded(player: Player): boolean
	local profile = profiles[player]
	return profile == nil or profile.degraded
end

--[[ Forces a save now. For anything that has just done something a player would
     be upset to lose — a purchase — rather than waiting up to a minute for the
     autosave to come round. ]]
function ProfileService:flush(player: Player): boolean
	local profile = profiles[player]
	if not profile then
		return false
	end
	return saveProfile(player, profile, false)
end

-- ── lifecycle ───────────────────────────────────────────────────────────────

function ProfileService:init()
	--[[ GetDataStore itself can throw — in Studio with API access off, and in
	     any context where the service is unavailable. Everything past here is
	     written to work without it. ]]
	local ok, result = pcall(function()
		return DataStoreService:GetDataStore(STORE_NAME)
	end)
	if ok and result then
		store = result
		storeAvailable = true
	else
		warnOnce(
			"nostore",
			"DataStores are unavailable, so nothing will be saved this session. "
				.. "In Studio, tick Game Settings > Security > Enable Studio Access to API Services."
		)
	end

	for _, player in Players:GetPlayers() do
		loadProfile(player)
	end
	serviceTrove:connect(Players.PlayerAdded, loadProfile)
	serviceTrove:connect(Players.PlayerRemoving, releaseProfile)

	--[[ A profile can finish loading before its client has finished booting, in
	     which case the sync above fired into a listener that did not exist yet.
	     The client asks once when it is ready; a request for a profile that has
	     not loaded is answered by the load itself, a moment later. ]]
	--[[ Throttled, because it is a client-triggered full-profile send and there
	     is nothing stopping a crafted client asking for one every frame. Once a
	     second is far more than the one call a booting client actually makes. ]]
	local lastRequestAt: { [Player]: number } = setmetatable({}, { __mode = "k" }) :: any
	serviceTrove:connect(Remotes.Event.RequestProfile.OnServerEvent, function(player: Player)
		local now = os.clock()
		if lastRequestAt[player] and now - lastRequestAt[player] < REQUEST_COOLDOWN then
			return
		end
		lastRequestAt[player] = now
		ProfileService:sync(player)
	end)
end

function ProfileService:start()
	--[[
		The autosave, and the lock heartbeat: they are the same write.

		One loop at 1Hz rather than a thread per player, and each player carries
		their own due time from whenever they joined — so four players on a full
		server are saved at four different moments rather than handing the
		DataStore four writes in the same frame every minute.

		A CLEAN profile is still written, at a slower cadence, because the write
		is also the lock refresh: a player who buys nothing for ten minutes must
		not have their lock go stale underneath them and get stolen by the next
		server they join.
	]]
	serviceTrove:add(task.spawn(function()
		--[[ Reused rather than reallocated: this runs once a second forever, and
		     a fresh table per tick is a table per second for the life of the
		     server to hold at most four players. ]]
		local due: { Player } = {}

		while true do
			task.wait(1)
			local now = os.clock()

			--[[
				Collected FIRST, then saved.

				saveProfile yields — UpdateAsync is a network call — and yielding
				inside `for player, profile in profiles` is a real hazard rather
				than a stylistic one: a player joining during that yield adds a
				key to the table being traversed, which is undefined in Lua and
				shows up as "invalid key to 'next'" at some later, unrelated
				moment.
			]]
			table.clear(due)
			for player, profile in profiles do
				if not profile.degraded and now >= (dueAt[player] or 0) then
					table.insert(due, player)
				end
			end

			for _, player in due do
				--[[ Re-read: this player may have left, or been saved and
				     released, while an earlier save in this same batch yielded. ]]
				local profile = profiles[player]
				if profile and not profile.degraded then
					local interval = if profile.dirty then AUTOSAVE_INTERVAL else LOCK_TTL * 0.5
					dueAt[player] = os.clock() + interval
					saveProfile(player, profile, false)
				end
			end
		end
	end))

	--[[
		The shutdown save.

		BindToClose gets a few seconds before the server is killed, and it is the
		only chance to release locks — without it every player who was online at
		a shutdown waits out LOCK_TTL before they can play again. Saves run in
		parallel because the budget is wall-clock, not work.
	]]
	game:BindToClose(function()
		if RunService:IsStudio() then
			return
		end
		local pending = 0
		for player, profile in profiles do
			pending += 1
			task.spawn(function()
				saveProfile(player, profile, true)
				pending -= 1
			end)
		end
		local deadline = os.clock() + 20
		while pending > 0 and os.clock() < deadline do
			task.wait(0.1)
		end
	end)
end

function ProfileService:destroy()
	for player in profiles do
		releaseProfile(player)
	end
	serviceTrove:destroy()
end

Registry.register("ProfileService", ProfileService)

return ProfileService
