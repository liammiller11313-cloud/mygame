--!nonstrict
--[[
	LeaderboardController — the RANKS panel.

	Three tabs, a hundred rows each, and one line at the bottom that is always
	about you. Everything on it came off a remote; this file computes nothing, in
	the same sense the shop and the career panel compute nothing — a rank a client
	worked out for itself is a rank the server never agreed to.

	── THE ROW IS A RANK, A TAG, A NAME AND A NUMBER ───────────────────────────
	The tag is the callsign the player earned on the pass track, in the accent
	colour they earned with it. It is resolved HERE and not on the server, and
	that is the interesting decision: a callsign rides Player attributes precisely
	so every client already has everybody else's, which means the ninety players
	on this page who are not in this server have no tag to look up and no request
	could produce one. So a row shows a tag when its owner is here and nothing
	when they are not.

	That sounds like a limitation and it is the opposite — it means the four names
	you recognise on a global board are exactly the four that light up, which is
	the thing a leaderboard is for. See LeaderboardConfig.tagFor.

	── YOUR LINE IS PINNED, AND IT IS HONEST ABOUT WHAT IT KNOWS ───────────────
	Under the list, always, is your own number. It has a RANK on it only when you
	are somewhere on the page — because there is no request on an
	OrderedDataStore that answers "what rank is this one player" without walking
	the whole thing, and inventing an answer is worse than not having one. So it
	says your value always and your position when it is knowable, which is what
	every game this is imitating actually does.

	── IT IS ALLOWED TO BE EMPTY ───────────────────────────────────────────────
	A brand new board legitimately has nobody on it, a Studio session usually has
	no DataStore access, and a live server can be refused. All three end in a line
	of text saying which, rather than an empty box a player reads as broken.

	── AND IT IS UP TO TWO MINUTES OLD ─────────────────────────────────────────
	Said on the screen, in words. The page is cached per server for
	LeaderboardConfig.CacheSeconds, so a player who has just finished a round may
	not see themselves move yet — and a board that silently disagreed with the
	round somebody just played is a board they stop believing.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attributes = require(Shared.Net.Attributes)
local AudioConfig = require(Shared.Config.AudioConfig)
local LeaderboardConfig = require(Shared.Config.LeaderboardConfig)
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
local PA = Attributes.Player

local player = Players.LocalPlayer

local PANEL_WIDTH = 720
local HEADER_HEIGHT = PANEL.HeaderHeight

--[[
	The two controls on this screen a finger has to hit, and both are sized from
	PANEL.RowHeightTouch rather than from how they look on a desktop.

	The interface is drawn at ScaleLayer's 0.75 floor on a phone, so a reference
	pixel is three quarters of a real one and this project's touch standard is 42
	REAL pixels. These were 40 and 46 when they were drawn against a mouse, which
	is 30 and 34.5 — both comfortably under it, on a screen whose entire content
	is a list you tab between.

	Unconditional rather than input-dependent, following the argument the main
	menu's own NAV_HEIGHT makes: the difference is invisible on a desktop, and a
	control that resizes when somebody picks up a controller is a control with two
	layouts to keep working instead of one.
]]
local TAB_HEIGHT = PANEL.RowHeightTouch
local BLURB_HEIGHT = 18
--[[ A row is not a target — nothing on this list is pressable — so it stays the
     size that fits a hundred of them on a screen. ]]
local ROW_HEIGHT = 30
local SELF_HEIGHT = PANEL.RowHeightTouch

--[[ Column geometry, as fractions of the row. Fractions rather than offsets for
     the reason every panel here uses them: the whole thing is drawn at
     ScaleLayer's 0.75 floor on a phone and an offset column would run off it.

     The number is right-aligned to the row's edge rather than given a column,
     because the numbers on a body-count board are five digits and the ones on a
     victories board are one, and a left-aligned column sized for either looks
     broken drawing the other. ]]
local RANK_WIDTH = 0.09
local TAG_WIDTH = 0.22
local VALUE_WIDTH = 0.20

--[[ A request the server never answered. The panel says so rather than sitting
     on LOADING forever, which reads as a board with nobody on it. ]]
local ANSWER_TIMEOUT = 8

local LeaderboardController = {}

local trove = Trove.new()

local gui: ScreenGui
local panel: Frame
local closeButton: TextButton
local blurbLabel: TextLabel
local statusLabel: TextLabel
local listFrame: ScrollingFrame
local selfRank: TextLabel
local selfTag: TextLabel
local selfName: TextLabel
local selfValue: TextLabel
local tabButtons: { any } = {}
local rowFrames: { any } = {}

local state = {
	open = false,
	board = LeaderboardConfig.Boards[1].id,
	--[[ One entry per board: the last page the server sent, and when we asked.
	     Kept across closes so re-opening the panel draws instantly and refreshes
	     underneath, rather than showing LOADING for a list it already has. ]]
	pages = {} :: { [string]: any },
	askedAt = {} :: { [string]: number },
}

local function callController(name: string, method: string, ...: any)
	local controller: any = Registry.find(name)
	if controller and typeof(controller[method]) == "function" then
		controller[method](controller, ...)
	end
end

local function menuIsOpen(): boolean
	local menu: any = Registry.find("MainMenuController")
	return menu ~= nil and typeof(menu.isOpen) == "function" and menu:isOpen()
end

local function setSuppressed(value: boolean)
	callController("MainMenuController", "setSuppressed", value)
end

local function restore()
	if state.open then
		LeaderboardController:close()
	end
end

--[[ Thousands separators. A six-figure body count set solid is a number nobody
     reads, and this board is nothing but numbers. ]]
local function commas(value: number): string
	local text = tostring(math.max(math.floor(value), 0))
	local out = text
	while true do
		local replaced: number
		out, replaced = string.gsub(out, "^(-?%d+)(%d%d%d)", "%1,%2")
		if replaced == 0 then
			break
		end
	end
	return out
end

--[[ The tag and colour for a name, when that player is in this server. See the
     header: for anybody else there is nothing to look up and the honest answer
     is no tag rather than an invented one. ]]
local function tagFor(name: string): (string, Color3?)
	local other = Players:FindFirstChild(name)
	if not other or not other:IsA("Player") then
		return "", nil
	end
	return LeaderboardConfig.tagFor(
		tostring(other:GetAttribute(PA.Callsign) or ""),
		tostring(other:GetAttribute(PA.Accent) or "")
	)
end

local function currentBoard()
	return LeaderboardConfig.get(state.board) or LeaderboardConfig.Boards[1]
end

--[[
	Paints every tab for the current selection.

	Its own function because THREE things want to write these colours: a redraw
	after a page lands, the press that changes boards, and a mouse leaving a
	button. Widgets.hover cannot be used here for exactly that reason — it
	captures the label's colour at BUILD time and restores it on leave, so
	hovering the active tab would put it back to the inactive dim and leave it
	there until something else happened to redraw.
]]
local function paintTabs()
	local id = currentBoard().id
	for _, tab in tabButtons do
		local active = tab.id == id
		tab.label.TextColor3 = if active then COLOR.AccentBright else COLOR.TextDim
		tab.button.BackgroundColor3 = COLOR.PanelRaised
		tab.button.BackgroundTransparency = if active then PANEL.ActionFill else 1
	end
end

-- ── asking ──────────────────────────────────────────────────────────────────

local refresh: () -> ()

local function ask(boardId: string)
	state.askedAt[boardId] = os.clock()
	Remotes.Event.RequestLeaderboard:FireServer(boardId)
	--[[ One delayed redraw, so the LOADING line can become NO ANSWER. Nothing
	     else on this panel is on a clock — a page arriving redraws it — and
	     without this the failure case is the one state the screen can enter and
	     never leave. ]]
	task.delay(ANSWER_TIMEOUT, function()
		if state.open and not state.pages[boardId] then
			refresh()
		end
	end)
end

-- ── drawing ─────────────────────────────────────────────────────────────────

local function buildRow(index: number)
	local row = Widgets.frame(listFrame, "Row" .. index, COLOR.PanelRaised, PANEL.RaisedFill)
	row.LayoutOrder = index
	row.Size = UDim2.new(1, 0, 0, ROW_HEIGHT)
	row.Visible = false

	local rank = Widgets.label(row, "Rank", FONT.Numeric, TEXT.Small, COLOR.TextDim)
	rank.Position = UDim2.fromOffset(LAYOUT.PanelPadding, 0)
	rank.Size = UDim2.new(RANK_WIDTH, 0, 1, 0)

	local tag = Widgets.label(row, "Tag", FONT.Heading, TEXT.Tiny, COLOR.Accent)
	tag.Position = UDim2.new(RANK_WIDTH, LAYOUT.PanelPadding, 0, 0)
	tag.Size = UDim2.new(TAG_WIDTH, 0, 1, 0)
	tag.TextTruncate = Enum.TextTruncate.AtEnd

	local name = Widgets.label(row, "Name", FONT.Body, TEXT.Small, COLOR.TextPrimary)
	name.Position = UDim2.new(RANK_WIDTH + TAG_WIDTH, LAYOUT.PanelPadding, 0, 0)
	name.Size = UDim2.new(1 - RANK_WIDTH - TAG_WIDTH - VALUE_WIDTH, 0, 1, 0)
	name.TextTruncate = Enum.TextTruncate.AtEnd

	local value = Widgets.label(row, "Value", FONT.Numeric, TEXT.Small, COLOR.Accent)
	value.AnchorPoint = Vector2.new(1, 0)
	value.Position = UDim2.new(1, -LAYOUT.PanelPadding, 0, 0)
	value.Size = UDim2.new(VALUE_WIDTH, 0, 1, 0)
	value.TextXAlignment = Enum.TextXAlignment.Right

	rowFrames[index] = { row = row, rank = rank, tag = tag, name = name, value = value }
end

--[[ Writes one row, or hides it. Rows are built once and written into rather
     than destroyed and remade: a hundred frames rebuilt on every tab press is a
     hundred frames of garbage three times a second while somebody flicks
     between boards. ]]
local function drawRow(index: number, entry: any?)
	local views = rowFrames[index]
	if not views then
		return
	end
	if not entry then
		views.row.Visible = false
		return
	end

	local mine = entry.userId == player.UserId
	views.row.Visible = true
	views.rank.Text = "#" .. tostring(entry.rank)
	views.name.Text = tostring(entry.name)
	views.value.Text = commas(entry.value)

	local tag, accent = tagFor(tostring(entry.name))
	views.tag.Text = tag
	views.tag.TextColor3 = accent or COLOR.Accent

	--[[ Your own row is lit wherever it lands. A player scrolling to eightieth
	     should be able to find themselves without reading eighty names. ]]
	views.name.TextColor3 = if mine then COLOR.AccentBright else COLOR.TextPrimary
	views.row.BackgroundTransparency = if mine then PANEL.ActionFill else PANEL.RaisedFill
end

local function refreshSelf(page: any?)
	local board = currentBoard()
	local me = if typeof(page) == "table" then page.me else nil

	local tag, accent = LeaderboardConfig.tagFor(
		tostring(player:GetAttribute(PA.Callsign) or ""),
		tostring(player:GetAttribute(PA.Accent) or "")
	)
	selfTag.Text = tag
	selfTag.TextColor3 = accent or COLOR.Accent
	selfName.Text = player.Name

	if typeof(me) ~= "table" then
		selfRank.Text = "—"
		selfValue.Text = "—"
		return
	end

	--[[ The rank comes off the PAGE rather than off `me`, because the server
	     genuinely does not know it — see the header. Found by walking the rows we
	     were sent, which is a hundred compares once per redraw. ]]
	local rank: number? = nil
	if typeof(page.rows) == "table" then
		for _, entry in page.rows do
			if entry.userId == player.UserId then
				rank = entry.rank
				break
			end
		end
	end

	selfRank.Text = if rank then "#" .. tostring(rank) else "UNRANKED"
	selfRank.TextColor3 = if rank then COLOR.AccentBright else COLOR.TextDim
	selfValue.Text = commas(tonumber(me.value) or 0) .. board.unit
end

function refresh()
	if not state.open then
		return
	end

	local board = currentBoard()
	blurbLabel.Text = board.blurb

	paintTabs()

	local page = state.pages[board.id]
	local rows = if typeof(page) == "table" and typeof(page.rows) == "table" then page.rows else {}

	--[[ Rows are built on demand and never destroyed. A board with twelve people
	     on it costs twelve rows; a full page costs a hundred, and only once,
	     because the next redraw finds them already there.

	     Built lazily rather than at init for a reason worth stating: every
	     controller's init() runs at boot, and a hundred rows of four labels each
	     is five hundred instances created before the menu has drawn, for a panel
	     most players will not open this session. ]]
	local shown = math.min(#rows, LeaderboardConfig.Rows)
	for index = 1, shown do
		if not rowFrames[index] then
			buildRow(index)
		end
		drawRow(index, rows[index])
	end
	for index = shown + 1, #rowFrames do
		rowFrames[index].row.Visible = false
	end

	if not page then
		local asked = state.askedAt[board.id] or 0
		statusLabel.Text = if asked > 0 and os.clock() - asked > ANSWER_TIMEOUT
			then "NO ANSWER — TRY AGAIN IN A MOMENT"
			else "LOADING…"
		statusLabel.TextColor3 = COLOR.TextDim
	elseif not page.ok then
		--[[ The server's own word for what went wrong, not a guess. OFFLINE means
		     this session has no DataStore access at all, which in Studio is
		     normal and in production is not. ]]
		statusLabel.Text = if page.reason == "OFFLINE"
			then "GLOBAL RANKS ARE OFF IN THIS SESSION"
			else "THE BOARDS ARE UNAVAILABLE RIGHT NOW"
		statusLabel.TextColor3 = COLOR.Warning
	elseif #rows == 0 then
		statusLabel.Text = "NOBODY HAS MADE THIS BOARD YET. GO FIRST."
		statusLabel.TextColor3 = COLOR.TextDim
	else
		statusLabel.Text = string.format(
			"TOP %d  ·  ALL SERVERS  ·  UP TO %d MINUTES OLD",
			#rows,
			math.max(math.floor(LeaderboardConfig.CacheSeconds / 60), 1)
		)
		statusLabel.TextColor3 = COLOR.TextDim
	end

	refreshSelf(page)
end

local function onPage(payload: any)
	if typeof(payload) ~= "table" then
		return
	end
	local board = LeaderboardConfig.get(payload.board)
	if not board then
		return
	end
	state.pages[board.id] = {
		rows = if typeof(payload.rows) == "table" then payload.rows else {},
		ok = payload.ok == true,
		reason = tostring(payload.reason or ""),
		me = payload.me,
	}
	--[[ Every board is stored, not only the one on screen. Pages arrive
	     unsolicited — the server answers a fetch to everybody waiting on it — so
	     a board this client never asked for may land, and keeping it is free. ]]
	if state.open and board.id == state.board then
		refresh()
	end
end

local function selectBoard(id: string)
	if state.board == id then
		return
	end
	state.board = id
	UiSound.play(AudioConfig.UI.MenuConfirm)
	refresh()
	ask(id)
end

-- ── construction ────────────────────────────────────────────────────────────

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
	panel.Size = UDim2.new(0, width, PANEL.HeightScale, 0)
end

local function buildTabs(top: number): number
	local count = #LeaderboardConfig.Boards
	local gap = LAYOUT.ElementGap

	--[[ A holder inset by the panel padding, with the tabs laid out inside it,
	     rather than each tab positioned by arithmetic. The arithmetic version is
	     where a row of buttons picks up a half-pixel drift per tab and the last
	     one hangs off the edge on a phone. ]]
	local holder = Widgets.frame(panel, "Tabs", COLOR.Panel, 1)
	holder.Position = UDim2.fromOffset(LAYOUT.PanelPadding, top)
	holder.Size = UDim2.new(1, -LAYOUT.PanelPadding * 2, 0, TAB_HEIGHT)
	local row = Widgets.list(holder, gap)
	row.FillDirection = Enum.FillDirection.Horizontal

	for index, board in LeaderboardConfig.Boards do
		local button = Widgets.button(holder, "Tab" .. board.id)
		button.LayoutOrder = index
		-- Width by scale minus the share of the gaps it owes, so the row fills
		-- exactly at any panel width. Same shape as the streak pips next door.
		button.Size = UDim2.new(1 / count, -gap * (count - 1) / count, 1, 0)
		button.BackgroundColor3 = COLOR.PanelRaised
		button.BackgroundTransparency = 1

		local label = Widgets.label(button, "Label", FONT.Heading, TEXT.Body, COLOR.TextDim)
		label.Size = UDim2.fromScale(1, 1)
		label.TextXAlignment = Enum.TextXAlignment.Center
		label.Text = board.displayName

		local id = board.id
		trove:connect(button.Activated, function()
			selectBoard(id)
		end)
		trove:connect(button.MouseEnter, function()
			label.TextColor3 = COLOR.AccentBright
		end)
		trove:connect(button.MouseLeave, paintTabs)

		table.insert(tabButtons, { id = board.id, button = button, label = label })
	end

	paintTabs()
	return top + TAB_HEIGHT + LAYOUT.ElementGap
end

local function buildSelfRow()
	local card = Widgets.frame(panel, "You", COLOR.PanelRaised, PANEL.ActionFill)
	card.AnchorPoint = Vector2.new(0, 1)
	card.Position = UDim2.new(0, LAYOUT.PanelPadding, 1, -LAYOUT.PanelPadding)
	card.Size = UDim2.new(1, -LAYOUT.PanelPadding * 2, 0, SELF_HEIGHT)
	Widgets.stroke(card, COLOR.Accent)

	selfRank = Widgets.label(card, "Rank", FONT.Numeric, TEXT.Body, COLOR.AccentBright)
	selfRank.Position = UDim2.fromOffset(LAYOUT.PanelPadding, 0)
	selfRank.Size = UDim2.new(RANK_WIDTH + 0.06, 0, 1, 0)

	selfTag = Widgets.label(card, "Tag", FONT.Heading, TEXT.Tiny, COLOR.Accent)
	selfTag.Position = UDim2.new(RANK_WIDTH + 0.06, LAYOUT.PanelPadding, 0, 0)
	selfTag.Size = UDim2.new(TAG_WIDTH, 0, 1, 0)
	selfTag.TextTruncate = Enum.TextTruncate.AtEnd

	selfName = Widgets.label(card, "Name", FONT.Heading, TEXT.Body, COLOR.TextPrimary)
	selfName.Position = UDim2.new(RANK_WIDTH + TAG_WIDTH + 0.06, LAYOUT.PanelPadding, 0, 0)
	selfName.Size = UDim2.new(1 - RANK_WIDTH - TAG_WIDTH - VALUE_WIDTH - 0.06, 0, 1, 0)
	selfName.TextTruncate = Enum.TextTruncate.AtEnd

	selfValue = Widgets.label(card, "Value", FONT.Numeric, TEXT.Body, COLOR.AccentBright)
	selfValue.AnchorPoint = Vector2.new(1, 0)
	selfValue.Position = UDim2.new(1, -LAYOUT.PanelPadding, 0, 0)
	selfValue.Size = UDim2.new(VALUE_WIDTH, 0, 1, 0)
	selfValue.TextXAlignment = Enum.TextXAlignment.Right
end

local function build()
	gui = Instance.new("ScreenGui")
	gui.Name = "FL_Leaderboard"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = UITheme.DisplayOrder.Settings
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Enabled = false
	gui.Parent = player:WaitForChild("PlayerGui")
	trove:add(gui)

	local layer = ScaleLayer.new(gui, "Scaled")
	local chrome = Widgets.panel(layer, trove, "RANKS", function()
		LeaderboardController:close()
	end)
	panel = chrome.frame
	closeButton = chrome.close

	local top = HEADER_HEIGHT + LAYOUT.PanelPadding
	top = buildTabs(top)

	blurbLabel = Widgets.label(panel, "Blurb", FONT.Body, TEXT.Small, COLOR.TextSecondary)
	blurbLabel.Position = UDim2.fromOffset(LAYOUT.PanelPadding, top)
	blurbLabel.Size = UDim2.new(1, -LAYOUT.PanelPadding * 2, 0, BLURB_HEIGHT)
	top += BLURB_HEIGHT + 2

	statusLabel = Widgets.label(panel, "Status", FONT.Body, TEXT.Tiny, COLOR.TextDim)
	statusLabel.Position = UDim2.fromOffset(LAYOUT.PanelPadding, top)
	statusLabel.Size = UDim2.new(1, -LAYOUT.PanelPadding * 2, 0, BLURB_HEIGHT)
	top += BLURB_HEIGHT + LAYOUT.ElementGap

	listFrame = Widgets.scroller(panel, "Rows")
	listFrame.Position = UDim2.fromOffset(LAYOUT.PanelPadding, top)
	listFrame.Size = UDim2.new(1, -LAYOUT.PanelPadding * 2, 1, -(top + SELF_HEIGHT + LAYOUT.PanelPadding * 2))
	listFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
	Widgets.list(listFrame, 2)

	buildSelfRow()
	refreshPanelSize()
end

-- ── surface ─────────────────────────────────────────────────────────────────

function LeaderboardController:isOpen(): boolean
	return state.open
end

function LeaderboardController:open()
	if state.open then
		return
	end
	state.open = true
	gui.Enabled = true
	refreshPanelSize()
	refresh()
	--[[ Asked on every open rather than only the first. The cache lives on the
	     SERVER, so a request that arrives inside the window costs one remote and
	     no web call — and a player who just finished a round opening this panel
	     is exactly who most wants it re-read. ]]
	ask(state.board)
	setSuppressed(not menuIsOpen())
	FreeCursor.take(restore)
	GamepadFocus.capture(closeButton)
	UiSound.play(AudioConfig.UI.MenuConfirm)
end

function LeaderboardController:close()
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

function LeaderboardController:toggle()
	if state.open then
		self:close()
	else
		self:open()
	end
end

function LeaderboardController:init()
	build()
end

function LeaderboardController:start()
	trove:connect(Remotes.Event.LeaderboardPage.OnClientEvent, onPage)

	--[[ B backs out, which is what B does on every console screen there has ever
	     been — and it is checked BEFORE the processed guard, because the panel is
	     focused while it is up and its own presses arrive marked processed. This
	     had only the Escape half, which is a screen a controller can open and
	     cannot leave. Copied deliberately from CareerController rather than
	     invented, so the two behave identically. ]]
	trove:connect(UserInputService.InputBegan, function(input: InputObject, processed: boolean)
		if not state.open then
			return
		end
		if input.KeyCode == Enum.KeyCode.ButtonB then
			LeaderboardController:close()
			return
		end
		if not processed and input.KeyCode == Enum.KeyCode.Escape then
			LeaderboardController:close()
		end
	end)

	--[[ A tag appears the moment its owner joins, and goes when they leave. Both
	     matter on this screen: a board is mostly strangers, and the two or three
	     rows that light up are the reason to look at it. ]]
	trove:connect(Players.PlayerAdded, function()
		refresh()
	end)
	trove:connect(Players.PlayerRemoving, function()
		refresh()
	end)
end

function LeaderboardController:destroy()
	trove:destroy()
	table.clear(rowFrames)
	table.clear(tabButtons)
end

Registry.register("LeaderboardController", LeaderboardController)

return LeaderboardController
