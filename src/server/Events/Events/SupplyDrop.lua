--!nonstrict
--[[
	Supply Drop — something worth crossing the map for, somewhere the map chose.

	── THE MAP SAYS WHERE, THE GAME SAYS WHEN ──────────────────────────────────
	A map puts parts in Events/SupplyDrops and this picks one. It has no idea
	what those places are — a rooftop, a parking lot, a back alley — and it does
	not need to: the designer who put the part there knew, and that is the whole
	contract. A map with no drop points never sees this event.

	Which one is rolled fresh every time, so the same map does not train players
	to run to the same corner.

	── IT MAKES NOTHING NEW ────────────────────────────────────────────────────
	The pile is built by ItemPlacer, out of the same pickups the level already
	scatters, and it is picked up through the ordinary floor-pickup path. There is
	no new item, no new currency, no reward table of its own — a supply drop is
	the map restocking somewhere unusual at a time nobody expected, and that is
	worth more than an invented prize because a player already knows exactly what
	a medkit on the floor is worth to them right now.

	── AND IT EXPIRES ──────────────────────────────────────────────────────────
	What is left when the event ends is removed, because a drop that stays is
	just a stash, and the decision the event is FOR — go now, or hold the line —
	only exists while there is a clock on it. Anything already picked up is gone
	from the world and cannot be taken back.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Enums = require(Shared.Enums)
local EventConfig = require(Shared.Config.EventConfig)
local Registry = require(Shared.Util.Registry)

local Support = require(script.Parent.Parent.Support)

--[[
	What lands, in order.

	Fixed rather than rolled, and generous rather than random: this is the one
	event a team can choose to walk toward, and the walk has to be worth it every
	time. A drop that rolls badly is a team that crossed a map under fire for two
	pain pills, and they will not go for the next one.

	A medkit is the anchor — it is the item this game's economy of health is
	built around — with a throwable and pills to make the trip pay even for a
	team already at full strength.
]]
local CONTENTS = table.freeze({
	table.freeze({ slot = Enums.Slot.Health, item = Enums.HealthItem.Medkit }),
	table.freeze({ slot = Enums.Slot.Health, item = Enums.HealthItem.Medkit }),
	table.freeze({ slot = Enums.Slot.Throwable, item = Enums.Throwable.PipeBomb }),
	table.freeze({ slot = Enums.Slot.Throwable, item = Enums.Throwable.Molotov }),
	table.freeze({ slot = Enums.Slot.Pills, item = Enums.PillItem.PainPills }),
})

--[[ How far apart the pieces sit, and how high above the marker they start.
     Spread so the pile reads as a pile rather than as one item, and lifted
     because a pickup built at floor level inside a marker part is a pickup
     inside the floor. ]]
local SPREAD = 3.2
local LIFT = 2.5

local random = Random.new()

local SupplyDrop = {}

SupplyDrop.claims = { EventConfig.Id.SupplyDrop }

function SupplyDrop.supported(): boolean
	if #Support.dropPoints() == 0 then
		return false
	end
	local placer = Registry.find("ItemPlacer")
	return placer ~= nil and typeof(placer.spawnPickup) == "function"
end

function SupplyDrop.start(context: any)
	local points = Support.dropPoints()
	if #points == 0 then
		return
	end
	local marker = points[random:NextInteger(1, #points)]
	local placer = Registry.find("ItemPlacer")
	if not placer then
		return
	end

	local origin = marker.Position + Vector3.new(0, marker.Size.Y * 0.5 + LIFT, 0)
	local spawned = {}

	for index, entry in CONTENTS do
		--[[ Laid out on a ring rather than in a line, so the pile looks the same
		     from whichever side the team arrives — which, on a map this code has
		     never seen, could be any of them. ]]
		local angle = (index / #CONTENTS) * math.pi * 2
		local offset = Vector3.new(math.cos(angle) * SPREAD, 0, math.sin(angle) * SPREAD)
		local ok, model = pcall(placer.spawnPickup, placer, entry.slot, entry.item, origin + offset)
		if ok and typeof(model) == "Instance" then
			table.insert(spawned, model)
		end
	end

	context.state.spawned = spawned
	context.state.marker = marker

	--[[ Said rather than marked on a HUD. The team has to find it, and the
	     finding is the event — a waypoint would turn a search into a walk. The
	     part's own name is the direction, which is why a designer naming these
	     "Rooftop" and "Back Alley" is doing something useful. ]]
	Support.say("RADIO", string.format("Drop is down near the %s. It will not sit there long.", marker.Name))
	Support.play("Radio", marker.Position)
end

function SupplyDrop.stop(context: any)
	--[[ Only what is still there. A pickup somebody took was destroyed by
	     InventoryService when they took it, and the reference here is to an
	     instance that no longer has a parent — checking is cheaper than being
	     wrong about which. ]]
	for _, model in context.state.spawned or {} do
		if model.Parent then
			model:Destroy()
		end
	end
	context.state.spawned = nil
end

return SupplyDrop
