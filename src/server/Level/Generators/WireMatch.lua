--!strict
--[[
	WireMatch — four wires, four terminals, and none of them opposite each other.

	The player's own idea for this puzzle was connecting cords to matching
	colours, and this is that with the drag taken out: the wires are a column
	down the left, the terminals are a column down the right in a different
	order, and you PRESS the terminal that matches whichever wire is currently
	lit. Same picture, same reasoning, and a thumb on a phone or a stick on a pad
	can do it.

	── THE DERANGEMENT IS THE PUZZLE ───────────────────────────────────────────
	The terminals are shuffled until NO terminal sits in the same row as its
	wire. Without that, a shuffle lands on the identity often enough that a
	player who never looks at the colours gets a free generator every few rounds
	— and worse, a player who gets one learns the wrong lesson about what the
	panel wants.

	Four colours are drawn from a palette of six, so consecutive generators are
	rarely the same four and the round does not settle into one picture.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GeneratorConfig = require(Shared.Config.GeneratorConfig)

local WireMatch = {}

WireMatch.Kind = GeneratorConfig.Kind.WireMatch

--[[ Four of the six. More than four is a column that does not fit a panel a
     phone can read; fewer is a puzzle you can solve by elimination after two
     presses. ]]
local COUNT = 4

--[[ A bounded number of reshuffles before the derangement is built by hand.
     A random shuffle of four is a derangement about three times in eight, so
     twelve tries fails about once in every four hundred thousand puzzles — and
     the rotation below is what happens on that one, because a loop that can
     spin forever inside a round is not a loop, it is a hang. ]]
local SHUFFLE_TRIES = 12

local function shuffled(random: Random, source: { number }): { number }
	local out = table.clone(source)
	for index = #out, 2, -1 do
		local swap = random:NextInteger(1, index)
		out[index], out[swap] = out[swap], out[index]
	end
	return out
end

--[[ Whether any terminal sits opposite its own wire. One row matching is enough
     to make the shuffle worth rejecting: it is the row a guesser gets free. ]]
local function anyAligned(wires: { number }, terminals: { number }): boolean
	for index, colour in wires do
		if terminals[index] == colour then
			return true
		end
	end
	return false
end

export type Deal = { kind: string, challenge: { [string]: any }, solution: { number } }

function WireMatch.deal(random: Random): Deal
	--[[ Four distinct colours, drawn by shuffling the whole palette and taking
	     the front of it. Drawing one at a time and rejecting repeats is the same
	     answer with a loop that gets slower as it fills up. ]]
	local palette = {}
	for index = 1, #GeneratorConfig.Wires do
		table.insert(palette, index)
	end
	palette = shuffled(random, palette)

	local wires: { number } = {}
	for index = 1, COUNT do
		wires[index] = palette[index]
	end

	local terminals = shuffled(random, wires)
	local tries = 0
	while anyAligned(wires, terminals) and tries < SHUFFLE_TRIES do
		terminals = shuffled(random, wires)
		tries += 1
	end
	if anyAligned(wires, terminals) then
		--[[ The guaranteed answer, for the one puzzle in four hundred thousand
		     the shuffles did not find one for. Rotating every entry by one is a
		     derangement of any list with no repeats in it, which this has none
		     of because the colours were drawn distinct. ]]
		local rotated: { number } = {}
		for index = 1, COUNT do
			rotated[index] = wires[(index % COUNT) + 1]
		end
		terminals = rotated
	end

	--[[ Which terminal each wire wants, top to bottom. Derived from the two
	     columns rather than rolled beside them — the rule this file exists to
	     keep is the vault's: the answer is READ OUT of what the player is
	     shown, so there is no arrangement of pixels the answer can disagree
	     with. ]]
	local solution: { number } = {}
	for index, colour in wires do
		for slot, terminal in terminals do
			if terminal == colour then
				solution[index] = slot
				break
			end
		end
	end

	return {
		kind = WireMatch.Kind,
		challenge = { wires = wires, terminals = terminals },
		solution = solution,
	}
end

function WireMatch.check(deal: Deal, answer: { number }): boolean
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

return WireMatch
