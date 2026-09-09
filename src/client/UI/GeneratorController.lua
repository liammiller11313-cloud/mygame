--!nonstrict
--[[
	GeneratorController — the panel on the front of a generator, whichever of the
	five puzzles is behind it tonight.

	One screen that can draw five different things, because they are five faces
	of one activity: a machine is broken, you are standing in front of it, and
	the horde is not waiting. A panel each would be five copies of the
	suppression, the cursor, the pad focus and the round-end teardown — and five
	places for one of them to be forgotten, which is how a screen ends up
	impossible to close on a console.

	── IT KNOWS NOTHING IT WAS NOT DRAWN ───────────────────────────────────────
	Everything on this screen arrived in a payload: the wire colours, the breaker
	ratings, the bus target, the bands, the dials. It has to — the player solves
	these by LOOKING at them, so anything they can see is on their machine by the
	time they can play at all.

	What this file cannot do is decide anything. It cannot power a generator, it
	cannot power one out of turn, it cannot tell you whether the four terminals
	you pressed were the right four, and it cannot open the gate. It presses
	SUBMIT and waits, exactly like the keypad next door. A player who deleted
	this file entirely would be exactly as far from the loot room as one who kept
	it. See GeneratorConfig's header for the whole of that trade written out.

	── EVERY PUZZLE IS PRESSES ─────────────────────────────────────────────────
	No dragging, no holding, no aiming. Five layouts of buttons, and the answer
	is which ones you pressed and in what order — because a drag is a mouse, and
	a mouse is a third of this game's audience. The one timing puzzle is a single
	button, which is the one interaction every scheme is equally good at.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attributes = require(Shared.Net.Attributes)
local AudioConfig = require(Shared.Config.AudioConfig)
local Enums = require(Shared.Enums)
local GeneratorConfig = require(Shared.Config.GeneratorConfig)
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

local GA = Attributes.Game
local KIND = GeneratorConfig.Kind

local player = Players.LocalPlayer

--[[ Wide rather than tall. Four of the five layouts are two columns or a row of
     five, and a narrow panel would stack them into a scroll — which is the one
     thing a screen you read while being chased must never be. ]]
local PANEL_WIDTH = 500
local PANEL_HEIGHT = 440

local INSTRUCTION_HEIGHT = 38
local FOOTER_HEIGHT = 36
local CLEAR_WIDTH = 118

--[[ How long the panel sits on ONLINE before it closes itself. Long enough to
     read, short enough that it is not standing between a player and the next
     generator. ]]
local DONE_DWELL = 0.9

--[[ The gauge, in reference pixels. Tall enough that a needle inside a band is
     unambiguous on a phone at the 0.75 scale floor. ]]
local GAUGE_HEIGHT = 54
local NEEDLE_WIDTH = 4
local STOP_HEIGHT = 62

local GeneratorController = {}

local trove = Trove.new()
--[[ Everything the CURRENT puzzle drew. Cleaned on every open and every close,
     so a wire panel never leaves four rows behind a breaker panel. ]]
local bodyTrove = Trove.new()

local gui: ScreenGui
local panel: Frame
local title: TextLabel
local closeButton: TextButton
local instruction: TextLabel
local body: Frame
local statusLabel: TextLabel
local clearButton: TextButton
local clearLabel: TextLabel

--[[ The panel's OWN restore slot. FreeCursor's contract: these screens nest, so
     a shared one would have an inner panel hand back an outer panel's camera. ]]
local restore = {}

local state = {
	open = false,
	suppressed = false,
	--[[ The machine this panel belongs to. Sent back with the answer, so a panel
	     left open while somebody else powered the generator is refused by name
	     rather than applied to whatever is next. ]]
	target = nil :: Instance?,
	order = 0,
	kind = "",
	challenge = nil :: any,

	--[[ What the player has pressed, in the currency the server checks: a list of
	     small whole numbers. Every one of the five answers this shape. ]]
	answer = {} :: { number },
	--[[ Which cells are lit, for the one puzzle whose presses TOGGLE rather than
	     append. Kept beside `answer` rather than derived from it because a
	     deselect has to be able to find and remove an entry. ]]
	picked = {} :: { [number]: boolean },
	--[[ The phase dials as the player has turned them. A working copy: the dealt
	     board stays in `challenge` so CLEAR has something to go back to. ]]
	dials = {} :: { number },
	--[[ The pressure gauge. `running` is what the Heartbeat step tests, so a
	     panel showing a result is not also animating a needle behind it. ]]
	stage = 1,
	needle = 0,
	sweep = 1,
	running = false,

	--[[ Absolute server-time stamp the panel will take another answer at. Never a
	     countdown: the client subtracts its own clock, so it cannot drift and
	     cannot arrive stale. Same rule as the keypad. ]]
	retryAt = 0,
	--[[ True from the moment an answer goes up until one comes back. Presses do
	     nothing while it is set, which matters on the toggle layout: without it a
	     player who deselects a cell while the reply is in flight can send a
	     second answer for a generator the first one may already have powered. ]]
	pending = false,
	--[[ Where a pad's focus lands when the panel opens. Whichever button the
	     current layout considers first — without it these screens are answerable
	     only with a mouse, which on a console is the same as not answerable. ]]
	firstButton = nil :: GuiButton?,
}

-- ── helpers ─────────────────────────────────────────────────────────────────

--[[ Asked of InputController rather than of the device, because the scheme is
     what the player is DRIVING with. Same check every other panel makes. ]]
local function isTouch(): boolean
	local input = Registry.find("InputController")
	if not input or typeof(input.isTouchScheme) ~= "function" then
		return false
	end
	local ok, touch = pcall(input.isTouchScheme, input)
	return ok and touch == true
end

--[[ The needle's per-frame step, set by the gauge layout and nil for the other
     four. A plain upvalue rather than a method on the controller, so tearing the
     body down actually removes it instead of leaving a closure over four
     destroyed instances hanging off the module. ]]
local gaugeStep: ((number) -> ())? = nil

--[[
	How tall the puzzle area is, in reference pixels.

	Computed from the constants rather than read off AbsoluteSize, because the
	layouts are built in the same frame the panel is resized and enabled — and on
	that frame AbsoluteSize is still whatever it was before, or zero. A wire loom
	whose four rows were divided out of zero is a wire loom nobody can press.
]]
local function bodyHeight(): number
	local height = PANEL_HEIGHT + (if isTouch() then PANEL.RowHeightTouch else 0)
	return height
		- PANEL.HeaderHeight
		- INSTRUCTION_HEIGHT
		- FOOTER_HEIGHT
		- LAYOUT.ElementGap * 2
		- LAYOUT.PanelPadding
end

--[[ Whether the main menu is up. Same three lines every panel in this folder
     carries, and for the same reason: a panel opened OVER the menu must not
     hand the round back when it closes. ]]
local function menuIsOpen(): boolean
	local menu = Registry.find("MainMenuController")
	if not menu or typeof(menu.isOpen) ~= "function" then
		return false
	end
	local ok, open = pcall(menu.isOpen, menu)
	return ok and open == true
end

local function callController(name: string, method: string, ...: any)
	local controller = Registry.find(name)
	if controller and typeof(controller[method]) == "function" then
		pcall(controller[method], controller, ...)
	end
end

local function setSuppressed(value: boolean)
	if state.suppressed == value then
		return
	end
	state.suppressed = value
	callController("InputController", "setSuppressed", value)
	callController("PromptController", "setEnabled", not value)
end

local function serverNow(): number
	return Workspace:GetServerTimeNow()
end

local function setStatus(text: string, color: Color3)
	statusLabel.Text = text
	statusLabel.TextColor3 = color
end

--[[ Whether presses should do anything right now. False while a wrong answer is
     cooling off, so the panel refuses in one place rather than every handler
     carrying its own check — and so a player mashing a breaker during a fault
     does not queue up an answer that fires the instant it clears. ]]
local function accepting(): boolean
	return state.open and not state.pending and serverNow() >= state.retryAt
end

-- ── the chrome ──────────────────────────────────────────────────────────────

--[[ A button with a border and a centred word in it. Every one of the five
     layouts is made of these, so the touch target, the outline and the hover
     are decided once. ]]
local function tile(parent: Instance, name: string): (TextButton, TextLabel, UIStroke)
	local button = Widgets.button(parent, name)
	button.BackgroundColor3 = COLOR.PanelRaised
	button.BackgroundTransparency = 0
	local stroke = Widgets.stroke(button, COLOR.Border)
	local label = Widgets.label(button, "Label", FONT.Heading, TEXT.Body, COLOR.TextPrimary)
	label.Size = UDim2.fromScale(1, 1)
	label.TextXAlignment = Enum.TextXAlignment.Center
	return button, label, stroke
end

local function build()
	gui = Instance.new("ScreenGui")
	gui.Name = "FL_Generator"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = UITheme.DisplayOrder.Settings
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Enabled = false
	gui.Parent = player:WaitForChild("PlayerGui")
	trove:add(gui)

	local layer = ScaleLayer.new(gui, "Scaled")
	local chrome = Widgets.panel(layer, trove, "GENERATOR", function()
		GeneratorController:close()
	end)
	panel = chrome.frame
	title = chrome.title
	closeButton = chrome.close

	instruction = Widgets.label(panel, "Instruction", FONT.Body, TEXT.Small, COLOR.TextSecondary)
	instruction.Position = UDim2.fromOffset(LAYOUT.PanelPadding, PANEL.HeaderHeight + 2)
	instruction.Size = UDim2.new(1, -LAYOUT.PanelPadding * 2, 0, INSTRUCTION_HEIGHT)
	instruction.TextWrapped = true
	instruction.TextXAlignment = Enum.TextXAlignment.Center

	body = Widgets.frame(panel, "Body", COLOR.Panel, 1)
	body.Position =
		UDim2.fromOffset(LAYOUT.PanelPadding, PANEL.HeaderHeight + INSTRUCTION_HEIGHT + LAYOUT.ElementGap)
	body.Size = UDim2.new(
		1,
		-LAYOUT.PanelPadding * 2,
		1,
		-(
				PANEL.HeaderHeight
				+ INSTRUCTION_HEIGHT
				+ FOOTER_HEIGHT
				+ LAYOUT.ElementGap * 2
				+ LAYOUT.PanelPadding
			)
	)

	--[[ CLEAR on the left and the status line filling the rest. CLEAR exists on
	     every layout because four of the five are sequences: a player who
	     realises on the third press that they started wrong should be able to
	     start again rather than having to finish a wrong answer to be told it was
	     wrong. ]]
	local footer = Widgets.frame(panel, "Footer", COLOR.Panel, 1)
	footer.AnchorPoint = Vector2.new(0, 1)
	footer.Position = UDim2.new(0, LAYOUT.PanelPadding, 1, -LAYOUT.PanelPadding)
	footer.Size = UDim2.new(1, -LAYOUT.PanelPadding * 2, 0, FOOTER_HEIGHT)

	local stroke
	clearButton, clearLabel, stroke = tile(footer, "Clear")
	clearButton.Size = UDim2.fromOffset(CLEAR_WIDTH, FOOTER_HEIGHT)
	clearLabel.Text = "CLEAR"
	clearLabel.TextSize = TEXT.Small
	Widgets.outlineHover(trove, clearButton, stroke)
	trove:connect(clearButton.Activated, function()
		GeneratorController:reset()
	end)

	statusLabel = Widgets.label(footer, "Status", FONT.Body, TEXT.Small, COLOR.TextSecondary)
	statusLabel.Position = UDim2.fromOffset(CLEAR_WIDTH + LAYOUT.ElementGap, 0)
	statusLabel.Size = UDim2.new(1, -(CLEAR_WIDTH + LAYOUT.ElementGap), 1, 0)
	statusLabel.TextXAlignment = Enum.TextXAlignment.Right
	statusLabel.TextTruncate = Enum.TextTruncate.AtEnd
end

-- ── sending an answer ───────────────────────────────────────────────────────

local function submit()
	if #state.answer < 1 or not state.target or state.pending then
		return
	end
	state.pending = true
	setStatus("CHECKING\226\128\166", COLOR.TextSecondary)
	Remotes.Event.SubmitGenerator:FireServer({
		generator = state.target,
		--[[ A copy. The table goes onto a wire and then the player keeps pressing
		     — sending the live one would be sending whatever it became by the
		     time it serialised. ]]
		answer = table.clone(state.answer),
	})
end

-- ── 1. the wire loom ────────────────────────────────────────────────────────

--[[
	Four wires down the left, four terminals down the right, and no terminal
	opposite its own wire.

	Presses go in WIRE order: the lit row is the one the panel is waiting on, and
	the terminal you press is the answer for it. Which makes the whole thing a
	sequence of four presses rather than four separate matches, and means the
	answer is a list in exactly the shape every other puzzle here produces.

	Nothing is checked locally. The panel lights the row it has moved on to and
	sends all four at once, because it does not know and must not appear to know
	whether the third one was right.
]]
local function buildWireMatch()
	local wires = state.challenge.wires or {}
	local terminals = state.challenge.terminals or {}
	local count = math.min(#wires, #terminals)
	if count < 1 then
		return
	end

	local rowHeight = bodyHeight() // count
	local wireRows: { Frame } = {}
	local wireDots: { Frame } = {}
	local wireStrokes: { UIStroke } = {}

	--[[ Spliced is dim, next is bright, not-yet is normal. Three states rather
	     than two, because "which row am I answering" is the only thing this
	     layout has to communicate — and with a single highlight the finished rows
	     and the future ones look identical. ]]
	local function refresh()
		for index = 1, count do
			local done = index <= #state.answer
			local active = index == #state.answer + 1
			wireRows[index].BackgroundTransparency = if done then 0.6 else 0
			wireDots[index].BackgroundTransparency = if done then 0.6 else 0
			wireStrokes[index].Color = if active then COLOR.AccentBright else COLOR.Border
		end
		setStatus(string.format("%d / %d SPLICED", #state.answer, count), COLOR.TextSecondary)
	end

	for index = 1, count do
		local y = (index - 1) * rowHeight
		local rowInset = 4

		--[[ The wire. A swatch and its NAME, because a puzzle whose only channel
		     is hue is a puzzle a colourblind player cannot do — and this is
		     optional content in a co-op game, which is the version of
		     "inaccessible" where your team goes and does it without you. ]]
		local row = Widgets.frame(body, "Wire" .. index, COLOR.PanelRaised, 0)
		row.Position = UDim2.fromOffset(0, y)
		row.Size = UDim2.new(0.46, 0, 0, rowHeight - rowInset)
		wireStrokes[index] = Widgets.stroke(row, COLOR.Border)
		wireRows[index] = row

		local wire = GeneratorConfig.wire(wires[index])
		local dot = Widgets.frame(row, "Dot", wire.color, 0)
		dot.AnchorPoint = Vector2.new(0, 0.5)
		dot.Position = UDim2.new(0, 8, 0.5, 0)
		dot.Size = UDim2.fromOffset(22, 22)
		wireDots[index] = dot

		local name = Widgets.label(row, "Name", FONT.Heading, TEXT.Small, COLOR.TextPrimary)
		name.Position = UDim2.fromOffset(38, 0)
		name.Size = UDim2.new(1, -46, 1, 0)
		name.Text = wire.name

		--[[ The terminal. A button, and the only half of the row that is
		     pressable — the wires are a legend, not a control. ]]
		local terminal = GeneratorConfig.wire(terminals[index])
		local button, label, stroke = tile(body, "Terminal" .. index)
		button.AnchorPoint = Vector2.new(1, 0)
		button.Position = UDim2.new(1, 0, 0, y)
		button.Size = UDim2.new(0.46, 0, 0, rowHeight - rowInset)
		label.Text = terminal.name
		label.TextSize = TEXT.Small
		label.TextColor3 = terminal.color
		Widgets.outlineHover(bodyTrove, button, stroke)
		if index == 1 then
			state.firstButton = button
		end

		local terminalDot = Widgets.frame(button, "Dot", terminal.color, 0)
		terminalDot.AnchorPoint = Vector2.new(0, 0.5)
		terminalDot.Position = UDim2.new(0, 8, 0.5, 0)
		terminalDot.Size = UDim2.fromOffset(22, 22)

		bodyTrove:connect(button.Activated, function()
			if not accepting() or #state.answer >= count then
				return
			end
			table.insert(state.answer, index)
			UiSound.play(AudioConfig.Generator.Press)
			refresh()
			if #state.answer >= count then
				submit()
			end
		end)
	end

	refresh()
end

-- ── 2. the breaker panel ────────────────────────────────────────────────────

--[[
	Five breakers in a row, and one instruction that changes.

	The simplest of the five on purpose: a pack where every puzzle demands a
	moment of standing still is a pack that gets a team killed, and this is the
	one a player can finish while backing away from a doorway.

	What stops it being free is the DIRECTION. Half the deals want the lowest
	first and half want the highest, so a player who has done it before still has
	to read the line — and one who assumes gets a fault rather than a generator.
]]
local function buildBreakerOrder()
	local ratings = state.challenge.ratings or {}
	local count = #ratings
	if count < 1 then
		return
	end

	--[[
		The DIRECTION, said out loud on the instruction line.

		This is the whole puzzle. The generic line in GeneratorConfig says to
		throw them in order of rating and stops short of saying which order,
		because half the deals want each — and a direction the player cannot read
		is not a puzzle, it is a coin flip they lose half the time for no reason
		they can see.

		Refined here rather than shipped as two Presentation rows, because the
		direction is a fact about THIS deal and the presentation table is a fact
		about the puzzle.
	]]
	instruction.Text = if state.challenge.ascending == true
		then "THROW THE BREAKERS FROM LOWEST RATING TO HIGHEST"
		else "THROW THE BREAKERS FROM HIGHEST RATING TO LOWEST"

	local width = 1 / count
	local marks: { TextLabel } = {}

	--[[ The order the player put each breaker in, under its rating. Without it a
	     half-finished sequence is invisible and CLEAR is the only way to be sure
	     what you have already thrown. ]]
	local function refresh()
		for index = 1, count do
			local at = table.find(state.answer, index)
			marks[index].Text = if at then tostring(at) else ""
		end
		setStatus(string.format("%d / %d THROWN", #state.answer, count), COLOR.TextSecondary)
	end

	for index = 1, count do
		local button, label, stroke = tile(body, "Breaker" .. index)
		button.Position = UDim2.new(width * (index - 1), 3, 0, 0)
		button.Size = UDim2.new(width, -6, 1, 0)
		label.Text = string.format("%dA", ratings[index])
		label.Position = UDim2.fromOffset(0, -12)
		Widgets.outlineHover(bodyTrove, button, stroke)
		if index == 1 then
			state.firstButton = button
		end

		local mark = Widgets.label(button, "Mark", FONT.Numeric, TEXT.Small, COLOR.AccentBright)
		mark.AnchorPoint = Vector2.new(0.5, 1)
		mark.Position = UDim2.new(0.5, 0, 1, -8)
		mark.Size = UDim2.new(1, 0, 0, TEXT.Small + 2)
		mark.TextXAlignment = Enum.TextXAlignment.Center
		marks[index] = mark

		bodyTrove:connect(button.Activated, function()
			if not accepting() or #state.answer >= count then
				return
			end
			--[[ Once each. A breaker you have already thrown is not a breaker you
			     can throw again, and allowing it would let a player build an
			     answer the server can only refuse. ]]
			if table.find(state.answer, index) then
				return
			end
			table.insert(state.answer, index)
			UiSound.play(AudioConfig.Generator.Press)
			refresh()
			if #state.answer >= count then
				submit()
			end
		end)
	end

	refresh()
end

-- ── 3. the bus voltage ──────────────────────────────────────────────────────

--[[
	Six cells, one target, pick the three that make it.

	The only puzzle here whose presses TOGGLE rather than append: a cell is in or
	out, order does not matter, and pressing a lit one takes it back out. That is
	what an addition problem wants — a player who mis-taps the fourth cell should
	be able to correct it without starting again — and it is why this layout
	keeps a `picked` set beside the answer list.
]]
local function buildVoltageMatch()
	local cells = state.challenge.cells or {}
	local target = tonumber(state.challenge.target) or 0
	local pick = tonumber(state.challenge.pick) or 3
	local count = #cells
	if count < 1 then
		return
	end

	--[[ How many, on the line. The generic wording says "cells" and the count is
	     the one thing a player needs before they start adding — three is a
	     different problem from two. ]]
	instruction.Text = string.format("SELECT %d CELLS THAT ADD UP TO THE BUS TARGET", pick)

	local header = Widgets.label(body, "Target", FONT.Numeric, TEXT.Heading, COLOR.AccentBright)
	header.Size = UDim2.new(1, 0, 0, TEXT.Heading + 6)
	header.TextXAlignment = Enum.TextXAlignment.Center
	header.Text = string.format("BUS TARGET  %dV", target)

	local columns = 3
	local rows = math.ceil(count / columns)
	local gridTop = TEXT.Heading + 12
	local gridHeight = math.max(bodyHeight() - gridTop, 60)
	local buttons: { TextButton } = {}
	local strokes: { UIStroke } = {}

	--[[ The running total beside the target, which is the whole reason this is
	     an addition puzzle rather than a search: a player two cells in can see
	     how much of the bus they have and pick the third one on purpose. ]]
	local function refresh()
		local sum = 0
		for index = 1, count do
			local on = state.picked[index] == true
			strokes[index].Color = if on then COLOR.AccentBright else COLOR.Border
			buttons[index].BackgroundTransparency = if on then 0.35 else 0
			if on then
				sum += cells[index]
			end
		end
		setStatus(
			string.format("%d / %d SELECTED  \226\128\148  %dV OF %dV", #state.answer, pick, sum, target),
			COLOR.TextSecondary
		)
	end

	for index = 1, count do
		local column = (index - 1) % columns
		local row = (index - 1) // columns
		local button, label, stroke = tile(body, "Cell" .. index)
		button.Position = UDim2.new(column / columns, 3, 0, gridTop + row * (gridHeight // rows))
		button.Size = UDim2.new(1 / columns, -6, 0, (gridHeight // rows) - 6)
		label.Text = string.format("%dV", cells[index])
		Widgets.outlineHover(bodyTrove, button, stroke)
		buttons[index] = button
		strokes[index] = stroke
		if index == 1 then
			state.firstButton = button
		end

		bodyTrove:connect(button.Activated, function()
			if not accepting() then
				return
			end
			if state.picked[index] then
				state.picked[index] = nil
				local at = table.find(state.answer, index)
				if at then
					table.remove(state.answer, at)
				end
			elseif #state.answer < pick then
				state.picked[index] = true
				table.insert(state.answer, index)
			else
				return
			end
			UiSound.play(AudioConfig.Generator.Press)
			refresh()
			--[[ Sent the moment the third one lights, rather than behind a
			     CONFIRM. There is nothing to confirm: three cells either make the
			     target or they do not, and a button that says "are you sure"
			     about arithmetic is a button in the way. ]]
			if #state.answer >= pick then
				submit()
			end
		end)
	end

	refresh()
end

-- ── 4. the pressure gauge ───────────────────────────────────────────────────

--[[
	A needle sweeping a gauge, a green band, and one button.

	Three stages with the band narrowing and the needle speeding up, which makes
	it the only puzzle in the pack that gets harder rather than longer. It is
	here because the other four are all about reading a layout, and a phone
	screen is worst at exactly that — this one works identically with a mouse, a
	thumb and a pad face button.

	The needle is animated HERE, and where it stopped is what goes up. A crafted
	client can therefore always stop it perfectly; see this file's header and
	GeneratorConfig's for why that is the correct trade rather than a hole.
]]
local function buildPressureValve()
	local stages = state.challenge.stages or {}
	local span = tonumber(state.challenge.span) or GeneratorConfig.GaugeSpan
	if #stages < 1 then
		return
	end

	local track = Widgets.frame(body, "Gauge", COLOR.Background, 0.15)
	track.AnchorPoint = Vector2.new(0, 0.5)
	track.Position = UDim2.new(0, 0, 0.42, 0)
	track.Size = UDim2.new(1, 0, 0, GAUGE_HEIGHT)
	Widgets.stroke(track, COLOR.Border)

	local band = Widgets.frame(track, "Band", COLOR.Hazard, 0.35)
	band.Size = UDim2.new(0, 0, 1, 0)

	local needle = Widgets.frame(track, "Needle", COLOR.TextPrimary, 0)
	needle.AnchorPoint = Vector2.new(0.5, 0)
	needle.Size = UDim2.new(0, NEEDLE_WIDTH, 1, 0)

	local stageLabel = Widgets.label(body, "Stage", FONT.Heading, TEXT.Small, COLOR.TextSecondary)
	stageLabel.Position = UDim2.fromOffset(0, 0)
	stageLabel.Size = UDim2.new(1, 0, 0, TEXT.Small + 4)
	stageLabel.TextXAlignment = Enum.TextXAlignment.Center

	local stop, stopText, stopStroke = tile(body, "Stop")
	stop.AnchorPoint = Vector2.new(0.5, 1)
	stop.Position = UDim2.new(0.5, 0, 1, 0)
	stop.Size = UDim2.new(1, 0, 0, STOP_HEIGHT)
	stopText.Text = "STOP"
	stopText.TextSize = TEXT.Large
	Widgets.outlineHover(bodyTrove, stop, stopStroke)
	state.firstButton = stop

	--[[ Redrawn on every stage rather than tweened between them. The band moves
	     and changes width at the same instant the needle restarts, and a player
	     watching a band slide into place has been given a moment of information
	     they cannot act on. ]]
	local function paintStage()
		local stage = stages[state.stage]
		if not stage then
			return
		end
		band.Position = UDim2.new(stage.low / span, 0, 0, 0)
		band.Size = UDim2.new((stage.high - stage.low) / span, 0, 1, 0)
		stageLabel.Text = string.format("STAGE %d OF %d", state.stage, #stages)
		setStatus("HOLD STEADY", COLOR.TextSecondary)
	end

	gaugeStep = function(dt: number)
		local stage = stages[state.stage]
		if not state.running or not stage then
			return
		end
		--[[ Sweeps per second across the whole span, reversing at both ends. A
		     wrap instead of a bounce would teleport the needle, and a needle that
		     teleports is a needle a player cannot time. ]]
		state.needle += state.sweep * stage.sweep * span * dt
		if state.needle >= span then
			state.needle = span
			state.sweep = -1
		elseif state.needle <= 0 then
			state.needle = 0
			state.sweep = 1
		end
		needle.Position = UDim2.new(state.needle / span, 0, 0, 0)
	end

	bodyTrove:connect(stop.Activated, function()
		if not accepting() or not state.running then
			return
		end
		local stage = stages[state.stage]
		if not stage then
			return
		end
		table.insert(state.answer, math.floor(state.needle + 0.5))
		UiSound.play(AudioConfig.Generator.Press)

		if state.stage >= #stages then
			--[[ Stopped, then sent. The needle freezes on the last reading so the
			     player can see what they submitted while they wait for the
			     answer. ]]
			state.running = false
			submit()
			return
		end

		state.stage += 1
		state.needle = 0
		state.sweep = 1
		paintStage()
	end)

	paintStage()
	state.running = true
end

-- ── 5. the phase dials ──────────────────────────────────────────────────────

--[[
	Four dials, and turning one turns its right-hand neighbour as well.

	Which means the obvious approach — fix the first, then the second, then the
	third — breaks itself as it goes, and the puzzle is noticing that the
	coupling is the mechanism rather than the obstacle.

	The board is dealt BACKWARDS from solved on the server, so every one of them
	can be finished; see the module there. What goes up is the sequence of dials
	pressed, not the values reached — the server replays the presses on its own
	copy, because asking a client what it thinks the answer is and then checking
	its arithmetic against itself is not a check.
]]
local function buildPhaseAlign()
	local dealt = state.challenge.dials or {}
	local target = tonumber(state.challenge.target) or 0
	local modulus = tonumber(state.challenge.modulus) or 4
	local count = #dealt
	if count < 1 then
		return
	end

	local header = Widgets.label(body, "Target", FONT.Numeric, TEXT.Heading, COLOR.AccentBright)
	header.Size = UDim2.new(1, 0, 0, TEXT.Heading + 6)
	header.TextXAlignment = Enum.TextXAlignment.Center
	header.Text = string.format("ALIGN EVERY DIAL TO %d", target)

	local top = TEXT.Heading + 14
	local height = math.max(bodyHeight() - top, 60)
	local labels: { TextLabel } = {}
	local strokes: { UIStroke } = {}

	--[[ A dial on the target is green and outlined; everything else is plain.
	     The count under it is what tells a player whether the press they just
	     made helped, which on a coupled board is not obvious from the dials
	     alone. ]]
	local function refresh()
		local right = 0
		for index = 1, count do
			local value = state.dials[index] or 0
			labels[index].Text = tostring(value)
			local on = value == target
			labels[index].TextColor3 = if on then COLOR.HealthGood else COLOR.TextPrimary
			strokes[index].Color = if on then COLOR.AccentBright else COLOR.Border
			if on then
				right += 1
			end
		end
		setStatus(string.format("%d / %d ALIGNED", right, count), COLOR.TextSecondary)
	end

	for index = 1, count do
		local button, label, stroke = tile(body, "Dial" .. index)
		button.Position = UDim2.new((index - 1) / count, 4, 0, top)
		button.Size = UDim2.new(1 / count, -8, 0, height)
		label.TextSize = TEXT.Display
		Widgets.outlineHover(bodyTrove, button, stroke)
		labels[index] = label
		strokes[index] = stroke
		if index == 1 then
			state.firstButton = button
		end

		bodyTrove:connect(button.Activated, function()
			if not accepting() then
				return
			end
			--[[ Capped at what a submission is allowed to carry. A player who has
			     pressed twenty-four times has lost the thread rather than found a
			     long route — the worst board this puzzle deals is nine presses
			     from solved — so the panel says so and resets instead of building
			     an answer the server would refuse for a reason nobody could
			     read. ]]
			if #state.answer >= GeneratorConfig.MaxAnswer then
				setStatus("TOO MANY TURNS \226\128\148 CLEARED", COLOR.Warning)
				GeneratorController:reset()
				return
			end
			table.insert(state.answer, index)
			--[[ The same rule the server replays, written once on each side
			     because it is the rule the PLAYER is learning: this dial and the
			     one to its right, wrapping. ]]
			local right = (index % count) + 1
			state.dials[index] = (state.dials[index] + 1) % modulus
			state.dials[right] = (state.dials[right] + 1) % modulus
			UiSound.play(AudioConfig.Generator.Press)
			refresh()

			local aligned = true
			for _, value in state.dials do
				if value ~= target then
					aligned = false
					break
				end
			end
			if aligned then
				submit()
			end
		end)
	end

	refresh()
end

-- ── drawing whichever one it is ─────────────────────────────────────────────

local BUILDERS = {
	[KIND.WireMatch] = buildWireMatch,
	[KIND.BreakerOrder] = buildBreakerOrder,
	[KIND.VoltageMatch] = buildVoltageMatch,
	[KIND.PressureValve] = buildPressureValve,
	[KIND.PhaseAlign] = buildPhaseAlign,
}

--[[ Back to the board as it was dealt, keeping the puzzle. Not a re-roll: the
     server still holds the same deal, and a CLEAR that changed the picture would
     look like the machine had reset itself. ]]
local function redraw()
	bodyTrove:clean()
	--[[ Torn down BEFORE the early return below, not after it. A redraw with no
	     challenge is what a version mismatch and a closed panel both look like,
	     and leaving the previous layout's buttons alive in either case leaves a
	     screen you can still press. ]]
	for _, child in body:GetChildren() do
		child:Destroy()
	end

	gaugeStep = nil
	state.firstButton = nil
	state.running = false
	state.pending = false
	table.clear(state.answer)
	table.clear(state.picked)
	table.clear(state.dials)
	state.stage = 1
	state.needle = 0
	state.sweep = 1

	if not state.challenge then
		return
	end
	--[[ Back to the generic line before a builder gets a chance to refine it.
	     Two of the five rewrite this with something specific to the deal, and
	     without the reset a CLEAR on a breaker panel would keep whatever the LAST
	     panel wrote. ]]
	local present = GeneratorConfig.Presentation[state.kind]
	instruction.Text = if present then present.instruction else ""

	for index, value in state.challenge.dials or {} do
		state.dials[index] = value
	end

	local builder = BUILDERS[state.kind]
	if builder then
		builder()
	else
		--[[ A kind this build does not draw. Said out loud on the panel rather
		     than left blank, because a blank machine reads as a bug in the map
		     and this is a version mismatch. ]]
		setStatus("UNKNOWN PANEL TYPE", COLOR.Danger)
	end
end

-- ── public ──────────────────────────────────────────────────────────────────

function GeneratorController:isOpen(): boolean
	return state.open
end

--[[ Start the current puzzle again from the board it was dealt. Bound to CLEAR
     and used by the fault path, so a wrong answer and a change of mind put the
     panel in the same place. ]]
function GeneratorController:reset()
	--[[ Not while an answer is in flight. `redraw` clears the pending flag, so a
	     CLEAR pressed between SUBMIT and the reply would unblock the panel and
	     let a second answer go up for a generator the first one may already have
	     powered. ]]
	if not state.open or state.pending then
		return
	end
	redraw()
	UiSound.play(AudioConfig.UI.MenuBack)
end

--[[
	Opens a panel the server dealt.

	Only ever called from the GeneratorPanel remote — there is no way to open
	this from the client, because whether this is the next generator in the order
	is a fact only the server has.
]]
function GeneratorController:open(payload: any)
	if state.open or typeof(payload) ~= "table" then
		return
	end
	local target = payload.generator
	if typeof(target) ~= "Instance" then
		return
	end

	state.target = target
	state.order = tonumber(payload.order) or 0
	state.kind = tostring(payload.kind or "")
	state.challenge = payload.challenge
	state.retryAt = 0
	state.open = true

	local present = GeneratorConfig.Presentation[state.kind]
	title.Text =
		string.format("GENERATOR %d \226\128\148 %s", state.order, if present then present.title else "PANEL")

	--[[ Taller on a phone by one row's worth, the same allowance the keypad
	     makes. A finger is not a cursor, and five breakers across a 0.75-scaled
	     panel is where that stops being a slogan. ]]
	panel.Size = UDim2.fromOffset(PANEL_WIDTH, PANEL_HEIGHT + (if isTouch() then PANEL.RowHeightTouch else 0))
	gui.Enabled = true
	redraw()

	--[[ Unless the menu already has it, like every other panel in this folder.
	     Suppressing unconditionally means the close below hands the round back
	     even when the main menu is still up over it. ]]
	setSuppressed(not menuIsOpen())
	FreeCursor.take(restore)
	GamepadFocus.capture(state.firstButton or closeButton)
	UiSound.play(AudioConfig.Generator.Open)
end

function GeneratorController:close()
	if not state.open then
		return
	end
	state.open = false
	state.running = false
	state.pending = false
	state.target = nil
	state.challenge = nil
	gaugeStep = nil
	bodyTrove:clean()
	gui.Enabled = false
	GamepadFocus.release(nil)
	FreeCursor.giveBack(restore)
	setSuppressed(false)
	if menuIsOpen() then
		callController("MainMenuController", "reassertSuppression")
	end
	UiSound.play(AudioConfig.UI.MenuBack)
end

-- ── lifecycle ───────────────────────────────────────────────────────────────

function GeneratorController:init()
	build()
end

function GeneratorController:start()
	--[[ The round ending closes this, the way it closes the keypad. A player
	     standing at a generator when the last survivor goes down would otherwise
	     keep a full-screen panel over the results poster, holding the cursor and
	     the input lock, and hand both back to a round that no longer exists. ]]
	trove:connect(Workspace:GetAttributeChangedSignal(GA.RoundState), function()
		if state.open and Attributes.get(Workspace, GA.RoundState, "") ~= Enums.RoundState.InProgress then
			self:close()
		end
	end)

	--[[
		The server's answer to pressing interact on a machine.

		Two shapes. A refusal never opens anything — the player is standing in the
		open with a horde coming and the last thing they need is a screen telling
		them they are at the wrong generator, so it goes to the counter card where
		the vault's refusals go, and they keep running.
	]]
	trove:connect(Remotes.Event.GeneratorPanel.OnClientEvent, function(payload: any)
		if typeof(payload) ~= "table" then
			return
		end
		if payload.ok ~= true then
			callController("VaultController", "sayRefusal", tostring(payload.reason or ""))
			UiSound.play(AudioConfig.Generator.Fault)
			return
		end
		self:open(payload)
	end)

	--[[ And the answer to an answer. A fault keeps the panel open on the board
	     the player was working, cleared back to the dealt state, because the
	     alternative — closing it — sends them back out to press interact again
	     for the same puzzle. ]]
	trove:connect(Remotes.Event.GeneratorResult.OnClientEvent, function(payload: any)
		if typeof(payload) ~= "table" or not state.open then
			return
		end
		state.retryAt = tonumber(payload.retryAt) or 0
		state.pending = false

		if payload.ok == true then
			state.running = false
			setStatus("ONLINE", COLOR.HealthGood)
			UiSound.play(AudioConfig.Generator.Solved)
			task.delay(DONE_DWELL, function()
				if state.open then
					self:close()
				end
			end)
			return
		end

		redraw()
		setStatus(tostring(payload.reason or "FAULT"), COLOR.Danger)
		UiSound.play(AudioConfig.Generator.Fault)
	end)

	--[[ Somebody else finished one. The panel closes rather than sitting on a
	     puzzle for a machine that is already running — and the closing IS the
	     notification, because a player staring at a wire panel is a player who
	     was working on exactly this. ]]
	trove:connect(Remotes.Event.GeneratorPowered.OnClientEvent, function(payload: any)
		if typeof(payload) ~= "table" or not state.open then
			return
		end
		if payload.player ~= player and tonumber(payload.order) == state.order then
			self:close()
		end
	end)

	--[[ The needle, on the one puzzle that has one. Guarded on `running` rather
	     than on the kind, so the four layouts that never set it cost one boolean
	     test a frame and nothing else. ]]
	trove:connect(RunService.Heartbeat, function(dt: number)
		if state.running and gaugeStep then
			gaugeStep(dt)
		end
	end)
end

function GeneratorController:destroy()
	bodyTrove:destroy()
	trove:destroy()
end

Registry.register("GeneratorController", GeneratorController)

return GeneratorController
