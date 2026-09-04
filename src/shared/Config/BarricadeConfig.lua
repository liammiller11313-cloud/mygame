--!nonstrict
--[[
	BarricadeConfig — what makes a part something the horde can chew through.

	── THE CONTRACT IS THE MATERIAL ─────────────────────────────────────────────
	Set a part's Material to Wood in Studio and the infected can break it down.
	That is the whole authoring story: no tag, no attribute, no naming
	convention, no script inside the model. A level designer boarding up a window
	reaches for planks anyway, so the thing they were already going to do IS the
	thing that arms it.

	WoodPlanks counts as well. Roblox ships two wood materials and nobody
	choosing between them is making a gameplay decision; treating one as
	breakable and the other as stone would be a trap laid for whoever builds the
	next map.

	── WHY THERE IS A SIZE WINDOW ───────────────────────────────────────────────
	"Every wood part" taken literally would arm the trim, the chair legs, the
	skirting boards and the pallet nobody will ever stand behind — hundreds of
	instances per map, each with health, each searched every time a body swings.
	It would also arm the FLOOR, and a horde that can eat the floor is a horde
	that drops the team into the void.

	So a part has to be big enough to be worth hiding behind and small enough to
	be a piece of carpentry rather than a building. Both ends are in studs cubed
	and both are here rather than in the service, because the day this is wrong
	it will be wrong for one specific map and the fix should be a number.

	── AND IT HAS TO BE STRUCTURE ───────────────────────────────────────────────
	Anchored and colliding. Loose wood is furniture — a chair that can be shoved
	across a room is not a barricade, and letting the horde stop to fight one
	would turn every table in the map into cover the Director has to path around.
	A part with collisions off is decoration by definition: nothing is behind it.

	── HEALTH COMES FROM VOLUME ─────────────────────────────────────────────────
	A door is a door-sized amount of work and a boarded shopfront is more. Paying
	per stud is the only version of this that stays right when somebody builds a
	map this code has never seen, and the clamp at both ends stops a sliver and a
	warehouse wall from being absurd in opposite directions.
]]

local BarricadeConfig = {}

--[[ The whole feature, off in one place. A map that turns out to be full of
     wooden scenery can be played with this false while the geometry is sorted
     out, rather than with a service commented out of the boot list. ]]
BarricadeConfig.Enabled = true

--[[ Set by the service on every part it arms, so the brain can ask "is this
     thing in my way something I can break?" with one CollectionService call
     rather than by re-testing material, size and anchoring per swing. ]]
BarricadeConfig.Tag = "FL_Barricade"

--[[
	The escape hatch, and the reason it exists.

	A map with a folder of this name arms EXACTLY what is inside it and does not
	scan for wood at all. The material contract is the good default and it is
	still a heuristic: it has to guess, on a map this code has never seen,
	which wooden things were meant to be obstacles. When it guesses wrong the
	answer should be a folder a designer drags six parts into, not a set of
	numbers they have to tune until the trim stops being edible.

	Matched as forgivingly as every other map folder here — case, spacing,
	punctuation and a trailing plural all folded away.
]]
BarricadeConfig.FolderName = "Barricades"

--[[ Both wood materials. See the header: choosing between them is a texture
     decision, not a gameplay one. ]]
BarricadeConfig.Materials = table.freeze({
	[Enum.Material.Wood] = true,
	[Enum.Material.WoodPlanks] = true,
})

--[[ Studs cubed. A door leaf is about 14, a shop counter about 40, and ONE
     plank nailed across a window about 1.5 — the low end is set by that plank
     rather than by the window, because boarding is several parts and each one
     being separately breakable is the better version of it. A floor slab or a
     whole wooden wall is in the thousands and is deliberately outside. ]]
BarricadeConfig.MinVolume = 1.5
BarricadeConfig.MaxVolume = 900

--[[ Health per stud cubed, then clamped. 25 puts a standard door at ~350 —
     about eight seconds of a six-body horde, which is long enough to be a
     moment and short enough that nobody goes to make tea. ]]
BarricadeConfig.HealthPerStud = 25
BarricadeConfig.MinHealth = 150
BarricadeConfig.MaxHealth = 1200

--[[
	What one infected swing takes off, as a multiple of what that swing would do
	to a survivor.

	Scaled rather than flat so the hierarchy the infected roster already
	establishes carries over: a Tank should go through a door faster than a
	Common, and it does, without a second damage table to keep in step with the
	first. Three is chosen against the horde, not the individual — one Common
	alone on a door is 13 dps and will be there a while, which is correct.
]]
BarricadeConfig.InfectedDamageScale = 3

--[[ How far past its own reach a body will look for something to break. Zero
     would mean only swinging at a barricade it is already touching, which reads
     as the horde ignoring the door until it is flush against it. ]]
BarricadeConfig.ReachBonus = 2.5

--[[
	How far ahead the brain looks for something in its way.

	Short on purpose. This is "there is a door between me and you", not "there is
	a door somewhere over there" — a long probe would have bodies stopping to
	attack barricades they were never going to walk into, three rooms away from
	anything.
]]
BarricadeConfig.ProbeRange = 9

--[[
	How vertical a slab's thinnest axis has to be before it is read as a FLOOR.

	This is the clause that stops the horde eating the ground, and it is needed
	because the obvious guards do not cover it. A plank floor is not one big part
	outside the volume window — it is forty small ones, each the size of a door
	panel, each anchored, each colliding, each made of wood. Every test above
	passes them.

	What actually separates them is which way they are thin. A floor is thin
	VERTICALLY; a door, a wall and a board nailed across a window are all thin
	HORIZONTALLY, whatever their other two dimensions do and however the part
	itself is rotated. So the thinnest axis is taken into world space and its Y
	component compared against this: 0.7 is about 45 degrees, which lets a sloped
	board through and keeps a floor and a ceiling out.

	Only applied to parts that are genuinely slab-shaped — see the service. A
	cube has no meaningful thinnest axis and asking one which way it is thin
	gives an answer that flips with the modelling.
]]
BarricadeConfig.FloorNormalDot = 0.7

--[[ How much thinner than its next dimension a part has to be before the floor
     test means anything at all. Below this it is a block, not a slab, and a
     block is a crate. ]]
BarricadeConfig.SlabRatio = 0.5

--[[ Debris. A break that just vanishes reads as a part being deleted, which is
     what it is, so the splinters are the whole job of making it read as a break
     instead. ]]
BarricadeConfig.SplinterCount = 14
BarricadeConfig.SplinterLifetime = 2.5

--[[
	Whether a broken barricade is removed or left standing as a wreck.

	It is HIDDEN, not destroyed, and that is a lesson paid for once already: the
	map is not reloaded when a round replays the same level, so anything a round
	destroys is still gone at the start of the next one. Hiding is also the
	cheaper restore — the service puts back the three properties it changed.
]]
BarricadeConfig.HiddenTransparency = 1

return BarricadeConfig
