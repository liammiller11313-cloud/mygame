--!nonstrict
--[[
	CareerController — the level, today's quests, and the pass, on one screen.

	Built as its own module rather than as four more sections of
	MainMenuController, which scripts/audit.py already reports as "182 top-level
	locals, heading for Luau's 200-per-scope limit". The menu opens this the same
	way it opens the shop; everything about the panel's chrome comes from
	Widgets.panel and UITheme, so it is visibly the same game as the two screens
	beside it.

	── ONE SCREEN, NOT TABS ─────────────────────────────────────────────────────
	The quests and the pass are the same loop seen from two ends — quests are how
	Scrip arrives, the pass is where it goes — and putting them behind tabs would
	hide the connection at exactly the moment a player is deciding whether the
	grind is worth it. So: the banner says where you are, the left column says
	what to do today, the right column says what it buys. Nothing is more than one
	glance away from the thing that justifies it.

	── IT DECIDES NOTHING ───────────────────────────────────────────────────────
	Same rule as the shop. No number on this screen is computed from a purchase
	this client believes it made; the CLAIM button sends a request and the panel
	redraws when the server answers. ProgressionController is the mirror and even
	IT is not authoritative — see its header for the one number that is computed
	locally, and why that is safe.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local AudioConfig = require(Shared.Config.AudioConfig)
local EconomyConfig = require(Shared.Config.EconomyConfig)
local ProgressionConfig = require(Shared.Config.ProgressionConfig)
local Registry = require(Shared.Util.Registry)
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

local player = Players.LocalPlayer

-- ── layout, in reference pixels ─────────────────────────────────────────────
--[[ The same two numbers the shop declares, and for the same reason: everything
     else — header, footer, rows, scrim, hairlines — comes from UITheme.Panel, so
     this screen tracks the rest of the interface without being told to. ]]
local PANEL_WIDTH = 860
local PANEL_MAX_HEIGHT = 620

local HEADER_HEIGHT = PANEL.HeaderHeight
local FOOTER_HEIGHT = PANEL.FooterHeight

--[[ The banner across the top: level, the bar, and the Scrip balance. Tall
     enough for a display-size number, because the level IS the headline of this
     screen and setting it in body type would make the quests below look like the
     point. ]]
local BANNER_HEIGHT = 86

--[[ The split. A fraction rather than an offset so it survives a phone, where
     the whole panel is narrower — the shop's LIST_WIDTH does the same. ]]
local QUEST_WIDTH = 0.42

local COLUMN_GAP = 14
local SECTION_LABEL_HEIGHT = 20

local QUEST_ROW_HEIGHT = 62

--[[
	The streak card, above today's orders.

	It sits at the top of the left column rather than on a screen of its own,
	because it is the same sentence as the quests underneath it: here is what
	today owes you. A separate panel would need its own button on the menu, and a
	daily reward behind two clicks is a daily reward most people never find.

	The height is fixed and every term is at an offset from the top of the card,
	on a phone as much as on a desktop. A seven-pip row that reflowed would be a
	row whose pips stopped reading as "seven", which is the only thing they are
	there to say.

	── AND THE BUTTON IS A TOUCH TARGET ────────────────────────────────────
	CLAIM TODAY was 38 reference pixels, which on a phone — where the whole
	panel is drawn at ScaleLayer's 0.75 floor — is 28.5 REAL pixels against
	this project's 42-pixel standard. It is now sized from PANEL.RowHeightTouch
	like every other control somebody presses, and the card grew to hold it.

	Unconditional rather than input-dependent, on the argument the main menu's
	NAV_HEIGHT already makes: the difference is invisible on a desktop, and a
	control that resizes when the input scheme changes is two layouts to keep
	working instead of one.
]]
local STREAK_BUTTON_HEIGHT = PANEL.RowHeightTouch
local STREAK_PIP_HEIGHT = 9
local STREAK_PIP_GAP = 4
--[[ Everything above the button, plus the button, plus its inset. Derived so
     the two cannot drift: a card sized by hand around a button that grew is how
     a CLAIM control ends up half outside the frame it lives in. ]]
local STREAK_REWARD_TOP = 28 + STREAK_PIP_HEIGHT + 6
local STREAK_CARD_HEIGHT = STREAK_REWARD_TOP + (TEXT.Small + 2) + 6 + STREAK_BUTTON_HEIGHT + 8

--[[
	A pass tier row, and the same row on a phone.

	34 was chosen against a mouse and is a real defect with a finger: the whole
	panel is drawn at ScaleLayer's 0.75 floor on a phone, so 34 reference pixels
	is 26 REAL ones — well under the 42 that PANEL.RowHeightTouch works out to,
	and these rows are stacked touching each other, so a mis-tap does not miss,
	it wears the wrong reward.

	Four panels in this interface already made this distinction. This one and the
	play panel did not, which is what happens when a screen is built without a
	phone in front of it.
]]
local TIER_ROW_HEIGHT = 34
local TIER_ROW_HEIGHT_TOUCH = PANEL.RowHeightTouch

--[[ The footer has to grow with the button in it. A CLAIM button that stayed
     30 reference pixels tall would be 22 real ones — half the standard, on the
     one control that spends a currency it took days to earn. ]]
--[[ Tall enough to HOLD a full-size button plus its inset, not merely to
     equal one. A 56-pixel footer with a button inset inside it yields a
     46-pixel button, which is 34 real pixels and still under the standard
     the footer grew for. ]]
local FOOTER_HEIGHT_TOUCH = PANEL.RowHeightTouch + 8

--[[ Where the two columns begin, under the header and the banner. A constant
     because every term in it is one — and because build() and applyTouchSizing
     both need it, and two copies of this sum would drift the moment the banner
     changed height. ]]
local BODY_TOP = HEADER_HEIGHT + LAYOUT.PanelPadding + BANNER_HEIGHT + LAYOUT.PanelPadding

--[[ How thick the XP and quest bars are. One number for both: they mean the same
     thing — how far through something you are — and drawing them at two weights
     would suggest they do not. ]]
local BAR_HEIGHT = 6

--[[ How long a message under the footer stays up. Long enough to read a refusal,
     short enough that it is gone before the player has decided what to do about
     it. ]]
local MESSAGE_SECONDS = 3.2

local CareerController = {}

local trove = Trove.new()

local gui: ScreenGui
local panel: Frame
local levelLabel: TextLabel
local levelSub: TextLabel
local xpFill: Frame
local xpLabel: TextLabel
local scripLabel: TextLabel
local streakLabel: TextLabel
local streakReward: TextLabel
local streakButton: TextButton
local streakButtonLabel: TextLabel
--[[ The seven rungs, in order. The SET never changes the way the quest set
     does — it is always seven — so these are written into rather than destroyed
     and rebuilt. ]]
local streakPips: { Frame } = {}
local questHolder: Frame
local tierList: ScrollingFrame
local claimButton: TextButton
local claimLabel: TextLabel
local footRule: Frame
local hint: TextLabel

local state = {
	open = false,
	suppressed = false,
	messageUntil = 0,
	firstRow = nil :: GuiButton?,
}

--[[ Owned here rather than shared, because these screens nest: this one opens
     over a live round from the pause menu, and a shared slot would have the
     inner screen hand back the outer screen's camera. Written by FreeCursor. ]]
local restore = {
	cameraMode = nil :: any,
	cameraZoom = nil :: any,
	cameraMinZoom = nil :: any,
	mouseIcon = nil :: any,
}

--[[ Rebuilt on every refresh — three of them, once a screen opens or a round
     ends. Kept so `refresh` can write into them rather than tearing the column
     down, which would drop a controller's selection every time a kill landed. ]]
local questRows: { { fill: Frame, count: TextLabel, text: TextLabel } } = {}
local tierRows: { { button: TextButton, name: TextLabel, cost: TextLabel, mark: Frame } } = {}

-- ── small helpers ───────────────────────────────────────────────────────────

local function progression()
	return Registry.find("ProgressionController")
end

local function callController(name: string, method: string, ...: any)
	local controller = Registry.find(name)
	if controller and typeof(controller[method]) == "function" then
		pcall(controller[method], controller, ...)
	end
end

--[[
	Everything this panel has to take off the game while it is up.

	It did not need any of this when it only opened from the main menu — the menu
	had already suppressed the round, exactly as the shop relies on. The pause
	menu changed that: CAREER now opens over a live first-person round, where the
	mouse is locked to the middle of the screen and nothing on this panel can be
	clicked. Modelled on SettingsController, which has opened over a round from
	the start and got this right.
]]
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

--[[ The cursor, unconditionally — NOT conditional on the menu being open the way
     suppression is. The menu can close underneath this panel, which hands the
     camera back to a live survivor and pins the cursor to the middle of a screen
     that is still up. ]]
local function claimCursor(value: boolean)
	if value then
		FreeCursor.take(restore)
	else
		FreeCursor.giveBack(restore)
	end
end

--[[ The scheme, asked at layout time rather than remembered. A player who picks
     up a phone-sized window or plugs in a keyboard mid-session gets the right
     targets on the next open — SettingsController rebuilds its rows for exactly
     this reason. ]]
local function isTouch(): boolean
	local input = Registry.find("InputController")
	if not input or typeof(input.isTouchScheme) ~= "function" then
		return false
	end
	local ok, touch = pcall(input.isTouchScheme, input)
	return ok and touch == true
end

local function footerHeight(): number
	return if isTouch() then FOOTER_HEIGHT_TOUCH else FOOTER_HEIGHT
end

local function menuIsOpen(): boolean
	local menu = Registry.find("MainMenuController")
	if not menu or typeof(menu.isOpen) ~= "function" then
		return false
	end
	local ok, open = pcall(menu.isOpen, menu)
	return ok and open == true
end

--[[ Thousands separators. A five-figure Scrip balance set solid is a number
     nobody reads, and this interface has no other place that formats one. ]]
local function commas(value: number): string
	local text = tostring(math.max(math.floor(value), 0))
	local out = text
	while true do
		local replaced: number
		out, replaced = string.gsub(out, "^(%-?%d+)(%d%d%d)", "%1,%2")
		if replaced == 0 then
			break
		end
	end
	return out
end

local function scripText(value: number): string
	return ProgressionConfig.CurrencySymbol .. " " .. commas(value)
end

local function showMessage(text: string, color: Color3)
	hint.Text = text
	hint.TextColor3 = color
	state.messageUntil = os.clock() + MESSAGE_SECONDS
end

--[[ What a refusal from the server actually means, in words. The server sends a
     short reason code rather than a sentence, so that the sentence can be
     changed here without a server deploy. ]]
local function claimRefusal(reason: string): string
	if reason == "cost" then
		return "NOT ENOUGH " .. ProgressionConfig.CurrencyName .. "."
	end
	if reason == "complete" then
		return "THE TRACK IS FINISHED. NOTHING LEFT TO CLAIM."
	end
	if reason == "notready" then
		return "PROFILE STILL LOADING."
	end
	return "COULD NOT CLAIM THAT TIER."
end

-- ── drawing ─────────────────────────────────────────────────────────────────

local function refreshBanner()
	local store = progression()
	if not store then
		return
	end

	local level, into, cost = store:getLevelProgress()
	levelLabel.Text = tostring(level)

	--[[ A finished curve reports a cost of 0 — see ProgressionConfig.resolve.
	     Dividing by it would be inf, and a bar at inf draws as a bar at zero,
	     which is the most confusing possible way to show a maxed level. ]]
	if cost <= 0 then
		xpFill.Size = UDim2.fromScale(1, 1)
		xpLabel.Text = "MAX LEVEL"
	else
		xpFill.Size = UDim2.fromScale(math.clamp(into / cost, 0, 1), 1)
		xpLabel.Text = commas(into) .. " / " .. commas(cost) .. " XP"
	end

	local callsign = select(1, store:getWorn())
	local reward = if callsign ~= "" then ProgressionConfig.getReward("Callsign", callsign) else nil
	levelSub.Text = if reward then reward.label else "UNRANKED"

	scripLabel.Text = scripText(store:getScrip())
end

--[[
	The streak card.

	Everything drawn here comes off one server-supplied row — see
	ProgressionController.getLogin. `streak` is what today's claim would make it,
	not what is banked, so a player on six days with today unclaimed is shown a
	lit seventh pip and the seventh reward: the thing they are about to get,
	rather than the thing they already have.
]]
local function refreshStreak()
	local store = progression()
	if not store then
		return
	end

	local login = store:getLogin()
	local rung = ProgressionConfig.loginReward(login.streak).day
	local pending = store:canClaimLogin()

	streakLabel.Text = if login.streak > 0
		then string.format("DAY %d OF 7   ·   %d-DAY STREAK", rung, login.streak)
		else "DAY 1 OF 7"

	for index, pip in streakPips do
		--[[ Three states, and the middle one is the point of the card: days
		     already banked, the one on offer right now, and the ones still to
		     come. A card that only knew "done" and "not done" would light the
		     same pip whether the player had claimed today or merely could. ]]
		if index < rung or (index == rung and not pending) then
			pip.BackgroundColor3 = COLOR.Accent
			pip.BackgroundTransparency = 0
		elseif index == rung then
			pip.BackgroundColor3 = COLOR.Accent
			pip.BackgroundTransparency = 0.45
		else
			pip.BackgroundColor3 = COLOR.TextDim
			pip.BackgroundTransparency = 0.6
		end
	end

	streakReward.Text =
		string.format("%s%s   %s", EconomyConfig.Symbol, commas(login.dollars), scripText(login.scrip))

	if store:isLoginPending() then
		streakButtonLabel.Text = "CLAIMING…"
		streakButtonLabel.TextColor3 = COLOR.TextDim
		streakButton.Active = false
	elseif pending then
		streakButtonLabel.Text = "CLAIM TODAY"
		streakButtonLabel.TextColor3 = COLOR.TextPrimary
		streakButton.Active = true
	else
		--[[ Deliberately not "COME BACK TOMORROW". The rollover is UTC midnight
		     and for most of the world that is not tomorrow — it is later today,
		     or it was an hour ago. Saying "claimed" is true everywhere. ]]
		streakButtonLabel.Text = "CLAIMED"
		streakButtonLabel.TextColor3 = COLOR.TextDim
		streakButton.Active = false
	end
end

local function refreshQuests()
	local store = progression()
	if not store then
		return
	end

	for index, view in store:questView() do
		local row = questRows[index]
		if not row then
			break
		end
		local quest = view.quest
		row.text.Text = quest.text
		row.fill.Size = UDim2.fromScale(math.clamp(view.progress / quest.target, 0, 1), 1)

		if view.complete then
			row.count.Text = "DONE  +" .. quest.xp .. " XP  " .. scripText(quest.scrip)
			row.count.TextColor3 = COLOR.Accent
			row.fill.BackgroundColor3 = COLOR.Accent
			row.text.TextColor3 = COLOR.TextSecondary
		else
			row.count.Text = view.progress .. " / " .. quest.target
			--[[ Dimmer while part of the number is this round's and has not been
			     written down yet. "You have done this" and "you will have done
			     this when the round ends" are different promises and the screen
			     should not make them in the same colour. ]]
			row.count.TextColor3 = if view.pending then COLOR.TextDim else COLOR.TextSecondary
			row.fill.BackgroundColor3 = if view.pending then COLOR.AccentDim else COLOR.TextSecondary
			row.text.TextColor3 = COLOR.TextPrimary
		end
	end
end

local function refreshTiers()
	local store = progression()
	if not store then
		return
	end
	local claimed = store:getPassTier()
	local callsign, accent = store:getWorn()

	for index, row in tierRows do
		local reward = ProgressionConfig.PassTrack[index]
		local worn = (reward.kind == "Accent" and accent == reward.id)
			or (reward.kind == "Callsign" and callsign == reward.id)

		row.name.Text = string.format("%02d  %s", index, reward.label)

		if index <= claimed then
			--[[ Accents preview themselves. A colour reward whose row is drawn in
			     the interface's own text colour is a colour reward you cannot see
			     until you wear it. ]]
			row.name.TextColor3 = if reward.kind == "Accent" and reward.color
				then reward.color
				else COLOR.TextPrimary
			row.cost.Text = if worn then "WORN" else "OWNED"
			row.cost.TextColor3 = if worn then COLOR.Accent else COLOR.TextDim
			row.mark.BackgroundColor3 = if worn then COLOR.Accent else COLOR.Border
			row.mark.BackgroundTransparency = 0
			row.button.Active = true
		elseif index == claimed + 1 then
			row.name.TextColor3 = COLOR.TextPrimary
			row.cost.Text = scripText(ProgressionConfig.passCost(index))
			row.cost.TextColor3 = if store:getScrip() >= ProgressionConfig.passCost(index)
				then COLOR.Accent
				else COLOR.TextDim
			row.mark.BackgroundColor3 = COLOR.Accent
			row.mark.BackgroundTransparency = 0
			row.button.Active = true
		else
			row.name.TextColor3 = COLOR.TextDim
			row.cost.Text = scripText(ProgressionConfig.passCost(index))
			row.cost.TextColor3 = COLOR.TextDim
			row.mark.BackgroundColor3 = COLOR.Border
			row.mark.BackgroundTransparency = 0.6
			row.button.Active = false
		end
	end
end

local function refreshClaim()
	local store = progression()
	if not store then
		return
	end

	local reward, cost = store:nextTier()
	if not reward then
		claimLabel.Text = "TRACK COMPLETE"
		claimLabel.TextColor3 = COLOR.TextDim
		claimButton.Active = false
		return
	end

	if store:isClaimPending() then
		claimLabel.Text = "CLAIMING…"
		claimLabel.TextColor3 = COLOR.TextDim
		claimButton.Active = false
		return
	end

	claimLabel.Text = "CLAIM  " .. scripText(cost)
	local affordable = store:getScrip() >= cost
	claimLabel.TextColor3 = if affordable then COLOR.TextPrimary else COLOR.TextDim
	claimButton.Active = affordable
end

--[[ Everything whose size depends on the input scheme, applied together. Called
     from build so the first frame is right, and from open so a scheme change
     between two openings is picked up. ]]
local function applyTouchSizing()
	local rowHeight = if isTouch() then TIER_ROW_HEIGHT_TOUCH else TIER_ROW_HEIGHT
	for _, row in tierRows do
		row.button.Size = UDim2.new(1, -PANEL.ScrollBarWidth - 2, 0, rowHeight)
	end

	local foot = footerHeight()
	if footRule then
		footRule.Position = UDim2.new(0, 0, 1, -foot)
	end
	if hint then
		hint.Size = UDim2.new(0.58, 0, 0, foot)
	end
	if claimButton then
		--[[ The full touch height on a phone, inset only on a desktop where the
		     pointer is exact. ]]
		claimButton.Size = UDim2.fromOffset(200, if isTouch() then PANEL.RowHeightTouch else foot - 10)
	end
	if tierList then
		tierList.Size = UDim2.new(
			1 - QUEST_WIDTH,
			-(LAYOUT.PanelPadding * 2 + COLUMN_GAP),
			1,
			-(BODY_TOP + foot + LAYOUT.PanelPadding + SECTION_LABEL_HEIGHT)
		)
	end
	if questHolder then
		questHolder.Size = UDim2.new(
			QUEST_WIDTH,
			-LAYOUT.PanelPadding,
			1,
			-(BODY_TOP + foot + LAYOUT.PanelPadding + SECTION_LABEL_HEIGHT)
		)
	end
end

local function refresh()
	if not state.open then
		return
	end
	refreshBanner()
	refreshStreak()
	refreshQuests()
	refreshTiers()
	refreshClaim()

	if os.clock() >= state.messageUntil then
		local store = progression()
		if store and store:isDegraded() then
			--[[ Said on this screen and not only in the shop. Scrip spent against
			     a profile that will not save is Scrip gone at the next join, and
			     the pass is the slowest thing in the game to earn back. ]]
			hint.Text = "OFFLINE — NOTHING EARNED THIS SESSION WILL BE SAVED"
			hint.TextColor3 = COLOR.Warning
		else
			hint.Text = "TAP A CLAIMED TIER TO WEAR IT"
			hint.TextColor3 = COLOR.TextDim
		end
	end
end

-- ── build ───────────────────────────────────────────────────────────────────

local function refreshPanelSize()
	if not panel then
		return
	end
	local camera = Workspace.CurrentCamera
	local factor = ScaleLayer.getFactor()
	local viewport = if camera and factor > 0 then camera.ViewportSize / factor else nil

	local width = math.min(
		PANEL_WIDTH,
		math.max((if viewport then viewport.X else PANEL_WIDTH) - LAYOUT.ScreenMargin * 2, 280)
	)
	local height =
		math.min(PANEL_MAX_HEIGHT, (if viewport then viewport.Y else PANEL_MAX_HEIGHT) * PANEL.HeightScale)
	panel.Size = UDim2.fromOffset(width, height)
end

local function buildBanner()
	local banner = Widgets.frame(panel, "Banner", COLOR.PanelRaised, PANEL.RaisedFill)
	banner.Position = UDim2.fromOffset(LAYOUT.PanelPadding, HEADER_HEIGHT + LAYOUT.PanelPadding)
	banner.Size = UDim2.new(1, -LAYOUT.PanelPadding * 2, 0, BANNER_HEIGHT)
	Widgets.stroke(banner, COLOR.Border)

	--[[ The accent stripe down the left edge. Every raised surface in this
	     interface earns one; without it a filled rectangle reads as a hole rather
	     than as a card. ]]
	local edge = Widgets.frame(banner, "Edge", COLOR.Accent, 0)
	edge.Size = UDim2.new(0, LAYOUT.BorderThickness * 2, 1, 0)

	local caption = Widgets.label(banner, "Caption", FONT.Body, TEXT.Tiny, COLOR.TextDim)
	caption.Position = UDim2.fromOffset(LAYOUT.PanelPadding + 6, 8)
	caption.Size = UDim2.fromOffset(120, TEXT.Tiny + 2)
	caption.Text = "LEVEL"

	levelLabel = Widgets.label(banner, "Level", FONT.Display, TEXT.Display, COLOR.TextPrimary)
	levelLabel.Position = UDim2.fromOffset(LAYOUT.PanelPadding + 4, 16)
	levelLabel.Size = UDim2.fromOffset(120, TEXT.Display)
	levelLabel.Text = "1"

	levelSub = Widgets.label(banner, "Callsign", FONT.Heading, TEXT.Body, COLOR.Accent)
	levelSub.Position = UDim2.fromOffset(LAYOUT.PanelPadding + 132, 14)
	levelSub.Size = UDim2.new(0.5, 0, 0, TEXT.Body + 2)
	levelSub.Text = "UNRANKED"

	local track = Widgets.frame(banner, "XpTrack", COLOR.Background, 0.25)
	track.Position = UDim2.fromOffset(LAYOUT.PanelPadding + 132, 44)
	track.Size = UDim2.new(1, -(LAYOUT.PanelPadding * 2 + 132 + 150), 0, BAR_HEIGHT)
	xpFill = Widgets.frame(track, "Fill", COLOR.Accent, 0)
	xpFill.Size = UDim2.fromScale(0, 1)

	xpLabel = Widgets.label(banner, "Xp", FONT.Numeric, TEXT.Small, COLOR.TextSecondary)
	xpLabel.Position = UDim2.fromOffset(LAYOUT.PanelPadding + 132, 44 + BAR_HEIGHT + 4)
	xpLabel.Size = UDim2.new(0.5, 0, 0, TEXT.Small + 2)
	xpLabel.Text = ""

	local scripCaption = Widgets.label(banner, "ScripCaption", FONT.Body, TEXT.Tiny, COLOR.TextDim)
	scripCaption.AnchorPoint = Vector2.new(1, 0)
	scripCaption.Position = UDim2.new(1, -LAYOUT.PanelPadding, 0, 12)
	scripCaption.Size = UDim2.fromOffset(140, TEXT.Tiny + 2)
	scripCaption.TextXAlignment = Enum.TextXAlignment.Right
	scripCaption.Text = ProgressionConfig.CurrencyName

	scripLabel = Widgets.label(banner, "Scrip", FONT.Numeric, TEXT.Heading, COLOR.Accent)
	scripLabel.AnchorPoint = Vector2.new(1, 0)
	scripLabel.Position = UDim2.new(1, -LAYOUT.PanelPadding, 0, 28)
	scripLabel.Size = UDim2.fromOffset(180, TEXT.Heading)
	scripLabel.TextXAlignment = Enum.TextXAlignment.Right
	scripLabel.Text = scripText(0)
end

--[[
	The card, as the FIRST ROW OF THE LEFT COLUMN rather than a fixed block above
	it.

	It was the second, and the arithmetic did not survive a phone. The left column
	was a plain frame of fixed height holding three 62-pixel quest rows, and it
	had never fitted on a handset — three rows plus their gaps want 198 reference
	pixels and the column had 186, so it was twelve over before any of this. The
	card took another 139 with it and turned a twelve-pixel overflow into a
	hundred and seventy: on an iPhone the orders were simply not on the screen.

	So the column is a scroller now, exactly like the pass track beside it, and
	the card is a row inside it with LayoutOrder 0. On a desktop everything is
	visible and nothing looks different; on a phone the whole column scrolls as
	one, which is what a player would try anyway. It also deletes the fixed-height
	arithmetic entirely — nothing computes where the quests start any more,
	because the layout does.
]]
local function buildStreak()
	local card = Widgets.frame(questHolder, "Streak", COLOR.PanelRaised, PANEL.RaisedFill)
	--[[ Zero, so it sorts above every quest row. They start at 1 — see
	     buildQuestRow, which uses the quest's own index. ]]
	card.LayoutOrder = 0
	card.Size = UDim2.new(1, 0, 0, STREAK_CARD_HEIGHT)
	Widgets.stroke(card, COLOR.Accent)

	local edge = Widgets.frame(card, "Edge", COLOR.Accent, 0)
	edge.Size = UDim2.new(0, LAYOUT.BorderThickness * 2, 1, 0)

	streakLabel = Widgets.label(card, "Days", FONT.Heading, TEXT.Small, COLOR.TextPrimary)
	streakLabel.Position = UDim2.fromOffset(LAYOUT.PanelPadding, 8)
	streakLabel.Size = UDim2.new(1, -LAYOUT.PanelPadding * 2, 0, TEXT.Small + 2)
	streakLabel.Text = "DAY 1 OF 7"

	local pips = Widgets.frame(card, "Pips", COLOR.PanelRaised, 1)
	pips.Position = UDim2.fromOffset(LAYOUT.PanelPadding, 28)
	pips.Size = UDim2.new(1, -LAYOUT.PanelPadding * 2, 0, STREAK_PIP_HEIGHT)
	local row = Widgets.list(pips, STREAK_PIP_GAP)
	row.FillDirection = Enum.FillDirection.Horizontal

	table.clear(streakPips)
	local count = #ProgressionConfig.LoginStreak
	for index = 1, count do
		local pip = Widgets.frame(pips, "Pip" .. index, COLOR.TextDim, 0.6)
		pip.LayoutOrder = index
		--[[ Width by SCALE minus the gap it owes, so seven of them fill the row
		     exactly at any panel width. An offset width would leave a ragged
		     edge on a phone, where the panel is 0.75 of what this was drawn
		     against. ]]
		pip.Size = UDim2.new(1 / count, -STREAK_PIP_GAP * (count - 1) / count, 1, 0)
		table.insert(streakPips, pip)
	end

	streakReward = Widgets.label(card, "Reward", FONT.Numeric, TEXT.Small, COLOR.Accent)
	streakReward.Position = UDim2.fromOffset(LAYOUT.PanelPadding, STREAK_REWARD_TOP)
	streakReward.Size = UDim2.new(1, -LAYOUT.PanelPadding * 2, 0, TEXT.Small + 2)
	streakReward.Text = ""

	streakButton = Widgets.button(card, "ClaimLogin")
	streakButton.AnchorPoint = Vector2.new(0, 1)
	streakButton.Position = UDim2.new(0, LAYOUT.PanelPadding, 1, -8)
	streakButton.Size = UDim2.new(1, -LAYOUT.PanelPadding * 2, 0, STREAK_BUTTON_HEIGHT)
	streakButton.BackgroundColor3 = COLOR.PanelRaised
	streakButton.BackgroundTransparency = PANEL.ActionFill
	local stroke = Widgets.stroke(streakButton, COLOR.Border)

	streakButtonLabel = Widgets.label(streakButton, "Label", FONT.Heading, TEXT.Body, COLOR.TextPrimary)
	streakButtonLabel.Size = UDim2.fromScale(1, 1)
	streakButtonLabel.TextXAlignment = Enum.TextXAlignment.Center
	streakButtonLabel.Text = "CLAIM TODAY"
	Widgets.outlineHover(trove, streakButton, stroke)

	trove:connect(streakButton.Activated, function()
		local store = progression()
		if not store then
			return
		end
		--[[ Refused on the client so it says why on the client, the same as the
		     pass claim below. The one refusal worth words is "already claimed" —
		     a button that goes dead with no explanation reads as broken. ]]
		if not store:claimLogin() then
			showMessage("TODAY IS ALREADY CLAIMED.", COLOR.TextDim)
			UiSound.play(AudioConfig.UI.MenuBack)
			return
		end
		UiSound.play(AudioConfig.UI.MenuConfirm)
		refreshStreak()
	end)
end

local function buildQuestRow(index: number, quest: ProgressionConfig.Quest)
	local row = Widgets.frame(questHolder, "Quest" .. index, COLOR.PanelRaised, PANEL.RaisedFill)
	row.LayoutOrder = index
	row.Size = UDim2.new(1, 0, 0, QUEST_ROW_HEIGHT)
	Widgets.stroke(row, COLOR.Border)

	local edge = Widgets.frame(row, "Edge", COLOR.Border, 0)
	edge.Size = UDim2.new(0, LAYOUT.BorderThickness * 2, 1, 0)

	local text = Widgets.label(row, "Text", FONT.Body, TEXT.Body, COLOR.TextPrimary)
	text.Position = UDim2.fromOffset(LAYOUT.PanelPadding, 8)
	text.Size = UDim2.new(1, -LAYOUT.PanelPadding * 2, 0, TEXT.Body + 4)
	text.TextTruncate = Enum.TextTruncate.AtEnd
	text.Text = quest.text

	local track = Widgets.frame(row, "Track", COLOR.Background, 0.25)
	track.Position = UDim2.fromOffset(LAYOUT.PanelPadding, 32)
	track.Size = UDim2.new(1, -LAYOUT.PanelPadding * 2, 0, BAR_HEIGHT)
	local fill = Widgets.frame(track, "Fill", COLOR.TextSecondary, 0)
	fill.Size = UDim2.fromScale(0, 1)

	local count = Widgets.label(row, "Count", FONT.Numeric, TEXT.Small, COLOR.TextSecondary)
	count.Position = UDim2.fromOffset(LAYOUT.PanelPadding, 32 + BAR_HEIGHT + 4)
	count.Size = UDim2.new(1, -LAYOUT.PanelPadding * 2, 0, TEXT.Small + 2)
	count.Text = ""

	table.insert(questRows, { fill = fill, count = count, text = text })
end

--[[ Rebuilt rather than written into, because the SET changes at midnight and a
     row holding yesterday's quest text with today's counter behind it is worse
     than a rebuild nobody sees. ]]
local function buildQuests()
	table.clear(questRows)
	for _, child in questHolder:GetChildren() do
		--[[ By NAME, not by class. The streak card is a Frame in this same
		     scroller now, and a midnight rebuild that swept every Frame would
		     take it with the quests — leaving a column with no card and every
		     reference in refreshStreak pointing at a destroyed instance. ]]
		if child:IsA("Frame") and string.sub(child.Name, 1, 5) == "Quest" then
			child:Destroy()
		end
	end

	local day = math.floor(os.time() / ProgressionConfig.QuestPeriod)
	for index, quest in ProgressionConfig.questsForDay(day) do
		buildQuestRow(index, quest)
	end
end

local function wearTier(index: number)
	local store = progression()
	if not store then
		return
	end
	if index > store:getPassTier() then
		showMessage("CLAIM THAT TIER FIRST.", COLOR.TextDim)
		UiSound.play(AudioConfig.UI.MenuBack)
		return
	end
	local reward = ProgressionConfig.PassTrack[index]
	local callsign, accent = store:getWorn()
	local current = if reward.kind == "Accent" then accent else callsign
	--[[ A second tap takes it off. Without it there is no way back to the plain
	     name once anything has been worn, and the only alternative would be a
	     "NONE" row at the top of a track that is otherwise all rewards. ]]
	store:setWorn(reward.kind, if current == reward.id then "" else reward.id)
	UiSound.play(AudioConfig.UI.MenuConfirm)
end

local function buildTierRow(index: number, reward: ProgressionConfig.PassTier)
	local button = Widgets.button(tierList, "Tier" .. index)
	button.LayoutOrder = index
	button.Size = UDim2.new(1, -PANEL.ScrollBarWidth - 2, 0, TIER_ROW_HEIGHT)

	local mark = Widgets.frame(button, "Mark", COLOR.Border, 0)
	mark.AnchorPoint = Vector2.new(0, 0.5)
	mark.Position = UDim2.fromScale(0, 0.5)
	mark.Size = UDim2.new(0, LAYOUT.BorderThickness * 2, 0.6, 0)

	local name = Widgets.label(button, "Name", FONT.Heading, TEXT.Body, COLOR.TextDim)
	name.Position = UDim2.fromOffset(LAYOUT.PanelPadding, 0)
	name.Size = UDim2.new(0.62, 0, 1, 0)
	name.TextTruncate = Enum.TextTruncate.AtEnd
	--[[ Written here as well as in refreshTiers so the track reads correctly on
	     the frame it is built, before the first refresh has run. An empty column
	     of rows is what a screen looks like when it is broken. ]]
	name.Text = string.format("%02d  %s", index, reward.label)

	local cost = Widgets.label(button, "Cost", FONT.Numeric, TEXT.Small, COLOR.TextDim)
	cost.AnchorPoint = Vector2.new(1, 0)
	cost.Position = UDim2.new(1, -LAYOUT.PanelPadding, 0, 0)
	cost.Size = UDim2.new(0.36, 0, 1, 0)
	cost.TextXAlignment = Enum.TextXAlignment.Right

	local under = Widgets.rule(button, "Under", COLOR.Border)
	under.AnchorPoint = Vector2.new(0, 1)
	under.Position = UDim2.fromScale(0, 1)
	under.BackgroundTransparency = 0.6

	trove:connect(button.Activated, function()
		wearTier(index)
		refresh()
	end)
	Widgets.rowHover(trove, button)

	if index == 1 then
		state.firstRow = button
	end
	table.insert(tierRows, { button = button, name = name, cost = cost, mark = mark })
end

local function build()
	gui = Instance.new("ScreenGui")
	gui.Name = "FL_Career"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = UITheme.DisplayOrder.Settings
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Enabled = false
	gui.Parent = player:WaitForChild("PlayerGui")
	trove:add(gui)

	local layer = ScaleLayer.new(gui, "Scaled")
	local chrome = Widgets.panel(layer, trove, "CAREER", function()
		CareerController:close()
	end)
	panel = chrome.frame
	panel.Size = UDim2.new(0, PANEL_WIDTH, PANEL.HeightScale, 0)

	buildBanner()

	local top = BODY_TOP
	local bodyHeight = -(top + FOOTER_HEIGHT + LAYOUT.PanelPadding)

	local questCaption = Widgets.label(panel, "QuestCaption", FONT.Heading, TEXT.Small, COLOR.TextDim)
	questCaption.Position = UDim2.fromOffset(LAYOUT.PanelPadding, top)
	questCaption.Size = UDim2.new(QUEST_WIDTH, 0, 0, SECTION_LABEL_HEIGHT)
	questCaption.Text = "TODAY"

	--[[ A scroller, matching the pass track opposite. It was a plain frame, and
	     a plain frame is a promise that everything inside it fits — which on a
	     phone it never did. See buildStreak. ]]
	questHolder = Widgets.scroller(panel, "Quests")
	questHolder.Position = UDim2.fromOffset(LAYOUT.PanelPadding, top + SECTION_LABEL_HEIGHT)
	questHolder.Size = UDim2.new(QUEST_WIDTH, -LAYOUT.PanelPadding, 1, bodyHeight - SECTION_LABEL_HEIGHT)
	questHolder.AutomaticCanvasSize = Enum.AutomaticSize.Y
	Widgets.list(questHolder, LAYOUT.ElementGap)

	buildStreak()

	local passCaption = Widgets.label(panel, "PassCaption", FONT.Heading, TEXT.Small, COLOR.TextDim)
	passCaption.Position = UDim2.new(QUEST_WIDTH, LAYOUT.PanelPadding + COLUMN_GAP, 0, top)
	passCaption.Size = UDim2.new(1 - QUEST_WIDTH, 0, 0, SECTION_LABEL_HEIGHT)
	passCaption.Text = "THE PASS"

	tierList = Widgets.scroller(panel, "Tiers")
	tierList.Position =
		UDim2.new(QUEST_WIDTH, LAYOUT.PanelPadding + COLUMN_GAP, 0, top + SECTION_LABEL_HEIGHT)
	tierList.Size = UDim2.new(
		1 - QUEST_WIDTH,
		-(LAYOUT.PanelPadding * 2 + COLUMN_GAP),
		1,
		bodyHeight - SECTION_LABEL_HEIGHT
	)
	tierList.AutomaticCanvasSize = Enum.AutomaticSize.Y
	Widgets.list(tierList)
	for index, reward in ProgressionConfig.PassTrack do
		buildTierRow(index, reward)
	end

	footRule = Widgets.frame(panel, "FootRule", COLOR.Border, 0)
	footRule.AnchorPoint = Vector2.new(0, 1)
	footRule.Position = UDim2.new(0, 0, 1, -FOOTER_HEIGHT)
	footRule.Size = UDim2.new(1, 0, 0, LAYOUT.BorderThickness)

	hint = Widgets.label(panel, "Hint", FONT.Body, TEXT.Small, COLOR.TextDim)
	hint.AnchorPoint = Vector2.new(0, 1)
	hint.Position = UDim2.new(0, LAYOUT.PanelPadding, 1, 0)
	hint.Size = UDim2.new(0.58, 0, 0, FOOTER_HEIGHT)
	hint.Text = ""

	claimButton = Widgets.button(panel, "Claim")
	claimButton.AnchorPoint = Vector2.new(1, 1)
	claimButton.Position = UDim2.new(1, -LAYOUT.PanelPadding, 1, -6)
	claimButton.Size = UDim2.fromOffset(200, FOOTER_HEIGHT - 10)
	claimButton.BackgroundColor3 = COLOR.PanelRaised
	claimButton.BackgroundTransparency = PANEL.ActionFill
	local claimStroke = Widgets.stroke(claimButton, COLOR.Border)

	claimLabel = Widgets.label(claimButton, "Label", FONT.Heading, TEXT.Body, COLOR.TextPrimary)
	claimLabel.Size = UDim2.fromScale(1, 1)
	claimLabel.TextXAlignment = Enum.TextXAlignment.Center
	claimLabel.Text = "CLAIM"
	Widgets.outlineHover(trove, claimButton, claimStroke)

	trove:connect(claimButton.Activated, function()
		local store = progression()
		if not store then
			return
		end
		if not store:canClaim() then
			--[[ Refused on the client, so it says WHY on the client. Firing the
			     remote to be told "not enough" by a server that already published
			     the balance this screen is drawing is a round trip to learn
			     something already on screen. ]]
			local reward, cost = store:nextTier()
			if not reward then
				showMessage(claimRefusal("complete"), COLOR.TextDim)
			else
				showMessage(
					"NEED "
						.. scripText(cost - store:getScrip())
						.. " MORE "
						.. ProgressionConfig.CurrencyName,
					COLOR.TextDim
				)
			end
			UiSound.play(AudioConfig.UI.MenuBack)
			refresh()
			return
		end
		store:claim()
		UiSound.play(AudioConfig.UI.MenuConfirm)
		refresh()
	end)

	applyTouchSizing()
	refreshPanelSize()
end

-- ── public API ──────────────────────────────────────────────────────────────

function CareerController:isOpen(): boolean
	return state.open
end

function CareerController:open()
	if state.open then
		return
	end
	state.open = true
	gui.Enabled = true
	refreshPanelSize()
	--[[ Rebuilt on open rather than at boot: the quest set turns over at
	     midnight, and a player who left the game running through it should get
	     today's three without rejoining. ]]
	buildQuests()
	--[[ Before refresh, so the first frame after an open is already at the right
	     size rather than resizing under the player's thumb. ]]
	applyTouchSizing()
	refresh()
	setSuppressed(not menuIsOpen())
	claimCursor(true)
	GamepadFocus.capture(state.firstRow)
	UiSound.play(AudioConfig.UI.MenuConfirm)
end

function CareerController:close()
	if not state.open then
		return
	end
	state.open = false
	gui.Enabled = false
	GamepadFocus.release(state.firstRow)
	setSuppressed(false)
	claimCursor(false)
	--[[ The menu can have been open underneath the whole time, or have opened
	     while this was up — a round ending is the obvious way. Either way the
	     release above has just handed input and the HUD back over a menu that is
	     still on screen. The menu puts both right. ]]
	if menuIsOpen() then
		callController("MainMenuController", "reassertSuppression")
	end
	UiSound.play(AudioConfig.UI.MenuBack)
end

function CareerController:toggle()
	if state.open then
		self:close()
	else
		self:open()
	end
end

-- ── lifecycle ───────────────────────────────────────────────────────────────

function CareerController:init()
	build()
end

function CareerController:start()
	local store = progression()
	if store and store.changed then
		trove:add(store.changed:connect(refresh))
	end
	if store and store.awarded then
		trove:add(store.awarded:connect(function(payload: any)
			if not state.open or typeof(payload) ~= "table" then
				return
			end
			if payload.kind == "Pass" and payload.ok == false then
				showMessage(claimRefusal(tostring(payload.reason or "")), COLOR.Danger)
			end
			refresh()
		end))
	end

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

	--[[ B backs out, which is what B does on every console screen there has ever
	     been. Checked before the processed guard because the panel is focused
	     while it is up and its own presses arrive marked processed. ]]
	trove:connect(UserInputService.InputBegan, function(input: InputObject, processed: boolean)
		if not state.open then
			return
		end
		if input.KeyCode == Enum.KeyCode.ButtonB then
			CareerController:close()
			return
		end
		if not processed and input.KeyCode == Enum.KeyCode.Escape then
			CareerController:close()
		end
	end)
end

function CareerController:destroy()
	table.clear(questRows)
	table.clear(tierRows)
	trove:destroy()
end

Registry.register("CareerController", CareerController)

return CareerController
