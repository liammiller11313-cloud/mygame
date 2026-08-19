--!nonstrict
--[[
	TouchController — the on-screen pad, and only when a finger is driving.

	ContextActionService will draw touch buttons for you, and this file exists
	because what it draws is wrong for this game in three ways at once: round
	grey buttons that ignore the theme, fixed pixel offsets from the bottom-right
	corner — which is exactly where the ammo counter and the hotbar live, so they
	landed on top of the HUD — and no awareness of the viewport scale, so they
	were postage stamps on a tablet and covered a third of a phone.

	So the pad is drawn here, in the game's own language, inside the same scale
	layer everything else uses, and stacked up the RIGHT edge above the hotbar
	rather than over it. The left half of the screen belongs to Roblox's
	thumbstick and to looking around, and nothing here is allowed into it.

	── WHAT IT DOES NOT DO ──────────────────────────────────────────────────────
	It never decides what a verb means or whether it is legal. Every button calls
	InputController:raise(), which is the same path a trigger pull takes — the
	disabled check, the held-state bookkeeping and the remote all happen once, in
	one place, whether the input came from a finger or a mouse.

	── WHY THE HOTBAR BECOMES THE ITEM BUTTONS ──────────────────────────────────
	Five more buttons for the five slots would be five more things covering the
	screen. The hotbar is already on screen, already says what is in each slot,
	and is already in the corner a thumb can reach — so on touch its slots become
	tap targets. One tap selects, a second tap on a consumable uses it, which is
	the same press-again-to-use rule the D-pad follows on a controller.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Registry = require(Shared.Util.Registry)
local Trove = require(Shared.Util.Trove)
local UITheme = require(Shared.Config.UITheme)

local ScaleLayer = require(script.Parent.ScaleLayer)

local COLOR = UITheme.Color
local FONT = UITheme.Font
local LAYOUT = UITheme.Layout
local TEXT = UITheme.TextSize

--[[ Reference pixels, like everything else drawn in a scale layer. 64 is about
     9mm on a phone at this scale, which is the smallest target a thumb hits
     reliably while also being shot at. ]]
local BUTTON = 64
local GAP = 8

--[[ The pad sits above the hotbar, not beside it. The hotbar is 54 tall plus the
     screen margin, and the ammo panel sits above that — this clears both. ]]
local BOTTOM_INSET = 150

-- Fire is the one button that has to be under the thumb without looking, so it
-- gets the bottom-right corner and a larger target than the rest.
local FIRE_SCALE = 1.35

local TouchController = {}

local player = Players.LocalPlayer
local trove = Trove.new()

local gui: ScreenGui
local root: Frame
local pad: Frame
local buttons: { { frame: TextButton, stroke: UIStroke, action: string } } = {}

local state = {
	visible = false,
	enabled = true,
	cinematic = false,
}

-- ── construction ────────────────────────────────────────────────────────────

local function paint(entry, held: boolean)
	entry.frame.BackgroundTransparency = if held then 0.1 else 0.45
	entry.stroke.Color = if held then COLOR.AccentBright else COLOR.BorderBright
	entry.stroke.Thickness = if held then LAYOUT.BorderThickness + 1 else LAYOUT.BorderThickness
end

local function newButton(action: string, label: string, size: number): any
	local frame = Instance.new("TextButton")
	frame.Name = action
	frame.AutoButtonColor = false
	frame.Text = ""
	frame.BackgroundColor3 = COLOR.Panel
	frame.BorderSizePixel = 0
	frame.Size = UDim2.fromOffset(size, size)
	frame.Parent = pad

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, LAYOUT.CornerRadius)
	corner.Parent = frame

	local stroke = Instance.new("UIStroke")
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Thickness = LAYOUT.BorderThickness
	stroke.Color = COLOR.BorderBright
	stroke.Parent = frame

	local text = Instance.new("TextLabel")
	text.Name = "Label"
	text.BackgroundTransparency = 1
	text.Size = UDim2.fromScale(1, 1)
	text.Font = FONT.Heading
	text.TextSize = TEXT.Tiny
	text.TextColor3 = COLOR.TextPrimary
	text.Text = label
	text.TextScaled = true
	text.Parent = frame

	local bounds = Instance.new("UITextSizeConstraint")
	bounds.MaxTextSize = TEXT.Small
	bounds.MinTextSize = TEXT.Tiny
	bounds.Parent = text

	local padding = Instance.new("UIPadding")
	local inset = UDim.new(0, math.floor(size * 0.18))
	padding.PaddingTop, padding.PaddingBottom = inset, inset
	padding.PaddingLeft, padding.PaddingRight = inset, inset
	padding.Parent = text

	local entry = { frame = frame, stroke = stroke, action = action }
	paint(entry, false)

	--[[ InputBegan/Ended on the button rather than Activated. Activated only
	     fires on release, which would make holding the trigger impossible: FIRE
	     and AIM are held verbs, and a fire button you have to tap once per round
	     is not a fire button. ]]
	trove:connect(frame.InputBegan, function(input: InputObject)
		if input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end
		local input_ = Registry.find("InputController")
		if input_ and input_:raise(action, true) then
			paint(entry, true)
		end
	end)

	local function release(input: InputObject)
		if input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end
		local input_ = Registry.find("InputController")
		if input_ then
			input_:raise(action, false)
		end
		paint(entry, false)
	end
	trove:connect(frame.InputEnded, release)

	table.insert(buttons, entry)
	return entry
end

local function build()
	gui = Instance.new("ScreenGui")
	gui.Name = "FL_Touch"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	--[[ Under the menu and the vote, above the HUD. A button the player can press
	     while a results screen is up would be a button pressed by accident. ]]
	gui.DisplayOrder = UITheme.DisplayOrder.Hud + 2
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Enabled = false
	gui.Parent = player:WaitForChild("PlayerGui")
	trove:add(gui)

	root = ScaleLayer.new(gui, "Scaled")

	pad = Instance.new("Frame")
	pad.Name = "Pad"
	pad.AnchorPoint = Vector2.new(1, 1)
	pad.Position = UDim2.new(1, -LAYOUT.ScreenMargin, 1, -BOTTOM_INSET)
	pad.BackgroundTransparency = 1
	pad.Size = UDim2.fromOffset(BUTTON * 2 + GAP, BUTTON * 3 + GAP * 2)
	pad.Parent = root

	--[[ Ordered by touchOrder and laid out bottom-up, so the verbs that matter
	     most in a fight are nearest the thumb. The keymap decides which verbs
	     earn a button; this decides where they go. ]]
	local input = Registry.find("InputController")
	local rows: { any } = {}
	if input and typeof(input.getBindings) == "function" then
		for _, binding in input:getBindings() do
			if binding.touch and binding.touchOrder then
				table.insert(rows, binding)
			end
		end
	end
	table.sort(rows, function(a, b)
		return a.touchOrder < b.touchOrder
	end)

	--[[ Two columns filling upward from the bottom-right. Fire is pulled out of
	     the grid and given the corner and a bigger target: it is the one button
	     a player must be able to find without looking at it. ]]
	local column, row = 0, 0
	for _, binding in rows do
		local isFire = binding.touchOrder == 1
		local size = if isFire then math.floor(BUTTON * FIRE_SCALE) else BUTTON
		local entry = newButton(binding.action, binding.touch, size)

		entry.frame.AnchorPoint = Vector2.new(1, 1)
		if isFire then
			entry.frame.Position = UDim2.new(1, 0, 1, 0)
			column, row = 1, 0
		else
			entry.frame.Position = UDim2.new(
				1,
				-column * (BUTTON + GAP),
				1,
				-(math.floor(BUTTON * FIRE_SCALE) + GAP + row * (BUTTON + GAP))
			)
			column += 1
			if column > 1 then
				column = 0
				row += 1
			end
		end
	end

	-- Tall enough for whatever the keymap actually asked for.
	pad.Size =
		UDim2.fromOffset(BUTTON * 2 + GAP, math.floor(BUTTON * FIRE_SCALE) + GAP + (row + 1) * (BUTTON + GAP))
end

-- ── visibility ──────────────────────────────────────────────────────────────

local function refresh()
	if not gui then
		return
	end
	local input = Registry.find("InputController")
	local touch = input and typeof(input.isTouchScheme) == "function" and input:isTouchScheme()
	state.visible = touch == true

	gui.Enabled = state.visible and state.enabled and not state.cinematic
	if not gui.Enabled then
		--[[ A pad that vanishes mid-press leaves the verb held forever, because
		     the button that would have raised the release is gone. Everything is
		     let go on the way out. ]]
		for _, entry in buttons do
			if input then
				input:raise(entry.action, false)
			end
			paint(entry, false)
		end
	end
end

-- ── public API ──────────────────────────────────────────────────────────────

--[[ Hidden while a menu, a vote or a results card owns the screen. Mirrors the
     HUD's own two switches so the pad and the HUD are never half-present. ]]
function TouchController:setVisible(value: boolean)
	state.enabled = value
	refresh()
end

function TouchController:setCinematic(value: boolean)
	state.cinematic = value
	refresh()
end

function TouchController:isShowing(): boolean
	return gui ~= nil and gui.Enabled
end

function TouchController:init()
	build()
end

function TouchController:start()
	local input = Registry.find("InputController")
	if input and input.schemeChanged then
		trove:add(input.schemeChanged:connect(refresh))
	end

	--[[ Roblox's own thumbstick and jump button are deliberately left alone. The
	     stick because Roblox's handles multitouch and dead zones better than a
	     reimplementation would, and jump because it is already in the corner this
	     pad is careful to stay out of. ]]

	refresh()
end

function TouchController:destroy()
	trove:destroy()
	table.clear(buttons)
end

Registry.register("TouchController", TouchController)

return TouchController
