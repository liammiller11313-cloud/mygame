--[[
	SlapClient
	----------
	WHERE THIS GOES:  StarterPlayer > StarterPlayerScripts
	WHAT KIND:        LocalScript   (NOT a Script)

	Input and the readout.

	  Keyboard   left click to bonk, E for your special
	  Gamepad    R2 to bonk, L2 for your special
	  Phone      two buttons, bottom right

	Everything wears the same purple-to-red theme. Ready and waiting are
	told apart by brightness rather than by colour, so the theme stays put
	instead of the screen changing colour every second.

	It decides nothing. Who got hit, how far they fly, how long the wait
	is - all of that is the server's. The countdowns here only mirror what
	the server already decided, so there is nothing to cheat.

	The whole thing hides itself when you have no walrus, so the lobby
	stays clean and no button is offered that would do nothing.
]]

local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local player = Players.LocalPlayer
local bonkEvent = ReplicatedStorage:WaitForChild("SlapEvent")
local specialEvent = ReplicatedStorage:WaitForChild("SpecialEvent")

local BONK_ACTION = "Bonk"
local SPECIAL_ACTION = "WalrusSpecial"

-- A keyboard beats a touchscreen: a laptop with a touch screen should get
-- the keyboard layout, not a pair of thumb buttons.
local USE_TOUCH_BUTTONS = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled

-- ============================================================
--  THE THEME
--
--  Purple into red, across everything. The gradient tints whatever
--  BackgroundColor3 is underneath it, so brightening or darkening that
--  one colour dims the whole thing without touching the hues - which is
--  how the cooldown state is drawn.
-- ============================================================

local PURPLE = Color3.fromRGB(126, 48, 196)
local RED = Color3.fromRGB(214, 45, 58)
local EDGE = Color3.fromRGB(240, 110, 120) -- the outline, a lit-up red

local READY_TINT = Color3.fromRGB(255, 255, 255) -- gradient at full strength
local COOLING_TINT = Color3.fromRGB(152, 146, 158) -- same gradient, muted

-- Black text, so the cooling state can only mute the panel, never darken
-- it: black on a dimmed purple would be a panel you can't read at the
-- exact moment you're checking whether you can swing yet.
local READY_TEXT = Color3.fromRGB(0, 0, 0)
local COOLING_TEXT = Color3.fromRGB(52, 46, 56)

local function themeGradient(parent)
	local gradient = Instance.new("UIGradient")
	gradient.Color = ColorSequence.new(PURPLE, RED)
	gradient.Rotation = 20 -- a slight diagonal, so it doesn't read as a stripe
	gradient.Parent = parent
	return gradient
end

-- ============================================================
--  ARE WE IN THE ARENA?
-- ============================================================

-- Having a walrus is what "in the arena" means - it's the same test the
-- server uses to decide whether you may swing at all.
local function hasWalrus()
	local character = player.Character
	return character ~= nil and character:FindFirstChild("Walrus") ~= nil
end

-- ============================================================
--  INPUT
-- ============================================================

local function onBonk(_actionName, inputState)
	-- Begin = the moment the button goes down. Without this it would fire
	-- again on the way back up.
	if inputState == Enum.UserInputState.Begin then
		bonkEvent:FireServer()
	end
end

local function onSpecial(_actionName, inputState)
	if inputState == Enum.UserInputState.Begin then
		specialEvent:FireServer()
	end
end

local bound = false

local function setBound(shouldBind)
	if shouldBind == bound then
		return -- already in the state we want
	end
	bound = shouldBind

	if shouldBind then
		-- The `false` is the important bit: no automatic touch button. We
		-- draw our own below, so phones get the game's colours rather than
		-- Roblox's default grey circle.
		ContextActionService:BindAction(
			BONK_ACTION,
			onBonk,
			false,
			Enum.UserInputType.MouseButton1,
			Enum.KeyCode.ButtonR2
		)

		ContextActionService:BindAction(SPECIAL_ACTION, onSpecial, false, Enum.KeyCode.E, Enum.KeyCode.ButtonL2)
	else
		ContextActionService:UnbindAction(BONK_ACTION)
		ContextActionService:UnbindAction(SPECIAL_ACTION)
	end
end

-- ============================================================
--  BUILDING THE READOUT
-- ============================================================

local gui = Instance.new("ScreenGui")
gui.Name = "WalrusHud"
gui.ResetOnSpawn = false -- survives dying, so it isn't rebuilt every respawn
gui.Parent = player:WaitForChild("PlayerGui")

-- Desktop: two bars along the bottom.
local stack = Instance.new("Frame")
stack.AnchorPoint = Vector2.new(0.5, 1) -- measured from its own bottom middle
stack.Position = UDim2.new(0.5, 0, 1, -14) -- centred, 14px up from the bottom
stack.Size = UDim2.new(0, 240, 0, 82)
stack.BackgroundTransparency = 1
stack.Visible = not USE_TOUCH_BUTTONS
stack.Parent = gui

local layout = Instance.new("UIListLayout")
layout.FillDirection = Enum.FillDirection.Vertical
layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
layout.Padding = UDim.new(0, 6)
layout.Parent = stack

local function makeRow(order)
	local row = Instance.new("TextLabel")
	row.LayoutOrder = order
	row.Size = UDim2.new(0, 240, 0, 38)
	row.BackgroundColor3 = READY_TINT
	row.Font = Enum.Font.GothamBold
	row.TextScaled = true
	row.TextColor3 = READY_TEXT
	row.Text = ""
	row.Parent = stack

	themeGradient(row)

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = row

	local stroke = Instance.new("UIStroke")
	stroke.Color = EDGE
	stroke.Thickness = 2
	stroke.Transparency = 0.4
	stroke.Parent = row

	-- Text needs room to breathe, or TextScaled runs it into the corners.
	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, 7)
	padding.PaddingBottom = UDim.new(0, 7)
	padding.PaddingLeft = UDim.new(0, 14)
	padding.PaddingRight = UDim.new(0, 14)
	padding.Parent = row

	return row
end

-- Phone: two round buttons up the right-hand side, clear of Roblox's own
-- jump button in the bottom corner. Nudge the second numbers if they sit
-- awkwardly on your screen.
local function makeButton(size, fromBottom)
	local button = Instance.new("TextButton")
	button.AnchorPoint = Vector2.new(1, 1)
	button.Position = UDim2.new(1, -28, 1, -fromBottom)
	button.Size = UDim2.new(0, size, 0, size)
	button.BackgroundColor3 = READY_TINT
	button.Font = Enum.Font.GothamBold
	button.TextScaled = true
	button.TextColor3 = READY_TEXT
	button.Text = ""
	button.AutoButtonColor = false -- we colour it ourselves, by cooldown
	button.Visible = USE_TOUCH_BUTTONS
	button.Parent = gui

	themeGradient(button)

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0) -- fully round
	corner.Parent = button

	local stroke = Instance.new("UIStroke")
	stroke.Color = EDGE
	stroke.Thickness = 3
	stroke.Transparency = 0.25
	stroke.Parent = button

	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, 22)
	padding.PaddingBottom = UDim.new(0, 22)
	padding.PaddingLeft = UDim.new(0, 10)
	padding.PaddingRight = UDim.new(0, 10)
	padding.Parent = button

	return button
end

local bonkRow = makeRow(1)
local specialRow = makeRow(2)

local bonkButton = makeButton(96, 150)
local specialButton = makeButton(84, 262)

bonkButton.Activated:Connect(function()
	bonkEvent:FireServer()
end)

specialButton.Activated:Connect(function()
	specialEvent:FireServer()
end)

-- ============================================================
--  KEEPING IT UP TO DATE
-- ============================================================

-- Only touch a widget when its words actually change, rather than 60 times
-- a second each for the whole match.
local shown = {}

local function paint(widget, text, ready)
	if shown[widget] == text then
		return
	end
	shown[widget] = text

	widget.Text = text
	widget.TextColor3 = ready and READY_TEXT or COOLING_TEXT

	-- The gradient stays exactly as it is. Only what's underneath it
	-- changes, which turns the whole thing down without shifting the hues.
	widget.BackgroundColor3 = ready and READY_TINT or COOLING_TINT
end

local function secondsLeft(readyAtAttribute)
	-- The same clock the server used to set it, so this counts down in step
	-- rather than drifting.
	return (player:GetAttribute(readyAtAttribute) or 0) - workspace:GetServerTimeNow()
end

local function refresh()
	local inArena = hasWalrus()

	-- One check drives the buttons and the readout together, so they can
	-- never disagree about whether you're allowed to attack.
	gui.Enabled = inArena
	setBound(inArena)

	if not inArena then
		return -- nothing to draw
	end

	local bonkLeft = secondsLeft("BonkReadyAt")
	local bonkReady = bonkLeft <= 0

	paint(bonkRow, bonkReady and "BONK   READY" or ("BONK   " .. math.ceil(bonkLeft) .. "s"), bonkReady)

	-- A round button has room for one word, so it shows the countdown
	-- instead of the name while it's waiting.
	paint(bonkButton, bonkReady and "BONK" or (math.ceil(bonkLeft) .. "s"), bonkReady)

	-- The server names the special once it sees which walrus you're
	-- wearing. A walrus with no special yet gets no button at all, rather
	-- than one that does nothing when pressed.
	local specialName = player:GetAttribute("SpecialName")

	specialRow.Visible = specialName ~= nil and not USE_TOUCH_BUTTONS
	specialButton.Visible = specialName ~= nil and USE_TOUCH_BUTTONS

	if specialName then
		local left = secondsLeft("SpecialReadyAt")
		local ready = left <= 0
		local label = string.upper(specialName)

		paint(specialRow, ready and (label .. "   READY") or (label .. "   " .. math.ceil(left) .. "s"), ready)
		paint(specialButton, ready and "SPECIAL" or (math.ceil(left) .. "s"), ready)
	end
end

refresh()
RunService.Heartbeat:Connect(refresh)
