--!nonstrict
--[[
	Dread — the room the interface sits in.

	Two full-screen effects under everything else, running for the whole session:
	an edge darkness that never quite holds still, and film grain built out of
	gradients rather than uploaded as a texture. Neither of them says anything.
	That is the point — every other layer in this game is a readout, and a game
	that only ever draws information is a game played in a clean rectangle.

	── WHY THIS IS NOT THE VIGNETTE WE ALREADY HAD ─────────────────────────────
	OverlayController's vignette is a READOUT: it reddens as health falls and it
	is honestly blank when you are fine, which is right for a thing whose job is
	to tell you something. The consequence nobody noticed is that a healthy
	survivor plays inside a perfectly clean frame with hard screen edges.

	This one is black, quiet and permanent, and it draws UNDER that one so the
	two never fight: at full health you get only this, and as the red comes up it
	composites over a frame that already had edges.

	It does not reach the main menu, and that is deliberate rather than an
	oversight — the menu draws its own vignette, stronger, measured against its
	own two text columns and its own photograph. Two vignettes over one picture
	is a muddy corner and a number nobody can tune.

	── THE HAZE IS INTERFERENCE, AND IT IS NOT GRAIN ───────────────────────────
	Two full-screen gradients at angles that share no common factor, each with
	eighteen randomised stops, re-seeded several times a second. Where they cross,
	two independent random sequences interfere and the frame develops a slow
	uneven cast that keeps moving: light through dirty glass rather than a clean
	pane.

	It is deliberately not called film grain, because it cannot be. A UIGradient
	interpolates SMOOTHLY between at most twenty stops, so the finest thing this
	can draw is soft banding tens of pixels across — not speckle. Calling it grain
	would be describing an effect the code does not produce.

	Real grain needs a texture, so there is a slot for one: set UITheme.Dread
	HazeImage to a seamless noise tile and the layers become that tile, repeated
	small and jerked to a new offset on the same clock, which IS per-pixel
	speckle. Empty is the default because an image that fails to load is a broken
	square over somebody's HUD, and an atmosphere layer must never be able to do
	that. The gradients are what you get for free until somebody uploads one.

	Either way it re-seeds at HazeFps rather than per frame, and that is a look
	decision before it is a cost one: something that changes every frame at 120Hz
	reads as electronic noise, and something that changes fourteen times a second
	reads as a projector.

	── TWO LAYERS, BECAUSE THEY WANT OPPOSITE PLACES ───────────────────────────
	The edges belong UNDER the interface: they are the world getting darker at the
	corners, and putting them over the HUD would darken the corners the hotbar and
	the ammo counter live in.

	The haze belongs OVER it, above even the menu. It is grime on the glass the
	whole game is seen through, and a menu exempt from it reads as a different and
	cleaner screen — which is the exact seam this was added to close. That is why
	the menu is opaque over the edges and still gets the haze.

	── AND IT COSTS ALMOST NOTHING ─────────────────────────────────────────────
	Six instances. The edges are written only when the breath has moved them far
	enough to see, and the grain rebuilds two NumberSequences at fourteen hertz.
	There is no per-frame allocation in the common case.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Device = require(Shared.Util.Device)
local Registry = require(Shared.Util.Registry)
local Trove = require(Shared.Util.Trove)
local UITheme = require(Shared.Config.UITheme)

local DREAD = UITheme.Dread

local Dread = {}

local player = Players.LocalPlayer
local trove = Trove.new()

local edgeGui: ScreenGui
local hazeGui: ScreenGui
local edges: { Frame } = {}
--[[ The two haze layers. Gradients when there is no texture, ImageLabels when
     there is; `hazeTiled` says which, because the two are re-seeded differently
     and nothing else about them differs. ]]
local hazeGradients: { UIGradient } = {}
local hazeTiles: { ImageLabel } = {}
local hazeTiled = false

--[[ How much of the authored strength this device gets. A phone is a smaller
     screen held closer: a full-strength vignette eats the corners of a HUD that
     is already tight, and it has the least frame budget to spend on something
     nobody is looking at. ]]
local scale = 1

local state = {
	--[[ What the edges are actually drawing, so the breath only writes when it
	     has moved far enough for anybody to see. Starts impossible so the first
	     tick always publishes. ]]
	applied = -1,
	nextHaze = 0,
	--[[ A phase offset per session, so two players sitting next to each other do
	     not breathe in unison. It is the kind of thing nobody would consciously
	     notice and everybody would feel. ]]
	phase = math.random() * 1000,
}

-- ── the edges ───────────────────────────────────────────────────────────────

--[[
	One edge of the vignette: a black frame with a gradient that fades it out
	toward the middle of the screen.

	Four of them rather than one radial image for the same reason MenuBackdrop
	does it: there is no radial gradient in Roblox's 2D UI, and four linear ones
	produce a rectangle-shaped darkness that suits a rectangle-shaped screen
	better than a circle would anyway. The corners get two layers and are
	therefore darkest, which is what a vignette wants.
]]
local function buildEdge(name: string, rotation: number, size: UDim2, position: UDim2, anchor: Vector2)
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.BackgroundColor3 = Color3.new()
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0
	frame.AnchorPoint = anchor
	frame.Position = position
	frame.Size = size
	frame.Parent = edgeGui

	local gradient = Instance.new("UIGradient")
	gradient.Rotation = rotation
	--[[ Opaque at the screen edge, gone by the inner lip. The frame's own
	     BackgroundTransparency is what the breath moves; this only shapes it. ]]
	gradient.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.55, 0.55),
		NumberSequenceKeypoint.new(1, 1),
	})
	gradient.Parent = frame

	table.insert(edges, frame)
end

local function buildEdges()
	local extent = DREAD.EdgeExtent
	buildEdge("Left", 0, UDim2.fromScale(extent, 1), UDim2.fromScale(0, 0.5), Vector2.new(0, 0.5))
	buildEdge("Right", 180, UDim2.fromScale(extent, 1), UDim2.fromScale(1, 0.5), Vector2.new(1, 0.5))
	buildEdge("Top", 90, UDim2.fromScale(1, extent), UDim2.fromScale(0.5, 0), Vector2.new(0.5, 0))
	buildEdge("Bottom", 270, UDim2.fromScale(1, extent), UDim2.fromScale(0.5, 1), Vector2.new(0.5, 1))
end

-- ── the haze ────────────────────────────────────────────────────────────────

--[[ One haze layer, in whichever form this build has. Both are full-screen,
     both are almost entirely transparent, and both are re-seeded on the same
     clock; the tiled one is real grain and the gradient one is the fallback. ]]
local function buildHazeLayer(name: string, rotation: number)
	if hazeTiled then
		local tile = Instance.new("ImageLabel")
		tile.Name = name
		tile.BackgroundTransparency = 1
		tile.BorderSizePixel = 0
		tile.Size = UDim2.fromScale(1, 1)
		tile.Image = DREAD.HazeImage
		tile.ImageTransparency = DREAD.HazeTransparency
		tile.ScaleType = Enum.ScaleType.Tile
		tile.TileSize = UDim2.fromOffset(DREAD.HazeTileSize, DREAD.HazeTileSize)
		tile.Parent = hazeGui
		table.insert(hazeTiles, tile)
		return
	end

	local frame = Instance.new("Frame")
	frame.Name = name
	frame.BackgroundColor3 = Color3.new()
	frame.BackgroundTransparency = DREAD.HazeTransparency
	frame.BorderSizePixel = 0
	frame.Size = UDim2.fromScale(1, 1)
	frame.Parent = hazeGui

	local gradient = Instance.new("UIGradient")
	gradient.Rotation = rotation
	gradient.Parent = frame

	table.insert(hazeGradients, gradient)
end

--[[
	A fresh random stop sequence for one grain layer.

	The two ends are pinned because NumberSequence requires keypoints at exactly
	0 and 1, which leaves HazeStops for the middle. Values run the full 0..1
	range: the layer's own transparency is what makes it faint, so clamping the
	sequence as well would only flatten it into a uniform wash.
]]
local function reseedGradient(gradient: UIGradient)
	local stops = table.create(DREAD.HazeStops + 2)
	table.insert(stops, NumberSequenceKeypoint.new(0, math.random()))
	for index = 1, DREAD.HazeStops do
		--[[ Evenly spaced rather than randomly placed. Random POSITIONS can land
		     two stops on top of each other, which NumberSequence rejects outright
		     — a crash for a cosmetic layer. Random VALUES on a fixed comb give the
		     same noise and cannot fail. ]]
		table.insert(stops, NumberSequenceKeypoint.new(index / (DREAD.HazeStops + 1), math.random()))
	end
	table.insert(stops, NumberSequenceKeypoint.new(1, math.random()))
	gradient.Transparency = NumberSequence.new(stops)
end

--[[ A tiled layer is re-seeded by MOVING it: one tile's worth in each direction,
     which with a seamless texture is a completely different arrangement of
     speckle and no visible edge anywhere. ]]
local function reseedTile(tile: ImageLabel)
	local size = DREAD.HazeTileSize
	tile.Position = UDim2.fromOffset(-math.random(0, size), -math.random(0, size))
	--[[ Oversized by one tile in each direction, so shifting it never uncovers a
	     corner of the screen it was supposed to be covering. ]]
	tile.Size = UDim2.new(1, size * 2, 1, size * 2)
end

-- ── the tick ────────────────────────────────────────────────────────────────

local function step()
	local now = os.clock() + state.phase

	--[[ The breath. One sine on a period long enough that it never reads as a
	     pulse, taking the edge down by a fifth at its shallowest. ]]
	local breath = 1 - DREAD.BreathDepth * (0.5 + 0.5 * math.sin(now * math.pi * 2 / DREAD.BreathPeriod))
	local strength = DREAD.EdgeStrength * scale * breath

	if math.abs(strength - state.applied) > 0.004 then
		state.applied = strength
		local transparency = 1 - strength
		for _, edge in edges do
			edge.BackgroundTransparency = transparency
		end
	end

	if now >= state.nextHaze then
		state.nextHaze = now + 1 / DREAD.HazeFps
		for _, gradient in hazeGradients do
			reseedGradient(gradient)
		end
		for _, tile in hazeTiles do
			reseedTile(tile)
		end
	end
end

-- ── lifecycle ───────────────────────────────────────────────────────────────

function Dread:init()
	scale = Device.pick({ Mobile = DREAD.MobileScale }, 1)

	--[[ Nothing on either layer ever takes input, and nothing has to be set to
	     arrange that: a Frame is inert unless its Active is turned on, and none of
	     these six touch it. Worth stating rather than left to be rediscovered —
	     two full-screen layers over every menu in the game is exactly the shape of
	     thing that swallows every click if somebody "tidies" a property in. ]]
	local parent = player:WaitForChild("PlayerGui")

	edgeGui = Instance.new("ScreenGui")
	edgeGui.Name = "FL_DreadEdges"
	edgeGui.ResetOnSpawn = false
	edgeGui.IgnoreGuiInset = true
	edgeGui.DisplayOrder = UITheme.DisplayOrder.Dread
	edgeGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	edgeGui.Parent = parent
	trove:add(edgeGui)

	hazeGui = Instance.new("ScreenGui")
	hazeGui.Name = "FL_DreadHaze"
	hazeGui.ResetOnSpawn = false
	hazeGui.IgnoreGuiInset = true
	hazeGui.DisplayOrder = UITheme.DisplayOrder.DreadHaze
	hazeGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	hazeGui.Parent = parent
	trove:add(hazeGui)

	hazeTiled = DREAD.HazeImage ~= ""

	buildEdges()
	buildHazeLayer("HazeA", DREAD.HazeAngleA)
	buildHazeLayer("HazeB", DREAD.HazeAngleB)
end

function Dread:start()
	--[[ Heartbeat rather than RenderStepped. Nothing here has to be correct
	     before the frame is drawn — it is a slow breath and grain that resamples
	     fourteen times a second — and RenderStepped is the one budget in the
	     engine worth being precious about. ]]
	trove:connect(RunService.Heartbeat, step)
	step()
end

--[[ Off, for anything that needs a clean frame. Nothing calls it yet; it exists
     because a photo mode or a cutscene will, and the alternative to a switch is
     that whoever needs one reaches in and reparents the ScreenGui. ]]
function Dread:setEnabled(enabled: boolean)
	local on = enabled ~= false
	if edgeGui then
		edgeGui.Enabled = on
	end
	if hazeGui then
		hazeGui.Enabled = on
	end
end

function Dread:destroy()
	trove:destroy()
	table.clear(edges)
	table.clear(hazeGradients)
	table.clear(hazeTiles)
end

Registry.register("Dread", Dread)

return Dread
