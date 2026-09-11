--!nonstrict
--[[
	PassService — who owns a game pass, asked rather than remembered.

	── THE RULE THIS WHOLE FILE EXISTS FOR ──────────────────────────────────────
	Pass ownership is never written to a profile.

	`ProfileService.owned` is the Dollars economy's set, and it lives in a
	DataStore. DataStores fail: a read times out, a key comes back empty, a
	profile is reset by hand. Every one of those is survivable for a rifle
	somebody earned over an evening — they earn it again — and none of them is
	survivable for something they paid real money for. A player whose pass
	vanished because a save went wrong does not file a bug report, they file a
	refund request, and they are right to.

	Roblox already stores this. It is authoritative, it is permanent, and it
	cannot be lost by anything this game does. So the question is asked once per
	session, cached in memory for as long as that session lasts, and thrown away
	when the player leaves. Nothing is persisted here because nothing needs to be.

	── A FAILURE IS NOT A NO ────────────────────────────────────────────────────
	UserOwnsGamePassAsync is a web call and it throws — rate limits, an outage,
	a bad moment on Roblox's side. The tempting shape is

	    local ok, owns = pcall(...)
	    cache[player][id] = owns == true

	which caches `false` on failure and locks a paying player out for the rest of
	their session, silently, with the shop cheerfully offering to sell them what
	they already own. A failure is cached as NOTHING and retried on the next ask,
	with a short floor between attempts so a broken endpoint is not hammered.

	The shop is told the difference. "We do not know yet" draws as CHECKING…
	rather than as a price, because offering to sell somebody their own pass is
	the one outcome worth going out of the way to avoid.

	── PURCHASES LAND WITHOUT A REJOIN ──────────────────────────────────────────
	PromptGamePassPurchaseFinished fires on the server the moment Roblox takes
	the money. Without listening for it, the cached "does not own" from thirty
	seconds ago stands until the player rejoins — which is exactly when somebody
	who has just paid goes looking for what they bought.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PassConfig = require(Shared.Config.PassConfig)
local Registry = require(Shared.Util.Registry)
local Remotes = require(Shared.Net.Remotes)
local Signal = require(Shared.Util.Signal)
local Trove = require(Shared.Util.Trove)

local PassService = {}

--[[
	Retry, and the sweep that drives it.

	Caching a failure as "unknown rather than no" is only half an answer. The
	first version of this file stopped there, and the half it was missing is the
	half that matters: refreshAll ran once, on join, and nothing ever asked
	again — so a player whose check threw at exactly the wrong moment spent their
	whole session watching CHECKING… on a pass they could not buy. That is a
	worse outcome than the false-cache this file's header warns about, arrived at
	from the opposite direction.

	So the sweep re-asks. Backoff doubles per consecutive failure so a genuine
	Roblox outage is not hammered by every player on the server at once, and caps
	so a long outage still recovers within a minute of ending rather than backing
	off into next week.
]]
local RETRY_BASE = 8
local RETRY_MAX = 60
local SWEEP_INTERVAL = 2

--[[ And a floor between prompt requests, per player. The prompt itself is
     Roblox's UI and it cannot be spammed into anything harmful, but a client
     firing this every frame is still traffic worth refusing. ]]
local PROMPT_THROTTLE = 1.5

--[[ state[player][passId] = true | false. A key that is ABSENT means unknown —
     never asked, or the ask failed — and that is a different thing from false.
     Weak-keyed so a player who leaves between a request and its answer does not
     hold their own record alive. ]]
local state = (setmetatable({}, { __mode = "k" }) :: any) :: { [Player]: { [string]: boolean } }
local retryAt = (setmetatable({}, { __mode = "k" }) :: any) :: { [Player]: { [string]: number } }
local retryFor = (setmetatable({}, { __mode = "k" }) :: any) :: { [Player]: { [string]: number } }
local lastPrompt = (setmetatable({}, { __mode = "k" }) :: any) :: { [Player]: number }
local inFlight = (setmetatable({}, { __mode = "k" }) :: any) :: { [Player]: { [string]: boolean } }

--[[
	Fired when a player's pass answer turns into a YES, with the player.

	The point of it is timing rather than news. Owning a pass unlocks weapons,
	and the ask is a web call that routinely lands AFTER the player has already
	spawned in the lobby — so without this they stand there holding the default
	UMP-45 while a paintball gun they own sits one resolved promise away, and
	nothing changes until they die or touch the picker.

	LoadoutService listens and re-arms them. It is the same story its
	ProfileService.loaded hook already handles, one step further down: first the
	profile lands late, then the pass behind it does.

	Only on a transition to owned. A sweep that re-confirms what was already true
	is not news, and re-arming a player every two seconds for the rest of their
	session would be.
]]
PassService.unlocked = Signal.new()

local serviceTrove = Trove.new()

--[[ Writes an answer, and announces the one answer worth announcing. Every
     path that can turn a pass into a YES goes through here so the transition
     test lives once — see the signal's own note. ]]
local function setOwned(player: Player, passId: string, value: boolean)
	local owned = state[player]
	if not owned then
		return
	end
	local before = owned[passId]
	owned[passId] = value
	if value and before ~= true then
		PassService.unlocked:fire(player, passId)
	end
end

local function ownedTable(player: Player)
	local t = state[player]
	if not t then
		t = {}
		state[player] = t
	end
	return t
end

--[[ What the client is allowed to know: one flag per pass, and a `known` flag
     saying whether the answer is real yet. The shop draws CHECKING… on the
     difference rather than guessing. ]]
local function publish(player: Player)
	local owned = state[player]
	if not owned then
		return
	end
	local payload = {}
	for _, pass in PassConfig.Passes do
		local value = owned[pass.id]
		payload[pass.id] = {
			owns = value == true,
			known = value ~= nil,
		}
	end
	Remotes.Event.PassesSynced:FireClient(player, payload)

	--[[ And the profile behind it. Everything that asks "do I own this weapon" —
	     the loadout picker, the shop row, sanitise — reads the profile's owned
	     set, not this event, because they were written before there were two
	     currencies and should not have to learn. ProfileService merges the pass
	     grants into what it publishes, so a resolved pass only reaches those
	     screens if the profile is re-sent after it.

	     Guarded rather than required: pass ownership is still correct without
	     ProfileService, the weapons just do not appear until something else
	     causes a sync. ]]
	local profiles: any = Registry.find("ProfileService")
	if profiles and typeof(profiles.sync) == "function" then
		profiles:sync(player)
	end
end

--[[
	Asks Roblox, once, and remembers the answer for this session.

	Never yields the caller into a second ask for the same pass: `inFlight` is
	what stops four screens opening at once turning into four web calls, and what
	stops a client that fires the remote repeatedly from doing the same.
]]
local function refresh(player: Player, pass: PassConfig.Pass): boolean?
	--[[ Left already. Checked before ownedTable, which would otherwise recreate
	     the record PlayerRemoving has just cleared — and the sweep runs on a
	     spawned thread, so a player can leave between its turn and its call. ]]
	if player.Parent == nil then
		return nil
	end

	local owned = ownedTable(player)
	if owned[pass.id] ~= nil then
		return owned[pass.id]
	end

	local flights = inFlight[player]
	if not flights then
		flights = {}
		inFlight[player] = flights
	end
	if flights[pass.id] then
		return nil -- somebody else is already asking
	end

	local clocks = retryAt[player]
	if clocks and clocks[pass.id] and os.clock() < clocks[pass.id] then
		return nil -- a recent ask threw; not yet
	end

	flights[pass.id] = true
	local ok, result = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(player.UserId, pass.gamePassId)
	end)
	flights[pass.id] = nil

	if not ok then
		--[[ Cached as nothing, deliberately. Writing `false` here is the bug this
		     file's header is about: it would lock a paying player out for the
		     rest of their session and offer to sell them their own pass. ]]
		if not clocks then
			clocks = {}
			retryAt[player] = clocks
		end
		local waits = retryFor[player]
		if not waits then
			waits = {}
			retryFor[player] = waits
		end
		waits[pass.id] = math.min((waits[pass.id] or RETRY_BASE) * 2, RETRY_MAX)
		clocks[pass.id] = os.clock() + waits[pass.id]
		warn(string.format("PassService: ownership check failed for %s (%s)", pass.id, tostring(result)))
		return nil
	end

	-- A success clears the backoff, so one bad minute does not slow the next.
	local waits = retryFor[player]
	if waits then
		waits[pass.id] = nil
	end
	setOwned(player, pass.id, result == true)
	return owned[pass.id]
end

--[[ Whether any pass is still unanswered for this player. The sweep's only
     question, asked without touching the network. ]]
local function hasUnknown(player: Player): boolean
	local owned = state[player]
	if not owned then
		return false
	end
	for _, pass in PassConfig.Passes do
		if owned[pass.id] == nil then
			return true
		end
	end
	return false
end

--[[ The public question. Returns false for "asked, and no" AND for "do not know
     yet", because a caller deciding whether to hand out a weapon has to fail
     closed. Callers that need to tell the two apart use `isKnown`. ]]
function PassService:owns(player: Player, passId: string): boolean
	local pass = PassConfig.get(passId)
	if not pass then
		return false
	end
	return refresh(player, pass) == true
end

--[[
	Every weapon this player's passes unlock, as an ownership set.

	The shape LoadoutConfig.sanitise wants, so ProfileService can merge it with
	the profile's own set and hand the result to a function that never learns
	there are two currencies.

	Empty for a player whose checks have not resolved, which is the correct fail:
	a weapon that briefly does not appear is a redraw away from appearing, and
	one that briefly DOES is a weapon somebody equips and then loses at spawn.
]]
function PassService:unlockedWeapons(player: Player): { [string]: boolean }
	local unlocked = {}
	for _, pass in PassConfig.Passes do
		if self:owns(player, pass.id) then
			for _, weaponId in pass.grantsWeapons do
				unlocked[weaponId] = true
			end
		end
	end
	return unlocked
end

function PassService:isKnown(player: Player, passId: string): boolean
	local owned = state[player]
	return owned ~= nil and owned[passId] ~= nil
end

--[[ Every pass, resolved and published. Called on join, by the sweep, and after
     a purchase. Publishes only when an answer actually changed: a sweep that
     resolves nothing — the common case once everybody is settled — should cost
     no traffic at all. ]]
function PassService:refreshAll(player: Player, force: boolean?)
	local before = {}
	local owned = state[player]
	if owned then
		for _, pass in PassConfig.Passes do
			before[pass.id] = owned[pass.id]
		end
	end

	local changed = false
	for _, pass in PassConfig.Passes do
		refresh(player, pass)
		if state[player] and state[player][pass.id] ~= before[pass.id] then
			changed = true
		end
	end

	if changed or force then
		publish(player)
	end
end

local function onJoin(player: Player)
	state[player] = {}
	--[[ Off the join thread. UserOwnsGamePassAsync is a web call per pass, and
	     a slow one would hold up everything else waiting on PlayerAdded. ]]
	task.spawn(function()
		--[[ Forced, because a client that hears nothing keeps its own defaults and
		     the shop cannot tell "still checking" from "server never answered".
		     Every later publish is earned by a change. ]]
		PassService:refreshAll(player, true)
	end)
end

function PassService:init()
	serviceTrove:connect(Players.PlayerAdded, onJoin)
	for _, player in Players:GetPlayers() do
		onJoin(player)
	end

	serviceTrove:connect(Players.PlayerRemoving, function(player: Player)
		state[player] = nil
		retryAt[player] = nil
		retryFor[player] = nil
		lastPrompt[player] = nil
		inFlight[player] = nil
	end)
end

--[[
	Re-asks for anybody still unanswered.

	One player per tick rather than all of them: an outage means every player on
	the server is unknown at once, and asking for all of them in the same frame
	is the thundering herd that keeps the outage going. Round-robin over the
	roster spreads it, and each player's own backoff decides whether their turn
	actually spends a call.
]]
local sweepIndex = 1
local sweepClock = 0

local function sweep(dt: number)
	sweepClock += dt
	if sweepClock < SWEEP_INTERVAL then
		return
	end
	sweepClock = 0

	local roster = Players:GetPlayers()
	if #roster == 0 then
		sweepIndex = 1
		return
	end
	if sweepIndex > #roster then
		sweepIndex = 1
	end

	local player = roster[sweepIndex]
	sweepIndex += 1
	if player and hasUnknown(player) then
		task.spawn(function()
			PassService:refreshAll(player)
		end)
	end
end

function PassService:start()
	serviceTrove:connect(RunService.Heartbeat, sweep)

	--[[ The client asks to be shown the prompt rather than calling
	     PromptGamePassPurchase itself. A client CAN prompt on its own — it is not
	     a security boundary — but routing it here means one place knows which
	     passes exist, and a request naming a pass that does not is refused
	     instead of opening Roblox's "this item is unavailable" dialog. ]]
	serviceTrove:connect(
		Remotes.Event.RequestPassPurchase.OnServerEvent,
		function(player: Player, passId: any)
			if typeof(passId) ~= "string" then
				return
			end
			local pass = PassConfig.get(passId)
			if not pass then
				return
			end

			local now = os.clock()
			if lastPrompt[player] and now - lastPrompt[player] < PROMPT_THROTTLE then
				return
			end
			lastPrompt[player] = now

			-- Already theirs: re-publish rather than prompting them to buy it twice.
			if PassService:owns(player, pass.id) then
				publish(player)
				return
			end

			local ok, err = pcall(function()
				MarketplaceService:PromptGamePassPurchase(player, pass.gamePassId)
			end)
			if not ok then
				warn(string.format("PassService: prompt failed for %s (%s)", pass.id, tostring(err)))
			end
		end
	)

	--[[ The money has changed hands. Written straight into the cache rather than
	     re-asked, because Roblox's own ownership endpoint can lag its purchase
	     signal by a few seconds — and the player is looking at the screen now. ]]
	serviceTrove:connect(
		MarketplaceService.PromptGamePassPurchaseFinished,
		function(player: Player, gamePassId: number, purchased: boolean)
			if not purchased then
				return
			end
			local pass = PassConfig.byGamePassId(gamePassId)
			if not pass then
				return
			end
			ownedTable(player)
			setOwned(player, pass.id, true)
			publish(player)
		end
	)
end

function PassService:destroy()
	serviceTrove:destroy()
end

Registry.register("PassService", PassService)

return PassService
