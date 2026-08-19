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

local function bump(player: Player?, key: string, amount: number)
	if not player or amount == 0 then
		return
	end
	local record = recordFor(player)
	record[key] += amount
	dirty = true
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

	serviceTrove:connect(Players.PlayerAdded, function(player)
		recordFor(player)
		dirty = true
	end)
	serviceTrove:connect(Players.PlayerRemoving, function(player)
		stats[player] = nil
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
