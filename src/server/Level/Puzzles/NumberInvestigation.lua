--!strict
--[[
	NumberInvestigation — three credentials, one order, four digits.

	The first puzzle template, and the shape every later one has to fit. A
	template owns exactly three questions:

	    generate(random)     what values is this round's puzzle made of
	    answer(values)       what those values spell, in order
	    surfaces(values)     what each clue object should read

	It owns nothing else. It does not know what a keypad is, it never sees a
	player, it cannot open a door and it has no opinion about rewards — which is
	what lets a symbol sequence or a breaker puzzle be a sibling file rather than
	a second copy of the service.

	── WHY IT LIVES ON THE SERVER ──────────────────────────────────────────────
	Under Server, not Shared, and that is the whole anti-exploit story for the
	code itself. The client is never sent the values, never sent the order and
	never sent the answer — it is sent the same painted text a player reads off a
	prop with their eyes. There is nothing on a client to decompile, because the
	arithmetic that turns a squad number into a code has never been there.

	── THE ANSWER IS READ OUT OF THE CLUES, NEVER ROLLED ───────────────────────
	`answer` takes the values and concatenates them. It cannot disagree with the
	clues because it is the same table the clues are filled from. There is no
	branch in this file where a code is chosen and clues are then built to match
	it — that is the design, not an implementation detail, and it is the one thing
	a future template must copy.

	── AND WHY 1, 2, 1 ─────────────────────────────────────────────────────────
	A squad is one digit, a room is two, an ID is one. That is not decoration: it
	means all six orderings are four digits long, so the ORDER can be randomised
	without the keypad ever changing shape or the player ever being able to
	deduce the arrangement from the length of what they are holding. Two two-digit
	credentials would leak the answer to anyone who counted.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PuzzleConfig = require(Shared.Config.PuzzleConfig)

local NumberInvestigation = {}

export type Values = {
	--[[ The rolled credentials, keyed exactly as PuzzleConfig.Credentials names
	     them, so `answer` can walk the order without a translation table. ]]
	[string]: any,
}

--[[ Months are written as they would be on a form somebody filled in by hand in
     the week everything stopped. It is flavour and it is deliberately NOT a
     credential: a number in a field the player has been taught to skip is a
     number they will never find, and one they check is one that wastes their
     time. ]]
local function rollDate(random: Random): string
	return string.format("%d/%d", random:NextInteger(9, 11), random:NextInteger(1, 28))
end

--[[
	This round's puzzle.

	Every value comes from the supplied Random, so a caller that wants a
	reproducible round supplies its own — the same courtesy ModifierConfig.roll
	extends, and the reason neither of them reaches for math.random.
]]
function NumberInvestigation.generate(random: Random): Values
	local values: Values = {}

	for _, credential in PuzzleConfig.Credentials do
		values[credential.key] = random:NextInteger(credential.min, credential.max)
	end

	--[[ One officer, named on TWO documents. The badge on the floor and the
	     signature on the report are the same person, which is the only
	     cross-reference in the puzzle and the cheapest possible way to say "these
	     papers came from one building". ]]
	local officer = PuzzleConfig.Officers[random:NextInteger(1, #PuzzleConfig.Officers)]
	values.officerFirst = officer.first
	values.officerLast = officer.last
	values.officerInitial = string.sub(officer.first, 1, 1)

	values.area = PuzzleConfig.Areas[random:NextInteger(1, #PuzzleConfig.Areas)]
	values.note = PuzzleConfig.Notes[random:NextInteger(1, #PuzzleConfig.Notes)]
	values.date = rollDate(random)

	--[[ The order, which is the fourth clue and the reason the other three are
	     not enough. Stored on the values so `answer` and the procedure document
	     are reading one decision rather than two. ]]
	local order = PuzzleConfig.Orders[random:NextInteger(1, #PuzzleConfig.Orders)]
	values.order = order

	--[[ Spelled out for the procedure text here rather than in the config,
	     because the config should be able to say `{first}` without knowing that
	     first means "the first key of the order tuple". ]]
	for index, key in order do
		local credential = PuzzleConfig.credential(key)
		local slot = if index == 1 then "first" elseif index == 2 then "second" else "third"
		values[slot] = if credential then credential.label else string.upper(key)
	end

	return values
end

--[[
	What those values spell.

	Zero-padded to each credential's own width, so a room of 07 stays two digits
	and the code stays four. Without the pad, `room = 7` would silently produce a
	three-digit answer that the keypad could never accept and no clue would
	explain — which is exactly the class of bug that makes a player think the
	puzzle is broken rather than that they are wrong.
]]
function NumberInvestigation.answer(values: Values): string
	local parts: { string } = {}
	for _, key in values.order do
		local credential = PuzzleConfig.credential(key)
		if not credential then
			--[[ A key in the order with no credential behind it is a config error,
			     and returning a short code would hide it behind an unsolvable
			     puzzle. Empty, so the service's own length check refuses to arm the
			     puzzle at all and says why. ]]
			return ""
		end
		table.insert(parts, string.format("%0" .. tostring(credential.digits) .. "d", values[key]))
	end
	return table.concat(parts)
end

--[[
	What each clue object should read, keyed by the object's configured name.

	The template does not draw anything and does not know a SurfaceGui exists. It
	returns strings; PuzzleService puts them on parts. That split is what lets a
	later template answer with switch positions or a symbol sequence instead of
	prose without the drawing code caring.
]]
function NumberInvestigation.surfaces(
	definition: PuzzleConfig.PuzzleDefinition,
	values: Values
): { [string]: string }
	local out: { [string]: string } = {}
	for _, clue in definition.clues do
		out[clue.object] = PuzzleConfig.fill(clue.text, values)
	end
	return out
end

return NumberInvestigation
