--!nonstrict
--[[
	PromptController — "HOLD E — REVIVE Nick", and nothing at all otherwise.

	Two halves that have to agree:

	  1. FINDING THE TARGET. InputController deliberately does not send
	     BeginInteract, because that remote carries an Instance and picking it is
	     a presentation decision — you interact with what you are LOOKING at.
	     This controller casts one ray down the camera, falls back to a cone
	     check for a downed teammate lying at your feet (where a centre-screen
	     ray misses them), and sends the winner.

	  2. SHOWING THE HOLD. The server answers with InteractPromptChanged,
	     carrying the verb, the subject and the true duration — already scaled by
	     adrenaline, so the bar on screen and the clock on the server finish
	     together without a single progress packet crossing the wire.

	The local scan mirrors SurvivorService:_classify: revive, pull up, defib,
	heal, take, rescue. It is a PREDICTION of what the server will allow — if the
	two ever disagree the server simply refuses and the prompt clears, which is
	the correct failure and costs nothing.

	Nothing is on screen when there is nothing to interact with. The prompt is
	the only thing in the middle of the screen, so it is allowed to be the only
	thing the player sees there.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attributes = require(Shared.Net.Attributes)
local Enums = require(Shared.Enums)
local MapConfig = require(Shared.Config.MapConfig)
local PuzzleConfig = require(Shared.Config.PuzzleConfig)
local GameConfig = require(Shared.Config.GameConfig)
local RaycastUtil = require(Shared.Util.RaycastUtil)
local Registry = require(Shared.Util.Registry)
local Remotes = require(Shared.Net.Remotes)
local Trove = require(Shared.Util.Trove)
local UITheme = require(Shared.Config.UITheme)

local Glyph = require(script.Parent.Glyph)
local ScaleLayer = require(script.Parent.ScaleLayer)

local COLOR = UITheme.Color
local FONT = UITheme.Font
local LAYOUT = UITheme.Layout
local MOTION = UITheme.Motion
local TEXT = UITheme.TextSize

local LA = Attributes.Loadout
local PA = Attributes.Player
local PICKUP = Attributes.Pickup
local STATE = Enums.SurvivorState

local INTERACT_RANGE = GameConfig.Interaction.Range
local PICKUP_RANGE = GameConfig.Interaction.PickupRange
local MAX_HEALTH = GameConfig.Survivor.MaxHealth

--[[ Two tags SurvivorService owns and documents for exactly this use: a dead
     survivor's body stays a defib target after its Humanoid stops mattering,
     and a rescue closet is any tagged model in the level. Tags replicate, so
     the client finds the same instances the server will accept, with no remote
     and no extra state. The strings are duplicated from that service because
     neither is in the shared layer; being wrong costs a prompt, never a crash. ]]
local BODY_TAG = "FL_SurvivorBody"
local AMMO_CRATE_TAG = MapConfig.AmmoCrates.Tag
local CRATE = Attributes.Crate
local GA = Attributes.Game
local PUZZLE = Attributes.Puzzle

--[[ Asks another controller to do something, if it is there. The puzzle screens
     are optional — a build with the vault turned off has no VaultController —
     so this must be a lookup that can come back empty rather than a require. ]]
local function callController(name: string, method: string, ...: any)
	local controller = Registry.find(name)
	if controller and typeof(controller[method]) == "function" then
		pcall(controller[method], controller, ...)
	end
end
local CLOSET_TAG = "FL_RescueCloset"

-- Ten scans a second. A prompt that appears a frame late is imperceptible; a
-- raycast plus a roster walk every frame during a horde is not. It also happens
-- to be SurvivorService's own interact rate limit, so a scan can never produce a
-- request the server will drop.
local SCAN_INTERVAL = 0.1

-- How long a held key waits before asking again. Comfortably longer than any
-- round trip, because a duplicate request restarts the hold server-side.
local RETRY_INTERVAL = 0.6

--[[ A downed teammate is on the floor and a centre-screen ray sails over them,
     so anything inside this cone and inside interact range also counts. Wide,
     because the alternative is a player crouching over a friend wondering why
     the game will not let them help. ]]
local FLOOR_CONE = math.cos(math.rad(55))

--[[ A ceiling on what the near sweep will look at. Standing in a cluttered room
     can put a lot of parts inside arm's reach, and this runs on a phone; the
     nearest handful is all that can plausibly be the answer, and an unbounded
     query is how a spatial call becomes the thing you are optimising. ]]
local NEAR_SWEEP_MAX = 24

local PROMPT_WIDTH = 460
local PROMPT_HEIGHT = 46
local KEY_BOX = 26
local PROGRESS_HEIGHT = 3

local UPRIGHT: { [string]: boolean } = {
	[STATE.Healthy] = true,
	[STATE.Hurt] = true,
}

local PromptController = {}

local player = Players.LocalPlayer
local trove = Trove.new()

local gui: ScreenGui
-- The scaled content layer. See Client/UI/ScaleLayer.
local root: Frame
local panel: Frame
local keyBox: Frame
local keyLabel: TextLabel
--[[ The prompt itself, as a button, on a touchscreen only. See makeTappable. ]]
local tapButton: TextButton
local tapPlate: Frame
local textLabel: TextLabel
local progressBar: Frame
local progressFill: Frame

local rayParams: RaycastParams
--[[ For the near sweep below. Built once and refiltered with the ray's, since
     both exclude exactly the same thing — the player's own character. ]]
local nearParams: OverlapParams
local filtered: Model? = nil
local input: any = nil

local state = {
	enabled = true,
	cinematic = false,

	-- What the local scan believes is interactable right now.
	target = nil :: Instance?,
	verb = "",
	subject = "",
	subjectColor = COLOR.TextPrimary,
	holdable = false,

	-- What the server confirmed we are actually doing.
	serverVerb = "",
	serverSubject = "",
	duration = 0,
	elapsed = 0,
	holding = false,

	scanClock = 0,
	lastRequest = 0,
	--[[ The verb the in-flight request was made with. See getVerb. ]]
	requestVerb = "",
	alpha = 0,
	shownText = "",
	interactKey = "E",
	--[[ Whether the player is on a touchscreen, from InputController's scheme
	     rather than from the device: a phone in a dock with a pad attached is a
	     gamepad player, and the prompt must say what they are holding. Refreshed
	     by readKeyGlyph, which schemeChanged also drives. ]]
	touch = false,
}

-- ── construction ────────────────────────────────────────────────────────────

local function build()
	gui = Instance.new("ScreenGui")
	gui.Name = "FL_Prompt"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = UITheme.DisplayOrder.Prompt
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = player:WaitForChild("PlayerGui")
	trove:add(gui)

	root = ScaleLayer.new(gui, "Scaled")

	panel = Instance.new("Frame")
	panel.Name = "Prompt"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	-- Below the crosshair rather than under it: the prompt must never sit on
	-- top of the thing you are about to shoot.
	panel.Position = UDim2.fromScale(0.5, 0.63)
	panel.Size = UDim2.fromOffset(PROMPT_WIDTH, PROMPT_HEIGHT)
	panel.BackgroundTransparency = 1
	panel.Visible = false
	panel.Parent = root

	keyBox = Instance.new("Frame")
	keyBox.Name = "Key"
	keyBox.AnchorPoint = Vector2.new(0, 0.5)
	keyBox.Position = UDim2.new(0.5, -PROMPT_WIDTH * 0.5, 0.5, 0)
	keyBox.Size = UDim2.fromOffset(KEY_BOX, KEY_BOX)
	keyBox.BackgroundColor3 = COLOR.PanelRaised
	keyBox.BackgroundTransparency = 0.15
	keyBox.BorderSizePixel = 0
	keyBox.Parent = panel

	local keyCorner = Instance.new("UICorner")
	keyCorner.CornerRadius = UDim.new(0, LAYOUT.CornerRadius)
	keyCorner.Parent = keyBox

	local keyStroke = Instance.new("UIStroke")
	keyStroke.Color = COLOR.Accent
	keyStroke.Thickness = LAYOUT.BorderThickness
	keyStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	keyStroke.Parent = keyBox

	keyLabel = Instance.new("TextLabel")
	keyLabel.Name = "Glyph"
	keyLabel.BackgroundTransparency = 1
	keyLabel.Size = UDim2.fromScale(1, 1)
	keyLabel.Font = FONT.Heading
	keyLabel.TextSize = TEXT.Body
	keyLabel.TextColor3 = COLOR.AccentBright
	keyLabel.Text = state.interactKey
	keyLabel.Parent = keyBox

	--[[
		THE PROMPT IS THE BUTTON, ON A PHONE.

		There has always been a USE button on the touch pad, in the bottom-right
		corner, appearing when there is something to use. It works and almost
		nobody finds it: the thing that tells you an action exists is in the middle
		of the screen and the thing that performs it is two hundred pixels away in
		the corner, and a player's thumb goes to what they are reading.

		So on touch the prompt draws itself as a panel and takes the tap. A press
		holds Interact down and a lift releases it, which is one behaviour covering
		both kinds of interaction — a tap picks a gun up and a held thumb revives a
		teammate, with the bar filling under the finger doing it.

		── AND IT ONLY EXISTS WHEN IT IS NEEDED ────────────────────────────────
		A GuiButton swallows the touch that starts on it, so this is a band of
		screen the player cannot turn the camera from — which is why it is exactly
		the panel's own size, and why it is Visible only on touch AND only while
		there is something to interact with. That is a few seconds a minute, in a
		strip a fifth of the screen wide, at a moment when the player is looking
		at the thing rather than turning away from it.
	]]
	tapPlate = Instance.new("Frame")
	tapPlate.Name = "Plate"
	tapPlate.AnchorPoint = Vector2.new(0.5, 0.5)
	tapPlate.Position = UDim2.fromScale(0.5, 0.5)
	tapPlate.Size = UDim2.fromOffset(PROMPT_WIDTH, PROMPT_HEIGHT)
	tapPlate.BackgroundColor3 = COLOR.PanelRaised
	tapPlate.BackgroundTransparency = 0.25
	tapPlate.BorderSizePixel = 0
	tapPlate.Visible = false
	--[[ Behind the text, which is built after it and therefore draws on top
	     under Sibling ZIndex ordering. ]]
	tapPlate.Parent = panel

	local plateCorner = Instance.new("UICorner")
	plateCorner.CornerRadius = UDim.new(0, LAYOUT.CornerRadius)
	plateCorner.Parent = tapPlate

	local plateStroke = Instance.new("UIStroke")
	plateStroke.Color = COLOR.Accent
	plateStroke.Thickness = LAYOUT.BorderThickness
	plateStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	plateStroke.Parent = tapPlate

	textLabel = Instance.new("TextLabel")
	textLabel.Name = "Text"
	textLabel.AnchorPoint = Vector2.new(0, 0.5)
	textLabel.Position = UDim2.new(0.5, -PROMPT_WIDTH * 0.5 + KEY_BOX + LAYOUT.ElementGap * 2, 0.5, 0)
	textLabel.Size = UDim2.fromOffset(PROMPT_WIDTH - KEY_BOX - LAYOUT.ElementGap * 2, KEY_BOX)
	textLabel.BackgroundTransparency = 1
	textLabel.Font = FONT.Heading
	textLabel.TextSize = TEXT.Large
	textLabel.TextColor3 = COLOR.TextPrimary
	textLabel.TextXAlignment = Enum.TextXAlignment.Left
	textLabel.RichText = true
	textLabel.Text = ""
	textLabel.Parent = panel

	progressBar = Instance.new("Frame")
	progressBar.Name = "Progress"
	progressBar.AnchorPoint = Vector2.new(0.5, 1)
	progressBar.Position = UDim2.new(0.5, 0, 1, 0)
	progressBar.Size = UDim2.fromOffset(PROMPT_WIDTH, PROGRESS_HEIGHT)
	progressBar.BackgroundColor3 = COLOR.Background
	progressBar.BackgroundTransparency = 0.25
	progressBar.BorderSizePixel = 0
	progressBar.Visible = false
	progressBar.Parent = panel

	progressFill = Instance.new("Frame")
	progressFill.Name = "Fill"
	progressFill.Size = UDim2.new(0, 0, 1, 0)
	progressFill.BackgroundColor3 = COLOR.Accent
	progressFill.BorderSizePixel = 0
	progressFill.Parent = progressBar

	--[[ Last, so it is the topmost sibling and the tap reaches it rather than
	     the labels. Transparent and text-free: the panel underneath is what the
	     player sees, and this is only the hit area over it. ]]
	tapButton = Instance.new("TextButton")
	tapButton.Name = "Tap"
	tapButton.AnchorPoint = Vector2.new(0.5, 0.5)
	tapButton.Position = UDim2.fromScale(0.5, 0.5)
	tapButton.Size = UDim2.fromOffset(PROMPT_WIDTH, PROMPT_HEIGHT)
	tapButton.BackgroundTransparency = 1
	tapButton.Text = ""
	tapButton.AutoButtonColor = false
	--[[ Never a gamepad focus candidate. It is invisible off touch and Roblox does
	     not select invisible objects, but this is a button living in the HUD layer
	     rather than in a panel, and a controller landing on it would be a stuck
	     selection with nothing to explain it. ]]
	tapButton.Selectable = false
	tapButton.Visible = false
	tapButton.Parent = panel

	--[[ Down and up rather than Activated, so a HOLD works: Activated only fires
	     on release and would turn a five-second revive into a tap that does
	     nothing. The release is answered on three signals, not one — a finger
	     that slides off the button never sends MouseButton1Up, and an interact
	     left held down is a revive the server never hears the end of. ]]
	trove:connect(tapButton.MouseButton1Down, function()
		if input and typeof(input.raise) == "function" then
			input:raise(input.Action.Interact, true)
		end
	end)
	local function releaseTap()
		if input and typeof(input.raise) == "function" then
			input:raise(input.Action.Interact, false)
		end
	end
	trove:connect(tapButton.MouseButton1Up, releaseTap)
	trove:connect(tapButton.MouseLeave, releaseTap)
	--[[ And when the prompt goes away under the finger — the teammate got up,
	     the crate emptied, somebody else took the gun. Nothing else would ever
	     send the release in that case. ]]
	trove:connect(tapButton:GetPropertyChangedSignal("Visible"), function()
		if not tapButton.Visible then
			releaseTap()
		end
	end)

	rayParams = RaycastUtil.excluding({})

	--[[ Exclude, like the ray, and RespectCanCollide so a decoration part or an
	     effect volume never answers the near sweep. Built once; the filter
	     contents are refreshed with the ray's whenever the character changes. ]]
	nearParams = OverlapParams.new()
	nearParams.FilterType = Enum.RaycastFilterType.Exclude
	nearParams.RespectCanCollide = true
	nearParams.MaxParts = NEAR_SWEEP_MAX
end

local function hex(color: Color3): string
	return string.format(
		"#%02X%02X%02X",
		math.floor(color.R * 255 + 0.5),
		math.floor(color.G * 255 + 0.5),
		math.floor(color.B * 255 + 0.5)
	)
end

local function itemLabel(itemId: string): string
	local spaced = string.gsub(itemId, "(%l)(%u)", "%1 %2")
	return string.upper(spaced)
end

-- ── target scanning ─────────────────────────────────────────────────────────

local function survivorColor(target: Player): Color3
	local hud = Registry.find("HudController")
	if hud and typeof(hud.getSurvivorColor) == "function" then
		local ok, color = pcall(hud.getSurvivorColor, hud, target)
		if ok and typeof(color) == "Color3" then
			return color
		end
	end
	return COLOR.TextPrimary
end

--[[ What holding the key on this player would mean, mirroring the server's
     classification. Returns nil when the answer is "nothing". ]]
local function classifyPlayer(other: Player): (string?, boolean)
	local otherState = Attributes.get(other, PA.State, STATE.Spectating)
	if otherState == STATE.Incapacitated then
		return "REVIVE", true
	elseif otherState == STATE.LedgeHanging then
		return "PULL UP", true
	elseif otherState == STATE.Dead then
		if Attributes.get(player, LA.HealthItemId, "") == Enums.HealthItem.Defibrillator then
			return "REVIVE", true
		end
		return nil, false
	elseif UPRIGHT[otherState] then
		if
			Attributes.get(player, LA.HealthItemId, "") == Enums.HealthItem.Medkit
			and Attributes.get(other, PA.Health, MAX_HEALTH) < MAX_HEALTH
		then
			return "HEAL", true
		end
	end
	return nil, false
end

local function classifyInstance(instance: Instance): (Instance?, string?, string?, boolean, Color3?)
	local node: Instance? = instance
	while node and node ~= Workspace do
		if node:GetAttribute(PICKUP.Slot) ~= nil then
			local itemId = tostring(node:GetAttribute(PICKUP.ItemId) or node.Name)
			return node, "TAKE", itemLabel(itemId), false, COLOR.TextPrimary
		end
		if CollectionService:HasTag(node, CLOSET_TAG) then
			return node, "RESCUE", "SURVIVOR", true, COLOR.TextPrimary
		end
		if CollectionService:HasTag(node, AMMO_CRATE_TAG) then
			--[[ A spent crate is not a prompt. The ghost stays visible so the spot
			     still reads as a resupply point, but offering a hold that the
			     server will refuse is worse than offering nothing. ]]
			if node:GetAttribute(CRATE.Spent) == true then
				return nil, nil, nil, false, nil
			end
			return node, "RESUPPLY", "AMMO", true, COLOR.Accent
		end
		--[[
			The vault puzzle: a keypad and four documents somebody left behind.

			Both are INSTANT and both are answered here rather than on the server,
			which is why neither has a branch in SurvivorService._classify. Reading
			a document and opening a number pad are things that happen on one
			player's screen; they grant nothing, move nothing and cost nothing, so
			there is nothing for a server to validate. The moment something is
			actually at stake — the code itself — it goes up as its own remote and
			PuzzleService is the only thing that decides.

			A solved vault stops prompting. The door is already open; offering to
			type a code into it would be offering to do nothing.
		]]
		if CollectionService:HasTag(node, PuzzleConfig.KeypadTag) then
			if Attributes.get(Workspace, GA.VaultSolved, false) == true then
				return nil, nil, nil, false, nil
			end
			return node, "KEYPAD", "SECURITY VAULT", false, COLOR.Accent
		end
		--[[ The cash in the vault. Tagged only once the door is open, so before
		     that it is scenery and there is nothing to offer. ]]
		if CollectionService:HasTag(node, PuzzleConfig.StockpileTag) then
			local label = tostring(node:GetAttribute(PUZZLE.CluePrompt) or "SUPPLIES")
			return node, "TAKE", label, false, COLOR.Accent
		end
		if CollectionService:HasTag(node, PuzzleConfig.ClueTag) then
			local label = tostring(node:GetAttribute(PUZZLE.CluePrompt) or "DOCUMENT")
			--[[ A clue already in the team's hands is a document you re-read; one
			     that is not is a thing you pick up. Same key, same remote, and the
			     server decides which it actually was — this only changes the word,
			     so a player can tell at a glance what they have already been to. ]]
			local order = tonumber(node:GetAttribute(PUZZLE.ClueOrder)) or 0
			local held = tonumber(Attributes.get(Workspace, GA.CluesFound, 0)) or 0
			local colour = if order <= held then COLOR.TextDim else COLOR.Accent
			return node, "READ", label, false, colour
		end
		if CollectionService:HasTag(node, BODY_TAG) then
			-- A body is only a prompt while you are carrying the thing that
			-- answers it; without a defibrillator it is scenery.
			if Attributes.get(player, LA.HealthItemId, "") ~= Enums.HealthItem.Defibrillator then
				return nil, nil, nil, false, nil
			end
			local owner = Players:FindFirstChild(node.Name)
			local color = if owner and owner:IsA("Player") then survivorColor(owner) else COLOR.TextPrimary
			return node, "REVIVE", string.upper(node.Name), true, color
		end
		local other = node:IsA("Model") and Players:GetPlayerFromCharacter(node) or nil
		if other and other ~= player then
			local verb, holdable = classifyPlayer(other)
			if verb then
				return node, verb, string.upper(other.DisplayName), holdable, survivorColor(other)
			end
			return nil, nil, nil, false, nil
		end
		node = node.Parent
	end
	return nil, nil, nil, false, nil
end

local function clearTarget()
	state.target = nil
	state.verb = ""
	state.subject = ""
	state.holdable = false
end

local function scan()
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local camera = Workspace.CurrentCamera
	if
		not (character and root and camera) or not UPRIGHT[Attributes.get(player, PA.State, STATE.Spectating)]
	then
		clearTarget()
		return
	end

	if filtered ~= character then
		-- Rebuilt only when the character changes: this runs ten times a second
		-- and the table is the only allocation in the scan.
		filtered = character
		local exclude = { character }
		rayParams.FilterDescendantsInstances = exclude
		nearParams.FilterDescendantsInstances = exclude
	end
	local origin = camera.CFrame.Position
	local look = camera.CFrame.LookVector

	-- What you are looking at wins. Range is the interact range; a pickup is
	-- re-checked against its own, shorter range below.
	local hit = Workspace:Raycast(origin, look * INTERACT_RANGE, rayParams)
	if hit then
		local target, verb, subject, holdable, color = classifyInstance(hit.Instance)
		if target and verb then
			local limit = if verb == "TAKE" then PICKUP_RANGE else INTERACT_RANGE
			if (hit.Position - root.Position).Magnitude <= limit then
				state.target = target
				state.verb = verb
				state.subject = subject or ""
				state.holdable = holdable
				state.subjectColor = color or COLOR.TextPrimary
				return
			end
		end
	end

	--[[ Nothing under the crosshair. A teammate on the floor at your feet is the
	     case that matters, so sweep the roster for one inside the cone and take
	     the closest. ]]
	local best: Player? = nil
	local bestDistance = INTERACT_RANGE
	for _, other in Players:GetPlayers() do
		if other ~= player then
			local otherRoot = other.Character and other.Character:FindFirstChild("HumanoidRootPart")
			if otherRoot then
				local offset = (otherRoot :: BasePart).Position - root.Position
				local distance = offset.Magnitude
				if distance <= bestDistance and distance > 0 then
					if offset.Unit:Dot(look) >= FLOOR_CONE then
						best = other
						bestDistance = distance
					end
				end
			end
		end
	end

	if best then
		local verb, holdable = classifyPlayer(best)
		if verb then
			state.target = best.Character
			state.verb = verb
			state.subject = string.upper(best.DisplayName)
			state.holdable = holdable
			state.subjectColor = survivorColor(best)
			return
		end
	end

	--[[
		The same courtesy, for things that are not people.

		A downed teammate at your feet has been findable without aiming at them
		since this was written; a medkit on the floor and an ammo crate you are
		standing against have not. That gap is a desktop-shaped assumption: a
		mouse puts the crosshair on a crate without thinking about it, and a thumb
		dragging to look does not. It is the whole of "I cannot use the ammo crate
		on my phone".

		Runs ONLY when the ray missed, at the 10Hz this scan already ticks at, so
		it costs one spatial query a tenth of a second in the case where the
		player is currently being told they can do nothing. Nothing to reclaim
		there.

		PICKUP_RANGE rather than INTERACT_RANGE: this is for something within
		arm's reach, and the wider range would have you resupplying from a crate
		across the room because it happened to be roughly ahead.
	]]
	local nearBest: Instance? = nil
	local nearVerb, nearSubject, nearHoldable, nearColor = nil, nil, false, nil
	local nearDistance = PICKUP_RANGE

	for _, part in Workspace:GetPartBoundsInRadius(root.Position, PICKUP_RANGE, nearParams) do
		local offset = part.Position - root.Position
		local distance = offset.Magnitude
		if distance <= 0 or distance > nearDistance then
			continue
		end
		--[[ Same cone as the teammate sweep. Without it you would resupply from a
		     crate behind you, and a prompt that appears for something you cannot
		     see reads as the game choosing for you. ]]
		if offset.Unit:Dot(look) < FLOOR_CONE then
			continue
		end
		--[[ Through classifyInstance, so a target is exactly as legal here as
		     under the crosshair — the spent-crate rule, the defibrillator rule and
		     the pickup labels are decided in one place and this cannot drift from
		     it. Players are skipped: the sweep above already had its say, with a
		     longer range and its own rules. ]]
		local target, verb, subject, holdable, color = classifyInstance(part)
		if target and verb and not Players:GetPlayerFromCharacter(target.Parent) then
			nearBest = target
			nearVerb = verb
			nearSubject = subject
			nearHoldable = holdable
			nearColor = color
			nearDistance = distance
		end
	end

	if nearBest and nearVerb then
		state.target = nearBest
		state.verb = nearVerb
		state.subject = nearSubject or ""
		state.holdable = nearHoldable
		state.subjectColor = nearColor or COLOR.TextPrimary
		return
	end

	clearTarget()
end

-- ── input ───────────────────────────────────────────────────────────────────

--[[
	Whether this press was the puzzle's, in which case it never reaches the wire.

	The two puzzle verbs open a screen and nothing else. Sending BeginInteract
	for them would ask SurvivorService to classify an instance its own if-chain
	has never heard of, get refused, and clear the prompt the player is currently
	looking at — so the press is answered here and the remote is not fired.

	Returns true when it handled the press, so beginInteract can stop.
]]
local function handlePuzzlePress(): boolean
	local target = state.target
	if not target then
		return false
	end
	if state.verb == "KEYPAD" then
		callController("VaultController", "openKeypad", target)
		return true
	end
	--[[ TAKE is the pickup verb for a dropped weapon too, so the tag decides
	     rather than the word: only a stockpile answers here, and everything else
	     wearing TAKE falls through to the ordinary FL_Slot path on the server. ]]
	if state.verb == "TAKE" and CollectionService:HasTag(target, PuzzleConfig.StockpileTag) then
		Remotes.Event.ClaimStockpile:FireServer(target)
		return true
	end
	if state.verb == "READ" then
		--[[ Asked rather than opened. Picking a clue up is ORDERED and the server
		     owns the order, so the document is shown by whatever comes back —
		     including the refusal that names the clue they should have found
		     first. Opening it here would show a page of redactions and no reason
		     for them. ]]
		Remotes.Event.CollectClue:FireServer(target)
		return true
	end
	return false
end

local function beginInteract()
	if not state.enabled or state.cinematic or not state.target then
		return
	end
	if handlePuzzlePress() then
		return
	end
	state.lastRequest = os.clock()
	state.requestVerb = state.verb
	Remotes.Event.BeginInteract:FireServer(state.target)
end

local function cancelInteract()
	state.requestVerb = ""
	if state.holding then
		Remotes.Event.CancelInteract:FireServer()
	end
end

--[[
	The glyph in the box is whatever Interact is actually bound to, read back from
	InputController rather than assumed, so a rebind relabels the prompt.

	── AND IT WAS WRONG ON BOTH DEVICES THAT ARE NOT A KEYBOARD ────────────────
	This walked the bound keys itself and took the first one in the ASCII letter
	range. Interact is bound to E and to a face button; E sorts first. So a phone
	player standing over a downed teammate was told, in a box, to press a key
	their device does not have — and so was every player on a controller, which is
	worse, because a controller HAS a button for it and this told them the wrong
	one.

	Glyph answers it now, for every scheme, once. Touch gets no box at all: the
	prompt itself is the button there — see makeTappable.
]]
local function readKeyGlyph()
	local controller = Registry.find("InputController")
	if not controller then
		return
	end
	local scheme = if typeof(controller.getScheme) == "function"
		then select(2, pcall(controller.getScheme, controller))
		else nil
	local touch = scheme == "Touch"
	state.touch = touch

	local glyph = Glyph.forAction("Interact", scheme, controller)
	state.interactKey = glyph
	keyLabel.Text = glyph

	--[[ The box goes with the glyph rather than sitting there empty — on a phone,
	     which has no key, and on a pad with nothing bound to this verb, where an
	     empty box is a promise there is a button. And the text closes the gap it
	     leaves in BOTH cases: it is left-aligned from just past the box, so
	     hiding the box without moving the text would push the whole prompt a
	     key-width off centre. ]]
	local showBox = not touch and glyph ~= ""
	keyBox.Visible = showBox
	local indent = if showBox then KEY_BOX + LAYOUT.ElementGap * 2 else 0
	textLabel.Position = UDim2.new(0.5, -PROMPT_WIDTH * 0.5 + indent, 0.5, 0)
	textLabel.Size = UDim2.fromOffset(PROMPT_WIDTH - indent, KEY_BOX)
	textLabel.TextXAlignment = if showBox then Enum.TextXAlignment.Left else Enum.TextXAlignment.Center
end

-- ── presentation ────────────────────────────────────────────────────────────

local function composeText(): string
	local verb = if state.holding then state.serverVerb else state.verb
	local subject = if state.holding then state.serverSubject else state.subject
	if verb == "" then
		return ""
	end

	--[[ "PRESS E" on a keyboard, "PRESS X" on a pad, and "TAP" on a phone — where
	     there is no glyph after it and "press" is not what anybody does. HOLD is
	     the same word on all three, because it is the same gesture. ]]
	local prefix
	if state.holding or state.holdable then
		prefix = "HOLD"
	else
		prefix = if state.touch then "TAP" else "PRESS"
	end
	local subjectText = if subject ~= ""
		then string.format(' <font color="%s">%s</font>', hex(state.subjectColor), subject)
		else ""
	return string.format(
		'<font color="%s">%s</font>  <font color="%s">%s</font>%s',
		hex(COLOR.TextSecondary),
		prefix,
		hex(COLOR.Accent),
		string.upper(verb),
		subjectText
	)
end

local function update(dt: number)
	state.scanClock -= dt
	if state.scanClock <= 0 then
		state.scanClock = SCAN_INTERVAL
		if state.enabled and not state.cinematic then
			scan()
			--[[ Walking into range with the key ALREADY held has to work, or
			     every revive costs a re-press at the worst possible moment. The
			     retry is deliberately slow: the server restarts an interaction
			     it receives twice, so this must never outrun its own
			     confirmation on a bad connection. ]]
			if
				not state.holding
				and state.target
				and input
				and os.clock() - state.lastRequest > RETRY_INTERVAL
				and input:isDown(input.Action.Interact)
			then
				beginInteract()
			end
		else
			clearTarget()
		end
	end

	if state.holding and state.duration > 0 then
		state.elapsed = math.min(state.elapsed + dt, state.duration)
		progressFill.Size = UDim2.new(state.elapsed / state.duration, 0, 1, 0)
	end

	local wantVisible = (state.holding or (state.verb ~= "" and state.enabled and not state.cinematic))
	local text = if wantVisible then composeText() else ""
	if text ~= state.shownText then
		state.shownText = text
		textLabel.Text = text
	end

	-- The fade is the only easing on the prompt, and it is fast: a prompt that
	-- takes a third of a second to arrive is one the player already gave up on.
	local targetAlpha = if wantVisible and text ~= "" then 1 else 0
	local speed = if targetAlpha > state.alpha then MOTION.FastIn else MOTION.FastOut
	state.alpha += (targetAlpha - state.alpha) * math.min(dt / speed, 1)
	if math.abs(targetAlpha - state.alpha) < 0.01 then
		state.alpha = targetAlpha
	end

	local visible = state.alpha > 0.01
	if panel.Visible ~= visible then
		panel.Visible = visible
	end
	--[[ The tap target follows the PANEL rather than the fade, and it is armed
	     only while the prompt is genuinely up. See the tapButton comment in
	     build: this is a strip of screen a touch player cannot turn from, so it
	     must not outlive the thing it is for by even a fade. ]]
	local tappable = visible and state.touch
	if tapButton.Visible ~= tappable then
		tapButton.Visible = tappable
	end
	if tapPlate.Visible ~= tappable then
		tapPlate.Visible = tappable
	end
	if visible then
		local fade = 1 - state.alpha
		textLabel.TextTransparency = fade
		keyLabel.TextTransparency = fade
		keyBox.BackgroundTransparency = 0.15 + fade * 0.85
		if tappable then
			tapPlate.BackgroundTransparency = 0.25 + fade * 0.75
		end
		progressBar.Visible = state.holding and state.duration > 0
		progressBar.BackgroundTransparency = 0.25 + fade * 0.75
		progressFill.BackgroundTransparency = fade
	end
end

-- ── public API ──────────────────────────────────────────────────────────────

--[[ The instance BeginInteract would be sent for right now, or nil. ]]
function PromptController:getTarget(): Instance?
	return state.target
end

--[[
	What the player can do right now, or is already doing.

	`serverVerb` while a hold is running, so the answer survives looking away —
	the server holds the target it was handed and does not care where the camera
	points afterwards.

	The third case is the one that matters on a phone. Between firing
	BeginInteract and the server answering there is a round trip in which
	`holding` is still false, so this fell back to the raycast verb. On a touch
	screen the thumb that presses USE is the same thumb that aims: pressing it
	moves the camera off the target, the verb goes empty, TouchController hides
	the contextual button — and hiding it RELEASES the action, cancelling the
	revive a tenth of a second after it started. On a desktop the mouse and the
	key are different hands and the window never opened.

	So an in-flight request keeps answering with the verb it was made with, until
	the server replies or the grace expires.
]]
local REQUEST_GRACE = 0.6

function PromptController:getVerb(): string
	if state.holding then
		return state.serverVerb
	end
	if state.requestVerb ~= "" and os.clock() - state.lastRequest < REQUEST_GRACE then
		return state.requestVerb
	end
	return state.verb
end

function PromptController:setEnabled(value: boolean)
	state.enabled = value
end

function PromptController:setCinematic(value: boolean)
	state.cinematic = value
end

-- ── lifecycle ───────────────────────────────────────────────────────────────

function PromptController:init()
	build()
end

function PromptController:start()
	readKeyGlyph()

	input = Registry.find("InputController")
	if input and typeof(input.onBegan) == "function" then
		trove:add(input:onBegan(input.Action.Interact):connect(beginInteract))
		trove:add(input:onEnded(input.Action.Interact):connect(cancelInteract))
		--[[ Re-read when the player changes what they are holding. The glyph was
		     resolved exactly once at start, so a rebind relabelled nothing and a
		     phone player who had touched the screen after this ran was still being
		     shown a key. Every other glyph in the interface already follows the
		     scheme; this one did not. ]]
		if input.schemeChanged then
			trove:add(input.schemeChanged:connect(readKeyGlyph))
		end
	else
		warn("[PromptController] no InputController; interact prompts will display but cannot be started")
	end

	--[[ The reply ends the grace above, whichever way it went: a hold that
	     started sets `holding`, and one the server refused must stop pretending. ]]
	trove:connect(Remotes.Event.InteractPromptChanged.OnClientEvent, function(payload: any)
		state.requestVerb = ""
		if typeof(payload) ~= "table" then
			return
		end
		if not payload.visible then
			state.holding = false
			state.duration = 0
			state.elapsed = 0
			progressFill.Size = UDim2.new(0, 0, 1, 0)
			return
		end

		state.holding = true
		state.serverVerb = tostring(payload.verb or "")
		state.serverSubject = string.upper(tostring(payload.subject or ""))
		state.duration = if typeof(payload.duration) == "number" then payload.duration else 0
		state.elapsed = 0
		progressFill.Size = UDim2.new(0, 0, 1, 0)

		-- The server names the subject as a raw player name; colour it as that
		-- survivor when we can match one, so the prompt and the panel agree.
		state.subjectColor = COLOR.TextPrimary
		for _, other in Players:GetPlayers() do
			if
				string.upper(other.Name) == state.serverSubject
				or string.upper(other.DisplayName) == state.serverSubject
			then
				state.serverSubject = string.upper(other.DisplayName)
				state.subjectColor = survivorColor(other)
				break
			end
		end
	end)

	trove:connect(RunService.RenderStepped, update)
end

function PromptController:destroy()
	trove:destroy()
end

Registry.register("PromptController", PromptController)

return PromptController
