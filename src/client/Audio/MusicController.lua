--!nonstrict
--[[
	MusicController — the round's voice.

	In Left 4 Dead the music is not a soundtrack, it is a readout. Here the thing
	being read out is the WAVE, because that is what the round is made of: a
	fixed seventeen minutes of seven escalating waves with a breather between
	each one. Nothing else in this game decides what plays.

	  Attributes.Game.WavePhase    Active -> Horde. Prep / Breather -> Ambient,
	                               and Buildup for the last BUILDUP_LEAD seconds
	                               before the next wave lands.
	  Attributes.Game.WaveEndsAt   an absolute server stamp, so "how long until
	                               the wave" is a subtraction that cannot drift.
	  Attributes.Game.TankActive   TankTheme, and everything else ducks by
	                               AudioConfig.Mix.DuckMusicOnTank
	  Attributes.Game.RoundState   Victory / TeamWipe end the music with their
	                               own one-shot cue
	  Remotes.Event.WaveChanged    the WaveCleared sting on a breather edge
	  a live Witch nearby          WitchTheme

	The Director's own vocabulary (DirectorEvent) still drives the mix whenever
	there is no wave clock running — a lobby, a result screen, a mode without
	waves. Inside a round the wave schedule is the authority, because the wave
	schedule is what the player is actually experiencing.

	── EVERYTHING CROSS-FADES ──────────────────────────────────────────────────
	Cues are never cut. Each one carries its own fadeIn and fadeOut in
	AudioConfig.Music, and the mixer below runs an envelope per cue toward those
	times, so a phase change glides and a Tank arrives over its own 0.35s ramp
	while the previous track takes 3s to leave. Two cues overlapping mid-fade is
	the normal case, not an edge case.

	── AND SO DO THE LOOPS ─────────────────────────────────────────────────────
	None of the supplied tracks are seamless loops. AudioConfig says so, and
	gives every cue a `loopCrossfade` for it. A looped cue therefore owns TWO
	Sound instances and alternates between them: when the leading one is
	`loopCrossfade` seconds from its end, the other starts from the top
	underneath it and the pair equal-power crossfade. Without that you hear the
	track stop dead and restart every ninety seconds, which is the single
	loudest way for a game to sound unfinished.

	── AN EMPTY ID IS NOT AN ERROR ─────────────────────────────────────────────
	Several AudioConfig entries are still "". This controller has to be
	completely silent about it: no error, no warning, not once. It creates Sounds
	only for a cue whose id is filled in, re-checks on every tick, and picks up a
	pasted id the moment it appears with no other change anywhere.

	── ONE CONNECTION ──────────────────────────────────────────────────────────
	One Heartbeat, accumulated down to MIX_HZ. Music envelopes move over seconds;
	running them at frame rate would be sixty times the property writes for a
	difference nobody can hear, during the exact horde that needs the frame.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attributes = require(Shared.Net.Attributes)
local AudioConfig = require(Shared.Config.AudioConfig)
local DirectorConfig = require(Shared.Config.DirectorConfig)
local Enums = require(Shared.Enums)
local GameModeConfig = require(Shared.Config.GameModeConfig)
local InfectedConfig = require(Shared.Config.InfectedConfig)
local Registry = require(Shared.Util.Registry)
local Remotes = require(Shared.Net.Remotes)
local Trove = require(Shared.Util.Trove)

local MUSIC = AudioConfig.Music
local MIX = AudioConfig.Mix
local GA = Attributes.Game
local IA = Attributes.Infected
local PACING = Enums.PacingState
local ROUND = Enums.RoundState

local player = Players.LocalPlayer

--[[ Cue names, which are also the keys of AudioConfig.Music. Written out rather
     than spelled inline so a typo is a nil index at load rather than a track
     that silently never plays. ]]
local CUE = table.freeze({
	Ambient = "Ambient",
	Buildup = "Buildup",
	Horde = "Horde",
	TankTheme = "TankTheme",
	WitchTheme = "WitchTheme",
	WaveCleared = "WaveCleared",
	Defeat = "Defeat",
	Victory = "Victory",
})

--[[ The four values RoundService writes to Attributes.Game.WavePhase. There is
     no shared enum for them; RoundService and WaveController each declare the
     same set privately, and this is the third. ]]
local PHASE = table.freeze({
	Prep = "Prep",
	Active = "Active",
	Breather = "Breather",
	Over = "Over",
})

--[[ Pacing state -> cue, used only outside a running round. PeakFade shares
     Buildup deliberately: the horde is over but the team is still exposed, and
     dropping straight to Ambient there tells them they are safe a good ten
     seconds before they are. ]]
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
     actually keeps players alive. "Boss" is absent too — a Tank has its own
     attribute, and a Witch gets her theme from being NEAR you rather than from
     having spawned somewhere on the far side of the map. ]]
local EVENT = table.freeze({
	Pacing = "Pacing",
	HordeIncoming = "HordeIncoming",
	Calm = "Calm",
	Panic = "Panic",
})

--[[ How long before a wave lands the music starts telling you about it.

     Long enough to get your back to a wall, short enough that the breather is
     still a breather. This is the one cue in the game that is a promise rather
     than a reaction, and eight seconds is about how long a team needs to stop
     looting and look up. ]]
local BUILDUP_LEAD = 8

-- How many waves a round has, so the buildup never promises an eighth one.
local WAVE_COUNT = GameModeConfig.getWaveCount()

--[[ A Witch owns the music inside her own hearing range, which is the distance
     at which she is a threat to you rather than scenery. Taking the number from
     her definition means retuning her retunes the music with her. ]]
local WITCH_DEFINITION = InfectedConfig.get(Enums.Infected.Witch)
local WITCH_THEME_RADIUS = if WITCH_DEFINITION then WITCH_DEFINITION.hearingRange else 260

--[[ Ceilings for the timed overrides. The WaveCleared sting normally hands the
     mix back the instant it actually finishes — its length is a property of the
     asset and not something this file should claim to know — so this only ever
     applies when the asset never loaded and never reported an end. ]]
local WAVE_CLEARED_SECONDS = 10
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

--[[ The music slider, 0-1. Separate from `enabled` because a player who
     turns the music down to nothing has not asked the cue machine to stop
     deciding — the moment they turn it back up it should already be on the
     right track, not restarting the lobby loop mid-horde. ]]
local musicScale = 1

--[[ One cue's playback.

     `sounds` holds two instances for a cue that crossfades its own loop and one
     for everything else. `head` is the instance currently leading; `lapFrom` is
     the one dying underneath it during an overlap. ]]
type Voice = {
	sounds: { Sound },
	head: number,
	lapFrom: number?,
	lapAlpha: number, -- 0-1 through the loop overlap
	gain: number, -- 0-1 envelope, independent of the cue's own volume
	started: boolean, -- :Play() has been called and not yet undone by a full fade-out
	finished: boolean, -- a one-shot that has already played out
}

local voices: { [string]: Voice } = {}

-- Every live Witch model the client can see, kept as a set so the proximity
-- check is over the one boss rather than over forty-six commons.
local witches: { [Model]: boolean } = {}

local state = {
	pacing = PACING.Relax,
	round = ROUND.Lobby,
	tankActive = false,
	phase = PHASE.Over,
	waveIndex = 0,
	waveEndsAt = 0,
	current = "", -- the cue the mixer is currently driving toward
	overrideCue = "",
	overrideUntil = 0,
	overrideHoldsPhase = false, -- cleared by the next phase change
}

local accumulator = 0

-- ── voices ──────────────────────────────────────────────────────────────────

local function buildSound(name: string, cue: any, index: number): Sound
	local sound = Instance.new("Sound")
	sound.Name = string.format("FL_Music_%s_%d", name, index)
	sound.SoundId = cue.id
	--[[ Looped by the ENGINE only when we are not overlapping it ourselves. The
	     engine's loop is exactly the hard cut loopCrossfade exists to remove. ]]
	sound.Looped = cue.looped == true and (cue.loopCrossfade or 0) <= 0
	sound.Volume = 0
	--[[ Parented under SoundService rather than to a part: music is not a thing
	     happening somewhere in the room, and a positional music track would
	     swing across the stereo field every time the player turned around. ]]
	sound.Parent = folder
	trove:add(sound)
	return sound
end

--[[
	The Voice for a cue, or nil while its id is still empty.

	Called every tick for the cue that wants to play, which is what makes a
	pasted asset id work with no other change: the moment AudioConfig.Music
	carries an id, the next tick builds the Sounds and fades them in.
]]
local function ensureVoice(name: string): Voice?
	local cue = MUSIC[name]
	if not AudioConfig.isConfigured(cue) then
		return nil
	end

	local voice = voices[name]
	if voice then
		-- An id that changed under us (a live edit in Studio) is a different
		-- track, so it starts over rather than crossfading out of a waveform
		-- that no longer exists.
		if voice.sounds[1].SoundId ~= cue.id then
			for _, sound in voice.sounds do
				sound:Stop()
				sound.SoundId = cue.id
			end
			voice.started = false
			voice.finished = false
			voice.head = 1
			voice.lapFrom = nil
			voice.lapAlpha = 0
		end
		return voice
	end

	local sounds = { buildSound(name, cue, 1) }
	if cue.looped == true and (cue.loopCrossfade or 0) > 0 then
		--[[ The second instance IS the crossfade. None of these tracks were
		     authored to loop seamlessly, so the tail of one repeat has to play
		     over the head of the next; one Sound cannot overlap itself. ]]
		table.insert(sounds, buildSound(name, cue, 2))
	end

	voice = {
		sounds = sounds,
		head = 1,
		lapFrom = nil,
		lapAlpha = 0,
		gain = 0,
		started = false,
		finished = false,
	}
	voices[name] = voice
	return voice
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

--[[ Equal-power rather than linear across the loop overlap: the tail and the
     head of a track are uncorrelated, so two half-volume copies are audibly
     QUIETER than one full one, and a linear crossfade dips every time round. ]]
local function applyVolume(name: string, voice: Voice)
	local cue = MUSIC[name]
	if not cue then
		return
	end
	local base = cue.volume * MIX.MasterVolume * musicScale * duckFor(name) * voice.gain

	for index, sound in voice.sounds do
		local share: number
		if voice.lapFrom == index then
			share = math.sqrt(1 - voice.lapAlpha)
		elseif index == voice.head then
			share = if voice.lapFrom then math.sqrt(voice.lapAlpha) else 1
		else
			share = 0
		end
		sound.Volume = base * share
	end
end

--[[
	Keeps a looped cue looping, by overlap rather than by restart.

	`TimeLength` is 0 until the asset has streamed in, so this is re-evaluated
	every tick rather than scheduled once. A track that is shorter than its own
	crossfade (or that never loaded) falls back to a hard restart, which sounds
	worse but is still better than a cue going silent halfway through a horde.
]]
local function stepLoop(voice: Voice, cue: any, deltaTime: number)
	local overlap = cue.loopCrossfade or 0
	local head = voice.sounds[voice.head]

	if voice.lapFrom then
		voice.lapAlpha = math.min(voice.lapAlpha + deltaTime / math.max(overlap, MIN_FADE), 1)
		if voice.lapAlpha >= 1 then
			voice.sounds[voice.lapFrom]:Stop()
			voice.lapFrom = nil
			voice.lapAlpha = 0
		end
		-- One overlap at a time. A second one starting mid-lap would stack three
		-- copies of the same track on top of each other.
		return
	end

	local length = head.TimeLength
	if length <= 0 then
		--[[ Still streaming in, or an id that will never resolve. Either way
		     there is nothing to schedule an overlap against, and nothing to
		     restart — a "restart it because it is not playing" fallback here
		     would call Play() twenty times a second forever on a broken id. ]]
		return
	end

	if #voice.sounds < 2 or overlap <= 0 or length <= overlap then
		-- A track shorter than its own crossfade, or one the config asked not to
		-- overlap. A hard restart sounds worse and is still better than a cue
		-- going silent halfway through a horde.
		if not head.IsPlaying and not head.Looped then
			head.TimePosition = 0
			head:Play()
		end
		return
	end

	if length - head.TimePosition > overlap then
		return
	end

	local following = 3 - voice.head
	local sound = voice.sounds[following]
	sound.TimePosition = 0
	sound:Play()
	voice.lapFrom = voice.head
	voice.head = following
	voice.lapAlpha = 0
end

local function stopVoice(voice: Voice)
	for _, sound in voice.sounds do
		if sound.IsPlaying then
			sound:Stop()
		end
		sound.Volume = 0
	end
	voice.lapFrom = nil
	voice.lapAlpha = 0
end

-- ── the cue decision ────────────────────────────────────────────────────────

--[[ True while a live Witch is inside her own hearing range of the player. She
     has no attribute of her own — TankActive exists, WitchActive does not — so
     presence is read off the models InfectedService parents into workspace. ]]
local function witchIsNear(): boolean
	if next(witches) == nil then
		return false
	end

	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return false
	end
	local origin = root.Position

	for model in witches do
		if model.Parent == nil then
			-- Clearing the key we are standing on is legal, and this is the only
			-- place a despawned Witch gets forgotten.
			witches[model] = nil
			continue
		end
		if model:GetAttribute(IA.IsDead) == true then
			continue
		end
		local witchRoot = model.PrimaryPart or model:FindFirstChild("HumanoidRootPart")
		if
			witchRoot
			and witchRoot:IsA("BasePart")
			and (witchRoot.Position - origin).Magnitude <= WITCH_THEME_RADIUS
		then
			return true
		end
	end
	return false
end

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
	-- A Tank outranks everything the wave schedule has to say, because while one
	-- is alive nothing else on the map matters.
	if state.tankActive then
		return CUE.TankTheme
	end
	if witchIsNear() then
		return CUE.WitchTheme
	end
	if state.overrideCue ~= "" and now < state.overrideUntil then
		return state.overrideCue
	end

	local phase = state.phase
	if phase == PHASE.Active then
		return CUE.Horde
	end
	if phase == PHASE.Prep or phase == PHASE.Breather then
		--[[ WaveEndsAt is an absolute workspace:GetServerTimeNow() stamp, so the
		     approach is a subtraction against the same clock the server wrote
		     it on — no countdown to keep, and nothing to drift.

		     WaveIndex is the wave this breather follows (0 during prep), so the
		     buildup only promises a wave that actually exists. A breather after
		     the last one is the round ending, not another horde. ]]
		local remaining = state.waveEndsAt - Workspace:GetServerTimeNow()
		local hasNextWave = state.waveIndex < WAVE_COUNT
		if hasNextWave and state.waveEndsAt > 0 and remaining <= BUILDUP_LEAD then
			return CUE.Buildup
		end
		return CUE.Ambient
	end

	-- No wave clock: a lobby, a result screen, or a mode that does not run
	-- waves. The Director is the only thing left with an opinion, so it keeps it.
	return PACING_CUE[state.pacing] or CUE.Ambient
end

local function setOverride(cue: string, seconds: number, holdsPhase: boolean)
	state.overrideCue = cue
	state.overrideUntil = os.clock() + seconds
	state.overrideHoldsPhase = holdsPhase
end

local function clearOverride()
	state.overrideCue = ""
	state.overrideUntil = 0
	state.overrideHoldsPhase = false
end

local function setPacing(newState: string)
	if typeof(newState) ~= "string" then
		return
	end
	state.pacing = newState
end

local function setPhase(newPhase: string)
	if typeof(newPhase) ~= "string" or newPhase == state.phase then
		return
	end
	state.phase = newPhase
	-- A cue standing in for a moment (the wave-cleared sting) is over the
	-- instant the round moves on from that moment.
	if state.overrideHoldsPhase then
		clearOverride()
	end
end

-- ── the mixer ───────────────────────────────────────────────────────────────

local function mix(deltaTime: number)
	local now = os.clock()
	local wanted = resolveCue(now)

	-- Build the wanted cue's Sounds on demand. Silent and free while its id is
	-- still empty.
	if wanted ~= "" then
		ensureVoice(wanted)
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
			voice.head = 1
			voice.lapFrom = nil
			voice.lapAlpha = 0
			local sound = voice.sounds[1]
			sound.TimePosition = 0
			sound:Play()
		end

		if voice.started then
			if cue.looped == true then
				stepLoop(voice, cue, deltaTime)
			elseif voice.gain >= 1 and not voice.sounds[1].IsPlaying then
				voice.finished = true
			end
		end

		applyVolume(name, voice)

		if not rising and voice.gain <= SILENCE_EPSILON then
			voice.gain = 0
			stopVoice(voice)
			--[[ Out of the mix entirely rather than merely finished, so a cue
			     the round comes back to (the next wave, the next panic event)
			     starts from the top. ]]
			if not selected then
				voice.started = false
				voice.finished = false
				voice.head = 1
			end
		end
	end

	--[[ A sting hands the mix back the moment it genuinely ends rather than at a
	     duration guessed here: how long WaveCleared runs for is a property of
	     the asset, and this file has no business claiming to know it. ]]
	if state.overrideCue ~= "" then
		local overrideVoice = voices[state.overrideCue]
		if overrideVoice and overrideVoice.finished then
			clearOverride()
		end
	end
end

-- ── inputs ──────────────────────────────────────────────────────────────────

local function readAttributes()
	setPacing(Attributes.get(Workspace, GA.PacingState, PACING.Relax))
	state.round = Attributes.get(Workspace, GA.RoundState, ROUND.Lobby)
	state.tankActive = Attributes.get(Workspace, GA.TankActive, false) == true
	state.waveIndex = Attributes.get(Workspace, GA.WaveIndex, 0)
	state.waveEndsAt = Attributes.get(Workspace, GA.WaveEndsAt, 0)
	-- Through setPhase, not assigned: a phase EDGE is what retires a sting, and
	-- that has to happen whether the change arrived by attribute or by remote.
	setPhase(Attributes.get(Workspace, GA.WavePhase, PHASE.Over))
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
		setPacing(PACING.SustainPeak)
	elseif kind == EVENT.Calm then
		setPacing(PACING.Relax)
	elseif kind == EVENT.Panic then
		--[[ A panic event is a horde the wave schedule did not order, so it is
		     the one thing that can put the horde cue over a breather. ]]
		setOverride(CUE.Horde, PANIC_SECONDS, false)
	end
end

--[[ The phase edges. The attributes are the authority for WHAT is happening —
     they are read a line below — and this remote is what says a wave just
     ENDED, which is the only moment the cleared sting is correct. ]]
local function onWaveChanged(payload: any)
	if typeof(payload) ~= "table" then
		return
	end
	readAttributes()

	if payload.isBreather == true and state.round ~= ROUND.Victory then
		setOverride(CUE.WaveCleared, WAVE_CLEARED_SECONDS, true)
	else
		-- A wave starting is never the moment for a sting about the last one.
		clearOverride()
	end
end

local function onRoundStateChanged(payload: any)
	if typeof(payload) ~= "table" then
		return
	end
	if typeof(payload.state) == "string" then
		state.round = payload.state
	end
end

-- ── the Witch watch ─────────────────────────────────────────────────────────

local function considerInfected(instance: Instance)
	if not instance:IsA("Model") then
		return
	end
	if instance:GetAttribute(IA.Kind) == Enums.Infected.Witch then
		witches[instance] = true
	end
end

--[[ Watches the folder InfectedService spawns bodies into. Cheap on purpose:
     one filtered call per spawn and no lasting connection per model, because
     forty-six of those during a horde is exactly the shape of leak this
     codebase forbids. ]]
local function watchInfected(folderInstance: Instance)
	for _, child in folderInstance:GetChildren() do
		considerInfected(child)
	end

	trove:connect(folderInstance.ChildAdded, function(child: Instance)
		considerInfected(child)
		if child:GetAttribute(IA.Kind) == nil then
			-- Attributes normally arrive with the instance; a deferred second
			-- look costs one call and covers the case where they do not.
			task.defer(considerInfected, child)
		end
	end)

	trove:connect(folderInstance.ChildRemoved, function(child: Instance)
		witches[child] = nil
	end)
end

-- ── public API ──────────────────────────────────────────────────────────────

--[[ Forces a cue for `seconds`, on top of whatever the round is doing. For
     anything with its own idea of a moment — a scripted set piece, a finale
     crescendo — that the wave schedule does not model. ]]
function MusicController:play(cue: string, seconds: number?)
	if MUSIC[cue] == nil then
		return
	end
	setOverride(cue, seconds or DEFAULT_HOLD_SECONDS, false)
end

--[[ Drops any forced cue and hands the mix back to the round. ]]
function MusicController:resume()
	clearOverride()
end

--[[ The cue the mixer is driving toward. "" when the music is off, and note
     that a cue with no asset id still reports here — the decision is real even
     while the bank is incomplete. ]]
function MusicController:getCue(): string
	return state.current
end

function MusicController:setEnabled(value: boolean)
	enabled = value == true
end

--[[
	The player's music volume, 0-1.

	Applied on the spot rather than at the next mix tick: the slider is being
	dragged while they listen, and a quarter-second of latency on a volume
	control reads as the control not working.
]]
function MusicController:setVolume(scale: number)
	local wanted = if typeof(scale) == "number" and scale == scale then math.clamp(scale, 0, 1) else 1
	if wanted == musicScale then
		return
	end
	musicScale = wanted
	for name, voice in voices do
		applyVolume(name, voice)
	end
end

function MusicController:getVolume(): number
	return musicScale
end

function MusicController:isEnabled(): boolean
	return enabled
end

--[[ Stops everything immediately, with no fade. For a round teardown, not for
     a phase change — a cut is exactly what this controller exists to avoid. ]]
function MusicController:stopAll()
	for name, voice in voices do
		voice.gain = 0
		stopVoice(voice)
		voice.started = false
		voice.finished = false
		voice.head = 1
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
	local watched = {
		GA.PacingState,
		GA.RoundState,
		GA.TankActive,
		GA.WavePhase,
		GA.WaveIndex,
		GA.WaveEndsAt,
	}
	for _, attribute in watched do
		trove:connect(Workspace:GetAttributeChangedSignal(attribute), readAttributes)
	end

	trove:connect(Remotes.Event.DirectorEvent.OnClientEvent, onDirectorEvent)
	trove:connect(Remotes.Event.RoundStateChanged.OnClientEvent, onRoundStateChanged)
	trove:connect(Remotes.Event.WaveChanged.OnClientEvent, onWaveChanged)

	local infected = Workspace:FindFirstChild("Infected")
	if infected then
		watchInfected(infected)
	else
		-- The server creates the folder at boot, so this only fires for a client
		-- that got there first.
		local connection: RBXScriptConnection
		connection = Workspace.ChildAdded:Connect(function(child: Instance)
			if child.Name == "Infected" then
				connection:Disconnect()
				watchInfected(child)
			end
		end)
		trove:add(connection)
	end

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
	table.clear(witches)
end

Registry.register("MusicController", MusicController)

return MusicController
