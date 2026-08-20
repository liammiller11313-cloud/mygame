--!nonstrict
--[[
	LobbyClock — the countdown, drawn over everything the menu can open.

		LobbyClock.set(endsAt, running)   -- absolute server time, or 0 for none

	── WHY THIS IS NOT JUST THE NUMBER IN THE MENU PANEL ───────────────────────
	The lobby now waits for somebody to choose a mode before it starts counting,
	which is the point: a player gets to read the menu, open the shop, spend
	their dollars and set a loadout before anything is on a clock.

	That creates a new way to be ambushed. The shop and the loadout screen draw
	on a HIGHER layer than the menu — deliberately, they are modals opened from
	inside it — so the panel with the countdown in it is behind them. A player
	who picks a mode, opens the shop and starts comparing shotguns has no way to
	know the round is eight seconds away until the screen fades out from under
	them.

	So the clock leaves the panel and follows them. One small chip, top centre,
	above every screen the menu can open and below the teleport fade, which has
	to be the last thing anyone sees.

	── WHAT IT DOES NOT DO ─────────────────────────────────────────────────────
	It has no opinion about the lobby. It renders a number that was handed to it
	and hides when it is handed nothing, so it cannot disagree with the panel it
	is duplicating — there is one source of truth (MainMenuController's lobby
	state) and this is a second view of it.

	It also owns no loop of its own. MainMenuController already runs exactly one
	RenderStepped for the whole menu and drives this from inside it, for the same
	reason Confetti and TitleFlicker do not connect to one either.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local UITheme = require(Shared.Config.UITheme)

local ScaleLayer = require(script.Parent.ScaleLayer)
local Widgets = require(script.Parent.Widgets)

local COLOR = UITheme.Color
local FONT = UITheme.Font
local LAYOUT = UITheme.Layout
local TEXT = UITheme.TextSize

-- Matches the menu's own urgent threshold, because the two are the same clock.
local URGENT = 10

local CHIP_WIDTH = 190
local CHIP_HEIGHT = 46
local NUMBER_WIDTH = 52
local TOP_MARGIN = 14

local LobbyClock = {}

local gui: ScreenGui? = nil
local number: TextLabel? = nil
local caption: TextLabel? = nil

local endsAt = 0
local armed = false
local shown = -1

--[[ Built on first use rather than at boot. A player who never opens the menu —
     one dropped straight into a round in progress — never pays for this. ]]
local function build()
	if gui then
		return
	end
	local player = Players.LocalPlayer
	local parent = player:WaitForChild("PlayerGui")

	local screen = Instance.new("ScreenGui")
	screen.Name = "FL_LobbyClock"
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = true
	screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screen.DisplayOrder = UITheme.DisplayOrder.LobbyClock
	screen.Enabled = false
	screen.Parent = parent

	--[[ Through ScaleLayer for the same reason every other screen is: the offsets
	     below were chosen against a 900px viewport, and a chip that is legible on
	     a monitor is four pixels tall on a phone. ]]
	local root = ScaleLayer.new(screen, "Scale")

	local frame = Widgets.frame(root, "Chip", COLOR.Panel, 0.12)
	frame.AnchorPoint = Vector2.new(0.5, 0)
	frame.Position = UDim2.new(0.5, 0, 0, TOP_MARGIN)
	frame.Size = UDim2.fromOffset(CHIP_WIDTH, CHIP_HEIGHT)
	Widgets.stroke(frame, COLOR.Border, LAYOUT.BorderThickness)

	local big = Widgets.label(frame, "Number", FONT.Display, TEXT.Heading, COLOR.Accent)
	big.AnchorPoint = Vector2.new(0, 0.5)
	big.Position = UDim2.fromOffset(LAYOUT.PanelPadding, CHIP_HEIGHT * 0.5)
	big.Size = UDim2.fromOffset(NUMBER_WIDTH, TEXT.Heading + 4)
	big.Text = "—"

	local line = Widgets.label(frame, "Caption", FONT.Body, TEXT.Tiny, COLOR.TextDim)
	line.AnchorPoint = Vector2.new(1, 0.5)
	line.Position = UDim2.new(1, -LAYOUT.PanelPadding, 0, CHIP_HEIGHT * 0.5)
	line.Size = UDim2.fromOffset(CHIP_WIDTH - NUMBER_WIDTH - LAYOUT.PanelPadding * 3, TEXT.Tiny + 4)
	line.TextXAlignment = Enum.TextXAlignment.Right
	line.Text = "UNTIL IT STARTS"

	gui, number, caption = screen, big, line
end

--[[
	What the clock is counting to, in absolute server time, and whether it is
	actually running.

	`running` is separate from a non-zero `endsAt` on purpose: a lobby short of
	players holds its clock at full and re-stamps it every tick, so the stamp is
	real but the number would sit frozen. Showing a countdown that never moves is
	worse than showing none.
]]
function LobbyClock.set(stamp: number, running: boolean)
	local wanted = running and typeof(stamp) == "number" and stamp > 0
	if not wanted then
		endsAt = 0
		armed = false
		shown = -1
		if gui then
			gui.Enabled = false
		end
		return
	end

	build()
	endsAt = stamp
	armed = true
	if gui then
		gui.Enabled = true
	end
	LobbyClock.update()
end

--[[ Driven from the menu's own RenderStepped. Writes only when the whole number
     moves, so this allocates a string once a second rather than sixty times. ]]
function LobbyClock.update()
	if not armed or not number then
		return
	end
	local whole = math.max(math.ceil(endsAt - Workspace:GetServerTimeNow()), 0)
	if whole == shown then
		return
	end
	shown = whole
	number.Text = string.format("%d", whole)
	number.TextColor3 = if whole <= URGENT then COLOR.AccentBright else COLOR.Accent
	if caption then
		caption.Text = if whole <= URGENT then "STARTING" else "UNTIL IT STARTS"
	end
end

--[[ True while the chip is on screen. For a test, and for anything that wants
     to know whether the player is on a clock. ]]
function LobbyClock.isRunning(): boolean
	return armed
end

function LobbyClock.destroy()
	if gui then
		gui:Destroy()
	end
	gui, number, caption = nil, nil, nil
	endsAt = 0
	armed = false
	shown = -1
end

return LobbyClock
