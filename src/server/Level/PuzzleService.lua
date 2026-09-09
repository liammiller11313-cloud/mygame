--!nonstrict
--[[
	PuzzleService — the vault, the four documents, and the only copy of the code.

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

local PuzzleService = {}

local serviceTrove = Trove.new()
local doorTrove = Trove.new()

--[[
	A spare flamethrower, and why one is needed.

	InventoryService:pickup DESTROYS the world model — correct for a gun somebody
	dropped, and a problem for the one thing in the game that exists exactly
	once. MapService:ensure is a no-op when the team votes for the map already
	loaded, so a Clinton round followed by another Clinton round does not reload
	the map: the flamethrower was taken, the model is gone, and the vault of the
	second round is empty.

	So the first time one is seen it is cloned aside, with the place it was
	standing. Any later arm that cannot find one puts it back. Held out of the
	DataModel by a plain reference rather than parked in ServerStorage, because a
	template that is a descendant of nothing cannot be found by any of the tag
	sweeps or folder walks that would otherwise trip over it.
]]
local weaponStash: Model? = nil
local weaponHome: CFrame? = nil

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
	--[[ How many clues the TEAM has, 0 through 4. Team-wide rather than per
	     player because this is one objective four people are working on: a
	     counter that reset for whoever walked in second would be four separate
	     puzzles in one building. ]]
	found = 0,
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

	for _, part in partsOf(door) do
		part.CanCollide = not open
		part.CanQuery = not open
		--[[ Faded to 0.85 rather than to 1. A doorway with nothing in it reads as
		     a hole in the building; a ghost of a door reads as a door somebody
		     opened, and it keeps the frame legible from across the room. ]]
		local target = if open then math.max(part.Transparency, 0.85) else state.doorLooks[part] or 0
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
	table.clear(state.clues)
	table.clear(state.props)
	table.clear(state.clueOf)
	table.clear(attempts)

	Workspace:SetAttribute(GA.VaultPresent, false)
	Workspace:SetAttribute(GA.VaultSolved, false)
	Workspace:SetAttribute(GA.CluesFound, 0)
	Workspace:SetAttribute(GA.CluesTotal, 0)
end

--[[
	Rolls a fresh puzzle into the live map.

	Called from the round starting rather than from the map loading — see the
	header. Returns false when there is nothing to arm, which is the NORMAL
	answer on most of the roster — only Clinton has a puzzle authored today —
	and must never be an error.
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

	--[[ Optional. A tidy map keeps its documents together and this narrows the
	     search; an untidy one is searched whole. See findNamed. ]]
	local folder = findPuzzleFolder(root)

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

	local values = template.generate(random or Random.new(), definition)
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
				tostring(mapId),
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

	--[[ Found now, armed later. Both live inside the room the door seals, so
	     resolving them here costs nothing and means the moment the vault opens is
	     a couple of attribute writes rather than a search. ]]
	local loot = definition.loot
	state.weaponDrop = if loot and loot.weapon then findNamed(folder, root, loot.weapon.object) else nil

	--[[ Kept, or put back. See weaponStash: the pickup destroys the model, and a
	     map that is not reloaded between rounds never brings it back on its
	     own. ]]
	if loot and loot.weapon then
		if state.weaponDrop then
			if not weaponStash and state.weaponDrop:IsA("Model") then
				weaponStash = state.weaponDrop:Clone()
				weaponHome = state.weaponDrop:GetPivot()
			end
		elseif weaponStash and weaponHome then
			local restored = weaponStash:Clone()
			restored:PivotTo(weaponHome)
			restored.Parent = folder or root
			state.weaponDrop = restored
			print("[PuzzleService] restored the vault weapon a previous round removed")
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

	--[[ Printed only now that every prop is in the maps, and printed with the
	     count at zero — so all four documents are legible from the first second
	     of the round and all four digits are redacted. ]]
	repaint()

	print(
		string.format("[PuzzleService] %s armed with %d/%d clues", definition.id, painted, #definition.clues)
	)
	return true
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
	if not state.definition then
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

	state.solved = true
	Workspace:SetAttribute(GA.VaultSolved, true)
	reply(player, true, "ACCESS GRANTED", 0)

	setDoorOpen(true)
	armLoot()
	payOut()

	--[[
		And then they hear it.

		Opening the vault is loud, and the building has been listening. This is
		DirectorService's own crescendo — the same three waves a panic trigger
		fires — so the horde that answers the door is the horde the game already
		knows how to throw, spawned around the door rather than around the team.

		It is also what stops the reward being free: a supply room you have to
		hold for forty-five seconds is a decision, and a supply room you walk
		into is a vending machine.
	]]
	local director = Registry.find("DirectorService")
	if director and typeof(director.triggerPanicEvent) == "function" then
		local at = if state.door then state.door:GetPivot().Position else nil
		if not at and state.keypad then
			at = state.keypad:GetPivot().Position
		end
		if at then
			pcall(director.triggerPanicEvent, director, at)
		end
	end

	--[[ Announced to the whole server, not just the solver. Somebody found the
	     badge, somebody else found the sign, and the door opening is the moment
	     that was for. ]]
	Remotes.Event.VaultOpened:FireAllClients({
		player = player,
		position = if state.door then state.door:GetPivot().Position else nil,
	})

	--[[ On the keypad itself, so the whole team hears WHERE the lock let go
	     rather than getting a menu click in their ear. playOn wants a BasePart,
	     which a wrapped prop always has. ]]
	local audio = Registry.find("AudioService")
	local speaker = state.keypad
		and (state.keypad.PrimaryPart or state.keypad:FindFirstChildWhichIsA("BasePart", true))
	if audio and typeof(audio.playOn) == "function" and speaker then
		pcall(audio.playOn, audio, AudioConfig.UI.MenuConfirm, speaker)
	end
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

-- ── lifecycle ───────────────────────────────────────────────────────────────

function PuzzleService:init() end

function PuzzleService:start()
	serviceTrove:connect(Remotes.Event.SubmitVaultCode.OnServerEvent, onSubmit)
	serviceTrove:connect(Remotes.Event.CollectClue.OnServerEvent, onCollect)
	serviceTrove:connect(Remotes.Event.ClaimStockpile.OnServerEvent, onStockpile)

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
	if weaponStash then
		weaponStash:Destroy()
		weaponStash = nil
	end
	weaponHome = nil
	serviceTrove:destroy()
	doorTrove:destroy()
	self:clear()
end

Registry.register("PuzzleService", PuzzleService)

return PuzzleService
