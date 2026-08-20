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
local CARD_HEIGHT = 210
local CARD_GAP = 18

--[[ The panel the cards sit inside. Wide enough for four across at the sizes
     above plus its own padding, which is the whole roster. ]]
local PANEL_PADDING = 34
local HEADER_HEIGHT = 96
local FOOTER_HEIGHT = 44
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

local function buildCard(option: any, index: number, total: number)
	local frame = newFrame(cardsHolder, option.id, COLOR.Panel, 0.12)
	frame.Size = UDim2.fromOffset(CARD_WIDTH, CARD_HEIGHT)
	frame.Position = UDim2.fromOffset((index - 1) * (CARD_WIDTH + CARD_GAP), 0)

	local stroke = Instance.new("UIStroke")
	stroke.Color = COLOR.Border
	stroke.Thickness = LAYOUT.BorderThickness
	stroke.Parent = frame

	local name = newLabel(frame, "Name", FONT.Display, TEXT.Heading, COLOR.TextPrimary)
	name.Position = UDim2.fromOffset(LAYOUT.PanelPadding, LAYOUT.PanelPadding)
	name.Size = UDim2.new(1, -LAYOUT.PanelPadding * 2, 0, TEXT.Heading + 4)
	name.Text = option.displayName

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

	local key = newLabel(frame, "Key", FONT.Stencil, TEXT.Small, COLOR.TextDim)
	key.AnchorPoint = Vector2.new(1, 0)
	key.Position = UDim2.new(1, -LAYOUT.PanelPadding, 0, LAYOUT.PanelPadding)
	key.Size = UDim2.fromOffset(20, TEXT.Heading)
	key.TextXAlignment = Enum.TextXAlignment.Right
	key.Text = tostring(index)

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
		footHint = if isTouch() then "TAP A MAP" else "1 – 4  OR  CLICK TO VOTE"
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
	clockLabel.Position = UDim2.new(0.5, 0, 0, TEXT.Display + 10)
	clockLabel.Size = UDim2.new(1, 0, 0, TEXT.Heading + 4)
	clockLabel.TextXAlignment = Enum.TextXAlignment.Center
	clockLabel.Text = ""

	local rule = newFrame(root, "Rule", COLOR.BorderBright)
	rule.AnchorPoint = Vector2.new(0.5, 0)
	rule.Position = UDim2.new(0.5, 0, 0, HEADER_HEIGHT - 12)
	rule.Size = UDim2.fromOffset(96, 2)

	cardsHolder = newFrame(root, "Cards", COLOR.Background, 1)
	cardsHolder.AnchorPoint = Vector2.new(0.5, 0)
	cardsHolder.Position = UDim2.new(0.5, 0, 0, HEADER_HEIGHT)
	cardsHolder.Size = UDim2.fromOffset(CARD_WIDTH * 2 + CARD_GAP, CARD_HEIGHT)

	footLabel = newLabel(root, "Foot", FONT.Body, TEXT.Small, COLOR.TextDim)
	footLabel.AnchorPoint = Vector2.new(0.5, 1)
	footLabel.Position = UDim2.new(0.5, 0, 1, 0)
	footLabel.Size = UDim2.new(1, 0, 0, FOOTER_HEIGHT)
	footLabel.TextXAlignment = Enum.TextXAlignment.Center
	footLabel.Text = ""
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
