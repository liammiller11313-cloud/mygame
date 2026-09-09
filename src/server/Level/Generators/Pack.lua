--!strict
--[[
	Pack — the five mini-puzzles, dealt out across the generators.

	One place that knows every puzzle exists, so PuzzleService knows none of
	them. Adding a sixth is a file beside this one and a row in MODULES; nothing
	downstream of here has ever heard of a wire, a breaker or a needle.

	── EVERY ROUND IS A DIFFERENT DEAL ─────────────────────────────────────────
	The player asked for the puzzles to be mixed up every round, and this is
	where that happens: `assign` shuffles the five kinds and hands them out, so
	generator three is a breaker panel this round and a pressure gauge the next.
	The generators themselves do NOT move and are always walked 1 to 5 — the
	route is the thing a team learns about the map, and the puzzle at the end of
	each leg is the thing they cannot learn. Same split the vault makes between
	its fixed props and its rolled documents.

	With five puzzles and five generators a shuffle deals each one exactly once,
	which is the shape worth having: a round where two generators are the same
	puzzle wastes one of the five on a player who has just done it.

	── AND WHAT COMES OFF THE WIRE IS NOT TRUSTED ──────────────────────────────
	`sanitise` is the only door an answer comes through. Every one of the five
	checks assumes it has been handed a short list of whole numbers, and every
	one of them would be reading a crafted client's table without it — the
	length first, because a handler that iterates whatever it was given is a
	handler anybody standing at a machine can hang the round with.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GeneratorConfig = require(Shared.Config.GeneratorConfig)

local Pack = {}

--[[ The five, by kind. A table rather than a list so a definition naming a
     puzzle that does not exist fails as a nil lookup here rather than as the
     wrong puzzle drawn in front of a player. ]]
local MODULES = {
	[GeneratorConfig.Kind.WireMatch] = require(script.Parent.WireMatch),
	[GeneratorConfig.Kind.BreakerOrder] = require(script.Parent.BreakerOrder),
	[GeneratorConfig.Kind.VoltageMatch] = require(script.Parent.VoltageMatch),
	[GeneratorConfig.Kind.PressureValve] = require(script.Parent.PressureValve),
	[GeneratorConfig.Kind.PhaseAlign] = require(script.Parent.PhaseAlign),
}

--[[ In a fixed order, because `assign` shuffles a copy of this and a shuffle of
     a table with no order is a different pack on every server. ]]
local KINDS: { string } = {
	GeneratorConfig.Kind.WireMatch,
	GeneratorConfig.Kind.BreakerOrder,
	GeneratorConfig.Kind.VoltageMatch,
	GeneratorConfig.Kind.PressureValve,
	GeneratorConfig.Kind.PhaseAlign,
}

Pack.Kinds = table.freeze(table.clone(KINDS))

export type Deal = { kind: string, challenge: { [string]: any }, solution: any }

--[[
	Which puzzle each generator gets this round, in generator order.

	Shuffled, then handed out. When there are more generators than puzzles the
	pack is reshuffled and dealt again rather than repeating from where it left
	off, so a sixth generator is a fresh draw instead of always being whatever
	came first last time.
]]
function Pack.assign(random: Random, count: number): { string }
	local out: { string } = {}
	local bag: { string } = {}

	for index = 1, math.max(count, 0) do
		if #bag == 0 then
			bag = table.clone(KINDS)
			for slot = #bag, 2, -1 do
				local swap = random:NextInteger(1, slot)
				bag[slot], bag[swap] = bag[swap], bag[slot]
			end
		end
		out[index] = table.remove(bag) :: string
	end

	return out
end

--[[ A fresh puzzle of one kind, or nil if this build has no such kind. Nil is
     handled rather than warned about by the caller, because a generator with no
     puzzle should be a generator that says so and not a round that will not
     start. ]]
function Pack.deal(kind: string, random: Random): Deal?
	local module = MODULES[kind]
	if not module then
		return nil
	end
	return module.deal(random)
end

--[[ Whether an answer solves a deal. False for a kind this build does not have,
     which is the safe direction: an unknown puzzle refuses rather than opens. ]]
function Pack.check(deal: Deal?, answer: { number }): boolean
	if not deal then
		return false
	end
	local module = MODULES[deal.kind]
	if not module then
		return false
	end
	return module.check(deal, answer) == true
end

--[[
	Whatever arrived, turned into a short list of whole numbers, or nil.

	Copied rather than validated in place: the table a remote handed over is the
	client's, and holding onto it means holding onto whatever else is hanging off
	it. Everything downstream reads this copy.
]]
function Pack.sanitise(answer: any): { number }?
	if typeof(answer) ~= "table" then
		return nil
	end
	--[[ Length first. A table of a million entries costs nothing to send and
	     would otherwise be a million iterations of a loop, on the server, at the
	     request of anybody standing at a machine. ]]
	local count = #answer
	if count < 1 or count > GeneratorConfig.MaxAnswer then
		return nil
	end

	local out: { number } = {}
	for index = 1, count do
		local value = answer[index]
		--[[ Whole numbers only, and finite. `value ~= value` is the NaN test:
		     NaN is a number, survives a floor, and compares false against every
		     band and index in the pack — so a needle at NaN would fail every
		     check silently rather than be refused here, which is the same
		     outcome by luck rather than by rule. ]]
		if typeof(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
			return nil
		end
		if value % 1 ~= 0 then
			return nil
		end
		out[index] = value
	end
	return out
end

return Pack
