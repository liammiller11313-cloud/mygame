--!nonstrict
--[[
	Zombie Surge — a crowd, now, on top of whatever the wave was already doing.

	── IT DOES NOT SPAWN ANYTHING ──────────────────────────────────────────────
	Which is the entire design of this module. DirectorService already owns a
	"drop a horde on this position" behaviour — the panic event, three waves over
	forty-five seconds, placed at the level's own spawn nodes and counted against
	the same population cap as everything else. That is exactly this event, and
	it was already written, tested and balanced.

	So this calls it. There is no second spawner, no second population count, no
	second idea about where a body may appear, and nothing here to drift out of
	step with the Director the day its spawning changes.

	── AND IT CHANGES NOTHING PERMANENTLY ──────────────────────────────────────
	No wave budget is touched, no difficulty is raised, no config is written. The
	surge is a one-shot request; when it is over the Director is doing exactly
	what it was doing before, because it never stopped.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local EventConfig = require(Shared.Config.EventConfig)
local Registry = require(Shared.Util.Registry)

local Support = require(script.Parent.Parent.Support)

--[[ How many of the panic event's waves this is worth. The full panic is three
     and belongs to the vault — a side objective the team chose to complete, with
     a reward at the end of it. A random event nobody asked for is two: enough
     to be the thing happening for the next minute, not enough to be the round. ]]
local SURGE_WAVES = 2

local ZombieSurge = {}

ZombieSurge.claims = { EventConfig.Id.ZombieSurge }

--[[ Needs a Director and a team to send it at, and nothing from the map. The
     spawn nodes it ends up using are the level's own, which every playable map
     already has — a map without them cannot run a normal wave either. ]]
function ZombieSurge.supported(): boolean
	local director = Registry.find("DirectorService")
	return director ~= nil and typeof(director.triggerPanicEvent) == "function"
end

function ZombieSurge.start()
	local centre = Support.teamCentre()
	if not centre then
		--[[ Nobody is up. The director's own eligibility check should have caught
		     this, and if it did not, the honest thing is to do nothing rather than
		     to drop a horde on the origin. ]]
		return
	end

	local director = Registry.find("DirectorService")
	if director then
		director:triggerPanicEvent(centre, SURGE_WAVES)
	end
end

--[[ Nothing to undo. The panic event runs itself out on the Director's own
     clock and the bodies it made are ordinary infected that die like any other
     — an event that "ended" by deleting them would be taking the fight away
     halfway through. The duration in EventConfig is how long the BANNER and the
     event state last, not a leash on the horde. ]]
function ZombieSurge.stop() end

return ZombieSurge
