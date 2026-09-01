--!nonstrict
--[[
	ProgressionController — this client's copy of its level, Scrip and quests.

	The same discipline as ProfileController next door: it is a MIRROR, not a
	store. Nothing here decides that a quest is finished, that a level was
	crossed, or that a pass tier may be bought. It sends a request and draws what
	comes back.

	── THREE CHANNELS, FOR THREE DIFFERENT SHAPES ───────────────────────────────
	  * `Attributes.Player.Level / Scrip / Callsign / Accent` — the four facts
	    OTHER players' screens need too, so they ride attributes and cost nothing.
	  * `ProgressionSynced` — quest counters, the pass tier, the XP inside the
	    current level. Only the owner needs these.
	  * `ProgressionAwarded` — "this just happened", which is a different message
	    from "this is the state". A client cannot tell a level-up from a fresh
	    join by comparing two numbers, so the server says which it was.

	── THE LIVE QUEST NUMBER IS COMPUTED HERE ───────────────────────────────────
	The server commits quest progress once, at round end — see ProgressionService
	for why a profile write per kill was not an option. So the number this screen
	shows during a round is the committed progress PLUS what StatsUpdated says
	this client has done since, and at the round end the two collapse into one
	because they are the same arithmetic on the same snapshot.

	This is the one place the client computes anything, and it is safe precisely
	because it is not authoritative: the worst a wrong live number can do is show
	a bar slightly ahead of itself for a few seconds. It never grants anything.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attributes = require(Shared.Net.Attributes)
local ProgressionConfig = require(Shared.Config.ProgressionConfig)
local Registry = require(Shared.Util.Registry)
local Remotes = require(Shared.Net.Remotes)
local Signal = require(Shared.Util.Signal)
local Trove = require(Shared.Util.Trove)

local PA = Attributes.Player
local GA = Attributes.Game

local player = Players.LocalPlayer

--[[ How long a pass claim may sit unanswered before the button comes back. Same
     reason ProfileController has one: without it a dropped remote locks the
     panel for the session. ]]
local CLAIM_TIMEOUT = 6

local ProgressionController = {}

--[[ () — after anything changed. Screens redraw off this rather than polling. ]]
ProgressionController.changed = Signal.new()

--[[ (payload) — a round's award, or a pass claim's answer. For the toast; the
     panel reads state instead, because a toast is about a moment and a panel is
     about a total. ]]
ProgressionController.awarded = Signal.new()

local trove = Trove.new()

local state = {
	ready = false,
	degraded = false,
	xp = 0,
	level = 1,
	into = 0,
	cost = ProgressionConfig.xpForLevel(1),
	scrip = 0,
	passTier = 0,
	callsign = "",
	accent = "",
	--[[ { [questId] = committed progress }. What the SERVER has written down;
	     see questView for the number actually drawn. ]]
	quests = {} :: { [string]: number },
	--[[ This client's row out of the last StatsUpdated, and the wave it was
	     taken at. The live half of the sum. ]]
	round = {} :: { [string]: number },
	claimPending = false,
	claimAt = 0,
}

-- ── reading ─────────────────────────────────────────────────────────────────

function ProgressionController:isReady(): boolean
	return state.ready
end

--[[ Whether this session's profile is running in memory only. The panel says so
     rather than letting somebody spend Scrip that will not be there tomorrow. ]]
function ProgressionController:isDegraded(): boolean
	return state.degraded
end

function ProgressionController:getLevel(): number
	return state.level
end

function ProgressionController:getScrip(): number
	return state.scrip
end

function ProgressionController:getPassTier(): number
	return state.passTier
end

function ProgressionController:getWorn(): (string, string)
	return state.callsign, state.accent
end

--[[
	What a named player is wearing: their accent colour and their callsign.

	Any player, not just this one — which is the whole point of the pass. The
	four progression facts ride Player attributes precisely so that every client
	already has everybody else's, and a scoreboard can draw a teammate's callsign
	without a remote, a cache, or a round trip.

	Returns nil and "" for somebody who has claimed nothing, who has left, or
	whose saved reward is no longer on the track. A caller that draws whatever it
	gets is correct in all three cases.
]]
function ProgressionController:describe(name: string): (Color3?, string)
	local other = Players:FindFirstChild(name)
	if not other or not other:IsA("Player") then
		return nil, ""
	end
	local accentId = tostring(other:GetAttribute(PA.Accent) or "")
	local callsignId = tostring(other:GetAttribute(PA.Callsign) or "")
	local accent = if accentId ~= "" then ProgressionConfig.getReward("Accent", accentId) else nil
	local callsign = if callsignId ~= "" then ProgressionConfig.getReward("Callsign", callsignId) else nil
	return (if accent then accent.color else nil), (if callsign then callsign.label else "")
end

--[[ The one-line readout the main menu puts under CAREER. Built here rather
     than there because the currency's name and symbol belong to
     ProgressionConfig, and MainMenuController is close enough to Luau's
     200-local limit that a require of its own is a real cost. Empty until the
     first sync: "LEVEL 0" for the second before a profile lands is a worse first
     impression than the words it would replace. ]]
function ProgressionController:summaryLine(): string
	if not state.ready then
		return ""
	end
	return string.format("LEVEL %d   %s %d", state.level, ProgressionConfig.CurrencySymbol, state.scrip)
end

--[[ Level, XP into it, and what it costs — the three numbers a progress bar
     needs. Returned together so a screen cannot draw a bar out of one sync and a
     label out of the next. ]]
function ProgressionController:getLevelProgress(): (number, number, number)
	return state.level, state.into, state.cost
end

--[[ How far past the last committed number this round has got, for one quest.
     Zero outside a round, and zero for the two quests that only resolve at the
     end — a victory is not a thing you are partway through. ]]
local function liveDelta(quest: ProgressionConfig.Quest, committed: number): number
	if quest.stat == "victory" then
		return 0
	end
	if quest.stat == "wave" then
		local wave = Attributes.get(Workspace, GA.WaveIndex, 0)
		if typeof(wave) ~= "number" or wave ~= wave then
			return 0
		end
		return math.max(math.floor(wave) - committed, 0)
	end
	local value = state.round[quest.stat]
	if typeof(value) ~= "number" or value ~= value then
		return 0
	end
	return math.max(math.floor(value), 0)
end

export type QuestView = {
	quest: ProgressionConfig.Quest,
	--[[ Committed plus live, capped at the target — a bar that reads 163/150 is
	     a bar nobody trusts. ]]
	progress: number,
	complete: boolean,
	--[[ True while part of `progress` is this round's and has not been written
	     down yet. The panel draws that part differently, because "you have done
	     this" and "you will have done this when the round ends" are not the same
	     promise. ]]
	pending: boolean,
}

--[[ Today's three quests, with the number to draw beside each. ]]
function ProgressionController:questView(): { QuestView }
	local out: { QuestView } = {}
	local day = math.floor(os.time() / ProgressionConfig.QuestPeriod)
	for _, quest in ProgressionConfig.questsForDay(day) do
		local committed = state.quests[quest.id] or 0
		local delta = if committed >= quest.target then 0 else liveDelta(quest, committed)
		local progress = math.min(committed + delta, quest.target)
		table.insert(out, {
			quest = quest,
			progress = progress,
			complete = progress >= quest.target,
			pending = delta > 0,
		})
	end
	return out
end

--[[ The next tier and what it costs, or nil once the track is finished. One
     call rather than two so a panel cannot draw tier 7's name over tier 8's
     price. ]]
function ProgressionController:nextTier(): (ProgressionConfig.PassTier?, number)
	local wanted = state.passTier + 1
	local reward = ProgressionConfig.PassTrack[wanted]
	if not reward then
		return nil, 0
	end
	return reward, ProgressionConfig.passCost(wanted)
end

function ProgressionController:canClaim(): boolean
	local reward, cost = self:nextTier()
	return reward ~= nil and not state.claimPending and state.scrip >= cost
end

function ProgressionController:isClaimPending(): boolean
	--[[ Expired rather than stuck. A claim whose answer never arrived must give
	     the button back; the server is the only thing that can actually spend
	     the Scrip, so the worst case of a timeout is a second request it
	     refuses. ]]
	if state.claimPending and os.clock() - state.claimAt > CLAIM_TIMEOUT then
		state.claimPending = false
	end
	return state.claimPending
end

-- ── asking ──────────────────────────────────────────────────────────────────

function ProgressionController:claim(): boolean
	if not self:canClaim() then
		return false
	end
	state.claimPending = true
	state.claimAt = os.clock()
	Remotes.Event.ClaimPassTier:FireServer()
	ProgressionController.changed:fire()
	return true
end

--[[ Wears a claimed reward. Not predicted locally: the attribute is what every
     other player's screen reads, and a name that changed here and nowhere else
     is a lie only this client can see. ]]
function ProgressionController:setWorn(kind: string, id: string)
	if kind ~= "Callsign" and kind ~= "Accent" then
		return
	end
	Remotes.Event.SetWornReward:FireServer(kind, id)
end

-- ── receiving ───────────────────────────────────────────────────────────────

local function onSynced(payload: any)
	if typeof(payload) ~= "table" then
		return
	end
	state.ready = true
	state.degraded = payload.degraded == true
	state.xp = tonumber(payload.xp) or state.xp
	state.level = tonumber(payload.level) or state.level
	state.into = tonumber(payload.into) or 0
	state.cost = tonumber(payload.cost) or ProgressionConfig.xpForLevel(state.level)
	state.scrip = tonumber(payload.scrip) or state.scrip
	state.passTier = tonumber(payload.passTier) or state.passTier

	table.clear(state.quests)
	if typeof(payload.quests) == "table" then
		for _, entry in payload.quests do
			if typeof(entry) == "table" and typeof(entry.id) == "string" then
				state.quests[entry.id] = tonumber(entry.progress) or 0
			end
		end
	end

	--[[ A sync is the server's answer to everything outstanding, including a
	     claim. Clearing it here rather than only in the award handler means a
	     dropped ProgressionAwarded still frees the button. ]]
	state.claimPending = false
	ProgressionController.changed:fire()
end

--[[ This client's own row out of the broadcast. Everybody else's is ignored:
     the only thing this table feeds is the live half of a quest number, and that
     is by definition about this player. ]]
local function onStats(payload: any)
	if typeof(payload) ~= "table" then
		return
	end
	local row = payload[player.Name]
	if typeof(row) ~= "table" then
		return
	end
	table.clear(state.round)
	for key, value in row do
		if typeof(key) == "string" and typeof(value) == "number" and value == value then
			state.round[key] = value
		end
	end
	ProgressionController.changed:fire()
end

local function readAttributes()
	local level = Attributes.get(player, PA.Level, nil)
	if typeof(level) == "number" then
		state.level = math.max(math.floor(level), 1)
	end
	local scrip = Attributes.get(player, PA.Scrip, nil)
	if typeof(scrip) == "number" then
		state.scrip = math.max(math.floor(scrip), 0)
	end
	state.callsign = tostring(Attributes.get(player, PA.Callsign, "") or "")
	state.accent = tostring(Attributes.get(player, PA.Accent, "") or "")
end

-- ── lifecycle ───────────────────────────────────────────────────────────────

function ProgressionController:init()
	trove:connect(Remotes.Event.ProgressionSynced.OnClientEvent, onSynced)
	trove:connect(Remotes.Event.StatsUpdated.OnClientEvent, onStats)

	trove:connect(Remotes.Event.ProgressionAwarded.OnClientEvent, function(payload: any)
		if typeof(payload) ~= "table" then
			return
		end
		state.claimPending = false
		if payload.kind == "Round" then
			--[[ The round just went into the profile. The live half of every
			     quest number is now ALSO in the committed half, and leaving it
			     here would draw the round twice — a bar that jumps to double on
			     the results screen and then quietly halves when the next round
			     resets the stats broadcast. ]]
			table.clear(state.round)
		end
		ProgressionController.awarded:fire(payload)
		ProgressionController.changed:fire()
	end)

	for _, name in { PA.Level, PA.Scrip, PA.Callsign, PA.Accent } do
		trove:connect(player:GetAttributeChangedSignal(name), function()
			readAttributes()
			ProgressionController.changed:fire()
		end)
	end
end

function ProgressionController:start()
	--[[ Both halves of the same race ProfileController describes: progression can
	     land before this client was listening, so ask once — and the attributes
	     may already be set, so read them once. ]]
	readAttributes()
	Remotes.Event.RequestProgression:FireServer()
	ProgressionController.changed:fire()
end

function ProgressionController:destroy()
	trove:destroy()
end

Registry.register("ProgressionController", ProgressionController)

return ProgressionController
