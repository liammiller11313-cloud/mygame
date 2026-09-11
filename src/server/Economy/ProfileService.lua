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
	    xp        lifetime experience; the level is DERIVED from it, never stored
	    scrip     the pass currency, spent on the pass and nothing else
	    quests    { [questId] = progress } for today's set, and the day it is for
	    passTier  how far along the pass track has been claimed
	    callsign  which two rewards are being worn, by id
	    accent
	    lock      the session lock above; never handed to the rest of the game

	    loadoutNames    what the player called each of the three
	    abilities       the permanent unlock set
	    abilitySlots    which two are equipped

	Nothing else — and the three above were missing from this list while
	`serialise` wrote them and `migrate` read them back, which is exactly the
	kind of quiet drift a list ending in "nothing else" invites. Round stats and
	settings are deliberately absent: this key is read and written on every join
	and leave, and every field added to it is weight on the one operation a
	player waits for.

	── WHY THE LEVEL IS NOT A FIELD ─────────────────────────────────────────────
	It would be a second copy of something `xp` already says, and the only thing
	two copies of a number can do that one cannot is disagree. Every reader calls
	ProgressionConfig.resolve, so the bar on a client and the level on the server
	are the same arithmetic on the same input. A stored level is also the field an
	exploit or a bad migration would want to write.
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attributes = require(Shared.Net.Attributes)
local EconomyConfig = require(Shared.Config.EconomyConfig)
local CodeConfig = require(Shared.Config.CodeConfig)
local PassConfig = require(Shared.Config.PassConfig)
local AbilityConfig = require(Shared.Config.AbilityConfig)
local LeaderboardConfig = require(Shared.Config.LeaderboardConfig)
local LoadoutConfig = require(Shared.Config.LoadoutConfig)
local ProgressionConfig = require(Shared.Config.ProgressionConfig)
local Registry = require(Shared.Util.Registry)
local Remotes = require(Shared.Net.Remotes)
local Signal = require(Shared.Util.Signal)
local Trove = require(Shared.Util.Trove)
local WeaponConfig = require(Shared.Config.WeaponConfig)

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

--[[
	(player: Player, grantedId: string) — this profile's unlock set just got
	bigger, by something it wrote down itself rather than something Roblox sold.

	Named for the EFFECT rather than the cause, because there are two causes and
	one effect. A code can hand over a pass (the pack, as PassConfig ids) or a
	single weapon (the birthday RPG, as a WeaponConfig id), and `grantedId` is
	whichever it was. Nothing should branch on it: the only thing a listener can
	usefully do is re-read the unlock set, which is now correct either way.

	The twin of PassService.unlocked, and it exists for the same reason: a player
	whose entitlement grows while they are standing in the lobby is still holding
	whatever they spawned with until something re-arms them.

	Two signals rather than one because the two ROADS are genuinely different
	facts from different places — Roblox answering a web call, and this profile
	reading something it stored — and neither service should have to know the
	other exists. LoadoutService listens to both and does the same thing with
	each.

	Fired only on a transition. grantPass and grantWeapon both refuse something
	already held, so redeeming the same code twice announces nothing.
]]
ProfileService.unlocked = Signal.new()

export type Profile = {
	version: number,
	dollars: number,
	owned: { [string]: boolean },
	loadouts: { LoadoutConfig.Loadout },
	loadoutNames: { string },
	active: number,
	--[[ Permanent abilities: what is unlocked, and what is equipped. A SEPARATE
	     set from `owned` on purpose — that one is validated against
	     EconomyConfig on load and drops anything it does not recognise, so an
	     ability id stored there would be deleted on the next join. Two
	     catalogues, two sets, one save. ]]
	abilities: { [string]: boolean },
	abilitySlots: { string },
	xp: number,
	scrip: number,
	--[[ Today's quest progress, keyed by quest id, and the day number it belongs
	     to. Kept together because one without the other is a set of counters
	     with no way to know whether they are stale. See ProgressionService,
	     which rolls the day on load. ]]
	quests: { [string]: number },
	questDay: number,
	--[[ The login streak, and the day number it was last claimed on. Two fields
	     and no third: whether there is something to claim RIGHT NOW is derived
	     from these plus today — see ProgressionConfig.loginStateFor. A stored
	     "pending" flag would be a third thing to keep in step with a clock, and
	     the one that goes stale is always the one that was written down. ]]
	loginStreak: number,
	loginClaimedDay: number,
	--[[ Everything this account has done since it started playing, which is what
	     the global boards rank. Separate from StatsService's per-round counters
	     and from the per-SESSION leaderstats beside them: three tallies of the
	     same events, at three different lifetimes, and the boards need the only
	     one of the three that survives a rejoin.

	     The shape is LeaderboardConfig.blankLifetime rather than a literal here,
	     so a board can never name a field this table does not have. ]]
	lifetime: { [string]: number },
	passTier: number,
	--[[ Codes this account has already redeemed, and what redeeming them handed
	     over. Both persist — see unlockedSet for why passGrants is the one thing
	     about a pass this game may write down. ]]
	redeemed: { [string]: boolean },
	passGrants: { [string]: boolean },
	--[[
		Weapons a CODE handed over, by weapon id.

		A fourth set rather than a fourth use of `owned`, and the reason is one
		line of deserialise: `owned` is filtered against EconomyConfig at load,
		because an id that left the catalogue is a weapon that was removed. A code
		weapon has no catalogue row and never will — so writing one into `owned`
		would look correct, save correctly, and be silently dropped on the very
		next join. The gift would last exactly one session.

		Filtered against WeaponConfig instead, which is the right question for a
		thing that is not for sale: does this weapon still exist.
	]]
	codeWeapons: { [string]: boolean },
	callsign: string,
	accent: string,
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
		loadoutNames = LoadoutConfig.sanitiseNames(nil),
		active = 1,
		abilities = AbilityConfig.defaultOwned(),
		abilitySlots = AbilityConfig.sanitiseSlots(nil, nil),
		xp = 0,
		scrip = 0,
		quests = {},
		questDay = 0,
		--[[ Zero, which loginStateFor reads as "never claimed" and answers with
		     day one pending. A new account's first session pays immediately,
		     which is the correct first impression of a streak. ]]
		loginStreak = 0,
		loginClaimedDay = 0,
		lifetime = LeaderboardConfig.blankLifetime(),
		passTier = 0,
		--[[ Codes already redeemed, so one cannot be claimed twice, and the
		     entitlements a code handed over. Both persist; see unlockedSet for
		     why passGrants is the one thing about a pass that this game is
		     allowed to write down. ]]
		redeemed = {},
		passGrants = {},
		codeWeapons = {},
		callsign = "",
		accent = "",
		degraded = false,
		dirty = false,
	}
end

--[[ Far enough out that no real clock reaches it, near enough that a corrupted
     value is obviously corrupt: day 4,000,000 is the year 12,920. ]]
local MAX_QUEST_DAY = 4_000_000

--[[ A number out of a DataStore, made safe. Not paranoia about players — they
     cannot write here — but about what an older version of this game wrote, and
     about the one value JSON can hold that arithmetic cannot survive: NaN, which
     compares false against itself and poisons every clamp downstream. ]]
local function storedNumber(value: any, ceiling: number): number
	if typeof(value) ~= "number" or value ~= value then
		return 0
	end
	return math.clamp(math.floor(value), 0, ceiling)
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
--[[
	Re-derives the cached equipped-ability pair from the active loadout.

	`abilitySlots` is no longer the storage — the active loadout is — but it is
	still what goes down the profile sync and into the save, because the ability
	panel and every client that reads the payload already speak that shape. So it
	is a MIRROR, and every path that can change which abilities are equipped has
	to refresh it: equipping one, editing a loadout, and switching between them.

	Kept rather than computed at the two payload sites so there is one place that
	can be wrong instead of several, and so the saved profile carries a pair that
	an older client — or a rollback — can still read.
]]
local function syncAbilityMirror(profile: Profile)
	profile.abilitySlots =
		LoadoutConfig.abilitiesOf(profile.loadouts[LoadoutConfig.clampIndex(profile.active)])
end

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

	if typeof(stored.abilities) == "table" then
		for id, value in stored.abilities do
			-- Dropped rather than kept, for the same reason an unknown weapon is.
			if value == true and AbilityConfig.get(id) then
				profile.abilities[id] = true
			end
		end
	end
	--[[ Filtered against what survived above, so a profile cannot come back with
	     an ability equipped that it no longer owns. ]]
	profile.abilitySlots = AbilityConfig.sanitiseSlots(stored.abilitySlots, profile.abilities)

	--[[
		── STRUCTURE HERE, OWNERSHIP AT THE POINT OF USE ───────────────────────
		`nil` for the owned set, and deliberately, because the set this function
		can see is the WRONG one.

		`profile.owned` is only what was bought with Dollars. A weapon that came
		with a game pass is never in it — see unlockedSet, which merges the two —
		and passing it here made every load quietly rewrite the player's saved
		loadout: a Brickbattler's Pack weapon failed the ownership test, fell back
		to the default for its slot, and was saved back over on the next write.
		Equip it, play, rejoin, and it is a UMP-45 again, with nothing anywhere
		saying why. Four weapons somebody paid a hundred Robux for, forgotten
		once per session.

		The set cannot be fixed here either. This is a pure function of what came
		out of the DataStore and has no Player to ask, and the pass answer is a
		web call that has very likely not landed yet — so even reaching for it
		would be trading a certain bug for a race.

		So this sanitises SHAPE and nothing else: a loadout that names a weapon
		which no longer exists still collapses to the default, because that is
		structural and knowable from here. Ownership is checked where the full
		set IS known — activeLoadout on the way to a spawn, setLoadout on the way
		in from a client, sync on the way out to one — all three of which already
		go through unlockedSet. A weapon this player genuinely no longer owns
		therefore stays visible in the picker and still will not spawn, which is
		the right way round: the loadout is a preference, and a preference should
		survive losing the thing it points at.
	]]
	profile.loadouts = LoadoutConfig.sanitiseAll(stored.loadouts, nil, profile.abilities)
	--[[ Names are sanitised the same way and separately from the slots, because
	     a profile saved before naming existed has loadouts and no names — see
	     sanitiseNames, which answers a default for every one it does not find. ]]
	profile.loadoutNames = LoadoutConfig.sanitiseNames(stored.loadoutNames)
	profile.active = LoadoutConfig.clampIndex(stored.active)

	--[[
		Abilities used to be one pair for the account and are now per loadout, and
		this is the one line of migration that needed.

		A profile saved before the change has loadouts with no ability keys at
		all, which sanitise above turned into three loadouts of empty slots — so a
		player who had bought and equipped two abilities would log in to find both
		unequipped and nothing saying why. Seeding every loadout from the old
		global pair means they log in with what they had, three times over, and
		can then make them differ.

		Only when a loadout has NOTHING equipped, so this cannot overwrite a
		choice somebody has already made on a newer save. It stops mattering once
		every profile has been through it, and costs one comparison until then.
	]]
	for index, loadout in profile.loadouts do
		local empty = true
		for _, id in LoadoutConfig.abilitiesOf(loadout) do
			if id ~= LoadoutConfig.NoAbility then
				empty = false
				break
			end
		end
		if empty then
			local seeded = loadout
			for slot, id in profile.abilitySlots do
				if id ~= "" then
					seeded = LoadoutConfig.withAbility(seeded, slot, id)
				end
			end
			-- nil for the same reason the sanitise above passes nil.
			profile.loadouts[index] = LoadoutConfig.sanitise(seeded, nil, profile.abilities)
		end
	end
	syncAbilityMirror(profile)

	profile.xp = storedNumber(stored.xp, ProgressionConfig.MaxXp)
	profile.scrip = storedNumber(stored.scrip, ProgressionConfig.MaxScrip)
	profile.passTier = storedNumber(stored.passTier, #ProgressionConfig.PassTrack)

	--[[ Both filtered against what still exists rather than trusted wholesale,
	     the same way abilities are above: a code retired from CodeConfig or a
	     pass renamed should not leave a key in every profile that read it, and
	     an unknown key here is either an old version of this game or a value
	     JSON gave back in a shape nobody wrote. ]]
	if typeof(stored.redeemed) == "table" then
		for code, value in stored.redeemed do
			if value == true and typeof(code) == "string" and CodeConfig.get(code) then
				profile.redeemed[CodeConfig.normalise(code)] = true
			end
		end
	end
	if typeof(stored.passGrants) == "table" then
		for passId, value in stored.passGrants do
			if value == true and typeof(passId) == "string" and PassConfig.get(passId) then
				profile.passGrants[passId] = true
			end
		end
	end
	--[[ Against WeaponConfig rather than EconomyConfig, which is the whole reason
	     this set exists separately from `owned`. See the field. ]]
	if typeof(stored.codeWeapons) == "table" then
		for weaponId, value in stored.codeWeapons do
			if value == true and typeof(weaponId) == "string" and WeaponConfig.get(weaponId) then
				profile.codeWeapons[weaponId] = true
			end
		end
	end

	--[[ Quest ids are dropped if the pool no longer carries them, for the same
	     reason an unknown weapon id is dropped from `owned`: the alternative is
	     a table that grows by three keys a day forever and is parsed on every
	     join for the rest of the game's life. ]]
	if typeof(stored.quests) == "table" then
		for id, value in stored.quests do
			if typeof(id) == "string" and ProgressionConfig.getQuest(id) then
				profile.quests[id] = storedNumber(value, ProgressionConfig.MaxXp)
			end
		end
	end
	--[[ Ceiling is its own number rather than a borrowed one: this is a day
	     count (os.time() // 86400, about 20,700 today), and clamping it against
	     an experience ceiling would only read as though the two were related. ]]
	profile.questDay = storedNumber(stored.questDay, MAX_QUEST_DAY)
	profile.loginStreak = storedNumber(stored.loginStreak, ProgressionConfig.MaxLoginStreak)
	profile.loginClaimedDay = storedNumber(stored.loginClaimedDay, MAX_QUEST_DAY)

	--[[ Read field by field off the blank rather than copied wholesale, which is
	     what makes adding a counter safe: a profile saved before the field
	     existed reads 0 for it instead of nil, and a field somebody removed from
	     the blank stops being loaded rather than lingering in every save. ]]
	if typeof(stored.lifetime) == "table" then
		for key in profile.lifetime do
			profile.lifetime[key] = storedNumber(stored.lifetime[key], LeaderboardConfig.MaxValue)
		end
	end

	--[[ A worn reward is kept only if the track still has it AND the tier it
	     sits at has actually been claimed. The second half matters: without it,
	     a profile whose passTier was clamped down by a shortened track would go
	     on wearing something it no longer owns. ]]
	for _, field in { "callsign", "accent" } do
		local kind = if field == "accent" then "Accent" else "Callsign"
		local id = stored[field]
		if typeof(id) == "string" and id ~= "" then
			local tier = ProgressionConfig.rewardTier(kind, id)
			if tier > 0 and tier <= profile.passTier then
				profile[field] = id
			end
		end
	end

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
		loadoutNames = profile.loadoutNames,
		active = profile.active,
		abilities = profile.abilities,
		abilitySlots = profile.abilitySlots,
		xp = math.clamp(math.floor(profile.xp), 0, ProgressionConfig.MaxXp),
		scrip = math.clamp(math.floor(profile.scrip), 0, ProgressionConfig.MaxScrip),
		quests = profile.quests,
		questDay = profile.questDay,
		loginStreak = profile.loginStreak,
		loginClaimedDay = profile.loginClaimedDay,
		lifetime = profile.lifetime,
		passTier = profile.passTier,
		redeemed = profile.redeemed,
		passGrants = profile.passGrants,
		codeWeapons = profile.codeWeapons,
		callsign = profile.callsign,
		accent = profile.accent,
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
--[[
	What this player may equip: what they bought, plus what their passes unlock.

	Derived on every read and never stored. `profile.owned` is the Dollars
	economy's set and it is what `serialise` writes to the DataStore — merging
	into it would put Robux entitlements in a save file, and then a save that
	fails or a key reset by hand takes away something somebody paid money for.
	That is the one rule the whole pass system is built around; see PassService.

	A fresh table each call rather than a cached one. It is a handful of string
	keys on paths that already touch a DataStore or a remote, and a cache here
	would need invalidating from PassService — which is a second thing to keep in
	step for a saving nobody can measure.

	Returns `profile.owned` itself when there is nothing to add, which is every
	player who owns no passes. Callers only ever read it.
]]
local function unlockedSet(player: Player, profile: Profile): { [string]: boolean }
	--[[ Built lazily and returned by reference when empty. Most players own no
	     passes at all, and cloning the owned set on every sanitise for them
	     would be a copy nothing ever reads. ]]
	local merged: { [string]: boolean }? = nil
	local function add(weaponId: string)
		local into = merged
		if not into then
			into = table.clone(profile.owned)
			merged = into
		end
		into[weaponId] = true
	end

	--[[ Bought from Roblox. Asked of Roblox every session and never written down
	     — that record is theirs and a DataStore of ours must not be able to lose
	     it. See PassService. ]]
	local passes: any = Registry.find("PassService")
	if passes and typeof(passes.unlockedWeapons) == "function" then
		local ok, granted = pcall(passes.unlockedWeapons, passes, player)
		if ok and typeof(granted) == "table" then
			for weaponId in granted do
				add(weaponId)
			end
		end
	end

	--[[
		Handed over by a code, and THIS one is stored — the rule inverts, on
		purpose.

		Roblox owns the record of a purchase, so writing it down would be keeping
		a second copy that can go stale or go missing. Nobody owns the record of
		a redemption except this profile: there is no authority to ask, so if it
		is not written here it did not happen. A code grant that lived only in
		memory would evaporate on rejoin, which for a two-hour launch window
		means it evaporates for everybody, permanently.

		Stored as PASS ids rather than weapon ids so a redeemer owns whatever the
		pack contains, the same as somebody who paid — if the pack grows a fifth
		weapon, both of them get it and neither list has to be found and edited.
	]]
	for passId, granted in profile.passGrants do
		if granted == true then
			local pass = PassConfig.get(passId)
			if pass then
				for _, weaponId in pass.grantsWeapons do
					add(weaponId)
				end
			end
		end
	end

	--[[
		And a weapon a code handed over directly, which is the fourth road.

		Stored as WEAPON ids rather than as pass ids, unlike the block above, and
		the difference is what the two things are. A pack is a bundle whose
		contents may grow, so a redeemer is recorded as owning the BUNDLE and gets
		whatever it later contains. A code weapon is one weapon given to one
		person; there is no bundle for it to be a member of, and inventing one
		would mean a storefront row for something that is not for sale.
	]]
	for weaponId, granted in profile.codeWeapons do
		if granted == true then
			add(weaponId)
		end
	end

	return merged or profile.owned
end

--[[
	The unlock set for EDITING loadout `index`, which is the set above plus
	whatever that loadout already names.

	── AN OWNERSHIP CHECK SHOULD GATE A CHANGE, NOT A RE-READ ──────────────────
	unlockedSet fails closed on purpose: a pass it has not heard back about yet
	reads as "no". That is right for a spawn — better to hand somebody the
	default than a weapon they might not own — and quietly destructive for an
	edit, because every write path re-sanitises the WHOLE loadout and saves the
	result. So a player whose pass had not resolved yet could open the ability
	panel, equip a perk, and have their paintball gun replaced by a UMP-45 as a
	side effect. They changed an ability. The ability code never touches a weapon
	slot. Sanitise did it on the way past.

	Grandfathering what is already stored closes every one of those doors at once
	and opens none: the only way a weapon gets INTO a stored loadout is a
	sanitise that accepted it against a real unlock set, so the invariant carries
	forward on its own. A client inventing a weapon it does not own is refused
	exactly as before — the id is not in the unlock set and not in the stored
	loadout either.

	What it deliberately does NOT do is let an ungranted weapon reach anybody's
	hands. activeLoadout still gates the spawn on unlockedSet alone. This is only
	ever about not deleting a choice somebody made.
]]
local function editableSet(player: Player, profile: Profile, index: number): { [string]: boolean }
	local set = unlockedSet(player, profile)
	local stored = profile.loadouts[index]
	if not stored then
		return set
	end
	local widened: { [string]: boolean }? = nil
	for _, slot in LoadoutConfig.Slots do
		local id = stored[slot]
		if typeof(id) == "string" and id ~= "" and not set[id] then
			if not widened then
				widened = table.clone(set)
			end
			(widened :: any)[id] = true
		end
	end
	return widened or set
end

local function publish(player: Player, profile: Profile)
	if not player.Parent then
		return
	end
	player:SetAttribute(PA.Dollars, profile.dollars)
end

--[[
	The four progression attributes. Deliberately NOT part of `publish`.

	`publish` runs from `markChanged`, which runs on every kill — three hundred
	times a round, four players. Deriving the level in there means walking the
	level curve, up to two hundred steps of it, three hundred times a round to
	re-publish a number that only moves when a round ends. None of that would be
	visible in a profile and all of it is waste.

	So this is called by the things that actually move these numbers, and by the
	load that first sets them. See the progression section below.
]]
local function publishProgression(player: Player, profile: Profile)
	if not player.Parent then
		return
	end
	--[[ Derived rather than stored, so there is exactly one place that turns XP
	     into a level and every screen in the game reads its output. See the
	     header. ]]
	local level = ProgressionConfig.resolve(profile.xp)
	player:SetAttribute(PA.Level, level)
	player:SetAttribute(PA.Scrip, profile.scrip)
	player:SetAttribute(PA.Callsign, profile.callsign)
	player:SetAttribute(PA.Accent, profile.accent)
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
		--[[ Merged, not stored. This is the only `owned` any screen ever sees, so
		     a pass-unlocked weapon un-greys in the loadout picker without any of
		     them knowing there are two currencies. serialise below still writes
		     profile.owned and must keep doing so. ]]
		owned = unlockedSet(player, profile),
		loadouts = profile.loadouts,
		loadoutNames = profile.loadoutNames,
		active = profile.active,
		--[[ Carried on the existing sync rather than through a remote of their
		     own. Every screen that reads this payload already needs all of it,
		     and a second "here is your profile, the ability half" event is a
		     second thing that can arrive out of order with the first. ]]
		abilities = profile.abilities,
		abilitySlots = profile.abilitySlots,
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
		publishProgression(player, profile)
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
local function saveProfile(player: Player, profile: Profile, release: boolean, heartbeat: boolean?): boolean
	if profile.degraded or not storeAvailable then
		return false
	end
	--[[ A clean profile is normally not worth a write, and there is one case
	     where it is: the write IS the lock refresh.

	     The autosave loop has always scheduled a clean profile at LOCK_TTL * 0.5
	     for exactly that, and this guard swallowed it — so the branch was dead,
	     lock.at was never re-stamped, and the heartbeat this file's header
	     promises did not exist. A player who browsed the shop for five minutes
	     without buying anything had a stale lock, and the next server they
	     joined took it as abandoned instead of waiting the couple of seconds for
	     this one to release it cleanly. That is a profile rolled back to
	     whatever the thief loaded. ]]
	if not profile.dirty and not release and not heartbeat then
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

--[[ Did they BUY it. Deliberately the stored set rather than unlockedSet: this
     answers a question about the Dollars economy — EconomyService asks it to
     refuse a second purchase — and a pass weapon has no shop row to buy twice.
     What a player may EQUIP is a different question with a different answer;
     that one goes through unlockedSet, and every screen sees it because `sync`
     publishes it. ]]
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

-- ── progression ─────────────────────────────────────────────────────────────

--[[
	The second axis. See ProgressionConfig for why it is separate from Dollars.

	None of these fire a full ProfileSynced. XP moves once a round and quest
	progress moves on every kill, and pushing the unlock set and three loadouts
	at a client to say a quest counter went from 41 to 42 is exactly the mistake
	`markChanged` was written to stop. Level, Scrip and the two worn rewards ride
	attributes; ProgressionService owns the one remote that carries the rest.
]]

function ProfileService:getXp(player: Player): number
	local profile = profiles[player]
	return if profile then profile.xp else 0
end

--[[ The level, derived. Deliberately not cached anywhere: `resolve` walks at
     most MaxLevel steps of integer arithmetic, and a cached level is a level
     that can be stale. ]]
function ProfileService:getLevel(player: Player): number
	local profile = profiles[player]
	if not profile then
		return 1
	end
	local level = ProgressionConfig.resolve(profile.xp)
	return level
end

--[[ Adds experience. Returns the new total AND how many levels it crossed,
     because the caller has to pay Scrip per level crossed and counting them
     again on its side would be the same loop with a second chance to be wrong.

	Never negative: XP is a record of what happened, and there is no event in
	this game that un-happens. A negative amount is a bug at the call site and is
	refused rather than quietly clamped into a no-op that looks like it worked.
]]
function ProfileService:addXp(player: Player, amount: number): (number, number)
	local profile = profiles[player]
	if not profile then
		return 0, 0
	end
	if typeof(amount) ~= "number" or amount ~= amount or amount <= 0 then
		return profile.xp, 0
	end

	local before = ProgressionConfig.resolve(profile.xp)
	profile.xp = math.clamp(math.floor(profile.xp + amount), 0, ProgressionConfig.MaxXp)
	local after = ProgressionConfig.resolve(profile.xp)

	publishProgression(player, profile)
	markChanged(player, profile, false)
	return profile.xp, math.max(after - before, 0)
end

function ProfileService:getScrip(player: Player): number
	local profile = profiles[player]
	return if profile then profile.scrip else 0
end

function ProfileService:addScrip(player: Player, amount: number): number
	local profile = profiles[player]
	if not profile then
		return 0
	end
	if typeof(amount) ~= "number" or amount ~= amount or amount == 0 then
		return profile.scrip
	end
	profile.scrip = math.clamp(math.floor(profile.scrip + amount), 0, ProgressionConfig.MaxScrip)
	publishProgression(player, profile)
	markChanged(player, profile, false)
	return profile.scrip
end

--[[
	Takes Scrip, and says whether it could.

	Separate from addScrip with a negative amount, and the difference is the
	whole point: this one REFUSES rather than clamping. A price the player cannot
	afford has to come back as a false the caller can turn into "you cannot
	afford that", not as a silent clamp to zero that spends everything they had
	and gives them the thing anyway.
]]
function ProfileService:spendScrip(player: Player, amount: number): boolean
	local profile = profiles[player]
	if not profile then
		return false
	end
	if typeof(amount) ~= "number" or amount ~= amount or amount <= 0 then
		return false
	end
	local price = math.floor(amount)
	if profile.scrip < price then
		return false
	end
	profile.scrip -= price
	publishProgression(player, profile)
	--[[ Not structural. `structural` pushes a full ProfileSynced, which carries
	     dollars, owned items and loadouts and does NOT carry Scrip — Scrip rides
	     Attributes.Player and ProgressionSynced, both of which publishProgression
	     has already sent. Asking for one here would be a whole profile over the
	     wire to tell the client something it was not going to read. Same call
	     addScrip makes, for the same reason. ]]
	markChanged(player, profile, false)
	return true
end

--[[ Today's counters, and the day they are for. Handed out by reference on
     purpose — every caller is on the server and reads it to draw or to compare;
     a clone per HUD update would be a table per kill. ]]
function ProfileService:getQuests(player: Player): ({ [string]: number }, number)
	local profile = profiles[player]
	if not profile then
		return {}, 0
	end
	return profile.quests, profile.questDay
end

--[[ Wipes the counters and stamps the new day. Called by ProgressionService when
     it notices the profile's day is not today — which is on load, and again if a
     server outlives a day boundary. ]]
function ProfileService:rollQuests(player: Player, day: number)
	local profile = profiles[player]
	if not profile or typeof(day) ~= "number" or day ~= day then
		return
	end
	local clean = math.max(math.floor(day), 0)
	if profile.questDay == clean then
		return
	end
	profile.quests = {}
	profile.questDay = clean
	markChanged(player, profile, false)
end

--[[ This account's lifetime totals, as the stored table. Read-only to callers
     by convention — recordLifetime below is the only thing that writes it, so
     that "best" and "total" are decided in one place. ]]
function ProfileService:getLifetime(player: Player): { [string]: number }
	local profile = profiles[player]
	if not profile then
		return LeaderboardConfig.blankLifetime()
	end
	return profile.lifetime
end

--[[
	Folds one round's numbers into the lifetime totals, and says which fields
	actually moved.

	The return is the point. A caller publishing to a global board needs to know
	what changed — a Best that was not beaten must not be written, because
	writing it costs a request to say nothing, and there are three boards and
	four players and a round every seventeen minutes.

	Each field is folded by its own rule: LeaderboardConfig.isBest decides
	whether a number replaces the stored one when it is larger, or adds to it.
	Getting that per-FIELD rather than per-caller is what stops a bad round
	lowering somebody's record and a good one resetting their total.
]]
function ProfileService:recordLifetime(player: Player, row: { [string]: number }?): { [string]: number }
	local profile = profiles[player]
	if not profile or typeof(row) ~= "table" then
		return {}
	end

	local moved: { [string]: number } = {}
	for key, current in profile.lifetime do
		local value = row[key]
		if typeof(value) ~= "number" or value ~= value or value <= 0 then
			continue
		end
		value = math.floor(value)

		local updated: number
		if LeaderboardConfig.isBest(key) then
			if value <= current then
				continue
			end
			updated = value
		else
			updated = current + value
		end

		updated = math.clamp(updated, 0, LeaderboardConfig.MaxValue)
		if updated == current then
			continue
		end
		profile.lifetime[key] = updated
		moved[key] = updated
	end

	if next(moved) then
		--[[ Not structural: nothing on screen reads these live, and the caller
		     flushes anyway — a round end already writes the profile for the XP
		     it just paid. ]]
		markChanged(player, profile, false)
	end
	return moved
end

--[[ The stored streak and the day it was last claimed on. Both, always: one
     without the other cannot answer any question worth asking. ]]
function ProfileService:getLoginStreak(player: Player): (number, number)
	local profile = profiles[player]
	if not profile then
		return 0, 0
	end
	return profile.loginStreak, profile.loginClaimedDay
end

--[[
	Claims today's login reward, or returns nil because there was nothing to
	claim.

	The DECISION lives here rather than in the caller, and that is the whole
	point of the method. ProgressionService could read the two fields, ask
	ProgressionConfig whether a claim is due, and then write them back — and two
	claim requests arriving in the same frame would both read "yes" before either
	wrote. Reading, deciding and writing in one call with no yield between them
	is what makes a second request on the same day return nil instead of a second
	reward.

	Returns the NEW streak, which is what the reward is looked up from. The
	caller pays; this file does not know what a Dollar is.
]]
function ProfileService:claimLogin(player: Player, day: number): number?
	local profile = profiles[player]
	if not profile or typeof(day) ~= "number" or day ~= day then
		return nil
	end
	local clean = math.max(math.floor(day), 0)

	local pending, streak =
		ProgressionConfig.loginStateFor(clean, profile.loginClaimedDay, profile.loginStreak)
	if not pending then
		return nil
	end

	profile.loginStreak = math.clamp(streak, 1, ProgressionConfig.MaxLoginStreak)
	profile.loginClaimedDay = clean
	--[[ Structural, so the client's own copy of the profile is pushed rather
	     than waiting for whatever redraws next — a streak that visibly does not
	     move after a claim reads as a claim that failed. The DataStore write is
	     the caller's: ProgressionService flushes after paying, the same as it
	     does for a round award, because the flush belongs beside the payment and
	     not beside the counter. ]]
	markChanged(player, profile, true)
	return profile.loginStreak
end

--[[
	Adds to one quest counter. Returns the new progress and whether THIS call is
	the one that finished it.

	The second return is the whole reason this is a method rather than a table
	write. A quest pays once, and "did it just cross the target" is the only
	question with an answer that cannot be re-derived later: once the counter is
	saved above the target, a server that restarts cannot tell whether the reward
	was ever paid. Crossing is detected here, at the one moment it is knowable.
]]
function ProfileService:addQuestProgress(player: Player, id: string, amount: number): (number, boolean)
	local profile = profiles[player]
	if not profile or typeof(id) ~= "string" then
		return 0, false
	end
	local quest = ProgressionConfig.getQuest(id)
	if not quest then
		return 0, false
	end
	if typeof(amount) ~= "number" or amount ~= amount or amount <= 0 then
		return profile.quests[id] or 0, false
	end

	local before = profile.quests[id] or 0
	if before >= quest.target then
		--[[ Already finished and already paid. Not clamped-and-written: a write
		     here would mark the profile dirty on every kill for the rest of a
		     round in which nothing about it changed. ]]
		return before, false
	end

	local after = math.min(before + math.floor(amount), quest.target)
	profile.quests[id] = after
	markChanged(player, profile, false)
	return after, after >= quest.target
end

function ProfileService:getPassTier(player: Player): number
	local profile = profiles[player]
	return if profile then profile.passTier else 0
end

--[[
	Buys the NEXT tier, or refuses.

	Takes no tier argument, which is the point: the caller cannot ask for tier 12
	while sitting on tier 3. The track is sequential (see ProgressionConfig) and
	the only way to express that safely is to make "next" the only thing that can
	be bought — a tier number crossing a remote is a tier number somebody will
	try to set to 20.
]]
function ProfileService:claimNextPassTier(player: Player): (boolean, string)
	local profile = profiles[player]
	if not profile then
		return false, "notready"
	end
	local wanted = profile.passTier + 1
	if wanted > #ProgressionConfig.PassTrack then
		return false, "complete"
	end
	local cost = ProgressionConfig.passCost(wanted)
	if profile.scrip < cost then
		return false, "cost"
	end
	profile.scrip -= cost
	profile.passTier = wanted

	--[[ Worn immediately. A reward that has to be bought and THEN equipped from
	     a second screen is a reward half the players never wear, and the menu
	     still offers every earlier one — see `setWorn`. ]]
	local reward = ProgressionConfig.PassTrack[wanted]
	if reward.kind == "Accent" then
		profile.accent = reward.id
	else
		profile.callsign = reward.id
	end

	publishProgression(player, profile)
	markChanged(player, profile, false)
	return true, "ok"
end

--[[ Wears a reward that has already been claimed, or takes one off with an empty
     id. Checked against `passTier` rather than against a list of what was
     granted, because the track IS the list and a second one would be a second
     thing to keep in step. ]]
function ProfileService:setWorn(player: Player, kind: string, id: string): boolean
	local profile = profiles[player]
	if not profile then
		return false
	end
	if kind ~= "Callsign" and kind ~= "Accent" then
		return false
	end
	local field = if kind == "Accent" then "accent" else "callsign"
	if typeof(id) ~= "string" then
		return false
	end
	if id ~= "" then
		--[[ Both halves matter. `tier == 0` is an id the track has never carried
		     — a stale client, or a crafted one — and `tier > passTier` is a real
		     reward that has not been paid for yet. Testing only the second lets
		     an unknown id through, because an unknown id scores 0 and 0 is not
		     greater than anything. ]]
		local tier = ProgressionConfig.rewardTier(kind, id)
		if tier <= 0 or tier > profile.passTier then
			return false
		end
	end
	if profile[field] == id then
		return false
	end
	profile[field] = id
	publishProgression(player, profile)
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

-- ── codes ───────────────────────────────────────────────────────────────────

--[[ Whether this account has already used a code. Normalised on the way in, so
     a stored key written before normalise existed still matches. ]]
function ProfileService:hasRedeemed(player: Player, code: string): boolean
	local profile = profiles[player]
	if not profile then
		return false
	end
	return profile.redeemed[CodeConfig.normalise(code)] == true
end

--[[
	Records a redemption. False when the profile is missing or the code was
	already used — and that answer is load-bearing rather than informational:
	CodeService takes it as permission to hand over the reward, so a second
	caller racing the first is refused here rather than paying twice.

	Marked structural so it reaches the DataStore. A redemption that lived only
	in memory would evaporate on rejoin, and for a two-hour window that means it
	evaporates for everybody who used it.
]]
function ProfileService:markRedeemed(player: Player, code: string): boolean
	local profile = profiles[player]
	local key = CodeConfig.normalise(code)
	if not profile or key == "" or profile.redeemed[key] then
		return false
	end
	profile.redeemed[key] = true
	markChanged(player, profile, true)
	return true
end

--[[ Hands over a pass without Roblox having sold it. The one path by which pass
     entitlement is written to a profile, and it exists because a code grant has
     no other home — see unlockedSet. ]]
function ProfileService:grantPass(player: Player, passId: string): boolean
	local profile = profiles[player]
	if not profile or not PassConfig.get(passId) or profile.passGrants[passId] then
		return false
	end
	profile.passGrants[passId] = true
	markChanged(player, profile, true)
	--[[ After markChanged, so the client has the new unlock set before anything
	     acts on it, and the weapon it is about to be handed is one its own screens
	     already agree it owns. ]]
	ProfileService.unlocked:fire(player, passId)
	return true
end

--[[
	Hands over ONE weapon, permanently, because a code said so.

	The twin of grantPass and it answers on the same signal, because what
	LoadoutService does about either is identical: the set of weapons this player
	may hold just got bigger, so re-arm them. It does not care which road it
	arrived on.

	False when the profile is missing, the id is not a weapon, or it was already
	granted — the last one matters for the same reason it does on an ability: a
	caller that has already spent something needs to know it did not have to.
]]
function ProfileService:grantWeapon(player: Player, weaponId: string): boolean
	local profile = profiles[player]
	if not profile or not WeaponConfig.get(weaponId) or profile.codeWeapons[weaponId] then
		return false
	end
	profile.codeWeapons[weaponId] = true
	markChanged(player, profile, true)
	ProfileService.unlocked:fire(player, weaponId)
	return true
end

-- ── abilities ───────────────────────────────────────────────────────────────

function ProfileService:ownsAbility(player: Player, id: string): boolean
	local profile = profiles[player]
	return profile ~= nil and profile.abilities[id] == true
end

--[[ The unlocked set, by reference. Callers on the server read it to filter or
     to sanitise; nothing mutates it except grantAbility. ]]
function ProfileService:getAbilities(player: Player): { [string]: boolean }
	local profile = profiles[player]
	return if profile then profile.abilities else {}
end

--[[ Unlocks one permanently. False when the profile is missing, the id is not
     an ability, or it was already owned — the last one matters, because a
     caller that has already taken the money needs to know it did not have to. ]]
function ProfileService:grantAbility(player: Player, id: string): boolean
	local profile = profiles[player]
	if not profile or not AbilityConfig.get(id) or profile.abilities[id] then
		return false
	end
	profile.abilities[id] = true
	markChanged(player, profile, true)
	return true
end

--[[ What the player takes into a round, which is now a property of the loadout
     they are taking rather than of the account. Everything that asks this — the
     HUD, the input dispatch, AbilityService's own validation — keeps asking the
     same question and gets an answer that changes when they switch kits. ]]
function ProfileService:getAbilitySlots(player: Player): { string }
	return LoadoutConfig.abilitiesOf(self:activeLoadout(player))
end

--[[
	Equips an ability in a slot, or clears it with "".

	Re-sanitised against what the player OWNS rather than trusting the caller,
	because the caller is a remote handler and the id came off the wire. The
	whole list goes through sanitiseSlots rather than just the one entry, so
	equipping an ability that is already in the other slot moves it instead of
	duplicating it.
]]
function ProfileService:setAbilitySlot(player: Player, slot: number, id: string): boolean
	local profile = profiles[player]
	if not profile or not AbilityConfig.isSlot(slot) then
		return false
	end
	if id ~= "" and not profile.abilities[id] then
		return false
	end

	--[[ Written into the ACTIVE loadout, which is where equipped abilities live.
	     The ability panel and the loadout screen therefore edit the same thing
	     through two different doors, and neither has to know the other exists.

	     withAbility owns the move-rather-than-duplicate rule; sanitise re-checks
	     ownership against the profile rather than trusting the caller, because
	     the id came off a wire. ]]
	local index = LoadoutConfig.clampIndex(profile.active)
	local next_ = LoadoutConfig.withAbility(profile.loadouts[index], slot, id)
	--[[ editableSet, not unlockedSet: this edits an ABILITY, and it must not be
	     able to change a weapon as a side effect. See editableSet. ]]
	local cleaned = LoadoutConfig.sanitise(next_, editableSet(player, profile, index), profile.abilities)
	if LoadoutConfig.equal(profile.loadouts[index], cleaned) then
		return false
	end

	profile.loadouts[index] = cleaned
	syncAbilityMirror(profile)
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
	return LoadoutConfig.sanitise(
		profile.loadouts[profile.active],
		unlockedSet(player, profile),
		profile.abilities
	)
end

function ProfileService:setLoadout(player: Player, index: number, loadout: any): boolean
	local profile = profiles[player]
	if not profile then
		return false
	end
	local slot = LoadoutConfig.clampIndex(index)
	--[[ Also editableSet. A client sending back the loadout it was drawing —
	     which is what the picker does on every edit, one slot changed and the
	     other two carried over — must not lose the other two because a pass has
	     not resolved yet. A weapon it does NOT already hold is still refused. ]]
	local cleaned = LoadoutConfig.sanitise(loadout, editableSet(player, profile, slot), profile.abilities)
	if LoadoutConfig.equal(profile.loadouts[slot], cleaned) then
		return false
	end
	profile.loadouts[slot] = cleaned
	--[[ An edit to the ACTIVE loadout can have changed its abilities, and the
	     mirror is what the ability panel is reading. Refreshed unconditionally
	     rather than only when slot == active: the cost is two table reads and
	     the alternative is a branch that is wrong the first time somebody makes
	     the active index change in the same breath. ]]
	syncAbilityMirror(profile)
	markChanged(player, profile, true)
	return true
end

--[[
	Renames one loadout.

	Sanitised on arrival rather than trusted: the client's TextBox has a length
	limit and a filter of its own, and both are a courtesy to the player rather
	than a property of the wire. See LoadoutConfig.sanitiseName, which is also
	where the rule that these names are OWNER-ONLY is written down.

	Returns false for a no-op so the caller does not mark a profile dirty and
	spend a datastore write on somebody clicking into a field and back out.
]]
function ProfileService:setLoadoutName(player: Player, index: number, name: any): boolean
	local profile = profiles[player]
	if not profile then
		return false
	end
	local slot = LoadoutConfig.clampIndex(index)
	local cleaned = LoadoutConfig.sanitiseName(name, slot)
	if profile.loadoutNames[slot] == cleaned then
		return false
	end
	profile.loadoutNames[slot] = cleaned
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
	--[[ Switching kits switches abilities with them — that is the whole point of
	     them living on the loadout — so the mirror the ability panel and the HUD
	     read has to follow the switch. ]]
	syncAbilityMirror(profile)
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
					local dirty = profile.dirty
					local interval = if dirty then AUTOSAVE_INTERVAL else LOCK_TTL * 0.5
					dueAt[player] = os.clock() + interval
					--[[ The clean branch asks for the write explicitly. Half the
					     lock's life is the cadence this schedule was built
					     around, and it only means anything now that saveProfile
					     stops discarding it. ]]
					saveProfile(player, profile, false, not dirty)
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
