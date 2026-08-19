--!nonstrict
--[[
	PauseController — the button in the corner, and what is behind it.

	Three entries: RESUME, SETTINGS, RETURN TO MAIN MENU. It is the one place a
	player can reliably get out of whatever they are in, on every platform, and
	that is the whole reason it exists — a keyboard has Escape (which belongs to
	Roblox), a pad has a menu button (which also belongs to Roblox), and a phone
	has nothing at all.

	── IT ABSORBED THE SETTINGS BUTTON ──────────────────────────────────────────
	SettingsController used to draw its own gear in this corner, on phones only,
	and the kill feed already steps aside for it. Two buttons fighting for one
	corner is worse than one button that leads to both, so this is that button on
	EVERY platform and settings is one press deeper. `O` still opens settings
	directly, because a shortcut that already worked should keep working.

	── NOTHING IS ACTUALLY PAUSED ───────────────────────────────────────────────
	Roblox has no pause in a multiplayer game and pretending otherwise would be a
	lie told to one player while three others fight. What this does is the same
	thing every other menu in this game does: suppress input, free the cursor,
	and dim the world. The horde keeps coming. The overlay says so.

	── RETURN TO MAIN MENU ──────────────────────────────────────────────────────
	Opens the main menu over the round rather than leaving the server, because
	leaving is what the Roblox menu is for and because the mode entries on that
	screen are how a player moves servers here. The round carries on behind it —
	stated on the button, not hidden.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local AudioConfig = require(Shared.Config.AudioConfig)
local Attributes = require(Shared.Net.Attributes)
local Enums = require(Shared.Enums)
local Registry = require(Shared.Util.Registry)
local Trove = require(Shared.Util.Trove)
local UITheme = require(Shared.Config.UITheme)

local GamepadFocus = require(script.Parent.GamepadFocus)
local ScaleLayer = require(script.Parent.ScaleLayer)
local UiSound = require(script.Parent.UiSound)
local Widgets = require(script.Parent.Widgets)

local COLOR = UITheme.Color
local FONT = UITheme.Font
local LAYOUT = UITheme.Layout
local PANEL = UITheme.Panel
local TEXT = UITheme.TextSize
local PA = Attributes.Player
local STATE = Enums.SurvivorState

local player = Players.LocalPlayer

-- ── layout, in reference pixels ─────────────────────────────────────────────
local BUTTON_SIZE = LAYOUT.PauseButtonSize

--[[ Drawn as two bars rather than set as a pause character: the display faces
     this interface uses are Latin text faces, and a glyph one of them happens
     not to carry renders as an empty box. ]]
local BAR_WIDTH = 4
local BAR_HEIGHT = 16
local BAR_GAP = 6

--[[ Deliberately NOT the header-and-CLOSE panel the shop, the settings screen
     and the loadout screen share. This one is not a dialog laid over a screen —
     it IS the screen, three choices centred on black, and giving it a title bar
     with a CLOSE in the corner would make the way out of every other panel look
     like the way out of the game. What it does share is the scrim: a modal in
     this game dims the world by exactly one amount. ]]
local PANEL_WIDTH = 340
local ENTRY_HEIGHT = 54
local ENTRY_GAP = 8

local ENTRIES = {
	{ id = "Resume", title = "RESUME", line = "Back to it." },
	{ id = "Settings", title = "SETTINGS", line = "Graphics, audio, controls, difficulty." },
	{ id = "Menu", title = "RETURN TO MAIN MENU", line = "The round keeps going without you." },
}

local PauseController = {}

local trove = Trove.new()

local gui: ScreenGui
local panel: Frame
local subtitle: TextLabel
local entries: { any } = {}

local buttonGui: ScreenGui
local pauseButton: TextButton

local state = {
	open = false,
	--[[ Whether the interface underneath wants a button in the corner at all.
	     The main menu turns this off with everything else it suppresses. ]]
	allowed = true,
	suppressed = false,
}

local restore = {
	cameraMode = nil :: any,
	mouseIcon = nil :: any,
}

-- ── small helpers ───────────────────────────────────────────────────────────

local function callController(name: string, method: string, ...: any)
	local controller = Registry.find(name)
	if controller and typeof(controller[method]) == "function" then
		pcall(controller[method], controller, ...)
	end
end

local function menuIsOpen(): boolean
	local menu = Registry.find("MainMenuController")
	if not menu or typeof(menu.isOpen) ~= "function" then
		return false
	end
	local ok, open = pcall(menu.isOpen, menu)
	return ok and open == true
end

--[[
	Whether the corner button is drawn.

	It does NOT need to know about the shop, the loadout screen or the settings
	panel. All three draw a full-screen scrim on a higher DisplayOrder, and a
	scrim is a TextButton — so the pause button is both hidden behind it and
	unclickable through it, for free.

	The main menu is the exception and the reason `allowed` exists: its backdrop
	is a plain Frame, and a Frame does not block input in Roblox. Without being
	told, this button would sit invisible behind the menu and still be pressable.
]]
local function refreshButton()
	if not buttonGui then
		return
	end
	buttonGui.Enabled = state.allowed and not state.open and not menuIsOpen()
end

-- ── suppression ─────────────────────────────────────────────────────────────

--[[
	Frees the cursor and takes the trigger away, exactly as the settings panel
	does — and for the same reason it does it conditionally. When the main menu
	is already up it has done all of this itself, and a second owner restoring
	on close would hand a live camera back to a player still in the lobby.
]]
local function setSuppressed(value: boolean)
	if state.suppressed == value then
		return
	end
	state.suppressed = value

	callController("InputController", "setEnabled", not value)
	callController("CrosshairController", "setVisible", not value)
	callController("PromptController", "setEnabled", not value)
	callController("TouchController", "setVisible", not value)

	if value then
		restore.cameraMode = player.CameraMode
		restore.mouseIcon = UserInputService.MouseIconEnabled
		player.CameraMode = Enum.CameraMode.Classic
		UserInputService.MouseIconEnabled = true
	else
		if restore.cameraMode ~= nil then
			player.CameraMode = restore.cameraMode
		end
		if restore.mouseIcon ~= nil then
			UserInputService.MouseIconEnabled = restore.mouseIcon
		end
		restore.cameraMode = nil
		restore.mouseIcon = nil
	end
end

-- ── the entries ─────────────────────────────────────────────────────────────

local function activate(id: string)
	if id == "Resume" then
		PauseController:close()
	elseif id == "Settings" then
		--[[ Closed first. The settings panel does its own suppression and its
		     own gamepad capture, and two overlays holding both at once is how a
		     player ends up unable to close either. ]]
		PauseController:close()
		callController("SettingsController", "open")
	elseif id == "Menu" then
		PauseController:close()
		callController("MainMenuController", "open")
	end
end

-- ── build ───────────────────────────────────────────────────────────────────

local function buildButton()
	buttonGui = Instance.new("ScreenGui")
	buttonGui.Name = "FL_PauseButton"
	buttonGui.ResetOnSpawn = false
	buttonGui.IgnoreGuiInset = true
	--[[ On the HUD's layer: it is part of the interface being played through and
	     has to sit under anything that covers the screen. ]]
	buttonGui.DisplayOrder = UITheme.DisplayOrder.Hud
	buttonGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	buttonGui.Enabled = false
	buttonGui.Parent = player:WaitForChild("PlayerGui")
	trove:add(buttonGui)

	local layer = ScaleLayer.new(buttonGui, "Scaled")
	pauseButton = Widgets.button(layer, "Pause")
	pauseButton.AnchorPoint = Vector2.new(1, 0)
	pauseButton.Position = UDim2.new(1, -LAYOUT.ScreenMargin, 0, LAYOUT.ScreenMargin)
	pauseButton.Size = UDim2.fromOffset(BUTTON_SIZE, BUTTON_SIZE)
	pauseButton.BackgroundColor3 = COLOR.Panel
	pauseButton.BackgroundTransparency = 0.25

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0)
	corner.Parent = pauseButton
	Widgets.stroke(pauseButton, COLOR.Border)

	for index = 1, 2 do
		local bar = Widgets.frame(pauseButton, "Bar" .. index, COLOR.TextSecondary, 0)
		bar.AnchorPoint = Vector2.new(0.5, 0.5)
		bar.Position = UDim2.new(0.5, (if index == 1 then -1 else 1) * BAR_GAP * 0.5, 0.5, 0)
		bar.Size = UDim2.fromOffset(BAR_WIDTH, BAR_HEIGHT)
	end

	trove:connect(pauseButton.Activated, function()
		PauseController:open()
	end)
end

local function buildEntry(index: number, definition: any)
	local button = Widgets.button(panel, definition.id)
	button.Position = UDim2.new(0, 0, 0, (index - 1) * (ENTRY_HEIGHT + ENTRY_GAP))
	button.Size = UDim2.new(1, 0, 0, ENTRY_HEIGHT)
	button.BackgroundColor3 = COLOR.PanelRaised
	button.BackgroundTransparency = PANEL.RaisedFill
	local stroke = Widgets.stroke(button, COLOR.Border)

	local bar = Widgets.frame(button, "Bar", COLOR.Accent, 1)
	bar.Size = UDim2.new(0, 3, 1, 0)

	local title = Widgets.label(button, "Title", FONT.Heading, TEXT.Large, COLOR.TextPrimary)
	title.Position = UDim2.fromOffset(LAYOUT.PanelPadding + 6, 4)
	title.Size = UDim2.new(1, -LAYOUT.PanelPadding, 0, TEXT.Large + 2)
	title.Text = definition.title

	local line = Widgets.label(button, "Line", FONT.Body, TEXT.Tiny, COLOR.TextDim)
	line.Position = UDim2.fromOffset(LAYOUT.PanelPadding + 6, TEXT.Large + 6)
	line.Size = UDim2.new(1, -LAYOUT.PanelPadding, 0, TEXT.Body)
	line.Text = definition.line

	entries[index] = { button = button, stroke = stroke, bar = bar, title = title }

	Widgets.outlineHover(trove, button, stroke)
	trove:connect(button.MouseEnter, function()
		bar.BackgroundTransparency = 0
		title.TextColor3 = COLOR.AccentBright
	end)
	trove:connect(button.MouseLeave, function()
		bar.BackgroundTransparency = 1
		title.TextColor3 = COLOR.TextPrimary
	end)
	trove:connect(button.Activated, function()
		UiSound.play(AudioConfig.UI.MenuConfirm)
		activate(definition.id)
	end)
end

local function build()
	gui = Instance.new("ScreenGui")
	gui.Name = "FL_Pause"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	--[[ Above the shop and the loadout screen, which are on the settings layer:
	     the pause menu is what a player reaches for to get OUT of one of those,
	     so it must never end up behind one. ]]
	gui.DisplayOrder = UITheme.DisplayOrder.Pause
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Enabled = false
	gui.Parent = player:WaitForChild("PlayerGui")
	trove:add(gui)

	local layer = ScaleLayer.new(gui, "Scaled")
	local scrim = Widgets.scrim(layer, PANEL.Scrim)
	trove:connect(scrim.Activated, function()
		PauseController:close()
	end)

	panel = Widgets.frame(layer, "Panel", COLOR.Background, 1)
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromOffset(PANEL_WIDTH, #ENTRIES * (ENTRY_HEIGHT + ENTRY_GAP) - ENTRY_GAP)

	local title = Widgets.label(layer, "Title", FONT.Stencil, TEXT.Display, COLOR.TextPrimary)
	title.AnchorPoint = Vector2.new(0.5, 1)
	title.Position = UDim2.new(0.5, 0, 0.5, -(panel.Size.Y.Offset * 0.5 + LAYOUT.ScreenMargin * 2))
	title.Size = UDim2.new(0.8, 0, 0, TEXT.Display + 6)
	title.TextXAlignment = Enum.TextXAlignment.Center
	title.Text = "PAUSED"

	subtitle = Widgets.label(layer, "Subtitle", FONT.Body, TEXT.Small, COLOR.TextDim)
	subtitle.AnchorPoint = Vector2.new(0.5, 0)
	subtitle.Position = UDim2.new(0.5, 0, 0.5, -(panel.Size.Y.Offset * 0.5 + LAYOUT.ScreenMargin))
	subtitle.Size = UDim2.new(0.8, 0, 0, TEXT.Body)
	subtitle.TextXAlignment = Enum.TextXAlignment.Center

	for index, definition in ENTRIES do
		buildEntry(index, definition)
	end

	buildButton()
end

-- ── public API ──────────────────────────────────────────────────────────────

function PauseController:isOpen(): boolean
	return state.open
end

--[[ Whether the corner button may be drawn. Called by whatever is suppressing
     the HUD, on the same footing as it hides the touch pad. ]]
function PauseController:setButtonVisible(value: boolean)
	state.allowed = value ~= false
	refreshButton()
end

function PauseController:open()
	if state.open then
		return
	end
	state.open = true
	gui.Enabled = true

	--[[ Said out loud, because it is the one thing a pause menu in a multiplayer
	     game has to be honest about. A player who believes the game is paused and
	     walks away comes back to a corpse. ]]
	local downed = Attributes.get(player, PA.State, STATE.Spectating) == STATE.Incapacitated
	subtitle.Text = if downed
		then "YOU ARE STILL ON THE FLOOR. THIS DOES NOT STOP ANYTHING."
		else "THE ROUND IS STILL RUNNING."

	setSuppressed(not menuIsOpen())
	refreshButton()
	GamepadFocus.capture(entries[1] and entries[1].button)
	UiSound.play(AudioConfig.UI.MenuConfirm)
end

function PauseController:close()
	if not state.open then
		return
	end
	state.open = false
	gui.Enabled = false
	GamepadFocus.release(entries[1] and entries[1].button)
	setSuppressed(false)
	--[[ The menu can have opened underneath while this was up — RETURN TO MAIN
	     MENU does exactly that — in which case the restore above has just handed
	     input and gamepad selection back over a menu that is still on screen. ]]
	if menuIsOpen() then
		callController("MainMenuController", "reassertSuppression")
	end
	refreshButton()
	UiSound.play(AudioConfig.UI.MenuBack)
end

function PauseController:toggle()
	if state.open then
		self:close()
	else
		self:open()
	end
end

-- ── lifecycle ───────────────────────────────────────────────────────────────

function PauseController:init()
	build()
end

function PauseController:start()
	trove:connect(UserInputService.InputBegan, function(input: InputObject, processed: boolean)
		--[[ B and P close it before the processed guard: the overlay is focused
		     while it is up, so its own presses arrive marked processed, and a
		     player who cannot back out of a pause menu is genuinely stuck. ]]
		if state.open then
			if input.KeyCode == Enum.KeyCode.ButtonB or input.KeyCode == Enum.KeyCode.P then
				PauseController:close()
			end
			return
		end
		if processed then
			return
		end
		--[[ P, and the pad's view button. Not Escape and not Start: both belong
		     to Roblox, and taking either would take the platform menu with it. ]]
		if input.KeyCode == Enum.KeyCode.P or input.KeyCode == Enum.KeyCode.ButtonSelect then
			PauseController:open()
		end
	end)

	--[[
		CameraController re-applies LockFirstPerson on every survivor state change,
		and LockFirstPerson pins the cursor to the middle of the screen. If that
		lands while this is up, nothing on it can be clicked. Deferred, because it
		runs on the same signal and has to land after that handler.
	]]
	trove:connect(player:GetAttributeChangedSignal(PA.State), function()
		if not state.suppressed then
			return
		end
		task.defer(function()
			if not state.suppressed then
				return
			end
			restore.cameraMode = player.CameraMode
			player.CameraMode = Enum.CameraMode.Classic
			UserInputService.MouseIconEnabled = true
		end)
	end)

	refreshButton()
end

function PauseController:destroy()
	setSuppressed(false)
	table.clear(entries)
	trove:destroy()
end

Registry.register("PauseController", PauseController)

return PauseController
