--!nonstrict
--[[
	PassController — the client's copy of which Robux passes this player owns.

	Deliberately the thinnest controller in the game. It holds three facts per
	pass and asks the server for a prompt; it decides nothing.

	── WHY "KNOWN" IS A SEPARATE FLAG ───────────────────────────────────────────
	The obvious mirror is `owned[id] = true/false`, which collapses two very
	different states into one. PassService's ownership check is a web call that
	can throw, and until it has succeeded the honest answer is not "no", it is
	"we have not managed to ask". Drawn as a price, "we have not asked" invites a
	player to buy a pass they already own; drawn as CHECKING…, it costs them a
	second and tells the truth.

	So `known` rides alongside `owns` all the way from PassService to the shop
	row, and the shop branches on it. See ShopController.passStatus.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PassConfig = require(Shared.Config.PassConfig)
local Registry = require(Shared.Util.Registry)
local Remotes = require(Shared.Net.Remotes)
local Signal = require(Shared.Util.Signal)
local Trove = require(Shared.Util.Trove)

local PassController = {}

local trove = Trove.new()

-- passes[id] = { owns: boolean, known: boolean }
local passes: { [string]: { owns: boolean, known: boolean } } = {}

--[[ Fired whenever the server's answer changes, so the shop can redraw without
     polling. The only reason this file has a signal at all. ]]
PassController.changed = Signal.new()

function PassController:owns(passId: string): boolean
	local entry = passes[passId]
	return entry ~= nil and entry.owns == true
end

--[[ Whether the answer above is real. False means the check has not succeeded
     yet — not that the player does not own it. ]]
function PassController:isKnown(passId: string): boolean
	local entry = passes[passId]
	return entry ~= nil and entry.known == true
end

--[[ Asks the server to put Roblox's purchase prompt on screen. Refused locally
     for a pass that is not in the catalogue or one already owned, so the common
     mistakes never reach the wire; everything else is the server's call. ]]
function PassController:promptPurchase(passId: string): boolean
	if not PassConfig.get(passId) or self:owns(passId) then
		return false
	end
	Remotes.Event.RequestPassPurchase:FireServer(passId)
	return true
end

function PassController:init()
	for _, pass in PassConfig.Passes do
		passes[pass.id] = { owns = false, known = false }
	end
end

function PassController:start()
	trove:connect(Remotes.Event.PassesSynced.OnClientEvent, function(payload: any)
		if typeof(payload) ~= "table" then
			return
		end
		for id, entry in payload do
			if typeof(id) == "string" and typeof(entry) == "table" then
				passes[id] = {
					owns = entry.owns == true,
					known = entry.known == true,
				}
			end
		end
		PassController.changed:fire()
	end)
end

function PassController:destroy()
	trove:destroy()
end

Registry.register("PassController", PassController)

return PassController
