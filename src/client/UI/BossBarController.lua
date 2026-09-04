--!nonstrict
--[[
	BossBarController — how much is left of the thing in front of you.

	A Common dies in one shot and a special dies in a magazine, so neither needs
	a number: you find out by shooting it. A Tank does not work that way. Four
	thousand health is thirty seconds of a whole team's output, and the finale's
	Apex Tank is twelve thousand — a minute and a half in which the only feedback
	the game gave was that it had not fallen over yet.

	That is the difference between a hard fight and an unreadable one. A team
	that cannot see progress cannot make the decision the fight is actually
	about: keep shooting, or break off and pick somebody up. So this draws the
	one bar, and only for the one creature that has earned it.

	── ONLY TANKS ──────────────────────────────────────────────────────────────
	Not the Witch, deliberately, even though she is also flagged isBoss. A Witch
	is a hazard you are supposed to walk around, and the whole tension of one is
	not knowing whether you have already woken her; a health bar hanging over
	her the moment she exists announces her, and answers the question the
	encounter is made of. The Tank has no such secret — it is a Tank, it is
	coming, and the only open question is how much of it is left.

	── AND ONLY THE NEAREST ONE ────────────────────────────────────────────────
	Waves can put two on the map. Two bars would be two things to read in the
	one moment nobody has time to read anything, so the bar follows whichever is
	closest to you — which, when there are two Tanks in a round, is the one
	actually about to hit you.

	── IT COSTS NO NETWORK ─────────────────────────────────────────────────────
	FL_Health and FL_MaxHealth are already written on the model by
	InfectedService and already replicate. The bar reads those. It does not ask
	the server anything and it does not add a remote.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attributes = require(Shared.Net.Attributes)
local Enums = require(Shared.Enums)
local InfectedConfig = require(Shared.Config.InfectedConfig)
local Registry = require(Shared.Util.Registry)
local RigUtil = require(Shared.Util.RigUtil)
local Trove = require(Shared.Util.Trove)
local UITheme = require(Shared.Config.UITheme)

local ScaleLayer = require(script.Parent.ScaleLayer)

local COLOR = UITheme.Color
local FONT = UITheme.Font
local LAYOUT = UITheme.Layout
local TEXT = UITheme.TextSize
local IA = Attributes.Infected

local player = Players.LocalPlayer

local BAR_WIDTH = 420
local BAR_HEIGHT = 10
local LABEL_HEIGHT = TEXT.Small + 2
local BLOCK_HEIGHT = LABEL_HEIGHT + LAYOUT.ElementGap + BAR_HEIGHT

--[[ Which Tank the bar is following is re-decided on a throttle, not per frame.
     Nothing about the answer changes in a sixtieth of a second, and the test
     walks every live boss. The FILL still moves every frame — that is the part
     a player is actually watching. ]]
local PICK_INTERVAL = 0.25

--[[ How fast the fill chases the truth, as a fraction of the gap per second.
     A bar that snaps reads as a bug when a rocket lands; a bar that eases makes
     the same rocket feel like it did something. Fast enough that it has caught
     up before the player looks back at it. ]]
local FILL_CHASE = 9

--[[ Below this fraction the bar goes hot. Not a phase and not a mechanic — the
     Tank does not change — it is the readout admitting the fight is nearly
     over, which is the moment a team decides to commit rather than break off. ]]
local NEARLY_DEAD = 0.25

local BossBarController = {}

local trove = Trove.new()
local folderTrove = Trove.new()
local targetTrove = Trove.new()

local gui: ScreenGui
local block: Frame
local nameLabel: TextLabel
local countLabel: TextLabel
local barTrack: Frame
local barFill: Frame

local bosses: { [Model]: true } = {}

local state = {
	model = nil :: Model?,
	fraction = 1,
	shown = 0, -- what the bar is actually drawing, easing toward `fraction`
	pickAt = 0,
	inset = 0,
}

-- ── helpers ─────────────────────────────────────────────────────────────────

--[[ What this Tank is called. An Apex is called an Apex: a team that reads
     "TANK" on the finale brings the plan that worked on wave 5. ]]
local function titleFor(model: Model): string
	local definition = InfectedConfig.get(Attributes.get(model, IA.Kind, "") :: string)
	local name = if definition then definition.displayName else "Tank"
	local elite = InfectedConfig.elite(Attributes.get(model, IA.Elite, "") :: string)
	if elite then
		name = elite.titlePrefix .. " " .. name
	end
	return string.upper(name)
end

local function accentFor(model: Model): Color3
	local elite = InfectedConfig.elite(Attributes.get(model, IA.Elite, "") :: string)
	return if elite then elite.outlineColor else COLOR.Danger
end

--[[ Where the top of the screen ends. WaveController owns that number and the
     HUD already asks it for the same one, so this asks too rather than adding a
     third opinion about where the clock block finishes. ]]
local function reservedTop(): number
	local waves = Registry.find("WaveController")
	if waves and typeof(waves.getReservedTopHeight) == "function" then
		local ok, value = pcall(waves.getReservedTopHeight, waves)
		if ok and typeof(value) == "number" then
			return value
		end
	end
	return LAYOUT.ScreenMargin
end

--[[ Push the objective line down past the bar while it is up, and let it back
     when it is not. WaveController sets the resting value once at start and
     never touches it again, so an additive push here is safe — but it is
     RESTORED rather than remembered, so a fault that leaves this module wedged
     cannot leave the HUD permanently indented. ]]
local function pushInset(extra: number)
	if state.inset == extra then
		return
	end
	state.inset = extra
	local hud = Registry.find("HudController")
	if hud and typeof(hud.setTopInset) == "function" then
		pcall(hud.setTopInset, hud, reservedTop() + extra)
	end
end

local function healthOf(model: Model): (number, number)
	local maximum = math.max(tonumber(Attributes.get(model, IA.MaxHealth, 0)) or 0, 1)
	local current = math.clamp(tonumber(Attributes.get(model, IA.Health, 0)) or 0, 0, maximum)
	return current, maximum
end

local function isLive(model: Model): boolean
	if not model.Parent then
		return false
	end
	if Attributes.get(model, IA.IsDead, false) == true then
		return false
	end
	local current = healthOf(model)
	return current > 0
end

-- ── choosing the boss ───────────────────────────────────────────────────────

local function localPosition(): Vector3?
	local character = player.Character
	local root = if character then RigUtil.getRoot(character) else nil
	return if root then root.Position else nil
end

local function pickBoss(): Model?
	local origin = localPosition()
	local best: Model? = nil
	local bestDistance = math.huge
	for model in bosses do
		if not isLive(model) then
			continue
		end
		--[[ With no character to measure from — dead, spectating, mid-respawn —
		     any live Tank is better than none. The bar is still worth reading
		     from the floor: it is how you know whether the people still up are
		     winning. ]]
		if not origin then
			return model
		end
		local root = RigUtil.getRoot(model)
		if not root then
			continue
		end
		local distance = (root.Position - origin).Magnitude
		if distance < bestDistance then
			bestDistance = distance
			best = model
		end
	end
	return best
end

local function refreshHealth()
	local model = state.model
	if not model then
		return
	end
	local current, maximum = healthOf(model)
	state.fraction = current / maximum
	countLabel.Text = string.format("%d / %d", math.ceil(current), maximum)
end

local function follow(model: Model?)
	if state.model == model then
		return
	end
	targetTrove:clean()
	state.model = model

	if not model then
		gui.Enabled = false
		pushInset(0)
		return
	end

	nameLabel.Text = titleFor(model)
	local accent = accentFor(model)
	nameLabel.TextColor3 = accent
	barFill.BackgroundColor3 = accent

	--[[ Snapped rather than eased on a change of target. Easing from the last
	     Tank's remaining health would show the new one at whatever the old one
	     was down to, which is a lie in the direction that gets people killed. ]]
	refreshHealth()
	state.shown = state.fraction

	targetTrove:connect(model:GetAttributeChangedSignal(IA.Health), refreshHealth)
	targetTrove:connect(model:GetAttributeChangedSignal(IA.MaxHealth), refreshHealth)

	gui.Enabled = true
	pushInset(BLOCK_HEIGHT + LAYOUT.ElementGap)
end

-- ── the folder ──────────────────────────────────────────────────────────────

local function considerModel(child: Instance)
	if not child:IsA("Model") then
		return
	end
	if Attributes.get(child, IA.Kind, "") ~= Enums.Infected.Tank then
		return
	end
	bosses[child] = true
end

local function forgetModel(child: Instance)
	if child:IsA("Model") then
		bosses[child :: Model] = nil
		if state.model == child then
			follow(nil)
		end
	end
end

local function watchFolder(folder: Instance)
	folderTrove:clean()
	table.clear(bosses)
	for _, child in folder:GetChildren() do
		considerModel(child)
	end
	folderTrove:connect(folder.ChildAdded, considerModel)
	folderTrove:connect(folder.ChildRemoved, forgetModel)
end

-- ── the frame ───────────────────────────────────────────────────────────────

local function step(dt: number)
	local now = os.clock()
	if now >= state.pickAt then
		state.pickAt = now + PICK_INTERVAL
		local chosen = pickBoss()
		--[[ A dead Tank stops being a target the frame its health reaches zero,
		     which is before the corpse leaves the folder. Waiting for ChildRemoved
		     would leave an empty bar hanging over a body on the ground. ]]
		if state.model and not isLive(state.model) then
			bosses[state.model] = nil
		end
		follow(chosen)
	end

	if not state.model then
		return
	end

	local gap = state.fraction - state.shown
	if math.abs(gap) > 0.0005 then
		state.shown += gap * math.clamp(FILL_CHASE * dt, 0, 1)
	else
		state.shown = state.fraction
	end
	barFill.Size = UDim2.new(math.max(state.shown, 0), 0, 1, 0)
	barFill.BackgroundColor3 = if state.shown <= NEARLY_DEAD
		then COLOR.AccentBright
		else accentFor(state.model)
end

local function build()
	gui = Instance.new("ScreenGui")
	gui.Name = "FL_BossBar"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	--[[ The HUD layer. It is HUD — it is read while shooting — and it must go
	     under every menu and under the incap overlay, both of which are things
	     that have already taken the player out of the fight. ]]
	gui.DisplayOrder = UITheme.DisplayOrder.Hud
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Enabled = false
	gui.Parent = player:WaitForChild("PlayerGui")
	trove:add(gui)

	local layer = ScaleLayer.new(gui, "Scaled")

	block = Instance.new("Frame")
	block.Name = "Boss"
	block.BackgroundTransparency = 1
	block.BorderSizePixel = 0
	block.AnchorPoint = Vector2.new(0.5, 0)
	block.Size = UDim2.fromOffset(BAR_WIDTH, BLOCK_HEIGHT)
	block.Parent = layer

	nameLabel = Instance.new("TextLabel")
	nameLabel.Name = "Name"
	nameLabel.BackgroundTransparency = 1
	nameLabel.BorderSizePixel = 0
	nameLabel.Font = FONT.Heading
	nameLabel.TextSize = TEXT.Small
	nameLabel.TextColor3 = COLOR.Danger
	nameLabel.TextXAlignment = Enum.TextXAlignment.Left
	nameLabel.Size = UDim2.new(0.6, 0, 0, LABEL_HEIGHT)
	nameLabel.Text = ""
	nameLabel.Parent = block

	countLabel = Instance.new("TextLabel")
	countLabel.Name = "Count"
	countLabel.BackgroundTransparency = 1
	countLabel.BorderSizePixel = 0
	countLabel.Font = FONT.Numeric
	countLabel.TextSize = TEXT.Small
	countLabel.TextColor3 = COLOR.TextSecondary
	countLabel.TextXAlignment = Enum.TextXAlignment.Right
	countLabel.AnchorPoint = Vector2.new(1, 0)
	countLabel.Position = UDim2.fromScale(1, 0)
	countLabel.Size = UDim2.new(0.4, 0, 0, LABEL_HEIGHT)
	countLabel.Text = ""
	countLabel.Parent = block

	barTrack = Instance.new("Frame")
	barTrack.Name = "Track"
	barTrack.BackgroundColor3 = COLOR.Panel
	barTrack.BackgroundTransparency = 0.25
	barTrack.BorderSizePixel = 0
	barTrack.AnchorPoint = Vector2.new(0, 1)
	barTrack.Position = UDim2.fromScale(0, 1)
	barTrack.Size = UDim2.new(1, 0, 0, BAR_HEIGHT)
	barTrack.Parent = block

	local stroke = Instance.new("UIStroke")
	stroke.Color = COLOR.Border
	stroke.Thickness = LAYOUT.BorderThickness
	stroke.Parent = barTrack

	barFill = Instance.new("Frame")
	barFill.Name = "Fill"
	barFill.BackgroundColor3 = COLOR.Danger
	barFill.BorderSizePixel = 0
	barFill.Size = UDim2.fromScale(1, 1)
	barFill.Parent = barTrack
end

--[[ Under the wave clock, and re-read rather than cached: the block above this
     one is sized from the wave COUNT, so a schedule change moves it. ]]
local function reposition()
	if block then
		block.Position = UDim2.new(0.5, 0, 0, reservedTop() + LAYOUT.ElementGap)
	end
end

-- ── lifecycle ───────────────────────────────────────────────────────────────

--[[ How much room this is taking under the wave block right now, or 0. Asked by
     anything else that draws below it — see EventController's banner, which
     would otherwise be laid straight over a Tank's health bar, since both anchor
     to the same reserved top. Nobody has to know whether a boss is up; they ask
     for a number and add it. ]]
function BossBarController:getReservedExtra(): number
	return state.inset
end

function BossBarController:init()
	build()
end

function BossBarController:start()
	reposition()

	local existing = Workspace:FindFirstChild("Infected")
	if existing then
		watchFolder(existing)
	else
		--[[ The folder is made by InfectedService on the first spawn, which on a
		     fresh server is after the client has booted. One connection, dropped
		     the moment it fires. ]]
		local connection: RBXScriptConnection
		connection = Workspace.ChildAdded:Connect(function(child: Instance)
			if child.Name == "Infected" then
				connection:Disconnect()
				watchFolder(child)
			end
		end)
		trove:add(connection)
	end

	trove:connect(RunService.RenderStepped, step)
end

function BossBarController:destroy()
	targetTrove:destroy()
	folderTrove:destroy()
	trove:destroy()
	table.clear(bosses)
end

Registry.register("BossBarController", BossBarController)

return BossBarController
