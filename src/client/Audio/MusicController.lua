--!nonstrict
--[[
	MusicController — the Director's voice.

	In Left 4 Dead the music is not a soundtrack, it is a readout. A rising cue
	means the Director has decided you are due; the tank theme means stop
	thinking about anything else. Nothing else in this game decides what plays:
	DirectorService broadcasts, and this file listens.

	  Attributes.Game.PacingState  Relax -> Ambient, BuildUp / PeakFade ->
	                               Buildup, SustainPeak -> Horde
	  Attributes.Game.TankActive   TankTheme, and everything else ducks by
	                               AudioConfig.Mix.DuckMusicOnTank
	  Attributes.Game.RoundState   Victory / TeamWipe end the music with their
	                               own one-shot cue
	  DirectorEvent                Pacing / HordeIncoming / Calm / Boss / Panic,
	                               the vocabulary DirectorService documents

	── EVERYTHING CROSS-FADES ──────────────────────────────────────────────────
	Cues are never cut. Each one carries its own fadeIn and fadeOut in
	AudioConfig.Music, and the mixer below runs an envelope per cue toward those
	times, so a pacing change glides and a Tank arrives over its own 0.3s ramp
	while the previous track takes 3s to leave. Two cues overlapping mid-fade is
	the normal case, not an edge case.

	── THE SOUND BANK IS EMPTY, AND THAT IS FINE ───────────────────────────────
	Every id in AudioConfig.Music is "" on purpose — read that file's header.
	This controller therefore has to be completely silent about it: no error, no
	warning, not once. It creates a Sound only for a cue whose id is filled in,
	re-checks on every tick, and picks up a pasted id the moment it appears with
	no other change anywhere. A half-filled bank plays the half that exists.

	── ONE CONNECTION ──────────────────────────────────────────────────────────
	One Heartbeat, accumulated down to MIX_HZ. Music envelopes move over seconds;
	running them at frame rate would be sixty times the property writes for a
	difference nobody can hear, during the exact horde that needs the frame.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attributes = require(Shared.Net.Attributes)
local AudioConfig = require(Shared.Config.AudioConfig)
local DirectorConfig = require(Shared.Config.DirectorConfig)
local Enums = require(Shared.Enums)
local Registry = require(Shared.Util.Registry)
local Remotes = require(Shared.Net.Remotes)
local Trove = require(Shared.Util.Trove)

local MUSIC = AudioConfig.Music
local MIX = AudioConfig.Mix
local GA = Attributes.Game
local PACING = Enums.PacingState
local ROUND = Enums.RoundState

--[[ Cue names, which are also the keys of AudioConfig.Music. Written out rather
     than spelled inline so a typo is a nil index at load rather than a track
     that silently never plays. ]]
local CUE = table.freeze({
	Ambient = "Ambient",
	Buildup = "Buildup",
	Horde = "Horde",
	TankTheme = "TankTheme",
	WitchTheme = "WitchTheme",
	SafeRoom = "SafeRoom",
	Defeat = "Defeat",
	Victory = "Victory",
})

--[[ Pacing state -> cue. PeakFade shares Buildup deliberately: the horde is
     over but the team is still exposed, and dropping straight to Ambient there
     tells them they are safe a good ten seconds before they are. ]]
local PACING_CUE = table.freeze({
	[PACING.Relax] = CUE.Ambient,
	[PACING.BuildUp] = CUE.Buildup,
	[PACING.SustainPeak] = CUE.Horde,
	[PACING.PeakFade] = CUE.Buildup,
})

--[[ DirectorService's event vocabulary. These strings are its contract and
     nothing else in the game defines them. "Special" is deliberately absent:
     a special infected announces itself with its own vocalisation, which is
     AudioService's, and a music sting on top of it would bury the tell that
     actually keeps players alive. ]]
local EVENT = table.freeze({
	Pacing = "Pacing",
	HordeIncoming = "HordeIncoming",
	Calm = "Calm",
	Boss = "Boss",
	Panic = "Panic",
})

--[[ How long a cue that is not driven by a state stays up.

     A Witch has no attribute and no death event of her own — TankActive exists,
     WitchActive does not — so her theme is a warning with a timer rather than a
     state, and it expires instead of looping forever over a Witch somebody
     walked around ten minutes ago. The safe room cue is the same shape: the
     round state does not change when a team walks through the door.

     The panic window is the one number here that IS in a config, because the
     Director already knows how long a panic event lasts. ]]
local WITCH_THEME_SECONDS = 22
local SAFE_ROOM_SECONDS = 18
local DEFAULT_HOLD_SECONDS = 20
local PANIC_SECONDS = DirectorConfig.PanicEvent.Duration

-- Envelopes move over seconds; twenty steps a second is smooth and free.
local MIX_HZ = 20
local MIX_INTERVAL = 1 / MIX_HZ

-- Below this a voice is inaudible and is stopped rather than left running.
local SILENCE_EPSILON = 0.002

-- A fade time of zero would divide by it. Two frames is "immediately" anyway.
local MIN_FADE = 0.033

local MusicController = {}

local trove = Trove.new()
local folder: Folder

local enabled = true

type Voice = {
	sound: Sound,
	gain: number, -- 0-1 envelope, independent of the cue's own volume
	started: boolean, -- :Play() has been called and not yet undone by a full fade-out
	finished: boolean, -- a one-shot that has already played out
}

local voices: { [string]: Voice } = {}

local state = {
	pacing = PACING.Relax,
	round = ROUND.Lobby,
	tankActive = false,
	current = "", -- the cue the mixer is currently driving toward
	overrideCue = "",
	overrideUntil = 0,
	overrideHoldsPacing = false, -- cleared by the next pacing change
}

local accumulator = 0

-- ── voices ──────────────────────────────────────────────────────────────────

--[[
	The Sound for a cue, or nil while its id is still empty.

	Called every tick for the cue that wants to play, which is what makes a
	pasted asset id work with no other change: the moment AudioConfig.Music
	carries an id, the next tick builds the Sound and fades it in.
]]
local function ensureSound(name: string): Sound?
	local cue = MUSIC[name]
	if not AudioConfig.isConfigured(cue) then
		return nil
	end

	local voice = voices[name]
	if voice then
		-- An id that changed under us (a live edit in Studio) is a new track.
		if voice.sound.SoundId ~= cue.id then
			voice.sound.SoundId = cue.id
			voice.started = false
			voice.finished = false
		end
		return voice.sound
	end

	local sound = Instance.new("Sound")
	sound.Name = "FL_Music_" .. name
	sound.SoundId = cue.id
	sound.Looped = cue.looped == true
	sound.Volume = 0
	--[[ Parented under SoundService rather than to a part: music is not a thing
	     happening somewhere in the room, and a positional music track would
	     swing across the stereo field every time the player turned around. ]]
	sound.Parent = folder
	trove:add(sound)

	voices[name] = { sound = sound, gain = 0, started = false, finished = false }
	return sound
end

--[[ The Tank duck. Everything that is not the tank theme drops to
     AudioConfig.Mix.DuckMusicOnTank while one is alive, which is what lets the
     tank theme sit on top without simply being louder than the mix. ]]
local function duckFor(name: string): number
	if state.tankActive and name ~= CUE.TankTheme then
		return MIX.DuckMusicOnTank
	end
	return 1
end

local function applyVolume(name: string, voice: Voice)
	local cue = MUSIC[name]
	if not cue then
		return
	end
	voice.sound.Volume = cue.volume * MIX.MasterVolume * duckFor(name) * voice.gain
end

-- ── the cue decision ────────────────────────────────────────────────────────

--[[ What should be playing right now, in priority order. Every branch is a
     state read; nothing here is stateful, so the same inputs always produce the
     same cue and the mixer never has to be told twice. ]]
local function resolveCue(now: number): string
	if not enabled then
		return ""
	end
	if state.round == ROUND.Victory then
		return CUE.Victory
	end
	if state.round == ROUND.TeamWipe then
		return CUE.Defeat
	end
	-- A Tank outranks everything the pacing machine has to say, because while
	-- one is alive nothing else on the map matters.
	if state.tankActive then
		return CUE.TankTheme
	end
	if state.overrideCue ~= "" and now < state.overrideUntil then
		return state.overrideCue
	end
	return PACING_CUE[state.pacing] or CUE.Ambient
end

local function setOverride(cue: string, seconds: number, holdsPacing: boolean)
	state.overrideCue = cue
	state.overrideUntil = os.clock() + seconds
	state.overrideHoldsPacing = holdsPacing
end

local function clearOverride()
	state.overrideCue = ""
	state.overrideUntil = 0
	state.overrideHoldsPacing = false
end

local function setPacing(newState: string)
	if typeof(newState) ~= "string" or newState == state.pacing then
		return
	end
	state.pacing = newState
	--[[ A cue that was standing in for a moment (the safe room, a Witch) is
	     over the instant the Director changes its mind about the pacing. ]]
	if state.overrideHoldsPacing then
		clearOverride()
	end
end

-- ── the mixer ───────────────────────────────────────────────────────────────

local function mix(deltaTime: number)
	local now = os.clock()
	local wanted = resolveCue(now)

	-- Build the wanted cue's Sound on demand. Silent and free while its id is
	-- still empty, which is the normal state of this project today.
	if wanted ~= "" then
		ensureSound(wanted)
	end
	state.current = wanted

	for name, voice in voices do
		local cue = MUSIC[name]
		if not cue then
			continue
		end

		local selected = name == wanted
		local rising = selected and not voice.finished
		local fade = math.max(if rising then cue.fadeIn else cue.fadeOut, MIN_FADE)
		local target = if rising then 1 else 0
		local step = deltaTime / fade

		if voice.gain < target then
			voice.gain = math.min(voice.gain + step, target)
		elseif voice.gain > target then
			voice.gain = math.max(voice.gain - step, target)
		end

		--[[ Started once per rise, never per tick. A one-shot reports IsPlaying
		     false the moment it ends, and restarting it on that would loop a
		     defeat sting forever over the wipe screen. ]]
		if rising and not voice.started then
			voice.started = true
			voice.sound.TimePosition = 0
			voice.sound:Play()
		end

		applyVolume(name, voice)

		if voice.started and not cue.looped and voice.gain >= 1 and not voice.sound.IsPlaying then
			voice.finished = true
		end

		if not rising and voice.gain <= SILENCE_EPSILON then
			voice.gain = 0
			if voice.sound.IsPlaying then
				voice.sound:Stop()
			end
			--[[ Out of the mix entirely rather than merely finished, so a cue
			     the round comes back to (a second campaign, a new panic event)
			     starts from the top. ]]
			if not selected then
				voice.started = false
				voice.finished = false
			end
		end
	end
end

-- ── inputs ──────────────────────────────────────────────────────────────────

local function readAttributes()
	setPacing(Attributes.get(Workspace, GA.PacingState, PACING.Relax))
	state.round = Attributes.get(Workspace, GA.RoundState, ROUND.Lobby)
	state.tankActive = Attributes.get(Workspace, GA.TankActive, false) == true
end

local function onDirectorEvent(message: any)
	if typeof(message) ~= "table" then
		return
	end
	local kind = message.kind
	local payload = message.payload

	if kind == EVENT.Pacing then
		if typeof(payload) == "table" then
			setPacing(payload.state)
		end
	elseif kind == EVENT.HordeIncoming then
		--[[ The event beats its own attribute here, and that is the point: the
		     horde cue is a warning, and a warning that arrives with the horde is
		     not one. ]]
		setPacing(PACING.SustainPeak)
	elseif kind == EVENT.Calm then
		setPacing(PACING.Relax)
	elseif kind == EVENT.Boss then
		if typeof(payload) == "table" and payload.kind == Enums.Infected.Witch then
			--[[ The Tank has its own attribute and does not need an override;
			     the Witch has nothing, so her theme is a timed warning. ]]
			setOverride(CUE.WitchTheme, WITCH_THEME_SECONDS, true)
		end
	elseif kind == EVENT.Panic then
		setOverride(CUE.Horde, PANIC_SECONDS, false)
	end
end

local function onRoundStateChanged(payload: any)
	if typeof(payload) ~= "table" then
		return
	end
	if typeof(payload.state) == "string" then
		state.round = payload.state
	end

	--[[ There is no safe-room remote in the manifest; LevelService rides the
	     round payload instead, so the arrival is inferred from it. A team that
	     just walked through the door gets the one lull the map guarantees. ]]
	local body = payload.payload
	if typeof(body) == "table" and body.safeRoom ~= nil and state.round ~= ROUND.Victory then
		setOverride(CUE.SafeRoom, SAFE_ROOM_SECONDS, true)
	end
end

-- ── public API ──────────────────────────────────────────────────────────────

--[[ Forces a cue for `seconds`, on top of whatever the Director is doing. For
     anything with its own idea of a moment — a scripted set piece, a finale
     crescendo — that the pacing machine does not model. ]]
function MusicController:play(cue: string, seconds: number?)
	if MUSIC[cue] == nil then
		return
	end
	setOverride(cue, seconds or DEFAULT_HOLD_SECONDS, false)
end

--[[ Drops any forced cue and hands the mix back to the Director. ]]
function MusicController:resume()
	clearOverride()
end

--[[ The cue the mixer is driving toward. "" when the music is off, and note
     that a cue with no asset id still reports here — the decision is real even
     while the bank is empty. ]]
function MusicController:getCue(): string
	return state.current
end

function MusicController:setEnabled(value: boolean)
	enabled = value == true
end

function MusicController:isEnabled(): boolean
	return enabled
end

--[[ Stops everything immediately, with no fade. For a round teardown, not for
     a pacing change — a cut is exactly what this controller exists to avoid. ]]
function MusicController:stopAll()
	for name, voice in voices do
		voice.gain = 0
		voice.sound.Volume = 0
		if voice.sound.IsPlaying then
			voice.sound:Stop()
		end
		voice.started = false
		voice.finished = false
		applyVolume(name, voice)
	end
	state.current = ""
end

-- ── lifecycle ───────────────────────────────────────────────────────────────

local function update(deltaTime: number)
	accumulator += deltaTime
	if accumulator < MIX_INTERVAL then
		return
	end
	local elapsed = accumulator
	accumulator = 0
	mix(elapsed)
end

function MusicController:init()
	folder = Instance.new("Folder")
	folder.Name = "FL_Music"
	folder.Parent = SoundService
	trove:add(folder)

	readAttributes()
end

function MusicController:start()
	trove:connect(Workspace:GetAttributeChangedSignal(GA.PacingState), function()
		setPacing(Attributes.get(Workspace, GA.PacingState, PACING.Relax))
	end)
	trove:connect(Workspace:GetAttributeChangedSignal(GA.TankActive), function()
		state.tankActive = Attributes.get(Workspace, GA.TankActive, false) == true
	end)
	trove:connect(Workspace:GetAttributeChangedSignal(GA.RoundState), function()
		state.round = Attributes.get(Workspace, GA.RoundState, ROUND.Lobby)
	end)

	trove:connect(Remotes.Event.DirectorEvent.OnClientEvent, onDirectorEvent)
	trove:connect(Remotes.Event.RoundStateChanged.OnClientEvent, onRoundStateChanged)

	trove:connect(RunService.Heartbeat, update)
end

--[[ A player joining into a round in progress needs the music they would have
     had. Attributes only fire on the next write, so without this a mid-round
     join hears ambient over a tank. ]]
function MusicController:onInitialState(payload: any)
	readAttributes()
	if typeof(payload) == "table" and typeof(payload.roundState) == "string" then
		state.round = payload.roundState
	end
end

function MusicController:destroy()
	trove:destroy()
	table.clear(voices)
end

Registry.register("MusicController", MusicController)

return MusicController
