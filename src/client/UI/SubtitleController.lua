--!nonstrict
--[[
	SubtitleController — survivor callouts and captions, one line at a time.

	In Left 4 Dead the callouts ARE information: "reloading", "pills here",
	"Hunter!". A caption that is unreadable because a second one landed on top of
	it has failed at the only job it has, so this is a strict queue — one line on
	screen, the rest waiting, never two at once.

	The speaker's name is drawn in that survivor's identity colour, the same
	colour as their HUD panel stripe and their outline through a wall. Three
	places, one colour, no legend needed.

	When callouts stack up (a Boomer landing on the whole team produces four at
	once) each line's dwell shortens toward MIN_DWELL rather than the queue
	playing out in slow motion for eight seconds after the moment has passed.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Registry = require(Shared.Util.Registry)
local Remotes = require(Shared.Net.Remotes)
local Trove = require(Shared.Util.Trove)
local UITheme = require(Shared.Config.UITheme)

local ScaleLayer = require(script.Parent.ScaleLayer)

local COLOR = UITheme.Color
local FONT = UITheme.Font
local LAYOUT = UITheme.Layout
local MOTION = UITheme.Motion
local TEXT = UITheme.TextSize

-- Clear of the item slots along the bottom edge; captions must never cover the
-- one part of the HUD a player checks under pressure.
local BOTTOM_OFFSET = LAYOUT.ScreenMargin + LAYOUT.ItemSlotSize + LAYOUT.ElementGap * 3

--[[
	How wide a caption is allowed to get, and why it is not simply 720.

	The line is centred, and the bottom corners of the HUD are not: survivor
	panels sit in the left one at 214 wide and the ammo readout in the right at
	190 plus its margin. On a desktop a 720-wide line is nowhere near either of
	them. On a landscape phone it is — reference pixels are real pixels over the
	scale factor and the factor floors at 0.75, so a 844-wide screen is 1125
	reference pixels, and a centred 720 reaches into both columns by about ten
	pixels in the one band where their heights overlap.

	Ten pixels of a caption clipping the corner of the ammo count is not a
	disaster. It is also the kind of thing that is invisible in every screenshot
	taken on a monitor and obvious in the one taken on a phone, which is the
	worst way for it to be found.

	So the cap is the room BETWEEN the columns rather than a number: whatever is
	left of the viewport once the wider of the two side panels is subtracted from
	each edge. On anything desktop-shaped that arithmetic is larger than 720 and
	nothing changes at all.
]]
local LINE_WIDTH = 720
local LINE_MIN_WIDTH = 260
local LINE_HEIGHT = 52

local MIN_DWELL = 1.1
local MAX_DWELL = 6.0
local DEFAULT_DWELL = 2.6

-- Past this the queue is stale rather than backed up: the fight has moved on.
local MAX_QUEUE = 4

local SubtitleController = {}

local player = Players.LocalPlayer
local trove = Trove.new()

local gui: ScreenGui
-- The scaled content layer. See Client/UI/ScaleLayer.
local root: Frame
local line: TextLabel

local queue: { { speaker: string, text: string, dwell: number } } = {}

--[[ The subtitles setting. On by default: a player who never opens the options
     panel should still be told what the Boomer just did. ]]
local enabled = true

local state = {
	cinematic = false,
	remaining = 0,
	alpha = 0,
	target = 0,
	current = nil :: any,
}

local function hex(color: Color3): string
	return string.format(
		"#%02X%02X%02X",
		math.floor(color.R * 255 + 0.5),
		math.floor(color.G * 255 + 0.5),
		math.floor(color.B * 255 + 0.5)
	)
end

--[[ The speaker's identity colour, matched by name against the roster. A
     non-player speaker (a radio, the level itself) gets the amber accent, which
     is the game's own voice. ]]
local function speakerColor(speaker: string): Color3
	local hud = Registry.find("HudController")
	if hud and typeof(hud.getSurvivorColor) == "function" then
		for _, other in Players:GetPlayers() do
			if other.Name == speaker or other.DisplayName == speaker then
				local ok, color = pcall(hud.getSurvivorColor, hud, other)
				if ok and typeof(color) == "Color3" then
					return color
				end
			end
		end
	end
	return COLOR.Accent
end

local function compose(speaker: string, text: string): string
	if speaker == "" then
		return string.format('<font color="%s">%s</font>', hex(COLOR.TextPrimary), text)
	end
	return string.format(
		'<font color="%s">%s</font>  <font color="%s">%s</font>',
		hex(speakerColor(speaker)),
		string.upper(speaker),
		hex(COLOR.TextPrimary),
		text
	)
end

--[[ Re-measured whenever a caption is drawn rather than fixed at build. A phone
     rotates and a window resizes, and this costs two divisions on the frames
     something is being said. ]]
local function lineWidth(): number
	local camera = Workspace.CurrentCamera
	local factor = ScaleLayer.getFactor()
	if not camera or factor <= 0 then
		return LINE_WIDTH
	end
	local room = camera.ViewportSize.X / factor
	--[[ The wider of the two columns, applied to BOTH edges, because the line is
	     centred and cannot be kept off one side without being kept off the
	     other. ]]
	local side = math.max(LAYOUT.SurvivorPanelWidth, LAYOUT.AmmoPanelWidth + LAYOUT.ScreenMargin)
	return math.max(math.min(LINE_WIDTH, room - side * 2), LINE_MIN_WIDTH)
end

local function advance()
	local entry = table.remove(queue, 1)
	state.current = entry
	if not entry then
		state.target = 0
		state.remaining = 0
		return
	end

	-- A backed-up queue plays faster; the line still reads, but the batch clears
	-- before the situation that produced it is over.
	local pressure = math.min(#queue, MAX_QUEUE) / MAX_QUEUE
	state.remaining = entry.dwell - (entry.dwell - MIN_DWELL) * pressure
	line.Text = compose(entry.speaker, entry.text)
	-- Sized per caption; see lineWidth for why it is not a constant.
	line.Size = UDim2.fromOffset(lineWidth(), LINE_HEIGHT)
	state.target = 1
end

local function update(dt: number)
	if state.cinematic then
		state.target = 0
	elseif state.current then
		state.remaining -= dt
		if state.remaining <= 0 then
			state.target = 0
			if state.alpha < 0.02 then
				state.current = nil
			end
		end
	elseif #queue > 0 and state.alpha < 0.02 then
		advance()
	end

	local speed = if state.target > state.alpha then MOTION.FastIn else MOTION.FastOut
	state.alpha += (state.target - state.alpha) * math.min(dt / speed, 1)
	if math.abs(state.target - state.alpha) < 0.01 then
		state.alpha = state.target
		if state.alpha == 0 and state.current and state.remaining <= 0 then
			state.current = nil
		end
	end

	local visible = state.alpha > 0.01
	if line.Visible ~= visible then
		line.Visible = visible
	end
	if visible then
		line.TextTransparency = 1 - state.alpha
		line.TextStrokeTransparency = 0.5 + (1 - state.alpha) * 0.5
	end
end

local function build()
	gui = Instance.new("ScreenGui")
	gui.Name = "FL_Subtitles"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = UITheme.DisplayOrder.Subtitle
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = player:WaitForChild("PlayerGui")
	trove:add(gui)

	root = ScaleLayer.new(gui, "Scaled")

	line = Instance.new("TextLabel")
	line.Name = "Line"
	line.AnchorPoint = Vector2.new(0.5, 1)
	line.Position = UDim2.new(0.5, 0, 1, -BOTTOM_OFFSET)
	line.Size = UDim2.fromOffset(lineWidth(), LINE_HEIGHT)
	line.BackgroundTransparency = 1
	line.Font = FONT.Body
	line.TextSize = TEXT.Body
	line.TextColor3 = COLOR.TextPrimary
	line.TextXAlignment = Enum.TextXAlignment.Center
	line.TextYAlignment = Enum.TextYAlignment.Bottom
	line.TextWrapped = true
	line.RichText = true
	-- Captions are read against gunfire, muzzle flash and blood. The stroke is
	-- what keeps them legible when the frame behind them is white for a moment.
	line.TextStrokeColor3 = COLOR.Background
	line.TextStrokeTransparency = 0.5
	line.Visible = false
	line.Text = ""
	line.Parent = root
end

-- ── public API ──────────────────────────────────────────────────────────────

--[[ Queues a caption. `speaker` may be empty for a line with no owner. ]]
function SubtitleController:say(speaker: string, text: string, duration: number?)
	if not enabled or typeof(text) ~= "string" or text == "" then
		return
	end
	local dwell = if typeof(duration) == "number" and duration > 0 then duration else DEFAULT_DWELL
	table.insert(queue, {
		speaker = if typeof(speaker) == "string" then speaker else "",
		text = text,
		dwell = math.clamp(dwell, MIN_DWELL, MAX_DWELL),
	})
	while #queue > MAX_QUEUE do
		table.remove(queue, 1)
	end
end

function SubtitleController:clear()
	table.clear(queue)
	state.current = nil
	state.remaining = 0
	state.target = 0
end

function SubtitleController:setCinematic(value: boolean)
	state.cinematic = value
	if value then
		self:clear()
	end
end

--[[
	Turns captions off for a player who does not want them.

	Clears what is on screen as well as refusing what comes next: a caption
	already up when the setting is switched off would otherwise sit there for its
	full dwell, which reads as the switch not working.
]]
function SubtitleController:setEnabled(value: boolean)
	enabled = value == true
	if not enabled then
		self:clear()
	end
end

function SubtitleController:isEnabled(): boolean
	return enabled
end

function SubtitleController:isBusy(): boolean
	return state.current ~= nil or #queue > 0
end

-- ── lifecycle ───────────────────────────────────────────────────────────────

function SubtitleController:init()
	build()
end

function SubtitleController:start()
	trove:connect(Remotes.Event.Subtitle.OnClientEvent, function(payload: any)
		if typeof(payload) ~= "table" then
			return
		end
		SubtitleController:say(
			tostring(payload.speaker or ""),
			tostring(payload.text or ""),
			if typeof(payload.duration) == "number" then payload.duration else nil
		)
	end)

	trove:connect(RunService.RenderStepped, update)
end

function SubtitleController:destroy()
	trove:destroy()
end

Registry.register("SubtitleController", SubtitleController)

return SubtitleController
