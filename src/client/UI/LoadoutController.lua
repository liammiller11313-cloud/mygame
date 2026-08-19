--!nonstrict
--[[
	LoadoutController — the three kits you keep, and the one you spawn with.

	Two screens in one file because they are two views of one thing:

	  THE PANEL   opened from the main menu. Three loadouts down the left, the
	              selected one's two slots on the right, and a weapon picker that
	              takes over the right-hand side when you change a slot.
	  THE PICKER  a strip along the bottom while a round is starting. Three
	              buttons, no editing. It is the answer to "which one am I taking
	              in" asked at the only moment it matters.

	── WHY THE PICKER IS NOT A MODAL ────────────────────────────────────────────
	A round starting is not a good moment to cover the screen. The strip sits at
	the bottom, takes no input away from anything, and goes when the round starts
	or when you have chosen — so a player who ignores it entirely loses nothing
	and spawns with whatever they had.

	── THE LIST SHOWS WHAT YOU CANNOT AFFORD ────────────────────────────────────
	Every weapon in the roster appears in the slot picker, with what you have not
	bought greyed and priced. A list that hid them would never tell anybody what
	to save for, and the shop is one button away.

	── NOTHING IS EDITED IN PLACE ───────────────────────────────────────────────
	Changing a slot builds a COPY of the loadout, sends it, and waits for the
	sync. ProfileController's table is never written to by this file, so a screen
	closed halfway through an edit leaves nothing half-changed behind it.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local AudioConfig = require(Shared.Config.AudioConfig)
local EconomyConfig = require(Shared.Config.EconomyConfig)
local Enums = require(Shared.Enums)
local LoadoutConfig = require(Shared.Config.LoadoutConfig)
local Registry = require(Shared.Util.Registry)
local Remotes = require(Shared.Net.Remotes)
local Trove = require(Shared.Util.Trove)
local UITheme = require(Shared.Config.UITheme)
local WeaponConfig = require(Shared.Config.WeaponConfig)

local GamepadFocus = require(script.Parent.GamepadFocus)
local ScaleLayer = require(script.Parent.ScaleLayer)
local WeaponPreview = require(script.Parent.WeaponPreview)
local Widgets = require(script.Parent.Widgets)

local COLOR = UITheme.Color
local FONT = UITheme.Font
local LAYOUT = UITheme.Layout
local PANEL = UITheme.Panel
local TEXT = UITheme.TextSize
local ROUND = Enums.RoundState

local player = Players.LocalPlayer

-- ── layout, in reference pixels ─────────────────────────────────────────────
--[[ The two numbers that are this screen's own: three cards beside a preview
     column, and how tall that is worth growing. The chrome around them comes
     from UITheme.Panel. ]]
local PANEL_WIDTH = 820
local PANEL_MAX_HEIGHT = 520

local HEADER_HEIGHT = PANEL.HeaderHeight

local CARD_WIDTH = 0.32
local CARD_HEIGHT = 96
local CARD_GAP = 10

local SLOT_HEIGHT = 52
local PICK_ROW_HEIGHT = 38
local PICK_ROW_HEIGHT_TOUCH = 50

local PREVIEW_HEIGHT = 0.44

--[[ How long the round-start picker stays up. Long enough to read three names
     and press one, short enough that it is gone before the first Common. ]]
local PICKER_SECONDS = 12
local PICKER_HEIGHT = 74

local LoadoutController = {}

local trove = Trove.new()
local rowTrove = Trove.new()

local gui: ScreenGui
local panel: Frame
local right: Frame
local preview: WeaponPreview.Preview
local previewMissing: TextLabel
local slotRows: { any } = {}
local cards: { any } = {}
local pickList: ScrollingFrame
local pickTitle: TextLabel
local pickBack: TextButton
local activeButton: TextButton
local activeLabel: TextLabel

local pickerGui: ScreenGui
local pickerButtons: { any } = {}
local pickerClock: TextLabel

local state = {
	open = false,
	--[[ Which of the three the panel is showing. Not the same as the ACTIVE one:
	     you edit one loadout while spawning with another, which is most of the
	     point of having three. ]]
	editing = 1,
	--[[ The slot whose weapon list is on screen, or "" when the two slot rows
	     are. The right-hand column is one of those two things and never both. ]]
	choosing = "",
	pickerUntil = 0,
	firstCard = nil :: TextButton?,
}

-- ── small helpers ───────────────────────────────────────────────────────────

local function profile(): any
	return Registry.find("ProfileController")
end

local function callController(name: string, method: string, ...: any)
	local controller = Registry.find(name)
	if controller and typeof(controller[method]) == "function" then
		pcall(controller[method], controller, ...)
	end
end

local function playUi(definition: any)
	if not AudioConfig.isConfigured(definition) then
		return
	end
	local sound = Instance.new("Sound")
	sound.Name = "FL_Loadout"
	sound.SoundId = AudioConfig.pickId(definition)
	sound.Volume = definition.volume
	sound.Parent = SoundService
	sound:Play()
	sound.Ended:Once(function()
		sound:Destroy()
	end)
end

local function isTouch(): boolean
	local input = Registry.find("InputController")
	if not input or typeof(input.isTouchScheme) ~= "function" then
		return false
	end
	local ok, touch = pcall(input.isTouchScheme, input)
	return ok and touch == true
end

local function weaponName(weaponId: string?): string
	local definition = if typeof(weaponId) == "string" then WeaponConfig.get(weaponId) else nil
	return if definition then string.upper(definition.displayName) else "—"
end

local function slotLabel(slot: string): string
	return if slot == Enums.Slot.Primary then "PRIMARY" else "SIDEARM"
end

--[[ The loadout the panel is currently editing, as it exists on the server.
     Read fresh every time rather than cached: a sync can land between two
     draws, and a stale copy is how a screen shows a weapon you just replaced. ]]
local function editing(): LoadoutConfig.Loadout
	local store = profile()
	return if store then store:getLoadout(state.editing) else LoadoutConfig.sanitise(nil, nil)
end

-- ── drawing: the three cards ────────────────────────────────────────────────

local function refreshCards()
	local store = profile()
	local active = if store then store:getActiveIndex() else 1

	for index, card in cards do
		local loadout = if store then store:getLoadout(index) else LoadoutConfig.sanitise(nil, nil)
		card.primary.Text = weaponName(loadout[Enums.Slot.Primary])
		card.secondary.Text = weaponName(loadout[Enums.Slot.Secondary])

		local isActive = index == active
		local isEditing = index == state.editing
		card.badge.Visible = isActive
		card.stroke.Color = if isEditing
			then COLOR.Accent
			elseif isActive then COLOR.BorderBright
			else COLOR.Border
		card.stroke.Thickness = if isEditing then LAYOUT.BorderThickness + 1 else LAYOUT.BorderThickness
		card.title.TextColor3 = if isEditing then COLOR.AccentBright else COLOR.TextPrimary
	end

	local isActive = state.editing == active
	activeLabel.Text = if isActive then "SPAWNING WITH THIS" else "SPAWN WITH THIS"
	activeLabel.TextColor3 = if isActive then COLOR.TextSecondary else COLOR.AccentBright
	activeButton.Selectable = not isActive
	activeButton.BackgroundTransparency = if isActive then 0.7 else 0.15
end

-- ── drawing: the two slot rows ──────────────────────────────────────────────

local function showPreviewFor(weaponId: string?)
	local shown = preview:setWeapon(weaponId)
	previewMissing.Visible = not shown
	previewMissing.Text = "NO MODEL SUPPLIED"
end

local function refreshSlots()
	local loadout = editing()
	for _, row in slotRows do
		local weaponId = loadout[row.slot]
		row.value.Text = weaponName(weaponId)
		local definition = WeaponConfig.get(weaponId)
		row.detail.Text = if definition
			then string.format(
				"%s · %d DMG · %d RPM",
				string.upper(definition.class),
				definition.damage,
				definition.rpm
			)
			else ""
	end
	--[[ The primary is what the preview shows by default: it is the weapon a
	     player spends the round holding, and a sidearm in the window while the
	     rifle line sits above it reads as the wrong one being highlighted. ]]
	showPreviewFor(loadout[Enums.Slot.Primary])
end

-- ── drawing: the weapon picker ──────────────────────────────────────────────

local function releasePickRows()
	rowTrove:clean()
	for _, child in pickList:GetChildren() do
		if child:IsA("TextButton") then
			child:Destroy()
		end
	end
end

--[[ Writes one slot of the loadout being edited and sends the whole thing.
     A copy, never the stored table — see the header. ]]
local function chooseWeapon(slot: string, weaponId: string)
	local store = profile()
	if not store or not store:owns(weaponId) then
		return
	end
	local next_: LoadoutConfig.Loadout = {}
	for _, each in LoadoutConfig.Slots do
		next_[each] = editing()[each]
	end
	next_[slot] = weaponId

	store:setLoadout(state.editing, next_)
	playUi(AudioConfig.UI.MenuConfirm)
	LoadoutController:_closePicker()
end

local function buildPickRow(slot: string, weaponId: string, index: number)
	local store = profile()
	local owned = store and store:owns(weaponId)
	local price = EconomyConfig.priceOf(weaponId)
	local height = if isTouch() then PICK_ROW_HEIGHT_TOUCH else PICK_ROW_HEIGHT

	local button = Widgets.button(pickList, weaponId)
	button.Size = UDim2.new(1, -(PANEL.ScrollBarWidth + LAYOUT.ElementGap), 0, height)
	button.LayoutOrder = index
	button.BackgroundColor3 = COLOR.TextPrimary
	button.Selectable = owned == true

	local name = Widgets.label(button, "Name", FONT.Heading, TEXT.Body, COLOR.TextPrimary)
	name.Position = UDim2.fromOffset(LAYOUT.PanelPadding, 0)
	name.Size = UDim2.new(0.6, 0, 1, 0)
	name.Text = weaponName(weaponId)
	name.TextColor3 = if owned then COLOR.TextPrimary else COLOR.TextDim

	local status = Widgets.label(button, "Status", FONT.Numeric, TEXT.Small, COLOR.TextDim)
	status.AnchorPoint = Vector2.new(1, 0)
	status.Position = UDim2.new(1, -LAYOUT.PanelPadding, 0, 0)
	status.Size = UDim2.new(0.38, 0, 1, 0)
	status.TextXAlignment = Enum.TextXAlignment.Right
	if owned then
		local current = editing()[slot] == weaponId
		status.Text = if current then "EQUIPPED" else ""
		status.TextColor3 = COLOR.Accent
	else
		status.Text = if price then "LOCKED · " .. EconomyConfig.format(price) else "LOCKED"
	end

	local rule = Widgets.frame(button, "Rule", COLOR.Border, 0.6)
	rule.AnchorPoint = Vector2.new(0, 1)
	rule.Position = UDim2.new(0, 0, 1, 0)
	rule.Size = UDim2.new(1, 0, 0, LAYOUT.BorderThickness)

	rowTrove:connect(button.Activated, function()
		if owned then
			chooseWeapon(slot, weaponId)
		else
			--[[ A locked row is not a dead row. Pressing it opens the shop on
			     the thing you just tried to equip, which is the only useful
			     thing it could do. ]]
			playUi(AudioConfig.UI.MenuBack)
			LoadoutController:close()
			callController("ShopController", "open")
		end
	end)
	--[[ Only what can be picked lights up. A LOCKED row that highlights under the
	     cursor is a row promising something it will not do. It still updates the
	     preview, because seeing what you have not bought yet is the point. ]]
	if owned then
		Widgets.rowHover(rowTrove, button)
	end
	rowTrove:connect(button.MouseEnter, function()
		showPreviewFor(weaponId)
	end)
end

function LoadoutController:_openPicker(slot: string)
	state.choosing = slot
	releasePickRows()

	local candidates = LoadoutConfig.candidates(slot)
	for index, weaponId in candidates do
		buildPickRow(slot, weaponId, index)
	end

	local height = if isTouch() then PICK_ROW_HEIGHT_TOUCH else PICK_ROW_HEIGHT
	pickList.CanvasPosition = Vector2.zero
	pickList.CanvasSize = UDim2.fromOffset(0, #candidates * height)
	pickTitle.Text = "CHOOSE A " .. slotLabel(slot)

	pickList.Visible = true
	pickTitle.Visible = true
	pickBack.Visible = true
	for _, row in slotRows do
		row.button.Visible = false
	end
	activeButton.Visible = false
end

function LoadoutController:_closePicker()
	state.choosing = ""
	releasePickRows()
	pickList.Visible = false
	pickTitle.Visible = false
	pickBack.Visible = false
	for _, row in slotRows do
		row.button.Visible = true
	end
	activeButton.Visible = true
	refreshSlots()
	refreshCards()
end

-- ── the round-start picker ──────────────────────────────────────────────────

local function refreshPickerButtons()
	local store = profile()
	local active = if store then store:getActiveIndex() else 1
	for index, entry in pickerButtons do
		local loadout = if store then store:getLoadout(index) else LoadoutConfig.sanitise(nil, nil)
		entry.name.Text = weaponName(loadout[Enums.Slot.Primary])
		entry.sub.Text = weaponName(loadout[Enums.Slot.Secondary])
		local selected = index == active
		entry.stroke.Color = if selected then COLOR.Accent else COLOR.Border
		entry.stroke.Thickness = if selected then LAYOUT.BorderThickness + 1 else LAYOUT.BorderThickness
		entry.title.TextColor3 = if selected then COLOR.AccentBright else COLOR.TextSecondary
	end
end

local function setPickerVisible(visible: boolean)
	if not pickerGui then
		return
	end
	pickerGui.Enabled = visible
	if visible then
		state.pickerUntil = os.clock() + PICKER_SECONDS
		refreshPickerButtons()
	else
		state.pickerUntil = 0
	end
end

-- ── build: the panel ────────────────────────────────────────────────────────

local function buildCard(index: number, parent: Frame)
	local button = Widgets.button(parent, "Card" .. index)
	button.Position = UDim2.new(0, 0, 0, (index - 1) * (CARD_HEIGHT + CARD_GAP))
	button.Size = UDim2.new(1, 0, 0, CARD_HEIGHT)
	button.BackgroundColor3 = COLOR.PanelRaised
	button.BackgroundTransparency = PANEL.RaisedFill
	local stroke = Widgets.stroke(button, COLOR.Border)

	local title = Widgets.label(button, "Title", FONT.Heading, TEXT.Body, COLOR.TextPrimary)
	title.Position = UDim2.fromOffset(LAYOUT.PanelPadding, 4)
	title.Size = UDim2.new(1, -LAYOUT.PanelPadding * 2, 0, TEXT.Large)
	title.Text = LoadoutConfig.defaultName(index)

	local badge = Widgets.label(button, "Badge", FONT.Body, TEXT.Tiny, COLOR.Accent)
	badge.AnchorPoint = Vector2.new(1, 0)
	badge.Position = UDim2.new(1, -LAYOUT.PanelPadding, 0, 6)
	badge.Size = UDim2.fromOffset(60, TEXT.Body)
	badge.TextXAlignment = Enum.TextXAlignment.Right
	badge.Text = "ACTIVE"
	badge.Visible = false

	local primary = Widgets.label(button, "Primary", FONT.Body, TEXT.Small, COLOR.TextSecondary)
	primary.Position = UDim2.fromOffset(LAYOUT.PanelPadding, TEXT.Large + 8)
	primary.Size = UDim2.new(1, -LAYOUT.PanelPadding * 2, 0, TEXT.Body)

	local secondary = Widgets.label(button, "Secondary", FONT.Body, TEXT.Small, COLOR.TextDim)
	secondary.Position = UDim2.fromOffset(LAYOUT.PanelPadding, TEXT.Large + TEXT.Body + 10)
	secondary.Size = UDim2.new(1, -LAYOUT.PanelPadding * 2, 0, TEXT.Body)

	cards[index] = {
		button = button,
		stroke = stroke,
		title = title,
		badge = badge,
		primary = primary,
		secondary = secondary,
	}
	state.firstCard = state.firstCard or button

	trove:connect(button.Activated, function()
		if state.editing == index then
			return
		end
		state.editing = index
		playUi(AudioConfig.UI.MenuHover)
		LoadoutController:_closePicker()
	end)
end

local function buildSlotRow(index: number, slot: string)
	local button = Widgets.button(right, "Slot" .. slot)
	button.Position = UDim2.new(0, 0, PREVIEW_HEIGHT, (index - 1) * (SLOT_HEIGHT + 6))
	button.Size = UDim2.new(1, 0, 0, SLOT_HEIGHT)
	button.BackgroundColor3 = COLOR.PanelRaised
	button.BackgroundTransparency = PANEL.RaisedFill
	local stroke = Widgets.stroke(button, COLOR.Border)

	local label = Widgets.label(button, "Label", FONT.Body, TEXT.Tiny, COLOR.TextDim)
	label.Position = UDim2.fromOffset(LAYOUT.PanelPadding, 4)
	label.Size = UDim2.new(0.5, 0, 0, TEXT.Body)
	label.Text = slotLabel(slot)

	local value = Widgets.label(button, "Value", FONT.Heading, TEXT.Body, COLOR.TextPrimary)
	value.Position = UDim2.fromOffset(LAYOUT.PanelPadding, TEXT.Body + 2)
	value.Size = UDim2.new(0.7, 0, 0, TEXT.Large)

	local detail = Widgets.label(button, "Detail", FONT.Body, TEXT.Tiny, COLOR.TextDim)
	detail.AnchorPoint = Vector2.new(1, 1)
	detail.Position = UDim2.new(1, -(LAYOUT.PanelPadding + 22), 1, -6)
	detail.Size = UDim2.new(0.6, 0, 0, TEXT.Body)
	detail.TextXAlignment = Enum.TextXAlignment.Right

	local chevron = Widgets.label(button, "Chevron", FONT.Heading, TEXT.Large, COLOR.TextDim)
	chevron.AnchorPoint = Vector2.new(1, 0.5)
	chevron.Position = UDim2.new(1, -LAYOUT.PanelPadding, 0.5, 0)
	chevron.Size = UDim2.fromOffset(16, SLOT_HEIGHT)
	chevron.TextXAlignment = Enum.TextXAlignment.Right
	chevron.Text = ">"

	slotRows[index] = { slot = slot, button = button, value = value, detail = detail, stroke = stroke }

	trove:connect(button.Activated, function()
		playUi(AudioConfig.UI.MenuHover)
		LoadoutController:_openPicker(slot)
	end)
	Widgets.outlineHover(trove, button, stroke)
	trove:connect(button.MouseEnter, function()
		showPreviewFor(editing()[slot])
	end)
end

local function buildPanel(layer: Frame)
	local chrome = Widgets.panel(layer, trove, "LOADOUTS", function()
		LoadoutController:close()
	end)
	panel = chrome.frame

	local body = Widgets.frame(panel, "Body", COLOR.Panel, 1)
	body.Position = UDim2.fromOffset(LAYOUT.PanelPadding, HEADER_HEIGHT + LAYOUT.PanelPadding)
	body.Size = UDim2.new(1, -LAYOUT.PanelPadding * 2, 1, -(HEADER_HEIGHT + LAYOUT.PanelPadding * 2))

	local left = Widgets.frame(body, "Cards", COLOR.Panel, 1)
	left.Size = UDim2.new(CARD_WIDTH, 0, 1, 0)
	for index = 1, LoadoutConfig.MaxLoadouts do
		buildCard(index, left)
	end

	right = Widgets.frame(body, "Right", COLOR.Panel, 1)
	right.Position = UDim2.new(CARD_WIDTH, LAYOUT.ScreenMargin, 0, 0)
	right.Size = UDim2.new(1 - CARD_WIDTH, -LAYOUT.ScreenMargin, 1, 0)

	preview = WeaponPreview.new(right, "Preview")
	preview.frame.Size = UDim2.new(1, 0, PREVIEW_HEIGHT, 0)

	previewMissing = Widgets.label(right, "NoModel", FONT.Body, TEXT.Small, COLOR.TextDim)
	previewMissing.AnchorPoint = Vector2.new(0.5, 0.5)
	previewMissing.Position = UDim2.new(0.5, 0, PREVIEW_HEIGHT * 0.5, 0)
	previewMissing.Size = UDim2.new(1, 0, 0, TEXT.Body)
	previewMissing.TextXAlignment = Enum.TextXAlignment.Center
	previewMissing.Visible = false

	for index, slot in LoadoutConfig.Slots do
		buildSlotRow(index, slot)
	end

	activeButton = Widgets.button(right, "SetActive")
	activeButton.AnchorPoint = Vector2.new(1, 1)
	activeButton.Position = UDim2.new(1, 0, 1, 0)
	activeButton.Size = UDim2.fromOffset(230, 38)
	activeButton.BackgroundColor3 = COLOR.PanelRaised
	activeButton.BackgroundTransparency = PANEL.ActionFill
	Widgets.stroke(activeButton, COLOR.Border)
	activeLabel = Widgets.label(activeButton, "Label", FONT.Heading, TEXT.Body, COLOR.AccentBright)
	activeLabel.Size = UDim2.fromScale(1, 1)
	activeLabel.TextXAlignment = Enum.TextXAlignment.Center
	trove:connect(activeButton.Activated, function()
		local store = profile()
		if store and store:getActiveIndex() ~= state.editing then
			store:setActive(state.editing)
			playUi(AudioConfig.UI.MenuConfirm)
			refreshCards()
		end
	end)

	-- The slot picker, which takes over the right column when a slot is pressed.
	pickTitle = Widgets.label(right, "PickTitle", FONT.Heading, TEXT.Body, COLOR.AccentBright)
	pickTitle.Position = UDim2.new(0, 0, PREVIEW_HEIGHT, 0)
	pickTitle.Size = UDim2.new(0.6, 0, 0, TEXT.Large)
	pickTitle.Visible = false

	pickBack = Widgets.button(right, "PickBack")
	pickBack.AnchorPoint = Vector2.new(1, 0)
	pickBack.Position = UDim2.new(1, 0, PREVIEW_HEIGHT, 0)
	pickBack.Size = UDim2.fromOffset(70, TEXT.Large)
	pickBack.Visible = false
	local backLabel = Widgets.label(pickBack, "Label", FONT.Heading, TEXT.Small, COLOR.TextSecondary)
	backLabel.Size = UDim2.fromScale(1, 1)
	backLabel.TextXAlignment = Enum.TextXAlignment.Right
	backLabel.Text = "BACK"
	Widgets.hover(trove, pickBack, backLabel)
	trove:connect(pickBack.Activated, function()
		playUi(AudioConfig.UI.MenuBack)
		LoadoutController:_closePicker()
	end)

	pickList = Widgets.scroller(right, "PickList")
	pickList.Position = UDim2.new(0, 0, PREVIEW_HEIGHT, TEXT.Large + 6)
	pickList.Size = UDim2.new(1, 0, 1 - PREVIEW_HEIGHT, -(TEXT.Large + 6))
	pickList.Visible = false
	Widgets.list(pickList)
end

-- ── build: the round-start picker ───────────────────────────────────────────

local function buildPicker()
	pickerGui = Instance.new("ScreenGui")
	pickerGui.Name = "FL_LoadoutPicker"
	pickerGui.ResetOnSpawn = false
	pickerGui.IgnoreGuiInset = true
	--[[ The vote's layer. They never appear together — a map vote runs at the end
	     of a round and this runs at the start of one — and both want to be above
	     the HUD and below a teleport fade. ]]
	pickerGui.DisplayOrder = UITheme.DisplayOrder.Vote
	pickerGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	pickerGui.Enabled = false
	pickerGui.Parent = player:WaitForChild("PlayerGui")
	trove:add(pickerGui)

	local layer = ScaleLayer.new(pickerGui, "Scaled")
	local root = Widgets.frame(layer, "Root", COLOR.Background, 1)
	root.AnchorPoint = Vector2.new(0.5, 1)
	root.Position = UDim2.new(0.5, 0, 1, -LAYOUT.ScreenMargin * 3)
	root.Size = UDim2.fromOffset(640, PICKER_HEIGHT)

	local title = Widgets.label(root, "Title", FONT.Heading, TEXT.Small, COLOR.TextSecondary)
	title.Size = UDim2.new(0.7, 0, 0, TEXT.Body)
	title.Text = "PICK A LOADOUT"

	pickerClock = Widgets.label(root, "Clock", FONT.Numeric, TEXT.Small, COLOR.TextDim)
	pickerClock.AnchorPoint = Vector2.new(1, 0)
	pickerClock.Position = UDim2.new(1, 0, 0, 0)
	pickerClock.Size = UDim2.fromOffset(40, TEXT.Body)
	pickerClock.TextXAlignment = Enum.TextXAlignment.Right

	local count = LoadoutConfig.MaxLoadouts
	for index = 1, count do
		local button = Widgets.button(root, "Pick" .. index)
		button.Position =
			UDim2.new((index - 1) / count, if index > 1 then CARD_GAP * 0.5 else 0, 0, TEXT.Body + 4)
		button.Size = UDim2.new(1 / count, -CARD_GAP * 0.5, 1, -(TEXT.Body + 4))
		button.BackgroundColor3 = COLOR.Panel
		button.BackgroundTransparency = 0.1
		local stroke = Widgets.stroke(button, COLOR.Border)

		local label = Widgets.label(button, "Title", FONT.Body, TEXT.Tiny, COLOR.TextSecondary)
		label.Position = UDim2.fromOffset(LAYOUT.PanelPadding, 2)
		label.Size = UDim2.new(1, -LAYOUT.PanelPadding, 0, TEXT.Body)
		label.Text = LoadoutConfig.defaultName(index)

		local name = Widgets.label(button, "Name", FONT.Heading, TEXT.Body, COLOR.TextPrimary)
		name.Position = UDim2.fromOffset(LAYOUT.PanelPadding, TEXT.Body + 2)
		name.Size = UDim2.new(1, -LAYOUT.PanelPadding, 0, TEXT.Large)

		local sub = Widgets.label(button, "Sub", FONT.Body, TEXT.Tiny, COLOR.TextDim)
		sub.Position = UDim2.fromOffset(LAYOUT.PanelPadding, TEXT.Body + TEXT.Large + 2)
		sub.Size = UDim2.new(1, -LAYOUT.PanelPadding, 0, TEXT.Body)

		pickerButtons[index] = { button = button, stroke = stroke, title = label, name = name, sub = sub }

		trove:connect(button.Activated, function()
			local store = profile()
			if store then
				store:setActive(index)
			end
			playUi(AudioConfig.UI.MenuConfirm)
			refreshPickerButtons()
			--[[ Closed on choosing rather than left up for the rest of the
			     window: the question has been answered, and a strip that stays
			     is a strip in the way. ]]
			task.delay(0.4, function()
				setPickerVisible(false)
			end)
		end)
	end
end

--[[ Fits the panel to the screen. Same reasoning as the shop and the settings
     panel: the layer's width in reference pixels moves with the aspect ratio. ]]
local function refreshPanelSize()
	if not panel then
		return
	end
	local camera = Workspace.CurrentCamera
	local factor = ScaleLayer.getFactor()
	local viewport = if camera and factor > 0 then camera.ViewportSize / factor else nil
	local width = math.min(
		PANEL_WIDTH,
		math.max((if viewport then viewport.X else PANEL_WIDTH) - LAYOUT.ScreenMargin * 2, 280)
	)
	local height =
		math.min(PANEL_MAX_HEIGHT, (if viewport then viewport.Y else PANEL_MAX_HEIGHT) * PANEL.HeightScale)
	panel.Size = UDim2.fromOffset(width, height)
end

local function menuIsOpen(): boolean
	local menu = Registry.find("MainMenuController")
	if not menu or typeof(menu.isOpen) ~= "function" then
		return false
	end
	local ok, open = pcall(menu.isOpen, menu)
	return ok and open == true
end

-- ── public API ──────────────────────────────────────────────────────────────

function LoadoutController:isOpen(): boolean
	return state.open
end

function LoadoutController:open()
	if state.open then
		return
	end
	state.open = true
	gui.Enabled = true
	refreshPanelSize()

	local store = profile()
	state.editing = if store then store:getActiveIndex() else 1
	self:_closePicker()
	preview:setTurning(true)
	GamepadFocus.capture(state.firstCard)
	playUi(AudioConfig.UI.MenuConfirm)
end

function LoadoutController:close()
	if not state.open then
		return
	end
	state.open = false
	gui.Enabled = false
	preview:setTurning(false)
	GamepadFocus.release(state.firstCard)
	if menuIsOpen() then
		callController("MainMenuController", "reassertSuppression")
	end
	playUi(AudioConfig.UI.MenuBack)
end

function LoadoutController:toggle()
	if state.open then
		self:close()
	else
		self:open()
	end
end

-- ── lifecycle ───────────────────────────────────────────────────────────────

function LoadoutController:init()
	gui = Instance.new("ScreenGui")
	gui.Name = "FL_Loadouts"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = UITheme.DisplayOrder.Settings
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Enabled = false
	gui.Parent = player:WaitForChild("PlayerGui")
	trove:add(gui)

	local layer = ScaleLayer.new(gui, "Scaled")
	buildPanel(layer)
	buildPicker()
end

function LoadoutController:start()
	WeaponPreview.awaitAssets()

	local store = profile()
	if store then
		trove:add(store.changed:connect(function()
			if state.open then
				refreshCards()
				if state.choosing == "" then
					refreshSlots()
				end
			end
			if pickerGui and pickerGui.Enabled then
				refreshPickerButtons()
			end
		end))
	end

	--[[
		The picker appears when a round is STARTING.

		Not during the lobby: the main menu is what a player is looking at then,
		and it has a LOADOUTS entry of its own. Starting is the window between
		the countdown firing and the first Common — the one moment the question
		is live and the menu is not on screen to answer it.
	]]
	trove:connect(Remotes.Event.RoundStateChanged.OnClientEvent, function(payload: any)
		if typeof(payload) ~= "table" then
			return
		end
		if payload.state == ROUND.Starting then
			setPickerVisible(true)
		elseif payload.state ~= ROUND.Lobby then
			setPickerVisible(false)
		end
	end)

	trove:connect(Workspace:GetPropertyChangedSignal("CurrentCamera"), refreshPanelSize)

	--[[ One loop for the picker's countdown, and only while it is up. A second
	     RenderStepped for a number that changes once a second would be a frame
	     cost for nothing. ]]
	trove:add(task.spawn(function()
		while true do
			task.wait(0.25)
			if state.pickerUntil > 0 then
				local remaining = state.pickerUntil - os.clock()
				if remaining <= 0 then
					setPickerVisible(false)
				else
					pickerClock.Text = string.format("%d", math.ceil(remaining))
				end
			end
		end
	end))

	trove:connect(UserInputService.InputBegan, function(input: InputObject, processed: boolean)
		if not state.open then
			return
		end
		if input.KeyCode == Enum.KeyCode.ButtonB then
			if state.choosing ~= "" then
				LoadoutController:_closePicker()
			else
				LoadoutController:close()
			end
			return
		end
		if not processed and input.KeyCode == Enum.KeyCode.Escape then
			LoadoutController:close()
		end
	end)
end

function LoadoutController:destroy()
	rowTrove:destroy()
	if preview then
		preview:destroy()
	end
	table.clear(cards)
	table.clear(slotRows)
	table.clear(pickerButtons)
	trove:destroy()
end

Registry.register("LoadoutController", LoadoutController)

return LoadoutController
