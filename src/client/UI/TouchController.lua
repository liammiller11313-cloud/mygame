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
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attributes = require(Shared.Net.Attributes)
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

	--[[
		── THE ABILITIES, AND WHY THEY WERE NOT HERE ───────────────────────────
		InputController marks both ability slots `touch = "ABILITY n"`, and its
		own comment says "Touch gets real buttons: see `touch`, which
		TouchController draws". It did not. This table is the other half of that
		sentence and had no rows for them, and the loop below deliberately skips
		any verb marked for touch with nowhere to put it — so that an unplaced
		button cannot end up stacked under the fire button.

		The result was that NO ability was reachable on a phone. Not the walrus,
		not the shield, not any of the six: a mobile player could buy one, equip
		it, watch its cooldown tick down on the HUD, and never once press it.

		── A THIRD ROW, AND ONLY WHEN IT IS EARNED ─────────────────────────────
		Above the other two rather than beside them. An ability is on a five
		minute cooldown and is a decision, so it must not sit in the arc a thumb
		RESTS in — a mis-press beside the trigger costs five minutes, which is the
		most expensive accidental tap in the game. The stretch is the point, the
		same way jump and crouch are a deliberate reach.

		Each is drawn only while its slot actually holds something. A player with
		no abilities gets the pad exactly as it was, which is most players and
		every new one; it grows only for somebody with something to press.
	]]
	Ability1 = { x = 94, y = 188, size = BUTTON },
	Ability2 = { x = 166, y = 188, size = BUTTON },

	--[[
		SPECIAL — the verb an ability gives you while it is running.

		On the same top row as the two abilities and for the same reason: it is a
		deliberate press, not a reflex, and it must not sit in the arc a thumb
		rests in. Left of them, on its own, because it is not a third ability —
		it belongs to whichever one is currently up.

		Drawn only while the player IS something. A survivor sees the pad exactly
		as it was; a walrus grows one button. That is the same rule the two
		ability buttons follow, with a different question asked.
	]]
	Special = { x = 22, y = 188, size = BUTTON },
}

--[[ The pad is as wide as its leftmost button reaches. Jump is 76 at x=232, so
     308 — six wider than when both columns were 64. Written out rather than
     typed as a literal, because the last three times a button moved this number
     did not, and a pad narrower than its contents clips the far column on the
     platform least able to spare it. ]]
local PAD_WIDTH = 232 + JUMP_SIZE
--[[ Three rows now: the top one is the abilities. Written as the row's own
     offset plus a button rather than as a typed 252, for the same reason the
     width above is written out — the last three times a button moved, a
     hand-written total did not. ]]
local PAD_HEIGHT = 188 + BUTTON

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
--[[
	The context button: USE when there is something to use, PING otherwise.

	It was USE alone, hidden whenever PromptController had no target — on the
	reasoning that a permanent USE button is a permanent hole in the screen for
	something relevant maybe fifteen seconds a round. That reasoning was right and
	the hole was real; the answer is to put something in it rather than to leave
	it empty.

	PING is what goes there, because a phone player could not communicate AT ALL.
	Ping has no pad button and no slot tile, the pad is already eight buttons wide
	on a five-inch screen, and typing in Roblox chat mid-horde is not a thing
	anybody does with two thumbs occupied. In a co-op game whose own briefing ends
	"NOBODY SURVIVES ALONE", the mobile half of the server was mute.

	The two never compete: PromptController only reports a verb when the player is
	looking at something they can act on, and in that moment USE is unambiguously
	what the button is for. Every other moment it is a callout.
]]
local CONTEXTUAL: { [string]: boolean } = {
	Interact = true,
}

--[[ What the context button becomes when its primary verb has no target, and
     what to call it. Nil for a contextual button with no fallback — that one
     still simply hides. ]]
local CONTEXT_FALLBACK: { [string]: { action: string, label: string } } = {
	Interact = { action = "Ping", label = "PING" },
}

local TouchController = {}

local player = Players.LocalPlayer

--[[
	Verbs whose button stays lit after the finger comes off it.

	Crouch, and only crouch: with TOGGLE CROUCH on it is a tap, so the finger
	leaving the button means nothing about whether the player is crouched. The
	button unlit itself on release and left them crouched with no lit control
	anywhere on screen — on the one platform where the toggle is worth having,
	because holding a virtual button down while also steering and shooting is
	what the setting exists to avoid.

	Painted from the server's own IsCrouching attribute rather than from anything
	this file remembers. That is right in HOLD mode too — the server drops crouch
	by itself whenever the body stops being upright, so a button mirroring the
	finger was already lying every time a player crouch-walked off a ledge.
]]
--[[ How often the button states are re-read. See the note on the connection. ]]
local STATE_INTERVAL = 1 / 15

local LATCHED: { [string]: boolean } = {
	Crouch = true,
	Aim = true,
}

--[[
	Verbs that a TAP switches on and the next tap switches off, rather than ones
	that follow the finger.

	── AIM, BECAUSE HOLDING IT IS NOT POSSIBLE ─────────────────────────────────
	On a mouse, aim is held: the hand that holds it is not the hand that moves or
	shoots. On a phone the same thumb does all three. Aiming down the sights
	meant pinning a thumb to a 64-pixel circle in the bottom-right corner — which
	is the thumb that also steers the camera — so a mobile player could aim, or
	they could look at what they were aiming at, and not both. The sights were
	effectively unavailable on the platform.

	Crouch is here too, but it arrives by a different road and keeps it: crouch
	is a toggle in the SETTINGS and InputController owns that. This table is only
	about the touch pad, so crouch is not in it — its button already latches
	because the setting makes the verb behave that way underneath.
]]
local TOGGLE: { [string]: boolean } = {
	Aim = true,
}

--[[
	Whether a latched verb is currently ON, asked of whoever actually knows.

	Never of anything this file remembers, and that is the whole design. The
	server drops crouch by itself the moment the body stops being upright, and
	WeaponController drops the sights by itself when the player sprints or goes
	down — neither of them tells the input layer, and neither of them should have
	to. A button mirroring its own last press would be lying within seconds.

	Asking the truth instead makes the button self-heal: it unlights when the
	verb ends for a reason nobody pressed, and the next tap does the right thing
	because it is reading the same answer.
]]
--[[ Which ability slot a pad button drives, or nil. Parsed from the action name
     rather than listed, so a third slot needs a key in InputController and a
     place in PAD_LAYOUT and nothing here. ]]
local function abilitySlotOf(action: string): number?
	local index = string.match(action, "^Ability(%d+)$")
	return if index then tonumber(index) else nil
end

--[[ Whether that slot actually holds something. Asked of the profile, which is
     the only thing that knows — an ability is equipped in the menu and the pad
     has no memory of it. A button for an empty slot is a button that refuses
     every press, and on the platform with the least room to spare. ]]
--[[ Whether the SPECIAL button has anything to do, which today means "are you
     a walrus". Read off the server's own attribute rather than from anything
     local — the same one WalrusController draws its panel from, so the button
     and the panel can never disagree about whether you are an animal. ]]
local function specialAvailable(): boolean
	return Players.LocalPlayer:GetAttribute(Attributes.Player.IsWalrus) == true
end

local function slotFilled(slot: number): boolean
	local store = Registry.find("ProfileController")
	if not store or typeof(store.getAbilitySlots) ~= "function" then
		return false
	end
	local ok, slots = pcall(store.getAbilitySlots, store)
	if not ok or typeof(slots) ~= "table" then
		return false
	end
	local id = slots[slot]
	return typeof(id) == "string" and id ~= ""
end

local function latchedState(action: string): boolean
	if action == "Crouch" then
		return Attributes.get(player, Attributes.Player.IsCrouching, false) == true
	end
	if action == "Aim" then
		local weapon = Registry.find("WeaponController")
		if not weapon or typeof(weapon.isAiming) ~= "function" then
			return false
		end
		local ok, aiming = pcall(weapon.isAiming, weapon)
		return ok and aiming == true
	end
	return false
end
local trove = Trove.new()

local gui: ScreenGui
local root: Frame
local pad: Frame
type PadButton = {
	frame: TextButton,
	stroke: UIStroke,
	label: TextLabel,
	action: string,
	-- Shown only while its verb would do something. See refreshState.
	contextual: boolean,
	-- Drawn heavier, and never fully dimmed. Fire and Jump.
	prominent: boolean,
	-- What the state sweep last painted a LATCHED button. See LATCHED.
	lit: boolean,
	-- The touch currently holding this button down. See newButton's InputBegan.
	held: InputObject?,
	--[[ For a contextual button: the verb it is when its target exists, and that
	     verb's label. `action` swaps between this and CONTEXT_FALLBACK. ]]
	primary: string?,
	primaryLabel: string?,
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

--[[
	Lets a button's verb go, whoever is asking.

	One place, because a held verb has three ways to end and every one of them
	has to clear the SAME three things — the remembered touch, the server-facing
	action, and the paint. The touch lifting is the ordinary one; the other two
	are a contextual button being taken off screen under a finger, and the whole
	pad being hidden by a menu. Both of those already raised the release; neither
	cleared `held`, so the next InputBegan on that button would have seen it as
	still occupied and refused to press it at all.
]]
local function releaseEntry(entry, force: boolean?)
	entry.held = nil
	--[[ A toggled verb does not follow the finger. Lifting off AIM says nothing
	     about whether the player still wants the sights — that is what the next
	     tap is for — so an ordinary release leaves the verb alone.

	     `force` is the pad going AWAY, and that is different in kind: the button
	     that would switch the verb back off is about to stop existing. A player
	     who opens a menu mid-aim and comes back to find the sights still up and
	     nothing on screen saying so is the crouch bug this file already fixed
	     once, wearing the other verb. ]]
	if force or not TOGGLE[entry.action] then
		local input = Registry.find("InputController")
		if input then
			input:raise(entry.action, false)
		end
	end
	--[[ A latched button is left alone: the finger coming off crouch says nothing
	     about whether the player is crouched, and the state sweep owns it.
	     Painting false here and letting the sweep light it again a tick later
	     would be a flicker on every tap. ]]
	if not LATCHED[entry.action] then
		paint(entry, false)
	end
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
		--[[ What the state sweep last painted a LATCHED button, so it writes only
		     when the answer moves. Meaningless for every other button. ]]
		lit = false,
		--[[ The touch that is currently holding this button down, or nil. See the
		     note on InputBegan: the finger owns the verb, not the button. ]]
		held = nil :: InputObject?,
	}
	paint(entry, false)

	--[[
		InputBegan on the button rather than Activated. Activated only fires on
		release, which would make holding the trigger impossible: FIRE and AIM are
		held verbs, and a fire button you have to tap once per round is not a fire
		button.

		── THE FINGER OWNS THE VERB, NOT THE BUTTON ────────────────────────────
		The release used to be frame.InputEnded, and that is the bug that made
		mobile unplayable. A GuiObject fires InputEnded when the touch LEAVES ITS
		BOUNDS as well as when the finger lifts — so on a 64-pixel circle under a
		thumb that is also steering, the verb was released every time the contact
		patch drifted a few pixels.

		FIRE survived it: you press it again a third of a second later and never
		notice. A HOLD did not. Reviving a teammate is several seconds of keeping
		one verb down, and every micro-drift cancelled it and sent CancelInteract —
		so a player could stand over a downed teammate with the prompt on screen,
		press USE, and simply never revive them. That is "mobile players can't
		interact", and it was never the button being unreachable.

		So the touch is remembered and released from UserInputService.InputEnded,
		which fires for that exact InputObject when the FINGER actually lifts,
		wherever it has wandered to by then.
	]]
	trove:connect(frame.InputBegan, function(input: InputObject)
		if input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end
		--[[ One finger at a time per button. A second touch landing on a button
		     already held would overwrite the InputObject being watched for, and
		     the first finger's lift would then never release the verb. ]]
		if entry.held then
			return
		end
		local input_ = Registry.find("InputController")
		if not input_ then
			return
		end
		--[[ entry.action, not the captured `action`: the contextual button changes
		     which verb it is at runtime. See CONTEXTUAL below. ]]
		if TOGGLE[entry.action] then
			--[[
				A tap switches the verb, and which way is decided by what is
				actually true rather than by what was last asked for. See
				latchedState.

				The re-press is not belt and braces. InputController's `down` is
				edge-gated — raise(true) against an input it already believes is
				down returns having done nothing — and the two DO come apart:
				sprinting cancels the sights and being knocked down cancels them,
				neither of which goes anywhere near the input layer. That is
				correct for a mouse, where letting go and pressing again is the
				fix and costs nothing. On a toggle it would be permanent: the
				button would stop aiming for the rest of the round, and no amount
				of tapping would bring it back. Clearing first makes the press an
				edge again.
			]]
			local wasOn = latchedState(entry.action)
			input_:raise(entry.action, false)
			if not wasOn then
				input_:raise(entry.action, true)
			end
			--[[ Remembered so the finger lifting still clears the button's own
			     state, and so a second finger cannot land on it mid-press. The
			     verb itself is not released with it — see releaseEntry. ]]
			entry.held = input
			--[[
				Painted to the state the tap just ASKED for, not to the state
				re-read from the verb.

				Re-reading would answer the old value: raise fires its signal
				through Signal, which spawns each handler on its own thread, so
				setAiming has not run by the time raise returns. And waiting for
				the state sweep instead is a fifteenth of a second of a button
				that looks like it ignored a tap.

				`lit` moves with it so the sweep agrees rather than immediately
				repainting, and if the verb was refused — a menu is open, the
				input is muted — the sweep corrects this a tick later from the
				truth.
			]]
			entry.lit = not wasOn
			paint(entry, entry.lit)
			return
		end
		if input_:raise(entry.action, true) then
			entry.held = input
			paint(entry, true)
		end
	end)

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
			--[[ Hidden until the state sweep says otherwise, a fifteenth of a
			     second from now. The alternative is two dead buttons on screen for
			     the first frame of every round. ]]
			if abilitySlotOf(binding.action) or binding.action == "Special" then
				entry.frame.Visible = false
			end
			entry.contextual = CONTEXTUAL[binding.action] == true
			if entry.contextual then
				--[[ What this button is when its verb HAS a target. `entry.action`
				     moves between this and the fallback; these two do not. ]]
				entry.primary = binding.action
				entry.primaryLabel = binding.touch
				--[[ A button with a fallback starts on the fallback rather than
				     hidden: there is always something to ping. ]]
				local fallback = CONTEXT_FALLBACK[binding.action]
				if fallback then
					entry.action = fallback.action
					entry.label.Text = fallback.label
				else
					entry.frame.Visible = false
				end
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
local function refreshState()
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
		--[[
			A held touch whose InputObject has already finished.

			The backstop to the UserInputService watcher, and it is worth having
			because the failure it covers is the worst one this file can produce: a
			verb held forever. The watcher covers the finger lifting; this covers a
			touch that ends without one arriving — the GUI being torn down under
			it, or the OS taking the input away mid-press.

			Roblox marks the InputObject itself once it is done, so this is one
			property read per held button, fifteen times a second, and it turns
			"stuck for the rest of the round" into "stuck for one tick".
		]]
		local held = entry.held
		if
			held
			and (
				held.UserInputState == Enum.UserInputState.End
				or held.UserInputState == Enum.UserInputState.Cancel
			)
		then
			releaseEntry(entry)
		end

		--[[ An ability button exists only while its slot holds something — see
		     PAD_LAYOUT. Released on the way out, because a slot emptied under a
		     finger would otherwise leave the verb held with no button left to
		     raise it. ]]
		local slot = abilitySlotOf(entry.action)
		if slot or entry.action == "Special" then
			local wanted = if slot then slotFilled(slot) else specialAvailable()
			if entry.frame.Visible ~= wanted then
				if not wanted then
					releaseEntry(entry)
				end
				entry.frame.Visible = wanted
			end
		end

		--[[ Crouch, painted from the server's own answer rather than from the
		     finger. See LATCHED. ]]
		if LATCHED[entry.action] then
			local lit = latchedState(entry.action)
			if entry.lit ~= lit then
				entry.lit = lit
				paint(entry, lit)
			end
		end
		if entry.contextual then
			local fallback = CONTEXT_FALLBACK[entry.primary or entry.action]
			if fallback then
				--[[ Never hidden — it swaps verb instead. See CONTEXT_FALLBACK. ]]
				local wanted = if live then entry.primary else fallback.action
				local wantedLabel = if live then entry.primaryLabel else fallback.label
				if entry.action ~= wanted then
					--[[ Let go of the OLD verb before becoming the new one. A finger
					     down on USE at the instant the target goes out of range would
					     otherwise leave Interact held for the rest of the round, and
					     the release would be sent for Ping instead. ]]
					releaseEntry(entry)
					entry.action = wanted
					entry.label.Text = wantedLabel
				end
				if not entry.frame.Visible then
					entry.frame.Visible = true
				end
			elseif entry.frame.Visible ~= live then
				entry.frame.Visible = live
				if not live then
					--[[ Released on the way out. A finger still down on a button that
					     vanishes never delivers its InputEnded, and the verb would
					     stay held for the rest of the round. ]]
					releaseEntry(entry)
				end
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
			releaseEntry(entry, true)
			--[[ Cleared with the paint, or the state sweep would compare against a
			     lit it no longer matches and decline to light crouch again when the
			     pad comes back. ]]
			entry.lit = false
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

	--[[ One guard at a time. Roblox rebuilds the TouchGui on every respawn, and
	     a fresh connection per rebuild would leave the trove holding one dead
	     connection per death for the length of the round. Bounded rather than
	     large, but there is no reason to hold any: only the CURRENT button can
	     be shown, so only the current one needs watching. ]]
	local guard: RBXScriptConnection? = nil
	trove:add(function()
		if guard then
			guard:Disconnect()
			guard = nil
		end
	end)

	local function hide(button: Instance)
		if not button:IsA("GuiObject") then
			return
		end
		if guard then
			guard:Disconnect()
		end
		button.Visible = false
		guard = button:GetPropertyChangedSignal("Visible"):Connect(function()
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

	--[[ The finger lifting anywhere on the screen, which is the only thing that
	     genuinely ends a held touch verb. Matched by InputObject identity, so a
	     second finger elsewhere on the pad releases only its own button. See the
	     note on InputBegan for why the button's own InputEnded cannot be used. ]]
	trove:connect(UserInputService.InputEnded, function(input: InputObject)
		if input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end
		for _, entry in buttons do
			if entry.held == input then
				releaseEntry(entry)
			end
		end
	end)

	suppressRobloxJump()

	--[[
		Polled, but not every frame.

		What it asks changes far slower than the screen redraws: PromptController
		recomputes its target on a 0.1s scan, and crouch is a server attribute that
		moves when a thumb does. Sixty times a second was six wasted passes out of
		seven — each one a Registry lookup and a pcall — on the one platform in the
		game with a battery and a thermal limit.

		Fifteen is under a frame and a half of latency on a button appearing, which
		nobody can see, and it is still four times faster than the data behind it
		actually changes.
	]]
	local sinceState = 0
	trove:connect(RunService.RenderStepped, function(dt: number)
		sinceState += dt
		if sinceState < STATE_INTERVAL then
			return
		end
		sinceState = 0
		refreshState()
	end)

	refresh()
end

function TouchController:destroy()
	trove:destroy()
	table.clear(buttons)
end

Registry.register("TouchController", TouchController)

return TouchController
