--!strict
--[[
	AmmoConfig — casings, magazines and ammo pickups.

	Three separate things a player sees, and they are worth distinguishing because
	they cost very different amounts of attention:

	  CASINGS    ejected on every single shot. At 1100rpm that is eighteen a
	             second, from one gun, and they are on screen for under a second
	             each. They must be cheap and they must be the right SHAPE — a
	             rifle case and a shotgun hull read differently at a glance and
	             that difference is most of what sells the weapon's calibre.
	  MAGAZINES  seen once per reload, up close, for about a second while it
	             falls out of frame. This is the one the player actually looks at,
	             so it is worth a real model.
	  PICKUPS    sat on the floor waiting to be walked over. Seen from further
	             away and from any angle.

	Everything falls back to a procedural stand-in, so a half-filled Ammo folder
	still plays. Nothing here is required for the game to run.

	── WHERE THE MODELS GO ──────────────────────────────────────────────────────
	    ReplicatedStorage/Assets/Ammo/
	        Casings/     one per CALIBRE, not per gun
	        Magazines/   one per magazine FAMILY, not per gun
	        Pickups/     ammo piles and boxes

	Names must match the `model` fields below exactly.
]]

local Enums = require(script.Parent.Parent.Enums)

local AmmoConfig = {}

AmmoConfig.FolderName = "Ammo"
AmmoConfig.CasingFolder = "Casings"
AmmoConfig.MagazineFolder = "Magazines"
AmmoConfig.PickupFolder = "Pickups"

export type CasingDefinition = {
	model: string, -- name in Assets/Ammo/Casings
	size: Vector3, -- fallback block dimensions, in studs
	color: Color3, -- fallback colour
	material: Enum.Material,
	ejectSpeed: number, -- studs/sec out of the port
	ejectUp: number, -- upward component
	spin: number, -- radians/sec of tumble
	lifetime: number,
	bounce: boolean, -- shotgun hulls skitter; rifle brass mostly does not
}

export type MagazineDefinition = {
	model: string, -- name in Assets/Ammo/Magazines
	size: Vector3,
	color: Color3,
	material: Enum.Material,
	dropSpeed: number,
	lifetime: number,
	-- Shell-by-shell weapons drop no magazine; they show a single round instead.
	perShellRound: boolean,
}

--[[
	Casings, by calibre. Sizes are real-ish in Roblox scale: a stud is roughly
	28cm, so a 9mm case at 0.06 studs is about 17mm — small, but large enough to
	catch a specular highlight, which is the entire reason you can see brass fly
	in a dark room.
]]
AmmoConfig.Casings = {
	["9mm"] = {
		model = "Casing_9mm",
		size = Vector3.new(0.055, 0.055, 0.13),
		color = Color3.fromRGB(198, 158, 74),
		material = Enum.Material.Metal,
		ejectSpeed = 12,
		ejectUp = 5,
		spin = 22,
		lifetime = 3.5,
		bounce = false,
	},
	["45acp"] = {
		model = "Casing_45ACP",
		size = Vector3.new(0.07, 0.07, 0.13),
		color = Color3.fromRGB(206, 164, 78),
		material = Enum.Material.Metal,
		ejectSpeed = 11,
		ejectUp = 5,
		spin = 20,
		lifetime = 3.5,
		bounce = false,
	},
	["357"] = {
		model = "Casing_357",
		size = Vector3.new(0.065, 0.065, 0.18),
		color = Color3.fromRGB(212, 172, 84),
		material = Enum.Material.Metal,
		ejectSpeed = 9,
		ejectUp = 7,
		spin = 16,
		lifetime = 4.0,
		bounce = false,
	},
	["556"] = {
		model = "Casing_556",
		size = Vector3.new(0.06, 0.06, 0.2),
		color = Color3.fromRGB(196, 152, 70),
		material = Enum.Material.Metal,
		ejectSpeed = 15,
		ejectUp = 6,
		spin = 26,
		lifetime = 3.5,
		bounce = false,
	},
	["762"] = {
		model = "Casing_762",
		size = Vector3.new(0.075, 0.075, 0.24),
		color = Color3.fromRGB(188, 144, 66),
		material = Enum.Material.Metal,
		ejectSpeed = 16,
		ejectUp = 6,
		spin = 24,
		lifetime = 4.0,
		bounce = false,
	},
	["12ga"] = {
		-- The one casing anybody actually notices: a red plastic hull with a brass
		-- base, tumbling out of a pump at head height.
		model = "Casing_12ga",
		size = Vector3.new(0.11, 0.11, 0.3),
		color = Color3.fromRGB(148, 34, 30),
		material = Enum.Material.Plastic,
		ejectSpeed = 10,
		ejectUp = 8,
		spin = 12,
		lifetime = 5.0,
		bounce = true,
	},
	["flare"] = {
		--[[ 26.5mm, so fatter and shorter than a 12ga hull, and the model name
		     is the SPENT one on purpose: this folder is what comes OUT of a gun.
		     The live shell is a separate model in Magazines — see FlareShell
		     below, and docs/AMMO_MODELS.md, which spells the pair out because
		     "Flare Shell" and "Flare Shell (spent)" are one character apart and
		     they go in different folders. ]]
		model = "Flare Shell (spent)",
		size = Vector3.new(0.15, 0.15, 0.26),
		--[[ Scorched, not red. A fired flare case is blackened at the mouth, and
		     an unfired-looking case on the floor next to a burning body is the
		     kind of small lie a player notices without being able to say why. ]]
		color = Color3.fromRGB(96, 74, 62),
		material = Enum.Material.Plastic,
		--[[ Break-action: the case is not thrown by a slide, it is tipped out by
		     hand. So it barely leaves the gun and it does not skitter. ]]
		ejectSpeed = 3,
		ejectUp = 4,
		spin = 5,
		lifetime = 6.0,
		bounce = false,
	},
} :: { [string]: CasingDefinition }

--[[ Magazines, by family. A dropped magazine is the clearest possible signal
     that a reload is happening and roughly how far through it you are. ]]
AmmoConfig.Magazines = {
	PistolMag = {
		model = "Mag_Pistol",
		size = Vector3.new(0.16, 0.5, 0.09),
		color = Color3.fromRGB(46, 46, 50),
		material = Enum.Material.Metal,
		dropSpeed = 2.5,
		lifetime = 4,
		perShellRound = false,
	},
	RevolverSpeedloader = {
		model = "Speedloader_357",
		size = Vector3.new(0.26, 0.26, 0.18),
		color = Color3.fromRGB(58, 56, 58),
		material = Enum.Material.Metal,
		dropSpeed = 2.0,
		lifetime = 4,
		perShellRound = false,
	},
	SmgMag = {
		model = "Mag_SMG",
		size = Vector3.new(0.15, 0.62, 0.1),
		color = Color3.fromRGB(42, 42, 46),
		material = Enum.Material.Metal,
		dropSpeed = 2.6,
		lifetime = 4,
		perShellRound = false,
	},
	DrumMag = {
		-- The PPSh's 71-round drum. Big, round, and unmistakable in the hand.
		model = "Mag_Drum",
		size = Vector3.new(0.52, 0.52, 0.16),
		color = Color3.fromRGB(60, 52, 44),
		material = Enum.Material.Metal,
		dropSpeed = 2.2,
		lifetime = 5,
		perShellRound = false,
	},
	StanagMag = {
		model = "Mag_STANAG",
		size = Vector3.new(0.16, 0.76, 0.11),
		color = Color3.fromRGB(38, 40, 38),
		material = Enum.Material.Plastic,
		dropSpeed = 2.8,
		lifetime = 4,
		perShellRound = false,
	},
	AkMag = {
		-- Curved and usually orange-brown bakelite; visually distinct from a
		-- STANAG at a glance, which is the whole point of giving it its own entry.
		model = "Mag_AK",
		size = Vector3.new(0.17, 0.82, 0.13),
		color = Color3.fromRGB(122, 74, 38),
		material = Enum.Material.Plastic,
		dropSpeed = 2.8,
		lifetime = 4,
		perShellRound = false,
	},
	MarksmanMag = {
		model = "Mag_Marksman",
		size = Vector3.new(0.17, 0.66, 0.13),
		color = Color3.fromRGB(40, 42, 40),
		material = Enum.Material.Metal,
		dropSpeed = 2.6,
		lifetime = 4,
		perShellRound = false,
	},
	ShotgunShell = {
		-- Not a magazine. The shotgun loads one hull at a time, so this is the
		-- round the hand carries to the loading port on each shell of a reload.
		model = "Round_12ga",
		size = Vector3.new(0.11, 0.11, 0.3),
		color = Color3.fromRGB(148, 34, 30),
		material = Enum.Material.Plastic,
		dropSpeed = 0,
		lifetime = 2,
		perShellRound = true,
	},
	FlareShell = {
		--[[ The LIVE shell, and the other half of the pair. perShellRound is
		     what puts it in the hand on the way to the breech rather than
		     dropping it on the floor: a break-action gun loads one round, and
		     the reload IS watching that round go in.

		     Its spent twin lives in Casings under "Flare Shell (spent)". One
		     letter of difference and two different folders, which is exactly why
		     both are named in docs/AMMO_MODELS.md. ]]
		model = "Flare Shell",
		size = Vector3.new(0.15, 0.15, 0.3),
		-- Unfired: the orange every flare in this game is, so the round in the
		-- hand and the light it becomes are obviously the same object.
		color = Color3.fromRGB(226, 108, 42),
		material = Enum.Material.Plastic,
		dropSpeed = 0,
		lifetime = 2,
		perShellRound = true,
	},
} :: { [string]: MagazineDefinition }

--[[ Which calibre and magazine each weapon uses. Grouped by what the gun really
     fires, so sixteen weapons need six casings and eight magazines rather than
     sixteen of each. ]]
AmmoConfig.Weapons = {
	[Enums.Weapon.M1911A1] = { casing = "45acp", magazine = "PistolMag" },
	[Enums.Weapon.Magnum357] = { casing = "357", magazine = "RevolverSpeedloader" },
	[Enums.Weapon.FlareGun] = { casing = "flare", magazine = "FlareShell" },
	--[[ These three shipped without a row here, so they ejected nothing and
	     reloaded nothing visible — the one piece of feedback that says a pistol
	     is a pistol, missing on three of the five. ]]
	[Enums.Weapon.DualBerettas] = { casing = "9mm", magazine = "PistolMag" },
	[Enums.Weapon.Glock18] = { casing = "9mm", magazine = "PistolMag" },
	[Enums.Weapon.SawnOff] = { casing = "12ga", magazine = "ShotgunShell" },
	--[[ Nothing on either side. An RPG ejects no case and takes no magazine — it
	     takes a rocket, which is a model nobody has built. Named explicitly rather
	     than left absent so the next person to read this table can tell the
	     difference between "has none" and "was forgotten", which is exactly the
	     distinction the three rows above got wrong. ]]
	[Enums.Weapon.RPG7] = { casing = "", magazine = "" },
	[Enums.Weapon.M9] = { casing = "9mm", magazine = "PistolMag" },
	[Enums.Weapon.Shotgun] = { casing = "12ga", magazine = "ShotgunShell" },
	[Enums.Weapon.TacticalShotty] = { casing = "12ga", magazine = "ShotgunShell" },
	[Enums.Weapon.M1014] = { casing = "12ga", magazine = "ShotgunShell" },
	--[[ The only shotgun that drops a drum rather than feeding shells. ]]
	[Enums.Weapon.DAO12] = { casing = "12ga", magazine = "DrumMag" },

	[Enums.Weapon.PPSh41] = { casing = "762", magazine = "DrumMag" },
	[Enums.Weapon.KrissVector] = { casing = "45acp", magazine = "SmgMag" },
	[Enums.Weapon.MP7A1] = { casing = "9mm", magazine = "SmgMag" },
	[Enums.Weapon.UMP45] = { casing = "45acp", magazine = "SmgMag" },
	[Enums.Weapon.AKS74U] = { casing = "556", magazine = "AkMag" },

	[Enums.Weapon.M4A1] = { casing = "556", magazine = "StanagMag" },
	[Enums.Weapon.HK416A5] = { casing = "556", magazine = "StanagMag" },
	[Enums.Weapon.Mk18CQBR] = { casing = "556", magazine = "StanagMag" },
	[Enums.Weapon.AK12] = { casing = "556", magazine = "AkMag" },
	[Enums.Weapon.AKM] = { casing = "762", magazine = "AkMag" },
	[Enums.Weapon.M16A4] = { casing = "556", magazine = "StanagMag" },
	[Enums.Weapon.HK416D] = { casing = "556", magazine = "StanagMag" },
	[Enums.Weapon.HK417] = { casing = "762", magazine = "MarksmanMag" },

	--[[ Belt-fed, and there is no belt model. The drum is the closest thing in
	     the folder to a hundred rounds coming out of a box, and a wrong magazine
	     that exists reads better than a right one that grey-boxes. ]]
	[Enums.Weapon.M249] = { casing = "556", magazine = "DrumMag" },
	[Enums.Weapon.M60E4] = { casing = "762", magazine = "DrumMag" },
	--[[ Genuinely nothing. It burns fuel: there is no case to eject and no
	     magazine to drop, and the empty row is how "has none" stays
	     distinguishable from "was forgotten". ]]
	[Enums.Weapon.Flamethrower] = { casing = "", magazine = "" },
	--[[ Nothing, again, and for the same reason: it fires a charge, so there is
	     no case and no magazine. Said explicitly rather than left absent, so
	     "has none" stays distinguishable from "was forgotten" — which is the
	     whole point of this table having empty rows in it at all. ]]
	[Enums.Weapon.TeslaRifle] = { casing = "", magazine = "" },

	[Enums.Weapon.ScopedMk18] = { casing = "556", magazine = "StanagMag" },
	[Enums.Weapon.M1AEBR] = { casing = "762", magazine = "MarksmanMag" },
	[Enums.Weapon.MK11] = { casing = "762", magazine = "MarksmanMag" },
	[Enums.Weapon.M24] = { casing = "762", magazine = "MarksmanMag" },

	--[[ Melee. Nothing on either side, said explicitly for all five rather than
	     left absent for four of them — `forWeapon` returns nil either way, so the
	     only difference these rows make is to the next person reading the table,
	     who can now tell "has none" from "was forgotten". audit.py check 16
	     enforces exactly that. ]]
	[Enums.Weapon.Machete] = { casing = "", magazine = "" },

	--[[ Brickbattler's Pack. None of them ejects anything: a sword and a
	     slingshot have no casing to throw, the paintball gun's ammunition is the
	     projectile, and the rocket leaves the tube whole. Written out rather
	     than left absent, so "has none" stays distinguishable from "forgotten" —
	     which is the entire reason this table refuses to have holes. ]]
	[Enums.Weapon.ClassicSword] = { casing = "", magazine = "" },
	[Enums.Weapon.ClassicPaintballGun] = { casing = "", magazine = "" },
	[Enums.Weapon.ClassicSlingshot] = { casing = "", magazine = "" },
	[Enums.Weapon.ClassicRocketLauncher] = { casing = "", magazine = "" },
	[Enums.Weapon.FireAxe] = { casing = "", magazine = "" },
	[Enums.Weapon.BaseballBat] = { casing = "", magazine = "" },
	[Enums.Weapon.LeadPipe] = { casing = "", magazine = "" },
	[Enums.Weapon.Knife] = { casing = "", magazine = "" },
} :: { [string]: { casing: string, magazine: string } }

--[[ Ammo pickups on the floor. `AmmoPile` is the shared refill every survivor
     can draw from; the boxes are single-use drops the Director places. ]]
AmmoConfig.Pickups = table.freeze({
	Pile = "AmmoPile",
	Box = "AmmoBox",
	ShellBox = "ShellBox",
})

function AmmoConfig.forWeapon(weaponId: string?)
	if not weaponId then
		return nil
	end
	return AmmoConfig.Weapons[weaponId]
end

function AmmoConfig.casingFor(weaponId: string?): CasingDefinition?
	local entry = AmmoConfig.forWeapon(weaponId)
	if not entry or entry.casing == "" then
		return nil
	end
	return AmmoConfig.Casings[entry.casing]
end

function AmmoConfig.magazineFor(weaponId: string?): MagazineDefinition?
	local entry = AmmoConfig.forWeapon(weaponId)
	if not entry or entry.magazine == "" then
		return nil
	end
	return AmmoConfig.Magazines[entry.magazine]
end

return AmmoConfig
