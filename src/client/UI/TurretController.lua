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
local Enums = require(Shared.Enums)
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
local INPUT_HZ = 20
local INPUT_PERIOD = 1 / INPUT_HZ

--[[
	THE BARREL IS DRAWN HERE, NOT WAITED FOR.

	A manned turret felt laggy because it WAS: the aim went to the server at
	INPUT_HZ, the server turned the model on its own Heartbeat, and the new angle
	came back down the wire — so the gun sat a full round trip plus up to a tick
	of quantisation behind the crosshair. On a hundred-millisecond connection
	that is most of a fifth of a second of the barrel visibly trailing the mouse,
	which is exactly what "very buggy and laggy" describes.

	A client already knows where it is aiming. So while YOU are the driver, your
	own client pivots the gun every frame from your own camera and does not wait
	for anyone. RenderStepped runs after replication inside a frame, so the local
	angle is what gets drawn even though the server keeps writing its own for
	everybody else.

	── AND IT CANNOT CHEAT ─────────────────────────────────────────────────────
	Nothing about the SHOT moves. The server fires from the direction it was
	sent, applies its own clamp, and picks its own target; a client that lied
	about where the model points would change what the gun looks like and not
	what it hits. That split — cosmetic on the client, authority on the server —
	is the only reason this is safe to do at all.
]]
local MAX_PITCH = math.rad(AbilityConfig.get(Enums.Ability.Turret).tuning.MaxPitchDegrees)

--[[ The same clamp the server applies, from the same shared number. Duplicated
     as CODE and not as a constant on purpose: two files agreeing on 28 is a
     config read, two files agreeing on the arithmetic is four lines. ]]
local function aimHeading(delta: Vector3): Vector3?
	local flat = Vector3.new(delta.X, 0, delta.Z)
	local run = flat.Magnitude
	if run < 0.05 then
		return nil
	end
	local pitch = math.clamp(math.atan2(delta.Y, run), -MAX_PITCH, MAX_PITCH)
	return (flat / run) * math.cos(pitch) + Vector3.yAxis * math.sin(pitch)
end

--[[ Resolved once per turret and remembered. Weak keys, so a turret that
     expires or is destroyed takes its entry with it — this is looked up every
     frame while somebody is driving, and a recursive FindFirstChild per frame
     for an answer that cannot change is the kind of waste that only shows up on
     a phone. ]]
local aimParts = (setmetatable({}, { __mode = "k" }) :: any) :: { [Model]: PVInstance | false }

--[[
	Whatever has to turn to point the gun.

	The same two candidates the server resolves, in the same order: a supplied
	model's child called `gun` (see buildSupplied), or the procedural body's
	`Head` (see the grey-box build). Getting this wrong is worse than not
	predicting at all — the client would turn one part while the server turned
	another — so it mirrors that function rather than guessing.

	`false` is cached for a turret with neither, which is a model somebody
	supplied without a gun child. The server stands those still and shoots from
	the base, and this leaves them alone.
]]
local function aimPartOf(turret: Model): PVInstance?
	local cached = aimParts[turret]
	if cached ~= nil then
		return if cached then cached else nil
	end
	local found: PVInstance? = nil
	local gun = turret:FindFirstChild("gun", true)
	if gun and (gun:IsA("BasePart") or gun:IsA("Model")) then
		found = gun :: PVInstance
	else
		local head = turret:FindFirstChild("Head", true)
		if head and head:IsA("BasePart") then
			found = head :: PVInstance
		end
	end
	aimParts[turret] = found or false
	return found
end

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

		--[[
			The barrel first, and OUTSIDE the send throttle.

			These were one block, so the gun turned at INPUT_HZ even for the
			person driving it — the throttle exists to spare the network and was
			costing the driver frames it was never meant to touch. Drawing is
			every frame; telling the server is twenty times a second.
		]]
		local seatedNow = seatedTurret()
		if seatedNow then
			local camera = Workspace.CurrentCamera
			local aim = camera and aimPartOf(seatedNow)
			if camera and aim then
				local at = aim:GetPivot().Position
				local heading = aimHeading(aimPoint(camera, seatedNow) - at)
				if heading then
					aim:PivotTo(CFrame.lookAt(at, at + heading))
				end
			end
		end

		if now < nextSendAt then
			return
		end
		nextSendAt = now + INPUT_PERIOD

		local seated = seatedNow
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
