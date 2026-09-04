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

	── ALONE IT PAUSES. IN COMPANY IT SAYS SO ───────────────────────────────────
	Roblox has no pause in a multiplayer game and pretending otherwise would be a
	lie told to one player while three others fight. That was the whole of it for
	a long time, and it quietly assumed a case that Classic does not require:
	MinPlayersToStart is 1, so the player can be the only person in the server,
	and a pause told to nobody is not a lie.

	So this asks, every time it opens, and the SERVER decides — see PauseService,
	which counts the players itself and grants it only to somebody who is alone.
	Granted, the horde stops, the Director stops and the round's clock stops, and
	the overlay says PAUSED. Refused, the attribute simply never changes and the
	overlay says the round is still running, which it is.

	There is no reply remote and there does not need to be one: the answer is
	Attributes.Game.Paused, which every client watches anyway. A refusal is the
	attribute not changing.

	Either way the menu still does what every other menu here does — suppress
	input, free the cursor, dim the world.

	── LEAVE MATCH ──────────────────────────────────────────────────────────────
	Takes the player OUT of the round and back to the lobby. It used to open the
	main menu over a round the player was still very much in — which meant a
	survivor standing in a doorway with a menu on their screen, still shootable,
	still counted by the wipe check, still expected to revive somebody. A menu
	that looks like leaving and is not is worse than no exit at all.

	It does not leave the SERVER. Leaving is what the Roblox menu is for, and the
	mode entries on the main menu are how a player moves servers here; this is
	the smaller thing — stop playing this round, stay for the next one. The round
	carries on behind it, stated on the button rather than hidden.

	The server decides what leaving means to a body: see SurvivorService.
	leaveRound. It is deliberately not a death — a player who quits must not be
	able to fake a team wipe.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local AudioConfig = require(Shared.Config.AudioConfig)
local Attributes = require(Shared.Net.Attributes)
local Enums = require(Shared.Enums)
local Registry = require(Shared.Util.Registry)
local Remotes = require(Shared.Net.Remotes)
local Trove = require(Shared.Util.Trove)
local UITheme = require(Shared.Config.UITheme)

local GamepadFocus = require(script.Parent.GamepadFocus)
local ScaleLayer = require(script.Parent.ScaleLayer)
local UiSound = require(script.Parent.UiSound)
local Widgets = require(script.Parent.Widgets)
local FreeCursor = require(script.Parent.FreeCursor)

local COLOR = UITheme.Color
local FONT = UITheme.Font
local LAYOUT = UITheme.Layout
local PANEL = UITheme.Panel
local TEXT = UITheme.TextSize
local PA = Attributes.Player
local GA = Attributes.Game
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
	--[[ Directly under RESUME, above everything about the account. It is the one
	     entry here that is about the next thirty seconds — what is left in the
	     sidearm you have not drawn, and which teammate is holding the medkit —
	     and a player who paused to find that out should not have to read past
	     the battle pass to get to it. ]]
	{ id = "Backpack", title = "BACKPACK", line = "Your kit, and what the squad is carrying." },
	--[[ Next to BACKPACK because it is the other thing that is about the round
	     you are standing in rather than the account you are building. ]]
	{ id = "Requisitions", title = "REQUISITIONS", line = "Spend Scrip on something the whole team gets." },
	--[[ Above SETTINGS because it is about the round you are in the middle of.
	     Today's orders are things you do DURING a round — "revive four teammates"
	     is a decision you make at wave three, not one you plan in a menu — and
	     making a player leave the round to find out how close they are is how a
	     quest system stops being part of the game. ]]
	{ id = "Career", title = "CAREER", line = "Level, orders, the pass." },
	{ id = "Settings", title = "SETTINGS", line = "Graphics, audio, controls, difficulty." },
	--[[ A real exit, and the line says the part that matters: this ends YOUR
	     round, not the server's. See the header. ]]
	{ id = "Menu", title = "LEAVE MATCH", line = "You drop out. The round goes on without you." },
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
	--[[ Owned here, written by FreeCursor. These screens nest — this one can open
	     over a live round and the settings panel opens over this one — so a shared
	     slot would have the inner screen hand back the outer screen's camera. ]]
	cameraMode = nil :: any,
	cameraZoom = nil :: any,
	cameraMinZoom = nil :: any,
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
	Takes the trigger away. CONDITIONAL, because these four are plain booleans
	with no idea how many screens are up: when the main menu is already open it
	has switched all of them off itself, and a second owner switching them back
	on when it closes would hand input and the HUD back over a menu still on
	screen.
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
end

--[[
	The cursor, and UNCONDITIONALLY — which is the opposite of the rule above and
	deliberately so.

	This used to ride along inside setSuppressed and inherit its condition, so a
	pause menu opened over the main menu never claimed the mouse at all: the menu
	had it, and that was judged to be enough. It is not, because the menu can go
	away first. Open the pause menu in the lobby, let the round start — RETURN TO
	MAIN MENU does the same thing in reverse — and the menu closing hands the
	camera back to a live survivor while this screen is still up, pinning the
	cursor to the middle of it. Resume becomes unclickable and only the P key
	gets the player out.

	Claiming it is safe precisely where switching the HUD back on is not, because
	FreeCursor COUNTS its holders. Two screens can both hold the mouse and the
	camera only comes back when the second of them lets go, whichever order that
	happens in.
]]
--[[
	The one line under the title, and the only place this interface makes a claim
	about what is happening behind it.

	Three answers, in the order they matter. A paused round says so, because that
	is now sometimes true and a player who cannot tell a real pause from a menu
	over a live game gets no benefit from the real one. A downed player is told
	the floor does not wait — the most expensive misunderstanding available here,
	and worth its own line above the general case. Everything else is the honest
	default this menu has always shown.

	Read from the attribute rather than from anything this client decided, so it
	says PAUSED when and only when the server has actually stopped the world.
]]
local function refreshSubtitle()
	if not subtitle then
		return
	end
	if Workspace:GetAttribute(GA.Paused) == true then
		subtitle.Text = "PAUSED. YOU ARE ALONE IN THIS SERVER."
		return
	end

	--[[ Between rounds this menu opens over a lobby, and the line it used to show
	     there said the round was still running when there was no round at all.
	     Nobody was ever misled into danger by it, which is why it survived — but
	     a pause menu whose one job is to be honest about what is happening behind
	     it should not be wrong in the one state where nothing is. ]]
	local round = Workspace:GetAttribute(GA.RoundState)
	if round ~= Enums.RoundState.InProgress and round ~= Enums.RoundState.Starting then
		subtitle.Text = "NO ROUND IS RUNNING."
		return
	end

	local downed = Attributes.get(player, PA.State, STATE.Spectating) == STATE.Incapacitated
	subtitle.Text = if downed
		then "YOU ARE STILL ON THE FLOOR. THIS DOES NOT STOP ANYTHING."
		else "THE ROUND IS STILL RUNNING."
end

local function claimCursor(value: boolean)
	if value then
		FreeCursor.take(restore)
	else
		FreeCursor.giveBack(restore)
	end
end

-- ── the entries ─────────────────────────────────────────────────────────────

local function activate(id: string)
	if id == "Resume" then
		PauseController:close()
	elseif id == "Backpack" then
		-- Closed first, for the same reason SETTINGS is. See below.
		PauseController:close()
		callController("BackpackController", "open")
	elseif id == "Requisitions" then
		-- Closed first, for the same reason SETTINGS is. See below.
		PauseController:close()
		callController("RequisitionController", "open")
	elseif id == "Career" then
		-- Closed first, for the same reason SETTINGS is. See below.
		PauseController:close()
		callController("CareerController", "open")
	elseif id == "Settings" then
		--[[ Closed first. The settings panel does its own suppression and its
		     own gamepad capture, and two overlays holding both at once is how a
		     player ends up unable to close either. ]]
		PauseController:close()
		callController("SettingsController", "open")
	elseif id == "Menu" then
		--[[ Asked before the menu opens, so the round has already let go by the
		     time the player is looking at the lobby. The server ignores it when
		     no round is running, which is what makes it safe to send from a pause
		     menu that can be opened between rounds. ]]
		Remotes.Event.LeaveMatch:FireServer()
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

	--[[ Asked before the line is written, so a granted pause is already true by
	     the time the first frame of the menu is drawn rather than correcting
	     itself a moment later. The server refuses in company and the line below
	     stays honest on its own. ]]
	Remotes.Event.SetPause:FireServer(true)
	refreshSubtitle()

	setSuppressed(not menuIsOpen())
	claimCursor(true)
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
	--[[ Unconditional. Asking the server to release a pause it never granted is
	     a no-op there, and the alternative — only releasing when this client
	     believes it is paused — is how a client and a server end up disagreeing
	     about whether the horde is allowed to move. ]]
	Remotes.Event.SetPause:FireServer(false)
	GamepadFocus.release(entries[1] and entries[1].button)
	setSuppressed(false)
	claimCursor(false)
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
	--[[ The grant lands a round trip after the ask, so the line is rewritten when
	     it arrives rather than guessed at when the menu opened. It also catches
	     the pause being lifted OUT from under an open menu — a second player
	     joining does exactly that — where the overlay would otherwise go on
	     claiming the game was stopped while the horde moved behind it. ]]
	trove:connect(Workspace:GetAttributeChangedSignal(GA.Paused), function()
		if state.open then
			refreshSubtitle()
		end
	end)

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
		--[[ P, and only P, on the press. Not Escape and not Start: both belong to
		     Roblox, and taking either would take the platform menu with it. ]]
		if input.KeyCode == Enum.KeyCode.P then
			PauseController:open()
		end
	end)

	--[[
		The pad's view button, on RELEASE rather than on press.

		It is also the modifier for the gamepad ability layer — hold it and the
		face buttons become ability slots — and a button that is a modifier cannot
		fire its own verb on the press, because at that moment nobody knows yet
		whether it is a tap or a hold. See the ABILITY LAYER note in
		InputController for why the view button is the only pad input that can
		afford this: the pause menu is the one thing on a controller where a
		fifth of a second is invisible, which MELEE and SHOVE are not.

		A tap opens the menu. A hold does not, whether or not an ability was
		chosen — somebody who held it, looked at their cards and let go has
		decided against, and answering that with a pause menu is worse than doing
		nothing.
	]]
	trove:connect(UserInputService.InputEnded, function(input: InputObject, processed: boolean)
		if state.open or processed or input.KeyCode ~= Enum.KeyCode.ButtonSelect then
			return
		end
		local controller = Registry.find("InputController")
		if controller and typeof(controller.consumedLayerTap) == "function" then
			local ok, consumed = pcall(controller.consumedLayerTap, controller)
			if ok and consumed then
				return
			end
		end
		PauseController:open()
	end)

	--[[
		CameraController re-applies LockFirstPerson on every survivor state change
		— being downed, revived or respawned — and LockFirstPerson pins the cursor
		to the middle of the screen, which used to leave Resume unclickable under
		an open pause menu.

		It was a deferred re-take racing CameraController's handler for the same
		signal. CameraController now stands down entirely while any screen holds
		the mouse, so the cursor is never taken back from under this one; this
		re-asserts the free camera without the race, and is idempotent.
	]]
	trove:connect(player:GetAttributeChangedSignal(PA.State), function()
		if state.open then
			FreeCursor.take(restore)
		end
	end)

	refreshButton()
end

function PauseController:destroy()
	setSuppressed(false)
	claimCursor(false)
	table.clear(entries)
	trove:destroy()
end

Registry.register("PauseController", PauseController)

return PauseController
