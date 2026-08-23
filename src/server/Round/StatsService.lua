--!nonstrict
--[[
	StatsService — what each player actually did this round.

	The end-of-round scoreboard was rendering dashes. MainMenuController has been
	built to show kills, headshots, damage taken and revives since it was written,
	and `Remotes.Event.StatsUpdated` has been in the manifest the whole time with
	nothing on the server firing it — so the screen fell back to what a client can
	honestly observe about itself, which is almost nothing about anyone else.

	This is the missing producer. It owns no gameplay and makes no decisions: it
	listens to signals the combat systems already fire and counts. That is
	deliberate — a tally that can influence the fight is a tally that can be
	blamed for it.

	Everything is keyed by Player rather than by name so a rename mid-round cannot
	orphan a row, and flattened to names only at the moment it is sent.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attributes = require(Shared.Net.Attributes)
local Enums = require(Shared.Enums)
local InfectedConfig = require(Shared.Config.InfectedConfig)
local Registry = require(Shared.Util.Registry)
local Remotes = require(Shared.Net.Remotes)
local Trove = require(Shared.Util.Trove)

--[[ Pushed to clients on this interval rather than on every kill. A player
     killing forty commons a minute would otherwise be forty broadcasts a minute
     per player, to say a number nobody is looking at mid-fight. ]]
local BROADCAST_INTERVAL = 5

local StatsService = {}

local serviceTrove = Trove.new()
local stats: { [Player]: { [string]: number } } = {}
local dirty = false
local accumulator = 0

local function blank(): { [string]: number }
	return {
		kills = 0,
		specialKills = 0,
		bossKills = 0,
		headshots = 0,
		damageDealt = 0,
		damageTaken = 0,
		friendlyFire = 0,
		revives = 0,
		incaps = 0,
		deaths = 0,
	}
end

local function recordFor(player: Player): { [string]: number }
	local record = stats[player]
	if not record then
		record = blank()
		stats[player] = record
	end
	return record
end

--[[
	The Roblox player list, which is a different audience from the scoreboard.

	The end-of-round card is a report on the round you just played; this is the
	thing anybody can pull up mid-fight with one key to see how the team is
	doing, and it survives the round because leaderstats are per-session rather
	than per-round. Two numbers only: what you killed, and how many times you
	went down for good. A player list with ten columns is a player list nobody
	reads.

	"Wipeouts" rather than "Deaths" because that is this game's word for it — the
	round ends in a team wipeout, and a survivor who did not get up was wiped
	out. Consistency with what the game says everywhere else is worth more than
	the more obvious noun.
]]
--[[ `live` marks a column that is NOT a session counter — it is read straight
     off whatever already owns the number, every time the board is pushed. See
     the Dollars entry. ]]
local LEADERBOARD: { { key: string, title: string, live: boolean? } } = {
	{ key = "kills", title = "Kills" },
	{ key = "deaths", title = "Wipeouts" },
	--[[
		What is in your wallet right now, not what you have earned all session.

		Deliberately different from the two above it, and worth being explicit
		about because the difference is the whole design of this file: kills and
		wipeouts ACCUMULATE, so they are counted here and survive a round reset.
		Dollars do not accumulate — you spend them — and EconomyService already
		owns the number and publishes it as an attribute the HUD reads. Counting a
		second copy here would be a total that drifted from the balance the player
		can see in their own corner, and the one on the player list would be the
		wrong one.

		So this column has no counter behind it. It mirrors the attribute, which
		makes it correct by construction and free to keep correct.
	]]
	{ key = "dollars", title = "Dollars", live = true },
}

--[[ The current value of a live column, or nil for a counted one. ]]
local function liveValue(player: Player, key: string): number?
	if key == "dollars" then
		return Attributes.get(player, Attributes.Player.Dollars, 0)
	end
	return nil
end

local function leaderboardFor(player: Player): Folder?
	local existing = player:FindFirstChild("leaderstats")
	if existing then
		return existing :: Folder
	end
	if not player.Parent then
		return nil
	end

	--[[ Named exactly "leaderstats". Roblox looks that folder up by name to
	     build the player list, and any other name is a folder nobody ever
	     sees. ]]
	local folder = Instance.new("Folder")
	folder.Name = "leaderstats"
	for _, column in LEADERBOARD do
		local value = Instance.new("IntValue")
		value.Name = column.title
		value.Value = 0
		value.Parent = folder
	end
	folder.Parent = player
	return folder
end

--[[
	Session totals, which are NOT the per-round counters above.

	`stats` is cleared at the start of every round, because the scoreboard is a
	report on the round that just happened. The player list is the opposite: it
	is what somebody checks in the middle of their fourth round to see how the
	team has been doing all evening, and a column that silently zeroes every
	seventeen minutes is worse than no column.

	So the two are kept apart. Reading the player list off `stats` would have
	looked correct and quietly reset itself.
]]
local session: { [Player]: { [string]: number } } = {}

local function sessionFor(player: Player): { [string]: number }
	local record = session[player]
	if not record then
		record = {}
		for _, column in LEADERBOARD do
			--[[ Counted columns only. A live column has no counter and giving it a
			     zero here would be a number that looked authoritative, was never
			     written to, and would be shown the moment anything read the wrong
			     branch of pushLeaderboard. ]]
			if not column.live then
				record[column.key] = 0
			end
		end
		session[player] = record
	end
	return record
end

--[[ Mirrors one player's session totals onto their leaderstats. Cheap and
     idempotent: an IntValue only replicates when the number actually changes,
     so calling this on every bump costs a comparison rather than a network
     write. ]]
local function pushLeaderboard(player: Player)
	local folder = leaderboardFor(player)
	if not folder then
		return
	end
	local record = sessionFor(player)
	for _, column in LEADERBOARD do
		local value = folder:FindFirstChild(column.title)
		if value and value:IsA("IntValue") then
			local number = if column.live then liveValue(player, column.key) or 0 else record[column.key] or 0
			value.Value = math.floor(number)
		end
	end
end

local function bump(player: Player?, key: string, amount: number)
	if not player or amount == 0 then
		return
	end
	local record = recordFor(player)
	record[key] += amount
	dirty = true

	-- Only the two columns the player list shows; every other counter changes
	-- many times a second and none of them are on it.
	for _, column in LEADERBOARD do
		--[[ Counted columns only. A live column has no counter to add to, so this
		     would be arithmetic on a nil the first time anybody wired a bump to
		     one — and the number it was trying to keep is already correct. ]]
		if column.key == key and not column.live then
			sessionFor(player)[key] += amount
			pushLeaderboard(player)
			break
		end
	end
end

--[[ Name-keyed snapshot, which is the shape both `StatsUpdated` and
     `RoundEnded.scores` are read in. Incaps come from the attribute rather than
     a counter here, because SurvivorService already owns that number and two
     sources of truth for it would eventually disagree. ]]
function StatsService:snapshot(): { [string]: any }
	local out = {}
	for player, record in stats do
		if player.Parent then
			local copy = table.clone(record)
			copy.incaps = Attributes.get(player, Attributes.Player.IncapCount, 0)
			copy.accuracy = 0
			out[player.Name] = copy
		end
	end
	return out
end

function StatsService:get(player: Player): { [string]: number }
	return recordFor(player)
end

--[[ Wipes the board. Called by RoundService when a round starts, so a scoreboard
     never shows last round's numbers. ]]
--[[ Wipes the per-round counters. The player list is deliberately NOT reset:
     leaderstats are the session total, which is the whole reason to look at
     them rather than at the scoreboard that just cleared itself. ]]
function StatsService:reset()
	table.clear(stats)
	for _, player in Players:GetPlayers() do
		recordFor(player)
	end
	dirty = true
end

function StatsService:broadcast()
	dirty = false
	Remotes.Event.StatsUpdated:FireAllClients(self:snapshot())
end

function StatsService:init()
	self:reset()
end

function StatsService:start()
	local infected = Registry.find("InfectedService")
	local survivors = Registry.find("SurvivorService")
	local damage = Registry.find("DamageService")

	--[[ Kills. Read the region off the context that killed it rather than
	     re-deriving it, so a headshot credited here is the same event that got
	     the 4x multiplier and the bone impact sound. ]]
	if infected and infected.died then
		serviceTrove:add(infected.died:connect(function(_model, kind, ctx)
			local attacker = ctx and ctx.attacker
			if not attacker then
				return
			end
			bump(attacker, "kills", 1)
			if ctx.region == Enums.HitRegion.Head then
				bump(attacker, "headshots", 1)
			end
			local definition = InfectedConfig.get(kind)
			if definition then
				if definition.isBoss then
					bump(attacker, "bossKills", 1)
				elseif definition.isSpecial then
					bump(attacker, "specialKills", 1)
				end
			end
		end))
	end

	if survivors then
		if survivors.damaged then
			serviceTrove:add(survivors.damaged:connect(function(player, amount, _ctx)
				bump(player, "damageTaken", math.floor(amount + 0.5))
			end))
		end
		if survivors.died then
			serviceTrove:add(survivors.died:connect(function(player)
				bump(player, "deaths", 1)
			end))
		end
		if survivors.revived then
			-- Credit the rescuer, not the person who stood up. Picking your team
			-- back up is the cooperative act worth counting.
			serviceTrove:add(survivors.revived:connect(function(_player, rescuer)
				bump(rescuer, "revives", 1)
			end))
		end
	end

	--[[ Damage dealt, split by whether it landed on the right team. Friendly fire
	     is tracked separately and deliberately: it is the one number on the board
	     that a player would rather nobody saw, which is exactly why showing it
	     changes how carefully people shoot in a doorway. ]]
	if damage and damage.damageDealt then
		serviceTrove:add(damage.damageDealt:connect(function(_target, result, ctx)
			local attacker = ctx and ctx.attacker
			if not attacker or not result or result.blocked then
				return
			end
			local dealt = math.floor((result.dealt or 0) + 0.5)
			if ctx.isFriendlyFire then
				bump(attacker, "friendlyFire", dealt)
			else
				bump(attacker, "damageDealt", dealt)
			end
		end))
	end

	--[[ A live column moves without anything in this file being told, so the
	     board follows the attribute rather than waiting for the next kill. Every
	     purchase and every payout writes it, and an IntValue only replicates when
	     the number actually changes — so this costs a comparison per spend. ]]
	local function watchWallet(player: Player)
		serviceTrove:add(player:GetAttributeChangedSignal(Attributes.Player.Dollars):Connect(function()
			pushLeaderboard(player)
		end))
	end

	serviceTrove:connect(Players.PlayerAdded, function(player)
		recordFor(player)
		pushLeaderboard(player)
		watchWallet(player)
		dirty = true
	end)
	for _, player in Players:GetPlayers() do
		--[[ Anybody already here when this service started. In Studio the local
		     player joins during boot, so without this the first player of every
		     test session has no row until their first kill. ]]
		recordFor(player)
		pushLeaderboard(player)
		watchWallet(player)
	end
	serviceTrove:connect(Players.PlayerRemoving, function(player)
		stats[player] = nil
		session[player] = nil
	end)

	serviceTrove:connect(RunService.Heartbeat, function(dt)
		accumulator += dt
		if accumulator < BROADCAST_INTERVAL then
			return
		end
		accumulator = 0
		if dirty then
			self:broadcast()
		end
	end)
end

Registry.register("StatsService", StatsService)

return StatsService
