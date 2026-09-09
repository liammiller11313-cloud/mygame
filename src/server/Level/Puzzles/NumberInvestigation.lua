--!strict
--[[
	NumberInvestigation — four clues, one digit each, collected in order.

	The first puzzle template, and the shape every later one has to fit. A
	template owns exactly four questions:

	    generate(random, definition)  what values is this round's puzzle made of
	    answer(values)                what those values spell
	    surfaces(definition, values)  what each prop reads, given what is found
	    prompt(clue, values)          what the HUD says when one is picked up

	It owns nothing else. It does not know what a keypad is, it never sees a
	player, it cannot open a door and it has no opinion about rewards — which is
	what lets a symbol sequence or a breaker puzzle be a sibling file rather than
	a second copy of the service.

	── WHY IT LIVES ON THE SERVER ──────────────────────────────────────────────
	Under Server, not Shared, and that is the whole anti-exploit story for the
	code itself. The client is never sent the digits, and never sent the answer —
	it is sent the same printed text a player reads off a prop with their eyes,
	with every digit they have not yet earned still redacted. There is nothing on
	a client to decompile, because the string that spells the code has never been
	there.

	── THE ANSWER IS READ OUT OF THE CLUES, NEVER ROLLED ───────────────────────
	`answer` walks the clues in order and concatenates their digits. It cannot
	disagree with the props because it is the same table the props are printed
	from. There is no branch in this file where a code is chosen and clues are
	then built to match it — that is the design, not an implementation detail,
	and it is the one thing a future template must copy.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PuzzleConfig = require(Shared.Config.PuzzleConfig)

local NumberInvestigation = {}

export type Values = {
	--[[ Digit by clue ORDER — [1] is the clipboard's, [4] is the note's — so
	     `answer` is a walk rather than a lookup table of names. ]]
	digits: { number },
	--[[ Which PHRASING each clue prints this round, by the same order. Rolled
	     here rather than chosen in `surfaces`, because surfaces runs again on
	     every collection — picking there would reword the documents under a
	     player who was halfway through reading them. ]]
	variants: { number },
	[string]: any,
}

--[[ Written the way somebody would fill in a form in the week everything
     stopped. Flavour, and deliberately NOT a digit: a number in a field the
     player has been taught to skip is a number they will never find, and one
     they check is one that wasted their time. ]]
local function rollDate(random: Random): string
	return string.format("%d/%d", random:NextInteger(9, 11), random:NextInteger(1, 28))
end

--[[
	This round's puzzle.

	Every value comes from the supplied Random, so a caller that wants a
	reproducible round supplies its own — the same courtesy ModifierConfig.roll
	extends, and the reason neither of them reaches for math.random.
]]
function NumberInvestigation.generate(random: Random, definition: PuzzleConfig.PuzzleDefinition?): Values
	local digits: { number } = {}
	for index = 1, PuzzleConfig.Digits do
		digits[index] = random:NextInteger(PuzzleConfig.DigitMin, PuzzleConfig.DigitMax)
	end

	--[[ One phrasing per clue. The definition is optional so a caller that only
	     wants values — a test, a future tool — is not forced to hand one over;
	     without it every clue falls to its first phrasing, which is the same
	     behaviour this file had before phrasings existed. ]]
	local variants: { number } = {}
	if definition then
		for _, clue in definition.clues do
			local count = #clue.texts
			variants[clue.order] = if count > 1 then random:NextInteger(1, count) else 1
		end
	end

	--[[ One officer, named on TWO documents. The badge on the floor and the
	     signature on the report are the same person, which is the only
	     cross-reference in the set and the cheapest possible way to say "these
	     papers came from one building". ]]
	local officer = PuzzleConfig.Officers[random:NextInteger(1, #PuzzleConfig.Officers)]

	return {
		digits = digits,
		variants = variants,
		officerFirst = officer.first,
		officerLast = officer.last,
		officerInitial = string.sub(officer.first, 1, 1),
		--[[ The surname's initial, which the handwritten note signs with.

		     It used to sign "{officerInitial}H" — a literal H, left over from
		     writing the note against MARCUS HARPER. Five officers in six
		     therefore signed somebody else's surname: DENISE OKONKWO's note came
		     out "- DH". That broke the one cross-reference the puzzle has, which
		     is that the badge, the report and the note are all the same person. ]]
		officerLastInitial = string.sub(officer.last, 1, 1),
		area = PuzzleConfig.Areas[random:NextInteger(1, #PuzzleConfig.Areas)],
		note = PuzzleConfig.Notes[random:NextInteger(1, #PuzzleConfig.Notes)],
		date = rollDate(random),
	}
end

--[[
	What those digits spell, in clue order.

	The clipboard's digit first because the clipboard is clue one. That is the
	entire rule, and it is the rule the last note states out loud — so a player
	who collected them in the only order the game allows already knows it.
]]
function NumberInvestigation.answer(values: Values): string
	local parts: { string } = {}
	for index = 1, PuzzleConfig.Digits do
		local digit = values.digits[index]
		if typeof(digit) ~= "number" then
			--[[ A missing digit is a config error, and returning a short code
			     would hide it behind an unsolvable puzzle. Empty, so the service's
			     own length check refuses to arm at all and says why. ]]
			return ""
		end
		table.insert(parts, tostring(digit))
	end
	return table.concat(parts)
end

--[[
	What each prop reads, given how many clues the team has collected.

	`found` is the count, so a clue at or below it prints its digit and
	everything above it prints REDACTED. That is what makes the order mean
	something: the note on the wall is legible from the moment the round starts,
	and the one number on it is not there until the badge has been picked up.

	Recomputed for every prop on every collection rather than patched in place —
	four small strings, once every few minutes, and no way for a prop to be left
	holding a digit the team has not earned.
]]
function NumberInvestigation.surfaces(
	definition: PuzzleConfig.PuzzleDefinition,
	values: Values,
	found: number
): { [string]: string }
	local out: { [string]: string } = {}
	for _, clue in definition.clues do
		local revealed = clue.order <= found
		local digit = values.digits[clue.order]
		local filled = table.clone(values)
		filled.digit = if revealed and digit then tostring(digit) else PuzzleConfig.Redacted
		--[[ Clamped rather than trusted. `variants` is empty when generate was
		     called without a definition, and a phrasing index past the end of the
		     list would print nothing at all — a blank prop reads as a broken
		     puzzle, where the first phrasing reads as the puzzle. ]]
		local pick = values.variants and values.variants[clue.order] or 1
		local text = clue.texts[pick] or clue.texts[1]
		out[clue.object] = PuzzleConfig.fill(text, filled)
	end
	return out
end

--[[ The line the HUD shows when a clue is picked up. Per clue, because "CLUE
     FOUND" four times says nothing about what was actually found. ]]
function NumberInvestigation.prompt(clue: PuzzleConfig.ClueSlot, values: Values): string
	local digit = values.digits[clue.order]
	return string.format("%s \226\128\148 %s", clue.found, if digit then tostring(digit) else "?")
end

return NumberInvestigation
