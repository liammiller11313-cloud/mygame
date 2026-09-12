--!nonstrict
--[[
	MapVoteController — the end-of-round map vote.

	Sits under the scoreboard, in the same black/white/orange the rest of the game
	uses. Two cards, a live tally, and a countdown.

	The design rule is that a vote must never feel like it ignored you: your own
	pick is marked distinctly from the crowd's, the bar under each card moves the
	instant anyone votes, and the winner is announced rather than just happening.
	A vote whose result appears without ceremony reads as a vote that was never
	really counted.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local AudioConfig = require(Shared.Config.AudioConfig)
local Registry = require(Shared.Util.Registry)
local Remotes = require(Shared.Net.Remotes)
local Trove = require(Shared.Util.Trove)
local UITheme = require(Shared.Config.UITheme)

local GamepadFocus = require(script.Parent.GamepadFocus)
local FreeCursor = require(script.Parent.FreeCursor)
local ImageCheck = require(script.Parent.ImageCheck)
local ScaleLayer = require(script.Parent.ScaleLayer)
local UiSound = require(script.Parent.UiSound)

local COLOR = UITheme.Color
local FONT = UITheme.Font
local LAYOUT = UITheme.Layout
local PANEL = UITheme.Panel
local MOTION = UITheme.Motion
local TEXT = UITheme.TextSize

local player = Players.LocalPlayer

--[[ The vote is a full-screen menu now rather than a strip along the bottom, so
     the cards are the screen's main event and are sized like it: big enough that
     a map is a thing you choose rather than a row you skim past, and readable
     from a phone held at arm's length. ]]
local CARD_WIDTH = 320
--[[ Sized to its contents. 210 was chosen to make the cards feel like the
     screen's main event and instead gave every one of them a hand's width of
     empty panel between a one-line blurb and the tally — which reads as a card
     that failed to load rather than as a card with room to breathe. ]]
local CARD_HEIGHT = 146
local CARD_GAP = 18

--[[ The panel the cards sit inside. Wide enough for four across at the sizes
     above plus its own padding, which is the whole roster. ]]
local KEY_CAP = 26
local EXIT_SIZE = 34
--[[ The way back to the main menu, bottom-left of the panel. Wide enough for its
     own label rather than a glyph: the × beside it already means "put this away",
     and a second icon next to it would be a guess. ]]
local MENU_BUTTON_WIDTH = 140
local MENU_BUTTON_HEIGHT = 30
--[[ Its own row under the hint rather than a corner of the hint's.

     Everything in this panel is centred across its full width, and the panel
     shrinks to 420 for a one-map vote or a narrow phone. A labelled button in a
     bottom corner would meet the centred hint there — the × gets away with the
     same corner only because it is 34 pixels wide and a glyph. A row of its own
     cannot collide at any width, and it reads as leaving rather than as part of
     the hint. ]]
local MENU_ROW = MENU_BUTTON_HEIGHT + 10
local PANEL_PADDING = 34

--[[ The header, as three stacked rows rather than a total everything has to be
     squeezed under. HEADER_HEIGHT is their sum, so moving one row cannot put it
     through another — which is exactly what happened when the clock and the rule
     were both positioned against the total independently. ]]
local TITLE_ROW = TEXT.Display + 8
local RULE_ROW = 18
local CLOCK_ROW = TEXT.Heading + 6
local HEADER_HEIGHT = TITLE_ROW + RULE_ROW + CLOCK_ROW

--[[ The hint row plus the main-menu row beneath it. Both places that size the
     panel add this to the header and the cards, so the extra row is accounted
     for everywhere by changing it here. ]]
local HINT_ROW = 44
local FOOTER_HEIGHT = HINT_ROW + MENU_ROW
local BAR_HEIGHT = 4
local BAR_CHASE = 1 / MOTION.Normal

--[[ How long the result card stays up when nothing else closes it. The normal
     path is the map reporting itself loaded, which is faster and reads as
     progress; this is the backstop for a vote whose round never starts. Long
     enough to read the winner, short enough not to feel stuck. ]]
local RESULT_HOLD = 8

local MapVoteController = {}

local trove = Trove.new()
local screen: ScreenGui
local root: Frame
local titleLabel: TextLabel
local clockLabel: TextLabel
local cardsHolder: Frame
local footLabel: TextLabel

--[[ Owned here and written by FreeCursor. Its own table rather than a shared
     one, because the vote can open over the main menu — which has already taken
     the cursor — and a shared slot would have whichever closed first hand back
     the other's camera. ]]
local restore = {}

--[[ How to cast a vote on this device, as a string _refresh can append the
     turnout to. Set when the screen opens, because the scheme can change while
     it is shut. ]]
local footHint = ""

local function isTouch(): boolean
	return UserInputService.TouchEnabled and not UserInputService.MouseEnabled
end
local cards: { any } = {}

local state = {
	visible = false,
	endsAt = 0,
	shownClock = -1,
	myVote = "",
	tally = {} :: { [string]: number },
	voters = 0,
	winner = "",
	resolved = false,
	--[[ When to close regardless of what the server does next. See RESULT_HOLD. ]]
	closeAt = 0,
	--[[ This player pressed the exit button. Their vote still counts — the tally
	     is the server's — this only stops drawing the screen for them, and it
	     clears when a NEW vote starts because that is a new question. ]]
	dismissed = false,
}

local function newFrame(parent: Instance, name: string, color: Color3, transparency: number?): Frame
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.BackgroundColor3 = color
	frame.BackgroundTransparency = transparency or 0
	frame.BorderSizePixel = 0
	frame.Parent = parent
	return frame
end

local function newLabel(
	parent: Instance,
	name: string,
	font: Enum.Font,
	size: number,
	color: Color3
): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = name
	label.BackgroundTransparency = 1
	label.Font = font
	label.TextSize = size
	label.TextColor3 = color
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.RichText = false
	label.Parent = parent
	return label
end

local function releaseCards()
	for _, card in cards do
		card.frame:Destroy()
	end
	table.clear(cards)
end

local function castVote(mapId: string)
	if state.resolved or state.myVote == mapId then
		return
	end
	state.myVote = mapId
	UiSound.play(AudioConfig.UI.MenuConfirm)
	Remotes.Event.CastMapVote:FireServer(mapId)
	MapVoteController:_refresh()
end

--[[ Fits the panel to the roster and to the screen. Four maps at full size is
     wider than a phone, so the cards shrink together rather than the panel
     hanging off both edges — the same rule the loadout picker follows. ]]
local function layoutPanel(total: number)
	if not root or not cardsHolder then
		return
	end
	local camera = Workspace.CurrentCamera
	local factor = ScaleLayer.getFactor()
	local available = if camera and factor > 0 then camera.ViewportSize.X / factor else CARD_WIDTH * total

	local wanted = CARD_WIDTH * total + CARD_GAP * (total - 1)
	local room = math.max(available - PANEL_PADDING * 2, 240)
	local shrink = math.min(room / math.max(wanted, 1), 1)
	local cardWidth = math.floor(CARD_WIDTH * shrink)
	local cardHeight = math.floor(CARD_HEIGHT * shrink)
	local gap = math.floor(CARD_GAP * shrink)
	local width = cardWidth * total + gap * (total - 1)

	cardsHolder.Size = UDim2.fromOffset(width, cardHeight)
	root.Size = UDim2.fromOffset(math.max(width, 420), HEADER_HEIGHT + cardHeight + FOOTER_HEIGHT)
	for index, card in cards do
		card.frame.Size = UDim2.fromOffset(cardWidth, cardHeight)
		card.frame.Position = UDim2.fromOffset((index - 1) * (cardWidth + gap), 0)
	end
end

--[[ `total` is no longer read: layoutPanel owns every card's size and
     position, so the builder only has to know which index this is. ]]
local function buildCard(option: any, index: number, _total: number)
	local frame = newFrame(cardsHolder, option.id, COLOR.Panel, 0.12)
	frame.Size = UDim2.fromOffset(CARD_WIDTH, CARD_HEIGHT)
	frame.Position = UDim2.fromOffset((index - 1) * (CARD_WIDTH + CARD_GAP), 0)

	local stroke = Instance.new("UIStroke")
	stroke.Color = COLOR.Border
	stroke.Thickness = LAYOUT.BorderThickness
	stroke.Parent = frame

	--[[
		The map's picture, and the scrim that keeps the words on top of it legible.

		Built FIRST and never given a ZIndex. This ScreenGui is Sibling-ordered, so
		siblings at the same ZIndex draw in creation order — which means everything
		below this point lands on top of the picture for free, and no existing
		element on the card had to be renumbered to make room for it.

		A card whose map has no image skips both and is byte-for-byte the card it
		was before, which is what makes adding pictures one map at a time safe.

		── WHY THE SCRIM IS NOT OPTIONAL, AND WHY IT IS NEARLY EVEN ─────────────
		The blurb is TextSecondary on a near-black panel. Over a photograph it is
		grey text on whatever happens to be behind it — a bright road surface, a
		wall, a sky — and the one thing you cannot do is know in advance.

		The obvious scrim is a poster gradient: clear at the top so the picture
		reads, opaque at the bottom where the words are. That is wrong for THIS
		card, because there is no bottom band of words — the name is at the top,
		the blurb fills the middle and the tally sits under it. Type covers the
		whole tile, so a gradient that clears at the top just puts the largest
		text on the card over an undimmed photograph.

		So it only leans: dark enough at the top to hold a display-size name, a
		little lighter through the middle, darkest under the tally. With the
		picture already dimmed below, the map reads as a backdrop rather than as
		the subject — which on a 320x146 tile mostly full of words is the only
		thing it can honestly be.
	]]
	if typeof(option.image) == "string" and option.image ~= "" then
		local picture = Instance.new("ImageLabel")
		picture.Name = "Picture"
		picture.BackgroundTransparency = 1
		picture.BorderSizePixel = 0
		picture.Size = UDim2.fromScale(1, 1)
		--[[ Crop, not Stretch. These are 320x146 cards and a screenshot is not,
		     so stretching would show every map through a squashed lens. ]]
		picture.ScaleType = Enum.ScaleType.Crop
		picture.Image = option.image
		--[[ A card whose picture does not load is a plain dark tile with the map
		     name on it, which is a perfectly acceptable-looking card — so
		     nobody would ever report it. See ImageCheck. The name comes from
		     the server's own option list, so the warning says which map. ]]
		ImageCheck.verify(
			option.image,
			string.format("the %s map card", tostring(option.displayName or option.id))
		)
		--[[ Dimmed a little even before the scrim. A full-brightness photograph
		     under this interface's type reads as a web banner; this game is set
		     at dusk and the card should look like it belongs to it. ]]
		picture.ImageColor3 = Color3.fromRGB(168, 162, 152)
		picture.Parent = frame

		local scrim = newFrame(frame, "Scrim", COLOR.Background, 0)
		scrim.Size = UDim2.fromScale(1, 1)
		local shade = Instance.new("UIGradient")
		shade.Rotation = 90
		shade.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.34),
			NumberSequenceKeypoint.new(0.55, 0.2),
			NumberSequenceKeypoint.new(1, 0.08),
		})
		shade.Parent = scrim
	end

	local name = newLabel(frame, "Name", FONT.Display, TEXT.Heading, COLOR.TextPrimary)
	name.Position = UDim2.fromOffset(LAYOUT.PanelPadding, LAYOUT.PanelPadding)
	name.Size = UDim2.new(1, -LAYOUT.PanelPadding * 2, 0, TEXT.Heading + 4)
	name.Text = option.displayName
	--[[
		Shrinks to fit, up to the size it already was.

		layoutPanel narrows the cards when the roster does not fit the screen, and
		it narrows the FRAME only — the type stayed at Heading whatever happened
		around it. Two maps never reached the point where that mattered; three on
		a 480-pixel viewport puts a 132-pixel card under a 30-pixel word, and
		"CROSSROADS" simply ran off the side of it.

		The constraint is what keeps this from being a downgrade everywhere else:
		TextScaled on its own would GROW the name to fill a desktop card, which is
		a different card than the one this screen was designed as.
	]]
	name.TextScaled = true
	local nameSize = Instance.new("UITextSizeConstraint")
	nameSize.MaxTextSize = TEXT.Heading
	nameSize.Parent = name

	local blurb = newLabel(frame, "Blurb", FONT.Body, TEXT.Small, COLOR.TextSecondary)
	blurb.Position = UDim2.fromOffset(LAYOUT.PanelPadding, LAYOUT.PanelPadding + TEXT.Heading + 6)
	--[[ Fills the space between the title and the tally instead of a fixed two
	     lines. The cards are two-thirds taller than the strip they replaced, and
	     a blurb that ignored that left a band of dead panel across the middle of
	     every one of them. ]]
	blurb.Size = UDim2.new(
		1,
		-LAYOUT.PanelPadding * 2,
		1,
		-(LAYOUT.PanelPadding + TEXT.Heading + 6 + TEXT.Large + BAR_HEIGHT + 20)
	)
	blurb.TextWrapped = true
	blurb.TextYAlignment = Enum.TextYAlignment.Top
	blurb.Text = option.blurb

	--[[
		The number key that votes for this card, drawn as a KEY CAP.

		It used to be a bare digit in the top-right corner, directly diagonal from
		the tally in the bottom-right — two numbers on one card, one of which is
		how many people chose this map and the other of which is which button to
		press. On a two-map vote the caps read "1" and "2" and looked exactly like
		a score of one against two. A boxed, dim, bracket-less cap with a border
		is a keyboard key; a number on its own is a quantity.
	]]
	local keyCap = newFrame(frame, "KeyCap", COLOR.Background, 0.35)
	keyCap.AnchorPoint = Vector2.new(1, 0)
	keyCap.Position = UDim2.new(1, -LAYOUT.PanelPadding, 0, LAYOUT.PanelPadding + 2)
	keyCap.Size = UDim2.fromOffset(KEY_CAP, KEY_CAP)
	local keyStroke = Instance.new("UIStroke")
	keyStroke.Color = COLOR.Border
	keyStroke.Thickness = LAYOUT.BorderThickness
	keyStroke.Parent = keyCap

	local key = newLabel(keyCap, "Key", FONT.Body, TEXT.Small, COLOR.TextDim)
	key.Size = UDim2.fromScale(1, 1)
	key.TextXAlignment = Enum.TextXAlignment.Center
	key.Text = tostring(index)
	keyCap.Visible = not isTouch()

	local count = newLabel(frame, "Count", FONT.Numeric, TEXT.Large, COLOR.TextSecondary)
	count.AnchorPoint = Vector2.new(1, 1)
	count.Position = UDim2.new(1, -LAYOUT.PanelPadding, 1, -(BAR_HEIGHT + 8))
	count.Size = UDim2.fromOffset(60, TEXT.Large + 2)
	count.TextXAlignment = Enum.TextXAlignment.Right
	count.Text = "0"

	--[[ Anchored to the card's bottom edge rather than measured down from
	     CARD_HEIGHT. The cards are resized to fit the roster and the screen — see
	     layoutPanel — so an absolute offset from the constant is correct only at
	     one card size, and every other size drew this through the share bar or
	     out of the card entirely. Everything else here is already scale-anchored;
	     this was the one that was not. ]]
	--[[ And the tally says what it is. One labelled number and one boxed key is
	     readable; two unlabelled numbers on the same card are not. ]]
	local countCaption = newLabel(frame, "CountCaption", FONT.Body, TEXT.Tiny, COLOR.TextDim)
	countCaption.AnchorPoint = Vector2.new(1, 1)
	countCaption.Position = UDim2.new(1, -(LAYOUT.PanelPadding + 46), 1, -(BAR_HEIGHT + 10))
	countCaption.Size = UDim2.fromOffset(52, TEXT.Body)
	countCaption.TextXAlignment = Enum.TextXAlignment.Right
	countCaption.Text = "VOTES"

	local yours = newLabel(frame, "Yours", FONT.Body, TEXT.Tiny, COLOR.Accent)
	yours.AnchorPoint = Vector2.new(0, 1)
	yours.Position = UDim2.new(0, LAYOUT.PanelPadding, 1, -(BAR_HEIGHT + 8))
	yours.Size = UDim2.fromOffset(120, TEXT.Body)
	yours.Text = ""

	-- The share bar. Sits flush on the bottom edge so it reads as the card
	-- filling up rather than as a separate widget.
	local barTrack = newFrame(frame, "Track", COLOR.Background, 0.4)
	barTrack.AnchorPoint = Vector2.new(0, 1)
	barTrack.Position = UDim2.new(0, 0, 1, 0)
	barTrack.Size = UDim2.new(1, 0, 0, BAR_HEIGHT)

	local barFill = newFrame(barTrack, "Fill", COLOR.Accent)
	barFill.Size = UDim2.new(0, 0, 1, 0)

	local button = Instance.new("TextButton")
	button.Name = "Hit"
	button.BackgroundTransparency = 1
	button.Text = ""
	button.Size = UDim2.fromScale(1, 1)
	button.ZIndex = 4
	button.Parent = frame
	--[[ A vote a controller cannot reach is a vote a console player never casts,
	     and the number keys that back this screen up are keyboard-only. ]]
	GamepadFocus.style(button)

	local card = {
		id = option.id,
		frame = frame,
		button = button,
		stroke = stroke,
		name = name,
		count = count,
		yours = yours,
		fill = barFill,
		share = 0,
		shareTarget = 0,
	}

	trove:connect(button.MouseEnter, function()
		if not state.resolved and state.myVote ~= card.id then
			stroke.Color = COLOR.BorderBright
			UiSound.play(AudioConfig.UI.MenuHover)
		end
	end)
	trove:connect(button.MouseLeave, function()
		MapVoteController:_refresh()
	end)
	trove:connect(button.Activated, function()
		castVote(card.id)
	end)

	cards[index] = card
end

function MapVoteController:_refresh()
	local total = 0
	for _, count in state.tally do
		total += count
	end

	for _, card in cards do
		local count = state.tally[card.id] or 0
		card.count.Text = tostring(count)
		card.shareTarget = if total > 0 then count / total else 0

		local mine = state.myVote == card.id
		local winning = state.resolved and state.winner == card.id

		card.yours.Text = if mine then "YOUR VOTE" else ""
		card.stroke.Color = if winning
			then COLOR.AccentBright
			elseif mine then COLOR.Accent
			elseif count > 0 then COLOR.BorderBright
			else COLOR.Border
		card.stroke.Thickness = if mine or winning then LAYOUT.BorderThickness + 1 else LAYOUT.BorderThickness
		card.name.TextColor3 = if winning then COLOR.AccentBright else COLOR.TextPrimary
		card.count.TextColor3 = if mine or winning then COLOR.Accent else COLOR.TextSecondary

		--[[ Three states with three different weights, because at full-screen size
		     a one-pixel border change is not enough to answer "which one did I
		     press" at a glance. The card you chose LIFTS — brighter panel, thicker
		     edge — the winner lifts further, and everything else recedes once the
		     vote is decided so the result reads without having to find the number. ]]
		card.stroke.Thickness = if winning
			then LAYOUT.BorderThickness + 2
			elseif mine then LAYOUT.BorderThickness + 1
			else LAYOUT.BorderThickness
		card.frame.BackgroundTransparency = if state.resolved and not winning
			then 0.6
			elseif winning then 0.02
			elseif mine then 0.04
			else 0.12
	end

	--[[ How much of the room has actually voted. Without it the numbers are
	     unreadable — two votes for one map means nothing until you know whether
	     that is two players out of two or two out of eight — and it is the line
	     that tells a player whether waiting will change anything. ]]
	if footLabel then
		local voters = math.max(state.voters, total)
		footLabel.Text = if state.resolved
			then string.format("%d VOTE%s CAST", total, if total == 1 then "" else "S")
			elseif voters > 0 then string.format("%d OF %d VOTED  ·  %s", total, voters, footHint)
			else footHint
	end
end

local function setVisible(visible: boolean)
	--[[ Dismissed stays dismissed until a new vote starts. Without this the
	     next tally update would put the screen back up, and the close button
	     would be a button that closes for half a second. ]]
	if visible and state.dismissed then
		return
	end
	state.visible = visible
	screen.Enabled = visible
	if not visible then
		state.closeAt = 0
	end

	--[[ The menu's lobby screen steps aside while a vote is up. A vote during the
	     countdown is the act of loading into the round, and the mode list the
	     player already chose from is nothing but clutter behind it. The results
	     screen is unaffected — a post-round vote is meant to run alongside the
	     scoreboard, which is why the vote sits above the menu at all. ]]
	local menu = Registry.find("MainMenuController")
	if menu and typeof(menu.setVoteOpen) == "function" then
		pcall(menu.setVoteOpen, menu, visible)
	end

	--[[ A full-screen menu with things to click has to hand the mouse back, the
	     same way the main menu and the pause menu do. It did not need to as a
	     strip along the bottom of a first-person screen — the number keys were
	     the whole interface — and a desktop player looking at four cards they
	     cannot click is the trapped-cursor bug in a new place. ]]
	if visible then
		FreeCursor.take(restore)
	else
		FreeCursor.giveBack(restore)
	end

	if visible then
		state.shownClock = -1
		--[[ The real number of options, not the roster's ceiling. "1 – 4" over a
		     two-map vote tells a player two keys that do nothing. ]]
		local count = #cards
		footHint = if isTouch()
			then "TAP A MAP  ·  × TO CLOSE"
			elseif count > 1 then string.format("1 – %d  OR  CLICK TO VOTE  ·  P  PAUSE", count)
			else "CLICK TO VOTE  ·  P  PAUSE"
		footLabel.Text = footHint
		GamepadFocus.capture(cards[1] and cards[1].button)
	else
		GamepadFocus.release(cards[1] and cards[1].button)
	end
end

local function onVoteStarted(payload: any)
	if typeof(payload) ~= "table" or typeof(payload.options) ~= "table" then
		return
	end

	releaseCards()
	--[[ A new question, so a player who dismissed the last one is asked again. ]]
	state.dismissed = false
	state.endsAt = tonumber(payload.endsAt) or 0
	state.myVote = ""
	state.tally = {}
	state.voters = 0
	state.winner = ""
	state.resolved = false

	local total = #payload.options
	for index, option in payload.options do
		state.tally[option.id] = 0
		buildCard(option, index, total)
	end

	layoutPanel(total)
	titleLabel.Text = "VOTE FOR THE NEXT MAP"

	MapVoteController:_refresh()
	setVisible(true)
	UiSound.play(AudioConfig.UI.ObjectiveChange)
end

local function onVoteUpdated(payload: any)
	if typeof(payload) ~= "table" or typeof(payload.tally) ~= "table" then
		return
	end
	state.tally = payload.tally
	state.voters = tonumber(payload.voters) or 0
	--[[ The deadline can MOVE now: the server collapses the clock the moment the
	     result can no longer change, so a countdown drawn from the value that
	     arrived with MapVoteStarted would read fourteen while the vote closed.
	     Only ever accepted EARLIER than what we hold — a later one would be the
	     vote appearing to extend itself, which nothing does. ]]
	local moved = tonumber(payload.endsAt)
	if moved and (state.endsAt <= 0 or moved < state.endsAt) then
		state.endsAt = moved
	end
	MapVoteController:_refresh()
end

local function onVoteResult(payload: any)
	if typeof(payload) ~= "table" then
		return
	end
	state.winner = tostring(payload.winner or "")
	if typeof(payload.tally) == "table" then
		state.tally = payload.tally
	end
	state.resolved = true

	for _, card in cards do
		if card.id == state.winner then
			titleLabel.Text = "NEXT: " .. card.name.Text
		end
	end
	clockLabel.Text = "LOADING"
	clockLabel.TextColor3 = COLOR.Accent

	--[[
		A deadline, because the fast path is not guaranteed.

		The card normally closes when the map reports itself loaded, which is the
		right moment and the one that reads as progress. But a fresh-server vote
		resolves during the lobby countdown, and a countdown can be reset — the
		last player leaves, matchmaking cancels — in which case no round starts,
		no map loads, and nothing was ever going to close this. That used to leave
		a stale card on screen; now the menu's lobby is hiding behind it, so it
		would leave the player with no way back to the mode list at all.
	]]
	state.closeAt = os.clock() + RESULT_HOLD

	MapVoteController:_refresh()
	UiSound.play(AudioConfig.UI.WaveCleared)
end

--[[ The map swap itself. Kept on this screen rather than given its own, because
     the player is already looking here and a second overlay appearing on top
     would read as a stall rather than as progress. ]]
local function onMapLoading(payload: any)
	if typeof(payload) ~= "table" then
		return
	end
	local phase = tostring(payload.phase)
	if phase == "Ready" then
		task.delay(0.35, function()
			if state.visible and state.resolved then
				setVisible(false)
			end
		end)
	elseif state.resolved then
		clockLabel.Text = if phase == "Unload" then "CLEARING" else "LOADING"
	end
end

local function update(dt: number)
	if not state.visible then
		return
	end

	if state.closeAt > 0 and os.clock() >= state.closeAt then
		setVisible(false)
		return
	end

	for _, card in cards do
		if math.abs(card.share - card.shareTarget) > 0.002 then
			card.share += (card.shareTarget - card.share) * math.min(dt * BAR_CHASE, 1)
			card.fill.Size = UDim2.new(card.share, 0, 1, 0)
		end
	end

	if state.resolved then
		return
	end

	local remaining = math.max(math.ceil(state.endsAt - Workspace:GetServerTimeNow()), 0)
	if remaining == state.shownClock then
		return
	end
	state.shownClock = remaining
	clockLabel.Text = string.format("%d", remaining)
	-- The last five seconds turn orange, which is the only cue anyone needs that
	-- a vote is about to close.
	clockLabel.TextColor3 = if remaining <= 5 then COLOR.Accent else COLOR.TextSecondary
end

local function build()
	screen = Instance.new("ScreenGui")
	screen.Name = "FL_MapVote"
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = true
	--[[ Above the menu, and so above the scoreboard the menu draws, because the
	     vote runs at the same time as the scoreboard rather than after it. Below
	     a teleport fade. ]]
	screen.DisplayOrder = UITheme.DisplayOrder.Vote
	screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screen.Enabled = false
	screen.Parent = player:WaitForChild("PlayerGui")
	trove:add(screen)

	local layer = ScaleLayer.new(screen, "Scaled")

	--[[
		A full-screen ground rather than a strip along the bottom.

		This vote decides the map you are about to spend seventeen minutes in, and
		as a bar under the HUD it read as a notification — something happening to
		you rather than something you were doing. It is a menu now, and it covers
		the screen like one.

		Nearly opaque rather than fully: a hair of the world through it is what
		keeps this reading as a screen laid OVER the game instead of the game
		having been replaced, which is the same rule every other modal here
		follows. It is also a full-size button, so a click that misses a card
		lands on the scrim and does nothing rather than reaching the world behind.
	]]
	local scrim = Instance.new("TextButton")
	scrim.Name = "Scrim"
	scrim.AutoButtonColor = false
	scrim.Text = ""
	scrim.BackgroundColor3 = COLOR.Background
	scrim.BackgroundTransparency = PANEL.Scrim * 0.2
	scrim.BorderSizePixel = 0
	scrim.Size = UDim2.fromScale(1, 1)
	scrim.ZIndex = 0
	scrim.Parent = layer

	root = newFrame(layer, "Root", COLOR.Background, 1)
	root.AnchorPoint = Vector2.new(0.5, 0.5)
	root.Position = UDim2.fromScale(0.5, 0.5)
	root.Size = UDim2.fromOffset(760, HEADER_HEIGHT + CARD_HEIGHT + FOOTER_HEIGHT)
	root.ZIndex = 2

	titleLabel = newLabel(root, "Title", FONT.Display, TEXT.Display, COLOR.TextPrimary)
	titleLabel.AnchorPoint = Vector2.new(0.5, 0)
	titleLabel.Position = UDim2.new(0.5, 0, 0, 0)
	titleLabel.Size = UDim2.new(1, 0, 0, TEXT.Display + 6)
	titleLabel.TextXAlignment = Enum.TextXAlignment.Center
	titleLabel.Text = "VOTE FOR THE NEXT MAP"

	clockLabel = newLabel(root, "Clock", FONT.Stencil, TEXT.Heading, COLOR.TextSecondary)
	clockLabel.AnchorPoint = Vector2.new(0.5, 0)
	--[[ Below the rule, not across it. The clock used to start at Display + 10
	     and run 34 tall, and the rule sat at HEADER_HEIGHT - 12 — which is inside
	     that span, so the orange line struck straight through the number. The
	     three header rows are laid out in order now and HEADER_HEIGHT is their
	     sum rather than a round number they have to fit inside. ]]
	clockLabel.Position = UDim2.new(0.5, 0, 0, TITLE_ROW + RULE_ROW)
	clockLabel.Size = UDim2.new(1, 0, 0, CLOCK_ROW)
	clockLabel.TextXAlignment = Enum.TextXAlignment.Center
	clockLabel.Text = ""

	--[[
		A way out.

		The vote covers the screen, frees the mouse and runs for twenty seconds,
		and once a player has voted there is nothing left for them to do on it —
		but it was still the only thing they could look at. Worse, it opens right
		after the round ends, so a player who wants the pause menu (or just their
		own scoreboard) had a full-screen card in the way and no button on it.

		Dismissing does NOT cancel the vote. The tally is server-side and stays
		cast; this only stops drawing it for this player. A new vote brings the
		screen back, because that is a new question.
	]]
	local exitButton = Instance.new("TextButton")
	exitButton.Name = "Exit"
	exitButton.AnchorPoint = Vector2.new(1, 0)
	exitButton.Position = UDim2.new(1, 0, 0, 0)
	exitButton.Size = UDim2.fromOffset(EXIT_SIZE, EXIT_SIZE)
	exitButton.BackgroundTransparency = 1
	exitButton.Font = FONT.Display
	exitButton.TextSize = TEXT.Large
	exitButton.TextColor3 = COLOR.TextDim
	exitButton.Text = "×"
	exitButton.ZIndex = 3
	exitButton.Parent = root
	GamepadFocus.style(exitButton)
	trove:connect(exitButton.MouseEnter, function()
		exitButton.TextColor3 = COLOR.TextPrimary
	end)
	trove:connect(exitButton.MouseLeave, function()
		exitButton.TextColor3 = COLOR.TextDim
	end)
	trove:connect(exitButton.Activated, function()
		MapVoteController:dismiss()
	end)

	--[[
		Out of the game entirely, as opposed to the × which only stops drawing the
		vote.

		These are two different wants and the × served neither of them well. A
		player who is done for the evening was, at the one moment the game asks
		them a question and frees their mouse, given a close button that put them
		back in a first-person view they then had to open the pause menu from.
		Every other full-screen menu here offers a way to the main menu; the vote
		is the screen most likely to be up when somebody wants one.

		Dismisses first, exactly as the pause menu closes itself before opening the
		menu: this screen owns a FreeCursor claim and the menu takes its own, and
		two overlays holding the cursor at once is how a player ends up unable to
		close either. The vote stays cast — the tally is the server's and leaving
		the screen was never a withdrawal.
	]]
	local menuButton = Instance.new("TextButton")
	menuButton.Name = "MainMenu"
	menuButton.AnchorPoint = Vector2.new(0.5, 1)
	menuButton.Position = UDim2.new(0.5, 0, 1, 0)
	menuButton.Size = UDim2.fromOffset(MENU_BUTTON_WIDTH, MENU_BUTTON_HEIGHT)
	menuButton.BackgroundTransparency = 1
	menuButton.AutoButtonColor = false
	menuButton.BorderSizePixel = 0
	menuButton.Font = FONT.Body
	menuButton.TextSize = TEXT.Small
	menuButton.TextColor3 = COLOR.TextDim
	menuButton.Text = "MAIN MENU"
	menuButton.ZIndex = 3
	menuButton.Parent = root
	GamepadFocus.style(menuButton)

	local menuStroke = Instance.new("UIStroke")
	menuStroke.Color = COLOR.Border
	menuStroke.Thickness = 1
	menuStroke.Parent = menuButton

	trove:connect(menuButton.MouseEnter, function()
		menuButton.TextColor3 = COLOR.TextPrimary
		menuStroke.Color = COLOR.BorderBright
	end)
	trove:connect(menuButton.MouseLeave, function()
		menuButton.TextColor3 = COLOR.TextDim
		menuStroke.Color = COLOR.Border
	end)
	trove:connect(menuButton.Activated, function()
		MapVoteController:dismiss()
		local menu = Registry.find("MainMenuController")
		if menu and typeof(menu.open) == "function" then
			pcall(menu.open, menu)
		end
	end)

	local rule = newFrame(root, "Rule", COLOR.BorderBright)
	rule.AnchorPoint = Vector2.new(0.5, 0)
	rule.Position = UDim2.new(0.5, 0, 0, TITLE_ROW + (RULE_ROW - 2) * 0.5)
	rule.Size = UDim2.fromOffset(96, 2)

	cardsHolder = newFrame(root, "Cards", COLOR.Background, 1)
	cardsHolder.AnchorPoint = Vector2.new(0.5, 0)
	cardsHolder.Position = UDim2.new(0.5, 0, 0, HEADER_HEIGHT)
	cardsHolder.Size = UDim2.fromOffset(CARD_WIDTH * 2 + CARD_GAP, CARD_HEIGHT)

	footLabel = newLabel(root, "Foot", FONT.Body, TEXT.Small, COLOR.TextDim)
	footLabel.AnchorPoint = Vector2.new(0.5, 1)
	footLabel.Position = UDim2.new(0.5, 0, 1, -MENU_ROW)
	footLabel.Size = UDim2.new(1, 0, 0, HINT_ROW)
	footLabel.TextXAlignment = Enum.TextXAlignment.Center
	footLabel.Text = ""
end

--[[
	Hides the vote for this player without withdrawing their vote.

	Separate from setVisible so `state.dismissed` survives the tally updates that
	arrive afterwards: every MapVoteUpdated calls _refresh, and a screen that
	came back on the next tally would be a close button that does not close.
]]
function MapVoteController:dismiss()
	if not state.visible then
		return
	end
	state.dismissed = true
	setVisible(false)
	UiSound.play(AudioConfig.UI.MenuBack)
end

function MapVoteController:isOpen(): boolean
	return state.visible
end

function MapVoteController:init()
	build()
end

function MapVoteController:start()
	trove:connect(Remotes.Event.MapVoteStarted.OnClientEvent, onVoteStarted)
	trove:connect(Remotes.Event.MapVoteUpdated.OnClientEvent, onVoteUpdated)
	trove:connect(Remotes.Event.MapVoteResult.OnClientEvent, onVoteResult)
	trove:connect(Remotes.Event.MapLoading.OnClientEvent, onMapLoading)

	-- Number keys mirror the cards, because a mouse is a long way to travel for
	-- a twenty-second decision.
	local keys = { Enum.KeyCode.One, Enum.KeyCode.Two, Enum.KeyCode.Three, Enum.KeyCode.Four }
	trove:connect(UserInputService.InputBegan, function(input, processed)
		if processed or not state.visible or state.resolved then
			return
		end
		local index = table.find(keys, input.KeyCode)
		if index and cards[index] then
			castVote(cards[index].id)
		end
	end)

	trove:connect(RunService.RenderStepped, update)
end

Registry.register("MapVoteController", MapVoteController)

return MapVoteController
