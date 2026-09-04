--!nonstrict
--[[
	AbilityController — the two cards in the corner, and the ask.

	See Shared/Config/AbilityConfig for what an ability is. This file owns three
	things and deliberately no more:

	  1. what the cards say — the name, and READY or a countdown
	  2. what a keypress means — fire it now, or start choosing a spot
	  3. the spot, for the two abilities that need one

	It decides NOTHING about whether an ability may fire. The press goes to the
	server, the server checks alive, round, slot, ownership and cooldown, and the
	server answers. The greying-out here is a courtesy so the player is not
	pressing a key that will be refused — it is not a gate, and a client that
	skipped it would be refused exactly the same.

	── EVERYTHING IT DRAWS IS AN ATTRIBUTE ─────────────────────────────────────
	What is equipped and when each slot is next usable ride Attributes.Player,
	written by AbilityService. The cooldown is an ABSOLUTE server-time stamp, so
	the countdown here is arithmetic against the clock rather than a number being
	streamed down: a cooldown costs one attribute write, the text is smooth, and
	it cannot drift. Nothing here polls the server and nothing here asks it a
	question it has already answered.

	── AND THE HUD IS NOT REDESIGNED ───────────────────────────────────────────
	Its own ScreenGui on the HUD layer, in UITheme's own colours and fonts, sat
	above the hotbar. HudController is not touched: a second surface that obeys
	the same theme is a smaller change than a new section inside a 2,000-line
	file, and it can be switched off independently.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ContextActionService = game:GetService("ContextActionService")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local AbilityAssets = require(Shared.Util.AbilityAssets)
local AbilityConfig = require(Shared.Config.AbilityConfig)
local Attributes = require(Shared.Net.Attributes)
local AudioConfig = require(Shared.Config.AudioConfig)
local Registry = require(Shared.Util.Registry)
local Remotes = require(Shared.Net.Remotes)
local RaycastUtil = require(Shared.Util.RaycastUtil)
local RigUtil = require(Shared.Util.RigUtil)
local Trove = require(Shared.Util.Trove)
local UITheme = require(Shared.Config.UITheme)

local ScaleLayer = require(script.Parent.ScaleLayer)
local UiSound = require(script.Parent.UiSound)
local Widgets = require(script.Parent.Widgets)

local COLOR = UITheme.Color
local FONT = UITheme.Font
local LAYOUT = UITheme.Layout
local TEXT = UITheme.TextSize

local player = Players.LocalPlayer

--[[ The card. Two lines — what it is, and whether you can use it — because
     under pressure a player reads the second one and nothing else. ]]
local CARD_WIDTH = 138
local CARD_HEIGHT = 44
local CARD_GAP = 6

--[[ Where the stack sits: bottom-left, above the health block, opposite the
     hotbar. It is the one corner the HUD leaves empty. ]]
local STACK_X = LAYOUT.ScreenMargin
local STACK_Y = 210

--[[ How far a target ray may travel before it gives up. Longer than any
     ability's range, because the SERVER clamps to the range — the client's job
     is to find the ground under the crosshair, not to enforce a rule. ]]
local AIM_DISTANCE = 900

--[[ The placement ghost: how see-through it is, and the two colours that say
     whether the spot will be accepted. Green and red rather than the interface's
     own orange, because this is the one moment the game is answering yes or no
     rather than presenting an option. ]]
local GHOST_TRANSPARENCY = 0.55
local GHOST_OK = Color3.fromRGB(88, 200, 108)
local GHOST_BAD = Color3.fromRGB(206, 46, 32)

--[[ What the prompt under the ability's name says. The two refusals are the
     ONLY two the client can honestly diagnose — the server's remaining checks
     are about ownership and cooldown, which the card has already greyed out —
     so a red ghost always has one of these next to it rather than a shrug. ]]
local HINT_PLACE = "AIM AND FIRE TO PLACE IT"
local HINT_NO_GROUND = "NO SOLID GROUND THERE"
local HINT_TOO_FAR = "TOO FAR AWAY"

--[[ The confirm binding, above InputController's own so the shot that would
     otherwise accompany a placement is sunk before the weapon ever sees it. ]]
local AIM_ACTION = "FL_AbilityAim"
local AIM_PRIORITY = Enum.ContextActionPriority.High.Value + 500

local AbilityController = {}

local trove = Trove.new()
local aimTrove = Trove.new()

local gui: ScreenGui
local stack: Frame
local reticle: Frame
local reticleLabel: TextLabel
local reticleHint: TextLabel

type Card = {
	frame: Frame,
	name: TextLabel,
	status: TextLabel,
	stroke: UIStroke,
	key: TextLabel,
	id: string,
	readyAt: number,
	shownWhole: number,
}
local cards: { Card } = {}

local state = {
	--[[ The slot waiting for a click, or 0. Only ever set for an ability whose
	     definition is `targeted`; everything else fires on the press. ]]
	aiming = 0,
	--[[ The placement preview, for abilities that declare one. Nil for a cryo
	     field or an airstrike, whose target is a patch of floor rather than an
	     object that has to fit somewhere. ]]
	ghost = nil :: Model?,
	ghostOk = false,
	--[[ What the prompt currently says. Compared against rather than written
	     blindly: stepGhost runs every frame, and re-setting a TextLabel to the
	     string it already holds is a layout pass sixty times a second. ]]
	hint = "",
}

-- ── helpers ─────────────────────────────────────────────────────────────────

local function now(): number
	return Workspace:GetServerTimeNow()
end

--[[ The face buttons the gamepad ability layer puts each slot on, in the same
     order InputController binds them. See the ABILITY LAYER note there. ]]
local LAYER_FACE = { "X", "Y", "A", "B" }

--[[
	What opens this slot, for the corner of the card — and it is a different
	answer on every scheme.

	Keyboard gets the bound key, asked of InputController rather than assumed
	because these are rebindable. A gamepad gets the LAYER prompt, because there
	is no single button to name: abilities live behind holding the view button,
	and a card that said "Z" to a controller player would be actively lying to
	them. Touch gets nothing, because the on-screen button IS the prompt and
	labelling a button with its own name is noise.
]]
local function keyLabelFor(slot: number): string
	local input = Registry.find("InputController")
	if not input then
		return ""
	end

	local scheme = if typeof(input.getScheme) == "function" then input:getScheme() else nil
	if scheme == "Touch" then
		return ""
	end
	if scheme == "Gamepad" then
		local face = LAYER_FACE[slot]
		--[[ "VIEW" rather than a glyph. A Roblox game cannot know whether it is
		     on an Xbox or a PlayStation pad, so any symbol drawn here would be
		     wrong on one of them — the same reason InputController's D-pad
		     prompts use arrows and its face buttons keep their letters. ]]
		return if face then "VIEW+" .. face else ""
	end

	if typeof(input.getBindings) ~= "function" then
		return ""
	end
	local ok, bindings = pcall(input.getBindings, input)
	if not ok or typeof(bindings) ~= "table" then
		return ""
	end
	for _, binding in bindings do
		if binding.action ~= "Ability" .. slot then
			continue
		end
		for _, key in binding.keys do
			if typeof(key) == "EnumItem" and key.EnumType == Enum.KeyCode then
				return string.upper(key.Name)
			end
		end
	end
	return ""
end

--[[ The point under the crosshair, dropped to the floor. The server re-derives
     and clamps this — see AbilityService — so a client that lies about it gets
     the edge of its own range and nothing more. ]]
local function aimPoint(): Vector3?
	local camera = Workspace.CurrentCamera
	if not camera then
		return nil
	end
	local origin = camera.CFrame.Position
	local direction = camera.CFrame.LookVector * AIM_DISTANCE

	local ignore = { player.Character }
	local infected = Workspace:FindFirstChild("Infected")
	if infected then
		--[[ Bodies are not ground. Aiming a cryo field at the horde should put it
		     on the floor under them rather than on the shoulder of whichever one
		     the crosshair happened to cross. ]]
		table.insert(ignore, infected)
	end

	local result = Workspace:Raycast(origin, direction, RaycastUtil.excluding(ignore))
	return if result then result.Position else nil
end

-- ── drawing ─────────────────────────────────────────────────────────────────

local function refreshSlots()
	for index, card in cards do
		local idAttribute = AbilityConfig.attributesFor(index)
		local id = if idAttribute then tostring(Attributes.get(player, idAttribute, "") or "") else ""
		card.id = id

		local definition = AbilityConfig.get(id)
		card.frame.Visible = definition ~= nil
		if definition then
			card.name.Text = definition.displayName
			local key = keyLabelFor(index)
			card.key.Text = key
			card.key.Visible = key ~= ""
		end
	end
end

local function refreshCooldowns()
	for index, card in cards do
		local _, readyAttribute = AbilityConfig.attributesFor(index)
		card.readyAt = if readyAttribute then tonumber(Attributes.get(player, readyAttribute, 0)) or 0 else 0
	end
end

--[[
	Moves the placement preview to wherever the crosshair is, and colours it.

	Green or red, and the red is a real answer rather than decoration: the server
	refuses a turret with no floor under it, so a ghost that stayed green
	everywhere would be promising placements that get rejected. The test here is
	deliberately the CHEAP half of the server's — is there ground, and is it
	inside the ability's range — because the client cannot be authoritative about
	it anyway and running the expensive half twice would buy nothing.

	Recoloured only when the answer CHANGES. This runs every frame and a model
	can be a hundred parts; rewriting all of them sixty times a second to the
	colour they already were is the kind of thing that only shows up on a phone.
]]
local function stepGhost()
	local ghost = state.ghost
	if not ghost then
		return
	end
	--[[ A ghost only ever exists inside an aim, so `state.aiming` is a real slot
	     here rather than the 0 it rests at. ]]
	local card = cards[state.aiming]
	local definition = if card then AbilityConfig.get(card.id) else nil
	local character = player.Character
	local root = if character then RigUtil.getRoot(character) else nil
	local point = aimPoint()

	local ok = point ~= nil and definition ~= nil and root ~= nil
	local hint = HINT_PLACE
	local resting: Vector3? = point
	if ok then
		local aimed = point :: Vector3
		--[[ Range is checked here so a spot the server will refuse turns red
		     BEFORE the click, rather than the press being sent and quietly doing
		     nothing. The ghost keeps following the crosshair past the limit on
		     purpose — a preview that stopped moving reads as the game freezing,
		     where a red one reads as an answer. ]]
		if (aimed - (root :: BasePart).Position).Magnitude > (definition :: any).range then
			ok = false
			hint = HINT_TOO_FAR
		end
		--[[ The same floor search the server runs, so the preview stands where
		     the real one will. Without it a turret aimed at a railing previews
		     floating at railing height and then deploys on the floor below. ]]
		local ground = RaycastUtil.groundAt(aimed, 12, { character })
		if ground then
			resting = ground
		else
			ok = false
			--[[ Named second on purpose: with no floor at all there is nothing to
			     be too far from, so this is the more useful of the two. ]]
			hint = HINT_NO_GROUND
		end
	elseif point == nil then
		--[[ The crosshair is on the skybox. Same message as bad footing, because
		     to the player it is the same problem: there is nowhere to put it. ]]
		hint = HINT_NO_GROUND
	end

	if hint ~= state.hint then
		state.hint = hint
		reticleHint.Text = hint
		reticleHint.TextColor3 = if hint == HINT_PLACE then COLOR.TextSecondary else GHOST_BAD
	end

	if resting then
		--[[ Faced away from the player, which is what deploy does — a turret
		     model has a barrel, and previewing it pointed back at you would be
		     showing the wrong thing every time. Seated through the same shared
		     helper deploy uses, so the two cannot disagree about where the
		     model's feet are. ]]
		local at = resting :: Vector3
		local heading = if root
			then Vector3.new(at.X - root.Position.X, 0, at.Z - root.Position.Z)
			else Vector3.zero
		AbilityAssets.seat(ghost, at, heading)
	end

	--[[ Parented only on the frame it changes. This runs every frame and a
	     reparent is not a free property write. ]]
	local wantedParent = if resting then Workspace else nil
	if ghost.Parent ~= wantedParent then
		ghost.Parent = wantedParent
	end

	if ok ~= state.ghostOk then
		state.ghostOk = ok
		local colour = if ok then GHOST_OK else GHOST_BAD
		for _, part in ghost:GetDescendants() do
			if part:IsA("BasePart") then
				part.Color = colour
			end
		end
	end
end

--[[ Per-frame, and it writes nothing unless the WHOLE second changed. A
     countdown redrawn sixty times a second to show the same two characters is
     sixty property writes for nothing. ]]
local function step()
	local at = now()
	stepGhost()
	for index, card in cards do
		if not card.frame.Visible then
			continue
		end
		local remaining = card.readyAt - at
		local whole = if remaining > 0 then math.ceil(remaining) else 0
		if whole == card.shownWhole then
			continue
		end
		card.shownWhole = whole

		if whole <= 0 then
			card.status.Text = if state.aiming == index then "PICK A SPOT" else "READY"
			card.status.TextColor3 = if state.aiming == index then COLOR.AccentBright else COLOR.TextPrimary
			card.stroke.Color = COLOR.BorderBright
			card.frame.BackgroundTransparency = 0.3
		else
			card.status.Text = string.format("%ds", whole)
			card.status.TextColor3 = COLOR.TextDim
			card.stroke.Color = COLOR.Border
			card.frame.BackgroundTransparency = 0.62
		end
	end
end

-- ── aiming ──────────────────────────────────────────────────────────────────

local function endAim()
	if state.aiming == 0 then
		return
	end
	local slot = state.aiming
	state.aiming = 0
	aimTrove:clean()
	reticle.Visible = false

	if state.ghost then
		state.ghost:Destroy()
		state.ghost = nil
	end
	--[[ Forces the card back off its cached second, so "PICK A SPOT" is replaced
	     on the next frame rather than whenever the clock happens to tick. ]]
	local card = cards[slot]
	if card then
		card.shownWhole = -1
	end
end

local function send(slot: number, target: Vector3?)
	Remotes.Event.RequestAbility:FireServer({ slot = slot, target = target })
end

--[[
	Takes the spot under the crosshair, if it is one the server would accept.

	A RED ghost is refused here and the player stays in placement mode. The
	server would refuse it too and charge no cooldown, so nothing is lost either
	way — but being dropped out of placement with no turret and no explanation
	reads as a bug, and being left aiming with the preview still red reads as
	"not there". Only previewed abilities get this: without a ghost there is
	nothing the client has actually judged, so the press goes through and the
	server answers.
]]
local function confirmAim(slot: number)
	if state.ghost and not state.ghostOk then
		UiSound.play(AudioConfig.UI.MenuBack)
		return
	end
	local point = aimPoint()
	if point then
		send(slot, point)
	end
	endAim()
end

--[[
	Puts the player into "choose a spot" for one slot.

	A mode rather than a hold, because it has to work identically on a mouse, a
	thumbstick and a thumb — all three of them can point a camera and press a
	button, and only one of them can hold a key while doing something else. The
	crosshair IS the cursor on every scheme, which is why there is no separate
	touch path here.
]]
local function beginAim(slot: number)
	if state.aiming == slot then
		--[[ Pressing the same key again confirms, rather than doing nothing. On a
		     phone the ability button is the only thing under a thumb, so it has to
		     be both halves of the gesture. ]]
		confirmAim(slot)
		return
	end

	endAim()
	state.aiming = slot
	reticle.Visible = true

	--[[ A ghost for anything that declares one. Cheap to fail: an ability with
	     no `preview`, or a preview whose model nobody has uploaded, simply aims
	     with the reticle alone — which is exactly what the cryo field and the
	     airstrike do by design. ]]
	local definition = AbilityConfig.get(cards[slot] and cards[slot].id or "")
	if definition and definition.preview then
		state.ghost = AbilityAssets.ghost(definition.preview, GHOST_TRANSPARENCY, GHOST_OK)
		--[[ Forced to disagree, so the first stepGhost paints it whichever it
		     actually is rather than trusting the colour it was cloned with. ]]
		state.ghostOk = false
	end
	--[[ Back to the plain instruction on every entry. Without a ghost nothing
	     ever rewrites it, so an airstrike opened right after a refused turret
	     placement would still be showing that turret's complaint. ]]
	state.hint = HINT_PLACE
	reticleHint.Text = HINT_PLACE
	reticleHint.TextColor3 = COLOR.TextSecondary
	reticleLabel.Text = if definition then definition.displayName else ""
	local card = cards[slot]
	if card then
		card.shownWhole = -1
	end

	--[[
		Bound through ContextActionService and SUNK, rather than watched.

		The confirm is the fire button on every scheme — a click, a tap, or the
		right trigger — which is also the button that shoots the gun in your
		hands. A raw InputBegan listener sees the press but cannot stop it, so
		placing an airstrike also emptied a magazine into the floor in front of
		you. Bound above InputController's own priority and returning Sink, the
		shot never happens.

		Torn down with aimTrove the moment the mode ends, so nothing here can
		outlive the aim and eat a trigger pull afterwards.
	]]
	ContextActionService:BindActionAtPriority(
		AIM_ACTION,
		function(_name: string, inputState: Enum.UserInputState): Enum.ContextActionResult
			if inputState ~= Enum.UserInputState.Begin then
				return Enum.ContextActionResult.Sink
			end
			confirmAim(slot)
			return Enum.ContextActionResult.Sink
		end,
		false,
		AIM_PRIORITY,
		Enum.UserInputType.MouseButton1,
		Enum.UserInputType.Touch,
		Enum.KeyCode.ButtonR2
	)
	aimTrove:add(function()
		ContextActionService:UnbindAction(AIM_ACTION)
	end)

	--[[ Cancelling stays a plain listener. Escape and B do not need sinking —
	     Escape is Roblox's and B is crouch, and crouching as you back out of a
	     placement is harmless. ]]
	aimTrove:connect(UserInputService.InputBegan, function(input: InputObject, processed: boolean)
		if processed then
			return
		end
		if input.KeyCode == Enum.KeyCode.Escape or input.KeyCode == Enum.KeyCode.ButtonB then
			endAim()
			UiSound.play(AudioConfig.UI.MenuBack)
		end
	end)
end

-- ── public ──────────────────────────────────────────────────────────────────

--[[ A slot's key was pressed. The single entry point InputController uses; it
     knows a slot number and nothing else about abilities. ]]
function AbilityController:press(slot: number)
	local card = cards[slot]
	if not card or not card.frame.Visible then
		return
	end
	local definition = AbilityConfig.get(card.id)
	if not definition then
		return
	end

	--[[ Refused here as a courtesy, not as a gate — the server checks the same
	     thing and is the one that decides. Firing anyway would just spend a
	     round trip to be told no, and would make the card a liar. ]]
	if now() < card.readyAt then
		UiSound.play(AudioConfig.UI.MenuBack)
		return
	end

	if definition.targeted then
		beginAim(slot)
		return
	end
	send(slot, nil)
end

function AbilityController:isAiming(): boolean
	return state.aiming ~= 0
end

-- ── build ───────────────────────────────────────────────────────────────────

local function buildCard(index: number)
	local frame = Widgets.frame(stack, "Slot" .. index, COLOR.PanelRaised, 0.3)
	frame.LayoutOrder = index
	frame.Size = UDim2.fromOffset(CARD_WIDTH, CARD_HEIGHT)
	frame.Visible = false
	local stroke = Widgets.stroke(frame, COLOR.BorderBright)

	local edge = Widgets.frame(frame, "Edge", COLOR.Accent, 0)
	edge.Size = UDim2.new(0, LAYOUT.BorderThickness * 2, 1, 0)

	local name = Widgets.label(frame, "Name", FONT.Heading, TEXT.Tiny, COLOR.TextSecondary)
	name.Position = UDim2.fromOffset(LAYOUT.PanelPadding, 5)
	name.Size = UDim2.new(1, -LAYOUT.PanelPadding * 2, 0, TEXT.Tiny + 2)
	name.TextTruncate = Enum.TextTruncate.AtEnd

	local status = Widgets.label(frame, "Status", FONT.Numeric, TEXT.Body, COLOR.TextPrimary)
	status.Position = UDim2.fromOffset(LAYOUT.PanelPadding, 5 + TEXT.Tiny + 3)
	status.Size = UDim2.new(1, -LAYOUT.PanelPadding * 2, 0, TEXT.Body + 2)

	--[[ The key, in the corner, dim. It is the thing a new player needs once and
	     never again, so it is present and quiet rather than absent or loud. ]]
	local key = Widgets.label(frame, "Key", FONT.Body, TEXT.Tiny, COLOR.TextDim)
	key.AnchorPoint = Vector2.new(1, 1)
	key.Position = UDim2.new(1, -LAYOUT.PanelPadding, 1, -3)
	--[[ Wide enough for "VIEW+X", which is the longest thing this ever says. A
	     28-pixel box sized for "Z" truncated the gamepad prompt to nothing. ]]
	key.Size = UDim2.fromOffset(56, TEXT.Tiny + 2)
	key.TextXAlignment = Enum.TextXAlignment.Right

	cards[index] = {
		frame = frame,
		name = name,
		status = status,
		stroke = stroke,
		key = key,
		id = "",
		readyAt = 0,
		shownWhole = -1,
	}
end

local function build()
	gui = Instance.new("ScreenGui")
	gui.Name = "FL_Abilities"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = UITheme.DisplayOrder.Hud
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = player:WaitForChild("PlayerGui")
	trove:add(gui)

	local layer = ScaleLayer.new(gui, "Scaled")

	stack = Widgets.frame(layer, "Abilities", COLOR.Panel, 1)
	stack.AnchorPoint = Vector2.new(0, 1)
	stack.Position = UDim2.new(0, STACK_X, 1, -STACK_Y)
	stack.Size = UDim2.fromOffset(CARD_WIDTH, AbilityConfig.MaxSlots * (CARD_HEIGHT + CARD_GAP))
	Widgets.list(stack, CARD_GAP)

	for index = 1, AbilityConfig.MaxSlots do
		buildCard(index)
	end

	--[[ The targeting prompt, dead centre and above the crosshair. Deliberately
	     text rather than a world marker: the ground marker is the SERVER's, drawn
	     when the strike is actually called, and a client-side one would promise
	     something the server has not agreed to yet. ]]
	reticle = Widgets.frame(layer, "Reticle", COLOR.Panel, 1)
	reticle.AnchorPoint = Vector2.new(0.5, 0.5)
	reticle.Position = UDim2.fromScale(0.5, 0.42)
	reticle.Size = UDim2.fromOffset(320, 40)
	reticle.Visible = false

	reticleLabel = Widgets.label(reticle, "Label", FONT.Heading, TEXT.Small, COLOR.AccentBright)
	reticleLabel.Size = UDim2.new(1, 0, 0, TEXT.Small + 2)
	reticleLabel.TextXAlignment = Enum.TextXAlignment.Center

	reticleHint = Widgets.label(reticle, "Hint", FONT.Body, TEXT.Tiny, COLOR.TextSecondary)
	reticleHint.Position = UDim2.new(0, 0, 0, TEXT.Small + 6)
	reticleHint.Size = UDim2.new(1, 0, 0, TEXT.Tiny + 2)
	reticleHint.TextXAlignment = Enum.TextXAlignment.Center
	--[[ "FIRE" rather than a named button. It is the left mouse, the trigger and
	     a tap on the screen, and the one word covers all three without this file
	     having to know which scheme is in front of it. ]]
	reticleHint.Text = HINT_PLACE
end

-- ── lifecycle ───────────────────────────────────────────────────────────────

function AbilityController:init()
	build()
end

function AbilityController:start()
	for index = 1, AbilityConfig.MaxSlots do
		local idAttribute, readyAttribute = AbilityConfig.attributesFor(index)
		if idAttribute then
			trove:connect(player:GetAttributeChangedSignal(idAttribute), refreshSlots)
		end
		if readyAttribute then
			trove:connect(player:GetAttributeChangedSignal(readyAttribute), refreshCooldowns)
		end
	end
	refreshSlots()
	refreshCooldowns()

	--[[ A refusal cancels any aim in progress and says so. A success needs no
	     handling at all: the cooldown attribute is what changes, and the card is
	     already watching it. ]]
	trove:connect(Remotes.Event.AbilityResult.OnClientEvent, function(payload: any)
		if typeof(payload) ~= "table" or payload.ok ~= false then
			return
		end
		endAim()
		UiSound.play(AudioConfig.UI.MenuBack)
	end)

	--[[ Rebinding changes what the corner of a card says. Cheap to re-read and
	     it happens once in a blue moon, so it rides the same refresh. ]]
	--[[ Rebinding changes what the corner of a card says, and so does picking up
	     a controller — the prompt is per-scheme, so both have to redraw it. ]]
	local input = Registry.find("InputController")
	if input then
		if input.created then
			trove:add(input.created:connect(refreshSlots))
		end
		if input.schemeChanged then
			trove:add(input.schemeChanged:connect(refreshSlots))
		end
	end

	trove:connect(RunService.RenderStepped, step)
end

function AbilityController:destroy()
	aimTrove:destroy()
	trove:destroy()
	table.clear(cards)
end

Registry.register("AbilityController", AbilityController)

return AbilityController
