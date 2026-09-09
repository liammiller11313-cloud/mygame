--!nonstrict
--[[
	PuzzleService — the side objective, in both of the shapes it comes in.

	Clinton's is a VAULT: four documents left in a building, one keypad, and a
	code that exists nowhere except in this process. Zombieville's is a GRID:
	five generators walked in numerical order, each opening one of five
	mini-puzzles dealt fresh every round, and a loot room whose gate rolls up
	when the last one turns over.

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
	clearing are one implementation with two front ends. See PuzzleConfig.Kind.

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
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
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
}

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

-- ── painting the clues ──────────────────────────────────────────────────────

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
	local surface = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart", true)
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
	label.Font = Enum.Font.Code
	label.TextSize = clue.textSize
	label.TextColor3 = Color3.fromRGB(28, 26, 24)
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
	local painted = 0
	for _, clue in definition.clues do
		local child = findNamed(folder, root, clue.object)
		local model = child and asModel(child, child.Parent or root)
		if model then
			--[[ Anchored, collision left alone. A document has to still be on the
			     desk at wave twelve, and a room sign may be part of a wall. ]]
			settle(model, false)
			CollectionService:AddTag(model, PuzzleConfig.ClueTag)
			model:SetAttribute(PZ.ClueOrder, clue.order)
			table.insert(state.clues, model)
			state.props[clue.object] = model
			state.clueOf[model] = clue
			painted += 1
		else
			warn(string.format("[PuzzleService] no %q prop — that clue is missing this round", clue.object))
		end
	end

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
	local armed
	if PuzzleConfig.kindOf(definition) == PuzzleConfig.Kind.Generators then
		armed = armGenerators(definition, folder, root, rng)
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
	local opened = if PuzzleConfig.kindOf(state.definition) == PuzzleConfig.Kind.Generators
		then AudioConfig.Generator.Gate
		else AudioConfig.UI.MenuConfirm
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
	if PuzzleConfig.kindOf(state.definition) ~= PuzzleConfig.Kind.Investigation then
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

	--[[ Already in. Silent rather than refused: walking back past a clipboard
	     you have read is not a mistake and does not deserve a message. ]]
	if clue.order <= state.found then
		Remotes.Event.ClueResult:FireClient(player, {
			ok = true,
			order = clue.order,
			found = state.found,
			total = #state.definition.clues,
			text = target:GetAttribute(PZ.ClueText),
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

-- ── lifecycle ───────────────────────────────────────────────────────────────

function PuzzleService:init() end

function PuzzleService:start()
	serviceTrove:connect(Remotes.Event.SubmitVaultCode.OnServerEvent, onSubmit)
	serviceTrove:connect(Remotes.Event.CollectClue.OnServerEvent, onCollect)
	serviceTrove:connect(Remotes.Event.ClaimStockpile.OnServerEvent, onStockpile)
	serviceTrove:connect(Remotes.Event.OpenGenerator.OnServerEvent, onOpenGenerator)
	serviceTrove:connect(Remotes.Event.SubmitGenerator.OnServerEvent, onSubmitGenerator)

	serviceTrove:connect(Players.PlayerRemoving, function(player: Player)
		attempts[player] = nil
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
