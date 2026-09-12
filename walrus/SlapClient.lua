--[[
	SlapClient
	----------
	WHERE THIS GOES:  StarterPlayer > StarterPlayerScripts
	WHAT KIND:        LocalScript   (NOT a Script)

	Input only. Click, tap or pull the trigger and it tells the server you
	swung. It doesn't decide who got hit, how far they fly, or draw the
	lunge - the server does all of that, so every player sees the same
	swing rather than each seeing only their own.

	The cooldown here is just so the button feels honest. The server keeps
	its own, which is the one that actually counts.
]]

local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local player = Players.LocalPlayer
local slapEvent = ReplicatedStorage:WaitForChild("SlapEvent")

-- A hair under the server's 1 second. Asking slightly too early is fine -
-- the server just ignores it - but asking slightly too late means a bonk
-- you were entitled to and didn't get.
local COOLDOWN = 0.95

local ACTION_NAME = "Bonk"
local readyAt = 0

local function bonk()
	local now = os.clock()
	if now < readyAt then
		return
	end
	readyAt = now + COOLDOWN

	slapEvent:FireServer()
end

local function onAction(_actionName, inputState, _inputObject)
	-- Begin = the moment the button goes down. Without this it would fire
	-- again on the way back up.
	if inputState == Enum.UserInputState.Begin then
		bonk()
	end
end

-- One call covers all three: left mouse button, an on-screen button on
-- phones (that's what the `true` is for), and the right trigger on a
-- gamepad. It also stays quiet while you're typing in chat.
ContextActionService:BindAction(
	ACTION_NAME,
	onAction,
	true,
	Enum.UserInputType.MouseButton1,
	Enum.KeyCode.ButtonR2
)
ContextActionService:SetTitle(ACTION_NAME, "BONK")

-- ============================================================
--  THE COOLDOWN DIAL
-- ============================================================

local gui = Instance.new("ScreenGui")
gui.Name = "BonkHud"
gui.ResetOnSpawn = false -- survives dying, so it isn't rebuilt every respawn
gui.Parent = player:WaitForChild("PlayerGui")

local readout = Instance.new("TextLabel")
readout.AnchorPoint = Vector2.new(0.5, 1) -- measured from its own bottom middle
readout.Position = UDim2.new(0.5, 0, 1, -14) -- centred, 14px up from the bottom
readout.Size = UDim2.new(0, 180, 0, 36)
readout.BackgroundColor3 = Color3.fromRGB(18, 18, 22)
readout.BackgroundTransparency = 0.35
readout.Font = Enum.Font.GothamBold
readout.TextScaled = true
readout.Text = ""
readout.Parent = gui

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 8)
corner.Parent = readout

local READY_COLOR = Color3.fromRGB(255, 255, 255)
local WAITING_COLOR = Color3.fromRGB(150, 150, 160)

-- Only touch the label when the words actually change, rather than 60 times
-- a second for the whole match.
local shown = nil

local function refresh()
	local remaining = readyAt - os.clock()
	local text = (remaining > 0) and string.format("%.1fs", remaining) or "BONK READY"

	if text ~= shown then
		shown = text
		readout.Text = text
		readout.TextColor3 = (remaining > 0) and WAITING_COLOR or READY_COLOR
	end
end

refresh()
RunService.Heartbeat:Connect(refresh)
