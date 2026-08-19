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
local GameConfig = require(Shared.Config.GameConfig)
local RaycastUtil = require(Shared.Util.RaycastUtil)
local Registry = require(Shared.Util.Registry)
local Remotes = require(Shared.Net.Remotes)
local Trove = require(Shared.Util.Trove)
local UITheme = require(Shared.Config.UITheme)

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
local textLabel: TextLabel
local progressBar: Frame
local progressFill: Frame

local rayParams: RaycastParams
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
	alpha = 0,
	shownText = "",
	interactKey = "E",
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

	rayParams = RaycastUtil.excluding({})
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
		rayParams.FilterDescendantsInstances = { character }
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

	clearTarget()
end

-- ── input ───────────────────────────────────────────────────────────────────

local function beginInteract()
	if not state.enabled or state.cinematic or not state.target then
		return
	end
	state.lastRequest = os.clock()
	Remotes.Event.BeginInteract:FireServer(state.target)
end

local function cancelInteract()
	if state.holding then
		Remotes.Event.CancelInteract:FireServer()
	end
end

--[[ The glyph in the box is whatever Interact is actually bound to, read back
     from InputController rather than assumed, so a rebind relabels the prompt. ]]
local function readKeyGlyph()
	local controller = Registry.find("InputController")
	if not controller or typeof(controller.getBindings) ~= "function" then
		return
	end
	local ok, bindings = pcall(controller.getBindings, controller)
	if not ok or typeof(bindings) ~= "table" then
		return
	end
	for _, binding in bindings do
		if binding.action == "Interact" then
			for _, key in binding.keys do
				if typeof(key) == "EnumItem" and key.EnumType == Enum.KeyCode then
					local value = key.Value
					if (value >= 48 and value <= 57) or (value >= 97 and value <= 122) then
						state.interactKey = string.upper(string.char(value))
						keyLabel.Text = state.interactKey
						return
					end
				end
			end
		end
	end
end

-- ── presentation ────────────────────────────────────────────────────────────

local function composeText(): string
	local verb = if state.holding then state.serverVerb else state.verb
	local subject = if state.holding then state.serverSubject else state.subject
	if verb == "" then
		return ""
	end

	local prefix = if state.holding or state.holdable then "HOLD" else "PRESS"
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
	if visible then
		local fade = 1 - state.alpha
		textLabel.TextTransparency = fade
		keyLabel.TextTransparency = fade
		keyBox.BackgroundTransparency = 0.15 + fade * 0.85
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

function PromptController:getVerb(): string
	return if state.holding then state.serverVerb else state.verb
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
	else
		warn("[PromptController] no InputController; interact prompts will display but cannot be started")
	end

	trove:connect(Remotes.Event.InteractPromptChanged.OnClientEvent, function(payload: any)
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
