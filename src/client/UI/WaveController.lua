--!nonstrict
--[[
	WaveController — the round clock, the seven pips, and the wave announcements.

	Classic is seventeen minutes long and the only question it asks is whether
	the team is still standing at the end of them. That makes the clock the score,
	not decoration, so it sits top centre above everything else the HUD says.

	── WHERE THE TIME COMES FROM ───────────────────────────────────────────────
	FL_WaveEndsAt and FL_RoundEndsAt are absolute workspace:GetServerTimeNow()
	stamps. The client subtracts its own synchronised clock every frame and gets
	a countdown that is smooth at any framerate, costs nothing while it runs, and
	cannot drift — the attributes only change when a phase does. Nothing here
	polls the server and nothing here ticks a number over a remote.

	── QUIET, THEN LOUD ────────────────────────────────────────────────────────
	During a wave the block is reference information: one small line, one clock,
	seven pips. The player is busy and the clock is not what is about to kill
	them, so it stays out of the way and lets the pips carry progress.

	The breather is the opposite, and it is the only moment in a round where the
	interface is allowed to be the loudest thing on screen. The WAVE CLEARED beat
	lands first, alone; then — once it has left — the countdown to the next wave
	takes the same spot and grows as it approaches zero, so nothing ever arrives
	as a surprise. The last ten seconds are unmistakable, and the last thirty
	seconds of wave 7 are red, because surviving them is the whole mode.

	── PERFORMANCE ─────────────────────────────────────────────────────────────
	One RenderStepped. The clock and the countdown reformat their text only when
	the whole second they are showing actually changes, so a countdown running
	for seventeen minutes allocates about a thousand short strings rather than
	sixty thousand.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attributes = require(Shared.Net.Attributes)
local GameModeConfig = require(Shared.Config.GameModeConfig)
local Registry = require(Shared.Util.Registry)
local Remotes = require(Shared.Net.Remotes)
local Trove = require(Shared.Util.Trove)
local UITheme = require(Shared.Config.UITheme)

local ScaleLayer = require(script.Parent.ScaleLayer)

local COLOR = UITheme.Color
local FONT = UITheme.Font
local LAYOUT = UITheme.Layout
local MOTION = UITheme.Motion
local TEXT = UITheme.TextSize

local GA = Attributes.Game

-- The values RoundService writes to Attributes.Game.WavePhase.
local PHASE = table.freeze({
	Prep = "Prep",
	Active = "Active",
	Breather = "Breather",
	Over = "Over",
})

local WAVE_COUNT = GameModeConfig.getWaveCount()
local PREP_DURATION = GameModeConfig.Classic.PrepDuration

--[[ Seven pips at this pitch come to 218px, which sits inside the block with
     enough margin that a two-digit minute clock above them still centres. ]]
local BLOCK_WIDTH = 300
local PIP_WIDTH = 26
local PIP_HEIGHT = 4

--[[ The one focal point. The announcement card and the countdown share it and
     are never on screen together — the beat lands, then the clock takes over —
     so a single position stays clear of the crosshair and of the objective line
     the HUD draws under this block. ]]
local FOCUS_Y = 0.3

--[[ A card that lingers is a card the player is fighting through. Long enough
     to read three words without looking away from the fight, and gone before
     the wave it announces is on top of them. ]]
local CARD_HOLD = 1.7
--[[ The poster settles rather than arrives flat: it lands a touch oversized and
     shrinks into place over the fade-in. ]]
local CARD_OVERSHOOT = 0.06
local CARD_RULE_WIDTH = 420

--[[ Inside this many seconds the countdown stops being information and starts
     being pressure: bigger type, hotter colour, a harder tick. ]]
local TENSION_WINDOW = 10

--[[ Matches RoundService's own finale warning, so the screen turning red and
     the "30 seconds! Hold on!" callout land together rather than a beat apart. ]]
local FINALE_WINDOW = 30

-- How far the countdown number kicks on each tick, and how long the kick lasts.
local PUNCH_CALM = 0.06
local PUNCH_TENSE = 0.2
local PUNCH_DECAY = 0.28

-- A pip fill under this much movement is not worth a UDim2 write.
local PIP_EPSILON = 0.002

local WaveController = {}

local player = Players.LocalPlayer
local trove = Trove.new()

local gui: ScreenGui
--[[ The scaled content layer. It has to be the same one the HUD uses, because
     getReservedTopHeight hands the HUD a pixel inset and both sides only agree
     on what a pixel is while both are drawing in reference space. ]]
local root: Frame
local block: Frame
local waveLabel: TextLabel
local clockLabel: TextLabel
local pips: { { track: Frame, fill: Frame } } = {}

local callout: Frame
local calloutCaption: TextLabel
local calloutNumber: TextLabel
local calloutScale: UIScale

local card: Frame
local cardScale: UIScale
local cardTitle: TextLabel
local cardSubtitle: TextLabel
local cardRules: { Frame } = {}

local state = {
	visible = true,
	cinematic = false,

	-- Mirrors of Attributes.Game, refreshed on their changed signals only.
	waveIndex = 0,
	phase = PHASE.Over,
	waveEndsAt = 0,
	roundEndsAt = 0,

	active = false, -- a round is running and the block belongs on screen
	phaseDuration = 0,
	activeFill = nil :: Frame?,
	pipFill = -1,

	clockWhole = -1,
	calloutWhole = -1,
	calloutAlpha = 0,
	captionText = "",
	calloutSize = 0,
	punch = 0,

	card = nil :: any,
	cardPhase = "idle",
	cardClock = 0,
	cardAlpha = 0,
}

-- ── construction helpers ────────────────────────────────────────────────────

local function newFrame(parent: Instance, name: string, color: Color3, transparency: number): Frame
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.BackgroundColor3 = color
	frame.BackgroundTransparency = transparency
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
	label.BorderSizePixel = 0
	label.Font = font
	label.TextSize = size
	label.TextColor3 = color
	label.TextXAlignment = Enum.TextXAlignment.Center
	label.TextYAlignment = Enum.TextYAlignment.Center
	label.Text = ""
	label.Parent = parent
	return label
end

-- ── the top block ───────────────────────────────────────────────────────────

local LABEL_HEIGHT = TEXT.Small + 4
local CLOCK_HEIGHT = TEXT.Heading + 4
local BLOCK_HEIGHT = LABEL_HEIGHT + CLOCK_HEIGHT + PIP_HEIGHT + LAYOUT.ElementGap * 2

local function buildBlock()
	block = newFrame(root, "Round", COLOR.Panel, 1)
	block.AnchorPoint = Vector2.new(0.5, 0)
	block.Position = UDim2.new(0.5, 0, 0, LAYOUT.ScreenMargin)
	block.Size = UDim2.fromOffset(BLOCK_WIDTH, BLOCK_HEIGHT)
	block.Visible = false

	waveLabel = newLabel(block, "Wave", FONT.Heading, TEXT.Small, COLOR.TextSecondary)
	waveLabel.Position = UDim2.fromOffset(0, 0)
	waveLabel.Size = UDim2.new(1, 0, 0, LABEL_HEIGHT)

	clockLabel = newLabel(block, "Clock", FONT.Numeric, TEXT.Heading, COLOR.TextPrimary)
	clockLabel.Position = UDim2.new(0, 0, 0, LABEL_HEIGHT + LAYOUT.ElementGap)
	clockLabel.Size = UDim2.new(1, 0, 0, CLOCK_HEIGHT)

	local row = newFrame(block, "Pips", COLOR.Panel, 1)
	row.AnchorPoint = Vector2.new(0.5, 1)
	row.Position = UDim2.new(0.5, 0, 1, 0)
	row.Size = UDim2.fromOffset(WAVE_COUNT * PIP_WIDTH + (WAVE_COUNT - 1) * LAYOUT.ElementGap, PIP_HEIGHT)

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, LAYOUT.ElementGap)
	layout.Parent = row

	for index = 1, WAVE_COUNT do
		local track = newFrame(row, "Pip" .. index, COLOR.Border, 0.3)
		track.LayoutOrder = index
		track.Size = UDim2.fromOffset(PIP_WIDTH, PIP_HEIGHT)

		local fill = newFrame(track, "Fill", COLOR.Accent, 0)
		fill.Size = UDim2.new(0, 0, 1, 0)

		pips[index] = { track = track, fill = fill }
	end
end

-- ── the countdown ───────────────────────────────────────────────────────────

local function buildCallout()
	callout = newFrame(root, "Countdown", COLOR.Panel, 1)
	callout.AnchorPoint = Vector2.new(0.5, 0.5)
	callout.Position = UDim2.fromScale(0.5, FOCUS_Y)
	callout.Size = UDim2.new(1, 0, 0, TEXT.Title + TEXT.Small + LAYOUT.ElementGap)
	callout.Visible = false

	calloutScale = Instance.new("UIScale")
	calloutScale.Parent = callout

	calloutCaption = newLabel(callout, "Caption", FONT.Heading, TEXT.Small, COLOR.TextSecondary)
	calloutCaption.Position = UDim2.fromOffset(0, 0)
	calloutCaption.Size = UDim2.new(1, 0, 0, TEXT.Small + LAYOUT.ElementGap)

	calloutNumber = newLabel(callout, "Seconds", FONT.Numeric, TEXT.Display, COLOR.Accent)
	calloutNumber.AnchorPoint = Vector2.new(0.5, 1)
	calloutNumber.Position = UDim2.new(0.5, 0, 1, 0)
	calloutNumber.Size = UDim2.new(1, 0, 0, TEXT.Title)
end

-- ── the announcement card ───────────────────────────────────────────────────

local function buildCard()
	card = newFrame(root, "Announcement", COLOR.Panel, 1)
	card.AnchorPoint = Vector2.new(0.5, 0.5)
	card.Position = UDim2.fromScale(0.5, FOCUS_Y)
	card.Size = UDim2.new(1, 0, 0, TEXT.Display + TEXT.Large + LAYOUT.ElementGap * 4)
	card.Visible = false

	cardScale = Instance.new("UIScale")
	cardScale.Parent = card

	--[[ "SOMETHING IS CALLING THEM" is twenty-five characters at Display size.
	     It fits a desktop frame and does not fit a phone, so the poster shrinks
	     to fit rather than running off both edges of the screen. ]]
	cardTitle = newLabel(card, "Title", FONT.Display, TEXT.Display, COLOR.TextPrimary)
	cardTitle.AnchorPoint = Vector2.new(0.5, 0.5)
	cardTitle.Position = UDim2.fromScale(0.5, 0.5)
	cardTitle.Size = UDim2.new(1, -LAYOUT.ScreenMargin * 2, 0, TEXT.Display + LAYOUT.ElementGap)
	cardTitle.TextScaled = true
	local titleBounds = Instance.new("UITextSizeConstraint")
	titleBounds.MaxTextSize = TEXT.Display
	titleBounds.MinTextSize = TEXT.Heading
	titleBounds.Parent = cardTitle

	cardSubtitle = newLabel(card, "Subtitle", FONT.Heading, TEXT.Large, COLOR.TextSecondary)
	cardSubtitle.AnchorPoint = Vector2.new(0.5, 1)
	cardSubtitle.Position = UDim2.new(0.5, 0, 1, 0)
	cardSubtitle.Size = UDim2.new(1, -LAYOUT.ScreenMargin * 2, 0, TEXT.Large + LAYOUT.ElementGap)
	cardSubtitle.TextScaled = true
	local subtitleBounds = Instance.new("UITextSizeConstraint")
	subtitleBounds.MaxTextSize = TEXT.Large
	subtitleBounds.MinTextSize = TEXT.Small
	subtitleBounds.Parent = cardSubtitle

	--[[ Two hairlines that wipe open around the title. They are the whole reason
	     the card reads as a printed poster rather than as a floating string, and
	     they cost two frames. ]]
	for _, anchor in { 0, 1 } do
		local rule = newFrame(card, "Rule", COLOR.Accent, 1)
		rule.AnchorPoint = Vector2.new(0.5, anchor)
		rule.Position = UDim2.new(0.5, 0, if anchor == 0 then 0 else 1, 0)
		rule.Size = UDim2.fromOffset(0, LAYOUT.BorderThickness)
		table.insert(cardRules, rule)
	end
end

local function build()
	gui = Instance.new("ScreenGui")
	gui.Name = "FL_Wave"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	--[[ One step above the HUD: the announcement card has to cover a HUD panel
	     rather than argue with it for the same layer, and the Overlay layer still
	     wins so an end-of-round card is never drawn under a wave poster. ]]
	gui.DisplayOrder = UITheme.DisplayOrder.Hud + 1
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = player:WaitForChild("PlayerGui")
	trove:add(gui)

	root = ScaleLayer.new(gui, "Scaled")

	buildBlock()
	buildCallout()
	buildCard()
end

-- ── state ───────────────────────────────────────────────────────────────────

--[[ How long the phase now running lasts, straight out of the schedule. The
     client knows the whole wave table, so the fraction of a phase already spent
     is arithmetic rather than another attribute. ]]
local function phaseDuration(): number
	if state.phase == PHASE.Prep then
		return PREP_DURATION
	end
	local wave = GameModeConfig.getWave(state.waveIndex)
	if state.phase == PHASE.Active then
		return wave.duration
	elseif state.phase == PHASE.Breather then
		return wave.breather
	end
	return 0
end

--[[
	Which pip is filling right now.

	During a wave it is that wave's own pip. During prep and during a breather it
	is the pip of the wave that is COMING, so the bar the player watches drain is
	always the one that ends with something walking through the door.
]]
local function activePipIndex(): number
	if state.phase == PHASE.Active then
		return math.clamp(state.waveIndex, 1, WAVE_COUNT)
	end
	return math.clamp(state.waveIndex + 1, 1, WAVE_COUNT)
end

local function refreshPips()
	local current = activePipIndex()
	local cleared = if state.phase == PHASE.Active then state.waveIndex - 1 else state.waveIndex

	for index, pip in pips do
		if index <= cleared then
			-- Done with. Still lit, because seeing four waves behind you is most
			-- of what makes the seventh one mean anything, but dimmed out of the
			-- way of the one that is running.
			pip.fill.BackgroundColor3 = COLOR.AccentDim
			pip.fill.Size = UDim2.new(1, 0, 1, 0)
		elseif index == current and state.active then
			-- Emptied here and filled by the frame loop, so a phase always starts
			-- its pip from zero rather than inheriting the last one's progress.
			pip.fill.BackgroundColor3 = COLOR.Accent
			pip.fill.Size = UDim2.new(0, 0, 1, 0)
		else
			pip.fill.Size = UDim2.new(0, 0, 1, 0)
		end
	end

	state.activeFill = if state.active and current > cleared then pips[current].fill else nil
	state.pipFill = -1
end

local function refresh()
	state.waveIndex = Attributes.get(Workspace, GA.WaveIndex, 0)
	state.phase = Attributes.get(Workspace, GA.WavePhase, PHASE.Over)
	state.waveEndsAt = Attributes.get(Workspace, GA.WaveEndsAt, 0)
	state.roundEndsAt = Attributes.get(Workspace, GA.RoundEndsAt, 0)

	-- A zero stamp is the lobby, not a round that ended a moment ago: everything
	-- here counts down to an absolute time, and there is nothing to count to.
	state.active = state.phase ~= PHASE.Over and state.roundEndsAt > 0
	state.phaseDuration = phaseDuration()

	block.Visible = state.active
	state.clockWhole = -1

	if state.phase == PHASE.Prep then
		waveLabel.Text = "PREPARE"
		waveLabel.TextColor3 = COLOR.TextSecondary
	elseif state.phase == PHASE.Breather then
		waveLabel.Text = string.format("WAVE %d CLEARED", state.waveIndex)
		waveLabel.TextColor3 = COLOR.Accent
	else
		waveLabel.Text = string.format("WAVE %d / %d", state.waveIndex, WAVE_COUNT)
		waveLabel.TextColor3 = COLOR.TextSecondary
	end

	refreshPips()
end

--[[ Cuts the countdown dead rather than fading it. Used when a card takes the
     focal point: a breather countdown reaching zero and the poster it was
     counting to are the same beat, and two things dissolving through each other
     in the middle of the frame is not a beat. ]]
local function hideCallout()
	state.calloutAlpha = 0
	state.calloutWhole = -1
	state.punch = 0
	calloutScale.Scale = 1
	callout.Visible = false
end

-- ── announcements ───────────────────────────────────────────────────────────

local function announce(title: string, subtitle: string, color: Color3)
	if title == "" then
		return
	end
	hideCallout()
	state.card = true
	state.cardPhase = "in"
	state.cardClock = 0

	cardTitle.Text = string.upper(title)
	cardTitle.TextColor3 = color
	cardSubtitle.Text = string.upper(subtitle)
	cardSubtitle.Visible = subtitle ~= ""
	card.Visible = true
end

local function hideCard()
	state.card = nil
	state.cardPhase = "idle"
	state.cardAlpha = 0
	card.Visible = false
end

local function updateCard(dt: number)
	if not state.card then
		return
	end

	state.cardClock += dt
	if state.cardPhase == "in" then
		state.cardAlpha = math.clamp(state.cardClock / MOTION.FastIn, 0, 1)
		if state.cardAlpha >= 1 then
			state.cardPhase = "hold"
			state.cardClock = 0
		end
	elseif state.cardPhase == "hold" then
		state.cardAlpha = 1
		if state.cardClock >= CARD_HOLD then
			state.cardPhase = "out"
			state.cardClock = 0
		end
	else
		state.cardAlpha = 1 - math.clamp(state.cardClock / MOTION.FastOut, 0, 1)
		if state.cardAlpha <= 0 then
			hideCard()
			return
		end
	end

	local fade = 1 - state.cardAlpha
	cardTitle.TextTransparency = fade
	cardSubtitle.TextTransparency = math.min(fade * 1.4, 1)
	cardScale.Scale = 1 + CARD_OVERSHOOT * fade
	for _, rule in cardRules do
		rule.BackgroundTransparency = fade
		rule.Size = UDim2.fromOffset(CARD_RULE_WIDTH * state.cardAlpha, LAYOUT.BorderThickness)
	end
end

--[[
	The wave that just started, or the breather that just began.

	Only the presentation is taken from this remote — the phase, the index and
	the deadline all come off the attributes, which are the authority. A boss
	wave announces in red because "TANK INBOUND" is the one wave announcement
	that is a warning rather than a title card, and GameModeConfig already knows
	which waves those are.
]]
local function onWaveChanged(payload: any)
	if typeof(payload) ~= "table" then
		return
	end
	local index = tonumber(payload.index) or 0
	if index <= 0 then
		return
	end

	if payload.isBreather == true then
		announce(string.format("WAVE %d CLEARED", index), "", COLOR.Accent)
		return
	end

	local wave = GameModeConfig.getWave(index)
	local dangerous = #wave.bosses > 0
	announce(
		tostring(payload.announcement or wave.announcement),
		string.format("WAVE %d OF %d — %s", index, WAVE_COUNT, tostring(payload.name or wave.name)),
		if dangerous then COLOR.Danger else COLOR.TextPrimary
	)
end

-- ── frame loop ──────────────────────────────────────────────────────────────

local function update(dt: number)
	updateCard(dt)

	local now = Workspace:GetServerTimeNow()
	local roundLeft = if state.active then math.max(state.roundEndsAt - now, 0) else 0
	local phaseLeft = if state.active then math.max(state.waveEndsAt - now, 0) else 0
	local finale = state.active
		and state.phase == PHASE.Active
		and state.waveIndex >= WAVE_COUNT
		and roundLeft <= FINALE_WINDOW

	if state.active then
		-- Ceil, so "0:01" means there is still time on the clock and 0:00 only
		-- ever shows at the moment the phase is genuinely over.
		local whole = math.ceil(roundLeft)
		if whole ~= state.clockWhole then
			state.clockWhole = whole
			clockLabel.Text = string.format("%d:%02d", whole // 60, whole % 60)
			clockLabel.TextColor3 = if finale then COLOR.Danger else COLOR.TextPrimary
		end

		local fill = state.activeFill
		if fill and state.phaseDuration > 0 then
			local spent = math.clamp(1 - phaseLeft / state.phaseDuration, 0, 1)
			if math.abs(spent - state.pipFill) > PIP_EPSILON then
				state.pipFill = spent
				fill.Size = UDim2.new(spent, 0, 1, 0)
			end
		end
	end

	--[[ The countdown owns the focal point, and it waits its turn: while the
	     WAVE CLEARED beat is still on screen there is nothing else in the middle
	     of the frame. ]]
	local wanted = state.active
		and state.card == nil
		and (state.phase == PHASE.Prep or state.phase == PHASE.Breather or finale)

	local target = if wanted then 1 else 0
	if state.calloutAlpha ~= target then
		local step = dt / MOTION.Normal
		state.calloutAlpha = if target > state.calloutAlpha
			then math.min(state.calloutAlpha + step, 1)
			else math.max(state.calloutAlpha - step, 0)
		local fade = 1 - state.calloutAlpha
		calloutNumber.TextTransparency = fade
		calloutCaption.TextTransparency = math.min(fade * 1.4, 1)
		callout.Visible = state.calloutAlpha > 0
		if not callout.Visible then
			-- Nothing is left mid-punch: the next countdown starts at rest.
			hideCallout()
		end
	end

	if not callout.Visible then
		return
	end

	local seconds = if finale then roundLeft else phaseLeft
	local whole = math.ceil(seconds)
	local tense = whole <= TENSION_WINDOW

	if whole ~= state.calloutWhole then
		state.calloutWhole = whole
		calloutNumber.Text = tostring(whole)
		-- Every tick lands, and lands harder once the window is closing. The
		-- number moving is what a player catches out of the corner of an eye
		-- while they are looking at a doorway.
		state.punch = 1

		local size = if finale or tense then TEXT.Title else TEXT.Display
		if size ~= state.calloutSize then
			state.calloutSize = size
			calloutNumber.TextSize = size
		end
		calloutNumber.TextColor3 = if finale
			then COLOR.Danger
			elseif tense then COLOR.AccentBright
			else COLOR.Accent

		local caption = if finale
			then "HOLD"
			elseif tense then "BRACE"
			elseif state.phase == PHASE.Prep then "FIRST WAVE IN"
			else "NEXT WAVE IN"
		if caption ~= state.captionText then
			state.captionText = caption
			calloutCaption.Text = caption
			calloutCaption.TextColor3 = if finale then COLOR.Danger else COLOR.TextSecondary
		end
	end

	if state.punch > 0 then
		state.punch = math.max(state.punch - dt / PUNCH_DECAY, 0)
		calloutScale.Scale = 1 + state.punch * (if tense or finale then PUNCH_TENSE else PUNCH_CALM)
	end
end

-- ── public API ──────────────────────────────────────────────────────────────

--[[ How much room the block takes off the top of the screen. HudController
     drops its objective line below whatever this returns, so the two never
     stack on top of each other at the same margin. ]]
function WaveController:getReservedTopHeight(): number
	return LAYOUT.ScreenMargin + BLOCK_HEIGHT
end

function WaveController:getWaveIndex(): number
	return state.waveIndex
end

function WaveController:getPhase(): string
	return state.phase
end

function WaveController:isBreather(): boolean
	return state.phase == PHASE.Breather
end

--[[ Seconds left in the whole round, and in the phase running right now. Both
     are derived from the same absolute stamps the block renders, so anything
     asking gets exactly what the player is looking at. ]]
function WaveController:getTimeRemaining(): number
	if not state.active then
		return 0
	end
	return math.max(state.roundEndsAt - Workspace:GetServerTimeNow(), 0)
end

function WaveController:getWaveTimeRemaining(): number
	if not state.active then
		return 0
	end
	return math.max(state.waveEndsAt - Workspace:GetServerTimeNow(), 0)
end

function WaveController:setVisible(value: boolean)
	state.visible = value
	if gui then
		gui.Enabled = value and not state.cinematic
	end
end

--[[ The end-of-round cards take the whole frame; a wave clock counting down
     under one reads as a bug. OverlayController pushes this. ]]
function WaveController:setCinematic(value: boolean)
	state.cinematic = value
	if gui then
		gui.Enabled = state.visible and not value
	end
	if value then
		hideCard()
	end
end

-- ── lifecycle ───────────────────────────────────────────────────────────────

function WaveController:init()
	build()
	refresh()

	for _, attribute in { GA.WaveIndex, GA.WavePhase, GA.WaveEndsAt, GA.RoundEndsAt } do
		trove:connect(Workspace:GetAttributeChangedSignal(attribute), refresh)
	end
end

function WaveController:start()
	trove:connect(Remotes.Event.WaveChanged.OnClientEvent, onWaveChanged)
	trove:connect(RunService.RenderStepped, update)

	-- The HUD was laid out before this block existed, so it is told rather than
	-- asked: it has no reason to know what a wave is.
	local hud = Registry.find("HudController")
	if hud and typeof(hud.setTopInset) == "function" then
		pcall(hud.setTopInset, hud, self:getReservedTopHeight())
	end
end

--[[ Attributes only fire their changed signal on the NEXT write, so a player
     dropping into wave 5 has to read them once on the way in or they see a
     blank block until the breather. ]]
function WaveController:onInitialState(_payload: any)
	refresh()
end

function WaveController:destroy()
	trove:destroy()
end

Registry.register("WaveController", WaveController)

return WaveController
