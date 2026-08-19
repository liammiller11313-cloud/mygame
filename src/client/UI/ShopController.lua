--!nonstrict
--[[
	ShopController — the shop, and the only place Dollars are spent.

	Three tabs down the top, a list of what is in the tab down the left, and one
	big panel on the right holding a rotating 3D weapon, its price, and its
	numbers. Pick a row, look at it, buy it.

	── WHY THE STATS ARE BARS AND NOT NUMBERS ───────────────────────────────────
	"28 damage, 750 RPM, 2.5° hip spread" is four facts nobody can compare. The
	same four as bars against the best in the roster is one picture that answers
	the only question being asked, which is "is this better than what I have".

	Every bar is normalised against the extremes of the whole roster rather than
	against an absolute, so a full bar means "the best there is" rather than "an
	arbitrary number I hit". Recoil and spread are INVERTED — less is better, and
	a bar that grew as a gun got worse would read backwards.

	── WHY COMING-SOON ENTRIES ARE SHOWN ────────────────────────────────────────
	Three melee weapons and three specials have no model, no stats and no
	behaviour. They are drawn anyway, greyed and unbuyable, because a SPECIALS tab
	that is empty reads as broken while one holding three greyed rockets reads as
	a plan. It also means a model dropped into the Assets folder later has an
	obvious place to land.

	── WHAT THIS SCREEN NEVER DOES ──────────────────────────────────────────────
	It never decides whether a purchase is allowed, never prices anything from
	its own arithmetic, and never moves the balance itself. It sends an id and
	draws what comes back. See ProfileController.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local AudioConfig = require(Shared.Config.AudioConfig)
local EconomyConfig = require(Shared.Config.EconomyConfig)
local Registry = require(Shared.Util.Registry)
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

local player = Players.LocalPlayer

-- ── layout, in reference pixels ─────────────────────────────────────────────
--[[ Only the two numbers that are genuinely this screen's: how wide two columns
     of weapon want to be, and how tall it is worth growing on a big display.
     Header, tabs, footer, scrim, rows and panel treatment all come from
     UITheme.Panel, which is what makes this look like the same game as the
     settings panel next to it. ]]
local PANEL_WIDTH = 860
local PANEL_MAX_HEIGHT = 620

local HEADER_HEIGHT = PANEL.HeaderHeight
local TAB_HEIGHT = PANEL.TabHeight
local FOOTER_HEIGHT = PANEL.FooterHeight

--[[ The list on the left and the detail on the right. A fraction rather than an
     offset so the split holds on a phone, where the whole panel is narrower. ]]
local LIST_WIDTH = 0.36

local ROW_HEIGHT = PANEL.RowHeight
local ROW_HEIGHT_TOUCH = PANEL.RowHeightTouch

--[[ How tall the 3D preview is, as a fraction of the detail column. The rest is
     price, name, stats and the buy button — and the weapon is the reason the
     player is here, so it gets the largest single piece. ]]
local PREVIEW_HEIGHT = 0.42

--[[ Which numbers are drawn, in this order, and how each one is normalised.

     `invert` marks the ones where less is better. Without it a bar for recoil
     would fill up as a gun got harder to control, which is exactly backwards
     and is the kind of thing nobody notices until they have bought the wrong
     gun twice. ]]
local STATS = {
	{ key = "damage", label = "DAMAGE" },
	{ key = "rpm", label = "FIRE RATE" },
	{ key = "magSize", label = "MAGAZINE" },
	{ key = "spreadHip", label = "ACCURACY", invert = true },
	{ key = "recoilVertical", label = "CONTROL", invert = true },
	{ key = "reloadTime", label = "RELOAD", invert = true },
}

-- How long a refusal stays under the buy button before the button comes back.
local MESSAGE_SECONDS = 3.0

local ShopController = {}

local trove = Trove.new()
local rowTrove = Trove.new()

local gui: ScreenGui
local panel: Frame
local balanceLabel: TextLabel
local warningLabel: TextLabel
local hintLabel: TextLabel
local tabHolder: Frame
local list: ScrollingFrame
local detail: Frame
local preview: WeaponPreview.Preview
local previewMissing: TextLabel
local nameLabel: TextLabel
local classLabel: TextLabel
local blurbLabel: TextLabel
local priceLabel: TextLabel
local buyButton: TextButton
local buyLabel: TextLabel
local messageLabel: TextLabel
local statRows: { any } = {}

local tabs: { any } = {}
local rows: { any } = {}

local state = {
	open = false,
	category = EconomyConfig.Categories[1],
	selected = "",
	messageUntil = 0,
	firstRow = nil :: TextButton?,
	--[[ How many stat rows the column is tall enough for. Set by layoutDetail,
	     read by refreshStats — see both. ]]
	visibleStats = #STATS,
}

-- ── the roster's extremes, computed once ────────────────────────────────────

--[[
	The highest and lowest each stat reaches across every real weapon.

	Computed at require rather than per draw: it is sixteen weapons and six
	fields, it never changes at runtime, and doing it per selection would be the
	same arithmetic ninety-six times for every row a player clicks.
]]
local extremes: { [string]: { min: number, max: number } } = {}
do
	for _, stat in STATS do
		extremes[stat.key] = { min = math.huge, max = -math.huge }
	end
	for _, definition in WeaponConfig.all() do
		for _, stat in STATS do
			local value = definition[stat.key]
			if typeof(value) == "number" then
				local range = extremes[stat.key]
				range.min = math.min(range.min, value)
				range.max = math.max(range.max, value)
			end
		end
	end
end

--[[ Where a weapon sits between the roster's worst and best for one stat, 0-1.
     Inverted stats are flipped so a full bar always means "good". ]]
local function statFraction(definition: any, stat: any): number
	local value = definition[stat.key]
	local range = extremes[stat.key]
	if typeof(value) ~= "number" or not range or range.max <= range.min then
		return 0
	end
	local alpha = (value - range.min) / (range.max - range.min)
	return if stat.invert then 1 - alpha else alpha
end

-- ── small helpers ───────────────────────────────────────────────────────────

local function callController(name: string, method: string, ...: any)
	local controller = Registry.find(name)
	if controller and typeof(controller[method]) == "function" then
		pcall(controller[method], controller, ...)
	end
end

local function profile(): any
	return Registry.find("ProfileController")
end

local function isTouch(): boolean
	local input = Registry.find("InputController")
	if not input or typeof(input.isTouchScheme) ~= "function" then
		return false
	end
	local ok, touch = pcall(input.isTouchScheme, input)
	return ok and touch == true
end

local function rowHeight(): number
	return if isTouch() then ROW_HEIGHT_TOUCH else ROW_HEIGHT
end

--[[ The name to print for a catalogue entry: the weapon's own if it is real,
     the placeholder's if it is not. Two copies of a weapon's name is one copy
     too many, so a real entry never carries one. ]]
local function displayNameOf(entry: any): string
	local definition = WeaponConfig.get(entry.id)
	if definition then
		return string.upper(definition.displayName)
	end
	return entry.displayName or string.upper(entry.id)
end

--[[ What a row says on its right-hand side: OWNED, a price, or SOON. This is
     the only thing on the row that changes after it is built. ]]
local function rowStatus(entry: any): (string, Color3)
	if entry.soon then
		return "SOON", COLOR.TextDim
	end
	local store = profile()
	if store and store:owns(entry.id) then
		return "OWNED", COLOR.TextSecondary
	end
	if entry.price <= 0 then
		return "FREE", COLOR.TextSecondary
	end
	local affordable = store and store:canAfford(entry.id)
	return EconomyConfig.format(entry.price), if affordable then COLOR.Accent else COLOR.TextDim
end

-- ── drawing ─────────────────────────────────────────────────────────────────

--[[ A colour as RichText wants it. One place, so the header caption cannot end
     up a different grey from the theme's. ]]
local function hex(color: Color3): string
	return string.format(
		"#%02X%02X%02X",
		math.floor(color.R * 255 + 0.5),
		math.floor(color.G * 255 + 0.5),
		math.floor(color.B * 255 + 0.5)
	)
end

local function refreshBalance()
	local store = profile()
	local dollars = if store then store:getDollars() else 0
	balanceLabel.Text = string.format(
		'<font size="%d" color="%s">BALANCE  </font>%s',
		TEXT.Small,
		hex(COLOR.TextDim),
		EconomyConfig.format(dollars)
	)

	local degraded = store and store:isDegraded()
	warningLabel.Visible = degraded == true
	warningLabel.Text = if degraded then "OFFLINE — NOTHING BOUGHT NOW WILL BE SAVED" else ""
	hintLabel.Visible = not degraded
end

local function refreshRows()
	for _, row in rows do
		local text, color = rowStatus(row.entry)
		row.status.Text = text
		row.status.TextColor3 = color

		local selected = state.selected == row.entry.id
		row.bar.BackgroundTransparency = if selected then 0 else 1
		row.name.TextColor3 = if row.entry.soon
			then COLOR.TextDim
			elseif selected then COLOR.AccentBright
			else COLOR.TextPrimary
		row.button.BackgroundTransparency = if selected then 0.9 else 1
	end
end

--[[ The buy button, which is four different buttons depending on what is
     selected. Kept in one function so they cannot drift: every path sets both
     the text and whether it is pressable. ]]
local function refreshBuy()
	local entry = EconomyConfig.get(state.selected)
	local store = profile()
	if not entry or not store then
		buyButton.Visible = false
		return
	end

	buyButton.Visible = true
	local pressable = false
	local text, color = "", COLOR.TextPrimary

	if entry.soon then
		text, color = "COMING SOON", COLOR.TextDim
	elseif store:owns(entry.id) then
		text, color = "OWNED", COLOR.TextSecondary
	elseif store:isPending(entry.id) then
		text, color = "BUYING…", COLOR.Accent
	elseif not store:isReady() then
		text, color = "LOADING…", COLOR.TextDim
	elseif store:canAfford(entry.id) then
		text, color, pressable = "BUY  " .. EconomyConfig.format(entry.price), COLOR.AccentBright, true
	else
		text, color = "NEED " .. EconomyConfig.format(entry.price), COLOR.TextDim
	end

	buyLabel.Text = text
	buyLabel.TextColor3 = color
	buyButton.Selectable = pressable
	buyButton.BackgroundTransparency = if pressable then 0.15 else 0.6
	buyButton.Active = pressable
end

local function refreshStats(definition: any)
	for index, row in statRows do
		local stat = STATS[index]
		--[[ Two reasons a row is not drawn: this weapon has no such number, or
		     the column is too short to hold the row at all. See layoutDetail. ]]
		local has = definition ~= nil
			and typeof(definition[stat.key]) == "number"
			and index <= state.visibleStats
		row.holder.Visible = has
		if has then
			row.fill.Size = UDim2.new(math.clamp(statFraction(definition, stat), 0.02, 1), 0, 1, 0)
		end
	end
end

local function select(itemId: string)
	local entry = EconomyConfig.get(itemId)
	if not entry then
		return
	end
	state.selected = itemId

	local definition = WeaponConfig.get(itemId)
	nameLabel.Text = displayNameOf(entry)
	classLabel.Text = if definition
		then string.format("%s · %s", string.upper(definition.class), string.upper(definition.slot))
		else "NOT YET AVAILABLE"
	blurbLabel.Text = entry.blurb or ""

	local price = EconomyConfig.priceOf(itemId)
	priceLabel.Text = if price == nil
		then ""
		elseif price <= 0 then "INCLUDED"
		else EconomyConfig.format(price)

	local shown = preview:setWeapon(if entry.soon then nil else itemId)
	previewMissing.Visible = not shown
	previewMissing.Text = if entry.soon then "MODEL COMING SOON" else "NO MODEL SUPPLIED"

	refreshStats(definition)
	refreshRows()
	refreshBuy()
end

local function releaseRows()
	rowTrove:clean()
	for _, row in rows do
		row.button:Destroy()
	end
	table.clear(rows)
	state.firstRow = nil
end

local function buildRow(entry: any, index: number)
	local height = rowHeight()
	local button = Widgets.button(list, entry.id)
	button.Size = UDim2.new(1, -(PANEL.ScrollBarWidth + LAYOUT.ElementGap), 0, height)
	button.LayoutOrder = index
	button.BackgroundColor3 = COLOR.TextPrimary

	local bar = Widgets.frame(button, "Bar", COLOR.Accent, 1)
	bar.Size = UDim2.new(0, 3, 1, 0)

	local name = Widgets.label(button, "Name", FONT.Heading, TEXT.Body, COLOR.TextPrimary)
	name.Position = UDim2.fromOffset(LAYOUT.PanelPadding, 0)
	name.Size = UDim2.new(0.62, 0, 1, 0)
	name.Text = displayNameOf(entry)

	local status = Widgets.label(button, "Status", FONT.Numeric, TEXT.Small, COLOR.TextSecondary)
	status.AnchorPoint = Vector2.new(1, 0)
	status.Position = UDim2.new(1, -LAYOUT.PanelPadding, 0, 0)
	status.Size = UDim2.new(0.36, 0, 1, 0)
	status.TextXAlignment = Enum.TextXAlignment.Right

	local rule = Widgets.frame(button, "Rule", COLOR.Border, 0.5)
	rule.AnchorPoint = Vector2.new(0, 1)
	rule.Position = UDim2.new(0, 0, 1, 0)
	rule.Size = UDim2.new(1, 0, 0, LAYOUT.BorderThickness)

	local row = { entry = entry, button = button, name = name, status = status, bar = bar }
	--[[ refreshRows rather than a bare clear: a SELECTED row rests at 0.9, and
	     wiping it to transparent on mouse-leave would drop the selection
	     highlight until something else happened to redraw. ]]
	Widgets.rowHover(rowTrove, button, refreshRows)
	rowTrove:connect(button.Activated, function()
		if state.selected ~= entry.id then
			UiSound.play(AudioConfig.UI.MenuHover)
			select(entry.id)
		end
	end)
	table.insert(rows, row)
	state.firstRow = state.firstRow or button
end

local function renderCategory(category: string)
	state.category = category
	releaseRows()

	local entries = EconomyConfig.inCategory(category)
	for index, entry in entries do
		buildRow(entry, index)
	end
	list.CanvasPosition = Vector2.zero
	list.CanvasSize = UDim2.fromOffset(0, #entries * rowHeight())

	for _, tab in tabs do
		local selected = tab.category == category
		tab.label.TextColor3 = if selected then COLOR.AccentBright else COLOR.TextSecondary
		tab.underline.BackgroundTransparency = if selected then 0 else 1
	end

	--[[ Selection follows the tab rather than persisting across it: a detail
	     panel showing a rifle while the MELEE list is on screen is a panel
	     nobody can explain. ]]
	if entries[1] then
		select(entries[1].id)
	end
end

-- ── buying ──────────────────────────────────────────────────────────────────

local function showMessage(text: string, color: Color3)
	messageLabel.Text = text
	messageLabel.TextColor3 = color
	state.messageUntil = os.clock() + MESSAGE_SECONDS
	task.delay(MESSAGE_SECONDS, function()
		if os.clock() >= state.messageUntil then
			messageLabel.Text = ""
		end
	end)
end

local function attemptBuy()
	local store = profile()
	local entry = EconomyConfig.get(state.selected)
	if not store or not entry or entry.soon or store:owns(entry.id) then
		return
	end
	if store:buy(entry.id) then
		UiSound.play(AudioConfig.UI.MenuConfirm)
		refreshBuy()
	end
end

-- ── build ───────────────────────────────────────────────────────────────────

local function buildTab(category: string, index: number, total: number)
	local holder = Widgets.button(tabHolder, category)
	holder.Size = UDim2.new(1 / total, 0, 1, 0)
	holder.Position = UDim2.new((index - 1) / total, 0, 0, 0)

	local label = Widgets.label(holder, "Label", FONT.Heading, TEXT.Small, COLOR.TextSecondary)
	label.Size = UDim2.fromScale(1, 1)
	label.TextXAlignment = Enum.TextXAlignment.Center
	label.Text = category

	local underline = Widgets.frame(holder, "Underline", COLOR.Accent, 1)
	underline.AnchorPoint = Vector2.new(0.5, 1)
	underline.Position = UDim2.new(0.5, 0, 1, 0)
	underline.Size = UDim2.new(0.7, 0, 0, LAYOUT.BorderThickness * 2)

	trove:connect(holder.Activated, function()
		if state.category ~= category then
			UiSound.play(AudioConfig.UI.MenuHover)
			renderCategory(category)
		end
	end)
	table.insert(tabs, { category = category, label = label, underline = underline, button = holder })
end

local function buildStatRow(index: number, stat: any, top: number, height: number)
	local holder = Widgets.frame(detail, "Stat" .. stat.key, COLOR.Panel, 1)
	holder.Position = UDim2.new(0, 0, 0, top)
	holder.Size = UDim2.new(1, 0, 0, height)

	local label = Widgets.label(holder, "Label", FONT.Body, TEXT.Tiny, COLOR.TextDim)
	label.Size = UDim2.new(0.34, 0, 1, 0)
	label.Text = stat.label

	local track = Widgets.frame(holder, "Track", COLOR.Border, 0.4)
	track.AnchorPoint = Vector2.new(1, 0.5)
	track.Position = UDim2.new(1, 0, 0.5, 0)
	track.Size = UDim2.new(0.62, 0, 0, LAYOUT.BorderThickness * 3)

	local fill = Widgets.frame(track, "Fill", COLOR.Accent, 0)
	fill.Size = UDim2.new(0, 0, 1, 0)

	statRows[index] = { holder = holder, fill = fill }
end

local function buildDetail(parent: Frame)
	detail = Widgets.frame(parent, "Detail", COLOR.Panel, 1)
	detail.Position = UDim2.new(LIST_WIDTH, LAYOUT.ScreenMargin, 0, 0)
	detail.Size = UDim2.new(1 - LIST_WIDTH, -LAYOUT.ScreenMargin, 1, 0)

	preview = WeaponPreview.new(detail, "Preview")
	preview.frame.Size = UDim2.new(1, 0, PREVIEW_HEIGHT, 0)

	previewMissing = Widgets.label(detail, "NoModel", FONT.Body, TEXT.Small, COLOR.TextDim)
	previewMissing.AnchorPoint = Vector2.new(0.5, 0.5)
	previewMissing.Position = UDim2.new(0.5, 0, PREVIEW_HEIGHT * 0.5, 0)
	previewMissing.Size = UDim2.new(1, 0, 0, TEXT.Body)
	previewMissing.TextXAlignment = Enum.TextXAlignment.Center
	previewMissing.Visible = false

	nameLabel = Widgets.label(detail, "Name", FONT.Display, TEXT.Heading, COLOR.TextPrimary)
	nameLabel.Size = UDim2.new(0.66, 0, 0, TEXT.Heading + 4)

	priceLabel = Widgets.label(detail, "Price", FONT.Numeric, TEXT.Large, COLOR.Accent)
	priceLabel.AnchorPoint = Vector2.new(1, 0)
	priceLabel.Size = UDim2.new(0.34, 0, 0, TEXT.Heading)
	priceLabel.TextXAlignment = Enum.TextXAlignment.Right

	classLabel = Widgets.label(detail, "Class", FONT.Body, TEXT.Tiny, COLOR.TextSecondary)
	classLabel.Size = UDim2.new(1, 0, 0, TEXT.Body)

	blurbLabel = Widgets.label(detail, "Blurb", FONT.Body, TEXT.Small, COLOR.TextDim)
	blurbLabel.Size = UDim2.new(1, 0, 0, TEXT.Body)

	for index, stat in STATS do
		buildStatRow(index, stat, 0, STAT_HEIGHT)
	end

	buyButton = Widgets.button(detail, "Buy")
	buyButton.AnchorPoint = Vector2.new(1, 1)
	buyButton.Position = UDim2.new(1, 0, 1, 0)
	buyButton.Size = UDim2.fromOffset(220, 40)
	buyButton.BackgroundColor3 = COLOR.PanelRaised
	buyButton.BackgroundTransparency = PANEL.ActionFill

	Widgets.stroke(buyButton, COLOR.Border)
	buyLabel = Widgets.label(buyButton, "Label", FONT.Heading, TEXT.Body, COLOR.AccentBright)
	buyLabel.Size = UDim2.fromScale(1, 1)
	buyLabel.TextXAlignment = Enum.TextXAlignment.Center

	trove:connect(buyButton.Activated, attemptBuy)

	messageLabel = Widgets.label(detail, "Message", FONT.Body, TEXT.Small, COLOR.Danger)
	messageLabel.AnchorPoint = Vector2.new(0, 1)
	messageLabel.Position = UDim2.new(0, 0, 1, 0)
	messageLabel.Size = UDim2.new(0.6, 0, 0, 40)
end

local function build()
	gui = Instance.new("ScreenGui")
	gui.Name = "FL_Shop"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = UITheme.DisplayOrder.Settings
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Enabled = false
	gui.Parent = player:WaitForChild("PlayerGui")
	trove:add(gui)

	local layer = ScaleLayer.new(gui, "Scaled")

	local chrome = Widgets.panel(layer, trove, "SHOP", function()
		ShopController:close()
	end)
	panel = chrome.frame

	local inner = Widgets.frame(panel, "Inner", COLOR.Panel, 1)
	inner.Position = UDim2.fromOffset(LAYOUT.PanelPadding, HEADER_HEIGHT + TAB_HEIGHT + 6)
	inner.Size = UDim2.new(1, -LAYOUT.PanelPadding * 2, 1, -(HEADER_HEIGHT + TAB_HEIGHT + FOOTER_HEIGHT + 10))

	--[[ The balance sits in the header between the title and CLOSE, right-aligned
	     against the inside edge of the CLOSE button. It is the number a player
	     checks before every other decision on this screen, so it is the second
	     thing in reading order rather than something in a footer. ]]
	local balanceInset = LAYOUT.PanelPadding + PANEL.CloseWidth + LAYOUT.ElementGap
	balanceLabel = Widgets.label(panel, "Balance", FONT.Numeric, TEXT.Heading, COLOR.Accent)
	balanceLabel.AnchorPoint = Vector2.new(1, 0)
	balanceLabel.Position = UDim2.new(1, -balanceInset, 0, 0)
	balanceLabel.Size = UDim2.new(0.5, 0, 0, PANEL.HeaderHeight)
	balanceLabel.TextXAlignment = Enum.TextXAlignment.Right
	--[[ The word BALANCE rides in the same label rather than in one beside it,
	     because the number's width changes with the number and a separate caption
	     would have to be repositioned every time it did. RichText is one string
	     and one right edge. ]]
	balanceLabel.RichText = true

	--[[ In the footer, not stacked under the balance.

	     The panel has always reserved FOOTER_HEIGHT at the bottom and drawn
	     nothing in it, while this warning was crammed into the header where it
	     ran through the accent rule and over the tabs. A warning about the whole
	     screen belongs across the whole width of it. ]]
	local footRule = Widgets.frame(panel, "FootRule", COLOR.Border, 0)
	footRule.AnchorPoint = Vector2.new(0, 1)
	footRule.Position = UDim2.new(0, 0, 1, -FOOTER_HEIGHT)
	footRule.Size = UDim2.new(1, 0, 0, LAYOUT.BorderThickness)

	warningLabel = Widgets.label(panel, "Warning", FONT.Body, TEXT.Small, COLOR.Danger)
	warningLabel.AnchorPoint = Vector2.new(0, 1)
	warningLabel.Position = UDim2.new(0, LAYOUT.PanelPadding, 1, 0)
	warningLabel.Size = UDim2.new(1, -LAYOUT.PanelPadding * 2, 0, FOOTER_HEIGHT)
	warningLabel.Visible = false

	--[[ What the footer says when there is nothing wrong. It occupies the same
	     line as the warning and gives way to it, because a player who is about to
	     lose a purchase does not also need to be told purchases are permanent. ]]
	hintLabel = Widgets.label(panel, "Hint", FONT.Body, TEXT.Small, COLOR.TextDim)
	hintLabel.AnchorPoint = Vector2.new(0, 1)
	hintLabel.Position = UDim2.new(0, LAYOUT.PanelPadding, 1, 0)
	hintLabel.Size = UDim2.new(1, -LAYOUT.PanelPadding * 2, 0, FOOTER_HEIGHT)
	hintLabel.Text = "EVERYTHING YOU BUY IS YOURS PERMANENTLY. EQUIP IT FROM LOADOUTS."

	tabHolder = Widgets.frame(panel, "Tabs", COLOR.Panel, 1)
	tabHolder.Position = UDim2.fromOffset(0, HEADER_HEIGHT + 2)
	tabHolder.Size = UDim2.new(1, 0, 0, TAB_HEIGHT)
	for index, category in EconomyConfig.Categories do
		buildTab(category, index, #EconomyConfig.Categories)
	end

	list = Widgets.scroller(inner, "List")
	list.Size = UDim2.new(LIST_WIDTH, 0, 1, 0)
	Widgets.list(list)

	buildDetail(inner)
end

--[[
	Lays the detail column out against the height it actually has.

	Everything under the preview was positioned as `PREVIEW_HEIGHT` (a fraction)
	plus a fixed offset, which is fine at the design height and wrong everywhere
	else: on a phone the panel is 430 reference pixels rather than 620, the
	column is 306, and 214 pixels of name-price-class-blurb-and-six-stat-bars
	starting 42% of the way down ran 80 pixels past the buy button and out of the
	panel entirely. It was invisible on every desktop and every tablet.

	So the fixed content is measured, the preview gets whatever is left, and
	below COMPACT the least useful rows go: the blurb (which is empty for every
	real weapon anyway — only placeholders carry one) and then the stat rows
	shrink. The preview never goes below PREVIEW_MIN, because a shop with no
	picture of the thing is not a shop.
]]
local STAT_HEIGHT = 22
local STAT_HEIGHT_COMPACT = 17
local PREVIEW_MIN = 96
--[[ Below this there is no picture worth drawing, so the row goes entirely
     rather than showing a letterbox. Only reachable in a desktop window
     deliberately resized smaller than any device this game ships on. ]]
local PREVIEW_HIDE = 40
local BUY_HEIGHT = 40
local BUY_HEIGHT_COMPACT = 34

local function layoutDetail()
	if not detail then
		return
	end
	local height = detail.AbsoluteSize.Y / math.max(ScaleLayer.getFactor(), 0.01)
	if height <= 0 then
		return
	end

	local compact = height < 380
	local statHeight = if compact then STAT_HEIGHT_COMPACT else STAT_HEIGHT
	local buyHeight = if compact then BUY_HEIGHT_COMPACT else BUY_HEIGHT
	local headBlock = TEXT.Heading + 6 + TEXT.Body + (if compact then 0 else TEXT.Body + 4)
	local statBlock = #STATS * statHeight
	local fixed = headBlock + statBlock + buyHeight + LAYOUT.ElementGap * 3

	local previewHeight = height - fixed
	local shown = #STATS

	--[[
		When even the minimum picture does not fit, stat rows come off rather than
		the column overflowing.

		The picture wins because it is what the player came to look at, and STATS
		is ordered by how much the answer matters — damage, rate, magazine, then
		accuracy, control, reload — so the rows that go are the ones nobody
		decides on. Never below two: one bar compares nothing.
	]]
	if previewHeight < PREVIEW_MIN then
		local shortfall = PREVIEW_MIN - previewHeight
		shown -= math.clamp(math.ceil(shortfall / statHeight), 0, #STATS - 2)
		fixed = headBlock + shown * statHeight + buyHeight + LAYOUT.ElementGap * 3
		--[[ Whatever is left, and no floor this time. PREVIEW_MIN decided how many
		     bars to drop; it is not a promise the column can keep at every size,
		     and re-applying it here is what put a Roblox window resized down to
		     300 pixels back into overflow. Below PREVIEW_HIDE there is no picture
		     worth drawing and the row goes entirely. ]]
		previewHeight = math.max(height - fixed, 0)
	end
	state.visibleStats = shown

	local top = previewHeight + LAYOUT.ElementGap

	local hasRoom = previewHeight >= PREVIEW_HIDE
	preview.frame.Visible = hasRoom
	preview.frame.Size = UDim2.new(1, 0, 0, previewHeight)
	previewMissing.Position = UDim2.new(0.5, 0, 0, previewHeight * 0.5)
	previewMissing.Visible = previewMissing.Visible and hasRoom

	nameLabel.Position = UDim2.fromOffset(0, top)
	priceLabel.Position = UDim2.new(1, 0, 0, top + 2)
	classLabel.Position = UDim2.fromOffset(0, top + TEXT.Heading + 6)
	blurbLabel.Visible = not compact
	blurbLabel.Position = UDim2.fromOffset(0, top + TEXT.Heading + TEXT.Body + 8)

	local statTop = top + headBlock + LAYOUT.ElementGap
	for index, row in statRows do
		row.holder.Position = UDim2.fromOffset(0, statTop + (index - 1) * statHeight)
		row.holder.Size = UDim2.new(1, 0, 0, statHeight)
	end
	--[[ Which rows exist is this function's answer; whether a given weapon HAS
	     that number is refreshStats'. Re-run so the two agree without either
	     needing to know the other's rule. ]]
	refreshStats(WeaponConfig.get(state.selected))

	buyButton.Size = UDim2.fromOffset(if compact then 170 else 220, buyHeight)
	messageLabel.Size = UDim2.new(0.6, 0, 0, buyHeight)
end

--[[
	Fits the panel to the screen it is on.

	The same problem the settings panel has: everything inside is laid out in
	reference pixels and ScaleLayer keeps those honest, but the layer's WIDTH in
	reference pixels moves with the aspect ratio because the scale factor comes
	from height alone. A phone held upright is about 500 reference pixels across
	and a panel fixed at 860 would hang off both edges.
]]
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
	--[[ Deferred: the detail column's AbsoluteSize is a fraction of the panel
	     that was just resized, and Roblox has not laid it out yet this frame. ]]
	task.defer(layoutDetail)
end

-- ── suppression ─────────────────────────────────────────────────────────────

local function menuIsOpen(): boolean
	local menu = Registry.find("MainMenuController")
	if not menu or typeof(menu.isOpen) ~= "function" then
		return false
	end
	local ok, open = pcall(menu.isOpen, menu)
	return ok and open == true
end

-- ── public API ──────────────────────────────────────────────────────────────

function ShopController:isOpen(): boolean
	return state.open
end

function ShopController:open()
	if state.open then
		return
	end
	state.open = true
	gui.Enabled = true
	refreshPanelSize()
	renderCategory(state.category)
	layoutDetail()
	refreshBalance()
	preview:setTurning(true)
	GamepadFocus.capture(state.firstRow)
	UiSound.play(AudioConfig.UI.MenuConfirm)
end

function ShopController:close()
	if not state.open then
		return
	end
	state.open = false
	gui.Enabled = false
	--[[ The viewport stops rendering the moment nobody is looking at it. A
	     ViewportFrame is a second render pass and a rotating gun behind a closed
	     menu is the definition of a frame spent on nothing. ]]
	preview:setTurning(false)
	GamepadFocus.release(state.firstRow)
	if menuIsOpen() then
		callController("MainMenuController", "reassertSuppression")
	end
	UiSound.play(AudioConfig.UI.MenuBack)
end

function ShopController:toggle()
	if state.open then
		self:close()
	else
		self:open()
	end
end

-- ── lifecycle ───────────────────────────────────────────────────────────────

function ShopController:init()
	build()
end

function ShopController:start()
	WeaponPreview.awaitAssets()

	local store = profile()
	if store then
		trove:add(store.changed:connect(function()
			if not state.open then
				return
			end
			refreshBalance()
			refreshRows()
			refreshBuy()
		end))

		trove:add(store.purchaseAnswered:connect(function(itemId: string, ok: boolean, reason: string)
			if not state.open then
				return
			end
			if ok then
				UiSound.play(AudioConfig.UI.WaveCleared)
				showMessage("PURCHASED", COLOR.Accent)
				--[[ Re-selected rather than merely redrawn: buying the thing you
				     are looking at changes its price line, its buy button and its
				     row all at once, and one path that does all three is one path
				     that cannot do two of them. ]]
				if state.selected == itemId then
					select(itemId)
				end
			else
				UiSound.play(AudioConfig.UI.MenuBack)
				showMessage(reason, COLOR.Danger)
			end
			refreshBalance()
			refreshRows()
			refreshBuy()
		end))
	end

	--[[ Re-fitted on every viewport change and re-pointed when the camera is
	     replaced, which happens on death, on spectate and on rejoin. ]]
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

	--[[ B backs out, which is what B does on every console screen there has ever
	     been. Checked before the processed guard because the panel is focused
	     while it is up and its own presses arrive marked processed. ]]
	trove:connect(UserInputService.InputBegan, function(input: InputObject, processed: boolean)
		if not state.open then
			return
		end
		if input.KeyCode == Enum.KeyCode.ButtonB then
			ShopController:close()
			return
		end
		if not processed and input.KeyCode == Enum.KeyCode.Escape then
			ShopController:close()
		end
	end)
end

function ShopController:destroy()
	rowTrove:destroy()
	if preview then
		preview:destroy()
	end
	table.clear(tabs)
	table.clear(rows)
	table.clear(statRows)
	trove:destroy()
end

Registry.register("ShopController", ShopController)

return ShopController
