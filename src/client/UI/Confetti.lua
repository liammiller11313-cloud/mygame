--!nonstrict
--[[
	Confetti — the victory burst on the result screen.

	Fired from the two bottom corners like a pair of cannons rather than dropped
	from the top: a burst reads as celebration, a drizzle reads as snow, and the
	screen this appears on only ever appears when a team survived all seventeen
	minutes.

	Kept on the palette — orange, white and gold, the same three the survivor
	outlines use — so the one genuinely joyful moment in the game still looks
	like it belongs to it.

	Everything is pooled and driven off whichever RenderStepped the owner already
	has; this module never connects to one itself. The pieces are plain Frames
	with a UIStroke-free fill, because a hundred ImageLabels would cost real frame
	time on a phone for something the player looks at for four seconds.

	── WHY THIS IS ITS OWN FILE ─────────────────────────────────────────────────
	It used to live at the top of MainMenuController, where its twelve tuning
	constants and three pieces of state sat in the same scope as the menu's own.
	Luau allows 200 locals per function scope and a module's top level is ONE
	scope, so a menu that had grown a PLAY page tipped the controller over the
	limit and stopped compiling — an error no formatter, linter or static check
	can see, because it only exists at compile time. Particle physics was never
	the menu's job anyway.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local UITheme = require(Shared.Config.UITheme)

local Widgets = require(script.Parent.Widgets)

local COUNT = 108
local GRAVITY = 1.05 -- screen heights per second squared
local SPEED_MIN = 0.95
local SPEED_MAX = 1.65
local SPREAD = 0.42 -- radians either side of straight up
local DRAG = 0.72
local SWAY = 0.22 -- horizontal flutter amplitude
local SWAY_RATE = 3.4
local LIFETIME = 4.2
local FADE_AT = 0.65 -- fraction of life before it starts fading
local WIDTH = 7
local HEIGHT = 11

local Confetti = {}
Confetti.__index = Confetti

export type Piece = {
	frame: Frame,
	x: number,
	y: number,
	vx: number,
	vy: number,
	age: number,
	phase: number,
	spin: number,
	alive: boolean,
}

export type Confetti = {
	layer: Frame,
	pieces: { Piece },
	active: number,
	burst: (self: Confetti) -> (),
	clear: (self: Confetti) -> (),
	update: (self: Confetti, dt: number) -> (),
}

--[[ Builds the layer and the pool once. Pieces live hidden until a burst claims
     them, so there is no allocation at the moment the player is looking. ]]
function Confetti.new(parent: Instance): Confetti
	local layer = Widgets.frame(parent, "Confetti", UITheme.Color.Background, 1)
	layer.Size = UDim2.fromScale(1, 1)
	layer.ClipsDescendants = true
	layer.ZIndex = 3

	local self = setmetatable({ layer = layer, pieces = {}, active = 0 }, Confetti)

	local palette = UITheme.SurvivorColors
	for index = 1, COUNT do
		local piece = Widgets.frame(layer, "Piece" .. index, palette[((index - 1) % #palette) + 1], 0)
		piece.AnchorPoint = Vector2.new(0.5, 0.5)
		piece.Size = UDim2.fromOffset(WIDTH, HEIGHT)
		piece.Visible = false
		piece.ZIndex = 3
		self.pieces[index] = {
			frame = piece,
			x = 0,
			y = 0,
			vx = 0,
			vy = 0,
			age = 0,
			phase = 0,
			spin = 0,
			alive = false,
		}
	end

	return self
end

--[[ Claims the whole pool and throws it from both bottom corners. ]]
function Confetti:burst()
	self.active = 0
	for index, piece in self.pieces do
		-- Alternate cannons so both corners fill at the same rate.
		local fromLeft = index % 2 == 1
		local angle = (-math.pi / 2) + (if fromLeft then 1 else -1) * (SPREAD * (0.35 + math.random() * 0.65))
		local speed = SPEED_MIN + math.random() * (SPEED_MAX - SPEED_MIN)

		piece.x = if fromLeft then -0.02 else 1.02
		piece.y = 1.02
		-- cos(angle) already carries the correct sign for both cannons: the left
		-- one opens clockwise from straight up and the right one anticlockwise,
		-- so each is thrown inward. Negating one sent half the pool off-screen.
		piece.vx = math.cos(angle) * speed * 1.6
		piece.vy = math.sin(angle) * speed
		piece.age = -(index % 9) * 0.035 -- stagger, so it reads as a burst not a wall
		piece.phase = math.random() * math.pi * 2
		piece.spin = (math.random() * 2 - 1) * 420
		piece.alive = true
		self.active += 1

		piece.frame.Visible = false
		piece.frame.BackgroundTransparency = 0
	end
end

function Confetti:clear()
	for _, piece in self.pieces do
		piece.alive = false
		piece.frame.Visible = false
	end
	self.active = 0
end

--[[ One integration step for the whole pool. Returns early once everything has
     landed, so the result screen costs nothing to leave open. ]]
function Confetti:update(dt: number)
	if self.active <= 0 then
		return
	end

	for _, piece in self.pieces do
		if not piece.alive then
			continue
		end

		piece.age += dt
		if piece.age < 0 then
			continue -- still waiting its turn in the stagger
		end

		if piece.age >= LIFETIME then
			piece.alive = false
			piece.frame.Visible = false
			self.active -= 1
			continue
		end

		piece.vy += GRAVITY * dt
		piece.vx -= piece.vx * DRAG * dt
		piece.x += (piece.vx + math.sin(piece.age * SWAY_RATE + piece.phase) * SWAY) * dt
		piece.y += piece.vy * dt

		-- A piece that has fallen well clear of the screen is done early.
		if piece.y > 1.15 and piece.vy > 0 then
			piece.alive = false
			piece.frame.Visible = false
			self.active -= 1
			continue
		end

		local life = piece.age / LIFETIME
		local fade = if life <= FADE_AT then 0 else (life - FADE_AT) / (1 - FADE_AT)

		local frame = piece.frame
		frame.Visible = true
		frame.Position = UDim2.fromScale(piece.x, piece.y)
		frame.Rotation = piece.age * piece.spin
		frame.BackgroundTransparency = fade
	end
end

return Confetti
