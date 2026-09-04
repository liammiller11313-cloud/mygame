--!nonstrict
--[[
	Emergency Broadcast — the world talking, and not to you.

	The only event that does nothing. No lighting, no spawns, no items, no
	mechanical effect of any kind: a radio comes through, says three lines, and
	stops. It is here because a world that occasionally speaks is a world, and
	because the first time it happens nobody knows it is harmless — which is
	worth something on its own in a game where every other announcement means
	trouble.

	── ONCE A ROUND ────────────────────────────────────────────────────────────
	EventConfig marks it non-repeatable, and that is the whole design. A second
	transmission is a radio station; the first one is somebody out there.

	── AND IT ANSWERS NOTHING ──────────────────────────────────────────────────
	None of the lines resolves anything. The moment one does, this becomes a hint
	system, and every player who drew a different broadcast feels they got the
	wrong one. See EventConfig.Broadcasts.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local EventConfig = require(Shared.Config.EventConfig)

local Support = require(script.Parent.Parent.Support)

--[[ How long each line holds, and the gap after it. Slower than a combat
     callout: this is somebody reading, not somebody shouting over gunfire, and
     the pace is most of what tells them apart. ]]
local LINE_HOLD = 5.0
local LINE_GAP = 5.6

--[[ Before the first line. The blip lands, then a beat of nothing, then the
     voice — which is how a transmission opening actually sounds and stops the
     first line being swallowed by the noise announcing it. ]]
local OPENING_DELAY = 1.4

local random = Random.new()

local EmergencyBroadcast = {}

EmergencyBroadcast.claims = { EventConfig.Id.EmergencyBroadcast }

--[[ Needs nothing. No map support, no service, no objects — it is a few lines of
     text and it works on a map that is an empty baseplate, which is exactly what
     you want from the event that carries the world's voice. ]]
function EmergencyBroadcast.supported(): boolean
	return true
end

function EmergencyBroadcast.start(context: any)
	local pool = EventConfig.Broadcasts
	if #pool == 0 then
		return
	end

	local state = context.state
	state.message = pool[random:NextInteger(1, #pool)]
	state.line = 0
	--[[ The blip lands, then a beat of nothing, then the voice. That is how a
	     transmission opening actually sounds, and without the beat the first line
	     is swallowed by the noise announcing it. ]]
	state.nextLineAt = 0
	state.openingAt = OPENING_DELAY

	--[[ Played at the team rather than positionally. A transmission arrives on a
	     radio somebody is carrying, not from a point in the map, and giving it a
	     location would have players turning to look for a speaker. ]]
	local centre = Support.teamCentre()
	if centre then
		Support.play("Radio", centre)
	end
end

--[[
	The lines, paced on the DIRECTOR'S tick rather than on a thread of its own.

	This was a task.spawn with task.wait between lines, and it worked — but a
	spawned thread keeps running through a pause, so a solo player who paused
	mid-transmission came back to a radio that had finished talking to an empty
	room. The director's tick is already frozen while the game is, so pacing here
	is paused for free and there is no thread to guard against a round ending
	underneath it either.

	`now` is server time and `state.startedAt` is stamped on the first tick rather
	than in start(), because start() is the frame the banner goes up and the
	opening beat should be measured from the sound, not from the schedule.
]]
function EmergencyBroadcast.update(context: any, now: number)
	local state = context.state
	local message = state.message
	if not message or state.line >= #message.lines then
		return
	end

	if not state.startedAt then
		state.startedAt = now
		state.nextLineAt = now + state.openingAt
		return
	end
	if now < state.nextLineAt then
		return
	end

	state.line += 1
	state.nextLineAt = now + LINE_GAP
	Support.say(message.speaker, message.lines[state.line], LINE_HOLD)
end

--[[ Nothing to stop. There is no thread and no world state — the last line
     either played or it did not, and a transmission cut short by a round ending
     is a transmission cut short, which is fine. ]]
function EmergencyBroadcast.stop(context: any)
	context.state.message = nil
end

return EmergencyBroadcast
