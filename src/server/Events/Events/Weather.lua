--!nonstrict
--[[
	Weather — heavy rain, dense fog and the thunderstorm, which are one module.

	Three events out of one file because they are the same event with different
	numbers: ask AtmosphereService for a grade, optionally throw lightning, put
	the grade back. Splitting them into three would be three copies of four lines
	and three places to fix the day the sky grows another knob.

	── NOTHING IS SAVED AND NOTHING IS RESTORED ────────────────────────────────
	Which is worth saying out loud, because the obvious way to write a weather
	event is to read Lighting, keep the old values, write new ones and put them
	back — and that version breaks the first time two things want the sky, or a
	round ends mid-event, or a module errors between the read and the write.

	AtmosphereService already recomputes the entire look every tick from the
	round clock plus whatever moods are active. So a weather event sets a mood
	and clears it. There is no old value to lose.

	── THE STORM'S LIGHTNING IS NOT ON A TIMER ─────────────────────────────────
	Every strike schedules the next one at a random distance inside a band, which
	is the same trick the ambient sky uses for its own distant flashes. A storm
	whose lightning arrived every four seconds would stop being weather within
	about twelve seconds of anybody noticing.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local EventConfig = require(Shared.Config.EventConfig)
local Registry = require(Shared.Util.Registry)

local Support = require(script.Parent.Parent.Support)

local ID = EventConfig.Id

--[[ Which grade each of the three asks for. The names are AtmosphereService's,
     and an id missing from here simply gets no sky — which is why the fog event
     appears in this table even though it does nothing else. ]]
local GRADE = table.freeze({
	[ID.HeavyRain] = "Rain",
	[ID.DenseFog] = "Fog",
	[ID.Thunderstorm] = "Storm",
})

--[[ The gap between strikes, and how hard each one hits. The flash goes through
     AtmosphereService rather than being written to Lighting for the same reason
     the grade does: it is added on top of the resolved look and ends by writing
     the correctly interpolated value back. ]]
local STRIKE_MIN_GAP = 4.5
local STRIKE_MAX_GAP = 16.0
local STRIKE_DURATION = 0.30
local STRIKE_INTENSITY = 0.55

--[[ A second flash, close behind, some of the time. Real lightning rarely
     strikes once and the double is most of what sells it. ]]
local DOUBLE_CHANCE = 0.4
local DOUBLE_GAP = 0.16

--[[ How long after the flash the thunder arrives. Sound is slower than light and
     everybody knows it; a bang on the same frame as the flash reads as a bug in
     a way that a delay never does. ]]
local THUNDER_DELAY_MIN = 0.6
local THUNDER_DELAY_MAX = 2.4

local random = Random.new()

local Weather = {}

--[[ Three ids, one module. See the header: a rain event and a storm are the
     same four lines with different numbers. ]]
Weather.claims = { ID.HeavyRain, ID.DenseFog, ID.Thunderstorm }

--[[ Weather works anywhere. It needs nothing from the map — no folder, no
     fixtures, no drop points — which is exactly why it is the common case and
     why every map gets these three whatever else it supports. ]]
function Weather.supported(): boolean
	return true
end

function Weather.start(context: any)
	Support.setWeather(GRADE[context.definition.id])
	context.state.nextStrikeAt = 0
	context.state.pendingStrikeAt = 0
	context.state.pendingIntensity = 0
end

--[[ Only the storm ticks. Rain and fog set a grade and are then finished until
     something stops them, which is what makes them nearly free. ]]
function Weather.update(context: any, now: number)
	if context.definition.id ~= ID.Thunderstorm then
		return
	end
	local state = context.state

	--[[ The second half of a double, if one was rolled. Checked before the
	     schedule below so a double never delays the next strike proper. ]]
	if state.pendingStrikeAt > 0 and now >= state.pendingStrikeAt then
		state.pendingStrikeAt = 0
		Weather._flash(state.pendingIntensity)
	end

	if now < state.nextStrikeAt then
		return
	end
	--[[ Scheduled BEFORE the strike rather than after, so a strike that throws
	     for any reason still leaves a next one on the clock. An event that stops
	     flashing halfway through is a storm that quietly became fog. ]]
	state.nextStrikeAt = now + random:NextNumber(STRIKE_MIN_GAP, STRIKE_MAX_GAP)

	Weather._flash(STRIKE_INTENSITY)
	if random:NextNumber() < DOUBLE_CHANCE then
		state.pendingStrikeAt = now + DOUBLE_GAP
		state.pendingIntensity = STRIKE_INTENSITY * 0.6
	end
end

--[[ One strike: the light, then the sound a beat later. Split out because the
     double needs the same thing and a copy of it would be a copy that drifts. ]]
function Weather._flash(intensity: number)
	local atmosphere = Registry.find("AtmosphereService")
	if atmosphere and typeof(atmosphere.flash) == "function" then
		atmosphere:flash(STRIKE_DURATION, intensity)
	end

	local delay = random:NextNumber(THUNDER_DELAY_MIN, THUNDER_DELAY_MAX)
	--[[ Around the team rather than at a fixed point, so the thunder is
	     overhead wherever the round has got to. It falls back to nothing rather
	     than to the origin: a bang from the corner of the map is worse than
	     silence. ]]
	task.delay(delay, function()
		local centre = Support.teamCentre()
		if centre then
			Support.play("Thunder", centre + Vector3.new(0, 60, 0))
		end
	end)
end

function Weather.stop()
	Support.setWeather(nil)
end

return Weather
