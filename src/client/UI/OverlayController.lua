--!nonstrict
--[[
	OverlayController — everything the screen does TO the player.

	Six jobs, all of them full-frame, all of them driven by state the server
	already publishes:

	  1. HEALTH VIGNETTE   the edges redden below UITheme.Vignette.HurtStart and
	                       pulse under it, capped at MaxIntensity
	  2. DOWNED / DEAD     desaturation, a heavy vignette, and the one line that
	                       matters ("WAITING FOR HELP"), plus the black-and-white
	                       warning that the next down is the last one — which now
	                       drains the world while the player is still standing in
	                       it, because that is when it is worth knowing
	  3. ROUND CARDS       team wipe and victory, from RoundStateChanged
	  4. THE HANDOFF       RoundEnded lands the result card, then gets out of the
	                       way for MainMenuController
	  5. SCREEN EFFECTS    Boomer bile, blood on the lens, the adrenaline shift
	  6. DAMAGE ARROWS     which direction that came from, in screen space
	  7. PERSONAL GAMMA    the brightness setting, as a client-side grade — see
	                       setBrightness, and GameConfig.Flashlight for why a
	                       game that ends in the dark needs one

	── RESTRAINT ───────────────────────────────────────────────────────────────
	A full red wash at the exact moment the player most needs to read the screen
	is a failure, not feedback. The vignette lives at the edges, the bile leaves
	the middle of the frame usable, and the blood is droplets rather than a
	sheet. Every ceiling here comes from UITheme.Vignette and
	GoreConfig.ScreenBlood; none of them are decorative.

	── DESATURATION ────────────────────────────────────────────────────────────
	Roblox GUIs cannot desaturate what is behind them, so the grey of being
	downed comes from a ColorCorrectionEffect this controller owns. Nothing else
	in the game touches Lighting (PlaceholderFactory lights the level with
	fixtures on purpose), so the effect is safe to own outright.

	── PERFORMANCE ─────────────────────────────────────────────────────────────
	One RenderStepped. Every droplet, blob and arrow is pooled at init and
	recycled; a horde beating on the team allocates nothing here.
]]

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attributes = require(Shared.Net.Attributes)
local Enums = require(Shared.Enums)
local GameConfig = require(Shared.Config.GameConfig)
local GameModeConfig = require(Shared.Config.GameModeConfig)
local GoreConfig = require(Shared.Config.GoreConfig)
local Registry = require(Shared.Util.Registry)
local Remotes = require(Shared.Net.Remotes)
local Trove = require(Shared.Util.Trove)
local UITheme = require(Shared.Config.UITheme)

local ScaleLayer = require(script.Parent.ScaleLayer)

local COLOR = UITheme.Color
local FONT = UITheme.Font
local INDICATOR = UITheme.DamageIndicator
local LAYOUT = UITheme.Layout
local MOTION = UITheme.Motion
local TEXT = UITheme.TextSize
local VIGNETTE = UITheme.Vignette

local GA = Attributes.Game
local PA = Attributes.Player
local ROUND = Enums.RoundState
local STATE = Enums.SurvivorState

local SCREEN_BLOOD = GoreConfig.ScreenBlood
local MAX_HEALTH = GameConfig.Survivor.MaxHealth

-- Effect names carried by Remotes.Event.ScreenEffect. SurvivorService sends
-- "Adrenaline"; Boomer.lua sends "Bile". Anything else is ignored in silence.
local EFFECT = table.freeze({
	Bile = "Bile",
	Adrenaline = "Adrenaline",
	Blood = "Blood",
})

-- How fast the full-frame values chase their targets. Fast enough to feel like
-- a reaction, slow enough that a stream of small hits does not strobe.
local VIGNETTE_CHASE = 7
local GRADE_CHASE = 3.5

-- A hit punches the vignette briefly on top of whatever the health level says.
local HIT_FLASH = 0.28
local HIT_FLASH_TIME = 0.35

local CARD_HOLD = 2.6
local CARD_SLIDE = 26 -- pixels the card title drifts as it fades in

local BILE_BLOBS = 9

--[[
	Standing in black and white.

	The whole L4D health model builds toward this moment — two incaps down, the
	next one is fatal, and the player is still on their feet — and until now the
	screen said nothing about it unless you were already on the floor. It does
	now: the colour drains out of the world while you are still walking around in
	it. Short of the -1 that being downed uses, so the two never read as the same
	state. On your feet the world is draining; on the floor it is already gone.
]]
local STANDING_BW_SATURATION = -0.85
local STANDING_BW_BRIGHTNESS = -0.04

--[[
	How long the result card gets before the screen is handed over.

	MainMenuController's scoreboard is already waiting behind this — it takes
	RoundEnded itself and returns everyone to the lobby on
	Matchmaking.PostRoundDuration — so this is a beat, not a screen: long enough
	for the card to land, short enough to leave the scoreboard nearly all of that
	window.
]]
local HANDOFF_DELAY = CARD_HOLD

local OverlayController = {}

local player = Players.LocalPlayer
local trove = Trove.new()
local random = Random.new()

local vignetteGui: ScreenGui
local overlayGui: ScreenGui
--[[ The scaled content layer, on the overlay ScreenGui only. The vignette and
     the fade are full-bleed washes with no pixel offsets in them — there is
     nothing there for a scale to correct, and a fade that has to end on solid
     black is safest as a plain full-screen frame. ]]
local overlayRoot: Frame
local edges: { Frame } = {}
local scrim: Frame
local droplets: { any } = {}
local dropletCursor = 1
local bileLayer: Frame
local bileBlobs: { Frame } = {}
local tintLayer: Frame
local grade: ColorCorrectionEffect

--[[ The player's own brightness, as a SECOND grade. Separate from `grade` above
     because that one is state — downed, black-and-white, bile — and is switched
     off the moment the state clears; this one is a preference and has to survive
     that. See setBrightness. ]]
local personalGrade: ColorCorrectionEffect

local indicators: { any } = {}
local indicatorCursor = 1

local statusPanel: Frame
local statusTitle: TextLabel
local statusLine: TextLabel
local statusWarning: TextLabel
local statusProgress: Frame
local statusProgressFill: Frame

local cardPanel: Frame
local cardBack: Frame
local cardTitle: TextLabel
local cardSubtitle: TextLabel

local fadeGui: ScreenGui
local fadeLayer: Frame

--[[
	The player's gore setting, as it applies to the lens.

	Blood on the screen is drawn here rather than by GoreController — this owns
	the layer the vignette and the bile wash composite on — so turning gore off
	has to reach this file too, or the setting removes the gibs and leaves the
	player looking through a red smear.

	Only the blood. The damage vignette is not gore, it is the readout that says
	how close to dead you are, and it stays whatever this is set to.
]]
local bloodEnabled = true

local state = {
	survivorState = STATE.Spectating,
	blackAndWhite = false,
	healthFraction = 1,

	vignette = 0,
	vignetteApplied = -1,
	hitFlashUntil = 0,

	bileUntil = 0,
	bileDuration = SCREEN_BLOOD.BoomerBileFadeTime,
	adrenalineUntil = 0,
	adrenalineDuration = 1,

	saturation = 0,
	tint = Color3.new(1, 1, 1),
	brightness = 0,

	card = nil :: any,
	cardPhase = "idle",
	cardClock = 0,
	cardAlpha = 0,
	cinematic = false,

	roundState = ROUND.Lobby,

	fade = 0,
	fadeTarget = 0,
	fadeSpeed = 1 / MOTION.Cinematic,
}

--[[ Bumped on every round-state edge. A handoff scheduled for the round that
     just ended must not fire into the one that already started. ]]
local handoffGeneration = 0

-- ── construction ────────────────────────────────────────────────────────────

local function newFrame(parent: Instance, name: string, color: Color3, transparency: number): Frame
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.BackgroundColor3 = color
	frame.BackgroundTransparency = transparency
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
	label.Font = font
	label.TextSize = size
	label.TextColor3 = color
	label.TextXAlignment = Enum.TextXAlignment.Center
	label.Text = ""
	label.Parent = parent
	return label
end

--[[ One edge of the vignette: a band of Vignette.Color whose gradient runs from
     opaque at the screen edge to nothing a third of the way in. Four bands read
     as a ring and cost four frames; an image would cost an asset upload and a
     texture fetch. ]]
local function buildEdge(name: string, size: UDim2, position: UDim2, anchor: Vector2, rotation: number)
	local frame = newFrame(vignetteGui, name, VIGNETTE.Color, 1)
	frame.Size = size
	frame.Position = position
	frame.AnchorPoint = anchor

	local gradient = Instance.new("UIGradient")
	gradient.Rotation = rotation
	gradient.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.5, 0.7),
		NumberSequenceKeypoint.new(1, 1),
	})
	gradient.Parent = frame

	table.insert(edges, frame)
end

local function buildVignette()
	buildEdge("Top", UDim2.fromScale(1, 0.34), UDim2.fromScale(0, 0), Vector2.new(0, 0), 90)
	buildEdge("Bottom", UDim2.fromScale(1, 0.34), UDim2.fromScale(0, 1), Vector2.new(0, 1), 270)
	buildEdge("Left", UDim2.fromScale(0.26, 1), UDim2.fromScale(0, 0), Vector2.new(0, 0), 0)
	buildEdge("Right", UDim2.fromScale(0.26, 1), UDim2.fromScale(1, 0), Vector2.new(1, 0), 180)
end

--[[
	GRIT — the permanent, always-on layer that makes the game feel like a horror
	game rather than a shooting range with zombies in it.

	Two things, both deliberately almost invisible:

	  A DARK VIGNETTE at the corners, separate from the red damage one above. It
	  is on at all times at a level you cannot consciously see, and it does the
	  same job a camera lens does — it pulls the eye to the centre of the frame
	  and makes the edges of the screen feel like the edges of what you can see,
	  rather than where the monitor stops.

	  A SLOW BREATHE on that vignette, a few percent over several seconds. Static
	  darkness reads as a UI element; darkness that moves reads as the room.

	Both are capped low on purpose. The moment a player notices this layer, it has
	stopped being atmosphere and started being something between them and the
	horde — and the whole design rule here is that readability beats mood.
]]
local GRIT_BASE = 0.30 -- resting opacity of the corner darkening
local GRIT_BREATHE = 0.05 -- how far it drifts either side of that
local GRIT_BREATHE_RATE = 0.22 -- cycles per second: slow enough to feel like breath
local GRIT_COLOR = Color3.fromRGB(4, 3, 3)

local gritEdges: { Frame } = {}

local function buildGritEdge(name: string, size: UDim2, position: UDim2, anchor: Vector2, rotation: number)
	local frame = newFrame(vignetteGui, name, GRIT_COLOR, 1 - GRIT_BASE)
	frame.Size = size
	frame.Position = position
	frame.AnchorPoint = anchor
	-- Under the damage vignette and everything else: this is the floor of the
	-- stack, not a thing that ever covers information.
	frame.ZIndex = 0

	local gradient = Instance.new("UIGradient")
	gradient.Rotation = rotation
	gradient.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.55, 0.82),
		NumberSequenceKeypoint.new(1, 1),
	})
	gradient.Parent = frame

	table.insert(gritEdges, frame)
end

local function buildGrit()
	buildGritEdge("GritTop", UDim2.fromScale(1, 0.30), UDim2.fromScale(0, 0), Vector2.new(0, 0), 90)
	buildGritEdge("GritBottom", UDim2.fromScale(1, 0.34), UDim2.fromScale(0, 1), Vector2.new(0, 1), 270)
	buildGritEdge("GritLeft", UDim2.fromScale(0.30, 1), UDim2.fromScale(0, 0), Vector2.new(0, 0), 0)
	buildGritEdge("GritRight", UDim2.fromScale(0.30, 1), UDim2.fromScale(1, 0), Vector2.new(1, 0), 180)
end

--[[ One sine, four writes, and only when the value actually moved enough to be
     worth the property assignment. ]]
local gritApplied = -1

local function updateGrit(now: number)
	local level = GRIT_BASE + math.sin(now * math.pi * 2 * GRIT_BREATHE_RATE) * GRIT_BREATHE
	if math.abs(level - gritApplied) < 0.004 then
		return
	end
	gritApplied = level
	local transparency = 1 - level
	for _, edge in gritEdges do
		edge.BackgroundTransparency = transparency
	end
end

local function buildBlood()
	for index = 1, SCREEN_BLOOD.MaxDroplets do
		local drop = newFrame(vignetteGui, "Droplet" .. index, COLOR.Blood, 1)
		drop.AnchorPoint = Vector2.new(0.5, 0.5)
		drop.Size = UDim2.fromOffset(30, 30)
		drop.Visible = false

		local shape = Instance.new("UICorner")
		-- A full-radius corner on a non-square frame gives a lozenge, which is
		-- what a droplet on glass actually looks like.
		shape.CornerRadius = UDim.new(1, 0)
		shape.Parent = drop

		droplets[index] = { frame = drop, age = math.huge, peak = 0 }
	end
end

local function buildBile()
	bileLayer = newFrame(vignetteGui, "Bile", COLOR.Bile, 1)
	bileLayer.Size = UDim2.fromScale(1, 1)
	bileLayer.Visible = false

	for index = 1, BILE_BLOBS do
		local blob = newFrame(bileLayer, "Blob" .. index, COLOR.Bile, 0.1)
		blob.AnchorPoint = Vector2.new(0.5, 0.5)
		local size = random:NextNumber(0.18, 0.42)
		blob.Size = UDim2.fromScale(size, size * random:NextNumber(0.6, 1.2))
		blob.Position = UDim2.fromScale(random:NextNumber(0.05, 0.95), random:NextNumber(0.05, 0.95))
		blob.Rotation = random:NextNumber(0, 180)

		local shape = Instance.new("UICorner")
		shape.CornerRadius = UDim.new(1, 0)
		shape.Parent = blob

		bileBlobs[index] = blob
	end
end

local function buildIndicators()
	for index = 1, INDICATOR.MaxSimultaneous do
		local arrow = newFrame(overlayRoot, "Damage" .. index, INDICATOR.Color, 1)
		arrow.AnchorPoint = Vector2.new(0.5, 0.5)
		arrow.Size = UDim2.fromOffset(INDICATOR.Width, INDICATOR.Height)
		arrow.Visible = false

		-- Faded at both ends so the bar reads as an arc of the damage ring
		-- rather than as a floating rectangle.
		local gradient = Instance.new("UIGradient")
		gradient.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.5, 0),
			NumberSequenceKeypoint.new(1, 1),
		})
		gradient.Parent = arrow

		indicators[index] = { frame = arrow, position = Vector3.zero, age = math.huge }
	end
end

local function buildStatus()
	statusPanel = newFrame(overlayRoot, "Status", COLOR.Background, 1)
	statusPanel.AnchorPoint = Vector2.new(0.5, 0.5)
	statusPanel.Position = UDim2.fromScale(0.5, 0.58)
	statusPanel.Size = UDim2.fromOffset(760, 120)
	statusPanel.Visible = false

	--[[ The stencil face, scoped to the one line that says what has happened.
	     YOU ARE DEAD is the most dramatic thing this interface ever says and it
	     was set in the same grotesque as a settings row. ]]
	statusTitle = newLabel(statusPanel, "Title", FONT.Sign, TEXT.Heading, COLOR.TextPrimary)
	statusTitle.Position = UDim2.fromScale(0, 0)
	statusTitle.Size = UDim2.new(1, 0, 0, 38)

	statusLine = newLabel(statusPanel, "Line", FONT.Body, TEXT.Body, COLOR.TextSecondary)
	statusLine.Position = UDim2.new(0, 0, 0, 42)
	statusLine.Size = UDim2.new(1, 0, 0, 24)

	statusWarning = newLabel(statusPanel, "Warning", FONT.Heading, TEXT.Body, COLOR.Danger)
	statusWarning.Position = UDim2.new(0, 0, 0, 70)
	statusWarning.Size = UDim2.new(1, 0, 0, 24)

	--[[ Somebody is picking you up. This is the single most important thing a
	     downed player can know, and it is the difference between holding still
	     and crawling away from the person helping. ]]
	statusProgress = newFrame(statusPanel, "Revive", COLOR.Background, 0.3)
	statusProgress.AnchorPoint = Vector2.new(0.5, 0)
	statusProgress.Position = UDim2.new(0.5, 0, 0, 100)
	statusProgress.Size = UDim2.fromOffset(240, 4)
	statusProgress.Visible = false

	statusProgressFill = newFrame(statusProgress, "Fill", COLOR.AccentBright, 0)
	statusProgressFill.Size = UDim2.new(0, 0, 1, 0)
end

local function buildCard()
	cardPanel = newFrame(overlayRoot, "Card", COLOR.Background, 1)
	cardPanel.Size = UDim2.fromScale(1, 1)
	cardPanel.Visible = false

	cardBack = newFrame(cardPanel, "Scrim", COLOR.Background, 1)
	cardBack.Size = UDim2.fromScale(1, 1)

	-- showCard sets the font per card; this is only the resting state.
	cardTitle = newLabel(cardPanel, "Title", FONT.Display, TEXT.Title, COLOR.TextPrimary)
	cardTitle.AnchorPoint = Vector2.new(0.5, 1)
	cardTitle.Position = UDim2.fromScale(0.5, 0.5)
	cardTitle.Size = UDim2.new(0, 1100, 0, TEXT.Title + 12)
	cardTitle.TextTransparency = 1

	cardSubtitle = newLabel(cardPanel, "Subtitle", FONT.Heading, TEXT.Large, COLOR.TextSecondary)
	cardSubtitle.AnchorPoint = Vector2.new(0.5, 0)
	cardSubtitle.Position = UDim2.new(0.5, 0, 0.5, LAYOUT.ElementGap * 2)
	cardSubtitle.Size = UDim2.new(0, 900, 0, 32)
	cardSubtitle.TextTransparency = 1
end

local function build()
	vignetteGui = Instance.new("ScreenGui")
	vignetteGui.Name = "FL_Vignette"
	vignetteGui.ResetOnSpawn = false
	vignetteGui.IgnoreGuiInset = true
	vignetteGui.DisplayOrder = UITheme.DisplayOrder.Vignette
	vignetteGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	vignetteGui.Parent = player:WaitForChild("PlayerGui")
	trove:add(vignetteGui)

	overlayGui = Instance.new("ScreenGui")
	overlayGui.Name = "FL_Overlay"
	overlayGui.ResetOnSpawn = false
	overlayGui.IgnoreGuiInset = true
	overlayGui.DisplayOrder = UITheme.DisplayOrder.Overlay
	overlayGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	overlayGui.Parent = player:WaitForChild("PlayerGui")
	trove:add(overlayGui)

	overlayRoot = ScaleLayer.new(overlayGui, "Scaled")

	--[[ The fade owns its own layer above everything, including whatever the main
	     menu draws: it is the seam between the round and the menu, and a seam
	     something else can appear through is not a seam. ]]
	fadeGui = Instance.new("ScreenGui")
	fadeGui.Name = "FL_Fade"
	fadeGui.ResetOnSpawn = false
	fadeGui.IgnoreGuiInset = true
	fadeGui.DisplayOrder = UITheme.DisplayOrder.Fade
	fadeGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	fadeGui.Parent = player:WaitForChild("PlayerGui")
	trove:add(fadeGui)

	fadeLayer = newFrame(fadeGui, "Black", COLOR.Background, 1)
	fadeLayer.Size = UDim2.fromScale(1, 1)
	fadeLayer.Visible = false

	-- Behind the edges: the flat darkening that being downed or dead adds.
	scrim = newFrame(vignetteGui, "Scrim", COLOR.Background, 1)
	scrim.Size = UDim2.fromScale(1, 1)

	buildGrit()
	buildVignette()
	buildBlood()
	buildBile()

	tintLayer = newFrame(vignetteGui, "Tint", COLOR.Accent, 1)
	tintLayer.Size = UDim2.fromScale(1, 1)
	tintLayer.Visible = false

	buildIndicators()
	buildStatus()
	buildCard()

	grade = Instance.new("ColorCorrectionEffect")
	grade.Name = "FL_Overlay"
	grade.Enabled = false
	grade.Saturation = 0
	grade.TintColor = Color3.new(1, 1, 1)
	grade.Parent = Lighting
	trove:add(grade)

	personalGrade = Instance.new("ColorCorrectionEffect")
	personalGrade.Name = "FL_PlayerBrightness"
	personalGrade.Enabled = false
	personalGrade.Parent = Lighting
	trove:add(personalGrade)
end

-- ── vignette and grade ──────────────────────────────────────────────────────

local function refreshHealth()
	local health = math.max(Attributes.get(player, PA.Health, MAX_HEALTH), 0)
	local temp = math.max(Attributes.get(player, PA.TempHealth, 0), 0)
	state.healthFraction = math.clamp((health + temp) / MAX_HEALTH, 0, 1)
end

--[[ The revive clock, as seen by the person on the floor. ]]
local function refreshReviveProgress()
	local downed = state.survivorState == STATE.Incapacitated or state.survivorState == STATE.LedgeHanging
	local progress = if downed then Attributes.get(player, PA.ReviveProgress, 0) else 0
	statusProgress.Visible = progress > 0
	statusProgressFill.Size = UDim2.new(math.clamp(progress, 0, 1), 0, 1, 0)
end

local function refreshState()
	state.survivorState = Attributes.get(player, PA.State, STATE.Spectating)
	state.blackAndWhite = Attributes.get(player, PA.IsBlackAndWhite, false)

	local downed = state.survivorState == STATE.Incapacitated or state.survivorState == STATE.LedgeHanging
	local dead = state.survivorState == STATE.Dead

	statusPanel.Visible = downed or dead
	if dead then
		statusTitle.Text = "YOU ARE DEAD"
		statusTitle.TextColor3 = COLOR.Danger
		statusLine.Text = if GameConfig.RespawnClosetsEnabled
			then "WAITING FOR RESCUE"
			else "WAITING FOR A DEFIBRILLATOR"
		statusWarning.Text = ""
	elseif downed then
		statusTitle.Text = if state.survivorState == STATE.LedgeHanging then "HANGING ON" else "YOU ARE DOWN"
		statusTitle.TextColor3 = COLOR.HealthIncap
		statusLine.Text = "WAITING FOR HELP"
		-- Black and white is the difference between "get me up" and "get me up
		-- or that is the campaign", so it says so in as many words.
		statusWarning.Text = if state.blackAndWhite then "BLACK AND WHITE — THE NEXT DOWN IS FATAL" else ""
	end
	refreshReviveProgress()
end

local function updateVignette(dt: number, now: number)
	local target = 0
	local downed = state.survivorState == STATE.Incapacitated or state.survivorState == STATE.LedgeHanging

	if downed then
		target = VIGNETTE.IncapIntensity
	elseif state.survivorState == STATE.Dead or state.survivorState == STATE.Spectating then
		target = 0
	elseif state.healthFraction < VIGNETTE.HurtStart then
		local hurt = 1 - state.healthFraction / VIGNETTE.HurtStart
		target = VIGNETTE.MaxIntensity * hurt
		-- Under the hurt line the edges breathe. It is the visual half of the
		-- heartbeat the audio plays, and it is what makes low health feel like
		-- a condition rather than a number.
		target *= 0.82 + 0.18 * math.sin(now * VIGNETTE.PulseSpeed * math.pi * 2)
	end

	if now < state.hitFlashUntil then
		target = math.min(target + HIT_FLASH, VIGNETTE.IncapIntensity)
	end

	state.vignette += (target - state.vignette) * math.min(dt * VIGNETTE_CHASE, 1)
	if math.abs(state.vignette - state.vignetteApplied) > 0.004 then
		state.vignetteApplied = state.vignette
		local transparency = 1 - state.vignette
		for _, edge in edges do
			edge.BackgroundTransparency = transparency
		end
	end

	local scrimTarget = if state.survivorState == STATE.Dead then 0.35 elseif downed then 0.82 else 1
	if math.abs(scrim.BackgroundTransparency - scrimTarget) > 0.004 then
		scrim.BackgroundTransparency += (scrimTarget - scrim.BackgroundTransparency) * math.min(
			dt * VIGNETTE_CHASE,
			1
		)
	end
end

local function updateGrade(dt: number, now: number)
	local saturation = 0
	local tint = Color3.new(1, 1, 1)
	local brightness = 0

	if state.survivorState == STATE.Dead then
		saturation = -1
		brightness = -0.05
	elseif state.survivorState == STATE.Incapacitated or state.survivorState == STATE.LedgeHanging then
		-- Downed drains the colour out of the world; black and white takes the
		-- last of it, so the two states are never confusable.
		saturation = if state.blackAndWhite then -1 else -0.75
	elseif state.blackAndWhite then
		-- Standing, and one down from dead. The health model spends the whole
		-- round building to this and the screen has to say so while the player is
		-- still upright, not only once they are on the floor.
		saturation = STANDING_BW_SATURATION
		brightness = STANDING_BW_BRIGHTNESS
	end

	local bile = if now < state.bileUntil
		then math.clamp((state.bileUntil - now) / state.bileDuration, 0, 1)
		else 0
	if bile > 0 then
		tint = tint:Lerp(COLOR.Bile, 0.45 * bile)
		saturation -= 0.25 * bile
	end

	local adrenaline = if now < state.adrenalineUntil
		then math.clamp((state.adrenalineUntil - now) / state.adrenalineDuration, 0, 1)
		else 0
	if adrenaline > 0 then
		-- Adrenaline warms and sharpens rather than washing: the point of the
		-- item is that everything gets easier to read, not harder.
		tint = tint:Lerp(COLOR.AccentBright, 0.2 * adrenaline)
		saturation += 0.35 * adrenaline
		brightness += 0.03 * adrenaline
	end

	local alpha = math.min(dt * GRADE_CHASE, 1)
	state.saturation += (saturation - state.saturation) * alpha
	state.brightness += (brightness - state.brightness) * alpha
	state.tint = state.tint:Lerp(tint, alpha)

	local active = math.abs(state.saturation) > 0.01 or math.abs(state.brightness) > 0.005
	if active then
		grade.Enabled = true
		grade.Saturation = state.saturation
		grade.Brightness = state.brightness
		grade.TintColor = state.tint
	elseif grade.Enabled then
		grade.Enabled = false
		grade.Saturation = 0
		grade.Brightness = 0
		grade.TintColor = Color3.new(1, 1, 1)
	end

	-- The bile layer itself: green on the lens, thickest at the edges, always
	-- leaving the middle of the frame usable.
	if bile > 0 then
		bileLayer.Visible = true
		bileLayer.BackgroundTransparency = 1 - 0.35 * bile
		for _, blob in bileBlobs do
			blob.BackgroundTransparency = 1 - 0.75 * bile
		end
	elseif bileLayer.Visible then
		bileLayer.Visible = false
	end

	if adrenaline > 0 then
		tintLayer.Visible = true
		tintLayer.BackgroundTransparency = 1 - 0.06 * adrenaline
	elseif tintLayer.Visible then
		tintLayer.Visible = false
	end
end

-- ── blood on the lens ───────────────────────────────────────────────────────

local function spawnDroplets(count: number)
	if not SCREEN_BLOOD.Enabled or not bloodEnabled then
		return
	end
	for _ = 1, count do
		local entry = droplets[dropletCursor]
		dropletCursor = (dropletCursor % #droplets) + 1

		--[[ Sized in REFERENCE pixels, like everything else that lays out in
		     offsets. Raw pixels made a droplet cover three times as much of a
		     phone as of a desktop — 14% of a handset's height at the top of the
		     range against 5% at 1080p — so being hit on mobile blacked out the
		     screen in a way it never did anywhere else. ]]
		local scale = ScaleLayer.getFactor()
		local size = random:NextNumber(16, 54) * scale
		entry.frame.Size = UDim2.fromOffset(size, size * random:NextNumber(0.5, 1.1))
		entry.frame.Position = UDim2.fromScale(random:NextNumber(0.04, 0.96), random:NextNumber(0.04, 0.96))
		entry.frame.Rotation = random:NextNumber(0, 180)
		entry.peak = random:NextNumber(0.25, 0.55)
		entry.age = 0
		entry.frame.Visible = true
		entry.frame.BackgroundTransparency = entry.peak
	end
end

local function updateDroplets(dt: number)
	for _, entry in droplets do
		if entry.age < SCREEN_BLOOD.FadeTime then
			entry.age += dt
			local alpha = math.clamp(entry.age / SCREEN_BLOOD.FadeTime, 0, 1)
			entry.frame.BackgroundTransparency = entry.peak + (1 - entry.peak) * alpha
			if alpha >= 1 then
				entry.frame.Visible = false
			end
		end
	end
end

-- ── damage indicators ───────────────────────────────────────────────────────

local function addIndicator(position: Vector3)
	local entry = indicators[indicatorCursor]
	indicatorCursor = (indicatorCursor % #indicators) + 1
	entry.position = position
	entry.age = 0
	entry.frame.Visible = true
end

local function updateIndicators(dt: number)
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	local cframe = camera.CFrame

	for _, entry in indicators do
		if entry.age < INDICATOR.Duration then
			entry.age += dt
			local alpha = math.clamp(entry.age / INDICATOR.Duration, 0, 1)
			if alpha >= 1 then
				entry.frame.Visible = false
			else
				--[[ Recomputed every frame against the live camera: an arrow
				     that stays where it was drawn while the player spins to face
				     the thing hitting them is worse than no arrow. ]]
				local relative = cframe:PointToObjectSpace(entry.position)
				--[[
					A source that is effectively AT the camera has no direction.

					atan2(0, 0) is zero, and zero is straight ahead — so damage
					from something standing on top of you drew a confident arrow
					at the horizon in front of you. That is not a missing arrow,
					it is a wrong one, and a player turns to face it.

					Hidden instead. The horizontal magnitude is what matters:
					vertical distance is not a direction anything on this ring can
					express, so a Spitter's pool directly underfoot should say
					nothing rather than point north.
				]]
				local flat = Vector2.new(relative.X, relative.Z)
				if flat.Magnitude < INDICATOR.MinDistance then
					entry.frame.Visible = false
					continue
				end
				entry.frame.Visible = true
				local angle = math.atan2(relative.X, -relative.Z)
				entry.frame.Position = UDim2.new(
					0.5,
					math.sin(angle) * INDICATOR.Radius,
					0.5,
					-math.cos(angle) * INDICATOR.Radius
				)
				entry.frame.Rotation = math.deg(angle)
				entry.frame.BackgroundTransparency = alpha * alpha
			end
		end
	end
end

-- ── cards ───────────────────────────────────────────────────────────────────

local function broadcastCinematic(value: boolean)
	if state.cinematic == value then
		return
	end
	state.cinematic = value
	for _, name in
		{
			"HudController",
			"CrosshairController",
			"PromptController",
			"SubtitleController",
			"WaveController",
			"TouchController",
		}
	do
		local controller = Registry.find(name)
		if controller and typeof(controller.setCinematic) == "function" then
			pcall(controller.setCinematic, controller, value)
		end
	end
end

--[[
	Shows a full-frame card.

	`persist` cards (the end of a round) stay until something replaces them;
	everything else holds for `hold` seconds and leaves. `takeover` cards hide
	the HUD, because a card the HUD shows through reads as a bug — a wave
	announcement does NOT, since the game is still being played underneath it,
	and WaveController draws those on its own layer for exactly that reason.
]]
local function showCard(config: any)
	state.card = config
	state.cardPhase = "in"
	state.cardClock = 0

	cardTitle.Text = string.upper(config.title or "")
	cardTitle.Font = config.font or FONT.Display
	cardTitle.TextSize = config.titleSize or TEXT.Display
	cardTitle.TextColor3 = config.color or COLOR.TextPrimary
	cardSubtitle.Text = string.upper(config.subtitle or "")
	cardSubtitle.Visible = (config.subtitle or "") ~= ""
	cardPanel.Visible = true

	if config.takeover then
		broadcastCinematic(true)
	end
end

local function hideCard()
	state.card = nil
	state.cardPhase = "idle"
	cardPanel.Visible = false
	broadcastCinematic(false)
end

local function updateCard(dt: number)
	local card = state.card
	if not card then
		return
	end

	state.cardClock += dt
	local fadeIn = card.fadeIn or MOTION.Normal
	local fadeOut = card.fadeOut or MOTION.Slow

	if state.cardPhase == "in" then
		state.cardAlpha = math.clamp(state.cardClock / fadeIn, 0, 1)
		if state.cardAlpha >= 1 then
			state.cardPhase = "hold"
			state.cardClock = 0
		end
	elseif state.cardPhase == "hold" then
		state.cardAlpha = 1
		if not card.persist and state.cardClock >= (card.hold or CARD_HOLD) then
			state.cardPhase = "out"
			state.cardClock = 0
		end
	elseif state.cardPhase == "out" then
		state.cardAlpha = 1 - math.clamp(state.cardClock / fadeOut, 0, 1)
		if state.cardAlpha <= 0 then
			hideCard()
			return
		end
	end

	local fade = 1 - state.cardAlpha
	cardTitle.TextTransparency = fade
	cardSubtitle.TextTransparency = math.min(fade * 1.4, 1)
	cardBack.BackgroundTransparency = 1 - (card.scrim or 0.5) * state.cardAlpha
	-- The title settles into place as it arrives. Small, and the only motion on
	-- a card that is otherwise deliberately still.
	cardTitle.Position = UDim2.new(0.5, 0, 0.5, CARD_SLIDE * fade)
end

-- ── event handling ──────────────────────────────────────────────────────────

local function onDamageTaken(payload: any)
	if typeof(payload) ~= "table" then
		return
	end
	state.hitFlashUntil = os.clock() + HIT_FLASH_TIME

	if typeof(payload.sourcePosition) == "Vector3" then
		addIndicator(payload.sourcePosition)
	end
	spawnDroplets(SCREEN_BLOOD.DropletsPerHit)
end

local function onScreenEffect(payload: any)
	if typeof(payload) ~= "table" then
		return
	end
	local effect = tostring(payload.effect or "")
	local duration = if typeof(payload.duration) == "number" and payload.duration > 0
		then payload.duration
		else nil

	if effect == EFFECT.Bile then
		state.bileDuration = duration or SCREEN_BLOOD.BoomerBileFadeTime
		state.bileUntil = os.clock() + state.bileDuration
	elseif effect == EFFECT.Adrenaline then
		state.adrenalineDuration = duration or GameConfig.Survivor.AdrenalineDuration
		state.adrenalineUntil = os.clock() + state.adrenalineDuration
	elseif effect == EFFECT.Blood then
		spawnDroplets(SCREEN_BLOOD.DropletsPerHit)
	end
end

--[[
	How the round ended, in one line under the title.

	"WAVE 5 OF 7 — 11:42" is the number a team argues about afterwards and the
	one they come back to beat, so it is worth more than a word like "DEFEAT".
]]
local function resultSubtitle(payload: any): string
	if typeof(payload) ~= "table" then
		return ""
	end
	local waves = GameModeConfig.getWaveCount()
	local elapsed = math.max(tonumber(payload.elapsed) or 0, 0)
	local clock = string.format("%d:%02d", elapsed // 60, math.floor(elapsed % 60))

	if payload.outcome == ROUND.Victory then
		return string.format("ALL %d WAVES — %s", waves, clock)
	end
	local reached = math.clamp(tonumber(payload.waveReached) or 0, 0, waves)
	return string.format("WAVE %d OF %d — %s", reached, waves, clock)
end

--[[
	The result card.

	RoundStateChanged and RoundEnded describe the same moment — the state arrives
	first, the detail a frame behind it — so the card is drawn once and the second
	message fills the subtitle in rather than restarting the fade under the
	player's eye.
]]
local function showResult(outcome: string, subtitle: string)
	if state.card and state.card.outcome == outcome then
		cardSubtitle.Text = string.upper(subtitle)
		cardSubtitle.Visible = subtitle ~= ""
		return
	end

	local victory = outcome == ROUND.Victory
	showCard({
		outcome = outcome,
		-- Seventeen minutes and seven waves. There is no door to reach and
		-- nowhere to have got to: holding out IS the win condition.
		title = if victory then "YOU HELD OUT" else "THE SURVIVORS DIDN'T MAKE IT",
		subtitle = subtitle,
		color = if victory then COLOR.Success else COLOR.Danger,
		titleSize = TEXT.Display,
		persist = true,
		takeover = true,
		scrim = if victory then 0.8 else 0.85,
		fadeIn = MOTION.Cinematic,
	})
end

--[[ Drives the black. Everything else on screen chases its target in the frame
     loop; this is the one full-frame value that has an explicit destination and
     a duration, because a handoff has to finish before the menu appears. ]]
local function fadeTo(value: number, duration: number)
	state.fadeTarget = math.clamp(value, 0, 1)
	state.fadeSpeed = 1 / math.max(duration, 0.01)
	if state.fadeTarget > 0 then
		fadeLayer.Visible = true
	end
end

--[[
	Hands the screen to the main menu.

	MainMenuController belongs to another module that may simply not be there — a
	developer running half a client must still get a readable end to their round —
	so nothing here assumes it. If nothing takes over, the card stays up and the
	server's own post-round timer returns everyone to the lobby.

	It also listens to RoundEnded itself and draws above this layer, so by the time
	the card's beat is over it is normally already showing its scoreboard. Handing
	over then means getting out of the way: no fade, because there is nothing left
	to hide, and above all no second result screen replacing the one the player has
	already started reading. The fade is for the other case — a menu that has not
	reacted — where the black is the seam between the round and the menu.
]]
local MENU_ENTRY_POINTS = { "showResults", "open" }

local function menuIsShowing(menu: any): boolean
	if typeof(menu.isOpen) ~= "function" then
		return false
	end
	local ok, result = pcall(menu.isOpen, menu)
	return ok and result == true
end

local function handOffToMenu(payload: any)
	local menu = Registry.find("MainMenuController")
	if not menu then
		return
	end

	if menuIsShowing(menu) then
		hideCard()
		return
	end

	local entry: string? = nil
	for _, name in MENU_ENTRY_POINTS do
		if typeof(menu[name]) == "function" then
			entry = name
			break
		end
	end
	if not entry then
		return
	end

	local mine = handoffGeneration
	fadeTo(1, MOTION.Cinematic)
	task.delay(MOTION.Cinematic, function()
		if mine ~= handoffGeneration then
			return
		end
		-- The card goes with the round it belonged to, and the takeover with it:
		-- from here the menu owns the screen and covers what it wants covered.
		hideCard()

		local ok, err = pcall(menu[entry], menu, payload)
		if not ok then
			warn(
				string.format("[OverlayController] MainMenuController:%s failed — %s", entry, tostring(err))
			)
		end
		fadeTo(0, MOTION.Cinematic)
	end)
end

--[[ Both the remote and the Workspace attribute report the same transition, so
     this deduplicates on the state itself: whichever arrives first draws the
     card and the other is a no-op. ]]
local function onRoundState(newState: string, payload: any)
	if newState == state.roundState then
		return
	end
	state.roundState = newState
	handoffGeneration += 1

	if newState == ROUND.TeamWipe or newState == ROUND.Victory then
		showResult(newState, (typeof(payload) == "table" and tostring(payload.subtitle or "")) or "")
		return
	end

	-- Anything else means another round is on its way in: clear whatever the last
	-- one left on screen, including a takeover that was handed to the menu.
	if state.card and state.card.persist then
		hideCard()
	elseif state.cinematic then
		broadcastCinematic(false)
	end
	fadeTo(0, MOTION.Cinematic)
end

--[[ The end of the round, with the detail the state change did not carry. This
     is also the one place the client hands the screen over, because RoundEnded
     is the only message that means "this round is finished", as opposed to
     "somebody joined a lobby". ]]
local function onRoundEnded(payload: any)
	if typeof(payload) ~= "table" then
		return
	end
	local outcome = tostring(payload.outcome or "")
	if outcome ~= ROUND.Victory and outcome ~= ROUND.TeamWipe then
		return
	end

	onRoundState(outcome, payload)
	showResult(outcome, resultSubtitle(payload))

	local mine = handoffGeneration
	task.delay(HANDOFF_DELAY, function()
		if mine == handoffGeneration then
			handOffToMenu(payload)
		end
	end)
end

-- ── frame loop ──────────────────────────────────────────────────────────────

local function updateFade(dt: number)
	if state.fade == state.fadeTarget then
		return
	end
	local step = dt * state.fadeSpeed
	state.fade = if state.fadeTarget > state.fade
		then math.min(state.fade + step, state.fadeTarget)
		else math.max(state.fade - step, state.fadeTarget)
	fadeLayer.BackgroundTransparency = 1 - state.fade
	if state.fade <= 0 then
		fadeLayer.Visible = false
	end
end

local function update(dt: number)
	local now = os.clock()
	updateGrit(now)
	updateVignette(dt, now)
	updateGrade(dt, now)
	updateDroplets(dt)
	updateIndicators(dt)
	updateCard(dt)
	updateFade(dt)
end

-- ── public API ──────────────────────────────────────────────────────────────

function OverlayController:showCard(title: string, subtitle: string?, color: Color3?)
	showCard({
		title = title,
		subtitle = subtitle or "",
		color = color or COLOR.TextPrimary,
		titleSize = TEXT.Display,
		hold = CARD_HOLD,
		scrim = 0.5,
	})
end

function OverlayController:clearCard()
	if state.card then
		hideCard()
	end
end

function OverlayController:isCinematic(): boolean
	return state.cinematic
end

--[[ Points an arrow at a world position for UITheme.DamageIndicator.Duration.
     Public so a future melee or special-attack path can flag a direction the
     damage remote does not describe. ]]
function OverlayController:addDamageIndicator(position: Vector3)
	if typeof(position) == "Vector3" then
		addIndicator(position)
	end
end

--[[ Whether blood may be drawn on the lens. Pushed by SettingsController from
     the gore setting; see `bloodEnabled`. ]]
function OverlayController:setBloodEnabled(value: boolean)
	bloodEnabled = value ~= false
end

--[[
	The player's own brightness, for a game that ends in the dark.

	AtmosphereService takes the map from a low orange sun to pitch black over
	seven waves, and that ramp is tuned against one screen in one room. A phone
	in daylight, a cheap panel, or somebody who simply cannot see into the gloom
	all end up playing a different game. This is the lever for that, and it is
	deliberately a CLIENT-side grade: it changes nothing for anybody else, and
	the server's own look — which is where the atmosphere lives — is untouched.

	`scale` is 1.0 for the game as designed. It drives Brightness rather than
	Exposure because exposure lifts the whole image including the fog, which
	turns the dark into grey soup; brightness lifts the mid-tones and leaves the
	fog where the artist put it. The matching contrast trim keeps the blacks from
	going flat as it opens up.

	Disabled outright at 1.0 rather than left running at zero: a ColorCorrection
	that is enabled costs a full-frame pass whatever its values are, and most
	players will never move this.
]]
local BRIGHTNESS_GAIN = 0.30
local BRIGHTNESS_CONTRAST = 0.16

function OverlayController:setBrightness(scale: number)
	if not personalGrade then
		return
	end
	local wanted = if typeof(scale) == "number" and scale == scale then math.clamp(scale, 0.5, 2) else 1
	if math.abs(wanted - 1) < 0.01 then
		personalGrade.Enabled = false
		return
	end
	personalGrade.Brightness = (wanted - 1) * BRIGHTNESS_GAIN
	personalGrade.Contrast = (wanted - 1) * BRIGHTNESS_CONTRAST
	personalGrade.Enabled = true
end

function OverlayController:screenEffect(effect: string, duration: number?, intensity: number?)
	onScreenEffect({ effect = effect, duration = duration, intensity = intensity })
end

-- ── lifecycle ───────────────────────────────────────────────────────────────

function OverlayController:init()
	build()
	refreshHealth()
	refreshState()

	for _, attribute in { PA.Health, PA.TempHealth } do
		trove:connect(player:GetAttributeChangedSignal(attribute), refreshHealth)
	end
	for _, attribute in { PA.State, PA.IsBlackAndWhite } do
		trove:connect(player:GetAttributeChangedSignal(attribute), refreshState)
	end
	trove:connect(player:GetAttributeChangedSignal(PA.ReviveProgress), refreshReviveProgress)
end

function OverlayController:start()
	trove:connect(Remotes.Event.DamageTaken.OnClientEvent, onDamageTaken)
	trove:connect(Remotes.Event.ScreenEffect.OnClientEvent, onScreenEffect)

	trove:connect(Remotes.Event.RoundStateChanged.OnClientEvent, function(payload: any)
		if typeof(payload) ~= "table" or typeof(payload.state) ~= "string" then
			return
		end
		local body = if typeof(payload.payload) == "table" then payload.payload else payload
		onRoundState(payload.state, body)
	end)

	trove:connect(Remotes.Event.RoundEnded.OnClientEvent, onRoundEnded)

	--[[ The round state is also an attribute, which is the only thing a player
	     joining into a finished round will ever see. ]]
	trove:connect(Workspace:GetAttributeChangedSignal(GA.RoundState), function()
		onRoundState(Attributes.get(Workspace, GA.RoundState, ROUND.Lobby), nil)
	end)

	trove:connect(RunService.RenderStepped, update)
end

function OverlayController:onInitialState(payload: any)
	refreshHealth()
	refreshState()
	-- Routed through the normal path rather than assigned: somebody joining into
	-- a finished round has to see the card everyone else is already looking at.
	if typeof(payload) == "table" and typeof(payload.roundState) == "string" then
		onRoundState(payload.roundState, nil)
	end
end

function OverlayController:destroy()
	broadcastCinematic(false)
	trove:destroy()
end

Registry.register("OverlayController", OverlayController)

return OverlayController
