--!strict
--[[
	RocketScript — Script, cloned into each missile. Keep it Disabled in the tool.

	No tag bug here: `tagHumanoid` clones the creator onto the victim and expires
	it, which is correct. What it had instead was a landmine and a crash.

	── THE LANDMINE ─────────────────────────────────────────────────────────────
	    error = position - shaft.Position

	`error` with no `local` overwrites Lua's own `error()` function for the whole
	script. Nothing here calls it, so it worked — but any line added later that
	tried to raise an error would instead try to call a Vector3. Renamed to
	`drift`, which is what it is: how far the missile has fallen behind the point
	its servo is steering toward.

	── THE CRASH ────────────────────────────────────────────────────────────────
	    if part.Name == "Head" then
	        local humanoid = part.Parent.Humanoid

	An explosion hits everything in its radius, including map geometry. Any part
	in the world called "Head" whose parent has no Humanoid — a statue, a prop,
	a decoration — threw on that second line and killed the tagging for everyone
	else caught in the same blast.

	── UNCHANGED ────────────────────────────────────────────────────────────────
	The flight. `position + direction` each step with the velocity set to seven
	times the drift is a servo, not a straight line, and it is what gives the
	classic rocket its slight wobble. Ten second life, Swoosh on launch, and the
	explosion sound riding PlayOnRemove so it fires on contact but not at max
	range.

	The 0.1s tag lifetime is also unchanged, and is worth a look during testing:
	it assumes the blast kills instantly, so a survivor who lives for a fifth of
	a second is a kill that credits nobody.
]]

local Debris = game:GetService("Debris")
local RunService = game:GetService("RunService")

local shaft = script.Parent
local swoosh = shaft:FindFirstChild("Swoosh") :: Sound?
local blast = shaft:FindFirstChild("Explosion") :: Sound?

local FLIGHT_TIME = 10
local SERVO_GAIN = 7
local TAG_LIFETIME = 0.1

local target = shaft.Position
local connection: RBXScriptConnection? = nil
local detonated = false

if blast then
	blast.PlayOnRemove = true
end

local function tagHumanoid(humanoid: Humanoid)
	local creator = shaft:FindFirstChild("creator")
	if not creator then
		return
	end
	local fresh = creator:Clone()
	fresh.Parent = humanoid
	Debris:AddItem(fresh, TAG_LIFETIME)
end

local function onBlownUp(part: BasePart)
	if part.Name ~= "Head" then
		return
	end
	-- FindFirstChildOfClass, not `.Humanoid`. See the header.
	local humanoid = part.Parent and part.Parent:FindFirstChildOfClass("Humanoid")
	if humanoid then
		tagHumanoid(humanoid)
	end
end

local function fly()
	local direction = shaft.CFrame.LookVector
	target += direction
	local drift = target - shaft.Position
	shaft.AssemblyLinearVelocity = drift * SERVO_GAIN
end

local function blow()
	if detonated then
		return
	end
	detonated = true
	if connection then
		connection:Disconnect()
	end
	if swoosh then
		swoosh:Stop()
	end

	local explosion = Instance.new("Explosion")
	explosion.Position = shaft.Position
	if shaft:FindFirstChild("creator") then
		explosion.Hit:Connect(onBlownUp)
	end
	explosion.Parent = workspace

	task.wait(0.1)
	shaft:Destroy()
end

local elapsed = 0
if swoosh then
	swoosh:Play()
end
connection = shaft.Touched:Connect(blow)

while elapsed < FLIGHT_TIME and not detonated do
	fly()
	elapsed += RunService.Stepped:Wait()
end

if not detonated then
	-- Ran out of range rather than hitting something: no bang.
	if blast then
		blast.PlayOnRemove = false
	end
	if swoosh then
		swoosh:Stop()
	end
	shaft:Destroy()
end
