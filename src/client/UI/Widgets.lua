--!nonstrict
--[[
	Widgets — the small pieces every screen in this game is built out of.

	Six controllers had grown their own private `newFrame`, `newLabel` and
	`newButton`, all subtly different: one set BorderSizePixel and one did not,
	two disagreed about the default text alignment, and the gamepad highlight was
	applied in some and forgotten in others. That is how two screens drift apart
	while both look correct on their own.

	This is that set, once. Every modal panel — settings, the shop, the loadout
	screen, the pause menu — now takes its chrome from `Widgets.panel` below, so
	there is exactly one definition of what a panel looks like, and the main menu
	and the HUD build their pieces from the primitives here rather than from
	copies of them.

	Five screens still keep private copies: the overlay, the map vote, the wave
	card, the infected HUD and the touch pad. Those are NOT the same functions
	with a different name — their `newLabel` centres text by default where this
	one aligns left, so folding them in would silently re-align every label on
	four screens at once. That is a separate change with its own verification,
	not a rename, and it is deliberately not being made here.

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
local FONT = UITheme.Font
local LAYOUT = UITheme.Layout
local PANEL = UITheme.Panel
local BRACKET = UITheme.Bracket
local GRIME = UITheme.Grime
local TEXT = UITheme.TextSize

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

--[[
	The chrome every modal panel in this game wears.

	Scrim, centred panel, one-pixel outline, a title on the left, a CLOSE on the
	right, and the accent rule that separates the header from the body. Four
	screens built that same sequence by hand and no two of them agreed on the
	numbers — see UITheme.Panel for what the drift actually looked like.

	The caller supplies only what is genuinely its own: how wide it wants to be
	and what happens when the player leaves. Everything else comes from the
	theme, which is the point — a fifth screen written next month gets the same
	header without anybody having to remember what the fourth one used.

	Height is deliberately NOT set here. Every one of these screens measures its
	own content against the viewport and picks a height from that, and a default
	imposed from here would only be overwritten a frame later.
]]
--[[
	Four corner brackets on an existing frame.

	Parented to the frame and sized in offsets, so they follow it through every
	resize without anything recomputing them. Drawn OVER the content on purpose:
	a bracket that a scrolling list slides under stops reading as part of the
	panel's edge.
]]
function Widgets.brackets(frame: GuiObject, color: Color3?): ()
	local tint = color or COLOR.Accent
	local length, thickness = BRACKET.Length, BRACKET.Thickness
	--[[ Each corner is two bars, and the table is (anchor, x, y) per corner so
	     the four are one loop rather than eight hand-placed frames that drift
	     apart the first time the length changes. ]]
	local corners = {
		{ Vector2.new(0, 0), 0, 0 },
		{ Vector2.new(1, 0), 1, 0 },
		{ Vector2.new(0, 1), 0, 1 },
		{ Vector2.new(1, 1), 1, 1 },
	}
	for index, corner in corners do
		local anchor, x, y = corner[1], corner[2], corner[3]
		local horizontal = Widgets.frame(frame, "BracketH" .. index, tint, 0)
		horizontal.AnchorPoint = anchor
		horizontal.Position = UDim2.fromScale(x, y)
		horizontal.Size = UDim2.fromOffset(length, thickness)
		horizontal.ZIndex = frame.ZIndex + 6

		local vertical = Widgets.frame(frame, "BracketV" .. index, tint, 0)
		vertical.AnchorPoint = anchor
		vertical.Position = UDim2.fromScale(x, y)
		vertical.Size = UDim2.fromOffset(thickness, length)
		vertical.ZIndex = frame.ZIndex + 6
	end
end

--[[ The grime gradient. One call, one instance, and the panel stops being a flat
     value — see UITheme.Grime for why it is deliberately almost invisible. ]]
function Widgets.grime(frame: GuiObject): UIGradient
	local gradient = Instance.new("UIGradient")
	gradient.Rotation = GRIME.Rotation
	gradient.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, GRIME.TopTransparency),
		NumberSequenceKeypoint.new(1, GRIME.BottomTransparency),
	})
	gradient.Parent = frame
	return gradient
end

export type Panel = {
	scrim: TextButton,
	frame: Frame,
	title: TextLabel,
	close: TextButton,
	rule: Frame,
}

function Widgets.panel(parent: Instance, trove: any, titleText: string, onClose: () -> ()): Panel
	local scrim = Widgets.scrim(parent, PANEL.Scrim)
	trove:connect(scrim.Activated, onClose)

	local frame = Widgets.frame(parent, "Panel", COLOR.Panel, PANEL.Transparency)
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromScale(0.5, 0.5)
	Widgets.stroke(frame, COLOR.Border)
	--[[ The genre pass, applied once here rather than five times. Every modal in
	     the game comes through this function — the shop, the loadout screen,
	     settings, career and play — so a surface treatment added here is a
	     treatment the whole interface gets, and one that cannot drift between
	     screens because there is only one of it. ]]
	Widgets.grime(frame)
	Widgets.brackets(frame)

	--[[ Vertically centred in the header rather than sat at a fixed offset, so
	     the title and the CLOSE opposite it share a baseline no matter what the
	     header height becomes. The width leaves room for the CLOSE plus whatever
	     a screen puts beside it — the shop hangs a balance there. ]]
	--[[ The one place per panel set in the stencil face. See UITheme.Font.Sign:
	     scoped to the line that says what the screen IS, because a battered
	     typewriter face in quantity is exhausting and at body sizes is
	     unreadable. ]]
	local title = Widgets.label(frame, "Title", FONT.Sign, TEXT.Heading, COLOR.TextPrimary)
	title.Position = UDim2.fromOffset(LAYOUT.PanelPadding, 0)
	title.Size = UDim2.new(0.5, -LAYOUT.PanelPadding, 0, PANEL.HeaderHeight)
	title.Text = titleText

	local close = Widgets.button(frame, "Close")
	close.AnchorPoint = Vector2.new(1, 0)
	close.Position = UDim2.new(1, -LAYOUT.PanelPadding, 0, 0)
	close.Size = UDim2.fromOffset(PANEL.CloseWidth, PANEL.HeaderHeight)
	local closeLabel = Widgets.label(close, "Label", FONT.Heading, TEXT.Body, COLOR.TextSecondary)
	closeLabel.Size = UDim2.fromScale(1, 1)
	closeLabel.TextXAlignment = Enum.TextXAlignment.Right
	closeLabel.Text = "CLOSE"
	Widgets.hover(trove, close, closeLabel)
	trove:connect(close.Activated, onClose)

	local rule = Widgets.frame(frame, "HeadRule", COLOR.BorderBright, 0)
	rule.Position = UDim2.fromOffset(0, PANEL.HeaderHeight)
	rule.Size = UDim2.new(1, 0, 0, LAYOUT.BorderThickness)

	return { scrim = scrim, frame = frame, title = title, close = close, rule = rule }
end

--[[ A scrolling surface with the theme's hairline bar. Four screens wrote these
     same eight properties; two of them forgot ScrollingDirection, which is how
     a vertical list ends up draggable sideways into empty space. ]]
function Widgets.scroller(parent: Instance, name: string): ScrollingFrame
	local scroller = Instance.new("ScrollingFrame")
	scroller.Name = name
	scroller.BackgroundTransparency = 1
	scroller.BorderSizePixel = 0
	scroller.CanvasSize = UDim2.fromOffset(0, 0)
	scroller.ScrollBarThickness = PANEL.ScrollBarWidth
	scroller.ScrollBarImageColor3 = COLOR.Border
	scroller.ScrollingDirection = Enum.ScrollingDirection.Y
	scroller.Parent = parent
	return scroller
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

--[[
	The wash a list row gets under the cursor.

	Every row in this interface is a target and until now only the settings rows
	admitted it: a shop row and a loadout pick row did nothing at all on hover, so
	the same-looking row in two panels behaved differently. A near-invisible white
	at 0.88 is enough — this is a pointer confirmation, not a selection state, and
	anything stronger competes with the row that IS selected.
]]
local ROW_HOVER = 0.88

--[[ `restore` is for a list whose rows also have a RESTING fill — a selected
     shop row sits at 0.9 — because clearing to fully transparent on mouse-leave
     would wipe the selection until the next redraw. Pass the function that owns
     that state and it stays the only thing that decides it. ]]
function Widgets.rowHover(trove: any, button: GuiButton, restore: (() -> ())?)
	trove:connect(button.MouseEnter, function()
		button.BackgroundColor3 = COLOR.TextPrimary
		button.BackgroundTransparency = ROW_HOVER
	end)
	trove:connect(button.MouseLeave, function()
		if restore then
			restore()
		else
			button.BackgroundTransparency = 1
		end
	end)
end

--[[ The outline lift a raised card or entry gets under the cursor. Four screens
     wrote this same two-connection pair by hand. Returns nothing; the caller
     keeps its own reference to the stroke for the SELECTED state, which is a
     different thing and outlives the pointer. ]]
function Widgets.outlineHover(trove: any, button: GuiButton, stroke: UIStroke)
	trove:connect(button.MouseEnter, function()
		stroke.Color = COLOR.BorderBright
	end)
	trove:connect(button.MouseLeave, function()
		stroke.Color = COLOR.Border
	end)
end

return Widgets
