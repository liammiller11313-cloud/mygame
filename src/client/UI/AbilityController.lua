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
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local AbilityConfig = require(Shared.Config.AbilityConfig)
local Attributes = require(Shared.Net.Attributes)
local AudioConfig = require(Shared.Config.AudioConfig)
local Registry = require(Shared.Util.Registry)
local Remotes = require(Shared.Net.Remotes)
local RaycastUtil = require(Shared.Util.RaycastUtil)
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

local AbilityController = {}

local trove = Trove.new()
local aimTrove = Trove.new()

local gui: ScreenGui
local stack: Frame
local reticle: Frame
local reticleLabel: TextLabel

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
}

-- ── helpers ─────────────────────────────────────────────────────────────────

local function now(): number
	return Workspace:GetServerTimeNow()
end

--[[ What key opens this slot, for the corner of the card. Asked of
     InputController rather than assumed, because these are rebindable — and on
     a pad or a phone there is no key at all, which is why an empty string is a
     legitimate answer rather than a bug. ]]
local function keyLabelFor(slot: number): string
	local input = Registry.find("InputController")
	if not input or typeof(input.getBindings) ~= "function" then
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

--[[ The only per-frame work in this file, and it writes nothing unless the
     WHOLE second changed. A countdown redrawn sixty times a second to show the
     same two characters is sixty property writes for nothing. ]]
local function step()
	local at = now()
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
		local point = aimPoint()
		if point then
			send(slot, point)
		end
		endAim()
		return
	end

	endAim()
	state.aiming = slot
	reticle.Visible = true
	local definition = AbilityConfig.get(cards[slot] and cards[slot].id or "")
	reticleLabel.Text = if definition then definition.displayName else ""
	local card = cards[slot]
	if card then
		card.shownWhole = -1
	end

	aimTrove:connect(UserInputService.InputBegan, function(input: InputObject, processed: boolean)
		if processed then
			return
		end
		if
			input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
			or input.KeyCode == Enum.KeyCode.ButtonR2
		then
			local point = aimPoint()
			if point then
				send(slot, point)
			end
			endAim()
		elseif input.KeyCode == Enum.KeyCode.Escape or input.KeyCode == Enum.KeyCode.ButtonB then
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
	key.Size = UDim2.fromOffset(28, TEXT.Tiny + 2)
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

	local hint = Widgets.label(reticle, "Hint", FONT.Body, TEXT.Tiny, COLOR.TextSecondary)
	hint.Position = UDim2.new(0, 0, 0, TEXT.Small + 6)
	hint.Size = UDim2.new(1, 0, 0, TEXT.Tiny + 2)
	hint.TextXAlignment = Enum.TextXAlignment.Center
	hint.Text = "AIM AND FIRE TO PLACE IT"
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
	local input = Registry.find("InputController")
	if input and input.created then
		trove:add(input.created:connect(refreshSlots))
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
