--!strict
--[[
	PuzzleConfig — the optional vault puzzle, and everything a designer can change
	about it without opening a service.

	── WHAT IT IS ──────────────────────────────────────────────────────────────
	One locked room, one keypad, and four documents left lying around a building
	by the survivors who used to live in it. The code is not written down
	anywhere. It is spread across a security report, a room sign, a dead man's ID
	badge and a laminated procedure, and the player has to notice that those four
	things are about each other.

	It is a SIDE objective. Nothing about a round depends on it, nothing about it
	touches the waves, and a team that never finds the keypad plays the round they
	would have played anyway. That is what lets it be a puzzle rather than a gate.

	── THE ONE RULE THAT MAKES IT FAIR ─────────────────────────────────────────
	The answer is never generated. The VALUES are generated, and the answer is
	read back out of them — see the template module. A code invented separately
	from the clues is a code the clues can disagree with, and a puzzle whose clues
	can be wrong is worse than no puzzle, because the player cannot tell the
	difference between "I misread it" and "the game lied".

	Everything downstream follows from that: the clue text is FILLED IN from the
	same table the answer is derived from, so there is exactly one source and no
	way for the two to drift.

	── AND WHY THE LOCATIONS DO NOT MOVE ───────────────────────────────────────
	The INFORMATION is randomised. The objects are not. A clipboard that could be
	anywhere is a clipboard a player cannot learn the map around, and an
	investigation you solve by sweeping every surface is a search, not an
	investigation. Same four objects every round, different story on them.

	── TEMPLATES ───────────────────────────────────────────────────────────────
	`template` names a module under Server/Level/Puzzles. A template owns three
	things and nothing else: what values to roll, what answer those values make,
	and what text each clue object should read. Adding a symbol sequence or a
	breaker-switch puzzle later is a new file and one row in `Puzzles` — the
	service, the keypad, the anti-exploit and the reward do not change, because
	none of them know what a squad number is.
]]

local Enums = require(script.Parent.Parent.Enums)

local PuzzleConfig = {}

--[[ The whole feature, off in one place. A map without the objects in it simply
     warns and carries on, so this exists for turning the puzzle off on a map
     that HAS them — a test, or a mode where a side objective is a distraction. ]]
PuzzleConfig.Enabled = true

--[[ The folder a designer puts the puzzle objects in, inside the map. Matched
     through MapConfig.folderMatches, so "Puzzle", "puzzles" and "Puzzle " all
     find it — the same forgiveness the medkit and ammo crate folders get, and
     for the same reason: a hand-typed folder name is the most likely thing to be
     slightly wrong. ]]
--[[
	Where to look for the props.

	The clue documents are expected in a folder called "Puzzle", but every name
	below is ALSO searched for across the whole map as a fallback — because the
	door assembly this puzzle was built around is a free-model called "KFC Code
	Door" sitting directly under Clinton, not inside anybody's folder, and asking
	a designer to dismantle a working model to satisfy a folder rule is asking
	for a broken model.

	Folder first, whole map second. That way a tidy map stays tidy and an untidy
	one still works.
]]
PuzzleConfig.FolderName = "Puzzle"

--[[ What the service tags the props with once it has found them, and what the
     client tests to decide whether to draw a prompt. Shared because both halves
     have to agree on the string; the TAGGING is the server's and a client that
     added the tag locally would get a prompt on a rock and a refusal from a
     server that never saw it. ]]
PuzzleConfig.KeypadTag = "FL_PuzzleKeypad"
PuzzleConfig.ClueTag = "FL_PuzzleClue"
--[[ The cash pile in the vault. Its own tag rather than a clue's, because it is
     interacted with once and pays the whole team — nothing about it is a
     document. ]]
PuzzleConfig.StockpileTag = "FL_PuzzleStockpile"

export type ClueSlot = {
	--[[ Where this clue sits in the chain, 1 through 4. Collecting them out of
	     order is refused — see PuzzleService — and this is the number the refusal
	     names back at the player. ]]
	order: number,
	--[[ The object's name inside the puzzle folder. Also matched forgivingly. ]]
	object: string,
	--[[ The line the HUD shows when this one is picked up. Written per clue
	     because "CLUE FOUND" four times says nothing about what was found. ]]
	found: string,
	--[[
		What the surface says — one entry per PHRASING, and the round picks one.

		Was a single string, which meant every round printed the same sentences
		with different numbers in them. That is fine for a code (the digits are
		the puzzle) and it stops being fine the moment a clue carries an argument
		rather than a value: a player who has read "SQUAD ASSIGNMENT" once knows
		which field to look at without reading the document, and the investigation
		becomes a lookup.

		The document TYPE stays fixed per slot — the clipboard is always a
		security report — so `found` and `prompt` keep describing what was
		actually picked up. Only the wording inside it moves.

		`{digit}`, `{officerFirst}`, `{officerLast}`, `{officerInitial}`,
		`{officerLastInitial}`, `{area}`, `{date}` and `{note}` are replaced from
		the rolled values; anything else is left alone, so a template can contain
		literal braces.
	]]
	texts: { string },
	--[[ Which face of the part the text is drawn on. A clipboard lying on a desk
	     wants Top; a sign on a wall wants Front. Named here rather than guessed
	     from the part's shape, because a guess is wrong exactly often enough to
	     be worse than a setting. ]]
	face: string,
	--[[ Reference pixels of SurfaceGui canvas per stud, and the text size in
	     those pixels. A badge is small and read from close up; a room sign is
	     large and read from across a room, so they cannot share one number. ]]
	pixelsPerStud: number,
	textSize: number,
	--[[ What the prompt says when a player is looking at it. It is a noun, not an
	     instruction: the player is picking a thing up to read it. ]]
	prompt: string,
}

export type PuzzleDefinition = {
	id: string,
	--[[ The map this puzzle belongs to, by MapConfig id. A puzzle is authored
	     against one building's geometry and means nothing in another. ]]
	map: string,
	template: string,
	digits: number,

	--[[ Seconds a player must wait between two attempts. Not a punishment — it is
	     the difference between a keypad and a brute-force oracle. See
	     LockoutAfter for the part that actually stops one. ]]
	attemptCooldown: number,
	--[[ Wrong answers in a row before the pad locks that player out, and for how
	     long. Ten thousand codes at one a second is under three hours; a team
	     that guesses instead of reading should not beat the puzzle inside a
	     round, and a team that reads never sees this. ]]
	lockoutAfter: number,
	lockoutSeconds: number,

	--[[ The objects, by role. The keypad and the door are the two the service
	     needs by name; the rest are clue surfaces the template fills in. ]]
	keypad: string,
	door: string,
	clues: { ClueSlot },

	--[[ The physical contents of the vault, armed when the door opens. Optional:
	     a puzzle with no loot table still pays through `reward`. ]]
	loot: {
		weapon: { object: string, itemId: string, slot: string }?,
		stockpile: { object: string, dollars: number, prompt: string }?,
	}?,

	reward: {
		--[[ Round dollars, split evenly across everyone still in the round —
		     EconomyService's own currency, not a new one. Solving it should be
		     worth a weapon the team could not otherwise afford yet. ]]
		dollars: number,
		--[[ Whether opening the vault also restocks the map's item spawns, which
		     is what makes it a SUPPLY room rather than a cash prize. Uses
		     LevelService's existing restock — the same call a breather makes. ]]
		restockItems: boolean,
	},
}

--[[
	The people whose names are on the paperwork.

	Both the badge and the security report name the SAME officer each round, and
	that is the detail that makes the two objects feel like they came from one
	building rather than from a puzzle generator. A player who notices that M.
	Harper signed the report and that the badge on the floor says MARCUS HARPER
	has learned something true about the place, and has also just been told the
	two clues belong together.
]]
PuzzleConfig.Officers = table.freeze({
	table.freeze({ first = "MARCUS", last = "HARPER" }),
	table.freeze({ first = "DENISE", last = "OKONKWO" }),
	table.freeze({ first = "RAY", last = "VASQUEZ" }),
	table.freeze({ first = "TOMMY", last = "BRENNAN" }),
	table.freeze({ first = "ALICE", last = "SOKOLOV" }),
	table.freeze({ first = "WENDELL", last = "PRICE" }),
})

--[[ Where the squad was working. Flavour only — no digit ever hides in here,
     because a number in a field the player has been taught to ignore is a number
     they will never find. ]]
PuzzleConfig.Areas = table.freeze({
	"EAST WING",
	"FRONT COUNTER",
	"DRIVE-THRU",
	"WALK-IN COOLER",
	"ROOF ACCESS",
	"BACK LOT",
})

--[[
	One line of story per round, on the report.

	Short on purpose. The lore's job here is to make four documents feel like the
	residue of people rather than the furniture of a puzzle, and a paragraph on a
	clipboard is a paragraph nobody reads while a horde is coming. Each of these
	answers one small question — who was here, why the room is shut, what went
	wrong — and none of them answers all of it.
]]
PuzzleConfig.Notes = table.freeze({
	"SUPPLY ROUTE SECURED. FRONT DOORS STAY SHUT AFTER DARK.",
	"MOVED EVERYTHING BEHIND THE MANAGER'S OFFICE AFTER THE FIRST BREACH.",
	"HEAD COUNT DOWN TO NINE. RATIONING FROM MONDAY.",
	"THE FREEZER HOLDS. THE FREEZER IS THE ONLY THING THAT HOLDS.",
	"IF YOU ARE READING THIS AND WE ARE NOT HERE, TAKE WHAT YOU NEED.",
	"NOBODY GOES OUT ALONE. NOT FOR ANYTHING.",
})

--[[
	The four clues, in the order they must be collected.

	One digit each, and the code is those four digits in THIS order — which is
	why there is no separate document telling you the arrangement any more. The
	order is the hunt: you cannot take the note off the wall until you have the
	badge, and you cannot take the badge until you have the sign.

	── AND THE DIGIT IS HIDDEN UNTIL IT IS FOUND ───────────────────────────────
	Every prop is printed with its document from the moment the round starts, but
	the one field that matters reads REDACTED until that clue is collected. That
	is what makes the ordering mean anything: with all four digits legible from
	across the room, the counter and the sequence would be decoration and a
	player could read the code off the walls without ever touching a clue.

	It also happens to be the most honest possible reason for a number to be
	missing from a security file.
]]
--[[ U+2588 FULL BLOCK, written as its UTF-8 bytes the way every other
     non-ASCII character in this codebase is. Four of them: enough to read as a
     struck-out field rather than as a typo, and short enough that "ROOM ████"
     still fits a sign built for "ROOM 7". ]]
local BLOCK = "\226\150\136"
PuzzleConfig.Redacted = string.rep(BLOCK, 4)

--[[ 0 through 9, one per clue. Ten thousand codes, and every digit is somewhere
     a player has to walk to. ]]
PuzzleConfig.DigitMin = 0
PuzzleConfig.DigitMax = 9

--[[ How many clues there are, which is also how many digits the code has. One
     number rather than two, because a keypad that takes five digits from four
     clues is a keypad nobody can satisfy. ]]
PuzzleConfig.Digits = 4

local DEFINITIONS: { PuzzleDefinition } = {
	table.freeze({
		id = "FriedChickenVault",
		map = "Clinton",
		template = "NumberInvestigation",
		digits = 4,

		attemptCooldown = 1.25,
		lockoutAfter = 6,
		lockoutSeconds = 25,

		--[[ The existing free-model door assembly, by the names it already has:
		     `KFC Code Door` holds the keypad face and a part called `Door`. Its
		     own Script and its twelve ClickDetectors are destroyed by
		     MapService.sanitise on load — the game strips both out of every map —
		     so the buttons are scenery and the code is entered on the panel this
		     feature draws. Nothing about the model has to change. ]]
		keypad = "KFC Code Door",
		door = "Door",

		clues = table.freeze({
			--[[ FIRST. A form with one field filled in is a puzzle prop; a form
			     with six is a document that happens to contain a number. ]]
			table.freeze({
				order = 1,
				object = "Clipboard",
				face = "Top",
				pixelsPerStud = 90,
				textSize = 22,
				prompt = "SECURITY REPORT",
				found = "SQUAD ASSIGNMENT LOGGED",
				texts = table.freeze({
					"FRIED CHICKEN SECURITY REPORT\n\n"
						.. "DATE: {date}\n\n"
						.. "SQUAD ASSIGNMENT: {digit}\n\n"
						.. "AREA: {area}\n\n"
						.. "STATUS:\n{note}\n\n"
						.. "AUTHORIZED BY:\n{officerInitial}. {officerLast}",
					"SHIFT HANDOVER \226\128\148 {date}\n\n"
						.. "POST: {area}\n\n"
						.. "SQUAD ON DUTY: {digit}\n\n"
						.. "PASSED TO NEXT SHIFT:\n{note}\n\n"
						.. "SIGNED: {officerInitial}. {officerLast}",
					"NIGHT PATROL SHEET\n\n"
						.. "{date} \226\128\148 {area}\n\n"
						.. "SQUAD {digit} WALKED IT.\n\n"
						.. "NOTES:\n{note}\n\n"
						.. "SUPERVISOR: {officerInitial}. {officerLast}",
				}),
			}),
			--[[ SECOND. A sign somebody screwed to a wall, which says nothing
			     about a code — a room number is a room number, and the player is
			     the one who decides it is also a digit. ]]
			table.freeze({
				order = 2,
				object = "House Number",
				face = "Front",
				pixelsPerStud = 70,
				textSize = 34,
				prompt = "ROOM SIGN",
				found = "ROOM NUMBER NOTED",
				texts = table.freeze({
					"ROOM {digit}\n\nSUPPLY STORAGE\n\nAUTHORIZED\nPERSONNEL ONLY",
					"STOREROOM {digit}\n\nDRY GOODS\n\nKEEP\nDOOR SHUT",
					"{digit}\n\nBACK STORE\n\nSTAFF ONLY\nBEYOND THIS POINT",
				}),
			}),
			--[[ THIRD. Named for the same officer who signed the report — the one
			     cross-reference in the set, and the cheapest possible way to say
			     these papers came from one building and one person. ]]
			table.freeze({
				order = 3,
				object = "ID Card",
				face = "Front",
				pixelsPerStud = 220,
				textSize = 16,
				prompt = "SECURITY BADGE",
				found = "OFFICER ID RECOVERED",
				texts = table.freeze({
					"THE FRIED CHICKEN\nSECURITY DIVISION\n\n"
						.. "OFFICER:\n{officerFirst} {officerLast}\n\n"
						.. "ID:\n{digit}\n\n"
						.. "CLEARANCE:\nSUPPLY VAULT",
					"STAFF PASS\n\n"
						.. "{officerFirst} {officerLast}\n"
						.. "SECURITY\n\n"
						.. "BADGE NO. {digit}\n\n"
						.. "VAULT ACCESS: YES",
					"THE FRIED CHICKEN\n\n"
						.. "NAME: {officerLast}, {officerFirst}\n"
						.. "DEPT: SECURITY\n"
						.. "NO: {digit}\n\n"
						.. "IF FOUND, RETURN TO\nTHE FRONT COUNTER",
				}),
			}),
			--[[ LAST, and the only one written by hand. It states the order the
			     player has just walked, which turns four digits they are carrying
			     into a code they can enter. ]]
			table.freeze({
				order = 4,
				object = "Note",
				face = "Front",
				pixelsPerStud = 110,
				textSize = 20,
				prompt = "HANDWRITTEN NOTE",
				found = "THE LAST DIGIT",
				--[[ Every one of these has to state the ORDER as well as carry the
				     last digit. It is the only document that tells a player how to
				     arrange what they are holding, and a phrasing that forgot to
				     would make the round unsolvable rather than merely differently
				     worded. ]]
				texts = table.freeze({
					"if you got this far you have\nthe other three.\n\n"
						.. "squad, room, id, then {digit}.\n\n"
						.. "same order you found them.\n\n"
						.. "dont let anyone else in.\n\n"
						.. "- {officerInitial}{officerLastInitial}",
					"whoever finds this \226\128\148\n\n"
						.. "the pad wants four.\n"
						.. "squad first, then the room,\n"
						.. "then my badge, then {digit}.\n\n"
						.. "walk it in that order.\n\n"
						.. "- {officerInitial}{officerLastInitial}",
					"cant carry it all out.\n\n"
						.. "code is squad, room, id,\nand {digit} on the end.\n\n"
						.. "in the order you picked\nthem up. dont get clever.\n\n"
						.. "- {officerInitial}{officerLastInitial}",
				}),
			}),
		}),

		--[[ Priced against EconomyConfig rather than picked: a vault worth less
		     than the gun you would have bought with the same ten minutes is a vault
		     nobody opens twice. Split across the team, so four survivors each clear
		     a meaningful step and a solo player is not paid four times for the same
		     work. ]]
		reward = table.freeze({ dollars = 3_000, restockItems = true }),

		--[[
			What is actually IN the room, as opposed to what opening it pays.

			Both are armed only when the door opens — the flamethrower's pickup
			attribute is not written and the stockpile is not tagged until then.
			A reward reachable by clipping through a wall is a reward nobody needs
			the puzzle for, and "the door is shut" is a promise about geometry
			rather than a rule.
		]]
		loot = table.freeze({
			--[[ Lying on the floor. Picked up through the ordinary FL_Slot path,
			     so it lands in the primary slot exactly like any other weapon and
			     the one already there drops where you stood. ]]
			weapon = table.freeze({
				object = "Flamethrower",
				itemId = "Flamethrower",
				slot = "Primary",
			}),
			--[[ One interaction, everybody paid, once. See PuzzleService: it is
			     the team's find, not the finder's. ]]
			stockpile = table.freeze({
				object = "Dollar Stockpile",
				dollars = 350,
				prompt = "DOLLAR STOCKPILE",
			}),
		}),
	}),
}

PuzzleConfig.Puzzles = table.freeze(DEFINITIONS) :: { PuzzleDefinition }

--[[ The puzzle authored for a map, or nil. Nil is the NORMAL answer — a puzzle
     is a per-map thing somebody sits down and writes, so most of the roster has
     none and only Clinton has one today. It must never be an error. ]]
function PuzzleConfig.forMap(mapId: string?): PuzzleDefinition?
	if typeof(mapId) ~= "string" then
		return nil
	end
	for _, definition in PuzzleConfig.Puzzles do
		if definition.map == mapId then
			return definition
		end
	end
	return nil
end

--[[ The clue that sits at a given position in the chain, or nil. Used by the
     server to name the one a player skipped, and by the HUD to say what is
     still missing. ]]
function PuzzleConfig.clueAt(definition: PuzzleDefinition, order: number): ClueSlot?
	for _, clue in definition.clues do
		if clue.order == order then
			return clue
		end
	end
	return nil
end

--[[ "first", "second", "third", "fourth" — for the refusal a player reads when
     they try to take the note before the clipboard. A number would be correct
     and would read like an error code. ]]
local ORDINALS = table.freeze({ "FIRST", "SECOND", "THIRD", "FOURTH" })

function PuzzleConfig.ordinal(order: number): string
	return ORDINALS[order] or tostring(order)
end

--[[
	Fills a clue's text in from a table of values.

	Deliberately dumb: it replaces `{key}` with `tostring(values[key])` and leaves
	anything it does not recognise exactly as written. A template that adds a
	field gets it substituted without touching this, and a typo in a config string
	shows up on the prop as `{squd}` rather than as a crash in front of the
	player — which is the failure mode you want, because one of those is
	debuggable from a screenshot.
]]
function PuzzleConfig.fill(template: string, values: { [string]: any }): string
	local out = string.gsub(template, "{(%w+)}", function(key: string): string?
		local value = values[key]
		return if value ~= nil then tostring(value) else nil
	end)
	return out
end

--[[ Kept so the round state this reads is named once. The puzzle is generated
     with the round and cleared with it; see PuzzleService. ]]
PuzzleConfig.RunningState = Enums.RoundState.InProgress

return table.freeze(PuzzleConfig)
