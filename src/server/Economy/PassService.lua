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
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PassConfig = require(Shared.Config.PassConfig)
local Registry = require(Shared.Util.Registry)
local Remotes = require(Shared.Net.Remotes)
local Trove = require(Shared.Util.Trove)

local PassService = {}

--[[ How long to wait before asking Roblox again after a call that threw. Long
     enough that an outage is not hammered, short enough that a player who was
     unlucky on join does not spend their session locked out. ]]
local RETRY_AFTER = 8

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
local lastPrompt = (setmetatable({}, { __mode = "k" }) :: any) :: { [Player]: number }
local inFlight = (setmetatable({}, { __mode = "k" }) :: any) :: { [Player]: { [string]: boolean } }

local serviceTrove = Trove.new()

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
end

--[[
	Asks Roblox, once, and remembers the answer for this session.

	Never yields the caller into a second ask for the same pass: `inFlight` is
	what stops four screens opening at once turning into four web calls, and what
	stops a client that fires the remote repeatedly from doing the same.
]]
local function refresh(player: Player, pass: PassConfig.Pass): boolean?
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
		clocks[pass.id] = os.clock() + RETRY_AFTER
		warn(string.format("PassService: ownership check failed for %s (%s)", pass.id, tostring(result)))
		return nil
	end

	owned[pass.id] = result == true
	return owned[pass.id]
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

function PassService:isKnown(player: Player, passId: string): boolean
	local owned = state[player]
	return owned ~= nil and owned[passId] ~= nil
end

--[[ Every pass, resolved and published. Called on join and after a purchase. ]]
function PassService:refreshAll(player: Player)
	for _, pass in PassConfig.Passes do
		refresh(player, pass)
	end
	publish(player)
end

local function onJoin(player: Player)
	state[player] = {}
	--[[ Off the join thread. UserOwnsGamePassAsync is a web call per pass, and
	     a slow one would hold up everything else waiting on PlayerAdded. ]]
	task.spawn(function()
		PassService:refreshAll(player)
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
		lastPrompt[player] = nil
		inFlight[player] = nil
	end)
end

function PassService:start()
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
			ownedTable(player)[pass.id] = true
			publish(player)
		end
	)
end

function PassService:destroy()
	serviceTrove:destroy()
end

Registry.register("PassService", PassService)

return PassService
