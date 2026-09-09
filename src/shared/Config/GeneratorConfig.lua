--!strict
--[[
	GeneratorConfig — the words and the colours the two halves of the generator
	puzzle have to agree on, and nothing either half could decide alone.

	── WHAT THIS IS FOR ────────────────────────────────────────────────────────
	Zombieville's side objective is five machines powered in numerical order,
	and each one opens a mini-puzzle dealt from a pack of five. The SERVER rolls
	the puzzle and owns the answer; the CLIENT draws it and sends back what the
	player pressed. Between them sits a small vocabulary — which puzzle is
	which, what a wire colour number means, how long a submission is allowed to
	be — and that vocabulary is here because a copy of it on each side is two
	copies until somebody edits one.

	── WHAT IS DELIBERATELY NOT HERE ───────────────────────────────────────────
	No answers, no generation, no checking. Those live in Server/Level/
	Generators, one module per puzzle, for the same reason the vault's template
	does: this file is readable by every client in the server.

	That is a smaller secret than the vault's, and it is worth being straight
	about why. A four-digit code is a fact you cannot see from across the room —
	hiding it is the whole puzzle. A wire panel is a picture: the player solves
	it by LOOKING at it, so everything they need is on their own machine by the
	time they can play at all. Keeping the checking on the server does not stop
	somebody from auto-solving their own mini-game; it stops them powering a
	generator they never walked to, powering one out of turn, or opening the
	gate without doing either. Those are the things that would cost the other
	three players something, and those are the things the server decides.

	── AND WHY EVERY PUZZLE IS PRESSES ─────────────────────────────────────────
	The obvious version of "connect the wires" is a drag. A drag is a mouse, and
	this game is played on a pad and a phone as well — TouchController and the
	D-pad rows in InputController are not decoration, they are two thirds of the
	audience. So every one of the five is a grid or a row of BUTTONS, answered
	by pressing them in some order, exactly the way the vault's keypad is. The
	wire puzzle still reads as connecting wires; you just press the terminal
	instead of dragging to it.
]]

local GeneratorConfig = {}

--[[
	The five, by the name a definition and a payload both use.

	A string rather than a number so a mismatched build fails as a missing
	drawer rather than as the wrong puzzle drawn over the right one's data.
]]
GeneratorConfig.Kind = table.freeze({
	--[[ Match by colour. The player's own suggestion, made pressable: four wire
	     ends down the left, four terminals down the right in a different order,
	     and you press the terminal that matches the wire that is lit. ]]
	WireMatch = "WireMatch",
	--[[ Sort by number. Five breakers with amperage stamped on them and one
	     instruction — lowest first, or highest first — and the ordering IS the
	     puzzle. ]]
	BreakerOrder = "BreakerOrder",
	--[[ Arithmetic. Six cells, one target voltage, pick the three that make it.
	     The only one of the five you can do standing still with your eyes. ]]
	VoltageMatch = "VoltageMatch",
	--[[ Timing. A needle sweeping a gauge, a green band, and a stop button,
	     three times with the band narrowing. The only one that is a reflex, and
	     the only one that gets harder rather than longer. ]]
	PressureValve = "PressureValve",
	--[[ Logic. Four phase dials, and pressing one turns the one beside it as
	     well — so the last two are always the awkward two. Rolled BACKWARDS from
	     solved, so there is no such thing as a dealt board that cannot be
	     finished. ]]
	PhaseAlign = "PhaseAlign",
})

export type Presentation = {
	--[[ The panel's heading. Names the machine's system rather than the puzzle,
	     because a heading reading "SORT THE NUMBERS" tells the player they are
	     doing a puzzle and one reading "BREAKER PANEL" tells them they are
	     fixing a generator. ]]
	title: string,
	--[[ The one line under it that says what to do. Written as an instruction a
	     technician would give, and it has to be complete: a player who reads only
	     this line must be able to finish. ]]
	instruction: string,
}

GeneratorConfig.Presentation = table.freeze({
	[GeneratorConfig.Kind.WireMatch] = table.freeze({
		title = "LOOM SPLICE",
		instruction = "PRESS THE TERMINAL MATCHING EACH LIT WIRE, TOP TO BOTTOM",
	}),
	[GeneratorConfig.Kind.BreakerOrder] = table.freeze({
		title = "BREAKER PANEL",
		instruction = "THROW THE BREAKERS IN ORDER OF RATING",
	}),
	[GeneratorConfig.Kind.VoltageMatch] = table.freeze({
		title = "BUS VOLTAGE",
		instruction = "SELECT CELLS THAT ADD UP TO THE BUS TARGET",
	}),
	[GeneratorConfig.Kind.PressureValve] = table.freeze({
		title = "FUEL PRESSURE",
		instruction = "STOP THE NEEDLE INSIDE THE GREEN BAND",
	}),
	[GeneratorConfig.Kind.PhaseAlign] = table.freeze({
		title = "PHASE ALIGN",
		instruction = "TURN EVERY DIAL TO THE TARGET \226\128\148 A DIAL TURNS ITS RIGHT NEIGHBOUR TOO",
	}),
})

--[[
	The wire palette, by index.

	Sent as NUMBERS rather than as colours, so the payload is four small integers
	instead of four Color3s and the client cannot be handed a wire the same shade
	as the panel behind it.

	Six hues rather than four, so a round can leave two out and the same four
	never come up twice running. Every one of them is picked to survive a dark
	panel AND to be distinguishable from every other one at a glance — which
	rules out the amber the rest of the interface is built from, because a wire
	the colour of the border is a wire nobody can see.

	── AND THEY ARE NAMED ──────────────────────────────────────────────────────
	The name is drawn on the wire as well as the colour. A puzzle whose only
	channel is hue is a puzzle a colourblind player cannot do, and this one is
	optional content in a co-op game — the version of "inaccessible" where your
	team walks off and does it without you.
]]
export type Wire = { name: string, color: Color3 }

GeneratorConfig.Wires = table.freeze({
	table.freeze({ name = "RED", color = Color3.fromRGB(214, 58, 46) }),
	table.freeze({ name = "BLUE", color = Color3.fromRGB(66, 138, 226) }),
	table.freeze({ name = "GREEN", color = Color3.fromRGB(86, 190, 86) }),
	table.freeze({ name = "YELLOW", color = Color3.fromRGB(226, 202, 62) }),
	table.freeze({ name = "WHITE", color = Color3.fromRGB(236, 234, 228) }),
	table.freeze({ name = "VIOLET", color = Color3.fromRGB(168, 108, 216) }),
}) :: { Wire }

--[[ A wire by index, or a grey placeholder. Never nil: a payload that named a
     colour this build does not have should draw a dead wire, not crash the panel
     a player is standing in front of. ]]
function GeneratorConfig.wire(index: any): Wire
	local slot = GeneratorConfig.Wires[if typeof(index) == "number" then index else 0]
	return slot or { name = "?", color = Color3.fromRGB(120, 116, 108) }
end

--[[
	How long a submission is allowed to be, in numbers.

	Every one of the five answers with a list of small integers — terminal
	indices, breaker indices, cell indices, needle positions, dial presses — so
	one ceiling covers all five. Phase align is the long one: it is dealt at most
	six presses from solved and a player who fumbles it can still take a few
	more, so twenty-four is generous rather than tight.

	Checked on the SERVER before anything is read out of the table. A remote that
	iterates whatever length it was handed is a remote a crafted client can hang
	the round with, and this one is called by anybody standing at a machine.
]]
GeneratorConfig.MaxAnswer = 24

--[[ The floor between two submissions from one player, in seconds. Long enough
     that a held button cannot be a firehose and short enough that a player who
     genuinely got it wrong can try again while they are still standing there. ]]
GeneratorConfig.SubmitInterval = 0.4

--[[ How long a wrong answer locks the panel for. Not a punishment — the horde
     is the punishment, and this is what makes a wrong press cost something
     without ejecting a player from a screen they are halfway through. ]]
GeneratorConfig.WrongCooldown = 1.5

--[[ Positions on the pressure gauge, as integers rather than a 0-1 float.
     Integers because they cross a remote and come back to be compared against
     a band: a float that arrives as 0.30000000000000004 is a needle that missed
     a band it visibly stopped inside. ]]
GeneratorConfig.GaugeSpan = 1000

return table.freeze(GeneratorConfig)
