--!nonstrict
--[[
	EconomyService — where Dollars come from, and the only place they are spent.

	Two halves of one job. Earning listens to signals the combat and round
	systems already fire and hands the result to ProfileService; spending answers
	the shop's one remote. Both sides are here because they are the same
	question — how much is a thing worth — and splitting them across two files is
	how a payout and a price end up disagreeing.

	Nothing in this file decides an AMOUNT. Every number comes out of
	EconomyConfig, which is where they can be tuned together and where a script
	checks that the pacing they produce is still the pacing that was intended.

	── THE CLIENT NEVER NAMES A PRICE ───────────────────────────────────────────
	A purchase request carries an item id and nothing else. The price, whether
	the thing is for sale at all, whether it is already owned, and whether the
	player can afford it are all answered here from the server's own copy of the
	catalogue. A client that sends a made-up id, a coming-soon id, or an id it
	already owns is refused with a reason rather than ignored — silence reads as
	a broken button, and the shop shows the reason.

	── WHY PAYING IS IMMEDIATE ──────────────────────────────────────────────────
	Kills pay the moment they happen rather than being banked to the end of the
	round. The balance is an attribute, so the client sees it move and can draw
	the "+$4" off the delta for free; and a player who dies on wave 6 keeps what
	they earned, which is the difference between a loss that felt worth playing
	and one that did not.

	── THE PER-ROUND CAP ────────────────────────────────────────────────────────
	Every payout is counted against EconomyConfig.MaxPerRound. Not distrust of
	the arithmetic — distrust of what feeds it. A Director fault that spawned ten
	thousand Commons would otherwise hand every player the entire roster in one
	round, and there is no way to take that back once it is in a DataStore.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attributes = require(Shared.Net.Attributes)
local EconomyConfig = require(Shared.Config.EconomyConfig)
local Enums = require(Shared.Enums)
local Registry = require(Shared.Util.Registry)
local Remotes = require(Shared.Net.Remotes)
local Signal = require(Shared.Util.Signal)
local Trove = require(Shared.Util.Trove)

local GA = Attributes.Game

--[[ How often one client may attempt a purchase. See the handler: every refusal
     costs a FireClient, and this is what stops that being unbounded. ]]
local PURCHASE_COOLDOWN = 0.25

local EconomyService = {}

--[[ (player: Player, itemId: string, price: number) — after a successful
     purchase. For anything that wants to react to an unlock: an announcement,
     a stat, a badge. ]]
EconomyService.purchased = Signal.new()

local serviceTrove = Trove.new()

--[[
	What each player has been paid this round, and for what.

	Kept per round rather than per session so the cap means "one round" and so
	the end-of-round screen can say where the money came from. Cleared when a
	round starts, which is the wave-1 edge — see `resetRound`.
]]
type RoundTally = { kills: number, bonus: number }
local tally: { [Player]: RoundTally } = {}

--[[
	Who was actually here for the round.

	The round bonus is most of a round's money — $1,220 for a win — and paying it
	to everyone in the server at the moment it ends pays it to somebody who
	joined during the scoreboard. That is a farm: hop servers, land on a
	scoreboard, collect. So a player is only paid if they were present while the
	round was RUNNING, which is stamped on every wave change and on any join that
	happens during one.

	Deliberately generous inside that rule: somebody who joins at wave 6 is paid
	the full bonus, because splitting it by waves-attended would pay a player who
	fought the finale less than one who idled through the first four.
]]
local present: { [Player]: boolean } = {}

--[[ Reasons a purchase is refused, as strings the shop prints verbatim. Written
     for a player rather than for a log: "YOU ALREADY OWN THIS" is an answer,
     "ERR_DUPLICATE" is a shrug. ]]
local REFUSED = table.freeze({
	Unknown = "THAT IS NOT FOR SALE",
	Soon = "NOT AVAILABLE YET",
	Owned = "YOU ALREADY OWN THIS",
	Poor = "NOT ENOUGH DOLLARS",
	NotReady = "YOUR PROFILE IS STILL LOADING",
	Failed = "THE PURCHASE COULD NOT BE COMPLETED",
})

local function tallyFor(player: Player): RoundTally
	local existing = tally[player]
	if existing then
		return existing
	end
	local fresh = { kills = 0, bonus = 0 }
	tally[player] = fresh
	return fresh
end

local function earnedThisRound(entry: RoundTally): number
	return entry.kills + entry.bonus
end

--[[
	Pays a player, honouring the per-round cap.

	Returns what was ACTUALLY paid, which can be less than what was asked for and
	can be zero. Callers add the return value to their tally rather than what
	they requested, so the end-of-round breakdown adds up to the balance the
	player is looking at.
]]
local function pay(player: Player, amount: number, into: string): number
	if amount <= 0 then
		return 0
	end
	local profiles = Registry.find("ProfileService")
	if not profiles or not profiles:isReady(player) then
		return 0
	end

	local entry = tallyFor(player)
	local room = EconomyConfig.MaxPerRound - earnedThisRound(entry)
	local granted = math.min(math.floor(amount), math.max(room, 0))
	if granted <= 0 then
		return 0
	end

	entry[into] += granted
	profiles:addDollars(player, granted)
	return granted
end

-- ── earning ─────────────────────────────────────────────────────────────────

local function onInfectedDied(_model: Model, kind: string, ctx: any)
	local attacker = ctx and ctx.attacker
	if not attacker or typeof(attacker) ~= "Instance" or not attacker:IsA("Player") then
		return
	end
	--[[ A survivor killed by a teammate is not an infected and never reaches
	     here; this is the infected death signal. The region comes off the same
	     context that decided the headshot multiplier, so the money and the
	     hitmarker agree about what just happened. ]]
	local isHeadshot = ctx.region == Enums.HitRegion.Head
	pay(attacker, EconomyConfig.rewardForKill(kind, isHeadshot), "kills")
end

--[[ Marks everybody currently in the server as having played this round.
     Called on every wave edge rather than only the first, so a mid-round joiner
     is picked up by the next wave. ]]
local function markPresent()
	for _, player in Players:GetPlayers() do
		present[player] = true
	end
end

--[[
	The round bonus, and the report.

	Paid to everyone who was here for it, including players who died on wave two:
	they held the line with everybody else, and paying only the survivors would
	make the last two minutes of a lost round worth more than the first forty of
	a good one. Players who were NOT here — who arrived while the scoreboard was
	already up — are skipped; see `present`.
]]
local function onRoundEnded(outcome: string)
	local victory = outcome == Enums.RoundState.Victory
	local waves = Attributes.get(Workspace, GA.WaveIndex, 0)
	waves = if typeof(waves) == "number" then math.max(math.floor(waves), 0) else 0

	local base = if victory then EconomyConfig.VictoryBonus else EconomyConfig.DefeatBonus
	local total = base + EconomyConfig.WaveBonus * waves

	local profiles = Registry.find("ProfileService")
	for _, player in Players:GetPlayers() do
		--[[ Not here for the round, not paid for it. See `present`: without this
		     the biggest single payout in the game goes to anyone who arrives
		     while the scoreboard is up. ]]
		if not present[player] then
			continue
		end
		local entry = tallyFor(player)
		pay(player, total, "bonus")

		Remotes.Event.RoundPayout:FireClient(player, {
			kills = entry.kills,
			bonus = entry.bonus,
			waves = waves,
			victory = victory,
			total = earnedThisRound(entry),
			balance = if profiles then profiles:getDollars(player) else 0,
		})

		--[[ Written out now rather than at the next autosave. A player who
		     closes the game on the scoreboard has just finished a round, and it
		     is the one moment where losing a minute of progress would be
		     obvious and unforgivable. ]]
		if profiles then
			task.spawn(function()
				profiles:flush(player)
			end)
		end
	end
end

local function resetRound()
	table.clear(tally)
	table.clear(present)
end

-- ── spending ────────────────────────────────────────────────────────────────

local function refuse(player: Player, itemId: string, reason: string)
	Remotes.Event.PurchaseResult:FireClient(player, {
		itemId = itemId,
		ok = false,
		reason = reason,
	})
end

--[[
	The whole purchase path, server-side, from an id and nothing else.

	The order of the checks is the order a player would ask them in, so the
	message they get back is the most useful true thing: "not for sale" before
	"not yet", "you own it" before "you cannot afford it".
]]
local function onPurchase(player: Player, itemId: any)
	if typeof(itemId) ~= "string" then
		return
	end

	local profiles = Registry.find("ProfileService")
	if not profiles or not profiles:isReady(player) then
		refuse(player, itemId, REFUSED.NotReady)
		return
	end

	local entry = EconomyConfig.get(itemId)
	if not entry then
		refuse(player, itemId, REFUSED.Unknown)
		return
	end
	if entry.soon then
		refuse(player, itemId, REFUSED.Soon)
		return
	end
	if profiles:owns(player, itemId) then
		refuse(player, itemId, REFUSED.Owned)
		return
	end

	--[[ Priced from the server's own catalogue. The request carried an id and
	     nothing else, so there is no number here a client could have chosen. ]]
	local price = EconomyConfig.priceOf(itemId)
	if price == nil then
		refuse(player, itemId, REFUSED.Unknown)
		return
	end

	if not profiles:trySpend(player, price) then
		refuse(player, itemId, REFUSED.Poor)
		return
	end

	if not profiles:grant(player, itemId) then
		--[[ Spent but not granted. Only reachable if the profile vanished
		     between the two calls — a player leaving mid-purchase — but the
		     money is put back rather than left gone, because the alternative is
		     a player returning to a balance they cannot account for. ]]
		profiles:addDollars(player, price)
		refuse(player, itemId, REFUSED.Failed)
		return
	end

	Remotes.Event.PurchaseResult:FireClient(player, {
		itemId = itemId,
		ok = true,
		price = price,
	})
	EconomyService.purchased:fire(player, itemId, price)

	--[[ Written immediately. An unlock is the single thing in this game a player
	     would be most upset to lose to a server crash, and it is rare enough
	     that a DataStore write per purchase costs nothing. ]]
	task.spawn(function()
		profiles:flush(player)
	end)
end

-- ── public API ──────────────────────────────────────────────────────────────

--[[ What this player has been paid this round, and for what. For the
     end-of-round screen and for anything debugging the cap. ]]
function EconomyService:getRoundTally(player: Player): RoundTally
	local entry = tally[player]
	return { kills = entry and entry.kills or 0, bonus = entry and entry.bonus or 0 }
end

--[[ Pays a player directly, for anything that is not a kill or a round end — a
     scripted reward, a compensation grant, a developer command. Goes through
     the same cap and the same profile as everything else. ]]
function EconomyService:award(player: Player, amount: number): number
	return pay(player, amount, "bonus")
end

-- ── lifecycle ───────────────────────────────────────────────────────────────

function EconomyService:init() end

function EconomyService:start()
	local infected = Registry.find("InfectedService")
	if infected and infected.died then
		serviceTrove:add(infected.died:connect(onInfectedDied))
	else
		warn("[EconomyService] no InfectedService.died; kills will not pay")
	end

	local round = Registry.find("RoundService")
	if round then
		if round.roundEnded then
			serviceTrove:add(round.roundEnded:connect(onRoundEnded))
		end
		--[[ Wave 1 is the start of a round. Watching the wave rather than a
		     round-started signal because there is not one, and because the wave
		     edge is the same moment by definition. ]]
		if round.waveChanged then
			serviceTrove:add(round.waveChanged:connect(function(index: number)
				if index <= 1 then
					resetRound()
				end
				markPresent()
			end))
		end
	else
		warn("[EconomyService] no RoundService; round bonuses will not be paid")
	end

	--[[
		Purchases are throttled.

		Not because a fast buyer is a problem — because every refusal answers with
		a FireClient, so an unthrottled handler lets a crafted client turn one
		socket into unlimited outbound traffic from the server. A quarter of a
		second is imperceptible to somebody pressing BUY and ends that entirely.
	]]
	local lastPurchaseAt: { [Player]: number } = setmetatable({}, { __mode = "k" }) :: any
	serviceTrove:connect(Remotes.Event.PurchaseItem.OnServerEvent, function(player, itemId)
		local now = os.clock()
		if lastPurchaseAt[player] and now - lastPurchaseAt[player] < PURCHASE_COOLDOWN then
			return
		end
		lastPurchaseAt[player] = now
		onPurchase(player, itemId)
	end)

	--[[ Anyone joining while a round is already running counts as present for
	     it. The wave edges cover everybody else. ]]
	serviceTrove:connect(Players.PlayerAdded, function(player: Player)
		local round = Registry.find("RoundService")
		if round and typeof(round.isRunning) == "function" then
			local ok, running = pcall(round.isRunning, round)
			if ok and running then
				present[player] = true
			end
		end
	end)

	serviceTrove:connect(Players.PlayerRemoving, function(player: Player)
		tally[player] = nil
		present[player] = nil
	end)
end

function EconomyService:destroy()
	table.clear(tally)
	table.clear(present)
	serviceTrove:destroy()
end

Registry.register("EconomyService", EconomyService)

return EconomyService
