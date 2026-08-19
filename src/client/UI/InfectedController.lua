--!nonstrict
--[[
	InfectedController — the Versus class picker.

	In Versus half the server plays the special infected. The server side of that
	is complete: VersusService puts those players in a ghost, offers them the
	kinds nobody else is currently using, and waits for one to be chosen. Nothing
	on the client ever answered, so the infected half spent the whole seventeen
	minutes as an invisible hovering ghost. This is the missing half.

	The screen is deliberately not the survivor HUD. Playing infected is a
	different game — you are choosing WHAT to be and WHERE to appear, and the
	interface should be about those two decisions and nothing else. So: a column
	of classes down the left, a respawn clock, and a line telling you what your
	teammates picked, on the same black/white/orange the rest of the game uses.

	It owns no gameplay. Movement while ghosting is the server's, the abilities
	are the specials' own modules, and this only ever sends
	`Remotes.Event.RequestInfectedSpawn`.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local AudioConfig = require(Shared.Config.AudioConfig)
local Enums = require(Shared.Enums)
local InfectedConfig = require(Shared.Config.InfectedConfig)
local Registry = require(Shared.Util.Registry)
local Remotes = require(Shared.Net.Remotes)
local Trove = require(Shared.Util.Trove)
local UITheme = require(Shared.Config.UITheme)

local GamepadFocus = require(script.Parent.GamepadFocus)
local ScaleLayer = require(script.Parent.ScaleLayer)
local UiSound = require(script.Parent.UiSound)

local COLOR = UITheme.Color
local FONT = UITheme.Font
local LAYOUT = UITheme.Layout
local TEXT = UITheme.TextSize

local player = Players.LocalPlayer

--[[ One line per class, because a player picking under a respawn timer will not
     read a paragraph. Each says what the class DOES, not what it is. ]]
local BLURB = {
	[Enums.Infected.Hunter] = "POUNCE FROM ABOVE · PINS ONE SURVIVOR",
	[Enums.Infected.Jockey] = "RIDE A SURVIVOR · STEER THEM AWAY",
	[Enums.Infected.Rusher] = "CHARGE IN A LINE · CARRY THEM INTO A WALL",
	[Enums.Infected.Tank] = "FOUR THOUSAND HEALTH · THROW THE WORLD AT THEM",
}

local ROW_HEIGHT = 58
local ROW_GAP = LAYOUT.ElementGap
local PANEL_WIDTH = 340
local NUMBER_KEYS = {
	Enum.KeyCode.One,
	Enum.KeyCode.Two,
	Enum.KeyCode.Three,
	Enum.KeyCode.Four,
}

local InfectedController = {}

local trove = Trove.new()
local screen: ScreenGui
local root: Frame
local titleLabel: TextLabel
local clockLabel: TextLabel
local teamLabel: TextLabel
local rowsFolder: Frame
local rows: { any } = {}

local state = {
	visible = false,
	kinds = {} :: { string },
	respawnAt = 0,
	selected = "",
	teammates = {} :: { any },
	lastSentAt = 0,
	shownClock = -1,
}

-- A client-side echo of the server's own rate limit, so a held key never even
-- reaches the wire.
local REQUEST_INTERVAL = 0.35

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
	label.Font = font
	label.TextSize = size
	label.TextColor3 = color
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Center
	label.RichText = false
	label.Parent = parent
	return label
end

local function newFrame(parent: Instance, name: string, color: Color3, transparency: number): Frame
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.BackgroundColor3 = color
	frame.BackgroundTransparency = transparency
	frame.BorderSizePixel = 0
	frame.Parent = parent
	return frame
end

--[[ Asks the server for a kind. The server is the authority on whether it is
     still available — this only stops the obvious local nonsense. ]]
local function request(kind: string)
	if kind == "" or not table.find(state.kinds, kind) then
		return
	end
	local now = os.clock()
	if now - state.lastSentAt < REQUEST_INTERVAL then
		return
	end
	state.lastSentAt = now
	state.selected = kind
	UiSound.play(AudioConfig.UI.MenuConfirm)
	Remotes.Event.RequestInfectedSpawn:FireServer(kind)
end

--[[ Builds one row per playable kind, once. Rows are shown and hidden rather
     than created and destroyed: the picker reappears on every single respawn. ]]
local function buildRows()
	local playable = {
		Enums.Infected.Hunter,
		Enums.Infected.Jockey,
		Enums.Infected.Rusher,
		Enums.Infected.Tank,
	}

	for index, kind in playable do
		local definition = InfectedConfig.get(kind)

		local row = newFrame(rowsFolder, kind, COLOR.Panel, 0.15)
		row.Size = UDim2.new(1, 0, 0, ROW_HEIGHT)
		row.Position = UDim2.fromOffset(0, (index - 1) * (ROW_HEIGHT + ROW_GAP))

		local stroke = Instance.new("UIStroke")
		stroke.Color = COLOR.Border
		stroke.Thickness = LAYOUT.BorderThickness
		stroke.Parent = row

		-- The class's own outline colour as an identity stripe, so the picker and
		-- the silhouette a survivor sees through a wall agree with each other.
		local stripe =
			newFrame(row, "Stripe", if definition then definition.outlineColor else COLOR.Accent, 0)
		stripe.Size = UDim2.new(0, 3, 1, 0)

		local key = newLabel(row, "Key", FONT.Numeric, TEXT.Small, COLOR.TextDim)
		key.Position = UDim2.fromOffset(LAYOUT.PanelPadding + 6, 0)
		key.Size = UDim2.fromOffset(16, ROW_HEIGHT)
		key.Text = tostring(index)

		local name = newLabel(row, "Name", FONT.Heading, TEXT.Large, COLOR.TextPrimary)
		name.Position = UDim2.fromOffset(LAYOUT.PanelPadding + 26, 6)
		name.Size = UDim2.new(1, -(LAYOUT.PanelPadding + 34), 0, TEXT.Large + 4)
		name.Text = string.upper(if definition then definition.displayName else kind)

		local blurb = newLabel(row, "Blurb", FONT.Body, TEXT.Tiny, COLOR.TextSecondary)
		blurb.Position = UDim2.fromOffset(LAYOUT.PanelPadding + 26, 6 + TEXT.Large + 2)
		blurb.Size = UDim2.new(1, -(LAYOUT.PanelPadding + 34), 0, TEXT.Body)
		blurb.Text = BLURB[kind] or ""

		local button = Instance.new("TextButton")
		button.Name = "Hit"
		button.BackgroundTransparency = 1
		button.Text = ""
		button.Size = UDim2.fromScale(1, 1)
		button.ZIndex = 4
		button.Parent = row
		-- Reachable without a cursor: on a console this screen is the only way
		-- into a round of Versus.
		GamepadFocus.style(button)

		local entry = {
			kind = kind,
			frame = row,
			button = button,
			stroke = stroke,
			name = name,
			blurb = blurb,
			key = key,
			available = false,
		}

		trove:connect(button.MouseEnter, function()
			if entry.available then
				stroke.Color = COLOR.Accent
				name.TextColor3 = COLOR.AccentBright
				UiSound.play(AudioConfig.UI.MenuHover)
			end
		end)
		trove:connect(button.MouseLeave, function()
			stroke.Color = if entry.available then COLOR.BorderBright else COLOR.Border
			name.TextColor3 = if entry.available then COLOR.TextPrimary else COLOR.TextDim
		end)
		trove:connect(button.Activated, function()
			if entry.available then
				request(kind)
			end
		end)

		rows[index] = entry
	end
end

--[[ Greys out anything another infected player already has. The server enforces
     it; showing it is what stops four people racing for the Tank. ]]
local function refreshRows()
	for _, entry in rows do
		local available = table.find(state.kinds, entry.kind) ~= nil
		entry.available = available
		entry.frame.BackgroundTransparency = if available then 0.15 else 0.55
		entry.stroke.Color = if available then COLOR.BorderBright else COLOR.Border
		entry.name.TextColor3 = if available then COLOR.TextPrimary else COLOR.TextDim
		entry.blurb.TextColor3 = if available then COLOR.TextSecondary else COLOR.TextDim
		entry.key.TextColor3 = if available then COLOR.Accent else COLOR.TextDim
	end
end

local function refreshTeam()
	if #state.teammates == 0 then
		teamLabel.Text = ""
		return
	end
	local parts = {}
	for _, mate in state.teammates do
		local label = if typeof(mate) == "table"
			then tostring(mate.kind or mate.name or "?")
			else tostring(mate)
		table.insert(parts, string.upper(label))
	end
	teamLabel.Text = "YOUR TEAM: " .. table.concat(parts, " · ")
end

local function setVisible(visible: boolean)
	if state.visible == visible then
		return
	end
	state.visible = visible
	screen.Enabled = visible
	if visible then
		state.shownClock = -1
		--[[ The first row that is actually pickable, not simply the first row:
		     landing a controller on a class somebody else already took means the
		     player's first press does nothing and the screen reads as broken. ]]
		local target = nil
		for _, entry in rows do
			if entry.available then
				target = entry.button
				break
			end
		end
		GamepadFocus.capture(target or (rows[1] and rows[1].button))
	else
		GamepadFocus.release(nil)
	end
end

local function onSpawnOptions(payload: any)
	if typeof(payload) ~= "table" then
		return
	end
	state.kinds = if typeof(payload.kinds) == "table" then payload.kinds else {}
	state.respawnAt = tonumber(payload.respawnAt) or 0
	state.teammates = if typeof(payload.teammates) == "table" then payload.teammates else {}
	state.selected = ""

	refreshRows()
	refreshTeam()
	setVisible(true)
end

--[[ The picker closes the moment the server gives this player a body. That event
     is VersusTeamChanged carrying a model for us. ]]
local function onTeamChanged(payload: any)
	if typeof(payload) ~= "table" then
		return
	end
	if payload.player ~= player then
		return
	end
	if payload.team ~= Enums.Team.Infected then
		setVisible(false)
		return
	end
	if payload.model ~= nil then
		setVisible(false)
	end
end

local function update()
	if not state.visible then
		return
	end

	local remaining = math.max(math.ceil(state.respawnAt - Workspace:GetServerTimeNow()), 0)
	if remaining == state.shownClock then
		return
	end
	state.shownClock = remaining

	if remaining > 0 then
		clockLabel.Text = string.format("MATERIALISING IN %d", remaining)
		clockLabel.TextColor3 = COLOR.TextSecondary
		titleLabel.Text = "PICK YOUR INFECTED"
	else
		clockLabel.Text = "READY — PICK ONE"
		clockLabel.TextColor3 = COLOR.Accent
		titleLabel.Text = "PICK YOUR INFECTED"
	end
end

local function build()
	screen = Instance.new("ScreenGui")
	screen.Name = "FL_InfectedPicker"
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = true
	--[[ One above the overlay layer, not level with it. You pick your next class
	     while the death card is still up, so the picker has to be the thing on
	     top rather than whichever ScreenGui happened to be built first. ]]
	screen.DisplayOrder = UITheme.DisplayOrder.Overlay + 1
	screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screen.Enabled = false
	screen.Parent = player:WaitForChild("PlayerGui")
	trove:add(screen)

	root = newFrame(ScaleLayer.new(screen, "Scaled"), "Root", COLOR.Background, 0.25)
	root.AnchorPoint = Vector2.new(0, 0.5)
	root.Position = UDim2.new(0, LAYOUT.ScreenMargin, 0.5, 0)
	root.Size = UDim2.fromOffset(PANEL_WIDTH, 0)

	titleLabel = newLabel(root, "Title", FONT.Display, TEXT.Heading, COLOR.TextPrimary)
	titleLabel.Position = UDim2.fromOffset(LAYOUT.PanelPadding, LAYOUT.PanelPadding)
	titleLabel.Size = UDim2.new(1, -LAYOUT.PanelPadding * 2, 0, TEXT.Heading + 4)
	titleLabel.Text = "PICK YOUR INFECTED"

	clockLabel = newLabel(root, "Clock", FONT.Body, TEXT.Small, COLOR.TextSecondary)
	clockLabel.Position = UDim2.fromOffset(LAYOUT.PanelPadding, LAYOUT.PanelPadding + TEXT.Heading + 6)
	clockLabel.Size = UDim2.new(1, -LAYOUT.PanelPadding * 2, 0, TEXT.Body)

	local rule = newFrame(root, "Rule", COLOR.Border, 0)
	rule.Position = UDim2.fromOffset(LAYOUT.PanelPadding, LAYOUT.PanelPadding + TEXT.Heading + TEXT.Body + 12)
	rule.Size = UDim2.new(1, -LAYOUT.PanelPadding * 2, 0, 1)

	local rowsTop = LAYOUT.PanelPadding + TEXT.Heading + TEXT.Body + 20
	rowsFolder = newFrame(root, "Rows", COLOR.Background, 1)
	rowsFolder.Position = UDim2.fromOffset(LAYOUT.PanelPadding, rowsTop)
	rowsFolder.Size = UDim2.new(1, -LAYOUT.PanelPadding * 2, 0, 4 * ROW_HEIGHT + 3 * ROW_GAP)

	buildRows()

	teamLabel = newLabel(root, "Team", FONT.Body, TEXT.Tiny, COLOR.TextDim)
	teamLabel.Position = UDim2.fromOffset(LAYOUT.PanelPadding, rowsTop + 4 * ROW_HEIGHT + 3 * ROW_GAP + 8)
	teamLabel.Size = UDim2.new(1, -LAYOUT.PanelPadding * 2, 0, TEXT.Body)

	root.Size = UDim2.fromOffset(
		PANEL_WIDTH,
		rowsTop + 4 * ROW_HEIGHT + 3 * ROW_GAP + TEXT.Body + LAYOUT.PanelPadding * 2
	)
end

function InfectedController:init()
	build()
end

function InfectedController:start()
	trove:connect(Remotes.Event.InfectedSpawnOptions.OnClientEvent, onSpawnOptions)
	trove:connect(Remotes.Event.VersusTeamChanged.OnClientEvent, onTeamChanged)

	-- Number keys 1-4 mirror the rows, because under a respawn clock nobody wants
	-- to move a mouse across the screen.
	trove:connect(UserInputService.InputBegan, function(input, processed)
		if processed or not state.visible then
			return
		end
		local index = table.find(NUMBER_KEYS, input.KeyCode)
		if index and rows[index] and rows[index].available then
			request(rows[index].kind)
		end
	end)

	trove:connect(Remotes.Event.RoundEnded.OnClientEvent, function()
		setVisible(false)
	end)

	trove:connect(RunService.RenderStepped, update)
end

function InfectedController:isOpen(): boolean
	return state.visible
end

Registry.register("InfectedController", InfectedController)

return InfectedController
