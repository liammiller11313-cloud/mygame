--!nonstrict
--[[
	TouchController — the on-screen pad, and only when a finger is driving.

	ContextActionService will draw touch buttons for you, and this file exists
	because what it draws is wrong for this game in three ways at once: round
	grey buttons that ignore the theme, fixed pixel offsets from the bottom-right
	corner — which is exactly where the ammo counter and the hotbar live, so they
	landed on top of the HUD — and no awareness of the viewport scale, so they
	were postage stamps on a tablet and covered a third of a phone.

	So the pad is drawn here, in the game's own language, inside the same scale
	layer everything else uses, and stacked up the RIGHT edge above the hotbar
	rather than over it. The left half of the screen belongs to Roblox's
	thumbstick and to looking around, and nothing here is allowed into it.

	── WHAT IT DOES NOT DO ──────────────────────────────────────────────────────
	It never decides what a verb means or whether it is legal. Every button calls
	InputController:raise(), which is the same path a trigger pull takes — the
	disabled check, the held-state bookkeeping and the remote all happen once, in
	one place, whether the input came from a finger or a mouse.

	── WHY THE HOTBAR BECOMES THE ITEM BUTTONS ──────────────────────────────────
	Five more buttons for the five slots would be five more things covering the
	screen. The hotbar is already on screen, already says what is in each slot,
	and is already in the corner a thumb can reach — so on touch its slots become
	tap targets. One tap selects, a second tap on a consumable uses it, which is
	the same press-again-to-use rule the D-pad follows on a controller.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Registry = require(Shared.Util.Registry)
local Trove = require(Shared.Util.Trove)
local UITheme = require(Shared.Config.UITheme)

local ScaleLayer = require(script.Parent.ScaleLayer)

local COLOR = UITheme.Color
local FONT = UITheme.Font
local LAYOUT = UITheme.Layout
local TEXT = UITheme.TextSize

--[[ Reference pixels, like everything else drawn in a scale layer. 64 is about
     9mm on a phone at the scale floor, which is the smallest target a thumb hits
     reliably while also being shot at. ]]
local BUTTON = 64
local BIG = 86 -- Fire only

--[[ Jump sits between the two. It is not a combat verb, so it does not get the
     trigger's size, but it was invisible at 64 among six identical grey circles
     — and it is the one button a player hunts for when a Hunter has them cornered
     against a crate. 76 reads as "different" at a glance without competing with
     the trigger for the corner. ]]
local JUMP_SIZE = 76

--[[ The ring is the whole of a circular button's edge, so it carries more of the
     read than a square one's border does and is drawn a little heavier. ]]
local RING_IDLE = 2
local RING_HELD = 3

--[[
	Where each button sits, as an offset from the pad's bottom-right corner.

	Explicit rather than computed from an index, because the arrangement is a
	THUMB ARC and not a grid. The bottom row is the sweep a right thumb makes
	without the hand moving — fire in the corner, then the two verbs you reach for
	mid-fight — and the row above it is a deliberate stretch for the two you have
	a moment to think about.

	The whole cluster is 230 x 158, which on a small phone is 26% of the width and
	32% of the height. The version this replaced filled two columns by index and
	came out 310 tall: half the screen, on the side the player is trying to see
	down.
]]
local PAD_LAYOUT: { [string]: { x: number, y: number, size: number, prominent: boolean? } } = {
	Fire = { x = 0, y = 0, size = BIG },
	Reload = { x = 94, y = 0, size = BUTTON },
	Aim = { x = 166, y = 0, size = BUTTON },
	Melee = { x = 22, y = 94, size = BUTTON },
	Shove = { x = 94, y = 94, size = BUTTON },
	Interact = { x = 166, y = 94, size = BUTTON },

	--[[ A third column, further from the corner than the rest. Jump and crouch
	     are movement rather than combat: wanted often enough to earn a button,
	     rarely enough that they should not sit where a thumb rests. Putting them
	     at the far edge of the arc is also what keeps them off the trigger.

	     Jump is the larger of the two and sits on the BOTTOM row, where the thumb
	     already travels, with crouch above it. They used to be the same size in
	     the same column and the wrong one was easier to hit: crouching by
	     accident while trying to clear a rail is a death, and jumping by accident
	     is nothing. ]]
	Jump = { x = 232, y = 0, size = JUMP_SIZE, prominent = true },
	Crouch = { x = 238, y = 94, size = BUTTON },
}

--[[ The pad is as wide as its leftmost button reaches. Jump is 76 at x=232, so
     308 — six wider than when both columns were 64. Written out rather than
     typed as a literal, because the last three times a button moved this number
     did not, and a pad narrower than its contents clips the far column on the
     platform least able to spare it. ]]
local PAD_WIDTH = 232 + JUMP_SIZE
local PAD_HEIGHT = 158

--[[ The pad clears the ammo counter, which sits above the hotbar in the same
     corner. Derived rather than typed: the ammo panel's own position is
     `ScreenMargin + hotbar height + gap` and its height is on top of that, so a
     hand-written inset here would silently start overlapping the first time
     either of those changed. The old one did — by eight pixels, which put the
     fire button on top of the magazine count. ]]
local BOTTOM_INSET = LAYOUT.ScreenMargin
	+ LAYOUT.HotbarSlotHeight
	+ LAYOUT.ElementGap
	+ LAYOUT.AmmoPanelHeight
	+ LAYOUT.ElementGap
	--[[ And the Dollars line, added to that corner after this sum was written.
	     It happened exactly as the note above predicted: the stack grew, this
	     was not updated with it, and the pad's bottom row came to rest on the
	     balance — 20 pixels of overlap, both right-aligned, on the platform with
	     the least room to spare. Every term here is a real element from
	     UITheme.Layout so the next addition moves the pad instead of landing
	     under it. ]]
	+ LAYOUT.WalletHeight
	+ LAYOUT.ElementGap

--[[ Verbs whose button only appears when the verb would do something. Interact
     is the only one: a permanent USE button is a permanent hole in the screen
     for something that is relevant for maybe fifteen seconds a round, and the
     button appearing IS the affordance — it says "there is something here"
     better than the prompt does. ]]
local CONTEXTUAL: { [string]: boolean } = {
	Interact = true,
}

local TouchController = {}

local player = Players.LocalPlayer
local trove = Trove.new()

local gui: ScreenGui
local root: Frame
local pad: Frame
type PadButton = {
	frame: TextButton,
	stroke: UIStroke,
	label: TextLabel,
	action: string,
	-- Shown only while its verb would do something. See refreshContextual.
	contextual: boolean,
}

local buttons: { PadButton } = {}

local state = {
	visible = false,
	enabled = true,
	cinematic = false,
}

-- ── construction ────────────────────────────────────────────────────────────

--[[ A pressed button fills and brightens rather than moving. A control that
     shifts under the thumb holding it is a control the thumb then has to chase,
     and on a touchscreen there is no cursor to re-find it with. ]]
--[[
	Every button already wears an orange ring — UITheme's BorderBright IS the
	accent — so "make it accent coloured" was not available as a way to pick one
	out. Jump is distinguished by FILL instead: a dark accent wash behind it at
	roughly half the transparency of the others, which reads as a different
	KIND of control at a glance rather than the same control shouting.

	It does not compete with the trigger. Fire is bigger and it is in the corner,
	and a corner is an identity no amount of colour takes away.
]]
local function paint(entry, held: boolean)
	local prominent = entry.prominent == true
	if held then
		entry.frame.BackgroundTransparency = 0.1
	else
		entry.frame.BackgroundTransparency = if prominent then 0.22 else 0.45
	end
	entry.frame.BackgroundColor3 = if prominent and not held then COLOR.AccentDim else COLOR.Panel
	entry.stroke.Color = if held then COLOR.AccentBright else COLOR.BorderBright
	entry.stroke.Thickness = if held or prominent then RING_HELD else RING_IDLE
	entry.label.TextColor3 = if held then COLOR.AccentBright else COLOR.TextPrimary
end

local function newButton(action: string, label: string, size: number, prominent: boolean?): any
	local frame = Instance.new("TextButton")
	frame.Name = action
	frame.AutoButtonColor = false
	frame.Text = ""
	frame.BackgroundColor3 = COLOR.Panel
	frame.BorderSizePixel = 0
	frame.Size = UDim2.fromOffset(size, size)
	frame.Parent = pad

	--[[ Round, not square. The rest of this interface is deliberately hard-edged
	     — Left 4 Dead's HUD has no rounded corners anywhere — but a touch control
	     is the one place that rule loses to the hand: a thumb's contact patch is
	     a circle, so a circular target is the shape whose whole area is reachable
	     without looking. Half the button's size is a full circle at any size. ]]
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0)
	corner.Parent = frame

	local stroke = Instance.new("UIStroke")
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Thickness = RING_IDLE
	stroke.Color = COLOR.BorderBright
	stroke.Parent = frame

	local text = Instance.new("TextLabel")
	text.Name = "Label"
	text.BackgroundTransparency = 1
	text.Size = UDim2.fromScale(1, 1)
	text.Font = FONT.Heading
	text.TextSize = TEXT.Tiny
	text.TextColor3 = COLOR.TextPrimary
	text.Text = label
	text.TextScaled = true
	text.Parent = frame

	local bounds = Instance.new("UITextSizeConstraint")
	bounds.MaxTextSize = TEXT.Small
	bounds.MinTextSize = TEXT.Tiny
	bounds.Parent = text

	--[[ 10%, not more. At 18% the inner box on a 64px button is 41 wide, and
	     "RELOAD" needs 43 even at the minimum text size — it clipped, because
	     TextScaled will not go below a UITextSizeConstraint's floor and the label
	     does not wrap. The longest label in the pad is what sets this number. ]]
	local padding = Instance.new("UIPadding")
	local inset = UDim.new(0, math.floor(size * 0.10))
	padding.PaddingTop, padding.PaddingBottom = inset, inset
	padding.PaddingLeft, padding.PaddingRight = inset, inset
	padding.Parent = text

	local entry = {
		frame = frame,
		stroke = stroke,
		label = text,
		action = action,
		contextual = false,
		prominent = prominent == true,
	}
	paint(entry, false)

	--[[ InputBegan/Ended on the button rather than Activated. Activated only
	     fires on release, which would make holding the trigger impossible: FIRE
	     and AIM are held verbs, and a fire button you have to tap once per round
	     is not a fire button. ]]
	trove:connect(frame.InputBegan, function(input: InputObject)
		if input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end
		local input_ = Registry.find("InputController")
		if input_ and input_:raise(action, true) then
			paint(entry, true)
		end
	end)

	local function release(input: InputObject)
		if input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end
		local input_ = Registry.find("InputController")
		if input_ then
			input_:raise(action, false)
		end
		paint(entry, false)
	end
	trove:connect(frame.InputEnded, release)

	table.insert(buttons, entry)
	return entry
end

local function build()
	gui = Instance.new("ScreenGui")
	gui.Name = "FL_Touch"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	--[[ Under the menu and the vote, above the HUD. A button the player can press
	     while a results screen is up would be a button pressed by accident. ]]
	gui.DisplayOrder = UITheme.DisplayOrder.Hud + 2
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Enabled = false
	gui.Parent = player:WaitForChild("PlayerGui")
	trove:add(gui)

	root = ScaleLayer.new(gui, "Scaled")

	pad = Instance.new("Frame")
	pad.Name = "Pad"
	pad.AnchorPoint = Vector2.new(1, 1)
	pad.Position = UDim2.new(1, -LAYOUT.ScreenMargin, 1, -BOTTOM_INSET)
	pad.BackgroundTransparency = 1
	pad.Size = UDim2.fromOffset(PAD_WIDTH, PAD_HEIGHT)
	pad.Parent = root

	--[[ The keymap says which verbs earn a button; PAD_LAYOUT says where each one
	     goes. A verb marked for touch with no entry in the layout is skipped
	     rather than stacked at the origin — an unplaced button hiding under the
	     fire button is worse than a missing one. ]]
	local input = Registry.find("InputController")
	if not input or typeof(input.getBindings) ~= "function" then
		return
	end

	for _, binding in input:getBindings() do
		local place = binding.touch and PAD_LAYOUT[binding.action]
		if place then
			local entry = newButton(binding.action, binding.touch, place.size, place.prominent)
			entry.frame.AnchorPoint = Vector2.new(1, 1)
			entry.frame.Position = UDim2.new(1, -place.x, 1, -place.y)
			entry.contextual = CONTEXTUAL[binding.action] == true
			if entry.contextual then
				entry.frame.Visible = false
			end
		end
	end
end

-- ── visibility ──────────────────────────────────────────────────────────────

--[[
	Shows the contextual buttons only while their verb would do something.

	Polled from a RenderStepped rather than pushed, because what it is asking —
	"does PromptController have a target right now" — is itself recomputed every
	frame from a raycast, and an event for it would be an event that fires every
	frame. The work is one method call and a boolean compare unless the answer
	changed.

	The button appearing is the affordance. It says "there is something here"
	more directly than the prompt text does, and a USE button that is on screen
	permanently is a permanent hole in the view for something relevant maybe
	fifteen seconds a round.
]]
local function refreshContextual()
	if not gui or not gui.Enabled then
		return
	end
	local prompt = Registry.find("PromptController")
	local live = false
	if prompt and typeof(prompt.getVerb) == "function" then
		local ok, verb = pcall(prompt.getVerb, prompt)
		live = ok and typeof(verb) == "string" and verb ~= ""
	end

	for _, entry in buttons do
		if entry.contextual and entry.frame.Visible ~= live then
			entry.frame.Visible = live
			if not live then
				--[[ Released on the way out. A finger still down on a button that
				     vanishes never delivers its InputEnded, and the verb would
				     stay held for the rest of the round. ]]
				local input = Registry.find("InputController")
				if input then
					input:raise(entry.action, false)
				end
				paint(entry, false)
			end
		end
	end
end

local function refresh()
	if not gui then
		return
	end
	local input = Registry.find("InputController")
	local touch = input and typeof(input.isTouchScheme) == "function" and input:isTouchScheme()
	state.visible = touch == true

	gui.Enabled = state.visible and state.enabled and not state.cinematic
	if not gui.Enabled then
		--[[ A pad that vanishes mid-press leaves the verb held forever, because
		     the button that would have raised the release is gone. Everything is
		     let go on the way out. ]]
		for _, entry in buttons do
			if input then
				input:raise(entry.action, false)
			end
			paint(entry, false)
		end
	end
end

-- ── public API ──────────────────────────────────────────────────────────────

--[[ Hidden while a menu, a vote or a results card owns the screen. Mirrors the
     HUD's own two switches so the pad and the HUD are never half-present. ]]
function TouchController:setVisible(value: boolean)
	state.enabled = value
	refresh()
end

function TouchController:setCinematic(value: boolean)
	state.cinematic = value
	refresh()
end

--[[
	Takes Roblox's own jump button off the screen.

	The thumbstick is deliberately LEFT ALONE: Roblox's handles multitouch and
	dead zones better than a reimplementation would, and it lives bottom-left
	where nothing here goes.

	The jump button is a different story. Roblox draws it in the bottom-RIGHT,
	which is exactly where this pad anchors — AnchorPoint (1, 1) against the
	bottom-right corner — so the player got two jump affordances, one of them
	sitting on the trigger. Two comments in this codebase used to describe this,
	in two files, saying OPPOSITE things: InputController claimed "TouchController
	hides Roblox's", and this function claimed the pad "is careful to stay out of"
	that corner. Neither was true. The pad is in that corner and nothing hid
	anything.

	── WHY IT IS NOT A SINGLE Visible = false ──────────────────────────────────
	Three things fight it, and all three are normal:

	  * the TouchGui does not exist yet when this runs on a fresh join;
	  * Roblox rebuilds it when the character respawns;
	  * its own TouchJump module sets Visible back to true whenever the humanoid
	    becomes able to jump, which is every landing.

	So it is a sweep, a watch for it being added, and a guard on the property
	itself. The guard costs nothing when nobody is writing to it — it fires only
	on a change, and the only writer is a module that touches it on state
	transitions.

	Every lookup is FindFirstChild against names that belong to Roblox rather
	than to us. If they ever rename these, this quietly does nothing, which is
	the correct failure: a duplicate jump button is a blemish, and an error
	thrown from start() would take the whole touch HUD down with it.
]]
local function suppressRobloxJump()
	local playerGui = player:FindFirstChildOfClass("PlayerGui")
	if not playerGui then
		return
	end

	local function hide(button: Instance)
		if not button:IsA("GuiObject") then
			return
		end
		button.Visible = false
		trove:connect(button:GetPropertyChangedSignal("Visible"), function()
			if button.Visible then
				button.Visible = false
			end
		end)
	end

	local function consider(instance: Instance)
		if instance.Name ~= "JumpButton" then
			return
		end
		--[[ Scoped to Roblox's TouchGui rather than hiding anything anywhere
		     called JumpButton, so a button of ours by that name is never eaten. ]]
		local ancestor = instance.Parent
		while ancestor and ancestor ~= playerGui do
			if ancestor.Name == "TouchGui" then
				hide(instance)
				return
			end
			ancestor = ancestor.Parent
		end
	end

	for _, descendant in playerGui:GetDescendants() do
		consider(descendant)
	end
	trove:connect(playerGui.DescendantAdded, consider)
end

function TouchController:isShowing(): boolean
	return gui ~= nil and gui.Enabled
end

function TouchController:init()
	build()
end

function TouchController:start()
	local input = Registry.find("InputController")
	if input and input.schemeChanged then
		trove:add(input.schemeChanged:connect(refresh))
	end

	suppressRobloxJump()

	trove:connect(RunService.RenderStepped, refreshContextual)

	refresh()
end

function TouchController:destroy()
	trove:destroy()
	table.clear(buttons)
end

Registry.register("TouchController", TouchController)

return TouchController
