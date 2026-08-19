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
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local AudioConfig = require(Shared.Config.AudioConfig)
local Registry = require(Shared.Util.Registry)
local Remotes = require(Shared.Net.Remotes)
local Trove = require(Shared.Util.Trove)
local UITheme = require(Shared.Config.UITheme)

local GamepadFocus = require(script.Parent.GamepadFocus)
local ScaleLayer = require(script.Parent.ScaleLayer)

local COLOR = UITheme.Color
local FONT = UITheme.Font
local LAYOUT = UITheme.Layout
local MOTION = UITheme.Motion
local TEXT = UITheme.TextSize

local player = Players.LocalPlayer

local CARD_WIDTH = 300
local CARD_HEIGHT = 128
local CARD_GAP = 14
local BAR_HEIGHT = 4
local BAR_CHASE = 1 / MOTION.Normal

local MapVoteController = {}

local trove = Trove.new()
local screen: ScreenGui
local root: Frame
local titleLabel: TextLabel
local clockLabel: TextLabel
local cardsHolder: Frame
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

local function playUi(definition: any)
	if not AudioConfig.isConfigured(definition) then
		return
	end
	local sound = Instance.new("Sound")
	sound.SoundId = AudioConfig.pickId(definition)
	sound.Volume = definition.volume
	sound.Parent = game:GetService("SoundService")
	sound:Play()
	sound.Ended:Once(function()
		sound:Destroy()
	end)
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
	playUi(AudioConfig.UI.MenuConfirm)
	Remotes.Event.CastMapVote:FireServer(mapId)
	MapVoteController:_refresh()
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
	blurb.Size = UDim2.new(1, -LAYOUT.PanelPadding * 2, 0, TEXT.Body * 2)
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

	local yours = newLabel(frame, "Yours", FONT.Body, TEXT.Tiny, COLOR.Accent)
	yours.Position = UDim2.fromOffset(LAYOUT.PanelPadding, CARD_HEIGHT - BAR_HEIGHT - 22)
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
			playUi(AudioConfig.UI.MenuHover)
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
		card.frame.BackgroundTransparency = if state.resolved and not winning then 0.55 else 0.12
	end
end

local function setVisible(visible: boolean)
	state.visible = visible
	screen.Enabled = visible
	if visible then
		state.shownClock = -1
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

	cardsHolder.Size = UDim2.fromOffset(total * CARD_WIDTH + (total - 1) * CARD_GAP, CARD_HEIGHT)
	titleLabel.Text = "VOTE FOR THE NEXT MAP"

	MapVoteController:_refresh()
	setVisible(true)
	playUi(AudioConfig.UI.ObjectiveChange)
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

	MapVoteController:_refresh()
	playUi(AudioConfig.UI.WaveCleared)
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

	root = newFrame(ScaleLayer.new(screen, "Scaled"), "Root", COLOR.Background, 1)
	root.AnchorPoint = Vector2.new(0.5, 1)
	root.Position = UDim2.new(0.5, 0, 1, -LAYOUT.ScreenMargin * 2)
	root.Size = UDim2.fromOffset(760, CARD_HEIGHT + 56)

	titleLabel = newLabel(root, "Title", FONT.Display, TEXT.Large, COLOR.TextPrimary)
	titleLabel.Position = UDim2.fromOffset(0, 0)
	titleLabel.Size = UDim2.new(1, -70, 0, TEXT.Large + 4)
	titleLabel.Text = "VOTE FOR THE NEXT MAP"

	clockLabel = newLabel(root, "Clock", FONT.Stencil, TEXT.Heading, COLOR.TextSecondary)
	clockLabel.AnchorPoint = Vector2.new(1, 0)
	clockLabel.Position = UDim2.new(1, 0, 0, -4)
	clockLabel.Size = UDim2.fromOffset(64, TEXT.Heading + 6)
	clockLabel.TextXAlignment = Enum.TextXAlignment.Right
	clockLabel.Text = ""

	local rule = newFrame(root, "Rule", COLOR.Border)
	rule.Position = UDim2.fromOffset(0, TEXT.Large + 10)
	rule.Size = UDim2.new(1, 0, 0, 1)

	cardsHolder = newFrame(root, "Cards", COLOR.Background, 1)
	cardsHolder.AnchorPoint = Vector2.new(0.5, 0)
	cardsHolder.Position = UDim2.new(0.5, 0, 0, TEXT.Large + 24)
	cardsHolder.Size = UDim2.fromOffset(CARD_WIDTH * 2 + CARD_GAP, CARD_HEIGHT)
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
	trove:connect(game:GetService("UserInputService").InputBegan, function(input, processed)
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
