--!nonstrict
--[[
	TurretController — the bar over a turret, and the trigger when you are in it.

	── TWO JOBS, ONE FILE, BECAUSE THEY ARE THE SAME FACT ──────────────────────
	Whether you are sitting in a turret decides both of them: it is what the bar
	says (AUTO or MANUAL) and it is what makes this file start sending input. One
	seat lookup answers both, on one loop, and splitting it would be two
	controllers asking the engine the same question fifteen times a second.

	── THE BAR IS A BILLBOARD, NOT A SCREEN ELEMENT ────────────────────────────
	Every other health readout in this game is screen-space: the survivor panels
	are a list and the boss bar is one thing at a time. A turret is neither. There
	can be four of them, they are objects in the world rather than characters, and
	which one is being torn apart is a question about WHERE. So it is drawn over
	the object, which is the only presentation that answers it.

	Built on the client and parented to PlayerGui with an Adornee, so nothing is
	added to the replicated model — the server owns the turret, this owns the
	picture of it. AlwaysOnTop is deliberately off: a bar showing through a wall
	would tell you where a turret is from somewhere you cannot see it.

	── THE NUMBERS COME FROM ATTRIBUTES ────────────────────────────────────────
	Health, MaxHealth and Manned are attributes on the model, written by the
	Turret ability. So a player who spawns in halfway through a round sees a
	correct bar over a turret nobody re-sent anything about, and a swing costs one
	replicated number rather than a remote to everybody.

	── AND THE INPUT IS A HELD FLAG ────────────────────────────────────────────
	Fifteen times a second while seated, never otherwise. It carries where the
	camera is looking and whether the trigger is down; the server owns the rate of
	fire, so sending this faster would buy nothing. See Remotes.TurretInput.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local AbilityConfig = require(Shared.Config.AbilityConfig)
local Attributes = require(Shared.Net.Attributes)
local Registry = require(Shared.Util.Registry)
local RaycastUtil = require(Shared.Util.RaycastUtil)
local Remotes = require(Shared.Net.Remotes)
local Trove = require(Shared.Util.Trove)
local UITheme = require(Shared.Config.UITheme)

local COLOR = UITheme.Color
local FONT = UITheme.Font
local TEXT = UITheme.TextSize
local TA = Attributes.Turret

local player = Players.LocalPlayer
local trove = Trove.new()

--[[ Fifteen a second. Fast enough that the barrel tracks a mouse without
     visible stepping, slow enough that four players manning four turrets is 60
     small packets a second rather than 240. ]]
local INPUT_HZ = 15
local INPUT_PERIOD = 1 / INPUT_HZ

local BAR_WIDTH = 132
local BAR_HEIGHT = 6
local CARD_HEIGHT = 34
--[[ How far clear of the top of the model the bar floats. ]]
local BAR_LIFT = 1.6
--[[ Past this the bar is not drawn at all. A turret across the map is not
     information, it is clutter, and Roblox culls it for free. ]]
local BAR_DISTANCE = 90
--[[ And how close you have to be for it to tell you how to use it. ]]
local HINT_DISTANCE = 15

type Bar = {
	gui: BillboardGui,
	adornee: BasePart,
	fill: Frame,
	caption: TextLabel,
	hint: TextLabel,
	watch: Trove.Trove,
}

local bars: { [Model]: Bar } = {}
local nextSendAt = 0
--[[ What we last told the server, so leaving the seat sends one final
     trigger-up rather than leaving the gun firing on the last flag it heard.
     The server times that out on its own — this just does not make it wait. ]]
local wasFiring = false

--[[ The turret the local player is sitting in, or nil.

     Walks ancestors rather than checking the seat's immediate parent: a supplied
     model can nest its seat inside a Model of its own, and a check one level deep
     would work for the grey-box and quietly fail for the thing somebody built. ]]
local function seatedTurret(): Model?
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local seat = humanoid and humanoid.SeatPart
	if not seat then
		return nil
	end
	local model = seat:FindFirstAncestorOfClass("Model")
	while model do
		if CollectionService:HasTag(model, AbilityConfig.TurretTag) then
			return model :: Model
		end
		model = model:FindFirstAncestorOfClass("Model")
	end
	return nil
end

--[[
	What the player is looking AT, which is what the server needs.

	Sending a direction instead is the obvious version and it is wrong by the
	distance between the camera and the gun: the camera is behind and above the
	player, the player is behind the barrel, and a heading measured at one and
	applied at the other misses by that offset. It vanishes at range and it is
	most of a body-width at five studs — which is exactly where a manned turret
	spends its time.

	So the ray is resolved here, where the client already has the world, and the
	server aims the barrel at the result. Its own character and its own turret are
	excluded: you are sitting inside both.

	Falls back to a point far down the camera ray when the ray hits nothing, which
	is a sky-facing aim and correct — the barrel should follow.
]]
local AIM_DISTANCE = 500

local function aimPoint(camera: Camera, turret: Model): Vector3
	local origin = camera.CFrame.Position
	local look = camera.CFrame.LookVector
	local ignore = { turret }
	local character = player.Character
	if character then
		table.insert(ignore, character)
	end
	local hit = Workspace:Raycast(origin, look * AIM_DISTANCE, RaycastUtil.excluding(ignore))
	return if hit then hit.Position else origin + look * AIM_DISTANCE
end

local function healthColour(fraction: number): Color3
	if fraction > 0.6 then
		return COLOR.HealthGood
	elseif fraction > 0.28 then
		return COLOR.HealthHurt
	end
	return COLOR.HealthCritical
end

local function refresh(model: Model, bar: Bar)
	local maximum = math.max(tonumber(model:GetAttribute(TA.MaxHealth)) or 0, 1)
	local current = math.clamp(tonumber(model:GetAttribute(TA.Health)) or 0, 0, maximum)
	local fraction = current / maximum

	bar.fill.Size = UDim2.fromScale(fraction, 1)
	bar.fill.BackgroundColor3 = healthColour(fraction)

	if model:GetAttribute(TA.Manned) == true then
		bar.caption.Text = "MANUAL"
		bar.caption.TextColor3 = COLOR.AccentBright
	else
		bar.caption.Text = "AUTO"
		bar.caption.TextColor3 = COLOR.TextSecondary
	end
end

local function attach(model: Model)
	if bars[model] then
		return
	end
	local adornee = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart")
	if not adornee then
		return
	end

	local gui = Instance.new("BillboardGui")
	gui.Name = "FL_TurretBar"
	gui.Adornee = adornee
	gui.AlwaysOnTop = false
	gui.LightInfluence = 0
	gui.MaxDistance = BAR_DISTANCE
	gui.Size = UDim2.fromOffset(BAR_WIDTH, CARD_HEIGHT)
	--[[ Above the whole MODEL, not above the part the bar is pinned to. The
	     adornee is the base, which on a supplied turret is a plate on the floor —
	     measuring from it would draw the bar through the middle of the gun. ]]
	local boxCFrame, boxSize = model:GetBoundingBox()
	local top = boxCFrame.Position.Y + boxSize.Y * 0.5
	gui.StudsOffsetWorldSpace = Vector3.new(0, math.max(top - adornee.Position.Y, 0) + BAR_LIFT, 0)
	gui.Parent = player:WaitForChild("PlayerGui")

	local caption = Instance.new("TextLabel")
	caption.Name = "Caption"
	caption.BackgroundTransparency = 1
	caption.Font = FONT.Heading
	caption.TextSize = TEXT.Tiny
	caption.TextColor3 = COLOR.TextSecondary
	caption.TextStrokeTransparency = 0.4
	caption.Text = "AUTO"
	caption.Size = UDim2.new(1, 0, 0, TEXT.Tiny + 2)
	caption.Parent = gui

	local hint = Instance.new("TextLabel")
	hint.Name = "Hint"
	hint.BackgroundTransparency = 1
	hint.Font = FONT.Body
	hint.TextSize = TEXT.Tiny
	hint.TextColor3 = COLOR.TextDim
	hint.TextStrokeTransparency = 0.5
	hint.Text = "WALK IN TO TAKE CONTROL"
	hint.Position = UDim2.fromOffset(0, TEXT.Tiny + 3)
	hint.Size = UDim2.new(1, 0, 0, TEXT.Tiny + 2)
	hint.Visible = false
	hint.Parent = gui

	local track = Instance.new("Frame")
	track.Name = "Track"
	track.AnchorPoint = Vector2.new(0.5, 1)
	track.Position = UDim2.new(0.5, 0, 1, 0)
	track.Size = UDim2.fromOffset(BAR_WIDTH, BAR_HEIGHT)
	track.BackgroundColor3 = COLOR.Background
	track.BackgroundTransparency = 0.25
	track.BorderSizePixel = 0
	track.Parent = gui

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = COLOR.HealthGood
	fill.BorderSizePixel = 0
	fill.Parent = track

	local watch = Trove.new()
	local bar: Bar =
		{ gui = gui, adornee = adornee, fill = fill, caption = caption, hint = hint, watch = watch }
	bars[model] = bar

	--[[ One connection per number rather than one per frame. These change on a
	     swing and on somebody sitting down, which is a handful of times in a
	     turret's whole thirty seconds. ]]
	for _, key in { TA.Health, TA.MaxHealth, TA.Manned } do
		watch:connect(model:GetAttributeChangedSignal(key), function()
			refresh(model, bar)
		end)
	end
	watch:add(gui)
	refresh(model, bar)
end

local function detach(model: Model)
	local bar = bars[model]
	if not bar then
		return
	end
	bars[model] = nil
	bar.watch:destroy()
end

--[[ How close the local player is to each turret, which is the only thing the
     hint needs. Walked on the input tick rather than per frame: there is at most
     one turret per player alive at a time and this is a subtraction each. ]]
local function refreshHints(seated: Model?)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	for model, bar in bars do
		local near = false
		if root and root:IsA("BasePart") and bar.adornee.Parent then
			near = (bar.adornee.Position - root.Position).Magnitude <= HINT_DISTANCE
		end
		--[[ Not while you are IN one, and not while somebody else is: a prompt to
		     take control of a gun that is already taken is an instruction that
		     does not work. ]]
		bar.hint.Visible = near and model ~= seated and model:GetAttribute(TA.Manned) ~= true
	end
end

local TurretController = {}

function TurretController:init()
	for _, model in CollectionService:GetTagged(AbilityConfig.TurretTag) do
		if model:IsA("Model") then
			attach(model)
		end
	end
	trove:connect(CollectionService:GetInstanceAddedSignal(AbilityConfig.TurretTag), function(instance)
		if instance:IsA("Model") then
			attach(instance)
		end
	end)
	trove:connect(CollectionService:GetInstanceRemovedSignal(AbilityConfig.TurretTag), function(instance)
		if instance:IsA("Model") then
			detach(instance)
		end
	end)
end

function TurretController:start()
	trove:connect(RunService.RenderStepped, function()
		local now = os.clock()
		if now < nextSendAt then
			return
		end
		nextSendAt = now + INPUT_PERIOD

		local seated = seatedTurret()
		refreshHints(seated)

		if not seated then
			--[[ One last trigger-up on the way out of the seat. The server times
			     a silent client out anyway, but a gun that keeps firing for a
			     third of a second after you stand up is a third of a second of
			     bullets nobody asked for. ]]
			if wasFiring then
				wasFiring = false
				local camera = Workspace.CurrentCamera
				local at = if camera then camera.CFrame.Position else Vector3.zero
				Remotes.Event.TurretInput:FireServer({ point = at, firing = false })
			end
			return
		end

		local camera = Workspace.CurrentCamera
		if not camera then
			return
		end

		local input = Registry.find("InputController")
		local firing = false
		if input and typeof(input.isDown) == "function" then
			local ok, down = pcall(input.isDown, input, input.Action.Fire)
			firing = ok and down == true
		end
		wasFiring = firing

		Remotes.Event.TurretInput:FireServer({ point = aimPoint(camera, seated), firing = firing })
	end)
end

function TurretController:destroy()
	for model in bars do
		detach(model)
	end
	trove:destroy()
end

Registry.register("TurretController", TurretController)

return TurretController
