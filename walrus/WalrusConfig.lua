--[[
	WalrusConfig
	------------
	WHERE THIS GOES:  ReplicatedStorage
	WHAT KIND:        ModuleScript   (not a Script, not a LocalScript)

	Every walrus in the game, in one place. The shop, the podiums and the
	bonk code all read from here, so a number can only be wrong once.

	A ModuleScript doesn't run on its own - other scripts `require` it and
	get this table back.
]]

local WalrusConfig = {}

-- Everyone owns this one from their very first join. It can't be sold and
-- it can't be lost.
WalrusConfig.Starter = "Basic"

-- The key on the left ("Basic") is the walrus's real name. It must match
-- the model name under ReplicatedStorage.Walruses exactly, and it's also
-- what goes in a podium's WalrusName attribute and what gets saved.
-- Rename a key later and everybody's save forgets that walrus, so pick
-- names you can live with.
WalrusConfig.Walruses = {

	Basic = {
		Cost = 0, -- in Icicles. 0 means free, which the starter must be.
		Power = 10, -- knockback strength when you bonk someone
		Ability = "Basic", -- the key AbilityServer looks up in ABILITIES
		AbilityLabel = "Lunge & Jab", -- the prettier name for signs
	},

	Flamespitter = {
		Cost = 50,
		Power = 15,
		Ability = "Molten",
		AbilityLabel = "Flamethrower",
	},
}

-- Look one up safely. Anything unknown - a podium with a typo, a save from
-- before you renamed a walrus - falls back to the starter rather than
-- erroring halfway through a purchase.
function WalrusConfig.get(name)
	return WalrusConfig.Walruses[name] or WalrusConfig.Walruses[WalrusConfig.Starter]
end

return WalrusConfig
