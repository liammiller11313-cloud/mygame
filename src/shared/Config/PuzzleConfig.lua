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

export type ClueSlot = {
	--[[ The object's name inside the puzzle folder. Also matched forgivingly. ]]
	object: string,
	--[[ What the surface says. `{squad}`, `{room}`, `{officer}`, `{officerName}`,
	     `{officerInitial}`, `{area}`, `{date}`, `{first}`, `{second}`, `{third}`
	     and `{note}` are replaced from the rolled values; anything else is left
	     alone, so a template can contain literal braces. ]]
	text: string,
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
	The three credentials, in the order a template lists them.

	The ORDER is what makes this an investigation rather than three lookups: a
	player who finds all three numbers still has six ways to arrange them, and the
	procedure document is the fourth clue precisely because it is the one that
	turns information into an answer.

	Digit widths are 1, 2, 1 — so every permutation is four digits and the keypad
	never has to change shape. That is a constraint on the values, not a
	coincidence: see the template.
]]
PuzzleConfig.Credentials = table.freeze({
	table.freeze({ key = "squad", label = "SQUAD", digits = 1, min = 1, max = 9 }),
	table.freeze({ key = "room", label = "ROOM", digits = 2, min = 10, max = 99 }),
	table.freeze({ key = "officer", label = "OFFICER", digits = 1, min = 1, max = 9 }),
})

--[[ Every way the three can be ordered. Written out rather than permuted at
     runtime: six rows is smaller than the code that would generate them, and a
     designer who wants to drop a confusing one deletes a line. ]]
PuzzleConfig.Orders = table.freeze({
	table.freeze({ "squad", "room", "officer" }),
	table.freeze({ "squad", "officer", "room" }),
	table.freeze({ "room", "squad", "officer" }),
	table.freeze({ "room", "officer", "squad" }),
	table.freeze({ "officer", "squad", "room" }),
	table.freeze({ "officer", "room", "squad" }),
})

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
			table.freeze({
				object = "Clipboard",
				face = "Top",
				pixelsPerStud = 90,
				textSize = 22,
				prompt = "SECURITY REPORT",
				--[[ The squad number is one line in a form. Everything around it is
				     doing the real work: a form with one field filled in is a puzzle
				     prop, and a form with six is a document that happens to contain a
				     number. ]]
				text = "FRIED CHICKEN SECURITY REPORT\n\n"
					.. "DATE: {date}\n\n"
					.. "SQUAD ASSIGNMENT: {squad}\n\n"
					.. "AREA: {area}\n\n"
					.. "STATUS:\n{note}\n\n"
					.. "AUTHORIZED BY:\n{officerInitial}. {officerLast}",
			}),
			table.freeze({
				object = "Room Sign",
				face = "Front",
				pixelsPerStud = 70,
				textSize = 34,
				prompt = "ROOM SIGN",
				--[[ It has to read as a sign somebody screwed to a wall in 1998, not
				     as a clue. No mention of a code, no mention of a vault: a room
				     number is a room number, and the player is the one who decides it
				     is also a credential. ]]
				text = "ROOM {room}\n\nSUPPLY STORAGE\n\nAUTHORIZED\nPERSONNEL ONLY",
			}),
			table.freeze({
				object = "Badge",
				face = "Front",
				pixelsPerStud = 220,
				textSize = 16,
				prompt = "SECURITY BADGE",
				--[[ Named for the same officer who signed the report. That is the
				     one cross-reference in the whole puzzle and it is free: it costs a
				     field and it tells the player these documents are about a person. ]]
				text = "THE FRIED CHICKEN\nSECURITY DIVISION\n\n"
					.. "OFFICER:\n{officerFirst} {officerLast}\n\n"
					.. "ID:\n{officer}\n\n"
					.. "CLEARANCE:\nSUPPLY VAULT",
			}),
			table.freeze({
				object = "Procedure",
				face = "Top",
				pixelsPerStud = 90,
				textSize = 22,
				prompt = "VAULT PROCEDURE",
				--[[ The fourth clue, and the only one that is about the other three.
				     It never names a number — it names the ORDER, which is useless
				     until you have been to the other three objects and useless to
				     anyone who skipped it. ]]
				text = "EMERGENCY SUPPLY VAULT PROCEDURE\n\n"
					.. "If the main systems fail, the vault\nmust be opened manually.\n\n"
					.. "Enter the credentials in this order:\n\n"
					.. "1. {first}\n2. {second}\n3. {third}\n\n"
					.. "DO NOT REVERSE THE ORDER.\n\n"
					.. "\226\128\148 SECURITY",
			}),
		}),

		--[[ Priced against EconomyConfig rather than picked: a vault worth less
		     than the gun you would have bought with the same ten minutes is a vault
		     nobody opens twice. Split across the team, so four survivors each clear
		     a meaningful step and a solo player is not paid four times for the same
		     work. ]]
		reward = table.freeze({ dollars = 3_000, restockItems = true }),
	}),
}

PuzzleConfig.Puzzles = table.freeze(DEFINITIONS) :: { PuzzleDefinition }

--[[ The puzzle authored for a map, or nil. Nil is the normal answer for two of
     the three maps and must never be an error. ]]
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

--[[ A credential row by key, so a template can ask "how wide is `room`" without
     knowing the order of the list. ]]
function PuzzleConfig.credential(key: string): any?
	for _, entry in PuzzleConfig.Credentials do
		if entry.key == key then
			return entry
		end
	end
	return nil
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
