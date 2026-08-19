--!nonstrict
--[[
	HitmarkerController — the proof that the server agreed with you.

	Three marks, and the whole point is that they are distinguishable from
	PERIPHERAL VISION, without reading anything:

	  hit       a small cross,  UITheme.Hitmarker.NormalColor
	  headshot  a larger cross, gold, with the arms pushed outward
	  kill      an X — the same cross rotated by RotationOnKill — in red

	Shape, size and colour all differ, so a player who is looking at the next
	target still knows what happened to the last one. That is worth more than any
	number on screen, which is why the damage numbers are optional and the marks
	are not.

	── WHY ONE MARK PER KIND ───────────────────────────────────────────────────
	A shotgun blast resolves as up to ten separate HitConfirmed events inside one
	frame. Ten stacked hitmarkers is visual noise and ten instances is garbage;
	instead each kind owns exactly one mark that re-punches when it is hit again,
	so a blast lands as a single hard punch. Damage numbers aggregate for the
	same reason: one "112" reads, ten "11"s do not.

	── PERFORMANCE ─────────────────────────────────────────────────────────────
	Every instance is built once at init and recycled. One RenderStepped, no
	allocation per hit, no tweens.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local AudioConfig = require(Shared.Config.AudioConfig)
local Registry = require(Shared.Util.Registry)
local Remotes = require(Shared.Net.Remotes)
local Trove = require(Shared.Util.Trove)
local UITheme = require(Shared.Config.UITheme)

local ScaleLayer = require(script.Parent.ScaleLayer)

local COLOR = UITheme.Color
local FONT = UITheme.Font
local MARK = UITheme.Hitmarker
local TEXT = UITheme.TextSize

-- The punch is over well before the mark is: it snaps to size in the first
-- fifth of its life and spends the rest fading, which is what makes it read as
-- an impact rather than as an animation.
local PUNCH_FRACTION = 0.2

--[[ Hits inside this window are one event as far as the player is concerned —
     a shotgun blast, a burst — and their numbers add together. ]]
local AGGREGATE_WINDOW = 0.14

local NUMBER_POOL = 8
local NUMBER_LIFETIME = 0.85
local NUMBER_DRIFT = 34 -- pixels travelled upward over that lifetime
local NUMBER_SPREAD = 26 -- pixels of scatter, so two numbers never sit exactly on each other

local HitmarkerController = {}

local player = Players.LocalPlayer
local trove = Trove.new()
local random = Random.new()

local gui: ScreenGui
--[[ The scaled content layer. A hitmarker is sized in reference pixels like
     everything else, so a 4K player does not get a speck. ]]
local root: Frame
local marks: { [string]: any } = {}
local numbers: { any } = {}
local numberCursor = 1

local sounds: { [any]: Sound } = {}
local lastPlayed: { [any]: number } = {}

local state = {
	damageNumbers = true,
	lastNumber = nil :: any,
	lastNumberAt = 0,
}

-- ── construction ────────────────────────────────────────────────────────────

--[[ One mark: four bars radiating from centre inside a container that carries
     the rotation and the punch scale. Rotating the container rather than each
     bar is what makes the kill X land as one shape. ]]
local function buildMark(name: string, size: number, color: Color3, rotation: number)
	local holder = Instance.new("Frame")
	holder.Name = name
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	holder.Position = UDim2.fromScale(0.5, 0.5)
	holder.Size = UDim2.fromOffset(size * 2, size * 2)
	holder.BackgroundTransparency = 1
	holder.Rotation = rotation
	holder.Visible = false
	holder.Parent = root

	local scale = Instance.new("UIScale")
	scale.Scale = 1
	scale.Parent = holder

	-- The inner gap keeps the target visible through the middle of the mark.
	local gap = size * 0.35
	local length = size - gap

	local bars: { Frame } = {}
	for index = 1, 4 do
		local bar = Instance.new("Frame")
		bar.Name = "Bar" .. index
		bar.AnchorPoint = Vector2.new(0.5, 0.5)
		bar.BackgroundColor3 = color
		bar.BorderSizePixel = 0
		local vertical = index <= 2
		bar.Size = if vertical
			then UDim2.fromOffset(MARK.Thickness, length)
			else UDim2.fromOffset(length, MARK.Thickness)
		local offset = gap + length * 0.5
		if index == 1 then
			bar.Position = UDim2.new(0.5, 0, 0.5, -offset)
		elseif index == 2 then
			bar.Position = UDim2.new(0.5, 0, 0.5, offset)
		elseif index == 3 then
			bar.Position = UDim2.new(0.5, -offset, 0.5, 0)
		else
			bar.Position = UDim2.new(0.5, offset, 0.5, 0)
		end
		bar.Parent = holder
		bars[index] = bar
	end

	return {
		holder = holder,
		scale = scale,
		bars = bars,
		duration = MARK.Duration,
		elapsed = math.huge,
	}
end

local function buildNumbers()
	for index = 1, NUMBER_POOL do
		local label = Instance.new("TextLabel")
		label.Name = "Damage" .. index
		label.AnchorPoint = Vector2.new(0.5, 0.5)
		label.BackgroundTransparency = 1
		label.Font = FONT.Numeric
		label.TextSize = TEXT.Body
		label.TextColor3 = COLOR.TextPrimary
		label.TextStrokeTransparency = 0.4
		label.TextStrokeColor3 = COLOR.Background
		label.Size = UDim2.fromOffset(90, 20)
		label.Visible = false
		label.Text = ""
		label.Parent = root
		numbers[index] = {
			label = label,
			elapsed = math.huge,
			total = 0,
			originX = 0,
			originY = 0,
		}
	end
end

local function build()
	gui = Instance.new("ScreenGui")
	gui.Name = "FL_Hitmarkers"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = UITheme.DisplayOrder.Hitmarker
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = player:WaitForChild("PlayerGui")
	trove:add(gui)

	root = ScaleLayer.new(gui, "Scaled")

	marks.Hit = buildMark("Hit", MARK.Size, MARK.NormalColor, 0)
	marks.Headshot = buildMark("Headshot", MARK.HeadshotSize, MARK.HeadshotColor, 0)
	marks.Kill = buildMark("Kill", MARK.KillSize, MARK.KillColor, MARK.RotationOnKill)
	marks.Kill.duration = MARK.KillDuration

	buildNumbers()
end

-- ── audio ───────────────────────────────────────────────────────────────────

--[[
	UI hitmarker sounds are 2D and belong to this client alone, so they are
	created here rather than routed through AudioService (which is server-side
	and spatial). Every id in AudioConfig ships empty, so this is silent until
	somebody fills the bank in — never an error, exactly as the config promises.
]]
local function playUi(definition: any)
	if not AudioConfig.isConfigured(definition) then
		return
	end
	local now = os.clock()
	if now - (lastPlayed[definition] or 0) < AudioConfig.Mix.MinRetriggerInterval then
		return
	end
	lastPlayed[definition] = now

	local sound = sounds[definition]
	if not sound then
		sound = Instance.new("Sound")
		sound.Name = "FL_UI"
		sound.SoundId = definition.id
		sound.Volume = definition.volume * AudioConfig.Mix.MasterVolume
		sound.Parent = SoundService
		sounds[definition] = sound
		trove:add(sound)
	end
	sound.PlaybackSpeed = random:NextNumber(definition.pitchMin, definition.pitchMax)
	sound.TimePosition = 0
	sound:Play()
end

-- ── marks ───────────────────────────────────────────────────────────────────

local function punch(mark: any)
	mark.elapsed = 0
	mark.holder.Visible = true
	mark.scale.Scale = MARK.ScalePunch
	for _, bar in mark.bars do
		bar.BackgroundTransparency = 0
	end
end

--[[ Where a damage number starts: on the target if it is on screen, at the
     crosshair if the camera cannot see the hit (a pierced body, a hit behind a
     corner). Never off-screen, where it would silently cost the player their
     only readout of what the shot did. ]]
--[[ Where a damage number goes, in LAYER pixels rather than screen pixels.

     WorldToViewportPoint answers in real hardware pixels, and the numbers are
     drawn inside the scale layer, where an offset is multiplied by the layer's
     factor before it reaches the screen. Handing the layer a raw viewport point
     would put the number at 1.35x its position on a 4K display — off the bottom
     right of the screen for anything near the edge. Dividing here converts once,
     at the boundary, so everything downstream stays in one coordinate space. ]]
local function screenPointFor(position: Vector3?): (number, number)
	local camera = Workspace.CurrentCamera
	local factor = ScaleLayer.getFactor()

	if position and camera then
		local point, onScreen = camera:WorldToViewportPoint(position)
		if onScreen then
			return point.X / factor, point.Y / factor
		end
	end
	local viewport = camera and camera.ViewportSize or Vector2.new(1920, 1080)
	return viewport.X * 0.5 / factor, viewport.Y * 0.5 / factor
end

local function pushNumber(damage: number, position: Vector3?)
	if not state.damageNumbers or damage <= 0 then
		return
	end

	local now = os.clock()
	local recent = state.lastNumber
	if recent and now - state.lastNumberAt < AGGREGATE_WINDOW and recent.elapsed < NUMBER_LIFETIME then
		-- Same burst: add to the number already on screen and re-punch it.
		recent.total += damage
		recent.elapsed = 0
		recent.label.Text = tostring(math.floor(recent.total + 0.5))
		state.lastNumberAt = now
		return
	end

	local entry = numbers[numberCursor]
	numberCursor = (numberCursor % NUMBER_POOL) + 1

	local x, y = screenPointFor(position)
	entry.total = damage
	entry.elapsed = 0
	entry.originX = x + random:NextNumber(-NUMBER_SPREAD, NUMBER_SPREAD)
	entry.originY = y + random:NextNumber(-NUMBER_SPREAD * 0.5, NUMBER_SPREAD * 0.5)
	entry.label.Text = tostring(math.floor(damage + 0.5))
	entry.label.TextColor3 = COLOR.TextPrimary
	entry.label.Visible = true

	state.lastNumber = entry
	state.lastNumberAt = now
end

local function update(dt: number)
	for _, mark in marks do
		if mark.elapsed < mark.duration then
			mark.elapsed += dt
			local alpha = math.clamp(mark.elapsed / mark.duration, 0, 1)

			-- Scale collapses over the first fifth, transparency runs the whole
			-- way: the mark is at full size and already fading by the time the
			-- eye finds it, which is what makes it feel like a strike.
			local punchAlpha = math.min(alpha / PUNCH_FRACTION, 1)
			mark.scale.Scale = MARK.ScalePunch + (1 - MARK.ScalePunch) * punchAlpha
			for _, bar in mark.bars do
				bar.BackgroundTransparency = alpha
			end

			if alpha >= 1 then
				mark.holder.Visible = false
			end
		end
	end

	for _, entry in numbers do
		if entry.elapsed < NUMBER_LIFETIME then
			entry.elapsed += dt
			local alpha = math.clamp(entry.elapsed / NUMBER_LIFETIME, 0, 1)
			entry.label.Position = UDim2.fromOffset(entry.originX, entry.originY - NUMBER_DRIFT * alpha)
			entry.label.TextTransparency = alpha * alpha
			entry.label.TextStrokeTransparency = 0.4 + alpha * 0.6
			if alpha >= 1 then
				entry.label.Visible = false
				if state.lastNumber == entry then
					state.lastNumber = nil
				end
			end
		end
	end
end

-- ── public API ──────────────────────────────────────────────────────────────

--[[ Shows the mark that fits what happened. A kill outranks a headshot, because
     the kill is the fact the player needs; the headshot sound still carries the
     region. ]]
function HitmarkerController:mark(killed: boolean, isHeadshot: boolean, damage: number?, position: Vector3?)
	if killed then
		punch(marks.Kill)
	elseif isHeadshot then
		punch(marks.Headshot)
	else
		punch(marks.Hit)
	end

	-- AudioConfig.UI has no kill-specific cue, so a headshot kill still sounds
	-- like a headshot; that is the region tell and it is the one worth keeping.
	playUi(if isHeadshot then AudioConfig.UI.HeadshotMarker else AudioConfig.UI.Hitmarker)

	if damage then
		pushNumber(damage, position)
	end
end

function HitmarkerController:setDamageNumbersEnabled(value: boolean)
	state.damageNumbers = value
	if not value then
		for _, entry in numbers do
			entry.elapsed = math.huge
			entry.label.Visible = false
		end
		state.lastNumber = nil
	end
end

function HitmarkerController:areDamageNumbersEnabled(): boolean
	return state.damageNumbers
end

-- ── lifecycle ───────────────────────────────────────────────────────────────

function HitmarkerController:init()
	build()
end

function HitmarkerController:start()
	trove:connect(Remotes.Event.HitConfirmed.OnClientEvent, function(payload: any)
		if typeof(payload) ~= "table" then
			return
		end
		HitmarkerController:mark(
			payload.killed == true,
			payload.isHeadshot == true,
			if typeof(payload.damage) == "number" then payload.damage else nil,
			if typeof(payload.position) == "Vector3" then payload.position else nil
		)
	end)

	trove:connect(RunService.RenderStepped, update)
end

function HitmarkerController:destroy()
	trove:destroy()
end

Registry.register("HitmarkerController", HitmarkerController)

return HitmarkerController
