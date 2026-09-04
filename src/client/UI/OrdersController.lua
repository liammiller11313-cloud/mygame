--!nonstrict
--[[
	OrdersController — your level and today's orders, without leaving the round.

	── WHY THIS EXISTS ──────────────────────────────────────────────────────────
	PauseController's own comment already made the argument: today's orders are
	things you do DURING a round. "Revive four teammates" is a decision you make
	at wave three, not one you plan in a menu, and a player who has to pause the
	game to find out they are on three of four has a quest system that is not
	part of the game.

	Everything about progression lived somewhere the round is not — the CAREER
	panel to look at it, the award card once it is over. This is the part that is
	on screen while it is being earned.

	── WHAT IT DRAWS AND WHAT IT DELIBERATELY DOES NOT ──────────────────────────
	Level, the bar into the next one, Scrip, and the three orders with a live
	count. It does not draw the battle pass: a track you claim between rounds is
	not something a player acts on with a horde on them, and the card is small
	because a corner of a shooter is not a menu.

	The XP bar does not move during a round, and that is correct rather than
	broken — ProgressionService commits XP once, at the end. What moves is the
	ORDERS, which ProgressionController computes live from StatsUpdated. So the
	bar is context and the orders are the reason to look.

	── IT IS QUIET UNTIL SOMETHING HAPPENS ──────────────────────────────────────
	A permanent bright block in the corner of a horde shooter is noise for the
	fifteen minutes nothing is happening to it. This sits dim, and brightens for
	a couple of seconds when an order actually advances — which is the only
	moment the information is worth a player's attention. See `pulse`.

	── AND IT IS NOT THE CAREER PANEL ───────────────────────────────────────────
	It reads ProgressionController exactly like every other screen and decides
	nothing. No claim button, no worn-title picker, no quest that can be finished
	from here. Anything a player wants to DO with their progression is still one
	pause away, where there is room to think about it.
]]

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attributes = require(Shared.Net.Attributes)
local Enums = require(Shared.Enums)
local ProgressionConfig = require(Shared.Config.ProgressionConfig)
local Registry = require(Shared.Util.Registry)
local Trove = require(Shared.Util.Trove)
local UITheme = require(Shared.Config.UITheme)

local ScaleLayer = require(script.Parent.ScaleLayer)
local Widgets = require(script.Parent.Widgets)

local COLOR = UITheme.Color
local FONT = UITheme.Font
local LAYOUT = UITheme.Layout
local TEXT = UITheme.TextSize

local GA = Attributes.Game
local ROUND = Enums.RoundState

local player = Players.LocalPlayer

--[[ Top-left, which is the one corner of the HUD nothing else claims: the
     survivor panels and the ability cards are bottom-left, the kill feed is
     top-right, the hotbar and the wallet are bottom-right, and the wave banner
     owns the centre. ]]
local CARD_WIDTH = 208

--[[
	Air between Roblox's own chrome and the top of this card.

	The card is in the top-left corner and so is Roblox's unibar — the logo
	button, the chat toggle, the party icons — and the HUD's ScreenGuis all set
	IgnoreGuiInset, which is right for a crosshair and a vignette and wrong for
	the one element that lives exactly where the platform draws its own.

	So this element, alone, puts the inset back. GetGuiInset is asked at build
	and again on every resize rather than hard-coded, because the answer is not a
	constant: it is taller on a phone with a notch than on a desktop, and Roblox
	has changed it more than once. The extra few pixels on top of it are so the
	card sits UNDER the chrome rather than flush against it.
]]
local TOP_BAR_GAP = 6

local LEVEL_HEIGHT = 18
local BAR_HEIGHT = 4
local ORDER_HEIGHT = 26
local ORDER_GAP = 3

--[[
	How faded the card sits when nothing is happening to it, and how solid it
	goes when something is. The gap between the two is the whole design — see
	the header.

	These are GroupTransparency on a CanvasGroup, not BackgroundTransparency on
	a Frame, and that is load-bearing rather than a preference: a Frame's
	transparency does not touch its children, so fading one would have left the
	panel behind the text disappearing while the text itself stayed at full
	strength. A CanvasGroup composites the whole card and then fades the result,
	which is the only way the numbers go quiet with the box they sit in.
]]
--[[ Idle was 0.55, which reads beautifully against the inside of a building and
     not at all against the sky. Clinton's street is bright cloud for most of its
     height and the card sat on top of it at 45% — three order lines in dim grey
     over white. Raised until it survives the worst background in the game, which
     is the only background worth tuning it against; the gap to LIVE is still
     wide enough to see the card answer you. ]]
local IDLE_TRANSPARENCY = 0.42
local LIVE_TRANSPARENCY = 0.0
local PULSE_SECONDS = 2.2
local FADE_SECONDS = 0.5

--[[ The panel's own backing, which the group transparency is applied on top of.
     Constant: it is the card's weight relative to its contents, and that ratio
     should not change when the card brightens.

     Darker than it was, for the same reason as above: the backing is what gives
     the text something that is not sky to sit on, and at 0.3 under a 0.55 group
     fade there was effectively nothing there. ]]
local CARD_TRANSPARENCY = 0.2

--[[
	Where the card sits, in the scaled layer's reference pixels.

	Roblox's inset arrives in REAL pixels and everything inside a ScaleLayer is
	in reference pixels, so it has to be divided by the factor before it can be
	added to a margin — adding the two spaces together is how a card ends up
	correctly placed on a desktop and half a topbar too high on a phone.
]]
local function cardPosition(): UDim2
	local inset = GuiService:GetGuiInset()
	local factor = math.max(ScaleLayer.getFactor(), 0.01)
	local top = LAYOUT.ScreenMargin + inset.Y / factor + TOP_BAR_GAP
	return UDim2.fromOffset(LAYOUT.ScreenMargin, math.floor(top + 0.5))
end

local OrdersController = {}

local trove = Trove.new()

local gui: ScreenGui
--[[ A CanvasGroup rather than a Frame, so one property fades the whole card and
     everything drawn in it together. See IDLE_TRANSPARENCY. ]]
local card: CanvasGroup
local levelLabel: TextLabel
local scripLabel: TextLabel
local barFill: Frame

type Row = {
	frame: Frame,
	text: TextLabel,
	count: TextLabel,
	fill: Frame,
}
local rows: { Row } = {}

local state = {
	--[[ The progress last drawn for each order, so a pulse fires on the CHANGE
	     rather than on every refresh. Keyed by quest id: the three quests rotate
	     daily and an index would pulse the wrong row across midnight. ]]
	shown = {} :: { [string]: number },
	--[[ Absolute clock the current pulse fades at, or 0. One timer for the whole
	     card rather than one per row: three orders advancing in the same second
	     is one thing happening, not three. ]]
	brightUntil = 0,
	visible = false,
	--[[ The player's own answer to SettingsConfig `showOrders`. Kept apart from
	     `visible`, which is about whether a round is running: both have to be
	     true, and collapsing them into one boolean is how a HUD element ends up
	     switched off by a round ending. ]]
	allowed = true,
}

-- ── helpers ─────────────────────────────────────────────────────────────────

local function progression(): any
	return Registry.find("ProgressionController")
end

--[[ Whether a round is actually being played. The card is for the round, so it
     is not on screen in the lobby — the main menu is what a player is looking
     at then, and it has a CAREER entry of its own. ]]
local function inRound(): boolean
	local round = Attributes.get(Workspace, GA.RoundState, ROUND.Lobby)
	return round == ROUND.InProgress or round == ROUND.Starting
end

--[[ Brightens the card and sets it to fade again. Called when an order moves
     and on nothing else: a pulse for a thing the player did not do teaches them
     to stop looking. ]]
local function pulse()
	state.brightUntil = os.clock() + PULSE_SECONDS
	TweenService:Create(card, TweenInfo.new(0.12), { GroupTransparency = LIVE_TRANSPARENCY }):Play()
end

local function dim()
	state.brightUntil = 0
	TweenService:Create(card, TweenInfo.new(FADE_SECONDS), { GroupTransparency = IDLE_TRANSPARENCY }):Play()
end

-- ── drawing ─────────────────────────────────────────────────────────────────

local function refresh()
	local store = progression()
	local ready = store ~= nil and typeof(store.isReady) == "function" and store:isReady()

	--[[ Nothing until the profile has landed. A card reading LEVEL 0 for the
	     first two seconds of a round is a card that lies before it tells the
	     truth. ]]
	local wanted = state.allowed and ready and inRound()
	if wanted ~= state.visible then
		state.visible = wanted
		gui.Enabled = wanted
	end
	if not wanted then
		return
	end

	local level, into, cost = store:getLevelProgress()
	levelLabel.Text = string.format("LEVEL %d", level)
	--[[ Clamped, not asserted. `cost` is zero at the top of the track and a bar
	     that divided by it would be a full-screen error over a firefight. ]]
	barFill.Size = UDim2.fromScale(if cost > 0 then math.clamp(into / cost, 0, 1) else 1, 1)
	scripLabel.Text = string.format("%s %d", ProgressionConfig.CurrencySymbol, store:getScrip())

	local views = store:questView()
	local advanced = false
	for index, row in rows do
		local view = views[index]
		row.frame.Visible = view ~= nil
		if not view then
			continue
		end
		local quest = view.quest
		row.text.Text = string.upper(quest.text)
		row.count.Text = if view.complete
			then "DONE"
			else string.format("%d / %d", view.progress, quest.target)
		row.count.TextColor3 = if view.complete
			then COLOR.HealthGood
			elseif view.pending then COLOR.AccentBright
			else COLOR.TextDim
		row.fill.Size = UDim2.fromScale(math.clamp(view.progress / math.max(quest.target, 1), 0, 1), 1)
		row.fill.BackgroundColor3 = if view.complete then COLOR.HealthGood else COLOR.Accent
		row.text.TextColor3 = if view.complete then COLOR.TextDim else COLOR.TextSecondary

		--[[ The pulse fires on an order that MOVED, and the first draw of a
		     round is not a move: `shown` starts empty, so the initial pass
		     records every number without lighting anything up. ]]
		local previous = state.shown[quest.id]
		if previous ~= nil and view.progress > previous then
			advanced = true
		end
		state.shown[quest.id] = view.progress
	end

	if advanced then
		pulse()
	end
end

--[[ The only per-frame work here, and it does nothing on all but one frame in
     a couple of hundred: it exists to end a pulse. A tween cannot schedule its
     own reversal without a second tween that would fight the first if two
     orders advanced a second apart. ]]
local function step()
	if state.brightUntil > 0 and os.clock() >= state.brightUntil then
		dim()
	end
end

-- ── build ───────────────────────────────────────────────────────────────────

local function buildRow(parent: Instance, index: number)
	local frame = Widgets.frame(parent, "Order" .. index, COLOR.Background, 1)
	frame.LayoutOrder = index
	frame.Size = UDim2.new(1, 0, 0, ORDER_HEIGHT)
	frame.Visible = false

	local text = Widgets.label(frame, "Text", FONT.Body, TEXT.Tiny, COLOR.TextSecondary)
	text.Position = UDim2.fromOffset(0, 0)
	text.Size = UDim2.new(1, -52, 0, TEXT.Tiny + 2)
	text.TextTruncate = Enum.TextTruncate.AtEnd

	local count = Widgets.label(frame, "Count", FONT.Numeric, TEXT.Tiny, COLOR.TextDim)
	count.AnchorPoint = Vector2.new(1, 0)
	count.Position = UDim2.new(1, 0, 0, 0)
	count.Size = UDim2.fromOffset(50, TEXT.Tiny + 2)
	count.TextXAlignment = Enum.TextXAlignment.Right

	local track = Widgets.frame(frame, "Track", COLOR.Background, 0.35)
	track.AnchorPoint = Vector2.new(0, 1)
	track.Position = UDim2.new(0, 0, 1, -4)
	track.Size = UDim2.new(1, 0, 0, BAR_HEIGHT - 1)

	local fill = Widgets.frame(track, "Fill", COLOR.Accent, 0)
	fill.Size = UDim2.fromScale(0, 1)

	rows[index] = { frame = frame, text = text, count = count, fill = fill }
end

local function build()
	gui = Instance.new("ScreenGui")
	gui.Name = "FL_Orders"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = UITheme.DisplayOrder.Hud
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Enabled = false
	gui.Parent = player:WaitForChild("PlayerGui")
	trove:add(gui)

	local layer = ScaleLayer.new(gui, "Scaled")

	card = Instance.new("CanvasGroup")
	card.Name = "Card"
	card.BackgroundColor3 = COLOR.Panel
	card.BackgroundTransparency = CARD_TRANSPARENCY
	card.BorderSizePixel = 0
	card.GroupTransparency = IDLE_TRANSPARENCY
	card.Position = cardPosition()
	--[[ Height is the header plus three orders, written out of the same numbers
	     the rows are built from rather than typed — the last three times a row
	     changed shape in this project, a hand-written parent height did not. ]]
	card.Size = UDim2.fromOffset(
		CARD_WIDTH,
		LAYOUT.PanelPadding * 2
			+ LEVEL_HEIGHT
			+ BAR_HEIGHT
			+ LAYOUT.ElementGap
			+ ProgressionConfig.DailyQuests * (ORDER_HEIGHT + ORDER_GAP)
	)

	card.Parent = layer
	--[[ Inside the group, so the outline fades with everything else. A card with
	     a permanent hard edge is a card that stays loud however faded its
	     contents are. ]]
	Widgets.stroke(card, COLOR.Border)

	local inner = Widgets.frame(card, "Inner", COLOR.Panel, 1)
	inner.Position = UDim2.fromOffset(LAYOUT.PanelPadding, LAYOUT.PanelPadding)
	inner.Size = UDim2.new(1, -LAYOUT.PanelPadding * 2, 1, -LAYOUT.PanelPadding * 2)

	levelLabel = Widgets.label(inner, "Level", FONT.Heading, TEXT.Small, COLOR.TextPrimary)
	levelLabel.Size = UDim2.new(1, -60, 0, LEVEL_HEIGHT)

	scripLabel = Widgets.label(inner, "Scrip", FONT.Numeric, TEXT.Tiny, COLOR.Accent)
	scripLabel.AnchorPoint = Vector2.new(1, 0)
	scripLabel.Position = UDim2.new(1, 0, 0, 2)
	scripLabel.Size = UDim2.fromOffset(58, LEVEL_HEIGHT)
	scripLabel.TextXAlignment = Enum.TextXAlignment.Right

	local barTrack = Widgets.frame(inner, "Bar", COLOR.Background, 0.35)
	barTrack.Position = UDim2.fromOffset(0, LEVEL_HEIGHT)
	barTrack.Size = UDim2.new(1, 0, 0, BAR_HEIGHT)

	barFill = Widgets.frame(barTrack, "Fill", COLOR.AccentBright, 0)
	barFill.Size = UDim2.fromScale(0, 1)

	--[[ The orders sit under the bar in their own laid-out column, so adding a
	     fourth daily quest is a config change rather than three more offsets. ]]
	local column = Widgets.frame(inner, "Orders", COLOR.Panel, 1)
	column.Position = UDim2.fromOffset(0, LEVEL_HEIGHT + BAR_HEIGHT + LAYOUT.ElementGap)
	column.Size = UDim2.new(1, 0, 1, -(LEVEL_HEIGHT + BAR_HEIGHT + LAYOUT.ElementGap))
	Widgets.list(column, ORDER_GAP)

	for index = 1, ProgressionConfig.DailyQuests do
		buildRow(column, index)
	end
end

-- ── public ──────────────────────────────────────────────────────────────────

--[[
	The player's switch, from SettingsConfig `showOrders`.

	Applied at boot as well as on every change — SettingsController pushes every
	definition once at start — so a player who turned this off on their last
	server never sees it here.

	A hidden card is not kept up to date: `refresh` stops at the visibility test,
	because three labels nobody is looking at are three labels not worth
	redrawing. It is fully redrawn on the way back IN, which is the only moment
	its contents have to be right.

	Coming back on clears the pulse memory for the same reason a round starting
	does. The orders may well have advanced while the card was away, and lighting
	it up for progress the player made ten minutes ago would be announcing old
	news as though it had just happened.
]]
function OrdersController:setEnabled(value: boolean)
	local wanted = value == true
	if state.allowed == wanted then
		return
	end
	state.allowed = wanted
	if wanted then
		table.clear(state.shown)
	end
	refresh()
end

function OrdersController:isEnabled(): boolean
	return state.allowed
end

-- ── lifecycle ───────────────────────────────────────────────────────────────

function OrdersController:init()
	build()
end

function OrdersController:start()
	--[[ Re-placed on both of the things that can move it. The viewport changing
	     changes the ScaleLayer factor the inset is divided by; the inset itself
	     changes when Roblox's own chrome does, which it does on a phone rotating
	     and has done between engine versions. Neither is frequent and both leave
	     the card sitting under the platform's buttons if nothing listens. ]]
	local function replace()
		if card then
			card.Position = cardPosition()
		end
	end
	local camera = Workspace.CurrentCamera
	if camera then
		trove:connect(camera:GetPropertyChangedSignal("ViewportSize"), replace)
	end
	--[[ Guarded because TopbarInset is a property Roblox added, and asking for a
	     changed signal on a name the running engine does not have throws. The
	     card is placed correctly at build with or without this; the signal only
	     keeps it correct when the platform's own chrome resizes underneath it, so
	     losing it costs a re-place and not the controller. ]]
	local ok, signal = pcall(function()
		return GuiService:GetPropertyChangedSignal("TopbarInset")
	end)
	if ok and signal then
		trove:connect(signal, replace)
	end

	--[[ Everything this draws is a mirror with a signal, so it redraws on the
	     change rather than on a clock. `changed` covers a sync, a level, a Scrip
	     spend and — through StatsUpdated — an order advancing. ]]
	local store = progression()
	if store and store.changed then
		trove:add(store.changed:connect(refresh))
	end

	--[[ Rounds starting and ending are what put it on screen and take it off,
	     and the orders are cleared with the round: last round's counters are not
	     this round's, and `shown` holding them would swallow the first pulse of
	     the next one. ]]
	trove:connect(Workspace:GetAttributeChangedSignal(GA.RoundState), function()
		if not inRound() then
			table.clear(state.shown)
			state.brightUntil = 0
			card.GroupTransparency = IDLE_TRANSPARENCY
		end
		refresh()
	end)

	trove:connect(RunService.Heartbeat, step)
	refresh()
end

function OrdersController:destroy()
	trove:destroy()
	table.clear(rows)
	table.clear(state.shown)
end

Registry.register("OrdersController", OrdersController)

return OrdersController
