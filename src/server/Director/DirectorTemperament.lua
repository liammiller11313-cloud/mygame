--!nonstrict
--[[
	DirectorTemperament — the Director's personality for this round.

	The pacing machine in DirectorService is deterministic: given the same team
	intensity it makes the same decision every time. That is exactly right for
	readability and exactly wrong for replay value, because a team that plays a
	map twice learns when the pressure comes and stops being afraid of it.

	This layer sits beside it and answers "how does THIS Director lean". It rolls
	a temperament per round and a lighter mood per wave, and everything it
	produces is a MULTIPLIER on a decision the wave budget already made. It can
	never widen a limit, only lean inside one — so the Director stays unfair-
	proof: it still refuses to spawn in your field of view, still backs off when
	the team is hurt, still respects the wave's ceiling.

	It also carries the SKILL READ, which is a slower and separate question from
	intensity. Intensity asks "is this moment rough"; skill asks "are these
	players good". A strong team sits at low intensity all round precisely
	because they are killing things before the pressure lands, and a Director
	that only watched intensity would conclude the wave was going fine and let
	them coast.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local DirectorConfig = require(Shared.Config.DirectorConfig)
local Registry = require(Shared.Util.Registry)

local MOOD = DirectorConfig.Mood
local SKILL = DirectorConfig.Skill

local DirectorTemperament = {}

local random = Random.new()

local state = {
	temperament = DirectorConfig.Temperaments[1],
	waveIndex = 0,
	moodRolledAt = 0,

	-- Per-wave mood multipliers, re-rolled on every wave.
	population = 1,
	spawnRate = 1,
	specialRate = 1,

	-- Skill read: -1 struggling, 0 average, +1 dominating.
	skill = 0,
	kills = 0,
	damageTaken = 0,
	windowStart = 0,
}

local function now(): number
	return Workspace:GetServerTimeNow()
end

--[[ Weighted pick over the temperament table, so the pool can be rebalanced by
     editing weights rather than by duplicating entries. ]]
local function rollTemperament()
	local total = 0
	for _, entry in DirectorConfig.Temperaments do
		total += entry.weight
	end
	local roll = random:NextNumber() * total
	for _, entry in DirectorConfig.Temperaments do
		roll -= entry.weight
		if roll <= 0 then
			return entry
		end
	end
	return DirectorConfig.Temperaments[1]
end

local function jitter(spread: number): number
	return 1 + (random:NextNumber() * 2 - 1) * spread
end

local function rollMood()
	state.population = jitter(MOOD.PopulationJitter)
	state.spawnRate = jitter(MOOD.SpawnRateJitter)
	state.specialRate = jitter(MOOD.SpecialRateJitter)
	state.moodRolledAt = now()
end

--[[ Called by RoundService as a round starts. One temperament for the whole
     round: changing it mid-round would read as the game glitching rather than as
     the Director having a character. ]]
function DirectorTemperament:beginRound()
	state.temperament = rollTemperament()
	state.waveIndex = 0
	state.skill = 0
	state.kills = 0
	state.damageTaken = 0
	state.windowStart = now()
	rollMood()

	print(string.format("[Director] temperament for this round: %s", state.temperament.displayName))
	return state.temperament
end

function DirectorTemperament:beginWave(waveIndex: number)
	state.waveIndex = waveIndex
	rollMood()
end

--[[ Erratic rerolls its mood mid-wave; everything else holds. That single
     difference is what makes it feel like it is changing its mind. ]]
function DirectorTemperament:update()
	if state.temperament.id ~= "Erratic" then
		return
	end
	if now() - state.moodRolledAt >= MOOD.ErraticRerollSeconds then
		rollMood()
	end
end

function DirectorTemperament:getTemperament()
	return state.temperament
end

function DirectorTemperament:getName(): string
	return state.temperament.displayName
end

-- ── the skill read ──────────────────────────────────────────────────────────

function DirectorTemperament:recordKill()
	state.kills += 1
end

function DirectorTemperament:recordDamage(amount: number)
	state.damageTaken += math.max(amount, 0)
end

--[[
	Moves the skill read toward what the last window actually showed.

	Two signals, deliberately opposed: killing fast pushes it up, taking damage
	pushes it down. A team that is killing quickly AND taking hits is average,
	which is correct — that is a team trading, not a team in control.
]]
function DirectorTemperament:updateSkill(survivorCount: number)
	local elapsed = now() - state.windowStart
	if elapsed < SKILL.Window then
		return
	end

	local minutes = elapsed / 60
	local perSecond = state.kills / math.max(elapsed, 1)
	local perSurvivorPerMinute = state.damageTaken / math.max(survivorCount, 1) / math.max(minutes, 0.01)

	local killScore = (perSecond / SKILL.KillsPerSecondBaseline) - 1
	local painScore = (perSurvivorPerMinute / SKILL.DamageTakenBaseline) - 1

	local target = math.clamp(killScore - painScore, -1, 1)
	state.skill += (target - state.skill) * SKILL.Responsiveness

	state.kills = 0
	state.damageTaken = 0
	state.windowStart = now()
end

function DirectorTemperament:getSkill(): number
	return state.skill
end

--[[ What the skill read is worth as a population multiplier. Bounded hard and
     asymmetrically: a struggling team gets more relief than a dominating one
     gets punishment, because being crushed for playing badly is a worse
     experience than coasting for playing well. ]]
function DirectorTemperament:getSkillScale(): number
	if state.skill >= 0 then
		return 1 + state.skill * SKILL.MaxBoost
	end
	return 1 + state.skill * SKILL.MaxRelief
end

-- ── the multipliers DirectorService actually asks for ───────────────────────

function DirectorTemperament:getPopulationScale(): number
	return state.temperament.population * state.population * self:getSkillScale()
end

function DirectorTemperament:getSpawnRateScale(): number
	return state.temperament.spawnRate * state.spawnRate
end

function DirectorTemperament:getSpecialIntervalScale(): number
	return state.temperament.specialRate * state.specialRate
end

--[[
	How clumpy arrivals are.

	Returned as a batch multiplier rather than as a raw number: at burstiness 0
	the Director sends its batch as configured, and at 1 it holds several batches
	back and sends them as one. Same total population either way — the difference
	is entirely in whether a horde arrives as a stream or as a wall, and that
	difference is most of what separates "busy" from "frightening".
]]
function DirectorTemperament:getBurstScale(): number
	local burst = state.temperament.burstiness
	if burst <= 0 then
		return 1
	end
	-- Rolled per call so a bursty Director is bursty irregularly rather than on
	-- a rhythm anyone could count.
	if random:NextNumber() < burst then
		return 1 + burst * 2.2
	end
	return math.max(1 - burst * 0.55, 0.25)
end

function DirectorTemperament:shouldPairSpecials(): boolean
	return random:NextNumber() < state.temperament.pairChance
end

--[[ True when the next group should come from BEHIND the team rather than from
     ahead of it. Being cut off from the way you came is a different kind of
     pressure from being blocked, and alternating between them is what stops a
     team from simply always facing forward. ]]
function DirectorTemperament:shouldFlank(): boolean
	return random:NextNumber() < state.temperament.flankChance
end

--[[ A one-line summary for the debug overlay and the round log. Being able to
     see WHY a round felt the way it did is most of what makes this tunable. ]]
function DirectorTemperament:describe(): string
	return string.format(
		"%s | pop x%.2f | rate x%.2f | specials x%.2f | skill %+.2f",
		state.temperament.displayName,
		self:getPopulationScale(),
		self:getSpawnRateScale(),
		self:getSpecialIntervalScale(),
		state.skill
	)
end

Registry.register("DirectorTemperament", DirectorTemperament)

return DirectorTemperament
