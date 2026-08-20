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
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attributes = require(Shared.Net.Attributes)
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
local UiSound = require(script.Parent.UiSound)
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

--[[
	How tall the weapon preview is, as a fraction of the right-hand column.

	Cut from 0.44 when melee became a third slot. Three 52-pixel slot rows are
	168 pixels rather than 110, and on a phone — where the panel is 430 reference
	pixels rather than 520 — the bottom row landed exactly on the SET ACTIVE
	button. The picture gives up the difference because it is the thing that
	degrades most gracefully.
]]
local PREVIEW_HEIGHT = 0.38

--[[
	The round-start picker: how long it stays up, and how big it is.

	It used to be a 640×74 strip of three unlabelled cards with a two-digit clock
	in the corner, clickable and nothing else. On a controller or a phone there
	was no way to answer it at all, and on a keyboard the fastest way to change
	loadout was to ignore it and open the full screen. A question nobody can
	answer is worse than no question.

	It is now a card with real presence, a timer you can see running out, number
	keys, gamepad focus, and a way through to the full editor. It still does NOT
	block input: the round is starting, players are moving around the safe room,
	and a modal that traps them there would be the wrong trade for a convenience.
]]
local PICKER_SECONDS = 14
local PICKER_WIDTH = 720
local PICKER_HEIGHT = 168
local PICKER_HEADER = 30
local PICKER_FOOTER = 26
--[[ The depleting bar across the top. A number counting down tells you the time
     left; a bar tells you without being read, which is the whole difference
     between a deadline you notice and one that expires on you. ]]
local PICKER_BAR = 3
--[[ Under this much of the window left, the bar and the clock turn to the danger
     colour. A quarter is late enough to mean something and early enough to still
     act on. ]]
local PICKER_URGENT = 0.25
--[[ How long the card stays up after the player answers, showing that it took
     the press. ]]
local PICKER_HOLD = 0.7

--[[
	How far off the bottom the card sits: clear of the entire bottom-right stack.

	Derived rather than eyeballed, because eyeballing it is what put the old strip
	straight through the ammo counter on a phone. A phone in landscape is about
	500 reference pixels tall, not 900 — the picker at a fixed offset that looked
	generous on a monitor had nowhere to go there.

	Read bottom-up: screen margin, hotbar, gap, ammo panel, gap, the Dollars line,
	gap. Every one of those is a real element from UITheme.Layout, so the card
	moves if any of them is resized instead of quietly overlapping it.
]]
local PICKER_BOTTOM = LAYOUT.ScreenMargin
	+ LAYOUT.HotbarSlotHeight
	+ LAYOUT.ElementGap
	+ LAYOUT.AmmoPanelHeight
	+ LAYOUT.ElementGap
	+ LAYOUT.WalletHeight
	+ LAYOUT.ElementGap

--[[
	Answering the picker from a keyboard: arrows to move, Enter to take it.

	NOT the number keys, which is the obvious design and the wrong one — 1, 2 and
	3 are already bound to the weapon slots (see InputController's DEFAULT_BINDINGS)
	and the picker is deliberately non-blocking, so a player pressing 2 in the safe
	room means "draw my pistol". Binding the same keys here would have done both
	things at once, every time, and the loadout half would have been invisible.

	Arrows are unbound during play and read as "move along a row" without being
	told. The cursor only appears once one is pressed: a mouse player never sees a
	highlight they did not ask for, and the moment somebody reaches for the
	keyboard the card row starts behaving like a keyboard control.
]]
local PICKER_STEP: { [Enum.KeyCode]: number } = {
	[Enum.KeyCode.Left] = -1,
	[Enum.KeyCode.Right] = 1,
}
local PICKER_CONFIRM: { [Enum.KeyCode]: boolean } = {
	[Enum.KeyCode.Return] = true,
	[Enum.KeyCode.KeypadEnter] = true,
}

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
local pickerRoot: Frame
local pickerBarFill: Frame
local pickerFoot: TextLabel
local pickerHint: TextLabel

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
	--[[ The full window, kept so the bar knows what fraction is left. Separate
	     from PICKER_SECONDS because opening the editor extends the deadline. ]]
	pickerWindow = PICKER_SECONDS,
	--[[ Set once the player answers. The card stays up for a beat afterwards
	     saying so, and a second press in that beat must not re-arm the timer. ]]
	pickerLocked = false,
	--[[ Where the keyboard cursor is, or 0 for "the keyboard has not been used".
	     Zero is not index 1: a mouse player must never see a highlight they did
	     not ask for, and the card row only starts looking like a keyboard control
	     once somebody presses an arrow. ]]
	pickerCursor = 0,
	firstCard = nil :: TextButton?,
}

-- ── small helpers ───────────────────────────────────────────────────────────

local function profile(): any
	return Registry.find("ProfileController")
end

--[[ Which of the three is currently armed. Its own function because four places
     ask, and every one of them has to cope with a profile that has not loaded —
     defaulting to 1 rather than nil-indexing a card. ]]
local function activeIndex(): number
	local store = profile()
	return if store then store:getActiveIndex() else 1
end

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

--[[ Which input the player is on right now, as InputController spells it. Empty
     when that controller is not up yet, which callers read as "not a gamepad" —
     the safe answer, since it costs a hint nobody needed rather than hiding one
     somebody did. ]]
local function scheme(): string
	local input = Registry.find("InputController")
	if not input or typeof(input.getScheme) ~= "function" then
		return ""
	end
	local ok, value = pcall(input.getScheme, input)
	return if ok and typeof(value) == "string" then value else ""
end

local function weaponName(weaponId: string?): string
	local definition = if typeof(weaponId) == "string" then WeaponConfig.get(weaponId) else nil
	return if definition then string.upper(definition.displayName) else "—"
end

--[[ What a slot is called on screen. A table rather than a chain of ifs now
     that there are three of them — the two-slot version returned "SIDEARM" for
     everything that was not a primary, which would have labelled the new melee
     row a sidearm. ]]
local SLOT_LABEL = {
	[Enums.Slot.Primary] = "PRIMARY",
	[Enums.Slot.Secondary] = "SIDEARM",
	[Enums.Slot.Melee] = "MELEE",
}

local function slotLabel(slot: string): string
	return SLOT_LABEL[slot] or string.upper(slot)
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
		card.melee.Text = weaponName(loadout[Enums.Slot.Melee])

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
	UiSound.play(AudioConfig.UI.MenuConfirm)
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
			UiSound.play(AudioConfig.UI.MenuBack)
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
	local active = activeIndex()
	for index, entry in pickerButtons do
		local loadout = if store then store:getLoadout(index) else LoadoutConfig.sanitise(nil, nil)
		entry.name.Text = weaponName(loadout[Enums.Slot.Primary])
		--[[ Both of the other two on one line. The picker is where the choice is
		     actually made and it was summarising two slots out of three — a card
		     that does not mention the melee is a card you have to leave to find
		     out what you are picking. ]]
		entry.sub.Text = string.format(
			"%s   ·   %s",
			weaponName(loadout[Enums.Slot.Secondary]),
			weaponName(loadout[Enums.Slot.Melee])
		)
		local selected = index == active
		--[[ Two different states on the same row, so they must not look alike.
		     ACTIVE is the one you spawn with and it FILLS; the keyboard cursor is
		     where the arrows have got to and it OUTLINES. A player arrowing across
		     can see both at once, which is the whole point of having a cursor. ]]
		local under = index == state.pickerCursor
		entry.stroke.Color = if under
			then COLOR.AccentBright
			elseif selected then COLOR.Accent
			else COLOR.Border
		entry.stroke.Thickness = if under or selected
			then LAYOUT.BorderThickness + 1
			else LAYOUT.BorderThickness
		entry.title.TextColor3 = if selected then COLOR.AccentBright else COLOR.TextSecondary
		--[[ The selected card fills. A stroke alone is a one-pixel difference
		     read at a glance in a safe room with a horde arriving — which is to
		     say, not read. ]]
		--[[ Three depths, not two. A card you could pick is barely there; the one
		     you spawn with is lit; and the one you just locked in goes brighter
		     still, which is what makes "LOCKED IN" — drawn in the background
		     colour on top of it — legible rather than a dark word on a dim
		     orange. ]]
		entry.button.BackgroundColor3 = if selected then COLOR.Accent else COLOR.Panel
		entry.button.BackgroundTransparency = if selected and state.pickerLocked
			then 0.2
			elseif selected then 0.55
			else 0.94
		entry.key.Visible = selected and not state.pickerLocked
		entry.chosen.Visible = selected and state.pickerLocked
	end

	--[[ What happens if nobody presses anything. Stated rather than left to be
	     discovered, because the whole point of a default is that it is fine —
	     and a countdown with an unnamed consequence reads as a threat. ]]
	if pickerFoot then
		local name = LoadoutConfig.defaultName(active)
		pickerFoot.Text = if state.pickerLocked
			then string.upper(name) .. " LOCKED IN"
			else "KEEPING " .. string.upper(name) .. " IF YOU DO NOT CHOOSE"
		pickerFoot.TextColor3 = if state.pickerLocked then COLOR.Accent else COLOR.TextDim
	end
end

--[[
	Answers the picker.

	Shared by the mouse, the number keys and the gamepad, which is the reason it
	exists: three call sites that each did their own `setActive` plus their own
	close is how one of them ends up not refreshing.
]]
local function choosePicker(index: number)
	if state.pickerUntil <= 0 or state.pickerLocked then
		return
	end
	local wanted = LoadoutConfig.clampIndex(index)
	local store = profile()
	if store then
		store:setActive(wanted)
	end
	state.pickerLocked = true
	UiSound.play(AudioConfig.UI.MenuConfirm)
	refreshPickerButtons()
	--[[ Held for a beat rather than closed on the press. The card says LOCKED IN
	     and then goes: a strip that vanishes the instant you click it leaves you
	     unsure whether it registered, which is the one thing a confirmation is
	     for.

	     Done by shortening the deadline rather than with a task.delay, so the
	     countdown loop stays the single thing that decides when the picker goes.
	     Two owners of that is how a picker ends up closing during the beat and
	     reopening for the rest of its window. ]]
	state.pickerUntil = os.clock() + PICKER_HOLD
end

local function setPickerVisible(visible: boolean)
	if not pickerGui then
		return
	end
	pickerGui.Enabled = visible
	if visible then
		state.pickerLocked = false
		state.pickerCursor = 0
		state.pickerWindow = PICKER_SECONDS
		state.pickerUntil = os.clock() + PICKER_SECONDS
		if pickerBarFill then
			pickerBarFill.Size = UDim2.fromScale(1, 1)
			pickerBarFill.BackgroundColor3 = COLOR.Accent
		end
		refreshPickerButtons()
		--[[ A pad lands on the first card rather than nowhere. Without this the
		     picker was answerable only with a mouse, which on a console is the
		     same as not being answerable. ]]
		local first = pickerButtons[1]
		if first then
			GamepadFocus.capture(first.button)
		end
	else
		state.pickerUntil = 0
		state.pickerLocked = false
		GamepadFocus.release(nil)
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

	--[[ The third line, added with the melee slot. A card that summarises two of
	     the three things in a loadout is a card you have to open to trust. ]]
	local melee = Widgets.label(button, "Melee", FONT.Body, TEXT.Small, COLOR.TextDim)
	melee.Position = UDim2.fromOffset(LAYOUT.PanelPadding, TEXT.Large + TEXT.Body * 2 + 12)
	melee.Size = UDim2.new(1, -LAYOUT.PanelPadding * 2, 0, TEXT.Body)

	cards[index] = {
		button = button,
		stroke = stroke,
		title = title,
		badge = badge,
		primary = primary,
		secondary = secondary,
		melee = melee,
	}
	state.firstCard = state.firstCard or button

	trove:connect(button.Activated, function()
		if state.editing == index then
			return
		end
		state.editing = index
		UiSound.play(AudioConfig.UI.MenuHover)
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
		UiSound.play(AudioConfig.UI.MenuHover)
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
			UiSound.play(AudioConfig.UI.MenuConfirm)
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
		UiSound.play(AudioConfig.UI.MenuBack)
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

	--[[ A real card, not a floating row of buttons. It has a background and an
	     outline for one reason: this appears over a lit safe room with survivors
	     moving through it, and the old transparent strip was regularly unreadable
	     against a wall. It does NOT get a scrim — see PICKER_HEIGHT. ]]
	local root = Widgets.frame(layer, "Root", COLOR.Panel, PANEL.Transparency)
	root.AnchorPoint = Vector2.new(0.5, 1)
	root.Position = UDim2.new(0.5, 0, 1, -PICKER_BOTTOM)
	root.Size = UDim2.fromOffset(PICKER_WIDTH, PICKER_HEIGHT)
	Widgets.stroke(root, COLOR.Border)
	pickerRoot = root

	--[[ The deadline, as a bar across the top edge. The digit beside the title
	     stays as well: the bar is what gets noticed and the number is what gets
	     read, and neither does the other one's job. ]]
	local barTrack = Widgets.frame(root, "BarTrack", COLOR.Background, 0.4)
	barTrack.Size = UDim2.new(1, 0, 0, PICKER_BAR)
	pickerBarFill = Widgets.frame(barTrack, "Fill", COLOR.Accent, 0)
	pickerBarFill.Size = UDim2.fromScale(1, 1)

	local title = Widgets.label(root, "Title", FONT.Heading, TEXT.Body, COLOR.TextPrimary)
	title.Position = UDim2.fromOffset(LAYOUT.PanelPadding, PICKER_BAR)
	title.Size = UDim2.new(0.6, 0, 0, PICKER_HEADER)
	title.Text = "PICK A LOADOUT"

	pickerClock = Widgets.label(root, "Clock", FONT.Numeric, TEXT.Large, COLOR.TextSecondary)
	pickerClock.AnchorPoint = Vector2.new(1, 0)
	pickerClock.Position = UDim2.new(1, -LAYOUT.PanelPadding, 0, PICKER_BAR)
	pickerClock.Size = UDim2.fromOffset(48, PICKER_HEADER)
	pickerClock.TextXAlignment = Enum.TextXAlignment.Right

	--[[ The way through to the full editor, for the player whose answer is "none
	     of these three". Without it the picker was a dead end: the only way to
	     change what was in a loadout was to let the timer run out, die, and go
	     back to the menu. ]]
	local edit = Widgets.button(root, "Edit")
	edit.AnchorPoint = Vector2.new(1, 0)
	edit.Position = UDim2.new(1, -(LAYOUT.PanelPadding + 56), 0, PICKER_BAR)
	edit.Size = UDim2.fromOffset(90, PICKER_HEADER)
	local editLabel = Widgets.label(edit, "Label", FONT.Body, TEXT.Small, COLOR.TextDim)
	editLabel.Size = UDim2.fromScale(1, 1)
	editLabel.TextXAlignment = Enum.TextXAlignment.Right
	editLabel.Text = "EDIT"
	Widgets.hover(trove, edit, editLabel)
	trove:connect(edit.Activated, function()
		UiSound.play(AudioConfig.UI.MenuConfirm)
		--[[ The picker goes rather than sitting behind the panel counting down.
		     A deadline running while the player is three clicks deep in an editor
		     is a deadline that expires on them mid-decision. ]]
		setPickerVisible(false)
		LoadoutController:open()
	end)

	local cardTop = PICKER_BAR + PICKER_HEADER
	local cardHeight = PICKER_HEIGHT - cardTop - PICKER_FOOTER - LAYOUT.PanelPadding
	local count = LoadoutConfig.MaxLoadouts
	local usable = PICKER_WIDTH - LAYOUT.PanelPadding * 2 - CARD_GAP * (count - 1)
	local cardWidth = usable / count

	for index = 1, count do
		local button = Widgets.button(root, "Pick" .. index)
		button.Position =
			UDim2.fromOffset(LAYOUT.PanelPadding + (index - 1) * (cardWidth + CARD_GAP), cardTop)
		button.Size = UDim2.fromOffset(cardWidth, cardHeight)
		button.BackgroundColor3 = COLOR.Panel
		button.BackgroundTransparency = 0.94
		local stroke = Widgets.stroke(button, COLOR.Border)
		Widgets.outlineHover(trove, button, stroke)

		local label = Widgets.label(button, "Title", FONT.Body, TEXT.Tiny, COLOR.TextSecondary)
		label.Position = UDim2.fromOffset(LAYOUT.PanelPadding, 4)
		label.Size = UDim2.new(1, -(LAYOUT.PanelPadding * 2 + 18), 0, TEXT.Body)
		label.Text = LoadoutConfig.defaultName(index)

		--[[ The ACTIVE badge, on whichever card the player spawns with. It is the
		     one fact a glance has to return, so it is a word rather than a
		     difference in border colour. ]]
		local key = Widgets.label(button, "Badge", FONT.Body, TEXT.Tiny, COLOR.Accent)
		key.AnchorPoint = Vector2.new(1, 0)
		key.Position = UDim2.new(1, -LAYOUT.PanelPadding, 0, 4)
		key.Size = UDim2.fromOffset(46, TEXT.Body)
		key.TextXAlignment = Enum.TextXAlignment.Right
		key.Text = "ACTIVE"
		key.Visible = false

		--[[ Truncated, not clipped. Nothing here clips its children, so on a phone
		     — where three cards share about 456 reference pixels — "Kriss Vector
		     .45" would otherwise be drawn straight across the card beside it. ]]
		local name = Widgets.label(button, "Name", FONT.Heading, TEXT.Body, COLOR.TextPrimary)
		name.Position = UDim2.fromOffset(LAYOUT.PanelPadding, TEXT.Body + 6)
		name.Size = UDim2.new(1, -LAYOUT.PanelPadding * 2, 0, TEXT.Large)
		name.TextTruncate = Enum.TextTruncate.AtEnd

		local sub = Widgets.label(button, "Sub", FONT.Body, TEXT.Small, COLOR.TextDim)
		sub.Position = UDim2.fromOffset(LAYOUT.PanelPadding, TEXT.Body + TEXT.Large + 6)
		sub.Size = UDim2.new(1, -LAYOUT.PanelPadding * 2, 0, TEXT.Body)
		sub.TextTruncate = Enum.TextTruncate.AtEnd

		--[[ The confirmation, sitting on the card that was chosen rather than
		     somewhere else on screen. Hidden until the press lands. ]]
		local chosen = Widgets.label(button, "Chosen", FONT.Heading, TEXT.Tiny, COLOR.Background)
		chosen.AnchorPoint = Vector2.new(0, 1)
		chosen.Position = UDim2.new(0, LAYOUT.PanelPadding, 1, -4)
		chosen.Size = UDim2.new(1, -LAYOUT.PanelPadding * 2, 0, TEXT.Body)
		chosen.Text = "LOCKED IN"
		chosen.Visible = false

		pickerButtons[index] = {
			button = button,
			stroke = stroke,
			title = label,
			name = name,
			sub = sub,
			key = key,
			chosen = chosen,
		}

		trove:connect(button.Activated, function()
			choosePicker(index)
		end)
	end

	pickerFoot = Widgets.label(root, "Foot", FONT.Body, TEXT.Tiny, COLOR.TextDim)
	pickerFoot.AnchorPoint = Vector2.new(0, 1)
	pickerFoot.Position = UDim2.new(0, LAYOUT.PanelPadding, 1, 0)
	pickerFoot.Size = UDim2.new(0.62, -LAYOUT.PanelPadding, 0, PICKER_FOOTER)

	pickerHint = Widgets.label(root, "Hint", FONT.Body, TEXT.Tiny, COLOR.TextDim)
	pickerHint.AnchorPoint = Vector2.new(1, 1)
	pickerHint.Position = UDim2.new(1, -LAYOUT.PanelPadding, 1, 0)
	pickerHint.Size = UDim2.new(0.38, -LAYOUT.PanelPadding, 0, PICKER_FOOTER)
	pickerHint.TextXAlignment = Enum.TextXAlignment.Right
end

--[[ Fits the picker to the screen, and hides the number keys on a scheme that
     has none. Same width problem as every other panel here: the layer's width in
     reference pixels moves with the aspect ratio, and 720 hangs off both edges
     of a phone held upright. ]]
local function refreshPickerSize()
	if not pickerRoot then
		return
	end
	local camera = Workspace.CurrentCamera
	local factor = ScaleLayer.getFactor()
	local viewport = if camera and factor > 0 then camera.ViewportSize / factor else nil
	local available = if viewport then viewport.X else PICKER_WIDTH
	local width = math.min(PICKER_WIDTH, math.max(available - LAYOUT.ScreenMargin * 2, 300))
	pickerRoot.Size = UDim2.fromOffset(width, PICKER_HEIGHT)

	local count = LoadoutConfig.MaxLoadouts
	local usable = width - LAYOUT.PanelPadding * 2 - CARD_GAP * (count - 1)
	local cardWidth = usable / count
	local cardTop = PICKER_BAR + PICKER_HEADER
	local cardHeight = PICKER_HEIGHT - cardTop - PICKER_FOOTER - LAYOUT.PanelPadding
	for index, entry in pickerButtons do
		entry.button.Position =
			UDim2.fromOffset(LAYOUT.PanelPadding + (index - 1) * (cardWidth + CARD_GAP), cardTop)
		entry.button.Size = UDim2.fromOffset(cardWidth, cardHeight)
	end

	--[[ The key hint, only where those keys exist. A phone is told to tap and a
	     pad is told nothing, because a pad player is already moving a highlight
	     they can see. ]]
	if pickerHint then
		pickerHint.Text = if isTouch() then "TAP TO CHOOSE" else "◄ ►  CHOOSE      ENTER  CONFIRM"
		pickerHint.Visible = scheme() ~= "Gamepad"
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

--[[
	Whether the picker is behind something.

	Used by BOTH the countdown loop and the arrow keys, which is the point: the
	loop already hid the card behind the main menu and the loadout panel, and the
	keyboard did not — so arrows pressed while the pause menu was up still moved a
	cursor on a card nobody could see.

	The shop, the settings panel and the pause menu all draw above the picker's
	layer, so anything open there is covering it. Asked by method rather than
	tracked, because these are four independent screens and a flag mirrored from
	each of them is four things to keep in sync.
]]
local COVERING_SCREENS = { "ShopController", "SettingsController", "PauseController" }

local function pickerObscured(): boolean
	if state.open or menuIsOpen() then
		return true
	end
	for _, name in COVERING_SCREENS do
		local controller = Registry.find(name)
		if controller and typeof(controller.isOpen) == "function" then
			local ok, open = pcall(controller.isOpen, controller)
			if ok and open == true then
				return true
			end
		end
	end
	return false
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
	UiSound.play(AudioConfig.UI.MenuConfirm)
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
	UiSound.play(AudioConfig.UI.MenuBack)
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

	--[[ And for a client that finished booting DURING the start window, which is
	     every client on a fresh server: the state change above already fired, into
	     a listener that did not exist yet. The attribute is the same fact without
	     the race. ]]
	if Attributes.get(Workspace, Attributes.Game.RoundState, ROUND.Lobby) == ROUND.Starting then
		setPickerVisible(true)
	end

	trove:connect(Workspace:GetPropertyChangedSignal("CurrentCamera"), function()
		refreshPanelSize()
		refreshPickerSize()
	end)
	refreshPickerSize()

	--[[ The number-key hints appear and disappear with the keyboard. A player who
	     picks up a controller mid-round should not be looking at a "2" they
	     cannot press. ]]
	local input = Registry.find("InputController")
	if input and input.schemeChanged then
		trove:add(input.schemeChanged:connect(refreshPickerSize))
	end

	--[[ One loop for the picker's countdown, and only while it is up. A second
	     RenderStepped for a bar that moves a few pixels a second would be a frame
	     cost for nothing; a tenth of a second is well under what anybody reads as
	     a step. ]]
	trove:add(task.spawn(function()
		while true do
			task.wait(0.1)
			if state.pickerUntil <= 0 then
				continue
			end
			--[[
				A deadline nobody can see must not expire.

				The main menu, the full loadout panel, the shop and the pause menu
				all draw over this, and a player who opened one of them has not
				declined to answer — they are doing something else. The card hides
				and the clock holds until it is back on screen.
			]]
			local obscured = pickerObscured()
			pickerRoot.Visible = not obscured
			if obscured then
				state.pickerUntil += 0.1
				continue
			end

			local remaining = state.pickerUntil - os.clock()
			if remaining <= 0 then
				setPickerVisible(false)
				continue
			end
			--[[ Once the player has answered, the deadline is only the beat the
			     confirmation is held for. Running the bar and the clock down
			     through it would show a two-second panic on a decision that has
			     already been made. ]]
			if state.pickerLocked then
				continue
			end

			local fraction = math.clamp(remaining / state.pickerWindow, 0, 1)
			pickerBarFill.Size = UDim2.fromScale(fraction, 1)
			pickerClock.Text = string.format("%d", math.ceil(remaining))

			local urgent = fraction <= PICKER_URGENT
			pickerBarFill.BackgroundColor3 = if urgent then COLOR.Danger else COLOR.Accent
			pickerClock.TextColor3 = if urgent then COLOR.Danger else COLOR.TextSecondary
		end
	end))

	--[[
		Answering the picker without a mouse.

		Arrows move the cursor, Enter takes what it is on. On a pad none of this
		runs: GamepadFocus already owns the selection and ButtonA already activates
		it, which is why setPickerVisible captures the first card.

		`processed` is respected throughout, so an arrow key going into the chat
		box is not also a loadout change.
	]]
	trove:connect(UserInputService.InputBegan, function(input: InputObject, processed: boolean)
		if processed or state.pickerUntil <= 0 or state.pickerLocked or pickerObscured() then
			return
		end

		local step = PICKER_STEP[input.KeyCode]
		if step then
			--[[ The first arrow press starts the cursor on whatever is ACTIVE
			     rather than on card one, so the common case — nudge one across
			     from what you already run — is a single key. ]]
			local from = if state.pickerCursor > 0 then state.pickerCursor else activeIndex()
			state.pickerCursor = LoadoutConfig.clampIndex(from + step)
			UiSound.play(AudioConfig.UI.MenuHover)
			refreshPickerButtons()
			return
		end

		if PICKER_CONFIRM[input.KeyCode] then
			--[[ Enter with no cursor confirms what is already active. That is not
			     a no-op: it dismisses the card, which is exactly what a player who
			     is happy with their loadout wants from it. ]]
			choosePicker(if state.pickerCursor > 0 then state.pickerCursor else activeIndex())
		end
	end)

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
