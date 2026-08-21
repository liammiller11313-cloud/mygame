--!nonstrict
--[[
	MainMenuController — the poster the game opens on, and the one it closes on.

	This is the first thing anybody sees, so it is not a game UI. It is a worn
	movie poster: a black field, a handful of white words, and exactly one orange
	thing telling you where to look. Two mode entries, a countdown, one line into
	the settings, and nothing else. Every box that is not on this screen was left
	off on purpose.

	── THE TITLE ───────────────────────────────────────────────────────────────
	FADING in white, LIGHT in orange underneath it, both in UITheme.Font.Stencil
	— the battered typewriter face — and the word LIGHT flickers like a tube
	about to go. It is on the nose, and a zombie game title screen is the one
	place where on the nose is the correct choice.

	The flicker is a handful of scalars driven off the single RenderStepped this
	controller owns: no tween objects, no per-element connections, and nothing
	allocated per frame anywhere in the loop. Every property written in `update`
	is a number.

	── WHAT IS DELIBERATELY NOT IN THIS FILE ───────────────────────────────────
	The title flicker (UI/TitleFlicker) and the victory confetti (UI/Confetti)
	are both driven from `update` here but live in their own modules, and that
	split is load-bearing rather than tidiness.

	Luau allows 200 locals per FUNCTION SCOPE and a module's top level is one
	scope. This file once carried both subsystems' tuning constants alongside its
	own, reached 205, and stopped compiling — the main menu simply never appeared
	and the error was one line in the client's require log:

	    MainMenuController:1930: Out of local registers when trying to allocate
	    layoutColumns: exceeded limit 200

	It is invisible to stylua and selene because the source is entirely valid; it
	just cannot be turned into bytecode. `scripts/audit.py` now counts top-level
	locals and fails well before 200, so the next screen this grows says so in
	CI rather than at the player. If this file needs a new subsystem, give it a
	module — do not shave two constants to fit.

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
	    assigns them a group. The SETTING itself belongs to SettingsController,
	    which owns every preference in the game and draws the panel this screen's
	    SETTINGS line opens; only the bus lives here.
]]

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attributes = require(Shared.Net.Attributes)
local AudioConfig = require(Shared.Config.AudioConfig)
local EconomyConfig = require(Shared.Config.EconomyConfig)
local Enums = require(Shared.Enums)
local GameModeConfig = require(Shared.Config.GameModeConfig)
local MapConfig = require(Shared.Config.MapConfig)
local Registry = require(Shared.Util.Registry)
local Remotes = require(Shared.Net.Remotes)
local Trove = require(Shared.Util.Trove)
local UITheme = require(Shared.Config.UITheme)

local GamepadFocus = require(script.Parent.GamepadFocus)
local Widgets = require(script.Parent.Widgets)
local UiSound = require(script.Parent.UiSound)
local FreeCursor = require(script.Parent.FreeCursor)
local LobbyClock = require(script.Parent.LobbyClock)
local Confetti = require(script.Parent.Confetti)
local TitleFlicker = require(script.Parent.TitleFlicker)

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

--[[ The menu covers everything the game draws — including OverlayController's
     end-of-round card at Overlay — and is in turn covered by the map vote and
     by the fade that ends a teleport. ]]
local MENU_ORDER = UITheme.DisplayOrder.Menu

--[[ The layout is drawn against a 900px-tall viewport and scaled from there, so
     the poster keeps its proportions on a phone and on a 4K monitor instead of
     turning into a wall of type or a stamp in the corner. The menu keeps its own
     layer list — it has several, and they fade independently — but the FACTOR
     comes from UITheme so the menu and the HUD are never drawn at two different
     sizes across the same transition. ]]

--[[ Not fully opaque: the blurred world stays faintly visible behind the black,
     which is the difference between a menu that sits in front of the game and a
     menu that replaced it. ]]
local MENU_SCRIM = 0.04
local RESULTS_SCRIM = 0.02

local BLUR_SIZE = 26
-- UITheme's durations, expressed as the chase rates the frame loop wants.
local BLUR_SPEED = 1 / MOTION.Normal
local BLUR_EPSILON = 0.05

-- The left margin every headline, rule and mode entry lines up against.
local COLUMN_X = 0.09
local TITLE_LINE = TEXT.Title + 6
local TITLE_RULE_WIDTH = 300

--[[
	PLAY, and the page behind it.

	The menu used to open straight onto the mode list, which put a decision in
	front of a player before they had been shown anything: two entries with
	nothing above them but a title, and nothing to suggest that SHOP and LOADOUTS
	were things you might want to do FIRST. The mode list is one press deep now,
	behind a single button that says what the game is for.

	Nothing about matchmaking changed — pressing a mode still sends RequestMode
	and the server still decides which server or round you land in. This only
	moved WHEN the question is asked.
]]
local PLAY_HEIGHT = 110
local PLAY_HEIGHT_COMPACT = 64
--[[ Under LAYOUT.ScreenMargin, because that gap is where it lives — see where it
     is positioned. Wide to stay tappable at the height that leaves it. ]]
local BACK_HEIGHT = 18
local BACK_WIDTH = 0.26

local ENTRY_HEIGHT = 88
local ENTRY_GAP = 20
local ENTRY_WIDTH = 0.44
local ENTRY_BAR_WIDTH = 3
local ENTRY_TEXT_INSET = 20

local HOVER_SPEED = 1 / MOTION.FastOut
local HOVER_EPSILON = 0.004

--[[ How long the menu waits for the server to answer a mode request before it
     stops saying SEARCHING. The only slow path is a MemoryStore browse plus a
     teleport attempt; past this something went wrong and silence is the worst
     possible answer. ]]
local PENDING_TIMEOUT = 14
local MESSAGE_LIFETIME = 9

-- The countdown turns orange here. The last ten seconds are the only ones
-- anybody actually counts, and that is when the number should start shouting.
local COUNTDOWN_URGENT = 10

local NO_DATA = "—"
local RESULT_ROW_HEIGHT = 30
local MAX_ROWS = math.max(GameModeConfig.Classic.MaxPlayers, GameModeConfig.Versus.MaxPlayers)

--[[ A revive is credited when the local player's hold bar was most of the way
     full and then released, AND a teammate stood up right afterwards. See
     `noteHelpProgress` for why it cannot simply watch for progress hitting 1. ]]
local HELP_NEAR_COMPLETE = 0.5
local HELP_WINDOW = 0.75

local MainMenuController = {}

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
--[[ The victory burst, built with the results screen. See UI/Confetti.

     Non-nil from `build()` in init() onward, and the frame loop that steps it is
     only connected in start() — Registry runs every init() before any start(),
     so there is no window where `update` can reach this before it exists. Move
     the RenderStepped connection into init() and that stops being true. ]]
local confetti
local teleportRoot: Frame
local teleportLayer: Frame

--[[ Every scaled content layer, and the UIScale driving it. See `newLayer`. ]]
local layers: { { frame: Frame, scale: UIScale } } = {}

local titleKicker: TextLabel
local titleFading: TextLabel
local titleLight: TextLabel
local titleRule: Frame
local briefingColumn: Frame
local navRow: Frame
local navEntries: { any } = {}

local modeEntries: { any } = {}

local lobbyBig: TextLabel
local lobbyCaption: TextLabel
local lobbyMode: TextLabel
local lobbyMap: TextLabel
local lobbyPlayers: TextLabel
local lobbyMessage: TextLabel
local balanceLabel: TextLabel

local resultOutcome: TextLabel
local resultVerdict: TextLabel
local resultWave: TextLabel
local resultTime: TextLabel
local resultPayout: TextLabel
local resultPayoutLine: TextLabel
local payoutShown: any = nil
local resultRows: { any } = {}
local resultContinue: TextLabel
--[[ The buttons a controller lands on when each screen opens. Held rather than
     looked up, because "the first mode entry" and "the continue button" are the
     only two answers and searching the tree for them every time would be a
     lookup that can silently start returning the wrong thing. ]]
local firstModeButton: TextButton? = nil
local playButton: TextButton? = nil
local playLine: TextLabel? = nil
local backButton: TextButton? = nil
local resultContinueButton: TextButton? = nil
local resultReturn: TextLabel

local masterGroup: SoundGroup

-- Defined down with the build helpers; declared here so `start` can reach it.
local watchViewport: () -> ()

-- ── state ───────────────────────────────────────────────────────────────────

local state = {
	open = false,
	results = false,
	suppressed = false,
	committed = false, -- the server has admitted this player to the round
	--[[ Which page of the menu is up: "Root" is PLAY plus the nav row, "Modes"
	     is the mode list. One field rather than a pile of booleans, so the menu
	     can never be half way between the two. ]]
	page = "Root",
	teleporting = false,
	roundState = ROUND.Lobby,
	--[[ A map vote is on screen. Pushed in by MapVoteController rather than
	     polled, because the menu has no reason to know when votes happen and
	     every reason to get out of the way when one does. ]]
	voteOpen = false,

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
	--[[ The lobby is deliberately not counting down because nobody in this
	     server has picked a mode yet. Starts true so a menu built before the
	     first LobbyStateChanged says CHOOSE A MODE rather than flashing a
	     countdown state it has no numbers for. ]]
	awaitingChoice = true,
	inProgress = false,
	waveIndex = 0,
	joinable = true,
}

local flicker = TitleFlicker.new()

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

local restore = {
	--[[ Owned here, written by FreeCursor — these screens nest, so a shared slot
	     would have the inner one hand back the outer one's camera. ]]
	cameraMode = nil :: any,
	cameraZoom = nil :: any,
	cameraMinZoom = nil :: any,
	mouseIcon = nil :: any,
}

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

--[[ A hairline. Every division on this screen is one pixel of border or accent —
     never a panel, never a card, and never a drop shadow. ]]
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
	local frame = Widgets.frame(parent, "Layer", COLOR.Background, 1)
	frame.Size = UDim2.fromScale(1, 1)

	local scale = Instance.new("UIScale")
	scale.Parent = frame

	table.insert(layers, { frame = frame, scale = scale })
	return frame
end

-- ── the master bus ──────────────────────────────────────────────────────────

--[[
	The mixer bus, and the one piece of the options that lives here.

	SettingsController owns every preference in the game — see its header — but
	the SoundGroup every client sound is adopted into is built and held by this
	controller, because adoption happens the moment a sound appears and the menu
	is what is on screen when the first ones do. So the volume setting is pushed
	in here rather than the group being handed out.
]]
function MainMenuController:setMasterVolume(value: number)
	if not masterGroup then
		return
	end
	local wanted = if typeof(value) == "number" and value == value then math.clamp(value, 0, 1) else 1
	masterGroup.Volume = wanted
end

-- ── suppression: what the menu does to the rest of the client ───────────────

--[[
	CameraController re-applies LockFirstPerson every time the survivor state
	changes, and LockFirstPerson pins the cursor to the centre of the screen —
	which, landing while the menu is up, made everything on it unclickable.

	This used to be a deferred re-take that raced CameraController's own handler
	and hoped to land after it. It no longer has to: CameraController asks
	FreeCursor whether a screen is holding the mouse and stands down while one
	is, so the camera is never taken back from underneath this menu in the first
	place. Kept as a call site because the menu still wants a hook here, and
	because a no-op with a reason beats deleting the connection and rediscovering
	why it existed.
]]
local function reassertFreeCursor()
	if not state.suppressed then
		return
	end
	--[[ Idempotent: FreeCursor counts a screen once however many times it takes,
	     and the properties it writes are the ones already in force. ]]
	FreeCursor.take(restore)
end

--[[ Everything the menu takes over while it is on screen, in one place so it can
     never be half-applied. The HUD is hidden through setVisible rather than
     setCinematic: OverlayController owns the cinematic flag for its end-of-round
     card, and two owners for one boolean is how a HUD ends up stuck off. ]]
--[[ What the menu takes away from the rest of the client, as one call. Split out
     of setSuppressed so it can be re-asserted: the settings panel suppresses the
     same things when it opens over a live round, and handing them back when it
     closes would hand them back over a menu that is still up. ]]
local function pushSuppression(value: boolean)
	callController("HudController", "setVisible", not value)
	callController("CrosshairController", "setVisible", not value)
	callController("PromptController", "setEnabled", not value)
	callController("InputController", "setEnabled", not value)
	-- The touch pad goes with the HUD. Leaving fire buttons live under a menu is
	-- how a phone player shoots the scoreboard.
	callController("TouchController", "setVisible", not value)
	--[[ Same reasoning as the pad: a pause button floating over the scoreboard
	     belongs to neither screen. It has to be told rather than working it out —
	     this menu's backdrop is a plain Frame, and a Frame does not block input
	     in Roblox, so an untold button would sit invisible behind the menu and
	     still be pressable. ]]
	callController("PauseController", "setButtonVisible", not value)
end

local function setSuppressed(value: boolean)
	if state.suppressed == value then
		return
	end
	state.suppressed = value

	pushSuppression(value)

	state.blurTarget = if value then BLUR_SIZE else 0

	if value then
		FreeCursor.take(restore)
	else
		FreeCursor.giveBack(restore)
	end
end

local function refreshVisibility()
	--[[
		The menu is never hidden by a map vote. The vote draws OVER it, which is
		what its display order is for.

		This briefly worked the other way and it was wrong, for a reason worth
		recording: the lobby countdown is not a signal that anybody chose
		anything. MatchmakingService counts a player who has picked nothing as a
		vote for the default mode, so the countdown starts within a second of the
		first join — meaning "the countdown is running" and "the player is sitting
		in the menu reading the mode list" are the same twenty seconds. Hiding the
		lobby for the one hid it for the other, and the main menu simply never
		appeared.
	]]
	local lobbyVisible = state.open

	gui.Enabled = state.open or state.results or state.teleporting
	menuRoot.Visible = lobbyVisible
	resultsRoot.Visible = state.results
	teleportRoot.Visible = state.teleporting
	setSuppressed(state.open or state.results)

	--[[ A controller has no cursor, so a screen nothing selects is a screen a pad
	     player cannot press a single button on. Selection follows whichever of
	     the three screens is up, and is handed back when none of them is —
	     leaving it on a hidden button eats every D-pad press in the game. ]]
	--[[ Selection follows whatever is actually on screen. With the lobby hidden
	     behind a vote the mode buttons are invisible, and leaving a controller
	     pointed at one would eat every D-pad press the vote wanted. ]]
	if state.voteOpen then
		-- The vote captures its own cards; the menu must not fight it for
		-- selection while it is up.
		GamepadFocus.release(nil)
	elseif state.results then
		GamepadFocus.capture(resultContinueButton)
	elseif lobbyVisible then
		--[[ Whichever page is up. Pointing a pad at a mode entry that PLAY has not
		     revealed yet is pointing it at a hidden button, which eats every D-pad
		     press in the menu. ]]
		GamepadFocus.capture(if state.page == "Modes" then firstModeButton else playButton)
	else
		GamepadFocus.release(nil)
	end
end

--[[
	Shows one page of the menu.

	Root is PLAY; Modes is the list behind it. Everything else on the screen —
	title, nav row, lobby panel, briefing — belongs to both and is untouched
	here, because those are the things a player should be able to reach from
	either page.

	Called on open as well as on the press, so a menu reopened after a round
	always comes back on Root rather than wherever it was left.
]]
local function setPage(page: string)
	state.page = page
	local modes = page == "Modes"

	if playButton then
		playButton.Visible = not modes
	end
	if backButton then
		backButton.Visible = modes
	end
	for _, entry in modeEntries do
		entry.button.Visible = modes
	end

	--[[ No relayout here on purpose: PLAY and the mode stack are both centred in
	     the same band and BACK lives outside it, so the geometry is identical on
	     both pages and only what is VISIBLE changes. That is also what makes the
	     swap read as one screen rather than two. ]]

	--[[ Selection has to move with the page for the same reason the buttons do:
	     a pad left pointing at a hidden entry eats every press. refreshVisibility
	     owns which button that is. ]]
	refreshVisibility()
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
--[[ Reads the map straight off the Workspace attribute MapService writes, so it
     is correct the instant a swap lands with no extra remote. ]]
local function refreshMapLine()
	if not lobbyMap then
		return
	end
	local id = Attributes.get(Workspace, GA.CurrentMap, "")
	if id == "" then
		lobbyMap.Text = ""
		return
	end
	local definition = MapConfig.get(id)
	lobbyMap.Text = "MAP  " .. (if definition then definition.displayName else string.upper(id))
end

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
	elseif lobby.awaitingChoice then
		--[[ Nobody has picked, so there is no clock and the server is not waiting
		     on anyone to arrive — it is waiting on THIS player. Saying WAITING FOR
		     SURVIVORS here was a lie about whose turn it is, and it read as the
		     menu being stuck. ]]
		lobbyBig.Text = "—"
		lobbyBig.TextColor3 = COLOR.TextDim
		lobbyCaption.Text = "CHOOSE A MODE TO START"
		state.countdownShown = -1
	else
		lobbyBig.Text = "—"
		lobbyBig.TextColor3 = COLOR.TextDim
		lobbyCaption.Text = "WAITING FOR SURVIVORS"
		state.countdownShown = -1
	end

	--[[ The clock follows the player out of the menu and over the shop and the
	     loadout screen — see UI/LobbyClock. Being pulled into a round from
	     inside a shop with no warning is the bug that giving people time to
	     browse would otherwise create. ]]
	LobbyClock.set(if lobby.inProgress then 0 else lobby.endsAt, state.committed or lobby.canStart)
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
	lobby.awaitingChoice = payload.awaitingChoice == true
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

--[[ The result screen. SURVIVED is white and quiet; WIPED OUT is the one place
     on this screen red belongs, and it gets the poster voice — the team did not
     lose a match, the light went out on them. ]]
--[[ Draws an itemised payout, or clears the two lines when there is not one. ]]
local function applyPayout(payload: any)
	if not resultPayout then
		return
	end
	if typeof(payload) ~= "table" then
		resultPayout.Text = ""
		resultPayoutLine.Text = ""
		return
	end
	local total = math.max(tonumber(payload.total) or 0, 0)
	local kills = math.max(tonumber(payload.kills) or 0, 0)
	local bonus = math.max(tonumber(payload.bonus) or 0, 0)
	local balance = math.max(tonumber(payload.balance) or 0, 0)

	resultPayout.Text = "+" .. EconomyConfig.format(total)
	resultPayoutLine.Text = string.format(
		"%s FROM KILLS · %s FOR THE ROUND\nBALANCE %s",
		EconomyConfig.format(kills),
		EconomyConfig.format(bonus),
		EconomyConfig.format(balance)
	)
end

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

	--[[
		The payout, if it has arrived.

		RoundPayout and RoundEnded are two remotes fired a moment apart and there
		is no ordering guarantee between them, so this screen draws whichever it
		has and `onPayout` fills the gap if the money lands second. Left blank
		rather than showing a zero: a zero is a claim, and a blank is honest about
		not knowing yet.
	]]
	applyPayout(payoutShown)

	fillRows(payload and payload.scores)

	-- Confetti is the one flourish this game gets, and it is earned: surviving
	-- all seven waves is meant to be uncommon.
	if survived then
		confetti:burst()
	else
		confetti:clear()
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
	--[[ Dropped on the way back to the menu, so the NEXT scoreboard cannot open
	     showing what the LAST round paid while it waits for its own remote. ]]
	payoutShown = nil
	state.countdownShown = -1
	--[[ Always back on PLAY. A menu reopened after a round that resumed on the
	     mode list would be showing a decision the player has just finished
	     making. ]]
	setPage("Root")
	refreshLobby()
	refreshVisibility()
end

--[[
	Closes whichever of the two screens is showing. The result screen counts: it
	sets `open = false` while it is up, so a version of this that only checked
	`open` did nothing when a new round started underneath the scoreboard — and
	the client's own return timer then reopened the menu on top of a live round
	with input and the HUD still suppressed.
]]
function MainMenuController:close()
	if not state.open and not state.results then
		return
	end
	if state.results then
		state.results = false
		confetti:clear()
	end
	state.open = false
	--[[ The chip outlives the menu's own ScreenGui by design — it draws above the
	     shop and the loadout screen — so closing the menu has to take it down
	     explicitly. Nothing else is watching. ]]
	LobbyClock.set(0, false)
	refreshVisibility()
end

function MainMenuController:isOpen(): boolean
	return state.open or state.results
end

--[[
	Tells the menu a map vote is up.

	It no longer changes what is drawn — see refreshVisibility — but the menu
	still tracks it so gamepad focus can move to the vote's cards instead of
	staying on a mode button behind them, which would eat every D-pad press the
	vote wanted.
]]
function MainMenuController:setVoteOpen(value: boolean)
	value = value == true
	if state.voteOpen == value then
		return
	end
	state.voteOpen = value
	refreshVisibility()
end

local function dismissResults()
	if not state.results then
		return
	end
	state.results = false
	confetti:clear()
	UiSound.play(AudioConfig.UI.MenuBack)
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
	local alpha = flicker:alphaAt(now)
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
		--[[ Driven from here rather than from a loop of its own, like Confetti and
		     TitleFlicker: the menu already owns exactly one RenderStepped and the
		     chip is a second view of the number updateCountdown just wrote. ]]
		LobbyClock.update()

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
	confetti:update(dt)

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
	titleKicker = Widgets.label(menuLayer, "Kicker", FONT.Body, TEXT.Tiny, COLOR.TextDim)
	local kicker = titleKicker
	kicker.Position = UDim2.new(COLUMN_X, 0, 0.13, 0)
	kicker.Size = UDim2.new(0.5, 0, 0, TEXT.Body)
	kicker.Text = tracked("A CO-OP SURVIVAL SHOOTER")

	titleFading = Widgets.label(menuLayer, "Fading", FONT.Stencil, TEXT.Title, COLOR.TextPrimary)
	local fading = titleFading
	fading.Position = UDim2.new(COLUMN_X, 0, 0.13, TEXT.Body + LAYOUT.ElementGap)
	fading.Size = UDim2.new(0.8, 0, 0, TITLE_LINE)
	fading.Text = "FADING"

	titleLight = Widgets.label(menuLayer, "Light", FONT.Stencil, TEXT.Title, COLOR.Accent)
	titleLight.Position = UDim2.new(COLUMN_X, 0, 0.13, TEXT.Body + LAYOUT.ElementGap + TITLE_LINE)
	titleLight.Size = UDim2.new(0.8, 0, 0, TITLE_LINE)
	titleLight.Text = "LIGHT"

	titleRule = Widgets.rule(menuLayer, "TitleRule", COLOR.Accent)
	titleRule.Position =
		UDim2.new(COLUMN_X, 0, 0.13, TEXT.Body + LAYOUT.ElementGap + TITLE_LINE * 2 + LAYOUT.PanelPadding)
	titleRule.Size = UDim2.new(0, TITLE_RULE_WIDTH, 0, LAYOUT.BorderThickness)
end

--[[
	PLAY, and the way back from what it opens.

	Deliberately the only thing on the root page below the title: the whole point
	of the change is that a player who has just loaded in sees one obvious verb
	and four quiet options, rather than a fork they have no information to answer.

	Both sit in the same column and the same vertical band as the mode stack, so
	the page swap is a change of content rather than a change of layout — nothing
	jumps.
]]
local function buildPlay()
	local button = Widgets.button(menuLayer, "Play")
	playButton = button

	--[[
		A size and a position before layoutColumns has ever run.

		Not belt and braces — load-bearing. layoutColumns owns the real geometry,
		but it is only reached through refreshScale, which returns early while the
		camera reports a ViewportSize of zero. That happens for the first frame or
		two of a fresh client (see ScaleLayer's header), and if nothing resizes the
		window afterwards it never runs at all.

		A Frame with no Size set is 0x0. So this button was invisible, the mode
		entries were hidden behind it by setPage("Root"), and the main menu came up
		as a title and a nav row with nothing to press. buildModes has always set
		exactly these two lines for exactly this reason; buildPlay was written
		without them.
	]]
	button.Position = UDim2.new(COLUMN_X, 0, 0.52, 0)
	button.Size = UDim2.new(ENTRY_WIDTH, 0, 0, PLAY_HEIGHT)

	local rule = Widgets.rule(button, "Rule", COLOR.Accent)

	local bar = Widgets.frame(button, "Bar", COLOR.Accent, 0)
	bar.Position = UDim2.fromOffset(0, LAYOUT.BorderThickness)
	bar.Size = UDim2.new(0, ENTRY_BAR_WIDTH, 1, -LAYOUT.BorderThickness)

	local label = Widgets.label(button, "Label", FONT.Display, TEXT.Title, COLOR.TextPrimary)
	label.Position = UDim2.fromOffset(ENTRY_TEXT_INSET, LAYOUT.PanelPadding)
	label.Text = "PLAY"

	playLine = Widgets.label(button, "Line", FONT.Body, TEXT.Body, COLOR.TextSecondary)
	playLine.Position = UDim2.fromOffset(ENTRY_TEXT_INSET + 2, LAYOUT.PanelPadding)
	playLine.Text = "CHOOSE A MODE AND FIND A ROUND"
	playLine.TextTransparency = 0.35

	trove:connect(button.MouseEnter, function()
		label.TextColor3 = COLOR.AccentBright
		UiSound.play(AudioConfig.UI.MenuHover)
	end)
	trove:connect(button.MouseLeave, function()
		label.TextColor3 = COLOR.TextPrimary
	end)
	trove:connect(button.Activated, function()
		UiSound.play(AudioConfig.UI.MenuConfirm)
		setPage("Modes")
	end)

	backButton = Widgets.button(menuLayer, "Back")
	-- Same fallback, same reason.
	backButton.Position = UDim2.new(COLUMN_X, 0, 0.46, 0)
	backButton.Size = UDim2.new(BACK_WIDTH, 0, 0, BACK_HEIGHT)
	local backLabel = Widgets.label(backButton, "Label", FONT.Heading, TEXT.Body, COLOR.TextDim)
	backLabel.Size = UDim2.fromScale(1, 1)
	backLabel.Text = "‹  BACK"
	Widgets.hover(trove, backButton, backLabel)
	trove:connect(backButton.Activated, function()
		UiSound.play(AudioConfig.UI.MenuBack)
		setPage("Root")
	end)
	backButton.Visible = false
end

local function buildModes()
	for index, definition in MODE_ENTRIES do
		local button = Widgets.button(menuLayer, definition.id)
		button.Position = UDim2.new(COLUMN_X, 0, 0.52, (index - 1) * (ENTRY_HEIGHT + ENTRY_GAP))
		button.Size = UDim2.new(ENTRY_WIDTH, 0, 0, ENTRY_HEIGHT)
		if index == 1 then
			firstModeButton = button
		end

		local rule = Widgets.rule(button, "Rule", COLOR.Border)

		local bar = Widgets.frame(button, "Bar", COLOR.Accent, 1)
		bar.Position = UDim2.fromOffset(0, LAYOUT.BorderThickness)
		bar.Size = UDim2.new(0, ENTRY_BAR_WIDTH, 1, -LAYOUT.BorderThickness)

		local title = Widgets.label(button, "Title", FONT.Display, TEXT.Display, COLOR.TextPrimary)
		title.Position = UDim2.fromOffset(ENTRY_TEXT_INSET, LAYOUT.PanelPadding)
		title.Size = UDim2.new(1, -ENTRY_TEXT_INSET, 0, TEXT.Display + 6)
		title.Text = definition.title

		local line = Widgets.label(button, "Line", FONT.Body, TEXT.Body, COLOR.TextSecondary)
		line.Position = UDim2.fromOffset(ENTRY_TEXT_INSET + 2, LAYOUT.PanelPadding + TEXT.Display + 8)
		line.Size = UDim2.new(1, -ENTRY_TEXT_INSET, 0, TEXT.Body + 4)
		line.Text = definition.line
		line.TextTransparency = 0.35

		local tag = Widgets.label(button, "Tag", FONT.Body, TEXT.Tiny, COLOR.TextDim)
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
			UiSound.play(AudioConfig.UI.MenuHover)
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

--[[
	The briefing panel: what the game is, and how to play it.

	Every zombie shooter on Roblox drops a new player straight into a horde with
	no idea that shove exists, and shove is the single verb that most often
	decides whether they survive their first wave. A controls list on the menu is
	the cheapest possible fix, and putting the survival rules next to it means the
	one screen everybody sees before their first round is also the one that
	explains the game.

	Deliberately quiet: dim text down the right-hand column, no border, no
	heading bar. It is reference material, not an advertisement, and the mode
	buttons must stay the loudest thing on the screen.
]]
local BRIEFING = {
	{ key = "WASD", text = "Move" },
	{ key = "SHIFT", text = "Sprint — costs stamina" },
	{ key = "LMB", text = "Fire" },
	{ key = "RMB", text = "Aim" },
	{ key = "R", text = "Reload" },
	{ key = "F", text = "Shove — frees a pinned teammate" },
	{ key = "E", text = "Hold to revive, heal, or take a crate" },
	{ key = "G", text = "Throw" },
	{ key = "Q", text = "Call out what you are looking at" },
	{ key = "1-5", text = "Weapons and items" },
}

local RULES = {
	"HEADSHOTS KILL ANYTHING COMMON, WITH ANY GUN.",
	"WHITE HEALTH DRAINS. PERMANENT HEALTH DOES NOT.",
	"GO DOWN THREE TIMES AND YOU STAY DOWN.",
	"AMMO CRATES ARE ONE USE AND COME BACK SLOWLY.",
	"NOBODY SURVIVES ALONE.",
}

local function buildBriefing()
	briefingColumn = Widgets.frame(menuLayer, "Briefing", COLOR.Background, 1)
	local column = briefingColumn
	column.AnchorPoint = Vector2.new(1, 0.5)
	column.Position = UDim2.new(1 - COLUMN_X, 0, 0.52, 0)
	column.Size = UDim2.fromOffset(300, 420)

	local heading = Widgets.label(column, "Heading", FONT.Body, TEXT.Tiny, COLOR.TextDim)
	heading.Size = UDim2.new(1, 0, 0, TEXT.Body)
	heading.TextXAlignment = Enum.TextXAlignment.Right
	heading.Text = tracked("CONTROLS")

	local y = TEXT.Body + 8
	for _, entry in BRIEFING do
		local key = Widgets.label(column, "K_" .. entry.key, FONT.Stencil, TEXT.Small, COLOR.Accent)
		key.Position = UDim2.fromOffset(0, y)
		key.Size = UDim2.fromOffset(64, TEXT.Body + 2)
		key.TextXAlignment = Enum.TextXAlignment.Right
		key.Text = entry.key

		local text = Widgets.label(column, "T_" .. entry.key, FONT.Body, TEXT.Small, COLOR.TextSecondary)
		text.Position = UDim2.fromOffset(74, y)
		text.Size = UDim2.new(1, -74, 0, TEXT.Body + 2)
		text.Text = entry.text

		y += TEXT.Body + 6
	end

	y += 14
	local rule = Widgets.rule(column, "Rule", COLOR.Border)
	rule.Position = UDim2.fromOffset(0, y)
	rule.Size = UDim2.new(1, 0, 0, 1)
	y += 12

	for index, line in RULES do
		local label = Widgets.label(column, "Rule" .. index, FONT.Body, TEXT.Tiny, COLOR.TextDim)
		label.Position = UDim2.fromOffset(0, y)
		label.Size = UDim2.new(1, 0, 0, TEXT.Body + 4)
		label.TextXAlignment = Enum.TextXAlignment.Right
		label.TextWrapped = true
		label.Text = line
		y += TEXT.Body + 6
	end
end

local function buildLobby()
	local panel = Widgets.frame(menuLayer, "Lobby", COLOR.Background, 1)
	panel.AnchorPoint = Vector2.new(1, 0)
	panel.Position = UDim2.new(1 - COLUMN_X, 0, 0.15, 0)
	panel.Size = UDim2.new(0.3, 0, 0, 260)

	local heading = Widgets.label(panel, "Heading", FONT.Body, TEXT.Tiny, COLOR.TextDim)
	heading.Size = UDim2.new(1, 0, 0, TEXT.Body)
	heading.TextXAlignment = Enum.TextXAlignment.Right
	heading.Text = tracked("LOBBY")

	local rule = Widgets.rule(panel, "Rule", COLOR.Border)
	rule.Position = UDim2.fromOffset(0, TEXT.Body + LAYOUT.ElementGap)

	lobbyBig = Widgets.label(panel, "Countdown", FONT.Display, TEXT.Title, COLOR.Accent)
	lobbyBig.Position = UDim2.fromOffset(0, TEXT.Body + LAYOUT.ElementGap * 2)
	lobbyBig.Size = UDim2.new(1, 0, 0, TITLE_LINE)
	lobbyBig.TextXAlignment = Enum.TextXAlignment.Right
	lobbyBig.Text = "—"

	lobbyCaption = Widgets.label(panel, "Caption", FONT.Body, TEXT.Small, COLOR.TextSecondary)
	lobbyCaption.Position = UDim2.fromOffset(0, TEXT.Body + LAYOUT.ElementGap * 2 + TITLE_LINE)
	lobbyCaption.Size = UDim2.new(1, 0, 0, TEXT.Body)
	lobbyCaption.TextXAlignment = Enum.TextXAlignment.Right

	lobbyMode = Widgets.label(panel, "Mode", FONT.Heading, TEXT.Large, COLOR.TextPrimary)
	lobbyMode.Position = UDim2.fromOffset(0, TEXT.Body + LAYOUT.ElementGap * 3 + TITLE_LINE + TEXT.Body)
	lobbyMode.Size = UDim2.new(1, 0, 0, TEXT.Large + 4)
	lobbyMode.TextXAlignment = Enum.TextXAlignment.Right

	--[[ Which map is actually loaded. Worth a line of its own: with a map vote
	     between rounds, "what am I about to play" stops being obvious, and a
	     player deciding whether to join a round in progress wants to know. ]]
	lobbyMap = Widgets.label(panel, "Map", FONT.Body, TEXT.Small, COLOR.TextDim)
	lobbyMap.Position =
		UDim2.fromOffset(0, TEXT.Body + LAYOUT.ElementGap * 3 + TITLE_LINE + TEXT.Body + TEXT.Large + 8)
	lobbyMap.Size = UDim2.new(1, 0, 0, TEXT.Body)
	lobbyMap.TextXAlignment = Enum.TextXAlignment.Right
	lobbyMap.Text = ""

	lobbyPlayers = Widgets.label(panel, "Players", FONT.Body, TEXT.Small, COLOR.TextSecondary)
	lobbyPlayers.Position =
		UDim2.fromOffset(0, TEXT.Body + LAYOUT.ElementGap * 3 + TITLE_LINE + TEXT.Body + TEXT.Large + 6)
	lobbyPlayers.Size = UDim2.new(1, 0, 0, TEXT.Body)
	lobbyPlayers.TextXAlignment = Enum.TextXAlignment.Right

	lobbyMessage = Widgets.label(panel, "Message", FONT.Body, TEXT.Small, COLOR.Accent)
	lobbyMessage.AnchorPoint = Vector2.new(1, 0)
	lobbyMessage.Position = UDim2.new(1, 0, 1, LAYOUT.ElementGap)
	lobbyMessage.Size = UDim2.new(1.6, 0, 0, TEXT.Body * 3)
	lobbyMessage.TextXAlignment = Enum.TextXAlignment.Right
	lobbyMessage.TextYAlignment = Enum.TextYAlignment.Top
	lobbyMessage.TextWrapped = true
end

--[[
	The way into the options, and nothing else.

	This used to be four inline cells — volume, sensitivity, gore, damage
	numbers — which meant the menu owned a settings store that the game itself
	had no way to open. Everything moved to SettingsController, which draws the
	same panel here and over a live round, so there is one store and one set of
	rows rather than a menu version and an in-game version drifting apart.
]]
--[[
	The row along the bottom: everything that is not a mode.

	Four compact entries rather than four more of the big mode blocks, because
	UITheme's own header warns that a THIRD mode entry runs off the bottom of a
	small phone at any scale floor — and these are not modes anyway. A mode is a
	thing you commit to; these are places you visit first.

	GUNSMITH is drawn and does nothing, on purpose. An entry that is visibly
	coming reads as a plan; one that is absent reads as an idea nobody had.
]]
local NAV_ENTRIES = {
	{ id = "Shop", title = "SHOP", line = "GUNS  MELEE  SPECIALS", controller = "ShopController" },
	{
		id = "Loadouts",
		title = "LOADOUTS",
		line = "THREE KITS  ONE ACTIVE",
		controller = "LoadoutController",
	},
	{ id = "Gunsmith", title = "GUNSMITH", line = "COMING SOON", soon = true },
	{
		id = "Settings",
		title = "SETTINGS",
		line = "GRAPHICS  AUDIO  CONTROLS",
		controller = "SettingsController",
	},
}

local NAV_HEIGHT = 46
local NAV_WIDTH = 0.21
local NAV_GAP = 0.015

local function buildNav()
	navRow = Widgets.frame(menuLayer, "Nav", COLOR.Background, 1)
	local row = navRow
	row.AnchorPoint = Vector2.new(0, 1)
	row.Position = UDim2.new(COLUMN_X, 0, 1, -LAYOUT.ScreenMargin * 2)
	row.Size = UDim2.new(1 - COLUMN_X * 2, 0, 0, NAV_HEIGHT)

	local rule = Widgets.rule(row, "Rule", COLOR.Border)
	rule.Position = UDim2.fromOffset(0, -LAYOUT.PanelPadding)
	rule.Size = UDim2.new(0, TITLE_RULE_WIDTH, 0, LAYOUT.BorderThickness)

	for index, definition in NAV_ENTRIES do
		local holder = Widgets.button(row, definition.id)
		holder.Position = UDim2.new((index - 1) * (NAV_WIDTH + NAV_GAP), 0, 0, 0)
		holder.Size = UDim2.new(NAV_WIDTH, 0, 1, 0)

		local label = Widgets.label(holder, "Label", FONT.Heading, TEXT.Large, COLOR.TextPrimary)
		label.Size = UDim2.new(1, 0, 0, TEXT.Large + 2)
		label.Text = definition.title
		if definition.soon then
			label.TextColor3 = COLOR.TextDim
		end

		local line = Widgets.label(holder, "Line", FONT.Body, TEXT.Tiny, COLOR.TextDim)
		line.Position = UDim2.fromOffset(0, TEXT.Large + 2)
		line.Size = UDim2.new(1, 0, 0, TEXT.Body)
		line.Text = tracked(definition.line)

		table.insert(navEntries, { button = holder, label = label, line = line })

		--[[ Reachable without a cursor: the mode entries take selection when the
		     menu opens, and this row is what a pad walks down to from them.
		     Widgets.button has already styled it; only whether it is a legal
		     landing spot is this screen's to say. ]]
		holder.Selectable = not definition.soon

		if not definition.soon then
			trove:connect(holder.Activated, function()
				UiSound.play(AudioConfig.UI.MenuConfirm)
				callController(definition.controller, "open")
			end)
			trove:connect(holder.MouseEnter, function()
				label.TextColor3 = COLOR.AccentBright
			end)
			trove:connect(holder.MouseLeave, function()
				label.TextColor3 = COLOR.TextPrimary
			end)
		end
	end
end

--[[ The balance, top-right, in the one place a player looks before opening the
     shop. Driven by ProfileController's `changed` rather than polled. ]]
local function buildBalance()
	balanceLabel = Widgets.label(menuLayer, "Balance", FONT.Numeric, TEXT.Heading, COLOR.Accent)
	balanceLabel.AnchorPoint = Vector2.new(1, 0)
	balanceLabel.Position = UDim2.new(1 - COLUMN_X, 0, 0, LAYOUT.ScreenMargin * 2)
	balanceLabel.Size = UDim2.fromOffset(240, TEXT.Heading + 4)
	balanceLabel.TextXAlignment = Enum.TextXAlignment.Right
	balanceLabel.Text = ""

	local caption = Widgets.label(menuLayer, "BalanceCaption", FONT.Body, TEXT.Tiny, COLOR.TextDim)
	caption.AnchorPoint = Vector2.new(1, 0)
	caption.Position = UDim2.new(1 - COLUMN_X, 0, 0, LAYOUT.ScreenMargin * 2 + TEXT.Heading + 2)
	caption.Size = UDim2.fromOffset(240, TEXT.Body)
	caption.TextXAlignment = Enum.TextXAlignment.Right
	caption.Text = tracked("DOLLARS")
end

local function refreshBalance()
	if not balanceLabel then
		return
	end
	local store = Registry.find("ProfileController")
	if not store or typeof(store.getDollars) ~= "function" then
		balanceLabel.Text = ""
		return
	end
	local ok, dollars = pcall(store.getDollars, store)
	balanceLabel.Text = if ok then EconomyConfig.format(dollars) else ""
end

local function buildTeleport()
	teleportRoot = Widgets.frame(gui, "Teleport", COLOR.Background, 0)
	teleportRoot.Size = UDim2.fromScale(1, 1)
	teleportRoot.ZIndex = 4
	teleportRoot.Visible = false
	teleportLayer = newLayer(teleportRoot)

	local title = Widgets.label(teleportLayer, "Title", FONT.Stencil, TEXT.Display, COLOR.TextPrimary)
	title.AnchorPoint = Vector2.new(0.5, 1)
	title.Position = UDim2.fromScale(0.5, 0.5)
	title.Size = UDim2.new(0.8, 0, 0, TEXT.Display + 10)
	title.TextXAlignment = Enum.TextXAlignment.Center
	title.ZIndex = 4
	title.Text = "HOLD ON"

	local rule = Widgets.rule(teleportLayer, "Rule", COLOR.Accent)
	rule.AnchorPoint = Vector2.new(0.5, 0)
	rule.Position = UDim2.new(0.5, 0, 0.5, LAYOUT.PanelPadding)
	rule.Size = UDim2.new(0, TITLE_RULE_WIDTH, 0, LAYOUT.BorderThickness)
	rule.ZIndex = 4

	local line = Widgets.label(teleportLayer, "Line", FONT.Body, TEXT.Large, COLOR.TextSecondary)
	line.AnchorPoint = Vector2.new(0.5, 0)
	line.Position = UDim2.new(0.5, 0, 0.5, LAYOUT.PanelPadding * 3)
	line.Size = UDim2.new(0.8, 0, 0, TEXT.Large + 6)
	line.TextXAlignment = Enum.TextXAlignment.Center
	line.ZIndex = 4
	line.Text = "MOVING YOU TO ANOTHER SERVER"
end

local function buildResultRow(index: number): any
	local frame = Widgets.frame(resultsLayer, "Row" .. index, COLOR.Background, 1)
	frame.Position = UDim2.new(COLUMN_X, 0, 0.5, (index - 1) * RESULT_ROW_HEIGHT)
	frame.Size = UDim2.new(1 - COLUMN_X * 2, 0, 0, RESULT_ROW_HEIGHT)
	frame.Visible = false

	local name = Widgets.label(frame, "Name", FONT.Heading, TEXT.Large, COLOR.TextPrimary)
	name.Size = UDim2.new(NAME_WIDTH, 0, 1, 0)

	local cells = {}
	for column, definition in STAT_COLUMNS do
		local label = Widgets.label(frame, definition.key, FONT.Numeric, TEXT.Body, COLOR.TextSecondary)
		label.Position = UDim2.fromScale(NAME_WIDTH + COLUMN_WIDTH * (column - 1), 0)
		label.Size = UDim2.new(COLUMN_WIDTH, 0, 1, 0)
		label.TextXAlignment = Enum.TextXAlignment.Right
		table.insert(cells, { key = definition.key, label = label })
	end

	local status = Widgets.label(frame, "Status", FONT.Body, TEXT.Small, COLOR.TextSecondary)
	status.Position = UDim2.fromScale(1 - STATUS_WIDTH, 0)
	status.Size = UDim2.new(STATUS_WIDTH, 0, 1, 0)
	status.TextXAlignment = Enum.TextXAlignment.Right

	local rule = Widgets.rule(frame, "Rule", COLOR.Border)
	rule.Position = UDim2.new(0, 0, 1, -LAYOUT.BorderThickness)
	rule.BackgroundTransparency = 0.55

	return { frame = frame, name = name, status = status, cells = cells }
end

local function buildResults()
	resultsRoot = Widgets.frame(gui, "Results", COLOR.Background, RESULTS_SCRIM)
	resultsRoot.Size = UDim2.fromScale(1, 1)
	resultsRoot.ZIndex = 2
	resultsRoot.Visible = false
	resultsLayer = newLayer(resultsRoot)

	--[[ Confetti sits in its own unscaled layer directly on the results root, not
	     inside the scaled poster layout: a burst should fill the actual screen at
	     any resolution rather than being shrunk along with the type. ]]
	confetti = Confetti.new(resultsRoot)

	resultOutcome = Widgets.label(resultsLayer, "Outcome", FONT.Stencil, TEXT.Title, COLOR.TextPrimary)
	resultOutcome.Position = UDim2.new(COLUMN_X, 0, 0.14, 0)
	resultOutcome.Size = UDim2.new(0.8, 0, 0, TITLE_LINE)
	resultOutcome.ZIndex = 2

	resultVerdict = Widgets.label(resultsLayer, "Verdict", FONT.Body, TEXT.Large, COLOR.TextSecondary)
	resultVerdict.Position = UDim2.new(COLUMN_X, 0, 0.14, TITLE_LINE)
	resultVerdict.Size = UDim2.new(0.8, 0, 0, TEXT.Large + 6)
	resultVerdict.ZIndex = 2

	local rule = Widgets.rule(resultsLayer, "Rule", COLOR.Accent)
	rule.Position = UDim2.new(COLUMN_X, 0, 0.14, TITLE_LINE + TEXT.Large + LAYOUT.PanelPadding * 2)
	rule.Size = UDim2.new(0, TITLE_RULE_WIDTH, 0, LAYOUT.BorderThickness)
	rule.ZIndex = 2

	resultWave = Widgets.label(resultsLayer, "Wave", FONT.Heading, TEXT.Heading, COLOR.TextPrimary)
	resultWave.Position = UDim2.new(COLUMN_X, 0, 0.32, 0)
	resultWave.Size = UDim2.new(0.8, 0, 0, TEXT.Heading + 6)
	resultWave.ZIndex = 2

	resultTime = Widgets.label(resultsLayer, "Time", FONT.Heading, TEXT.Heading, COLOR.TextPrimary)
	resultTime.Position = UDim2.new(COLUMN_X, 0, 0.32, TEXT.Heading + LAYOUT.ElementGap)
	resultTime.Size = UDim2.new(0.8, 0, 0, TEXT.Heading + 6)
	resultTime.ZIndex = 2

	--[[ What the round paid, on the right, itemised.

	     Sent by the server rather than accumulated here: the client can watch its
	     own balance move and could total the kills, but it cannot see the bonus
	     arithmetic and should not be inventing it. The one number a player checks
	     after a round is how much they made, so it is the same size as the
	     outcome rather than a footnote under it. ]]
	resultPayout = Widgets.label(resultsLayer, "Payout", FONT.Numeric, TEXT.Display, COLOR.Accent)
	resultPayout.AnchorPoint = Vector2.new(1, 0)
	resultPayout.Position = UDim2.new(1 - COLUMN_X, 0, 0.3, 0)
	resultPayout.Size = UDim2.new(0.5, 0, 0, TEXT.Display + 6)
	resultPayout.TextXAlignment = Enum.TextXAlignment.Right
	resultPayout.ZIndex = 2
	resultPayout.Text = ""

	resultPayoutLine = Widgets.label(resultsLayer, "PayoutLine", FONT.Body, TEXT.Small, COLOR.TextDim)
	resultPayoutLine.AnchorPoint = Vector2.new(1, 0)
	resultPayoutLine.Position = UDim2.new(1 - COLUMN_X, 0, 0.3, TEXT.Display + 4)
	resultPayoutLine.Size = UDim2.new(0.6, 0, 0, TEXT.Body * 2)
	resultPayoutLine.TextXAlignment = Enum.TextXAlignment.Right
	resultPayoutLine.TextYAlignment = Enum.TextYAlignment.Top
	resultPayoutLine.ZIndex = 2
	resultPayoutLine.Text = ""

	-- Column headings, one row above the first player.
	local header = Widgets.frame(resultsLayer, "Header", COLOR.Background, 1)
	header.Position = UDim2.new(COLUMN_X, 0, 0.5, -RESULT_ROW_HEIGHT)
	header.Size = UDim2.new(1 - COLUMN_X * 2, 0, 0, RESULT_ROW_HEIGHT)
	header.ZIndex = 2

	local headerName = Widgets.label(header, "Name", FONT.Body, TEXT.Tiny, COLOR.TextDim)
	headerName.Size = UDim2.new(NAME_WIDTH, 0, 1, 0)
	headerName.Text = tracked("SURVIVORS")

	for column, definition in STAT_COLUMNS do
		local label = Widgets.label(header, definition.key, FONT.Body, TEXT.Tiny, COLOR.TextDim)
		label.Position = UDim2.fromScale(NAME_WIDTH + COLUMN_WIDTH * (column - 1), 0)
		label.Size = UDim2.new(COLUMN_WIDTH, 0, 1, 0)
		label.TextXAlignment = Enum.TextXAlignment.Right
		label.Text = definition.title
	end

	for index = 1, MAX_ROWS do
		table.insert(resultRows, buildResultRow(index))
	end

	local continue = Widgets.button(resultsLayer, "Continue")
	resultContinueButton = continue
	continue.AnchorPoint = Vector2.new(0, 1)
	continue.Position = UDim2.new(COLUMN_X, 0, 1, -LAYOUT.ScreenMargin * 2)
	continue.Size = UDim2.new(0.3, 0, 0, TEXT.Display + LAYOUT.PanelPadding)
	continue.ZIndex = 2

	local continueRule = Widgets.rule(continue, "Rule", COLOR.Border)
	continueRule.ZIndex = 2

	resultContinue = Widgets.label(continue, "Label", FONT.Display, TEXT.Display, COLOR.TextPrimary)
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

	resultReturn = Widgets.label(resultsLayer, "Return", FONT.Body, TEXT.Small, COLOR.TextDim)
	resultReturn.AnchorPoint = Vector2.new(1, 1)
	resultReturn.Position = UDim2.new(1 - COLUMN_X, 0, 1, -LAYOUT.ScreenMargin * 2)
	resultReturn.Size = UDim2.new(0.4, 0, 0, TEXT.Body)
	resultReturn.TextXAlignment = Enum.TextXAlignment.Right
	resultReturn.ZIndex = 2
end

--[[ Bound to the viewport's changed signal rather than sampled per frame: a
     window is resized about as often as it is created. ]]
--[[
	COMPACT LAYOUT — what this poster does on a screen it does not fit on.

	Every offset on this screen was chosen against a 900-pixel-tall viewport, and
	ScaleLayer's floor means a phone in landscape reports about 500 REFERENCE
	pixels rather than 900 — the scale is clamped at 0.75 so the type stays
	legible, which is right, and the consequence is that the layout has 55% of
	the vertical room it was drawn for.

	It did not fit, and had not for a while: at 500 reference pixels the two mode
	entries ran from 260 to 456, the title block ended at 275, and the row along
	the bottom started at 400. All three overlapped. It was invisible on every
	desktop and on every tablet, which is exactly the shape of bug that ships.

	So below COMPACT_HEIGHT the poster becomes a phone menu:
	  * the title drops from TEXT.Title to TEXT.Display — 84 to 54, which is the
	    difference between two lines taking 180 pixels and taking 120;
	  * the mode entries lose their sub-line and shorten to fit what is left;
	  * the briefing column goes. It is the control list, and a phone player is
	    not reading a keyboard reference.

	Everything is measured rather than guessed: the stack is laid out from the
	title's real bottom down to the nav row's real top, so the three blocks
	cannot overlap at any height.
]]
local COMPACT_HEIGHT = 620
--[[ The shortest a mode entry is allowed to get. Its title is TEXT.Heading in
     compact, so this has to clear 30 plus its padding — and a 640x360 phone,
     which is 480 reference pixels, needs every one of the studs between. ]]
local ENTRY_HEIGHT_COMPACT = 48
local TITLE_LINE_COMPACT = TEXT.Display + 6

local function layoutColumns(referenceHeight: number)
	if not titleKicker or not navRow then
		return
	end
	local compact = referenceHeight < COMPACT_HEIGHT
	local titleSize = if compact then TEXT.Display else TEXT.Title
	local titleLine = if compact then TITLE_LINE_COMPACT else TITLE_LINE
	local top = referenceHeight * 0.13

	titleKicker.Position = UDim2.new(COLUMN_X, 0, 0, top)
	titleFading.TextSize = titleSize
	titleFading.Position = UDim2.new(COLUMN_X, 0, 0, top + TEXT.Body + LAYOUT.ElementGap)
	titleFading.Size = UDim2.new(0.8, 0, 0, titleLine)
	titleLight.TextSize = titleSize
	titleLight.Position = UDim2.new(COLUMN_X, 0, 0, top + TEXT.Body + LAYOUT.ElementGap + titleLine)
	titleLight.Size = UDim2.new(0.8, 0, 0, titleLine)

	local titleBottom = top + TEXT.Body + LAYOUT.ElementGap + titleLine * 2 + LAYOUT.PanelPadding
	titleRule.Position = UDim2.new(COLUMN_X, 0, 0, titleBottom)

	--[[ The nav row is anchored to the bottom and does not move; the mode stack
	     is fitted into whatever is left between the title and it. ]]
	local navTop = referenceHeight - LAYOUT.ScreenMargin * 2 - NAV_HEIGHT - LAYOUT.PanelPadding * 2
	local count = math.max(#modeEntries, 1)
	--[[ One gap short of the real room, so the bottom entry never lands exactly
	     on the nav row's top edge. Two blocks touching reads as one block. ]]
	local room = navTop - (titleBottom + LAYOUT.ScreenMargin) - LAYOUT.ElementGap
	local height = math.clamp((room - (count - 1) * ENTRY_GAP) / count, ENTRY_HEIGHT_COMPACT, ENTRY_HEIGHT)
	local stack = count * height + (count - 1) * ENTRY_GAP
	--[[ Centred in the room rather than pinned to the top of it, so a desktop
	     keeps the deliberate gap under the title that the 0.52 anchor gave it. ]]
	local bandTop = titleBottom + LAYOUT.ScreenMargin
	local entryTop = bandTop + math.max((room - stack) * 0.5, 0)

	--[[ PLAY is centred in the same band the mode stack fills, so the page swap
	     is a change of content rather than a change of layout. A button that
	     jumps when you press it reads as two different screens. ]]
	if playButton then
		local playHeight = if compact then PLAY_HEIGHT_COMPACT else PLAY_HEIGHT
		playButton.Position = UDim2.new(COLUMN_X, 0, 0, bandTop + math.max((room - playHeight) * 0.5, 0))
		playButton.Size = UDim2.new(ENTRY_WIDTH, 0, 0, playHeight)
		local label = playButton:FindFirstChild("Label") :: TextLabel?
		if label then
			label.TextSize = if compact then TEXT.Display else TEXT.Title
			label.Size = UDim2.new(1, -ENTRY_TEXT_INSET, 0, label.TextSize + 6)
		end
		if playLine then
			--[[ The strapline goes on a phone for the same reason a mode entry's
			     does: in a 64-pixel button it is a second line of type sitting on
			     the first. ]]
			playLine.Visible = not compact
			playLine.Position = UDim2.fromOffset(
				ENTRY_TEXT_INSET + 2,
				LAYOUT.PanelPadding + (if label then label.TextSize else TEXT.Title) + 8
			)
			playLine.Size = UDim2.new(1, -ENTRY_TEXT_INSET, 0, TEXT.Body + 4)
		end
	end

	--[[
		BACK goes in the margin between the title rule and the band, not in the
		band itself.

		It wanted a row of its own and it cannot have one. On the smallest phone
		this game supports — 480 reference pixels tall — the whole band between
		the title and the nav row is about 109 pixels, and two mode entries with
		30-pixel titles already need every one of them. Taking BACK_HEIGHT plus a
		gap out of that pushed the second entry straight through the nav row, which
		is what verify_menu caught.

		The margin gap is exactly ScreenMargin on every viewport, so a BACK_HEIGHT
		under that always fits with room either side. It is wide rather than tall
		to stay tappable, and Escape and B do the same job for the two schemes
		that have them.
	]]
	if backButton then
		backButton.Position =
			UDim2.new(COLUMN_X, 0, 0, titleBottom + (LAYOUT.ScreenMargin - BACK_HEIGHT) * 0.5)
		backButton.Size = UDim2.new(BACK_WIDTH, 0, 0, BACK_HEIGHT)
	end

	for index, entry in modeEntries do
		entry.button.Position = UDim2.new(COLUMN_X, 0, 0, entryTop + (index - 1) * (height + ENTRY_GAP))
		entry.button.Size = UDim2.new(ENTRY_WIDTH, 0, 0, height)
		entry.title.TextSize = if compact then TEXT.Heading else TEXT.Display
		entry.title.Size = UDim2.new(1, -ENTRY_TEXT_INSET, 0, entry.title.TextSize + 6)
		--[[ The pitch line is the first thing to go: it is flavour, and on a
		     phone it is flavour sitting on top of the next entry's title. ]]
		entry.line.Visible = not compact
		entry.line.Position =
			UDim2.fromOffset(ENTRY_TEXT_INSET + 2, LAYOUT.PanelPadding + entry.title.TextSize + 8)
	end

	if briefingColumn then
		briefingColumn.Visible = not compact
		briefingColumn.Position = UDim2.new(1 - COLUMN_X, 0, 0, entryTop + stack * 0.5)
	end

	--[[ The nav row narrows with the screen — four entries across 82% of a phone
	     held upright is about 86 reference pixels each, and "LOADOUTS" at
	     TEXT.Large does not fit in that. The sub-line goes with it: two lines of
	     type in a 46-pixel row that has shrunk is one line too many. ]]
	for _, entry in navEntries do
		entry.label.TextSize = if compact then TEXT.Body else TEXT.Large
		entry.label.Size = UDim2.new(1, 0, 0, entry.label.TextSize + 2)
		entry.line.Visible = not compact
		entry.line.Position = UDim2.fromOffset(0, entry.label.TextSize + 2)
	end
end

local function refreshScale()
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	local height = camera.ViewportSize.Y
	--[[ A viewport of zero is a camera that has not resolved yet, which happens
	     for the first frame or two of a fresh client. Returning was correct —
	     laying out against zero would be worse — but returning and never coming
	     back is what left the menu unpositioned when nothing resized the window
	     afterwards. One deferred retry costs nothing and closes it. ]]
	if height <= 0 then
		task.defer(function()
			local later = Workspace.CurrentCamera
			if later and later.ViewportSize.Y > 0 then
				refreshScale()
			end
		end)
		return
	end

	local factor = UITheme.scaleFor(height)
	local inverse = UDim2.fromScale(1 / factor, 1 / factor)
	for _, layer in layers do
		layer.scale.Scale = factor
		layer.frame.Size = inverse
	end

	--[[ The layout follows the scale, because the two are the same question:
	     how much room this screen actually has in the units everything below is
	     written in. See layoutColumns. ]]
	layoutColumns(height / factor)
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

	menuRoot = Widgets.frame(gui, "Menu", COLOR.Background, MENU_SCRIM)
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
	--[[ Handed to UiSound so every cue in the interface routes through it. Only
	     the menu's own sounds used to, which meant the master volume setting
	     silently did not apply to the hitmarker, the shop, the pause menu or any
	     of the other five — they each made their own ungrouped Sound. ]]
	UiSound.setGroup(masterGroup)

	buildTitle()
	buildPlay()
	buildModes()
	buildBriefing()
	buildLobby()
	buildNav()
	buildBalance()
	buildResults()
	buildTeleport()

	--[[ The root page is the built state, not just the opened one: the mode
	     entries are constructed visible and would show through the first frame
	     of the menu otherwise. ]]
	setPage("Root")
	refreshScale()
end

local function adopt(instance: Instance)
	if instance:IsA("Sound") and instance.SoundGroup == nil then
		instance.SoundGroup = masterGroup
	end
end

-- ── public API ──────────────────────────────────────────────────────────────

--[[
	Puts the menu back the way it should be, without touching the saved camera.

	For one case, and it has two halves. The settings panel opens over a live
	round and suppresses the same things this menu does; while it is up the round
	ends and this menu opens behind it; closing the panel then hands input and
	the HUD back over a menu that is still on screen, and hands gamepad selection
	back to nothing at all — which on a console is a screen where no button can
	be pressed. So both are re-asserted here.

	Only the pushes are repeated. The camera and cursor the menu saved on the way
	in are left exactly as they are, because they are what it still has to hand
	back later — which is why this is not simply `setSuppressed(true)` again.
]]
function MainMenuController:reassertSuppression()
	if not state.suppressed then
		return
	end
	pushSuppression(true)
	-- Idempotent: setSuppressed inside sees no change and returns, and the
	-- selection block at the end is the half this call is really after.
	refreshVisibility()
end

--[[ Kept as a courtesy for anything that used to ask the menu for a preference.
     SettingsController is the store; this is a forward, not a second copy. ]]
function MainMenuController:getSetting(key: string): any
	local settings = Registry.find("SettingsController")
	if not settings or typeof(settings.get) ~= "function" then
		return nil
	end
	local ok, value = pcall(settings.get, settings, key)
	return if ok then value else nil
end

function MainMenuController:setSetting(key: string, value: any): boolean
	local settings = Registry.find("SettingsController")
	if not settings or typeof(settings.set) ~= "function" then
		return false
	end
	local ok, changed = pcall(settings.set, settings, key, value)
	return ok and changed == true
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

	-- The round may already be running when this client arrives; read it quietly
	-- so the first real transition is the first thing that moves the menu.
	state.roundState = Attributes.get(Workspace, GA.RoundState, ROUND.Lobby)
	refreshLobby()
end

function MainMenuController:start()
	for _, instance in SoundService:GetDescendants() do
		adopt(instance)
	end
	trove:connect(SoundService.DescendantAdded, adopt)

	local store = Registry.find("ProfileController")
	if store then
		if store.changed then
			trove:add(store.changed:connect(refreshBalance))
		end
		--[[ RoundPayout and RoundEnded are fired a moment apart with no ordering
		     guarantee between them. Whichever lands first draws what it has; this
		     is the case where the money arrives after the scoreboard is already
		     up, and it has to fill in rather than wait for the next round. ]]
		if store.paid then
			trove:add(store.paid:connect(function(payload: any)
				payoutShown = payload
				if state.results then
					applyPayout(payload)
				end
			end))
		end
	end
	refreshBalance()

	trove:connect(Remotes.Event.LobbyStateChanged.OnClientEvent, onLobbyState)
	trove:connect(Remotes.Event.RoundEnded.OnClientEvent, showResults)

	trove:connect(Workspace:GetAttributeChangedSignal(GA.CurrentMap), refreshMapLine)
	trove:connect(Remotes.Event.MapLoading.OnClientEvent, refreshMapLine)
	refreshMapLine()
	trove:connect(Remotes.Event.HitConfirmed.OnClientEvent, onHitConfirmed)

	--[[
		The way back off the mode page without a mouse.

		Escape and B are what every other screen in this game closes on, and the
		mode list is a page rather than a panel, so they step back one instead of
		closing anything. On the root page they do nothing at all — the main menu
		in the lobby is not something a player should be able to dismiss into an
		empty screen.

		`processed` is respected so Escape going to the Roblox menu is not also a
		page change.
	]]
	trove:connect(UserInputService.InputBegan, function(input: InputObject, processed: boolean)
		if processed or not state.open or state.page ~= "Modes" then
			return
		end
		if input.KeyCode == Enum.KeyCode.Escape or input.KeyCode == Enum.KeyCode.ButtonB then
			UiSound.play(AudioConfig.UI.MenuBack)
			setPage("Root")
		end
	end)
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
	-- Its own ScreenGui, so the menu's trove does not take it with it.
	LobbyClock.destroy()
	table.clear(modeEntries)
	table.clear(navEntries)
	table.clear(resultRows)
	trove:destroy()
end

Registry.register("MainMenuController", MainMenuController)

return MainMenuController
