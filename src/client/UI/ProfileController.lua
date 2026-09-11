--!nonstrict
--[[
	ProfileController — this client's copy of what the player owns.

	Dollars, unlocks, and the three loadouts, mirrored from the server and handed
	to whatever wants to draw them. The shop and the loadout screen both read it;
	neither keeps a copy, because two copies is how a shop shows a balance the
	loadout screen disagrees with.

	── IT IS A MIRROR, NOT A STORE ──────────────────────────────────────────────
	Nothing here decides anything. Buying sends a request and waits; the balance
	does not move until the server says it moved. That is slower than predicting
	it locally and it is the right trade for money: a predicted purchase that the
	server then refuses leaves the player looking at a balance that is wrong and
	an item they do not have, and there is no good way to explain it to them.

	The one exception is nothing at all — there is no exception. Every number on
	every screen came from the server.

	── TWO CHANNELS, ON PURPOSE ─────────────────────────────────────────────────
	  * `ProfileSynced` carries the whole profile — the unlock set and all three
	    loadouts — and fires on load and after a STRUCTURAL change: something
	    bought, a loadout edited, the active one switched.
	  * `Attributes.Player.Dollars` carries the balance alone and moves on every
	    kill, three hundred times a round.

	The split is load-bearing rather than tidy. Syncing on every change meant
	firing the entire profile at a client twice a second during a horde to say a
	number that was already on its way as an attribute — see ProfileService's
	`markChanged`.

	The delta between two attribute values IS the earning, which is what feeds
	the "+$4" that appears when something dies. No remote carries it, because the
	subtraction already knows.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attributes = require(Shared.Net.Attributes)
local EconomyConfig = require(Shared.Config.EconomyConfig)
local AbilityConfig = require(Shared.Config.AbilityConfig)
local LoadoutConfig = require(Shared.Config.LoadoutConfig)
local Registry = require(Shared.Util.Registry)
local Remotes = require(Shared.Net.Remotes)
local Signal = require(Shared.Util.Signal)
local Trove = require(Shared.Util.Trove)

local PA = Attributes.Player

--[[ How long a purchase may sit unanswered before the button comes back. See
     `buy` — without it a dropped remote locks the shop for the session. ]]
local PURCHASE_TIMEOUT = 6

local ProfileController = {}

--[[ () — after anything in the profile changed. Screens redraw off this rather
     than polling; it fires for a balance change too, which is what keeps a shop
     that is open while a round is running honest. ]]
ProfileController.changed = Signal.new()

--[[ (amount: number, balance: number) — money arrived. Derived from the balance
     moving UP, so it covers kills, round bonuses and anything else the server
     ever pays, without any of them needing to say so. ]]
ProfileController.earned = Signal.new()

--[[ (payload) — the itemised end-of-round total. The one thing the client
     cannot derive, because it cannot see the bonus arithmetic. ]]
ProfileController.paid = Signal.new()

--[[ (itemId: string, ok: boolean, reason: string?) — the answer to a purchase.
     The shop draws the reason verbatim; they are written for a player to read. ]]
ProfileController.purchaseAnswered = Signal.new()

local player = Players.LocalPlayer
local trove = Trove.new()

local state = {
	ready = false,
	degraded = false,
	dollars = 0,
	owned = {} :: { [string]: boolean },
	loadouts = LoadoutConfig.sanitiseAll(nil, nil),
	loadoutNames = LoadoutConfig.sanitiseNames(nil),
	active = 1,
	--[[ The ability half of the same profile. It rides the same sync for the
	     same reason the loadouts do: one payload, one arrival order, and no
	     screen that has to reconcile two halves that showed up separately. ]]
	abilities = {} :: { [string]: boolean },
	abilitySlots = AbilityConfig.sanitiseSlots(nil, nil),
	--[[ The id currently waiting on the server, so the shop can grey its own BUY
	     button rather than letting somebody press it four times while a
	     DataStore write is in flight. ]]
	pending = "",
}

-- ── reading ─────────────────────────────────────────────────────────────────

--[[ Whether the server has sent a profile yet. Every screen checks it: a shop
     drawn against an empty profile shows everything as unaffordable and reads
     as a bug rather than as a wait. ]]
function ProfileController:isReady(): boolean
	return state.ready
end

--[[ True when the server could not reach a DataStore. The shop says so out loud
     rather than letting somebody spend an evening's Dollars on something that
     will not be there tomorrow. ]]
function ProfileController:isDegraded(): boolean
	return state.degraded
end

function ProfileController:getDollars(): number
	return state.dollars
end

function ProfileController:owns(itemId: string): boolean
	return state.owned[itemId] == true
end

--[[ The whole unlock set, by reference. Read by the loadout screen, which needs
     to ask about a weapon it has not drawn a row for yet — see
     LoadoutConfig.candidates and the one weapon that is listed only to the
     account holding it. Nothing mutates it; the sync replaces it wholesale. ]]
function ProfileController:getOwned(): { [string]: boolean }
	return state.owned
end

function ProfileController:canAfford(itemId: string): boolean
	local price = EconomyConfig.priceOf(itemId)
	return price ~= nil and state.dollars >= price
end

function ProfileController:ownsAbility(id: string): boolean
	return state.abilities[id] == true
end

function ProfileController:getAbilities(): { [string]: boolean }
	return state.abilities
end

function ProfileController:getAbilitySlots(): { string }
	return state.abilitySlots
end

--[[ Which slot this ability is in, or 0. The question the panel asks about
     every row, so it is answered here rather than by five copies of a loop. ]]
function ProfileController:abilitySlotOf(id: string): number
	if id == "" then
		return 0
	end
	for index, equipped in state.abilitySlots do
		if equipped == id then
			return index
		end
	end
	return 0
end

--[[ The three, as stored. Returned by reference on purpose: the loadout screen
     edits a COPY it makes itself and sends the result, so nothing here is ever
     half-edited by a screen that was closed midway. ]]
function ProfileController:getLoadouts(): { LoadoutConfig.Loadout }
	return state.loadouts
end

function ProfileController:getActiveIndex(): number
	return state.active
end

function ProfileController:getLoadout(index: number): LoadoutConfig.Loadout
	return state.loadouts[LoadoutConfig.clampIndex(index)] or LoadoutConfig.sanitise(nil, nil)
end

--[[ What this loadout is called. Never empty: sanitiseNames answers a default
     for every index it does not find, so a screen can draw this without a
     fallback of its own and a profile saved before naming existed reads as
     LOADOUT 1, 2, 3 rather than as three blank rows. ]]
function ProfileController:getLoadoutName(index: number): string
	local slot = LoadoutConfig.clampIndex(index)
	return state.loadoutNames[slot] or LoadoutConfig.defaultName(slot)
end

--[[ Renames one. Drawn immediately, like setActive and for the same reason: the
     player typed it, they are looking at the field, and a name that snapped back
     to the old one for a round trip would read as the edit being rejected. The
     server sanitises and the next sync is what settles it. ]]
function ProfileController:setLoadoutName(index: number, name: string)
	if not state.ready then
		return
	end
	local slot = LoadoutConfig.clampIndex(index)
	local cleaned = LoadoutConfig.sanitiseName(name, slot)
	if state.loadoutNames[slot] == cleaned then
		return
	end
	state.loadoutNames[slot] = cleaned
	Remotes.Event.SetLoadoutName:FireServer({ index = slot, name = cleaned })
	ProfileController.changed:fire()
end

--[[ Whether a purchase for this id is in flight. One at a time: the shop has one
     BUY button and a second press while the first is unanswered is a player
     wondering whether it worked, not a player asking to buy two. ]]
function ProfileController:isPending(itemId: string?): boolean
	if itemId == nil then
		return state.pending ~= ""
	end
	return state.pending == itemId
end

-- ── asking ──────────────────────────────────────────────────────────────────

--[[
	Asks the server to sell this player something.

	Refused locally only for the things the client can be certain about without
	guessing — not ready, already pending — because every other answer belongs to
	the server and duplicating its rules here is how the two end up disagreeing
	about what something costs.
]]
function ProfileController:buy(itemId: string): boolean
	if not state.ready or state.pending ~= "" or typeof(itemId) ~= "string" then
		return false
	end
	state.pending = itemId
	Remotes.Event.PurchaseItem:FireServer(itemId)
	ProfileController.changed:fire()

	--[[
		A deadline on the answer.

		`pending` greys the BUY button so nobody presses it four times while a
		DataStore write is in flight. Without this it is also a permanent lock:
		a dropped remote, a server-side error, or a request the server throttled
		away leaves it set for the rest of the session and the player can never
		buy anything again. PURCHASE_TIMEOUT is far longer than the round trip —
		it has to survive a DataStore write — and far shorter than the session it
		would otherwise cost.
	]]
	task.delay(PURCHASE_TIMEOUT, function()
		if state.pending == itemId then
			state.pending = ""
			ProfileController.purchaseAnswered:fire(itemId, false, "NO ANSWER FROM THE SERVER")
			ProfileController.changed:fire()
		end
	end)
	return true
end

--[[ Saves one of the three. The server sanitises it against what this player
     actually owns, so a slot naming something unowned comes back as the default
     rather than as a refusal. ]]
function ProfileController:setLoadout(index: number, slots: LoadoutConfig.Loadout)
	if not state.ready then
		return
	end
	Remotes.Event.SetLoadout:FireServer({ index = LoadoutConfig.clampIndex(index), slots = slots })
end

function ProfileController:setActive(index: number)
	if not state.ready then
		return
	end
	local wanted = LoadoutConfig.clampIndex(index)
	if wanted == state.active then
		return
	end
	--[[ Drawn immediately rather than waiting for the round trip. The exception
	     to the rule at the top of this file, and a deliberate one: this is a
	     preference rather than a balance, the server cannot refuse it, and a
	     radio button that takes a hundred milliseconds to move reads as broken.
	     The next sync overwrites it either way. ]]
	state.active = wanted
	Remotes.Event.SetActiveLoadout:FireServer(wanted)
	ProfileController.changed:fire()
end

-- ── receiving ───────────────────────────────────────────────────────────────

local function onSynced(payload: any)
	if typeof(payload) ~= "table" then
		return
	end

	state.dollars = if typeof(payload.dollars) == "number" then math.max(payload.dollars, 0) else 0
	state.owned = if typeof(payload.owned) == "table" then payload.owned else {}
	state.degraded = payload.degraded == true
	state.active = LoadoutConfig.clampIndex(payload.active)
	--[[ Sanitised again on arrival. Not distrust of the server — it sanitised
	     these on the way out — but the SHAPE has to be right for the screens
	     that index it, and a payload that arrived malformed for any reason
	     should produce a drawable loadout rather than a nil index. ]]
	state.loadouts = LoadoutConfig.sanitiseAll(payload.loadouts, nil)
	state.loadoutNames = LoadoutConfig.sanitiseNames(payload.loadoutNames)
	state.abilities = if typeof(payload.abilities) == "table" then payload.abilities else {}
	-- Same reasoning as the loadouts above: the shape has to be right to index.
	state.abilitySlots = AbilityConfig.sanitiseSlots(payload.abilitySlots, nil)
	state.ready = true
	--[[ `pending` is deliberately NOT cleared here. A sync fires for any
	     structural change — a loadout edited on another screen — and clearing it
	     on one of those would re-enable BUY while a purchase was still in flight,
	     which is a second purchase waiting to happen. PurchaseResult owns it, and
	     the timeout in `buy` covers a result that never arrives. ]]

	ProfileController.changed:fire()
end

--[[
	The balance, off the attribute rather than the sync.

	It moves on every kill and the sync does not fire for those — see the header.
	A rise is money arriving, which is all the "+$4" popup needs to know; a fall
	is a purchase, and the sync that follows it says what was bought.
]]
local function onBalanceChanged()
	local value = Attributes.get(player, PA.Dollars, state.dollars)
	if typeof(value) ~= "number" then
		return
	end
	local delta = value - state.dollars
	state.dollars = value
	if delta > 0 and state.ready then
		ProfileController.earned:fire(delta, value)
	end
	ProfileController.changed:fire()
end

-- ── lifecycle ───────────────────────────────────────────────────────────────

function ProfileController:init()
	trove:connect(Remotes.Event.ProfileSynced.OnClientEvent, onSynced)
	trove:connect(player:GetAttributeChangedSignal(PA.Dollars), onBalanceChanged)

	trove:connect(Remotes.Event.PurchaseResult.OnClientEvent, function(payload: any)
		if typeof(payload) ~= "table" then
			return
		end
		local itemId = tostring(payload.itemId or "")
		if state.pending == itemId then
			state.pending = ""
		end
		ProfileController.purchaseAnswered:fire(itemId, payload.ok == true, tostring(payload.reason or ""))
		ProfileController.changed:fire()
	end)

	trove:connect(Remotes.Event.RoundPayout.OnClientEvent, function(payload: any)
		if typeof(payload) == "table" then
			ProfileController.paid:fire(payload)
		end
	end)
end

function ProfileController:start()
	--[[ A profile can finish loading before this client finished booting, in
	     which case the server's sync fired into a listener that did not exist
	     yet. Asking is cheap and removes the race entirely. ]]
	Remotes.Event.RequestProfile:FireServer()

	--[[ The attribute may already be set from before the connection above
	     existed, for the same reason. Reading it once here is what stops a
	     player's balance showing zero until their first kill. ]]
	local existing = Attributes.get(player, PA.Dollars, nil)
	if typeof(existing) == "number" then
		state.dollars = existing
	end
end

function ProfileController:destroy()
	trove:destroy()
end

Registry.register("ProfileController", ProfileController)

return ProfileController
