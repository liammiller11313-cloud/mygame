--!nonstrict
--[[
	ProgressionService — the second axis. Levels, Scrip, quests, the pass.

	EconomyService pays Dollars for what you did in the last seventeen minutes,
	and those Dollars buy the guns you carry into the next seventeen. That loop is
	closed and finite by design: a player who has bought the roster has finished
	it. This file owns the loop that is not.

	Experience never resets, never gets spent and cannot be bought. Levelling pays
	Scrip, Scrip buys the pass, and the pass pays a name and a colour. Nothing
	here touches damage, health, price or spawn rate — see ProgressionConfig for
	why that is a rule rather than a shortage of ideas.

	── WHERE THE NUMBERS COME FROM ──────────────────────────────────────────────
	StatsService's snapshot, and nothing else. It already counts kills, headshots,
	specials, bosses and revives for the scoreboard, and a second tally in here
	would be a second thing that can drift — the exact bug the Dollars column on
	the player list was written to avoid.

	Two facts are not in the snapshot: the wave reached, which is an attribute on
	Workspace, and whether the round was won, which is the outcome that fired us.

	── QUESTS ARE COMMITTED AT ROUND END, NOT DURING IT ─────────────────────────
	The obvious build hangs quest counters off the same signals StatsService
	listens to, so a counter moves the instant something dies. That is a profile
	write on every kill — three hundred a round, four players — to a key whose
	whole design is that it is touched as rarely as possible.

	So the committed progress moves once, at the end, out of the same snapshot the
	XP comes from. The player still watches it move DURING the round: StatsUpdated
	already broadcasts that snapshot to every client, so the client adds its own
	live row to the stored number and draws the sum. No extra traffic, one write,
	and the two can never disagree because they are the same arithmetic on the
	same numbers — see ProgressionController.questView.

	── WHAT IS REFUSED, AND WHY ─────────────────────────────────────────────────
	  * A player who was not here for the round is not paid for it. Same rule as
	    EconomyService, same reason: without it the biggest single XP award in the
	    game goes to whoever walks in while the scoreboard is up.
	  * A pass claim names no tier. The track is sequential and a tier number
	    crossing a remote is a tier number somebody sets to 20.
	  * A degraded profile still earns, for the session, and still saves nothing.
	    That is ProfileService's rule and this file does not get an opinion on it.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attributes = require(Shared.Net.Attributes)
local Enums = require(Shared.Enums)
local ProgressionConfig = require(Shared.Config.ProgressionConfig)
local Registry = require(Shared.Util.Registry)
local Remotes = require(Shared.Net.Remotes)
local Trove = require(Shared.Util.Trove)

local GA = Attributes.Game
local XP = ProgressionConfig.Xp

--[[ How often one client may ask for a push, and how often it may try to buy a
     pass tier. A booting client asks once and a claim is one button press; both
     of these exist because nothing stops a crafted client asking every frame. ]]
local REQUEST_COOLDOWN = 1.0
local CLAIM_COOLDOWN = 0.35

--[[ Quests whose stat is not a field of StatsService's snapshot. Named here so
     the round-end walk can skip them in the loop that reads the snapshot and
     handle them explicitly, rather than reading nil and silently awarding zero
     for the two most interesting quests in the pool. ]]
local WAVE_STAT = "wave"
local VICTORY_STAT = "victory"

local ProgressionService = {}

--[[ There is deliberately no `levelled` signal. Nothing on the server needs to
     know, the client is told over ProgressionAwarded, and audit.py is right that
     a signal fired into no listeners is weight rather than an extension point.
     Add one the day something actually connects to it. ]]

local serviceTrove = Trove.new()

--[[ Who was actually here. See EconomyService's `present`, which this mirrors
     deliberately rather than sharing: the two services pay different things and
     coupling their presence rules would mean a change to one silently changing
     who the other pays. ]]
local present: { [Player]: boolean } = {}

-- ── helpers ─────────────────────────────────────────────────────────────────

local function profileService()
	return Registry.find("ProfileService")
end

--[[ Today, as the integer every server in the world agrees on. Quests are
     derived from this rather than rolled, so a player who rejoins gets the same
     three they left — see ProgressionConfig.questsForDay. ]]
local function today(): number
	return math.floor(os.time() / ProgressionConfig.QuestPeriod)
end

local function currentWave(): number
	local value = Attributes.get(Workspace, GA.WaveIndex, 0)
	if typeof(value) ~= "number" or value ~= value then
		return 0
	end
	return math.max(math.floor(value), 0)
end

--[[ A number out of a stats snapshot. The snapshot is built by another service
     from counters this one does not own, so every read is checked: a field that
     was renamed should award nothing rather than throw on the frame a round
     ends, when half the game is already tearing down. ]]
local function statValue(row: any, key: string): number
	if typeof(row) ~= "table" then
		return 0
	end
	local value = row[key]
	if typeof(value) ~= "number" or value ~= value then
		return 0
	end
	return math.max(math.floor(value), 0)
end

--[[ Everything one client needs to draw its own progression, and nothing anybody
     else needs. Level, Scrip and the two worn rewards are NOT in here — they are
     attributes, because every other player's scoreboard wants them too. ]]
local function snapshotFor(player: Player): any?
	local profiles = profileService()
	if not profiles or not profiles:isReady(player) then
		return nil
	end

	local xp = profiles:getXp(player)
	local level, into, cost = ProgressionConfig.resolve(xp)
	local stored = profiles:getQuests(player)

	local quests = {}
	for _, quest in ProgressionConfig.questsForDay(today()) do
		table.insert(quests, { id = quest.id, progress = stored[quest.id] or 0 })
	end

	return {
		xp = xp,
		level = level,
		into = into,
		cost = cost,
		scrip = profiles:getScrip(player),
		passTier = profiles:getPassTier(player),
		degraded = profiles:isDegraded(player),
		quests = quests,
	}
end

local function sync(player: Player)
	if not player.Parent then
		return
	end
	local snapshot = snapshotFor(player)
	if snapshot then
		Remotes.Event.ProgressionSynced:FireClient(player, snapshot)
	end
end

--[[ Puts today's quest set in front of this profile, wiping yesterday's
     counters. Called on load and again at every round end, so a server that
     outlives a day boundary rolls over with the players still in it rather than
     counting a new day's kills against an old day's quests. ]]
local function rollDay(player: Player)
	local profiles = profileService()
	if not profiles or not profiles:isReady(player) then
		return
	end
	local _, storedDay = profiles:getQuests(player)
	if storedDay ~= today() then
		profiles:rollQuests(player, today())
	end
end

-- ── awarding ────────────────────────────────────────────────────────────────

--[[
	Turns one player's round into experience.

	Commons are the REMAINDER — total kills minus the specials and bosses —
	because StatsService's `kills` counts every death including those two, and
	paying the flat rate on the total would pay a Tank at the Common rate on top
	of the Boss rate it already earned.
]]
local function xpForRound(row: any, waveReached: number, victory: boolean): number
	local kills = statValue(row, "kills")
	local specials = statValue(row, "specialKills")
	local bosses = statValue(row, "bossKills")
	local commons = math.max(kills - specials - bosses, 0)

	local earned = commons * XP.Common
		+ specials * XP.Special
		+ bosses * XP.Boss
		+ statValue(row, "headshots") * XP.Headshot
		+ statValue(row, "revives") * XP.Revive
		+ waveReached * XP.WaveReached
	if victory then
		earned += XP.Victory
	end
	return earned
end

--[[
	How much one quest moved this round.

	Every quest is expressed as a positive delta, including the two that are not
	really additive. "Reach wave 5" is a best-of rather than a sum — reaching
	wave 3 twice is not reaching wave 6 — so its delta is however far past the
	stored best this round got, which is zero on a worse round. That keeps a
	single `addQuestProgress` on the profile instead of two kinds of write.
]]
local function questDelta(
	quest: ProgressionConfig.Quest,
	row: any,
	stored: number,
	waveReached: number,
	victory: boolean
): number
	if quest.stat == WAVE_STAT then
		return math.max(waveReached - stored, 0)
	end
	if quest.stat == VICTORY_STAT then
		return if victory then 1 else 0
	end
	return statValue(row, quest.stat)
end

--[[
	The whole round, for one player, in one place.

	Order matters and is not arbitrary. XP is awarded first so a quest reward
	cannot be the thing that crosses a level; the level-ups are paid in Scrip
	before quests are, so a claim button lighting up is attributable to something
	the player can point at. The client gets ONE ProgressionAwarded describing all
	of it, because three toasts racing each other over a results screen is worse
	than one that says what happened.
]]
local function awardRound(player: Player, row: any, waveReached: number, victory: boolean)
	local profiles = profileService()
	if not profiles or not profiles:isReady(player) then
		return
	end

	local xpEarned = xpForRound(row, waveReached, victory)
	local _, levels = profiles:addXp(player, xpEarned)

	local scripEarned = 0
	--[[ Every level crossed this round, wherever it came from. `levels` above is
	     only the ones the round's own XP paid for; a quest reward can cross one
	     too, and a card that said "+2,900 XP" with no level on it while the
	     number on the menu went up would read as the card being wrong. ]]
	local levelsTotal = levels
	if levels > 0 then
		local reached = profiles:getLevel(player)
		--[[ Paid per level CROSSED, not once for the round. A round that carries
		     somebody from 4 to 7 pays three levels and whichever milestones are
		     among them; paying once would quietly rob the best rounds. ]]
		for level = reached - levels + 1, reached do
			scripEarned += ProgressionConfig.scripForLevel(level)
		end
		if scripEarned > 0 then
			profiles:addScrip(player, scripEarned)
		end
	end

	local finished = {}
	local stored = profiles:getQuests(player)
	for _, quest in ProgressionConfig.questsForDay(today()) do
		local delta = questDelta(quest, row, stored[quest.id] or 0, waveReached, victory)
		if delta > 0 then
			local _, justFinished = profiles:addQuestProgress(player, quest.id, delta)
			if justFinished then
				table.insert(finished, quest.id)
				xpEarned += quest.xp
				scripEarned += quest.scrip
				--[[ A quest's XP can itself cross a level, and that level has to
				     be paid too — otherwise finishing a quest at 249/250 hands
				     out a level number with no Scrip behind it. ]]
				local _, bonusLevels = profiles:addXp(player, quest.xp)
				levelsTotal += bonusLevels
				if bonusLevels > 0 then
					local reached = profiles:getLevel(player)
					for level = reached - bonusLevels + 1, reached do
						scripEarned += ProgressionConfig.scripForLevel(level)
						profiles:addScrip(player, ProgressionConfig.scripForLevel(level))
					end
				end
				profiles:addScrip(player, quest.scrip)
			end
		end
	end

	--[[ Written now rather than at the next autosave. This is the largest single
	     thing this file ever gives anybody, and a server that dies during the
	     results screen must not take a whole round of it with it. ]]
	profiles:flush(player)

	local stats = Registry.find("StatsService")
	if stats and typeof(stats.refresh) == "function" then
		--[[ The player list's Level column is live off the attribute, so nothing
		     would redraw it until somebody's next kill — which is next round. ]]
		pcall(stats.refresh, stats, player)
	end

	sync(player)
	if player.Parent then
		Remotes.Event.ProgressionAwarded:FireClient(player, {
			kind = "Round",
			xp = xpEarned,
			scrip = scripEarned,
			levels = levelsTotal,
			level = profiles:getLevel(player),
			quests = finished,
		})
	end
end

local function onRoundEnded(outcome: string)
	local victory = outcome == Enums.RoundState.Victory
	local waveReached = currentWave()

	local rows = {}
	local stats = Registry.find("StatsService")
	if stats then
		local ok, snapshot = pcall(function()
			return stats:snapshot()
		end)
		if ok and typeof(snapshot) == "table" then
			rows = snapshot
		end
	end

	for _, player in Players:GetPlayers() do
		--[[ Not here for the round, not paid for it. See the header. ]]
		if not present[player] then
			continue
		end
		--[[ Before awarding, not after: a round that ends after midnight must
		     count against the day it ends in, and the counters it is about to
		     write have to be the right day's counters. ]]
		rollDay(player)
		awardRound(player, rows[player.Name], waveReached, victory)
	end

	table.clear(present)
end

local function markPresent()
	for _, player in Players:GetPlayers() do
		present[player] = true
	end
end

-- ── the pass ────────────────────────────────────────────────────────────────

local function onClaim(player: Player)
	local profiles = profileService()
	if not profiles or not profiles:isReady(player) then
		return
	end

	local ok, reason = profiles:claimNextPassTier(player)
	if ok then
		--[[ Flushed for the same reason a round award is: this spent something
		     the player earned over days, and losing the tier while keeping the
		     spend is the one outcome there is no way to apologise for. ]]
		profiles:flush(player)
	end

	sync(player)
	if player.Parent then
		Remotes.Event.ProgressionAwarded:FireClient(player, {
			kind = "Pass",
			ok = ok,
			reason = reason,
			tier = profiles:getPassTier(player),
		})
	end
end

local function onSetWorn(player: Player, kind: any, id: any)
	local profiles = profileService()
	if not profiles or not profiles:isReady(player) then
		return
	end
	if typeof(kind) ~= "string" or typeof(id) ~= "string" then
		return
	end
	--[[ Bounded before it reaches the profile. Every real id is a short lowercase
	     word from ProgressionConfig; anything longer is not a near miss, it is
	     somebody seeing how much they can make the server hold. ]]
	if #id > 32 then
		return
	end
	if profiles:setWorn(player, kind, id) then
		profiles:flush(player)
	end
end

-- ── lifecycle ───────────────────────────────────────────────────────────────

function ProgressionService:init() end

function ProgressionService:start()
	local profiles = profileService()
	if profiles and profiles.loaded then
		--[[ The day is rolled the moment a profile lands rather than at the first
		     round end, so a player who opens the menu before playing sees today's
		     three quests at zero rather than yesterday's three part-finished. ]]
		serviceTrove:add(profiles.loaded:connect(function(player: Player)
			rollDay(player)
			sync(player)
		end))
	else
		warn("[ProgressionService] no ProfileService; nothing will be awarded")
	end

	local round = Registry.find("RoundService")
	if round then
		if round.roundEnded then
			serviceTrove:add(round.roundEnded:connect(onRoundEnded))
		end
		--[[ Every wave edge, not just the first, so a mid-round joiner is picked
		     up by the next wave. Mirrors EconomyService exactly. ]]
		if round.waveChanged then
			serviceTrove:add(round.waveChanged:connect(markPresent))
		end
	else
		warn("[ProgressionService] no RoundService; rounds will not award experience")
	end

	local lastRequestAt: { [Player]: number } = setmetatable({}, { __mode = "k" }) :: any
	serviceTrove:connect(Remotes.Event.RequestProgression.OnServerEvent, function(player: Player)
		local now = os.clock()
		if lastRequestAt[player] and now - lastRequestAt[player] < REQUEST_COOLDOWN then
			return
		end
		lastRequestAt[player] = now
		sync(player)
	end)

	local lastClaimAt: { [Player]: number } = setmetatable({}, { __mode = "k" }) :: any
	serviceTrove:connect(Remotes.Event.ClaimPassTier.OnServerEvent, function(player: Player)
		local now = os.clock()
		if lastClaimAt[player] and now - lastClaimAt[player] < CLAIM_COOLDOWN then
			return
		end
		lastClaimAt[player] = now
		onClaim(player)
	end)

	serviceTrove:connect(Remotes.Event.SetWornReward.OnServerEvent, onSetWorn)

	serviceTrove:connect(Players.PlayerAdded, function(player: Player)
		local active = Registry.find("RoundService")
		if active and typeof(active.isRunning) == "function" then
			local ok, running = pcall(active.isRunning, active)
			if ok and running then
				present[player] = true
			end
		end
	end)

	serviceTrove:connect(Players.PlayerRemoving, function(player: Player)
		present[player] = nil
	end)
end

function ProgressionService:destroy()
	table.clear(present)
	serviceTrove:destroy()
end

Registry.register("ProgressionService", ProgressionService)

return ProgressionService
