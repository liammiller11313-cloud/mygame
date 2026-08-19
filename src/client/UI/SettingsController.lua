--!nonstrict
--[[
	SettingsController — the options panel, and the only owner of a player's
	preferences.

	One panel, reachable from both places a player might want it: the main menu
	before a round, and over the top of a live one. Same screen, same store, same
	code — a second in-game options screen that drifted from the menu's would be
	two answers to "what is my sensitivity".

	── WHAT LIVES WHERE ────────────────────────────────────────────────────────
	Shared/Config/SettingsConfig declares WHAT the options are: their names,
	kinds, ranges and defaults. This file decides how they are drawn, where they
	are stored, and what applying one means. Adding an option is a change to that
	file only — a new row appears here with no UI work, because nothing below
	names a specific setting except `applySetting`, which is the one place that
	has to know what a value MEANS.

	── APPLYING ────────────────────────────────────────────────────────────────
	Every value is pushed at whatever owns it through `callController`, so a
	client missing its gore controller still gets a working options screen. Every
	setting is applied once at start as well as on change, which is what makes a
	preference restored from a previous server take effect before the first shot
	rather than the first time the panel is opened.

	── HOW IT IS REACHED ───────────────────────────────────────────────────────
	From the main menu's SETTINGS entry, from the pause menu, and from `O` on a
	keyboard. It used to draw its own button in the top-right corner on phones;
	PauseController owns that corner now and settings is one press inside it, so
	there is one button there rather than two fighting over it.

	── PERSONAL DIFFICULTY ─────────────────────────────────────────────────────
	The one setting with a server side, and the only one that leaves this
	machine. The client says what it wants; the server validates it against the
	same SettingsConfig table and applies it to damage arriving at that player
	and nothing else. It cannot make anybody stronger — see SettingsConfig's
	header.

	── REBINDING ───────────────────────────────────────────────────────────────
	A keybind row captures the next input and hands it to InputController:rebind,
	preserving the keys of the OTHER families: rebinding RELOAD to T must not
	silently take the gamepad's X button away from it. A key already spoken for
	is refused with the name of the verb that owns it rather than being stolen,
	because stealing it can leave that verb with nothing bound to it at all.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TeleportService = game:GetService("TeleportService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attributes = require(Shared.Net.Attributes)
local AudioConfig = require(Shared.Config.AudioConfig)
local Registry = require(Shared.Util.Registry)
local Remotes = require(Shared.Net.Remotes)
local SettingsConfig = require(Shared.Config.SettingsConfig)
local Signal = require(Shared.Util.Signal)
local Trove = require(Shared.Util.Trove)
local UITheme = require(Shared.Config.UITheme)

local GamepadFocus = require(script.Parent.GamepadFocus)
local ScaleLayer = require(script.Parent.ScaleLayer)

local COLOR = UITheme.Color
local FONT = UITheme.Font
local LAYOUT = UITheme.Layout
local TEXT = UITheme.TextSize

local player = Players.LocalPlayer

-- ── layout, in reference pixels ─────────────────────────────────────────────
local PANEL_WIDTH = 620
local PANEL_HEIGHT_SCALE = 0.84
local HEADER_HEIGHT = 38
local TAB_HEIGHT = 30
local FOOTER_HEIGHT = 34
local SCRIM = 0.35

--[[ Row heights, by scheme. A finger is not a cursor: 46 reference pixels is a
     comfortable mouse target and a cramped thumb one, and on the phone where
     that matters the whole panel is being drawn at the 0.75 scale floor. ]]
local ROW_HEIGHT = 46
local ROW_HEIGHT_TOUCH = 58

local STEP_BUTTON = 30
local STEP_BUTTON_TOUCH = 40

local SCROLLBAR_WIDTH = 3

--[[ How many presses it takes to cross a slider end to end. Twenty is fine
     enough that nobody feels the steps and coarse enough that a volume can be
     set with a thumb in about a second. ]]
local SLIDER_STEPS = 20

-- How long a refusal or a hint stays in a row before the row goes back to
-- showing its value.
local FLASH_SECONDS = 1.6

--[[ Inputs arriving within this long of a capture starting are the CLICK that
     started it, not the key being bound. Without it, opening the capture with
     the mouse instantly binds mouse 1. ]]
local CAPTURE_GRACE = 0.2

local SETTING_PREFIX = "FL_Setting_"

local SettingsController = {}

--[[ Fires (key, value) after a setting is stored and applied. For anything that
     wants to react to a preference without polling this table. ]]
SettingsController.changed = Signal.new()

local trove = Trove.new()

--[[ The rows are torn down and rebuilt every time a tab is picked or the panel
     is reopened, so their connections cannot go in the trove above — fifty
     openings would leave fifty generations of dead handlers in it. This one is
     cleaned on every render. ]]
local rowTrove = Trove.new()

local gui: ScreenGui
local scrim: TextButton
local panel: Frame
local tabHolder: Frame
local list: ScrollingFrame
local hint: TextLabel

local tabs: { any } = {}
local rows: { any } = {}
local firstRowButton: TextButton? = nil

local values: { [string]: any } = SettingsConfig.defaults()

local state = {
	open = false,
	category = SettingsConfig.Categories[1],
	--[[ Whether WE took the game over. False when the menu is already up, which
	     has done it already — restoring from both would hand the player back a
	     camera the menu still wants suppressed. ]]
	suppressed = false,
	--[[ The keybind row waiting for an input, and when it started waiting. ]]
	capturing = nil :: any,
	captureAt = 0,
}

local restore = {
	cameraMode = nil :: any,
	mouseIcon = nil :: any,
}

-- ── small helpers ───────────────────────────────────────────────────────────

--[[ Calls a method on another controller if it exists, without caring whether it
     does. Every setting is presentation: a client missing its music controller
     must still be able to change its sensitivity. ]]
local function callController(name: string, method: string, ...: any)
	local controller = Registry.find(name)
	if controller and typeof(controller[method]) == "function" then
		pcall(controller[method], controller, ...)
	end
end

local function newFrame(parent: Instance, name: string, color: Color3?, transparency: number?): Frame
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.BackgroundColor3 = color or COLOR.Panel
	frame.BackgroundTransparency = transparency or 0
	frame.BorderSizePixel = 0
	frame.Parent = parent
	return frame
end

local function newLabel(
	parent: Instance,
	name: string,
	font: Enum.Font,
	size: number,
	color: Color3
): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = name
	label.BackgroundTransparency = 1
	label.BorderSizePixel = 0
	label.Font = font
	label.TextSize = size
	label.TextColor3 = color
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Center
	label.Text = ""
	label.Parent = parent
	return label
end

local function newButton(parent: Instance, name: string): TextButton
	local button = Instance.new("TextButton")
	button.Name = name
	button.BackgroundTransparency = 1
	button.BorderSizePixel = 0
	button.AutoButtonColor = false
	button.Text = ""
	button.Parent = parent
	GamepadFocus.style(button)
	return button
end

local function playUi(definition: any)
	if not AudioConfig.isConfigured(definition) then
		return
	end
	local sound = Instance.new("Sound")
	sound.Name = "FL_Settings"
	sound.SoundId = AudioConfig.pickId(definition)
	sound.Volume = definition.volume
	sound.Parent = SoundService
	sound:Play()
	sound.Ended:Once(function()
		sound:Destroy()
	end)
end

local function isTouch(): boolean
	local input = Registry.find("InputController")
	if not input or typeof(input.isTouchScheme) ~= "function" then
		return false
	end
	local ok, touch = pcall(input.isTouchScheme, input)
	return ok and touch == true
end

local function rowHeight(): number
	return if isTouch() then ROW_HEIGHT_TOUCH else ROW_HEIGHT
end

--[[ The tallest category, which is what the panel sizes itself to hold. Counted
     once rather than per resize: the config is frozen. ]]
local function tallestCategory(): number
	local most = 0
	for _, category in SettingsConfig.Categories do
		most = math.max(most, #SettingsConfig.inCategory(category))
	end
	return most
end

--[[
	Fits the panel to the screen it is actually on, in both directions.

	WIDTH: everything inside is laid out in reference pixels and ScaleLayer keeps
	those honest, but the layer's width in reference pixels varies with the
	ASPECT RATIO — the scale factor comes from height alone. A phone held upright
	is about 500 reference pixels across, and a panel fixed at 620 would hang off
	both edges of it. So the width is the smaller of the design width and what
	the screen actually has.

	HEIGHT: as much of the screen as it needs and no more. A fraction of the
	viewport alone gives a 620-by-1344 column on a 4K display — eleven rows of
	content in a panel with room for twenty-seven — so the fraction is a ceiling
	rather than the answer, and the longest category is the other one.
]]
local function refreshPanelSize()
	if not panel then
		return
	end
	local camera = Workspace.CurrentCamera
	local factor = ScaleLayer.getFactor()
	local viewport = if camera and factor > 0 then camera.ViewportSize / factor else nil

	local availableWidth = if viewport then viewport.X else PANEL_WIDTH
	local width = math.min(PANEL_WIDTH, math.max(availableWidth - LAYOUT.ScreenMargin * 2, 240))

	local chrome = HEADER_HEIGHT + TAB_HEIGHT + FOOTER_HEIGHT + 8
	local wanted = chrome + tallestCategory() * rowHeight()
	local ceiling = if viewport then viewport.Y * PANEL_HEIGHT_SCALE else wanted

	panel.Size = UDim2.fromOffset(width, math.min(wanted, ceiling))
end

-- ── persistence ─────────────────────────────────────────────────────────────

--[[
	Preferences with no data store and no server round trip.

	TeleportService's teleport settings are client-side and survive a teleport,
	which is exactly the lifetime that matters: this game moves players between
	servers to fill a round, and a sensitivity that reset every time the
	matchmaker did its job would read as the game forgetting.

	They do NOT survive rejoining from the website, which is the honest limit of
	doing this without a DataStore. Every touch is wrapped because the API throws
	rather than returning nil in contexts where it is unavailable; the in-memory
	table is the real store either way.
]]
local function loadSetting(key: string, default: any): any
	local ok, value = pcall(TeleportService.GetTeleportSetting, TeleportService, SETTING_PREFIX .. key)
	if ok and typeof(value) == typeof(default) then
		return value
	end
	return default
end

local function saveSetting(key: string, value: any)
	pcall(TeleportService.SetTeleportSetting, TeleportService, SETTING_PREFIX .. key, value)
end

-- ── keys, as text and back ──────────────────────────────────────────────────

--[[
	Which INPUT DEVICE a key belongs to.

	Rebinding replaces the keys of one family and leaves the others alone, which
	is what stops a keyboard player retyping RELOAD from taking the gamepad's X
	button away from it. Three families, because that is how many kinds of thing
	a row can hold.
]]
local function keyFamily(key: any): string
	if typeof(key) == "EnumItem" and key.EnumType == Enum.UserInputType then
		return "pointer"
	end
	local name = if typeof(key) == "EnumItem" then key.Name else ""
	if
		string.sub(name, 1, 6) == "Button"
		or string.sub(name, 1, 4) == "DPad"
		or string.sub(name, 1, 10) == "Thumbstick"
	then
		return "gamepad"
	end
	return "keyboard"
end

--[[ Names nobody would recognise from the enum. Everything else upper-cases
     cleanly enough to print as-is. ]]
local KEY_NAMES: { [string]: string } = {
	MouseButton1 = "MOUSE 1",
	MouseButton2 = "MOUSE 2",
	MouseButton3 = "MOUSE 3",
	LeftShift = "L SHIFT",
	RightShift = "R SHIFT",
	LeftControl = "L CTRL",
	RightControl = "R CTRL",
	LeftAlt = "L ALT",
	RightAlt = "R ALT",
	Space = "SPACE",
	Return = "ENTER",
	Backquote = "`",
	LeftBracket = "[",
	RightBracket = "]",
	Semicolon = ";",
	Quote = "'",
	Comma = ",",
	Period = ".",
	Slash = "/",
	BackSlash = "\\",
	Minus = "-",
	Equals = "=",
	ButtonA = "A BUTTON",
	ButtonB = "B BUTTON",
	ButtonX = "X BUTTON",
	ButtonY = "Y BUTTON",
	ButtonL1 = "LB",
	ButtonR1 = "RB",
	ButtonL2 = "LT",
	ButtonR2 = "RT",
	ButtonL3 = "L STICK",
	ButtonR3 = "R STICK",
	DPadUp = "D-PAD UP",
	DPadDown = "D-PAD DOWN",
	DPadLeft = "D-PAD LEFT",
	DPadRight = "D-PAD RIGHT",
}

local function keyText(key: any): string
	if typeof(key) ~= "EnumItem" then
		return "—"
	end
	return KEY_NAMES[key.Name] or string.upper(key.Name)
end

--[[ A key back out of a saved string. Stored as the enum's own name so a save
     stays readable and cannot be knocked out of step by an enum being
     renumbered. ]]
local function keyFromName(name: string): any
	if typeof(name) ~= "string" or name == "" then
		return nil
	end
	local ok, key = pcall(function()
		return (Enum.KeyCode :: any)[name]
	end)
	if ok and key then
		return key
	end
	ok, key = pcall(function()
		return (Enum.UserInputType :: any)[name]
	end)
	if ok and key then
		return key
	end
	return nil
end

--[[ The live binding row for an action, straight out of InputController. Read
     rather than remembered: the keymap is that controller's, and a copy here
     would be a second answer that could go stale. ]]
local function bindingFor(action: string): any
	local input = Registry.find("InputController")
	if not input or typeof(input.getBindings) ~= "function" then
		return nil
	end
	local ok, bindings = pcall(input.getBindings, input)
	if not ok or typeof(bindings) ~= "table" then
		return nil
	end
	for _, binding in bindings do
		if binding.action == action then
			return binding
		end
	end
	return nil
end

--[[ What a keybind row shows: the key a keyboard-and-mouse player would press.
     A row whose verb is gamepad-only prints its pad button instead of a dash,
     because "nothing" and "not on this device" are different answers. ]]
local function boundKeyText(action: string): string
	local binding = bindingFor(action)
	if not binding then
		return "—"
	end
	local fallback: any = nil
	for _, key in binding.keys do
		local family = keyFamily(key)
		if family == "keyboard" or family == "pointer" then
			return keyText(key)
		end
		fallback = fallback or key
	end
	return keyText(fallback)
end

--[[ The verb a key is already spoken for by, or "". Used to refuse a rebind
     rather than steal the key — stealing it can leave the other verb with
     nothing bound at all, which is a worse outcome than "that one is taken". ]]
local function actionUsingKey(key: any, exceptAction: string): string
	local input = Registry.find("InputController")
	if not input or typeof(input.getBindings) ~= "function" then
		return ""
	end
	local ok, bindings = pcall(input.getBindings, input)
	if not ok or typeof(bindings) ~= "table" then
		return ""
	end
	for _, binding in bindings do
		if binding.action ~= exceptAction then
			for _, existing in binding.keys do
				if existing == key then
					return binding.action
				end
			end
		end
	end
	return ""
end

-- ── applying ────────────────────────────────────────────────────────────────

--[[
	The gore budget, from the two settings that feed it.

	Quality is the player's ceiling on particle count; gore is whether bodies
	come apart at all. LOW gore halves the particles as well as keeping the
	limbs on, because "less gore" that sprays the same amount of blood is not
	less gore.
]]
local function applyGoreBudget()
	local scale = SettingsConfig.Quality[values.quality] or 1
	if values.gore == "LOW" then
		scale *= 0.5
	end
	callController("GoreController", "setEnabled", values.gore ~= "OFF")
	callController("GoreController", "setQuality", scale)
	--[[ And the lens, which is drawn by OverlayController rather than by the gore
	     controller — it owns the layer the vignette composites on. Without this
	     the setting takes the gibs away and leaves the player looking through the
	     blood. ]]
	callController("OverlayController", "setBloodEnabled", values.gore ~= "OFF")
end

--[[ Pushes one setting at whatever owns it. The single place in this file that
     knows what a particular setting MEANS; everything else treats them as
     rows. ]]
local function applySetting(key: string, value: any)
	if key == "quality" or key == "gore" then
		applyGoreBudget()
	elseif key == "brightness" then
		callController("OverlayController", "setBrightness", value)
	elseif key == "screenShake" then
		callController("CameraController", "setShakeEnabled", value == true)
	elseif key == "damageNumbers" then
		callController("HitmarkerController", "setDamageNumbersEnabled", value == true)
	elseif key == "masterVolume" then
		callController("MainMenuController", "setMasterVolume", value)
	elseif key == "musicVolume" then
		callController("MusicController", "setVolume", value)
		--[[ Silence stops the cue machine as well as muting it. A mixer running
		     at zero volume is a stack of streaming sounds nobody can hear, which
		     on a phone is bandwidth and CPU spent on nothing. ]]
		callController("MusicController", "setEnabled", value > 0)
	elseif key == "sensitivity" then
		UserInputService.MouseDeltaSensitivity = math.clamp(value, 0.05, 10)
	elseif key == "subtitles" then
		callController("SubtitleController", "setEnabled", value == true)
	elseif key == "difficulty" then
		--[[ The only setting that leaves this machine. The server validates it
		     again on arrival; this is a request, not an instruction. ]]
		Remotes.Event.SetDifficulty:FireServer(value)
	elseif string.sub(key, 1, 4) == "bind" then
		local definition = SettingsConfig.get(key)
		local action = definition and definition.action
		local wanted = keyFromName(value)
		if not action or not wanted then
			return
		end
		local binding = bindingFor(action)
		if not binding then
			return
		end
		--[[ Restoring a saved bind is the same operation as making a new one:
		     replace this key's family, keep the others. ]]
		local family = keyFamily(wanted)
		local keys = { wanted }
		for _, existing in binding.keys do
			if keyFamily(existing) ~= family then
				table.insert(keys, existing)
			end
		end
		callController("InputController", "rebind", action, keys)
	end
end

-- ── the store ───────────────────────────────────────────────────────────────

local function valueText(definition: any, value: any): string
	if definition.kind == "toggle" then
		return if value then "ON" else "OFF"
	elseif definition.kind == "choice" then
		return tostring(value)
	elseif definition.kind == "keybind" then
		return boundKeyText(definition.action or "")
	elseif definition.key == "sensitivity" then
		return string.format("%.2f", value)
	end
	return string.format("%d%%", math.floor(value * 100 + 0.5))
end

local function refreshRow(row: any)
	local definition = row.definition
	local value = values[definition.key]

	if row.flashUntil and os.clock() < row.flashUntil then
		return
	end
	row.flashUntil = nil

	row.value.Text = valueText(definition, value)
	row.value.TextColor3 = COLOR.TextPrimary

	if row.fill then
		local span = (definition.max or 1) - (definition.min or 0)
		local alpha = if span > 0 then (value - (definition.min or 0)) / span else 0
		row.fill.Size = UDim2.new(math.clamp(alpha, 0, 1), 0, 1, 0)
	end
end

--[[ Says something in a row's value slot for a moment, then lets it go back to
     showing the value. For a refused rebind and for the "press a key" prompt —
     both of which are about the row rather than about the whole panel, and a
     message in the footer is a message next to the wrong thing. ]]
local function flashRow(row: any, text: string, color: Color3?, seconds: number?)
	row.value.Text = text
	row.value.TextColor3 = color or COLOR.Accent
	row.flashUntil = if seconds and seconds <= 0 then nil else os.clock() + (seconds or FLASH_SECONDS)
	if row.flashUntil then
		local expected = row.flashUntil
		task.delay(seconds or FLASH_SECONDS, function()
			if row.flashUntil == expected then
				row.flashUntil = nil
				refreshRow(row)
			end
		end)
	end
end

local function setValue(key: string, raw: any, silent: boolean?)
	local value = SettingsConfig.coerce(key, raw)
	if value == nil or values[key] == value then
		return
	end
	values[key] = value
	saveSetting(key, value)
	applySetting(key, value)
	for _, row in rows do
		if row.definition.key == key then
			refreshRow(row)
		end
	end
	if not silent then
		playUi(AudioConfig.UI.MenuHover)
	end
	SettingsController.changed:fire(key, value)
end

--[[ One press of a choice or a toggle. Wraps, because a list of three with no
     way back is a list you have to go round twice. ]]
local function cycleValue(definition: any)
	if definition.kind == "toggle" then
		setValue(definition.key, not values[definition.key])
		return
	end
	local options = definition.options or {}
	local index = table.find(options, values[definition.key]) or 0
	setValue(definition.key, options[(index % #options) + 1])
end

local function stepValue(definition: any, direction: number)
	local min = definition.min or 0
	local max = definition.max or 1
	local step = (max - min) / SLIDER_STEPS
	setValue(definition.key, math.clamp(values[definition.key] + step * direction, min, max), true)
end

-- ── rebinding ───────────────────────────────────────────────────────────────

local function endCapture()
	local row = state.capturing
	state.capturing = nil
	if row then
		row.flashUntil = nil
		refreshRow(row)
	end
end

local function beginCapture(row: any)
	if state.capturing == row then
		endCapture()
		return
	end
	if state.capturing then
		endCapture()
	end
	state.capturing = row
	state.captureAt = os.clock()
	--[[ No timeout: the prompt holds until something is pressed or the row is
	     tapped again. A capture that expired on its own would do so exactly
	     while the player was looking at their keyboard for the key. ]]
	flashRow(row, "PRESS A KEY", COLOR.AccentBright, 0)
end

--[[
	Turns a captured input into a binding.

	The two refusals are deliberate. Escape belongs to Roblox — binding it means
	losing the platform menu — and a key another verb already owns is refused
	with that verb's name rather than taken, because taking it can leave that
	verb unbound entirely.
]]
local function completeCapture(key: any)
	local row = state.capturing
	if not row then
		return
	end
	local action = row.definition.action
	if not action then
		endCapture()
		return
	end

	local owner = actionUsingKey(key, action)
	if owner ~= "" then
		state.capturing = nil
		flashRow(row, string.upper(owner) .. " HAS IT", COLOR.Danger)
		return
	end

	local binding = bindingFor(action)
	if not binding then
		endCapture()
		return
	end

	local family = keyFamily(key)
	local keys = { key }
	for _, existing in binding.keys do
		if keyFamily(existing) ~= family then
			table.insert(keys, existing)
		end
	end

	state.capturing = nil
	row.flashUntil = nil
	callController("InputController", "rebind", action, keys)
	setValue(row.definition.key, key.Name)
	--[[ setValue is a no-op when the stored name has not changed — rebinding a
	     key back to the one it started on, say — so the row is refreshed here
	     rather than relying on it. ]]
	refreshRow(row)
	playUi(AudioConfig.UI.MenuConfirm)
end

-- ── rows ────────────────────────────────────────────────────────────────────

local function buildRow(definition: any, index: number): any
	local height = rowHeight()
	local holder = newButton(list, definition.key)
	--[[ Short of the full width by the scrollbar, so a value hard against the
	     right edge is not half-covered by it on the categories that scroll. ]]
	holder.Size = UDim2.new(1, -(SCROLLBAR_WIDTH + LAYOUT.ElementGap), 0, height)
	holder.LayoutOrder = index

	local label = newLabel(holder, "Label", FONT.Heading, TEXT.Body, COLOR.TextPrimary)
	label.Position = UDim2.fromOffset(LAYOUT.PanelPadding, 0)

	--[[ A row with a line of explanation stacks; one without centres. Two layouts
	     rather than one with an empty second line, because a label floating above
	     the space where a blurb would have been reads as a rendering fault. ]]
	if definition.blurb then
		label.Size = UDim2.new(0.55, 0, 0, TEXT.Large + 4)
		label.Position = UDim2.fromOffset(LAYOUT.PanelPadding, 4)

		local blurb = newLabel(holder, "Blurb", FONT.Body, TEXT.Tiny, COLOR.TextDim)
		blurb.Position = UDim2.fromOffset(LAYOUT.PanelPadding, TEXT.Large + 2)
		blurb.Size = UDim2.new(0.62, 0, 0, TEXT.Body)
		blurb.Text = definition.blurb
	else
		label.Size = UDim2.new(0.55, 0, 1, 0)
	end
	label.Text = definition.label

	local value = newLabel(holder, "Value", FONT.Heading, TEXT.Body, COLOR.TextPrimary)
	value.AnchorPoint = Vector2.new(1, 0)
	value.Position = UDim2.new(1, -LAYOUT.PanelPadding, 0, 0)
	value.Size = UDim2.new(0.3, 0, 1, 0)
	value.TextXAlignment = Enum.TextXAlignment.Right

	local rule = newFrame(holder, "Rule", COLOR.Border, 0.4)
	rule.AnchorPoint = Vector2.new(0, 1)
	rule.Position = UDim2.new(0, 0, 1, 0)
	rule.Size = UDim2.new(1, 0, 0, LAYOUT.BorderThickness)

	local row = { definition = definition, button = holder, value = value, fill = nil, flashUntil = nil }

	if definition.kind == "slider" then
		--[[
			Two buttons and a bar, rather than a draggable track.

			A track you drag is a mouse widget. On a phone it fights the list's own
			scroll for the same gesture, and on a controller there is nothing to
			drag WITH — the pad can select a button and press it, which is the
			whole interaction model. Stepping works identically on all three, and
			twenty steps is fine enough that nobody feels them.
		]]
		local buttonSize = if isTouch() then STEP_BUTTON_TOUCH else STEP_BUTTON
		value.Position = UDim2.new(1, -(LAYOUT.PanelPadding + buttonSize * 2 + LAYOUT.ElementGap * 2), 0, 0)
		value.Size = UDim2.new(0, 70, 1, 0)

		local track = newFrame(holder, "Track", COLOR.Border, 0.2)
		track.Position = UDim2.fromOffset(LAYOUT.PanelPadding, height - 10)
		track.Size = UDim2.new(0.55, 0, 0, LAYOUT.BorderThickness * 2)
		row.fill = newFrame(track, "Fill", COLOR.Accent, 0)
		row.fill.Size = UDim2.new(0, 0, 1, 0)

		local function stepButton(name: string, text: string, offsetFromRight: number, direction: number)
			local step = newButton(holder, name)
			step.AnchorPoint = Vector2.new(1, 0.5)
			step.Position = UDim2.new(1, -offsetFromRight, 0.5, 0)
			step.Size = UDim2.fromOffset(buttonSize, buttonSize)
			step.BackgroundColor3 = COLOR.PanelRaised
			step.BackgroundTransparency = 0
			step.Font = FONT.Heading
			step.TextSize = TEXT.Large
			step.TextColor3 = COLOR.TextPrimary
			step.Text = text
			rowTrove:connect(step.Activated, function()
				stepValue(definition, direction)
			end)
			return step
		end

		stepButton("Down", "−", LAYOUT.PanelPadding + buttonSize + LAYOUT.ElementGap, -1)
		stepButton("Up", "+", LAYOUT.PanelPadding, 1)

		--[[ The row itself is not a button for a slider: there is no sensible
		     answer to "the player pressed the volume". Selection lands on the two
		     step buttons instead, which is also what a controller wants. ]]
		holder.Selectable = false
	elseif definition.kind == "keybind" then
		rowTrove:connect(holder.Activated, function()
			beginCapture(row)
		end)
	else
		rowTrove:connect(holder.Activated, function()
			cycleValue(definition)
		end)
	end

	rowTrove:connect(holder.MouseEnter, function()
		holder.BackgroundTransparency = 0.88
		holder.BackgroundColor3 = COLOR.TextPrimary
	end)
	rowTrove:connect(holder.MouseLeave, function()
		holder.BackgroundTransparency = 1
	end)

	refreshRow(row)
	return row
end

local function releaseRows()
	rowTrove:clean()
	for _, row in rows do
		row.button:Destroy()
	end
	table.clear(rows)
	firstRowButton = nil
end

local function renderCategory(category: string)
	state.category = category
	endCapture()
	releaseRows()

	for index, definition in SettingsConfig.inCategory(category) do
		local row = buildRow(definition, index)
		table.insert(rows, row)
		--[[ A slider row is not itself selectable — its two step buttons are —
		     so the pad's landing spot is the first row that can take it. ]]
		if not firstRowButton and row.button.Selectable then
			firstRowButton = row.button
		end
	end
	if not firstRowButton and rows[1] then
		firstRowButton = rows[1].button:FindFirstChild("Down") :: TextButton?
	end

	list.CanvasPosition = Vector2.zero
	list.CanvasSize = UDim2.fromOffset(0, #rows * rowHeight())
	--[[ Row height follows the input scheme, so the panel that holds them has to
	     be re-fitted whenever they are rebuilt. ]]
	refreshPanelSize()

	for _, tab in tabs do
		local selected = tab.category == category
		tab.label.TextColor3 = if selected then COLOR.AccentBright else COLOR.TextSecondary
		tab.underline.BackgroundTransparency = if selected then 0 else 1
	end

	hint.Text = if category == "CONTROLS"
		then "SELECT A ROW, THEN PRESS THE KEY YOU WANT"
		else "CHANGES APPLY IMMEDIATELY"
end

-- ── suppression: what the panel does to the rest of the client ──────────────

--[[
	Frees the cursor so the panel can be clicked, and hands the game back on
	close.

	Only ever engages when the MENU is not already up. The menu suppresses all of
	this itself, and a second owner restoring the camera on close would hand a
	live camera back to a player still sitting in the lobby.
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

local function menuIsOpen(): boolean
	local menu = Registry.find("MainMenuController")
	if not menu or typeof(menu.isOpen) ~= "function" then
		return false
	end
	local ok, open = pcall(menu.isOpen, menu)
	return ok and open == true
end

-- ── public API ──────────────────────────────────────────────────────────────

function SettingsController:isOpen(): boolean
	return state.open
end

function SettingsController:open()
	if state.open then
		return
	end
	state.open = true
	gui.Enabled = true
	--[[ Rebuilt on every open rather than once at boot: the row heights and the
	     step buttons are sized for the scheme the player is using, and somebody
	     who picked up a controller between two openings should get the bigger
	     targets without having to rejoin. ]]
	renderCategory(state.category)
	setSuppressed(not menuIsOpen())
	GamepadFocus.capture(firstRowButton)
	playUi(AudioConfig.UI.MenuConfirm)
end

function SettingsController:close()
	if not state.open then
		return
	end
	endCapture()
	state.open = false
	gui.Enabled = false
	GamepadFocus.release(firstRowButton)
	setSuppressed(false)
	--[[ The menu can have been open underneath the panel the whole time, or have
	     opened while it was up — a round ending is the obvious way. Either way the
	     release above has just handed gamepad selection back to nothing, and the
	     restore may have handed input and the HUD back over a menu that is still
	     on screen. The menu puts both right. ]]
	if menuIsOpen() then
		callController("MainMenuController", "reassertSuppression")
	end
	playUi(AudioConfig.UI.MenuBack)
end

function SettingsController:toggle()
	if state.open then
		self:close()
	else
		self:open()
	end
end

--[[ One setting's current value. For anything that wants to read a preference
     without owning a copy of it. ]]
function SettingsController:get(key: string): any
	return values[key]
end

--[[ Programmatic set, validated through SettingsConfig exactly as a click is.
     Returns false for a key that does not exist. ]]
function SettingsController:set(key: string, value: any): boolean
	if not SettingsConfig.get(key) then
		return false
	end
	setValue(key, value)
	return true
end

--[[ Everything back to the shipped defaults except the keymap — see below.
     Applied through the same path as a click, so nothing can be reset in the
     store and left running in the game. ]]
function SettingsController:resetDefaults()
	for _, definition in SettingsConfig.Definitions do
		if definition.kind == "keybind" then
			--[[ A keybind's default is the empty string, which means "whatever
			     InputController shipped with" — and that is a keymap this file
			     cannot reconstruct, because the row it replaced is gone. Left
			     alone rather than pretended about. ]]
			continue
		end
		setValue(definition.key, definition.default, true)
	end
	renderCategory(state.category)
	playUi(AudioConfig.UI.MenuConfirm)
end

-- ── build ───────────────────────────────────────────────────────────────────

local function buildTab(category: string, index: number, total: number)
	local holder = newButton(tabHolder, category)
	holder.Size = UDim2.new(1 / total, 0, 1, 0)
	holder.Position = UDim2.new((index - 1) / total, 0, 0, 0)

	local label = newLabel(holder, "Label", FONT.Heading, TEXT.Small, COLOR.TextSecondary)
	label.Size = UDim2.fromScale(1, 1)
	label.TextXAlignment = Enum.TextXAlignment.Center
	label.Text = category

	local underline = newFrame(holder, "Underline", COLOR.Accent, 1)
	underline.AnchorPoint = Vector2.new(0.5, 1)
	underline.Position = UDim2.new(0.5, 0, 1, 0)
	underline.Size = UDim2.new(0.7, 0, 0, LAYOUT.BorderThickness * 2)

	local tab = { category = category, label = label, underline = underline, button = holder }
	trove:connect(holder.Activated, function()
		if state.category ~= category then
			renderCategory(category)
			playUi(AudioConfig.UI.MenuHover)
		end
	end)
	table.insert(tabs, tab)
end

local function build()
	gui = Instance.new("ScreenGui")
	gui.Name = "FL_Settings"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = UITheme.DisplayOrder.Settings
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Enabled = false
	gui.Parent = player:WaitForChild("PlayerGui")
	trove:add(gui)

	local layer = ScaleLayer.new(gui, "Scaled")

	--[[ A button rather than a frame, so a click that misses the panel is eaten
	     here instead of landing on the menu — or on the trigger — behind it. ]]
	scrim = Instance.new("TextButton")
	scrim.Name = "Scrim"
	scrim.BackgroundColor3 = COLOR.Background
	scrim.BackgroundTransparency = SCRIM
	scrim.BorderSizePixel = 0
	scrim.AutoButtonColor = false
	scrim.Text = ""
	--[[ TextButtons are selectable by default, and a full-screen one would be a
	     place the D-pad could land — one press of A on it closes the panel the
	     player was trying to walk through. ]]
	scrim.Selectable = false
	scrim.Size = UDim2.fromScale(1, 1)
	scrim.Parent = layer
	trove:connect(scrim.Activated, function()
		SettingsController:close()
	end)

	panel = newFrame(layer, "Panel", COLOR.Panel, 0.05)
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.new(0, PANEL_WIDTH, PANEL_HEIGHT_SCALE, 0)

	local stroke = Instance.new("UIStroke")
	stroke.Color = COLOR.Border
	stroke.Thickness = LAYOUT.BorderThickness
	stroke.Parent = panel

	local title = newLabel(panel, "Title", FONT.Display, TEXT.Heading, COLOR.TextPrimary)
	title.Position = UDim2.fromOffset(LAYOUT.PanelPadding, 4)
	title.Size = UDim2.new(1, -120, 0, TEXT.Heading)
	title.Text = "SETTINGS"

	local closeButton = newButton(panel, "Close")
	closeButton.AnchorPoint = Vector2.new(1, 0)
	closeButton.Position = UDim2.new(1, -LAYOUT.PanelPadding, 0, 4)
	--[[ The full header height rather than the height of its own text: this is
	     the panel's way out on a phone, and a thumb needs something to hit. ]]
	closeButton.Size = UDim2.fromOffset(96, HEADER_HEIGHT - 6)
	closeButton.Font = FONT.Heading
	closeButton.TextSize = TEXT.Body
	closeButton.TextColor3 = COLOR.TextSecondary
	closeButton.TextXAlignment = Enum.TextXAlignment.Right
	closeButton.Text = "CLOSE"
	trove:connect(closeButton.Activated, function()
		SettingsController:close()
	end)
	trove:connect(closeButton.MouseEnter, function()
		closeButton.TextColor3 = COLOR.AccentBright
	end)
	trove:connect(closeButton.MouseLeave, function()
		closeButton.TextColor3 = COLOR.TextSecondary
	end)

	local headRule = newFrame(panel, "HeadRule", COLOR.BorderBright, 0)
	headRule.Position = UDim2.fromOffset(0, HEADER_HEIGHT)
	headRule.Size = UDim2.new(1, 0, 0, LAYOUT.BorderThickness)

	tabHolder = newFrame(panel, "Tabs", COLOR.Panel, 1)
	tabHolder.Position = UDim2.fromOffset(0, HEADER_HEIGHT + 2)
	tabHolder.Size = UDim2.new(1, 0, 0, TAB_HEIGHT)
	for index, category in SettingsConfig.Categories do
		buildTab(category, index, #SettingsConfig.Categories)
	end

	list = Instance.new("ScrollingFrame")
	list.Name = "Rows"
	list.BackgroundTransparency = 1
	list.BorderSizePixel = 0
	list.Position = UDim2.fromOffset(0, HEADER_HEIGHT + TAB_HEIGHT + 6)
	list.Size = UDim2.new(1, 0, 1, -(HEADER_HEIGHT + TAB_HEIGHT + FOOTER_HEIGHT + 8))
	list.CanvasSize = UDim2.fromOffset(0, 0)
	list.ScrollBarThickness = SCROLLBAR_WIDTH
	list.ScrollBarImageColor3 = COLOR.Border
	list.ScrollingDirection = Enum.ScrollingDirection.Y
	list.Parent = panel

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = list

	hint = newLabel(panel, "Hint", FONT.Body, TEXT.Tiny, COLOR.TextDim)
	hint.AnchorPoint = Vector2.new(0, 1)
	hint.Position = UDim2.new(0, LAYOUT.PanelPadding, 1, -LAYOUT.PanelPadding)
	hint.Size = UDim2.new(0.65, 0, 0, TEXT.Body)
	hint.Text = ""

	local reset = newButton(panel, "Reset")
	reset.AnchorPoint = Vector2.new(1, 1)
	reset.Position = UDim2.new(1, -LAYOUT.PanelPadding, 1, -LAYOUT.PanelPadding + 4)
	reset.Size = UDim2.fromOffset(120, TEXT.Large)
	reset.Font = FONT.Body
	reset.TextSize = TEXT.Small
	reset.TextColor3 = COLOR.TextDim
	reset.TextXAlignment = Enum.TextXAlignment.Right
	reset.Text = "RESET DEFAULTS"
	trove:connect(reset.Activated, function()
		SettingsController:resetDefaults()
	end)
	trove:connect(reset.MouseEnter, function()
		reset.TextColor3 = COLOR.Accent
	end)
	trove:connect(reset.MouseLeave, function()
		reset.TextColor3 = COLOR.TextDim
	end)

	refreshPanelSize()
end

-- ── lifecycle ───────────────────────────────────────────────────────────────

function SettingsController:init()
	build()
	for _, definition in SettingsConfig.Definitions do
		values[definition.key] =
			SettingsConfig.coerce(definition.key, loadSetting(definition.key, definition.default))
	end
end

function SettingsController:start()
	--[[ Applied once here as well as on every change, so a preference restored
	     from the last server is in force before the first shot rather than the
	     first time the panel is opened. ]]
	for _, definition in SettingsConfig.Definitions do
		applySetting(definition.key, values[definition.key])
	end

	--[[
		Opening it mid-round.

		O rather than Escape, which belongs to Roblox and cannot be taken without
		taking the platform menu with it. The view/select button is the pad's
		equivalent and is the one face button Roblox leaves alone — Start is its
		own menu.
	]]
	trove:connect(UserInputService.InputBegan, function(input: InputObject, processed: boolean)
		--[[ A capture has to see the key BEFORE the processed check: the panel is
		     focused while it is up, so every press arrives marked processed, and
		     honouring that would mean nothing could ever be bound. ]]
		if state.capturing then
			if os.clock() - state.captureAt < CAPTURE_GRACE then
				return
			end
			if input.KeyCode == Enum.KeyCode.Escape then
				endCapture()
				return
			end
			if input.KeyCode ~= Enum.KeyCode.Unknown then
				completeCapture(input.KeyCode)
			elseif
				input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.MouseButton2
				or input.UserInputType == Enum.UserInputType.MouseButton3
			then
				completeCapture(input.UserInputType)
			end
			return
		end

		--[[ B closes it, which is what B does on every console screen there has
		     ever been. Checked before the processed guard because the panel is
		     focused while it is up, so its own presses arrive marked processed —
		     and a pad player who cannot back out of a menu is stuck in it. ]]
		if state.open and input.KeyCode == Enum.KeyCode.ButtonB then
			SettingsController:close()
			return
		end

		if processed then
			return
		end
		if input.KeyCode == Enum.KeyCode.O or input.KeyCode == Enum.KeyCode.ButtonSelect then
			SettingsController:toggle()
		end
	end)

	--[[
		CameraController re-applies LockFirstPerson every time the survivor state
		changes — on a death, on a revive, on a respawn — and LockFirstPerson pins
		the cursor to the middle of the screen. If that lands while the panel is
		up, nothing on it can be clicked again. So the value it just wrote becomes
		the one to hand back on close, and the cursor is freed again. Deferred,
		because this runs on the same signal and has to land after that handler.
	]]
	trove:connect(player:GetAttributeChangedSignal(Attributes.Player.State), function()
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

	--[[ Re-fitted on every viewport change, and re-POINTED rather than re-added
	     when the camera is replaced — which happens on death, on spectate and on
	     rejoin. Connecting a second time per camera would leave one live handler
	     per death by the end of a round. ]]
	local viewportConnection: RBXScriptConnection? = nil
	local function watchViewport()
		if viewportConnection then
			viewportConnection:Disconnect()
			viewportConnection = nil
		end
		local camera = Workspace.CurrentCamera
		if camera then
			viewportConnection = camera:GetPropertyChangedSignal("ViewportSize"):Connect(refreshPanelSize)
		end
		refreshPanelSize()
	end
	trove:add(function()
		if viewportConnection then
			viewportConnection:Disconnect()
			viewportConnection = nil
		end
	end)
	trove:connect(Workspace:GetPropertyChangedSignal("CurrentCamera"), watchViewport)
	watchViewport()
end

function SettingsController:destroy()
	setSuppressed(false)
	rowTrove:destroy()
	table.clear(tabs)
	table.clear(rows)
	trove:destroy()
end

Registry.register("SettingsController", SettingsController)

return SettingsController
