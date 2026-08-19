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
local GuiService = game:GetService("GuiService")
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
	touch: string?, -- label for the on-screen button, when the verb earns one
	touchOrder: number?, -- where it sits in the touch pad; see TouchController
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
	--[[ Primary <-> Secondary in one press. Exists because a controller has ten
	     buttons and this game has eighteen verbs: the D-pad is worth more spent
	     on the three consumables, which are unusable without it, than on two
	     weapon slots that a single swap covers. ]]
	CycleWeapon = "CycleWeapon",
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

	── THE GAMEPAD LAYOUT ───────────────────────────────────────────────────────
	A controller has ten buttons and four D-pad directions for eighteen verbs, so
	the D-pad follows Left 4 Dead 2's console layout rather than mirroring the
	1-5 keys: up is pills, down is the medkit, right is the throwable, left swaps
	weapon. That is not a stylistic choice — the previous layout spent all four
	directions on weapon slots and left the three CONSUMABLES with no button at
	all, so a pad player could carry a medkit and never use it, hold pills and
	never take them, and pick up a molotov they could not throw.

	The rest of the button budget is spent the way the platform expects it:
	triggers shoot and aim, bumpers are the two panic moves, A jumps, B crouches,
	X reloads, Y interacts.

	── PRESS-AGAIN-TO-USE ───────────────────────────────────────────────────────
	Selecting a consumable that is ALREADY selected uses it. That is what makes
	the D-pad layout complete without a dedicated "use" button — one press equips,
	the next commits — and it is worth as much on a phone, where the hotbar slots
	are the buttons and there is no room for five more.

	── TOUCH ────────────────────────────────────────────────────────────────────
	`touch` marks the verbs that earn an on-screen button and `touchOrder` ranks
	them; TouchController owns where they actually go, because it is the thing
	that knows where the HUD already is. A screen covered in buttons is a screen
	you cannot see a Hunter through, so the pad is deliberately six.
]]
local BINDINGS: { Binding } = {
	{
		action = Action.Fire,
		keys = { Enum.UserInputType.MouseButton1, Enum.KeyCode.ButtonR2 },
		touch = "FIRE",
		touchOrder = 1,
	},
	{
		action = Action.Aim,
		keys = { Enum.UserInputType.MouseButton2, Enum.KeyCode.ButtonL2 },
		touch = "AIM",
		touchOrder = 2,
	},
	{
		action = Action.Reload,
		keys = { Enum.KeyCode.R, Enum.KeyCode.ButtonX },
		touch = "RELOAD",
		touchOrder = 3,
	},
	-- The panic button. Mouse 3 rather than a letter because it has to be
	-- reachable without taking a finger off movement.
	{
		action = Action.Shove,
		keys = { Enum.UserInputType.MouseButton3, Enum.KeyCode.ButtonR1 },
		touch = "PUSH",
		touchOrder = 4,
	},
	{
		action = Action.Melee,
		keys = { Enum.KeyCode.V, Enum.KeyCode.ButtonL1 },
		touch = "MELEE",
		touchOrder = 5,
	},
	{ action = Action.Sprint, keys = { Enum.KeyCode.LeftShift, Enum.KeyCode.ButtonL3 } },
	-- Passed through: Roblox's own control script owns the jump itself, and
	-- sinking Space would break jumping to fix nothing. We only want to know.
	{ action = Action.Jump, keys = { Enum.KeyCode.Space, Enum.KeyCode.ButtonA }, pass = true },
	{ action = Action.Crouch, keys = { Enum.KeyCode.LeftControl, Enum.KeyCode.C, Enum.KeyCode.ButtonB } },
	{
		action = Action.Interact,
		keys = { Enum.KeyCode.E, Enum.KeyCode.ButtonY },
		touch = "USE",
		touchOrder = 6,
	},
	--[[ Keyboard-only, and they do not need a gamepad or touch key: on those two
	     schemes the consumable slots use themselves when re-selected, which is
	     what press-again-to-use is for. ]]
	{ action = Action.UseItem, keys = { Enum.KeyCode.H } },
	{ action = Action.Throw, keys = { Enum.KeyCode.G } },
	{ action = Action.CycleWeapon, keys = { Enum.KeyCode.DPadLeft } },

	--[[ The D-pad half of each row follows L4D2's console layout, not the 1-5
	     order: up pills, down medkit, right throwable. See the header. ]]
	{ action = Action.Slot1, keys = { Enum.KeyCode.One }, slot = Enums.Slot.Primary },
	{ action = Action.Slot2, keys = { Enum.KeyCode.Two }, slot = Enums.Slot.Secondary },
	{
		action = Action.Slot3,
		keys = { Enum.KeyCode.Three, Enum.KeyCode.DPadRight },
		slot = Enums.Slot.Throwable,
	},
	{ action = Action.Slot4, keys = { Enum.KeyCode.Four, Enum.KeyCode.DPadDown }, slot = Enums.Slot.Health },
	{ action = Action.Slot5, keys = { Enum.KeyCode.Five, Enum.KeyCode.DPadUp }, slot = Enums.Slot.Pills },

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

--[[
	Which kind of thing the player is holding.

	Not "what device is this" — a laptop with a touchscreen and a pad plugged in
	is all three at once, and a Windows handheld is a keyboard device that nobody
	is using a keyboard on. What the interface actually needs to know is which
	input the player is USING right now, so this follows their last deliberate
	press and changes under them when they pick something else up.

	Everything that draws a key glyph, sizes a tap target, or decides whether to
	put buttons on the screen reads this.
]]
local Scheme = table.freeze({
	Desktop = "Desktop",
	Touch = "Touch",
	Gamepad = "Gamepad",
})

InputController.Scheme = Scheme
InputController.schemeChanged = Signal.new() -- (scheme: string)

local trove = Trove.new()
local scheme = Scheme.Desktop
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

-- ── which input the player is actually using ────────────────────────────────

--[[
	The scheme a given input type implies, or nil for one that implies nothing.

	MouseMovement is the notable exclusion. It fires continuously, and on a
	console with a virtual cursor it fires while the player is holding a
	controller — treating it as a deliberate press would flip a ten-foot
	interface back to keyboard glyphs every time the stick nudged the pointer.
	Focus and the motion sensors are excluded for the same reason: none of them
	is somebody choosing an input.
]]
local function schemeFor(inputType: Enum.UserInputType): string?
	if inputType == Enum.UserInputType.Touch then
		return Scheme.Touch
	end
	if string.sub(inputType.Name, 1, 7) == "Gamepad" then
		return Scheme.Gamepad
	end
	if
		inputType == Enum.UserInputType.Keyboard
		or inputType == Enum.UserInputType.MouseButton1
		or inputType == Enum.UserInputType.MouseButton2
		or inputType == Enum.UserInputType.MouseButton3
		or inputType == Enum.UserInputType.MouseWheel
	then
		return Scheme.Desktop
	end
	return nil
end

local function setScheme(value: string)
	if scheme == value then
		return
	end
	scheme = value
	InputController.schemeChanged:fire(scheme)
end

--[[ The starting guess, from what the device HAS rather than from what has been
     pressed — nothing has been pressed yet, and a phone showing keyboard glyphs
     for the first second of a round is a worse first impression than one that is
     occasionally wrong on a hybrid. IsTenFootInterface is definitive for console
     and is checked first for that reason. ]]
local function initialScheme(): string
	if GuiService:IsTenFootInterface() then
		return Scheme.Gamepad
	end
	if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		return Scheme.Touch
	end
	if UserInputService.GamepadEnabled and not UserInputService.KeyboardEnabled then
		return Scheme.Gamepad
	end
	return Scheme.Desktop
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
--[[ The slots whose whole purpose is to be spent. Selecting one of these when
     it is already selected uses it — see the keymap header. Primary and
     Secondary are absent on purpose: pressing 1 twice must never fire the gun. ]]
local CONSUMABLE_SLOTS: { [string]: boolean } = {
	[Enums.Slot.Throwable] = true,
	[Enums.Slot.Health] = true,
	[Enums.Slot.Pills] = true,
}

local function forward(action: string)
	local binding = bindingFor[action]
	if binding and binding.slot then
		--[[ Re-selecting a consumable commits it. The server decides whether that
		     is legal — an empty slot, a defibrillator with nothing to point it
		     at, a survivor already mid-heal — so this only has to express the
		     intent, and a UseItem for a slot holding nothing costs one ignored
		     remote. ]]
		if CONSUMABLE_SLOTS[binding.slot] and activeSlot() == binding.slot then
			Remotes.Event.UseItem:FireServer(binding.slot)
			return
		end
		Remotes.Event.SwitchSlot:FireServer(binding.slot)
		return
	end

	if action == Action.CycleWeapon then
		--[[ One press covers both weapon slots, which is what frees the D-pad for
		     the consumables. From anything that is not a weapon it lands on the
		     primary: coming off a medkit you almost always want the rifle. ]]
		local current = activeSlot()
		local target = if current == Enums.Slot.Primary then Enums.Slot.Secondary else Enums.Slot.Primary
		Remotes.Event.SwitchSlot:FireServer(target)
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

--[[ `false` for the touch-button argument, always. ContextActionService draws
     its own round grey buttons at fixed pixel offsets from the bottom-right
     corner — which is exactly where the ammo counter and the hotbar live, so
     they landed on top of the HUD, and they ignore the theme and the viewport
     scale besides. TouchController draws the pad instead and calls raise(). ]]
local function bind(binding: Binding)
	ContextActionService:BindActionAtPriority(
		PREFIX .. binding.action,
		handle(binding),
		false,
		PRIORITY,
		table.unpack(binding.keys)
	)
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
	Expresses a verb from something that is not a key.

	TouchController's buttons are the only caller: an on-screen button is a
	GuiButton, not a bound input, so it cannot reach the ContextActionService
	handler that everything else goes through. Routing it here rather than
	letting the touch layer fire remotes itself keeps ONE definition of what a
	verb costs — the disabled check, the held-state bookkeeping and the forward
	are the same code for a finger as for a trigger.

	Returns false when the verb was refused, so a button can decline to light up.
]]
function InputController:raise(action: string, isDown: boolean): boolean
	if not bindingFor[action] then
		return false
	end
	if isDown and (not enabled or UserInputService:GetFocusedTextBox() ~= nil) then
		return false
	end
	setDown(action, isDown)
	if isDown then
		forward(action)
	end
	return true
end

--[[ Which input the player is using right now: one of InputController.Scheme.
     Anything drawing a key glyph or sizing a tap target reads this and listens
     to schemeChanged. ]]
function InputController:getScheme(): string
	return scheme
end

--[[ True on a phone or tablet, as distinct from a desktop that merely has a
     touchscreen. The distinction matters because only the former needs the
     on-screen pad. ]]
function InputController:isTouchScheme(): boolean
	return scheme == Scheme.Touch
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

	--[[ The scheme follows the player's last deliberate press. LastInputTypeChanged
	     rather than polling: it fires exactly when the answer changes, and the
	     answer changes about as often as somebody puts a controller down. ]]
	setScheme(initialScheme())
	trove:connect(UserInputService.LastInputTypeChanged, function(inputType: Enum.UserInputType)
		local implied = schemeFor(inputType)
		if implied then
			setScheme(implied)
		end
	end)
end

function InputController:destroy()
	trove:destroy()
end

Registry.register("InputController", InputController)

return InputController
