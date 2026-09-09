--!nonstrict
--[[
	AwardController — the card that says what a round was worth.

	The CAREER panel is where a player goes to LOOK at their progression. This is
	the part that finds them: a round ends, and before they have decided whether
	to play another one, the screen tells them what the last one did to the
	number.

	── WHY IT IS NOT PART OF THE RESULTS SCREEN ─────────────────────────────────
	The results screen is MainMenuController's, and that file is at 182 of Luau's
	200 top-level locals — audit.py flags it on every run. It is also on a
	different clock: RoundPayout and ProgressionAwarded are fired a moment apart
	with no ordering guarantee, and a card that has to wait for both to draw
	either is a card that sometimes draws neither.

	So this is its own layer, above the results card and the map vote and below
	anything the player opened deliberately — see UITheme.DisplayOrder.Award.

	── ONE CARD, NOT A QUEUE ────────────────────────────────────────────────────
	The obvious build is a stack of toasts: one for the XP, one per level, one per
	quest. Four of those animating past each other over a results screen is noise,
	and the last one is on screen long after the player has moved on.

	One card, three lines, everything the round did. It is a summary, and a
	summary of three things is exactly what a summary is for.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local EconomyConfig = require(Shared.Config.EconomyConfig)
local ProgressionConfig = require(Shared.Config.ProgressionConfig)
local Registry = require(Shared.Util.Registry)
local Trove = require(Shared.Util.Trove)
local UITheme = require(Shared.Config.UITheme)

local ScaleLayer = require(script.Parent.ScaleLayer)
local Widgets = require(script.Parent.Widgets)

local COLOR = UITheme.Color
local FONT = UITheme.Font
local LAYOUT = UITheme.Layout
local MOTION = UITheme.Motion
local PANEL = UITheme.Panel
local TEXT = UITheme.TextSize

local player = Players.LocalPlayer

local CARD_WIDTH = 340
local CARD_HEIGHT = 92
local BAR_HEIGHT = 5

--[[ How long the card holds once it has arrived. Long enough to read three
     lines twice, short enough to be gone before the map vote wants the screen —
     the vote opens a few seconds after a round ends, and a reward still sliding
     around over it is the reward getting in the way of the game. ]]
local HOLD_SECONDS = 5.0

--[[ Where it rests, and where it comes from. Off the top rather than fading in:
     a card that arrives from somewhere reads as a thing that just happened, and
     one that fades up reads as a thing that was always there. ]]
local RESTING_Y = LAYOUT.ScreenMargin * 2
local HIDDEN_Y = -(CARD_HEIGHT + 20)

local AwardController = {}

local trove = Trove.new()

local gui: ScreenGui
local card: Frame
local headline: TextLabel
local levelLabel: TextLabel
local nextLabel: TextLabel
local barFill: Frame
local detail: TextLabel

--[[ Bumped on every show. A card that is already up when a second award lands
     must not have the first one's hide timer close it early — the token is how
     the delayed hide knows it is no longer the current one. ]]
local generation = 0

local function commas(value: number): string
	local out = tostring(math.max(math.floor(value), 0))
	while true do
		local replaced: number
		out, replaced = string.gsub(out, "^(%-?%d+)(%d%d%d)", "%1,%2")
		if replaced == 0 then
			break
		end
	end
	return out
end

local function slideTo(y: number)
	TweenService:Create(
		card,
		TweenInfo.new(MOTION.Normal, MOTION.Easing, MOTION.EasingDirection),
		{ Position = UDim2.new(0.5, 0, 0, y) }
	):Play()
end

local function hide(token: number)
	if token ~= generation then
		return
	end
	slideTo(HIDDEN_Y)
end

local function show()
	generation += 1
	local token = generation
	card.Visible = true
	slideTo(RESTING_Y)
	task.delay(HOLD_SECONDS, function()
		hide(token)
	end)
end

--[[ The bar under the headline, drawn from whatever the mirror says NOW.

     Deliberately the state after the award rather than an animation from before
     it: the sync that carries the new numbers and the event that says a round
     ended arrive together, and a bar that tried to animate between them would
     be animating from a number it had already been told was wrong.
]]
local function drawBar()
	local store = Registry.find("ProgressionController")
	if not store or typeof(store.getLevelProgress) ~= "function" then
		return
	end
	local level, into, cost = store:getLevelProgress()
	levelLabel.Text = tostring(level)
	if cost <= 0 then
		nextLabel.Text = "MAX"
		barFill.Size = UDim2.fromScale(1, 1)
	else
		nextLabel.Text = tostring(level + 1)
		barFill.Size = UDim2.fromScale(math.clamp(into / cost, 0, 1), 1)
	end
end

--[[ The third line: what happened beyond the raw XP. Built as a list and joined,
     so a round that levelled AND finished two orders says both in one line
     rather than picking whichever the code checked first. ]]
local function detailFor(payload: any): string
	local parts = {}

	local levels = tonumber(payload.levels) or 0
	if levels > 0 then
		local reached = tonumber(payload.level) or 0
		table.insert(parts, if levels == 1 then "LEVEL " .. reached else levels .. " LEVELS")
	end

	local quests = if typeof(payload.quests) == "table" then #payload.quests else 0
	if quests > 0 then
		table.insert(parts, if quests == 1 then "ORDER COMPLETE" else quests .. " ORDERS COMPLETE")
	end

	--[[ Only the login card carries this today, and it costs a round card
	     nothing: a payload with no `dollars` reads 0 and adds no part. Put ahead
	     of the Scrip because that is the order the streak panel lists them in
	     and two screens describing one reward should not disagree about which
	     currency comes first. ]]
	local dollars = tonumber(payload.dollars) or 0
	if dollars > 0 then
		table.insert(parts, EconomyConfig.Symbol .. commas(dollars))
	end

	local scrip = tonumber(payload.scrip) or 0
	if scrip > 0 then
		table.insert(parts, ProgressionConfig.CurrencySymbol .. " " .. commas(scrip))
	end

	return table.concat(parts, "   ")
end

local function onAwarded(payload: any)
	if typeof(payload) ~= "table" then
		return
	end

	if payload.kind == "Pass" then
		--[[ Only a SUCCESSFUL claim gets a card. A refusal is already answered on
		     the panel the player is looking at, and answering it twice in two
		     places is how one of them ends up saying something different. ]]
		if payload.ok ~= true then
			return
		end
		local tier = tonumber(payload.tier) or 0
		local reward = ProgressionConfig.PassTrack[tier]
		headline.Text = string.format("TIER %02d", tier)
		headline.TextColor3 = COLOR.Accent
		detail.Text = if reward then reward.label else ""
		drawBar()
		show()
		return
	end

	if payload.kind == "Login" then
		--[[ The card the whole streak is for. It says the STREAK rather than the
		     rung, because "DAY 3" is what the panel already showed and "12 DAY
		     STREAK" is the number a player is actually keeping. ]]
		local streak = math.max(math.floor(tonumber(payload.streak) or 1), 1)
		headline.Text = string.format("%d DAY STREAK", streak)
		headline.TextColor3 = COLOR.AccentBright
		detail.Text = detailFor(payload)
		drawBar()
		show()
		return
	end

	if payload.kind ~= "Round" then
		return
	end

	local xp = tonumber(payload.xp) or 0
	if xp <= 0 then
		--[[ A round somebody spent dead on wave one is worth nothing, and a card
		     saying so is a card that makes the system look broken. ]]
		return
	end

	headline.Text = "+" .. commas(xp) .. " XP"
	headline.TextColor3 = if (tonumber(payload.levels) or 0) > 0
		then COLOR.AccentBright
		else COLOR.TextPrimary
	detail.Text = detailFor(payload)
	drawBar()
	show()
end

local function build()
	gui = Instance.new("ScreenGui")
	gui.Name = "FL_Award"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = UITheme.DisplayOrder.Award
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = player:WaitForChild("PlayerGui")
	trove:add(gui)

	local layer = ScaleLayer.new(gui, "Scaled")

	card = Widgets.frame(layer, "Card", COLOR.Panel, PANEL.Transparency)
	card.AnchorPoint = Vector2.new(0.5, 0)
	card.Position = UDim2.new(0.5, 0, 0, HIDDEN_Y)
	card.Size = UDim2.fromOffset(CARD_WIDTH, CARD_HEIGHT)
	card.Visible = false
	Widgets.stroke(card, COLOR.Border)

	local edge = Widgets.frame(card, "Edge", COLOR.Accent, 0)
	edge.Size = UDim2.new(0, LAYOUT.BorderThickness * 2, 1, 0)

	local caption = Widgets.label(card, "Caption", FONT.Body, TEXT.Tiny, COLOR.TextDim)
	caption.Position = UDim2.fromOffset(LAYOUT.PanelPadding + 6, 8)
	caption.Size = UDim2.new(1, -LAYOUT.PanelPadding * 2, 0, TEXT.Tiny + 2)
	caption.Text = "EXPERIENCE"

	headline = Widgets.label(card, "Headline", FONT.Display, TEXT.Heading, COLOR.TextPrimary)
	headline.Position = UDim2.fromOffset(LAYOUT.PanelPadding + 4, 20)
	headline.Size = UDim2.new(1, -LAYOUT.PanelPadding * 2, 0, TEXT.Heading)
	headline.Text = ""

	levelLabel = Widgets.label(card, "Level", FONT.Numeric, TEXT.Tiny, COLOR.TextSecondary)
	levelLabel.Position = UDim2.fromOffset(LAYOUT.PanelPadding + 6, CARD_HEIGHT - 26)
	levelLabel.Size = UDim2.fromOffset(26, TEXT.Tiny + 2)
	levelLabel.Text = ""

	nextLabel = Widgets.label(card, "Next", FONT.Numeric, TEXT.Tiny, COLOR.TextDim)
	nextLabel.AnchorPoint = Vector2.new(1, 0)
	nextLabel.Position = UDim2.new(1, -LAYOUT.PanelPadding, 0, CARD_HEIGHT - 26)
	nextLabel.Size = UDim2.fromOffset(26, TEXT.Tiny + 2)
	nextLabel.TextXAlignment = Enum.TextXAlignment.Right
	nextLabel.Text = ""

	local track = Widgets.frame(card, "Track", COLOR.Background, 0.25)
	track.Position = UDim2.fromOffset(LAYOUT.PanelPadding + 34, CARD_HEIGHT - 26 + 4)
	track.Size = UDim2.new(1, -(LAYOUT.PanelPadding * 2 + 68), 0, BAR_HEIGHT)
	barFill = Widgets.frame(track, "Fill", COLOR.Accent, 0)
	barFill.Size = UDim2.fromScale(0, 1)

	detail = Widgets.label(card, "Detail", FONT.Heading, TEXT.Small, COLOR.Accent)
	detail.AnchorPoint = Vector2.new(1, 0)
	detail.Position = UDim2.new(1, -LAYOUT.PanelPadding, 0, 24)
	detail.Size = UDim2.new(0.62, 0, 0, TEXT.Small + 4)
	detail.TextXAlignment = Enum.TextXAlignment.Right
	detail.TextTruncate = Enum.TextTruncate.AtEnd
	detail.Text = ""
end

function AwardController:init()
	build()
end

function AwardController:start()
	local store = Registry.find("ProgressionController")
	if store and store.awarded then
		trove:add(store.awarded:connect(onAwarded))
	end
end

function AwardController:destroy()
	trove:destroy()
end

Registry.register("AwardController", AwardController)

return AwardController
