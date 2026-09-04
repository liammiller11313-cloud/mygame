--!nonstrict
--[[
	RequisitionService — one player pays, the whole team gets it.

	See Shared/Config/RequisitionConfig for what is for sale and why it is those
	five things rather than a stat shop. This file owns the transaction and the
	round's state, and nothing else: the effects themselves live where the thing
	they change lives — the reload in InventoryService, the reserve cap in the
	same, the outlines in the client's OutlineController, the fire in
	DamageService. All four read Attributes.Game.Req* off Workspace, which is the
	whole of the wiring.

	── WHEN YOU MAY BUY ────────────────────────────────────────────────────────
	Prep and breathers only. That is the design and not a limitation: a breather
	is supposed to be the moment a team decides something, and it had nothing to
	decide beyond who needs the medkit. A requisition that could be bought
	mid-wave would be a panic button pressed at the worst moment for the worst
	reason, and it would take the decision out of the one window built for it.

	── AND WHAT STOPS IT BEING SPENT TWICE ─────────────────────────────────────
	Three things, in this order:

	  1. The attribute is already set. Two people pressing BUY on the same row in
	     the same second is not a race here, because the whole exchange happens
	     inside one server callback and the second one finds the switch already
	     flipped and refuses BEFORE any Scrip is taken.
	  2. ProfileService:spendScrip refuses rather than clamping, so a player who
	     cannot afford it is told so and keeps their currency.
	  3. The Scrip comes out FIRST, then the switch is flipped. In the other
	     order a failure between the two hands the team a free requisition.

	── AND THE BUYER IS NAMED ──────────────────────────────────────────────────
	Deliberately. Somebody just spent a currency that takes days to earn on three
	other people, and a purchase nobody can see is a purchase nobody thanks you
	for. The refusal goes only to the asker; the sale goes to everybody.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attributes = require(Shared.Net.Attributes)
local Enums = require(Shared.Enums)
local Registry = require(Shared.Util.Registry)
local Remotes = require(Shared.Net.Remotes)
local RequisitionConfig = require(Shared.Config.RequisitionConfig)
local Trove = require(Shared.Util.Trove)

local GA = Attributes.Game

--[[ Matches RoundService's own callout length, so a requisition reads like
     every other thing the team shouts at each other. ]]
local SAY_SECONDS = 2.2

local PHASE_PREP = "Prep"
local PHASE_BREATHER = "Breather"

local RequisitionService = {}

local trove = Trove.new()

-- ── helpers ─────────────────────────────────────────────────────────────────

local function reply(player: Player, id: string, ok: boolean, reason: string, cost: number?)
	Remotes.Event.RequisitionResult:FireClient(player, {
		id = id,
		ok = ok,
		reason = reason,
		cost = cost,
	})
end

local function announce(entry: any, buyer: Player)
	Remotes.Event.RequisitionResult:FireAllClients({
		id = entry.id,
		ok = true,
		reason = "",
		buyer = buyer.DisplayName,
		cost = entry.cost,
	})
	--[[ And into the subtitle stream, which is where every other callout in the
	     game already goes. A toast system of its own for one line a round would
	     be a second place to look during the one moment nobody has time to look
	     anywhere — and this is a line the whole team should read. ]]
	Remotes.Event.Subtitle:FireAllClients({
		speaker = string.upper(buyer.DisplayName),
		text = string.format("%s, on me.", entry.displayName),
		duration = SAY_SECONDS,
	})
end

--[[ Whether the round is in a window where buying is allowed. Read off the
     Workspace attributes RoundService already publishes rather than by calling
     into it, so this cannot be wrong about the phase in a way RoundService is
     not — there is one clock and this reads it. ]]
local function inBuyWindow(): boolean
	--[[
		Starting counts, and that is the fix rather than a loosening.

		PREP has been in the list below since this file was written — the window
		before wave 1 is the one time a team is standing still together with a
		decision to make — but the round is in RoundState.Starting during prep,
		not InProgress, so the guard above rejected every prep purchase and the
		pre-round window silently never worked. The phase test underneath is
		still what decides: Starting only ever happens during prep.
	]]
	local state = Workspace:GetAttribute(GA.RoundState)
	if state ~= Enums.RoundState.InProgress and state ~= Enums.RoundState.Starting then
		return false
	end
	local phase = Workspace:GetAttribute(GA.WavePhase)
	return phase == PHASE_PREP or phase == PHASE_BREATHER
end

-- ── the effects that are not an attribute ───────────────────────────────────

--[[
	AIRDROP, and the top-up half of AMMO SURPLUS.

	Everything else a requisition does is a switch some other file reads. These
	two happen once, at the moment of purchase, and so they happen here.
]]
local function applyInstant(id: string)
	if id == "Airdrop" then
		local level = Registry.find("LevelService")
		if level and typeof(level.restockItems) == "function" then
			pcall(level.restockItems, level)
		end
		return
	end

	if id == "Surplus" then
		--[[ The ceiling went up; nobody's magazine did. A surplus that only
		     raised a cap would be a purchase whose entire effect was invisible
		     until the next ammo box, which for the team that just paid for it
		     reads as nothing having happened. ]]
		local inventory = Registry.find("InventoryService")
		if inventory and typeof(inventory.refillReserve) == "function" then
			for _, player in Players:GetPlayers() do
				pcall(inventory.refillReserve, inventory, player, 1, true)
			end
		end
	end
end

-- ── the transaction ─────────────────────────────────────────────────────────

local function onRequest(player: Player, id: any)
	local entry = RequisitionConfig.get(id)
	if not entry then
		return -- a bad id is not worth a reply; nothing legitimate sends one
	end

	if not inBuyWindow() then
		reply(player, entry.id, false, "Only between waves.")
		return
	end

	--[[ Before any money moves. See the header: two people on the same row in
	     the same second both land here, and the second one has to leave with its
	     Scrip. The attribute is the only record — every requisition sets one,
	     including AIRDROP, whose switch exists precisely so this question has one
	     answer rather than two. ]]
	if RequisitionConfig.isActive(Workspace, entry.id) then
		reply(player, entry.id, false, "Already requisitioned.")
		return
	end

	local profiles = Registry.find("ProfileService")
	if not profiles or typeof(profiles.spendScrip) ~= "function" then
		reply(player, entry.id, false, "Requisitions are offline.")
		return
	end

	if not profiles:spendScrip(player, entry.cost) then
		reply(player, entry.id, false, "Not enough Scrip.")
		return
	end

	--[[ Paid. Flip the switch before anything that could fail, so a broken effect
	     cannot leave a player charged for nothing — and before applyInstant,
	     which for AMMO SURPLUS refills against the cap this switch just raised. ]]
	Workspace:SetAttribute(entry.attribute, true)

	applyInstant(entry.id)
	announce(entry, player)
end

-- ── the round ───────────────────────────────────────────────────────────────

--[[ Everything off. Called at both ends of a round rather than one: clearing on
     START means a server whose previous round ended badly cannot leak a
     requisition into the next one, and clearing on END means the lobby is not
     sitting there with the horde outlined through the walls. ]]
function RequisitionService:clear()
	for _, name in RequisitionConfig.attributes() do
		Workspace:SetAttribute(name, false)
	end
end

-- ── lifecycle ───────────────────────────────────────────────────────────────

function RequisitionService:init()
	self:clear()
end

function RequisitionService:start()
	trove:connect(Remotes.Event.RequestRequisition.OnServerEvent, onRequest)

	--[[ Both ends of a round, and the start is read off the attribute rather than
	     a signal because RoundService does not have a roundStarted one. The state
	     going to Starting is the same fact and it is already published. ]]
	trove:connect(Workspace:GetAttributeChangedSignal(GA.RoundState), function()
		if Workspace:GetAttribute(GA.RoundState) == Enums.RoundState.Starting then
			self:clear()
		end
	end)

	local round = Registry.find("RoundService")
	if round and round.roundEnded then
		trove:add(round.roundEnded:connect(function()
			self:clear()
		end))
	end
end

function RequisitionService:destroy()
	trove:destroy()
	self:clear()
end

Registry.register("RequisitionService", RequisitionService)

return RequisitionService
