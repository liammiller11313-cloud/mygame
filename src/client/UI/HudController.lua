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
	Everything is attributes and their changed signals. Nothing here polls a
	value, and nothing here asks a service for state it could read off a Player.
	Attributes replicate on write, so a HUD driven by them costs zero bandwidth
	while nothing is happening, which during a breather and most of a wave is
	most of the time.

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
local Enums = require(Shared.Enums)
local GameConfig = require(Shared.Config.GameConfig)
local InfectedConfig = require(Shared.Config.InfectedConfig)
local Registry = require(Shared.Util.Registry)
local Remotes = require(Shared.Net.Remotes)
local Trove = require(Shared.Util.Trove)
local UITheme = require(Shared.Config.UITheme)
local WeaponConfig = require(Shared.Config.WeaponConfig)

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

local ITEM_SLOTS = { SLOT.Throwable, SLOT.Health, SLOT.Pills }

local HudController = {}

local player = Players.LocalPlayer
local trove = Trove.new()

local gui: ScreenGui
local panelHolder: Frame
local ammo: {
	panel: Frame,
	name: TextLabel,
	mag: TextLabel,
	reserve: TextLabel,
	reloading: TextLabel,
}
local itemSlots: { [string]: { frame: Frame, key: TextLabel, label: TextLabel, stroke: UIStroke } } = {}
local objective: { frame: Frame, label: TextLabel, bar: Frame, fill: Frame }
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
	objectiveText = "",
	-- How much of the top of the screen WaveController has claimed. Pushed in
	-- rather than read, so the HUD needs to know nothing about waves.
	topInset = LAYOUT.ScreenMargin,
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

local function newFrame(parent: Instance, name: string, color: Color3?, transparency: number?): Frame
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.BackgroundColor3 = color or COLOR.Panel
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
	label.BorderSizePixel = 0
	label.Font = font
	label.TextSize = size
	label.TextColor3 = color
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Center
	label.Text = ""
	label.Parent = parent
	return label
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

--[[
	The printable glyph for a bound key. Roblox's KeyCode values for letters and
	digits ARE their ASCII codes, so the common cases turn into "E" and "3"
	without a lookup table; anything else (LeftShift, MouseButton3) falls back to
	its name, which is at least honest.
]]
local function keyGlyph(keys: { any }): string
	for _, key in keys do
		if typeof(key) == "EnumItem" and key.EnumType == Enum.KeyCode then
			local value = key.Value
			if (value >= 48 and value <= 57) or (value >= 97 and value <= 122) then
				return string.upper(string.char(value))
			end
		end
	end
	for _, key in keys do
		if typeof(key) == "EnumItem" then
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

	local frame = newFrame(panelHolder, "Survivor_" .. target.Name, COLOR.Panel, 0.12)
	frame.AnchorPoint = Vector2.new(0, 1)
	frame.Size = UDim2.fromOffset(LAYOUT.SurvivorPanelWidth, LAYOUT.SurvivorPanelHeight)
	frame.Position = UDim2.fromOffset(0, 0)
	corner(frame)
	local border = stroke(frame, target == player and COLOR.BorderBright or COLOR.Border)

	local stripe = newFrame(frame, "Stripe", identity)
	stripe.Size = UDim2.new(0, STRIPE_WIDTH, 1, 0)

	local contentX = STRIPE_WIDTH + LAYOUT.PanelPadding
	local rightInset = contentX + LAYOUT.PanelPadding

	local name = newLabel(frame, "Name", FONT.Heading, TEXT.Body, COLOR.TextPrimary)
	name.Position = UDim2.fromOffset(contentX, 3)
	name.Size = UDim2.new(1, -(rightInset + 72), 0, 18)
	name.TextTruncate = Enum.TextTruncate.AtEnd
	name.Text = string.upper(target.DisplayName)

	local status = newLabel(frame, "Status", FONT.Body, TEXT.Tiny, COLOR.TextSecondary)
	status.AnchorPoint = Vector2.new(1, 0)
	status.Position = UDim2.new(1, -LAYOUT.PanelPadding, 0, 4)
	status.Size = UDim2.fromOffset(70, 16)
	status.TextXAlignment = Enum.TextXAlignment.Right

	local barBg = newFrame(frame, "Bar", COLOR.Background)
	barBg.Position = UDim2.new(0, contentX, 1, -(LAYOUT.HealthBarHeight + 7))
	barBg.Size = UDim2.new(1, -rightInset, 0, LAYOUT.HealthBarHeight)
	barBg.ClipsDescendants = true
	corner(barBg)

	local perm = newFrame(barBg, "Permanent", COLOR.HealthGood)
	perm.Size = UDim2.new(0, 0, 1, 0)

	-- Drawn after (and therefore over) the permanent fill, starting where it
	-- ends. This is the white pill buffer.
	local temp = newFrame(barBg, "Temp", COLOR.HealthTemp)
	temp.Size = UDim2.new(0, 0, 1, 0)

	-- The revive clock, along the bottom edge of the bar so it cannot be
	-- mistaken for health returning.
	local revive = newFrame(barBg, "Revive", COLOR.AccentBright)
	revive.AnchorPoint = Vector2.new(0, 1)
	revive.Position = UDim2.new(0, 0, 1, 0)
	revive.Size = UDim2.new(0, 0, 0, 3)

	local deadX = newFrame(frame, "DeadX", COLOR.Danger, 1)
	deadX.Size = UDim2.new(1, 0, 1, 0)
	deadX.Visible = false
	for sign = -1, 1, 2 do
		local slash = newFrame(deadX, "Slash", COLOR.Danger, 0.25)
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

--[[ Which weapon the counter is describing, straight off the loadout
     attributes. Returns a reserve of -1 for "infinite", which is what a pistol
     carries and what the counter draws as a dash rather than a number. ]]
local function activeWeapon(): (string, number, number)
	local slot = Attributes.get(player, LA.ActiveSlot, SLOT.Primary)
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
		ammo.reserve.Text = ""
		ammo.panel.Visible = true
		return
	end

	ammo.name.Text = string.upper(definition.displayName)
	ammo.panel.Visible = true

	if definition.magSize <= 0 then
		-- Melee. No magazine to count, and a "0" here would read as empty.
		ammo.mag.Text = "—"
		ammo.mag.TextColor3 = COLOR.TextPrimary
		ammo.reserve.Text = ""
		return
	end

	ammo.mag.Text = tostring(magazine)
	ammo.mag.TextColor3 = if magazine <= math.max(definition.magSize * LOW_AMMO_FRACTION, 1)
		then COLOR.Danger
		else COLOR.TextPrimary
	ammo.reserve.Text = if reserve < 0 then "/ ∞" else "/ " .. tostring(reserve)
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

local function refreshItems()
	local active = Attributes.get(player, LA.ActiveSlot, SLOT.Primary)
	for _, slot in ITEM_SLOTS do
		local entry = itemSlots[slot]
		local flash = flashAmount(slot)
		local itemId = ""
		if slot == SLOT.Throwable then
			itemId = Attributes.get(player, LA.ThrowableId, "")
		elseif slot == SLOT.Health then
			itemId = Attributes.get(player, LA.HealthItemId, "")
		else
			itemId = Attributes.get(player, LA.PillItemId, "")
		end

		local filled = itemId ~= ""
		entry.label.Text = if filled then itemLabel(itemId) else "—"
		entry.label.TextColor3 = if filled then COLOR.TextPrimary else COLOR.TextDim
		entry.key.TextColor3 = if filled then COLOR.TextSecondary else COLOR.TextDim
		entry.frame.BackgroundTransparency = if filled then 0.15 else 0.55

		local base = if slot == active and filled
			then COLOR.Accent
			elseif filled then COLOR.BorderBright
			else COLOR.Border

		-- The flash rides on top of whatever the slot's resting colour is, so a
		-- pickup reads the same whether the slot was empty, full, or selected.
		if flash > 0 then
			entry.stroke.Color = base:Lerp(COLOR.AccentBright, flash)
			entry.stroke.Thickness = LAYOUT.BorderThickness + flash * 1.5
			entry.frame.BackgroundTransparency = (if filled then 0.15 else 0.55) * (1 - flash * 0.6)
		else
			entry.stroke.Color = base
			entry.stroke.Thickness = LAYOUT.BorderThickness
		end
	end
end

local function bindItemKeys()
	local input = Registry.find("InputController")
	if not input or typeof(input.getBindings) ~= "function" then
		return
	end
	local ok, bindings = pcall(input.getBindings, input)
	if not ok or typeof(bindings) ~= "table" then
		return
	end
	for _, binding in bindings do
		local entry = binding.slot and itemSlots[binding.slot]
		if entry then
			entry.key.Text = keyGlyph(binding.keys)
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
     the feed is the only part still true. ]]
local function acquireRow(): TextLabel
	local free = table.remove(killFeedPool)
	if free then
		return free
	end
	local oldest = table.remove(killFeed, 1)
	return (oldest :: any).label
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
	local panel = newFrame(gui, "Ammo", COLOR.Panel, 0.12)
	panel.AnchorPoint = Vector2.new(1, 1)
	panel.Position = UDim2.new(1, -LAYOUT.ScreenMargin, 1, -LAYOUT.ScreenMargin)
	panel.Size = UDim2.fromOffset(LAYOUT.AmmoPanelWidth, LAYOUT.AmmoPanelHeight)
	corner(panel)
	stroke(panel)

	--[[ Sixteen real guns means names like "Kriss Vector .45" where the old
	     roster had "SMG". Truncation would hide the half of ".357 Magnum" that
	     identifies it, so the name scales itself down to TextSize.Tiny instead
	     and every weapon in the roster fits at a glance. ]]
	local name = newLabel(panel, "Weapon", FONT.Heading, TEXT.Small, COLOR.TextSecondary)
	name.Position = UDim2.fromOffset(LAYOUT.PanelPadding, 5)
	name.Size = UDim2.new(1, -LAYOUT.PanelPadding * 2, 0, 16)
	name.TextXAlignment = Enum.TextXAlignment.Right
	name.TextScaled = true
	name.TextWrapped = false
	local nameBounds = Instance.new("UITextSizeConstraint")
	nameBounds.MaxTextSize = TEXT.Small
	nameBounds.MinTextSize = TEXT.Tiny
	nameBounds.Parent = name

	local reloading = newLabel(panel, "Reloading", FONT.Body, TEXT.Small, COLOR.Accent)
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
	local reserve = newLabel(panel, "Reserve", FONT.Numeric, TEXT.Large, COLOR.TextSecondary)
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

	local magazine = newLabel(panel, "Magazine", FONT.Numeric, TEXT.Display, COLOR.TextPrimary)
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

	ammo = { panel = panel, name = name, mag = magazine, reserve = reserve, reloading = reloading }
end

local function buildItems()
	local holder = newFrame(gui, "Items", COLOR.Panel, 1)
	holder.AnchorPoint = Vector2.new(0.5, 1)
	holder.Position = UDim2.new(0.5, 0, 1, -LAYOUT.ScreenMargin)
	holder.Size = UDim2.fromOffset(
		#ITEM_SLOTS * LAYOUT.ItemSlotSize + (#ITEM_SLOTS - 1) * LAYOUT.ItemSlotGap,
		LAYOUT.ItemSlotSize
	)

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, LAYOUT.ItemSlotGap)
	layout.Parent = holder

	for order, slot in ITEM_SLOTS do
		local frame = newFrame(holder, slot, COLOR.Panel, 0.55)
		frame.LayoutOrder = order
		frame.Size = UDim2.fromOffset(LAYOUT.ItemSlotSize, LAYOUT.ItemSlotSize)
		corner(frame)
		local line = stroke(frame)

		local key = newLabel(frame, "Key", FONT.Body, TEXT.Tiny, COLOR.TextDim)
		key.Position = UDim2.fromOffset(4, 2)
		key.Size = UDim2.fromOffset(16, 12)

		local label = newLabel(frame, "Label", FONT.Body, TEXT.Tiny, COLOR.TextDim)
		label.AnchorPoint = Vector2.new(0.5, 1)
		label.Position = UDim2.new(0.5, 0, 1, -3)
		label.Size = UDim2.new(1, -6, 0, 26)
		label.TextXAlignment = Enum.TextXAlignment.Center
		label.TextYAlignment = Enum.TextYAlignment.Bottom
		label.TextWrapped = true

		itemSlots[slot] = { frame = frame, key = key, label = label, stroke = line }
	end
end

local function buildObjective()
	local frame = newFrame(gui, "Objective", COLOR.Panel, 1)
	frame.AnchorPoint = Vector2.new(0.5, 0)
	frame.Position = UDim2.new(0.5, 0, 0, state.topInset)
	frame.Size = UDim2.fromOffset(560, 28)
	frame.Visible = false

	local label = newLabel(frame, "Text", FONT.Heading, TEXT.Body, COLOR.Accent)
	label.AnchorPoint = Vector2.new(0.5, 0)
	label.Position = UDim2.fromScale(0.5, 0)
	label.Size = UDim2.new(1, 0, 0, 20)
	label.TextXAlignment = Enum.TextXAlignment.Center

	local bar = newFrame(frame, "Progress", COLOR.Background)
	bar.AnchorPoint = Vector2.new(0.5, 0)
	bar.Position = UDim2.new(0.5, 0, 0, 22)
	bar.Size = UDim2.fromOffset(220, 2)
	bar.Visible = false

	local fill = newFrame(bar, "Fill", COLOR.Accent)
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

	panelHolder = newFrame(gui, "Survivors", COLOR.Panel, 1)
	panelHolder.AnchorPoint = Vector2.new(0, 1)
	panelHolder.Position = UDim2.new(0, LAYOUT.ScreenMargin, 1, -LAYOUT.ScreenMargin)
	panelHolder.Size = UDim2.fromOffset(
		LAYOUT.SurvivorPanelWidth,
		MAX_SURVIVORS * (LAYOUT.SurvivorPanelHeight + LAYOUT.SurvivorPanelGap)
	)

	--[[ Fixed height and clipped, so no volume of kills can grow the feed down
	     the side of the screen and into the play space. The rows it can hold are
	     the rows that exist. ]]
	killFeedHolder = newFrame(gui, "KillFeed", COLOR.Panel, 1)
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
		local row = newLabel(killFeedHolder, "Kill", FONT.Body, TEXT.Small, COLOR.TextPrimary)
		row.RichText = true
		row.Size = UDim2.new(1, 0, 0, KILLFEED_ROW_HEIGHT)
		row.TextXAlignment = Enum.TextXAlignment.Right
		row.Visible = false
		table.insert(killFeedPool, row)
	end

	buildAmmo()
	buildItems()
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

	for _, attribute in
		{
			LA.ActiveSlot,
			LA.PrimaryId,
			LA.PrimaryAmmo,
			LA.PrimaryReserve,
			LA.SecondaryId,
			LA.SecondaryAmmo,
			LA.IsReloading,
		}
	do
		trove:connect(player:GetAttributeChangedSignal(attribute), refreshAmmo)
	end
	for _, attribute in { LA.ThrowableId, LA.HealthItemId, LA.PillItemId, LA.ActiveSlot } do
		trove:connect(player:GetAttributeChangedSignal(attribute), refreshItems)
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
