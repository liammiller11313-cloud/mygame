--!nonstrict
--[[
	MainMenuController — the poster the game opens on, and the one it closes on.

	This is the first thing anybody sees, so it is not a game UI. It is a worn
	movie poster: a black field, a handful of white words, and exactly one orange
	thing telling you where to look. Two mode entries, a countdown, a settings
	line along the bottom, and nothing else. Every box that is not on this screen
	was left off on purpose.

	── THE TITLE ───────────────────────────────────────────────────────────────
	FADING in white, LIGHT in orange underneath it, both in UITheme.Font.Stencil
	— the battered typewriter face — and the word LIGHT flickers like a tube
	about to go. It is on the nose, and a zombie game title screen is the one
	place where on the nose is the correct choice.

	The flicker is a handful of scalars driven off the single RenderStepped this
	controller owns: no tween objects, no per-element connections, and nothing
	allocated per frame anywhere in the loop. Every property written in `update`
	is a number.

	── WHAT DRIVES IT ──────────────────────────────────────────────────────────
	  * `LobbyStateChanged`  mode, players, countdown, whether a round is running
	                         and how far in. `endsAt` is an absolute server-time
	                         stamp, so the countdown is rendered locally and the
	                         server sends nothing per second.
	  * `RoundEnded`         the result screen: outcome, wave reached, time.
	  * `Player.OnTeleport`  the matchmaker moves players between servers without
	                         telling the client, so the engine's own teleport
	                         signal is what puts "MOVING YOU TO ANOTHER SERVER"
	                         on screen. A player who blinks out mid-menu with no
	                         explanation assumes the game crashed.
	  * `RequestMode`        the only thing this screen sends. The server decides
	                         where the player ends up; the menu just asks.

	── LAYERING ────────────────────────────────────────────────────────────────
	One ScreenGui holds both the menu and the result screen. While either is up
	the world behind it is blurred, the HUD, crosshair and interact prompts are
	hidden, and gameplay input is suspended — a menu that lets you shoot through
	it is a bug. The camera is dropped to Classic for exactly as long as the menu
	is open, because LockFirstPerson pins the mouse to the middle of the screen
	and nothing here would be clickable.

	── KNOWN GAPS (deliberate, not oversights) ─────────────────────────────────
	  * Nothing on the server tallies per-player kills, headshots, damage taken
	    or revives. `StatsUpdated` is in the manifest with no sender. This screen
	    reads it and `RoundEnded.scores` first and falls back to what the client
	    can honestly observe about ITSELF; anything it cannot know renders as a
	    dash rather than as a zero, because a fabricated zero is worse than an
	    admitted blank.
	  * Master volume drives a SoundGroup this controller owns and adopts every
	    client-side Sound under SoundService. World sounds are created by the
	    server on parts in Workspace and are out of its reach until AudioService
	    assigns them a group.
]]

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TeleportService = game:GetService("TeleportService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attributes = require(Shared.Net.Attributes)
local AudioConfig = require(Shared.Config.AudioConfig)
local Enums = require(Shared.Enums)
local GameModeConfig = require(Shared.Config.GameModeConfig)
local Registry = require(Shared.Util.Registry)
local Remotes = require(Shared.Net.Remotes)
local Signal = require(Shared.Util.Signal)
local Trove = require(Shared.Util.Trove)
local UITheme = require(Shared.Config.UITheme)

local COLOR = UITheme.Color
local FONT = UITheme.Font
local LAYOUT = UITheme.Layout
local MOTION = UITheme.Motion
local TEXT = UITheme.TextSize

local GA = Attributes.Game
local PA = Attributes.Player
local MODES = GameModeConfig.Modes
local ROUND = Enums.RoundState
local STATE = Enums.SurvivorState

--[[ UITheme.DisplayOrder has no menu layer, and should not: the menu is not part
     of the HUD stack. It has to cover everything the game draws — including
     OverlayController's end-of-round card at Overlay — while still sitting under
     the fade that covers a teleport. ]]
local MENU_ORDER = UITheme.DisplayOrder.Fade - 1

--[[ The layout is drawn against a 900px-tall viewport and scaled from there, so
     the poster keeps its proportions on a phone and on a 4K monitor instead of
     turning into a wall of type or a stamp in the corner. ]]
local REFERENCE_HEIGHT = 900
local MIN_SCALE = 0.62
local MAX_SCALE = 1.35

--[[ Not fully opaque: the blurred world stays faintly visible behind the black,
     which is the difference between a menu that sits in front of the game and a
     menu that replaced it. ]]
local MENU_SCRIM = 0.04
local RESULTS_SCRIM = 0.02

--[[
	Victory confetti. Fired from the two bottom corners like a pair of cannons
	rather than dropped from the top: a burst reads as celebration, a drizzle
	reads as snow, and this screen only ever appears when a team survived all
	seventeen minutes.

	Kept on the palette — orange, white and gold, the same three the survivor
	outlines use — so the one genuinely joyful moment in the game still looks
	like it belongs to it.

	Everything is pooled and driven off the single RenderStepped this controller
	already owns. The pieces are plain Frames with a UIStroke-free fill, because
	a hundred ImageLabels would cost real frame time on a phone for something the
	player looks at for four seconds.
]]
local CONFETTI_COUNT = 108
local CONFETTI_GRAVITY = 1.05 -- screen heights per second squared
local CONFETTI_SPEED_MIN = 0.95
local CONFETTI_SPEED_MAX = 1.65
local CONFETTI_SPREAD = 0.42 -- radians either side of straight up
local CONFETTI_DRAG = 0.72
local CONFETTI_SWAY = 0.22 -- horizontal flutter amplitude
local CONFETTI_SWAY_RATE = 3.4
local CONFETTI_LIFETIME = 4.2
local CONFETTI_FADE_AT = 0.65 -- fraction of life before it starts fading
local CONFETTI_WIDTH = 7
local CONFETTI_HEIGHT = 11

local BLUR_SIZE = 26
-- UITheme's durations, expressed as the chase rates the frame loop wants.
local BLUR_SPEED = 1 / MOTION.Normal
local BLUR_EPSILON = 0.05

-- The left margin every headline, rule and mode entry lines up against.
local COLUMN_X = 0.09
local TITLE_LINE = TEXT.Title + 6
local TITLE_RULE_WIDTH = 300

local ENTRY_HEIGHT = 88
local ENTRY_GAP = 20
local ENTRY_WIDTH = 0.44
local ENTRY_BAR_WIDTH = 3
local ENTRY_TEXT_INSET = 20

local HOVER_SPEED = 1 / MOTION.FastOut
local HOVER_EPSILON = 0.004

--[[ A failing tube holds, drops for a fraction of a second, and holds again. It
     does not strobe. Long gaps and short dips are the whole trick, and the slow
     breath underneath keeps the word from ever sitting perfectly still. ]]
local FLICKER_BASE = 0.02
local FLICKER_BREATH = 0.06
local FLICKER_BREATH_SPEED = 0.7
local FLICKER_BUZZ_SPEED = 47
local FLICKER_MIN_GAP = 2.6
local FLICKER_GAP_RANGE = 6.0
local FLICKER_MIN_DURATION = 0.05
local FLICKER_DURATION_RANGE = 0.22
local FLICKER_MIN_DEPTH = 0.28
local FLICKER_DEPTH_RANGE = 0.5
local FLICKER_MAX = 0.86

--[[ How long the menu waits for the server to answer a mode request before it
     stops saying SEARCHING. The only slow path is a MemoryStore browse plus a
     teleport attempt; past this something went wrong and silence is the worst
     possible answer. ]]
local PENDING_TIMEOUT = 14
local MESSAGE_LIFETIME = 9

-- The countdown turns orange here. The last ten seconds are the only ones
-- anybody actually counts, and that is when the number should start shouting.
local COUNTDOWN_URGENT = 10

-- Roblox's default mouse delta is 1.0. The ends are wide enough to be useful and
-- narrow enough that a slider drag cannot make the game unplayable by accident.
local SENSITIVITY_MIN = 0.2
local SENSITIVITY_MAX = 2.5
local SLIDER_STEP = 0.05

local NO_DATA = "—"
local RESULT_ROW_HEIGHT = 30
local MAX_ROWS = math.max(GameModeConfig.Classic.MaxPlayers, GameModeConfig.Versus.MaxPlayers)

--[[ A revive is credited when the local player's hold bar was most of the way
     full and then released, AND a teammate stood up right afterwards. See
     `noteHelpProgress` for why it cannot simply watch for progress hitting 1. ]]
local HELP_NEAR_COMPLETE = 0.5
local HELP_WINDOW = 0.75

local MainMenuController = {}

--[[ Fires (key, value) whenever a setting changes, so anything that grows a
     preference later can subscribe instead of polling this table. ]]
MainMenuController.settingChanged = Signal.new()

local player = Players.LocalPlayer
local trove = Trove.new()

-- ── mode copy ───────────────────────────────────────────────────────────────
-- The numbers are formatted from GameModeConfig rather than typed, so the pitch
-- on the front screen can never end up describing a round length that changed.
local MODE_ENTRIES = {
	{
		id = MODES.Classic,
		title = "CLASSIC",
		line = string.format(
			"%d minutes. %d waves. Survive.",
			GameModeConfig.Classic.TotalDuration // 60,
			GameModeConfig.getWaveCount()
		),
	},
	{
		id = MODES.Versus,
		title = "VERSUS",
		line = "Half of you are the infected.",
	},
}

local SETTING_DEFS = {
	{ key = "damageNumbers", label = "DAMAGE NUMBERS", kind = "toggle", default = true, width = 176 },
	{
		key = "masterVolume",
		label = "VOLUME",
		kind = "slider",
		default = AudioConfig.Mix.MasterVolume,
		min = 0,
		max = 1,
		width = 190,
	},
	{
		key = "sensitivity",
		label = "MOUSE SENSITIVITY",
		kind = "slider",
		default = 1,
		min = SENSITIVITY_MIN,
		max = SENSITIVITY_MAX,
		width = 190,
	},
	{
		key = "gore",
		label = "GORE",
		kind = "choice",
		options = { "FULL", "LOW", "OFF" },
		default = "FULL",
		width = 150,
	},
}

local STAT_COLUMNS = {
	{ key = "kills", title = "KILLS" },
	{ key = "headshots", title = "HEADSHOTS" },
	{ key = "damageTaken", title = "DAMAGE TAKEN" },
	{ key = "revives", title = "REVIVES" },
}

local NAME_WIDTH = 0.30
local STATUS_WIDTH = 0.14
local COLUMN_WIDTH = (1 - NAME_WIDTH - STATUS_WIDTH) / #STAT_COLUMNS

-- ── instances ───────────────────────────────────────────────────────────────

local gui: ScreenGui
local blur: BlurEffect
local menuRoot: Frame
local menuLayer: Frame
local resultsRoot: Frame
local resultsLayer: Frame
local confettiLayer: Frame
local confetti: { any } = {}
local confettiActive = 0
local teleportRoot: Frame
local teleportLayer: Frame

--[[ Every scaled content layer, and the UIScale driving it. See `newLayer`. ]]
local layers: { { frame: Frame, scale: UIScale } } = {}

local titleLight: TextLabel
local titleRule: Frame

local modeEntries: { any } = {}

local lobbyBig: TextLabel
local lobbyCaption: TextLabel
local lobbyMode: TextLabel
local lobbyPlayers: TextLabel
local lobbyMessage: TextLabel

local settingCells: { any } = {}

local resultOutcome: TextLabel
local resultVerdict: TextLabel
local resultWave: TextLabel
local resultTime: TextLabel
local resultRows: { any } = {}
local resultContinue: TextLabel
local resultReturn: TextLabel

local masterGroup: SoundGroup
local uiSounds: { [string]: Sound } = {}

-- Defined down with the build helpers; declared here so `start` can reach it.
local watchViewport: () -> ()

-- ── state ───────────────────────────────────────────────────────────────────

local state = {
	open = false,
	results = false,
	suppressed = false,
	committed = false, -- the server has admitted this player to the round
	teleporting = false,
	roundState = ROUND.Lobby,

	pending = "", -- the mode we asked for and have not been answered about
	pendingUntil = 0,
	message = "",
	messageUntil = 0,

	blur = 0,
	blurTarget = 0,
	countdownShown = -1,
	returnShown = -1,
	returnAt = 0,
}

local lobby = {
	mode = GameModeConfig.DefaultMode,
	countdown = 0,
	endsAt = 0,
	players = 0,
	maxPlayers = GameModeConfig.Classic.MaxPlayers,
	canStart = false,
	inProgress = false,
	waveIndex = 0,
	joinable = true,
}

local flicker = {
	endsAt = 0,
	nextAt = 0,
	depth = 0,
}

--[[ What this client can honestly say about itself. Reset when a round starts so
     a second round never inherits the first one's tally. ]]
local localStats = {
	kills = 0,
	headshots = 0,
	damageTaken = 0,
	revives = 0,
}

-- Anything the server chooses to tell us, keyed by player name. Always wins.
local serverStats: { [string]: any } = {}

local help = {
	progress = 0,
	finishedAt = 0,
}

local settings: { [string]: any } = {}
local restore = {
	cameraMode = nil :: any,
	mouseIcon = nil :: any,
}
local dragging: any = nil

-- ── small helpers ───────────────────────────────────────────────────────────

--[[ Calls a method on another controller if it exists, without caring whether it
     does. Every one of these is presentation polish: a client missing its gore
     controller must still get a menu. ]]
local function callController(name: string, method: string, ...: any)
	local controller = Registry.find(name)
	if controller and typeof(controller[method]) == "function" then
		pcall(controller[method], controller, ...)
	end
end

--[[ Roblox has no letter-spacing. The kicker line above the title is the one
     place the poster needs it, so the spaces are baked in once at build. ]]
local function tracked(text: string): string
	local spread = string.gsub(text, "(.)", "%1 ")
	return (string.gsub(spread, "%s+$", ""))
end

local function clockText(seconds: number): string
	local whole = math.max(math.floor(seconds), 0)
	return string.format("%d:%02d", whole // 60, whole % 60)
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

--[[ A hairline. Every division on this screen is one pixel of border or accent —
     never a panel, never a card, and never a drop shadow. ]]
local function newRule(parent: Instance, name: string, color: Color3?): Frame
	local rule = newFrame(parent, name, color or COLOR.Border, 0)
	rule.Size = UDim2.new(1, 0, 0, LAYOUT.BorderThickness)
	return rule
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
	return button
end

--[[
	A content layer that keeps its layout at any resolution.

	The poster is drawn against a 900px-tall viewport: pixel offsets are chosen
	for that height and would be a wall of type on a phone. A UIScale fixes the
	offsets but would also shrink the layer away from the screen edges, so the
	layer's size is set to 1/scale — after the UIScale multiplies it back up it
	covers the viewport exactly, scale-based positions still resolve against the
	full screen, and every offset inside it scales with the display.
]]
local function newLayer(parent: Instance): Frame
	local frame = newFrame(parent, "Layer", COLOR.Background, 1)
	frame.Size = UDim2.fromScale(1, 1)

	local scale = Instance.new("UIScale")
	scale.Parent = frame

	table.insert(layers, { frame = frame, scale = scale })
	return frame
end

--[[ Menu blips, played locally. Mode clicks stay silent here on purpose:
     MatchmakingService answers an accepted request with MenuConfirm through
     AudioService, and two copies of the same sample one frame apart sounds like
     a bug rather than like confirmation. ]]
local function playUi(definition: any)
	if not AudioConfig.isConfigured(definition) then
		return
	end
	local existing = uiSounds[definition.id]
	if not existing then
		existing = Instance.new("Sound")
		existing.Name = "FL_Menu"
		existing.SoundId = definition.id
		existing.Volume = definition.volume
		existing.SoundGroup = masterGroup
		existing.Parent = SoundService
		uiSounds[definition.id] = trove:add(existing)
	end
	existing.PlaybackSpeed = definition.pitchMin + math.random() * (definition.pitchMax - definition.pitchMin)
	existing:Play()
end

-- ── settings ────────────────────────────────────────────────────────────────

--[[
	Persistence with no data service and no server round trip.

	TeleportService's teleport settings are client-side and survive a teleport,
	which is exactly the lifetime that matters here: this game moves players
	between servers to fill a round, and a volume slider that resets every time
	the matchmaker did its job would read as the game forgetting.

	It is not available in every context and it throws rather than returning nil,
	so every touch is wrapped and the in-memory table is the real store.
]]
local SETTING_PREFIX = "FL_Setting_"

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

--[[ Pushes one setting at whatever owns it. Called on change and once at start,
     so a preference restored from a previous server is applied before the first
     shot is fired rather than the first time the player opens the menu. ]]
local function applySetting(key: string, value: any)
	if key == "damageNumbers" then
		callController("HitmarkerController", "setDamageNumbersEnabled", value == true)
	elseif key == "gore" then
		-- GoreController is on/off today. LOW is stored and published for it to
		-- read when it grows a quality level; it must not silently mean OFF.
		callController("GoreController", "setEnabled", value ~= "OFF")
	elseif key == "masterVolume" then
		masterGroup.Volume = math.clamp(value, 0, 1)
		callController("MusicController", "setEnabled", value > 0)
	elseif key == "sensitivity" then
		UserInputService.MouseDeltaSensitivity = math.clamp(value, SENSITIVITY_MIN, SENSITIVITY_MAX)
	end
end

local function settingText(definition: any, value: any): string
	if definition.kind == "toggle" then
		return if value then "ON" else "OFF"
	elseif definition.kind == "choice" then
		return tostring(value)
	elseif definition.key == "masterVolume" then
		return string.format("%d%%", math.floor(value * 100 + 0.5))
	end
	return string.format("%.2f", value)
end

local function refreshCell(cell: any)
	local value = settings[cell.definition.key]
	cell.value.Text = settingText(cell.definition, value)
	if cell.fill then
		local definition = cell.definition
		local alpha = (value - definition.min) / (definition.max - definition.min)
		cell.fill.Size = UDim2.new(math.clamp(alpha, 0, 1), 0, 1, 0)
	end
end

local function setSetting(key: string, value: any, silent: boolean?)
	if settings[key] == value then
		return
	end
	settings[key] = value
	saveSetting(key, value)
	applySetting(key, value)
	for _, cell in settingCells do
		if cell.definition.key == key then
			refreshCell(cell)
		end
	end
	if not silent then
		playUi(AudioConfig.UI.MenuHover)
	end
	MainMenuController.settingChanged:fire(key, value)
end

local function cycleSetting(definition: any)
	local current = settings[definition.key]
	if definition.kind == "toggle" then
		setSetting(definition.key, not current)
		return
	end

	local options = definition.options
	local index = table.find(options, current) or 0
	setSetting(definition.key, options[(index % #options) + 1])
end

local function dragSetting(cell: any, x: number)
	local definition = cell.definition
	local track = cell.track
	local width = track.AbsoluteSize.X
	if width <= 0 then
		return
	end
	local alpha = math.clamp((x - track.AbsolutePosition.X) / width, 0, 1)
	local raw = definition.min + alpha * (definition.max - definition.min)
	local stepped = math.floor(raw / SLIDER_STEP + 0.5) * SLIDER_STEP
	setSetting(definition.key, math.clamp(stepped, definition.min, definition.max), true)
end

-- ── suppression: what the menu does to the rest of the client ───────────────

--[[
	CameraController re-applies LockFirstPerson every time the survivor state
	changes, and LockFirstPerson pins the cursor to the centre of the screen. If
	that happens while the menu is up, nothing on it can be clicked. So the value
	it just wrote is taken as the one to hand back on close, and the camera is
	unlocked again — deferred, because this runs on the same attribute signal and
	has to land after CameraController's own handler.
]]
local function reassertFreeCursor()
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
end

--[[ Everything the menu takes over while it is on screen, in one place so it can
     never be half-applied. The HUD is hidden through setVisible rather than
     setCinematic: OverlayController owns the cinematic flag for its end-of-round
     card, and two owners for one boolean is how a HUD ends up stuck off. ]]
local function setSuppressed(value: boolean)
	if state.suppressed == value then
		return
	end
	state.suppressed = value

	callController("HudController", "setVisible", not value)
	callController("CrosshairController", "setVisible", not value)
	callController("PromptController", "setEnabled", not value)
	callController("InputController", "setEnabled", not value)

	state.blurTarget = if value then BLUR_SIZE else 0

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
		dragging = nil
	end
end

local function refreshVisibility()
	gui.Enabled = state.open or state.results or state.teleporting
	menuRoot.Visible = state.open
	resultsRoot.Visible = state.results
	teleportRoot.Visible = state.teleporting
	setSuppressed(state.open or state.results)
end

-- ── lobby presentation ──────────────────────────────────────────────────────

local function setMessage(text: string)
	state.message = text
	state.messageUntil = if text == "" then 0 else os.clock() + MESSAGE_LIFETIME
	lobbyMessage.Text = string.upper(text)
end

--[[ The tag on the right of a mode entry: what would happen if you pressed it,
     or what already did. ]]
local function entryTag(entry: any): (string, Color3)
	if state.pending == entry.id then
		return "SEARCHING", COLOR.Accent
	end
	if lobby.mode ~= entry.id then
		return "", COLOR.TextDim
	end
	if state.committed then
		return "YOU'RE IN", COLOR.Accent
	end
	if lobby.inProgress then
		return (if lobby.joinable then "JOIN IN PROGRESS" else "NEXT ROUND"), COLOR.TextSecondary
	end
	return "THIS SERVER", COLOR.TextDim
end

local function refreshEntries()
	for _, entry in modeEntries do
		local text, color = entryTag(entry)
		entry.tag.Text = text
		entry.tag.TextColor3 = color
		entry.current = lobby.mode == entry.id
	end
end

--[[ The big number, and what it means. Three honest states: a lobby counting
     down, a round already running, and a lobby with nobody in it to start one. ]]
local function refreshLobby()
	lobbyMode.Text = string.upper(lobby.mode)
	lobbyPlayers.Text = string.format("%d / %d SURVIVORS", lobby.players, lobby.maxPlayers)

	if lobby.inProgress then
		local wave = math.max(lobby.waveIndex, 0)
		lobbyBig.Text = if wave > 0 then string.format("%d", wave) else "—"
		lobbyBig.TextColor3 = COLOR.TextPrimary
		lobbyCaption.Text = if wave > 0 then "WAVE, IN PROGRESS" else "ROUND IN PROGRESS"
		state.countdownShown = -1
	elseif state.committed or lobby.canStart then
		-- The number itself is written by updateCountdown, which also owns the
		-- colour: it is the only thing that knows how little time is left.
		lobbyCaption.Text = "UNTIL IT STARTS"
	else
		lobbyBig.Text = "—"
		lobbyBig.TextColor3 = COLOR.TextDim
		lobbyCaption.Text = "WAITING FOR SURVIVORS"
		state.countdownShown = -1
	end
	refreshEntries()
end

local function onLobbyState(payload: any)
	if typeof(payload) ~= "table" then
		return
	end

	if typeof(payload.mode) == "string" then
		lobby.mode = payload.mode
	end
	lobby.countdown = tonumber(payload.countdown) or 0
	lobby.endsAt = tonumber(payload.endsAt) or 0
	lobby.players = tonumber(payload.players) or 0
	lobby.maxPlayers = tonumber(payload.maxPlayers) or lobby.maxPlayers
	lobby.waveIndex = tonumber(payload.waveIndex) or 0
	lobby.canStart = payload.canStart == true
	lobby.inProgress = payload.inProgress == true
	lobby.joinable = payload.joinable ~= false

	-- Every answer to a RequestMode carries a sentence. Whatever it says, the
	-- request is over and the entry stops claiming to be searching.
	if typeof(payload.message) == "string" and payload.message ~= "" then
		state.pending = ""
		setMessage(payload.message)
	end

	if payload.joined == true then
		state.committed = true
		state.pending = ""
		-- Dropped straight into a live round: there is nothing left to decide,
		-- so the menu gets out of the way instead of waiting for a state change
		-- that already happened.
		if lobby.inProgress then
			MainMenuController:close()
			return
		end
	end

	refreshLobby()
end

-- ── stats ───────────────────────────────────────────────────────────────────

local function resetStats()
	localStats.kills = 0
	localStats.headshots = 0
	localStats.damageTaken = 0
	localStats.revives = 0
	table.clear(serverStats)
	help.progress = 0
	help.finishedAt = 0
end

local STAT_KEYS = { "kills", "headshots", "damageTaken", "revives" }

--[[ Merges anything stat-shaped out of a payload. Both `StatsUpdated` and the
     `scores` table on `RoundEnded` are accepted, so whichever service grows a
     tally first lands on this screen with no change here. ]]
local function mergeStats(name: string, source: any)
	if typeof(source) ~= "table" then
		return
	end
	local record = serverStats[name]
	for _, key in STAT_KEYS do
		local value = tonumber(source[key])
		if value then
			record = record or {}
			record[key] = value
		end
	end
	if record then
		serverStats[name] = record
	end
end

--[[
	Credit for a revive, inferred.

	The server publishes FL_ReviveProgress on the rescuer as well as on the
	person on the floor, but it writes 1.00 and then 0.00 inside the same server
	frame, so the client never observes the completion — attribute writes are
	coalesced before they replicate. What it does observe is a hold bar that was
	most of the way full and then vanished.

	That alone is also true of a revive the player let go of, so it is only half
	the signal: the other half is a teammate actually standing up within a beat
	of it. Both together is a revive. Neither this nor the kill counters are the
	right long-term answer — a server-side tally through StatsUpdated is — but a
	scoreboard that only ever prints dashes is not worth shipping either.
]]
local function noteHelpProgress()
	local progress = Attributes.get(player, PA.ReviveProgress, 0)
	local previous = help.progress
	help.progress = progress

	if progress > 0 or previous < HELP_NEAR_COMPLETE then
		return
	end
	-- Only the person doing the reviving is on their feet.
	local mine = Attributes.get(player, PA.State, STATE.Spectating)
	if mine == STATE.Healthy or mine == STATE.Hurt then
		help.finishedAt = os.clock()
	end
end

local DOWNED_STATES = {
	[STATE.Incapacitated] = true,
	[STATE.LedgeHanging] = true,
	[STATE.Dead] = true,
}

local function onSurvivorStateChanged(payload: any)
	if typeof(payload) ~= "table" or payload.player == player then
		return
	end
	if not DOWNED_STATES[payload.previousState] or DOWNED_STATES[payload.state] then
		return
	end
	if help.finishedAt > 0 and os.clock() - help.finishedAt <= HELP_WINDOW then
		help.finishedAt = 0
		localStats.revives += 1
	end
end

local function onHitConfirmed(payload: any)
	if typeof(payload) ~= "table" or payload.killed ~= true then
		return
	end
	localStats.kills += 1
	if payload.isHeadshot == true then
		-- Headshot KILLS, not headshot hits: on a Common the two are the same
		-- thing by design, and on a Tank a graze is not worth a line on a board.
		localStats.headshots += 1
	end
end

local function onDamageTaken(payload: any)
	if typeof(payload) ~= "table" then
		return
	end
	localStats.damageTaken += math.max(tonumber(payload.amount) or 0, 0)
end

local function statText(name: string, key: string): string
	local record = serverStats[name]
	local value = record and record[key]
	if value == nil and name == player.Name then
		value = localStats[key]
	end
	if typeof(value) ~= "number" then
		return NO_DATA
	end
	return string.format("%d", math.floor(value + 0.5))
end

-- ── result screen ───────────────────────────────────────────────────────────

local function hideRows()
	for _, row in resultRows do
		row.frame.Visible = false
	end
end

local function fillRows(scores: any)
	hideRows()
	if typeof(scores) ~= "table" then
		return
	end

	local order = {}
	for name, record in scores do
		if typeof(name) == "string" then
			mergeStats(name, record)
			table.insert(order, {
				name = name,
				alive = typeof(record) == "table" and record.alive == true,
				kills = tonumber(statText(name, "kills")) or -1,
			})
		end
	end

	--[[ Standing first, then by kills, then alphabetically. Sorting a scoreboard
	     by who survived puts the answer to "did we make it" in the same place
	     every time. ]]
	table.sort(order, function(a, b)
		if a.alive ~= b.alive then
			return a.alive
		end
		if a.kills ~= b.kills then
			return a.kills > b.kills
		end
		return a.name < b.name
	end)

	for index, entry in order do
		local row = resultRows[index]
		if not row then
			break
		end
		local isLocal = entry.name == player.Name
		row.frame.Visible = true
		row.name.Text = string.upper(entry.name)
		row.name.TextColor3 = if isLocal then COLOR.Accent else COLOR.TextPrimary
		row.status.Text = if entry.alive then "STANDING" else "DIED"
		row.status.TextColor3 = if entry.alive then COLOR.TextSecondary else COLOR.Danger
		for _, cell in row.cells do
			cell.label.Text = statText(entry.name, cell.key)
			cell.label.TextColor3 = if isLocal then COLOR.TextPrimary else COLOR.TextSecondary
		end
	end
end

--[[ Builds the pool once. Pieces live hidden until a burst claims them. ]]
local function buildConfetti()
	local palette = UITheme.SurvivorColors
	for index = 1, CONFETTI_COUNT do
		local piece = newFrame(confettiLayer, "Piece" .. index, palette[((index - 1) % #palette) + 1], 0)
		piece.AnchorPoint = Vector2.new(0.5, 0.5)
		piece.Size = UDim2.fromOffset(CONFETTI_WIDTH, CONFETTI_HEIGHT)
		piece.Visible = false
		piece.ZIndex = 3
		confetti[index] = {
			frame = piece,
			x = 0,
			y = 0,
			vx = 0,
			vy = 0,
			age = 0,
			phase = 0,
			spin = 0,
			alive = false,
		}
	end
end

--[[ Claims the whole pool and throws it from both bottom corners. ]]
local function burstConfetti()
	confettiActive = 0
	for index, piece in confetti do
		-- Alternate cannons so both corners fill at the same rate.
		local fromLeft = index % 2 == 1
		local angle = (if fromLeft then -math.pi / 2 else -math.pi / 2)
			+ (if fromLeft then 1 else -1) * (CONFETTI_SPREAD * (0.35 + math.random() * 0.65))
		local speed = CONFETTI_SPEED_MIN + math.random() * (CONFETTI_SPEED_MAX - CONFETTI_SPEED_MIN)

		piece.x = if fromLeft then -0.02 else 1.02
		piece.y = 1.02
		piece.vx = math.cos(angle) * speed * (if fromLeft then -1.6 else 1.6)
		piece.vy = math.sin(angle) * speed
		piece.age = -(index % 9) * 0.035 -- stagger, so it reads as a burst not a wall
		piece.phase = math.random() * math.pi * 2
		piece.spin = (math.random() * 2 - 1) * 420
		piece.alive = true
		confettiActive += 1

		piece.frame.Visible = false
		piece.frame.BackgroundTransparency = 0
	end
end

local function clearConfetti()
	for _, piece in confetti do
		piece.alive = false
		piece.frame.Visible = false
	end
	confettiActive = 0
end

--[[ One integration step for the whole pool. Returns early once everything has
     landed, so the result screen costs nothing to leave open. ]]
local function updateConfetti(dt: number)
	if confettiActive <= 0 then
		return
	end

	for _, piece in confetti do
		if not piece.alive then
			continue
		end

		piece.age += dt
		if piece.age < 0 then
			continue -- still waiting its turn in the stagger
		end

		if piece.age >= CONFETTI_LIFETIME then
			piece.alive = false
			piece.frame.Visible = false
			confettiActive -= 1
			continue
		end

		piece.vy += CONFETTI_GRAVITY * dt
		piece.vx -= piece.vx * CONFETTI_DRAG * dt
		piece.x += (piece.vx + math.sin(piece.age * CONFETTI_SWAY_RATE + piece.phase) * CONFETTI_SWAY) * dt
		piece.y += piece.vy * dt

		-- A piece that has fallen well clear of the screen is done early.
		if piece.y > 1.15 and piece.vy > 0 then
			piece.alive = false
			piece.frame.Visible = false
			confettiActive -= 1
			continue
		end

		local life = piece.age / CONFETTI_LIFETIME
		local fade = if life <= CONFETTI_FADE_AT
			then 0
			else (life - CONFETTI_FADE_AT) / (1 - CONFETTI_FADE_AT)

		local frame = piece.frame
		frame.Visible = true
		frame.Position = UDim2.fromScale(piece.x, piece.y)
		frame.Rotation = piece.age * piece.spin
		frame.BackgroundTransparency = fade
	end
end

--[[ The result screen. SURVIVED is white and quiet; WIPED OUT is the one place
     on this screen red belongs, and it gets the poster voice — the team did not
     lose a match, the light went out on them. ]]
local function showResults(payload: any)
	local outcome = if typeof(payload) == "table" then tostring(payload.outcome) else ROUND.TeamWipe
	local survived = outcome == ROUND.Victory
	local waveCount = GameModeConfig.getWaveCount()
	local waveReached = math.clamp(tonumber(payload and payload.waveReached) or 0, 0, waveCount)
	local elapsed = math.max(tonumber(payload and payload.elapsed) or 0, 0)

	resultOutcome.Text = if survived then "SURVIVED" else "WIPED OUT"
	resultOutcome.TextColor3 = if survived then COLOR.TextPrimary else COLOR.Danger

	if survived then
		resultVerdict.Text = string.format(
			"%d MINUTES. %d WAVES. STILL BREATHING.",
			GameModeConfig.Classic.TotalDuration // 60,
			waveCount
		)
	elseif waveReached <= 0 then
		resultVerdict.Text = "IT WAS OVER BEFORE THE FIRST WAVE LANDED."
	else
		resultVerdict.Text = string.format("THE LIGHT WENT OUT ON WAVE %d.", waveReached)
	end

	if waveReached <= 0 then
		resultWave.Text = "REACHED   NO WAVES"
	else
		resultWave.Text = string.format(
			"REACHED   WAVE %d OF %d · %s",
			waveReached,
			waveCount,
			string.upper(GameModeConfig.getWave(waveReached).name)
		)
	end
	resultTime.Text = string.format("TIME SURVIVED   %s", clockText(elapsed))

	fillRows(payload and payload.scores)

	-- Confetti is the one flourish this game gets, and it is earned: surviving
	-- all seven waves is meant to be uncommon.
	if survived then
		burstConfetti()
	else
		clearConfetti()
	end

	state.results = true
	state.open = false
	state.returnAt = os.clock() + GameModeConfig.Matchmaking.PostRoundDuration
	state.returnShown = -1
	refreshVisibility()
end

-- ── open / close ────────────────────────────────────────────────────────────

function MainMenuController:open()
	if state.open then
		return
	end
	state.open = true
	state.results = false
	state.countdownShown = -1
	refreshLobby()
	refreshVisibility()
end

function MainMenuController:close()
	if not state.open then
		return
	end
	state.open = false
	refreshVisibility()
end

function MainMenuController:isOpen(): boolean
	return state.open or state.results
end

local function dismissResults()
	if not state.results then
		return
	end
	state.results = false
	clearConfetti()
	playUi(AudioConfig.UI.MenuBack)
	MainMenuController:open()
end

local function requestMode(mode: string)
	if state.teleporting then
		return
	end
	state.pending = mode
	state.pendingUntil = os.clock() + PENDING_TIMEOUT
	setMessage("")
	refreshEntries()
	Remotes.Event.RequestMode:FireServer(mode)
end

-- ── round state ─────────────────────────────────────────────────────────────

local function onRoundState(newState: string)
	if newState == state.roundState then
		return
	end
	state.roundState = newState

	if newState == ROUND.Starting or newState == ROUND.InProgress then
		resetStats()
		MainMenuController:close()
	elseif newState == ROUND.Lobby then
		state.committed = false
		-- The result screen owns the screen until it is done; a round that ended
		-- before this client connected has no result screen and gets the menu.
		if not state.results then
			MainMenuController:open()
		end
	end
end

-- ── the one frame loop ──────────────────────────────────────────────────────

local function applyEntryVisual(entry: any)
	local emphasis = math.max(entry.alpha, if entry.current then 0.35 else 0)
	entry.bar.BackgroundTransparency = 1 - emphasis
	entry.rule.BackgroundTransparency = 1 - (0.35 + 0.65 * emphasis)
	entry.line.TextTransparency = 0.35 - 0.35 * entry.alpha
end

local function updateFlicker(now: number)
	if now >= flicker.nextAt then
		flicker.endsAt = now + FLICKER_MIN_DURATION + math.random() * FLICKER_DURATION_RANGE
		flicker.depth = FLICKER_MIN_DEPTH + math.random() * FLICKER_DEPTH_RANGE
		flicker.nextAt = flicker.endsAt + FLICKER_MIN_GAP + math.random() * FLICKER_GAP_RANGE
	end

	local alpha = FLICKER_BASE + FLICKER_BREATH * (0.5 + 0.5 * math.sin(now * FLICKER_BREATH_SPEED))
	if now < flicker.endsAt then
		alpha += flicker.depth * (0.5 + 0.5 * math.sin(now * FLICKER_BUZZ_SPEED))
	end
	alpha = math.clamp(alpha, 0, FLICKER_MAX)

	titleLight.TextTransparency = alpha
	titleRule.BackgroundTransparency = alpha
end

--[[ The countdown is rendered from an absolute server-time stamp, so it stays
     smooth and correct with the server sending nothing per second. The text is
     only written when the whole number moves — otherwise this allocates a string
     sixty times a second to say the same thing. ]]
local function updateCountdown()
	if lobby.inProgress or not (state.committed or lobby.canStart) then
		return
	end

	local remaining = lobby.countdown
	if lobby.endsAt > 0 then
		remaining = lobby.endsAt - Workspace:GetServerTimeNow()
	end
	local whole = math.max(math.ceil(remaining), 0)
	if whole ~= state.countdownShown then
		state.countdownShown = whole
		lobbyBig.Text = string.format("%d", whole)
		lobbyBig.TextColor3 = if whole <= COUNTDOWN_URGENT then COLOR.AccentBright else COLOR.TextPrimary
	end
end

local function update(dt: number)
	if state.blur ~= state.blurTarget then
		local delta = state.blurTarget - state.blur
		if math.abs(delta) <= BLUR_EPSILON then
			state.blur = state.blurTarget
		else
			state.blur += delta * math.min(dt * BLUR_SPEED, 1)
		end
		blur.Size = state.blur
		blur.Enabled = state.blur > BLUR_EPSILON
	end

	if not (state.open or state.results) then
		return
	end

	local now = os.clock()

	for _, entry in modeEntries do
		local target = if entry.hovered then 1 else 0
		if entry.alpha ~= target then
			local delta = target - entry.alpha
			if math.abs(delta) <= HOVER_EPSILON then
				entry.alpha = target
			else
				entry.alpha += delta * math.min(dt * HOVER_SPEED, 1)
			end
			applyEntryVisual(entry)
		end
	end

	if state.open then
		updateFlicker(now)
		updateCountdown()

		if state.pending ~= "" and now >= state.pendingUntil then
			state.pending = ""
			setMessage("No answer from the server. Try again.")
			refreshEntries()
		end
		if state.messageUntil > 0 and now >= state.messageUntil then
			setMessage("")
		end
		return
	end

	-- Result screen: the clock back to the menu, and any confetti still in the air.
	updateConfetti(dt)

	local remaining = math.max(math.ceil(state.returnAt - now), 0)
	if remaining ~= state.returnShown then
		state.returnShown = remaining
		resultReturn.Text = string.format("BACK TO THE MENU IN %d", remaining)
	end
	if remaining <= 0 then
		dismissResults()
	end
end

-- ── build ───────────────────────────────────────────────────────────────────

local function buildTitle()
	local kicker = newLabel(menuLayer, "Kicker", FONT.Body, TEXT.Tiny, COLOR.TextDim)
	kicker.Position = UDim2.new(COLUMN_X, 0, 0.13, 0)
	kicker.Size = UDim2.new(0.5, 0, 0, TEXT.Body)
	kicker.Text = tracked("A CO-OP SURVIVAL SHOOTER")

	local fading = newLabel(menuLayer, "Fading", FONT.Stencil, TEXT.Title, COLOR.TextPrimary)
	fading.Position = UDim2.new(COLUMN_X, 0, 0.13, TEXT.Body + LAYOUT.ElementGap)
	fading.Size = UDim2.new(0.8, 0, 0, TITLE_LINE)
	fading.Text = "FADING"

	titleLight = newLabel(menuLayer, "Light", FONT.Stencil, TEXT.Title, COLOR.Accent)
	titleLight.Position = UDim2.new(COLUMN_X, 0, 0.13, TEXT.Body + LAYOUT.ElementGap + TITLE_LINE)
	titleLight.Size = UDim2.new(0.8, 0, 0, TITLE_LINE)
	titleLight.Text = "LIGHT"

	titleRule = newRule(menuLayer, "TitleRule", COLOR.Accent)
	titleRule.Position =
		UDim2.new(COLUMN_X, 0, 0.13, TEXT.Body + LAYOUT.ElementGap + TITLE_LINE * 2 + LAYOUT.PanelPadding)
	titleRule.Size = UDim2.new(0, TITLE_RULE_WIDTH, 0, LAYOUT.BorderThickness)
end

local function buildModes()
	for index, definition in MODE_ENTRIES do
		local button = newButton(menuLayer, definition.id)
		button.Position = UDim2.new(COLUMN_X, 0, 0.52, (index - 1) * (ENTRY_HEIGHT + ENTRY_GAP))
		button.Size = UDim2.new(ENTRY_WIDTH, 0, 0, ENTRY_HEIGHT)

		local rule = newRule(button, "Rule", COLOR.Border)

		local bar = newFrame(button, "Bar", COLOR.Accent, 1)
		bar.Position = UDim2.fromOffset(0, LAYOUT.BorderThickness)
		bar.Size = UDim2.new(0, ENTRY_BAR_WIDTH, 1, -LAYOUT.BorderThickness)

		local title = newLabel(button, "Title", FONT.Display, TEXT.Display, COLOR.TextPrimary)
		title.Position = UDim2.fromOffset(ENTRY_TEXT_INSET, LAYOUT.PanelPadding)
		title.Size = UDim2.new(1, -ENTRY_TEXT_INSET, 0, TEXT.Display + 6)
		title.Text = definition.title

		local line = newLabel(button, "Line", FONT.Body, TEXT.Body, COLOR.TextSecondary)
		line.Position = UDim2.fromOffset(ENTRY_TEXT_INSET + 2, LAYOUT.PanelPadding + TEXT.Display + 8)
		line.Size = UDim2.new(1, -ENTRY_TEXT_INSET, 0, TEXT.Body + 4)
		line.Text = definition.line
		line.TextTransparency = 0.35

		local tag = newLabel(button, "Tag", FONT.Body, TEXT.Tiny, COLOR.TextDim)
		tag.AnchorPoint = Vector2.new(1, 0)
		tag.Position = UDim2.new(1, 0, 0, LAYOUT.PanelPadding + 6)
		tag.Size = UDim2.new(0.5, 0, 0, TEXT.Body)
		tag.TextXAlignment = Enum.TextXAlignment.Right

		local entry = {
			id = definition.id,
			button = button,
			bar = bar,
			rule = rule,
			title = title,
			line = line,
			tag = tag,
			hovered = false,
			current = false,
			alpha = 0,
		}

		trove:connect(button.MouseEnter, function()
			entry.hovered = true
			title.TextColor3 = COLOR.AccentBright
			playUi(AudioConfig.UI.MenuHover)
		end)
		trove:connect(button.MouseLeave, function()
			entry.hovered = false
			title.TextColor3 = COLOR.TextPrimary
		end)
		trove:connect(button.Activated, function()
			requestMode(entry.id)
		end)

		applyEntryVisual(entry)
		table.insert(modeEntries, entry)
	end
end

local function buildLobby()
	local panel = newFrame(menuLayer, "Lobby", COLOR.Background, 1)
	panel.AnchorPoint = Vector2.new(1, 0)
	panel.Position = UDim2.new(1 - COLUMN_X, 0, 0.15, 0)
	panel.Size = UDim2.new(0.3, 0, 0, 260)

	local heading = newLabel(panel, "Heading", FONT.Body, TEXT.Tiny, COLOR.TextDim)
	heading.Size = UDim2.new(1, 0, 0, TEXT.Body)
	heading.TextXAlignment = Enum.TextXAlignment.Right
	heading.Text = tracked("LOBBY")

	local rule = newRule(panel, "Rule", COLOR.Border)
	rule.Position = UDim2.fromOffset(0, TEXT.Body + LAYOUT.ElementGap)

	lobbyBig = newLabel(panel, "Countdown", FONT.Display, TEXT.Title, COLOR.Accent)
	lobbyBig.Position = UDim2.fromOffset(0, TEXT.Body + LAYOUT.ElementGap * 2)
	lobbyBig.Size = UDim2.new(1, 0, 0, TITLE_LINE)
	lobbyBig.TextXAlignment = Enum.TextXAlignment.Right
	lobbyBig.Text = "—"

	lobbyCaption = newLabel(panel, "Caption", FONT.Body, TEXT.Small, COLOR.TextSecondary)
	lobbyCaption.Position = UDim2.fromOffset(0, TEXT.Body + LAYOUT.ElementGap * 2 + TITLE_LINE)
	lobbyCaption.Size = UDim2.new(1, 0, 0, TEXT.Body)
	lobbyCaption.TextXAlignment = Enum.TextXAlignment.Right

	lobbyMode = newLabel(panel, "Mode", FONT.Heading, TEXT.Large, COLOR.TextPrimary)
	lobbyMode.Position = UDim2.fromOffset(0, TEXT.Body + LAYOUT.ElementGap * 3 + TITLE_LINE + TEXT.Body)
	lobbyMode.Size = UDim2.new(1, 0, 0, TEXT.Large + 4)
	lobbyMode.TextXAlignment = Enum.TextXAlignment.Right

	lobbyPlayers = newLabel(panel, "Players", FONT.Body, TEXT.Small, COLOR.TextSecondary)
	lobbyPlayers.Position =
		UDim2.fromOffset(0, TEXT.Body + LAYOUT.ElementGap * 3 + TITLE_LINE + TEXT.Body + TEXT.Large + 6)
	lobbyPlayers.Size = UDim2.new(1, 0, 0, TEXT.Body)
	lobbyPlayers.TextXAlignment = Enum.TextXAlignment.Right

	lobbyMessage = newLabel(panel, "Message", FONT.Body, TEXT.Small, COLOR.Accent)
	lobbyMessage.AnchorPoint = Vector2.new(1, 0)
	lobbyMessage.Position = UDim2.new(1, 0, 1, LAYOUT.ElementGap)
	lobbyMessage.Size = UDim2.new(1.6, 0, 0, TEXT.Body * 3)
	lobbyMessage.TextXAlignment = Enum.TextXAlignment.Right
	lobbyMessage.TextYAlignment = Enum.TextYAlignment.Top
	lobbyMessage.TextWrapped = true
end

local function buildSettingCell(row: Instance, definition: any): any
	local holder = newButton(row, definition.key)
	holder.Size = UDim2.new(0, definition.width, 1, 0)

	local label = newLabel(holder, "Label", FONT.Body, TEXT.Tiny, COLOR.TextDim)
	label.Size = UDim2.new(1, 0, 0, TEXT.Body)
	label.Text = tracked(definition.label)

	local value = newLabel(holder, "Value", FONT.Heading, TEXT.Body, COLOR.TextPrimary)
	value.Position = UDim2.fromOffset(0, TEXT.Body + 2)
	value.Size = UDim2.new(1, 0, 0, TEXT.Large)

	local cell = { definition = definition, button = holder, value = value, track = nil, fill = nil }

	if definition.kind == "slider" then
		local track = newFrame(holder, "Track", COLOR.Border, 0)
		track.Position = UDim2.fromOffset(0, TEXT.Body + TEXT.Large + 6)
		track.Size = UDim2.new(1, -LAYOUT.PanelPadding, 0, LAYOUT.BorderThickness * 2)
		cell.track = track
		cell.fill = newFrame(track, "Fill", COLOR.Accent, 0)
		cell.fill.Size = UDim2.new(0, 0, 1, 0)

		-- The whole cell is the hit area: a one-pixel rule is a rule, not a
		-- target, and nobody should have to aim at it.
		trove:connect(holder.InputBegan, function(input: InputObject)
			if
				input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch
			then
				dragging = cell
				dragSetting(cell, input.Position.X)
			end
		end)
	else
		trove:connect(holder.Activated, function()
			cycleSetting(definition)
		end)
	end

	trove:connect(holder.MouseEnter, function()
		value.TextColor3 = COLOR.AccentBright
	end)
	trove:connect(holder.MouseLeave, function()
		value.TextColor3 = COLOR.TextPrimary
	end)

	return cell
end

local function buildSettings()
	local row = newFrame(menuLayer, "Settings", COLOR.Background, 1)
	row.AnchorPoint = Vector2.new(0, 1)
	row.Position = UDim2.new(COLUMN_X, 0, 1, -LAYOUT.ScreenMargin * 2)
	row.Size = UDim2.new(0.85, 0, 0, TEXT.Body + TEXT.Large + LAYOUT.PanelPadding + 6)

	local rule = newRule(row, "Rule", COLOR.Border)
	rule.Position = UDim2.fromOffset(0, -LAYOUT.PanelPadding)
	rule.Size = UDim2.new(0, TITLE_RULE_WIDTH, 0, LAYOUT.BorderThickness)

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, LAYOUT.ScreenMargin * 2)
	layout.Parent = row

	for index, definition in SETTING_DEFS do
		local cell = buildSettingCell(row, definition)
		cell.button.LayoutOrder = index
		table.insert(settingCells, cell)
	end
end

local function buildTeleport()
	teleportRoot = newFrame(gui, "Teleport", COLOR.Background, 0)
	teleportRoot.Size = UDim2.fromScale(1, 1)
	teleportRoot.ZIndex = 4
	teleportRoot.Visible = false
	teleportLayer = newLayer(teleportRoot)

	local title = newLabel(teleportLayer, "Title", FONT.Stencil, TEXT.Display, COLOR.TextPrimary)
	title.AnchorPoint = Vector2.new(0.5, 1)
	title.Position = UDim2.fromScale(0.5, 0.5)
	title.Size = UDim2.new(0.8, 0, 0, TEXT.Display + 10)
	title.TextXAlignment = Enum.TextXAlignment.Center
	title.ZIndex = 4
	title.Text = "HOLD ON"

	local rule = newRule(teleportLayer, "Rule", COLOR.Accent)
	rule.AnchorPoint = Vector2.new(0.5, 0)
	rule.Position = UDim2.new(0.5, 0, 0.5, LAYOUT.PanelPadding)
	rule.Size = UDim2.new(0, TITLE_RULE_WIDTH, 0, LAYOUT.BorderThickness)
	rule.ZIndex = 4

	local line = newLabel(teleportLayer, "Line", FONT.Body, TEXT.Large, COLOR.TextSecondary)
	line.AnchorPoint = Vector2.new(0.5, 0)
	line.Position = UDim2.new(0.5, 0, 0.5, LAYOUT.PanelPadding * 3)
	line.Size = UDim2.new(0.8, 0, 0, TEXT.Large + 6)
	line.TextXAlignment = Enum.TextXAlignment.Center
	line.ZIndex = 4
	line.Text = "MOVING YOU TO ANOTHER SERVER"
end

local function buildResultRow(index: number): any
	local frame = newFrame(resultsLayer, "Row" .. index, COLOR.Background, 1)
	frame.Position = UDim2.new(COLUMN_X, 0, 0.5, (index - 1) * RESULT_ROW_HEIGHT)
	frame.Size = UDim2.new(1 - COLUMN_X * 2, 0, 0, RESULT_ROW_HEIGHT)
	frame.Visible = false

	local name = newLabel(frame, "Name", FONT.Heading, TEXT.Large, COLOR.TextPrimary)
	name.Size = UDim2.new(NAME_WIDTH, 0, 1, 0)

	local cells = {}
	for column, definition in STAT_COLUMNS do
		local label = newLabel(frame, definition.key, FONT.Numeric, TEXT.Body, COLOR.TextSecondary)
		label.Position = UDim2.fromScale(NAME_WIDTH + COLUMN_WIDTH * (column - 1), 0)
		label.Size = UDim2.new(COLUMN_WIDTH, 0, 1, 0)
		label.TextXAlignment = Enum.TextXAlignment.Right
		table.insert(cells, { key = definition.key, label = label })
	end

	local status = newLabel(frame, "Status", FONT.Body, TEXT.Small, COLOR.TextSecondary)
	status.Position = UDim2.fromScale(1 - STATUS_WIDTH, 0)
	status.Size = UDim2.new(STATUS_WIDTH, 0, 1, 0)
	status.TextXAlignment = Enum.TextXAlignment.Right

	local rule = newRule(frame, "Rule", COLOR.Border)
	rule.Position = UDim2.new(0, 0, 1, -LAYOUT.BorderThickness)
	rule.BackgroundTransparency = 0.55

	return { frame = frame, name = name, status = status, cells = cells }
end

local function buildResults()
	resultsRoot = newFrame(gui, "Results", COLOR.Background, RESULTS_SCRIM)
	resultsRoot.Size = UDim2.fromScale(1, 1)
	resultsRoot.ZIndex = 2
	resultsRoot.Visible = false
	resultsLayer = newLayer(resultsRoot)

	--[[ Confetti sits in its own unscaled layer directly on the results root, not
	     inside the scaled poster layout: a burst should fill the actual screen at
	     any resolution rather than being shrunk along with the type. ]]
	confettiLayer = newFrame(resultsRoot, "Confetti", COLOR.Background, 1)
	confettiLayer.Size = UDim2.fromScale(1, 1)
	confettiLayer.ClipsDescendants = true
	confettiLayer.ZIndex = 3
	buildConfetti()

	resultOutcome = newLabel(resultsLayer, "Outcome", FONT.Stencil, TEXT.Title, COLOR.TextPrimary)
	resultOutcome.Position = UDim2.new(COLUMN_X, 0, 0.14, 0)
	resultOutcome.Size = UDim2.new(0.8, 0, 0, TITLE_LINE)
	resultOutcome.ZIndex = 2

	resultVerdict = newLabel(resultsLayer, "Verdict", FONT.Body, TEXT.Large, COLOR.TextSecondary)
	resultVerdict.Position = UDim2.new(COLUMN_X, 0, 0.14, TITLE_LINE)
	resultVerdict.Size = UDim2.new(0.8, 0, 0, TEXT.Large + 6)
	resultVerdict.ZIndex = 2

	local rule = newRule(resultsLayer, "Rule", COLOR.Accent)
	rule.Position = UDim2.new(COLUMN_X, 0, 0.14, TITLE_LINE + TEXT.Large + LAYOUT.PanelPadding * 2)
	rule.Size = UDim2.new(0, TITLE_RULE_WIDTH, 0, LAYOUT.BorderThickness)
	rule.ZIndex = 2

	resultWave = newLabel(resultsLayer, "Wave", FONT.Heading, TEXT.Heading, COLOR.TextPrimary)
	resultWave.Position = UDim2.new(COLUMN_X, 0, 0.32, 0)
	resultWave.Size = UDim2.new(0.8, 0, 0, TEXT.Heading + 6)
	resultWave.ZIndex = 2

	resultTime = newLabel(resultsLayer, "Time", FONT.Heading, TEXT.Heading, COLOR.TextPrimary)
	resultTime.Position = UDim2.new(COLUMN_X, 0, 0.32, TEXT.Heading + LAYOUT.ElementGap)
	resultTime.Size = UDim2.new(0.8, 0, 0, TEXT.Heading + 6)
	resultTime.ZIndex = 2

	-- Column headings, one row above the first player.
	local header = newFrame(resultsLayer, "Header", COLOR.Background, 1)
	header.Position = UDim2.new(COLUMN_X, 0, 0.5, -RESULT_ROW_HEIGHT)
	header.Size = UDim2.new(1 - COLUMN_X * 2, 0, 0, RESULT_ROW_HEIGHT)
	header.ZIndex = 2

	local headerName = newLabel(header, "Name", FONT.Body, TEXT.Tiny, COLOR.TextDim)
	headerName.Size = UDim2.new(NAME_WIDTH, 0, 1, 0)
	headerName.Text = tracked("SURVIVORS")

	for column, definition in STAT_COLUMNS do
		local label = newLabel(header, definition.key, FONT.Body, TEXT.Tiny, COLOR.TextDim)
		label.Position = UDim2.fromScale(NAME_WIDTH + COLUMN_WIDTH * (column - 1), 0)
		label.Size = UDim2.new(COLUMN_WIDTH, 0, 1, 0)
		label.TextXAlignment = Enum.TextXAlignment.Right
		label.Text = definition.title
	end

	for index = 1, MAX_ROWS do
		table.insert(resultRows, buildResultRow(index))
	end

	local continue = newButton(resultsLayer, "Continue")
	continue.AnchorPoint = Vector2.new(0, 1)
	continue.Position = UDim2.new(COLUMN_X, 0, 1, -LAYOUT.ScreenMargin * 2)
	continue.Size = UDim2.new(0.3, 0, 0, TEXT.Display + LAYOUT.PanelPadding)
	continue.ZIndex = 2

	local continueRule = newRule(continue, "Rule", COLOR.Border)
	continueRule.ZIndex = 2

	resultContinue = newLabel(continue, "Label", FONT.Display, TEXT.Display, COLOR.TextPrimary)
	resultContinue.Position = UDim2.fromOffset(0, LAYOUT.PanelPadding)
	resultContinue.Size = UDim2.new(1, 0, 0, TEXT.Display + 4)
	resultContinue.ZIndex = 2
	resultContinue.Text = "MAIN MENU"

	trove:connect(continue.MouseEnter, function()
		resultContinue.TextColor3 = COLOR.AccentBright
	end)
	trove:connect(continue.MouseLeave, function()
		resultContinue.TextColor3 = COLOR.TextPrimary
	end)
	trove:connect(continue.Activated, dismissResults)

	resultReturn = newLabel(resultsLayer, "Return", FONT.Body, TEXT.Small, COLOR.TextDim)
	resultReturn.AnchorPoint = Vector2.new(1, 1)
	resultReturn.Position = UDim2.new(1 - COLUMN_X, 0, 1, -LAYOUT.ScreenMargin * 2)
	resultReturn.Size = UDim2.new(0.4, 0, 0, TEXT.Body)
	resultReturn.TextXAlignment = Enum.TextXAlignment.Right
	resultReturn.ZIndex = 2
end

--[[ Bound to the viewport's changed signal rather than sampled per frame: a
     window is resized about as often as it is created. ]]
local function refreshScale()
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	local height = camera.ViewportSize.Y
	if height <= 0 then
		return
	end

	local factor = math.clamp(height / REFERENCE_HEIGHT, MIN_SCALE, MAX_SCALE)
	local inverse = UDim2.fromScale(1 / factor, 1 / factor)
	for _, layer in layers do
		layer.scale.Scale = factor
		layer.frame.Size = inverse
	end
end

--[[ The viewport signal belongs to the camera, and the camera is replaced on
     death, on spectate and on a rejoin. One connection, re-pointed each time,
     rather than one more every time the camera changes. ]]
local viewportConnection: RBXScriptConnection? = nil

function watchViewport()
	if viewportConnection then
		viewportConnection:Disconnect()
		viewportConnection = nil
	end
	local camera = Workspace.CurrentCamera
	if camera then
		viewportConnection = camera:GetPropertyChangedSignal("ViewportSize"):Connect(refreshScale)
	end
	refreshScale()
end

local function build()
	gui = Instance.new("ScreenGui")
	gui.Name = "FL_MainMenu"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = MENU_ORDER
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Enabled = false
	gui.Parent = player:WaitForChild("PlayerGui")
	trove:add(gui)

	menuRoot = newFrame(gui, "Menu", COLOR.Background, MENU_SCRIM)
	menuRoot.Size = UDim2.fromScale(1, 1)
	menuRoot.Visible = false
	menuLayer = newLayer(menuRoot)

	trove:add(function()
		if viewportConnection then
			viewportConnection:Disconnect()
			viewportConnection = nil
		end
	end)

	blur = Instance.new("BlurEffect")
	blur.Name = "FL_MainMenu"
	blur.Size = 0
	blur.Enabled = false
	blur.Parent = Lighting
	trove:add(blur)

	--[[ The mixer bus. Everything the client plays under SoundService is adopted
	     into it, which is what makes the volume slider mean something without
	     every controller having to know it exists. ]]
	masterGroup = Instance.new("SoundGroup")
	masterGroup.Name = "FL_Master"
	masterGroup.Volume = AudioConfig.Mix.MasterVolume
	masterGroup.Parent = SoundService
	trove:add(masterGroup)

	buildTitle()
	buildModes()
	buildLobby()
	buildSettings()
	buildResults()
	buildTeleport()

	refreshScale()
end

local function adopt(instance: Instance)
	if instance:IsA("Sound") and instance.SoundGroup == nil then
		instance.SoundGroup = masterGroup
	end
end

-- ── public API ──────────────────────────────────────────────────────────────

function MainMenuController:getSetting(key: string): any
	return settings[key]
end

--[[ Programmatic set, for anything that grows an in-game options screen later.
     Values are validated against the same definitions the menu uses, so nothing
     can push a string into the sensitivity or an unknown gore level. ]]
function MainMenuController:setSetting(key: string, value: any): boolean
	for _, definition in SETTING_DEFS do
		if definition.key ~= key then
			continue
		end
		if definition.kind == "toggle" and typeof(value) == "boolean" then
			setSetting(key, value, true)
			return true
		elseif definition.kind == "choice" and table.find(definition.options, value) then
			setSetting(key, value, true)
			return true
		elseif definition.kind == "slider" and typeof(value) == "number" then
			setSetting(key, math.clamp(value, definition.min, definition.max), true)
			return true
		end
		return false
	end
	return false
end

function MainMenuController:getLobbyState(): any
	return table.clone(lobby)
end

--[[ Shows the result screen by hand. Only for a developer checking the layout
     without dying seven waves in. ]]
function MainMenuController:showResults(payload: any)
	showResults(payload)
end

-- ── lifecycle ───────────────────────────────────────────────────────────────

function MainMenuController:init()
	build()

	for _, definition in SETTING_DEFS do
		settings[definition.key] = loadSetting(definition.key, definition.default)
	end
	for _, cell in settingCells do
		refreshCell(cell)
	end

	-- The round may already be running when this client arrives; read it quietly
	-- so the first real transition is the first thing that moves the menu.
	state.roundState = Attributes.get(Workspace, GA.RoundState, ROUND.Lobby)
	refreshLobby()
end

function MainMenuController:start()
	for _, definition in SETTING_DEFS do
		applySetting(definition.key, settings[definition.key])
	end
	for _, instance in SoundService:GetDescendants() do
		adopt(instance)
	end
	trove:connect(SoundService.DescendantAdded, adopt)

	trove:connect(Remotes.Event.LobbyStateChanged.OnClientEvent, onLobbyState)
	trove:connect(Remotes.Event.RoundEnded.OnClientEvent, showResults)
	trove:connect(Remotes.Event.HitConfirmed.OnClientEvent, onHitConfirmed)
	trove:connect(Remotes.Event.DamageTaken.OnClientEvent, onDamageTaken)
	trove:connect(Remotes.Event.SurvivorStateChanged.OnClientEvent, onSurvivorStateChanged)

	trove:connect(Remotes.Event.StatsUpdated.OnClientEvent, function(payload: any)
		if typeof(payload) ~= "table" then
			return
		end
		local subject = payload.player
		local name = if typeof(subject) == "Instance" and subject:IsA("Player")
			then subject.Name
			else tostring(subject)
		mergeStats(name, payload.stats or payload)
	end)

	--[[ Both the remote and the Workspace attribute report the same transition;
	     whichever lands first moves the menu and the other is a no-op. ]]
	trove:connect(Remotes.Event.RoundStateChanged.OnClientEvent, function(payload: any)
		if typeof(payload) == "table" and typeof(payload.state) == "string" then
			onRoundState(payload.state)
		end
	end)
	trove:connect(Workspace:GetAttributeChangedSignal(GA.RoundState), function()
		onRoundState(Attributes.get(Workspace, GA.RoundState, ROUND.Lobby))
	end)

	trove:connect(player:GetAttributeChangedSignal(PA.ReviveProgress), noteHelpProgress)
	trove:connect(player:GetAttributeChangedSignal(PA.State), reassertFreeCursor)

	--[[ MatchmakingService teleports a player to another server without sending
	     them anything first, so the engine's own signal is the only warning this
	     screen gets. Without it the player's game simply stops responding. ]]
	trove:connect(player.OnTeleport, function(teleportState: Enum.TeleportState)
		if teleportState == Enum.TeleportState.Failed then
			state.teleporting = false
			state.pending = ""
			setMessage("That server could not be reached. Pick a mode to play here.")
		else
			state.teleporting = true
		end
		refreshVisibility()
	end)

	trove:connect(UserInputService.InputChanged, function(input: InputObject)
		if
			dragging
			and (
				input.UserInputType == Enum.UserInputType.MouseMovement
				or input.UserInputType == Enum.UserInputType.Touch
			)
		then
			dragSetting(dragging, input.Position.X)
		end
	end)
	trove:connect(UserInputService.InputEnded, function(input: InputObject)
		if
			input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
		then
			dragging = nil
		end
	end)

	watchViewport()
	trove:connect(Workspace:GetPropertyChangedSignal("CurrentCamera"), watchViewport)

	trove:connect(RunService.RenderStepped, update)

	-- The menu is what a player arrives to, whatever this server is doing.
	self:open()
end

--[[ The join-time snapshot. A player who loaded into a server that is already
     mid-round gets a menu that says so, rather than one that claims the lobby is
     empty until the next broadcast. ]]
function MainMenuController:onInitialState(payload: any)
	if typeof(payload) ~= "table" then
		return
	end
	if typeof(payload.lobby) == "table" then
		onLobbyState(payload.lobby)
	end
	if typeof(payload.roundState) == "string" then
		state.roundState = payload.roundState
		lobby.inProgress = payload.roundState == ROUND.InProgress or payload.roundState == ROUND.Starting
	end
	refreshLobby()
end

function MainMenuController:destroy()
	setSuppressed(false)
	table.clear(modeEntries)
	table.clear(settingCells)
	table.clear(resultRows)
	table.clear(uiSounds)
	trove:destroy()
end

Registry.register("MainMenuController", MainMenuController)

return MainMenuController
