--!strict
--[[
	FuseSequence — four breaker boxes, thrown in an order the round invents.

	The Backrooms' template, and the second shape the registry has had to hold.
	Same four questions every template answers:

	    generate(random, definition)  what values is this round's puzzle made of
	    answer(values)                what those values spell
	    surfaces(definition, values)  what each prop reads
	    prompt(clue, values)          what the HUD says when one is read

	And the same silence about everything else: it does not know what a fuse box
	is, it never sees a player, it cannot open a door and it has no opinion about
	rewards. PuzzleService owns all of that already for two other puzzles.

	── THE ANSWER IS READ OUT OF THE CLUES, NEVER ROLLED ───────────────────────
	The one rule this file exists to keep. What `generate` rolls is a PERMUTATION
	of the box numbers; `answer` walks the clue slots in order and reads the box
	each of them names. There is no branch in this file where a sequence is
	chosen and documents are then written to match it, because that is the branch
	where the two can drift — and a puzzle whose clues can be wrong is worse than
	no puzzle at all, since the player cannot tell "I misread it" from "the game
	lied to me".

	── ONE POSITION PER DOCUMENT, AND ONLY ITS OWN ─────────────────────────────
	Clue 1 knows which box is first and knows nothing else. Clue 2 knows the
	second, and so on. `surfaces` enforces that by handing each document ONLY the
	key for its own position, so a text that reaches for another prints the
	placeholder rather than the number — visible on the prop, in a screenshot,
	which is the failure mode you want, because the alternative is two documents
	quietly agreeing until the day somebody edits one of them.

	It also means three clues are enough: the fourth box is whatever is left, and
	a document that fell through the world does not cost the team the round.

	── WHY IT LIVES ON THE SERVER ──────────────────────────────────────────────
	Same reason NumberInvestigation does. The sequence is never sent anywhere.
	What replicates is the printed text on four props — the same words a player
	reads with their eyes — and there is nothing on a client to decompile,
	because the table that holds the order has never been there.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PuzzleConfig = require(Shared.Config.PuzzleConfig)

local FuseSequence = {}

export type Values = {
	--[[ The box to throw at each position: `sequence[1]` is thrown first. A
	     permutation, so every box appears exactly once and the round always has
	     exactly one solution. ]]
	sequence: { number },
	--[[ Which PHRASING each document prints this round, by clue order. Rolled
	     here rather than in `surfaces`, which runs again whenever a prop is
	     reprinted — picking there would reword a document under somebody who was
	     halfway through reading it. ]]
	variants: { number },
	[string]: any,
}

--[[ What a document calls the position it owns. The index is the clue's order,
     so clue 3 is handed `third` and nothing else. Written once here because
     `surfaces` and nobody else may decide what a clue is allowed to know. ]]
local POSITION = table.freeze({ "first", "second", "third", "fourth" })

--[[ Written the way somebody fills in a form in the week everything stopped.
     Flavour, and deliberately never a box number: a number in a field the
     player has been taught to skip is a number they will never find. ]]
local function rollDate(random: Random): string
	return string.format("%02d/%02d", random:NextInteger(1, 12), random:NextInteger(1, 28))
end

--[[
	A permutation of 1..count, in place, from the supplied Random.

	Fisher-Yates walked downwards. Worth writing out rather than reaching for a
	shuffle helper this codebase does not have, and worth doing PROPERLY: the
	sort-by-random-key trick people reach for instead is biased, and a biased
	shuffle here means some sequences are commoner than others — which is a
	pattern a team that plays this map every night would eventually learn, and
	the whole point of rolling the order is that there is nothing to learn.
]]
local function shuffled(random: Random, count: number): { number }
	local out: { number } = {}
	for index = 1, count do
		out[index] = index
	end
	for index = count, 2, -1 do
		local swap = random:NextInteger(1, index)
		out[index], out[swap] = out[swap], out[index]
	end
	return out
end

--[[
	This round's puzzle.

	Every value comes from the supplied Random, so a caller that wants a
	reproducible round supplies its own — the same courtesy ModifierConfig.roll
	extends, and the reason neither of them reaches for math.random.
]]
function FuseSequence.generate(random: Random, definition: PuzzleConfig.PuzzleDefinition?): Values
	local set = definition and definition.fuses
	local count = if set then set.count else #POSITION

	--[[ One phrasing per document. The definition is optional so a caller that
	     only wants values — a test, a future tool — is not forced to hand one
	     over; without it every clue falls to its first phrasing, which is what
	     this file did before phrasings existed. ]]
	local variants: { number } = {}
	if definition and definition.clues then
		for _, clue in definition.clues do
			local choices = #clue.texts
			variants[clue.order] = if choices > 1 then random:NextInteger(1, choices) else 1
		end
	end

	--[[ One technician, named on TWO documents — the note and the hazmat log.
	     The only cross-reference in the set, and the cheapest possible way to say
	     these papers were left by a person rather than dealt by a generator. ]]
	local tech = PuzzleConfig.Technicians[random:NextInteger(1, #PuzzleConfig.Technicians)]

	return {
		sequence = shuffled(random, count),
		variants = variants,
		tech = string.format("%s %s", tech.first, tech.last),
		techInitial = string.sub(tech.first, 1, 1) .. string.sub(tech.last, 1, 1),
		sector = PuzzleConfig.Sublevels[random:NextInteger(1, #PuzzleConfig.Sublevels)],
		note = PuzzleConfig.MaintenanceNotes[random:NextInteger(1, #PuzzleConfig.MaintenanceNotes)],
		date = rollDate(random),
	}
end

--[[
	The order the boxes want, read back out of the values.

	A copy rather than the live table, because the caller holds this for a round
	and a service that could edit the sequence it is checking against is a
	service one bug away from moving the goalposts mid-round.
]]
function FuseSequence.order(values: Values): { number }
	return table.clone(values.sequence)
end

--[[
	What those values spell, in clue order — "3142".

	Not sent anywhere and not compared against anything; the service checks one
	box at a time against `order`. It exists because every template answers this
	question and because a single string is the thing you want in front of you
	when a round goes wrong. Same walk the vault's code does: position by
	position, out of the same table the documents are printed from.
]]
function FuseSequence.answer(values: Values): string
	local parts: { string } = {}
	for index = 1, #values.sequence do
		local box = values.sequence[index]
		if typeof(box) ~= "number" then
			--[[ A hole in the sequence is a config error, and a short answer would
			     hide it behind an unsolvable round. Empty, so the service's own
			     length check refuses to arm and says why. ]]
			return ""
		end
		table.insert(parts, tostring(box))
	end
	return table.concat(parts)
end

--[[
	What each document reads.

	Every one of them is legible from the moment the round starts — there is
	nothing redacted here, unlike the vault, and the `found` the service passes
	is deliberately ignored. The vault redacts because its clues are a CHAIN and
	the ordering is what stops a player reading the last digit off a wall without
	walking the building. These four are spread through a maze with no landmarks
	and no route you can learn; the walk is already the price, and charging it
	twice by making documents illegible until other documents are read would mean
	telling somebody to find the second one first in a place where they cannot
	navigate.

	Each clue is handed the key for its own position and no others. See the
	header: that is what makes the set incapable of contradicting itself.
]]
function FuseSequence.surfaces(
	definition: PuzzleConfig.PuzzleDefinition,
	values: Values,
	_found: number
): { [string]: string }
	local out: { [string]: string } = {}
	if not definition.clues then
		return out
	end

	for _, clue in definition.clues do
		local box = values.sequence[clue.order]
		local key = POSITION[clue.order]
		local filled = table.clone(values)
		if key and box then
			filled[key] = tostring(box)
		end
		--[[ The same number under a name that does not depend on the position,
		     so a designer writing a fifth document does not have to know which
		     slot it landed in. ]]
		filled.box = if box then tostring(box) else "?"

		--[[ Clamped rather than trusted. `variants` is empty when generate was
		     called without a definition, and an index past the end of the list
		     would print nothing at all — a blank prop reads as a broken puzzle
		     where the first phrasing reads as the puzzle. ]]
		local pick = values.variants and values.variants[clue.order] or 1
		local text = clue.texts[pick] or clue.texts[1]
		out[clue.object] = PuzzleConfig.fill(text, filled)
	end
	return out
end

--[[ The line the HUD shows when a document is read. Per clue, because "CLUE
     FOUND" four times says nothing about what was actually found — and unlike
     the vault's, this one does not append the value, because the value is a box
     number and the document already says it in a sentence that means
     something. ]]
function FuseSequence.prompt(clue: PuzzleConfig.ClueSlot, _values: Values): string
	return clue.found
end

return FuseSequence
