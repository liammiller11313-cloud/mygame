--!strict
--[[
	VoltageMatch — six cells, one bus target, pick the three that make it.

	The arithmetic one. It is the only puzzle in the pack a player can be BAD at
	rather than slow at, which is why the numbers are deliberately kind: every
	cell is a multiple of five between twenty and ninety, so the sums are in
	fives and a player is adding 45 + 60 + 25 rather than 47 + 63 + 22.

	── THE TARGET IS BUILT FROM A REAL ANSWER ──────────────────────────────────
	Three cells are rolled, the target is their sum, and then three decoys are
	rolled and the six are shuffled. A target rolled independently of the cells
	is a target the cells might not be able to reach — a puzzle with no solution,
	which the player cannot tell apart from a puzzle they cannot solve. Same rule
	the vault's code follows, for the same reason.

	── AND MORE THAN ONE ANSWER IS FINE ────────────────────────────────────────
	The decoys are not filtered for accidentally making a second valid triple.
	The check is on the SUM, not on which three were picked, so a second route to
	the target is simply a second right answer — which is what "add up to" means,
	and a player who finds the other one has done the puzzle.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GeneratorConfig = require(Shared.Config.GeneratorConfig)

local VoltageMatch = {}

VoltageMatch.Kind = GeneratorConfig.Kind.VoltageMatch

local CELLS = 6
--[[ Three, not two. Two is a lookup — find the pair, and once you have one cell
     the other is subtraction. Three is enough for the player to have to hold a
     running total, and few enough that the panel does not become a search. ]]
local PICK = 3
local STEP = 5
local MIN_STEP = 4 -- 20V
local MAX_STEP = 18 -- 90V

export type Deal = { kind: string, challenge: { [string]: any }, solution: { target: number, pick: number } }

function VoltageMatch.deal(random: Random): Deal
	local cells: { number } = {}
	local target = 0
	for _ = 1, PICK do
		local value = random:NextInteger(MIN_STEP, MAX_STEP) * STEP
		table.insert(cells, value)
		target += value
	end
	for _ = 1, CELLS - PICK do
		table.insert(cells, random:NextInteger(MIN_STEP, MAX_STEP) * STEP)
	end

	for index = #cells, 2, -1 do
		local swap = random:NextInteger(1, index)
		cells[index], cells[swap] = cells[swap], cells[index]
	end

	return {
		kind = VoltageMatch.Kind,
		--[[ Everything here is on the panel already: the six cells are printed on
		     the buttons and the target is printed above them. There is no half of
		     this puzzle to withhold — what makes it a puzzle is the adding. ]]
		challenge = { cells = cells, target = target, pick = PICK },
		solution = { target = target, pick = PICK },
	}
end

function VoltageMatch.check(deal: Deal, answer: { number }): boolean
	if #answer ~= deal.solution.pick then
		return false
	end
	local cells = deal.challenge.cells
	local seen: { [number]: boolean } = {}
	local sum = 0
	for _, index in answer do
		--[[ Distinct, and in range. Without this a client could send the same
		     cell three times and pay for a target with one cell — which is not
		     an exploit worth much, and is exactly the shape of the bug that
		     turns up when somebody later reuses this check for something that
		     matters. ]]
		if typeof(index) ~= "number" or index % 1 ~= 0 or seen[index] then
			return false
		end
		local value = cells[index]
		if typeof(value) ~= "number" then
			return false
		end
		seen[index] = true
		sum += value
	end
	return sum == deal.solution.target
end

return VoltageMatch
