--!strict
--[[
	FlashlightController — the light this player actually sees by.

	AtmosphereService takes the map from a low orange sun to pitch dark across
	fifteen waves. CarryVisualService hangs a torch on every survivor's weapon so a
	teammate's beam sweeping a doorway is a real read from forty studs away. This
	file exists because of the one thing that cannot cover: a gun points where the
	ARM points, and a player aims with the CAMERA.

	So the local player gets a second light, from the eye, and their own gun's is
	suppressed for them alone — see ViewmodelController, which already walks the
	same models to hide the weapon itself. Everyone else's beam still comes off
	their gun, which is where they can see it.

	── WHY IT IS PARENTED TO THE CAMERA ─────────────────────────────────────────
	The same trick the viewmodel uses. A part parented to Workspace.CurrentCamera
	is not part of the world: it does not replicate, nothing can collide with it,
	and it survives the camera being replaced only if we re-parent — which is why
	the camera is re-checked every frame rather than cached.

	── OFF-AXIS ─────────────────────────────────────────────────────────────────
	GameConfig.Flashlight.ViewOffset moves the beam a hand's width right and down
	of the eye. That is not decoration: a beam projected from exactly the eye
	lights nothing the player can perceive as lit, because every surface it
	reaches is one they are looking at head-on, with no shading gradient anywhere
	in frame. Moving it off-axis puts the shape back.

	── WHEN IT IS OFF ───────────────────────────────────────────────────────────
	Dead and spectating. A free camera flying over the map trailing a spotlight
	is not a survivor with a torch, it is a bug — and a dead player lighting the
	room for the living would be one too.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attributes = require(Shared.Net.Attributes)
local Enums = require(Shared.Enums)
local GameConfig = require(Shared.Config.GameConfig)
local Registry = require(Shared.Util.Registry)
local Trove = require(Shared.Util.Trove)

local PA = Attributes.Player
local STATE = Enums.SurvivorState
local TORCH = GameConfig.Flashlight

--[[ After the camera, so the beam is aimed at the CFrame that will actually be
     rendered this frame rather than at last frame's. One priority above the
     viewmodel would be pointless — neither reads the other — so it shares it. ]]
local RENDER_PRIORITY = Enum.RenderPriority.Camera.Value + 3
local RENDER_NAME = "FL_Flashlight"

--[[ States with no body to hold a torch. Dead and spectating only: a downed
     survivor still has a light in Left 4 Dead, and taking it away at exactly
     the moment they are on the floor in the dark waiting for help would be
     cruel in a way the game never intends to be. ]]
local DARK_STATES: { [string]: boolean } = {
	[STATE.Dead] = true,
	[STATE.Spectating] = true,
}

local FlashlightController = {}

local player = Players.LocalPlayer
local trove = Trove.new()

local host: BasePart? = nil
local light: SpotLight? = nil
local enabled = true

local function build()
	local part = Instance.new("Part")
	part.Name = "FL_Torch"
	part.Size = Vector3.new(0.2, 0.2, 0.2)
	part.Transparency = 1
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Locked = true

	local spot = Instance.new("SpotLight")
	spot.Name = "Beam"
	spot.Angle = TORCH.Angle
	spot.Brightness = TORCH.Brightness
	spot.Range = TORCH.Range
	spot.Color = TORCH.Color
	--[[ -Z, matching the part's own front. The part is posed straight from the
	     camera CFrame, whose LookVector is also -Z, so the beam and the view are
	     the same direction by construction rather than by a correction. ]]
	spot.Face = Enum.NormalId.Front
	spot.Shadows = false
	spot.Parent = part

	host = part
	light = spot
	trove:add(part)
end

local function survivorState(): string
	return Attributes.get(player, PA.State, STATE.Spectating)
end

local function update()
	local part, spot = host, light
	if not part or not spot then
		return
	end

	local camera = Workspace.CurrentCamera
	if not camera or not enabled or DARK_STATES[survivorState()] then
		spot.Enabled = false
		--[[ Unparented as well as switched off. A disabled light still costs the
		     renderer a light in its budget, and the whole point of the state
		     check is that this player is not using one. ]]
		part.Parent = nil
		return
	end

	--[[ Re-parented rather than cached: the camera is replaced on death, on
	     spectate and on rejoin, and a beam left in the old one is a beam that
	     never moves again. Checking a parent is cheaper than the connection that
	     would tell us it changed. ]]
	if part.Parent ~= camera then
		part.Parent = camera
	end
	spot.Enabled = true
	part.CFrame = camera.CFrame * TORCH.ViewOffset
end

--[[ Whether this player's own beam is drawn. Nothing calls it yet: the light is
     always on by design, and this is the switch a Witch mechanic or a graphics
     setting would reach for. See GameConfig.Flashlight's header. ]]
function FlashlightController:setEnabled(value: boolean)
	enabled = value ~= false
end

function FlashlightController:isEnabled(): boolean
	return enabled
end

function FlashlightController:init()
	if not TORCH.Enabled then
		return
	end
	build()
end

function FlashlightController:start()
	if not TORCH.Enabled then
		return
	end
	RunService:BindToRenderStep(RENDER_NAME, RENDER_PRIORITY, update)
	trove:add(function()
		RunService:UnbindFromRenderStep(RENDER_NAME)
	end)
end

function FlashlightController:destroy()
	trove:destroy()
	host = nil
	light = nil
end

Registry.register("FlashlightController", FlashlightController)

return FlashlightController
