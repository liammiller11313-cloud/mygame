--!nonstrict
--[[
	CodesController — type a code in, read what the server says back.

	── IT DECIDES NOTHING, AND THAT IS THE WHOLE FILE ───────────────────────────
	Whether a code exists, whether it is live, whether this account already used
	it, and what it pays are all CodeService's answers. This sends a string and
	draws the reply.

	That is not architectural neatness, it is the only version that works. The
	code strings are in a SHARED config and a player can read them out of the
	client, so anything checked here is checked by the attacker too. What makes a
	code exclusive is the window and the one-per-account rule, and both of those
	only mean anything on the server.

	── ONE MESSAGE LINE, TWO COLOURS ────────────────────────────────────────────
	The panel is a box, a button and a line of text. The line is the whole
	interface: it says what went wrong in the server's own words, or what was
	granted in them. Deliberately not a toast or a dialog — a player who mistypes
	a code wants to fix the string they can still see, not dismiss something
	covering it.

	── AND THE CODES ARE NOT LISTED ─────────────────────────────────────────────
	CodeConfig is right there and this panel could enumerate every code and its
	window. It does not, because a code you are told about is not a code you were
	given, and the whole point of handing one out is that somebody had to be
	somewhere to get it.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local AudioConfig = require(Shared.Config.AudioConfig)
local Registry = require(Shared.Util.Registry)
local Remotes = require(Shared.Net.Remotes)
local Trove = require(Shared.Util.Trove)
local UITheme = require(Shared.Config.UITheme)

local FreeCursor = require(script.Parent.FreeCursor)
local GamepadFocus = require(script.Parent.GamepadFocus)
local ScaleLayer = require(script.Parent.ScaleLayer)
local UiSound = require(script.Parent.UiSound)
local Widgets = require(script.Parent.Widgets)

local COLOR = UITheme.Color
local FONT = UITheme.Font
local LAYOUT = UITheme.Layout
local PANEL = UITheme.Panel
local TEXT = UITheme.TextSize

local player = Players.LocalPlayer

local PANEL_WIDTH = 560
local PANEL_HEIGHT = 300
local HEADER_HEIGHT = PANEL.HeaderHeight

local FIELD_HEIGHT = 52
local BUTTON_HEIGHT = 46

--[[ How long an answer stays on screen. Long enough to read a refusal twice,
     short enough that it is gone before the next attempt is typed. ]]
local MESSAGE_SECONDS = 7

--[[ A redeem the server never answered. Only reachable if CodeService is not
     running at all, which is a broken build rather than a broken code — but a
     button that stays on BUSY forever looks like the code was rejected, so it
     lets go and says so. ]]
local ANSWER_TIMEOUT = 6

-- Comfortably past the longest code, and nowhere near a paste of a novel.
local MAX_CODE_LENGTH = 64

local CodesController = {}

local trove = Trove.new()

local gui: ScreenGui
local panel: Frame
local closeButton: TextButton
local field: TextBox
local redeemButton: TextButton
local redeemLabel: TextLabel
local messageLabel: TextLabel

local state = {
	open = false,
	pending = false,
	messageUntil = 0,
	--[[ Whether the world is currently handed over to this panel. Memoised so
	     the five suppression calls are made on the EDGE rather than on every
	     open — and so a second open cannot double-suppress a round that a single
	     close then hands back. ]]
	suppressed = false,
}

local function callController(name: string, method: string, ...: any)
	local controller: any = Registry.find(name)
	if controller and typeof(controller[method]) == "function" then
		controller[method](controller, ...)
	end
end

local function menuIsOpen(): boolean
	local menu: any = Registry.find("MainMenuController")
	return menu ~= nil and typeof(menu.isOpen) == "function" and menu:isOpen()
end

--[[
	Everything the world takes back while this panel is up.

	The same five calls every other modal in this folder makes, in the same
	order. This one used to make ONE — to a method that does not exist — and
	`callController` is deliberately silent when a name does not resolve, which
	is what let a typo sit here doing nothing at all rather than erroring on the
	first open.

	`setMuted(nil)` is not optional on the way out: setMuted REPLACES the muted
	set, so a panel that closed without clearing it would leave the trigger dead.
]]
local function setSuppressed(value: boolean)
	if state.suppressed == value then
		return
	end
	state.suppressed = value
	callController("InputController", "setMuted", nil)
	callController("InputController", "setEnabled", not value)
	callController("CrosshairController", "setVisible", not value)
	callController("PromptController", "setEnabled", not value)
	callController("TouchController", "setVisible", not value)
end

local function restore()
	if state.open then
		CodesController:close()
	end
end

local function showMessage(text: string, color: Color3)
	messageLabel.Text = text
	messageLabel.TextColor3 = color
	state.messageUntil = os.clock() + MESSAGE_SECONDS
	task.delay(MESSAGE_SECONDS, function()
		if os.clock() >= state.messageUntil then
			messageLabel.Text = ""
		end
	end)
end

local function refreshButton()
	redeemLabel.Text = if state.pending then "CHECKING…" else "REDEEM"
	redeemLabel.TextColor3 = if state.pending then COLOR.TextDim else COLOR.AccentBright
	redeemButton.Active = not state.pending
	redeemButton.Selectable = not state.pending
	redeemButton.BackgroundTransparency = if state.pending then 0.6 else 0.15
end

local function submit()
	if state.pending then
		return
	end
	local typed = field.Text
	if typed == "" then
		showMessage("ENTER A CODE", COLOR.TextDim)
		return
	end
	--[[ The longest code is fourteen characters. Anything past sixty-four is
	     somebody pasting an essay into a remote, and while the server refuses it
	     too, there is no reason to put it on the wire. Not a security measure —
	     a client can send whatever it likes — just a refusal to help. ]]
	if #typed > MAX_CODE_LENGTH then
		showMessage("THAT IS NOT A CODE", COLOR.Danger)
		return
	end

	state.pending = true
	refreshButton()
	Remotes.Event.RedeemCode:FireServer(typed)
	UiSound.play(AudioConfig.UI.MenuConfirm)

	--[[ Released on a timer as well as on the answer. Whichever arrives first
	     wins; the timer only ever matters when nothing is listening on the far
	     end, and a button stuck on CHECKING… reads as a rejection. ]]
	task.delay(ANSWER_TIMEOUT, function()
		if state.pending then
			state.pending = false
			refreshButton()
			showMessage("NO ANSWER — TRY AGAIN", COLOR.Danger)
		end
	end)
end

local function onResult(payload: any)
	if typeof(payload) ~= "table" then
		return
	end
	state.pending = false
	refreshButton()

	local ok = payload.ok == true
	local reason = tostring(payload.reason or "")
	local granted = tostring(payload.granted or "")

	if ok then
		--[[ Cleared only on success. A refusal leaves the string in the box,
		     because the most common refusal is a typo and retyping fourteen
		     characters to fix one of them is the panel's fault, not the
		     player's. ]]
		field.Text = ""
		UiSound.play(AudioConfig.UI.WaveCleared)
		showMessage(if granted ~= "" then "REDEEMED  —  " .. granted else reason, COLOR.Accent)
	else
		UiSound.play(AudioConfig.UI.MenuBack)
		showMessage(reason, COLOR.Danger)
	end
end

-- ── build ───────────────────────────────────────────────────────────────────

local function refreshPanelSize()
	if not panel then
		return
	end
	local camera = Workspace.CurrentCamera
	local factor = ScaleLayer.getFactor()
	local viewport = if camera and factor > 0 then camera.ViewportSize / factor else nil

	local width = math.min(
		PANEL_WIDTH,
		math.max((if viewport then viewport.X else PANEL_WIDTH) - LAYOUT.ScreenMargin * 2, 280)
	)
	local height = math.min(
		PANEL_HEIGHT,
		math.max((if viewport then viewport.Y else PANEL_HEIGHT) - LAYOUT.ScreenMargin * 2, 220)
	)
	panel.Size = UDim2.fromOffset(width, height)
end

local function build()
	gui = Instance.new("ScreenGui")
	gui.Name = "FL_Codes_Panel"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = UITheme.DisplayOrder.Settings
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Enabled = false
	gui.Parent = player:WaitForChild("PlayerGui")
	trove:add(gui)

	local layer = ScaleLayer.new(gui, "Scaled")
	local chrome = Widgets.panel(layer, trove, "CODES", function()
		CodesController:close()
	end)
	panel = chrome.frame
	closeButton = chrome.close

	local blurb = Widgets.label(panel, "Blurb", FONT.Body, TEXT.Small, COLOR.TextDim)
	blurb.Position = UDim2.fromOffset(LAYOUT.PanelPadding, HEADER_HEIGHT + LAYOUT.PanelPadding)
	blurb.Size = UDim2.new(1, -LAYOUT.PanelPadding * 2, 0, TEXT.Body)
	blurb.Text = "CODES ARE HANDED OUT. THEY EXPIRE."

	local fieldTop = HEADER_HEIGHT + LAYOUT.PanelPadding + TEXT.Body + LAYOUT.ElementGap

	local box = Widgets.frame(panel, "Field", COLOR.PanelRaised, PANEL.ActionFill)
	box.Position = UDim2.fromOffset(LAYOUT.PanelPadding, fieldTop)
	box.Size = UDim2.new(1, -LAYOUT.PanelPadding * 2, 0, FIELD_HEIGHT)
	Widgets.stroke(box, COLOR.Border)

	field = Instance.new("TextBox")
	field.Name = "Input"
	field.BackgroundTransparency = 1
	field.Position = UDim2.fromOffset(LAYOUT.PanelPadding, 0)
	field.Size = UDim2.new(1, -LAYOUT.PanelPadding * 2, 1, 0)
	field.Font = FONT.Numeric
	field.TextSize = TEXT.Large
	field.TextColor3 = COLOR.TextPrimary
	field.PlaceholderText = "ENTER CODE"
	field.PlaceholderColor3 = COLOR.TextDim
	field.TextXAlignment = Enum.TextXAlignment.Left
	field.ClearTextOnFocus = false
	field.TextEditable = true
	field.Parent = box

	redeemButton = Widgets.button(panel, "Redeem")
	redeemButton.AnchorPoint = Vector2.new(1, 0)
	redeemButton.Position = UDim2.new(1, -LAYOUT.PanelPadding, 0, fieldTop + FIELD_HEIGHT + LAYOUT.ElementGap)
	redeemButton.Size = UDim2.fromOffset(200, BUTTON_HEIGHT)
	redeemButton.BackgroundColor3 = COLOR.PanelRaised
	redeemButton.BackgroundTransparency = PANEL.ActionFill
	Widgets.stroke(redeemButton, COLOR.Border)

	redeemLabel = Widgets.label(redeemButton, "Label", FONT.Heading, TEXT.Body, COLOR.AccentBright)
	redeemLabel.Size = UDim2.fromScale(1, 1)
	redeemLabel.TextXAlignment = Enum.TextXAlignment.Center

	messageLabel = Widgets.label(panel, "Message", FONT.Body, TEXT.Small, COLOR.TextDim)
	messageLabel.Position = UDim2.fromOffset(
		LAYOUT.PanelPadding,
		fieldTop + FIELD_HEIGHT + LAYOUT.ElementGap + BUTTON_HEIGHT + LAYOUT.ElementGap
	)
	messageLabel.Size = UDim2.new(1, -LAYOUT.PanelPadding * 2, 0, TEXT.Body * 2)
	messageLabel.TextWrapped = true
	messageLabel.TextYAlignment = Enum.TextYAlignment.Top

	trove:connect(redeemButton.Activated, submit)
	--[[ Enter submits. `enterPressed` is false when the box lost focus for any
	     other reason — clicking away, opening a menu — and submitting on those
	     would fire a remote the player did not ask for. ]]
	trove:connect(field.FocusLost, function(enterPressed: boolean)
		if enterPressed then
			submit()
		end
	end)

	refreshButton()
	refreshPanelSize()
end

-- ── surface ─────────────────────────────────────────────────────────────────

function CodesController:isOpen(): boolean
	return state.open
end

function CodesController:open()
	if state.open then
		return
	end
	state.open = true
	gui.Enabled = true
	refreshPanelSize()
	refreshButton()
	messageLabel.Text = ""
	setSuppressed(not menuIsOpen())
	FreeCursor.take(restore)
	GamepadFocus.capture(redeemButton)
	UiSound.play(AudioConfig.UI.MenuConfirm)
end

function CodesController:close()
	if not state.open then
		return
	end
	state.open = false
	gui.Enabled = false
	GamepadFocus.release(closeButton)
	setSuppressed(false)
	FreeCursor.giveBack(restore)
	if menuIsOpen() then
		callController("MainMenuController", "reassertSuppression")
	end
	UiSound.play(AudioConfig.UI.MenuBack)
end

function CodesController:toggle()
	if state.open then
		self:close()
	else
		self:open()
	end
end

function CodesController:init()
	build()
end

function CodesController:start()
	trove:connect(Remotes.Event.CodeResult.OnClientEvent, onResult)

	trove:connect(UserInputService.InputBegan, function(input: InputObject, processed: boolean)
		if not state.open then
			return
		end
		--[[
			B backs out, as it does on every other panel in the game. This screen
			was the one that did not have it — the only way out was Escape, which
			a console does not have, so a controller could open CODES and could
			not leave it.

			Before the processed guard, because the panel is focused while it is
			up and its own presses arrive marked processed. It follows Escape's
			rule about the text box for the same reason: while somebody is typing,
			back means abandon the typing, and taking two intentions from one
			press is how a player loses a code they were halfway through.
		]]
		if input.KeyCode == Enum.KeyCode.ButtonB then
			if field:IsFocused() then
				field:ReleaseFocus(false)
			else
				CodesController:close()
			end
			return
		end
		if processed then
			return
		end
		if input.KeyCode == Enum.KeyCode.Escape and not field:IsFocused() then
			CodesController:close()
		end
	end)
end

function CodesController:destroy()
	trove:destroy()
end

Registry.register("CodesController", CodesController)

return CodesController
