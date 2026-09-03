--!strict
--[[
	SettingsConfig — every option a player can change, in one table.

	The definitions live here rather than in the panel that draws them so that
	three things can share one source of truth: the panel, whatever applies each
	value, and the server for the one setting it has to enforce. A setting added
	here appears in the interface with no UI change.

	── WHAT BELONGS IN HERE ────────────────────────────────────────────────────
	Choices the PLAYER owns. Not tuning — a number the designer picks lives in
	the config for the thing it tunes, and moving it here would mean every player
	balancing the game for themselves. The line is whether two people could
	reasonably want different answers: mouse sensitivity yes, shotgun damage no.

	── PERSONAL DIFFICULTY ─────────────────────────────────────────────────────
	The one setting with a server side. It scales what the infected do to ONE
	player and nothing else — not their damage output, not their teammates, not
	the Director's pacing — so a player who finds the game too punishing can stay
	in a round with friends who do not. It cannot make anybody stronger: every
	multiplier is at most 1, so the setting can only ever cost that player
	difficulty rather than buy them an advantage over the team.
]]

local SettingsConfig = {}

export type Definition = {
	key: string,
	label: string,
	category: string,
	--[[ "toggle" | "choice" | "slider" | "keybind". The panel draws each kind;
	     nothing else needs to know which is which. ]]
	kind: string,
	default: any,
	options: { string }?, -- choice only
	min: number?, -- slider only
	max: number?,
	blurb: string?, -- one line under the label, where the name is not enough
	--[[ keybind only: the InputController action this row rebinds. Named rather
	     than derived from `key` so a row can be relabelled without breaking the
	     binding it drives. ]]
	action: string?,
}

SettingsConfig.Categories = table.freeze({ "GRAPHICS", "AUDIO", "CONTROLS", "GAMEPLAY" })

--[[
	Personal difficulty, as multipliers on what reaches ONE player.

	Every value is <= 1 on purpose. See the header: this can cost a player
	difficulty and can never buy them an advantage, which is what keeps it a
	comfort setting rather than a cheat menu.
]]
SettingsConfig.Difficulty = table.freeze({
	NORMAL = { incomingDamage = 1.0, blurb = "The game as designed." },
	FORGIVING = { incomingDamage = 0.7, blurb = "Infected hit you 30% softer." },
	RELAXED = { incomingDamage = 0.45, blurb = "Infected hit you less than half as hard." },
})

SettingsConfig.DifficultyOrder = table.freeze({ "NORMAL", "FORGIVING", "RELAXED" })

--[[
	Graphics quality, as a multiplier on the gore budget this client draws.

	Sits alongside the DEVICE scale in GoreConfig rather than replacing it: the
	device decides what the hardware can push, this decides what the player
	wants, and the smaller of the two wins. Somebody on a desktop who prefers a
	clean screen gets LOW; somebody on a phone gets the device floor whatever
	they pick.
]]
SettingsConfig.Quality = table.freeze({
	HIGH = 1.0,
	MEDIUM = 0.65,
	LOW = 0.35,
})

SettingsConfig.Definitions = table.freeze({
	-- ── graphics ────────────────────────────────────────────────────────────
	{
		key = "quality",
		label = "EFFECT QUALITY",
		category = "GRAPHICS",
		kind = "choice",
		options = { "HIGH", "MEDIUM", "LOW" },
		default = "HIGH",
		blurb = "How much blood, debris and particle the game draws.",
	},
	{
		key = "gore",
		label = "GORE",
		category = "GRAPHICS",
		kind = "choice",
		options = { "FULL", "LOW", "OFF" },
		default = "FULL",
		blurb = "Dismemberment and gibbing.",
	},
	--[[ The one setting most likely to be the difference between playing this
	     game and giving up on it. AtmosphereService ends the round in the dark,
	     and that ramp is tuned against one screen in one room — a phone in
	     daylight is a different game. Above 1.0 as well as below, because the
	     problem is nearly always not enough light rather than too much. ]]
	{
		key = "brightness",
		label = "BRIGHTNESS",
		category = "GRAPHICS",
		kind = "slider",
		default = 1.0,
		min = 0.8,
		max = 1.6,
		blurb = "Lifts the picture without opening the fog. 100% is as designed.",
	},
	{
		key = "screenShake",
		label = "SCREEN SHAKE",
		category = "GRAPHICS",
		kind = "toggle",
		default = true,
		blurb = "Camera kick from explosions and heavy hits.",
	},
	{
		key = "damageNumbers",
		label = "DAMAGE NUMBERS",
		category = "GRAPHICS",
		kind = "toggle",
		default = true,
	},

	-- ── audio ───────────────────────────────────────────────────────────────
	{
		key = "masterVolume",
		label = "MASTER VOLUME",
		category = "AUDIO",
		kind = "slider",
		default = 0.8,
		min = 0,
		max = 1,
	},
	{
		key = "musicVolume",
		label = "MUSIC",
		category = "AUDIO",
		kind = "slider",
		default = 1,
		min = 0,
		max = 1,
	},

	-- ── controls ────────────────────────────────────────────────────────────
	{
		key = "sensitivity",
		label = "MOUSE SENSITIVITY",
		category = "CONTROLS",
		kind = "slider",
		default = 1,
		min = 0.2,
		max = 3,
	},
	{
		key = "bindFire",
		label = "FIRE",
		category = "CONTROLS",
		kind = "keybind",
		default = "",
		action = "Fire",
	},
	{ key = "bindAim", label = "AIM", category = "CONTROLS", kind = "keybind", default = "", action = "Aim" },
	{
		key = "bindReload",
		label = "RELOAD",
		category = "CONTROLS",
		kind = "keybind",
		default = "",
		action = "Reload",
	},
	{
		key = "bindInteract",
		label = "INTERACT",
		category = "CONTROLS",
		kind = "keybind",
		default = "",
		action = "Interact",
	},
	{
		key = "bindMelee",
		label = "MELEE",
		category = "CONTROLS",
		kind = "keybind",
		default = "",
		action = "Melee",
	},
	{
		key = "bindShove",
		label = "SHOVE",
		category = "CONTROLS",
		kind = "keybind",
		default = "",
		action = "Shove",
	},
	{
		key = "bindSprint",
		label = "SPRINT",
		category = "CONTROLS",
		kind = "keybind",
		default = "",
		action = "Sprint",
	},
	{
		key = "bindCrouch",
		label = "CROUCH",
		category = "CONTROLS",
		kind = "keybind",
		default = "",
		action = "Crouch",
	},
	{
		key = "toggleSprint",
		label = "TOGGLE SPRINT",
		category = "CONTROLS",
		kind = "toggle",
		default = false,
		blurb = "Tap to sprint and tap again to stop, instead of holding the key.",
	},
	{
		key = "toggleCrouch",
		label = "TOGGLE CROUCH",
		category = "CONTROLS",
		kind = "toggle",
		default = false,
		blurb = "Tap to crouch and tap again to stand, instead of holding the key.",
	},
	{
		key = "bindUseItem",
		label = "USE ITEM",
		category = "CONTROLS",
		kind = "keybind",
		default = "",
		action = "UseItem",
	},
	{
		key = "bindThrow",
		label = "THROW",
		category = "CONTROLS",
		kind = "keybind",
		default = "",
		action = "Throw",
	},
	--[[ The one row here that opens a screen rather than doing something to the
	     world. It is in the list because a readout nobody can find is a readout
	     that does not exist — and on a controller or a phone, where this has no
	     key at all, the row still says so, which is the honest answer. ]]
	{
		key = "bindBackpack",
		label = "BACKPACK",
		category = "CONTROLS",
		kind = "keybind",
		default = "",
		action = "Backpack",
	},

	-- ── gameplay ────────────────────────────────────────────────────────────
	{
		key = "difficulty",
		label = "PERSONAL DIFFICULTY",
		category = "GAMEPLAY",
		kind = "choice",
		options = { "NORMAL", "FORGIVING", "RELAXED" },
		default = "NORMAL",
		blurb = "Only changes what the infected do to YOU.",
	},
	{
		key = "subtitles",
		label = "SUBTITLES",
		category = "GAMEPLAY",
		kind = "toggle",
		default = true,
	},
}) :: { Definition }

--[[ The definition for a key, or nil. Linear because the table is small and a
     lookup map would be a second thing to keep in step with it. ]]
function SettingsConfig.get(key: string): Definition?
	for _, definition in SettingsConfig.Definitions do
		if definition.key == key then
			return definition
		end
	end
	return nil
end

--[[ Every definition in one category, in declaration order. That order is the
     order they are drawn in, so it is the design. ]]
function SettingsConfig.inCategory(category: string): { Definition }
	local found = {}
	for _, definition in SettingsConfig.Definitions do
		if definition.category == category then
			table.insert(found, definition)
		end
	end
	return found
end

--[[ A table of every default, fresh each call so a caller can own and mutate
     it. ]]
function SettingsConfig.defaults(): { [string]: any }
	local values = {}
	for _, definition in SettingsConfig.Definitions do
		values[definition.key] = definition.default
	end
	return values
end

--[[ Clamps or snaps a value to what its definition allows. Everything that
     writes a setting goes through this, so a bad value from a stale save or a
     hand-edited client cannot reach the thing that applies it. ]]
function SettingsConfig.coerce(key: string, value: any): any
	local definition = SettingsConfig.get(key)
	if not definition then
		return nil
	end

	if definition.kind == "toggle" then
		return value == true
	elseif definition.kind == "slider" then
		local number = tonumber(value)
		if not number then
			return definition.default
		end
		return math.clamp(number, definition.min or 0, definition.max or 1)
	elseif definition.kind == "choice" then
		local text = tostring(value)
		for _, option in definition.options or {} do
			if option == text then
				return text
			end
		end
		return definition.default
	elseif definition.kind == "keybind" then
		return if typeof(value) == "string" then value else definition.default
	end
	return definition.default
end

return table.freeze(SettingsConfig)
