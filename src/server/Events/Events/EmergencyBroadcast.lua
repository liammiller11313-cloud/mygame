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
	local message = pool[random:NextInteger(1, #pool)]

	context.state.generation = (context.state.generation or 0) + 1
	local mine = context.state.generation
	local state = context.state
	state.running = true

	--[[ Played at the team rather than positionally. A transmission is arriving
	     on a radio somebody is carrying, not from a point in the map, and giving
	     it a location would have players turning to look for a speaker. ]]
	local centre = Support.teamCentre()
	if centre then
		Support.play("Radio", centre)
	end

	task.spawn(function()
		task.wait(OPENING_DELAY)
		for _, line in message.lines do
			--[[ Checked between every line, not just at the top. The whole message
			     takes the best part of twenty seconds and a round can end inside
			     it — a broadcast still talking over a scoreboard is the kind of
			     thing that survives a hundred playtests and then ships. ]]
			if state.generation ~= mine or not state.running then
				return
			end
			Support.say(message.speaker, line, LINE_HOLD)
			task.wait(LINE_GAP)
		end
	end)
end

function EmergencyBroadcast.stop(context: any)
	context.state.running = false
	context.state.generation = (context.state.generation or 0) + 1
end

return EmergencyBroadcast
