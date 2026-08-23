--!nonstrict
--[[
	CrosshairController — four ticks that open with the cone of fire.

	The crosshair IS the accuracy readout. A player should never have to be told
	their spread, or learn a weapon's bloom from a wiki: the gap between the
	ticks is the cone, live, every frame. Fire an SMG on the move and it blows
	open; stop, aim, and it closes down to a point. That single behaviour teaches
	the entire accuracy model without one word of UI text.

	The gap is UITheme.Crosshair.GapPerDegree pixels per degree of half-angle,
	clamped between MinGap and MaxGap, and smoothed at SmoothSpeed so that the
	per-shot bloom steps read as a swell rather than as a stutter.

	── WHEN IT HIDES ───────────────────────────────────────────────────────────
	Aiming a scoped weapon (the scope is the aim), incapacitated or dead (a
	pistol on the floor does not get a crosshair), and during a cinematic. In
	every one of those cases the crosshair would be lying about something.

	── COUPLING ────────────────────────────────────────────────────────────────
	WeaponController owns the spread; this reads it at call time through the
	Registry and degrades to a static cone if that method is ever missing, so a
	half-written weapon system costs the player a crosshair that does not open,
	not a client that fails to boot.
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
local Remotes = require(Shared.Net.Remotes)
local Trove = require(Shared.Util.Trove)
local UITheme = require(Shared.Config.UITheme)

local ScaleLayer = require(script.Parent.ScaleLayer)

local CROSSHAIR = UITheme.Crosshair
local HITMARKER = UITheme.Hitmarker
local PA = Attributes.Player
local STATE = Enums.SurvivorState

--[[ Any weapon that pulls the FOV below this is wearing a scope rather than
     iron sights, and its own optic is the aiming reticle. The Hunting Rifle
     (aimFov 32) is the only one today; the test is on the number so a new
     scoped weapon needs no code change. ]]
local SCOPE_FOV = 45

-- Sub-pixel gap changes are not visible and are not worth a property write.
--[[ How far down the aim ray the reticle's screen position is measured. Far
     enough that the answer is the ANGLE between the camera and the aim rather
     than a parallax artefact of the two having very slightly different origins;
     any distance past a few hundred studs gives the same pixels. ]]
local AIM_PROJECT_DISTANCE = 600

--[[ The reticle may never travel further than this from the centre, in layer
     pixels. Nothing legitimate comes close — the largest recoil in the roster is
     a couple of degrees of aim — so this only ever catches a frame where the
     projection returned nonsense. ]]
local AIM_OFFSET_LIMIT = 260

-- Sub-pixel movement is not worth a property write.
local OFFSET_EPSILON = 0.25

local GAP_EPSILON = 0.15

local HIDDEN_STATES: { [string]: boolean } = {
	[STATE.Incapacitated] = true,
	[STATE.LedgeHanging] = true,
	[STATE.Dead] = true,
	[STATE.Spectating] = true,
	[STATE.Pinned] = true,
}

local CrosshairController = {}

local player = Players.LocalPlayer
local trove = Trove.new()

local gui: ScreenGui
--[[ The scaled content layer. The gap is a tuned pixel figure rather than a
     projection of the real cone, so scaling it keeps the reticle the same
     apparent size on every display instead of a four-pixel speck at 4K. ]]
local root: Frame
--[[ Everything the reticle is made of hangs off this, and this is what MOVES.
     The ticks stay laid out around their own centre and never learn that the
     crosshair is not at the middle of the screen. ]]
local reticle: Frame
local ticks: { Frame } = {}
local dot: Frame?

local weapons: any = nil

local state = {
	gap = CROSSHAIR.MinGap,
	appliedGap = -1,
	color = CROSSHAIR.Color,
	flashColor = CROSSHAIR.Color,
	flashUntil = 0,
	survivorState = STATE.Spectating,
	cinematic = false,
	visible = true,
	shown = true,
	-- Where the reticle currently sits relative to the middle of the screen, in
	-- layer pixels. Held so the Position write is skipped on a frame that did not
	-- move, which is most of them.
	offsetX = 0,
	offsetY = 0,
}

--[[ The four ticks, built as one vertical and one horizontal pair. Each is
     offset from dead centre by the gap, which is the only property that moves. ]]
local function build()
	gui = Instance.new("ScreenGui")
	gui.Name = "FL_Crosshair"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = UITheme.DisplayOrder.Crosshair
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = player:WaitForChild("PlayerGui")
	trove:add(gui)

	root = ScaleLayer.new(gui, "Scaled")

	reticle = Instance.new("Frame")
	reticle.Name = "Reticle"
	reticle.BackgroundTransparency = 1
	reticle.BorderSizePixel = 0
	reticle.Size = UDim2.fromScale(1, 1)
	reticle.Parent = root

	for index = 1, 4 do
		local tick = Instance.new("Frame")
		tick.Name = "Tick" .. index
		tick.AnchorPoint = Vector2.new(0.5, 0.5)
		tick.BackgroundColor3 = CROSSHAIR.Color
		tick.BackgroundTransparency = CROSSHAIR.Transparency
		tick.BorderSizePixel = 0
		local vertical = index <= 2
		tick.Size = if vertical
			then UDim2.fromOffset(CROSSHAIR.Thickness, CROSSHAIR.Length)
			else UDim2.fromOffset(CROSSHAIR.Length, CROSSHAIR.Thickness)
		tick.Parent = reticle
		ticks[index] = tick
	end

	if CROSSHAIR.DotEnabled then
		local centre = Instance.new("Frame")
		centre.Name = "Dot"
		centre.AnchorPoint = Vector2.new(0.5, 0.5)
		centre.Position = UDim2.fromScale(0.5, 0.5)
		centre.Size = UDim2.fromOffset(CROSSHAIR.Thickness, CROSSHAIR.Thickness)
		centre.BackgroundColor3 = CROSSHAIR.Color
		centre.BackgroundTransparency = CROSSHAIR.Transparency
		centre.BorderSizePixel = 0
		centre.Parent = reticle
		dot = centre
	end
end

local function applyGap(gap: number)
	--[[ The ticks sit gap+half-length from centre, so the GAP is the empty space
	     the player reads as the cone, not the distance to the far end of a tick. ]]
	local offset = gap + CROSSHAIR.Length * 0.5
	ticks[1].Position = UDim2.new(0.5, 0, 0.5, -offset)
	ticks[2].Position = UDim2.new(0.5, 0, 0.5, offset)
	ticks[3].Position = UDim2.new(0.5, -offset, 0.5, 0)
	ticks[4].Position = UDim2.new(0.5, offset, 0.5, 0)
end

local function applyColor(color: Color3)
	for _, tick in ticks do
		tick.BackgroundColor3 = color
	end
	if dot then
		dot.BackgroundColor3 = color
	end
end

local function weaponController(): any
	if weapons == nil then
		weapons = Registry.find("WeaponController") or false
	end
	return weapons or nil
end

--[[ The live cone half-angle in degrees. WeaponController publishes it; if that
     method is ever missing we fall back to the definition's hip spread, which
     is wrong while moving but never wrong enough to be worth an error. ]]
local function currentSpread(): number
	local controller = weaponController()
	if not controller then
		return 0
	end
	if typeof(controller.getSpread) == "function" then
		local ok, spread = pcall(controller.getSpread, controller)
		if ok and typeof(spread) == "number" then
			return spread
		end
	end
	if typeof(controller.getDefinition) == "function" then
		local ok, definition = pcall(controller.getDefinition, controller)
		if ok and typeof(definition) == "table" then
			return definition.spreadHip or 0
		end
	end
	return 0
end

local function shouldShow(): boolean
	if not state.visible or state.cinematic then
		return false
	end
	if HIDDEN_STATES[state.survivorState] then
		return false
	end

	local controller = weaponController()
	if controller and typeof(controller.isAiming) == "function" then
		local ok, aiming = pcall(controller.isAiming, controller)
		if ok and aiming and typeof(controller.getDefinition) == "function" then
			local gotDefinition, definition = pcall(controller.getDefinition, controller)
			if gotDefinition and typeof(definition) == "table" and definition.aimFov <= SCOPE_FOV then
				return false
			end
		end
	end
	return true
end

--[[
	Puts the reticle where the bullet is actually going.

	The shot is fired along CameraController's AIM CFrame, which carries only a
	share of the recoil and none of the shake — so during a burst the aim and the
	middle of the screen are no longer the same place. A crosshair pinned to the
	centre would quietly lie about where the next round lands, which is the one
	thing a crosshair must never do.

	Projecting a far point along the aim ray and measuring how far it falls from
	the centre of the viewport turns that angular difference into pixels, exactly
	as the renderer would. The reticle drifts down under recoil and settles back,
	and that drift is also the clearest read of "you are climbing" the game has.
]]
local function aimOffset(): (number, number)
	local camera = Workspace.CurrentCamera
	if not camera then
		return 0, 0
	end
	local controller = Registry.find("CameraController")
	if not controller or typeof(controller.getAimCFrame) ~= "function" then
		return 0, 0
	end
	local ok, aim = pcall(controller.getAimCFrame, controller)
	if not ok or typeof(aim) ~= "CFrame" then
		return 0, 0
	end

	local point, onScreen = camera:WorldToViewportPoint(aim.Position + aim.LookVector * AIM_PROJECT_DISTANCE)
	if not onScreen then
		return 0, 0
	end

	-- Real viewport pixels out, layer pixels in: the reticle lives inside the
	-- scale layer, where an offset is multiplied by the factor before it is drawn.
	local factor = ScaleLayer.getFactor()
	local dx = (point.X - camera.ViewportSize.X * 0.5) / factor
	local dy = (point.Y - camera.ViewportSize.Y * 0.5) / factor

	-- A pathological frame must not fling the reticle across the screen.
	return math.clamp(dx, -AIM_OFFSET_LIMIT, AIM_OFFSET_LIMIT),
		math.clamp(dy, -AIM_OFFSET_LIMIT, AIM_OFFSET_LIMIT)
end

local function update(dt: number)
	local show = shouldShow()
	if show ~= state.shown then
		state.shown = show
		gui.Enabled = show
	end
	if not show then
		return
	end

	--[[
		Crouching pulls the whole reticle in, not only the cone-proportional part.

		currentSpread() already carries the crouch multiplier — WeaponController
		applies it, and BallisticsService applies the same one to the shot — so the
		second term tightens on its own. What does not is MinGap, which is an
		OFFSET added to every reading rather than a floor under it, and it is most
		of the gap for a weapon that is already accurate: a rifle at 0.4 degrees of
		aim spends three of its five pixels on it. Left alone, crouching with the
		most precise gun in the game would move the reticle by two thirds of a
		pixel, which is to say by nothing.

		Scaling it by the same factor makes the reticle contract by exactly that
		factor whatever is in your hands — a rifle behaves like the SMG behaves —
		and it stays honest, because it is the same number the cone moved by.
	]]
	local floor = CROSSHAIR.MinGap
	if Attributes.get(player, PA.IsCrouching, false) then
		floor *= GameConfig.Survivor.CrouchSpreadMultiplier
	end
	local target = math.clamp(floor + currentSpread() * CROSSHAIR.GapPerDegree, floor, CROSSHAIR.MaxGap)
	state.gap += (target - state.gap) * math.min(dt * CROSSHAIR.SmoothSpeed, 1)

	if math.abs(state.gap - state.appliedGap) > GAP_EPSILON then
		state.appliedGap = state.gap
		applyGap(state.gap)
	end

	local wanted = if os.clock() < state.flashUntil then state.flashColor else CROSSHAIR.Color
	if wanted ~= state.color then
		state.color = wanted
		applyColor(wanted)
	end

	local dx, dy = aimOffset()
	if math.abs(dx - state.offsetX) > OFFSET_EPSILON or math.abs(dy - state.offsetY) > OFFSET_EPSILON then
		state.offsetX, state.offsetY = dx, dy
		reticle.Position = UDim2.fromOffset(dx, dy)
	end
end

local function refreshState()
	state.survivorState = Attributes.get(player, PA.State, STATE.Spectating)
end

-- ── public API ──────────────────────────────────────────────────────────────

--[[ Flashes the ticks. A kill holds longer and in the kill colour, because the
     two events have to be distinguishable without looking directly at them. ]]
function CrosshairController:flash(killed: boolean)
	state.flashColor = if killed then CROSSHAIR.KillColor else CROSSHAIR.HitColor
	local duration = if killed then HITMARKER.KillDuration else HITMARKER.Duration
	state.flashUntil = os.clock() + duration
end

function CrosshairController:setVisible(value: boolean)
	state.visible = value
end

function CrosshairController:setCinematic(value: boolean)
	state.cinematic = value
end

function CrosshairController:isVisible(): boolean
	return state.shown
end

--[[ The gap currently drawn, in pixels. ViewmodelController and any future
     laser-sight code can align to it rather than guessing. ]]
function CrosshairController:getGap(): number
	return state.gap
end

-- ── lifecycle ───────────────────────────────────────────────────────────────

function CrosshairController:init()
	build()
	applyGap(state.gap)
	refreshState()
	trove:connect(player:GetAttributeChangedSignal(PA.State), refreshState)
end

function CrosshairController:start()
	trove:connect(Remotes.Event.HitConfirmed.OnClientEvent, function(payload: any)
		if typeof(payload) ~= "table" then
			return
		end
		CrosshairController:flash(payload.killed == true)
	end)

	trove:connect(RunService.RenderStepped, update)
end

function CrosshairController:onInitialState(_payload: any)
	refreshState()
end

function CrosshairController:destroy()
	trove:destroy()
end

Registry.register("CrosshairController", CrosshairController)

return CrosshairController
