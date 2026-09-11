--!strict
--[[
	WalrusController — the fire button, while you are a walrus.

	Three jobs, and two of them are the same job the turret's controller does:
	read the trigger, send it as a HELD flag at a fixed low rate, and say where
	the camera is pointing. The server owns the tick rate, the cone and the
	damage — see BecomeWalrus — so this sends a direction and a boolean and
	nothing else, and a client sending it every frame gets exactly what a client
	sending it fifteen times a second gets.

	The third job is the clock and the pool, drawn from the two attributes the
	server publishes. See Attributes.Player.WalrusHealth and WalrusUntil.

	── IT DOES NOT DECIDE ANYTHING ─────────────────────────────────────────────
	`IsWalrus` is the server's attribute and this only reads it. A client that set
	it locally would draw itself a health bar and a timer, send input that the
	server refuses because it is not actually a walrus, and be exactly as much a
	survivor as it was before.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attributes = require(Shared.Net.Attributes)
local Registry = require(Shared.Util.Registry)
local Remotes = require(Shared.Net.Remotes)
local Trove = require(Shared.Util.Trove)
local UITheme = require(Shared.Config.UITheme)

local COLOR = UITheme.Color
local FONT = UITheme.Font
local TEXT = UITheme.Text
local LAYOUT = UITheme.Layout
local PA = Attributes.Player

--[[ Matches TurretController's. Fifteen a second is far more than the server's
     own flame tick, so the held flag is never the thing that is late — and it is
     little enough traffic that a walrus costs less per second than one player
     walking. ]]
local INPUT_PERIOD = 1 / 15

local PANEL_WIDTH = 260
local PANEL_HEIGHT = 54
local BAR_HEIGHT = 8

local WalrusController = {}

local player = Players.LocalPlayer
local trove = Trove.new()

local gui: ScreenGui
local panel: Frame
local title: TextLabel
local clock: TextLabel
local barFill: Frame

local nextSendAt = 0
local wasFiring = false
local maxPool = 0

local function isWalrus(): boolean
	return player:GetAttribute(PA.IsWalrus) == true
end

local function poolNow(): number
	local value = player:GetAttribute(PA.WalrusHealth)
	return if typeof(value) == "number" then value else 0
end

local function secondsLeft(): number
	local until_ = player:GetAttribute(PA.WalrusUntil)
	if typeof(until_) ~= "number" or until_ <= 0 then
		return 0
	end
	return math.max(until_ - Workspace:GetServerTimeNow(), 0)
end

local function build()
	gui = Instance.new("ScreenGui")
	gui.Name = "FL_Walrus"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Enabled = false
	gui.Parent = player:WaitForChild("PlayerGui")
	trove:add(gui)

	--[[ Top centre, which is where this game already puts a thing that is
	     happening TO you rather than a thing you own — the boss bar lives there
	     and a walrus is the same kind of statement. Deliberately not the bottom
	     corners, which are the hotbar's and the pad's. ]]
	panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0.5, 0)
	panel.Position = UDim2.new(0.5, 0, 0, LAYOUT.ScreenMargin)
	panel.Size = UDim2.fromOffset(PANEL_WIDTH, PANEL_HEIGHT)
	panel.BackgroundColor3 = COLOR.Panel
	panel.BackgroundTransparency = 0.25
	panel.BorderSizePixel = 0
	panel.Parent = gui

	local stroke = Instance.new("UIStroke")
	stroke.Color = COLOR.BorderBright
	stroke.Thickness = 2
	stroke.Parent = panel

	title = Instance.new("TextLabel")
	title.Name = "Title"
	title.BackgroundTransparency = 1
	title.Position = UDim2.fromOffset(LAYOUT.PanelPadding, 4)
	title.Size = UDim2.new(0.6, 0, 0, 18)
	title.Font = FONT.Heading
	title.TextSize = TEXT.Small
	title.TextColor3 = COLOR.AccentBright
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Text = "WALRUS"
	title.Parent = panel

	clock = Instance.new("TextLabel")
	clock.Name = "Clock"
	clock.AnchorPoint = Vector2.new(1, 0)
	clock.BackgroundTransparency = 1
	clock.Position = UDim2.new(1, -LAYOUT.PanelPadding, 0, 4)
	clock.Size = UDim2.new(0.4, 0, 0, 18)
	clock.Font = FONT.Numeric
	clock.TextSize = TEXT.Small
	clock.TextColor3 = COLOR.TextPrimary
	clock.TextXAlignment = Enum.TextXAlignment.Right
	clock.Text = "3:00"
	clock.Parent = panel

	local track = Instance.new("Frame")
	track.Name = "Track"
	track.AnchorPoint = Vector2.new(0.5, 1)
	track.Position = UDim2.new(0.5, 0, 1, -LAYOUT.PanelPadding)
	track.Size = UDim2.new(1, -LAYOUT.PanelPadding * 2, 0, BAR_HEIGHT)
	track.BackgroundColor3 = COLOR.Border
	track.BackgroundTransparency = 0.4
	track.BorderSizePixel = 0
	track.Parent = panel

	barFill = Instance.new("Frame")
	barFill.Name = "Fill"
	barFill.Size = UDim2.fromScale(1, 1)
	barFill.BackgroundColor3 = COLOR.AccentBright
	barFill.BorderSizePixel = 0
	barFill.Parent = track
end

--[[ The trigger, wherever it lives on this device. Through InputController so a
     gamepad trigger and a phone's FIRE button both count — the walrus is exactly
     as playable on a thumb as the gun it replaces. ]]
local function firingNow(): boolean
	local input = Registry.find("InputController")
	if not input or typeof(input.isDown) ~= "function" then
		return false
	end
	local ok, down = pcall(input.isDown, input, (input :: any).Action.Fire)
	return ok and down == true
end

local function aimNow(): Vector3
	local camera = Workspace.CurrentCamera
	return if camera then camera.CFrame.LookVector else Vector3.zAxis
end

local function draw()
	local left = secondsLeft()
	clock.Text = string.format("%d:%02d", math.floor(left / 60), math.floor(left % 60))

	local pool = poolNow()
	--[[ The ceiling is learned from the first value seen rather than read from
	     config, so the bar cannot disagree with the server about what full is —
	     and a walrus that starts at less than full for any reason still draws a
	     bar that means something. ]]
	if pool > maxPool then
		maxPool = pool
	end
	barFill.Size = UDim2.fromScale(if maxPool > 0 then math.clamp(pool / maxPool, 0, 1) else 0, 1)
end

function WalrusController:init()
	build()
end

function WalrusController:start()
	trove:connect(RunService.Heartbeat, function()
		local active = isWalrus()
		if gui.Enabled ~= active then
			gui.Enabled = active
			if not active then
				--[[ One last trigger-up on the way out, for the same reason the
				     turret sends one when you stand up: the server times a silent
				     client out, but a walrus that keeps breathing for a third of a
				     second after it has stopped being one is a third of a second
				     of fire nobody asked for. ]]
				if wasFiring then
					wasFiring = false
					Remotes.Event.WalrusInput:FireServer({ aim = aimNow(), firing = false })
				end
				maxPool = 0
			end
		end
		if not active then
			return
		end

		draw()

		local now = os.clock()
		if now < nextSendAt then
			return
		end
		nextSendAt = now + INPUT_PERIOD

		local firing = firingNow()
		wasFiring = firing
		Remotes.Event.WalrusInput:FireServer({ aim = aimNow(), firing = firing })
	end)
end

function WalrusController:destroy()
	trove:destroy()
end

Registry.register("WalrusController", WalrusController)

return WalrusController
