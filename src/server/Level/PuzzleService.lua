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
}

--[[ Per-player, and cleared when they leave. `at` is the last attempt and
     `wrong` is the run of consecutive misses that drives the lockout. ]]
local attempts: { [Player]: { at: number, wrong: number, lockedUntil: number } } = {}

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
		entry = { at = 0, wrong = 0, lockedUntil = 0 }
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

	--[[ Replaced rather than reused. A round re-arming has to overwrite last
	     round's document, and a second SurfaceGui on the same face would leave
	     both codes legible at once. ]]
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

	if state.door and state.door.Parent then
		for _, part in partsOf(state.door) do
			part.Transparency = state.doorLooks[part] or part.Transparency
			part.CanCollide = true
			part.CanQuery = true
		end
	end
	table.clear(state.doorLooks)

	for _, model in state.clues do
		if model.Parent then
			CollectionService:RemoveTag(model, PuzzleConfig.ClueTag)
			model:SetAttribute(PZ.ClueText, nil)
			model:SetAttribute(PZ.CluePrompt, nil)
		end
	end
	if state.keypad and state.keypad.Parent then
		CollectionService:RemoveTag(state.keypad, PuzzleConfig.KeypadTag)
	end

	state.definition = nil
	state.answer = ""
	state.solved = false
	state.keypad = nil
	state.door = nil
	table.clear(state.clues)
	table.clear(attempts)

	Workspace:SetAttribute(GA.VaultPresent, false)
	Workspace:SetAttribute(GA.VaultSolved, false)
end

--[[
	Rolls a fresh puzzle into the live map.

	Called from the round starting rather than from the map loading — see the
	header. Returns false when there is nothing to arm, which is the normal
	answer on two of the three maps and must never be an error.
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

	local template = TEMPLATES[definition.template]
	if not template then
		warn(string.format("[PuzzleService] no template called %q", tostring(definition.template)))
		return false
	end

	local values = template.generate(random or Random.new())
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

	--[[ Taken as it is rather than wrapped. The door in the supplied assembly is
	     a single Part and wrapping it in a Model would reparent somebody else's
	     geometry for no gain — partsOf and GetPivot both handle either shape. ]]
	local door = findNamed(keypad.Parent, root, definition.door)

	local surfaces = template.surfaces(definition, values)
	local painted = 0
	for _, clue in definition.clues do
		local child = findNamed(folder, root, clue.object)
		local model = child and asModel(child, child.Parent or root)
		local text = surfaces[clue.object]
		if model and text then
			paint(model, clue, text)
			CollectionService:AddTag(model, PuzzleConfig.ClueTag)
			table.insert(state.clues, model)
			painted += 1
		else
			warn(string.format("[PuzzleService] no %q prop — that clue is missing this round", clue.object))
		end
	end

	state.definition = definition
	state.answer = answer
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
	if now - entry.at < state.definition.attemptCooldown then
		reply(player, false, "WAIT", entry.at + state.definition.attemptCooldown)
		return
	end
	entry.at = now

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
	payOut()

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

-- ── public reads ────────────────────────────────────────────────────────────

--[[ Whether this instance is the live keypad. The client asks the same question
     to decide whether to draw a prompt; this is the answer that counts. ]]
function PuzzleService:isKeypad(instance: Instance): boolean
	return state.keypad ~= nil and state.keypad == instance
end

function PuzzleService:isSolved(): boolean
	return state.solved
end

-- ── lifecycle ───────────────────────────────────────────────────────────────

function PuzzleService:init() end

function PuzzleService:start()
	serviceTrove:connect(Remotes.Event.SubmitVaultCode.OnServerEvent, onSubmit)

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
	serviceTrove:destroy()
	doorTrove:destroy()
	self:clear()
end

Registry.register("PuzzleService", PuzzleService)

return PuzzleService
