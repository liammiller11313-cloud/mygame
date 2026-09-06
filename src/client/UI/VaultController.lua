--!nonstrict
--[[
	VaultController — the number pad, and the documents you read to fill it in.

	Two screens on one panel, because they are two halves of one activity: you
	read a security report, you walk to the keypad, you type what you worked
	out. Sharing a panel means they share the suppression, the cursor and the
	touch sizing, and there is exactly one way in and one way out of both.

	── IT KNOWS NOTHING ────────────────────────────────────────────────────────
	This file cannot tell you whether a code is right. It has never seen the
	answer, the generated values or the order — none of those exist outside
	PuzzleService. What it has is four digits the player typed and a remote to
	send them up, and every word it displays afterwards came back down.

	That is not a precaution bolted on, it is the reason the keypad can be a
	client screen at all. Opening it grants nothing, typing in it grants nothing,
	and a client that deleted this file entirely would be exactly as far from the
	loot as one that kept it.

	── THE DOCUMENT READER IS A CONVENIENCE, NOT THE CLUE ──────────────────────
	The clue is printed on the prop, in the world, where a player finds it by
	looking at things. This draws the same string bigger, because a security
	badge is four inches across and a phone is not a magnifying glass. It reads
	the text off an attribute the server wrote — the same string it painted onto
	the surface — so the two can never disagree.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attributes = require(Shared.Net.Attributes)
local Enums = require(Shared.Enums)
local EconomyConfig = require(Shared.Config.EconomyConfig)
local AudioConfig = require(Shared.Config.AudioConfig)
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

local GA = Attributes.Game
local PUZZLE = Attributes.Puzzle

local player = Players.LocalPlayer

local PANEL_WIDTH = 460
local PANEL_HEIGHT = 520
--[[ The document panel is wider and taller: it is holding a page of typed
     report, and reflowing that into a keypad's footprint is how a clue becomes
     unreadable on the platform least able to spare the pixels. ]]
local DOC_WIDTH = 560
local DOC_HEIGHT = 560

--[[ How long the vault line stays up. Longer than a callout because it is the
     payoff for ten minutes of reading, and shorter than an announcement because
     the horde has not stopped for it. ]]
local VAULT_LINE_SECONDS = 5

--[[ Shorter than the vault line: a clue landing is news, not the payoff, and
     four of them over ten minutes should not each hold the subtitle bar. ]]
local CLUE_LINE_SECONDS = 3

--[[
	The clue counter. Its own small card rather than a line in the objective,
	because the objective is rewritten on every wave edge and a side objective
	that got overwritten by "WAVE 4" would be a counter nobody could rely on.

	── IT LIVES DOWN THE LEFT NOW ──────────────────────────────────────────────
	It was top-centre, at the literal number 96, which is INSIDE the wave block —
	the round clock and its pips are 22 + 84 tall before a modifier — so it drew
	straight through the round's own lines and through the objective under them.
	Putting it in the centre stack fixed the collision and left four cards queuing
	down the middle of the screen, which is a lot of furniture over the one part
	of the view a player is actually shooting into.

	So it moved to the left column, under the orders card, where nothing else
	draws until the survivor panels at the bottom. The centre is back to the round
	block, the objective and whatever is transient. OrdersController is ASKED
	where it ends rather than the number being copied — see its getBottom.
]]
--[[ The same width as the orders card above it. A column of two cards that do
     not agree on where their right edge is reads as two things that happen to be
     near each other rather than as one column. ]]
local TRACKER_WIDTH = 208
local TRACKER_HEIGHT = 52
local TRACKER_FLASH = 1.6
local TRACKER_IDLE = 0.45
local TRACKER_LIVE = 0.0

--[[ Under the orders card, at the same left margin.

     OrdersController owns every conditional in that Y — Roblox's chrome inset,
     the scale factor it is divided by, and whether the profile has landed and
     the card is on screen at all — so it is asked. Falling back to the plain
     screen margin means a build with the orders card removed still puts this
     somewhere sane rather than at zero, under the platform's own buttons. ]]
local function trackerPosition(): UDim2
	local top = LAYOUT.ScreenMargin
	local orders = Registry.find("OrdersController")
	if orders and typeof(orders.getBottom) == "function" then
		local ok, bottom = pcall(orders.getBottom, orders)
		if ok and typeof(bottom) == "number" then
			top = bottom
		end
	end
	return UDim2.fromOffset(LAYOUT.ScreenMargin, top + LAYOUT.ElementGap)
end

local KEY_GAP = 8
local READOUT_HEIGHT = 64

--[[ The pad, row by row, exactly as it reads on a real one. "C" clears and "E"
     enters; both are drawn with words rather than symbols because a glyph on a
     keypad is a thing players guess at. ]]
local KEYS = {
	{ "1", "2", "3" },
	{ "4", "5", "6" },
	{ "7", "8", "9" },
	{ "CLR", "0", "ENTER" },
}

local VaultController = {}

local trove = Trove.new()

local gui: ScreenGui
local panel: Frame
local title: TextLabel
local closeButton: TextButton
local keypadBody: Frame
local docBody: Frame
local readout: TextLabel
local statusLabel: TextLabel
local docText: TextLabel
local keyButtons: { [string]: TextButton } = {}

local trackerGui: ScreenGui
local trackerCard: CanvasGroup
local trackerCount: TextLabel
local trackerLine: TextLabel

--[[ The panel's OWN restore slot. FreeCursor's contract: these screens nest, so
     a shared one would have an inner panel hand back an outer panel's camera. ]]
local restore = {}

local state = {
	open = false,
	mode = "",
	--[[ What the player has typed, as a string of digits. A string rather than a
	     number so a leading zero survives — 0832 is a perfectly good code and a
	     number would silently make it 832. ]]
	input = "",
	digits = 4,
	--[[ Absolute server-time stamp the keypad will take another answer at, from
	     the server. Never a countdown: the client subtracts its own clock, so it
	     cannot drift and cannot arrive stale. ]]
	retryAt = 0,
	suppressed = false,
	--[[ Absolute clock the counter stops being bright at, or 0. It sits faded
	     the rest of the time: a permanent panel at the top of the screen for a
	     side objective is a panel in the way of the horde. ]]
	flashUntil = 0,
}

-- ── helpers ─────────────────────────────────────────────────────────────────

--[[ Asked of InputController rather than of the device, because the scheme is
     what the player is DRIVING with — a phone in a dock with a pad attached is
     not a touch player, and the pad is what decides how big a button has to
     be. Same check every other panel makes. ]]
local function isTouch(): boolean
	local input = Registry.find("InputController")
	if not input or typeof(input.isTouchScheme) ~= "function" then
		return false
	end
	local ok, touch = pcall(input.isTouchScheme, input)
	return ok and touch == true
end

--[[ Whether the main menu is up. Same three lines every panel in this folder
     carries, and for the same reason: a panel opened OVER the menu must not
     hand the round back when it closes. ]]
local function menuIsOpen(): boolean
	local menu = Registry.find("MainMenuController")
	if not menu or typeof(menu.isOpen) ~= "function" then
		return false
	end
	local ok, open = pcall(menu.isOpen, menu)
	return ok and open == true
end

local function callController(name: string, method: string, ...: any)
	local controller = Registry.find(name)
	if controller and typeof(controller[method]) == "function" then
		pcall(controller[method], controller, ...)
	end
end

--[[ Everything the world takes back while a panel is up. The same five calls
     every other modal in this game makes, in the same order — and setMuted(nil)
     is not optional on the way out, because setMuted REPLACES the muted set and
     a panel that closed without clearing it would leave the trigger dead. ]]
local function setSuppressed(value: boolean)
	if state.suppressed == value then
		return
	end
	state.suppressed = value
	callController("InputController", "setMuted", nil)
	callController("InputController", "setEnabled", not value)
	callController("CrosshairController", "setVisible", not value)
	callController("PromptController", "setEnabled", not value)
	callController("TouchController", "setVisible", not value)
end

local function serverNow(): number
	return Workspace:GetServerTimeNow()
end

-- ── drawing ─────────────────────────────────────────────────────────────────

--[[ The four boxes. Drawn as characters with a space between rather than as
     four framed cells, because a keypad readout is a line of digits and four
     boxes is a form. ]]
local function refreshReadout()
	local shown = {}
	for index = 1, state.digits do
		table.insert(
			shown,
			string.sub(state.input, index, index) ~= "" and string.sub(state.input, index, index)
				or "\226\128\162"
		)
	end
	readout.Text = table.concat(shown, "   ")
end

local function setStatus(text: string, color: Color3)
	statusLabel.Text = text
	statusLabel.TextColor3 = color
end

--[[ Refuses input while the server says to wait, and says how long. The pad is
     not disabled — a player who keeps typing during a lockout is told the same
     thing again, which is better than a dead panel that looks broken. ]]
local function waitingFor(): number
	return math.max(state.retryAt - serverNow(), 0)
end

local function press(key: string)
	if state.mode ~= "keypad" then
		return
	end

	if key == "CLR" then
		state.input = ""
		refreshReadout()
		setStatus("ENTER SECURITY CODE", COLOR.TextSecondary)
		UiSound.play(AudioConfig.UI.MenuBack)
		return
	end

	if key == "ENTER" then
		local remaining = waitingFor()
		if remaining > 0 then
			setStatus(string.format("WAIT %ds", math.ceil(remaining)), COLOR.Danger)
			UiSound.play(AudioConfig.UI.MenuBack)
			return
		end
		if #state.input ~= state.digits then
			setStatus(string.format("%d DIGITS", state.digits), COLOR.Danger)
			UiSound.play(AudioConfig.UI.MenuBack)
			return
		end
		--[[ Sent and then forgotten. The panel does not decide anything about
		     what it just sent, and does not clear the readout until an answer
		     comes back — a code that vanished the instant you pressed ENTER is a
		     code you cannot check you typed correctly. ]]
		Remotes.Event.SubmitVaultCode:FireServer({ code = state.input })
		setStatus("CHECKING\226\128\166", COLOR.TextDim)
		UiSound.play(AudioConfig.UI.MenuConfirm)
		return
	end

	if #state.input >= state.digits then
		return
	end
	state.input ..= key
	refreshReadout()
	UiSound.play(AudioConfig.UI.MenuHover)
end

--[[
	Redraws the counter from the two attributes the server publishes.

	Hidden entirely when no puzzle is armed, which is two maps out of three and
	the whole lobby — a 0/4 counter on a map with no clues in it would be an
	objective the player can never satisfy.
]]
local function refreshTracker()
	local total = tonumber(Attributes.get(Workspace, GA.CluesTotal, 0)) or 0
	local found = tonumber(Attributes.get(Workspace, GA.CluesFound, 0)) or 0
	local solved = Attributes.get(Workspace, GA.VaultSolved, false) == true

	--[[ The counter's job ends when the door opens. What happens after that is a
	     horde, and a card counting clues through it would be the least useful
	     thing on the screen. ]]
	local wanted = total > 0 and not solved
	trackerGui.Enabled = wanted
	if not wanted then
		return
	end
	--[[ Re-placed on every refresh rather than once at build. The orders card
	     above it appears when the profile lands, a second or two into a round,
	     and a counter that was placed before that sits in the gap where the card
	     was going to be. ]]
	trackerCard.Position = trackerPosition()

	trackerCount.Text = string.format("CLUES  %d/%d", found, total)
	if found >= total then
		trackerCount.TextColor3 = COLOR.HealthGood
		trackerLine.Text = "HEAD TO THE CODE DOOR AT KFC"
		trackerLine.TextColor3 = COLOR.AccentBright
	else
		trackerCount.TextColor3 = COLOR.AccentBright
		trackerLine.Text = "SEARCH THE BUILDING"
		trackerLine.TextColor3 = COLOR.TextSecondary
	end
end

--[[ Brightens the card for a moment, on a change the player caused. Fired for a
     collection and for a refusal alike: both are answers to something they just
     did, and both are worth looking up for. ]]
local function flashTracker()
	state.flashUntil = os.clock() + TRACKER_FLASH
	TweenService:Create(trackerCard, TweenInfo.new(0.12), { GroupTransparency = TRACKER_LIVE }):Play()
end

--[[ The only per-frame work in this file, and it does almost nothing on almost
     every frame: it ends a flash, and it keeps the card under the one above it.
     A tween cannot schedule its own reversal without a second tween that would
     fight the first when two clues are picked up a second apart. ]]
local function stepTracker()
	--[[
		Follow the orders card, by comparing rather than by listening.

		Its Y moves for three different reasons — the profile landing and the card
		appearing a second into the round, Roblox's chrome inset changing, and the
		viewport resizing under a ScaleLayer — and only the last of those has a
		signal worth connecting to. Recomputing costs one function call and one
		compare on a frame where nothing moved, and it is correct for every cause
		including the ones nobody has thought of yet.

		Only while the card is up: a hidden counter has nothing to place.
	]]
	if trackerGui.Enabled then
		local wanted = trackerPosition()
		if trackerCard.Position ~= wanted then
			trackerCard.Position = wanted
		end
	end

	if state.flashUntil > 0 and os.clock() >= state.flashUntil then
		state.flashUntil = 0
		TweenService:Create(trackerCard, TweenInfo.new(0.5), { GroupTransparency = TRACKER_IDLE }):Play()
		--[[ And back to what the counter normally says. A refusal is written
		     straight over that line, and without this "COLLECT THE FIRST CLUE
		     FIRST" would still be sitting there ten minutes later — long after
		     the player collected it — because nothing else was going to rewrite
		     the line until somebody found something. ]]
		refreshTracker()
	end
end

-- ── build ───────────────────────────────────────────────────────────────────

local function buildKeypad(parent: Instance)
	keypadBody = Widgets.frame(parent, "Keypad", COLOR.Panel, 1)
	keypadBody.Position = UDim2.fromOffset(LAYOUT.PanelPadding, PANEL.HeaderHeight + LAYOUT.PanelPadding)
	keypadBody.Size =
		UDim2.new(1, -LAYOUT.PanelPadding * 2, 1, -(PANEL.HeaderHeight + LAYOUT.PanelPadding * 2))
	keypadBody.Visible = false

	readout = Widgets.label(keypadBody, "Readout", FONT.Numeric, TEXT.Display, COLOR.AccentBright)
	readout.Size = UDim2.new(1, 0, 0, READOUT_HEIGHT)
	readout.TextXAlignment = Enum.TextXAlignment.Center

	local readoutRule = Widgets.frame(keypadBody, "ReadoutRule", COLOR.Border, 0)
	readoutRule.Position = UDim2.fromOffset(0, READOUT_HEIGHT)
	readoutRule.Size = UDim2.new(1, 0, 0, LAYOUT.BorderThickness)

	statusLabel = Widgets.label(keypadBody, "Status", FONT.Heading, TEXT.Small, COLOR.TextSecondary)
	statusLabel.Position = UDim2.fromOffset(0, READOUT_HEIGHT + LAYOUT.ElementGap)
	statusLabel.Size = UDim2.new(1, 0, 0, TEXT.Small + 6)
	statusLabel.TextXAlignment = Enum.TextXAlignment.Center

	local gridTop = READOUT_HEIGHT + LAYOUT.ElementGap + TEXT.Small + 6 + LAYOUT.ElementGap
	local grid = Widgets.frame(keypadBody, "Grid", COLOR.Panel, 1)
	grid.Position = UDim2.fromOffset(0, gridTop)
	grid.Size = UDim2.new(1, 0, 1, -gridTop)

	local columns = #KEYS[1]
	for row, keys in KEYS do
		for column, key in keys do
			local button = Widgets.button(grid, "Key" .. key)
			button.Size = UDim2.new(1 / columns, -KEY_GAP, 1 / #KEYS, -KEY_GAP)
			button.Position = UDim2.new((column - 1) / columns, 0, (row - 1) / #KEYS, 0)
			button.BackgroundColor3 = COLOR.PanelRaised
			button.BackgroundTransparency = 0.1
			local stroke = Widgets.stroke(button, COLOR.BorderBright)

			local label = Widgets.label(button, "Label", FONT.Numeric, TEXT.Heading, COLOR.TextPrimary)
			label.Size = UDim2.fromScale(1, 1)
			label.TextXAlignment = Enum.TextXAlignment.Center
			label.Text = key
			--[[ ENTER and CLR are words, not numerals, so they get the body face
			     at a smaller size — a four-letter word in the numeric display face
			     overflows a square button on a phone. ]]
			if key == "ENTER" or key == "CLR" then
				label.Font = FONT.Heading
				label.TextSize = TEXT.Body
				label.TextColor3 = if key == "ENTER" then COLOR.Accent else COLOR.TextSecondary
			end

			Widgets.outlineHover(trove, button, stroke)
			trove:connect(button.Activated, function()
				press(key)
			end)
			keyButtons[key] = button
		end
	end
end

local function buildDocument(parent: Instance)
	docBody = Widgets.frame(parent, "Document", COLOR.Background, 0.15)
	docBody.Position = UDim2.fromOffset(LAYOUT.PanelPadding, PANEL.HeaderHeight + LAYOUT.PanelPadding)
	docBody.Size = UDim2.new(1, -LAYOUT.PanelPadding * 2, 1, -(PANEL.HeaderHeight + LAYOUT.PanelPadding * 2))
	docBody.Visible = false
	Widgets.stroke(docBody, COLOR.Border)

	local scroller = Widgets.scroller(docBody, "Page")
	scroller.Position = UDim2.fromOffset(LAYOUT.PanelPadding, LAYOUT.PanelPadding)
	scroller.Size = UDim2.new(1, -LAYOUT.PanelPadding * 2, 1, -LAYOUT.PanelPadding * 2)
	scroller.AutomaticCanvasSize = Enum.AutomaticSize.Y

	--[[ The typewriter face and near-black ink on off-white, because this is a
	     photocopy of a form and not a screen. It is the one place in the
	     interface that deliberately does not look like the rest of it. ]]
	docText = Widgets.label(scroller, "Text", FONT.Body, TEXT.Body, COLOR.TextPrimary)
	docText.Font = Enum.Font.Code
	docText.Size = UDim2.new(1, -PANEL.ScrollBarWidth, 0, 0)
	docText.AutomaticSize = Enum.AutomaticSize.Y
	docText.TextXAlignment = Enum.TextXAlignment.Left
	docText.TextYAlignment = Enum.TextYAlignment.Top
	docText.TextWrapped = true
end

--[[
	The clue counter.

	CLUES 2/4 while there is hunting left, and one line telling the team what to
	do about it — which at 4/4 is the only instruction that matters: the code
	door. A CanvasGroup so the whole card fades together; a Frame's transparency
	does not touch its children, so fading one would leave the numbers at full
	strength over a faded box.
]]
local function buildTracker()
	trackerGui = Instance.new("ScreenGui")
	trackerGui.Name = "FL_ClueTracker"
	trackerGui.ResetOnSpawn = false
	trackerGui.IgnoreGuiInset = true
	trackerGui.DisplayOrder = UITheme.DisplayOrder.Hud
	trackerGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	trackerGui.Enabled = false
	trackerGui.Parent = player:WaitForChild("PlayerGui")
	trove:add(trackerGui)

	local layer = ScaleLayer.new(trackerGui, "Scaled")

	trackerCard = Instance.new("CanvasGroup")
	trackerCard.Name = "Card"
	trackerCard.AnchorPoint = Vector2.new(0, 0)
	trackerCard.Position = trackerPosition()
	trackerCard.Size = UDim2.fromOffset(TRACKER_WIDTH, TRACKER_HEIGHT)
	trackerCard.BackgroundColor3 = COLOR.Panel
	trackerCard.BackgroundTransparency = 0.3
	trackerCard.BorderSizePixel = 0
	trackerCard.GroupTransparency = TRACKER_IDLE
	trackerCard.Parent = layer
	Widgets.stroke(trackerCard, COLOR.Border)

	--[[ Left-aligned, like the orders rows above it. Centred text was right when
	     this card was centred on the screen and is wrong in a column: two cards
	     with their text starting in different places do not read as a column. ]]
	trackerCount = Widgets.label(trackerCard, "Count", FONT.Heading, TEXT.Body, COLOR.AccentBright)
	trackerCount.Position = UDim2.fromOffset(LAYOUT.PanelPadding, 6)
	trackerCount.Size = UDim2.new(1, -LAYOUT.PanelPadding * 2, 0, TEXT.Body + 2)
	trackerCount.TextXAlignment = Enum.TextXAlignment.Left

	trackerLine = Widgets.label(trackerCard, "Line", FONT.Body, TEXT.Tiny, COLOR.TextSecondary)
	trackerLine.Position = UDim2.fromOffset(LAYOUT.PanelPadding, 6 + TEXT.Body + 4)
	trackerLine.Size = UDim2.new(1, -LAYOUT.PanelPadding * 2, 0, TEXT.Tiny + 2)
	trackerLine.TextXAlignment = Enum.TextXAlignment.Left
	trackerLine.TextTruncate = Enum.TextTruncate.AtEnd
end

local function build()
	gui = Instance.new("ScreenGui")
	gui.Name = "FL_Vault"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = UITheme.DisplayOrder.Settings
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Enabled = false
	gui.Parent = player:WaitForChild("PlayerGui")
	trove:add(gui)

	local layer = ScaleLayer.new(gui, "Scaled")
	local chrome = Widgets.panel(layer, trove, "SECURITY VAULT", function()
		VaultController:close()
	end)
	panel = chrome.frame
	title = chrome.title
	closeButton = chrome.close

	buildKeypad(panel)
	buildDocument(panel)
	buildTracker()
end

-- ── public ──────────────────────────────────────────────────────────────────

function VaultController:isOpen(): boolean
	return state.open
end

--[[ Shared by both entry points, because opening a screen is the same job
     whichever screen it is: size it, suppress the world, take the cursor, put a
     gamepad's focus somewhere it can act. ]]
local function show(mode: string, width: number, height: number, heading: string)
	state.mode = mode
	state.open = true
	title.Text = heading
	panel.Size = UDim2.fromOffset(width, height)
	keypadBody.Visible = mode == "keypad"
	docBody.Visible = mode == "document"
	gui.Enabled = true

	--[[ Unless the menu already has it, like every other panel in this folder.
	     Suppressing unconditionally means the close below hands the round back
	     even when the main menu is still up over it. ]]
	setSuppressed(not menuIsOpen())
	FreeCursor.take(restore)
	--[[ A pad lands on a key rather than nowhere. Without this the keypad was
	     answerable only with a mouse, which on a console is the same as not being
	     answerable at all. ]]
	GamepadFocus.capture(if mode == "keypad" then keyButtons["5"] or closeButton else closeButton)
	UiSound.play(AudioConfig.UI.MenuConfirm)
end

--[[
	The keypad, from a player pressing the interact key on the vault door.

	Opening it is not an achievement and is not checked: the door is the thing
	that is locked, and it stays locked until PuzzleService says otherwise.
]]
function VaultController:openKeypad(keypad: Instance?)
	if state.open then
		return
	end
	if Attributes.get(Workspace, GA.VaultSolved, false) == true then
		return
	end
	local digits = tonumber(keypad and keypad:GetAttribute(PUZZLE.Digits)) or 4
	state.digits = math.clamp(math.floor(digits), 1, 8)
	state.input = ""
	refreshReadout()
	setStatus("ENTER SECURITY CODE", COLOR.TextSecondary)

	local height = if isTouch() then PANEL_HEIGHT + PANEL.RowHeightTouch else PANEL_HEIGHT
	show("keypad", PANEL_WIDTH, height, "SECURITY VAULT")
end

--[[
	A document, in a size a person can read.

	The text comes off the prop's own attribute, written by the server when it
	painted the surface. Reading it from the SurfaceGui's TextLabel instead would
	mean digging through a designer's instance tree by name, which breaks the
	first time somebody renames a part.
]]
function VaultController:openDocument(clue: Instance?)
	if state.open or not clue then
		return
	end
	local text = clue:GetAttribute(PUZZLE.ClueText)
	if typeof(text) ~= "string" or text == "" then
		return
	end
	docText.Text = text
	show("document", DOC_WIDTH, DOC_HEIGHT, tostring(clue:GetAttribute(PUZZLE.CluePrompt) or "DOCUMENT"))
end

function VaultController:close()
	if not state.open then
		return
	end
	state.open = false
	state.mode = ""
	gui.Enabled = false
	GamepadFocus.release(nil)
	FreeCursor.giveBack(restore)
	setSuppressed(false)
	--[[ And the menu takes its suppression back, which this was the one panel
	     close in the folder that never asked for. Without it a keypad closed
	     over the main menu handed input to a round that is not running. ]]
	if menuIsOpen() then
		callController("MainMenuController", "reassertSuppression")
	end
	UiSound.play(AudioConfig.UI.MenuBack)
end

-- ── lifecycle ───────────────────────────────────────────────────────────────

function VaultController:init()
	build()
end

function VaultController:start()
	--[[
		The round ending closes this, and nothing used to.

		Every other screen is torn down by the round leaving InProgress. This one
		listened only to its own four puzzle remotes, so a player standing at the
		keypad when the last survivor went down kept a full-screen panel over the
		results poster — holding the cursor and the input lock, and then handing
		both back to a round that no longer exists when they finally closed it.
	]]
	trove:connect(Workspace:GetAttributeChangedSignal(GA.RoundState), function()
		if state.open and Attributes.get(Workspace, GA.RoundState, "") ~= Enums.RoundState.InProgress then
			self:close()
		end
	end)

	--[[ The server's answer, and the only thing that decides what this screen
	     says after ENTER. A refusal keeps the panel open with the code still in
	     the readout so the player can see what they typed; success closes it,
	     because the door is open and there is nothing left to type. ]]
	trove:connect(Remotes.Event.VaultCodeResult.OnClientEvent, function(payload: any)
		if typeof(payload) ~= "table" or not state.open or state.mode ~= "keypad" then
			return
		end
		state.retryAt = tonumber(payload.retryAt) or 0
		if payload.ok == true then
			setStatus("ACCESS GRANTED", COLOR.HealthGood)
			UiSound.play(AudioConfig.UI.MenuConfirm)
			task.delay(1.1, function()
				if state.open and state.mode == "keypad" then
					VaultController:close()
				end
			end)
			return
		end
		setStatus(tostring(payload.reason or "ACCESS DENIED"), COLOR.Danger)
		state.input = ""
		refreshReadout()
		UiSound.play(AudioConfig.UI.MenuBack)
	end)

	--[[
		The lock letting go, announced to everybody.

		Not just to whoever typed it. One player found the badge, another found
		the room sign, and a third worked out the order — the door opening is the
		moment all three of them were working towards, and a team that only hears
		about it from the person who happened to be standing at the pad has been
		told the wrong story about what they just did.
	]]
	trove:connect(Remotes.Event.VaultOpened.OnClientEvent, function(payload: any)
		if typeof(payload) ~= "table" then
			return
		end
		local who = payload.player
		local name = if typeof(who) == "Instance" and who:IsA("Player") then who.DisplayName else ""
		callController(
			"SubtitleController",
			"say",
			name,
			"The vault is open. Take what you need.",
			VAULT_LINE_SECONDS
		)
	end)

	--[[
		A clue the player just tried to pick up.

		Three answers, and each one puts something different on screen. Picked
		up: the document opens with its digit now legible, and the counter moves.
		Out of order: the counter says which one they should have found first and
		no page opens — a document full of redactions with no explanation reads as
		a bug. Already had it: the page opens and nothing else happens.
	]]
	trove:connect(Remotes.Event.ClueResult.OnClientEvent, function(payload: any)
		if typeof(payload) ~= "table" then
			return
		end
		refreshTracker()
		flashTracker()

		if payload.ok ~= true then
			--[[ Newlines folded to a dash: the refusal is two lines on the server so
			     a page could show it, and one line here because the counter is one
			     line tall. ]]
			local reason = string.gsub(tostring(payload.reason or "NOT YET"), "\n", " \226\128\148 ")
			trackerLine.Text = reason
			trackerLine.TextColor3 = COLOR.Danger
			UiSound.play(AudioConfig.UI.MenuBack)
			return
		end

		if typeof(payload.text) == "string" and payload.text ~= "" and not state.open then
			docText.Text = payload.text
			show("document", DOC_WIDTH, DOC_HEIGHT, tostring(payload.headline or "DOCUMENT"))
		end
		if payload.repeated ~= true then
			UiSound.play(AudioConfig.UI.MenuConfirm)
		end
	end)

	--[[ Somebody else found one. The counter is the team's, so it moves on every
	     screen — the player three rooms away needs to know the hunt advanced and
	     that the next clue is somewhere they have not been. ]]
	trove:connect(Remotes.Event.ClueFound.OnClientEvent, function(payload: any)
		if typeof(payload) ~= "table" then
			return
		end
		refreshTracker()
		flashTracker()
		local who = payload.player
		if typeof(who) == "Instance" and who:IsA("Player") and who ~= player then
			callController(
				"SubtitleController",
				"say",
				who.DisplayName,
				string.format(
					"%s. %d of %d.",
					tostring(payload.prompt or "Got one"),
					payload.found,
					payload.total
				),
				CLUE_LINE_SECONDS
			)
		end
	end)

	trove:connect(Workspace:GetAttributeChangedSignal(GA.CluesFound), refreshTracker)
	trove:connect(Workspace:GetAttributeChangedSignal(GA.CluesTotal), refreshTracker)
	trove:connect(RunService.Heartbeat, stepTracker)
	refreshTracker()

	--[[ The cash pile, which pays everybody at once — so everybody is told, not
	     just whoever reached it. ]]
	trove:connect(Remotes.Event.StockpileClaimed.OnClientEvent, function(payload: any)
		if typeof(payload) ~= "table" then
			return
		end
		local who = payload.player
		local name = if typeof(who) == "Instance" and who:IsA("Player") then who.DisplayName else ""
		callController(
			"SubtitleController",
			"say",
			name,
			--[[ "each", not "split" — the pile pays everybody the same amount and
			     saying otherwise would have the line contradict the number beside
			     it. ]]
			string.format("Cracked the stockpile. %s each.", EconomyConfig.format(payload.dollars or 0)),
			CLUE_LINE_SECONDS
		)
	end)

	--[[ Somebody else got it. The panel closes rather than sitting on a keypad
	     for a door that is already open — and the closing IS the notification,
	     because a player staring at a number pad is a player who was working on
	     exactly this. ]]
	trove:connect(Workspace:GetAttributeChangedSignal(GA.VaultSolved), function()
		refreshTracker()
		if Workspace:GetAttribute(GA.VaultSolved) == true and state.open and state.mode == "keypad" then
			VaultController:close()
		end
	end)
end

function VaultController:destroy()
	trove:destroy()
	table.clear(keyButtons)
end

Registry.register("VaultController", VaultController)

return VaultController
