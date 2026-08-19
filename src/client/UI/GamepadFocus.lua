--!nonstrict
--[[
	GamepadFocus — making the menus usable without a pointer.

	A controller has no cursor. Roblox's answer is GuiService.SelectedObject: set
	it to a button and the D-pad and left stick walk between Selectable siblings,
	with A activating whatever is highlighted. Nothing happens until something
	sets it, which is why a menu that works perfectly with a mouse is a dead
	screen on a console — the buttons are all there and none of them can be
	reached.

	So every screen a player has to act on hands its first button to `capture`
	when it opens and calls `release` when it closes. Two rules make that safe:

	  1. It only ever engages under the gamepad scheme. Setting SelectedObject on
	     a desktop steals the keyboard: arrow keys start walking the UI instead of
	     doing whatever the game wanted them for.
	  2. Releasing restores nothing. A screen that closes hands selection back to
	     whatever opens next, and the next screen captures its own first button —
	     trying to remember and restore a previous selection across screens is how
	     focus ends up on a button that no longer exists.

	── THE HIGHLIGHT ────────────────────────────────────────────────────────────
	Roblox draws its own selection box, and it is a rounded blue rectangle. In a
	palette of black, white and orange that reads as a bug. `style` swaps it for
	an orange hairline that matches everything else, applied per button because
	SelectionImageObject is a per-object property.
]]

local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Registry = require(Shared.Util.Registry)
local UITheme = require(Shared.Config.UITheme)

local COLOR = UITheme.Color
local LAYOUT = UITheme.Layout

local GamepadFocus = {}

--[[ One shared template, cloned per button. SelectionImageObject wants an
     instance it can parent inside the selected object, and handing the same one
     to two buttons means only the second ever shows it. ]]
local template: Frame? = nil

local function highlightTemplate(): Frame
	if template then
		return template
	end
	local frame = Instance.new("Frame")
	frame.Name = "FL_Selection"
	frame.BackgroundColor3 = COLOR.Accent
	frame.BackgroundTransparency = 0.86
	frame.BorderSizePixel = 0
	-- Slightly larger than the button, so the outline reads as around it rather
	-- than as a border drawn on it.
	frame.Position = UDim2.fromOffset(-3, -3)
	frame.Size = UDim2.new(1, 6, 1, 6)

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, LAYOUT.CornerRadius)
	corner.Parent = frame

	local stroke = Instance.new("UIStroke")
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Thickness = LAYOUT.BorderThickness + 1
	stroke.Color = COLOR.AccentBright
	stroke.Parent = frame

	template = frame
	return frame
end

local function isGamepad(): boolean
	local input = Registry.find("InputController")
	if not input or typeof(input.getScheme) ~= "function" then
		return false
	end
	local ok, scheme = pcall(input.getScheme, input)
	return ok and scheme == "Gamepad"
end

--[[ Makes one button reachable by a controller and gives it the themed
     highlight. Safe to call on anything; a non-GuiObject is ignored rather than
     erroring, because the callers pass whatever their layout produced. ]]
function GamepadFocus.style(button: Instance?)
	if not button or not button:IsA("GuiObject") then
		return
	end
	button.Selectable = true
	if not button.SelectionImageObject then
		button.SelectionImageObject = highlightTemplate():Clone()
	end
end

--[[ Points the controller at `button`, if a controller is what the player is
     holding. Called when a screen opens. ]]
function GamepadFocus.capture(button: Instance?)
	if not isGamepad() then
		return
	end
	if button and button:IsA("GuiObject") and button.Visible then
		GamepadFocus.style(button)
		GuiService.SelectedObject = button
	end
end

--[[ Hands selection back. Called when a screen closes — including when it closes
     because the round started, which is the case that matters: leaving selection
     on a menu button that is now invisible eats every D-pad press in the game. ]]
function GamepadFocus.release(button: Instance?)
	-- Only clear if the thing selected is ours. Two screens closing in the same
	-- frame would otherwise have the second wipe the first's replacement.
	if button == nil or GuiService.SelectedObject == button then
		GuiService.SelectedObject = nil
	end
end

return GamepadFocus
