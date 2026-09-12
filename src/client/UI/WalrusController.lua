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
local Glyph = require(script.Parent.Glyph)
local Registry = require(Shared.Util.Registry)
local Remotes = require(Shared.Net.Remotes)
local Trove = require(Shared.Util.Trove)
local UITheme = require(Shared.Config.UITheme)

local COLOR = UITheme.Color
local FONT = UITheme.Font
local TEXT = UITheme.TextSize
local LAYOUT = UITheme.Layout
local PA = Attributes.Player

--[[ Matches TurretController's. Fifteen a second is far more than the server's
     own flame tick, so the held flag is never the thing that is late — and it is
     little enough traffic that a walrus costs less per second than one player
     walking. ]]
local INPUT_PERIOD = 1 / 15

local PANEL_WIDTH = 260
--[[ Grown by a row for the keybind hint. See drawHint: a verb on a key nobody
     was told about is a verb nobody presses. ]]
local PANEL_HEIGHT = 78
--[[ How far above the bottom edge the panel sits. Enough to clear a phone's
     home indicator and anything else that hugs the very edge, without pushing
     it up into the middle of the screen where it would cover the fight. ]]
local BOTTOM_LIFT = 72
local BAR_HEIGHT = 8
local HINT_HEIGHT = 16

local WalrusController = {}

local player = Players.LocalPlayer
local trove = Trove.new()

local gui: ScreenGui
local panel: Frame
local title: TextLabel
local clock: TextLabel
local hint: TextLabel
local barFill: Frame

--[[ What the hint last said, so the label is written only when the answer
     changes — a scheme change or a rebind, not on every heartbeat. ]]
local hintShown = ""

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

	--[[
		Bottom centre, raised clear of the very edge.

		This was top centre, on the reasoning that the boss bar lives there and a
		walrus is the same kind of statement. It is not: a boss bar is a thing
		happening TO you and you read it once, while this is YOUR health and the
		clock you are playing against, and both belong where the rest of your own
		state is — down with the hotbar and the ammo.

		Centre rather than a corner, because the corners are taken: the hotbar
		holds the bottom right and the touch pad the bottom left. Raised by
		BOTTOM_LIFT so it clears anything hugging the very edge on a phone.
	]]
	panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0.5, 1)
	panel.Position = UDim2.new(0.5, 0, 1, -(LAYOUT.ScreenMargin + BOTTOM_LIFT))
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

	--[[
		Which button breathes fire, on the device actually being held.

		Through Glyph, which reads InputController's live bindings — so a player
		who rebinds Special sees the new key here without this file knowing a
		rebind happened. Keyboard gets "F", a pad gets "VIEW", and a touchscreen
		gets nothing at all because Glyph correctly answers "" for a device with
		no keys: the phone has a SPECIAL button on the pad instead, which is a
		label you can read by looking at your own thumb.
	]]
	hint = Instance.new("TextLabel")
	hint.Name = "Hint"
	hint.BackgroundTransparency = 1
	hint.Position = UDim2.fromOffset(LAYOUT.PanelPadding, 26)
	hint.Size = UDim2.new(1, -LAYOUT.PanelPadding * 2, 0, HINT_HEIGHT)
	hint.Font = FONT.Body
	hint.TextSize = TEXT.Small
	hint.TextColor3 = COLOR.AccentBright
	hint.TextXAlignment = Enum.TextXAlignment.Left
	hint.Text = ""
	hint.Parent = panel

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

--[[
	SPECIAL, wherever it lives on this device. Through InputController so a key,
	a pad button and a thumb all count.

	── IT USED TO READ FIRE, AND THAT COST THE PLAYER THEIR LOADOUT ────────────
	One trigger cannot mean two things. While this read Action.Fire, pulling it
	breathed fire AND told BallisticsService to shoot — so for three minutes a
	walrus carried a primary, a secondary and a melee it could not use, because
	the only button that fires them also spat flame every time.

	Two verbs, two buttons: Fire is still the gun, Special is the flame. See
	InputController's Action.Special for what it is bound to on each device.
]]
local function specialDown(): boolean
	local input = Registry.find("InputController")
	if not input or typeof(input.isDown) ~= "function" then
		return false
	end
	local ok, down = pcall(input.isDown, input, (input :: any).Action.Special)
	return ok and down == true
end

--[[ The scheme name, for the hint. Asked per draw rather than cached off a
     signal, because a player can put a keyboard down and pick a controller up
     mid-round and the line has to follow them. One string compare, on a panel
     that is only drawn while somebody is a walrus. ]]
local function schemeName(): string
	local input = Registry.find("InputController")
	if not input or typeof(input.getScheme) ~= "function" then
		return ""
	end
	local ok, scheme = pcall(input.getScheme, input)
	return if ok and typeof(scheme) == "string" then scheme else ""
end

local function drawHint()
	local glyph = Glyph.forAction("Special", schemeName())
	--[[ Nothing on a phone. Glyph answers "" for a touchscreen, and the pad's own
	     SPECIAL button is the label — a line naming a key the device does not
	     have is worse than no line at all. ]]
	local wanted = if glyph == "" then "" else glyph .. "  ·  BREATHE FIRE"
	if wanted ~= hintShown then
		hintShown = wanted
		hint.Text = wanted
	end
end

local function aimNow(): Vector3
	local camera = Workspace.CurrentCamera
	return if camera then camera.CFrame.LookVector else Vector3.zAxis
end

local function draw()
	drawHint()

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
				--[[ Cleared with the panel, so the next walrus re-reads its
				     binding rather than trusting one taken three minutes and
				     possibly one input device ago. ]]
				hintShown = ""
				hint.Text = ""
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

		local firing = specialDown()
		wasFiring = firing
		Remotes.Event.WalrusInput:FireServer({ aim = aimNow(), firing = firing })
	end)
end

function WalrusController:destroy()
	trove:destroy()
end

Registry.register("WalrusController", WalrusController)

return WalrusController
