--!strict
--[[
	Paintball — Script, cloned into each paintball. Keep it Disabled in the tool.

	No tag bug. Two other things, and the first is the one that matters.

	── THE BALL KEPT KILLING AFTER IT HAD HIT YOU ───────────────────────────────
	    if humanoid then
	        tagHumanoid(humanoid)
	        humanoid:TakeDamage(damage)
	        wait(2)                    <-- inside the Touched handler
	        untagHumanoid(humanoid)
	    end
	    connection:Disconnect()
	    ball.Parent = nil

	The wait was INSIDE the handler and before the disconnect, so a ball that hit
	a player stayed in the world, still connected, for two more seconds — free to
	touch somebody else and damage them too. A ball that hit a wall died at once;
	only the ones that hit people lived on. The disconnect happens first now, and
	the tag expires on a Debris timer instead of a yield.

	── AND IT STOLE KILL CREDIT ─────────────────────────────────────────────────
	`untagHumanoid` deleted whatever creator tag it found on the victim after
	those two seconds — not necessarily its own. If somebody else shot the same
	player in the meantime, this erased THEIR claim, and the kill credited
	nobody. Debris:AddItem on the tag we placed removes exactly the one we own,
	which is how every other weapon in the pack does it.

	── LEFT ALONE ON PURPOSE ────────────────────────────────────────────────────
	    if hit:GetMass() < 1.2 * 200 then
	        hit.BrickColor = ball.BrickColor
	    end

	The gun repaints anything it hits under about 240 mass, permanently, with no
	way back. That is either the whole point of a paintball gun or a way to
	redecorate somebody's map forever, and which one it is depends on the game
	rather than on the code. Untouched — say the word and it reverts on a timer.
]]

local Debris = game:GetService("Debris")
local TweenService = game:GetService("TweenService")

local ball = script.Parent
local damage = 5

local TAG_LIFETIME = 2
local LIFETIME = 8
local PAINTABLE_MASS = 1.2 * 200
local SPLAT_SIZE = Vector3.new(0.5, 0.1, 0.5)
local SPLAT_COUNT = 3

local connection: RBXScriptConnection? = nil
local spent = false

local function splat(position: Vector3, color: BrickColor)
	local part = Instance.new("Part")
	part.Size = SPLAT_SIZE
	part.BrickColor = color
	part.Anchored = false
	part.CanCollide = false
	part.CFrame = CFrame.new(position)
	part.Parent = workspace

	TweenService:Create(
		part,
		TweenInfo.new(1, Enum.EasingStyle.Quart, Enum.EasingDirection.Out),
		{ Size = SPLAT_SIZE * 4 }
	):Play()

	Debris:AddItem(part, 2)
end

local function tagHumanoid(humanoid: Humanoid)
	local tag = ball:FindFirstChild("creator")
	if not tag then
		return
	end
	local fresh = tag:Clone()
	fresh.Parent = humanoid
	-- Ours, expiring on its own. Never reaches for a tag somebody else placed.
	Debris:AddItem(fresh, TAG_LIFETIME)
end

local function onTouched(hit: BasePart)
	if spent or not hit or not hit.Parent then
		return
	end
	spent = true
	if connection then
		connection:Disconnect()
	end

	if hit:GetMass() < PAINTABLE_MASS then
		hit.BrickColor = ball.BrickColor
	end

	for _ = 1, SPLAT_COUNT do
		splat(ball.Position + Vector3.new(math.random(-1, 1), 0, math.random(-1, 1)), ball.BrickColor)
	end

	local humanoid = hit.Parent:FindFirstChildOfClass("Humanoid")
	if humanoid then
		tagHumanoid(humanoid)
		humanoid:TakeDamage(damage)
	end

	ball:Destroy()
end

connection = ball.Touched:Connect(onTouched)

task.wait(LIFETIME)
if ball.Parent then
	ball:Destroy()
end
