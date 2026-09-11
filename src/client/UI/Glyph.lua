--!nonstrict
--[[
	Glyph — the button to press, drawn for the device the player is holding.

	── WHY THIS IS A MODULE ────────────────────────────────────────────────────
	A keyboard letter on a console is not a cosmetic slip. It names a key the
	player does not have, while the button that DOES work is somewhere else
	entirely — and this game's pad layout deliberately does not mirror the 1-5
	row, so there is nothing to guess from. Every place that draws "press this"
	has to answer the same question the same way.

	It was answered twice. HudController had the full version, scheme-aware and
	complete; PromptController had its own loop that walked the bound keys and
	accepted the first one in the ASCII letter range. Interact is bound to E and
	to a face button, E sorts first, and so the prompt over a downed teammate told
	every controller player in the game to press E.

	── THE FACE BUTTONS KEEP THEIR LETTERS ─────────────────────────────────────
	A Roblox game cannot know whether the pad in somebody's hands is an Xbox or a
	PlayStation one. A/B/X/Y are the Roblox KeyCode names and are right on Xbox;
	drawing a ✕ or a ○ instead would be wrong on the other half of the audience.
	The D-pad gets arrows because "DPADUP" is four times as wide and reads as a
	debug string.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Registry = require(Shared.Util.Registry)

local Glyph = {}

--[[ What a person calls a mouse button, as against what the enum calls it.
     These arrive as Enum.UserInputType rather than Enum.KeyCode, which is why
     they need their own table and their own pass. ]]
local MOUSE: { [string]: string } = {
	MouseButton1 = "LMB",
	MouseButton2 = "RMB",
	MouseButton3 = "MMB",
}

local GAMEPAD: { [string]: string } = {
	DPadUp = "▲",
	DPadDown = "▼",
	DPadLeft = "◄",
	DPadRight = "►",
	ButtonA = "A",
	ButtonB = "B",
	ButtonX = "X",
	ButtonY = "Y",
	ButtonL1 = "L1",
	ButtonR1 = "R1",
	ButtonL2 = "L2",
	ButtonR2 = "R2",
	ButtonL3 = "L3",
	ButtonR3 = "R3",
	--[[ "VIEW", which is the Xbox name. A Roblox game cannot know whether it is
	     on an Xbox or a PlayStation pad — the same reason every other entry here
	     is a letter or an arrow rather than a symbol — and AbilityController
	     already says VIEW for the layer button, so this is the word this game
	     has settled on for it.

	     Absent until now, which was not an oversight so much as an unused row:
	     nothing was bound to Select. The walrus SPECIAL is, and without this
	     forKeys would have fallen through the gamepad branch, found nothing, and
	     told a controller player to press F. ]]
	ButtonSelect = "VIEW",
}

function Glyph.isGamepadKey(key: any): boolean
	return typeof(key) == "EnumItem" and key.EnumType == Enum.KeyCode and GAMEPAD[key.Name] ~= nil
end

--[[
	The printable glyph for a bound key row, for `scheme`.

	Roblox's KeyCode values for letters and digits ARE their ASCII codes, so the
	common cases turn into "E" and "3" without a lookup table.

	Returns "" for a touchscreen and for a gamepad with nothing bound: "there is
	no button for this" is true, and "press 5" is not.
]]
function Glyph.forKeys(keys: { any }, scheme: string?): string
	if scheme == "Touch" then
		return ""
	end
	if scheme == "Gamepad" then
		for _, key in keys do
			if Glyph.isGamepadKey(key) then
				return GAMEPAD[key.Name]
			end
		end
		return ""
	end

	for _, key in keys do
		if typeof(key) == "EnumItem" and key.EnumType == Enum.KeyCode and not Glyph.isGamepadKey(key) then
			local value = key.Value
			if (value >= 48 and value <= 57) or (value >= 97 and value <= 122) then
				return string.upper(string.char(value))
			end
		end
	end
	--[[ The mouse, which is not a KeyCode at all. Fire and Aim are the only two
	     bindings in the game whose desktop key is a UserInputType, so they slid
	     past the ASCII loop above and landed in the last-resort one below — which
	     upper-cases the enum's own name and told players to press MOUSEBUTTON1.
	     LMB is what a person calls it. ]]
	for _, key in keys do
		if typeof(key) == "EnumItem" and key.EnumType == Enum.UserInputType and MOUSE[key.Name] then
			return MOUSE[key.Name]
		end
	end

	--[[ Last resort, and it deliberately does NOT print the enum's name any more.
	     That fallback was written for the D-pad-style names this module's header
	     rejects, and every time it fired it produced exactly the kind of string
	     the header exists to prevent. A question mark is honest; MOUSEBUTTON1 is
	     not. ]]
	return "?"
end

--[[
	The glyph for an ACTION, looked up through whatever InputController currently
	has bound to it — so a rebind relabels every prompt in the game and nothing
	here holds a second opinion about which key does what.

	`controller` is passed in rather than found here so a caller inside a render
	loop can hold the reference; omitted, it is resolved once per call.
]]
function Glyph.forAction(action: string, scheme: string?, controller: any?): string
	local input = controller or Registry.find("InputController")
	if not input or typeof(input.getBindings) ~= "function" then
		return ""
	end
	local ok, bindings = pcall(input.getBindings, input)
	if not ok or typeof(bindings) ~= "table" then
		return ""
	end
	for _, binding in bindings do
		if binding.action == action then
			return Glyph.forKeys(binding.keys, scheme)
		end
	end
	return ""
end

return Glyph
