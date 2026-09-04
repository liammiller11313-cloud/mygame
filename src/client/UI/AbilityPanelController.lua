--!nonstrict
--[[
	AbilityPanelController — buy them, and choose which two you take.

	── ONE SCREEN, NOT TWO ─────────────────────────────────────────────────────
	The shop and the loadout are the same list looked at twice: five abilities,
	each either locked, owned, or in a slot. Splitting them into an ABILITY SHOP
	and an ABILITIES section would mean drawing that list in two places, keeping
	both in step, and making a player who just bought something go and find
	another screen to use it on. Here, buying a row and equipping it are the same
	row and the second click.

	── THE SLOT SELECTOR IS THE WHOLE INTERACTION ──────────────────────────────
	Two buttons at the top say which slot EQUIP fills. That is a deliberate
	choice over drag-and-drop or a "change" sub-screen: it is two taps on a
	phone, two D-pad presses on a controller and two clicks on a mouse, and it is
	the same two everywhere. A player can see what is in both slots and what
	pressing EQUIP will do, at once, without a mode they have to remember being
	in.

	── AND IT DECIDES NOTHING ──────────────────────────────────────────────────
	Every button here sends a remote and waits. What is owned and what is
	equipped both come back down the profile sync — see ProfileController — so
	this panel never predicts an outcome, and a refusal simply means the screen
	does not change. The server is the only thing that knows whether a purchase
	happened.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local AbilityConfig = require(Shared.Config.AbilityConfig)
local AudioConfig = require(Shared.Config.AudioConfig)
local EconomyConfig = require(Shared.Config.EconomyConfig)
local Registry = require(Shared.Util.Registry)
local Remotes = require(Shared.Net.Remotes)
local Trove = require(Shared.Util.Trove)
local UITheme = require(Shared.Config.UITheme)

local FreeCursor = require(script.Parent.FreeCursor)
local GamepadFocus = require(script.Parent.GamepadFocus)
local ScaleLayer = require(script.Parent.ScaleLayer)
local UiSound = require(script.Parent.UiSound)
local Widgets = require(script.Parent.Widgets)

local COLOR = UITheme.Color
local FONT = UITheme.Font
local LAYOUT = UITheme.Layout
local PANEL = UITheme.Panel
local TEXT = UITheme.TextSize

local player = Players.LocalPlayer

local PANEL_WIDTH = 700
local PANEL_MAX_HEIGHT = 600
local HEADER_HEIGHT = PANEL.HeaderHeight

--[[ The slot selector is a TAP TARGET, so on touch it takes the project's row
     standard rather than the desktop height: a phone draws the whole interface
     at ScaleLayer's 0.75 floor, which turns 46 reference pixels into 34.5 real
     ones against a 42-pixel standard. ]]
local SLOTBAR_HEIGHT = 46
local SLOTBAR_HEIGHT_TOUCH = PANEL.RowHeightTouch
--[[ Sized against the TALLER of the two, so the list below starts in the same
     place on both and the slot bar never overlaps it. The few pixels a desktop
     loses are cheaper than a second layout pass that has to move the scroller
     every time the input scheme changes. ]]
local BODY_TOP = HEADER_HEIGHT + LAYOUT.PanelPadding + SLOTBAR_HEIGHT_TOUCH + LAYOUT.PanelPadding

local ROW_HEIGHT = 62
local ROW_HEIGHT_TOUCH = PANEL.RowHeightTouch + 14
local ACTION_WIDTH = 116
--[[ How much shorter than its row the action button is. Smaller on touch: at
     the desktop inset the button inside a 70-pixel row came to 54 reference
     pixels, which is 40.5 real ones — under the standard, on the one control
     that spends money. ]]
local ACTION_INSET = 16
local ACTION_INSET_TOUCH = 8

local AbilityPanelController = {}

local trove = Trove.new()

local gui: ScreenGui
local panel: Frame
local closeButton: TextButton
local balanceLabel: TextLabel
local slotBar: Frame
local list: ScrollingFrame
local hint: TextLabel

type SlotButton = { button: TextButton, label: TextLabel, name: TextLabel, stroke: UIStroke }
type Row = {
	entry: any,
	frame: Frame,
	button: TextButton,
	action: TextLabel,
	title: TextLabel,
	blurb: TextLabel,
	stroke: UIStroke,
}

local slotButtons: { SlotButton } = {}
local rows: { Row } = {}

local state = {
	open = false,
	suppressed = false,
	--[[ Which slot EQUIP fills. Never zero: a panel where pressing EQUIP does
	     nothing until you have first chosen a slot is a panel that looks
	     broken. ]]
	chosen = 1,
}

local restore = {
	cameraMode = nil :: any,
	cameraZoom = nil :: any,
	cameraMinZoom = nil :: any,
	mouseIcon = nil :: any,
}

-- ── helpers ─────────────────────────────────────────────────────────────────

local function callController(name: string, method: string, ...: any)
	local controller = Registry.find(name)
	if controller and typeof(controller[method]) == "function" then
		pcall(controller[method], controller, ...)
	end
end

local function isTouch(): boolean
	local input = Registry.find("InputController")
	if not input or typeof(input.isTouchScheme) ~= "function" then
		return false
	end
	local ok, touch = pcall(input.isTouchScheme, input)
	return ok and touch == true
end

local function menuIsOpen(): boolean
	local menu = Registry.find("MainMenuController")
	if not menu or typeof(menu.isOpen) ~= "function" then
		return false
	end
	local ok, open = pcall(menu.isOpen, menu)
	return ok and open == true
end

local function setSuppressed(value: boolean)
	if state.suppressed == value then
		return
	end
	state.suppressed = value
	callController("InputController", "setEnabled", not value)
	callController("CrosshairController", "setVisible", not value)
	callController("PromptController", "setEnabled", not value)
	callController("TouchController", "setVisible", not value)
end

local function profile(): any
	return Registry.find("ProfileController")
end

local function ownsAbility(id: string): boolean
	local store = profile()
	if not store or typeof(store.ownsAbility) ~= "function" then
		return false
	end
	local ok, owns = pcall(store.ownsAbility, store, id)
	return ok and owns == true
end

local function slotOf(id: string): number
	local store = profile()
	if not store or typeof(store.abilitySlotOf) ~= "function" then
		return 0
	end
	local ok, slot = pcall(store.abilitySlotOf, store, id)
	return if ok and typeof(slot) == "number" then slot else 0
end

local function dollars(): number
	local store = profile()
	if not store or typeof(store.getDollars) ~= "function" then
		return 0
	end
	local ok, value = pcall(store.getDollars, store)
	return if ok and typeof(value) == "number" then value else 0
end

-- ── drawing ─────────────────────────────────────────────────────────────────

local function refresh()
	if not state.open then
		return
	end

	local balance = dollars()
	-- format() already carries EconomyConfig.Symbol; prefixing it again doubles it.
	balanceLabel.Text = EconomyConfig.format(balance)

	for index, slotButton in slotButtons do
		local store = profile()
		local slots = if store and typeof(store.getAbilitySlots) == "function"
			then store:getAbilitySlots()
			else {}
		local equipped = AbilityConfig.get(slots[index] or "")
		slotButton.name.Text = if equipped then equipped.displayName else "EMPTY"
		slotButton.name.TextColor3 = if equipped then COLOR.TextPrimary else COLOR.TextDim
		local active = state.chosen == index
		slotButton.stroke.Color = if active then COLOR.BorderBright else COLOR.Border
		slotButton.button.BackgroundTransparency = if active then PANEL.ActionFill else 0.62
		slotButton.label.TextColor3 = if active then COLOR.Accent else COLOR.TextDim
	end

	for _, row in rows do
		local id = row.entry.id
		local owned = ownsAbility(id)
		local slot = slotOf(id)

		if not owned then
			local affordable = balance >= row.entry.price
			row.action.Text = EconomyConfig.format(row.entry.price)
			row.action.TextColor3 = if affordable then COLOR.TextPrimary else COLOR.Danger
			row.stroke.Color = COLOR.Border
			row.title.TextColor3 = COLOR.TextSecondary
		elseif slot > 0 then
			row.action.Text = "SLOT " .. slot
			row.action.TextColor3 = COLOR.Accent
			row.stroke.Color = COLOR.Accent
			row.title.TextColor3 = COLOR.Accent
		else
			row.action.Text = "EQUIP"
			row.action.TextColor3 = COLOR.TextPrimary
			row.stroke.Color = COLOR.BorderBright
			row.title.TextColor3 = COLOR.TextPrimary
		end
	end
end

--[[ One button, three meanings, decided by what the player has rather than by a
     mode they are in: buy it, put it in the chosen slot, or take it out again.
     A row that showed BUY and EQUIP side by side would have one of them
     disabled at all times. ]]
local function activate(row: Row)
	local id = row.entry.id

	if not ownsAbility(id) then
		Remotes.Event.PurchaseAbility:FireServer(id)
		UiSound.play(AudioConfig.UI.MenuConfirm)
		return
	end

	local slot = slotOf(id)
	if slot > 0 then
		Remotes.Event.SetAbilitySlot:FireServer({ slot = slot, id = "" })
	else
		Remotes.Event.SetAbilitySlot:FireServer({ slot = state.chosen, id = id })
	end
	UiSound.play(AudioConfig.UI.MenuConfirm)
end

-- ── build ───────────────────────────────────────────────────────────────────

local function applyTouchSizing()
	local touch = isTouch()
	local height = if touch then ROW_HEIGHT_TOUCH else ROW_HEIGHT
	local inset = if touch then ACTION_INSET_TOUCH else ACTION_INSET
	for _, row in rows do
		row.frame.Size = UDim2.new(1, -PANEL.ScrollBarWidth - 2, 0, height)
		row.button.Size = UDim2.fromOffset(ACTION_WIDTH, height - inset)
		row.button.Position = UDim2.new(1, -LAYOUT.PanelPadding, 0, inset * 0.5)
	end

	local barHeight = if touch then SLOTBAR_HEIGHT_TOUCH else SLOTBAR_HEIGHT
	slotBar.Size = UDim2.new(1, -LAYOUT.PanelPadding * 2, 0, barHeight)
	for _, slotButton in slotButtons do
		slotButton.button.Size = UDim2.new(0, slotButton.button.Size.X.Offset, 0, barHeight)
	end
	if list then
		list.Size =
			UDim2.new(1, -LAYOUT.PanelPadding * 2, 1, -(BODY_TOP + PANEL.FooterHeight + LAYOUT.PanelPadding))
	end
end

local function refreshPanelSize()
	if not panel then
		return
	end
	local camera = Workspace.CurrentCamera
	local factor = ScaleLayer.getFactor()
	local viewport = if camera and factor > 0 then camera.ViewportSize / factor else nil
	local width = math.min(
		PANEL_WIDTH,
		math.max((if viewport then viewport.X else PANEL_WIDTH) - LAYOUT.ScreenMargin * 2, 300)
	)
	local height =
		math.min(PANEL_MAX_HEIGHT, (if viewport then viewport.Y else PANEL_MAX_HEIGHT) * PANEL.HeightScale)
	panel.Size = UDim2.fromOffset(width, height)
end

local function buildSlotButton(index: number, width: number)
	local button = Widgets.button(slotBar, "Slot" .. index)
	button.Position = UDim2.new(0, (index - 1) * (width + LAYOUT.ElementGap), 0, 0)
	button.Size = UDim2.fromOffset(width, SLOTBAR_HEIGHT)
	button.BackgroundColor3 = COLOR.PanelRaised
	button.BackgroundTransparency = 0.62
	local stroke = Widgets.stroke(button, COLOR.Border)

	local label = Widgets.label(button, "Label", FONT.Body, TEXT.Tiny, COLOR.TextDim)
	label.Position = UDim2.fromOffset(LAYOUT.PanelPadding, 5)
	label.Size = UDim2.new(1, -LAYOUT.PanelPadding * 2, 0, TEXT.Tiny + 2)
	label.Text = "SLOT " .. index

	local name = Widgets.label(button, "Name", FONT.Heading, TEXT.Body, COLOR.TextPrimary)
	name.Position = UDim2.fromOffset(LAYOUT.PanelPadding, 5 + TEXT.Tiny + 2)
	name.Size = UDim2.new(1, -LAYOUT.PanelPadding * 2, 0, TEXT.Body + 2)
	name.TextTruncate = Enum.TextTruncate.AtEnd

	trove:connect(button.Activated, function()
		state.chosen = index
		UiSound.play(AudioConfig.UI.MenuHover)
		refresh()
	end)

	slotButtons[index] = { button = button, label = label, name = name, stroke = stroke }
end

local function buildRow(entry: any)
	local row = Widgets.frame(list, entry.id, COLOR.PanelRaised, PANEL.RaisedFill)
	row.LayoutOrder = entry.price
	row.Size = UDim2.new(1, -PANEL.ScrollBarWidth - 2, 0, ROW_HEIGHT)
	local stroke = Widgets.stroke(row, COLOR.Border)

	local edge = Widgets.frame(row, "Edge", COLOR.Accent, 0)
	edge.Size = UDim2.new(0, LAYOUT.BorderThickness * 2, 1, 0)

	local title = Widgets.label(row, "Title", FONT.Heading, TEXT.Body, COLOR.TextPrimary)
	title.Position = UDim2.fromOffset(LAYOUT.PanelPadding + 4, 8)
	title.Size = UDim2.new(1, -(ACTION_WIDTH + LAYOUT.PanelPadding * 3), 0, TEXT.Body + 2)
	title.TextTruncate = Enum.TextTruncate.AtEnd
	title.Text = entry.displayName

	local blurb = Widgets.label(row, "Blurb", FONT.Body, TEXT.Small, COLOR.TextSecondary)
	blurb.Position = UDim2.fromOffset(LAYOUT.PanelPadding + 4, 8 + TEXT.Body + 4)
	blurb.Size = UDim2.new(1, -(ACTION_WIDTH + LAYOUT.PanelPadding * 3), 0, TEXT.Small + 2)
	blurb.TextTruncate = Enum.TextTruncate.AtEnd
	blurb.Text = entry.blurb

	local button = Widgets.button(row, "Action")
	button.AnchorPoint = Vector2.new(1, 0)
	button.Position = UDim2.new(1, -LAYOUT.PanelPadding, 0, 8)
	button.Size = UDim2.fromOffset(ACTION_WIDTH, ROW_HEIGHT - 16)
	button.BackgroundColor3 = COLOR.PanelRaised
	button.BackgroundTransparency = PANEL.ActionFill
	Widgets.stroke(button, COLOR.Border)

	local action = Widgets.label(button, "Label", FONT.Heading, TEXT.Small, COLOR.TextPrimary)
	action.Size = UDim2.fromScale(1, 1)
	action.TextXAlignment = Enum.TextXAlignment.Center

	local record: Row = {
		entry = entry,
		frame = row,
		button = button,
		action = action,
		title = title,
		blurb = blurb,
		stroke = stroke,
	}
	trove:connect(button.Activated, function()
		activate(record)
	end)
	table.insert(rows, record)
end

local function build()
	gui = Instance.new("ScreenGui")
	gui.Name = "FL_Abilities_Panel"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = UITheme.DisplayOrder.Settings
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Enabled = false
	gui.Parent = player:WaitForChild("PlayerGui")
	trove:add(gui)

	local layer = ScaleLayer.new(gui, "Scaled")
	local chrome = Widgets.panel(layer, trove, "ABILITIES", function()
		AbilityPanelController:close()
	end)
	panel = chrome.frame
	closeButton = chrome.close

	balanceLabel = Widgets.label(panel, "Balance", FONT.Numeric, TEXT.Body, COLOR.Accent)
	balanceLabel.AnchorPoint = Vector2.new(1, 0)
	balanceLabel.Position = UDim2.new(1, -(PANEL.CloseWidth + LAYOUT.PanelPadding * 2), 0, 0)
	balanceLabel.Size = UDim2.new(0.3, 0, 0, HEADER_HEIGHT)
	balanceLabel.TextXAlignment = Enum.TextXAlignment.Right

	slotBar = Widgets.frame(panel, "Slots", COLOR.Panel, 1)
	slotBar.Position = UDim2.fromOffset(LAYOUT.PanelPadding, HEADER_HEIGHT + LAYOUT.PanelPadding)
	slotBar.Size = UDim2.new(1, -LAYOUT.PanelPadding * 2, 0, SLOTBAR_HEIGHT)

	--[[ Sized from MaxSlots rather than laid out for two, so a third slot fits
	     the bar rather than falling off the end of it. ]]
	local count = AbilityConfig.MaxSlots
	local slotWidth = (PANEL_WIDTH - LAYOUT.PanelPadding * 2 - LAYOUT.ElementGap * (count - 1)) / count
	for index = 1, count do
		buildSlotButton(index, slotWidth)
	end

	list = Widgets.scroller(panel, "List")
	list.Position = UDim2.fromOffset(LAYOUT.PanelPadding, BODY_TOP)
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	Widgets.list(list, LAYOUT.ElementGap)
	for _, entry in AbilityConfig.Definitions do
		buildRow(entry)
	end

	local footRule = Widgets.frame(panel, "FootRule", COLOR.Border, 0)
	footRule.AnchorPoint = Vector2.new(0, 1)
	footRule.Position = UDim2.new(0, 0, 1, -PANEL.FooterHeight)
	footRule.Size = UDim2.new(1, 0, 0, LAYOUT.BorderThickness)

	hint = Widgets.label(panel, "Hint", FONT.Body, TEXT.Small, COLOR.TextDim)
	hint.AnchorPoint = Vector2.new(0, 1)
	hint.Position = UDim2.new(0, LAYOUT.PanelPadding, 1, 0)
	hint.Size = UDim2.new(1, -LAYOUT.PanelPadding * 2, 0, PANEL.FooterHeight)
	hint.Text = "PICK A SLOT, THEN EQUIP. ABILITIES ARE YOURS FOR GOOD ONCE BOUGHT."

	applyTouchSizing()
	refreshPanelSize()
end

-- ── public API ──────────────────────────────────────────────────────────────

function AbilityPanelController:isOpen(): boolean
	return state.open
end

function AbilityPanelController:open()
	if state.open then
		return
	end
	state.open = true
	gui.Enabled = true
	applyTouchSizing()
	refreshPanelSize()
	refresh()
	setSuppressed(not menuIsOpen())
	FreeCursor.take(restore)
	GamepadFocus.capture(if slotButtons[1] then slotButtons[1].button else closeButton)
	UiSound.play(AudioConfig.UI.MenuConfirm)
end

function AbilityPanelController:close()
	if not state.open then
		return
	end
	state.open = false
	gui.Enabled = false
	GamepadFocus.release(closeButton)
	setSuppressed(false)
	FreeCursor.giveBack(restore)
	if menuIsOpen() then
		callController("MainMenuController", "reassertSuppression")
	end
	UiSound.play(AudioConfig.UI.MenuBack)
end

function AbilityPanelController:toggle()
	if state.open then
		self:close()
	else
		self:open()
	end
end

-- ── lifecycle ───────────────────────────────────────────────────────────────

function AbilityPanelController:init()
	build()
end

function AbilityPanelController:start()
	--[[ Redrawn off the profile mirror rather than off the remotes. A purchase
	     and an equip both end as a profile sync, so one signal covers both and
	     the panel cannot draw a state the server has not agreed to. ]]
	local store = Registry.find("ProfileController")
	if store and store.changed then
		trove:add(store.changed:connect(refresh))
	end

	trove:connect(UserInputService.InputBegan, function(input: InputObject, processed: boolean)
		if not state.open then
			return
		end
		if input.KeyCode == Enum.KeyCode.ButtonB then
			AbilityPanelController:close()
			return
		end
		if not processed and input.KeyCode == Enum.KeyCode.Escape then
			AbilityPanelController:close()
		end
	end)

	local viewportConnection: RBXScriptConnection? = nil
	local function watchViewport()
		if viewportConnection then
			viewportConnection:Disconnect()
			viewportConnection = nil
		end
		local camera = Workspace.CurrentCamera
		if camera then
			viewportConnection = camera:GetPropertyChangedSignal("ViewportSize"):Connect(refreshPanelSize)
		end
		refreshPanelSize()
	end
	trove:add(function()
		if viewportConnection then
			viewportConnection:Disconnect()
		end
	end)
	trove:connect(Workspace:GetPropertyChangedSignal("CurrentCamera"), watchViewport)
	watchViewport()
end

function AbilityPanelController:destroy()
	trove:destroy()
	table.clear(rows)
	table.clear(slotButtons)
end

Registry.register("AbilityPanelController", AbilityPanelController)

return AbilityPanelController
