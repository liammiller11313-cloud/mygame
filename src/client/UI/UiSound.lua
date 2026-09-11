--!nonstrict
--[[
	UiSound — the 2D cues the interface makes, from one implementation.

	Eight controllers had grown their own `playUi`, and they had drifted in a way
	that mattered rather than a way that was merely untidy:

	  * FIVE of them ignored pitchMin/pitchMax entirely, so the cue played at
	    exactly one pitch every time. AudioConfig's own header opens with
	    "anything you hear more than once a second gets varied", and a menu
	    click is heard rather more often than that — as is a hitmarker.
	  * Four created a Sound instance per play and destroyed it on Ended. During
	    a horde that is one instance per hit, garbage-collected on a delay,
	    for a sound that is always the same handful of assets.
	  * Only one of them routed through the master SoundGroup, so the volume
	    setting silently did not apply to the other seven.

	This is that function once: one cached Sound per asset id, pitch varied per
	play, throttled so a shotgun blast resolving as ten hits is one tick rather
	than ten, and routed through whatever group `setGroup` was handed.

	── WHY UI SOUND IS NOT AudioService'S JOB ───────────────────────────────────
	AudioService is server-side and spatial: it plays a sound AT a position for
	everyone in range. Every cue here is 2D, belongs to one client, and has no
	position at all — a hitmarker is not somewhere, it is feedback. Routing these
	through a positional system would be the wrong shape and a round trip.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local AudioConfig = require(Shared.Config.AudioConfig)

local UiSound = {}

local random = Random.new()

--[[ Keyed by ASSET id rather than by definition, so two definitions that share
     a sample share one instance. Six of the sixteen weapon fire sounds do. ]]
local sounds: { [string]: Sound } = {}
local lastPlayed: { [string]: number } = {}
local group: SoundGroup? = nil

--[[ Routes everything through a SoundGroup, so the master volume setting
     actually reaches these. Applied to what already exists as well as to what
     is made later: the menu builds its group after some cues may have played. ]]
function UiSound.setGroup(value: SoundGroup?)
	group = value
	for _, sound in sounds do
		sound.SoundGroup = value
	end
end

--[[
	Plays a UI cue.

	Silent for an unconfigured definition rather than an error, which is the
	promise AudioConfig makes: a partially filled bank is a working game with
	fewer sounds in it, never a broken one.

	Throttled per ASSET, not per definition or globally. A shotgun blast resolves
	as up to ten HitConfirmed events in one frame and should tick once; a kill
	landing in the same frame as a hit is a different asset and should still be
	heard, because those two are the whole point of having separate cues.
]]
function UiSound.play(definition: any)
	if not AudioConfig.isConfigured(definition) then
		return
	end
	local id = AudioConfig.pickId(definition)
	if id == "" then
		return
	end

	local now = os.clock()
	if now - (lastPlayed[id] or 0) < AudioConfig.Mix.MinRetriggerInterval then
		return
	end
	lastPlayed[id] = now

	local sound = sounds[id]
	if not sound then
		sound = Instance.new("Sound")
		sound.Name = "FL_Ui"
		sound.SoundId = id
		sound.SoundGroup = group
		sound.Parent = SoundService
		sounds[id] = sound
	end

	--[[ Volume is set per play, not once at creation: two definitions can share
	     an asset and want different volumes — the kill cue and the hit tick did
	     exactly that before they had separate samples. ]]
	--[[ The definition's own volume and nothing else. The trim used to be
	     applied here as well, which was harmless only while it was 1.0 -- every
	     one of these sounds is in the master SoundGroup, which now carries it, so
	     multiplying here too would trim the interface twice and leave the UI
	     quieter than the world it sits over. ]]
	sound.Volume = definition.volume
	sound.PlaybackSpeed = random:NextNumber(definition.pitchMin, definition.pitchMax)
	--[[ Rewound rather than left to finish. A cue re-triggered past the throttle
	     is a NEW event and has to sound like one; letting it run on from where it
	     was is how a rapid confirm turns into a stutter. ]]
	sound.TimePosition = 0
	sound:Play()
end

--[[ Drops every cached instance. Only for a client tearing its interface down;
     nothing in normal play calls this. ]]
function UiSound.destroy()
	for _, sound in sounds do
		sound:Destroy()
	end
	table.clear(sounds)
	table.clear(lastPlayed)
	group = nil
end

return UiSound
