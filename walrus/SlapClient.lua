--[[
	SlapClient
	----------
	WHERE THIS GOES:  StarterPlayer > StarterPlayerScripts
	WHAT KIND:        LocalScript   (NOT a Script)

	Input and the readout. Click to bonk, press E for your walrus's special.

	It decides nothing. Who got hit, how far they fly, how long the wait is -
	all of that is the server's. The buttons and the countdowns here only
	mirror what the server has already decided, so there is nothing to cheat.

	The whole thing hides itself when you have no walrus, so the lobby stays
	clean and the buttons only exist when they'd actually do something.
]]

local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local player = Players.LocalPlayer
local bonkEvent = ReplicatedStorage:WaitForChild("SlapEvent")
local specialEvent = ReplicatedStorage:WaitForChild("SpecialEvent")

local BONK_ACTION = "Bonk"
local SPECIAL_ACTION = "WalrusSpecial"

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
		-- Each call covers all three at once: the mouse or key, an
		-- on-screen button on phones (that's the `true`), and a gamepad.
		-- They also stay quiet while you're typing in chat.
		ContextActionService:BindAction(
			BONK_ACTION,
			onBonk,
			true,
			Enum.UserInputType.MouseButton1,
			Enum.KeyCode.ButtonR2
		)
		ContextActionService:SetTitle(BONK_ACTION, "BONK")

		ContextActionService:BindAction(SPECIAL_ACTION, onSpecial, true, Enum.KeyCode.E, Enum.KeyCode.ButtonL2)
		ContextActionService:SetTitle(SPECIAL_ACTION, "SPECIAL")
	else
		-- Unbinding takes the phone buttons away too, so the lobby doesn't
		-- show controls that would do nothing.
		ContextActionService:UnbindAction(BONK_ACTION)
		ContextActionService:UnbindAction(SPECIAL_ACTION)
	end
end

-- ============================================================
--  THE READOUT
-- ============================================================

local gui = Instance.new("ScreenGui")
gui.Name = "WalrusHud"
gui.ResetOnSpawn = false -- survives dying, so it isn't rebuilt every respawn
gui.Parent = player:WaitForChild("PlayerGui")

local stack = Instance.new("Frame")
stack.AnchorPoint = Vector2.new(0.5, 1) -- measured from its own bottom middle
stack.Position = UDim2.new(0.5, 0, 1, -14) -- centred, 14px up from the bottom
stack.Size = UDim2.new(0, 230, 0, 78)
stack.BackgroundTransparency = 1
stack.Parent = gui

local layout = Instance.new("UIListLayout")
layout.FillDirection = Enum.FillDirection.Vertical
layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
layout.Padding = UDim.new(0, 6)
layout.Parent = stack

local READY_COLOR = Color3.fromRGB(255, 255, 255)
local WAITING_COLOR = Color3.fromRGB(150, 150, 160)

local function makeRow(order)
	local row = Instance.new("TextLabel")
	row.LayoutOrder = order
	row.Size = UDim2.new(0, 230, 0, 36)
	row.BackgroundColor3 = Color3.fromRGB(18, 18, 22)
	row.BackgroundTransparency = 0.35
	row.Font = Enum.Font.GothamBold
	row.TextScaled = true
	row.Text = ""
	row.Parent = stack

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = row

	return row
end

local bonkRow = makeRow(1)
local specialRow = makeRow(2)

-- Only touch a label when its words actually change, rather than 60 times a
-- second each for the whole match.
local shown = {}

local function drawRow(row, label, readyAtAttribute)
	-- The same clock the server used to set it, so this counts down in step
	-- rather than drifting.
	local remaining = (player:GetAttribute(readyAtAttribute) or 0) - workspace:GetServerTimeNow()
	local text = (remaining > 0) and (label .. "   " .. math.ceil(remaining) .. "s") or (label .. "   READY")

	if text ~= shown[row] then
		shown[row] = text
		row.Text = text
		row.TextColor3 = (remaining > 0) and WAITING_COLOR or READY_COLOR
	end
end

local function refresh()
	local inArena = hasWalrus()

	-- One check drives both the buttons and the readout, so they can never
	-- disagree about whether you're allowed to attack.
	gui.Enabled = inArena
	setBound(inArena)

	if not inArena then
		return -- nothing to draw
	end

	drawRow(bonkRow, "BONK", "BonkReadyAt")

	-- The server names the special after it sees which walrus you're
	-- wearing. Until then, or for a walrus with no special yet, say so
	-- rather than promising a button that does nothing.
	local specialName = player:GetAttribute("SpecialName")
	if specialName then
		specialRow.Visible = true
		drawRow(specialRow, string.upper(specialName), "SpecialReadyAt")
	else
		specialRow.Visible = false
	end
end

refresh()
RunService.Heartbeat:Connect(refresh)
