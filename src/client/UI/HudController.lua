--!nonstrict
--[[
	HudController — the whole heads-up display, and deliberately not much of it.

	Four things live on screen permanently: the survivor panels bottom-left, the
	ammo counter bottom-right, three item slots along the bottom edge, and the
	objective line at the top. Everything else — the kill feed — appears only
	when it has something to say and then leaves. There is no minimap, no XP bar
	and no border art, and that absence is the design, not an omission.

	The top of the screen is shared: WaveController owns the round clock and the
	wave pips up there and pushes its height down here through setTopInset, so
	the objective line sits under the block instead of through it.

	── THE TWO-LAYER HEALTH BAR ────────────────────────────────────────────────
	The single most recognisable element of the L4D HUD. Permanent health fills
	the bar; temporary (pill / adrenaline / revive) health is a lighter segment
	stacked on top of it, so a player can see at a glance that a teammate looks
	healthy but is actually running on a buffer that is draining away. The colour
	ramp follows TOTAL health — that is what makes swallowing pills visibly pull
	somebody out of the red — while the permanent segment's LENGTH stays honest
	about what is really there.

	── WHERE THE DATA COMES FROM ───────────────────────────────────────────────
	Attributes and their changed signals, with one exception. Nothing here polls
	a value, and nothing here asks a service for state it could read off a
	Player. Attributes replicate on write, so a HUD driven by them costs zero
	bandwidth while nothing is happening, which during a breather and most of a
	wave is most of the time.

	The exception is the magazine of the gun actually in the player's hands.
	WeaponController predicts that count down on the frame the trigger goes and
	reconciles itself against the server afterwards; the attribute only moves
	once the server has answered. Drawing the attribute would put the one number
	that has to change at the same instant as the muzzle flash a full round trip
	behind it. So the counter and the hotbar ask WeaponController for the held
	slot and repaint on its ammoChanged, and everything else — every other slot,
	every other player, the reserve for a gun that is stowed — still comes from
	attributes. Note that this is invisible in Studio: a local server has no
	round trip, so the attribute-only version looked perfect right up until it
	shipped.

	── EVERYTHING IS DRAWN IN REFERENCE PIXELS ─────────────────────────────────
	Every offset in this file is chosen against a 900px-tall viewport and drawn
	inside a ScaleLayer, so it holds its proportions from a phone to a 4K
	display. Parent new elements to `root`, never to `gui`. The pixel inset
	WaveController pushes in through setTopInset is in the same space, which is
	the only reason the two agree about where the top of the screen ends.

	── PERFORMANCE ─────────────────────────────────────────────────────────────
	One RenderStepped connection for the entire HUD. Bars chase their targets in
	that loop rather than each spawning a Tween: during a horde, health changes
	arrive in a stream and tweens would queue up behind each other and lag the
	bar behind the truth. Nothing in the loop allocates unless a value actually
	moved.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attributes = require(Shared.Net.Attributes)
local EconomyConfig = require(Shared.Config.EconomyConfig)
local Enums = require(Shared.Enums)
local GameConfig = require(Shared.Config.GameConfig)
local InfectedConfig = require(Shared.Config.InfectedConfig)
local Registry = require(Shared.Util.Registry)
local Remotes = require(Shared.Net.Remotes)
local Trove = require(Shared.Util.Trove)
local UITheme = require(Shared.Config.UITheme)
local WeaponConfig = require(Shared.Config.WeaponConfig)

local ScaleLayer = require(script.Parent.ScaleLayer)
local Widgets = require(script.Parent.Widgets)

local COLOR = UITheme.Color
local FONT = UITheme.Font
local LAYOUT = UITheme.Layout
local MOTION = UITheme.Motion
local TEXT = UITheme.TextSize

local GA = Attributes.Game
local LA = Attributes.Loadout
local PA = Attributes.Player
local SLOT = Enums.Slot
local STATE = Enums.SurvivorState

local MAX_HEALTH = GameConfig.Survivor.MaxHealth
local MAX_SURVIVORS = GameConfig.MaxSurvivors

--[[ Bars chase their target at this rate. Fast enough that a hit reads as
     instant, slow enough that the eye catches the direction it moved. ]]
local BAR_CHASE_SPEED = 16
local BAR_EPSILON = 0.0015

--[[ A magazine below this fraction turns red. Not a balance number — it is the
     point at which the player should be thinking about cover, not arithmetic. ]]
local LOW_AMMO_FRACTION = 0.25

--[[ Room for "/ 426", the widest reserve in the roster, at TextSize.Large. The
     magazine count takes whatever is left of the panel. ]]
local RESERVE_WIDTH = 62

--[[
	The feed carried survivor deaths only — a handful in a whole round. It now
	carries infected kills too, and those arrive in bursts of a dozen, so every
	number here exists to keep it bounded and readable under load:

	  MAX       lines worth reading at once. Past this the oldest is pushed into
	            its fade rather than deleted under the eye, so the list visibly
	            drains instead of flickering.
	  HARD_MAX  rows that physically exist. They are pooled and recycled, so a
	            wave of kills never means a wave of Instance.new.
]]
--[[ How far the survivor stack lifts off the bottom-left corner on a touch
     device. Roblox's movement thumbstick lives there — the dynamic one follows
     the finger anywhere in the left half — and the four survivor bars were being
     drawn underneath it. Nothing is broken by the overlap, since the panels are
     read-only, but a thumb and a joystick sitting on top of the one piece of
     information you check constantly is not a HUD. ]]
local THUMBSTICK_INSET = 200

--[[ Fewer kill feed rows on a phone. Seven rows of churn during a horde is a
     third of a handset's height moving in the corner of your eye, and the feed
     is the least load-bearing thing on the screen. ]]
local TOUCH_FEED_LIMIT = 4

local KILLFEED_MAX = 5
local KILLFEED_HARD_MAX = KILLFEED_MAX + 2
local KILLFEED_LIFETIME = 5.0
local KILLFEED_FADE = 0.6
local KILLFEED_ROW_HEIGHT = 18
local KILLFEED_WIDTH = 380

--[[ Kill feed victims arrive as display names, not enum keys, so this maps one
     back to the definition that can say whether the thing that just died was a
     Common or a Tank. Built once: the roster is six entries. ]]
local INFECTED_BY_NAME: { [string]: any } = {}
for _, definition in InfectedConfig.all() do
	INFECTED_BY_NAME[definition.displayName] = definition
end

-- The identity stripe down the left edge of a survivor panel.
local STRIPE_WIDTH = 3

-- Two bars rotated to the panel's own diagonal, which is what makes the X read
-- as "this slot is struck out" rather than as a decorative cross.
local DEAD_X_ANGLE = math.deg(math.atan2(LAYOUT.SurvivorPanelHeight, LAYOUT.SurvivorPanelWidth))

--[[
	The hotbar, in Left 4 Dead's order: what you shoot with, what you fall back
	to, and the three things that save you. Weapon slots carry their own ammo,
	because in a firefight the question is never "how much do I have" in the
	abstract — it is "can I finish this magazine or do I switch".

	Six slots. Every tile draws its OWN key glyph, so the order here is about what
	reads well — the three weapons together, then the three things that save you —
	rather than about matching the number row. Melee is deliberately third and
	deliberately not on a number: it has a key of its own (V) because it is a
	weapon you dip into and come back from, not one of the five you cycle.
]]
local HOTBAR_SLOTS = { SLOT.Primary, SLOT.Secondary, SLOT.Melee, SLOT.Throwable, SLOT.Health, SLOT.Pills }
local WEAPON_SLOTS = { [SLOT.Primary] = true, [SLOT.Secondary] = true, [SLOT.Melee] = true }

--[[ What a slot is called when it is empty. Naming the empty slot rather than
     blanking it is what tells a new player the slot exists at all. ]]
local SLOT_TITLE = {
	[SLOT.Primary] = "PRIMARY",
	[SLOT.Secondary] = "SIDEARM",
	[SLOT.Melee] = "MELEE",
	[SLOT.Throwable] = "THROWABLE",
	[SLOT.Health] = "HEALTH",
	[SLOT.Pills] = "PILLS",
}

-- Wider than they are tall: a weapon name and an ammo count have to fit.
-- In the theme, not here: TouchController lays the on-screen pad out above the
-- hotbar and needs the same numbers. See UITheme.Layout.
--[[ The lit bar under the selected tile. Three pixels: thick enough to read at
     the edge of vision, thin enough that it is an underline rather than a second
     panel. ]]
local HOTBAR_MARKER_HEIGHT = 3

--[[ Where a notice sits, as a fraction of screen height. Just above the middle:
     high enough not to sit on the crosshair, low enough to be inside the cone a
     player is actually looking at. ]]
local NOTICE_Y = 0.42
local NOTICE_SECONDS = 2.2
local NOTICE_FADE = 0.5

--[[
	"+$4", when something dies.

	BELOW the crosshair, where the notice is above it: the two are the only
	things that appear in the middle of the screen and a player being warned
	about friendly fire while collecting money should be able to read both.

	It drifts up and fades, which is the oldest trick in the genre and works for
	the reason it always has — motion in the periphery is noticed without being
	looked at, and a number that merely appeared would have to be read.

	The amount comes from the BALANCE moving rather than from any remote. Kills
	pay three hundred times a round and a remote per kill to say "+2" would be
	the noisiest thing in the game; ProfileController subtracts two attribute
	values instead. That also means this covers the round bonus, and anything
	else the server ever pays, without either of them knowing it exists.
]]
local EARN_Y = 0.565
local EARN_SECONDS = 1.1
local EARN_RISE = 26 -- reference pixels it travels before it is gone
--[[ Two kills a second is normal in a horde and eight is possible. A pool of
     six is enough that a burst reads as several numbers rather than one
     flickering label, and small enough to cost nothing. ]]
local EARN_POOL = 6
--[[ Payments closer together than this merge into the newest number. Four
     Commons killed by one shotgun blast is ONE event to the player, and four
     "+$2"s climbing over each other is noise where "+$8" is the same
     information read in a glance. ]]
local EARN_MERGE_WINDOW = 0.35

--[[
	The balance, in the corner, all round.

	The "+$4" above is the EVENT; this is the STATE. Both are needed and for
	different reasons: the floating number says something just happened and is
	gone in a second, and a player deciding whether to push for one more wave or
	call the round wants the total, which no amount of watching popups gives you.

	It sits above the ammo counter rather than anywhere else because that corner
	is already where this interface keeps the numbers you spend, and because it
	is the corner the eye visits between fights rather than during one. It is
	deliberately quieter than the ammo count — dimmer, smaller, no panel of its
	own — since money is never the thing that kills you.
]]
local WALLET_HEIGHT = LAYOUT.WalletHeight
--[[ How long the balance stays lit after it moves. Long enough to notice out of
     the corner of the eye, short enough that a horde does not leave it glowing
     permanently. ]]
local WALLET_FLASH = 0.8

local HOTBAR_SLOT_WIDTH = LAYOUT.HotbarSlotWidth
local HOTBAR_SLOT_HEIGHT = LAYOUT.HotbarSlotHeight

local HudController = {}

local player = Players.LocalPlayer
local trove = Trove.new()

local gui: ScreenGui
--[[ Everything the HUD draws hangs off this, not off the ScreenGui. It is the
     viewport scale layer: the whole HUD is laid out in 900px-tall reference
     pixels and the layer is what turns those into the player's actual screen.
     See Client/UI/ScaleLayer. ]]
local root: Frame
local panelHolder: Frame
local ammo: {
	panel: Frame,
	name: TextLabel,
	mag: TextLabel,
	reserve: TextLabel,
	reloading: TextLabel,
	reloadBar: Frame,
	reloadFill: Frame,
}
--[[ Kept exhaustive on purpose. An entry that carries a field this type does
     not mention is a field refreshItems can silently read as nil, which is
     precisely how the ammo counts froze once already. ]]
local itemSlots: {
	[string]: {
		frame: Frame,
		key: TextLabel,
		label: TextLabel,
		count: TextLabel,
		marker: Frame,
		stroke: UIStroke,
		tap: TextButton,
	},
} =
	{}
local objective: { frame: Frame, label: TextLabel, bar: Frame, fill: Frame }
local notice: { label: TextLabel, until_: number }
local earnLabels: { { label: TextLabel, until_: number, amount: number } } = {}
local earnCursor = 0
local wallet: { label: TextLabel, litUntil: number }? = nil
local hotbarHolder: Frame? = nil
local killFeedHolder: Frame

local panels: { [Player]: any } = {}
local slotIndices: { [Player]: number } = {}
local killFeed: { { label: TextLabel, age: number } } = {}
local killFeedPool: { TextLabel } = {}
-- UIListLayout ties on equal LayoutOrder, so entries carry a running number and
-- the newest kill is always the bottom line.
local killFeedOrder = 0

local state = {
	visible = true,
	cinematic = false,
	reloading = false,
	--[[ An empty gun is not the same message as a nearly-empty one, and at a
	     glance a red 0 and a red 3 look identical. The zero pulses; the low
	     count sits still. Set by refreshAmmo, read by the frame loop. ]]
	ammoEmpty = false,
	objectiveText = "",
	-- How much of the top of the screen WaveController has claimed. Pushed in
	-- rather than read, so the HUD needs to know nothing about waves.
	topInset = LAYOUT.ScreenMargin,
	--[[ Set from InputController's scheme. The HUD is the same HUD on every
	     device; this only moves things out from under the controls a touchscreen
	     adds and drops the decoration a 390px-tall screen has no room for. ]]
	touch = false,
}

-- ── construction helpers ────────────────────────────────────────────────────

local function corner(instance: Instance)
	local shape = Instance.new("UICorner")
	shape.CornerRadius = UDim.new(0, LAYOUT.CornerRadius)
	shape.Parent = instance
end

local function stroke(instance: Instance, color: Color3?): UIStroke
	local line = Instance.new("UIStroke")
	line.Color = color or COLOR.Border
	line.Thickness = LAYOUT.BorderThickness
	line.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	line.Parent = instance
	return line
end

--[[ Rec. 601 luma. A flat channel average turns the blue survivor into mud and
     the green one into paper, which defeats the point of desaturating. ]]
local function desaturate(color: Color3): Color3
	local luma = color.R * 0.299 + color.G * 0.587 + color.B * 0.114
	return Color3.new(luma, luma, luma)
end

local function hex(color: Color3): string
	return string.format(
		"#%02X%02X%02X",
		math.floor(color.R * 255 + 0.5),
		math.floor(color.G * 255 + 0.5),
		math.floor(color.B * 255 + 0.5)
	)
end

--[[ "PainPills" -> "PAIN PILLS". Derived rather than tabulated so a new item id
     gets a readable label with no HUD change. ]]
local function itemLabel(itemId: string): string
	if itemId == "" then
		return ""
	end
	local spaced = string.gsub(itemId, "(%l)(%u)", "%1 %2")
	return string.upper(spaced)
end

--[[ What a controller's D-pad directions are called on screen. Arrows rather
     than "DPADUP", which is four times as wide and reads as a debug string. The
     face buttons keep their letters, which are the same on both platforms even
     though the colours are not — a Roblox game cannot know whether it is on a
     PlayStation or an Xbox, so it must not draw a glyph that would be wrong on
     one of them. ]]
local GAMEPAD_GLYPH: { [string]: string } = {
	DPadUp = "▲",
	DPadDown = "▼",
	DPadLeft = "◄",
	DPadRight = "►",
	ButtonA = "A",
	ButtonB = "B",
	ButtonX = "X",
	ButtonY = "Y",
	ButtonL1 = "L1",
	ButtonR1 = "R1",
	ButtonL2 = "L2",
	ButtonR2 = "R2",
	ButtonL3 = "L3",
	ButtonR3 = "R3",
}

local function isGamepadKey(key: any): boolean
	return typeof(key) == "EnumItem" and key.EnumType == Enum.KeyCode and GAMEPAD_GLYPH[key.Name] ~= nil
end

--[[
	The printable glyph for a bound key, for the device the player is actually
	holding.

	A keyboard glyph on a console is not a small cosmetic problem: it tells the
	player to press a key that does not exist, and the button that DOES work is
	somewhere else entirely — this game's D-pad layout deliberately does not
	mirror the 1-5 row. So the row is searched for a binding that matches the
	scheme first, and the keyboard half is the fallback rather than the default.

	Roblox's KeyCode values for letters and digits ARE their ASCII codes, so the
	common cases turn into "E" and "3" without a lookup table.
]]
local function keyGlyph(keys: { any }, scheme: string?): string
	if scheme == "Gamepad" then
		for _, key in keys do
			if isGamepadKey(key) then
				return GAMEPAD_GLYPH[key.Name]
			end
		end
		-- Bound to no gamepad button at all. Blank rather than a keyboard letter:
		-- "there is no button for this" is true, and "press 5" is not.
		return ""
	end

	for _, key in keys do
		if typeof(key) == "EnumItem" and key.EnumType == Enum.KeyCode and not isGamepadKey(key) then
			local value = key.Value
			if (value >= 48 and value <= 57) or (value >= 97 and value <= 122) then
				return string.upper(string.char(value))
			end
		end
	end
	for _, key in keys do
		if typeof(key) == "EnumItem" and not isGamepadKey(key) then
			return string.upper(key.Name)
		end
	end
	return "?"
end

-- ── survivor panels ─────────────────────────────────────────────────────────

--[[
	Colour slots are handed out on join and held until the player leaves, so a
	survivor keeps the same colour for the whole round. OutlineController and
	SubtitleController read the assignment back out of here rather than deriving
	their own, because a teammate whose outline and HUD panel disagree about
	which one they are is worse than no colour at all.
]]
local function assignIndex(target: Player): number
	local existing = slotIndices[target]
	if existing then
		return existing
	end

	local used: { [number]: boolean } = {}
	for _, index in slotIndices do
		used[index] = true
	end
	for index = 1, MAX_SURVIVORS do
		if not used[index] then
			slotIndices[target] = index
			return index
		end
	end

	-- Past MaxSurvivors there is no panel, but there is still a colour: a
	-- spectator or a fifth player must not crash the roster.
	local overflow = MAX_SURVIVORS + 1
	for _, index in slotIndices do
		if index >= overflow then
			overflow = index + 1
		end
	end
	slotIndices[target] = overflow
	return overflow
end

local function createPanel(target: Player)
	local index = assignIndex(target)
	local identity = UITheme.getSurvivorColor(index)

	local frame = Widgets.frame(panelHolder, "Survivor_" .. target.Name, COLOR.Panel, 0.12)
	frame.AnchorPoint = Vector2.new(0, 1)
	frame.Size = UDim2.fromOffset(LAYOUT.SurvivorPanelWidth, LAYOUT.SurvivorPanelHeight)
	frame.Position = UDim2.fromOffset(0, 0)
	corner(frame)
	local border = stroke(frame, target == player and COLOR.BorderBright or COLOR.Border)

	local stripe = Widgets.frame(frame, "Stripe", identity)
	stripe.Size = UDim2.new(0, STRIPE_WIDTH, 1, 0)

	local contentX = STRIPE_WIDTH + LAYOUT.PanelPadding
	local rightInset = contentX + LAYOUT.PanelPadding

	local name = Widgets.label(frame, "Name", FONT.Heading, TEXT.Body, COLOR.TextPrimary)
	name.Position = UDim2.fromOffset(contentX, 3)
	name.Size = UDim2.new(1, -(rightInset + 72), 0, 18)
	name.TextTruncate = Enum.TextTruncate.AtEnd
	name.Text = string.upper(target.DisplayName)

	local status = Widgets.label(frame, "Status", FONT.Body, TEXT.Tiny, COLOR.TextSecondary)
	status.AnchorPoint = Vector2.new(1, 0)
	status.Position = UDim2.new(1, -LAYOUT.PanelPadding, 0, 4)
	status.Size = UDim2.fromOffset(70, 16)
	status.TextXAlignment = Enum.TextXAlignment.Right

	local barBg = Widgets.frame(frame, "Bar", COLOR.Background)
	barBg.Position = UDim2.new(0, contentX, 1, -(LAYOUT.HealthBarHeight + 7))
	barBg.Size = UDim2.new(1, -rightInset, 0, LAYOUT.HealthBarHeight)
	barBg.ClipsDescendants = true
	corner(barBg)

	local perm = Widgets.frame(barBg, "Permanent", COLOR.HealthGood)
	perm.Size = UDim2.new(0, 0, 1, 0)

	-- Drawn after (and therefore over) the permanent fill, starting where it
	-- ends. This is the white pill buffer.
	local temp = Widgets.frame(barBg, "Temp", COLOR.HealthTemp)
	temp.Size = UDim2.new(0, 0, 1, 0)

	-- The revive clock, along the bottom edge of the bar so it cannot be
	-- mistaken for health returning.
	local revive = Widgets.frame(barBg, "Revive", COLOR.AccentBright)
	revive.AnchorPoint = Vector2.new(0, 1)
	revive.Position = UDim2.new(0, 0, 1, 0)
	revive.Size = UDim2.new(0, 0, 0, 3)

	local deadX = Widgets.frame(frame, "DeadX", COLOR.Danger, 1)
	deadX.Size = UDim2.new(1, 0, 1, 0)
	deadX.Visible = false
	for sign = -1, 1, 2 do
		local slash = Widgets.frame(deadX, "Slash", COLOR.Danger, 0.25)
		slash.AnchorPoint = Vector2.new(0.5, 0.5)
		slash.Position = UDim2.fromScale(0.5, 0.5)
		slash.Size = UDim2.new(1, -8, 0, 2)
		slash.Rotation = DEAD_X_ANGLE * sign
	end

	return {
		player = target,
		index = index,
		identity = identity,
		frame = frame,
		border = border,
		stripe = stripe,
		name = name,
		status = status,
		bar = barBg,
		perm = perm,
		temp = temp,
		revive = revive,
		deadX = deadX,
		trove = Trove.new(),

		permTarget = 0,
		permCurrent = 0,
		tempTarget = 0,
		tempCurrent = 0,
		reviveTarget = 0,
		reviveCurrent = 0,
		pulsing = false,
		state = STATE.Spectating,
	}
end

--[[ The local player's panel sits at the bottom of the stack and every teammate
     stacks above them in slot order, so "mine is the bottom one" is true for
     the whole round and nobody has to hunt for their own health. ]]
local function relayout()
	local order: { any } = {}
	for _, record in panels do
		-- A fifth player (or a spectator) keeps a colour but gets no panel: four
		-- bars is the layout, and a stack that grows past it is not the L4D HUD.
		local onRoster = record.index <= MAX_SURVIVORS
		record.frame.Visible = onRoster
		if onRoster then
			table.insert(order, record)
		end
	end
	table.sort(order, function(a, b)
		if (a.player == player) ~= (b.player == player) then
			return b.player == player
		end
		return a.index < b.index
	end)

	-- Positions are anchored to the holder's BOTTOM edge, so the stack grows
	-- upward as teammates join and nothing below the local player ever moves.
	local step = LAYOUT.SurvivorPanelHeight + LAYOUT.SurvivorPanelGap
	for row, record in order do
		record.frame.Position = UDim2.new(0, 0, 1, -(#order - row) * step)
	end
end

local function statusFor(record): (string, Color3)
	local survivorState = record.state
	if survivorState == STATE.Dead then
		return "DEAD", COLOR.Danger
	elseif survivorState == STATE.Incapacitated then
		return "HELP!", COLOR.HealthIncap
	elseif survivorState == STATE.LedgeHanging then
		return "HANGING", COLOR.HealthIncap
	elseif survivorState == STATE.Pinned then
		local by = Attributes.get(record.player, PA.PinnedBy, "")
		local pinText = if by ~= "" then string.upper(by) else "PINNED"
		return pinText, COLOR.Danger
	elseif survivorState == STATE.Spectating then
		return "AWAY", COLOR.TextDim
	elseif Attributes.get(record.player, PA.IsBlackAndWhite, false) then
		-- One more down is fatal. This is the most important word on the panel.
		return "B&W", COLOR.TextSecondary
	end
	return "", COLOR.TextSecondary
end

local function refreshPanel(record)
	local target = record.player
	record.state = Attributes.get(target, PA.State, STATE.Spectating)

	local health = math.max(Attributes.get(target, PA.Health, 0), 0)
	local temp = math.max(Attributes.get(target, PA.TempHealth, 0), 0)
	local blackAndWhite = Attributes.get(target, PA.IsBlackAndWhite, false)
	local incapacitated = record.state == STATE.Incapacitated or record.state == STATE.LedgeHanging
	local dead = record.state == STATE.Dead or record.state == STATE.Spectating

	local permFraction = math.clamp(health / MAX_HEALTH, 0, 1)
	local totalFraction = math.clamp((health + temp) / MAX_HEALTH, 0, 1)

	record.permTarget = if incapacitated then 1 elseif dead then 0 else permFraction
	record.tempTarget = if incapacitated or dead then 0 else math.max(totalFraction - permFraction, 0)
	record.reviveTarget = if incapacitated then Attributes.get(target, PA.ReviveProgress, 0) else 0

	if incapacitated then
		record.perm.BackgroundColor3 = COLOR.HealthIncap
	elseif blackAndWhite then
		-- Black and white is a whole-panel state, not a bar colour: the bar goes
		-- grey so that the one red thing left on the panel is the word.
		record.perm.BackgroundColor3 = COLOR.HealthBlackWhite
	else
		record.perm.BackgroundColor3 = UITheme.getHealthColor(totalFraction)
	end

	record.stripe.BackgroundColor3 = if blackAndWhite or dead
		then desaturate(record.identity)
		else record.identity
	record.name.TextColor3 = if dead
		then COLOR.TextDim
		elseif blackAndWhite then COLOR.TextSecondary
		else COLOR.TextPrimary
	record.frame.BackgroundTransparency = if dead then 0.45 else 0.12
	record.deadX.Visible = record.state == STATE.Dead
	record.pulsing = incapacitated

	local text, color = statusFor(record)
	record.status.Text = text
	record.status.TextColor3 = color
end

local function watchPanel(record)
	local target = record.player
	local function refresh()
		refreshPanel(record)
	end
	for _, attribute in
		{ PA.State, PA.Health, PA.TempHealth, PA.IsBlackAndWhite, PA.ReviveProgress, PA.PinnedBy }
	do
		record.trove:connect(target:GetAttributeChangedSignal(attribute), refresh)
	end
	refresh()
end

local function addPlayer(target: Player)
	if panels[target] then
		return
	end
	local record = createPanel(target)
	panels[target] = record
	watchPanel(record)
	relayout()
end

local function removePlayer(target: Player)
	local record = panels[target]
	if record then
		record.trove:destroy()
		record.frame:Destroy()
		panels[target] = nil
	end
	slotIndices[target] = nil
	relayout()
end

-- ── ammo ────────────────────────────────────────────────────────────────────

--[[
	The held weapon's live magazine and reserve, or nil if WeaponController is
	not holding this slot.

	WeaponController drops the count on the frame the trigger goes and reconciles
	itself against the server afterwards; the attributes only move once the
	server has answered. Reading the attribute for the gun in your hands puts the
	one number that has to change at the same instant as the muzzle flash a full
	round trip behind it — which is the whole thing prediction exists to prevent,
	and it is invisible in Studio because a local server has no round trip.

	Only ever asked about the slot it says it is holding. Every other slot still
	comes from attributes, which is the only truth for a gun that is not in hand.
]]
local function predictedAmmo(slot: string): (string?, number, number)
	if not WEAPON_SLOTS[slot] then
		return nil, 0, 0
	end
	local weapons = Registry.find("WeaponController")
	if not weapons or typeof(weapons.getAmmo) ~= "function" then
		return nil, 0, 0
	end

	local ok, held = pcall(weapons.getActiveSlot, weapons)
	if not ok or held ~= slot then
		return nil, 0, 0
	end

	local idOk, id = pcall(weapons.getWeaponId, weapons)
	if not idOk or typeof(id) ~= "string" or id == "" then
		return nil, 0, 0
	end

	local ammoOk, magazine, reserve = pcall(weapons.getAmmo, weapons)
	if not ammoOk or typeof(magazine) ~= "number" or typeof(reserve) ~= "number" then
		return nil, 0, 0
	end
	return id, magazine, reserve
end

--[[ Which weapon the counter is describing, straight off the loadout
     attributes. Returns a reserve of -1 for "infinite", which is what a pistol
     carries and what the counter draws as a dash rather than a number. ]]
local function activeWeapon(): (string, number, number)
	local slot = Attributes.get(player, LA.ActiveSlot, SLOT.Primary)

	local liveId, liveMagazine, liveReserve = predictedAmmo(slot)
	if liveId then
		return liveId, liveMagazine, liveReserve
	end

	if slot == SLOT.Secondary then
		local id = Attributes.get(player, LA.SecondaryId, "")
		local definition = WeaponConfig.get(id)
		local reserve = if definition and definition.reserveMax < 0 then -1 else 0
		return id, Attributes.get(player, LA.SecondaryAmmo, 0), reserve
	elseif slot == SLOT.Primary then
		return Attributes.get(player, LA.PrimaryId, ""),
			Attributes.get(player, LA.PrimaryAmmo, 0),
			Attributes.get(player, LA.PrimaryReserve, 0)
	end
	return "", 0, 0
end

local function refreshAmmo()
	local slot = Attributes.get(player, LA.ActiveSlot, SLOT.Primary)
	local id, magazine, reserve = activeWeapon()
	local definition = WeaponConfig.get(id)

	state.reloading = Attributes.get(player, LA.IsReloading, false)
	ammo.reloading.Visible = state.reloading
	ammo.reloading.TextTransparency = 0

	if not definition then
		-- An item slot is up, or the survivor is empty-handed. The counter still
		-- names what is in hand, because a blank corner reads as a broken HUD.
		local itemId = ""
		if slot == SLOT.Throwable then
			itemId = Attributes.get(player, LA.ThrowableId, "")
		elseif slot == SLOT.Health then
			itemId = Attributes.get(player, LA.HealthItemId, "")
		elseif slot == SLOT.Pills then
			itemId = Attributes.get(player, LA.PillItemId, "")
		end
		ammo.name.Text = itemLabel(itemId)
		ammo.mag.Text = if itemId ~= "" then "1" else "—"
		ammo.mag.TextColor3 = COLOR.TextPrimary
		ammo.mag.TextTransparency = 0
		ammo.reserve.Text = ""
		ammo.reserve.TextColor3 = COLOR.TextSecondary
		state.ammoEmpty = false
		ammo.panel.Visible = true
		return
	end

	ammo.name.Text = string.upper(definition.displayName)
	ammo.panel.Visible = true

	if definition.magSize <= 0 then
		-- Melee. No magazine to count, and a "0" here would read as empty.
		ammo.mag.Text = "—"
		ammo.mag.TextColor3 = COLOR.TextPrimary
		ammo.mag.TextTransparency = 0
		ammo.reserve.Text = ""
		ammo.reserve.TextColor3 = COLOR.TextSecondary
		state.ammoEmpty = false
		return
	end

	ammo.mag.Text = tostring(magazine)
	ammo.mag.TextColor3 = if magazine <= math.max(definition.magSize * LOW_AMMO_FRACTION, 1)
		then COLOR.Danger
		else COLOR.TextPrimary

	--[[ Only pulses while the gun is genuinely dry and nobody is fixing it. A
	     zero that is already being reloaded is not news, and a counter flashing
	     through every reload would be the HUD crying wolf sixty times a round. ]]
	state.ammoEmpty = magazine <= 0 and not state.reloading
	if not state.ammoEmpty then
		ammo.mag.TextTransparency = 0
	end

	ammo.reserve.Text = if reserve < 0 then "/ ∞" else "/ " .. tostring(reserve)
	--[[ Out of reserve is a different problem from out of magazine: it is the one
	     the ammo crates exist to solve, and it is the only reason to break off
	     and go looking for one. It gets its own red. ]]
	ammo.reserve.TextColor3 = if reserve == 0 then COLOR.Danger else COLOR.TextSecondary
end

--[[
	Pickup feedback. `InventoryChanged` was being broadcast by the server and read
	by nobody, because every value the HUD renders already arrives as an
	attribute. The event still carries something the attributes cannot: the fact
	that a slot changed AT THIS MOMENT, which is exactly what a pickup should feel
	like. So it drives a brief flash on the slot that changed.

	This is the cheapest kind of game feel there is — the player learns they
	picked something up from their peripheral vision instead of having to read
	the panel.
]]
local FLASH_SECONDS = 0.45
local flashUntil: { [string]: number } = {}
local flashLive = false

local function flashSlot(slot: string)
	if slot == "" then
		return
	end
	flashUntil[slot] = os.clock() + FLASH_SECONDS
	flashLive = true
end

--[[ Returns 0-1: how much of the flash is left on a slot. Sampled by the slot
     refresh rather than tweened, so no tween per pickup and nothing to cancel
     when two pickups land in the same frame. ]]
local function flashAmount(slot: string): number
	local until_ = flashUntil[slot]
	if not until_ then
		return 0
	end
	local remaining = until_ - os.clock()
	if remaining <= 0 then
		flashUntil[slot] = nil
		return 0
	end
	return remaining / FLASH_SECONDS
end

-- ── item slots ──────────────────────────────────────────────────────────────

--[[
	Draws the hotbar. Weapon slots show what is loaded; item slots show what is
	carried. Read from attributes — except the gun actually in hand, whose count
	comes from WeaponController's prediction — so this runs on change rather than
	on a timer, and the only thing that animates is the pickup flash.
]]
--[[ States in which the only thing you can hold is the incap pistol.
     InventoryService enforces it — setActiveSlot refuses outright — but a rule
     the server enforces and the interface does not show is a rule the player
     experiences as their keys having stopped working. ]]
local DOWNED_STATES: { [string]: boolean } = {
	[STATE.Incapacitated] = true,
	[STATE.LedgeHanging] = true,
}

local function refreshItems()
	local active = Attributes.get(player, LA.ActiveSlot, SLOT.Primary)
	local downed = DOWNED_STATES[Attributes.get(player, PA.State, STATE.Spectating)] == true

	for _, slot in HOTBAR_SLOTS do
		local entry = itemSlots[slot]
		if not entry then
			continue
		end

		local flash = flashAmount(slot)
		local itemId = ""
		local countText = ""

		--[[ Live for whichever gun is in hand, attributes for the other one. The
		     hotbar sits directly under the big counter, and the two disagreeing
		     by a round trip on every shot is more distracting than either being
		     slightly late on its own. ]]
		local liveId, liveMagazine, liveReserve = predictedAmmo(slot)

		if slot == SLOT.Primary then
			itemId = liveId or Attributes.get(player, LA.PrimaryId, "")
			if itemId ~= "" then
				local magazine, reserve
				if liveId then
					magazine, reserve = liveMagazine, liveReserve
				else
					magazine = Attributes.get(player, LA.PrimaryAmmo, 0)
					reserve = Attributes.get(player, LA.PrimaryReserve, 0)
				end
				countText = string.format("%d / %d", magazine, reserve)
			end
		elseif slot == SLOT.Secondary then
			itemId = liveId or Attributes.get(player, LA.SecondaryId, "")
			if itemId ~= "" then
				--[[ Sidearms have no finite reserve, and "15 / ∞" is noise: the
				     number that matters is what is in the gun. This used to have
				     a melee branch as well, because the machete lived in this
				     slot; melee has a slot of its own now. ]]
				local magazine = if liveId then liveMagazine else Attributes.get(player, LA.SecondaryAmmo, 0)
				countText = string.format("%d", magazine)
			end
		elseif slot == SLOT.Melee then
			--[[ No count of any kind. A melee has no magazine and no reserve, and
			     the tile saying so in words is what the SIDEARM tile does for a
			     machete-shaped thing that used to live there. ]]
			itemId = Attributes.get(player, LA.MeleeId, "")
		elseif slot == SLOT.Throwable then
			itemId = Attributes.get(player, LA.ThrowableId, "")
		elseif slot == SLOT.Health then
			itemId = Attributes.get(player, LA.HealthItemId, "")
		else
			itemId = Attributes.get(player, LA.PillItemId, "")
		end

		local filled = itemId ~= ""
		local selected = slot == active

		--[[ What is in the slot, or — when there is nothing — what the slot is
		     for. One label doing both is what lets an empty tile still teach a new
		     player that the slot exists, which the old dash on its own did not. ]]
		if filled then
			local definition = WEAPON_SLOTS[slot] and WeaponConfig.get(itemId)
			entry.label.Text = if definition then string.upper(definition.displayName) else itemLabel(itemId)
		else
			entry.label.Text = SLOT_TITLE[slot] or "—"
		end
		entry.count.Text = countText

		--[[ On the floor you hold the pistol and nothing else. The slots you
		     cannot reach are dimmed to the level an EMPTY slot draws at, so the
		     bar reads as "these are not available" rather than as five options
		     that ignore you — which is what it looked like before, because the
		     server refuses the switch silently. ]]
		local reachable = not downed or slot == SLOT.Secondary

		entry.label.TextColor3 = if not reachable
			then COLOR.TextDim
			elseif filled then COLOR.TextPrimary
			else COLOR.TextDim
		entry.key.TextColor3 = if reachable and filled then COLOR.TextSecondary else COLOR.TextDim
		entry.count.TextColor3 = if selected then COLOR.AccentBright else COLOR.TextSecondary
		entry.marker.Visible = selected and filled

		entry.frame.BackgroundTransparency = if not reachable
			then 0.72
			elseif selected and filled then 0.05
			elseif filled then 0.3
			else 0.62

		local base = if not reachable
			then COLOR.Border
			elseif selected and filled then COLOR.Accent
			elseif filled then COLOR.BorderBright
			else COLOR.Border

		-- The flash rides on top of whatever the slot's resting colour is, so a
		-- pickup reads the same whether the slot was empty, full, or selected.
		if flash > 0 then
			entry.stroke.Color = base:Lerp(COLOR.AccentBright, flash)
			entry.stroke.Thickness = LAYOUT.BorderThickness + flash * 1.8
			entry.frame.BackgroundTransparency *= 1 - flash * 0.7
		else
			entry.stroke.Color = base
			entry.stroke.Thickness = if selected and filled
				then LAYOUT.BorderThickness + 1
				else LAYOUT.BorderThickness
		end
	end
end

--[[
	How many kill feed rows are allowed right now.

	Declared HERE, above applyTouchLayout, and not down with the rest of the kill
	feed where it reads more naturally. A Lua closure can only see the locals that
	exist at the point it is WRITTEN — a `local function` further down the file is
	a different variable the closure never binds to, so calling it resolves a nil
	global at runtime and nothing says so until that line executes. It shipped
	exactly that way: the HUD died at start() and took every screen with it.
]]
local function feedLimit(): number
	return if state.touch then TOUCH_FEED_LIMIT else KILLFEED_HARD_MAX
end

--[[
	Moves the HUD out of the way of the controls a touchscreen adds.

	Two changes, both about the fact that a phone in landscape is around 390
	pixels tall and has a joystick drawn in the corner:

	  - The survivor stack lifts clear of Roblox's movement thumbstick. It was
	    being drawn underneath it, which breaks nothing (the panels are read-only)
	    but puts a thumb on top of the one thing you check constantly.
	  - The key glyph goes, since there is no key. The slot's NAME stays and takes
	    the space the glyph leaves, because with no glyph and no item it would
	    otherwise be the only thing telling a player what an empty slot is for.

	Everything else is the same HUD. A phone is not a different game.
]]
--[[
	Fits the hotbar to the screen it is on.

	Six tiles at the design width is 493 reference pixels. A phone held upright
	is about 500 across, so the row would have started fifteen pixels off the
	left edge of the screen — the tile count went from five to six when melee got
	a slot, and five fitted.

	So the tiles shrink instead. Never below MIN, because under that a weapon
	name at TextSize.Tiny stops fitting and the tile is a coloured square; the
	floor is not reachable on any device this game ships to, and is here so a
	Roblox window dragged to nothing degrades rather than lies.
]]
local HOTBAR_SLOT_MIN_WIDTH = 46

local function layoutHotbar()
	if not hotbarHolder then
		return
	end
	local camera = Workspace.CurrentCamera
	local factor = ScaleLayer.getFactor()
	if not camera or factor <= 0 then
		return
	end

	local count = #HOTBAR_SLOTS
	local gaps = (count - 1) * LAYOUT.ItemSlotGap
	local available = camera.ViewportSize.X / factor - LAYOUT.ScreenMargin * 2
	local width = math.clamp((available - gaps) / count, HOTBAR_SLOT_MIN_WIDTH, HOTBAR_SLOT_WIDTH)

	hotbarHolder.Size = UDim2.fromOffset(count * width + gaps, HOTBAR_SLOT_HEIGHT)
	for _, entry in itemSlots do
		entry.frame.Size = UDim2.fromOffset(width, HOTBAR_SLOT_HEIGHT)
	end
end

local function applyTouchLayout()
	if panelHolder then
		local lift = if state.touch then THUMBSTICK_INSET else 0
		panelHolder.Position = UDim2.new(0, LAYOUT.ScreenMargin, 1, -(LAYOUT.ScreenMargin + lift))
	end

	if killFeedHolder then
		killFeedHolder.Size = UDim2.fromOffset(KILLFEED_WIDTH, feedLimit() * KILLFEED_ROW_HEIGHT)
		--[[ And out from under the pause button, which is drawn into this exact
		     corner on every platform. The feed is right-aligned text in a
		     380-wide column with room to spare on its left, so stepping it aside
		     costs nothing and sharing the corner costs both of them.

		     No longer touch-only: the settings gear this replaced was a phone
		     control, and the pause button is not. ]]
		local inset = LAYOUT.PauseButtonSize + LAYOUT.ElementGap
		killFeedHolder.Position = UDim2.new(1, -(LAYOUT.ScreenMargin + inset), 0, LAYOUT.ScreenMargin)
	end

	--[[ No key glyph on a touchscreen: there is no key. The slot's single label
	     already says what it holds or what it is for, so nothing is lost — which
	     was not true when the glyph and the slot name were separate things. ]]
	for _, entry in itemSlots do
		entry.key.Visible = not state.touch
	end

	layoutHotbar()
end

--[[ Re-run whenever the player picks up a different input, not just at boot.
     A console player who plugs in a keyboard, or a tablet player who pairs a
     controller, should see the buttons they are now holding. ]]
local function bindItemKeys()
	local input = Registry.find("InputController")
	if not input or typeof(input.getBindings) ~= "function" then
		return
	end
	local ok, bindings = pcall(input.getBindings, input)
	if not ok or typeof(bindings) ~= "table" then
		return
	end

	local scheme = "Desktop"
	if typeof(input.getScheme) == "function" then
		local schemeOk, value = pcall(input.getScheme, input)
		if schemeOk and typeof(value) == "string" then
			scheme = value
		end
	end
	local touch = scheme == "Touch"
	state.touch = touch
	applyTouchLayout()

	--[[ The button that swaps between the two weapon slots. On a controller
	     neither of them has a D-pad direction of its own — all four are spent on
	     the consumables, which is what makes the layout complete — so both would
	     otherwise show a blank glyph and read as unreachable when they are one
	     press away. ]]
	local cycleGlyph = ""
	if scheme == "Gamepad" then
		for _, binding in bindings do
			if binding.action == "CycleWeapon" then
				cycleGlyph = keyGlyph(binding.keys, scheme)
				break
			end
		end
	end

	for _, binding in bindings do
		local entry = binding.slot and itemSlots[binding.slot]
		if entry then
			--[[ Nothing to press on a touchscreen, because the slot IS the
			     button. A key glyph there would be instructions for hardware the
			     player does not have. ]]
			local glyph = if touch then "" else keyGlyph(binding.keys, scheme)
			if glyph == "" and WEAPON_SLOTS[binding.slot] then
				glyph = cycleGlyph
			end
			entry.key.Text = glyph
			-- Inert on desktop and console, so it can never swallow a click.
			entry.tap.Active = touch
		end
	end
end

-- ── objective ───────────────────────────────────────────────────────────────

local function setObjective(text: string, progress: number?)
	text = if typeof(text) == "string" then text else ""
	local changed = text ~= state.objectiveText
	state.objectiveText = text

	objective.label.Text = string.upper(text)
	objective.frame.Visible = text ~= ""

	--[[ The objective arrives twice — once as the attribute a late joiner reads,
	     once as the remote that carries progress — and in either order. A call
	     with no progress therefore leaves the bar alone rather than clearing a
	     value the other half of the pair just set. ]]
	if typeof(progress) == "number" then
		objective.bar.Visible = text ~= ""
		objective.fill.Size = UDim2.new(math.clamp(progress, 0, 1), 0, 1, 0)
	elseif changed then
		objective.bar.Visible = false
	end

	if changed and text ~= "" then
		-- A new objective punches in rather than fading: it is the one line on
		-- screen the player is meant to read immediately.
		objective.label.TextTransparency = 1
		objective.label.Position = UDim2.new(0.5, 0, 0, -6)
		local tween = TweenService:Create(
			objective.label,
			TweenInfo.new(MOTION.FastOut, MOTION.Easing, MOTION.EasingDirection),
			{ TextTransparency = 0, Position = UDim2.new(0.5, 0, 0, 0) }
		)
		tween:Play()
	end
end

-- ── kill feed ───────────────────────────────────────────────────────────────

--[[
	The colour a name is drawn in.

	A survivor gets their identity colour — the same one on their panel stripe
	and their outline through a wall. An infected is coloured by what it was:
	Commons stay dim because they arrive in floods and none of them is news, a
	special reads as plain text, and a Tank or a Witch gets the accent, because
	that line is the one the player wants to find in a feed of twenty.
]]
local function nameColor(name: string): Color3
	for target, record in panels do
		if target.Name == name or target.DisplayName == name then
			return record.identity
		end
	end
	local infected = INFECTED_BY_NAME[name]
	if infected then
		return if infected.isBoss
			then COLOR.AccentBright
			elseif infected.isSpecial then COLOR.TextPrimary
			else COLOR.TextDim
	end
	return COLOR.TextSecondary
end

--[[ A free row, or the oldest one if every row is spoken for. Losing the top
     line to the newest kill is the right way round: under a horde the bottom of
     the feed is the only part still true.

     Recycles the oldest row once the feed is at its limit, rather than only once
     the pool runs dry. The pool is sized for the desktop limit and stays that
     size, so a player who picks up a controller mid-round gets the full feed back
     without anything being rebuilt. ]]
local function acquireRow(): TextLabel
	if #killFeed < feedLimit() then
		local free = table.remove(killFeedPool)
		if free then
			return free
		end
	end
	local oldest = table.remove(killFeed, 1)
	if oldest then
		return (oldest :: any).label
	end
	-- The limit is below the live count only just after a scheme change; take
	-- from the pool rather than returning nil into a caller that cannot check.
	return table.remove(killFeedPool) :: TextLabel
end

local function releaseRow(label: TextLabel)
	label.Visible = false
	label.Text = ""
	table.insert(killFeedPool, label)
end

local function pushKill(payload: any)
	if typeof(payload) ~= "table" then
		return
	end
	local killer = tostring(payload.killer or "")
	local victim = tostring(payload.victim or "")
	if victim == "" then
		return
	end

	local definition = WeaponConfig.get(tostring(payload.weaponId or ""))
	local weaponText = if definition then string.upper(definition.displayName) .. " " else ""
	-- A headshot kill is worth calling out in the feed the same way it is worth
	-- calling out at the crosshair: gold, and only when it happened.
	local middle = if payload.headshot then COLOR.AccentBright else COLOR.TextDim

	killFeedOrder += 1
	local label = acquireRow()
	label.LayoutOrder = killFeedOrder
	label.TextTransparency = 0
	label.Visible = true
	label.Text = string.format(
		'<font color="%s">%s</font><font color="%s">  ×  %s%s</font><font color="%s">%s</font>',
		hex(nameColor(killer)),
		string.upper(killer),
		hex(middle),
		weaponText,
		if payload.headshot then "HS  " else "",
		hex(nameColor(victim)),
		string.upper(victim)
	)

	table.insert(killFeed, { label = label, age = 0 })

	-- Everything past the readable count is pushed into its fade rather than
	-- yanked: under a burst the feed drains, it does not blink.
	for index = 1, #killFeed - KILLFEED_MAX do
		local entry = killFeed[index]
		if entry.age < KILLFEED_LIFETIME then
			entry.age = KILLFEED_LIFETIME
		end
	end
end

-- ── frame loop ──────────────────────────────────────────────────────────────

local function approach(current: number, target: number, dt: number): number
	if math.abs(target - current) < BAR_EPSILON then
		return target
	end
	return current + (target - current) * math.min(dt * BAR_CHASE_SPEED, 1)
end

--[[ A ring of labels, never grown and never destroyed, so a horde allocates
     nothing. The oldest is reused when the ring comes round — which is correct
     rather than merely cheap: the number that has been on screen longest is the
     one a player has finished reading. ]]
local function buildEarnPool()
	for index = 1, EARN_POOL do
		local label = Widgets.label(root, "Earn" .. index, FONT.Numeric, TEXT.Large, COLOR.Accent)
		label.AnchorPoint = Vector2.new(0.5, 0.5)
		label.Position = UDim2.fromScale(0.5, EARN_Y)
		label.Size = UDim2.new(0, 160, 0, TEXT.Large + 4)
		label.TextXAlignment = Enum.TextXAlignment.Center
		label.TextStrokeColor3 = COLOR.Background
		label.TextStrokeTransparency = 0.4
		label.Visible = false
		earnLabels[index] = { label = label, until_ = 0, amount = 0 }
	end
end

local function showEarned(amount: number)
	if amount <= 0 then
		return
	end
	local now = os.clock()
	local newest = earnLabels[earnCursor]
	if newest and newest.until_ > 0 and now < newest.until_ - EARN_SECONDS + EARN_MERGE_WINDOW then
		newest.amount += amount
		newest.label.Text = "+" .. EconomyConfig.format(newest.amount)
		return
	end

	earnCursor = (earnCursor % EARN_POOL) + 1
	local slot = earnLabels[earnCursor]
	if not slot then
		return
	end
	slot.amount = amount
	slot.until_ = now + EARN_SECONDS
	slot.label.Text = "+" .. EconomyConfig.format(amount)
	slot.label.TextTransparency = 0
	slot.label.TextStrokeTransparency = 0.4
	slot.label.Position = UDim2.fromScale(0.5, EARN_Y)
	slot.label.Visible = true
end

local function stepEarned(now: number)
	for _, slot in earnLabels do
		if slot.until_ > 0 then
			local remaining = slot.until_ - now
			if remaining <= 0 then
				slot.until_ = 0
				slot.label.Visible = false
			else
				--[[ Squared, so it holds its brightness for most of its life and
				     then goes. A linear fade spends half its time as a number
				     nobody can read still taking up the middle of the screen. ]]
				local alpha = 1 - remaining / EARN_SECONDS
				slot.label.TextTransparency = alpha * alpha
				slot.label.TextStrokeTransparency = 0.4 + alpha * 0.6
				slot.label.Position = UDim2.new(0.5, 0, EARN_Y, -EARN_RISE * alpha)
			end
		end
	end
end

local function buildWallet()
	--[[ Positioned off the ammo panel's own numbers so it stays put when the
	     hotbar or the ammo panel is resized: one margin, one hotbar, one gap, one
	     ammo panel, one gap. The alternative is a magic offset that is correct
	     until somebody changes AmmoPanelHeight. ]]
	local bottom = LAYOUT.ScreenMargin
		+ HOTBAR_SLOT_HEIGHT
		+ LAYOUT.ElementGap
		+ LAYOUT.AmmoPanelHeight
		+ LAYOUT.ElementGap

	local label = Widgets.label(root, "Wallet", FONT.Numeric, TEXT.Body, COLOR.TextSecondary)
	label.AnchorPoint = Vector2.new(1, 1)
	label.Position = UDim2.new(1, -LAYOUT.ScreenMargin, 1, -bottom)
	label.Size = UDim2.fromOffset(LAYOUT.AmmoPanelWidth, WALLET_HEIGHT)
	label.TextXAlignment = Enum.TextXAlignment.Right
	--[[ A stroke rather than a panel. The balance has to stay readable over a
	     lit sky or a wall of fire, and giving it its own background would put a
	     third box in a corner that already has two. ]]
	label.TextStrokeColor3 = COLOR.Background
	label.TextStrokeTransparency = 0.5
	--[[ Hidden until a profile arrives. A balance that reads $0 for the first
	     two seconds of every round is a bug report waiting to be filed. ]]
	label.Visible = false

	wallet = { label = label, litUntil = 0 }
end

--[[ Redraws the balance and lights it when it moved. `lit` is separate from the
     value because a balance can be refreshed for reasons that are not earnings —
     the profile syncing after a purchase, say — and flashing for those would
     teach the player that the flash means nothing. ]]
local function refreshWallet(lit: boolean)
	if not wallet then
		return
	end
	local store = Registry.find("ProfileController")
	if not store or typeof(store.isReady) ~= "function" then
		return
	end
	local ok, ready = pcall(store.isReady, store)
	if not ok or not ready then
		return
	end

	wallet.label.Visible = true
	wallet.label.Text = EconomyConfig.format(store:getDollars())
	if lit then
		wallet.litUntil = os.clock() + WALLET_FLASH
		wallet.label.TextColor3 = COLOR.AccentBright
	end
end

--[[ Fades the flash back to the resting colour. Driven from the frame loop
     rather than a tween so it cannot outlive a HUD that was hidden mid-flash. ]]
local function stepWallet(now: number)
	if not wallet or wallet.litUntil <= 0 then
		return
	end
	local remaining = wallet.litUntil - now
	if remaining <= 0 then
		wallet.litUntil = 0
		wallet.label.TextColor3 = COLOR.TextSecondary
		return
	end
	wallet.label.TextColor3 = COLOR.TextSecondary:Lerp(COLOR.AccentBright, remaining / WALLET_FLASH)
end

local function update(dt: number)
	local now = os.clock()

	--[[ The item slots are attribute-driven and normally only redraw when
	     something changes. A flash is the one thing that has to animate, so the
	     loop drives them for its duration and then stops paying for them again. ]]
	if flashLive then
		local anyLive = false
		for _, until_ in flashUntil do
			if until_ > now then
				anyLive = true
				break
			end
		end
		refreshItems()
		flashLive = anyLive
	end

	for _, record in panels do
		local perm = approach(record.permCurrent, record.permTarget, dt)
		if perm ~= record.permCurrent then
			record.permCurrent = perm
			record.perm.Size = UDim2.new(perm, 0, 1, 0)
			record.temp.Position = UDim2.new(perm, 0, 0, 0)
		end

		local temp = approach(record.tempCurrent, record.tempTarget, dt)
		if temp ~= record.tempCurrent then
			record.tempCurrent = temp
			record.temp.Size = UDim2.new(temp, 0, 1, 0)
		end

		local revive = approach(record.reviveCurrent, record.reviveTarget, dt)
		if revive ~= record.reviveCurrent then
			record.reviveCurrent = revive
			record.revive.Size = UDim2.new(revive, 0, 0, 3)
		end

		if record.pulsing then
			-- A downed teammate's panel breathes. It shares the outline pulse
			-- rate so the panel and the silhouette through the wall agree.
			local pulse = 0.5 + 0.5 * math.sin(now * UITheme.Outline.IncapPulseSpeed * math.pi)
			record.status.TextTransparency = pulse * 0.6
		elseif record.status.TextTransparency ~= 0 then
			record.status.TextTransparency = 0
		end
	end

	if state.reloading then
		local blink = 0.5 + 0.5 * math.sin(now * 9)
		ammo.reloading.TextTransparency = blink * 0.7
	end

	--[[ Asked rather than pushed: the reload clock lives in WeaponController and
	     ticks every frame there anyway, so mirroring it into an attribute would
	     be a second copy of a number that is already local. Missing controller,
	     or a build where it predates getReloadProgress, just means no bar. ]]
	local progress = -1
	local weapons = Registry.find("WeaponController")
	if weapons and typeof(weapons.getReloadProgress) == "function" then
		local ok, value = pcall(weapons.getReloadProgress, weapons)
		if ok and typeof(value) == "number" then
			progress = value
		end
	end
	if progress >= 0 then
		ammo.reloadBar.Visible = true
		ammo.reloadFill.Size = UDim2.new(progress, 0, 1, 0)
	elseif ammo.reloadBar.Visible then
		ammo.reloadBar.Visible = false
		ammo.reloadFill.Size = UDim2.new(0, 0, 1, 0)
	end

	if state.ammoEmpty then
		-- Slower than the RELOADING blink on purpose: the two are never up at
		-- the same time, and matching rates would make them read as one effect.
		ammo.mag.TextTransparency = (0.5 + 0.5 * math.sin(now * 5)) * 0.55
	end

	stepEarned(now)
	stepWallet(now)

	if notice.until_ > 0 then
		local remaining = notice.until_ - now
		if remaining <= 0 then
			notice.until_ = 0
			notice.label.Visible = false
		else
			--[[ Held solid, then faded over the tail. A warning that starts fading
			     immediately reads as an accident rather than as the game speaking. ]]
			local fade = if remaining < NOTICE_FADE then 1 - remaining / NOTICE_FADE else 0
			notice.label.TextTransparency = fade
			notice.label.TextStrokeTransparency = 0.4 + fade * 0.6
		end
	end

	for index = #killFeed, 1, -1 do
		local entry = killFeed[index]
		entry.age += dt
		local over = entry.age - KILLFEED_LIFETIME
		if over >= KILLFEED_FADE then
			releaseRow(entry.label)
			table.remove(killFeed, index)
		elseif over > 0 then
			entry.label.TextTransparency = over / KILLFEED_FADE
		end
	end
end

-- ── build ───────────────────────────────────────────────────────────────────

local function buildAmmo()
	local panel = Widgets.frame(root, "Ammo", COLOR.Panel, 0.12)
	panel.AnchorPoint = Vector2.new(1, 1)
	-- Clear of the hotbar below it, which owns the bottom margin now.
	panel.Position =
		UDim2.new(1, -LAYOUT.ScreenMargin, 1, -(LAYOUT.ScreenMargin + HOTBAR_SLOT_HEIGHT + LAYOUT.ElementGap))
	panel.Size = UDim2.fromOffset(LAYOUT.AmmoPanelWidth, LAYOUT.AmmoPanelHeight)
	corner(panel)
	stroke(panel)

	--[[ Sixteen real guns means names like "Kriss Vector .45" where the old
	     roster had "SMG". Truncation would hide the half of ".357 Magnum" that
	     identifies it, so the name scales itself down to TextSize.Tiny instead
	     and every weapon in the roster fits at a glance. ]]
	local name = Widgets.label(panel, "Weapon", FONT.Heading, TEXT.Small, COLOR.TextSecondary)
	name.Position = UDim2.fromOffset(LAYOUT.PanelPadding, 5)
	name.Size = UDim2.new(1, -LAYOUT.PanelPadding * 2, 0, 16)
	name.TextXAlignment = Enum.TextXAlignment.Right
	name.TextScaled = true
	name.TextWrapped = false
	local nameBounds = Instance.new("UITextSizeConstraint")
	nameBounds.MaxTextSize = TEXT.Small
	nameBounds.MinTextSize = TEXT.Tiny
	nameBounds.Parent = name

	local reloading = Widgets.label(panel, "Reloading", FONT.Body, TEXT.Small, COLOR.Accent)
	reloading.Position = UDim2.fromOffset(LAYOUT.PanelPadding, 22)
	reloading.Size = UDim2.new(1, -LAYOUT.PanelPadding * 2, 0, 14)
	reloading.TextXAlignment = Enum.TextXAlignment.Right
	reloading.Text = "RELOADING"
	reloading.Visible = false

	--[[ The reserve is pinned to the panel's padding edge and the magazine ends
	     where the reserve begins, so the pair right-aligns as one number no
	     matter how wide it gets. A PPSh-41 carries "71 / 426"; nothing in the
	     roster is wider than that, and the size constraints mean nothing could
	     be. ]]
	local reserve = Widgets.label(panel, "Reserve", FONT.Numeric, TEXT.Large, COLOR.TextSecondary)
	reserve.AnchorPoint = Vector2.new(1, 1)
	reserve.Position = UDim2.new(1, -LAYOUT.PanelPadding, 1, -10)
	reserve.Size = UDim2.fromOffset(RESERVE_WIDTH, TEXT.Large + 4)
	reserve.TextXAlignment = Enum.TextXAlignment.Right
	reserve.TextScaled = true
	reserve.TextWrapped = false
	local reserveBounds = Instance.new("UITextSizeConstraint")
	reserveBounds.MaxTextSize = TEXT.Large
	reserveBounds.MinTextSize = TEXT.Small
	reserveBounds.Parent = reserve

	--[[ Stencil, not the numeric face. This is the single largest element on the
	     screen and the one place the in-game HUD gets to carry the same worn,
	     stamped voice the main menu does. ]]
	local magazine = Widgets.label(panel, "Magazine", FONT.Stencil, TEXT.Display, COLOR.TextPrimary)
	magazine.AnchorPoint = Vector2.new(1, 1)
	magazine.Position = UDim2.new(1, -(LAYOUT.PanelPadding + RESERVE_WIDTH), 1, -4)
	magazine.Size =
		UDim2.fromOffset(LAYOUT.AmmoPanelWidth - RESERVE_WIDTH - LAYOUT.PanelPadding * 2, TEXT.Display)
	magazine.TextXAlignment = Enum.TextXAlignment.Right
	magazine.TextScaled = true
	magazine.TextWrapped = false
	local magazineBounds = Instance.new("UITextSizeConstraint")
	magazineBounds.MaxTextSize = TEXT.Display
	magazineBounds.MinTextSize = TEXT.Heading
	magazineBounds.Parent = magazine

	--[[ A hairline across the bottom of the panel that fills over the reload.
	     For a shell-fed gun it fills once per shell rather than once per reload,
	     because a shotgun reload can be interrupted after any shell and a single
	     bar spanning the whole thing would be promising something the gun does
	     not owe. Hidden entirely when nothing is reloading — a permanently empty
	     bar is furniture. ]]
	local reloadBar = Widgets.frame(panel, "ReloadTrack", COLOR.Border, 0.45)
	reloadBar.AnchorPoint = Vector2.new(0.5, 1)
	reloadBar.Position = UDim2.new(0.5, 0, 1, -2)
	reloadBar.Size = UDim2.new(1, -LAYOUT.PanelPadding * 2, 0, 2)
	reloadBar.Visible = false

	local reloadFill = Widgets.frame(reloadBar, "Fill", COLOR.Accent)
	reloadFill.Size = UDim2.new(0, 0, 1, 0)

	ammo = {
		panel = panel,
		name = name,
		mag = magazine,
		reserve = reserve,
		reloading = reloading,
		reloadBar = reloadBar,
		reloadFill = reloadFill,
	}
end

local function buildItems()
	--[[ Bottom right, with the ammo counter stacked directly above it. That
	     corner is where Left 4 Dead keeps everything about what you are holding,
	     and keeping the count and the slots together means one glance answers
	     both "what am I holding" and "what could I switch to". ]]
	local holder = Widgets.frame(root, "Hotbar", COLOR.Panel, 1)
	hotbarHolder = holder
	holder.AnchorPoint = Vector2.new(1, 1)
	holder.Position = UDim2.new(1, -LAYOUT.ScreenMargin, 1, -LAYOUT.ScreenMargin)
	--[[ A starting size only. layoutHotbar owns it from the first resize onward
	     and narrows the tiles when six of them do not fit. ]]
	holder.Size = UDim2.fromOffset(
		#HOTBAR_SLOTS * HOTBAR_SLOT_WIDTH + (#HOTBAR_SLOTS - 1) * LAYOUT.ItemSlotGap,
		HOTBAR_SLOT_HEIGHT
	)

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Right
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, LAYOUT.ItemSlotGap)
	layout.Parent = holder

	for order, slot in HOTBAR_SLOTS do
		local frame = Widgets.frame(holder, slot, COLOR.Panel, 0.55)
		frame.LayoutOrder = order
		frame.Size = UDim2.fromOffset(HOTBAR_SLOT_WIDTH, HOTBAR_SLOT_HEIGHT)
		--[[ No rounded corner, deliberately. Every other panel in this interface
		     takes UITheme's 2px radius; the hotbar does not, because Left 4 Dead's
		     item tiles are cut square and the corner is most of what separates a
		     row of game tiles from a row of app buttons. ]]
		local line = stroke(frame)

		--[[
			On a touchscreen the slot IS the button.

			Five more buttons for five slots would be five more things covering a
			screen the player is trying to see a Hunter through, and the hotbar is
			already on screen, already says what is in each slot, and is already in
			the corner a thumb can reach. So a tap selects, and a second tap on a
			consumable spends it — the same press-again-to-use rule the D-pad
			follows on a controller, and it comes free because InputController owns
			that decision rather than the keymap does.

			The button sits ON TOP of the slot rather than replacing the Frame:
			everything that draws a slot writes to `frame`, and turning that into a
			TextButton would have meant auditing every one of those writes for the
			sake of one property. Active is switched on only under the touch
			scheme, so on desktop it cannot swallow a click.
		]]
		local tap = Instance.new("TextButton")
		tap.Name = "Tap"
		tap.BackgroundTransparency = 1
		tap.BorderSizePixel = 0
		tap.AutoButtonColor = false
		tap.Text = ""
		tap.Size = UDim2.fromScale(1, 1)
		tap.ZIndex = frame.ZIndex + 4
		tap.Active = false
		tap.Selectable = false
		tap.Parent = frame

		trove:connect(tap.Activated, function()
			local input = Registry.find("InputController")
			if not input or typeof(input.raise) ~= "function" then
				return
			end
			for _, binding in input:getBindings() do
				if binding.slot == slot then
					input:raise(binding.action, true)
					input:raise(binding.action, false)
					return
				end
			end
		end)

		--[[ The selected slot is lit along its whole bottom edge rather than
		     marked with a hairline down its side. That underline is the L4D
		     read — the tile the light is under is the one in your hands — and a
		     full-width bar survives being caught in peripheral vision, which is
		     the only way this row is ever actually looked at during a fight. ]]
		local marker = Widgets.frame(frame, "Marker", COLOR.Accent)
		marker.AnchorPoint = Vector2.new(0, 1)
		marker.Position = UDim2.new(0, 0, 1, 0)
		marker.Size = UDim2.new(1, 0, 0, HOTBAR_MARKER_HEIGHT)
		marker.Visible = false

		-- Stencil digits: the one place in the HUD that gets to look stamped on.
		local key = Widgets.label(frame, "Key", FONT.Stencil, TEXT.Small, COLOR.TextDim)
		key.Position = UDim2.fromOffset(6, 4)
		key.Size = UDim2.fromOffset(16, 14)

		--[[
			One line of text per slot, not two.

			It used to carry the slot's NAME and the item's name at once, which is
			twice the words for one fact and nothing L4D would ever show — its
			tiles are a silhouette and a number. With no icons to draw, the honest
			equivalent is a single label that says whatever the slot currently
			needs to communicate: what is in it, or, when it is empty, what it is
			for. That also fixed the touch case, where hiding the key glyph used to
			leave an empty slot with no indication of what it was.
		]]
		local label = Widgets.label(frame, "Label", FONT.Heading, TEXT.Small, COLOR.TextDim)
		label.AnchorPoint = Vector2.new(0.5, 0)
		label.Position = UDim2.new(0.5, 0, 0, 20)
		label.Size = UDim2.new(1, -10, 0, 17)
		label.TextXAlignment = Enum.TextXAlignment.Center
		label.TextScaled = true
		label.TextWrapped = false
		local bounds = Instance.new("UITextSizeConstraint")
		bounds.MaxTextSize = TEXT.Small
		bounds.MinTextSize = TEXT.Tiny
		bounds.Parent = label

		--[[ Bottom-right, above the marker. Only weapon slots ever fill it in, but
		     it exists on every slot rather than being conditional, so every tile
		     keeps the same shape and refreshItems never has to check. ]]
		local count = Widgets.label(frame, "Count", FONT.Numeric, TEXT.Small, COLOR.TextSecondary)
		count.AnchorPoint = Vector2.new(1, 1)
		count.Position = UDim2.new(1, -6, 1, -(HOTBAR_MARKER_HEIGHT + 3))
		count.Size = UDim2.new(1, -12, 0, 14)
		count.TextXAlignment = Enum.TextXAlignment.Right

		itemSlots[slot] = {
			frame = frame,
			key = key,
			label = label,
			count = count,
			marker = marker,
			stroke = line,
			tap = tap,
		}
	end
end

--[[
	A short, centred warning about something the player just did.

	Deliberately not the objective line, which is about what the ROUND is doing
	and lives at the top of the screen where nobody looks mid-fight. This sits
	just above the crosshair — the one place a player is guaranteed to be looking
	— holds for a couple of seconds, and fades.

	One at a time, replaced rather than queued. A second warning arriving means
	the first is no longer the most important thing to say.
]]
local function buildNotice()
	local label = Widgets.label(root, "Notice", FONT.Display, TEXT.Heading, COLOR.Danger)
	label.AnchorPoint = Vector2.new(0.5, 1)
	label.Position = UDim2.fromScale(0.5, NOTICE_Y)
	label.Size = UDim2.new(1, -LAYOUT.ScreenMargin * 2, 0, TEXT.Heading + 6)
	label.TextXAlignment = Enum.TextXAlignment.Center
	label.TextScaled = true
	label.TextWrapped = false
	label.TextStrokeColor3 = COLOR.Background
	label.TextStrokeTransparency = 0.4
	label.Visible = false

	local bounds = Instance.new("UITextSizeConstraint")
	bounds.MaxTextSize = TEXT.Heading
	bounds.MinTextSize = TEXT.Body
	bounds.Parent = label

	notice = { label = label, until_ = 0 }
end

local function buildObjective()
	local frame = Widgets.frame(root, "Objective", COLOR.Panel, 1)
	frame.AnchorPoint = Vector2.new(0.5, 0)
	frame.Position = UDim2.new(0.5, 0, 0, state.topInset)
	frame.Size = UDim2.fromOffset(560, 28)
	frame.Visible = false

	local label = Widgets.label(frame, "Text", FONT.Heading, TEXT.Body, COLOR.Accent)
	label.AnchorPoint = Vector2.new(0.5, 0)
	label.Position = UDim2.fromScale(0.5, 0)
	label.Size = UDim2.new(1, 0, 0, 20)
	label.TextXAlignment = Enum.TextXAlignment.Center

	local bar = Widgets.frame(frame, "Progress", COLOR.Background)
	bar.AnchorPoint = Vector2.new(0.5, 0)
	bar.Position = UDim2.new(0.5, 0, 0, 22)
	bar.Size = UDim2.fromOffset(220, 2)
	bar.Visible = false

	local fill = Widgets.frame(bar, "Fill", COLOR.Accent)
	fill.Size = UDim2.new(0, 0, 1, 0)

	objective = { frame = frame, label = label, bar = bar, fill = fill }
end

local function build()
	gui = Instance.new("ScreenGui")
	gui.Name = "FL_Hud"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = UITheme.DisplayOrder.Hud
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = player:WaitForChild("PlayerGui")
	trove:add(gui)

	root = ScaleLayer.new(gui, "Scaled")

	panelHolder = Widgets.frame(root, "Survivors", COLOR.Panel, 1)
	panelHolder.AnchorPoint = Vector2.new(0, 1)
	panelHolder.Position = UDim2.new(0, LAYOUT.ScreenMargin, 1, -LAYOUT.ScreenMargin)
	panelHolder.Size = UDim2.fromOffset(
		LAYOUT.SurvivorPanelWidth,
		MAX_SURVIVORS * (LAYOUT.SurvivorPanelHeight + LAYOUT.SurvivorPanelGap)
	)

	--[[ Fixed height and clipped, so no volume of kills can grow the feed down
	     the side of the screen and into the play space. The rows it can hold are
	     the rows that exist. ]]
	killFeedHolder = Widgets.frame(root, "KillFeed", COLOR.Panel, 1)
	killFeedHolder.AnchorPoint = Vector2.new(1, 0)
	killFeedHolder.Position = UDim2.new(1, -LAYOUT.ScreenMargin, 0, LAYOUT.ScreenMargin)
	killFeedHolder.Size = UDim2.fromOffset(KILLFEED_WIDTH, KILLFEED_HARD_MAX * KILLFEED_ROW_HEIGHT)
	killFeedHolder.ClipsDescendants = true

	local feedLayout = Instance.new("UIListLayout")
	feedLayout.FillDirection = Enum.FillDirection.Vertical
	feedLayout.HorizontalAlignment = Enum.HorizontalAlignment.Right
	feedLayout.VerticalAlignment = Enum.VerticalAlignment.Top
	feedLayout.SortOrder = Enum.SortOrder.LayoutOrder
	feedLayout.Parent = killFeedHolder

	for _ = 1, KILLFEED_HARD_MAX do
		local row = Widgets.label(killFeedHolder, "Kill", FONT.Body, TEXT.Small, COLOR.TextPrimary)
		row.RichText = true
		row.Size = UDim2.new(1, 0, 0, KILLFEED_ROW_HEIGHT)
		row.TextXAlignment = Enum.TextXAlignment.Right
		row.Visible = false
		table.insert(killFeedPool, row)
	end

	buildAmmo()
	buildWallet()
	buildItems()
	buildNotice()
	buildEarnPool()
	buildObjective()
end

-- ── public API ──────────────────────────────────────────────────────────────

--[[ The stable colour slot for a player, 1-based and assigned on join. ]]
function HudController:getSurvivorIndex(target: Player): number
	return assignIndex(target)
end

--[[ The colour that identifies a player everywhere in the interface: their HUD
     stripe, their outline through a wall, and their name on a callout. ]]
function HudController:getSurvivorColor(target: Player): Color3
	return UITheme.getSurvivorColor(assignIndex(target))
end

function HudController:setVisible(value: boolean)
	state.visible = value
	if gui then
		gui.Enabled = value and not state.cinematic
	end
end

function HudController:isVisible(): boolean
	return state.visible and not state.cinematic
end

--[[ The end-of-round cards take the whole frame and a HUD showing through one
     reads as a bug. OverlayController owns this flag and pushes it; a wave
     announcement deliberately does NOT set it, because the game is still being
     played underneath that one. ]]
function HudController:setCinematic(value: boolean)
	state.cinematic = value
	if gui then
		gui.Enabled = state.visible and not value
	end
end

function HudController:setObjective(text: string, progress: number?)
	setObjective(text, progress)
end

--[[ Reserves the top of the screen for somebody else. WaveController's round
     clock lives at the same margin the objective line used to own, and the
     objective drops below whatever height it claims. ]]
function HudController:setTopInset(pixels: number)
	if typeof(pixels) ~= "number" then
		return
	end
	state.topInset = math.max(pixels, LAYOUT.ScreenMargin) + LAYOUT.ElementGap
	if objective then
		objective.frame.Position = UDim2.new(0.5, 0, 0, state.topInset)
	end
end

-- ── lifecycle ───────────────────────────────────────────────────────────────

function HudController:init()
	build()

	for _, target in Players:GetPlayers() do
		addPlayer(target)
	end
	trove:connect(Players.PlayerAdded, addPlayer)
	trove:connect(Players.PlayerRemoving, removePlayer)

	--[[
		ONE list, driving BOTH refreshers.

		These used to be two lists, and they disagreed: the ammo counter listened
		to the ammo attributes and the hotbar listened to the item ones. But the
		hotbar shows a per-slot round count too, so it read PrimaryAmmo without
		ever being told when it changed — the big number in the corner ticked down
		as you fired while the number on the slot itself sat frozen at whatever it
		said when you last picked something up.

		Splitting them saved nothing: every one of these attributes is written by
		the same publish on the same frame, so a change is one signal either way.
		Both panels read from the same loadout, so both should wake for all of it.
	]]
	for _, attribute in
		{
			LA.ActiveSlot,
			LA.PrimaryId,
			LA.PrimaryAmmo,
			LA.PrimaryReserve,
			LA.SecondaryId,
			LA.SecondaryAmmo,
			LA.IsReloading,
			LA.ThrowableId,
			LA.HealthItemId,
			LA.PillItemId,
			--[[ Not a loadout attribute, but it changes what the hotbar may draw:
			     going down locks every slot except the pistol, and without this
			     the bar keeps showing five live options until some unrelated
			     attribute happens to move. ]]
			PA.State,
		}
	do
		trove:connect(player:GetAttributeChangedSignal(attribute), function()
			refreshAmmo()
			refreshItems()
		end)
	end

	refreshAmmo()
	refreshItems()
end

function HudController:start()
	bindItemKeys()

	trove:connect(Remotes.Event.InventoryChanged.OnClientEvent, function(payload: any)
		if typeof(payload) ~= "table" then
			return
		end
		flashSlot(tostring(payload.slot or ""))
	end)

	--[[ A crate is a bigger moment than a pickup: it is the resupply you crossed
	     the map for, and it is gone for nearly three minutes afterwards. So it
	     says how many rounds it gave rather than just flashing a slot, and it
	     tells the whole team which crate went — a burned crate is information
	     everyone needs when they plan where to fall back to. ]]
	trove:connect(Remotes.Event.AmmoCrateUsed.OnClientEvent, function(payload: any)
		if typeof(payload) ~= "table" then
			return
		end
		if payload.player == player then
			local given = tonumber(payload.given) or 0
			setObjective(string.format("RESUPPLIED  +%d ROUNDS", given), nil)
			task.delay(2.5, function()
				if state.objectiveText:sub(1, 11) == "RESUPPLIED " then
					setObjective(Attributes.get(Workspace, GA.ObjectiveText, ""), nil)
				end
			end)
		end
	end)

	trove:connect(Remotes.Event.ObjectiveChanged.OnClientEvent, function(payload: any)
		if typeof(payload) ~= "table" then
			return
		end
		setObjective(tostring(payload.text or ""), payload.progress)
	end)

	-- The objective is also an attribute, so a player dropping into wave 5 sees
	-- it without waiting for the next time it changes.
	trove:connect(Workspace:GetAttributeChangedSignal(GA.ObjectiveText), function()
		setObjective(Attributes.get(Workspace, GA.ObjectiveText, ""), nil)
	end)
	setObjective(Attributes.get(Workspace, GA.ObjectiveText, ""), nil)

	trove:connect(Remotes.Event.KillFeed.OnClientEvent, pushKill)

	--[[
		The hotbar re-fits itself when the viewport changes.

		Driven off the scale layer's own size rather than off the camera, because
		the camera is replaced on death, on spectate and on rejoin — one connection
		here would become a stale one three times a round, and re-pointing it every
		time is machinery ScaleLayer already owns. Its frame resizes on exactly the
		events that matter and never goes away.
	]]
	trove:connect(root:GetPropertyChangedSignal("AbsoluteSize"), layoutHotbar)
	layoutHotbar()

	--[[ Money, from the balance moving rather than from a remote. See EARN_Y. ]]
	local store = Registry.find("ProfileController")
	if store and store.earned then
		trove:add(store.earned:connect(function(amount: number)
			showEarned(amount)
			refreshWallet(true)
		end))
	end
	--[[ And the corner total off `changed`, which also fires for a purchase and
	     for the first sync — the two moments `earned` deliberately does not. ]]
	if store and store.changed then
		trove:add(store.changed:connect(function()
			refreshWallet(false)
		end))
	end
	refreshWallet(false)

	trove:connect(Remotes.Event.Notice.OnClientEvent, function(payload: any)
		if typeof(payload) ~= "table" then
			return
		end
		local text = tostring(payload.text or "")
		if text == "" then
			return
		end
		notice.label.Text = string.upper(text)
		notice.label.TextColor3 = if tostring(payload.tone) == "Good" then COLOR.Accent else COLOR.Danger
		notice.label.TextTransparency = 0
		notice.label.TextStrokeTransparency = 0.4
		notice.label.Visible = true
		notice.until_ = os.clock() + NOTICE_SECONDS
	end)

	--[[
		The predicted half of the ammo counter.

		WeaponController drops the count on the frame the trigger goes and fires
		these; the attributes catch up a round trip later and refresh it again
		through the subscriptions in init(). Both paths call the same two
		functions, so a disagreement resolves the moment the server answers
		rather than needing its own reconciliation here.

		Connected defensively because WeaponController is the one controller the
		HUD reaches for that can fail to load — its start() touches the network
		manifest — and a HUD with a slightly late ammo count is worth far more
		than no HUD at all.
	]]
	--[[ Glyphs follow the input the player is holding. A console player who plugs
	     in a keyboard mid-round gets keyboard glyphs; a desktop player who picks
	     up a pad gets the D-pad arrows, which matter here because the pad layout
	     deliberately does not mirror the 1-5 row. ]]
	local inputController = Registry.find("InputController")
	if inputController and inputController.schemeChanged then
		trove:add(inputController.schemeChanged:connect(bindItemKeys))
	end

	local weapons = Registry.find("WeaponController")
	if weapons then
		local function repaint()
			refreshAmmo()
			refreshItems()
		end
		if weapons.ammoChanged then
			trove:connect(weapons.ammoChanged, repaint)
		end
		if weapons.weaponChanged then
			trove:connect(weapons.weaponChanged, repaint)
		end
	else
		warn(
			"[HudController] WeaponController is missing; the ammo counter will lag the server by a round trip"
		)
	end

	trove:connect(RunService.RenderStepped, update)
end

function HudController:onInitialState(payload: any)
	if typeof(payload) ~= "table" then
		return
	end
	if typeof(payload.objective) == "string" then
		setObjective(payload.objective, nil)
	end
	for _, record in panels do
		refreshPanel(record)
	end
	refreshAmmo()
	refreshItems()
end

function HudController:destroy()
	for target in panels do
		removePlayer(target)
	end
	table.clear(killFeed)
	trove:destroy()
end

Registry.register("HudController", HudController)

return HudController
