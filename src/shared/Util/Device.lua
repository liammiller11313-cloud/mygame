--!nonstrict
--[[
	Device — what kind of machine is this, and what should it be asked to draw.

		local Device = require(Shared.Util.Device)

		local budget = Device.pick({ Mobile = 24, Console = 60 }, 90)
		if Device.isHandheld() then ... end
		Device.changed:connect(function(class) ... end)

	── WHY THIS IS A MODULE AND NOT THREE LINES IN EACH FILE ────────────────────
	It WAS three lines in each file. GoreController had a private deviceClass()
	and used it to scale gib and decal budgets, which is real work — and it was
	the only thing in the entire client that knew it was on a phone. Lights,
	highlights, particles, the pose loop and the viewmodel all ran at desktop cost
	on a handset, because there was nothing to ask.

	InputController has the same three checks answering a different question
	(which control scheme to draw), and that one stays where it is: it is about
	what the player is holding, not about what the GPU can push, and the two
	genuinely diverge on a laptop with a touchscreen.

	── WHY IT IS LAZY, AND WHY THAT IS THE BUG FIX ─────────────────────────────
	The old copy ran at module scope and froze its answer for the session. Two
	things break under that:

	  * A phone with a Bluetooth keyboard paired reported Desktop — the test was
	    `TouchEnabled and not KeyboardEnabled` — and reported it FOREVER, so the
	    player who most needs the low budget got the high one. The test here is
	    `TouchEnabled and not MouseEnabled` instead: a desktop has a mouse, a
	    phone does not, and a keyboard says nothing about either.
	  * Telling a phone from a tablet needs the viewport, and at module scope the
	    camera does not exist yet. This codebase documents that trap twice
	    already.

	So the class is computed on first ask, cached, and recomputed when the
	hardware picture changes. `changed` fires when the answer actually moves,
	which is what lets a budget set at start-up correct itself.
]]

local GuiService = game:GetService("GuiService")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Signal = require(script.Parent.Signal)

local Device = {}

--[[ Four, and the split that matters is HANDHELD vs not. Tablet exists as its
     own class rather than being folded into Mobile because an iPad has a real
     GPU and four times the screen: giving it a phone's budget wastes it, and
     giving it a desktop's does not fit. ]]
Device.Class = table.freeze({
	Desktop = "Desktop",
	Console = "Console",
	Tablet = "Tablet",
	Mobile = "Mobile",
})

--[[ Screen diagonal, in pixels, above which a touch device is a tablet. A phone
     in landscape is around 900x400; an iPad is 1180x820. The diagonal is used
     rather than either axis alone because orientation must not change the
     answer, and a player who rotates their phone has not bought new hardware. ]]
local TABLET_DIAGONAL = 1150

Device.changed = Signal.new()

local cached: string? = nil

local function detect(): string
	--[[ Definitive, and checked first for that reason: a console reports touch
	     for its companion app and would otherwise fall through to a handheld
	     answer. ]]
	if GuiService:IsTenFootInterface() then
		return Device.Class.Console
	end

	--[[ MouseEnabled, not KeyboardEnabled. See the header: a paired keyboard is
	     the single most common way a phone got called a desktop. A Surface or a
	     touchscreen laptop has both, and lands on Desktop, which is the right
	     answer for a budget even though it is a touch device. ]]
	if UserInputService.TouchEnabled and not UserInputService.MouseEnabled then
		local camera = Workspace.CurrentCamera
		if not camera then
			--[[ Asked before the camera exists. Answer Mobile rather than guess
			     upward — the cost of under-drawing on a tablet for a moment is a
			     slightly plain frame, and the cost of over-drawing on a phone is
			     the frame rate. It is not cached, so the next ask is correct. ]]
			return Device.Class.Mobile
		end
		local size = camera.ViewportSize
		local diagonal = math.sqrt(size.X * size.X + size.Y * size.Y)
		return if diagonal >= TABLET_DIAGONAL then Device.Class.Tablet else Device.Class.Mobile
	end

	return Device.Class.Desktop
end

--[[ This machine's class. Cached after the first confident answer; see `detect`
     for the one case that deliberately declines to cache. ]]
function Device.get(): string
	if cached then
		return cached
	end
	local class = detect()
	--[[ Not cached when the camera was missing, because that answer is a floor
	     rather than a measurement and the next caller can do better. ]]
	if class == Device.Class.Mobile and not Workspace.CurrentCamera then
		return class
	end
	cached = class
	return class
end

--[[ Recomputes and reports if the answer moved. Called from the hardware
     signals below; exposed because a caller that has just changed something
     relevant — a resolution change in Studio, say — can ask for a recheck
     without waiting for one. ]]
function Device.refresh(): string
	local previous = cached
	cached = nil
	local class = Device.get()
	if previous and previous ~= class then
		Device.changed:fire(class)
	end
	return class
end

function Device.isHandheld(): boolean
	local class = Device.get()
	return class == Device.Class.Mobile or class == Device.Class.Tablet
end

function Device.isConsole(): boolean
	return Device.get() == Device.Class.Console
end

--[[
	The value for this device, from a table keyed by class.

	The reason this exists rather than callers writing their own `if` is the
	FALLBACK. GoreConfig.budgetFor does `BudgetScale[class] or 1.0`, which means
	any class it does not recognise is promoted to the full desktop budget — so
	adding Tablet to the vocabulary would have silently given tablets a desktop
	load. Here an unlisted class falls back to the next cheaper one it does know,
	and only then to `fallback`, so a new class can never cost more than the one
	it was split out of.

		Device.pick({ Mobile = 24, Console = 60 }, 90)   -- Tablet gets 24, not 90
]]
local CHEAPER_THAN: { [string]: string } = {
	[Device.Class.Tablet] = Device.Class.Mobile,
	[Device.Class.Console] = Device.Class.Desktop,
}

function Device.pick<T>(byClass: { [string]: T }, fallback: T): T
	local class = Device.get()
	local direct = byClass[class]
	if direct ~= nil then
		return direct
	end
	local nearest = CHEAPER_THAN[class]
	if nearest ~= nil and byClass[nearest] ~= nil then
		return byClass[nearest]
	end
	return fallback
end

--[[ A multiplier, for the common case of "the same thing, less of it". Same
     fallback rule as `pick`. ]]
function Device.scale(byClass: { [string]: number }): number
	return Device.pick(byClass, 1)
end

--[[
	Hardware can change under a running client and this has to notice.

	Plugging a controller into a phone, pairing a keyboard, docking a tablet, or
	rotating past the tablet threshold all move the answer. LastInputTypeChanged
	is the cheap signal that something about the input picture moved; the
	viewport signal covers rotation and window resize.

	Server-side this does nothing: there is no device to detect, `get` answers
	Desktop, and connecting to client-only signals from the server would throw.
]]
if RunService:IsClient() then
	UserInputService.LastInputTypeChanged:Connect(function()
		Device.refresh()
	end)

	local camera = Workspace.CurrentCamera
	if camera then
		camera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
			Device.refresh()
		end)
	end
	--[[ The camera is replaced on respawn and on some camera-mode changes, so
	     the connection above has to be re-made against whatever is current. ]]
	Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		local current = Workspace.CurrentCamera
		if current then
			current:GetPropertyChangedSignal("ViewportSize"):Connect(function()
				Device.refresh()
			end)
		end
		Device.refresh()
	end)
end

return Device
