--!nonstrict
--[[
	BackpackController — your kit in full, and what your squad is carrying.

	── WHAT THE HOTBAR ALREADY DOES ────────────────────────────────────────────
	Six tiles in the corner, one per slot, each with a truncated name and a bare
	number. It is a good glance-readout and this screen does not replace it.

	── WHAT NOTHING DOES ───────────────────────────────────────────────────────
	Two things, and they are the reason this exists.

	The first is teammates. Every survivor panel in the game carries a health
	bar, a state and a revive clock, and not one byte about equipment. So "does
	anybody have a medkit", which is the single most-asked question in a co-op
	zombie game, is a question the interface does not take. A team answers it by
	typing it into chat while something is chasing them.

	The second is what your own gear actually IS. A hotbar tile says "AK-74" and
	stops. It does not say it is a rifle, that it hits for 33, or that the medkit
	in the slot beside it heals four fifths of what you are missing. That information exists — it is in WeaponConfig and GameConfig, and
	the shop shows it — but the shop is a menu you cannot open mid-round, so
	between the safe room and the finale there is nowhere to find it out.

	── IT IS PURELY A READOUT ───────────────────────────────────────────────────
	Nothing here is interactive and nothing here is sent. No item is used, no
	slot is switched, no request crosses the wire. That is deliberate: a screen
	you open mid-round while something is chasing you must not be a screen you
	can fumble a medkit away on. The hotbar and the heal key already own using
	things.

	── AND IT COSTS NO NETWORK ──────────────────────────────────────────────────
	Every number on it is already on this client. Loadout ids ride
	Attributes.Loadout on the Player instance, which Roblox replicates to
	everybody — the same property the ammo counter reads for you is readable for
	your teammates, and always was. See Shared/Net/Attributes: that is the reason
	those attributes live on the Player rather than behind a remote.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attributes = require(Shared.Net.Attributes)
local AudioConfig = require(Shared.Config.AudioConfig)
local Enums = require(Shared.Enums)
local GameConfig = require(Shared.Config.GameConfig)
local Registry = require(Shared.Util.Registry)
local Trove = require(Shared.Util.Trove)
local UITheme = require(Shared.Config.UITheme)
local WeaponConfig = require(Shared.Config.WeaponConfig)

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
local LA = Attributes.Loadout
local PA = Attributes.Player
local SLOT = Enums.Slot
local STATE = Enums.SurvivorState
local THROWABLE = Enums.Throwable
local HEALTH_ITEM = Enums.HealthItem
local PILL_ITEM = Enums.PillItem

local player = Players.LocalPlayer

local PANEL_WIDTH = 800
local PANEL_MAX_HEIGHT = 560
local HEADER_HEIGHT = PANEL.HeaderHeight

--[[ Your kit on the left, the squad on the right. A fraction so it survives a
     phone, the same way every other split in this interface does. ]]
local KIT_WIDTH = 0.53
local COLUMN_GAP = 14
local CAPTION_HEIGHT = 20

--[[ Three stacked lines — slot, name, stats — plus the margin around them, so
     the row is derived from the type rather than a number that has to be kept
     in step with it.

     The touch row is taller for legibility rather than for a thumb. Nothing on
     this panel is pressable, but on a phone the whole thing is drawn at
     ScaleLayer's 0.75 floor, which turns 57 reference pixels into 43 real ones
     for three lines of type. ]]
local KIT_CONTENT_HEIGHT = (TEXT.Tiny + 2) + (TEXT.Body + 2) + (TEXT.Tiny + 2)
local ROW_HEIGHT = KIT_CONTENT_HEIGHT + 10
local ROW_HEIGHT_TOUCH = KIT_CONTENT_HEIGHT + 18

-- Two lines: the name, and what they are carrying.
local SQUAD_CONTENT_HEIGHT = (TEXT.Body + 4) + (TEXT.Small + 2)
local SQUAD_ROW_HEIGHT = SQUAD_CONTENT_HEIGHT + 10
local SQUAD_ROW_HEIGHT_TOUCH = PANEL.RowHeightTouch

local BODY_TOP = HEADER_HEIGHT + LAYOUT.PanelPadding + CAPTION_HEIGHT

--[[
	The six slots, in the order the hotbar draws them.

	Deliberately the same order. This screen and the hotbar describe the same
	kit, and a player glancing between them should not have to re-find anything.
]]
local KIT_SLOTS = {
	{
		slot = SLOT.Primary,
		title = "PRIMARY",
		id = LA.PrimaryId,
		ammo = LA.PrimaryAmmo,
		reserve = LA.PrimaryReserve,
	},
	{ slot = SLOT.Secondary, title = "SIDEARM", id = LA.SecondaryId, ammo = LA.SecondaryAmmo },
	{ slot = SLOT.Melee, title = "MELEE", id = LA.MeleeId },
	{ slot = SLOT.Throwable, title = "THROWABLE", id = LA.ThrowableId },
	{ slot = SLOT.Health, title = "HEALTH", id = LA.HealthItemId },
	{ slot = SLOT.Pills, title = "PILLS", id = LA.PillItemId },
}

--[[ What a teammate's row reports, and in the order somebody scanning for help
     wants it: the thing that saves a life, then the thing that buys time, then
     the thing that clears a room. Their guns are not here on purpose — you
     cannot borrow a rifle, so it is not information you can act on. ]]
local SQUAD_SLOTS = {
	{ short = "KIT", id = LA.HealthItemId },
	{ short = "PILLS", id = LA.PillItemId },
	{ short = "THROW", id = LA.ThrowableId },
}

--[[
	The stat line for the things WeaponConfig does not describe.

	The consumables have no config of their own — a medkit is a number in
	GameConfig.Survivor and a molotov is behaviour in ProjectileService — so the
	numbers that exist are read from where they live rather than retyped, and
	the ones that only exist as behaviour are described in words. A wrong number
	is worse than a sentence.
]]
local SURVIVOR = GameConfig.Survivor
local ITEM_DETAIL: { [string]: string } = {
	[HEALTH_ITEM.Medkit] = string.format(
		"HEALS %d%% OF WHAT YOU ARE MISSING · %.0fS",
		math.floor(SURVIVOR.MedkitHealPercent * 100 + 0.5),
		SURVIVOR.MedkitUseTime
	),
	[HEALTH_ITEM.Defibrillator] = "BRINGS A DEAD SURVIVOR BACK. ONE USE.",
	[PILL_ITEM.PainPills] = string.format("%d TEMPORARY HEALTH, DRAINING", SURVIVOR.PillHealth),
	--[[ Leads with RUN, not with the health. The 25 is the least of what this
	     does and reads as a worse pill bottle next to the 50 above it — what a
	     player needs told is that it is the item that gets a hurt survivor
	     moving, which is the reason to be holding one. ]]
	[PILL_ITEM.Adrenaline] = string.format(
		"RUN AND ACT FASTER FOR %.0fS, HURT OR NOT · %d TEMPORARY HEALTH",
		SURVIVOR.AdrenalineDuration,
		SURVIVOR.AdrenalineHealth
	),
	[THROWABLE.PipeBomb] = "DRAWS THE HORDE TO IT, THEN KILLS THEM",
	[THROWABLE.Molotov] = "A WALL OF FIRE THAT BURNS WHAT CROSSES IT",
	[THROWABLE.BileJar] = "TURNS THE HORDE ON WHATEVER IT LANDS ON",
	--[[ Deliberately says WHERE rather than what, because that is the whole
	     difference from the jar above it and a player reading both lines back to
	     back should be able to see it. The jar names a target; this names a
	     place, and the long duration is the reason to carry one. ]]
	[THROWABLE.HazardousWaste] = "A LEAK THAT HOLDS THE HORDE WHERE YOU PUT IT",
}

local BackpackController = {}

local trove = Trove.new()
local rowTrove = Trove.new()

local gui: ScreenGui
local panel: Frame
local closeButton: TextButton
local kitList: ScrollingFrame
local squadList: ScrollingFrame
local footRule: Frame
local hint: TextLabel

local state = {
	open = false,
	suppressed = false,
}

local restore = {
	cameraMode = nil :: any,
	cameraZoom = nil :: any,
	cameraMinZoom = nil :: any,
	mouseIcon = nil :: any,
}

type KitRow = { frame: Frame, value: TextLabel, detail: TextLabel, count: TextLabel }
local kitRows: { KitRow } = {}

-- ── helpers ─────────────────────────────────────────────────────────────────

local function callController(name: string, method: string, ...: any)
	local controller = Registry.find(name)
	if controller and typeof(controller[method]) == "function" then
		pcall(controller[method], controller, ...)
	end
end

local function isTouch(): boolean
	local input = Registry.find("InputController")
	if not input or typeof(input.isTouchScheme) ~= "function" then
		return false
	end
	local ok, touch = pcall(input.isTouchScheme, input)
	return ok and touch == true
end

--[[ Whether a key is the one that opens this panel. Asked rather than assumed,
     because the binding is rebindable: a player who moved BACKPACK off B should
     still be able to press their own key to put it away. ]]
local function boundToBackpack(keyCode: Enum.KeyCode): boolean
	local controller = Registry.find("InputController")
	if not controller or typeof(controller.getBindings) ~= "function" then
		return false
	end
	local ok, bindings = pcall(controller.getBindings, controller)
	if not ok or typeof(bindings) ~= "table" then
		return false
	end
	for _, binding in bindings do
		if binding.action == "Backpack" then
			for _, key in binding.keys do
				if key == keyCode then
					return true
				end
			end
		end
	end
	return false
end

local function menuIsOpen(): boolean
	local menu = Registry.find("MainMenuController")
	if not menu or typeof(menu.isOpen) ~= "function" then
		return false
	end
	local ok, open = pcall(menu.isOpen, menu)
	return ok and open == true
end

local function setSuppressed(value: boolean)
	if state.suppressed == value then
		return
	end
	state.suppressed = value
	callController("InputController", "setEnabled", not value)
	callController("CrosshairController", "setVisible", not value)
	callController("PromptController", "setEnabled", not value)
	callController("TouchController", "setVisible", not value)
end

local function claimCursor(value: boolean)
	if value then
		FreeCursor.take(restore)
	else
		FreeCursor.giveBack(restore)
	end
end

--[[ A weapon's real name, or an item id turned into words. Weapons come from
     WeaponConfig so this screen can never disagree with the shop about what a
     gun is called; the consumables have no config, so "PainPills" is split on
     the capital exactly the way the hotbar does it. ]]
local function labelFor(itemId: string): string
	if itemId == "" then
		return ""
	end
	local definition = WeaponConfig.get(itemId)
	if definition then
		return string.upper(definition.displayName)
	end
	return string.upper((string.gsub(itemId, "(%l)(%u)", "%1 %2")))
end

--[[ The line under the name. For a gun it is built from the same definition the
     shop reads, so the two can never disagree; for everything else it comes out
     of ITEM_DETAIL above. ]]
local function detailFor(itemId: string): string
	if itemId == "" then
		return ""
	end
	local definition = WeaponConfig.get(itemId)
	if not definition then
		return ITEM_DETAIL[itemId] or ""
	end
	local parts = { string.upper(definition.class) }
	--[[ A shotgun's per-pellet damage on its own is a lie by a factor of eight,
	     so the pellet count travels with it or neither number goes out. ]]
	if definition.pellets > 1 then
		table.insert(parts, string.format("%d × %d DMG", definition.pellets, definition.damage))
	else
		table.insert(parts, string.format("%d DMG", definition.damage))
	end
	-- A melee has no rate of fire worth printing, and no magazine at all.
	if definition.magSize > 0 then
		table.insert(parts, string.format("%d RND MAG", definition.magSize))
	end
	if definition.rpm > 0 and definition.slot ~= SLOT.Melee then
		table.insert(parts, string.format("%d RPM", definition.rpm))
	end
	return table.concat(parts, " · ")
end

-- ── drawing ─────────────────────────────────────────────────────────────────

local function refreshKit()
	for index, entry in KIT_SLOTS do
		local row = kitRows[index]
		if not row then
			break
		end
		local itemId = tostring(Attributes.get(player, entry.id, "") or "")
		local empty = itemId == ""

		--[[ An empty slot is NAMED rather than blanked, the same as the hotbar
		     does it: a slot that says what it is for still teaches a new player
		     that the slot exists, and a blank row teaches nothing. ]]
		row.value.Text = if empty then "EMPTY" else labelFor(itemId)
		row.value.TextColor3 = if empty then COLOR.TextDim else COLOR.TextPrimary
		row.detail.Text = detailFor(itemId)
		row.frame.BackgroundTransparency = if empty then 0.62 else PANEL.RaisedFill

		if empty then
			row.count.Text = ""
		elseif entry.ammo then
			local magazine = tonumber(Attributes.get(player, entry.ammo, 0)) or 0
			--[[ The number this screen is worth opening for on a phone, where the
			     hotbar tile is drawn at 0.75 and its count is six pixels tall. ]]
			local spare = if entry.reserve
				then tonumber(Attributes.get(player, entry.reserve, 0)) or 0
				else -1
			--[[ Only a primary has a finite reserve. Sidearms are bottomless by
			     design, so a number there would be a lie — the infinity is what
			     the HUD prints for the same case. ]]
			row.count.Text = if spare >= 0
				then string.format("%d / %d", magazine, spare)
				else string.format("%d / ∞", magazine)
			row.count.TextColor3 = if magazine == 0 then COLOR.Danger else COLOR.TextSecondary
		else
			row.count.Text = "CARRIED"
			row.count.TextColor3 = COLOR.TextDim
		end
	end
end

--[[ One row per OTHER survivor. Rebuilt rather than written into, because who is
     in the round changes and a stale row is worse than no row — "somebody has a
     medkit" is a thing a team will act on. ]]
local function refreshSquad()
	rowTrove:clean()

	local rowHeight = if isTouch() then SQUAD_ROW_HEIGHT_TOUCH else SQUAD_ROW_HEIGHT
	local order = 0
	for _, other in Players:GetPlayers() do
		if other == player then
			continue
		end
		--[[ Spectators and the infected half of a Versus match are not carrying
		     anything anybody can ask for. Same test the HUD roster uses. ]]
		local survivorState = Attributes.get(other, PA.State, STATE.Spectating)
		if survivorState == STATE.Spectating then
			continue
		end

		order += 1
		local row = Widgets.frame(squadList, "Mate" .. order, COLOR.PanelRaised, PANEL.RaisedFill)
		row.LayoutOrder = order
		row.Size = UDim2.new(1, -PANEL.ScrollBarWidth - 2, 0, rowHeight)
		Widgets.stroke(row, COLOR.Border)
		rowTrove:add(row)

		local edge = Widgets.frame(row, "Edge", COLOR.Border, 0)
		edge.Size = UDim2.new(0, LAYOUT.BorderThickness * 2, 1, 0)

		-- Centred as a block, for the same reason the kit rows are. See buildKitRow.
		local body = Widgets.frame(row, "Body", nil, 1)
		body.AnchorPoint = Vector2.new(0, 0.5)
		body.Position = UDim2.new(0, LAYOUT.PanelPadding + 4, 0.5, 0)
		body.Size = UDim2.new(1, -(LAYOUT.PanelPadding * 2 + 4), 0, SQUAD_CONTENT_HEIGHT)

		local name = Widgets.label(body, "Name", FONT.Heading, TEXT.Body, COLOR.TextPrimary)
		name.Size = UDim2.new(0.62, 0, 0, TEXT.Body + 2)
		name.TextTruncate = Enum.TextTruncate.AtEnd
		name.Text = string.upper(other.DisplayName)

		--[[ Their condition, beside their name, because what somebody on the floor
		     is carrying is exactly what you want to know — you are about to be
		     standing over them, and their medkit is the one you should use. ]]
		local condition = Widgets.label(body, "State", FONT.Body, TEXT.Tiny, COLOR.TextDim)
		condition.AnchorPoint = Vector2.new(1, 0)
		condition.Position = UDim2.new(1, 0, 0, 3)
		condition.Size = UDim2.new(0.38, 0, 0, TEXT.Tiny + 2)
		condition.TextXAlignment = Enum.TextXAlignment.Right

		if survivorState == STATE.Dead then
			condition.Text = "DEAD"
			condition.TextColor3 = COLOR.TextDim
			name.TextColor3 = COLOR.TextDim
		elseif survivorState == STATE.Incapacitated or survivorState == STATE.LedgeHanging then
			condition.Text = "DOWN"
			condition.TextColor3 = COLOR.HealthCritical
			name.TextColor3 = COLOR.HealthCritical
		elseif survivorState == STATE.Pinned then
			condition.Text = "PINNED"
			condition.TextColor3 = COLOR.HealthCritical
			name.TextColor3 = COLOR.HealthCritical
		elseif survivorState == STATE.Hurt then
			condition.Text = "HURT"
			condition.TextColor3 = COLOR.HealthHurt
		end

		local carried = Widgets.label(body, "Carried", FONT.Body, TEXT.Small, COLOR.TextSecondary)
		carried.Position = UDim2.fromOffset(0, TEXT.Body + 4)
		carried.Size = UDim2.new(1, 0, 0, TEXT.Small + 2)
		carried.TextTruncate = Enum.TextTruncate.AtEnd

		local parts = {}
		for _, want in SQUAD_SLOTS do
			local itemId = tostring(Attributes.get(other, want.id, "") or "")
			if itemId ~= "" then
				table.insert(parts, want.short .. " " .. labelFor(itemId))
			end
		end
		if #parts == 0 then
			carried.Text = "CARRYING NOTHING"
			carried.TextColor3 = COLOR.TextDim
		else
			carried.Text = table.concat(parts, "   ")
			carried.TextColor3 = COLOR.TextSecondary
		end
	end

	if order == 0 then
		local alone = Widgets.label(squadList, "Alone", FONT.Body, TEXT.Small, COLOR.TextDim)
		alone.Size = UDim2.new(1, -PANEL.ScrollBarWidth - 2, 0, 40)
		alone.TextWrapped = true
		alone.Text = "NOBODY ELSE IS OUT THERE."
		rowTrove:add(alone)
	end
end

-- ── build ───────────────────────────────────────────────────────────────────

--[[ Applied on open rather than once at build, because a player can pick up a
     controller or put down a phone between two rounds and the panel is rebuilt
     for nobody. ]]
local function applyTouchSizing()
	local touch = isTouch()
	local rowHeight = if touch then ROW_HEIGHT_TOUCH else ROW_HEIGHT
	for _, row in kitRows do
		row.frame.Size = UDim2.new(1, -PANEL.ScrollBarWidth - 2, 0, rowHeight)
	end

	--[[ The footer holds no button on this screen, so unlike the shop and the
	     career panel it does not have to grow to fit one — it only has to keep
	     a line of type legible at 0.75. ]]
	local foot = PANEL.FooterHeight
	if footRule then
		footRule.Position = UDim2.new(0, 0, 1, -foot)
	end
	if hint then
		hint.Size = UDim2.new(1, -LAYOUT.PanelPadding * 2, 0, foot)
	end

	local bodyHeight = -(BODY_TOP + foot + LAYOUT.PanelPadding)
	if kitList then
		kitList.Size = UDim2.new(KIT_WIDTH, -LAYOUT.PanelPadding, 1, bodyHeight)
	end
	if squadList then
		squadList.Size = UDim2.new(1 - KIT_WIDTH, -(LAYOUT.PanelPadding * 2 + COLUMN_GAP), 1, bodyHeight)
	end
end

local function refreshPanelSize()
	if not panel then
		return
	end
	local camera = Workspace.CurrentCamera
	local factor = ScaleLayer.getFactor()
	local viewport = if camera and factor > 0 then camera.ViewportSize / factor else nil
	local width = math.min(
		PANEL_WIDTH,
		math.max((if viewport then viewport.X else PANEL_WIDTH) - LAYOUT.ScreenMargin * 2, 300)
	)
	local height =
		math.min(PANEL_MAX_HEIGHT, (if viewport then viewport.Y else PANEL_MAX_HEIGHT) * PANEL.HeightScale)
	panel.Size = UDim2.fromOffset(width, height)
end

local function buildKitRow(index: number, entry: any)
	local row = Widgets.frame(kitList, entry.slot, COLOR.PanelRaised, PANEL.RaisedFill)
	row.LayoutOrder = index
	row.Size = UDim2.new(1, -PANEL.ScrollBarWidth - 2, 0, ROW_HEIGHT)
	Widgets.stroke(row, COLOR.Border)

	local edge = Widgets.frame(row, "Edge", COLOR.Accent, 0)
	edge.Size = UDim2.new(0, LAYOUT.BorderThickness * 2, 1, 0)

	--[[ The three lines live in a block of their OWN height, centred in the row,
	     rather than at fixed offsets from the top. That is what lets the row grow
	     for touch without the type ending up sat on the ceiling: the extra height
	     becomes margin above and below instead of all of it underneath. ]]
	local body = Widgets.frame(row, "Body", nil, 1)
	body.AnchorPoint = Vector2.new(0, 0.5)
	body.Position = UDim2.new(0, LAYOUT.PanelPadding + 4, 0.5, 0)
	body.Size = UDim2.new(1, -(LAYOUT.PanelPadding * 2 + 4), 0, KIT_CONTENT_HEIGHT)

	local title = Widgets.label(body, "Title", FONT.Body, TEXT.Tiny, COLOR.TextDim)
	title.Size = UDim2.new(0.6, 0, 0, TEXT.Tiny + 2)
	title.Text = entry.title

	local value = Widgets.label(body, "Value", FONT.Heading, TEXT.Body, COLOR.TextPrimary)
	value.Position = UDim2.fromOffset(0, TEXT.Tiny + 2)
	value.Size = UDim2.new(0.62, 0, 0, TEXT.Body + 2)
	value.TextTruncate = Enum.TextTruncate.AtEnd

	local detail = Widgets.label(body, "Detail", FONT.Body, TEXT.Tiny, COLOR.TextSecondary)
	detail.Position = UDim2.fromOffset(0, TEXT.Tiny + TEXT.Body + 4)
	detail.Size = UDim2.new(1, 0, 0, TEXT.Tiny + 2)
	detail.TextTruncate = Enum.TextTruncate.AtEnd

	--[[ On the NAME's line rather than the middle of the row. A count floating
	     level with the stat line reads as one of the stats. ]]
	local count = Widgets.label(body, "Count", FONT.Numeric, TEXT.Body, COLOR.TextSecondary)
	count.AnchorPoint = Vector2.new(1, 0)
	count.Position = UDim2.new(1, 0, 0, TEXT.Tiny + 2)
	count.Size = UDim2.new(0.36, 0, 0, TEXT.Body + 2)
	count.TextXAlignment = Enum.TextXAlignment.Right

	table.insert(kitRows, { frame = row, value = value, detail = detail, count = count })
end

local function build()
	gui = Instance.new("ScreenGui")
	gui.Name = "FL_Backpack"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	--[[ The panel layer, alongside the shop and the loadout screen. It is the
	     same kind of thing they are and it is never open at the same time as
	     one, and it must draw over the HUD it is explaining. ]]
	gui.DisplayOrder = UITheme.DisplayOrder.Settings
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Enabled = false
	gui.Parent = player:WaitForChild("PlayerGui")
	trove:add(gui)

	local layer = ScaleLayer.new(gui, "Scaled")
	local chrome = Widgets.panel(layer, trove, "BACKPACK", function()
		BackpackController:close()
	end)
	panel = chrome.frame
	closeButton = chrome.close

	local kitCaption = Widgets.label(panel, "KitCaption", FONT.Heading, TEXT.Small, COLOR.TextDim)
	kitCaption.Position = UDim2.fromOffset(LAYOUT.PanelPadding, HEADER_HEIGHT + LAYOUT.PanelPadding)
	kitCaption.Size = UDim2.new(KIT_WIDTH, 0, 0, CAPTION_HEIGHT)
	kitCaption.Text = "WHAT YOU ARE CARRYING"

	kitList = Widgets.scroller(panel, "Kit")
	kitList.Position = UDim2.fromOffset(LAYOUT.PanelPadding, BODY_TOP)
	kitList.AutomaticCanvasSize = Enum.AutomaticSize.Y
	Widgets.list(kitList, LAYOUT.ElementGap)
	for index, entry in KIT_SLOTS do
		buildKitRow(index, entry)
	end

	local squadCaption = Widgets.label(panel, "SquadCaption", FONT.Heading, TEXT.Small, COLOR.TextDim)
	squadCaption.Position =
		UDim2.new(KIT_WIDTH, LAYOUT.PanelPadding + COLUMN_GAP, 0, HEADER_HEIGHT + LAYOUT.PanelPadding)
	squadCaption.Size = UDim2.new(1 - KIT_WIDTH, 0, 0, CAPTION_HEIGHT)
	squadCaption.Text = "WHAT THEY ARE CARRYING"

	squadList = Widgets.scroller(panel, "Squad")
	squadList.Position = UDim2.new(KIT_WIDTH, LAYOUT.PanelPadding + COLUMN_GAP, 0, BODY_TOP)
	squadList.AutomaticCanvasSize = Enum.AutomaticSize.Y
	Widgets.list(squadList, LAYOUT.ElementGap)

	footRule = Widgets.frame(panel, "FootRule", COLOR.Border, 0)
	footRule.AnchorPoint = Vector2.new(0, 1)
	footRule.Position = UDim2.new(0, 0, 1, -PANEL.FooterHeight)
	footRule.Size = UDim2.new(1, 0, 0, LAYOUT.BorderThickness)

	hint = Widgets.label(panel, "Hint", FONT.Body, TEXT.Small, COLOR.TextDim)
	hint.AnchorPoint = Vector2.new(0, 1)
	hint.Position = UDim2.new(0, LAYOUT.PanelPadding, 1, 0)
	hint.Size = UDim2.new(1, -LAYOUT.PanelPadding * 2, 0, PANEL.FooterHeight)
	hint.Text = "NOTHING HERE IS A BUTTON — THE ROUND IS STILL RUNNING WITHOUT YOU."

	applyTouchSizing()
	refreshPanelSize()
end

-- ── public API ──────────────────────────────────────────────────────────────

function BackpackController:isOpen(): boolean
	return state.open
end

function BackpackController:open()
	if state.open then
		return
	end
	state.open = true
	gui.Enabled = true
	applyTouchSizing()
	refreshPanelSize()
	refreshKit()
	refreshSquad()
	--[[ Suppressed only when this is the top screen. Opened from inside the main
	     menu the menu already owns the cursor and the input lock, and taking them
	     a second time is how a player ends up unable to close either. ]]
	setSuppressed(not menuIsOpen())
	claimCursor(true)
	--[[ CLOSE is the only pressable thing on the screen, so it is where a pad's
	     selection goes. Leaving the selection on nothing would make B the only
	     way out on a console. ]]
	GamepadFocus.capture(closeButton)
	UiSound.play(AudioConfig.UI.MenuConfirm)
end

function BackpackController:close()
	if not state.open then
		return
	end
	state.open = false
	gui.Enabled = false
	GamepadFocus.release(closeButton)
	--[[ The rows go with the screen. Four teammate rows is not much to hold, but
	     a panel a player opens every wave should not be growing a list of dead
	     instances for the whole round. ]]
	rowTrove:clean()
	setSuppressed(false)
	claimCursor(false)
	if menuIsOpen() then
		callController("MainMenuController", "reassertSuppression")
	end
	UiSound.play(AudioConfig.UI.MenuBack)
end

function BackpackController:toggle()
	if state.open then
		self:close()
	else
		self:open()
	end
end

-- ── lifecycle ───────────────────────────────────────────────────────────────

function BackpackController:init()
	build()
end

function BackpackController:start()
	--[[
		Redrawn from the attributes that changed, rather than on a clock.

		Everything on this panel is an attribute, and an attribute has a changed
		signal — so a teammate picking up a medkit while this is open updates the
		moment they do, and a panel nobody has open costs nothing at all. A
		one-second poll would have been simpler and would have spent that second
		telling somebody the wrong thing.

		Note which half each signal redraws. Your magazine changes on every shot,
		and the squad column has nothing to do with it: wiring both halves to one
		refresh would rebuild four teammate rows ten times a second while you held
		a trigger with the panel open.
	]]
	local function kitChanged()
		if state.open then
			refreshKit()
		end
	end
	local function squadChanged()
		if state.open then
			refreshSquad()
		end
	end

	for _, name in
		{
			LA.PrimaryId,
			LA.PrimaryAmmo,
			LA.PrimaryReserve,
			LA.SecondaryId,
			LA.SecondaryAmmo,
			LA.MeleeId,
			LA.ThrowableId,
			LA.HealthItemId,
			LA.PillItemId,
		}
	do
		trove:connect(player:GetAttributeChangedSignal(name), kitChanged)
	end

	--[[ And the same for everybody else, connected as they arrive. A teammate's
	     attributes live on THEIR Player, so this cannot be one connection. ]]
	local function watch(other: Player)
		if other == player then
			return
		end
		for _, name in { LA.ThrowableId, LA.HealthItemId, LA.PillItemId, PA.State } do
			trove:connect(other:GetAttributeChangedSignal(name), squadChanged)
		end
	end
	for _, other in Players:GetPlayers() do
		watch(other)
	end
	trove:connect(Players.PlayerAdded, function(other: Player)
		watch(other)
		squadChanged()
	end)
	trove:connect(Players.PlayerRemoving, squadChanged)

	local viewportConnection: RBXScriptConnection? = nil
	local function watchViewport()
		if viewportConnection then
			viewportConnection:Disconnect()
			viewportConnection = nil
		end
		local camera = Workspace.CurrentCamera
		if camera then
			viewportConnection = camera:GetPropertyChangedSignal("ViewportSize"):Connect(refreshPanelSize)
		end
		refreshPanelSize()
	end
	trove:add(function()
		if viewportConnection then
			viewportConnection:Disconnect()
		end
	end)
	trove:connect(Workspace:GetPropertyChangedSignal("CurrentCamera"), watchViewport)
	watchViewport()

	--[[
		Closing, and only closing.

		OPENING is Action.Backpack in InputController — a real binding, so it
		appears in the controls screen and can be rebound, which a hard-coded key
		in this file could not be. That binding cannot close the panel: this
		screen suppresses InputController while it is up, exactly as every other
		screen does, so the action is unbound for as long as there is anything to
		close. Hence a raw listener here, which nothing suppresses.
	]]
	trove:connect(UserInputService.InputBegan, function(input: InputObject, processed: boolean)
		if not state.open then
			return
		end
		if input.KeyCode == Enum.KeyCode.ButtonB then
			BackpackController:close()
			return
		end
		--[[ B again, and Escape. The bound key is whatever the player rebound it
		     to, so it is asked for rather than assumed — and Escape is here
		     because processed input from Roblox's own menu never reaches us. ]]
		if processed then
			return
		end
		if input.KeyCode == Enum.KeyCode.Escape or boundToBackpack(input.KeyCode) then
			BackpackController:close()
		end
	end)
end

function BackpackController:destroy()
	rowTrove:destroy()
	table.clear(kitRows)
	trove:destroy()
end

Registry.register("BackpackController", BackpackController)

return BackpackController
