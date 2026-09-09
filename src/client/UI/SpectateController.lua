--!nonstrict
--[[
	SpectateController — watching the people who are still alive.

	── WHAT THERE WAS BEFORE ───────────────────────────────────────────────────
	Dying unlocked the camera: CameraController drops a dead survivor out of
	locked first person and lets them zoom out to 128 studs, with a comment
	saying that is "most of what makes death bearable". It is not, because the
	camera is still pointed at YOUR OWN BODY. A player who dies at the start of a
	seventeen-minute round spends the rest of it looking at the spot they died in
	while the fight walks away from them.

	This is the other half: pick a teammate and follow them.

	── IT IS A CAMERA CHOICE AND NOTHING ELSE ──────────────────────────────────
	No remote, no server state, no permission. Every character in the round is
	already replicated to every client, so following one is a local decision
	about where to point a camera — and a dead player has nothing to gain from
	the server that they do not already have. Which also means it cannot break
	anything: the worst failure available here is looking at the wrong person.

	── FIRE AND AIM CYCLE ──────────────────────────────────────────────────────
	Rather than new bindings. Both exist on all three schemes already — mouse
	buttons, both triggers, the FIRE and AIM buttons on the touch pad — and both
	are meaningless while you are dead, so nothing is taken from anybody and a
	console or a phone gets this for free the moment it ships. WeaponController
	independently refuses to fire while dead, so there is no double meaning.

	── AND IT RE-ASSERTS ───────────────────────────────────────────────────────
	Roblox owns CameraSubject and puts it back on your own Humanoid whenever it
	feels like it — a respawn, a character rebuild, its own camera scripts. So the
	subject is compared on the frame loop rather than set once. One property read
	per frame while dead, and none at all while alive.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attributes = require(Shared.Net.Attributes)
local Enums = require(Shared.Enums)
local Registry = require(Shared.Util.Registry)
local Trove = require(Shared.Util.Trove)
local Remotes = require(Shared.Net.Remotes)
local UITheme = require(Shared.Config.UITheme)

local FreeCursor = require(script.Parent.FreeCursor)
local Glyph = require(script.Parent.Glyph)
local ScaleLayer = require(script.Parent.ScaleLayer)
local TopStack = require(script.Parent.TopStack)
local Widgets = require(script.Parent.Widgets)

local COLOR = UITheme.Color
local FONT = UITheme.Font
local TEXT = UITheme.TextSize
local LAYOUT = UITheme.Layout

local GA = Attributes.Game
local PA = Attributes.Player
local STATE = Enums.SurvivorState

local player = Players.LocalPlayer
local trove = Trove.new()

--[[ The states with no game left to play. The same two CameraController unlocks
     the camera for, and deliberately not Incapacitated: a downed survivor is
     still in the round, still shooting a pistol, and still worth reviving. ]]
local WATCHING_STATES: { [string]: boolean } = {
	[STATE.Dead] = true,
	[STATE.Spectating] = true,
}

local CARD_WIDTH = 320
local CARD_HEIGHT = 40

--[[
	How far back the camera sits while following somebody else.

	Not the dead-player band CameraController hands out, which starts at 0.5 —
	and 0.5 is exactly where the camera already is when you die, because
	survivors are locked to first person. Left alone, the first frame of
	spectating puts you inside a teammate's skull with nothing to say so, and the
	only way out is a scroll wheel that a console and a phone do not have.

	So the floor is well clear of the head. The ceiling stays generous: watching
	the whole room a fight is happening in is a fair thing to want when there is
	nothing else left to do.
]]
local SPECTATE_ZOOM_MIN = 9
local SPECTATE_ZOOM_MAX = 70

local gui: ScreenGui
local card: Frame
local nameLabel: TextLabel
local leaveButton: TextButton
local leaveLabel: TextLabel

--[[ The way-out button's own height. Outside the card rather than inside it,
     because the card is sized for two lines of text and a late joiner should not
     make a dead survivor's card taller.

     Sized from the touch standard rather than by eye. It was 26, which on a
     phone — where the interface is drawn at ScaleLayer's 0.75 floor — is 19.5
     REAL pixels against this project's 42. It is the only control on the screen
     and it is offered to somebody who has just been told they cannot play for
     seventeen minutes; being unable to press it is the worst version of that. ]]
local LEAVE_HEIGHT = UITheme.Panel.RowHeightTouch
local hintLabel: TextLabel

local state = {
	watching = false,
	--[[ Who we are following. Held as the PLAYER rather than the Humanoid: a
	     character is rebuilt on every respawn and a stale Humanoid would leave
	     the camera watching a body that no longer exists. ]]
	target = nil :: Player?,
	shownName = "",
	shownHint = "",
	--[[
		Set when this player joined a server whose round had already started.

		They are spectating for a different reason from everybody else on this
		screen — not dead, not out of lives, just late — and the difference is
		worth saying, because "WAVE 7 IN PROGRESS · YOU ARE IN THE NEXT ONE" is
		the whole answer to the question they are actually asking, which is
		whether the game is broken.

		It is also the only state in which the way out is offered. A dead
		survivor has teammates who can defib them; a late joiner has nothing to
		wait for except the clock.
	]]
	late = false,
	lateWave = 0,
}

--[[ Everyone worth watching, in a stable order.

     Stable because the cycle has to be predictable: UserId sorts the same way on
     every frame and for every player, so pressing next twice always lands two
     people along rather than wherever the table happened to be walked. ]]
local function candidates(): { Player }
	local found = {}
	for _, other in Players:GetPlayers() do
		if other == player then
			continue
		end
		if WATCHING_STATES[Attributes.get(other, PA.State, STATE.Spectating)] then
			continue
		end
		local character = other.Character
		if character and character:FindFirstChildOfClass("Humanoid") then
			table.insert(found, other)
		end
	end
	table.sort(found, function(a, b)
		return a.UserId < b.UserId
	end)
	return found
end

local function step(list: { Player }, direction: number)
	if #list == 0 then
		state.target = nil
		return
	end
	local index = table.find(list, state.target)
	if not index then
		--[[ Nothing selected yet. The wrap below is written for a real index and
		     answers a zero one two places off, which is a fiddly thing to notice
		     and a silly thing to ship: from nowhere, forward means the first and
		     back means the last. ]]
		state.target = if direction > 0 then list[1] else list[#list]
		return
	end
	state.target = list[(index - 1 + direction) % #list + 1]
end

--[[ The camera actually follows a HUMANOID, so this is where the player we are
     tracking turns back into one. Nil at every step it cannot: no target, no
     character yet, or a character mid-rebuild. ]]
local function subjectOf(target: Player?): Humanoid?
	if not target then
		return nil
	end
	local character = target.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	return if humanoid and humanoid:IsA("Humanoid") then humanoid else nil
end

local function ownHumanoid(): Humanoid?
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	return if humanoid and humanoid:IsA("Humanoid") then humanoid else nil
end

local function hintText(): string
	local input = Registry.find("InputController")
	local scheme = if input and typeof(input.getScheme) == "function"
		then select(2, pcall(input.getScheme, input))
		else nil
	local nextGlyph = Glyph.forAction("Fire", scheme, input)
	local backGlyph = Glyph.forAction("Aim", scheme, input)
	if scheme == "Touch" then
		return "FIRE / AIM TO CHANGE"
	end
	if nextGlyph == "" or backGlyph == "" then
		return ""
	end
	return string.format("%s NEXT   %s BACK", nextGlyph, backGlyph)
end

local function redraw()
	local target = state.target
	local name = if target then string.upper(target.DisplayName) else ""
	--[[ Which of the two ways there is no way back matters to the player reading
	     it: waiting for a rescue is something a teammate can still fix, and being
	     out of lives is not. The card says which without them having to work it
	     out from the fact that nobody has come. ]]
	local out = Attributes.get(player, PA.Eliminated, false) == true
	local text
	if state.late then
		--[[ A late joiner is not out and is not waiting on a defib — they are
		     early for the next round. Saying THAT is the whole point of the
		     flag: it answers the question they are actually asking, which is
		     whether the game failed to spawn them. ]]
		text = if state.lateWave > 0
			then string.format("WAVE %d IN PROGRESS", state.lateWave)
			else "ROUND IN PROGRESS"
	elseif name ~= "" then
		text = if out then "OUT — SPECTATING  " .. name else "SPECTATING  " .. name
	else
		text = "NOBODY LEFT TO WATCH"
	end
	if text ~= state.shownName then
		state.shownName = text
		nameLabel.Text = text
	end
	--[[ The promise, and it is the load-bearing half. Somebody who has just been
	     told they are not playing needs to know they will be, and when. ]]
	local hint = if state.late then "YOU ARE IN THE NEXT ROUND" elseif target then hintText() else ""
	if hint ~= state.shownHint then
		state.shownHint = hint
		hintLabel.Text = hint
	end
end

local function place()
	if card then
		card.Position = UDim2.new(0.5, 0, 0, TopStack.top("Spectate"))
	end
end

--[[ Turns the whole thing on and off, and puts the camera back on the way out.

     Restoring the subject matters more than it looks: a player who is defibbed
     or rescued out of a closet gets their own body back, and a camera still
     bolted to whoever they were watching would follow that person around while
     the revived player walked blind. ]]
local function setWatching(on: boolean)
	if state.watching == on then
		return
	end
	state.watching = on
	gui.Enabled = on
	TopStack.set("Spectate", if on then CARD_HEIGHT else 0)

	if on then
		step(candidates(), 1)
		place()
		redraw()
		return
	end

	state.target = nil
	local camera = Workspace.CurrentCamera
	local own = ownHumanoid()
	if camera and own then
		camera.CameraSubject = own
	end
	--[[ And the zoom band goes back to whoever owns it now. Asked rather than
	     restored from a snapshot: what the band should be depends on the state
	     the player is in on the way out, which is exactly the question
	     applyCameraMode exists to answer, and a remembered value would be the one
	     from before they died. ]]
	local cameras = Registry.find("CameraController")
	if cameras and typeof(cameras.refreshCameraMode) == "function" then
		pcall(cameras.refreshCameraMode, cameras)
	end
end

local function cycle(direction: number)
	if not state.watching then
		return
	end
	--[[ Not while a screen owns the mouse. The results card comes up over a wipe
	     and its buttons are clicked with the same button this cycles on. ]]
	if FreeCursor.isHeld() then
		return
	end
	step(candidates(), direction)
	redraw()
end

--[[
	Whether there is anything left to play, asked every frame.

	On the frame loop rather than on the state attribute, and that is not
	laziness. The two facts this needs — the survivor state and whether the body
	is still alive — are written by different systems and arrive in whichever
	order they arrive. Hung off the attribute alone, a state that flips to Dead
	one frame before the Humanoid does would test a living body, refuse, and never
	be asked again; the player would sit looking at their own corpse for the rest
	of the round with no way to say otherwise.

	Two property reads and a FindFirstChild, on a loop that is already running.
]]
local function refreshWatching()
	if not WATCHING_STATES[Attributes.get(player, PA.State, STATE.Spectating)] then
		setWatching(false)
		return
	end
	--[[
		AND ONLY WITH NOTHING LEFT TO PLAY.

		In Versus a player whose survivor died comes back as an infected body, and
		their survivor state stays in this set while they do — so the state alone
		would hand somebody driving a Boomer a camera bolted to the other team. A
		living Humanoid means there is a game to play, whatever the survivor state
		says about it.

		Mode-agnostic on purpose: it asks about the body rather than about Versus,
		so it stays right for anything else that ever puts a player back in one
		without making them a survivor again.
	]]
	local own = ownHumanoid()
	setWatching(own == nil or own.Health <= 0)
end

local function update()
	refreshWatching()
	if not state.watching then
		return
	end

	--[[ The person being watched can leave, die, or be swallowed by a respawn.
	     Re-picking is one list walk on a frame where the target became invalid,
	     and nothing at all on every other frame. ]]
	local humanoid = subjectOf(state.target)
	if not humanoid or WATCHING_STATES[Attributes.get(state.target, PA.State, STATE.Spectating)] then
		step(candidates(), 1)
		humanoid = subjectOf(state.target)
		redraw()
	end

	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	--[[ Falls back to the player's own body rather than leaving the camera on a
	     destroyed Humanoid, which Roblox answers by putting the view at the world
	     origin — a black screen that reads as the game having crashed. ]]
	local wanted = humanoid or ownHumanoid()
	if wanted and camera.CameraSubject ~= wanted then
		camera.CameraSubject = wanted
	end

	--[[ Re-asserted for the same reason the subject is: CameraController owns
	     these two and re-applies its own dead-player band whenever a screen hands
	     the cursor back — closing the pause menu while dead, say. Comparing first
	     means the common frame writes nothing. ]]
	if player.CameraMinZoomDistance ~= SPECTATE_ZOOM_MIN then
		player.CameraMinZoomDistance = SPECTATE_ZOOM_MIN
	end
	if player.CameraMaxZoomDistance ~= SPECTATE_ZOOM_MAX then
		player.CameraMaxZoomDistance = SPECTATE_ZOOM_MAX
	end
end

local function build()
	gui = Instance.new("ScreenGui")
	gui.Name = "FL_Spectate"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = UITheme.DisplayOrder.Hud
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Enabled = false
	gui.Parent = player:WaitForChild("PlayerGui")
	trove:add(gui)

	local layer = ScaleLayer.new(gui, "Scaled")

	card = Widgets.frame(layer, "Spectate", COLOR.Panel, 0.25)
	card.AnchorPoint = Vector2.new(0.5, 0)
	card.Position = UDim2.new(0.5, 0, 0, TopStack.top("Spectate"))
	card.Size = UDim2.fromOffset(CARD_WIDTH, CARD_HEIGHT)
	Widgets.stroke(card, COLOR.Border)

	nameLabel = Widgets.label(card, "Name", FONT.Heading, TEXT.Body, COLOR.AccentBright)
	nameLabel.Position = UDim2.fromOffset(0, 5)
	nameLabel.Size = UDim2.new(1, 0, 0, TEXT.Body + 2)
	nameLabel.TextXAlignment = Enum.TextXAlignment.Center

	hintLabel = Widgets.label(card, "Hint", FONT.Body, TEXT.Tiny, COLOR.TextSecondary)
	hintLabel.Position = UDim2.fromOffset(0, 5 + TEXT.Body + 4)
	hintLabel.Size = UDim2.new(1, 0, 0, TEXT.Tiny + 2)
	hintLabel.TextXAlignment = Enum.TextXAlignment.Center

	--[[ Under the card and only for a late joiner. Hidden rather than absent, so
	     the ordinary spectate view — a dead survivor waiting on a defib — is
	     exactly the card it has always been, with nothing new on it. ]]
	leaveButton = Widgets.button(card, "Leave")
	leaveButton.AnchorPoint = Vector2.new(0.5, 0)
	leaveButton.Position = UDim2.new(0.5, 0, 1, LAYOUT.ElementGap)
	leaveButton.Size = UDim2.fromOffset(CARD_WIDTH, LEAVE_HEIGHT)
	leaveButton.BackgroundColor3 = COLOR.PanelRaised
	leaveButton.BackgroundTransparency = 0.15
	leaveButton.Visible = false
	local stroke = Widgets.stroke(leaveButton, COLOR.Border)
	leaveLabel = Widgets.label(leaveButton, "Label", FONT.Heading, TEXT.Tiny, COLOR.TextSecondary)
	leaveLabel.Size = UDim2.fromScale(1, 1)
	leaveLabel.TextXAlignment = Enum.TextXAlignment.Center
	leaveLabel.Text = "FIND ANOTHER SERVER"
	Widgets.outlineHover(trove, leaveButton, stroke)
	trove:connect(leaveButton.Activated, function()
		--[[ Says so immediately. A teleport takes a moment and gives no feedback
		     of its own, so without this the button reads as broken and gets
		     pressed again — which the server throttles, which makes it read as
		     more broken. ]]
		leaveLabel.Text = "LOOKING\226\128\166"
		Remotes.Event.FindAnotherServer:FireServer()
	end)
end

local SpectateController = {}

function SpectateController:init()
	build()
	trove:add(TopStack.onChanged(place))
end

function SpectateController:start()
	local input = Registry.find("InputController")
	if input then
		trove:add(input:onBegan(input.Action.Fire):connect(function()
			cycle(1)
		end))
		trove:add(input:onBegan(input.Action.Aim):connect(function()
			cycle(-1)
		end))
		--[[ The hint names buttons, so it is redrawn when the buttons change —
		     a controller picked up mid-round relabels it without a state change
		     ever happening. ]]
		if input.schemeChanged then
			trove:add(input.schemeChanged:connect(function()
				state.shownHint = ""
				redraw()
			end))
		end
	end

	--[[ The server saying why this player is watching. It arrives once, when
	     they press PLAY into a running round, and it is the difference between a
	     spectate camera that explains itself and one that looks like a failed
	     spawn. ]]
	trove:connect(Remotes.Event.RoundInProgress.OnClientEvent, function(payload: any)
		if typeof(payload) ~= "table" then
			return
		end
		state.late = true
		state.lateWave = tonumber(payload.wave) or 0
		state.shownHint = ""
		if leaveButton then
			leaveButton.Visible = true
			leaveLabel.Text = "FIND ANOTHER SERVER"
		end
		redraw()
	end)

	--[[ And the teleport not working. Put back rather than left saying LOOKING,
	     because a button stuck on its own progress text is the same dead button
	     it was pressed to escape. ]]
	trove:connect(Remotes.Event.TeleportFailed.OnClientEvent, function(payload: any)
		if not leaveButton then
			return
		end
		leaveLabel.Text = "NO SERVER FOUND \226\128\148 RETRY"
		if typeof(payload) == "table" and typeof(payload.reason) == "string" then
			hintLabel.Text = string.upper(payload.reason)
			state.shownHint = hintLabel.Text
		end
	end)

	--[[ A round ending takes the notice down with it: whatever this player was
	     late for is over, and the next thing that happens to them is being
	     spawned into the new one. ]]
	trove:connect(Workspace:GetAttributeChangedSignal(GA.RoundState), function()
		if Attributes.get(Workspace, GA.RoundState, "") ~= Enums.RoundState.InProgress then
			state.late = false
			state.lateWave = 0
			if leaveButton then
				leaveButton.Visible = false
			end
		end
	end)

	trove:connect(RunService.RenderStepped, update)
end

function SpectateController:destroy()
	setWatching(false)
	trove:destroy()
end

Registry.register("SpectateController", SpectateController)

return SpectateController
