--!nonstrict
--[[
	RequisitionController — the between-waves shop.

	Five rows, a Scrip balance, and a line saying whether the window is open. See
	Shared/Config/RequisitionConfig for what is on sale and the argument for why
	it is those five and not a stat shop, and Round/RequisitionService for the
	transaction.

	── IT IS READABLE ALWAYS AND BUYABLE SOMETIMES ─────────────────────────────
	The panel opens whenever the player wants it. The BUY buttons only work
	during prep and the breathers. Those are different questions and conflating
	them was the obvious mistake here: a player who cannot even LOOK at the list
	mid-wave cannot plan what to buy in the ten seconds they will get, and ten
	seconds is not long enough to read five things for the first time.

	So the rows are always there and always priced, and the footer says when.

	── AND THE STATE COMES OFF WORKSPACE ───────────────────────────────────────
	What is already bought rides Attributes.Game.Req* on Workspace, which
	replicates to every client, so this screen is correct for a player who joined
	thirty seconds ago and never saw the purchase happen. It does not track the
	broadcast and it does not ask the server — the attribute IS the answer, and a
	panel that remembered its own version of it would be a second truth that
	could drift.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attributes = require(Shared.Net.Attributes)
local AudioConfig = require(Shared.Config.AudioConfig)
local Enums = require(Shared.Enums)
local ModifierConfig = require(Shared.Config.ModifierConfig)
local ProgressionConfig = require(Shared.Config.ProgressionConfig)
local Registry = require(Shared.Util.Registry)
local Remotes = require(Shared.Net.Remotes)
local RequisitionConfig = require(Shared.Config.RequisitionConfig)
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
local GA = Attributes.Game
local PA = Attributes.Player

local player = Players.LocalPlayer

--[[ Wide enough for "WAITING…" over "3 / 4 READY" without either wrapping, and
     PANEL.RowHeightTouch tall so it is a real target on a phone. ]]
local READY_WIDTH = 168

local PANEL_WIDTH = 660
local PANEL_MAX_HEIGHT = 560
local HEADER_HEIGHT = PANEL.HeaderHeight
local BALANCE_HEIGHT = 24
local BODY_TOP = HEADER_HEIGHT + LAYOUT.PanelPadding + BALANCE_HEIGHT

--[[ The modifier advice sits between the balance and the rows, and only during
     the pre-round hold. The list starts BELOW it when it is showing and at
     BODY_TOP when it is not — see refreshBodyTop, which moves both. ]]
local COUNTER_TOP = BODY_TOP
local COUNTER_HEIGHT = 34

--[[ A row is a name, a line of prose and a price, plus a BUY button that has to
     be hittable with a thumb. The touch height is the project's standard rather
     than derived from the type, because unlike the backpack's rows this one IS
     a tap target. ]]
local ROW_HEIGHT = 62
local ROW_HEIGHT_TOUCH = PANEL.RowHeightTouch + 14
local BUY_WIDTH = 108

local PHASE_PREP = "Prep"
local PHASE_BREATHER = "Breather"

local RequisitionController = {}

local trove = Trove.new()

local gui: ScreenGui
local panel: Frame
local closeButton: TextButton
local balanceLabel: TextLabel
local list: ScrollingFrame
local footRule: Frame
local hint: TextLabel

--[[ The ready gate's corner of the footer. Built with the panel and shown only
     while the round is actually holding — see `build`. ]]
--[[ Forward-declared: `refresh` moves the row list when the modifier advice
     appears or goes, and the function that owns where the list starts is
     defined below it. Declaring it here keeps the offset arithmetic in one
     place rather than copied into both. ]]
local applyTouchSizing: () -> ()

local caption: TextLabel
--[[ The round's condition and what answers it, shown above the rows in the
     pre-round window. See ModifierConfig.counter. ]]
local counterLabel: TextLabel

local readyRoot: Frame
local readyButton: TextButton
local readyStroke: UIStroke
local readyLabel: TextLabel
local readyCount: TextLabel

local state = {
	open = false,
	suppressed = false,
	--[[ Whether the suppression currently in force is the SOFT one. Tracked
	     separately because the hold can lift while the panel is still open, and
	     the panel then has to tighten from soft to hard without a close. ]]
	softSuppressed = false,
	--[[ Whether the panel opened ITSELF for the pre-round window, as opposed to
	     the player opening it. Only a self-opened panel closes itself again when
	     the gate lifts: a player who deliberately opened the shop should not have
	     it shut in their face because somebody else pressed READY. ]]
	autoOpened = false,
}

local restore = {
	cameraMode = nil :: any,
	cameraZoom = nil :: any,
	cameraMinZoom = nil :: any,
	mouseIcon = nil :: any,
}

type Row = {
	entry: any,
	frame: Frame,
	button: TextButton,
	buyLabel: TextLabel,
	price: TextLabel,
	title: TextLabel,
	blurb: TextLabel,
	stroke: UIStroke,
}
local rows: { Row } = {}

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

--[[ The verbs the pre-round window refuses. Everything a player might do to the
     world with a weapon, and nothing they might do to move around it — see
     setSuppressed for why the two are separated. ]]
local HOLD_MUTED = { "Fire", "Aim", "Reload", "Melee", "Shove", "Throw", "UseItem" }

--[[
	Takes the world away from the player while this panel is up — except before
	wave 1, where it deliberately does not.

	── HARD, WHICH IS EVERY OTHER TIME ─────────────────────────────────────────
	Between waves this is a shop opened mid-round, and a player reading it is a
	player not watching a doorway. Everything goes off, the way it does for every
	other panel in the game.

	── AND SOFT, DURING THE READY HOLD ─────────────────────────────────────────
	The pre-round window is the opposite situation: nothing is hunting anybody,
	the round is explicitly waiting, and the team is meant to be able to spread
	out and grab a gun while they argue about who is paying. Freezing four people
	in place to read five cards makes the one calm minute of the round the one
	minute they cannot move.

	So movement, jumping, crouching, sprinting and INTERACT all stay live, the
	touch pad stays on screen, and the prompts keep working — you can walk to a
	shotgun and pick it up with the panel open. What goes away is the trigger,
	because the cursor is free for the BUY buttons and a click that bought a
	requisition should not also put a magazine into the floor.
]]
local function setSuppressed(value: boolean, soft: boolean?)
	local wantSoft = value and soft == true
	if state.suppressed == value and state.softSuppressed == wantSoft then
		return
	end
	state.suppressed = value
	state.softSuppressed = wantSoft

	--[[ The crosshair goes either way. The mouse is a cursor while this is open,
	     so a reticle in the middle of the screen is pointing at nothing. ]]
	callController("CrosshairController", "setVisible", not value)

	if wantSoft then
		callController("InputController", "setEnabled", true)
		callController("InputController", "setMuted", HOLD_MUTED)
		callController("PromptController", "setEnabled", true)
		callController("TouchController", "setVisible", true)
		return
	end

	callController("InputController", "setMuted", nil)
	callController("InputController", "setEnabled", not value)
	callController("PromptController", "setEnabled", not value)
	callController("TouchController", "setVisible", not value)
end

local function claimCursor(value: boolean)
	if value then
		FreeCursor.take(restore)
	else
		FreeCursor.giveBack(restore)
	end
end

--[[ Scrip, from ProgressionController's mirror when it has one and from the
     attribute otherwise. Both are the same number; the mirror is simply the one
     that is already correct on the frame a purchase lands. ]]
local function scrip(): number
	local progression = Registry.find("ProgressionController")
	if progression and typeof(progression.getScrip) == "function" then
		local ok, value = pcall(progression.getScrip, progression)
		if ok and typeof(value) == "number" then
			return value
		end
	end
	return tonumber(Attributes.get(player, PA.Scrip, 0)) or 0
end

--[[ Whether a key is the one that opens this panel. Asked rather than assumed,
     because the binding is rebindable: a player who moved REQUISITIONS off T
     should still be able to press their own key to put it away. ]]
local function boundToPanel(keyCode: Enum.KeyCode): boolean
	local controller = Registry.find("InputController")
	if not controller or typeof(controller.getBindings) ~= "function" then
		return false
	end
	local ok, bindings = pcall(controller.getBindings, controller)
	if not ok or typeof(bindings) ~= "table" then
		return false
	end
	for _, binding in bindings do
		if binding.action == "Requisitions" then
			for _, key in binding.keys do
				if key == keyCode then
					return true
				end
			end
		end
	end
	return false
end

--[[ Whether wave 1 is still waiting on the team. The one fact this panel's
     ready corner is driven by; RoundService owns it and publishes it, so four
     clients cannot disagree about whether the round has started. ]]
local function holding(): boolean
	return Workspace:GetAttribute(GA.ReadyHold) == true
end

local function windowOpen(): boolean
	--[[
		Starting counts, and that is the fix rather than a loosening.

		PREP has been in the list below since this file was written — the window
		before wave 1 is the one time a team is standing still together with a
		decision to make — but the round is in RoundState.Starting during prep,
		not InProgress, so the guard above rejected every prep purchase and the
		pre-round window silently never worked. The phase test underneath is
		still what decides: Starting only ever happens during prep.
	]]
	local round = Workspace:GetAttribute(GA.RoundState)
	if round ~= Enums.RoundState.InProgress and round ~= Enums.RoundState.Starting then
		return false
	end
	local phase = Workspace:GetAttribute(GA.WavePhase)
	return phase == PHASE_PREP or phase == PHASE_BREATHER
end

-- ── drawing ─────────────────────────────────────────────────────────────────

local function refresh()
	if not state.open then
		return
	end

	local balance = scrip()
	balanceLabel.Text = string.format("%s %d", ProgressionConfig.CurrencySymbol, balance)

	local open = windowOpen()
	for _, row in rows do
		local bought = RequisitionConfig.isActive(Workspace, row.entry.id)
		local affordable = balance >= row.entry.cost

		--[[ AIRDROP sets no attribute — it fires once and leaves no state — so
		     the panel cannot tell from Workspace whether it has been bought. It
		     stays offerable, which is the honest answer: the server is the thing
		     that knows, and it refuses a second one. ]]
		if bought then
			row.buyLabel.Text = "ACTIVE"
			row.buyLabel.TextColor3 = COLOR.Accent
			row.button.Active = false
			row.price.TextColor3 = COLOR.TextDim
			row.stroke.Color = COLOR.Accent
			row.title.TextColor3 = COLOR.Accent
		elseif not open then
			row.buyLabel.Text = "LOCKED"
			row.buyLabel.TextColor3 = COLOR.TextDim
			row.button.Active = false
			row.price.TextColor3 = COLOR.TextDim
			row.stroke.Color = COLOR.Border
			row.title.TextColor3 = COLOR.TextSecondary
		elseif not affordable then
			row.buyLabel.Text = "SHORT"
			row.buyLabel.TextColor3 = COLOR.Danger
			row.button.Active = false
			row.price.TextColor3 = COLOR.Danger
			row.stroke.Color = COLOR.Border
			row.title.TextColor3 = COLOR.TextSecondary
		else
			row.buyLabel.Text = "REQUISITION"
			row.buyLabel.TextColor3 = COLOR.TextPrimary
			row.button.Active = true
			row.price.TextColor3 = COLOR.TextSecondary
			row.stroke.Color = COLOR.BorderBright
			row.title.TextColor3 = COLOR.TextPrimary
		end
		row.button.Selectable = row.button.Active
	end

	local hold = holding()

	--[[ The round's condition and what answers it, but only while the team is
	     still deciding. Between waves it is old news and the space is better
	     spent on the rows. ]]
	local modifier = ModifierConfig.active(Workspace)
	local advise = hold and modifier ~= nil and modifier.counter ~= nil
	if advise then
		local answer = RequisitionConfig.get(modifier.counter)
		counterLabel.Text = string.format(
			"%s — %s  ·  BUY %s: %s",
			string.upper(modifier.displayName),
			modifier.blurb,
			if answer then answer.displayName else "?",
			modifier.counterLine or ""
		)
	end
	if counterLabel.Visible ~= advise then
		counterLabel.Visible = advise
		--[[ The rows move when this appears or goes. applyTouchSizing owns where
		     the list starts, so it is asked again rather than the offset being
		     computed a second time here. ]]
		applyTouchSizing()
	end

	--[[ And the row it points at is marked, so the advice above and the button
	     below are visibly the same recommendation. ]]
	for _, row in rows do
		local recommended = advise and modifier.counter == row.entry.id
		row.frame.BackgroundTransparency = if recommended then 0.86 else 0.94
	end

	readyRoot.Visible = hold
	if hold then
		local mine = Attributes.get(player, PA.Ready, false) == true
		local ready = tonumber(Workspace:GetAttribute(GA.ReadyCount)) or 0
		local needed = tonumber(Workspace:GetAttribute(GA.ReadyNeeded)) or 0
		readyLabel.Text = if mine then "WAITING…" else "READY"
		readyLabel.TextColor3 = if mine then COLOR.TextDim else COLOR.TextPrimary
		readyCount.Text = string.format("%d / %d READY", ready, needed)
		readyStroke.Color = if mine then COLOR.Accent else COLOR.BorderBright
	end

	--[[ Three lines, because the window means three different things. Before
	     wave 1 it is a decision the whole team is standing still for; between
	     waves it is a shop; the rest of the time it is a catalogue to read. ]]
	if hold then
		hint.Text = "SPEND BEFORE WAVE 1. ONE PAYS, EVERYONE GETS IT — THEN READY UP."
	elseif open then
		hint.Text = "REQUISITIONS ARE OPEN. ONE PAYS, EVERYONE GETS IT, FOR THE REST OF THE ROUND."
	else
		hint.Text = "REQUISITIONS OPEN BETWEEN WAVES. READ NOW, BUY IN THE BREATHER."
	end
	hint.TextColor3 = if open then COLOR.TextSecondary else COLOR.TextDim
end

-- ── build ───────────────────────────────────────────────────────────────────

function applyTouchSizing()
	local height = if isTouch() then ROW_HEIGHT_TOUCH else ROW_HEIGHT
	for _, row in rows do
		row.frame.Size = UDim2.new(1, -PANEL.ScrollBarWidth - 2, 0, height)
		row.button.Size = UDim2.fromOffset(BUY_WIDTH, height - 16)
	end
	if list then
		--[[ The rows start below the modifier advice when it is showing, and at
		     BODY_TOP when it is not. Both the position and the height move, or
		     the list keeps its old height and runs off the bottom. ]]
		local top = if counterLabel and counterLabel.Visible then BODY_TOP + COUNTER_HEIGHT else BODY_TOP
		list.Position = UDim2.fromOffset(LAYOUT.PanelPadding, top)
		list.Size =
			UDim2.new(1, -LAYOUT.PanelPadding * 2, 1, -(top + PANEL.FooterHeight + LAYOUT.PanelPadding))
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

local function buildRow(entry: any)
	local row = Widgets.frame(list, entry.id, COLOR.PanelRaised, PANEL.RaisedFill)
	row.LayoutOrder = entry.order
	row.Size = UDim2.new(1, -PANEL.ScrollBarWidth - 2, 0, ROW_HEIGHT)
	local stroke = Widgets.stroke(row, COLOR.Border)

	local edge = Widgets.frame(row, "Edge", COLOR.Accent, 0)
	edge.Size = UDim2.new(0, LAYOUT.BorderThickness * 2, 1, 0)

	local title = Widgets.label(row, "Title", FONT.Heading, TEXT.Body, COLOR.TextPrimary)
	title.Position = UDim2.fromOffset(LAYOUT.PanelPadding + 4, 8)
	title.Size = UDim2.new(1, -(BUY_WIDTH + LAYOUT.PanelPadding * 3), 0, TEXT.Body + 2)
	title.TextTruncate = Enum.TextTruncate.AtEnd
	title.Text = entry.displayName

	local blurb = Widgets.label(row, "Blurb", FONT.Body, TEXT.Small, COLOR.TextSecondary)
	blurb.Position = UDim2.fromOffset(LAYOUT.PanelPadding + 4, 8 + TEXT.Body + 4)
	blurb.Size = UDim2.new(1, -(BUY_WIDTH + LAYOUT.PanelPadding * 3), 0, TEXT.Small + 2)
	blurb.TextTruncate = Enum.TextTruncate.AtEnd
	blurb.Text = entry.blurb

	local price = Widgets.label(row, "Price", FONT.Numeric, TEXT.Small, COLOR.TextSecondary)
	price.AnchorPoint = Vector2.new(1, 1)
	price.Position = UDim2.new(1, -LAYOUT.PanelPadding, 1, -6)
	price.Size = UDim2.fromOffset(BUY_WIDTH, TEXT.Small + 2)
	price.TextXAlignment = Enum.TextXAlignment.Center
	price.Text = string.format("%s %d", ProgressionConfig.CurrencySymbol, entry.cost)

	local button = Widgets.button(row, "Buy")
	button.AnchorPoint = Vector2.new(1, 0)
	button.Position = UDim2.new(1, -LAYOUT.PanelPadding, 0, 6)
	button.Size = UDim2.fromOffset(BUY_WIDTH, ROW_HEIGHT - 16)
	button.BackgroundColor3 = COLOR.PanelRaised
	button.BackgroundTransparency = PANEL.ActionFill
	Widgets.stroke(button, COLOR.Border)

	local buyLabel = Widgets.label(button, "Label", FONT.Heading, TEXT.Tiny, COLOR.TextPrimary)
	buyLabel.Size = UDim2.fromScale(1, 1)
	buyLabel.TextXAlignment = Enum.TextXAlignment.Center

	trove:connect(button.Activated, function()
		--[[ Asked anyway when the row looks unbuyable, because `Active` is a
		     drawing decision made on the last refresh and the server is the only
		     thing that decides. It refuses politely. ]]
		Remotes.Event.RequestRequisition:FireServer(entry.id)
		UiSound.play(AudioConfig.UI.MenuConfirm)
	end)

	table.insert(rows, {
		entry = entry,
		frame = row,
		button = button,
		buyLabel = buyLabel,
		price = price,
		title = title,
		blurb = blurb,
		stroke = stroke,
	})
end

local function build()
	gui = Instance.new("ScreenGui")
	gui.Name = "FL_Requisitions"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = UITheme.DisplayOrder.Settings
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Enabled = false
	gui.Parent = player:WaitForChild("PlayerGui")
	trove:add(gui)

	local layer = ScaleLayer.new(gui, "Scaled")
	local chrome = Widgets.panel(layer, trove, "REQUISITIONS", function()
		RequisitionController:close()
	end)
	panel = chrome.frame
	closeButton = chrome.close

	balanceLabel = Widgets.label(panel, "Balance", FONT.Numeric, TEXT.Body, COLOR.Accent)
	balanceLabel.AnchorPoint = Vector2.new(1, 0)
	balanceLabel.Position = UDim2.new(1, -LAYOUT.PanelPadding, 0, HEADER_HEIGHT + LAYOUT.PanelPadding)
	balanceLabel.Size = UDim2.new(0.4, 0, 0, BALANCE_HEIGHT)
	balanceLabel.TextXAlignment = Enum.TextXAlignment.Right

	caption = Widgets.label(panel, "Caption", FONT.Heading, TEXT.Small, COLOR.TextDim)
	caption.Position = UDim2.fromOffset(LAYOUT.PanelPadding, HEADER_HEIGHT + LAYOUT.PanelPadding)
	caption.Size = UDim2.new(0.6, 0, 0, BALANCE_HEIGHT)
	caption.Text = "PAID BY ONE, CARRIED BY ALL"

	--[[
		What is different about tonight, and what to do about it.

		The modifier is announced in chat at round start and then gone, which is
		fine for "here is what is happening" and useless at the moment the team
		is deciding how to spend a shared currency. This sits directly above the
		rows it is advice about, so ARMORED ZOMBIES and INCENDIARY ROUNDS are on
		screen together rather than a minute apart.

		Only during the hold: between waves the modifier has been live for ten
		minutes and everybody knows.
	]]
	counterLabel = Widgets.label(panel, "Counter", FONT.Body, TEXT.Small, COLOR.Accent)
	counterLabel.Position = UDim2.fromOffset(LAYOUT.PanelPadding, COUNTER_TOP)
	counterLabel.Size = UDim2.new(1, -LAYOUT.PanelPadding * 2, 0, COUNTER_HEIGHT)
	counterLabel.TextWrapped = true
	counterLabel.TextYAlignment = Enum.TextYAlignment.Top
	counterLabel.Visible = false

	list = Widgets.scroller(panel, "List")
	list.Position = UDim2.fromOffset(LAYOUT.PanelPadding, BODY_TOP)
	--[[ Sized and placed by refreshPanelSize, which now has two answers
	     depending on whether the modifier advice is on screen. ]]
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	Widgets.list(list, LAYOUT.ElementGap)
	for _, entry in RequisitionConfig.Catalogue do
		buildRow(entry)
	end

	footRule = Widgets.frame(panel, "FootRule", COLOR.Border, 0)
	footRule.AnchorPoint = Vector2.new(0, 1)
	footRule.Position = UDim2.new(0, 0, 1, -PANEL.FooterHeight)
	footRule.Size = UDim2.new(1, 0, 0, LAYOUT.BorderThickness)

	hint = Widgets.label(panel, "Hint", FONT.Body, TEXT.Small, COLOR.TextDim)
	hint.AnchorPoint = Vector2.new(0, 1)
	hint.Position = UDim2.new(0, LAYOUT.PanelPadding, 1, 0)
	hint.Size = UDim2.new(1, -LAYOUT.PanelPadding * 2, 0, PANEL.FooterHeight)

	--[[
		The ready button, and the only reason it lives on THIS panel.

		The gate and the requisitions are one decision. The team is being held
		before wave 1 precisely so it can read five options and agree who pays,
		and "we are done deciding" is the answer to that question — so the button
		that ends the wait belongs next to the thing being decided, not on a
		separate prompt somewhere else on the screen.

		Hidden outside the hold. Between waves this panel is the same shop it
		always was and there is nothing to be ready for.
	]]
	readyRoot = Widgets.frame(panel, "Ready", COLOR.Panel, 1)
	readyRoot.AnchorPoint = Vector2.new(1, 1)
	readyRoot.Position = UDim2.new(1, -LAYOUT.PanelPadding, 1, -PANEL.FooterHeight)
	readyRoot.Size = UDim2.fromOffset(READY_WIDTH, PANEL.RowHeightTouch)
	readyRoot.Visible = false

	readyButton = Widgets.button(readyRoot, "Button")
	readyButton.Size = UDim2.fromScale(1, 1)
	readyButton.BackgroundColor3 = COLOR.PanelRaised
	readyButton.BackgroundTransparency = 0.1
	readyStroke = Widgets.stroke(readyButton, COLOR.BorderBright)

	readyLabel = Widgets.label(readyButton, "Label", FONT.Heading, TEXT.Small, COLOR.TextPrimary)
	readyLabel.Position = UDim2.fromOffset(0, 4)
	readyLabel.Size = UDim2.new(1, 0, 0, TEXT.Small + 2)
	readyLabel.TextXAlignment = Enum.TextXAlignment.Center

	readyCount = Widgets.label(readyButton, "Count", FONT.Numeric, TEXT.Tiny, COLOR.TextDim)
	readyCount.Position = UDim2.new(0, 0, 0, TEXT.Small + 7)
	readyCount.Size = UDim2.new(1, 0, 0, TEXT.Tiny + 2)
	readyCount.TextXAlignment = Enum.TextXAlignment.Center

	trove:connect(readyButton.Activated, function()
		--[[ A toggle, so a player who readied by accident while three others are
		     still reading is not the reason the round started. ]]
		local mine = Attributes.get(player, PA.Ready, false) == true
		Remotes.Event.SetReady:FireServer(not mine)
		UiSound.play(if mine then AudioConfig.UI.MenuBack else AudioConfig.UI.MenuConfirm)
	end)

	applyTouchSizing()
	refreshPanelSize()
end

-- ── public API ──────────────────────────────────────────────────────────────

function RequisitionController:isOpen(): boolean
	return state.open
end

function RequisitionController:open()
	if state.open then
		return
	end
	state.open = true
	gui.Enabled = true
	applyTouchSizing()
	refreshPanelSize()
	refresh()
	setSuppressed(not menuIsOpen(), holding())
	claimCursor(true)
	GamepadFocus.capture(closeButton)
	UiSound.play(AudioConfig.UI.MenuConfirm)
end

function RequisitionController:close()
	if not state.open then
		return
	end
	--[[ Closing it by hand hands the panel back to the player. The gate will not
	     re-open it and will not close it again on their behalf. ]]
	state.autoOpened = false
	state.open = false
	gui.Enabled = false
	GamepadFocus.release(closeButton)
	setSuppressed(false)
	claimCursor(false)
	if menuIsOpen() then
		callController("MainMenuController", "reassertSuppression")
	end
	UiSound.play(AudioConfig.UI.MenuBack)
end

function RequisitionController:toggle()
	if state.open then
		self:close()
	else
		self:open()
	end
end

-- ── lifecycle ───────────────────────────────────────────────────────────────

function RequisitionController:init()
	build()
end

function RequisitionController:start()
	--[[ Everything this screen draws is an attribute with a changed signal, so
	     it redraws on the change rather than on a clock: a teammate's purchase,
	     a wave ending, and the Scrip a purchase cost all land the moment they
	     happen and cost nothing while nothing is happening. ]]
	for _, name in RequisitionConfig.attributes() do
		trove:connect(Workspace:GetAttributeChangedSignal(name), refresh)
	end
	trove:connect(Workspace:GetAttributeChangedSignal(GA.WavePhase), refresh)
	trove:connect(Workspace:GetAttributeChangedSignal(GA.RoundState), refresh)
	trove:connect(Workspace:GetAttributeChangedSignal(GA.ReadyCount), refresh)
	trove:connect(Workspace:GetAttributeChangedSignal(GA.ReadyNeeded), refresh)
	trove:connect(player:GetAttributeChangedSignal(PA.Scrip), refresh)
	trove:connect(player:GetAttributeChangedSignal(PA.Ready), refresh)

	--[[
		The pre-round window opens the panel by itself.

		A choice nobody is shown is not a choice. Requisitions were reachable
		only by a key most players will never press, which was tolerable when the
		window was a breather between waves — you are already alive and looking
		around — and is not when the whole point of the pause before wave 1 is
		that the team is deciding something together.

		It closes itself again when the gate lifts, but only if it was the one
		that opened it: a player who deliberately opened the shop should not have
		it shut in their face because somebody else pressed READY.
	]]
	--[[
		Opened after the LOADOUT picker, not on top of it.

		Both screens answer to the same round-state edge, so opening on the
		attribute alone put two full panels on the frame and one of them behind
		the other. The loadout question comes first — it decides what you are
		holding, and the requisitions are what you buy on top of that — so this
		waits for LoadoutController to say it is done. If the picker is not up
		at all (a player who joined mid-prep) there is nothing to wait for.
	]]
	local function openForHold()
		if not holding() or state.open then
			return
		end
		state.autoOpened = true
		self:open()
	end

	local loadout = Registry.find("LoadoutController")
	if loadout and loadout.pickerClosed then
		trove:add(loadout.pickerClosed:connect(openForHold))
	end

	trove:connect(Workspace:GetAttributeChangedSignal(GA.ReadyHold), function()
		if holding() then
			local picker = Registry.find("LoadoutController")
			local waiting = picker and typeof(picker.isPickerOpen) == "function" and picker:isPickerOpen()
			if not waiting then
				openForHold()
			end
		elseif state.autoOpened then
			state.autoOpened = false
			self:close()
		elseif state.open then
			--[[ Still open because the PLAYER opened it, and the calm window it
			     was soft-suppressed for is over. Tighten to the ordinary rules
			     rather than leaving them able to walk around a live round with a
			     shop on screen. ]]
			setSuppressed(not menuIsOpen(), false)
		end
		refresh()
	end)

	--[[ A refusal is the only thing this has to hear. A successful purchase
	     arrives as an attribute and as a subtitle, both of which say it better
	     than a panel that may not even be open. ]]
	trove:connect(Remotes.Event.RequisitionResult.OnClientEvent, function(payload: any)
		if typeof(payload) ~= "table" then
			return
		end
		refresh()
		if payload.ok == false and typeof(payload.reason) == "string" then
			hint.Text = string.upper(payload.reason)
			hint.TextColor3 = COLOR.Danger
			UiSound.play(AudioConfig.UI.MenuBack)
		end
	end)

	--[[
		Closing, and only closing.

		OPENING is Action.Requisitions in InputController — a real binding, so it
		appears in the controls screen and can be rebound. That binding cannot
		close the panel: this screen suppresses InputController while it is up,
		as every screen does, so the action is unbound for exactly as long as
		there is something to close. Same arrangement as the backpack.
	]]
	trove:connect(UserInputService.InputBegan, function(input: InputObject, processed: boolean)
		if not state.open then
			return
		end
		if input.KeyCode == Enum.KeyCode.ButtonB then
			RequisitionController:close()
			return
		end
		if processed then
			return
		end
		if input.KeyCode == Enum.KeyCode.Escape or boundToPanel(input.KeyCode) then
			RequisitionController:close()
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

function RequisitionController:destroy()
	trove:destroy()
	table.clear(rows)
end

Registry.register("RequisitionController", RequisitionController)

return RequisitionController
