--!nonstrict
--[[
	PlayController — the four ways into a round.

	PLAY used to go straight to the mode list, and the mode list went straight to
	the matchmaker, which chose a server on the player's behalf. That is the right
	default and a poor ceiling: it is very good at putting you in A round and has
	no answer at all for putting you in a round with three named people.

	So PLAY opens this, and this asks the question the player actually has:

	  QUICK PLAY     the old path, unchanged. Still first, still the default, and
	                 still one press from here — a lobby menu that made every
	                 session cost three taps would be a worse game.
	  CREATE LOBBY   a private server and a code to hand out.
	  JOIN LOBBY     somebody else's code.
	  FIND SERVERS   the public browser as a list you choose from, rather than a
	                 sort somebody else already ran.

	── IT DECIDES NOTHING ───────────────────────────────────────────────────────
	Same rule as the shop and the career panel. No code is validated here, no
	server is judged joinable here, nothing is teleported from here. Every button
	sends a request and draws what LobbyService says came back — including the
	refusals, which are the whole reason a create in Studio says "Studio cannot
	reserve a server" rather than doing nothing at all.

	── ITS OWN MODULE ───────────────────────────────────────────────────────────
	Not four more sections of MainMenuController, which audit.py already reports
	at 182 of Luau's 200 top-level locals. The menu opens this the same way it
	opens the shop, and hands QUICK PLAY straight back to its own mode page.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local AudioConfig = require(Shared.Config.AudioConfig)
local GameModeConfig = require(Shared.Config.GameModeConfig)
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
local MM = GameModeConfig.Matchmaking
local MODES = GameModeConfig.Modes

local player = Players.LocalPlayer

local PANEL_WIDTH = 820
local PANEL_MAX_HEIGHT = 560
local HEADER_HEIGHT = PANEL.HeaderHeight
local FOOTER_HEIGHT = PANEL.FooterHeight

--[[ The four actions down the left, the detail for the chosen one on the right.
     A fraction so it survives a phone, exactly as the shop's LIST_WIDTH does. ]]
local ACTION_WIDTH = 0.36
local COLUMN_GAP = 14
local ACTION_HEIGHT = 62

--[[ Where the per-action control (mode row, code box or server list) begins.
     A constant for the same reason CareerController's BODY_TOP is one: build
     and applyTouchSizing both need it, and two copies of the sum drift. ]]
local CONTROL_TOP = HEADER_HEIGHT + LAYOUT.PanelPadding + TEXT.Heading + 8 + 104

--[[
	The three sizes a finger changes, and why.

	This panel is drawn at ScaleLayer's 0.75 floor on a phone, so a reference
	pixel is three quarters of a real one. A 34-pixel server row is 26 real —
	well under the 42 that PANEL.RowHeightTouch works out to — and the rows are
	stacked touching, so a mis-tap does not miss, it joins the wrong server. The
	commit button was worse at 22 real pixels, on the control that creates a
	lobby.

	The code box grows too. It is the one thing on this screen a player types
	into, and a text field you have to hit twice before the keyboard opens is the
	most annoying possible version of that.
]]
local SERVER_ROW_HEIGHT = 34
local MODE_ROW_HEIGHT = 34
local CODE_BOX_HEIGHT = 44
local TOUCH_HEIGHT = PANEL.RowHeightTouch
--[[ Tall enough to HOLD a full-size button plus its inset, not merely to
     equal one — an inset button inside a 56-pixel footer is 46, which is 34
     real pixels and still under the standard the footer grew for. ]]
local FOOTER_HEIGHT_TOUCH = TOUCH_HEIGHT + 8

local MESSAGE_SECONDS = 5.0

--[[ How long a request may sit unanswered before the button comes back. Every
     path on the server answers, including the refusals, so this only fires on a
     dropped remote — and the cost of not having it is a CREATE button stuck on
     "…" with no way to retry but navigating away and back. ]]
local REQUEST_TIMEOUT = 8

--[[
	The four, in the order a player wants them.

	QUICK PLAY first and phrased as the default, because it IS: somebody who
	opened this screen by reflex should be able to press the top item and get the
	game they had before any of this existed.
]]
local ACTIONS = {
	{
		id = "Quick",
		title = "QUICK PLAY",
		line = "Straight into the fullest round we can find.",
		detail = "The game picks. It prefers a server that already has people in it — a horde needs a crowd, and four survivors spread across four servers is four lonely maps.\n\nPick a mode on the next screen.",
		verb = "CHOOSE A MODE",
	},
	{
		id = "Create",
		title = "CREATE LOBBY",
		line = "A private server, and a code to hand out.",
		detail = "Reserves a server nobody reaches by accident and gives you a six-character code. Read it out, and whoever types it lands in your round.\n\nThe code lasts two hours.",
		verb = "CREATE",
	},
	{
		id = "Join",
		title = "JOIN LOBBY",
		line = "Somebody read you a code.",
		detail = "Type it below. Case does not matter and neither do spaces or dashes — the code is six characters and nothing else in it counts.",
		verb = "JOIN",
	},
	{
		id = "Find",
		title = "FIND SERVERS",
		line = "Every round you could walk into.",
		detail = "The same list the matchmaker reads, shown rather than sorted. A round still open to joiners is a round you can pick.",
		verb = "REFRESH",
	},
}

--[[ What LobbyService's reason codes mean, in words. Server-side they are short
     tokens so the sentence can change here without a deploy. ]]
local REASONS: { [string]: string } = {
	studio = "STUDIO CANNOT RESERVE A SERVER — PRESS PLAY INSTEAD.",
	unavailable = "LOBBIES ARE UNAVAILABLE RIGHT NOW. TRY QUICK PLAY.",
	badcode = "THAT IS NOT A CODE. SIX CHARACTERS, LETTERS AND DIGITS.",
	notfound = "NO LOBBY WITH THAT CODE. IT MAY HAVE EXPIRED.",
	teleport = "COULD NOT REACH THAT SERVER.",
}

local PlayController = {}

local trove = Trove.new()
local rowTrove = Trove.new()

local gui: ScreenGui
local panel: Frame
local detailTitle: TextLabel
local detailBody: TextLabel
local codeLabel: TextLabel
local codeBox: TextBox
local modeRow: Frame
local serverList: ScrollingFrame
local footRule: Frame
local actionButton: TextButton
local actionLabel: TextLabel
local hint: TextLabel

local state = {
	open = false,
	suppressed = false,
	choice = "Quick",
	mode = MODES.Classic,
	pending = false,
	messageUntil = 0,
	firstRow = nil :: GuiButton?,
}

local restore = {
	cameraMode = nil :: any,
	cameraZoom = nil :: any,
	cameraMinZoom = nil :: any,
	mouseIcon = nil :: any,
}

local actionRows: { { button: TextButton, title: TextLabel, line: TextLabel, id: string } } = {}

-- ── helpers ─────────────────────────────────────────────────────────────────

local function callController(name: string, method: string, ...: any)
	local controller = Registry.find(name)
	if controller and typeof(controller[method]) == "function" then
		pcall(controller[method], controller, ...)
	end
end

--[[ Asked at layout time rather than remembered, so a scheme change between two
     openings is picked up on the next one. ]]
local function isTouch(): boolean
	local input = Registry.find("InputController")
	if not input or typeof(input.isTouchScheme) ~= "function" then
		return false
	end
	local ok, touch = pcall(input.isTouchScheme, input)
	return ok and touch == true
end

local function footerHeight(): number
	return if isTouch() then FOOTER_HEIGHT_TOUCH else FOOTER_HEIGHT
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

local function claimCursor(value: boolean)
	if value then
		FreeCursor.take(restore)
	else
		FreeCursor.giveBack(restore)
	end
end

local function showMessage(text: string, color: Color3)
	hint.Text = text
	hint.TextColor3 = color
	state.messageUntil = os.clock() + MESSAGE_SECONDS
end

-- ── drawing ─────────────────────────────────────────────────────────────────

local function currentAction(): any
	for _, entry in ACTIONS do
		if entry.id == state.choice then
			return entry
		end
	end
	return ACTIONS[1]
end

--[[ Everything whose size depends on the input scheme, in one place. Run at
     build so the first frame is right, and again on every open so a scheme
     change between two openings is picked up. The server rows and the mode
     buttons size themselves as they are created — both are rebuilt after this
     runs, so they read the same answer. ]]
--[[
	Moves the panel clear of the on-screen keyboard, and back again.

	The size is asked for in REAL pixels and the panel lives inside a ScaleLayer,
	so it has to be divided by the factor before it means anything here — the
	same conversion ScaleLayer.getFactor exists for. Half the keyboard is enough:
	the panel only has to clear the field, not the whole thing, and lifting by
	the full height would push the header off the top of a short phone.
]]
local function liftForKeyboard(active: boolean)
	if not panel then
		return
	end
	local lift = 0
	if active and isTouch() then
		local factor = ScaleLayer.getFactor()
		local keyboard = UserInputService.OnScreenKeyboardSize.Y
		if factor > 0 and keyboard > 0 then
			lift = (keyboard / factor) * 0.5
		end
	end
	panel.Position = UDim2.new(0.5, 0, 0.5, -lift)
end

local function applyTouchSizing()
	local foot = footerHeight()
	if footRule then
		footRule.Position = UDim2.new(0, 0, 1, -foot)
	end
	if hint then
		hint.Size = UDim2.new(0.6, 0, 0, foot)
	end
	if actionButton then
		actionButton.Size = UDim2.fromOffset(210, if isTouch() then TOUCH_HEIGHT else foot - 10)
	end
	if codeBox then
		codeBox.Size = UDim2.new(
			1 - ACTION_WIDTH,
			-(LAYOUT.PanelPadding * 2 + COLUMN_GAP),
			0,
			if isTouch() then TOUCH_HEIGHT else CODE_BOX_HEIGHT
		)
	end
	if serverList then
		serverList.Size = UDim2.new(
			1 - ACTION_WIDTH,
			-(LAYOUT.PanelPadding * 2 + COLUMN_GAP),
			1,
			-(CONTROL_TOP + foot + 12)
		)
	end
end

local function refresh()
	if not state.open then
		return
	end
	local action = currentAction()

	for _, row in actionRows do
		local selected = row.id == state.choice
		row.title.TextColor3 = if selected then COLOR.Accent else COLOR.TextPrimary
		row.line.TextColor3 = if selected then COLOR.TextSecondary else COLOR.TextDim
		row.button.BackgroundTransparency = if selected then PANEL.ActionFill else PANEL.RaisedFill
	end

	detailTitle.Text = action.title
	detailBody.Text = action.detail

	--[[ Only one of these three belongs to any given action, and they are
	     mutually exclusive rather than stacked: a code box under a server list
	     would invite typing a code into a screen that does not read one. ]]
	modeRow.Visible = state.choice == "Create"
	codeBox.Visible = state.choice == "Join"
	serverList.Visible = state.choice == "Find"
	codeLabel.Visible = state.choice == "Create" and codeLabel.Text ~= ""

	actionLabel.Text = if state.pending then "…" else action.verb
	actionLabel.TextColor3 = if state.pending then COLOR.TextDim else COLOR.TextPrimary
	actionButton.Active = not state.pending

	for _, child in modeRow:GetChildren() do
		if child:IsA("TextButton") then
			local label = child:FindFirstChild("Label") :: TextLabel?
			if label then
				label.TextColor3 = if child.Name == state.mode then COLOR.Accent else COLOR.TextDim
			end
		end
	end

	if os.clock() >= state.messageUntil then
		hint.Text = action.line
		hint.TextColor3 = COLOR.TextDim
	end
end

local function drawServers(payload: any)
	--[[ clean, NOT destroy. Trove:destroy latches — a second call returns early
	     without cleaning — so destroying a trove that is reused would disconnect
	     the first list's rows and then silently leak every list after it. The
	     shop's releaseRows makes the same distinction. ]]
	rowTrove:clean()
	for _, child in serverList:GetChildren() do
		if child:IsA("GuiButton") or child:IsA("TextLabel") then
			child:Destroy()
		end
	end

	local servers = if typeof(payload) == "table" and typeof(payload.servers) == "table"
		then payload.servers
		else {}

	if #servers == 0 then
		--[[ Said out loud rather than left blank. An empty list and a broken list
		     look identical, and the difference matters here: one means "be the
		     first", the other means "try again". ]]
		local empty = Widgets.label(serverList, "Empty", FONT.Body, TEXT.Small, COLOR.TextDim)
		empty.Size = UDim2.new(1, 0, 0, 40)
		empty.TextWrapped = true
		empty.Text = "NO OPEN ROUNDS FOUND. QUICK PLAY WILL START ONE."
		return
	end

	for index, entry in servers do
		local button = Widgets.button(serverList, "Server" .. index)
		button.LayoutOrder = index
		button.Size =
			UDim2.new(1, -PANEL.ScrollBarWidth - 2, 0, if isTouch() then TOUCH_HEIGHT else SERVER_ROW_HEIGHT)
		button.BackgroundColor3 = COLOR.PanelRaised
		button.BackgroundTransparency = PANEL.RaisedFill

		local name = Widgets.label(button, "Name", FONT.Heading, TEXT.Body, COLOR.TextPrimary)
		name.Position = UDim2.fromOffset(LAYOUT.PanelPadding, 0)
		name.Size = UDim2.new(0.55, 0, 1, 0)
		name.Text = string.upper(tostring(entry.mode or "ROUND"))

		local count = Widgets.label(button, "Count", FONT.Numeric, TEXT.Small, COLOR.TextSecondary)
		count.AnchorPoint = Vector2.new(1, 0)
		count.Position = UDim2.new(1, -LAYOUT.PanelPadding, 0, 0)
		count.Size = UDim2.new(0.42, 0, 1, 0)
		count.TextXAlignment = Enum.TextXAlignment.Right
		local wave = tonumber(entry.waveIndex) or 0
		count.Text = if wave > 0
			then string.format("%d PLAYING  ·  WAVE %d", tonumber(entry.players) or 0, wave)
			else string.format("%d WAITING", tonumber(entry.players) or 0)

		Widgets.rowHover(rowTrove, button)
		rowTrove:connect(button.Activated, function()
			--[[ Joining a listed server is the same request Quick Play makes: the
			     matchmaker's own rule is that the server you are already in wins,
			     then the fullest one it can see — and the row was drawn from that
			     same list. Sending a JobId the client picked would be asking the
			     server to trust a client about where to send it. ]]
			UiSound.play(AudioConfig.UI.MenuConfirm)
			Remotes.Event.RequestMode:FireServer(entry.mode or state.mode)
			PlayController:close()
			callController("MainMenuController", "reassertSuppression")
		end)
	end
end

-- ── acting ──────────────────────────────────────────────────────────────────

--[[ Marks a request in flight and arms the timeout. The generation token is what
     stops an old timeout cancelling a NEW request: press CREATE, wait, press it
     again, and without it the first timer would clear the second attempt. ]]
local pendingGeneration = 0
local function beginRequest()
	state.pending = true
	pendingGeneration += 1
	local mine = pendingGeneration
	task.delay(REQUEST_TIMEOUT, function()
		if state.pending and pendingGeneration == mine then
			state.pending = false
			showMessage("NO ANSWER FROM THE SERVER. TRY AGAIN.", COLOR.Danger)
			refresh()
		end
	end)
end

local function commit()
	local action = currentAction()

	if action.id == "Quick" then
		--[[ Handed straight back to the menu's own mode page rather than
		     reimplemented here. That page already carries the pending state, the
		     refusal messages and the countdown; a second copy would be a second
		     thing to keep in step. ]]
		PlayController:close()
		callController("MainMenuController", "showModes")
		return
	end

	if action.id == "Find" then
		beginRequest()
		Remotes.Event.RequestServerList:FireServer(state.mode)
		refresh()
		return
	end

	if action.id == "Create" then
		beginRequest()
		codeLabel.Text = ""
		Remotes.Event.CreateLobby:FireServer(state.mode)
		refresh()
		return
	end

	if action.id == "Join" then
		beginRequest()
		Remotes.Event.JoinLobby:FireServer(codeBox.Text)
		refresh()
		return
	end
end

local function onLobbyResult(payload: any)
	if typeof(payload) ~= "table" then
		return
	end
	state.pending = false

	if payload.ok == true then
		if payload.action == "Create" and typeof(payload.code) == "string" then
			codeLabel.Text = payload.code
			showMessage("LOBBY READY. TAKING YOU THERE.", COLOR.Accent)
		else
			showMessage("FOUND IT. TAKING YOU THERE.", COLOR.Accent)
		end
	else
		local reason = tostring(payload.reason or "")
		showMessage(REASONS[reason] or "THAT DID NOT WORK.", COLOR.Danger)
		UiSound.play(AudioConfig.UI.MenuBack)
	end
	refresh()
end

-- ── build ───────────────────────────────────────────────────────────────────

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

local function buildAction(index: number, definition: any, top: number)
	local button = Widgets.button(panel, definition.id)
	button.Position = UDim2.fromOffset(LAYOUT.PanelPadding, top + (index - 1) * (ACTION_HEIGHT + 6))
	button.Size = UDim2.new(ACTION_WIDTH, -LAYOUT.PanelPadding, 0, ACTION_HEIGHT)
	button.BackgroundColor3 = COLOR.PanelRaised
	button.BackgroundTransparency = PANEL.RaisedFill
	Widgets.stroke(button, COLOR.Border)

	local bar = Widgets.frame(button, "Bar", COLOR.Accent, 0)
	bar.Size = UDim2.new(0, LAYOUT.BorderThickness * 2, 1, 0)

	local title = Widgets.label(button, "Title", FONT.Heading, TEXT.Large, COLOR.TextPrimary)
	title.Position = UDim2.fromOffset(LAYOUT.PanelPadding + 6, 8)
	title.Size = UDim2.new(1, -LAYOUT.PanelPadding * 2, 0, TEXT.Large + 2)
	title.Text = definition.title

	local line = Widgets.label(button, "Line", FONT.Body, TEXT.Small, COLOR.TextDim)
	line.Position = UDim2.fromOffset(LAYOUT.PanelPadding + 6, 8 + TEXT.Large + 4)
	line.Size = UDim2.new(1, -LAYOUT.PanelPadding * 2, 0, TEXT.Small + 2)
	line.TextTruncate = Enum.TextTruncate.AtEnd
	line.Text = definition.line

	trove:connect(button.Activated, function()
		if state.choice == definition.id then
			return
		end
		state.choice = definition.id
		state.pending = false
		UiSound.play(AudioConfig.UI.MenuHover)
		refresh()
	end)

	if index == 1 then
		state.firstRow = button
	end
	table.insert(actionRows, { button = button, title = title, line = line, id = definition.id })
end

local function buildModeRow(top: number, left: number, width: number)
	modeRow = Widgets.frame(panel, "Modes", COLOR.Panel, 1)
	modeRow.Position = UDim2.new(ACTION_WIDTH, left, 0, top)
	modeRow.Size = UDim2.new(1 - ACTION_WIDTH, width, 0, if isTouch() then TOUCH_HEIGHT else MODE_ROW_HEIGHT)
	modeRow.Visible = false

	local ids = { MODES.Classic, MODES.Versus }
	for index, id in ids do
		local button = Widgets.button(modeRow, id)
		button.Position = UDim2.new((index - 1) / #ids, 0, 0, 0)
		button.Size = UDim2.new(1 / #ids, -6, 1, 0)
		button.BackgroundColor3 = COLOR.PanelRaised
		button.BackgroundTransparency = PANEL.RaisedFill
		Widgets.stroke(button, COLOR.Border)

		local label = Widgets.label(button, "Label", FONT.Heading, TEXT.Body, COLOR.TextDim)
		label.Size = UDim2.fromScale(1, 1)
		label.TextXAlignment = Enum.TextXAlignment.Center
		label.Text = string.upper(id)

		trove:connect(button.Activated, function()
			state.mode = id
			UiSound.play(AudioConfig.UI.MenuHover)
			refresh()
		end)
	end
end

local function build()
	gui = Instance.new("ScreenGui")
	gui.Name = "FL_Play"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = UITheme.DisplayOrder.Settings
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Enabled = false
	gui.Parent = player:WaitForChild("PlayerGui")
	trove:add(gui)

	local layer = ScaleLayer.new(gui, "Scaled")
	local chrome = Widgets.panel(layer, trove, "PLAY", function()
		PlayController:close()
	end)
	panel = chrome.frame
	panel.Size = UDim2.new(0, PANEL_WIDTH, PANEL.HeightScale, 0)

	local top = HEADER_HEIGHT + LAYOUT.PanelPadding
	for index, definition in ACTIONS do
		buildAction(index, definition, top)
	end

	local detailLeft = LAYOUT.PanelPadding + COLUMN_GAP
	local detailWidth = -(LAYOUT.PanelPadding * 2 + COLUMN_GAP)

	detailTitle = Widgets.label(panel, "DetailTitle", FONT.Display, TEXT.Heading, COLOR.TextPrimary)
	detailTitle.Position = UDim2.new(ACTION_WIDTH, detailLeft, 0, top)
	detailTitle.Size = UDim2.new(1 - ACTION_WIDTH, detailWidth, 0, TEXT.Heading + 2)

	detailBody = Widgets.label(panel, "DetailBody", FONT.Body, TEXT.Small, COLOR.TextSecondary)
	detailBody.Position = UDim2.new(ACTION_WIDTH, detailLeft, 0, top + TEXT.Heading + 8)
	detailBody.Size = UDim2.new(1 - ACTION_WIDTH, detailWidth, 0, 96)
	detailBody.TextWrapped = true
	detailBody.TextYAlignment = Enum.TextYAlignment.Top

	local controlTop = CONTROL_TOP
	buildModeRow(controlTop, detailLeft, detailWidth)

	--[[ The code, set as large as the panel allows. It exists to be read off a
	     screen by somebody sitting next to you or squinting at a stream, and
	     every other consideration on this panel is subordinate to that. ]]
	codeLabel = Widgets.label(panel, "Code", FONT.Display, TEXT.Display, COLOR.Accent)
	codeLabel.Position = UDim2.new(ACTION_WIDTH, detailLeft, 0, controlTop + 44)
	codeLabel.Size = UDim2.new(1 - ACTION_WIDTH, detailWidth, 0, TEXT.Display + 6)
	codeLabel.TextXAlignment = Enum.TextXAlignment.Center
	codeLabel.Visible = false
	codeLabel.Text = ""

	codeBox = Instance.new("TextBox")
	codeBox.Name = "CodeEntry"
	codeBox.BackgroundColor3 = COLOR.PanelRaised
	codeBox.BackgroundTransparency = PANEL.RaisedFill
	codeBox.BorderSizePixel = 0
	codeBox.Font = FONT.Display
	codeBox.TextSize = TEXT.Heading
	codeBox.TextColor3 = COLOR.TextPrimary
	codeBox.PlaceholderText = "ENTER CODE"
	codeBox.PlaceholderColor3 = COLOR.TextDim
	codeBox.Text = ""
	codeBox.ClearTextOnFocus = false
	codeBox.TextXAlignment = Enum.TextXAlignment.Center
	codeBox.Position = UDim2.new(ACTION_WIDTH, detailLeft, 0, controlTop)
	codeBox.Size = UDim2.new(1 - ACTION_WIDTH, detailWidth, 0, 44)
	codeBox.Visible = false
	codeBox.Parent = panel
	Widgets.stroke(codeBox, COLOR.Border)

	--[[
		Upper-cased and clipped as it is typed.

		The server cleans whatever arrives and is the only thing that decides
		whether a code is real — this is not validation. It is the field agreeing
		with the code the player is looking at: a lobby code is printed in capitals
		on the creator's screen, so a box that shows lowercase while claiming to
		match it is the box lying about what it holds. Clipping past the length
		stops a paste turning the field into a scrolling ribbon.
	]]
	trove:connect(codeBox:GetPropertyChangedSignal("Text"), function()
		local wanted = string.upper(string.sub(codeBox.Text, 1, MM.LobbyCodeLength))
		if codeBox.Text ~= wanted then
			codeBox.Text = wanted
		end
	end)

	serverList = Widgets.scroller(panel, "Servers")
	serverList.Position = UDim2.new(ACTION_WIDTH, detailLeft, 0, controlTop)
	serverList.Size = UDim2.new(1 - ACTION_WIDTH, detailWidth, 1, -(controlTop + FOOTER_HEIGHT + 12))
	serverList.AutomaticCanvasSize = Enum.AutomaticSize.Y
	serverList.Visible = false
	Widgets.list(serverList, LAYOUT.ElementGap)

	footRule = Widgets.frame(panel, "FootRule", COLOR.Border, 0)
	footRule.AnchorPoint = Vector2.new(0, 1)
	footRule.Position = UDim2.new(0, 0, 1, -FOOTER_HEIGHT)
	footRule.Size = UDim2.new(1, 0, 0, LAYOUT.BorderThickness)

	hint = Widgets.label(panel, "Hint", FONT.Body, TEXT.Small, COLOR.TextDim)
	hint.AnchorPoint = Vector2.new(0, 1)
	hint.Position = UDim2.new(0, LAYOUT.PanelPadding, 1, 0)
	hint.Size = UDim2.new(0.6, 0, 0, FOOTER_HEIGHT)
	hint.TextTruncate = Enum.TextTruncate.AtEnd

	actionButton = Widgets.button(panel, "Commit")
	actionButton.AnchorPoint = Vector2.new(1, 1)
	actionButton.Position = UDim2.new(1, -LAYOUT.PanelPadding, 1, -6)
	actionButton.Size = UDim2.fromOffset(210, FOOTER_HEIGHT - 10)
	actionButton.BackgroundColor3 = COLOR.PanelRaised
	actionButton.BackgroundTransparency = PANEL.ActionFill
	local commitStroke = Widgets.stroke(actionButton, COLOR.Border)

	actionLabel = Widgets.label(actionButton, "Label", FONT.Heading, TEXT.Body, COLOR.TextPrimary)
	actionLabel.Size = UDim2.fromScale(1, 1)
	actionLabel.TextXAlignment = Enum.TextXAlignment.Center
	Widgets.outlineHover(trove, actionButton, commitStroke)
	trove:connect(actionButton.Activated, function()
		if state.pending then
			return
		end
		UiSound.play(AudioConfig.UI.MenuConfirm)
		commit()
	end)

	applyTouchSizing()
	refreshPanelSize()
end

-- ── public API ──────────────────────────────────────────────────────────────

function PlayController:isOpen(): boolean
	return state.open
end

function PlayController:open()
	if state.open then
		return
	end
	state.open = true
	state.pending = false
	state.messageUntil = 0
	gui.Enabled = true
	refreshPanelSize()
	applyTouchSizing()
	refresh()
	setSuppressed(not menuIsOpen())
	claimCursor(true)
	GamepadFocus.capture(state.firstRow)
	UiSound.play(AudioConfig.UI.MenuConfirm)
end

function PlayController:close()
	if not state.open then
		return
	end
	state.open = false
	gui.Enabled = false
	--[[ Put back before it is hidden. A panel closed while the code box still had
	     focus would be reopened later still shifted up by a keyboard that is no
	     longer there. ]]
	liftForKeyboard(false)
	GamepadFocus.release(state.firstRow)
	setSuppressed(false)
	claimCursor(false)
	if menuIsOpen() then
		callController("MainMenuController", "reassertSuppression")
	end
	UiSound.play(AudioConfig.UI.MenuBack)
end

function PlayController:toggle()
	if state.open then
		self:close()
	else
		self:open()
	end
end

-- ── lifecycle ───────────────────────────────────────────────────────────────

function PlayController:init()
	build()
end

function PlayController:start()
	trove:connect(Remotes.Event.LobbyResult.OnClientEvent, onLobbyResult)
	trove:connect(Remotes.Event.ServerListUpdated.OnClientEvent, function(payload: any)
		state.pending = false
		drawServers(payload)
		refresh()
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

	trove:connect(UserInputService.InputBegan, function(input: InputObject, processed: boolean)
		if not state.open then
			return
		end
		if input.KeyCode == Enum.KeyCode.ButtonB then
			PlayController:close()
			return
		end
		if not processed and input.KeyCode == Enum.KeyCode.Escape then
			PlayController:close()
		end
	end)

	--[[ Enter commits from the code box, which is the only place on this panel a
	     keyboard is already in use. Everywhere else it would be a hidden second
	     meaning for a key the player has no reason to press. ]]
	trove:connect(codeBox.FocusLost, function(enterPressed: boolean)
		liftForKeyboard(false)
		if enterPressed and state.open and not state.pending then
			commit()
		end
	end)

	--[[
		The on-screen keyboard covers the field it is there to fill.

		This is the only text box in the game, and on a phone Roblox raises the
		keyboard over the bottom of the screen — which is where a centred panel's
		lower half is. A player taps JOIN LOBBY, taps the box, and the thing they
		are typing into is behind the keys.

		So the panel steps up out of the way while the box has focus and drops
		back when it loses it. Focused rather than the keyboard's own visibility
		signal: this box is the only reason the keyboard ever appears here, and
		tying the lift to the field means it cannot be left raised by a keyboard
		that closed some other way.
	]]
	trove:connect(codeBox.Focused, function()
		liftForKeyboard(true)
	end)
end

function PlayController:destroy()
	rowTrove:destroy()
	table.clear(actionRows)
	trove:destroy()
end

Registry.register("PlayController", PlayController)

return PlayController
