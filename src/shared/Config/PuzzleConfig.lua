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
--[[ The generators, on the map that has them. Its own tag rather than a clue's,
     because the two are answered by completely different screens and a prompt
     that offered to READ a generator would be a prompt that opens the wrong
     one. ]]
PuzzleConfig.GeneratorTag = "FL_PuzzleGenerator"
--[[ The cash pile in the vault. Its own tag rather than a clue's, because it is
     interacted with once and pays the whole team — nothing about it is a
     document. ]]
PuzzleConfig.StockpileTag = "FL_PuzzleStockpile"
--[[ The breaker boxes in the Backrooms. Its own tag rather than a generator's,
     because the two answer completely differently: a generator hands back a
     mini-game to draw, and a fuse box is thrown or it is not. A prompt that
     opened a wire panel on a fuse box would be a prompt promising a puzzle that
     does not exist. ]]
PuzzleConfig.FuseTag = "FL_PuzzleFuse"
--[[ A door that moves the player rather than opening. See DoorwaySpec: the
     Backrooms loot room is somewhere else in the world, and the two doors that
     get you in and out of it are the only things in this game that teleport
     inside a map. ]]
PuzzleConfig.DoorwayTag = "FL_PuzzleDoorway"

--[[
	The two shapes a side objective comes in.

	`Investigation` is Clinton's: four documents, one keypad, a code you read out
	of the paperwork. `Generators` is Zombieville's: five machines, walked in
	numerical order, each opening one of five mini-puzzles dealt fresh every
	round.

	── WHY ONE SERVICE RUNS BOTH ───────────────────────────────────────────────
	They are different puzzles and they are the SAME feature: a side objective
	armed when the round starts and cleared when it ends, whose props are found
	by name in the map, which seals a room, and which pays a team in Dollars and
	a weapon that does not survive the round. Every one of those is already
	written once in PuzzleService, and a second service would be a second copy of
	all of it — including the parts that took several goes to get right, like
	putting back a loot weapon a previous round consumed on a map that was never
	reloaded.

	So the KIND decides which half of `arm` runs and nothing else. Finding props,
	settling them, arming the loot, opening the door, paying out and clearing are
	one implementation with two front ends.
]]
PuzzleConfig.Kind = table.freeze({
	Investigation = "Investigation",
	Generators = "Generators",
	--[[
		The Backrooms': four breaker boxes thrown in an order the round invents,
		and four objects in the maze that between them say what that order is.

		The third kind is what the template registry was written for, and it cost
		what the header above promised it would — a template file and a row in
		`Puzzles`. What it did NOT cost is worth naming, because it is the whole
		argument for having done it that way: the round lifecycle, the prop
		finder, the reach check, the rate limit, the gate, the loot, the payout
		and the counter on everybody's screen are the same code the other two
		kinds run.

		── AND IT IS THE FIRST ONE WHOSE ORDER IS A SECRET ─────────────────────
		Zombieville's generators are walked 1, 2, 3, 4, 5. The number is painted
		on the machine and the objective is the WALK. Here the boxes are numbered
		too, and the order they want is rolled fresh every round, so the objective
		is the READING: four documents in a maze that has no landmarks, and a
		sequence that cannot be learned because it did not exist ten minutes ago.

		Which means every refusal in this kind has to be careful in a way the
		generators' never had to be. See wrongFuse.
	]]
	Fuses = "Fuses",
})

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

	--[[
		What the words are written IN, and what colour they are.

		Both optional, and both absent on Clinton — where all four clues are
		paperwork and near-black on off-white is right for every one of them.

		The Backrooms is where they had to exist. Its four clues are a note, a
		dead television, a hazmat log and something scrawled on a wall, and
		printing all four in the same dark typewriter face would say those are
		four printouts of one document. A CRT glows and a wall does not; that
		difference is most of what tells a player which KIND of thing they just
		found, before they have read a word of it.

		`font` is an Enum.Font name and falls back to the typewriter face if this
		build does not have it, the same forgiveness `face` gets — a font that
		does not exist should print the clue in the wrong face, not stop a round
		from starting.
	]]
	font: string?,
	ink: Color3?,
}

--[[
	The five machines, and where the arrow points once they are all running.

	The generators do NOT move between rounds and are NOT shuffled — the player
	was explicit about that, and it is the right call for the same reason the
	vault's clipboard never moves: a route you can learn is what turns a map into
	a place. What is shuffled is which mini-puzzle waits at each one, which is
	the half a team cannot memorise.

	The models are `Generator 1` through `Generator 5` under the puzzle folder —
	the same numbered pattern every map item family uses, so a designer adding a
	sixth names it `Generator 6` and raises `count`.
]]
export type GeneratorSet = {
	--[[ The base name, without the number. Matched forgivingly like everything
	     else in the map, so "Generator 3", "generator 3" and "Generator  3" all
	     resolve. ]]
	object: string,
	count: number,
	--[[ What the interact prompt calls one. The number is appended by the
	     service, because a prompt reading GENERATOR on all five is a prompt that
	     cannot tell a player which one they are standing at — which is the whole
	     objective. ]]
	prompt: string,
}

--[[
	The room the generators open, and the thing in the doorway.

	`room` is looked up across the whole map and `door` only INSIDE it — the same
	split the vault makes, and for the same reason: a map has many things that
	could answer to "Gate" and exactly one of them is inside the loot room.

	`vanish` is the difference between a vault door and a security gate. The
	vault fades to a ghost, because a doorway with nothing in it reads as a hole
	in the building and the frame is worth keeping legible. A gate is a grille
	that rolls up and is gone, so this one goes all the way.
]]
export type GateSpec = {
	room: string,
	door: string,
	vanish: boolean,
	--[[ What the arrow says it is pointing at, once every generator is live. ]]
	label: string,
}

--[[
	The breaker boxes, and how they are drawn.

	Numbered `Fuse Box 1` through `Fuse Box 4` in the map, exactly like the
	generators are — the same numbered pattern every prop family in this game
	uses, so a designer adding a fifth names it `Fuse Box 5` and raises `count`.

	The number is PAINTED ON by the service rather than trusted to the model.
	Four identical grey boxes on four identical yellow walls is the Backrooms
	working as intended and a puzzle that cannot be played: a clue reading
	"THROW BOX 3" is worth nothing to somebody who cannot tell which box they
	are standing at. So the face, the resolution and the size are here, beside
	the clue slots that need the same three settings and for the same reason.
]]
export type FuseSet = {
	object: string,
	count: number,
	prompt: string,
	face: string,
	pixelsPerStud: number,
	textSize: number,
	--[[ A part inside the box whose colour says whether it is live — matched
	     forgivingly, so "Light", "light" and "Indicator" all answer. Optional: a
	     box without one still turns its printed number green, which is the
	     visible change the design actually requires. ]]
	indicator: string?,
}

--[[
	A door that puts you somewhere else.

	The Backrooms loot room is not on the other side of its door — it is a
	separate room somewhere else in the model, and `Exit Door 1` moves the player
	to the part `Lootroom Teleport` inside it. `Exit Door 2` moves them back to
	`Lootroom Exit`, out in the maze.

	── WHY `sealed` IS A FIELD AND NOT A CONSTANT ──────────────────────────────
	The way IN is armed when the puzzle is solved, because it IS the reward and
	a doorway that worked before the boards came off would make the fuses
	decorative. The way OUT is armed the moment the round starts, and that is not
	symmetry — it is the rule that a player can never be shut inside a room. If
	the exit door only existed after the objective completed, any way into that
	room the designer did not intend (a Charger, a physics fluke, a future
	change) would be a player stuck in a box until they died.
]]
export type DoorwaySpec = {
	door: string,
	--[[ The part to land on, by name, looked for inside the same room the door
	     is. A Part rather than a CFrame in the config, because the designer moves
	     the room and nobody should have to remember to move a number. ]]
	target: string,
	prompt: string,
	sealed: boolean,
}

export type PuzzleDefinition = {
	id: string,
	--[[ The map this puzzle belongs to, by MapConfig id. A puzzle is authored
	     against one building's geometry and means nothing in another. ]]
	map: string,
	--[[ Which of the two shapes this is. Absent means Investigation, so Clinton's
	     definition did not have to change to gain a field it is the default
	     of. ]]
	kind: string?,

	--[[
		── INVESTIGATION ONLY ──────────────────────────────────────────────────
		Optional because the generator kind has none of them: there is no code, no
		keypad and no document. One type covering both shapes rather than two
		types and a union, because every field OUTSIDE these two blocks is shared
		and a union would duplicate the shared half to avoid duplicating the
		unshared one.

		`arm` checks that the fields its kind needs are actually present and turns
		the puzzle off with a named warning when they are not, which is the check
		a union would have bought at the cost of every reader carrying a cast.
	]]
	template: string?,
	digits: number?,
	--[[ Seconds a player must wait between two attempts. Not a punishment — it is
	     the difference between a keypad and a brute-force oracle. See
	     LockoutAfter for the part that actually stops one. ]]
	attemptCooldown: number?,
	--[[ Wrong answers in a row before the pad locks that player out, and for how
	     long. Ten thousand codes at one a second is under three hours; a team
	     that guesses instead of reading should not beat the puzzle inside a
	     round, and a team that reads never sees this. ]]
	lockoutAfter: number?,
	lockoutSeconds: number?,
	--[[ The objects, by role. The keypad and the door are the two the service
	     needs by name; the rest are clue surfaces the template fills in. ]]
	keypad: string?,
	door: string?,
	clues: { ClueSlot }?,

	--[[ ── GENERATORS ONLY ──────────────────────────────────────────────────── ]]
	generators: GeneratorSet?,

	--[[ ── FUSES ONLY ───────────────────────────────────────────────────────── ]]
	fuses: FuseSet?,
	--[[ Optional even on the kind that has them: a map whose loot room is
	     BEHIND its door rather than somewhere else needs none, and the gate
	     opening is the whole mechanism. ]]
	doorways: { DoorwaySpec }?,

	--[[ Shared by the two kinds that seal a room with something in the doorway
	     rather than with a keypad. ]]
	gate: GateSpec?,

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
	── THE BACKROOMS ───────────────────────────────────────────────────────────
	The people who were down here before the lights went, and where they were
	working. Same job as Clinton's Officers and Areas: the maintenance note and
	the hazmat log name the SAME technician every round, so a player who notices
	that the scrawl on the wall and the log on the floor are the same person's
	has learned something true about the place rather than spotting a pattern in
	a puzzle generator.
]]
PuzzleConfig.Technicians = table.freeze({
	table.freeze({ first = "DALE", last = "MERRICK" }),
	table.freeze({ first = "PRIYA", last = "NANDA" }),
	table.freeze({ first = "OSCAR", last = "REYNA" }),
	table.freeze({ first = "JUNE", last = "HOLLIS" }),
	table.freeze({ first = "STEVIE", last = "ABARA" }),
	table.freeze({ first = "MARTIN", last = "KRUSE" }),
})

--[[ Where the paperwork says it was filed. Flavour only — no box number ever
     hides in here, because a number in a field the player has been taught to
     skip is a number they will never find. ]]
PuzzleConfig.Sublevels = table.freeze({
	"SUBLEVEL 2",
	"SUBLEVEL 7",
	"WING C",
	"THE LONG HALL",
	"SECTOR 12",
	"STAIRWELL 4",
})

--[[
	One line of somebody having been here, on the paperwork.

	Short for the same reason Clinton's are: a paragraph on a wall is a paragraph
	nobody reads with a horde coming, and the lore's job is to make four objects
	feel like the residue of people rather than the furniture of a puzzle. These
	answer smaller questions than Clinton's do — nobody down here knows what
	happened, and that is the map's whole idea.
]]
PuzzleConfig.MaintenanceNotes = table.freeze({
	"THE HALLS ARE NOT THE SAME LENGTH TWICE. STOP MEASURING THEM.",
	"WE COUNTED DOORS FOR SIX HOURS AND GOT A DIFFERENT NUMBER EVERY TIME.",
	"IF THE HUM STOPS, GET TO THE BOXES. THE HUM IS THE ONLY CLOCK WE HAVE.",
	"DO NOT SLEEP IN THE OPEN. DO NOT SLEEP ALONE. PREFERABLY DO NOT SLEEP.",
	"SOMEONE KEEPS MOVING THE CHAIR. THERE IS NOBODY ELSE DOWN HERE.",
	"THE WALLPAPER IS DRY. EVERYTHING IS DRY. THE CARPET IS NOT.",
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

	--[[
		── ZOMBIEVILLE ──────────────────────────────────────────────────────────
		Five generators, walked in numerical order, and a loot room that opens
		when the last one turns over.

		The same feature as Clinton's and a completely different activity, which
		is the point of there being two: the vault is a thing you SOLVE, once,
		standing still, by reading. This is a thing you DO, five times, moving,
		and the map is most of the difficulty — the generators are spread across
		open streets with long sightlines, and the walk between four and five is
		the part a horde gets to have an opinion about.

		── WHY THE ORDER IS FIXED AND THE PUZZLES ARE NOT ──────────────────────
		Generator 1 is always first. That is deliberate and it was asked for: the
		route is what a team learns about Zombieville, and a route that reshuffled
		every round would make the map unlearnable and the objective a search.

		The MINI-PUZZLE at each one is dealt fresh every round from a pack of
		five, so the fourth generator is a breaker panel tonight and a pressure
		gauge in ten minutes. Same split the vault makes between props that never
		move and documents that never repeat.
	]]
	table.freeze({
		id = "ZombievilleGrid",
		map = "Zombieville",
		kind = PuzzleConfig.Kind.Generators,

		generators = table.freeze({
			object = "Generator",
			count = 5,
			prompt = "GENERATOR",
		}),

		--[[ Both models the designer built, by the names they already carry.
		     `Lootroom` sits under Zombieville and `Lootroom Gate` sits inside it,
		     which is exactly the shape findNamed-then-findWithin was written
		     for. ]]
		gate = table.freeze({
			room = "Lootroom",
			door = "Lootroom Gate",
			--[[ Gone rather than ghosted. See GateSpec. ]]
			vanish = true,
			label = "LOOT ROOM",
		}),

		--[[ Half the vault's cash and the same restock, because the generators
		     are the cheaper objective of the two: five machines you interact with
		     is more walking and less thinking than four documents that have to be
		     found without a map marker, and paying them the same would make
		     Clinton's the one nobody bothers with.

		     Still split across the team, still through EconomyService, still
		     capped by the round's own earnings ceiling. Nothing here is a new
		     currency or a new reward path. ]]
		reward = table.freeze({ dollars = 1_500, restockItems = true }),

		loot = table.freeze({
			--[[ The room's own special, and the counterpart to Clinton's
			     flamethrower — see WeaponConfig for why it is a line rather than
			     a cone. Same distribution: it lies on the floor, it is taken
			     through the ordinary pickup path, it has no reserve, and it does
			     not survive the round. Every round the team wants one, they walk
			     the five generators again. ]]
			weapon = table.freeze({
				object = "Tesla Rifle",
				itemId = "TeslaRifle",
				slot = "Primary",
			}),
			--[[ Spelled the way the MAP spells it, which is with an A.

			     Clinton's says "Stockpile" and Zombieville's model says
			     "Stackpile", and the forgiving matcher folds case, spaces and
			     punctuation but not letters — so a config that quietly corrected
			     the spelling would find nothing and the pile would be scenery for
			     the life of the map. The config follows the build; the build does
			     not have to follow the config. ]]
			stockpile = table.freeze({
				object = "Dollar Stackpile",
				dollars = 350,
				prompt = "DOLLAR STACKPILE",
			}),
		}),
	}),

	--[[
		── THE BACKROOMS ────────────────────────────────────────────────────────
		Four breaker boxes, thrown in an order this round invented, and four
		objects in the maze that between them say what that order is.

		── WHY THIS MAP GETS THIS PUZZLE ───────────────────────────────────────
		The other two objectives are answered by knowing the building. Clinton's
		clipboard is always on the same desk; Zombieville's generators are always
		walked 1 to 5. Both are learnable, both are meant to be, and neither
		works here — the Backrooms is one continuous maze of identical yellow
		corridors with no landmarks, so "remember where the thing was" is not a
		skill this map lets a player have.

		So the thing that is not learnable is the ORDER. The boxes never move,
		the documents never move, and the sequence is rolled fresh every round —
		which means a team that has played this map fifty times still has to
		read, and a team on its first round is not at a disadvantage for it.

		── AND THE ANSWER IS STILL NEVER GENERATED ─────────────────────────────
		Same rule as the vault, and it is the reason this is a template rather
		than a handful of code in the service: the SEQUENCE is rolled, and every
		document is printed FROM that sequence. There is no second place where
		the order is written down and therefore no way for a clue to disagree
		with the boxes. See Server/Level/Puzzles/FuseSequence.
	]]
	table.freeze({
		id = "BackroomsFuses",
		map = "Backrooms",
		kind = PuzzleConfig.Kind.Fuses,
		template = "FuseSequence",

		--[[ The four boxes the designer built, by the names they carry. The
		     number is printed onto each one by the service — see FuseSet, and
		     the reason is that four unlabelled grey boxes in this map is a puzzle
		     nobody can play. ]]
		fuses = table.freeze({
			object = "Fuse Box",
			count = 4,
			prompt = "FUSE BOX",
			face = "Front",
			pixelsPerStud = 60,
			textSize = 40,
			indicator = "Light",
		}),

		--[[
			The four objects, and what each of them knows.

			One position each, in the order they are listed: the note says which
			box is FIRST, the television says which is SECOND, the hazmat log says
			THIRD and the scrawl says LAST. Deliberately one fact per object and
			no overlap, which buys two things worth having.

			The first is that three clues are enough. A team that finds any three
			can work the fourth out by elimination, and a document that fell
			through the world or sits behind a locked Charger is not a round
			nobody can finish.

			The second is that no two of them can ever contradict each other,
			because no two of them are talking about the same position. A clue set
			where two objects both describe the third box is a clue set that has
			to be checked for agreement, and a check like that is a thing that
			works until the day it does not.

			── AND THEY ARE READ IN ANY ORDER ──────────────────────────────────
			Unlike the vault's, which are a CHAIN. That was right there — the
			ordering is what stops a player reading the fourth digit off a wall
			without walking the building — and it is wrong here, because these
			four are spread through a maze with no landmarks and being told
			"find the second one first" in a place where you cannot navigate is
			being told to wander. Everything here is legible the moment you stand
			in front of it. The maze is the difficulty; it does not need help.
		]]
		clues = table.freeze({
			table.freeze({
				order = 1,
				object = "Clue 1",
				face = "Front",
				pixelsPerStud = 110,
				textSize = 20,
				font = "SpecialElite",
				prompt = "MAINTENANCE NOTE",
				found = "RESTART PROCEDURE",
				texts = table.freeze({
					"AUX POWER \226\128\148 RESTART PROCEDURE\n\n"
						.. "FILED: {date}   {sector}\n\n"
						.. "STEP ONE. THROW BOX {first}.\n\n"
						.. "START ANYWHERE ELSE AND THE\n"
						.. "LOOP TRIPS AND YOU WAIT.\n\n"
						.. "{tech}, MAINTENANCE",
					"IF YOU ARE READING THIS THE\n"
						.. "LIGHTS ARE OUT AGAIN.\n\n"
						.. "{sector} \226\128\148 {date}\n\n"
						.. "IT STARTS AT BOX {first}. ALWAYS.\n"
						.. "I HAVE WRITTEN IT DOWN BECAUSE\n"
						.. "I KEEP FORGETTING.\n\n"
						.. "{tech}",
					"POSTED FOR THE NEXT SHIFT\n\n"
						.. "{date}\n\n"
						.. "FIRST BREAKER IN THE SEQUENCE\n"
						.. "IS NUMBER {first}.\n\n"
						.. "THE REST IS ON THE OTHER\n"
						.. "PAPERWORK. GOOD LUCK.\n\n"
						.. "{tech}, {sector}",
				}),
			}),
			table.freeze({
				order = 2,
				object = "Clue 2",
				face = "Front",
				pixelsPerStud = 70,
				textSize = 22,
				font = "Code",
				--[[ A CRT with nothing behind it. Pale on dark rather than the
				     paperwork's ink, because the one thing a player has to be able
				     to tell about this object at a glance is that it is a SCREEN. ]]
				ink = Color3.fromRGB(126, 232, 160),
				prompt = "BROKEN TV",
				found = "SIGNAL FRAGMENT",
				texts = table.freeze({
					">> SIGNAL DEGRADED <<\n\n"
						.. "...AND THE SECOND IS\n"
						.. "BREAKER {second}. REPEAT.\n"
						.. "SECOND IS {second}...\n\n"
						.. ">> NO CARRIER <<",
					">> REC \226\151\143 {date} <<\n\n"
						.. "SOMEBODY WRITE THIS DOWN.\n"
						.. "AFTER THE FIRST ONE YOU\n"
						.. "WANT BOX {second}.\n\n"
						.. ">> TAPE ENDS <<",
					">> STANDBY <<\n\n"
						.. "SEQUENCE POSITION TWO\n"
						.. "= BOX {second}\n\n"
						.. "THIS LOOP HAS BEEN PLAYING\n"
						.. "FOR A VERY LONG TIME.\n\n"
						.. ">> STANDBY <<",
				}),
			}),
			table.freeze({
				order = 3,
				object = "Clue 3",
				face = "Front",
				pixelsPerStud = 110,
				textSize = 20,
				font = "SpecialElite",
				prompt = "HAZMAT LOG",
				found = "CONTAINMENT LOG",
				texts = table.freeze({
					"CONTAINMENT LOG \226\128\148 {sector}\n\n"
						.. "DATE: {date}\n\n"
						.. "THIRD BREAKER: BOX {third}\n\n"
						.. "SUIT ON BEFORE YOU GO PAST\n"
						.. "THE CARPET. NO EXCEPTIONS.\n\n"
						.. "{note}\n\n"
						.. "SIGNED: {techInitial}",
					"HAZARD SWEEP \226\128\148 {date}\n\n"
						.. "AREA: {sector}\n\n"
						.. "WE GOT AS FAR AS THE THIRD\n"
						.. "BOX. THAT IS NUMBER {third}.\n\n"
						.. "{note}\n\n"
						.. "{techInitial}",
					"DECON RECORD\n\n"
						.. "{sector} \226\128\148 {date}\n\n"
						.. "POSITION THREE IN THE\n"
						.. "RESTART IS BOX {third}.\n\n"
						.. "IF THE SUIT TEARS, TURN\n"
						.. "AROUND. {note}\n\n"
						.. "{techInitial}",
				}),
			}),
			table.freeze({
				order = 4,
				object = "Clue 4",
				face = "Front",
				pixelsPerStud = 60,
				textSize = 34,
				--[[ Scrawled rather than filed. The one clue in the set that was
				     not written by somebody doing their job. ]]
				font = "PermanentMarker",
				ink = Color3.fromRGB(58, 46, 40),
				prompt = "WALL MARKING",
				found = "SOMEBODY WROTE ON THE WALL",
				texts = table.freeze({
					"LAST ONE IS {fourth}\n\nTHEN THE DOOR OPENS\n\nDONT STOP MOVING",
					"{fourth} GOES LAST\n\nI AM NOT WRITING IT\nANYWHERE ELSE\n\nFIND ME",
					"FINISH ON {fourth}\n\nIF YOU ARE READING THIS\nI DIDNT MAKE IT BACK",
				}),
			}),
		}),

		--[[ The boards on the exit door, by the name the model carries. Gone
		     rather than ghosted — boards somebody pulled off a door are boards
		     on the floor, and half-transparent planks still filling a doorway
		     would read as a door that is somehow both barricaded and open. ]]
		gate = table.freeze({
			room = "Backrooms Lootroom",
			door = "Wooden Boards",
			vanish = true,
			label = "LOOT ROOM",
		}),

		--[[ In through door one, back out through door two. See DoorwaySpec for
		     why only the first of them is sealed. ]]
		doorways = table.freeze({
			table.freeze({
				door = "Exit Door 1",
				target = "Lootroom Teleport",
				prompt = "EXIT DOOR",
				sealed = true,
			}),
			table.freeze({
				door = "Exit Door 2",
				target = "Lootroom Exit",
				prompt = "RETURN TO THE MAZE",
				sealed = false,
			}),
		}),

		--[[ Between the other two, because the work is. Clinton is four
		     documents in a building you can navigate and one code; Zombieville is
		     five machines on a route you can learn. This is four documents in a
		     maze with no landmarks AND a walk to four boxes in an order that did
		     not exist ten minutes ago, and paying it Zombieville's rate would
		     make the hardest of the three objectives the least worth doing.

		     Still Dollars, still split across the team, still capped by the
		     round's own earnings ceiling. Nothing here is a new currency. ]]
		reward = table.freeze({ dollars = 2_500, restockItems = true }),
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
--[[ Five now, because Zombieville has five generators and the refusal a player
     reads when they walk up to the third one first names the one they should
     have found. A number would be correct and would read like an error code. ]]
local ORDINALS = table.freeze({ "FIRST", "SECOND", "THIRD", "FOURTH", "FIFTH" })

function PuzzleConfig.ordinal(order: number): string
	return ORDINALS[order] or tostring(order)
end

--[[ The same five in the case a sentence wants them. Kept beside the shouty set
     rather than lowercased at the call site, so the one place that decides how
     this game spells "fourth" is this line. ]]
local ORDINALS_SOFT = table.freeze({ "first", "second", "third", "fourth", "fifth" })

--[[
	What a player is told when they interact with the wrong generator.

	Written here rather than in the service because it is a piece of the design
	rather than a piece of the plumbing: it names the one they should be looking
	for, which is the entire difference between a refusal that teaches the
	objective and a refusal that just says no.
]]
function PuzzleConfig.wrongGenerator(wanted: number): string
	return string.format("Wrong generator, find the %s one!", ORDINALS_SOFT[wanted] or tostring(wanted))
end

--[[ Which shape a definition is, with the default filled in. Absent means
     Investigation — see PuzzleConfig.Kind — so Clinton's definition never had to
     grow a field to keep saying what it always said. ]]
function PuzzleConfig.kindOf(definition: PuzzleDefinition?): string
	if not definition then
		return PuzzleConfig.Kind.Investigation
	end
	return definition.kind or PuzzleConfig.Kind.Investigation
end

--[[ The nth prop in a numbered family: "Generator 3", "Fuse Box 2". One
     function so the name the service LOOKS for and the name a warning PRINTS
     are the same string, which is what makes a missing prop diagnosable from
     the output — and one function for both families, because two copies of a
     naming rule is how a map ends up with a `Fuse Box 2` nothing can find. ]]
function PuzzleConfig.numberedName(set: { object: string }, order: number): string
	return string.format("%s %d", set.object, order)
end

function PuzzleConfig.generatorName(set: GeneratorSet, order: number): string
	return PuzzleConfig.numberedName(set, order)
end

function PuzzleConfig.fuseName(set: FuseSet, order: number): string
	return PuzzleConfig.numberedName(set, order)
end

--[[
	What a player is told when they throw the wrong breaker.

	And, more importantly, what they are NOT told.

	The generators' refusal names the machine they should have found instead,
	because that order is public — it is painted on the side of five machines and
	the objective is the walking. This order is the SECRET, and a refusal reading
	"try box 3" would hand the sequence to anybody willing to press four things,
	which is the entire puzzle given away by its own error message.

	So it says that nothing happened, and it says it in the map's voice. The
	player learns exactly one true thing — not this one — which is the same thing
	they would learn from a real breaker that was not next in the loop.

	── AND THAT IS ALL THAT HAPPENS ────────────────────────────────────────────
	No damage, no reset, nothing broken. A wrong box costs a couple of seconds on
	that box and nothing else, deliberately: this is played while the map is
	trying to kill you, and an objective that punishes a guess is an objective
	that punishes a guess made because a Charger was coming.

	Which does leave brute force on the table, and it is worth being honest about
	the arithmetic: four boxes, then three, then two, then one is ten presses at
	worst. What makes that a bad plan is not a rule, it is the map — those ten
	presses are ten walks across a maze with no landmarks and a horde in it,
	against four walks for a team that read the paperwork. The clues are a
	shortcut through the Backrooms, and the Backrooms is the deterrent.
]]
local DEAD_FUSE = table.freeze({
	"Nothing. The box is dead.",
	"The switch throws and nothing answers.",
	"Dust, a click, and no power.",
	"Not this one. Somewhere in the dark, nothing changes.",
})

function PuzzleConfig.wrongFuse(random: Random?): string
	local index = if random then random:NextInteger(1, #DEAD_FUSE) else 1
	return DEAD_FUSE[index]
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
