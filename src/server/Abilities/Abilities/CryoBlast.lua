--!nonstrict
--[[
	Cryo Blast — freezes a doorway solid, and buys the seconds you needed.

	── IT SLOWS, IT DOES NOT STOP ──────────────────────────────────────────────
	SlowPercent 0.82 leaves a Common crawling at about four studs a second. Still
	coming, still swinging, still shootable. That number is the entire ability:
	an enemy frozen in place stops being frightening and becomes scenery, and the
	tension of a horde is that it is arriving. Slowly arriving is still arriving.

	── AND A BOSS KEEPS MOST OF ITS LEGS ───────────────────────────────────────
	BossResistance is the promise that the answer to a Tank is still a Tank's
	answer. The counter to one is running; an ability that switched that off
	would replace a movement problem with a button press. Four seconds of a Tank
	moving badly is worth a slot on its own — it just is not a solution.

	── IT IS A ONE-SHOT, NOT A FIELD ───────────────────────────────────────────
	The slow is applied to whatever is inside the radius AT THE MOMENT it lands
	and to nothing after. A persistent volume that kept chilling new arrivals
	would be a wall — the horde would pile up at its edge and stop being a horde
	— and it would need a per-frame overlap test against sixty bodies for seven
	seconds. This costs one sweep.
]]

local AbilitySupport = require(script.Parent.Parent.AbilitySupport)

local CryoBlast = {}

function CryoBlast.activate(context: any): boolean
	local tuning = context.tuning
	local caught = AbilitySupport.infectedWithin(context.target, tuning.Radius)

	for _, entry in caught do
		local brain = AbilitySupport.brainOf(entry.model)
		if not brain or typeof(brain.chill) ~= "function" then
			continue
		end
		--[[ A boss keeps `BossResistance` of the speed the slow would have taken.
		     At 0.82 slow and 0.65 resistance a Tank keeps about 71% of its pace,
		     which is a Tank you can still run from and cannot ignore. ]]
		local slow = if AbilitySupport.isBoss(entry.model)
			then tuning.SlowPercent * (1 - tuning.BossResistance)
			else tuning.SlowPercent
		brain:chill(1 - slow, tuning.Duration)
	end

	--[[ Broadcast whether or not it caught anything. The field is a place the
	     team can see and stand behind, so it has to be drawn even when the blast
	     landed on an empty street — that is a player reading the map, not a
	     wasted press. ]]
	AbilitySupport.broadcast("Cryo", {
		id = context.definition.id,
		player = context.player,
		position = context.target,
		radius = tuning.Radius,
		duration = tuning.Duration,
		caught = #caught,
	})
	return true
end

return CryoBlast
