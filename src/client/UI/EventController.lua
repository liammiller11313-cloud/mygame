--!nonstrict
--[[
	EventController — the banner that says something is happening, and the rain.

	Two jobs, one file, because they are two halves of one moment: the server
	decides an event has started, and this is everything the player sees and
	hears about it.

	── THE BANNER SITS UNDER THE ROUND BLOCK ───────────────────────────────────
	Directly below the clock and the wave pips, because that is where a player
	already looks for "what is the state of this round". It asks WaveController
	for the height of that block rather than hard-coding one — the block reserves
	space for a modifier line whether or not the round has one, and a number
	copied from it here would be a number that stops matching the first time it
	changes.

	It holds for four seconds and goes. The event usually has not: the banner is
	the ANNOUNCEMENT, and what is happening afterwards is the weather, the dark
	and the noise. A permanent bar would be a HUD element competing with the
	thing it is describing.

	── THE RAIN IS DRAWN HERE ──────────────────────────────────────────────────
	Because it has to be. Rain that reads is rain near the camera, and the camera
	is a client-side object — a server-side emitter would either be somewhere
	nobody is or one per player, which is the same thing done four times.

	So the SERVER decides it is raining and publishes that; this draws it. The
	client is told what is true and gets no say in it, which is the same split
	every other system here uses.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attributes = require(Shared.Net.Attributes)
local AudioConfig = require(Shared.Config.AudioConfig)
local EventConfig = require(Shared.Config.EventConfig)
local Registry = require(Shared.Util.Registry)
local Remotes = require(Shared.Net.Remotes)
local Trove = require(Shared.Util.Trove)
local UITheme = require(Shared.Config.UITheme)

local ScaleLayer = require(script.Parent.ScaleLayer)
local TopStack = require(script.Parent.TopStack)
local UiSound = require(script.Parent.UiSound)
local Widgets = require(script.Parent.Widgets)

local COLOR = UITheme.Color
local FONT = UITheme.Font
local LAYOUT = UITheme.Layout
local TEXT = UITheme.TextSize
local GA = Attributes.Game
local ID = EventConfig.Id

local player = Players.LocalPlayer

--[[ Four seconds, as asked for, and it is the right number: long enough to read
     a short line twice and short enough that it is gone before the player has
     to decide whether to keep looking at it. ]]
local HOLD_SECONDS = 4
local FADE_SECONDS = 0.35

local BANNER_WIDTH = 300
local BANNER_HEIGHT = TEXT.Body + 14

--[[ Which events make it rain, and how hard. Fog is not here on purpose: fog is
     a grade on the sky and drawing particles for it as well would be the same
     idea said twice, once badly. ]]
local RAIN = table.freeze({
	[ID.HeavyRain] = 1.0,
	[ID.Thunderstorm] = 1.35,
})

--[[ The volume of rain above the camera, and how far up it starts. Tall enough
     that a drop is on screen for long enough to read as a streak, and wide
     enough that turning does not reveal an edge. ]]
local RAIN_HEIGHT = 40
local RAIN_SPREAD = 34

local EventController = {}

local trove = Trove.new()

local gui: ScreenGui
local banner: CanvasGroup
local bannerLabel: TextLabel

local rainPart: BasePart? = nil
local rainEmitter: ParticleEmitter? = nil
local rainConnection: RBXScriptConnection? = nil

local hideAt = 0

-- ── the banner ──────────────────────────────────────────────────────────────

--[[
	Under everything already at the top of the screen, asked for rather than
	assumed.

	Two numbers, not one. The wave block's height is the obvious half — and on
	its own it puts the banner exactly where the boss bar draws, because that
	anchors to the same reserved top. A Tank and a random event overlapping is
	not a corner case either: the surge is gated to wave 3 and Tanks arrive at
	wave 5, so a banner over a boss health bar was going to happen in most
	rounds that saw both.

	TopStack settles it, and settles the other two cards that draw up here as
	well. The banner takes the LAST slot on purpose: it lives for four seconds,
	and a transient card above the objective line and the clue counter would shove
	both of them down and back up again every time an event fired.
]]
local function bannerY(): number
	return TopStack.top("Event")
end

local function hide()
	hideAt = 0
	if not banner then
		return
	end
	TweenService:Create(banner, TweenInfo.new(FADE_SECONDS), { GroupTransparency = 1 }):Play()
	task.delay(FADE_SECONDS, function()
		--[[ Only if nothing has claimed it since. A second event inside the fade
		     would otherwise be taken down by the first one's timer. ]]
		if banner and hideAt == 0 then
			banner.Visible = false
			TopStack.set("Event", 0)
		end
	end)
end

local function show(name: string)
	if not banner then
		return
	end
	bannerLabel.Text = string.format("\240\159\154\168 RANDOM EVENT \240\159\154\168  %s", string.upper(name))
	TopStack.set("Event", BANNER_HEIGHT)
	banner.Position = UDim2.new(0.5, 0, 0, bannerY())
	banner.Visible = true
	banner.GroupTransparency = 1
	TweenService:Create(banner, TweenInfo.new(FADE_SECONDS), { GroupTransparency = 0 }):Play()

	--[[ An absolute deadline rather than a delayed call, so a second event
	     landing inside the first one's four seconds simply moves the deadline
	     instead of leaving two timers racing to hide the same frame. ]]
	hideAt = os.clock() + HOLD_SECONDS
end

-- ── the rain ────────────────────────────────────────────────────────────────

local function stopRain()
	if rainConnection then
		rainConnection:Disconnect()
		rainConnection = nil
	end
	if rainEmitter then
		--[[ Rate to zero rather than destroyed immediately: the drops already in
		     the air finish falling, and rain that vanishes mid-screen is worse
		     than rain that eases off. ]]
		rainEmitter.Rate = 0
	end
	local part = rainPart
	rainPart = nil
	rainEmitter = nil
	if part then
		task.delay(2, function()
			part:Destroy()
		end)
	end
end

local function startRain(strength: number)
	stopRain()

	local camera = Workspace.CurrentCamera
	if not camera then
		--[[ No camera yet. Refused rather than parented to nil, which would have
		     made an orphan part and then thrown on the signal below — and this is
		     genuinely reachable, because a client can be told it is raining
		     before its camera exists. The state listener re-runs and rain starts
		     on the next change. ]]
		return
	end

	local part = Instance.new("Part")
	part.Name = "FL_Rain"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = 1
	part.Size = Vector3.new(RAIN_SPREAD, 1, RAIN_SPREAD)
	--[[ Parented to the camera, so it is drawn for this player and replicates to
	     nobody. A Part in Workspace would be a Part every other client also has
	     to stream. ]]
	part.Parent = camera

	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "Drops"
	emitter.Color = ColorSequence.new(Color3.fromRGB(176, 190, 202))
	--[[ Long and thin: a raindrop at speed is a streak, and a round particle
	     falling fast reads as snow. ]]
	emitter.Size = NumberSequence.new(0.06)
	emitter.Squash = NumberSequence.new(14)
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.35),
		NumberSequenceKeypoint.new(0.85, 0.45),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Lifetime = NumberRange.new(0.55, 0.8)
	emitter.Speed = NumberRange.new(78, 96)
	emitter.SpreadAngle = Vector2.new(4, 4)
	emitter.Rate = 900 * strength
	emitter.Acceleration = Vector3.new(0, -40, 0)
	emitter.LightEmission = 0.25
	emitter.LightInfluence = 1
	emitter.Rotation = NumberRange.new(0, 0)
	emitter.ZOffset = 1
	--[[ Straight down. The emitter is aimed by the PART's orientation, and the
	     part is re-aimed every frame below so the rain keeps falling downward
	     however the camera is pointed. ]]
	emitter.EmissionDirection = Enum.NormalId.Bottom
	emitter.Parent = part

	rainPart = part
	rainEmitter = emitter

	--[[
		The rain's own sound, if there is one yet.

		Wired but silent: AudioConfig.Event.RainLoop carries no id, because
		nothing in this project sounds like rain and a wrong loop running for two
		minutes is worse than none. Playing it anyway — guarded on the id being
		non-empty — means the day an id is dropped into that row, rain has sound
		and no code changes.

		On the rain part, so it rides the camera and is the same volume wherever
		the player is standing. Weather is not a thing you can walk away from.
	]]
	local loop = AudioConfig.Event.RainLoop
	if loop.id ~= "" then
		local sound = Instance.new("Sound")
		sound.Name = "FL_RainLoop"
		sound.SoundId = loop.id
		sound.Volume = loop.volume * strength
		sound.Looped = true
		sound.Parent = part
		sound:Play()
	end

	--[[
		Follows the camera in POSITION only, never in rotation: rain that inherits
		the camera's pitch falls sideways the moment you look up.

		On RenderStepped rather than on the camera's own CFrame signal, and
		re-parented every frame if the camera has changed. Both are the same bug:
		Workspace.CurrentCamera is REPLACED, not moved, when a character
		respawns — so a connection bound to the old one stops firing and a part
		parented to it is destroyed with it, and the rain quietly stops halfway
		through an event with nothing in the log. Reading the camera fresh each
		frame is the only version that survives that.
	]]
	rainConnection = RunService.RenderStepped:Connect(function()
		--[[ `rainPart ~= part` means this connection belongs to rain that has
		     already been replaced. stopRain disconnects before it destroys, so
		     this should not happen — and checking is a compare, while being wrong
		     is a write to a destroyed instance. ]]
		local current = Workspace.CurrentCamera
		if not current or rainPart ~= part then
			return
		end
		if part.Parent ~= current then
			part.Parent = current
		end
		part.CFrame = CFrame.new(current.CFrame.Position + Vector3.new(0, RAIN_HEIGHT, 0))
	end)
end

-- ── reacting to the server ──────────────────────────────────────────────────

--[[ Reads the published state rather than the banner's remote, so a player who
     joins into an event already running gets its rain — the banner is a moment
     they missed and the weather is a fact they are standing in. ]]
local function refreshWorld()
	local id = Workspace:GetAttribute(GA.EventId)
	local strength = if typeof(id) == "string" then RAIN[id] else nil
	if strength then
		if not rainPart then
			startRain(strength)
		end
	elseif rainPart then
		stopRain()
	end
end

function EventController:init()
	gui = Instance.new("ScreenGui")
	gui.Name = "FL_Event"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	--[[ The HUD's layer. It belongs with the round block it sits under, and above
	     that is where the menus live — a banner that drew over the pause menu
	     would be a banner nobody could get away from. ]]
	gui.DisplayOrder = UITheme.DisplayOrder.Hud
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = player:WaitForChild("PlayerGui")

	local layer = ScaleLayer.new(gui, "Scaled")

	banner = Instance.new("CanvasGroup")
	banner.Name = "Banner"
	banner.AnchorPoint = Vector2.new(0.5, 0)
	banner.Position = UDim2.new(0.5, 0, 0, bannerY())
	banner.Size = UDim2.fromOffset(BANNER_WIDTH, BANNER_HEIGHT)
	banner.BackgroundColor3 = COLOR.Panel
	banner.BackgroundTransparency = 0.15
	banner.BorderSizePixel = 0
	banner.Visible = false
	banner.Parent = layer

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, LAYOUT.CornerRadius)
	corner.Parent = banner
	--[[ Warning-coloured, and inside the group so the outline fades with the
	     text rather than outliving it. ]]
	Widgets.stroke(banner, COLOR.Warning)

	bannerLabel = Widgets.label(banner, "Text", FONT.Heading, TEXT.Body, COLOR.Warning)
	bannerLabel.Size = UDim2.fromScale(1, 1)
	bannerLabel.TextXAlignment = Enum.TextXAlignment.Center
	bannerLabel.TextYAlignment = Enum.TextYAlignment.Center
	bannerLabel.Text = ""
end

function EventController:start()
	--[[ A Tank can arrive during the banner's four seconds, and the boss bar
	     opening above it moves everything below. Without this the banner would
	     stay where it was posted and the bar would be drawn through it. ]]
	trove:add(TopStack.onChanged(function()
		if banner and banner.Visible then
			banner.Position = UDim2.new(0.5, 0, 0, bannerY())
		end
	end))

	trove:connect(Remotes.Event.RandomEvent.OnClientEvent, function(payload: any)
		if typeof(payload) ~= "table" or typeof(payload.name) ~= "string" then
			return
		end
		show(payload.name)
		UiSound.play(AudioConfig.Event.Siren)
		refreshWorld()
	end)

	--[[ The state, which is what a joiner reads and what an ending event
	     clears. The banner's remote only ever fires for people who were here. ]]
	trove:connect(Workspace:GetAttributeChangedSignal(GA.EventId), refreshWorld)

	--[[ One timer for the banner rather than a delayed call per event. See
	     `show`: a deadline can be moved and a scheduled call cannot be
	     un-scheduled. ]]
	trove:connect(game:GetService("RunService").Heartbeat, function()
		if hideAt > 0 and os.clock() >= hideAt then
			hide()
		end
	end)

	refreshWorld()
end

function EventController:destroy()
	trove:destroy()
	stopRain()
	if gui then
		gui:Destroy()
	end
end

Registry.register("EventController", EventController)

return EventController
