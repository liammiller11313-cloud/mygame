--!strict
--[[
	AbilitySupport — the parts more than one ability does the same way.

	The same idea as Infected/Specials/Support: five modules that grew up beside
	each other converge on the same three or four helpers, and four copies of
	"find the infected near this point" is four places to fix when the infected
	folder moves.

	Only what is genuinely shared lives here. What an ability DOES is the
	ability's own file, and nothing in this module has grown a parameter to serve
	one caller.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attributes = require(Shared.Net.Attributes)
local InfectedConfig = require(Shared.Config.InfectedConfig)
local Registry = require(Shared.Util.Registry)
local Remotes = require(Shared.Net.Remotes)
local RigUtil = require(Shared.Util.RigUtil)

local IA = Attributes.Infected

local AbilitySupport = {}

export type Target = {
	model: Model,
	root: BasePart,
	distance: number,
}

--[[ Tells every client to draw something. Fired to ALL rather than to the
     owner: an airstrike marker on the ground is a thing the whole team has to
     see before it lands, and a shield around a teammate is how you know not to
     spend a medkit on them. Nothing here is authoritative — the damage and the
     healing already happened on the server by the time this goes out. ]]
function AbilitySupport.broadcast(kind: string, payload: { [string]: any })
	payload.kind = kind
	Remotes.Event.AbilityEvent:FireAllClients(payload)
end

--[[
	Every living infected within `radius` of a point, with its root and distance.

	Walks InfectedService's own alive list rather than the Workspace folder, so a
	body that has died but not yet been cleaned up is already gone from it — a
	turret that spends its fire rate shooting a corpse is a turret that does
	nothing during the one second that mattered.

	Allocates. Called on a cooldown or a fire rate, never per frame per body.
]]
function AbilitySupport.infectedWithin(position: Vector3, radius: number): { Target }
	local found: { Target } = {}
	local infected: any = Registry.find("InfectedService")
	if not infected or typeof(infected.getAlive) ~= "function" then
		return found
	end
	local ok, models = pcall(infected.getAlive, infected)
	if not ok or typeof(models) ~= "table" then
		return found
	end

	for _, model in models do
		if not model.Parent or not RigUtil.isAlive(model) then
			continue
		end
		local root = RigUtil.getRoot(model)
		if not root then
			continue
		end
		local distance = (root.Position - position).Magnitude
		if distance <= radius then
			table.insert(found, { model = model, root = root, distance = distance })
		end
	end
	return found
end

--[[ Whether this body is a boss, from the definition rather than from a list of
     kind names — a special promoted to boss in InfectedConfig is a boss here
     without anybody remembering to come and say so. ]]
function AbilitySupport.isBoss(model: Model): boolean
	local definition = InfectedConfig.get(model:GetAttribute(IA.Kind) :: any)
	return definition ~= nil and definition.isBoss
end

--[[ The brain driving a body, or nil. Guarded the way the specials guard theirs:
     an ability must degrade to doing nothing rather than erroring out halfway
     through a list of forty zombies. ]]
function AbilitySupport.brainOf(model: Model): any?
	local infected: any = Registry.find("InfectedService")
	if not infected or typeof(infected.getBrain) ~= "function" then
		return nil
	end
	local ok, brain = pcall(infected.getBrain, infected, model)
	return if ok then brain else nil
end

return AbilitySupport
