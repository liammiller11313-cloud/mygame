--!nonstrict
--[[
	WaypointController — the arrow to the room the generators opened.

	One arrow, on a ring around the crosshair, pointing at whatever the server
	has marked. It exists because "GET TO THE LOOT ROOM" is only useful to
	somebody who already knows where the loot room is, and after five generators
	across a map that size the team is very often standing somewhere they have
	never been.

	── WHY IT IS A RING ARROW AND NOT A PIN OVER THE DOOR ──────────────────────
	A BillboardGui over the room is invisible the moment a building is between
	you and it, which on a street map is most of the time and exactly when a
	player needs it. A ring arrow answers a different question — WHICH WAY do I
	turn — and it answers it from anywhere, through anything.

	It is the same geometry OverlayController's damage arrows use, and
	deliberately so: this game already teaches its players that a mark on that
	ring means "over there", and a second convention for the same idea would be a
	second thing to learn.

	── DRIVEN BY AN ATTRIBUTE, NOT AN EVENT ────────────────────────────────────
	Where to point is a Vector3 on Workspace. A survivor who joins late, dies and
	respawns, or alt-tabs back in gets the current answer for free; a remote
	fired once at the moment the gate opened would have missed all three of them.
	Nil takes the arrow down, which is how the round ending removes it.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attributes = require(Shared.Net.Attributes)
local Registry = require(Shared.Util.Registry)
local Trove = require(Shared.Util.Trove)
local UITheme = require(Shared.Config.UITheme)

local ScaleLayer = require(script.Parent.ScaleLayer)
local Widgets = require(script.Parent.Widgets)

local COLOR = UITheme.Color
local FONT = UITheme.Font
local INDICATOR = UITheme.DamageIndicator
local TEXT = UITheme.TextSize

local GA = Attributes.Game

local player = Players.LocalPlayer

--[[ A little outside the damage ring, so the two never sit on top of each other
     when something hits you from the direction you are heading. Same radius
     would make one read as the other. ]]
local RADIUS = INDICATOR.Radius + 26
local ARROW_WIDTH = 26
local ARROW_HEIGHT = 26
--[[ The caption rides just outside the arrow, on the same bearing. Far enough
     that the two do not overlap at any angle, close enough to read as one
     mark. ]]
local CAPTION_RADIUS = RADIUS + 26
local CAPTION_WIDTH = 190

--[[
	How close counts as arrived.

	Inside this the arrow comes down: a mark that keeps pointing at a room you
	are standing in is a mark that says "you are lost" to somebody who is not,
	and on a ring an arrow to a target two studs away swings wildly with every
	step. Twenty-two studs is about a doorway and a bit.
]]
local ARRIVED = 22

--[[ How much of the fade is left at the far end. The arrow is never fully
     opaque — it is a hint over a horde, not a piece of the HUD — and it firms up
     as the room gets closer, which is the cheapest possible way to say "warmer".
     ]]
local FAR_TRANSPARENCY = 0.45
local NEAR_TRANSPARENCY = 0.1
--[[ The distance over which that fade happens. Beyond it the arrow sits at its
     dimmest, which on a map this size is most of the walk. ]]
local FADE_OVER = 260

local WaypointController = {}

local trove = Trove.new()

local gui: ScreenGui
local arrow: Frame
local caption: TextLabel

local state = {
	--[[ Whether the ring is being drawn at all. Held rather than read off
	     `gui.Enabled` so the step function can bail on one boolean rather than on
	     a property lookup plus an attribute read, every frame, for the whole of
	     every round that has no waypoint in it — which is most of them. ]]
	active = false,
	position = Vector3.zero,
	label = "",
	cinematic = false,
}

local function build()
	gui = Instance.new("ScreenGui")
	gui.Name = "FL_Waypoint"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	--[[ On the crosshair's layer rather than the HUD's. It is a mark about where
	     you are looking, and under the prompt and the subtitles, which are marks
	     about what is in front of you. ]]
	gui.DisplayOrder = UITheme.DisplayOrder.Crosshair
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Enabled = false
	gui.Parent = player:WaitForChild("PlayerGui")
	trove:add(gui)

	local layer = ScaleLayer.new(gui, "Scaled")

	--[[ A chevron, drawn as a square rotated 45 degrees with its lower half cut
	     off by a gradient. Cheaper and sharper than an image asset, and it
	     inherits the theme's accent rather than baking a colour into a texture.
	     ]]
	arrow = Widgets.frame(layer, "Arrow", COLOR.AccentBright, 0)
	arrow.AnchorPoint = Vector2.new(0.5, 0.5)
	arrow.Size = UDim2.fromOffset(ARROW_WIDTH, ARROW_HEIGHT)
	arrow.Rotation = 45
	arrow.Visible = false

	local fade = Instance.new("UIGradient")
	fade.Rotation = 45
	fade.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.5, 0),
		NumberSequenceKeypoint.new(0.55, 1),
		NumberSequenceKeypoint.new(1, 1),
	})
	fade.Parent = arrow

	caption = Widgets.label(layer, "Caption", FONT.Heading, TEXT.Tiny, COLOR.AccentBright)
	caption.AnchorPoint = Vector2.new(0.5, 0.5)
	caption.Size = UDim2.fromOffset(CAPTION_WIDTH, TEXT.Tiny + 4)
	caption.TextXAlignment = Enum.TextXAlignment.Center
	caption.TextStrokeTransparency = 0.4
	caption.Visible = false
end

--[[ Reads the two attributes and decides whether there is anything to draw. The
     only thing that turns the ScreenGui on, so a map with no waypoint costs one
     attribute read per change rather than anything per frame. ]]
local function refresh()
	local position = Attributes.get(Workspace, GA.WaypointPosition, nil)
	state.active = typeof(position) == "Vector3" and not state.cinematic
	state.position = if typeof(position) == "Vector3" then position else Vector3.zero
	state.label = tostring(Attributes.get(Workspace, GA.WaypointLabel, "") or "")

	gui.Enabled = state.active
	if not state.active then
		arrow.Visible = false
		caption.Visible = false
	end
end

local function step()
	if not state.active then
		return
	end
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end

	local relative = camera.CFrame:PointToObjectSpace(state.position)
	--[[
		A target you are standing on has no direction.

		atan2(0, 0) is zero, and zero is straight ahead — so a room you have
		walked into would draw a confident arrow at the horizon in front of you,
		which is not a missing arrow but a wrong one. The horizontal magnitude is
		what matters: a loot room one floor up is still "here", and telling a
		player to walk north because of it would be worse than saying nothing.

		Same reasoning, and the same fix, as OverlayController's damage ring.
	]]
	local flat = Vector2.new(relative.X, relative.Z)
	if flat.Magnitude < ARRIVED then
		arrow.Visible = false
		caption.Visible = false
		return
	end

	arrow.Visible = true
	caption.Visible = state.label ~= ""

	local angle = math.atan2(relative.X, -relative.Z)
	local sin, cos = math.sin(angle), math.cos(angle)

	arrow.Position = UDim2.new(0.5, sin * RADIUS, 0.5, -cos * RADIUS)
	arrow.Rotation = math.deg(angle) + 45

	caption.Position = UDim2.new(0.5, sin * CAPTION_RADIUS, 0.5, -cos * CAPTION_RADIUS)

	--[[ Firms up as you close. `alpha` is 1 at the far end and 0 on arrival, so
	     the arrow is dimmest exactly when the player has the least to do about
	     it. ]]
	local alpha = math.clamp((flat.Magnitude - ARRIVED) / FADE_OVER, 0, 1)
	local transparency = NEAR_TRANSPARENCY + (FAR_TRANSPARENCY - NEAR_TRANSPARENCY) * alpha
	arrow.BackgroundTransparency = transparency
	caption.TextTransparency = transparency
	--[[ The distance, in whole studs, under the name. It is the difference
	     between an arrow that says "that way" and one that says "that way, and
	     you are nearly there" — which is what stops a team giving up on a room
	     they cannot see yet. ]]
	caption.Text = string.format("%s  %dm", state.label, math.floor(flat.Magnitude))
end

-- ── public ──────────────────────────────────────────────────────────────────

--[[ Hidden during a cinematic, like every other piece of the HUD. A chevron over
     a chapter card is a chevron over the one moment the game is not asking the
     player to do anything. ]]
function WaypointController:setCinematic(value: boolean)
	state.cinematic = value
	refresh()
end

-- ── lifecycle ───────────────────────────────────────────────────────────────

function WaypointController:init()
	build()
end

function WaypointController:start()
	trove:connect(Workspace:GetAttributeChangedSignal(GA.WaypointPosition), refresh)
	trove:connect(Workspace:GetAttributeChangedSignal(GA.WaypointLabel), refresh)
	trove:connect(RunService.RenderStepped, step)
	--[[ Read once at boot as well as on change, so a player who joins after the
	     gate is already open sees the arrow rather than waiting for a change that
	     has already happened. ]]
	refresh()
end

function WaypointController:destroy()
	trove:destroy()
end

Registry.register("WaypointController", WaypointController)

return WaypointController
