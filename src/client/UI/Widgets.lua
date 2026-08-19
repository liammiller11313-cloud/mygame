--!nonstrict
--[[
	Widgets — the small pieces every screen in this game is built out of.

	Six controllers had grown their own private `newFrame`, `newLabel` and
	`newButton`, all subtly different: one set BorderSizePixel and one did not,
	two disagreed about the default text alignment, and the gamepad highlight was
	applied in some and forgotten in others. That is how two screens drift apart
	while both look correct on their own.

	This is that set, once. New screens use it. The older controllers keep their
	private copies for now — they work, and rewriting a 1,900-line menu to save a
	dozen lines is a bad trade — so this file is deliberately additive.

	── EVERYTHING HERE IS UNSTYLED BEYOND THE THEME ─────────────────────────────
	No sizes, no positions, no layout. A widget takes its colours and its font
	from UITheme and nothing else, because the moment one of these knows where it
	sits it stops being reusable and becomes a copy of whichever screen it was
	written for.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local UITheme = require(Shared.Config.UITheme)

local GamepadFocus = require(script.Parent.GamepadFocus)

local COLOR = UITheme.Color
local LAYOUT = UITheme.Layout

local Widgets = {}

function Widgets.frame(parent: Instance, name: string, color: Color3?, transparency: number?): Frame
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.BackgroundColor3 = color or COLOR.Panel
	frame.BackgroundTransparency = transparency or 0
	frame.BorderSizePixel = 0
	frame.Parent = parent
	return frame
end

--[[ A hairline. Every division in this interface is one pixel of border or
     accent — never a panel, never a card, never a drop shadow. ]]
function Widgets.rule(parent: Instance, name: string, color: Color3?): Frame
	local rule = Widgets.frame(parent, name, color or COLOR.Border, 0)
	rule.Size = UDim2.new(1, 0, 0, LAYOUT.BorderThickness)
	return rule
end

function Widgets.label(
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

--[[ A button with no chrome of its own. Selectable by a controller from the
     moment it exists, which is the part that kept being forgotten: a screen
     whose buttons are not Selectable is a dead screen on a console, and it looks
     perfect in Studio. ]]
function Widgets.button(parent: Instance, name: string): TextButton
	local button = Instance.new("TextButton")
	button.Name = name
	button.BackgroundTransparency = 1
	button.BorderSizePixel = 0
	button.AutoButtonColor = false
	button.Text = ""
	button.Parent = parent
	GamepadFocus.style(button)
	return button
end

--[[ A one-pixel outline on an existing object, in the theme's border colour.
     Returned so a caller can recolour it on hover without looking it up. ]]
function Widgets.stroke(parent: GuiObject, color: Color3?, thickness: number?): UIStroke
	local stroke = Instance.new("UIStroke")
	stroke.Color = color or COLOR.Border
	stroke.Thickness = thickness or LAYOUT.BorderThickness
	stroke.Parent = parent
	return stroke
end

--[[
	A full-screen click-eater.

	Every modal in this game needs one: without it a click that misses the panel
	lands on whatever is behind it — a menu button, or the trigger. A TextButton
	rather than a Frame because only a button consumes the click, and explicitly
	NOT Selectable because a full-screen one is a place the D-pad can land, where
	a single press of A would close the panel the player was trying to walk
	through.
]]
function Widgets.scrim(parent: Instance, transparency: number): TextButton
	local scrim = Instance.new("TextButton")
	scrim.Name = "Scrim"
	scrim.BackgroundColor3 = COLOR.Background
	scrim.BackgroundTransparency = transparency
	scrim.BorderSizePixel = 0
	scrim.AutoButtonColor = false
	scrim.Selectable = false
	scrim.Text = ""
	scrim.Size = UDim2.fromScale(1, 1)
	scrim.Parent = parent
	return scrim
end

--[[ A vertical list layout with even spacing. The single most repeated four
     lines in the interface. ]]
function Widgets.list(parent: Instance, padding: number?): UIListLayout
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, padding or 0)
	layout.Parent = parent
	return layout
end

--[[ Lights a label up on hover and puts it back on leave, which every clickable
     row in this interface does identically. Takes the trove so the connections
     die with the screen rather than with the process. ]]
function Widgets.hover(trove: any, button: GuiButton, label: TextLabel, color: Color3?)
	local base = label.TextColor3
	local lit = color or COLOR.AccentBright
	trove:connect(button.MouseEnter, function()
		label.TextColor3 = lit
	end)
	trove:connect(button.MouseLeave, function()
		label.TextColor3 = base
	end)
end

return Widgets
