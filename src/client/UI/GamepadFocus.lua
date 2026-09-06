--!nonstrict
--[[
	GamepadFocus — making the menus usable without a pointer.

	A controller usually has no cursor — see the pointer note further down for
	the console that does. Roblox's answer is GuiService.SelectedObject: set
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
local UserInputService = game:GetService("UserInputService")

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

--[[
	── WHEN THE CONTROLLER HAS A POINTER AFTER ALL ─────────────────────────────

	The header above says "a controller has no cursor". A PS5 does: the DualSense
	touchpad drives a pointer, and the player expects it to move freely and click
	whatever it is over.

	Forced selection fights that, and loses in the most confusing possible way.
	The highlight sits on whichever button `capture` chose, the pointer moves
	somewhere else entirely, and the two disagree about what is about to be
	pressed. Nothing is broken enough to look broken — it just does the wrong
	thing.

	So: while a pointer is being used, this module stands down. Selection is
	cleared, `capture` becomes a no-op, and the cursor owns the screen. The
	moment the player goes back to the stick or the D-pad, the last captured
	button is selected again — because putting the pad down and picking it back
	up is a thing people do mid-menu, and a console that then has no highlight
	and no cursor is a dead screen.

	Detected from the pointer moving rather than from any PS5 API, because Roblox
	exposes none: the touchpad arrives as ordinary mouse input. That also makes
	this correct for the Xbox virtual cursor, which behaves the same way.
]]
local pointerActive = false
local lastCaptured: GuiObject? = nil
local watching = false

--[[ How far a stick has to be pushed to count as navigating. Well above the
     resting noise of a worn thumbstick, which would otherwise take the screen
     back from the pointer every frame without the player touching anything. ]]
local STICK_DEADZONE = 0.25

local NAV_KEYS: { [Enum.KeyCode]: boolean } = {
	[Enum.KeyCode.DPadUp] = true,
	[Enum.KeyCode.DPadDown] = true,
	[Enum.KeyCode.DPadLeft] = true,
	[Enum.KeyCode.DPadRight] = true,
}

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

--[[ The pointer has been used: hand the screen to it and take the highlight
     off, so what is lit and what is under the cursor cannot disagree. ]]
local function pointerTookOver()
	if pointerActive or not isGamepad() then
		return
	end
	pointerActive = true
	GuiService.SelectedObject = nil
end

--[[ The stick or the D-pad has been used: take the screen back, and put the
     highlight where it was rather than nowhere. ]]
local function padTookOver()
	if not pointerActive then
		return
	end
	pointerActive = false
	local button = lastCaptured
	if button and button.Parent and button.Visible and isGamepad() then
		GuiService.SelectedObject = button
	end
end

--[[ Connected on first use rather than at require time. A player who never
     opens a screen never needs this, and a desktop never needs it at all —
     both handlers check the scheme before doing anything. ]]
local function watchPointer()
	if watching then
		return
	end
	watching = true

	UserInputService.InputChanged:Connect(function(input: InputObject)
		local kind = input.UserInputType
		if kind == Enum.UserInputType.MouseMovement then
			--[[ Only a real movement. A pointer parked on a console still emits
			     the occasional zero-delta change, and taking the screen off the
			     stick for that would make the highlight flicker. ]]
			if math.abs(input.Delta.X) + math.abs(input.Delta.Y) > 0 then
				pointerTookOver()
			end
		elseif kind == Enum.UserInputType.Gamepad1 and input.KeyCode == Enum.KeyCode.Thumbstick1 then
			if input.Position.Magnitude >= STICK_DEADZONE then
				padTookOver()
			end
		end
	end)

	UserInputService.InputBegan:Connect(function(input: InputObject)
		local kind = input.UserInputType
		if kind == Enum.UserInputType.MouseButton1 then
			pointerTookOver()
		elseif kind == Enum.UserInputType.Gamepad1 and NAV_KEYS[input.KeyCode] then
			padTookOver()
		end
	end)
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
	watchPointer()
	if not (button and button:IsA("GuiObject") and button.Visible) then
		return
	end
	--[[ Styled either way. The highlight has to already be on the button for
	     padTookOver to have something to put selection back onto, and a button
	     that is merely Selectable costs nothing while the cursor is in use. ]]
	GamepadFocus.style(button)
	lastCaptured = button
	--[[ Remembered, not selected. While the pointer owns the screen, forcing
	     selection here is the exact fight this module gave up. ]]
	if pointerActive then
		return
	end
	GuiService.SelectedObject = button
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
	--[[ And forget it, so a stick nudge after this screen is gone does not
	     select a button that closed with it. ]]
	if button == nil or lastCaptured == button then
		lastCaptured = nil
	end
end

return GamepadFocus
