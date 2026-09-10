--!nonstrict
--[[
	PuzzleService — the side objective, in all three of the shapes it comes in.

	Clinton's is a VAULT: four documents left in a building, one keypad, and a
	code that exists nowhere except in this process. Zombieville's is a GRID:
	five generators walked in numerical order, each opening one of five
	mini-puzzles dealt fresh every round, and a loot room whose gate rolls up
	when the last one turns over. The Backrooms' is a HUNT: four breaker boxes
	thrown in an order this round invented, four objects in a maze that between
	them say what that order is, and a loot room somewhere else entirely that two
	doors move you in and out of.

	── WHY ONE SERVICE RUNS BOTH ───────────────────────────────────────────────
	They are different activities and the same feature. Both are armed when a
	round starts and cleared when it ends; both find their props by name in
	whatever map is loaded; both seal a room; both pay a team in Dollars and a
	weapon that does not survive the round. All of that is written once, below,
	and a second service would have been a second copy of it — including the
	parts that took several goes to get right, like putting back a loot weapon a
	previous round consumed on a map that was never reloaded.

	So the KIND decides which arming half runs and which handlers answer. Finding
	props, settling them, arming the loot, opening the door, paying out and
	clearing are one implementation with three front ends. See PuzzleConfig.Kind.

	The third one is the evidence that was worth it: the fuse hunt cost a
	template file, an arming function and two handlers, and it inherited the
	round lifecycle, the prop finder, the reach check, the rate limits, the gate,
	the loot, the payout and the counter on everybody's screen without changing
	any of them.

	── THE VAULT ───────────────────────────────────────────────────────────────

	Found by NAME rather than by tag, exactly the way the ammo crates are: a
	folder called "Puzzle" inside the map holding models called "Keypad", "Vault
	Door", "Clipboard", "Room Sign", "Badge" and "Procedure". Nothing is tagged
	by hand — this service tags what it finds when a map loads, so a level
	designer only has to name things and put them somewhere sensible.

	── THE ANSWER HAS NEVER BEEN ON A CLIENT ───────────────────────────────────
	The values are rolled here, the answer is derived here from those same
	values, and neither is ever sent anywhere. What replicates is the TEXT on
	four props — the same words a player reads with their eyes. There is nothing
	to intercept, because the arithmetic that turns a squad number into a code
	does not exist outside this process.

	A submitted code is compared here and nowhere else. The client's keypad is a
	number pad and a text label; it has no idea what the answer is, and a client
	that skips it entirely gets the identical refusal.

	── AND IT IS GENERATED PER ROUND, NOT PER MAP LOAD ─────────────────────────
	`arm` is called from the round starting, not from the map changing, and that
	distinction is load-bearing: MapService.ensure is a no-op when the team votes
	for the map already loaded, so a puzzle that regenerated on mapChanged would
	serve the SAME code for every consecutive round on Clinton. Which is to say
	it would be solved once and then known.

	── WHAT IT DOES NOT DO ─────────────────────────────────────────────────────
	It does not touch the waves, the Director, the modifiers or the upgrades. It
	is a side objective: a team that never finds the keypad plays exactly the
	round they would have played, and nothing anywhere else asks whether the
	vault is open.

	── THE GRID ────────────────────────────────────────────────────────────────
	Everything above is still true of Zombieville, with one honest difference.
	The generator puzzles are PICTURES — a wire panel, a gauge, a row of
	breakers — and a player solves one by looking at it, so the drawable half has
	to reach their machine or there is nothing to play. What stays here is every
	decision that could cost somebody else something: whether a generator may be
	powered at all, whether it is the next one in the order, whether the answer
	was right, and whether the gate opens. A crafted client can auto-solve its
	own mini-game and is exactly as far from the loot room as one that did not.

	See GeneratorConfig's header for the long version of that trade.

	── THE HUNT ────────────────────────────────────────────────────────────────
	Back to keeping everything. There is no mini-game to draw here — a breaker is
	thrown or it is not — so nothing about the sequence has to leave this
	process, and nothing does: it is rolled from the template's values, it is
	compared here, and it is absent from every payload including the refusals.
	See PuzzleConfig.wrongFuse, which is careful in a way the generators' refusal
	never had to be, because Zombieville's order is painted on the side of five
	machines and this one is the thing the whole puzzle is made of.

	The one genuinely new mechanism is the pair of doorways, which MOVE a player
	rather than opening — the Backrooms loot room is not behind its door, it is
	somewhere else in the model. The server checks the door is armed and that the
	player is standing at it; where they land is a part in the map, and no
	position ever comes up from a client.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attributes = require(Shared.Net.Attributes)
local AudioConfig = require(Shared.Config.AudioConfig)
local Enums = require(Shared.Enums)
local GameConfig = require(Shared.Config.GameConfig)
local GeneratorConfig = require(Shared.Config.GeneratorConfig)
local MapConfig = require(Shared.Config.MapConfig)
local PuzzleConfig = require(Shared.Config.PuzzleConfig)
local Registry = require(Shared.Util.Registry)
local WeaponConfig = require(Shared.Config.WeaponConfig)
local Remotes = require(Shared.Net.Remotes)
local Trove = require(Shared.Util.Trove)

local GA = Attributes.Game
local PZ = Attributes.Puzzle

--[[
	Every puzzle template this build knows, by the name a definition uses.

	Here rather than in PuzzleConfig because a template derives the ANSWER, and
	the answer must not exist in a Shared module a client can read. The config
	says which template a map wants; only the server can turn that name into the
	code.

	Adding one is a file in Puzzles/ and a row here. Nothing below this line
	knows what a squad number is.
]]
local TEMPLATES = {
	NumberInvestigation = require(script.Parent.Puzzles.NumberInvestigation),
	FuseSequence = require(script.Parent.Puzzles.FuseSequence),
}

--[[ The five generator mini-puzzles, behind one door for the same reason the
     templates are: every one of them owns an answer, and an answer in a Shared
     module is an answer a client can read without playing. This file knows that
     a generator has a puzzle and has never heard of a wire. ]]
local Pack = require(script.Parent.Generators.Pack)

local PuzzleService = {}

local serviceTrove = Trove.new()
local doorTrove = Trove.new()
--[[ The hums of every generator currently running.

     Their own trove because they are the one sound in this file with a
     LIFETIME: AudioService leaves a looped voice alone until its Sound is
     destroyed, which is correct — a hum that stopped on a timer would be a
     machine that switched itself off — and means somebody has to destroy it.
     A generator still running into the next round is a machine nobody
     powered. ]]
local runningTrove = Trove.new()

--[[
	A spare of each room's weapon, and why one is needed.

	InventoryService:pickup DESTROYS the world model — correct for a gun somebody
	dropped, and a problem for the two things in the game that exist exactly
	once. MapService:ensure is a no-op when the team votes for the map already
	loaded, so a Clinton round followed by another Clinton round does not reload
	the map: the flamethrower was taken, the model is gone, and the vault of the
	second round is empty.

	So the first time one is seen it is cloned aside, with the place it was
	standing. Any later arm that cannot find one puts it back. Held out of the
	DataModel by a plain reference rather than parked in ServerStorage, because a
	template that is a descendant of nothing cannot be found by any of the tag
	sweeps or folder walks that would otherwise trip over it.

	── KEYED BY PUZZLE, NOT ONE SLOT ───────────────────────────────────────────
	This was a single pair of variables while the flamethrower was the only
	weapon behind a puzzle, and that stopped being safe the moment Zombieville
	got its own: a server that played Clinton and then voted Zombieville would
	arrive at the loot room, fail to find a Tesla Rifle, and restore the
	FLAMETHROWER it had stashed on the previous map — into a room that had never
	held one, at a CFrame from a building that is no longer loaded.

	One slot per puzzle id, so each room only ever puts back its own.
]]
type WeaponStash = { model: Model, home: CFrame }
local weaponStash: { [string]: WeaponStash } = {}

--[[ Everything about the puzzle currently armed, or a dead table when there is
     none. One table so `clear` is one assignment and there is no way to leave
     half a puzzle behind. ]]
local state = {
	definition = nil :: any,
	--[[ The four-digit string. The single most sensitive value in this file and
	     the reason none of this lives in Shared. ]]
	answer = "",
	solved = false,
	keypad = nil :: Model?,
	door = nil :: Model?,
	--[[ How see-through every part of the door was before it opened, so closing
	     it puts back what the designer built rather than a guess. A re-armed
	     round must never inherit an open vault. ]]
	doorLooks = {} :: { [BasePart]: number },
	clues = {} :: { Model },
	--[[ The rolled values, kept so a collection can re-print every prop with one
	     more digit revealed. Never leaves this process. ]]
	values = nil :: any,
	--[[ How many STEPS of the objective the team has done — clues collected on
	     Clinton, generators powered on Zombieville. Team-wide rather than per
	     player because this is one objective four people are working on: a
	     counter that reset for whoever walked in second would be four separate
	     puzzles in one building.

	     One field for both kinds, because it is the same number: how far along
	     the team is, and what the counter on everybody's screen reads. ]]
	found = 0,

	--[[
		── THE GENERATOR KIND ───────────────────────────────────────────────────
		The five machines by order, the reverse lookup that turns the instance a
		player pressed into "which one is this", and the puzzle dealt to each.

		`deals` is the sensitive one and never leaves this process. Each entry
		holds a challenge — the picture the client is sent — and a solution beside
		it, and only the first half is ever put on a wire. See onSubmitGenerator:
		the answer comes back up and is checked HERE.
	]]
	generators = {} :: { [number]: Model },
	generatorOf = {} :: { [Model]: number },
	deals = {} :: { [number]: any },
	--[[ The loot room itself, kept so the arrow has somewhere to point that is
	     not the gate part's own centre — a gate is a flat slab and pointing at it
	     from behind sends the team round the wrong side of the building. ]]
	gateRoom = nil :: Instance?,
	--[[ Two views of the same four props: by config name, so repaint can find
	     the model for a clue; and by model, so the instance a player interacted
	     with can be turned back into "which clue is this, and what number is
	     it". Both are rebuilt from scratch on every arm. ]]
	props = {} :: { [string]: Model },
	--[[ The two things actually in the room. Resolved at arm so they can be
	     found, and armed only when the door opens — see armLoot. ]]
	weaponDrop = nil :: Instance?,
	stockpile = nil :: Instance?,
	stockpileClaimed = false,
	clueOf = {} :: { [Model]: any },

	--[[
		── THE FUSE KIND ────────────────────────────────────────────────────────
		The four boxes by their printed number, the reverse lookup that turns the
		instance a player pressed back into "which box is this", and which of
		them have been thrown.

		`sequence` is the sensitive one and never leaves this process. It is the
		order the boxes want, read out of the template's values — see
		FuseSequence — and it appears in no payload, no attribute and no refusal.
		A client that pressed all four boxes learns it the same way an honest
		team does: by walking to all four.
	]]
	fuses = {} :: { [number]: Model },
	fuseOf = {} :: { [Model]: number },
	fuseLive = {} :: { [number]: boolean },
	--[[ What a box's indicator part looked like before this service touched it,
	     so OFF is the look the designer built and the map is handed back
	     unpainted. Same job `doorLooks` does for a door's transparency. ]]
	fuseLooks = {} :: { [BasePart]: { color: Color3, material: Enum.Material } },
	sequence = {} :: { number },

	--[[ Which documents the TEAM has read, and which each PLAYER has. The team's
	     drives the "2 of 4" everybody hears; the player's decides whether a page
	     opening is news or a re-read, so four survivors reading the same note do
	     not each announce it and one survivor re-reading it is not told they
	     found something. Neither is progress: the counter on this map is the
	     boxes. ]]
	clueSeen = {} :: { [number]: boolean },
	readBy = {} :: { [Player]: { [number]: boolean } },

	--[[
		── THE BEACON KIND ──────────────────────────────────────────────────────
		The four fires by number, the reverse lookup that turns a pressed prop
		back into "which one is this", and the server-time stamp each of them
		goes out at.

		`burn` is this round's window, taken once at arm from the headcount — see
		PuzzleConfig.beaconBurn. Sampled at arm rather than read live, because a
		player leaving mid-objective must not shorten a fire that is already
		burning, and one joining must not lengthen it.

		Nothing here is a secret. Every one of these is published on the prop as
		an attribute, because a beacon's state is a fact about the world that a
		player two hundred studs away is meant to be able to read.
	]]
	beacons = {} :: { [number]: Model },
	beaconOf = {} :: { [Model]: number },
	beaconUntil = {} :: { [number]: number },
	beaconLooks = {} :: { [BasePart]: { color: Color3, material: Enum.Material } },
	burn = 0,

	--[[ The doors that MOVE a player, and where each of them lands. Resolved at
	     arm, tagged when the design says they may be used — see armDoorways. ]]
	doorways = {} :: { [Instance]: BasePart },
	doorwayList = {} :: { { door: Instance, target: BasePart, spec: any } },
}

--[[ Wording only. Its own Random so that picking which way a dead breaker
     phrases itself can never consume a draw from the round's sequence — the
     puzzle has to be reproducible from its seed, and a refusal is not part of
     the puzzle. ]]
local chatter = Random.new()

--[[
	Per-player, and cleared when they leave.

	`typedAt` and `tookAt` are SEPARATE on purpose. They started as one field and
	that was a bug you would only find by playing it: picking up the fourth clue
	stamped the same clock the keypad reads, so walking straight to the door and
	entering the code you had just earned answered WAIT. The two actions are
	throttled for different reasons and at different rates, so they get a stamp
	each.

	`wrong` is the run of consecutive misses that drives the lockout.
]]
local attempts: {
	[Player]: { typedAt: number, tookAt: number, wrong: number, lockedUntil: number },
} = {}

--[[ The floor between two collect requests from one player. Short, because
     picking clues up is not a thing anybody spams for advantage — it exists so
     a crafted client cannot turn one socket into unlimited replies. ]]
local COLLECT_INTERVAL = 0.25

--[[
	How long a box sulks after somebody throws it out of turn.

	Short on purpose, and the shortest thing in this file that could be called a
	punishment. The design brief was explicit that a wrong box must not damage
	anybody, must not break anything permanently and must not reset the team's
	progress, because this is played while the map is actively trying to kill
	you and an objective that punishes a guess is an objective that punishes a
	guess made because a Charger was coming.

	So this is the whole of it: a couple of seconds on THAT box, for THAT player.
	It is not there to deter brute force — see PuzzleConfig.wrongFuse for why the
	maze is what does that — it is there so one player holding the interact key
	cannot turn a breaker into a sixty-press-per-second oracle.
]]
local WRONG_FUSE_COOLDOWN = 2.5

--[[ How far above a landing part a teleported survivor is placed, on top of
     half the part's own height. Enough to clear a carpet and a doorframe lip
     without dropping somebody through a thin platform. ]]
local DOORWAY_RISE = 3.5

--[[ Seconds the server keeps a teleported body before handing it back, and the
     same number SurvivorService uses for a spawn. Long enough for the move to
     replicate, short enough that nobody plays a corridor server-simulated. ]]
local DOORWAY_OWNERSHIP_TIME = 0.5

local function serverNow(): number
	return Workspace:GetServerTimeNow()
end

--[[ The one place a refusal is worded. Every branch below answers, because a
     keypad that silently ignores you is a keypad the player thinks is broken. ]]
local function reply(player: Player, ok: boolean, reason: string, retryAt: number)
	Remotes.Event.VaultCodeResult:FireClient(player, {
		ok = ok,
		reason = reason,
		--[[ An absolute server-time stamp, never a remaining count. Same rule as
		     every other deadline in this game: the client subtracts its own clock
		     and the number cannot drift or arrive stale. ]]
		retryAt = retryAt,
	})
end

local function record(player: Player)
	local entry = attempts[player]
	if not entry then
		entry = { typedAt = 0, tookAt = 0, wrong = 0, lockedUntil = 0 }
		attempts[player] = entry
	end
	return entry
end

-- ── finding the props ───────────────────────────────────────────────────────

--[[ The puzzle folder in whatever map is live, matched as forgivingly as the
     crate and medkit folders are: case, spacing, punctuation and a trailing
     plural all folded away, because a hand-typed folder name is the single most
     likely thing about this feature to be slightly wrong. ]]
local function findPuzzleFolder(root: Instance): Instance?
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("Folder") or descendant:IsA("Model") then
			if MapConfig.folderMatches(descendant.Name, PuzzleConfig.FolderName) then
				return descendant
			end
		end
	end
	return nil
end

--[[
	A prop by name, folded the same way the folder is.

	Searched in the puzzle folder first and then across the whole map, and the
	fallback is the important half: the door assembly this was built around is a
	free-model called "KFC Code Door" parented straight under Clinton. Requiring
	it to be moved into a folder would mean dismantling a model that already
	works, which is a good way to end up with one that does not.

	Descendants rather than children on the fallback, because a designer's own
	organisation is theirs — the prop might be three folders deep and it is still
	the prop.
]]
local function findNamed(scope: Instance?, root: Instance, wanted: string): Instance?
	if scope then
		for _, child in scope:GetChildren() do
			if MapConfig.folderMatches(child.Name, wanted) then
				return child
			end
		end
	end
	for _, descendant in root:GetDescendants() do
		if MapConfig.folderMatches(descendant.Name, wanted) then
			return descendant
		end
	end
	return nil
end

--[[
	A named descendant of one assembly, and nowhere else.

	The door is why this exists separately from findNamed. `findNamed` falls back
	to scanning the whole map, which is right for a clue prop a designer put
	wherever they liked and badly wrong for something called "Door" — a KFC has
	a front door, a kitchen door and a walk-in, and GetDescendants returns
	whichever it reaches first. Fading a random door and leaving the vault shut
	is a bug that looks like the puzzle being broken.

	So the vault door is looked for INSIDE the keypad assembly, which is where it
	lives, and if it is not there the puzzle says so rather than guessing.
]]
local function findWithin(scope: Instance, wanted: string): Instance?
	for _, descendant in scope:GetDescendants() do
		if MapConfig.folderMatches(descendant.Name, wanted) then
			return descendant
		end
	end
	return nil
end

--[[ Every BasePart in a prop, whether the prop is a Model or a lone Part. The
     door is the reason: their `Door` is a single Part, and a Model is equally
     likely from the next person's build. ]]
local function partsOf(instance: Instance): { BasePart }
	local parts: { BasePart } = {}
	if instance:IsA("BasePart") then
		table.insert(parts, instance)
	end
	for _, descendant in instance:GetDescendants() do
		if descendant:IsA("BasePart") then
			table.insert(parts, descendant)
		end
	end
	return parts
end

--[[
	Nails a prop to where the designer put it.

	Everything this puzzle uses has to stay put for ten minutes in a room full
	of gunfire and bodies, and an imported model is unanchored about half the
	time. Unanchored, a clipboard is shot off its desk by the first stray pellet,
	a flamethrower is kicked under the geometry by a Charger, and the clue a team
	needs is somewhere nobody will ever look. MapItemService anchors its floor
	pickups for exactly this reason and says so.

	Collision is only dropped for things a player walks up to and takes — a
	flamethrower lying in a doorway should not be something you bump into. It is
	left alone on the documents, because a room sign may well be part of a wall
	and turning its collision off would put a hole in the building.
]]
local function settle(instance: Instance, dropCollision: boolean)
	for _, part in partsOf(instance) do
		part.Anchored = true
		if dropCollision then
			part.CanCollide = false
		end
	end
end

--[[
	Everything downstream deals in Models.

	A designer will reasonably drop a single Part in for a room sign, and the
	interaction system's own pivot helper handles only BasePart and Model — so a
	lone part is wrapped once, here, rather than every caller checking. Copied
	from AmmoCrateService, which wraps crates for exactly the same reason.
]]
local function asModel(child: Instance, parent: Instance): Model?
	if child:IsA("Model") then
		return child
	end
	if not child:IsA("BasePart") then
		return nil
	end
	local wrapper = Instance.new("Model")
	wrapper.Name = child.Name
	wrapper.Parent = parent
	child.Parent = wrapper
	wrapper.PrimaryPart = child
	return wrapper
end

--[[ The face a SurfaceGui should be drawn on, from the config's plain-English
     name. Unknown values fall back to Front rather than erroring: a typo in a
     config string should put the text on the wrong side of a sign, not stop the
     round from starting. ]]
local function faceFrom(name: string): Enum.NormalId
	local face = (Enum.NormalId :: any)[name]
	return if typeof(face) == "EnumItem" then face else Enum.NormalId.Front
end

--[[
	The face a clue is written in, from the config's plain name, defaulting to
	the typewriter.

	Same forgiveness `faceFrom` gets and for a stronger reason: a font name is a
	string against a list Roblox owns and occasionally grows, so a build without
	`SpecialElite` should print the note in the wrong face rather than stop the
	round from starting. A puzzle that refuses to arm because of a typeface is a
	worse outcome than one that looks slightly off.
]]
local function fontFrom(name: string?): Enum.Font
	if typeof(name) ~= "string" then
		return Enum.Font.Code
	end
	local font = (Enum.Font :: any)[name]
	return if typeof(font) == "EnumItem" then font else Enum.Font.Code
end

--[[ The default ink: near-black on off-white, which is right for every piece of
     paperwork in the game and wrong for the two things in the Backrooms that
     are not paperwork. See ClueSlot.ink. ]]
local INK = Color3.fromRGB(28, 26, 24)

-- ── painting the clues ──────────────────────────────────────────────────────

--[[
	Which part of a prop the text goes on, and a warning when nobody said.

	PrimaryPart or the first BasePart the tree happens to return — and that
	second half is a coin toss. A designer's fuse box has a front panel, a
	bracket, four screws and a hinge, and `FindFirstChildWhichIsA` returns
	whichever of them comes first in the instance tree, which is an ordering
	nobody authored and nobody can see. The number ends up on the back of the
	box, or on a screw.

	It still falls back rather than refusing, because a number on the wrong face
	is a puzzle you can play badly and no number at all is a puzzle you cannot
	play. But it says so, once, naming the model AND the part it guessed, which
	between them are enough to fix it from the output without hunting.
]]
local warnedSurface: { [Instance]: boolean } = {}

local function surfaceOf(model: Model, what: string): BasePart?
	if model.PrimaryPart then
		return model.PrimaryPart
	end
	local guess = model:FindFirstChildWhichIsA("BasePart", true)
	if guess and not warnedSurface[model] then
		warnedSurface[model] = true
		warn(
			string.format(
				"[PuzzleService] %q has no PrimaryPart, so its %s was drawn on %q — whichever "
					.. "part the tree returned first. Set the model's PrimaryPart to the face "
					.. "you want it on.",
				model.Name,
				what,
				guess.Name
			)
		)
	end
	return guess
end

--[[
	Puts a document's text onto the prop itself.

	The whole design of this feature rests on the information being ON the
	object. A floating label above a clipboard is a quest marker; words printed
	on the paper are something somebody left behind, and the difference is the
	entire reason a player believes there was a security team here.

	Server-made, so it replicates to everyone for free and every survivor reads
	the same document — and so that a client cannot rewrite it into the answer,
	because the thing it would have to rewrite is not the thing being checked.

	Also mirrored onto an attribute. The close-up reader needs the string, and
	digging a TextLabel out of somebody else's instance tree by name is the kind
	of coupling that breaks the first time a designer renames a part.
]]
local function paint(model: Model, clue: any, text: string)
	local surface = surfaceOf(model, "document")
	if not surface then
		return
	end

	--[[
		A label the designer already built wins.

		Two of the four supplied props ship their own SurfaceGui and TextLabel,
		positioned and sized against geometry this code has never seen — the
		note's paper and the sign's face. Covering those with a generated one
		would throw away the only person's work that knew where the text should
		sit. So: if the prop already has a TextLabel under a SurfaceGui, this
		writes into it and touches nothing else.

		Only the props with nowhere to print get one made for them.
	]]
	local supplied = model:FindFirstChildWhichIsA("SurfaceGui", true)
	local suppliedLabel = supplied and supplied:FindFirstChildWhichIsA("TextLabel", true)
	if suppliedLabel and supplied.Name ~= "FL_Clue" then
		suppliedLabel.Text = text
		suppliedLabel.RichText = false
		model:SetAttribute(PZ.ClueText, text)
		model:SetAttribute(PZ.CluePrompt, clue.prompt)
		model:SetAttribute(PZ.ClueFont, clue.font)
		return
	end

	--[[ Replaced rather than reused. A round re-arming has to overwrite last
	     round's document, and a second SurfaceGui on the same face would leave
	     both legible at once. ]]
	local existing = surface:FindFirstChild("FL_Clue")
	if existing then
		existing:Destroy()
	end

	local gui = Instance.new("SurfaceGui")
	gui.Name = "FL_Clue"
	gui.Face = faceFrom(clue.face)
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = clue.pixelsPerStud
	gui.LightInfluence = 0
	--[[ Always on top is deliberately OFF. A document that draws through the
	     wall it is pinned to is a HUD element wearing a prop's clothes, and the
	     player would stop believing in it immediately. ]]
	gui.AlwaysOnTop = false
	gui.MaxDistance = 40

	local label = Instance.new("TextLabel")
	label.Name = "Text"
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	--[[ Both off the clue rather than fixed here. Clinton's four are paperwork
	     and take the defaults; the Backrooms' are a note, a dead television, a
	     hazmat log and something scrawled on a wall, and printing all four in
	     one dark typewriter face would tell the player those are four printouts
	     of the same document. A CRT glows and a wall does not, and that
	     difference is most of what says which KIND of thing this is before a
	     word of it has been read. ]]
	label.Font = fontFrom(clue.font)
	label.TextSize = clue.textSize
	label.TextColor3 = if typeof(clue.ink) == "Color3" then clue.ink else INK
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Top
	label.TextWrapped = true
	label.RichText = false
	label.Text = text
	label.Parent = gui

	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0.06, 0)
	pad.PaddingLeft = UDim.new(0.06, 0)
	pad.PaddingRight = UDim.new(0.06, 0)
	pad.PaddingBottom = UDim.new(0.06, 0)
	pad.Parent = label

	gui.Parent = surface

	model:SetAttribute(PZ.ClueText, text)
	model:SetAttribute(PZ.CluePrompt, clue.prompt)
	--[[ And the face it is written in, so the close-up reader can print the
	     scrawl as a scrawl instead of retyping somebody's wall in Courier. Same
	     reason the text itself rides an attribute: the reader needs the fact,
	     and digging it back out of a SurfaceGui by name is coupling that breaks
	     the first time a designer renames a part. ]]
	model:SetAttribute(PZ.ClueFont, clue.font)
end

-- ── the fuse boxes ──────────────────────────────────────────────────────────

--[[
	Prints a box's number on it, and says whether it is live.

	The number is NOT optional decoration. Four identical grey boxes in a maze of
	identical yellow corridors is the Backrooms working exactly as intended and a
	puzzle that cannot be played: a document reading "THROW BOX 3" is worth
	nothing to somebody with no way to tell which box they are standing at. So
	the service prints it rather than trusting four models to have been labelled
	by hand — one place decides, and it cannot disagree with the sequence.

	Live is a colour rather than a word, on the number and on the designer's own
	indicator part if they built one. It is the "changes visually" half of the
	brief, and it has to be visible from down the corridor, because on this map
	the thing a returning player needs to know from a distance is which boxes are
	already done.
]]
local FUSE_DEAD = Color3.fromRGB(196, 186, 170)
local FUSE_LIVE = Color3.fromRGB(126, 232, 160)
--[[ What the number turns once it has a lit panel behind it. Near-black rather
     than the dead grey: this is ink on a light surface now, and grey on green
     is the one combination that would be less legible than before. ]]
local FUSE_PLATE = Color3.fromRGB(18, 26, 20)

local function markFuse(model: Model, set: any, order: number, live: boolean)
	local surface = surfaceOf(model, "number")
	if not surface then
		return
	end

	local colour = if live then FUSE_LIVE else FUSE_DEAD

	--[[ Reused rather than replaced, unlike a clue's. A clue is re-printed with
	     new words every round and a stale SurfaceGui underneath would leave two
	     legible; this one only ever changes colour, and rebuilding it on every
	     throw would flicker the number the player is looking at. ]]
	local gui = surface:FindFirstChild("FL_Fuse") :: SurfaceGui?
	if not gui then
		gui = Instance.new("SurfaceGui")
		gui.Name = "FL_Fuse"
		gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
		gui.LightInfluence = 0
		--[[ Off, like a clue's. A number that draws through the wall the box is
		     bolted to is a HUD element wearing a prop's clothes. ]]
		gui.AlwaysOnTop = false
		gui.MaxDistance = 90

		--[[
			A plate behind the number, and the reason it exists.

			The optional indicator part is the good version of "this box is live",
			and a fuse box that is one mesh grouped into a model has nowhere to put
			one — which is the commonest way a designer builds a prop. On those, a
			digit changing from grey to green is the entire state change, and a
			digit is a few strokes of colour at twenty studs in a corridor with no
			landmarks.

			So the panel lights up as well. Invisible while the box is dead, so a
			cold box is a number printed on a mesh and nothing else; a dark plate
			with the live colour on it once it is thrown, which is a shape rather
			than a glyph and reads from the far end of a hall. Inside the
			SurfaceGui, so it costs the map no parts and works on a prop built any
			way at all.
		]]
		local plate = Instance.new("Frame")
		plate.Name = "Plate"
		plate.Size = UDim2.fromScale(1, 1)
		plate.BorderSizePixel = 0
		plate.BackgroundTransparency = 1
		plate.Parent = gui

		local label = Instance.new("TextLabel")
		label.Name = "Number"
		label.Size = UDim2.fromScale(1, 1)
		label.BackgroundTransparency = 1
		label.Font = Enum.Font.Code
		label.TextXAlignment = Enum.TextXAlignment.Center
		label.TextYAlignment = Enum.TextYAlignment.Center
		label.RichText = false
		--[[ Above the plate. Both are children of the same SurfaceGui and Roblox
		     draws siblings in tree order, so this would be true anyway — said
		     explicitly because "anyway" is the kind of thing that stops being
		     true when somebody reorders two lines. ]]
		label.ZIndex = 2
		label.Parent = gui
		gui.Parent = surface
	end

	gui.Face = faceFrom(set.face)
	gui.PixelsPerStud = set.pixelsPerStud
	local label = gui:FindFirstChild("Number") :: TextLabel?
	if label then
		label.TextSize = set.textSize
		label.Text = tostring(order)
		--[[ Dark on a lit plate, bright on nothing. A green digit on a green
		     panel is a digit nobody can read, and the number is still the thing
		     that says WHICH box this is after it has been thrown. ]]
		label.TextColor3 = if live then FUSE_PLATE else colour
	end

	local plate = gui:FindFirstChild("Plate") :: Frame?
	if plate then
		plate.BackgroundColor3 = colour
		plate.BackgroundTransparency = if live then 0.25 else 1
	end

	--[[
		And the designer's own light, if the model has one.

		Optional by design — a box without one still turns its printed number
		green, which is the change the brief actually asks for — so a map that
		never grows an indicator part is never broken by its absence.

		OFF is the look the designer built, not a look this file invented. The
		original colour and material are remembered the first time the part is
		seen and put back when the round clears, exactly the way `doorLooks`
		remembers a door's transparency: a service that decided what an unlit
		lamp should look like would be a service that quietly repaints somebody's
		model, and it would do it permanently on a map that is not reloaded
		between rounds.
	]]
	if typeof(set.indicator) == "string" then
		for _, part in partsOf(model) do
			if MapConfig.folderMatches(part.Name, set.indicator) then
				if not state.fuseLooks[part] then
					state.fuseLooks[part] = { color = part.Color, material = part.Material }
				end
				local was = state.fuseLooks[part]
				part.Color = if live then colour else was.color
				part.Material = if live then Enum.Material.Neon else was.material
			end
		end
	end
end

--[[
	Re-prints every prop for the number of clues the team now holds.

	Called once at arm and once per collection. The template decides what a prop
	says at a given count — this only carries the answer to the surface — so a
	future template that reveals something other than a digit needs no change
	here.
]]
local function repaint()
	local definition = state.definition
	local template = definition and TEMPLATES[definition.template]
	if not definition or not template or not state.values then
		return
	end
	local surfaces = template.surfaces(definition, state.values, state.found)
	for _, clue in definition.clues do
		local model = state.props[clue.object]
		local text = surfaces[clue.object]
		if model and model.Parent and text then
			paint(model, clue, text)
		end
	end
end

-- ── the beacons ─────────────────────────────────────────────────────────────

--[[
	Sets a beacon burning, or puts it out.

	The column is the whole point of this creature of a puzzle. Crossroads is
	four corners around an open middle with sightlines the whole way across, and
	a team splitting up to light four fires needs to know which of them are still
	going WITHOUT anybody reading a card — so what a lit beacon gets is a shaft of
	light tall enough and bright enough to be read from the far corner. That is
	the objective's entire user interface, and the map draws it.

	Built here rather than left to the designer for the same reason the fuse
	number is: four props that might or might not have been given a light is four
	ways for this objective to be unplayable, and one place that decides is one
	place that cannot disagree with the state.
]]
local BEACON_LIT = Color3.fromRGB(255, 170, 74)
local BEACON_COLUMN_HEIGHT = 220
local BEACON_COLUMN_WIDTH = 2.4
local BEACON_LIGHT_RANGE = 42

local function setBeaconFire(model: Model, set: any, live: boolean)
	local surface = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart", true)
	if not surface then
		return
	end

	local column = surface:FindFirstChild("FL_BeaconColumn") :: BasePart?
	if live and not column then
		column = Instance.new("Part")
		local part = column :: BasePart
		part.Name = "FL_BeaconColumn"
		part.Size = Vector3.new(BEACON_COLUMN_WIDTH, BEACON_COLUMN_HEIGHT, BEACON_COLUMN_WIDTH)
		--[[ Rising FROM the beacon rather than centred on it, so the shaft starts
		     at the fire and goes up instead of burying half of itself in the
		     ground. ]]
		part.CFrame = surface.CFrame * CFrame.new(0, BEACON_COLUMN_HEIGHT * 0.5, 0)
		part.Anchored = true
		part.CanCollide = false
		--[[ Invisible to raycasts, and that is not tidiness. hasLineOfSight is
		     what every special's grab and every burst is played against, and a
		     two-hundred-stud pillar that answered a raycast would cut four
		     creatures' sightlines across the middle of the map. ]]
		part.CanQuery = false
		part.CanTouch = false
		part.Material = Enum.Material.Neon
		part.Color = BEACON_LIT
		part.Transparency = 0.72
		part.Parent = surface

		local glow = Instance.new("PointLight")
		glow.Name = "FL_BeaconGlow"
		glow.Color = BEACON_LIT
		glow.Range = BEACON_LIGHT_RANGE
		glow.Brightness = 2.2
		glow.Parent = surface
	elseif not live and column then
		column:Destroy()
		local glow = surface:FindFirstChild("FL_BeaconGlow")
		if glow then
			glow:Destroy()
		end
	end

	--[[ And the designer's own lamp, if the model has one. OFF is the look they
	     built rather than one this file invented — remembered the first time it
	     is seen and put back when the round clears, the same way the fuse boxes'
	     indicators and a door's transparency are. ]]
	if typeof(set.light) == "string" then
		for _, part in partsOf(model) do
			if MapConfig.folderMatches(part.Name, set.light) then
				if not state.beaconLooks[part] then
					state.beaconLooks[part] = { color = part.Color, material = part.Material }
				end
				local was = state.beaconLooks[part]
				part.Color = if live then BEACON_LIT else was.color
				part.Material = if live then Enum.Material.Neon else was.material
			end
		end
	end
end

-- ── the door ────────────────────────────────────────────────────────────────

--[[
	Opens the vault, or puts it back.

	It FADES rather than swinging or sliding, and that is a decision about
	somebody else's model rather than a preference. A hinge needs a pivot a
	designer has to author; a slide needs somewhere for the door to go, and a
	door that is part of a wall has nowhere — pushing it down would drive it
	through the floor of the room behind it. Fading is the one motion that is
	correct for a door whose geometry this code has never seen, and it is what
	the model's own original script did.

	Collision drops on the first frame rather than at the end of the fade, so the
	door is passable the instant the lock lets go. Nobody has ever enjoyed
	walking into a door that is visibly open.
]]
local function setDoorOpen(open: boolean)
	local door = state.door
	if not door then
		return
	end
	doorTrove:clean()

	--[[
		How far open "open" is, which is a difference between the two maps rather
		than a preference.

		A vault door fades to 0.85 and no further: a doorway with nothing in it
		reads as a hole in the building, while a ghost of a door reads as a door
		somebody opened and keeps the frame legible from across the room.

		A loot-room GATE is a grille, and a grille that rolls up is gone. Leaving
		a ghost of one in the doorway would read as a gate that is still there and
		is now, inexplicably, walk-through-able. See PuzzleConfig's GateSpec.
	]]
	local gate = state.definition and state.definition.gate
	local openTo = if gate and gate.vanish then 1 else 0.85

	for _, part in partsOf(door) do
		part.CanCollide = not open
		part.CanQuery = not open
		local target = if open then math.max(part.Transparency, openTo) else state.doorLooks[part] or 0
		TweenService:Create(part, TweenInfo.new(1.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Transparency = target,
		}):Play()
	end
end

--[[
	Turns the contents of the vault on, once the vault is open.

	Nothing in the room is interactable until this runs. The flamethrower has no
	FL_Slot until now, so walking up to it before the door opens offers nothing;
	the stockpile has no tag, so it is scenery. That matters because "the door is
	shut" is a promise about geometry, and a reward that could be reached by
	clipping a wall is a reward the puzzle was optional for.

	The flamethrower goes in through the ORDINARY pickup path — FL_Slot and
	FL_ItemId, exactly what a dropped weapon carries — so it lands in the primary
	slot the same way any gun does and whatever was there drops at the player's
	feet. InventoryService needs no case for it.
]]
local function armLoot()
	local definition = state.definition
	local loot = definition and definition.loot
	if not loot then
		return
	end

	local weapon = loot.weapon
	if weapon and state.weaponDrop and state.weaponDrop.Parent then
		Attributes.markPickup(state.weaponDrop, weapon.slot, weapon.itemId)
		--[[ A full tank and no reserve. The weapon's own config says reserveMax
		     is zero — an ammo crate will not refill it, and this is the only one
		     that will ever exist. ]]
		local definitionFor = WeaponConfig.get(weapon.itemId)
		state.weaponDrop:SetAttribute(
			Attributes.Pickup.Ammo,
			if definitionFor then definitionFor.magSize else 0
		)
		state.weaponDrop:SetAttribute(Attributes.Pickup.Reserve, 0)
	end

	if loot.stockpile and state.stockpile and state.stockpile.Parent then
		CollectionService:AddTag(state.stockpile, PuzzleConfig.StockpileTag)
		state.stockpile:SetAttribute(PZ.CluePrompt, loot.stockpile.prompt)
	end
end

--[[ And back off, so a round ending does not leave a loaded flamethrower lying
     in an unlocked room for whoever spawns next. ]]
local function disarmLoot()
	if state.weaponDrop and state.weaponDrop.Parent then
		for _, key in
			{
				Attributes.Pickup.Slot,
				Attributes.Pickup.ItemId,
				Attributes.Pickup.Ammo,
				Attributes.Pickup.Reserve,
			}
		do
			state.weaponDrop:SetAttribute(key, nil)
		end
	end
	if state.stockpile and state.stockpile.Parent then
		CollectionService:RemoveTag(state.stockpile, PuzzleConfig.StockpileTag)
		state.stockpile:SetAttribute(PZ.CluePrompt, nil)
	end
end

-- ── what the HUD is told ────────────────────────────────────────────────────

--[[
	The counter's WORDS, published beside its numbers.

	The three numbers are generic — a side objective with N steps, M of them done
	— and both kinds are that shape. The wording is not: a card reading
	"CLUES 3/5" on a map with no clues in it is a counter that lies about what
	the player is doing.

	Written from here rather than decided on the client, because the client would
	have to work out which kind is armed to know which noun to use, and that is
	a fact this process already holds.
]]
local function setTracker(label: string, hint: string)
	Workspace:SetAttribute(GA.TrackerLabel, label)
	Workspace:SetAttribute(GA.TrackerHint, hint)
end

--[[
	Where the arrow points, or nothing.

	A Vector3 on Workspace rather than a remote, for the same reason every other
	team-wide fact here is an attribute: a survivor who joins late, dies and
	respawns, or alt-tabs back in gets the current answer for free, and a remote
	fired once would have missed all three of them.

	Nil clears it. Passing nil is how the round ending takes the arrow down, and
	it has to be an explicit call rather than a side effect of clearing the
	puzzle, because an arrow pointing at a room in a map that is no longer loaded
	is an arrow pointing into the skybox.
]]
local function setWaypoint(position: Vector3?, label: string?)
	Workspace:SetAttribute(GA.WaypointPosition, position)
	Workspace:SetAttribute(GA.WaypointLabel, if position then label or "" else "")
end

--[[ The middle of a model or part, whichever it turns out to be. `GetPivot` is
     right for both and is what the interaction system already uses, so an
     arrow and a prompt agree about where a thing is. ]]
local function centreOf(instance: Instance?): Vector3?
	if not instance then
		return nil
	end
	if instance:IsA("Model") or instance:IsA("BasePart") then
		local ok, pivot = pcall(function()
			return (instance :: any):GetPivot()
		end)
		if ok and typeof(pivot) == "CFrame" then
			return pivot.Position
		end
	end
	return nil
end

--[[
	Whether this player may work on a machine at all, and whether they are
	standing at THIS one.

	Both halves were missing, and the second one made a comment in Remotes.lua
	untrue: it says a crafted client "cannot power a generator out of turn, or
	from across the map", and only the first of those was actually enforced.
	Without a range test the whole objective collapses to five remote calls from
	the spawn point — which is not a cheat that beats the game so much as one
	that deletes the thing the objective IS, which is walking five legs of a map
	with a horde on you.

	The state test is the other half. A downed or dead player is not standing at
	a generator: they are on the floor with a pistol, or spectating, and the
	prompt they are answering is one their client should not still be drawing.

	Generous on distance rather than exact. GameConfig's interact range is what
	the prompt uses to decide the player can reach something, and a server that
	enforced the identical number would refuse honest presses on lag alone — the
	player was in range when they pressed and had drifted a stud by the time the
	packet landed. Double it: still nowhere near "from across the map", and it
	never argues with somebody who was actually there.
]]
local UPRIGHT_ONLY = table.freeze({
	[Enums.SurvivorState.Incapacitated] = true,
	[Enums.SurvivorState.LedgeHanging] = true,
	[Enums.SurvivorState.Pinned] = true,
	[Enums.SurvivorState.Dead] = true,
	[Enums.SurvivorState.Spectating] = true,
})

local REACH = GameConfig.Interaction.Range * 2

local function atMachine(player: Player, prop: Instance?): boolean
	if not prop or not prop.Parent then
		return false
	end

	local survivors = Registry.find("SurvivorService")
	if survivors and typeof(survivors.getState) == "function" then
		local ok, survivorState = pcall(survivors.getState, survivors, player)
		if ok and UPRIGHT_ONLY[survivorState] then
			return false
		end
	end

	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		--[[ No body, no reach. A player between characters cannot be standing at
		     anything, and letting a missing root mean "allowed" would make
		     respawning the way around the check. ]]
		return false
	end

	local at = centreOf(prop)
	return at ~= nil and (root.Position - at).Magnitude <= REACH
end

--[[ Something on a prop that a Sound can hang off. AudioService:playOn wants a
     BasePart and a designer's prop is as likely to be a Model, a Model wrapping
     one part, or a lone Part — all three answer here. ]]
local function speakerOf(instance: Instance?): BasePart?
	if not instance then
		return nil
	end
	if instance:IsA("BasePart") then
		return instance
	end
	return (instance :: any).PrimaryPart or instance:FindFirstChildWhichIsA("BasePart", true)
end

--[[
	A generator turning over, and the hum it settles into.

	Both at the machine rather than on the solver's screen, which is the entire
	point. Five generators across open streets is a job four people split up to
	do, and before this the only evidence a teammate had that the objective moved
	was a number changing on a card — the person who did it heard a menu confirm
	and nobody else heard anything at all.

	The start-up and the hum begin together rather than the hum waiting for the
	cough to finish. Chaining them off `Ended` would be tidier and would also mean
	no hum at all on any frame the voice budget refused the start-up, which is
	exactly the frame a horde is on top of somebody. A generator that hums as it
	turns over is right anyway.
]]
local function startRunning(model: Model)
	local audio = Registry.find("AudioService")
	local part = speakerOf(model)
	if not audio or typeof(audio.playOn) ~= "function" or not part then
		return
	end

	pcall(audio.playOn, audio, AudioConfig.Generator.Start, part)

	local ok, running = pcall(audio.playOn, audio, AudioConfig.Generator.Run, part)
	if ok and typeof(running) == "Instance" then
		runningTrove:add(running)
	end
end

-- ── the reward ──────────────────────────────────────────────────────────────

--[[
	Pays for the vault, once.

	Dollars through EconomyService, which is the currency the weapon shop spends
	and therefore the one that makes a vault worth opening. NOT Scrip: that is
	the progression currency and its config says in as many words that levelling
	and quests are its only sources.

	Split across everyone still in the round rather than paid per head, so four
	survivors each clear a real step and a solo player is not paid four times for
	the same puzzle. `award` clamps against the round's own earnings cap and can
	return less than asked — which is correct and is why nothing here checks that
	it got the full amount.
]]
local function payOut()
	local definition = state.definition
	if not definition then
		return
	end

	local survivors = Registry.find("SurvivorService")
	local roster = {}
	if survivors and typeof(survivors.getAliveSurvivors) == "function" then
		local ok, alive = pcall(survivors.getAliveSurvivors, survivors)
		if ok and typeof(alive) == "table" then
			roster = alive
		end
	end
	if #roster == 0 then
		roster = Players:GetPlayers()
	end

	local economy = Registry.find("EconomyService")
	if economy and typeof(economy.award) == "function" and #roster > 0 then
		local each = math.floor(definition.reward.dollars / #roster)
		for _, player in roster do
			pcall(economy.award, economy, player, each)
		end
	end

	--[[ And the shelves, which is what makes it a SUPPLY room rather than a cash
	     prize. The same restock a breather runs, so the vault stocks the map the
	     way the game already knows how rather than inventing a loot table. ]]
	if definition.reward.restockItems then
		local level = Registry.find("LevelService")
		if level and typeof(level.restockItems) == "function" then
			pcall(level.restockItems, level)
		end
	end
end

-- ── the doorways ────────────────────────────────────────────────────────────

--[[
	Makes a doorway usable, and says what its prompt reads.

	Separate from resolving it because the two halves happen at different
	moments: both doors are FOUND when the round arms, and only the way out is
	armed then. The way in is armed when the boards come off, because it is the
	reward and a doorway that worked while the door was still boarded would make
	the whole objective decorative.
]]
local function tagDoorway(entry: any)
	local door = entry.door
	if not door or not door.Parent then
		return
	end
	door:SetAttribute(PZ.DoorwayPrompt, entry.spec.prompt)
	CollectionService:AddTag(door, PuzzleConfig.DoorwayTag)
end

--[[
	Finds the doors that MOVE a player, and the parts they land on.

	Looked up inside the loot-room model when there is one and across the map
	when there is not — the same split the gate gets, and for the same reason: a
	map has any number of things that could answer to "Exit Door" and exactly two
	of them belong to this room.

	── WHY THE WAY OUT IS ARMED IMMEDIATELY ────────────────────────────────────
	Not symmetry. It is the rule that a player can never be shut inside a room:
	if the exit only existed once the objective completed, then any way into that
	room the designer did not intend — a Charger, a physics fluke, a future
	change to the map — would be a survivor stuck in a box until they died. The
	way out costs nothing to leave armed, because the only people who can reach
	it are already inside.
]]
local function resolveDoorways(definition: any, room: Instance?, root: Instance)
	local specs = definition.doorways
	if not specs then
		return
	end

	for _, spec in specs do
		local doorChild = if room then findWithin(room, spec.door) else findNamed(nil, root, spec.door)
		local targetChild = if room then findWithin(room, spec.target) else findNamed(nil, root, spec.target)
		local target = speakerOf(targetChild)
		if not doorChild or not target then
			--[[ A warning and no doorway, rather than a refusal to arm. A missing
			     exit door is a map mistake worth shouting about and it does not
			     make the fuse hunt unplayable — the boards still come off, the
			     room is still open, and the one thing that does not work is
			     named. ]]
			warn(
				string.format(
					"[PuzzleService] %s: could not resolve the doorway %q -> %q. That door will "
						.. "not move anybody this round.",
					tostring(definition.id),
					tostring(spec.door),
					tostring(spec.target)
				)
			)
			continue
		end

		local entry = { door = doorChild, target = target, spec = spec }
		table.insert(state.doorwayList, entry)
		state.doorways[doorChild] = target
		if not spec.sealed then
			tagDoorway(entry)
		end
	end
end

--[[ The sealed half, once the room is open. Called from openTheRoom beside
     armLoot, because they are the same moment and the same promise: nothing
     behind the boards is reachable until the boards are gone. ]]
local function armSealedDoorways()
	for _, entry in state.doorwayList do
		if entry.spec.sealed then
			tagDoorway(entry)
		end
	end
end

local function disarmDoorways()
	for _, entry in state.doorwayList do
		local door = entry.door
		if door and door.Parent then
			CollectionService:RemoveTag(door, PuzzleConfig.DoorwayTag)
			door:SetAttribute(PZ.DoorwayPrompt, nil)
		end
	end
end

--[[
	Puts a survivor on a part, somewhere else in the map.

	The only teleport inside a map in this game, and it copies SurvivorService's
	spawn move line for line, because that move took three goes to get right and
	every one of the failures is available here.

	Ownership is taken BEFORE the pivot, never after. An owning client that has
	already started simulating will not accept a server CFrame — it rubber-bands
	back and the player watches themselves fail to go through a door — and asking
	for the body back afterwards does not retroactively make the move land. It is
	handed straight back on a short timer, because a character the server is
	simulating is the laggiest a player in this game can feel.

	Where they land comes off the PART: the designer moves the room and nobody
	has to remember to move a number. Facing is the part's own look direction
	flattened, so somebody arriving in the loot room is looking into it rather
	than at whatever the part happened to be rotated towards in three dimensions.
]]
local function teleportTo(player: Player, target: BasePart)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not character or not root or not root:IsA("BasePart") then
		return false
	end

	local at = target.Position + Vector3.new(0, target.Size.Y / 2 + DOORWAY_RISE, 0)
	local look = target.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	--[[ A part rotated to face straight up or straight down has no flat facing,
	     and CFrame.lookAt with a zero direction throws. Whatever the designer
	     meant, the answer is not a crash inside a door. ]]
	if flat.Magnitude < 1e-3 then
		flat = Vector3.new(0, 0, -1)
	end

	--[[ Out of the seat first, if they are in one. A seated character is welded
	     to the seat, and PivotTo on a welded assembly either drags the turret
	     through the map or does nothing at all — neither of which is what a
	     player pressing a door expects. ]]
	local humanoid = character:FindFirstChildWhichIsA("Humanoid")
	if humanoid and humanoid.SeatPart then
		humanoid.Sit = false
		--[[ One frame for the weld to actually go. Jumping the character in the
		     same frame the seat is released moves a body that is still attached
		     to it. ]]
		task.wait()
		if not character.Parent or not root.Parent then
			return false
		end
	end

	pcall(function()
		root:SetNetworkOwner(nil)
	end)

	character:PivotTo(CFrame.lookAt(at, at + flat.Unit))
	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero

	task.delay(DOORWAY_OWNERSHIP_TIME, function()
		--[[ Not while it is anchored: SurvivorService anchors a body it is
		     holding and owns the release, and handing ownership back mid-hold
		     would return a held body to its client. ]]
		if root.Parent and not root.Anchored then
			pcall(function()
				root:SetNetworkOwnershipAuto()
			end)
		end
	end)
	return true
end

-- ── arming ──────────────────────────────────────────────────────────────────

--[[ Everything this service put into the world, taken back out. Called before
     every arm and at the end of every round, so a map is never left holding two
     rounds' documents or an open vault. ]]
function PuzzleService:clear()
	doorTrove:clean()
	runningTrove:clean()

	--[[ Through the same function that opened it, so there is one place that
	     knows what a closed door looks like. It used to be restored inline here
	     as well, which meant two copies of that answer and a `false` branch in
	     setDoorOpen nothing ever reached. ]]
	setDoorOpen(false)
	disarmLoot()
	--[[ And the doors stop moving anybody. A doorway left armed across a round
	     boundary is a teleport into a room in a map that may no longer be
	     loaded — the same failure the waypoint is taken down to avoid. ]]
	disarmDoorways()
	table.clear(state.doorLooks)

	--[[
		The paper goes blank as well as untagged.

		Removing the tag stops a prop being interactable and does nothing at all
		to what it SAYS, so a round ending used to leave four documents lying
		around the lobby still displaying the digits somebody earned. Harmless
		for the next round, which reprints them redacted — and not harmless at
		all if the next round has no puzzle, because then last round's answer
		sits legible on the wall until the server restarts.

		A generated surface is destroyed outright. One the designer supplied is
		emptied rather than destroyed: it is their instance, positioned against
		their geometry, and this only ever borrowed the text on it.
	]]
	for _, model in state.clues do
		if model.Parent then
			CollectionService:RemoveTag(model, PuzzleConfig.ClueTag)
			model:SetAttribute(PZ.ClueText, nil)
			model:SetAttribute(PZ.CluePrompt, nil)
			model:SetAttribute(PZ.ClueOrder, nil)
			model:SetAttribute(PZ.ClueFont, nil)
			for _, gui in model:GetDescendants() do
				if gui:IsA("SurfaceGui") and gui.Name == "FL_Clue" then
					gui:Destroy()
				elseif gui:IsA("TextLabel") and gui:FindFirstAncestorWhichIsA("SurfaceGui") then
					gui.Text = ""
				end
			end
		end
	end
	if state.keypad and state.keypad.Parent then
		CollectionService:RemoveTag(state.keypad, PuzzleConfig.KeypadTag)
	end

	--[[ And the machines. Untagged so nothing prompts on them, and their two
	     attributes wiped so the next round's arm cannot inherit an order or a
	     running light from this one — the same reason the clue props above are
	     blanked rather than merely untagged. ]]
	for _, model in state.generators do
		if model.Parent then
			CollectionService:RemoveTag(model, PuzzleConfig.GeneratorTag)
			model:SetAttribute(PZ.GeneratorOrder, nil)
			model:SetAttribute(PZ.GeneratorLive, nil)
			model:SetAttribute(PZ.CluePrompt, nil)
		end
	end

	--[[ And the boxes, which additionally have a NUMBER printed on them.

	     Destroyed rather than blanked, unlike a designer's own clue surface: this
	     one was made here and the next round makes its own. Leaving a green 3 on
	     a wall through a round with no puzzle in it would be last round's answer
	     sitting legible in the map until the server restarts — the same reason
	     the documents above go blank rather than merely quiet. ]]
	--[[ Indicators back to the colour and material they were built with, before
	     the models themselves are let go of. ]]
	for part, was in state.fuseLooks do
		if part.Parent then
			part.Color = was.color
			part.Material = was.material
		end
	end

	--[[ The beacons go out and hand their lamps back, before the models are let
	     go of. Same contract the fuse indicators have: OFF is the look the
	     designer built, and a map that is not reloaded between rounds would
	     otherwise keep this file's orange forever. ]]
	for part, was in state.beaconLooks do
		if part.Parent then
			part.Color = was.color
			part.Material = was.material
		end
	end

	local beaconSet = state.definition and state.definition.beacons
	for _, model in state.beacons do
		if model.Parent then
			CollectionService:RemoveTag(model, PuzzleConfig.BeaconTag)
			model:SetAttribute(PZ.BeaconOrder, nil)
			model:SetAttribute(PZ.BeaconLit, nil)
			model:SetAttribute(PZ.BeaconUntil, nil)
			model:SetAttribute(PZ.CluePrompt, nil)
			if beaconSet then
				setBeaconFire(model, beaconSet, false)
			end
		end
	end

	for _, model in state.fuses do
		if model.Parent then
			CollectionService:RemoveTag(model, PuzzleConfig.FuseTag)
			model:SetAttribute(PZ.FuseOrder, nil)
			model:SetAttribute(PZ.FuseLive, nil)
			model:SetAttribute(PZ.CluePrompt, nil)
			for _, gui in model:GetDescendants() do
				if gui:IsA("SurfaceGui") and gui.Name == "FL_Fuse" then
					gui:Destroy()
				end
			end
		end
	end

	state.definition = nil
	state.answer = ""
	state.values = nil
	state.found = 0
	state.solved = false
	state.keypad = nil
	state.door = nil
	state.weaponDrop = nil
	state.stockpile = nil
	state.stockpileClaimed = false
	state.gateRoom = nil
	table.clear(state.clues)
	table.clear(state.props)
	table.clear(state.clueOf)
	table.clear(state.generators)
	table.clear(state.generatorOf)
	table.clear(state.deals)
	table.clear(state.fuses)
	table.clear(state.fuseOf)
	table.clear(state.fuseLive)
	table.clear(state.fuseLooks)
	table.clear(state.beacons)
	table.clear(state.beaconOf)
	table.clear(state.beaconUntil)
	table.clear(state.beaconLooks)
	state.burn = 0
	table.clear(state.sequence)
	table.clear(warnedSurface)
	table.clear(state.clueSeen)
	table.clear(state.readBy)
	table.clear(state.doorways)
	table.clear(state.doorwayList)
	table.clear(attempts)

	Workspace:SetAttribute(GA.VaultPresent, false)
	Workspace:SetAttribute(GA.VaultSolved, false)
	Workspace:SetAttribute(GA.CluesFound, 0)
	Workspace:SetAttribute(GA.CluesTotal, 0)
	setTracker("", "")
	--[[ And the arrow comes down. A waypoint that outlived its round would point
	     at a room in a map that may no longer be loaded, which is an arrow into
	     the skybox on every screen until somebody solves something else. ]]
	setWaypoint(nil, nil)
end

--[[
	Finds what is actually IN the sealed room, for either kind.

	Shared, because "a weapon on the floor and a pile of cash" is the shape of
	both rewards and every hard-won line in it is about somebody else's model
	rather than about a puzzle: anchoring props that a stray pellet would
	otherwise shoot across the room, and putting back a loot weapon a previous
	round consumed on a map that was never reloaded.

	Found here, ARMED later. Both live inside the room the door seals, so
	resolving them at arm costs nothing and means the moment it opens is a
	couple of attribute writes rather than a search.
]]
local function resolveLoot(definition: any, folder: Instance?, root: Instance)
	local loot = definition.loot
	state.weaponDrop = if loot and loot.weapon then findNamed(folder, root, loot.weapon.object) else nil

	--[[ Kept, or put back. See weaponStash: the pickup destroys the model, and a
	     map that is not reloaded between rounds never brings it back on its
	     own. ]]
	if loot and loot.weapon then
		local stashed = weaponStash[definition.id]
		if state.weaponDrop then
			if not stashed and state.weaponDrop:IsA("Model") then
				weaponStash[definition.id] = {
					model = state.weaponDrop:Clone(),
					home = state.weaponDrop:GetPivot(),
				}
			end
		elseif stashed then
			local restored = stashed.model:Clone()
			restored:PivotTo(stashed.home)
			restored.Parent = folder or root
			state.weaponDrop = restored
			print(
				string.format(
					"[PuzzleService] restored %s's %s, which a previous round removed",
					definition.id,
					loot.weapon.object
				)
			)
		end
	end
	state.stockpile = if loot and loot.stockpile then findNamed(folder, root, loot.stockpile.object) else nil
	state.stockpileClaimed = false
	--[[ Both nailed down. Neither survives ten minutes of gunfire lying loose,
	     and an imported model is unanchored about half the time. ]]
	if state.stockpile then
		settle(state.stockpile, false)
	end
	if state.weaponDrop then
		--[[ Collision dropped as well, the way MapItemService does it for the same
		     reason: a weapon on the floor of a doorway should not be a thing the
		     team walks into. ]]
		settle(state.weaponDrop, true)
	end
end

--[[
	Finds, settles and registers the documents, for either kind that has them.

	Shared because it is the same job on both maps and every line of it is about
	somebody else's model rather than about a puzzle: wrapping a lone Part so
	everything downstream has a Model, anchoring paperwork that a stray pellet
	would otherwise shoot off a desk, and building the two lookups the rest of
	the file needs — `props`, so repaint can find the model for a clue, and
	`clueOf`, so the instance a player interacted with can be turned back into
	which clue it is.

	Nothing is PRINTED here. Every prop has to be in the maps before anything is
	painted, because a loop that painted as it went would print only the props it
	had already reached and leave the rest blank for the round.

	── AND THE ORDER ATTRIBUTE IS THE ONE DIFFERENCE ───────────────────────────
	Written only for the kind whose clues are a CHAIN. On Clinton the prompt
	dims a document you have already collected, which it works out from the
	prop's own order against the team's count — and on the Backrooms that same
	arithmetic would compare a document's position against the number of BOXES
	thrown, and start greying out clues nobody has read. A fact that only means
	something on one map is a fact only that map should publish.
]]
local function armClues(definition: any, folder: Instance?, root: Instance): number
	local ordered = PuzzleConfig.kindOf(definition) == PuzzleConfig.Kind.Investigation
	local painted = 0
	for _, clue in definition.clues do
		local child = findNamed(folder, root, clue.object)
		local model = child and asModel(child, child.Parent or root)
		if model then
			--[[ Anchored, collision left alone. A document has to still be on the
			     desk at wave twelve, and a room sign may be part of a wall. ]]
			settle(model, false)
			CollectionService:AddTag(model, PuzzleConfig.ClueTag)
			if ordered then
				model:SetAttribute(PZ.ClueOrder, clue.order)
			end
			table.insert(state.clues, model)
			state.props[clue.object] = model
			state.clueOf[model] = clue
			painted += 1
		else
			warn(string.format("[PuzzleService] no %q prop — that clue is missing this round", clue.object))
		end
	end
	return painted
end

--[[
	Clinton's shape: four documents, a keypad, and a code derived from the same
	values the documents are printed from.

	Returns false when the map cannot support it — a missing keypad, a template
	this build does not have, a code the pad could not accept. Every one of those
	is a config or a map mistake somebody would otherwise diagnose by playing ten
	minutes of a round that cannot end, so each says what it looked for.
]]
local function armInvestigation(definition: any, folder: Instance?, root: Instance, random: Random): boolean
	--[[
		One clue per digit, or nothing.

		A fifth clue with a four-digit code is a puzzle that cannot be finished:
		the template rolls four digits, the fifth clue's is nil, so its field
		stays redacted forever and the counter stalls at 4/5 with nothing left to
		find. Caught here because that is a config mistake somebody would
		otherwise diagnose by playing ten minutes of a round that cannot end.
	]]
	if #definition.clues ~= definition.digits then
		warn(
			string.format(
				"[PuzzleService] %s has %d clues but a %d-digit code — one clue per digit "
					.. "or the puzzle cannot be completed. Puzzle off.",
				definition.id,
				#definition.clues,
				definition.digits
			)
		)
		return false
	end

	local template = TEMPLATES[definition.template]
	if not template then
		warn(string.format("[PuzzleService] no template called %q", tostring(definition.template)))
		return false
	end

	local values = template.generate(random, definition)
	local answer = template.answer(values)
	--[[ Refused rather than shipped. A code that is not the length the keypad
	     accepts is a puzzle nobody can solve however well they read, and the one
	     failure mode a player would blame themselves for. ]]
	if #answer ~= definition.digits then
		warn(
			string.format(
				"[PuzzleService] %s generated a %d-digit answer but the keypad takes %d — puzzle off",
				definition.template,
				#answer,
				definition.digits
			)
		)
		return false
	end

	--[[ The keypad is the one prop the puzzle cannot do without: no keypad, no
	     way to answer, and four documents that lead nowhere is worse than no
	     puzzle at all. Everything else degrades; this refuses. ]]
	local keypadChild = findNamed(folder, root, definition.keypad)
	local keypad = keypadChild and asModel(keypadChild, keypadChild.Parent or root)
	if not keypad then
		warn(
			string.format(
				"[PuzzleService] no %q anywhere in %s — the vault puzzle is off for this round. "
					.. "The map's top-level folders are: %s",
				definition.keypad,
				tostring(definition.map),
				MapConfig.folderNamesIn(root)
			)
		)
		return false
	end

	--[[ Inside the keypad assembly and nowhere else — see findWithin for why a
	     map-wide search for "Door" is actively dangerous. Taken as it is rather
	     than wrapped: it is a single Part in the supplied assembly and wrapping
	     it would reparent somebody else's geometry for no gain, while partsOf
	     and GetPivot both handle either shape. ]]
	local door = findWithin(keypad, definition.door)
	if not door then
		warn(
			string.format(
				"[PuzzleService] found %q but no %q inside it — the code will be accepted "
					.. "and nothing will open. Put the door part inside the assembly.",
				definition.keypad,
				definition.door
			)
		)
	end

	resolveLoot(definition, folder, root)

	--[[
		Resolved into the maps FIRST, printed second.

		`repaint` reads state.props to find the model for a clue, so every prop
		has to be in there before anything is printed — a loop that painted as it
		went would print only the props it had already reached, and the ones after
		it would sit blank for the whole round.

		This is where the ordered collection actually lives: `clueOf` is what
		turns the instance a player interacted with back into "which clue is this
		and what number is it", and without it onCollect matches nothing and the
		counter never moves.
	]]
	local painted = armClues(definition, folder, root)

	state.definition = definition
	state.answer = answer
	state.values = values
	state.found = 0
	state.solved = false
	state.keypad = keypad
	state.door = door
	if door then
		for _, part in partsOf(door) do
			state.doorLooks[part] = part.Transparency
		end
	end

	keypad:SetAttribute(PZ.Digits, definition.digits)
	CollectionService:AddTag(keypad, PuzzleConfig.KeypadTag)

	Workspace:SetAttribute(GA.VaultPresent, true)
	Workspace:SetAttribute(GA.VaultSolved, false)
	Workspace:SetAttribute(GA.CluesFound, 0)
	Workspace:SetAttribute(GA.CluesTotal, #definition.clues)
	setTracker("CLUES", "SEARCH THE BUILDING")

	--[[ Printed only now that every prop is in the maps, and printed with the
	     count at zero — so all four documents are legible from the first second
	     of the round and all four digits are redacted. ]]
	repaint()

	print(
		string.format("[PuzzleService] %s armed with %d/%d clues", definition.id, painted, #definition.clues)
	)
	return true
end

--[[
	Zombieville's shape: five machines, and a gate that lifts when the last one
	turns over.

	── EVERY GENERATOR OR NONE ─────────────────────────────────────────────────
	A missing machine turns the whole objective off rather than running a short
	one. Four generators against a counter that needs five is a round where the
	gate can never open and the loot room is sealed for reasons nobody can see —
	which is strictly worse than a Zombieville with no side objective, because at
	least that one does not ask the team to walk it.

	So the failure is loud: it names the model it could not find and prints the
	map's top-level folders beside it, which between them are enough to fix a
	misnamed prop from the output alone.
]]
local function armGenerators(definition: any, folder: Instance?, root: Instance, random: Random): boolean
	local set = definition.generators
	local gate = definition.gate
	if not set or not gate then
		warn(
			string.format(
				"[PuzzleService] %s is kind %q but has no generators or gate block — puzzle off",
				tostring(definition.id),
				PuzzleConfig.Kind.Generators
			)
		)
		return false
	end

	--[[
		Which puzzle waits at which machine, rolled fresh for this round.

		This is the mix-up: the ROUTE never moves — generator 1 is always first,
		and that is what lets a team learn Zombieville — while the puzzle at the
		end of each leg is dealt from the pack every time. Same split the vault
		makes between props that stay put and documents that never repeat.
	]]
	local kinds = Pack.assign(random, set.count)

	for order = 1, set.count do
		local wanted = PuzzleConfig.generatorName(set, order)
		local child = findNamed(folder, root, wanted)
		local model = child and asModel(child, child.Parent or root)
		if not model then
			warn(
				string.format(
					"[PuzzleService] no %q anywhere in %s — the generator objective is off for "
						.. "this round. The map's top-level folders are: %s",
					wanted,
					tostring(definition.map),
					MapConfig.folderNamesIn(root)
				)
			)
			return false
		end

		local deal = Pack.deal(kinds[order], random)
		if not deal then
			warn(
				string.format(
					"[PuzzleService] no generator puzzle called %q — puzzle off",
					tostring(kinds[order])
				)
			)
			return false
		end

		--[[ Anchored, collision left alone. A generator is a large thing standing
		     in a street for ten minutes of gunfire, and an imported model is
		     unanchored about half the time — but it is also something a survivor
		     can take cover behind, so it keeps its collision. ]]
		settle(model, false)

		state.deals[order] = deal
		state.generators[order] = model
		state.generatorOf[model] = order

		--[[ The number goes on the PROP, so a prompt can read "GENERATOR 3"
		     without a round trip. It is not a secret: it is painted on the side of
		     the machine in the map, and finding them in that order is the whole
		     objective. ]]
		model:SetAttribute(PZ.GeneratorOrder, order)
		model:SetAttribute(PZ.GeneratorLive, false)
		model:SetAttribute(PZ.CluePrompt, string.format("%s %d", set.prompt, order))
		CollectionService:AddTag(model, PuzzleConfig.GeneratorTag)
	end

	--[[
		The room, then the gate INSIDE it.

		Same split the vault's door gets, and for the same reason: a map has any
		number of things that could answer to "Gate" and exactly one of them is in
		the loot room. Searching the whole map for the door would raise whichever
		one GetDescendants reached first, and lifting the wrong gate while the
		loot room stayed shut is a bug that looks like the objective being broken.
	]]
	local roomChild = findNamed(folder, root, gate.room)
	local room = roomChild and asModel(roomChild, roomChild.Parent or root)
	local door = if room then findWithin(room, gate.door) else nil
	if not room then
		warn(
			string.format(
				"[PuzzleService] no %q in %s — the generators will power and nothing will "
					.. "open. The map's top-level folders are: %s",
				gate.room,
				tostring(definition.map),
				MapConfig.folderNamesIn(root)
			)
		)
	elseif not door then
		warn(
			string.format(
				"[PuzzleService] found %q but no %q inside it — the generators will power "
					.. "and nothing will open. Put the gate inside the room model.",
				gate.room,
				gate.door
			)
		)
	end

	resolveLoot(definition, folder, root)

	state.definition = definition
	state.found = 0
	state.solved = false
	state.gateRoom = room
	state.door = door
	if door then
		for _, part in partsOf(door) do
			state.doorLooks[part] = part.Transparency
		end
	end

	Workspace:SetAttribute(GA.VaultPresent, true)
	Workspace:SetAttribute(GA.VaultSolved, false)
	Workspace:SetAttribute(GA.CluesFound, 0)
	Workspace:SetAttribute(GA.CluesTotal, set.count)
	setTracker("GENERATORS", "POWER THEM IN ORDER")

	print(
		string.format(
			"[PuzzleService] %s armed with %d generators — %s",
			definition.id,
			set.count,
			table.concat(kinds, ", ")
		)
	)
	return true
end

--[[
	The Backrooms' shape: four breaker boxes thrown in an order this round
	invented, and four documents that between them say what it is.

	── EVERY BOX OR NONE ───────────────────────────────────────────────────────
	Same rule the generators follow. Three boxes against a sequence of four is a
	round whose loot room can never open for reasons nobody can see, which is
	strictly worse than a Backrooms with no side objective — at least that one
	does not ask the team to walk it. So a missing box names itself and prints
	the map's top-level folders beside it, which between them are enough to fix a
	misnamed prop from the output alone.

	A missing DOCUMENT is survivable and is only warned about, by armClues. Three
	clues are enough to deduce the fourth position, and a puzzle that refused to
	arm because a note fell through the world would be a harsher rule than the
	one it is protecting.
]]
local function armFuses(definition: any, folder: Instance?, root: Instance, random: Random): boolean
	local set = definition.fuses
	local gate = definition.gate
	if not set or not gate or not definition.clues then
		warn(
			string.format(
				"[PuzzleService] %s is kind %q but has no fuses, gate or clues block — puzzle off",
				tostring(definition.id),
				PuzzleConfig.Kind.Fuses
			)
		)
		return false
	end

	local template = TEMPLATES[definition.template]
	if not template or typeof(template.order) ~= "function" then
		warn(
			string.format(
				"[PuzzleService] no fuse template called %q in this build — puzzle off",
				tostring(definition.template)
			)
		)
		return false
	end

	--[[ The values, and the order read back out of them. One roll, one source:
	     the documents below are printed from the same table, so there is no
	     second place the sequence is written down and therefore no way for a
	     clue to disagree with the boxes. See FuseSequence. ]]
	local values = template.generate(random, definition)
	local sequence = template.order(values)
	if #sequence ~= set.count then
		warn(
			string.format(
				"[PuzzleService] %s rolled a sequence of %d for %d boxes — puzzle off",
				tostring(definition.id),
				#sequence,
				set.count
			)
		)
		return false
	end

	for order = 1, set.count do
		local wanted = PuzzleConfig.fuseName(set, order)
		local child = findNamed(folder, root, wanted)
		local model = child and asModel(child, child.Parent or root)
		if not model then
			warn(
				string.format(
					"[PuzzleService] no %q anywhere in %s — the fuse hunt is off for this "
						.. "round. The map's top-level folders are: %s",
					wanted,
					tostring(definition.map),
					MapConfig.folderNamesIn(root)
				)
			)
			return false
		end

		--[[ Anchored, collision kept. A box bolted to a wall is part of the wall,
		     and turning its collision off would put a hole in the building. ]]
		settle(model, false)

		state.fuses[order] = model
		state.fuseOf[model] = order
		state.fuseLive[order] = false

		--[[ The box's identity, in three places that cannot disagree because one
		     line writes all three: the attribute a designer can bind a light to,
		     the words the interact prompt says, and the number markFuse prints on
		     the front. None of it is secret — a box a player cannot identify is a
		     clue they cannot act on. What IS secret is the ORDER, and that lives
		     in `sequence` and nowhere a client can reach. ]]
		model:SetAttribute(PZ.FuseOrder, order)
		model:SetAttribute(PZ.FuseLive, false)
		model:SetAttribute(PZ.CluePrompt, string.format("%s %d", set.prompt, order))
		CollectionService:AddTag(model, PuzzleConfig.FuseTag)
		markFuse(model, set, order, false)
	end

	--[[ The room, then the boards INSIDE it. Same split the vault's door and the
	     gate get: a map has many things that could answer to "Wooden Boards" and
	     exactly one of them is on the loot room's door. ]]
	local roomChild = findNamed(folder, root, gate.room)
	local room = roomChild and asModel(roomChild, roomChild.Parent or root)
	local door = if room then findWithin(room, gate.door) else nil
	if not room then
		warn(
			string.format(
				"[PuzzleService] no %q in %s — the boxes will throw and nothing will open. "
					.. "The map's top-level folders are: %s",
				gate.room,
				tostring(definition.map),
				MapConfig.folderNamesIn(root)
			)
		)
	elseif not door then
		warn(
			string.format(
				"[PuzzleService] found %q but no %q inside it — the boxes will throw and "
					.. "nothing will open. Put the boards inside the room model.",
				gate.room,
				gate.door
			)
		)
	end

	resolveLoot(definition, folder, root)
	resolveDoorways(definition, room, root)

	state.definition = definition
	state.values = values
	state.answer = template.answer(values)
	state.sequence = sequence
	state.found = 0
	state.solved = false
	state.gateRoom = room
	state.door = door
	if door then
		for _, part in partsOf(door) do
			state.doorLooks[part] = part.Transparency
		end
	end

	local painted = armClues(definition, folder, root)

	Workspace:SetAttribute(GA.VaultPresent, true)
	Workspace:SetAttribute(GA.VaultSolved, false)
	Workspace:SetAttribute(GA.CluesFound, 0)
	Workspace:SetAttribute(GA.CluesTotal, set.count)
	--[[ The counter counts BOXES, not documents. Reading is how you find out
	     what to do and throwing is the doing, and a card that ticked up when
	     somebody read a note would be telling the team they had made progress
	     towards a door that had not moved. ]]
	setTracker("FUSES", "FIND THE SEQUENCE")

	--[[ Printed last, with every prop already in the maps — see armClues. Every
	     document is legible from the first second of the round; there is nothing
	     redacted on this map. ]]
	repaint()

	print(
		string.format(
			"[PuzzleService] %s armed with %d boxes and %d/%d clues",
			definition.id,
			set.count,
			painted,
			#definition.clues
		)
	)
	return true
end

--[[
	Crossroads' shape: four fires that will not stay lit.

	Nothing is generated here and there is no template, which makes this the
	shortest arming function in the file. The other three roll a code, an order or
	a sequence because KNOWING is their difficulty; this one's difficulty is a
	clock and the distance between four corners, and a team that has run it fifty
	times still has to run it.

	── EVERY BEACON OR NONE ────────────────────────────────────────────────────
	Same rule the generators and the fuse boxes follow, and it bites harder here
	than anywhere: three beacons against a gate that wants four is a round whose
	loot room can never open, and unlike a missing document there is nothing to
	deduce and no way for a player to tell. So a missing prop names itself and
	prints the map's top-level folders beside it.
]]
local function armBeacons(definition: any, folder: Instance?, root: Instance): boolean
	local set = definition.beacons
	local gate = definition.gate
	if not set or not gate then
		warn(
			string.format(
				"[PuzzleService] %s is kind %q but has no beacons or gate block — puzzle off",
				tostring(definition.id),
				PuzzleConfig.Kind.Beacons
			)
		)
		return false
	end

	for order = 1, set.count do
		local wanted = PuzzleConfig.beaconName(set, order)
		local child = findNamed(folder, root, wanted)
		local model = child and asModel(child, child.Parent or root)
		if not model then
			warn(
				string.format(
					"[PuzzleService] no %q anywhere in %s — the beacon objective is off for "
						.. "this round. The map's top-level folders are: %s",
					wanted,
					tostring(definition.map),
					MapConfig.folderNamesIn(root)
				)
			)
			return false
		end

		--[[ Anchored, collision kept. A beacon on a hilltop is something a
		     survivor can put their back to, and one that had lost its collision
		     would be a hole in the cover on the one map made of open ground. ]]
		settle(model, false)

		state.beacons[order] = model
		state.beaconOf[model] = order
		state.beaconUntil[order] = 0

		model:SetAttribute(PZ.BeaconOrder, order)
		model:SetAttribute(PZ.BeaconLit, false)
		model:SetAttribute(PZ.BeaconUntil, 0)
		model:SetAttribute(PZ.CluePrompt, string.format("%s %d", set.prompt, order))
		CollectionService:AddTag(model, PuzzleConfig.BeaconTag)
		setBeaconFire(model, set, false)
	end

	--[[ The room, then the gate INSIDE it. Same split every sealed room in this
	     file gets: a map has any number of things that could answer to "Gate" and
	     exactly one of them is in the loot room. ]]
	local roomChild = findNamed(folder, root, gate.room)
	local room = roomChild and asModel(roomChild, roomChild.Parent or root)
	local door = if room then findWithin(room, gate.door) else nil
	if not room then
		warn(
			string.format(
				"[PuzzleService] no %q in %s — the beacons will light and nothing will open. "
					.. "The map's top-level folders are: %s",
				gate.room,
				tostring(definition.map),
				MapConfig.folderNamesIn(root)
			)
		)
	elseif not door then
		warn(
			string.format(
				"[PuzzleService] found %q but no %q inside it — the beacons will light and "
					.. "nothing will open. Put the gate inside the room model.",
				gate.room,
				gate.door
			)
		)
	end

	resolveLoot(definition, folder, root)

	state.definition = definition
	state.found = 0
	state.solved = false
	state.gateRoom = room
	state.door = door
	if door then
		for _, part in partsOf(door) do
			state.doorLooks[part] = part.Transparency
		end
	end

	--[[
		This round's window, taken ONCE.

		Read live it would be a fire that got longer when somebody joined and
		shorter when somebody left — including mid-run, which on an objective
		whose whole content is a clock is the one thing that must not move. The
		crew that starts the round owns the difficulty of it.
	]]
	--[[
		Counted off the SERVER, not off the survivors.

		`arm` runs when the round state reaches Starting, which is before bodies
		exist — getAliveSurvivors is empty at that moment, so reading it here
		would hand a full team of four the fifty-second solo window every single
		round. Nothing about that would look broken; the objective would just be
		free, and the one number the whole puzzle is made of would silently be
		the wrong one.

		Everybody connected when a round starts is in that round, so the player
		list is the honest measure. beaconBurn clamps it, so a fifth watching from
		the lobby cannot shrink the window below what four were tuned against.
	]]
	local crew = math.max(#Players:GetPlayers(), 1)
	state.burn = PuzzleConfig.beaconBurn(set, crew)

	Workspace:SetAttribute(GA.VaultPresent, true)
	Workspace:SetAttribute(GA.VaultSolved, false)
	Workspace:SetAttribute(GA.CluesFound, 0)
	Workspace:SetAttribute(GA.CluesTotal, set.count)
	--[[ The instruction is the whole puzzle and it fits on one line, which is
	     rarer than it sounds: nothing about this objective has to be explained
	     twice. ]]
	setTracker("BEACONS", "LIGHT ALL FOUR AT ONCE")

	print(
		string.format(
			"[PuzzleService] %s armed with %d beacons, %ds burn for a crew of %d",
			definition.id,
			set.count,
			math.floor(state.burn),
			crew
		)
	)
	return true
end

--[[
	Rolls a fresh puzzle into the live map.

	Called from the round starting rather than from the map loading — see the
	header. Returns false when there is nothing to arm, which is the NORMAL
	answer on most of the roster — two maps of the four have one authored — and
	must never be an error.

	Everything down to the folder is shared; the KIND picks which half runs from
	there. A half that refuses leaves nothing behind, because `clear` runs on
	both the way in and the way out.
]]
function PuzzleService:arm(random: Random?)
	self:clear()

	if not PuzzleConfig.Enabled then
		return false
	end

	local mapService = Registry.find("MapService")
	local mapId = mapService and typeof(mapService.getCurrentId) == "function" and mapService:getCurrentId()
	local definition = PuzzleConfig.forMap(mapId)
	if not definition then
		return false
	end

	local root = mapService and mapService:getCurrentRoot()
	if not root then
		return false
	end

	--[[ Optional. A tidy map keeps its props together and this narrows the
	     search; an untidy one is searched whole. See findNamed. ]]
	local folder = findPuzzleFolder(root)

	local rng = random or Random.new()
	local kind = PuzzleConfig.kindOf(definition)
	local armed
	if kind == PuzzleConfig.Kind.Generators then
		armed = armGenerators(definition, folder, root, rng)
	elseif kind == PuzzleConfig.Kind.Fuses then
		armed = armFuses(definition, folder, root, rng)
	elseif kind == PuzzleConfig.Kind.Beacons then
		--[[ No Random. Nothing about this objective is rolled — see armBeacons,
		     and see the Kind's own note for why that is the design rather than a
		     gap. ]]
		armed = armBeacons(definition, folder, root)
	else
		armed = armInvestigation(definition, folder, root, rng)
	end

	--[[ A refusal that had already tagged three of five machines would leave a
	     map holding half an objective, so a failed arm is cleared rather than
	     merely returned from. Cheap, and it is the only way `state` can be relied
	     on to mean "there is a puzzle running". ]]
	if not armed then
		self:clear()
		return false
	end
	return true
end
-- ── opening the room ────────────────────────────────────────────────────────

--[[
	The moment the lock lets go, for either kind.

	One function, because everything in it is the same job: the door goes, the
	contents become interactable, the team is paid, the building answers, and
	everybody is told. What differs between a vault and a loot room is the
	SENTENCE, and that is the argument.

	Shared rather than copied because the parts of it that are easy to get wrong
	are the parts neither kind should have to get right twice — arming the loot
	only after the door opens, so a reward reachable through a wall is not a
	reward the puzzle was optional for; and paying through EconomyService's own
	cap rather than inventing a payout.
]]
local function openTheRoom(player: Player, line: string)
	state.solved = true
	Workspace:SetAttribute(GA.VaultSolved, true)

	setDoorOpen(true)
	armLoot()
	--[[ And the way in, on the map where the loot room is somewhere else
	     entirely. Beside armLoot because it is the same promise: nothing behind
	     the boards is reachable until the boards are gone. ]]
	armSealedDoorways()
	payOut()

	--[[ Where the room IS, by the best answer available. The door first, because
	     that is the thing that just moved and the thing a player walks to; then
	     the room around it, which on Zombieville is a whole building and a fine
	     target; then the keypad, which on Clinton is the door's own assembly. ]]
	local at = centreOf(state.door) or centreOf(state.gateRoom) or centreOf(state.keypad)

	--[[
		And then they hear it.

		Opening the room is loud, and the map has been listening. This is
		DirectorService's own crescendo — the same three waves a panic trigger
		fires — so the horde that answers is the horde the game already knows how
		to throw, spawned around the ROOM rather than around the team.

		Around the room is the deliberate half. On Clinton the team is standing at
		the door and the horde arrives on top of them; on Zombieville they are at
		generator five and the horde is waiting between them and the prize. Both
		are the same rule — the reward is guarded from the moment it exists — and
		it is what stops a supply room being a vending machine.
	]]
	local director = Registry.find("DirectorService")
	if director and typeof(director.triggerPanicEvent) == "function" and at then
		pcall(director.triggerPanicEvent, director, at)
	end

	--[[ Announced to the whole server, not just whoever finished it. Somebody
	     found the badge and somebody else found the sign; somebody powered the
	     first generator and somebody else powered the fifth. The room opening is
	     the moment all of them were working towards, and a team that hears about
	     it only from the person who happened to be standing there has been told
	     the wrong story about what they just did.

	     The LINE comes from here rather than from the client, because the client
	     would have to work out which kind is armed to know which sentence to
	     say. ]]
	Remotes.Event.VaultOpened:FireAllClients({
		player = player,
		position = at,
		line = line,
	})

	--[[
		On the DOOR, so the whole team hears where the lock let go rather than
		getting a click in their ear.

		The door first and the room second, which is the other way round from how
		this used to pick: the door is the thing that just moved, and a loot room
		can be a whole building whose centre is nowhere near the way in.

		The generator kind gets a gate rolling up; the vault keeps its confirm.
		That split is only because the sound was sourced for the loot room — the
		vault door would be better served by the same shutter, and that is a
		one-line change whenever somebody decides it.
	]]
	local speaker = speakerOf(state.door) or speakerOf(state.gateRoom) or speakerOf(state.keypad)
	--[[ Anything that is a thing in a doorway gets the shutter; only the vault,
	     whose door is a keypad assembly, keeps the confirm. Boards being pulled
	     off a door are far closer to a gate rolling up than to a menu tick. ]]
	local opened = if PuzzleConfig.kindOf(state.definition) == PuzzleConfig.Kind.Investigation
		then AudioConfig.UI.MenuConfirm
		else AudioConfig.Generator.Gate
	local audio = Registry.find("AudioService")
	if audio and typeof(audio.playOn) == "function" and speaker then
		pcall(audio.playOn, audio, opened, speaker)
	end
end

-- ── the gate ────────────────────────────────────────────────────────────────

--[[
	A submitted code.

	Every branch refuses or accepts HERE. The rate limit is checked before
	anything touches the world, the way every other remote handler in this game
	orders it: an unthrottled handler that answers with FireClient is an
	outbound amplifier, and this one answers on every path by design.
]]
local function onSubmit(player: Player, payload: any)
	if typeof(payload) ~= "table" then
		return
	end
	--[[
		The keypad remotes only answer on a map that HAS a keypad.

		Not defensive tidying. A crafted client can fire SubmitVaultCode on
		Zombieville, where the armed definition is the generator kind and has no
		`attemptCooldown` and no `digits` — and the throttle two lines below
		compares a number against that nil, which is a runtime error inside a
		handler anybody in the server can reach.

		The generator handlers ask the same question through generatorsArmed, for
		the same reason and in the same shape.
	]]
	if not state.definition or PuzzleConfig.kindOf(state.definition) ~= PuzzleConfig.Kind.Investigation then
		return
	end

	local entry = record(player)
	local now = serverNow()

	if now < entry.lockedUntil then
		reply(player, false, "KEYPAD LOCKED", entry.lockedUntil)
		return
	end
	if now - entry.typedAt < state.definition.attemptCooldown then
		reply(player, false, "WAIT", entry.typedAt + state.definition.attemptCooldown)
		return
	end
	entry.typedAt = now

	--[[
		And you have to be standing at the pad.

		This was the one handler in the file that never asked. Every other one
		does — collecting a clue, claiming the stockpile, opening a generator,
		answering one, throwing a fuse, using a doorway — and Remotes.lua says of
		the generators that a crafted client "cannot power a generator out of
		turn, or from across the map". The keypad was the counter-example: the
		panel only OPENS from a prompt that needs range, but the submit is its
		own remote and nothing stopped one arriving from the spawn point.

		What that bought an exploiter was not the loot, which is inside the room
		either way. It was `payOut` — the vault's three thousand dollars, split
		across the whole team, for a door nobody walked to. The clues still have
		to be read at arm's length, so this closes the last leg of the walk
		rather than the puzzle.

		Answered rather than dropped, unlike the generators' silent refusal, and
		the difference is the screen: a generator press with no reply is a press
		that did nothing, while the keypad panel is sat open waiting for one and
		would hang. The reach is already doubled against lag, so an honest player
		standing at the pad never sees this.
	]]
	if not atMachine(player, state.keypad) then
		reply(player, false, "STEP UP TO THE PANEL", 0)
		return
	end

	if state.solved then
		reply(player, true, "ALREADY OPEN", 0)
		return
	end

	--[[ Shape first, and shape is all a client may choose. The code that arrives
	     is compared against the one string this file holds; there is no number
	     here a client could have supplied that means anything else. ]]
	local code = payload.code
	if typeof(code) ~= "string" or #code ~= state.definition.digits or string.match(code, "^%d+$") == nil then
		reply(player, false, "ACCESS DENIED", now + state.definition.attemptCooldown)
		return
	end

	if code ~= state.answer then
		entry.wrong += 1
		if entry.wrong >= state.definition.lockoutAfter then
			--[[ Guessing has to be slower than reading. Ten thousand codes at one
			     a second beats a round; ten thousand at one per twenty-five seconds
			     does not, and a team that actually read the documents never reaches
			     this branch. ]]
			entry.wrong = 0
			entry.lockedUntil = now + state.definition.lockoutSeconds
			reply(player, false, "KEYPAD LOCKED", entry.lockedUntil)
			return
		end
		reply(player, false, "ACCESS DENIED", now + state.definition.attemptCooldown)
		return
	end

	--[[ And the counter card goes. The vault opening genuinely ENDS this
	     objective — there is nothing left to count and nowhere left to go, the
	     room is the one you are standing at — whereas the generator kind clears
	     five machines and then still has to walk somewhere, and keeps its card up
	     saying so. See refreshTracker on the client: an empty label is what takes
	     the card down. ]]
	setTracker("", "")
	openTheRoom(player, "The vault is open. Take what you need.")
	reply(player, true, "ACCESS GRANTED", 0)
end

--[[
	A player picking a clue up.

	Ordered, and the order is the whole hunt: clue three is refused until clue
	two is in, and the refusal names the one they are missing rather than saying
	no. A player standing over the note with three clues left to find should be
	told "COLLECT THE FIRST CLUE" — "denied" would read as the prop being broken.

	Team-wide. Four survivors are working one objective; a counter that started
	again for whoever walked in second would be four separate puzzles in one
	building, and the player who found the badge would have nothing to tell
	anybody.
]]
local function onCollect(player: Player, target: any)
	if typeof(target) ~= "Instance" or not state.definition then
		return
	end
	--[[ Same guard the keypad carries. Nothing below reaches `definition.clues`
	     before the clueOf lookup would already have refused a generator map — but
	     the two remotes are a pair and a reader should not have to prove that
	     about one of them. ]]
	local kind = PuzzleConfig.kindOf(state.definition)
	if kind == PuzzleConfig.Kind.Generators then
		return
	end

	local entry = record(player)
	local now = serverNow()
	--[[ The rate check first, before anything touches the world — every branch
	     below answers with a FireClient, and an unthrottled handler that answers
	     is an outbound amplifier. ]]
	if now - entry.tookAt < COLLECT_INTERVAL then
		return
	end

	local clue = state.clueOf[target]
	if not clue then
		--[[ Not one of ours. Stamped nothing, because a player looking at a
		     lamppost should not be spending the budget that lets them pick up the
		     clipboard a tenth of a second later. ]]
		return
	end
	entry.tookAt = now

	--[[ And you have to be standing at it, alive. The vault's objective is a
	     walk around a building exactly as much as the generators' is a walk
	     around a map, and a clue chain answerable from the spawn point is four
	     remote calls rather than a search. Same helper, same reach. ]]
	if not atMachine(player, target) then
		return
	end

	--[[
		The Backrooms' documents are not a chain.

		Everything below this is the vault's ordering — collect the clipboard
		before the sign, refuse the note until the badge is in — and every line of
		it is wrong here. Those four are spread through a maze with no landmarks
		and no route a player can learn, so "find the second one first" is an
		instruction to wander, and the digits are not hidden anyway: there is
		nothing to reveal because everything is legible the moment you are stood
		in front of it.

		So a read is a read. It opens the page, it never refuses, and it never
		moves the counter — because the counter on this map is the BOXES, and a
		card that ticked up when somebody read a note would be telling the team
		they had made progress towards a door that has not moved.

		What it does do is tell everybody ONCE. Four documents in a maze is a job
		a team splits up to do, and the other three need to know a note exists and
		that somebody has it — the reader can say what it said.
	]]
	if kind == PuzzleConfig.Kind.Fuses then
		local mine = state.readBy[player]
		if not mine then
			mine = {}
			state.readBy[player] = mine
		end
		local first = mine[clue.order] ~= true
		mine[clue.order] = true

		Remotes.Event.ClueResult:FireClient(player, {
			ok = true,
			order = clue.order,
			found = state.found,
			total = #state.definition.clues,
			text = target:GetAttribute(PZ.ClueText),
			headline = clue.prompt,
			--[[ The face it was printed in travels with it, so the reader opens a
			     wall scrawl as a scrawl rather than retyping somebody's wall in
			     Courier. One setting in the config, rendered twice. ]]
			font = clue.font,
			ink = clue.ink,
			--[[ Only the confirm sound rides on this. A page re-opened is the same
			     page and should not chime a second time. ]]
			repeated = not first,
		})

		if first and state.clueSeen[clue.order] ~= true then
			state.clueSeen[clue.order] = true
			local seen = 0
			for _ in state.clueSeen do
				seen += 1
			end
			--[[ Counted in DOCUMENTS, which is the only number this event has
			     ever been about. It does not touch GA.CluesFound and the card on
			     everybody's screen keeps reading the boxes. ]]
			Remotes.Event.ClueFound:FireAllClients({
				player = player,
				order = clue.order,
				found = seen,
				total = #state.definition.clues,
				prompt = clue.prompt,
			})
		end
		return
	end

	--[[ Already in. Silent rather than refused: walking back past a clipboard
	     you have read is not a mistake and does not deserve a message. ]]
	if clue.order <= state.found then
		Remotes.Event.ClueResult:FireClient(player, {
			ok = true,
			order = clue.order,
			found = state.found,
			total = #state.definition.clues,
			text = target:GetAttribute(PZ.ClueText),
			font = clue.font,
			ink = clue.ink,
			--[[ Named, so re-reading the badge opens a page headed SECURITY BADGE
			     rather than DOCUMENT. It is the same page either way; only the
			     first read gets the "you just found this" line. ]]
			headline = clue.prompt,
			repeated = true,
		})
		return
	end

	local wanted = state.found + 1
	if clue.order ~= wanted then
		local missing = PuzzleConfig.clueAt(state.definition, wanted)
		Remotes.Event.ClueResult:FireClient(player, {
			ok = false,
			order = clue.order,
			found = state.found,
			total = #state.definition.clues,
			reason = string.format(
				"COLLECT THE %s CLUE FIRST\n%s",
				PuzzleConfig.ordinal(wanted),
				if missing then missing.prompt else ""
			),
		})
		return
	end

	--[[ Counted, then re-printed. The digit on THIS prop appears at the same
	     moment the counter moves, because they are the same event: the team now
	     holds a number it did not hold a frame ago. ]]
	state.found = wanted
	Workspace:SetAttribute(GA.CluesFound, state.found)
	--[[ And what the card says about it. The last clue changes the instruction
	     from "search" to "go to the door", which is the one moment in the hunt
	     where the counter has something new to tell the team. ]]
	if state.found >= #state.definition.clues then
		setTracker("CLUES", "HEAD TO THE CODE DOOR AT KFC")
	end
	repaint()

	local template = TEMPLATES[state.definition.template]
	Remotes.Event.ClueResult:FireClient(player, {
		ok = true,
		order = clue.order,
		found = state.found,
		total = #state.definition.clues,
		text = target:GetAttribute(PZ.ClueText),
		font = clue.font,
		ink = clue.ink,
		headline = if template and typeof(template.prompt) == "function"
			then template.prompt(clue, state.values)
			else clue.found,
	})

	--[[ Announced to everyone. One player is holding the badge; the other three
	     need to know the counter moved and who moved it, because the next clue
	     is somewhere none of them have been. ]]
	Remotes.Event.ClueFound:FireAllClients({
		player = player,
		order = clue.order,
		found = state.found,
		total = #state.definition.clues,
		prompt = clue.prompt,
	})
end

--[[
	The cash pile, claimed once for everybody.

	One interaction pays the whole team and then the pile is spent — not "once
	per player", which would make the reward scale with headcount and make the
	last person to arrive the most valuable. Four survivors solved this together
	and they are paid together.

	Guarded on the tag rather than on the model, so a claim aimed at anything
	else in the room is simply not this.
]]
local function onStockpile(player: Player, target: any)
	if typeof(target) ~= "Instance" or not state.definition then
		return
	end
	local loot = state.definition.loot
	if not loot or not loot.stockpile then
		return
	end

	local entry = record(player)
	local now = serverNow()
	if now - entry.tookAt < COLLECT_INTERVAL then
		return
	end
	if target ~= state.stockpile or not CollectionService:HasTag(target, PuzzleConfig.StockpileTag) then
		return
	end
	entry.tookAt = now

	--[[ Reached, not merely known about. This one pays the whole team at once,
	     so claiming it from outside the room would hand four players the reward
	     for a door nobody opened — and the tag it is guarded on goes up the
	     instant the room does, which is the moment the pile becomes worth
	     sending a packet at. ]]
	if not atMachine(player, target) then
		return
	end

	--[[ Untagged BEFORE anything is paid. Two players reaching it in the same
	     frame would otherwise both pass the check and the team would be paid
	     twice — the server is single-threaded, so removing the tag first is a
	     complete answer rather than a narrowing of the window. ]]
	if state.stockpileClaimed then
		return
	end
	state.stockpileClaimed = true
	CollectionService:RemoveTag(target, PuzzleConfig.StockpileTag)

	local economy = Registry.find("EconomyService")
	local survivors = Registry.find("SurvivorService")
	local roster = {}
	if survivors and typeof(survivors.getAliveSurvivors) == "function" then
		local ok, alive = pcall(survivors.getAliveSurvivors, survivors)
		if ok and typeof(alive) == "table" then
			roster = alive
		end
	end
	if #roster == 0 then
		roster = Players:GetPlayers()
	end

	if economy and typeof(economy.award) == "function" then
		for _, who in roster do
			--[[ Each. Not split: the pile is a fixed find and the team should not
			     be poorer for having four people in it. `award` clamps against
			     the round's own earnings cap and can return less, which is
			     correct and is why nothing here checks the total. ]]
			pcall(economy.award, economy, who, loot.stockpile.dollars)
		end
	end

	Remotes.Event.StockpileClaimed:FireAllClients({
		player = player,
		dollars = loot.stockpile.dollars,
	})
end

-- ── the generators ──────────────────────────────────────────────────────────

--[[ Whether the generator objective is the one running. Both kinds share every
     handler's rate limiter and none of their logic, so each one asks first —
     otherwise a crafted client on Clinton could walk the generator remotes into
     a definition that has no generators in it. ]]
local function generatorsArmed(): boolean
	return state.definition ~= nil and PuzzleConfig.kindOf(state.definition) == PuzzleConfig.Kind.Generators
end

--[[ How many there are this round. Off the definition rather than off the table
     of models, so a machine that was destroyed mid-round cannot quietly shorten
     the objective. ]]
local function generatorCount(): number
	local set = state.definition and state.definition.generators
	return if set then set.count else 0
end

--[[
	A player walking up to a machine and pressing interact.

	Answers with the PANEL to draw, or with the refusal that names the one they
	should be looking for. Nothing is granted here and nothing is checked — this
	is the server handing over a picture, and the picture is worth nothing until
	an answer comes back through onSubmitGenerator.

	The order is enforced HERE as well as on submit, and that is not redundant:
	refusing to open the panel is what makes the ordering readable, and refusing
	to accept the answer is what makes it true.
]]
local function onOpenGenerator(player: Player, target: any)
	if typeof(target) ~= "Instance" or not generatorsArmed() then
		return
	end

	local entry = record(player)
	local now = serverNow()
	--[[ The rate check first, before anything touches the world — every branch
	     below answers with a FireClient, and an unthrottled handler that answers
	     is an outbound amplifier. ]]
	if now - entry.tookAt < COLLECT_INTERVAL then
		return
	end

	local order = state.generatorOf[target]
	if not order then
		--[[ Not one of ours. Stamped nothing, because a player looking at a
		     lamppost should not be spending the budget that lets them open the
		     generator a tenth of a second later. ]]
		return
	end
	entry.tookAt = now

	--[[ Silent rather than refused: a request from somewhere this player cannot
	     be is not a mistake they made, it is a client that should not have sent
	     it, and answering one is how a rate-limited handler becomes an outbound
	     amplifier for whoever is sending them. ]]
	if not atMachine(player, state.generators[order]) then
		return
	end

	local total = generatorCount()

	--[[ Already running. Reachable even though a powered machine is untagged and
	     therefore prompts on nobody's screen: a client that had the prompt up
	     when somebody else finished it can still send one press. Answered rather
	     than dropped, because the player pressed a key and deserves to know
	     why nothing opened. ]]
	if order <= state.found then
		Remotes.Event.GeneratorPanel:FireClient(player, {
			ok = false,
			order = order,
			powered = state.found,
			total = total,
			reason = "This generator is already running.",
		})
		return
	end

	local wanted = state.found + 1
	if order ~= wanted then
		Remotes.Event.GeneratorPanel:FireClient(player, {
			ok = false,
			order = order,
			powered = state.found,
			total = total,
			--[[ Names the one they should be looking for rather than saying no.
			     The wording lives in PuzzleConfig, with the design. ]]
			reason = PuzzleConfig.wrongGenerator(wanted),
		})
		return
	end

	local deal = state.deals[order]
	if not deal then
		return
	end

	Remotes.Event.GeneratorPanel:FireClient(player, {
		ok = true,
		--[[ The machine itself goes back down with the panel, so the answer that
		     comes up names it. The alternative — the client remembering which
		     prop it pressed — is a client deciding which generator its answer
		     applies to, and that is exactly the decision this handler exists to
		     make. ]]
		generator = target,
		order = order,
		powered = state.found,
		total = total,
		kind = deal.kind,
		--[[ The DRAWABLE half, and only that. `deal.solution` sits beside it in
		     this process and is not in this table — see the remote's own comment
		     for the whole of what that does and does not buy. ]]
		challenge = deal.challenge,
	})
end

--[[
	An answer coming back from a panel.

	Every branch refuses or accepts here, and the order is the same one every
	remote handler in this game uses: rate limit first, then identity, then the
	answer. A handler that reads a client's table before it has decided whether
	to talk to that client at all is a handler anybody can make work.
]]
local function onSubmitGenerator(player: Player, payload: any)
	if typeof(payload) ~= "table" or not generatorsArmed() then
		return
	end

	local entry = record(player)
	local now = serverNow()
	if now - entry.typedAt < GeneratorConfig.SubmitInterval then
		return
	end
	--[[ Separate stamps from the collect path, for the reason `attempts` gives:
	     opening a panel and answering one are throttled for different reasons and
	     at different rates, so pressing interact must not spend the budget that
	     lets the answer through a tenth of a second later. ]]
	entry.typedAt = now

	local total = generatorCount()

	if now < entry.lockedUntil then
		Remotes.Event.GeneratorResult:FireClient(player, {
			ok = false,
			powered = state.found,
			total = total,
			reason = "FAULT \226\128\148 WAIT",
			retryAt = entry.lockedUntil,
		})
		return
	end

	local target = payload.generator
	local order = if typeof(target) == "Instance" then state.generatorOf[target] else nil
	if not order then
		return
	end

	if not atMachine(player, state.generators[order]) then
		return
	end

	--[[ Checked again on the way in, not merely on the way out of the panel. A
	     client that kept a panel open while a teammate powered the machine in
	     front of it is holding an answer to a puzzle that is no longer the next
	     one, and the ordering is a server fact or it is not a fact. ]]
	if order ~= state.found + 1 then
		Remotes.Event.GeneratorResult:FireClient(player, {
			ok = false,
			order = order,
			powered = state.found,
			total = total,
			reason = if order <= state.found
				then "This generator is already running."
				else PuzzleConfig.wrongGenerator(state.found + 1),
			retryAt = 0,
		})
		return
	end

	--[[ The only door an answer comes through. Length first: a handler that
	     iterates whatever table it was handed is a handler anybody standing at a
	     machine can hang the round with. ]]
	local answer = Pack.sanitise(payload.answer)
	if not answer or not Pack.check(state.deals[order], answer) then
		--[[ A cooldown rather than a lockout. The horde is the punishment here —
		     a player who fumbles a wire panel is already losing the thing this
		     objective actually costs, which is time, and ejecting them from a
		     screen they are halfway through would be charging them twice. ]]
		entry.lockedUntil = now + GeneratorConfig.WrongCooldown
		Remotes.Event.GeneratorResult:FireClient(player, {
			ok = false,
			order = order,
			powered = state.found,
			total = total,
			reason = "FAULT \226\128\148 REALIGN AND RETRY",
			retryAt = entry.lockedUntil,
		})
		return
	end

	--[[ Powered. Counted first, so two players answering the same machine in the
	     same frame cannot both pass the order check above — the server is
	     single-threaded, so moving the counter before anything else is a complete
	     answer rather than a narrowing of the window. ]]
	state.found = order
	entry.lockedUntil = 0
	Workspace:SetAttribute(GA.CluesFound, state.found)

	local model = state.generators[order]
	if model and model.Parent then
		--[[ Untagged, so it stops offering a prompt at all — the same rule a
		     spent ammo crate follows, because offering a hold the server will
		     refuse is worse than offering nothing.

		     The attribute stays and turns true, because it is the machine's own
		     state rather than the prompt's: a designer who wants a light on the
		     side of a running generator has something to bind to. ]]
		CollectionService:RemoveTag(model, PuzzleConfig.GeneratorTag)
		model:SetAttribute(PZ.GeneratorLive, true)
		startRunning(model)
	end

	Remotes.Event.GeneratorResult:FireClient(player, {
		ok = true,
		order = order,
		powered = state.found,
		total = total,
		retryAt = 0,
	})

	--[[ And everybody is told. Five machines across open streets is a job four
	     people split up to do, and the counter moving is the only way the other
	     three learn that the next one is somewhere none of them have been. ]]
	Remotes.Event.GeneratorPowered:FireAllClients({
		player = player,
		order = order,
		powered = state.found,
		total = total,
	})

	if state.found < total then
		setTracker("GENERATORS", "POWER THEM IN ORDER")
		return
	end

	--[[
		All five. The gate goes, the room arms, the team is paid — and an ARROW
		goes up.

		The arrow is the half that matters on a map like this one. "Get to the
		loot room" is only useful to somebody who already knows where the loot
		room is, and on a first round nobody does; five generators is enough
		walking that a team can finish the objective from a corner of the map
		they have never been to. So the room is pointed AT, on everybody's screen,
		from wherever they are standing.
	]]
	setTracker("POWERED", "GET TO THE LOOT ROOM!")
	openTheRoom(player, "Get to the loot room!")

	local gate = state.definition.gate
	local at = centreOf(state.gateRoom) or centreOf(state.door)
	if at then
		setWaypoint(at, if gate then gate.label else "LOOT ROOM")
	end
end

-- ── throwing a fuse ─────────────────────────────────────────────────────────

local function fusesArmed(): boolean
	return state.definition ~= nil and PuzzleConfig.kindOf(state.definition) == PuzzleConfig.Kind.Fuses
end

--[[ How many boxes there are this round. Off the definition rather than off the
     table of models, so a box destroyed mid-round cannot quietly shorten the
     objective. ]]
local function fuseCount(): number
	local set = state.definition and state.definition.fuses
	return if set then set.count else 0
end

--[[
	A player throwing a breaker.

	The whole puzzle is decided here and nowhere else. The order is in
	`state.sequence`, which was read out of the same values the documents were
	printed from, and it has never been on a wire — so a crafted client can press
	every box in the map and learns the sequence exactly the way an honest team
	does, which is by walking to all of them.

	Every branch answers, because a box that silently ignores you is a box the
	player thinks is broken — and every branch is throttled BEFORE it answers,
	because a handler that replies on every path is an outbound amplifier for
	whoever is sending them.

	── WHAT A WRONG BOX COSTS ──────────────────────────────────────────────────
	A couple of seconds on that box, for that player. No damage, nothing broken,
	and above all no reset: the brief was explicit, and it is right, because this
	is played while the map is trying to kill you and an objective that punishes
	a guess punishes a guess made because a Charger was coming. See
	WRONG_FUSE_COOLDOWN, and PuzzleConfig.wrongFuse for why the refusal is
	careful never to name the box that WOULD have worked.
]]
local function onPullFuse(player: Player, target: any)
	if typeof(target) ~= "Instance" or not fusesArmed() then
		return
	end

	local entry = record(player)
	local now = serverNow()
	if now - entry.tookAt < COLLECT_INTERVAL then
		return
	end

	local order = state.fuseOf[target]
	if not order then
		--[[ Not one of ours. Stamped nothing, because a player looking at a wall
		     should not be spending the budget that lets them throw the box a
		     tenth of a second later. ]]
		return
	end
	entry.tookAt = now

	--[[ And you have to be standing at it, alive. A sequence answerable from the
	     spawn point is four remote calls rather than four walks across a maze,
	     which is not a cheat that beats the objective so much as one that deletes
	     what the objective IS. ]]
	if not atMachine(player, state.fuses[order]) then
		return
	end

	local total = fuseCount()

	--[[ Already thrown. Reachable even though a live box is untagged and prompts
	     on nobody's screen: a client that had the prompt up when somebody else
	     threw it can still send one press. ]]
	if state.fuseLive[order] then
		Remotes.Event.FuseResult:FireClient(player, {
			ok = false,
			order = order,
			thrown = state.found,
			total = total,
			reason = "This one is already live.",
			retryAt = 0,
		})
		return
	end

	if now < entry.lockedUntil then
		Remotes.Event.FuseResult:FireClient(player, {
			ok = false,
			order = order,
			thrown = state.found,
			total = total,
			reason = "The panel is still settling.",
			retryAt = entry.lockedUntil,
		})
		return
	end

	local wanted = state.sequence[state.found + 1]
	if order ~= wanted then
		entry.lockedUntil = now + WRONG_FUSE_COOLDOWN
		Remotes.Event.FuseResult:FireClient(player, {
			ok = false,
			order = order,
			thrown = state.found,
			total = total,
			--[[ Says that nothing happened and never which box would have. The
			     wording lives in PuzzleConfig, with the design, and the reason it
			     has to be careful is that this order is the secret the whole
			     puzzle is made of. ]]
			reason = PuzzleConfig.wrongFuse(chatter),
			retryAt = entry.lockedUntil,
		})
		return
	end

	--[[ Live. Counted first, so two players throwing in the same frame cannot
	     both pass the check above — the server is single-threaded, so moving the
	     counter before anything else is a complete answer rather than a narrowing
	     of the window. ]]
	state.found += 1
	state.fuseLive[order] = true
	entry.lockedUntil = 0
	Workspace:SetAttribute(GA.CluesFound, state.found)

	local set = state.definition.fuses
	local model = state.fuses[order]
	if model and model.Parent then
		--[[ Untagged, so it stops offering a prompt at all — the same rule a
		     spent ammo crate follows, because offering a press the server will
		     refuse is worse than offering nothing. The attribute stays and turns
		     true, because it is the box's own state rather than the prompt's. ]]
		CollectionService:RemoveTag(model, PuzzleConfig.FuseTag)
		model:SetAttribute(PZ.FuseLive, true)
		markFuse(model, set, order, true)

		--[[ At the BOX, not on the thrower's screen. Four boxes in a maze is a
		     job a team splits up to do, and before this the only evidence a
		     teammate two corridors away had was a number changing on a card.

		     The turn-over only, and no hum after it. Five generators settling
		     into a drone is Zombieville coming alive; four of them in here would
		     be four drones over the one map whose ambience is the point of the
		     map. ]]
		local audio = Registry.find("AudioService")
		local speaker = speakerOf(model)
		if audio and typeof(audio.playOn) == "function" and speaker then
			pcall(audio.playOn, audio, AudioConfig.Generator.Start, speaker)
		end
	end

	Remotes.Event.FuseResult:FireClient(player, {
		ok = true,
		order = order,
		thrown = state.found,
		total = total,
		retryAt = 0,
	})

	Remotes.Event.FusePowered:FireAllClients({
		player = player,
		order = order,
		thrown = state.found,
		total = total,
	})

	if state.found < total then
		setTracker("FUSES", "FIND THE SEQUENCE")
		return
	end

	--[[
		All four. The boards come off, the room arms, the team is paid — and an
		ARROW goes up.

		The arrow matters more here than anywhere else in the game. "Get to the
		loot room" is only useful to somebody who knows where the loot room is,
		and this map is a maze of identical corridors specifically designed so
		that nobody does. A team can finish the sequence in a corner they have
		never been to, three turns from a door they have never seen.
	]]
	setTracker("POWER RESTORED", "GET TO THE LOOT ROOM!")
	openTheRoom(player, "Auxiliary power restored. Get to the loot room!")

	--[[
		The DOOR, and only then the room.

		The other way round from Zombieville, and it is not a preference. There
		the loot room is a building, its centre is inside it, and pointing at the
		building is pointing at the objective. Here `Backrooms Lootroom` is the
		model that holds the whole side objective — the boxes, the documents, both
		doors and the room itself — so its pivot is a centroid somewhere in the
		middle of all of that, which is a place nobody needs to go.

		What the team has to walk to is the door the boards just came off. That is
		`state.door`, it is one object, and it is where the arrow belongs.
	]]
	local gate = state.definition.gate
	local at = centreOf(state.door) or centreOf(state.gateRoom)
	if at then
		setWaypoint(at, if gate then gate.label else "LOOT ROOM")
	end
end

-- ── the beacons ─────────────────────────────────────────────────────────────

local function beaconsArmed(): boolean
	return state.definition ~= nil and PuzzleConfig.kindOf(state.definition) == PuzzleConfig.Kind.Beacons
end

local function beaconCount(): number
	local set = state.definition and state.definition.beacons
	return if set then set.count else 0
end

--[[
	How many are burning right now.

	Counted from the STAMPS rather than kept as a running total, and that is the
	one decision this objective's correctness rests on. A tally would have to be
	incremented when a fire is lit and decremented when it expires, and the two
	events do not happen in the same place — so a missed decrement anywhere leaves
	a gate that opens on three beacons and a bug nobody could reproduce. Four
	comparisons against a clock cannot drift.
]]
local function litCount(now: number): number
	local total = beaconCount()
	local lit = 0
	for order = 1, total do
		if (state.beaconUntil[order] or 0) > now then
			lit += 1
		end
	end
	return lit
end

--[[ Publishes the count to everybody's card. Skipped once the room is open: the
     fires burn down afterwards like any others, and a counter that fell back to
     zero behind a solved objective would be telling the team they had lost
     something they had already spent. ]]
local function publishLit(now: number)
	if state.solved then
		return
	end
	Workspace:SetAttribute(GA.CluesFound, litCount(now))
end

--[[ Puts out anything whose time is up. Driven from a Heartbeat rather than from
     a player's press, because going OUT is the one thing in this objective that
     happens when nobody is doing anything. ]]
local function stepBeacons(now: number)
	if not beaconsArmed() then
		return
	end
	local set = state.definition.beacons
	local changed = false

	for order = 1, beaconCount() do
		local until_ = state.beaconUntil[order] or 0
		if until_ > 0 and now >= until_ then
			state.beaconUntil[order] = 0
			changed = true
			local model = state.beacons[order]
			if model and model.Parent then
				model:SetAttribute(PZ.BeaconLit, false)
				model:SetAttribute(PZ.BeaconUntil, 0)
				setBeaconFire(model, set, false)
			end
		end
	end

	if changed then
		publishLit(now)
	end
end

--[[
	A player lighting one.

	The thinnest handler in the file, because there is nothing to check that is
	not physical: no order, no code, no answer. What the server owns is the CLOCK
	— when this fire goes out, and whether four of them happened to be burning at
	the same instant — and neither of those is a number a client could send.

	Re-lighting one that is already going is allowed and is not an oversight. A
	player who runs back to top up the first beacon while the fourth is still
	being walked to is playing the objective exactly as intended, and refusing
	that would make the puzzle harder in a way that reads as broken.
]]
local function onLightBeacon(player: Player, target: any)
	if typeof(target) ~= "Instance" or not beaconsArmed() then
		return
	end

	local entry = record(player)
	local now = serverNow()
	if now - entry.tookAt < COLLECT_INTERVAL then
		return
	end

	local order = state.beaconOf[target]
	if not order then
		--[[ Not one of ours. Stamped nothing, because looking at a tree should
		     not spend the budget that lights the beacon behind it. ]]
		return
	end
	entry.tookAt = now

	if not atMachine(player, state.beacons[order]) then
		return
	end

	local total = beaconCount()
	if state.solved then
		Remotes.Event.BeaconResult:FireClient(player, {
			ok = false,
			order = order,
			lit = total,
			total = total,
			reason = "The gate is already open.",
		})
		return
	end

	--[[ Lit, and the stamp is the state. Written to the prop as well as held
	     here, so a survivor across the field and one who joined thirty seconds
	     ago read the same fire. ]]
	local set = state.definition.beacons
	local until_ = now + state.burn
	state.beaconUntil[order] = until_

	local model = state.beacons[order]
	if model and model.Parent then
		model:SetAttribute(PZ.BeaconLit, true)
		model:SetAttribute(PZ.BeaconUntil, until_)
		setBeaconFire(model, set, true)

		local audio = Registry.find("AudioService")
		local speaker = speakerOf(model)
		if audio and typeof(audio.playOn) == "function" and speaker then
			pcall(audio.playOn, audio, AudioConfig.Generator.Start, speaker)
		end
	end

	local lit = litCount(now)
	publishLit(now)

	Remotes.Event.BeaconResult:FireClient(player, {
		ok = true,
		order = order,
		lit = lit,
		total = total,
		until_ = until_,
	})

	--[[ And everybody is told, which matters more here than on any other
	     objective. Four players spread across a map are making a timing decision
	     together, and the count moving is the only way three of them learn that
	     the fourth is in position. ]]
	Remotes.Event.BeaconLit:FireAllClients({
		player = player,
		order = order,
		lit = lit,
		total = total,
	})

	if lit < total then
		setTracker("BEACONS", "LIGHT ALL FOUR AT ONCE")
		return
	end

	--[[ All four, at the same instant. The gate goes, the room arms, the team is
	     paid, and the arrow goes up — which on a map this open is less about
	     finding the room than about telling four people who are standing in four
	     different corners that they can stop running. ]]
	setTracker("ALL LIT", "GET TO THE LOOT ROOM!")
	openTheRoom(player, "Crossroads access granted. Get to the loot room!")

	local gate = state.definition.gate
	local at = centreOf(state.door) or centreOf(state.gateRoom)
	if at then
		setWaypoint(at, if gate then gate.label else "LOOT ROOM")
	end
end

-- ── using a doorway ─────────────────────────────────────────────────────────

--[[
	A player stepping through a door that moves them.

	Deliberately thin. Nothing is granted, nothing is spent, and the only
	question is whether this player is standing at a door the server armed —
	which is the whole reason the tag is the gate rather than the config: the way
	IN is not tagged until the boards come off, so a client that fires this at
	`Exit Door 1` during wave one is aiming at an instance the server has not
	armed and is answered with nothing at all.

	Where they land is a part in the map. No position, CFrame or destination ever
	comes up from a client, so the worst a crafted one can do is use a door it is
	standing next to, which is what the door is for.
]]
local function onUseDoorway(player: Player, target: any)
	if typeof(target) ~= "Instance" or not state.definition then
		return
	end

	local landing = state.doorways[target]
	if not landing or not landing.Parent then
		return
	end
	--[[ Armed, not merely known. `doorways` holds both doors from the moment the
	     round starts so the way out can never be missing; the TAG is what says a
	     door may be used, and the sealed one does not get it until the room
	     opens. ]]
	if not CollectionService:HasTag(target, PuzzleConfig.DoorwayTag) then
		return
	end

	local entry = record(player)
	local now = serverNow()
	if now - entry.tookAt < COLLECT_INTERVAL then
		return
	end
	entry.tookAt = now

	if not atMachine(player, target) then
		return
	end

	teleportTo(player, landing)
end

-- ── lifecycle ───────────────────────────────────────────────────────────────

function PuzzleService:init() end

function PuzzleService:start()
	serviceTrove:connect(Remotes.Event.SubmitVaultCode.OnServerEvent, onSubmit)
	serviceTrove:connect(Remotes.Event.CollectClue.OnServerEvent, onCollect)
	serviceTrove:connect(Remotes.Event.ClaimStockpile.OnServerEvent, onStockpile)
	serviceTrove:connect(Remotes.Event.OpenGenerator.OnServerEvent, onOpenGenerator)
	serviceTrove:connect(Remotes.Event.SubmitGenerator.OnServerEvent, onSubmitGenerator)
	serviceTrove:connect(Remotes.Event.PullFuse.OnServerEvent, onPullFuse)
	serviceTrove:connect(Remotes.Event.UseDoorway.OnServerEvent, onUseDoorway)
	serviceTrove:connect(Remotes.Event.LightBeacon.OnServerEvent, onLightBeacon)

	--[[
		The only per-frame work this service does, and the only objective that
		needs any.

		Three of the four are answered entirely by a player pressing something:
		nothing about a code, an order or a sequence changes while everybody
		stands still. A beacon goes OUT on its own, so something has to be
		watching a clock — and it is guarded on the kind, so on the other three
		maps this costs one comparison a frame and nothing else.
	]]
	serviceTrove:connect(RunService.Heartbeat, function()
		stepBeacons(serverNow())
	end)

	serviceTrove:connect(Players.PlayerRemoving, function(player: Player)
		attempts[player] = nil
		--[[ And what they had read. Held per player only to decide whether a page
		     is news or a re-read, so it is worth nothing after they leave and
		     would otherwise keep a Player key alive for the life of the
		     server. ]]
		state.readBy[player] = nil
	end)

	--[[
		Armed when a round starts, and only then.

		Read off the round state attribute rather than a signal, because
		RoundService has no roundStarted one and the attribute reaching Starting
		is the same fact already published. The map is swapped before that point
		in startRound, so the props this looks for are the new map's.
	]]
	serviceTrove:connect(Workspace:GetAttributeChangedSignal(GA.RoundState), function()
		local round = Workspace:GetAttribute(GA.RoundState)
		if round == Enums.RoundState.Starting then
			self:arm()
		elseif round ~= PuzzleConfig.RunningState then
			self:clear()
		end
	end)

	local round = Registry.find("RoundService")
	if round and round.roundEnded then
		serviceTrove:add(round.roundEnded:connect(function()
			self:clear()
		end))
	end
end

function PuzzleService:destroy()
	for _, stashed in weaponStash do
		stashed.model:Destroy()
	end
	table.clear(weaponStash)
	serviceTrove:destroy()
	doorTrove:destroy()
	runningTrove:destroy()
	self:clear()
end

Registry.register("PuzzleService", PuzzleService)

return PuzzleService
