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

local Lighting = game:GetService("Lighting")
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
local PA = Attributes.Player
local PUZZLE = Attributes.Puzzle

--[[ States a panel cannot survive — see the PA.State watch in start(). Held
     here rather than in both files because the keypad and the generator panel
     are the same screen in two shapes and this is the same answer. ]]
local SHUT_STATES: { [string]: boolean } = {
	[Enums.SurvivorState.Incapacitated] = true,
	[Enums.SurvivorState.LedgeHanging] = true,
	[Enums.SurvivorState.Pinned] = true,
	[Enums.SurvivorState.Dead] = true,
	[Enums.SurvivorState.Spectating] = true,
}

local player = Players.LocalPlayer

local PANEL_WIDTH = 460
local PANEL_HEIGHT = 520
--[[ The document panel is wider and taller: it is holding a page of typed
     report, and reflowing that into a keypad's footprint is how a clue becomes
     unreadable on the platform least able to spare the pixels. ]]
local DOC_WIDTH = 560
local DOC_HEIGHT = 560

--[[ A page's own margin, wider than a panel's. Type that starts ten pixels from
     the edge of a sheet reads as a text box; type with a real margin around it
     reads as something that was printed. ]]
local DOC_MARGIN = 20

--[[
	The page, and the ink on it.

	Deliberately the one surface in this interface that is not a screen. Every
	other panel in this game is dark chrome with light type on it because every
	other panel IS an interface — a shop, a loadout, a keypad. This one is a
	sheet of paper somebody left behind, and the entire reason a document works
	as a clue is that the player believes that. Ink on paper is most of the
	belief.
]]
local PAPER = Color3.fromRGB(224, 214, 192)
local PAPER_SHADE = Color3.fromRGB(191, 179, 155)
local INK = Color3.fromRGB(32, 28, 24)
local INK_FADED = Color3.fromRGB(104, 93, 78)

--[[
	And the other thing a clue can be, which is a screen.

	One of the Backrooms' four documents is a dead television, and opening a CRT
	message as a sheet of cream paper would undo on this panel exactly the
	distinction the prop makes in the world. A clue that names its own ink is
	saying it is not paperwork; the page follows it.

	Two colours rather than one for the same reason the paper has two: a flat
	rectangle is a UI surface, and a tube is darker at its edges than at its
	centre.
]]
local SCREEN = Color3.fromRGB(17, 21, 19)
local SCREEN_SHADE = Color3.fromRGB(9, 12, 11)

--[[
	How far out of focus the world goes behind an open page.

	Below the main menu's 26 on purpose. The menu is a place you have LEFT the
	round to stand in; this is opened in the middle of one, with a horde
	somewhere behind you, and burying the world entirely turns a moment of
	reading into a moment of blindness. Enough that the eye stops trying to track
	movement out there, not so much that the room stops existing.
]]
--[[
	The face a document is written in, from the name the server sent, defaulting
	to the typewriter.

	Forgiving on purpose, the same way the server's own copy is: a font name is a
	string against a list Roblox owns and occasionally grows, and a build that
	does not have SpecialElite should open the note in the wrong face rather than
	leave the player looking at a blank page.
]]
local function fontFrom(name: any): Enum.Font
	if typeof(name) ~= "string" then
		return Enum.Font.Code
	end
	local font = (Enum.Font :: any)[name]
	return if typeof(font) == "EnumItem" then font else Enum.Font.Code
end

local READER_BLUR = 18
local BLUR_INFO = TweenInfo.new(UITheme.Motion.Normal, UITheme.Motion.Easing, UITheme.Motion.EasingDirection)

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
--[[ Two lines under the count rather than one.

     The refusals this card carries are sentences — "COLLECT THE FIRST CLUE
     FIRST", "Wrong generator, find the first one!" — and at 208 wide none of
     them fit on one row. They used to truncate, which turned the one message
     whose whole job is to name the thing you are missing into a message that
     names most of it. ]]
local TRACKER_HEIGHT = 68
local TRACKER_LINES = 2
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
--[[ The sheet's own tone, kept because it is what actually carries the colour:
     the body is white and this gradient tints it, so switching a page between
     paper and screen is one assignment rather than three. ]]
local docAge: UIGradient

--[[ In Lighting rather than in the ScreenGui, because that is where a
     post-process effect goes. Owned by the trove so a client teardown cannot
     leave the world blurred with nothing on screen to explain it. ]]
local blur: BlurEffect
local blurTween: Tween? = nil
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
	local label = tostring(Attributes.get(Workspace, GA.TrackerLabel, "") or "")

	--[[
		Up while the server says there is something to say.

		This used to hide on VaultSolved, which was right when there was one
		puzzle: the vault opening ends the objective — nothing left to count, and
		the room is the one you are standing at.

		It is wrong for the generator kind, where powering the fifth machine is
		not the end of anything. The team still has to cross the map to the loot
		room, and the card saying POWERED 5/5 / GET TO THE LOOT ROOM beside the
		arrow is the most useful thing on the screen at that moment rather than
		the least.

		So the SERVER decides, by clearing the label when it means "we are done
		here". One rule, and the map that wants each behaviour gets it without
		this file knowing which map it is on.
	]]
	local wanted = total > 0 and label ~= ""
	trackerGui.Enabled = wanted
	if not wanted then
		return
	end
	--[[ Re-placed on every refresh rather than once at build. The orders card
	     above it appears when the profile lands, a second or two into a round,
	     and a counter that was placed before that sits in the gap where the card
	     was going to be. ]]
	trackerCard.Position = trackerPosition()

	--[[
		The noun and the instruction come off the server, the numbers off the
		attributes beside them.

		This card counts whatever the map's side objective counts — clues on
		Clinton, generators on Zombieville — and the numbers are identical in both
		cases. The WORDS are not, and "CLUES 3/5" on a map with no clues in it is
		a counter that lies about what the player is doing. Working out which
		puzzle is armed on the client would mean four clients deriving a fact the
		server already holds; see Attributes.Game.TrackerLabel.

		Clinton's own wording is unchanged. It just arrives from somewhere else.
	]]
	trackerCount.Text = string.format("%s  %d/%d", label, found, total)
	trackerLine.Text = tostring(Attributes.get(Workspace, GA.TrackerHint, "") or "")
	if found >= total then
		trackerCount.TextColor3 = COLOR.HealthGood
		trackerLine.TextColor3 = COLOR.AccentBright
	else
		trackerCount.TextColor3 = COLOR.AccentBright
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
	--[[ White, and coloured entirely by the gradient below. A UIGradient
	     multiplies the background it sits on, so leaving the body at full
	     brightness is what lets one assignment repaint the whole sheet. ]]
	docBody = Widgets.frame(parent, "Document", Color3.new(1, 1, 1), 0)
	docBody.Position = UDim2.fromOffset(LAYOUT.PanelPadding, PANEL.HeaderHeight + LAYOUT.PanelPadding)
	docBody.Size = UDim2.new(1, -LAYOUT.PanelPadding * 2, 1, -(PANEL.HeaderHeight + LAYOUT.PanelPadding * 2))
	docBody.Visible = false
	Widgets.stroke(docBody, PAPER_SHADE)

	--[[ Dirtier toward the bottom than the top. A flat rectangle of cream is a UI
	     colour; paper that is darker where it has been held is a thing that has
	     been somewhere. Parented to the sheet, so it tones the sheet and not the
	     words — a UIGradient colours the object it sits on and never its
	     children. ]]
	docAge = Instance.new("UIGradient")
	docAge.Color = ColorSequence.new(PAPER, PAPER_SHADE)
	docAge.Rotation = 90
	docAge.Parent = docBody

	local scroller = Widgets.scroller(docBody, "Page")
	scroller.Position = UDim2.fromOffset(DOC_MARGIN, DOC_MARGIN)
	scroller.Size = UDim2.new(1, -DOC_MARGIN * 2, 1, -DOC_MARGIN * 2)
	scroller.AutomaticCanvasSize = Enum.AutomaticSize.Y
	--[[ The theme's bar is a pale stroke chosen to read on a dark panel, and on
	     cream it is very nearly invisible — on the one panel in the game whose
	     content is long enough for the bar to matter. ]]
	scroller.ScrollBarImageColor3 = INK_FADED

	--[[ The typewriter face and near-black ink on off-white, because this is a
	     photocopy of a form and not a screen. It is the one place in the
	     interface that deliberately does not look like the rest of it. ]]
	docText = Widgets.label(scroller, "Text", FONT.Body, TEXT.Body, INK)
	docText.Font = Enum.Font.Code
	docText.Size = UDim2.new(1, -PANEL.ScrollBarWidth, 0, 0)
	docText.AutomaticSize = Enum.AutomaticSize.Y
	docText.TextXAlignment = Enum.TextXAlignment.Left
	docText.TextYAlignment = Enum.TextYAlignment.Top
	docText.TextWrapped = true
	--[[ A quarter of a line of extra leading. Single-spaced monospace is a wall,
	     and a wall is what a player skips — which on this screen means skipping
	     the sentence the whole side objective is carried by. ]]
	docText.LineHeight = 1.25
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
	trackerLine.Size = UDim2.new(1, -LAYOUT.PanelPadding * 2, 0, (TEXT.Tiny + 2) * TRACKER_LINES)
	trackerLine.TextXAlignment = Enum.TextXAlignment.Left
	trackerLine.TextYAlignment = Enum.TextYAlignment.Top
	--[[ Wrapped rather than truncated, and truncated only if it overflows BOTH
	     rows — so a long refusal loses its tail instead of its point. ]]
	trackerLine.TextWrapped = true
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

	blur = Instance.new("BlurEffect")
	blur.Name = "FL_VaultReader"
	blur.Size = 0
	blur.Enabled = false
	blur.Parent = Lighting
	trove:add(blur)

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

--[[
	Paper, or a screen.

	Driven by whether the clue named its own ink — see PuzzleConfig's ClueSlot.
	Paperwork does not, and gets the default page; the one clue in the game that
	is a dead television does, and gets a dark tube with its own glow on it.

	Both halves are set on every open rather than only on the change, because the
	panel is shared and the last thing it drew is not something this call should
	have to know.
]]
local function setPage(ink: any)
	local screen = typeof(ink) == "Color3"
	if docAge then
		docAge.Color = if screen
			then ColorSequence.new(SCREEN, SCREEN_SHADE)
			else ColorSequence.new(PAPER, PAPER_SHADE)
	end
	docText.TextColor3 = if screen then ink else INK
end

--[[
	The world going out of focus behind the page.

	Asked for by name, and it is also the honest signal for what this screen
	already DOES: it has taken the cursor and the movement keys, so a world drawn
	sharp behind it is a world offering information the player cannot act on.

	Not while the main menu is up. That has a blur of its own and two BlurEffects
	stack — the sum is a smear rather than a depth of field — so the one panel
	that can legally open under the menu's suppression stays out of its way. The
	same test setSuppressed makes, for the same reason.
]]
local function setBlur(on: boolean)
	if not blur then
		return
	end
	if blurTween then
		blurTween:Cancel()
		blurTween = nil
	end

	local wanted = on and not menuIsOpen()
	if wanted then
		blur.Enabled = true
	end

	local tween = TweenService:Create(blur, BLUR_INFO, { Size = if wanted then READER_BLUR else 0 })
	blurTween = tween
	--[[ Switched off rather than left sitting at zero, because an enabled
	     BlurEffect is a full-screen pass whether or not it is blurring anything.
	     Only on a tween that RAN to the end: cancelled means something else has
	     taken this over and must be allowed to own Enabled. ]]
	tween.Completed:Connect(function(playback: Enum.PlaybackState)
		if blurTween == tween then
			blurTween = nil
		end
		if playback == Enum.PlaybackState.Completed and not wanted then
			blur.Enabled = false
		end
	end)
	tween:Play()
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
	setBlur(true)
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
	docText.Font = fontFrom(clue:GetAttribute(PUZZLE.ClueFont))
	setPage(nil)
	show("document", DOC_WIDTH, DOC_HEIGHT, tostring(clue:GetAttribute(PUZZLE.CluePrompt) or "DOCUMENT"))
end

--[[
	Puts a refusal on the counter card, and lights it up.

	The counter is where this game says no about a side objective: it is already
	on screen, it is already about the objective, and it is already the thing the
	player glances at. A refusal in a modal would be a screen in front of
	somebody who has just been told to go somewhere else, and a refusal in the
	objective bar would be overwritten by the next wave edge.

	Called by GeneratorController, which owns a panel and deliberately does not
	open it for a refusal, and shaped so the vault's own out-of-order message
	could come through here too.
]]
function VaultController:sayRefusal(text: string)
	if typeof(text) ~= "string" or text == "" then
		return
	end
	--[[ Newlines folded to a dash: refusals are written two lines deep on the
	     server so a page could show one, and this card is a card. ]]
	trackerLine.Text = string.gsub(text, "\n", " \226\128\148 ")
	trackerLine.TextColor3 = COLOR.Danger
	flashTracker()
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
	setBlur(false)
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

	--[[
		Going down closes it too, and nothing used to.

		The round-state watch above catches a round ENDING under an open panel;
		it does not catch the far commoner thing, which is one player being
		grabbed, shot down or killed while the round carries on around them. A
		panel at DisplayOrder.Settings draws OVER the incapacitated card and the
		death overlay, so a survivor pulled off a generator by a Hunter kept a
		full-screen puzzle over the one screen that tells them what happened to
		them — still holding the cursor and the input lock.

		The same five states the trigger refuses on, for the same reason: they
		are the ones where the player is not standing at the machine any more.
	]]
	trove:connect(player:GetAttributeChangedSignal(PA.State), function()
		if not state.open then
			return
		end
		if SHUT_STATES[Attributes.get(player, PA.State, "")] then
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
		--[[ The sentence comes down with the event rather than being written
		     here, because there are two rooms now and only the server knows which
		     one just opened. A missing line falls back to the vault's, which is
		     the one this handler was written for. ]]
		local line = payload.line
		if typeof(line) ~= "string" or line == "" then
			line = "The vault is open. Take what you need."
		end
		callController("SubtitleController", "say", name, line, VAULT_LINE_SECONDS)
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
			VaultController:sayRefusal(tostring(payload.reason or "NOT YET"))
			UiSound.play(AudioConfig.UI.MenuBack)
			return
		end

		if typeof(payload.text) == "string" and payload.text ~= "" and not state.open then
			docText.Text = payload.text
			--[[ A hazmat log and something scrawled on a wall are not the same
			     document, and opening both in one typeface is the reader quietly
			     saying they are. The face comes down with the text because the
			     config decides it and this screen only renders. ]]
			docText.Font = fontFrom(payload.font)
			setPage(payload.ink)
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
	--[[ The words as well as the numbers. Both move — the hint changes when the
	     last clue lands and again when the generators finish — and a card that
	     redrew only on a count change would keep saying SEARCH THE BUILDING to a
	     team standing at the door. ]]
	trove:connect(Workspace:GetAttributeChangedSignal(GA.TrackerLabel), refreshTracker)
	trove:connect(Workspace:GetAttributeChangedSignal(GA.TrackerHint), refreshTracker)

	--[[
		A breaker the player just threw, or failed to.

		A refusal goes on the counter card rather than into a panel, because
		there is no panel — a fuse box is thrown or it is not, and the card is
		already on screen, already about this objective and already the thing the
		player glances at. It is also the ONLY thing they are told: the server is
		careful never to name the box that would have worked, and this screen has
		no way of knowing it either.
	]]
	trove:connect(Remotes.Event.FuseResult.OnClientEvent, function(payload: any)
		if typeof(payload) ~= "table" then
			return
		end
		refreshTracker()
		flashTracker()
		if payload.ok ~= true then
			VaultController:sayRefusal(tostring(payload.reason or "NOTHING HAPPENS"))
			UiSound.play(AudioConfig.UI.MenuBack)
			return
		end
		UiSound.play(AudioConfig.UI.MenuConfirm)
	end)

	--[[ And somebody else's. Four boxes in a maze of identical corridors is a
	     job a team splits up to do, and the counter moving is the only way the
	     other three learn that the sequence advanced — and, more usefully, that
	     the box they are standing at is no longer the one to try. ]]
	trove:connect(Remotes.Event.FusePowered.OnClientEvent, function(payload: any)
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
					"Fuse box %s is live. %s of %s.",
					tostring(payload.order),
					tostring(payload.thrown),
					tostring(payload.total)
				),
				CLUE_LINE_SECONDS
			)
		end
	end)

	--[[ A generator powering is the same event as a clue landing, on the other
	     map: the team's counter moved, and everybody's card should say so and
	     flash. Handled here rather than in GeneratorController because this file
	     owns the card. ]]
	trove:connect(Remotes.Event.GeneratorPowered.OnClientEvent, function(payload: any)
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
					"Generator %s online. %s of %s.",
					tostring(payload.order),
					tostring(payload.powered),
					tostring(payload.total)
				),
				CLUE_LINE_SECONDS
			)
		end
	end)
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
