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
local AbilityConfig = require(Shared.Config.AbilityConfig)
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
	--[[ Opens the backpack panel. A verb rather than a hard-coded key so it shows
	     up in the controls screen and can be rebound like every other one — a
	     readout nobody can find is a readout that does not exist. Keyboard only:
	     see the binding row. ]]
	Backpack = "Backpack",
	--[[ Opens the requisition panel. Same reasoning as Backpack: a verb rather
	     than a hard-coded key, so it shows in the controls screen and rebinds. ]]
	Requisitions = "Requisitions",
	--[[ One per ability slot, named rather than generated because Action is a
	     frozen literal and a verb somebody rebinds has to have a stable name.
	     There are four because AbilityConfig.SlotCeiling is four; how many are
	     actually BOUND comes off AbilityConfig.MaxSlots below, so raising the
	     number of slots a player gets does not touch this table. ]]
	Ability1 = "Ability1",
	Ability2 = "Ability2",
	Ability3 = "Ability3",
	Ability4 = "Ability4",
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
	`touch` is the label for the verbs that earn an on-screen button. Placement
	is TouchController's, keyed on the action name, because the arrangement is a
	thumb arc rather than a list and only the thing that knows where the HUD
	already sits can decide it. A screen covered in buttons is a screen you cannot
	see a Hunter through, so the pad is deliberately six — and one of those six
	only appears when there is something to interact with.
]]
local BINDINGS: { Binding } = {
	{
		action = Action.Fire,
		keys = { Enum.UserInputType.MouseButton1, Enum.KeyCode.ButtonR2 },
		touch = "FIRE",
	},
	{
		action = Action.Aim,
		keys = { Enum.UserInputType.MouseButton2, Enum.KeyCode.ButtonL2 },
		touch = "AIM",
	},
	{
		action = Action.Reload,
		keys = { Enum.KeyCode.R, Enum.KeyCode.ButtonX },
		touch = "RELOAD",
	},
	-- The panic button. Mouse 3 rather than a letter because it has to be
	-- reachable without taking a finger off movement.
	{
		action = Action.Shove,
		keys = { Enum.UserInputType.MouseButton3, Enum.KeyCode.ButtonR1 },
		touch = "PUSH",
	},
	--[[ Carries `slot` so the hotbar tile can draw the key that reaches it, the
	     way every other slot row does. The BEHAVIOUR is not the generic slot
	     switch though — see the Action.Melee branch in `forward`, which toggles
	     rather than selects, and which runs before the generic path. ]]
	{
		action = Action.Melee,
		keys = { Enum.KeyCode.V, Enum.KeyCode.ButtonL1 },
		touch = "MELEE",
		slot = Enums.Slot.Melee,
	},
	{ action = Action.Sprint, keys = { Enum.KeyCode.LeftShift, Enum.KeyCode.ButtonL3 } },
	-- Passed through: Roblox's own control script owns the jump itself, and
	-- sinking Space would break jumping to fix nothing. We only want to know.
	--[[ Passed through: Roblox's own control script owns the jump itself, and
	     sinking Space would break jumping to fix nothing. We only want to know.

	     It still earns a touch button. Roblox draws its own on a phone, in the
	     bottom-RIGHT corner — which is exactly where the pad anchors, so the two
	     fought for the same thumb. TouchController.suppressRobloxJump now
	     actually removes Roblox's; for a long time this comment said it did
	     while nothing anywhere was doing it. ]]
	{
		action = Action.Jump,
		keys = { Enum.KeyCode.Space, Enum.KeyCode.ButtonA },
		pass = true,
		touch = "JUMP",
	},
	{
		action = Action.Crouch,
		keys = { Enum.KeyCode.LeftControl, Enum.KeyCode.C, Enum.KeyCode.ButtonB },
		touch = "CROUCH",
	},
	{
		action = Action.Interact,
		keys = { Enum.KeyCode.E, Enum.KeyCode.ButtonY },
		touch = "USE",
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

	--[[ Keyboard only, and no touch button. A pad has no free face or shoulder
	     button left — the view button opens the pause menu, which is where
	     BACKPACK sits for a controller and for a phone — and the touch pad is
	     deliberately six buttons, because a screen covered in them is a screen
	     you cannot see a Hunter through. ]]
	{ action = Action.Backpack, keys = { Enum.KeyCode.B } },
	--[[ Keyboard only, for the same reasons BACKPACK is: no pad button is free
	     and the touch pad is deliberately six. Both panels sit in the pause menu,
	     which is how a controller and a phone reach them. ]]
	{ action = Action.Requisitions, keys = { Enum.KeyCode.T } },
}

--[[
	── THE ABILITY SLOTS ───────────────────────────────────────────────────────
	Appended rather than written out, so the number of ability keys is
	AbilityConfig.MaxSlots and not a number repeated here. Adding a third slot is
	that one config change plus a key on the end of this list.

	Keyboard only, and that is a real gap rather than an oversight. Every gamepad
	button is spoken for — both triggers, both bumpers, all four face buttons,
	both stick clicks, all four D-pad directions and the view button — and Start
	belongs to Roblox. Nothing here is worth taking from a verb that already has
	it, so a controller player rebinds an ability onto whichever of those they
	want least, in the CONTROLS screen, which takes gamepad inputs. Touch gets
	real buttons: see `touch`, which TouchController draws.
]]
local ABILITY_KEYS = { Enum.KeyCode.Z, Enum.KeyCode.X, Enum.KeyCode.F, Enum.KeyCode.N }

for index = 1, math.min(AbilityConfig.MaxSlots, #ABILITY_KEYS) do
	table.insert(BINDINGS, {
		action = (Action :: any)["Ability" .. index],
		keys = { ABILITY_KEYS[index] },
		touch = "ABILITY " .. index,
	})
end

if AbilityConfig.MaxSlots > #ABILITY_KEYS then
	warn(
		string.format(
			"[InputController] AbilityConfig.MaxSlots is %d but only %d ability keys are listed — "
				.. "slots past %d have no default binding and can only be reached by rebinding",
			AbilityConfig.MaxSlots,
			#ABILITY_KEYS,
			#ABILITY_KEYS
		)
	)
end

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

--[[ Whether crouch is a tap or a hold. Off by default: holding is what a player
     who has never opened the settings expects, and it is what every prompt in
     the game says. ]]
local crouchToggle = false

--[[
	Sprint, which until now was not a control at all — the server granted sprint
	speed to anybody with stamina, so the key was bound, drawn on the controls
	card, and did nothing.

	The wish is tracked here rather than read back from an attribute (as crouch
	is) because the server publishes nothing for it: sprinting changes nothing
	anybody else can see, so there is no reason to spend a replicated property on
	it. That does mean this side owns the truth, which is why the default matches
	the server's and why assertSprintWish exists to re-state it whenever the rule
	changes underneath it.
]]
local sprintToggle = false
local sprintWish = true

local function setSprintWish(value: boolean)
	if sprintWish == value then
		return
	end
	sprintWish = value
	Remotes.Event.SetSprintState:FireServer(value)
end

local function isCrouching(): boolean
	return Attributes.get(player, Attributes.Player.IsCrouching, false) == true
end

local function setDown(action: string, isDown: boolean)
	if down[action] == isDown then
		return
	end
	down[action] = isDown

	--[[ Crouch is a HELD state, not an event, so it rides the down/up edge
	     rather than forward(). The server owns whether it is granted; this only
	     reports that the button is down, and reports the release too — including
	     the release setEnabled() synthesises when a menu opens, which is what
	     stops a player being stuck crouched behind the scoreboard.

	     In TOGGLE mode only the press says anything, and what it says is the
	     opposite of what the server currently has. Asking the ATTRIBUTE rather
	     than remembering our own last request is what makes it self-heal: the
	     server drops crouch on its own whenever the body stops being upright, so
	     a client keeping its own flag would come back from a jump believing it
	     was still crouched and spend the next tap standing up from a stand. ]]
	--[[ Sprint, on the same down/up edge as crouch. In toggle mode only the press
	     speaks, and it says the opposite of what we are currently asking for. ]]
	if action == Action.Sprint then
		if sprintToggle then
			if isDown then
				setSprintWish(not sprintWish)
			end
		else
			setSprintWish(isDown)
		end
	end

	if action == Action.Crouch then
		if not crouchToggle then
			Remotes.Event.SetCrouchState:FireServer(isDown)
		elseif isDown then
			Remotes.Event.SetCrouchState:FireServer(not isCrouching())
		end
	end

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

--[[ Whether there is anything in a slot to use. Read off the loadout attributes
     the HUD already draws from, so this cannot disagree with the tile the player
     is looking at. ]]
local function slotHolds(slot: string): boolean
	local attribute = if slot == Enums.Slot.Health
		then Attributes.Loadout.HealthItemId
		elseif slot == Enums.Slot.Pills then Attributes.Loadout.PillItemId
		elseif slot == Enums.Slot.Throwable then Attributes.Loadout.ThrowableId
		else nil
	if not attribute then
		return false
	end
	return Attributes.get(player, attribute, "") ~= ""
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

--[[ The slots holding something you can look at. Melee is here for completeness
     rather than reachability: the melee key is a toggle and returns above, so it
     never arrives at the slot branch. ]]
local WEAPON_SLOTS: { [string]: boolean } = {
	[Enums.Slot.Primary] = true,
	[Enums.Slot.Secondary] = true,
	[Enums.Slot.Melee] = true,
}

--[[
	Which slot the player has ASKED for, which is not the same as the one the
	server has confirmed.

	LA.ActiveSlot only moves once SwitchSlot has been there and back. Two quick
	presses on a bad connection would therefore both read the old slot, both send
	SwitchSlot, and nothing would ever be used — on precisely the platforms
	press-again-to-use exists for, which are also the ones most likely to be on a
	phone network. Remembering the request for a round trip's worth of time is
	the whole fix.

	The window is generous because being wrong is nearly free: the second press
	sends a UseItem for a slot the server may not agree is selected, and the
	server ignores it.
]]
local SELECT_MEMORY = 1.0
local lastSelect = { slot = "", at = 0 }

--[[ What the melee key came FROM, so pressing it again puts that back. Empty
     when the player got to the melee some other way — a number key, a pickup —
     in which case the key falls back to the primary. ]]
local meleeReturn = ""

local function selectedSlot(): string
	if lastSelect.slot ~= "" and os.clock() - lastSelect.at < SELECT_MEMORY then
		return lastSelect.slot
	end
	return activeSlot()
end

local function forward(action: string)
	local binding = bindingFor[action]

	--[[
		The melee key: draw it, or put it away.

		A toggle rather than a plain slot key, because a melee is something you
		dip into and come back from. Shoving a Common off you and then having to
		remember which number key your rifle was on is the kind of small friction
		that gets people killed, and "press it again" is the answer every shooter
		that has a melee key has landed on.

		It used to SWING instead — Action.Melee called swingMelee() on whatever was
		in your hands, so pressing V while holding a rifle sent the server a swing
		with a rifle's definition. Now the key changes what you are holding and the
		trigger swings it, which is the same two verbs on the two controls that
		already mean them.
	]]
	if action == Action.Melee then
		local current = selectedSlot()
		local target
		if current == Enums.Slot.Melee then
			--[[ Back to whatever the key interrupted. The primary is the fallback
			     for the same reason CycleWeapon uses it: coming off anything else,
			     the rifle is almost always what you wanted. ]]
			target = if meleeReturn ~= "" then meleeReturn else Enums.Slot.Primary
			meleeReturn = ""
		else
			meleeReturn = current
			target = Enums.Slot.Melee
		end
		lastSelect.slot = target
		lastSelect.at = os.clock()
		Remotes.Event.SwitchSlot:FireServer(target)
		return
	end

	if binding and binding.slot then
		--[[
			Re-selecting a consumable commits it — but only where the player has
			no better way to say so.

			On a controller and on a phone this is the only way to use an item at
			all: the D-pad is full and there is no room on screen for five more
			buttons. On a desktop there is a dedicated key, and adding a hidden
			second meaning to the number row would mean a player who double-tapped
			4 to make sure it registered had just burned their medkit. Same rule,
			applied only where it is the difference between usable and not.
		]]
		-- The upvalue, not getScheme(): same answer, and it does not depend on a
		-- method that is assigned further down the file than this closure.
		local pressAgain = scheme == Scheme.Gamepad or scheme == Scheme.Touch
		if pressAgain and CONSUMABLE_SLOTS[binding.slot] and selectedSlot() == binding.slot then
			Remotes.Event.UseItem:FireServer(binding.slot)
			lastSelect.slot = ""
			return
		end

		--[[
			Re-selecting the weapon you are already holding turns it over in your
			hands. The same press-again rule as the line above, on every scheme
			rather than only the cramped ones.

			The restriction above exists because re-pressing a consumable SPENDS
			it, so a desktop player double-tapping 4 to make sure it registered
			would have burned their medkit. Looking at a gun costs nothing and is
			cancelled by anything that matters, so there is no such trap here and
			no reason to hide it from the players with a keyboard.

			Purely local: no remote, no server state. It is what the weapon looks
			like, and nobody else needs to be told.
		]]
		if WEAPON_SLOTS[binding.slot] and selectedSlot() == binding.slot then
			local viewmodel = Registry.find("ViewmodelController")
			if viewmodel and typeof(viewmodel.inspect) == "function" then
				pcall(viewmodel.inspect, viewmodel)
			end
			return
		end

		lastSelect.slot = binding.slot
		lastSelect.at = os.clock()
		Remotes.Event.SwitchSlot:FireServer(binding.slot)
		return
	end

	--[[
		Jump, forwarded here because a touch button cannot reach the control
		script the way a key can.

		On a keyboard, Space is handled by Roblox's own controls and this binding
		only observes it — which is why the row is marked `pass`. A finger on an
		on-screen button has no such path, so the jump has to be performed here.

		── WHY THIS IS NOT `humanoid.Jump = true` ──────────────────────────────
		It was, and on a phone it did nothing at all.

		Roblox's ControlModule WRITES that property every frame, from whatever its
		own controller thinks the player is asking for — `humanoid.Jump =
		controller:GetIsJumping()`. On a phone that controller is TouchJump, whose
		button this game hides (see TouchController.suppressRobloxJump), so it
		reports false forever. Our `true` was set between two frames and
		overwritten by the control loop before the physics step could ever consume
		it. On a keyboard nobody noticed, because there Space never reached this
		branch for real — Roblox's own controller was doing the jumping.

		ChangeState drives the humanoid's state machine directly, which is not a
		property the ControlModule assigns, so nothing stomps it.

		── AND WHY IT NEEDS A GROUND CHECK ─────────────────────────────────────
		That directness is also the hazard. `Jump = true` was quietly safe because
		the state machine ignores it in mid-air; ChangeState does not ask, so
		without this guard the button becomes an infinite air-jump — hold it and
		walk over the map. FloorMaterial is Air exactly when there is nothing
		underfoot, and Climbing is the one grounded-enough state that has no
		floor.
	]]
	if action == Action.Jump then
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if not humanoid or humanoid.Health <= 0 then
			return
		end
		--[[ Zero while a survivor is pinned or downed — SurvivorService drops both
		     to immobilise them — and a state change would jump them out of a
		     Hunter's grip. ]]
		if humanoid.JumpPower <= 0 and humanoid.JumpHeight <= 0 then
			return
		end
		local grounded = humanoid.FloorMaterial ~= Enum.Material.Air
			or humanoid:GetState() == Enum.HumanoidStateType.Climbing
		if grounded then
			humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
		end
		return
	end

	if action == Action.CycleWeapon then
		--[[ One press covers both weapon slots, which is what frees the D-pad for
		     the consumables. From anything that is not a weapon it lands on the
		     primary: coming off a medkit you almost always want the rifle. ]]
		local current = selectedSlot()
		local target = if current == Enums.Slot.Primary then Enums.Slot.Secondary else Enums.Slot.Primary
		lastSelect.slot = target
		lastSelect.at = os.clock()
		Remotes.Event.SwitchSlot:FireServer(target)
		return
	end

	if action == Action.UseItem then
		--[[
			THE HEAL KEY MEANS HEAL.

			It used to send selectedSlot() and nothing else, which is the slot you
			are HOLDING — so pressing it with a rifle out sent "Primary", the
			server found no consumable in that slot and returned false, and
			absolutely nothing happened. No sound, no message, no heal. The only
			way to use a medkit was to press 4 first and then this, and a player
			who does not know that reasonably concludes the game will not let them
			heal at all.

			So the selected slot is honoured only when it is something this key
			could actually spend; otherwise it falls back to what the key is
			named after. Health before Pills, because a medkit is the deliberate
			choice and pills are the panic one — and because spending pills by
			accident while a medkit sits unused is the one wrong answer here.

			selectedSlot rather than activeSlot for the first test, still, and for
			the original reason: LA.ActiveSlot only moves once SwitchSlot has been
			to the server and back, so "4 then H" quickly enough would otherwise
			read the slot the player was on BEFORE they selected the kit.
		]]
		local slot = selectedSlot()
		if not CONSUMABLE_SLOTS[slot] or not slotHolds(slot) then
			if slotHolds(Enums.Slot.Health) then
				slot = Enums.Slot.Health
			elseif slotHolds(Enums.Slot.Pills) then
				slot = Enums.Slot.Pills
			end
		end
		Remotes.Event.UseItem:FireServer(slot)
	elseif action == Action.Throw then
		local origin, direction = cameraRay()
		Remotes.Event.ThrowItem:FireServer({ origin = origin, direction = direction, power = 1 })
	elseif action == Action.Ping then
		ping()
	elseif action == Action.Backpack then
		--[[ Opens only. Closing is the panel's own business: this binding is
		     unbound for as long as the panel is up — every screen in the game
		     suppresses InputController while it holds the cursor — so a toggle
		     here would be a key that opens and then cannot close. ]]
		local backpack = Registry.find("BackpackController")
		if backpack and typeof(backpack.open) == "function" then
			pcall(backpack.open, backpack)
		end
	elseif action == Action.Requisitions then
		-- Opens only, for the same reason. See above.
		local requisitions = Registry.find("RequisitionController")
		if requisitions and typeof(requisitions.open) == "function" then
			pcall(requisitions.open, requisitions)
		end
		return
	end

	--[[ The ability slots, matched on the verb's NAME rather than with a branch
	     each. A fourth slot is a key in ABILITY_KEYS and nothing here — and this
	     controller stays ignorant of what an ability is: it forwards a slot
	     number, and AbilityController decides whether that means "fire it" or
	     "start choosing a spot". ]]
	local slot = tonumber(string.match(action, "^Ability(%d+)$"))
	if slot then
		local abilities = Registry.find("AbilityController")
		if abilities and typeof(abilities.press) == "function" then
			pcall(abilities.press, abilities, slot)
		end
	end
end

-- ── binding ─────────────────────────────────────────────────────────────────

--[[
	Verbs the game is currently refusing by name, as opposed to `enabled`, which
	refuses all of them.

	One screen needs this: the pre-round requisition window. It is open while the
	team decides what to buy, and the whole point of that window is that nobody
	is under pressure — so a player should be able to walk to a gun and pick it
	up while reading, which switching the controller off entirely would prevent.
	What they must NOT be able to do is empty a magazine into the floor by
	clicking a BUY button, so the trigger is muted and movement is not.

	Checked in BOTH paths a verb can arrive by — the ContextActionService handler
	below and `raise`, which is how the touch pad's buttons get here. Muting one
	and not the other would leave a phone player firing from a screen a desktop
	player could not fire from.
]]
local muted: { [string]: boolean } = {}

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

		--[[ A muted verb still gets its RELEASE. Swallowing that would strand
		     whatever the press started — the same way the gamepad ability layer
		     used to strand a crouch — so only the Begin edge is refused. ]]
		if muted[binding.action] and state == Enum.UserInputState.Begin then
			return Enum.ContextActionResult.Sink
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

-- ── the gamepad ability layer ───────────────────────────────────────────────

--[[
	Abilities on a controller, without taking a button from anything.

	Every gamepad input this game has is spoken for — both triggers, both
	bumpers, four face buttons, both stick clicks, four D-pad directions — and
	Start belongs to Roblox. So abilities get a LAYER instead: hold the view
	button and the face buttons become ability slots for as long as you hold it.

	── WHY THE VIEW BUTTON IS THE ONE THAT CAN AFFORD IT ───────────────────────
	Making a button a modifier means its own verb can no longer fire on press —
	it has to wait for the release to find out whether you were holding it. For
	MELEE or SHOVE that is unacceptable: both are panic buttons and a fifth of a
	second of latency is a death. The view button opens the PAUSE MENU, which is
	the one thing on the pad where nobody can feel a delay, so it is the only
	honest donor.

	A tap still opens the pause menu, on release. A hold opens the layer and
	suppresses the tap, whether or not an ability was actually chosen — a player
	who held it, looked at their cards and let go had decided not to, and
	throwing a pause menu at them for that would be worse than doing nothing.

	── AND THE FACE BUTTONS ARE SUNK, NOT SHARED ───────────────────────────────
	These bind at a HIGHER ContextActionService priority than the ordinary
	keymap and return Pass while the layer is closed, so ButtonX is still reload
	and ButtonY is still interact for the whole time nobody is holding view. The
	instant the layer opens they return Sink, so holding view and pressing X
	fires an ability WITHOUT also reloading.
]]
local LAYER_KEY = Enum.KeyCode.ButtonSelect
local LAYER_FACE_KEYS = {
	Enum.KeyCode.ButtonX,
	Enum.KeyCode.ButtonY,
	Enum.KeyCode.ButtonA,
	Enum.KeyCode.ButtonB,
}

--[[ Above the ordinary bindings so the face buttons are seen first, and by
     enough that a future layer could sit between them. ]]
local LAYER_PRIORITY = PRIORITY + 100

--[[ How long the view button has to be down before it counts as a hold rather
     than a tap. Short enough that the layer feels instant, long enough that a
     deliberate tap on the pause menu is never mistaken for one. ]]
local LAYER_HOLD = 0.18

local layer = {
	down = false,
	downAt = 0,
	--[[ Set when the layer has done anything at all — opened, or fired — so the
	     release knows not to also open the pause menu. ]]
	consumed = false,
}

--[[ Which face buttons were sunk on their way DOWN, so their release can be
     answered the same way. See bindAbilityLayer: the layer can open or shut
     between the two edges, and a release answered differently from its press
     strands the action underneath it. ]]
local sunkFace: { [number]: boolean } = {}

--[[ Whether the modifier is being held long enough to count. Read on the face
     button PRESS rather than latched at the layer, so a press in the first
     fraction of a second still falls through to reload rather than being eaten
     by a layer the player has not opened yet. ]]
local function layerOpen(): boolean
	return layer.down and (os.clock() - layer.downAt) >= LAYER_HOLD
end

--[[
	True when the view button's release should be swallowed rather than opening
	the pause menu. PauseController asks this instead of opening on the PRESS,
	which is the whole of the coordination between the two.
]]
function InputController:consumedLayerTap(): boolean
	return layer.consumed
end

function InputController:isAbilityLayerOpen(): boolean
	return layerOpen()
end

local function bindAbilityLayer()
	ContextActionService:BindActionAtPriority(
		PREFIX .. "AbilityLayer",
		function(_name: string, state: Enum.UserInputState): Enum.ContextActionResult?
			if state == Enum.UserInputState.Begin then
				layer.down = true
				layer.downAt = os.clock()
				layer.consumed = false
			elseif state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
				--[[ A hold is consumed whether or not an ability was chosen. See
				     the header: letting go without picking one is a decision, and
				     answering it with a pause menu is the wrong answer. ]]
				if layerOpen() then
					layer.consumed = true
				end
				layer.down = false
			end
			--[[ Passed, always. PauseController still needs to see this button —
			     it is what opens the pause menu on a tap — and sinking it here
			     would leave a controller with no way into the menu at all. ]]
			return Enum.ContextActionResult.Pass
		end,
		false,
		LAYER_PRIORITY,
		LAYER_KEY
	)

	for index = 1, math.min(AbilityConfig.MaxSlots, #LAYER_FACE_KEYS) do
		ContextActionService:BindActionAtPriority(
			PREFIX .. "AbilityFace" .. index,
			function(_name: string, state: Enum.UserInputState): Enum.ContextActionResult?
				if state == Enum.UserInputState.Begin then
					--[[ Pass while the layer is shut, which is almost always. This
					     is what keeps ButtonX as reload and ButtonY as interact for
					     every player who never holds the view button. ]]
					if not layerOpen() then
						return Enum.ContextActionResult.Pass
					end
					--[[ LATCHED, and this is the whole reason the branch is on the
					     edge rather than on layerOpen() every time.

					     The layer can open or shut between a button going down and
					     coming back up, and re-asking would then answer the release
					     differently from the press. Both directions broke
					     something real: hold ButtonB to crouch, then hold view, and
					     the release was swallowed by a layer that was shut when the
					     press went through — leaving the player crouched at nine
					     studs a second with nothing holding the key. The same on
					     ButtonY left a revive begun and never cancelled.

					     Whatever the press was answered with, the release gets the
					     same answer. ]]
					sunkFace[index] = true
					layer.consumed = true
					if enabled and UserInputService:GetFocusedTextBox() == nil then
						forward("Ability" .. index)
					end
					return Enum.ContextActionResult.Sink
				end

				--[[ End and Cancel both settle the latch, so a button the game
				     never saw released — focus lost, controller unplugged — does
				     not leave it set for the next press. ]]
				if sunkFace[index] then
					sunkFace[index] = nil
					return Enum.ContextActionResult.Sink
				end
				return Enum.ContextActionResult.Pass
			end,
			false,
			LAYER_PRIORITY,
			LAYER_FACE_KEYS[index]
		)
	end
end

local function unbindAbilityLayer()
	ContextActionService:UnbindAction(PREFIX .. "AbilityLayer")
	for index = 1, #LAYER_FACE_KEYS do
		ContextActionService:UnbindAction(PREFIX .. "AbilityFace" .. index)
	end
	--[[ Unbinding cancels nothing, so a button held through a scheme change
	     never delivers its release edge. Cleared here or the latch would answer
	     the NEXT press's release with the last one's decision. ]]
	table.clear(sunkFace)
	layer.down = false
	layer.consumed = false
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
	if isDown and (not enabled or muted[action] or UserInputService:GetFocusedTextBox() ~= nil) then
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
		--[[ And crouch specifically, which the loop above cannot reach in toggle
		     mode: the key was tapped and released long ago, so nothing is `down`
		     while the player is very much still crouched. Without this, opening
		     the scoreboard with toggle crouch on left them stuck at eight studs a
		     second — the exact bug the synthesised release exists to prevent,
		     walking back in through the new door.

		     Toggle mode ONLY. In hold mode the loop above already fired the
		     release, and the attribute it would be tested against has not made the
		     round trip yet — so this fired a second, identical remote every time a
		     menu opened while crouched. ]]
		if crouchToggle and isCrouching() then
			Remotes.Event.SetCrouchState:FireServer(false)
		end
	end
end

--[[ Set from the settings panel. Standing up on the way through: flipping the
     rule while crouched would otherwise leave a held-mode player crouched with
     nothing holding the key, and the release edge that would have freed them
     already happened. ]]
--[[
	Re-states what this client is asking for, whenever the rule underneath it
	changes: at start-up, when the scheme moves, and when the toggle setting does.

	TOUCH ALWAYS SPRINTS. The pad is eight buttons wide on a five-inch screen and
	there is no room for a ninth, so a phone keeps the behaviour the whole game
	had before sprint became a key. That is not a concession — it is the reason
	the server's default is true: nobody loses a control they had.

	Hold mode restates from the key, because the default is true and a desktop
	player who has not touched Shift should be walking. Toggle mode is left alone:
	it is a choice the player made and re-asserting it would undo it.
]]
local function assertSprintWish()
	if scheme == Scheme.Touch then
		setSprintWish(true)
	elseif not sprintToggle then
		setSprintWish(down[Action.Sprint] == true)
	end
end

--[[ Set from the settings panel. Re-states the wish, because the meaning of the
     key just changed under the player's hand. ]]
function InputController:setSprintToggle(value: boolean)
	if sprintToggle == value then
		return
	end
	sprintToggle = value == true
	assertSprintWish()
end

function InputController:setCrouchToggle(value: boolean)
	if crouchToggle == value then
		return
	end
	crouchToggle = value == true
	if isCrouching() then
		Remotes.Event.SetCrouchState:FireServer(false)
	end
end

function InputController:isEnabled(): boolean
	return enabled
end

--[[
	Refuses a named set of verbs while leaving the rest alone.

	`actions` REPLACES the muted set rather than adding to it, so a screen that
	closes without cleaning up cannot leave the trigger dead for the rest of the
	round — passing nil or an empty list is how everything comes back, and that
	is the only call a caller has to remember.

	Anything already held goes down cleanly on the way in. A verb muted while its
	key is still pressed would otherwise never see its release.
]]
function InputController:setMuted(actions: { string }?)
	table.clear(muted)
	if actions then
		for _, action in actions do
			muted[action] = true
			if down[action] then
				setDown(action, false)
			end
		end
	end
end

-- ── lifecycle ───────────────────────────────────────────────────────────────

function InputController:init()
	for _, binding in BINDINGS do
		bind(binding)
	end
	--[[ After the ordinary keymap, though the priority is what actually decides
	     the order — see LAYER_PRIORITY. Bound unconditionally rather than only on
	     a gamepad: a player who picks a controller up mid-round should find it
	     already working, and the layer costs nothing while the view button is
	     not being held. ]]
	bindAbilityLayer()
	trove:add(function()
		for _, binding in BINDINGS do
			unbind(binding)
		end
		unbindAbilityLayer()
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
	--[[ And say what we want out of sprint, now that the scheme is known. Without
	     this a desktop player spawns sprinting — the server default is true, and
	     in hold mode nothing would contradict it until the first press. ]]
	assertSprintWish()
	trove:connect(UserInputService.LastInputTypeChanged, function(inputType: Enum.UserInputType)
		local implied = schemeFor(inputType)
		if implied then
			setScheme(implied)
			--[[ A player who picks up a controller or puts down a phone changes
			     which rule applies to them mid-round. ]]
			assertSprintWish()
		end
	end)
end

function InputController:destroy()
	trove:destroy()
end

Registry.register("InputController", InputController)

return InputController
