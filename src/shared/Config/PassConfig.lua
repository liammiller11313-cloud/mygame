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

	── FOUR OF THE SEVEN, AND WHY ───────────────────────────────────────────────
	The pack is seven tools. Four of them are weapons in the sense WeaponConfig
	means: a thing held in a slot that damages what it points at. Those are
	listed below. The other three are not, and forcing them into a weapon block
	would be the wrong shape rather than a shortcut:

	  * the TIMEBOMB is a throwable. This game already has that pipeline —
	    ProjectileService, a map family, an inventory slot — and it is where a
	    planted bomb belongs, beside the pipe bomb it is a cousin of.
	  * the SUPERBALL is a thrown bouncing projectile with no barrel and no
	    magazine. Same pipeline as the timebomb, different fuse.
	  * the TROWEL builds geometry. It is not a weapon in any sense and it wants
	    the barricade system, not the ballistics one.

	Selling four and describing seven would be a lie, so `grants` says four. The
	other three arrive when their pipelines do.

	**Do not publish the game pass until the weapons below are in WeaponConfig.**
	Selling a hundred Robux for nothing is a refund and a report, not a bug.
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
	--[[ And the same thing in ids: the WeaponConfig entries owning this pass
	     unlocks. Kept separate from `grants` on purpose — one is prose for a
	     storefront and the other is the gate, and collapsing them would make
	     every wording change a balance change. A weapon here does not need a
	     shop row: LoadoutConfig.candidates already appends anything in
	     WeaponConfig the catalogue does not list. ]]
	grantsWeapons: { string },
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
			"Classic Sword",
			"Classic Paintball Gun",
			"Classic Slingshot",
			"Rocket Launcher",
		},
		grantsWeapons = {
			"ClassicSword",
			"ClassicPaintballGun",
			"ClassicSlingshot",
			"ClassicRocketLauncher",
		},
	},
} :: { Pass })

local byId: { [string]: Pass } = {}
local byGamePassId: { [number]: Pass } = {}
local byWeapon: { [string]: Pass } = {}
for _, pass in PassConfig.Passes do
	byId[pass.id] = pass
	byGamePassId[pass.gamePassId] = pass
	for _, weaponId in pass.grantsWeapons do
		byWeapon[weaponId] = pass
	end
end

function PassConfig.get(id: string): Pass?
	return byId[id]
end

--[[ The lookup the purchase-finished signal needs: Roblox hands back the game
     pass id it just sold, and nothing else. ]]
function PassConfig.byGamePassId(gamePassId: number): Pass?
	return byGamePassId[gamePassId]
end

--[[
	Which pass unlocks this weapon, or nil for one bought with Dollars.

	The question the LOADOUT screen has, and it had no way to ask it. A pack
	weapon has no catalogue row, so an unowned one drew as a bare "LOCKED" — no
	price, nothing saying it was for sale at all — and pressing it opened the
	shop on a weapons tab that does not stock it. Four weapons behind a hundred
	Robux, presented as four weapons behind nothing.

	Built from `grantsWeapons` rather than written out, so it is the same list
	the entitlement is granted from and cannot disagree with it.
]]
function PassConfig.forWeapon(weaponId: string): Pass?
	return byWeapon[weaponId]
end

--[[ Formatted the way Roblox writes a price, so the shop's Robux column cannot
     drift from the prompt the player is about to see. ]]
function PassConfig.format(robux: number): string
	return "R$ " .. tostring(robux)
end

return PassConfig
