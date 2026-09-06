--[[
	AbilityClient
	-------------
	WHERE THIS GOES:  StarterPlayer > StarterPlayerScripts
	WHAT KIND:        LocalScript   (NOT a Script)

	Two jobs: watch for the ability key, and draw the little readout at the
	bottom of the screen telling you what you have and whether it's ready.

	It never decides anything. No damage, no cooldown enforcement. Anything
	a cheater could lie about stays on the server.
]]

local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local player = Players.LocalPlayer

-- Waits for AbilityServer to create this when the game starts.
local useAbility = ReplicatedStorage:WaitForChild("UseAbility")

-- Waits for WalrusLeaderboard to build these.
local equipped = player:WaitForChild("leaderstats"):WaitForChild("Equipped")

local ACTION_NAME = "UseWalrusAbility"

-- ============================================================
--  THE KEY
-- ============================================================

local function onAction(_actionName, inputState, _inputObject)
	-- Begin = the moment the key goes down. Without this check it would
	-- also fire on the way back up.
	if inputState == Enum.UserInputState.Begin then
		useAbility:FireServer()
	end
end

-- One call covers all three: the E key, the right trigger on a gamepad, and
-- (because of the `true`) an on-screen button on phones and tablets.
ContextActionService:BindAction(ACTION_NAME, onAction, true, Enum.KeyCode.E, Enum.KeyCode.ButtonR2)
ContextActionService:SetTitle(ACTION_NAME, "ABILITY")

-- ============================================================
--  THE READOUT
-- ============================================================

local gui = Instance.new("ScreenGui")
gui.Name = "AbilityHud"
gui.ResetOnSpawn = false -- survives dying, so it isn't rebuilt every respawn
gui.Parent = player:WaitForChild("PlayerGui")

local readout = Instance.new("TextLabel")
readout.AnchorPoint = Vector2.new(0.5, 1) -- measured from its own bottom middle
readout.Position = UDim2.new(0.5, 0, 1, -14) -- centred, 14px up from the bottom
readout.Size = UDim2.new(0, 260, 0, 40)
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
	-- Same clock the server used, so this counts down in step with it.
	local remaining = (player:GetAttribute("AbilityReadyAt") or 0) - workspace:GetServerTimeNow()

	local text
	if equipped.Value == "None" then
		text = "NOTHING EQUIPPED"
	elseif remaining > 0 then
		text = string.upper(equipped.Value) .. "   " .. math.ceil(remaining) .. "s"
	else
		text = string.upper(equipped.Value) .. "   READY"
	end

	if text ~= shown then
		shown = text
		readout.Text = text
		readout.TextColor3 = (remaining > 0) and WAITING_COLOR or READY_COLOR
	end
end

refresh()
RunService.Heartbeat:Connect(refresh)
