--!strict
--[[
	EconomyConfig — Dollars: where they come from, and what they buy.

	Earning and pricing live in ONE file on purpose. They are not two systems,
	they are two ends of one number: change a payout without changing prices and
	the whole progression moves. Anything that would have to be re-tuned together
	is written down together, and the pacing claim below is checked by a script
	rather than asserted.

	── THE TARGET ───────────────────────────────────────────────────────────────
	A decent player should own the whole roster after roughly 30-40 rounds. That
	is the number every other number here is derived from:

	  a round pays  ~$1,000 in kills + $1,100 for a win + $60 a wave survived
	                ≈ $2,500 for a won round, ~$1,000 for a deep loss
	  the roster    ≈ $98,900 of purchasable weapons
	  therefore     ≈ 39 winning rounds, and a loss still moves you forward

	  ── HEADROOM: NONE. 39 of a 40 ceiling. ──
	  Three secondaries went in at $8,500 and took this from 35 rounds to 39. The
	  NEXT priced thing added to the catalogue fails scripts/economy.py, and the
	  fix at that point is the income side — as it was when the melee roster went
	  in — but it cannot be the win bonus alone: raising VictoryBonus to 1250 buys
	  36 rounds and drags the kill share to 37%, against the 45% the section below
	  calls the number to protect. Raise kill rewards, or raise both.

	`scripts/economy.py` recomputes that from this table and fails if it has
	drifted out of the 30-40 band. The paragraph above is only true because
	something checks it — the first draft of these numbers said 39 and the model
	said 18, which is the whole reason that script exists.

	── WHY A LOSS STILL PAYS ────────────────────────────────────────────────────
	A wipe on wave 6 is forty minutes of good play that happened to end badly, and
	a game that pays nothing for it teaches players to quit the moment a round
	looks lost. The per-wave bonus is what makes a deep loss worth more than a
	shallow one, which is the actual thing being rewarded.

	── WHY FINISHING PAYS MORE THAN KILLING ─────────────────────────────────────
	Roughly 60% of a won round is the completion bonus and 40% is the four hundred
	things you shot. That split is deliberate and it is the number to protect if
	these are ever retuned. (It reads 55/45 in older copies of this comment; the
	number moved when VictoryBonus went to 1100 and the prose did not follow.
	scripts/economy.py prints the live figure — trust that over this paragraph.)

	Money that comes mostly from kills means the incentive is to leave your team
	and go farming, which is the exact behaviour that loses rounds in a co-op
	game. Money that comes ONLY from finishing means a player who is carrying the
	team is paid the same as one hiding in a closet. Just past half and half is
	where "help your team survive" and "actually fight" are both worth doing.

	Two to eight Dollars a kill is what keeps the shooting half honest without
	letting it dominate: three hundred Commons at $2 is real money, and no amount
	of farming beats finishing.

	── NOTHING HERE IS AUTHORITATIVE ON ITS OWN ─────────────────────────────────
	The server reads this table; the client reads it too, to draw prices. A client
	that lies about a price is refused by the server, which prices the purchase
	from its own copy — see EconomyService. The client's copy is for DRAWING.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Enums = require(Shared.Enums)

local EconomyConfig = {}

-- ── the currency ────────────────────────────────────────────────────────────

EconomyConfig.Symbol = "$"

--[[ What a brand-new player starts with.

     Enough to buy the cheapest thing in the shop on the first visit, and not a
     Dollar more. A shop where everything is locked on your first look teaches
     you that the shop is not for you; one purchase teaches you what it is. ]]
EconomyConfig.StartingDollars = 2000

--[[ The ceiling. Not a balance number — a storage one. DataStore values are
     JSON and a number that has been corrupted or tampered into something
     enormous should be clamped on the way in rather than written back out. ]]
EconomyConfig.MaxDollars = 9_999_999

-- ── earning ─────────────────────────────────────────────────────────────────

--[[
	What a kill is worth, by what died.

	The whole range is 2-8. A Common is the floor because there are three hundred
	of them in a round and they are the thing you shoot without thinking; a Tank
	is the ceiling because killing one is the hardest thing the game asks. The
	specials sit between, and the Witch is paid as a boss because startling one
	is a decision and killing one is a fight.
]]
EconomyConfig.KillReward = table.freeze({
	[Enums.Infected.Common] = 2,
	[Enums.Infected.Hunter] = 5,
	[Enums.Infected.Jockey] = 5,
	[Enums.Infected.Charger] = 5,
	--[[ The three that threaten a PLACE rather than a body pay the same as the
	     three that pin one. A Boomer deals almost no damage and decides more
	     fights than anything short of a Tank; paying for damage dealt would rank
	     it below a Common, which is the opposite of what it is worth. ]]
	[Enums.Infected.Tongue] = 5,
	[Enums.Infected.Boomer] = 5,
	[Enums.Infected.Spitter] = 5,
	[Enums.Infected.Witch] = 8,
	[Enums.Infected.Tank] = 8,
})

--[[ Anything that dies without a row above. A kind added to InfectedConfig and
     forgotten here pays the Common rate rather than nothing, so a new special is
     never silently worthless. ]]
EconomyConfig.DefaultKillReward = 2

--[[ Added for a head hit, on top of the row above. One Dollar: it has to be
     worth aiming for and it must not turn the payout into a marksmanship score,
     because the top of the range is reserved for what you KILLED rather than
     how. A Common headshot pays 3. ]]
EconomyConfig.HeadshotBonus = 1

--[[
	The top of the band, enforced rather than described.

	Every kill pays between 2 and 8 and that is a rule, not an observation — so
	the headshot bonus is clamped into it instead of being allowed to push a boss
	to 9. It costs a Tank headshot nothing real: a Tank has no head-kill rule and
	thousands of health, so nobody is aiming there for the money.

	The first version of this table said "the whole range is 2-8" in a comment and
	then paid 9 for a Tank headshot. scripts/economy.py caught it. This is the fix
	that keeps the comment true on its own.
]]
EconomyConfig.MaxKillReward = 8
EconomyConfig.MinKillReward = 2

--[[
	The round bonuses, which are most of the money.

	Survived is per wave REACHED, so a team wiped on wave 6 is paid for six. It
	applies to a victory too — holding out to the end is the same achievement
	measured the same way, and stacking it under the win bonus is what makes a
	full round clearly the best use of an hour.
]]
--[[ Raised from 800 when the melee roster went in. Five new things to want
     added $8,800 to the catalogue and pushed the unlock curve from 37 rounds to
     40 — the ceiling of the target band. The fix is on the income side rather
     than the price side on purpose: melee is content a player should be able to
     reach early, and paying more for a FINISHED round is the lever that costs
     nothing anywhere else. scripts/economy.py is what decides whether this
     number is right; it fails the build outside 30-40 rounds. ]]
EconomyConfig.VictoryBonus = 1100
EconomyConfig.DefeatBonus = 200
EconomyConfig.WaveBonus = 60

--[[ A hard ceiling on what one round can pay, whatever happens inside it.

     Not distrust of the arithmetic above — distrust of a bug in something that
     feeds it. A Director fault that spawned ten thousand Commons would, without
     this, hand every player the entire roster in one round and there would be no
     way to take it back. ]]
EconomyConfig.MaxPerRound = 8_000

-- ── what is for sale ────────────────────────────────────────────────────────

--[[ The shop's three tabs, in the order they are drawn. Strings rather than an
     enum because they are also the tab labels. ]]
EconomyConfig.Categories = table.freeze({ "GUNS", "MELEE", "SPECIALS" })

--[[
	Every purchasable thing, and every thing that will be.

	  id          a WeaponConfig id for anything real; any unique string for a
	              placeholder, which nothing will ever try to equip
	  category    which tab it appears under
	  price       Dollars. Ignored for a placeholder
	  soon        true for something with no model and no stats yet: it is drawn,
	              greyed, and cannot be bought. See the header of ShopController
	              for why they are shown at all rather than hidden

	── THE PRICE TIERS ──────────────────────────────────────────────────────────
	Price tracks how much a weapon CHANGES a round rather than how good its
	numbers are. The Magnum is a sidearm and expensive because a sidearm that
	one-shots a Common is a different game; the AKM is cheap for its damage
	because its recoil makes that damage conditional.

	  ~2000-3500   first purchases. Sidegrades to what you already have.
	  ~4500-6000   the working middle of the roster.
	  ~6500-8000   clear upgrades with a real cost to learn.
	  ~9000-10500  the two marksman rifles, which reward a different game.
]]
export type ShopEntry = {
	id: string,
	category: string,
	price: number,
	soon: boolean?,
	--[[ Placeholder-only. A real entry takes its name and its stats from
	     WeaponConfig, because two copies of a weapon's name is one copy too
	     many. ]]
	displayName: string?,
	blurb: string?,
}

EconomyConfig.Catalogue = table.freeze({
	-- ── guns ────────────────────────────────────────────────────────────────
	-- Sidearms. The pistol is free; the Magnum is one of the most expensive
	-- things here, because a sidearm you can fall back on that kills in one hit
	-- removes the pressure the primary is supposed to create.
	{ id = Enums.Weapon.M1911A1, category = "GUNS", price = 0 },
	--[[ Priced under the Magnum on purpose, and the ladder is the point: the
	     Berettas are the first thing a new player can afford, the Glock is a
	     sidegrade rather than an upgrade, and the Sawn-Off is the only secondary
	     that changes how you fight rather than how long you last. ]]
	{ id = Enums.Weapon.DualBerettas, category = "GUNS", price = 1500 },
	{ id = Enums.Weapon.Glock18, category = "GUNS", price = 2800 },
	{ id = Enums.Weapon.SawnOff, category = "GUNS", price = 4200 },
	{ id = Enums.Weapon.Magnum357, category = "GUNS", price = 6000 },

	-- Shotgun. Cheap because it is the most conditional weapon in the game.
	{ id = Enums.Weapon.Shotgun, category = "GUNS", price = 3000 },

	-- SMGs. The UMP is the free primary, so everything near it is priced as a
	-- sidegrade rather than as an upgrade.
	{ id = Enums.Weapon.UMP45, category = "GUNS", price = 0 },
	{ id = Enums.Weapon.PPSh41, category = "GUNS", price = 3500 },
	{ id = Enums.Weapon.MP7A1, category = "GUNS", price = 4500 },
	{ id = Enums.Weapon.AKS74U, category = "GUNS", price = 4800 },
	{ id = Enums.Weapon.KrissVector, category = "GUNS", price = 6500 },

	-- Rifles. The middle and top of the roster.
	{ id = Enums.Weapon.M4A1, category = "GUNS", price = 5500 },
	{ id = Enums.Weapon.AKM, category = "GUNS", price = 5800 },
	{ id = Enums.Weapon.HK416A5, category = "GUNS", price = 7000 },
	{ id = Enums.Weapon.Mk18CQBR, category = "GUNS", price = 7500 },
	{ id = Enums.Weapon.AK12, category = "GUNS", price = 8000 },

	-- Marksman. Priced above the rifles because they reward a different game
	-- rather than a better one.
	{ id = Enums.Weapon.ScopedMk18, category = "GUNS", price = 9000 },
	{ id = Enums.Weapon.M1AEBR, category = "GUNS", price = 10500 },

	-- ── melee ───────────────────────────────────────────────────────────────
	--[[ All five are real now: model, WeaponConfig row, and a slot of their own.
	     The knife is free for the same reason the UMP-45 and the M1911 are — a
	     melee slot that starts empty teaches a new player that the melee key does
	     nothing, and they would be right until they could afford one.

	     Priced by what they do rather than by damage. The knife is fast and
	     reaches nothing; the bat clears crowds and kills nothing quickly; the
	     pipe and the machete are the middle; the axe is the one you buy last. ]]
	{ id = Enums.Weapon.Knife, category = "MELEE", price = 0 },
	{ id = Enums.Weapon.BaseballBat, category = "MELEE", price = 1400 },
	{ id = Enums.Weapon.LeadPipe, category = "MELEE", price = 1800 },
	{ id = Enums.Weapon.Machete, category = "MELEE", price = 2400 },
	{ id = Enums.Weapon.FireAxe, category = "MELEE", price = 3200 },

	-- ── specials ────────────────────────────────────────────────────────────
	-- None of these exist yet: no model, no WeaponConfig row, no behaviour.
	-- They are here so the category reads as a plan rather than as an empty tab.
	{
		id = "RPG",
		category = "SPECIALS",
		price = 0,
		soon = true,
		displayName = "RPG-7",
		blurb = "One rocket. Bring it out for the Tank.",
	},
	{
		id = "Flamethrower",
		category = "SPECIALS",
		price = 0,
		soon = true,
		displayName = "FLAMETHROWER",
		blurb = "Holds a corridor. Holds it for a while.",
	},
	{
		id = "MolotovPack",
		category = "SPECIALS",
		price = 0,
		soon = true,
		displayName = "MOLOTOV PACK",
		blurb = "Spawn with a bottle instead of finding one.",
	},
} :: { ShopEntry })

-- ── lookups ─────────────────────────────────────────────────────────────────

local byId: { [string]: ShopEntry } = {}
for _, entry in EconomyConfig.Catalogue do
	byId[entry.id] = entry
end

--[[ The catalogue row for an id, or nil. Nil means "not a thing this game
     sells", which is the answer a purchase request for a made-up id gets. ]]
function EconomyConfig.get(id: string): ShopEntry?
	if typeof(id) ~= "string" then
		return nil
	end
	return byId[id]
end

--[[ Every entry in one category, in catalogue order. Order is the order they
     are written above, which is grouped by class and then by price — that is
     the reading order a shop wants and it is not worth sorting at runtime. ]]
function EconomyConfig.inCategory(category: string): { ShopEntry }
	local out = {}
	for _, entry in EconomyConfig.Catalogue do
		if entry.category == category then
			table.insert(out, entry)
		end
	end
	return out
end

--[[ What something costs, or nil if it is not for sale at all. A placeholder
     returns nil rather than 0: zero is the price of the free starting weapons
     and must not also mean "cannot be bought". ]]
function EconomyConfig.priceOf(id: string): number?
	local entry = byId[id]
	if not entry or entry.soon then
		return nil
	end
	return entry.price
end

--[[ Everything a player owns before they have bought anything.

     The free loadout, and it is a real loadout rather than a token: a UMP-45 and
     an M1911 is what every survivor has started with since the game was written,
     so nothing about the first round changes when the shop arrives. ]]
function EconomyConfig.defaultOwned(): { [string]: boolean }
	local owned = {}
	for _, entry in EconomyConfig.Catalogue do
		if not entry.soon and entry.price <= 0 then
			owned[entry.id] = true
		end
	end
	return owned
end

--[[ What one kill pays, before it is added to a round total. Kept here rather
     than in the service so the earning rules and the numbers they use cannot end
     up in two files with two opinions. ]]
function EconomyConfig.rewardForKill(kind: string, isHeadshot: boolean): number
	local base = EconomyConfig.KillReward[kind] or EconomyConfig.DefaultKillReward
	local total = base + (if isHeadshot then EconomyConfig.HeadshotBonus else 0)
	return math.clamp(total, EconomyConfig.MinKillReward, EconomyConfig.MaxKillReward)
end

--[[ Dollars as they are written on screen: "$1,250". Roblox has no locale
     formatting and a five-figure balance without separators is unreadable. ]]
function EconomyConfig.format(amount: number): string
	local whole = math.max(math.floor(amount), 0)
	local text = tostring(whole)
	local grouped = text
	while true do
		local replaced, count = string.gsub(grouped, "^(%-?%d+)(%d%d%d)", "%1,%2")
		grouped = replaced
		if count == 0 then
			break
		end
	end
	return EconomyConfig.Symbol .. grouped
end

return table.freeze(EconomyConfig)
