--!strict
--[[
	BreakerOrder — five breakers, five ratings, one instruction.

	The simplest of the five and deliberately so: one of a pack of five should be
	the one a player can finish without stopping moving, because four of them
	demand a moment of standing still and a horde does not grant five.

	The whole puzzle is reading five numbers and pressing them in order. What
	makes it not free is that the direction changes — half the deals want the
	lowest first and half want the highest — so a player who has done it before
	still has to read the line above it, and a player who assumes gets a reset
	rather than a generator.

	── THE RATINGS ARE PLAUSIBLE, NOT ARBITRARY ────────────────────────────────
	Multiples of five between fifteen and a hundred and twenty-five, which is
	what is actually stamped on a breaker. It costs nothing and it is the
	difference between a panel of five numbers and a panel of five breakers.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GeneratorConfig = require(Shared.Config.GeneratorConfig)

local BreakerOrder = {}

BreakerOrder.Kind = GeneratorConfig.Kind.BreakerOrder

local COUNT = 5
--[[ 15, 20, 25 … 125. Twenty-three of them for five slots, so the five drawn
     are comfortably spread and no deal is five numbers within ten amps of each
     other — which would be a reading test rather than an ordering one. ]]
local STEP = 5
local MIN_STEP = 3 -- 15A
local MAX_STEP = 25 -- 125A

export type Deal = { kind: string, challenge: { [string]: any }, solution: { number } }

function BreakerOrder.deal(random: Random): Deal
	--[[ Distinct, because two breakers rated the same have no order between
	     them and the puzzle would have two right answers while accepting one.
	     Drawn by shuffling the whole ladder rather than by rolling and
	     rejecting: a rejection loop on a small pool gets slower exactly as it
	     gets closer to finishing. ]]
	local ladder: { number } = {}
	for step = MIN_STEP, MAX_STEP do
		table.insert(ladder, step * STEP)
	end
	for index = #ladder, 2, -1 do
		local swap = random:NextInteger(1, index)
		ladder[index], ladder[swap] = ladder[swap], ladder[index]
	end

	local ratings: { number } = {}
	for index = 1, COUNT do
		ratings[index] = ladder[index]
	end

	local ascending = random:NextInteger(1, 2) == 1

	--[[ The order the breakers are in once sorted by rating, as INDICES into the
	     panel — the player presses a position, not a number, so the answer has
	     to be in the same currency the press arrives in. ]]
	local order: { number } = {}
	for index = 1, COUNT do
		order[index] = index
	end
	table.sort(order, function(left: number, right: number): boolean
		if ascending then
			return ratings[left] < ratings[right]
		end
		return ratings[left] > ratings[right]
	end)

	return {
		kind = BreakerOrder.Kind,
		--[[ `ascending` is public and has to be: it is printed on the panel as
		     the instruction, and a direction the player cannot read is a coin
		     flip rather than a puzzle. ]]
		challenge = { ratings = ratings, ascending = ascending },
		solution = order,
	}
end

function BreakerOrder.check(deal: Deal, answer: { number }): boolean
	if #answer ~= #deal.solution then
		return false
	end
	for index, wanted in deal.solution do
		if answer[index] ~= wanted then
			return false
		end
	end
	return true
end

return BreakerOrder
