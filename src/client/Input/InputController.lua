--!strict
--[[
	InputController — every binding in the game, in one table, and nothing else.

	This controller has exactly one opinion: which physical input means which
	verb. It never decides whether the verb is legal, never plays a sound, and
	never touches the camera. It answers "the player asked for X" and lets the
	system that owns X decide what that costs.

	Keeping it that thin is what makes rebinding a data change instead of a code
	change. BINDINGS below is the whole keymap; `InputController:rebind` swaps a
	row at runtime, which is all a future options menu needs.

		local input = Registry.get("InputController")
		input:onBegan(input.Action.Reload):connect(function() ... end)
		if input:isDown(input.Action.Aim) then ... end

	── WHAT THIS CONTROLLER SENDS ───────────────────────────────────────────────
	Four intents have no prediction to do and no owner other than the inventory,
	so they are forwarded straight from here: SwitchSlot, UseItem, ThrowItem and
	PingLocation. Everything with a predicted local consequence — firing,
	reloading, melee, shove, aim state — is WeaponController's, and it listens to
	the signals below rather than to the keyboard.

	BeginInteract is deliberately NOT sent here. That remote carries the target
	Instance, and choosing the target is PromptController's job; it listens for
	the Interact signal and supplies the subject.
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attributes = require(Shared.Net.Attributes)
local Enums = require(Shared.Enums)
local Registry = require(Shared.Util.Registry)
local Remotes = require(Shared.Net.Remotes)
local Signal = require(Shared.Util.Signal)
local Trove = require(Shared.Util.Trove)

type Binding = {
	action: string,
	keys: { any }, -- Enum.KeyCode | Enum.UserInputType, keyboard/mouse/gamepad alike
	slot: string?, -- set on the five slot actions; the slot they select
	pass: boolean?, -- let the input fall through to Roblox's own controls
	touch: string?, -- title of the on-screen button, when it earns one
	touchPos: UDim2?,
}

--[[ Every verb the player can express. Compare against these, never against a
     string literal, so a rename stays a single-file change. ]]
local Action = table.freeze({
	Fire = "Fire",
	Aim = "Aim",
	Reload = "Reload",
	Shove = "Shove",
	Melee = "Melee",
	Sprint = "Sprint",
	Jump = "Jump",
	Crouch = "Crouch",
	Interact = "Interact",
	UseItem = "UseItem",
	Throw = "Throw",
	Slot1 = "Slot1",
	Slot2 = "Slot2",
	Slot3 = "Slot3",
	Slot4 = "Slot4",
	Slot5 = "Slot5",
	Ping = "Ping",
})

--[[
	THE KEYMAP. One table, one row per verb, keyboard/mouse/gamepad in the same
	row because they are the same verb.

	Gamepad coverage is deliberately incomplete: a controller has ten buttons and
	this game has seventeen verbs, so the four that a pad player can live without
	(throw, use item, pills slot, ping) are keyboard-only rather than buried in a
	chord nobody would find. Touch gets the five buttons that make the game
	playable and no more; a screen covered in buttons is a screen you cannot see
	a Hunter through.
]]
local BINDINGS: { Binding } = {
	{
		action = Action.Fire,
		keys = { Enum.UserInputType.MouseButton1, Enum.KeyCode.ButtonR2 },
		touch = "FIRE",
		touchPos = UDim2.new(1, -128, 1, -128),
	},
	{
		action = Action.Aim,
		keys = { Enum.UserInputType.MouseButton2, Enum.KeyCode.ButtonL2 },
		touch = "AIM",
		touchPos = UDim2.new(1, -128, 1, -232),
	},
	{
		action = Action.Reload,
		keys = { Enum.KeyCode.R, Enum.KeyCode.ButtonX },
		touch = "RELOAD",
		touchPos = UDim2.new(1, -232, 1, -128),
	},
	-- The panic button. Mouse 3 rather than a letter because it has to be
	-- reachable without taking a finger off movement.
	{
		action = Action.Shove,
		keys = { Enum.UserInputType.MouseButton3, Enum.KeyCode.ButtonR1 },
		touch = "PUSH",
		touchPos = UDim2.new(1, -232, 1, -232),
	},
	{ action = Action.Melee, keys = { Enum.KeyCode.V, Enum.KeyCode.ButtonL1 } },
	{ action = Action.Sprint, keys = { Enum.KeyCode.LeftShift, Enum.KeyCode.ButtonL3 } },
	-- Passed through: Roblox's own control script owns the jump itself, and
	-- sinking Space would break jumping to fix nothing. We only want to know.
	{ action = Action.Jump, keys = { Enum.KeyCode.Space, Enum.KeyCode.ButtonA }, pass = true },
	{ action = Action.Crouch, keys = { Enum.KeyCode.LeftControl, Enum.KeyCode.C, Enum.KeyCode.ButtonB } },
	{
		action = Action.Interact,
		keys = { Enum.KeyCode.E, Enum.KeyCode.ButtonY },
		touch = "USE",
		touchPos = UDim2.new(1, -128, 1, -336),
	},
	{ action = Action.UseItem, keys = { Enum.KeyCode.H } },
	{ action = Action.Throw, keys = { Enum.KeyCode.G } },

	{ action = Action.Slot1, keys = { Enum.KeyCode.One, Enum.KeyCode.DPadUp }, slot = Enums.Slot.Primary },
	{
		action = Action.Slot2,
		keys = { Enum.KeyCode.Two, Enum.KeyCode.DPadLeft },
		slot = Enums.Slot.Secondary,
	},
	{
		action = Action.Slot3,
		keys = { Enum.KeyCode.Three, Enum.KeyCode.DPadRight },
		slot = Enums.Slot.Throwable,
	},
	{ action = Action.Slot4, keys = { Enum.KeyCode.Four, Enum.KeyCode.DPadDown }, slot = Enums.Slot.Health },
	{ action = Action.Slot5, keys = { Enum.KeyCode.Five }, slot = Enums.Slot.Pills },

	{ action = Action.Ping, keys = { Enum.KeyCode.Q, Enum.KeyCode.ButtonR3 } },
}

-- CAS binds under one namespace so nothing here can collide with a Roblox
-- default binding or with another controller's.
local PREFIX = "FL_"

-- Above the default character controls, so a sunk binding actually wins. The
-- rows marked `pass` still fall through despite sitting up here.
local PRIORITY = Enum.ContextActionPriority.High.Value

-- How far a ping ray reaches before it gives up and marks empty air.
local PING_RANGE = 500

local InputController = {}

--[[ Every action, as a fact rather than a keycode. Read InputController.Action
     at the call site instead of typing the string. ]]
InputController.Action = Action

--[[ Aggregate streams, for anything that wants the whole keymap at once (a
     rebinding UI, an input-echo debug overlay). Per-action signals are cheaper
     for a single consumer — see onBegan/onEnded. ]]
InputController.actionBegan = Signal.new() -- (action: string)
InputController.actionEnded = Signal.new() -- (action: string)

local trove = Trove.new()
local down: { [string]: boolean } = {}
local beganSignals: { [string]: Signal.Signal } = {}
local endedSignals: { [string]: Signal.Signal } = {}
local bindingFor: { [string]: Binding } = {}
local enabled = true
local player = Players.LocalPlayer

for _, binding in BINDINGS do
	bindingFor[binding.action] = binding
end

-- ── signal plumbing ─────────────────────────────────────────────────────────

local function signalIn(store: { [string]: Signal.Signal }, action: string): Signal.Signal
	local existing = store[action]
	if existing then
		return existing
	end
	local created = Signal.new()
	store[action] = created
	return created
end

--[[ Fires when `action` is pressed. Safe to connect before start(). ]]
function InputController:onBegan(action: string): Signal.Signal
	return signalIn(beganSignals, action)
end

--[[ Fires when `action` is released, and also when input is disabled while it
     was held — a menu opening must never leave the trigger stuck down. ]]
function InputController:onEnded(action: string): Signal.Signal
	return signalIn(endedSignals, action)
end

function InputController:isDown(action: string): boolean
	return down[action] == true
end

local function setDown(action: string, isDown: boolean)
	if down[action] == isDown then
		return
	end
	down[action] = isDown

	local perAction = if isDown then beganSignals[action] else endedSignals[action]
	if perAction then
		perAction:fire(action)
	end
	if isDown then
		InputController.actionBegan:fire(action)
	else
		InputController.actionEnded:fire(action)
	end
end

-- ── intents this controller forwards itself ─────────────────────────────────

local function cameraRay(): (Vector3, Vector3)
	local camera = Workspace.CurrentCamera
	if not camera then
		return Vector3.zero, Vector3.zAxis
	end
	local cframe = camera.CFrame
	return cframe.Position, cframe.LookVector
end

local function activeSlot(): string
	return Attributes.get(player, Attributes.Loadout.ActiveSlot, Enums.Slot.Secondary)
end

--[[
	A ping is a position plus what was standing at it. Resolving `kind` here
	rather than server-side keeps the remote to one round trip and costs a single
	raycast that the client was going to be able to do anyway.
]]
local function ping()
	local origin, direction = cameraRay()
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { player.Character :: any }

	local hit = Workspace:Raycast(origin, direction * PING_RANGE, params)
	local position = if hit then hit.Position else origin + direction * PING_RANGE

	local kind = "Location"
	if hit then
		local model = hit.Instance:FindFirstAncestorOfClass("Model")
		if model then
			if model:GetAttribute(Attributes.Infected.Kind) ~= nil then
				kind = "Infected"
			elseif model:GetAttribute(Attributes.Pickup.ItemId) ~= nil then
				kind = "Pickup"
			end
		end
	end

	Remotes.Event.PingLocation:FireServer({ position = position, kind = kind })
end

--[[ Intents with no local prediction. Everything with a predicted consequence
     belongs to WeaponController, which listens to the signals instead. ]]
local function forward(action: string)
	local binding = bindingFor[action]
	if binding and binding.slot then
		Remotes.Event.SwitchSlot:FireServer(binding.slot)
		return
	end

	if action == Action.UseItem then
		Remotes.Event.UseItem:FireServer(activeSlot())
	elseif action == Action.Throw then
		local origin, direction = cameraRay()
		Remotes.Event.ThrowItem:FireServer({ origin = origin, direction = direction, power = 1 })
	elseif action == Action.Ping then
		ping()
	end
end

-- ── binding ─────────────────────────────────────────────────────────────────

local function handle(binding: Binding)
	return function(_name: string, state: Enum.UserInputState, _input: InputObject): Enum.ContextActionResult?
		if binding.pass then
			-- Observe only. Sinking this would break the verb we are observing.
			if state == Enum.UserInputState.Begin then
				setDown(binding.action, true)
			elseif state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
				setDown(binding.action, false)
			end
			return Enum.ContextActionResult.Pass
		end

		if not enabled or UserInputService:GetFocusedTextBox() ~= nil then
			return Enum.ContextActionResult.Pass
		end

		if state == Enum.UserInputState.Begin then
			setDown(binding.action, true)
			forward(binding.action)
		elseif state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
			setDown(binding.action, false)
		end
		return Enum.ContextActionResult.Sink
	end
end

local function bind(binding: Binding)
	local name = PREFIX .. binding.action
	ContextActionService:BindActionAtPriority(
		name,
		handle(binding),
		binding.touch ~= nil,
		PRIORITY,
		table.unpack(binding.keys)
	)
	if binding.touch then
		ContextActionService:SetTitle(name, binding.touch)
		if binding.touchPos then
			ContextActionService:SetPosition(name, binding.touchPos)
		end
	end
end

local function unbind(binding: Binding)
	ContextActionService:UnbindAction(PREFIX .. binding.action)
end

-- ── public API ──────────────────────────────────────────────────────────────

--[[
	Swaps the inputs behind one verb at runtime. `keys` is a list of KeyCode or
	UserInputType, exactly as the BINDINGS rows are written, so an options menu
	only ever has to hand back the same shape it read.
]]
function InputController:rebind(action: string, keys: { any }): boolean
	local binding = bindingFor[action]
	if not binding or #keys == 0 then
		return false
	end
	unbind(binding)
	binding.keys = keys
	setDown(action, false)
	bind(binding)
	return true
end

--[[ The live keymap, for a rebinding UI to render. Rows are the live tables —
     edit them through :rebind, not by hand, or the CAS binding goes stale. ]]
function InputController:getBindings(): { Binding }
	return BINDINGS
end

--[[
	Suspends every gameplay binding, releasing anything held first. A menu that
	opens while the trigger is down must not leave WeaponController firing into
	the pause screen, which is what the explicit release below is for.
]]
function InputController:setEnabled(value: boolean)
	if enabled == value then
		return
	end
	enabled = value
	if not enabled then
		for action, isDown in down do
			if isDown then
				setDown(action, false)
			end
		end
	end
end

function InputController:isEnabled(): boolean
	return enabled
end

-- ── lifecycle ───────────────────────────────────────────────────────────────

function InputController:init()
	for _, binding in BINDINGS do
		bind(binding)
	end
	trove:add(function()
		for _, binding in BINDINGS do
			unbind(binding)
		end
	end)
end

function InputController:start()
	--[[
		A window that loses focus mid-firefight keeps its Begin but never delivers
		the End, so the player alt-tabs back into a gun that is still shooting.
		Releasing everything on focus loss is the entire fix.
	]]
	trove:connect(UserInputService.WindowFocusReleased, function()
		for action, isDown in down do
			if isDown then
				setDown(action, false)
			end
		end
	end)
end

function InputController:destroy()
	trove:destroy()
end

Registry.register("InputController", InputController)

return InputController
