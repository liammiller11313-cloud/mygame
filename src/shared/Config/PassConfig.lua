--!strict
--[[
	PassConfig — what is for sale for Robux.

	── WHY THIS IS NOT IN EconomyConfig ─────────────────────────────────────────
	The obvious build adds a row to EconomyConfig.Catalogue with a category of
	"PASSES" and gets three things wrong at once:

	  * `priceOf` returns Dollars, and the shop compares that against a balance.
	    A pass priced 100 would read as a hundred Dollars — buyable by anyone who
	    played two rounds.
	  * `defaultOwned()` walks the catalogue and grants everything priced at or
	    below zero, because that is how the starting UMP-45 and M1911 are handed
	    out. A pass with no Dollars price would be **given away free on join**.
	  * `economy.py` models a round's pacing from that catalogue and fails the
	    build when the numbers drift. A Robux price in there is not a number it
	    can reason about.

	Two currencies, two catalogues. They meet in exactly one place — the shop
	draws a tab from each — and nowhere else.

	── OWNERSHIP LIVES NOWHERE ──────────────────────────────────────────────────
	Nothing in this file, and nothing anywhere else, writes pass ownership to a
	profile. `ProfileService.owned` is the Dollars economy's set and it lives in a
	DataStore, which means a bad save or a wiped key takes an item away. That is
	survivable for a gun somebody earned in an evening and unacceptable for one
	they paid real money for.

	Roblox already stores this, permanently and authoritatively. PassService asks
	it once per session and caches the answer in memory. See its header.

	── ⚠ NOTHING READS THIS YET, SO NOTHING IS GRANTED ──────────────────────────
	The shop can sell Brickbattler's Pack today and buying it changes nothing in
	the game. `PassService:owns` has no callers: the seven tools live in
	packs/BrickbattlersPack/ as standalone Roblox Tool scripts and are not wired
	into this game's weapon pipeline, because whether they become WeaponConfig
	entries going through BallisticsService or stay classic tools in their own
	lane is a design decision that has not been made.

	**Do not publish the game pass until it does something.** Selling a hundred
	Robux for nothing is a refund and a report, not a bug. The plumbing is here
	and correct; the payload is not.
]]

export type Pass = {
	id: string, -- our own key, stable across renames
	gamePassId: number, -- the id Roblox knows it by
	displayName: string,
	robux: number, -- what it costs, for display only; Roblox owns the real price
	image: string, -- 512x512, drawn where a weapon's 3D preview would be
	blurb: string,
	--[[ What buying it actually gives, in the player's words rather than ours.
	     Drawn as a list under the image, because a pass with no visible contents
	     is asking for a hundred Robux on trust. ]]
	grants: { string },
}

local PassConfig = {}

PassConfig.Passes = table.freeze({
	{
		id = "BrickbattlersPack",
		gamePassId = 1975538258,
		displayName = "BRICKBATTLER'S PACK",
		robux = 100,
		image = "rbxassetid://124168366933983",
		blurb = "Seven classics out of Brickbattle Ultimate, pogo and all.",
		grants = {
			"Classic Paintball Gun",
			"Classic Slingshot — with stacking pogo",
			"Classic Superball",
			"Classic Sword",
			"Classic Timebomb",
			"Classic Trowel",
			"Rocket Launcher — with rocket pogo",
		},
	},
} :: { Pass })

local byId: { [string]: Pass } = {}
local byGamePassId: { [number]: Pass } = {}
for _, pass in PassConfig.Passes do
	byId[pass.id] = pass
	byGamePassId[pass.gamePassId] = pass
end

function PassConfig.get(id: string): Pass?
	return byId[id]
end

--[[ The lookup the purchase-finished signal needs: Roblox hands back the game
     pass id it just sold, and nothing else. ]]
function PassConfig.byGamePassId(gamePassId: number): Pass?
	return byGamePassId[gamePassId]
end

--[[ Formatted the way Roblox writes a price, so the shop's Robux column cannot
     drift from the prompt the player is about to see. ]]
function PassConfig.format(robux: number): string
	return "R$ " .. tostring(robux)
end

return PassConfig
