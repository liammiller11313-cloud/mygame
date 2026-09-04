--!nonstrict
--[[
	AbilityEffects — what the five abilities look like.

	Every one of these is cosmetic and arrives after the fact. The damage, the
	healing, the slow and the turret's own body all happened on the server before
	the broadcast that gets here was sent, so nothing in this file can change an
	outcome and nothing in it needs to be trusted. That is why it can be as
	cheap and as fire-and-forget as it is.

	── WHAT IS DRAWN HERE AND WHAT IS NOT ──────────────────────────────────────
	The shield bubble and the turret are real server-made Instances: they have
	positions the whole server has to agree on, and Roblox replicates them for
	free. This file does not draw those. What it draws is everything with no
	physical existence — a tracer, a heal pulse, a frost field, an airstrike
	marker, a blast — because those are moments rather than objects.

	The airstrike marker is the important one. It is drawn from the same
	broadcast on every client at the same moment, which is what makes it a
	warning the whole team shares rather than a private one.

	── EVERYTHING CLEANS ITSELF UP ─────────────────────────────────────────────
	Each effect is a part with a Debris lifetime and a tween. There is no pool
	and no per-frame loop: these fire on the order of once every thirty seconds
	per player, and a pool for that is a cache that is always cold.
]]

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Registry = require(Shared.Util.Registry)
local Remotes = require(Shared.Net.Remotes)
local Trove = require(Shared.Util.Trove)
local UITheme = require(Shared.Config.UITheme)

local COLOR = UITheme.Color

local CRYO_COLOR = Color3.fromRGB(122, 196, 226)

local AbilityEffects = {}

local trove = Trove.new()

--[[ The folder everything here goes in. One place to look in the explorer, and
     one thing to destroy if this controller is ever torn down — a stray
     airstrike marker with no owner is the kind of thing that outlives a round
     and confuses everybody. ]]
local folder: Folder

local function decorate(part: BasePart)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Parent = folder
end

--[[ A flat disc on the ground. The shape three of these five want — a heal
     radius, a frost field and an airstrike footprint are all "this circle of
     floor" — and a cylinder lying down is the cheapest honest way to say it. ]]
local function disc(position: Vector3, radius: number, color: Color3, transparency: number): BasePart
	local part = Instance.new("Part")
	part.Name = "FL_AbilityDisc"
	part.Shape = Enum.PartType.Cylinder
	part.Size = Vector3.new(0.4, radius * 2, radius * 2)
	--[[ Rotated onto its face: a Roblox cylinder's length runs down X, so a disc
	     lying flat is a quarter turn about Z. ]]
	part.CFrame = CFrame.new(position) * CFrame.Angles(0, 0, math.rad(90))
	part.Color = color
	part.Material = Enum.Material.Neon
	part.Transparency = transparency
	decorate(part)
	return part
end

local function fade(part: BasePart, seconds: number, from: number)
	part.Transparency = from
	TweenService:Create(part, TweenInfo.new(seconds, Enum.EasingStyle.Linear), { Transparency = 1 }):Play()
	Debris:AddItem(part, seconds + 0.1)
end

-- ── the effects ─────────────────────────────────────────────────────────────

--[[ One tracer per turret shot. A thin, short-lived beam rather than a
     projectile: the shot has already landed on the server, so anything that
     travels here would be a lie about when it hit. ]]
local function turretShot(payload: any)
	if typeof(payload.origin) ~= "Vector3" or typeof(payload.hit) ~= "Vector3" then
		return
	end
	local delta = payload.hit - payload.origin
	local distance = delta.Magnitude
	if distance < 0.5 then
		return
	end

	local beam = Instance.new("Part")
	beam.Name = "FL_TurretTracer"
	beam.Size = Vector3.new(0.12, 0.12, distance)
	beam.CFrame = CFrame.lookAt(payload.origin + delta * 0.5, payload.hit)
	beam.Color = COLOR.AccentBright
	beam.Material = Enum.Material.Neon
	decorate(beam)
	fade(beam, 0.09, 0.15)
end

--[[ A ring that grows out to the heal radius. Growing rather than appearing at
     full size, because the thing a player needs to read is "this reached me",
     and a circle that arrives already drawn does not say that. ]]
local function healPulse(payload: any)
	if typeof(payload.position) ~= "Vector3" then
		return
	end
	local radius = tonumber(payload.radius) or 20
	local part = disc(payload.position, radius * 0.2, COLOR.HealthGood, 0.55)
	TweenService:Create(part, TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(0.4, radius * 2, radius * 2),
		Transparency = 1,
	}):Play()
	Debris:AddItem(part, 0.6)
end

--[[ The frost field, for as long as the slow lasts. This one is NOT a moment —
     it is a place the team can stand behind and shoot into, so it holds for the
     ability's whole duration and then fades rather than pulsing. ]]
local function cryoField(payload: any)
	if typeof(payload.position) ~= "Vector3" then
		return
	end
	local radius = tonumber(payload.radius) or 20
	local duration = tonumber(payload.duration) or 6
	local part = disc(payload.position, radius, CRYO_COLOR, 0.9)

	TweenService:Create(part, TweenInfo.new(0.25), { Transparency = 0.62 }):Play()
	task.delay(math.max(duration - 0.6, 0), function()
		if part.Parent then
			fade(part, 0.6, part.Transparency)
		end
	end)
	Debris:AddItem(part, duration + 1)
end

--[[ The airstrike warning. The most important thing in this file: it is the
     only reason 260 damage across five shells is fair, and it has to be
     unmistakable from any angle and at any distance. ]]
local function marker(payload: any)
	if typeof(payload.position) ~= "Vector3" then
		return
	end
	local radius = tonumber(payload.radius) or 16
	local warning = tonumber(payload.warning) or 2.5

	local ring = disc(payload.position, radius, COLOR.Danger, 0.5)
	--[[ Pulsing rather than steady. A static red circle reads as scenery on a
	     map that already has red in it; one that beats reads as a countdown, and
	     the beat is the only clock the player gets. ]]
	local pulse = TweenService:Create(
		ring,
		TweenInfo.new(0.35, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ Transparency = 0.82 }
	)
	pulse:Play()
	Debris:AddItem(ring, warning + 0.4)

	--[[ A column of light standing in it, so the marker is visible from cover
	     and from above rather than only by somebody looking at the floor. ]]
	local column = Instance.new("Part")
	column.Name = "FL_StrikeColumn"
	column.Size = Vector3.new(radius * 0.5, 90, radius * 0.5)
	column.CFrame = CFrame.new(payload.position + Vector3.new(0, 45, 0))
	column.Color = COLOR.Danger
	column.Material = Enum.Material.Neon
	column.Transparency = 0.93
	decorate(column)
	Debris:AddItem(column, warning + 0.2)
end

local function blast(payload: any)
	if typeof(payload.position) ~= "Vector3" then
		return
	end
	local radius = tonumber(payload.radius) or 16

	local ball = Instance.new("Part")
	ball.Name = "FL_Blast"
	ball.Shape = Enum.PartType.Ball
	ball.Size = Vector3.new(radius * 0.4, radius * 0.4, radius * 0.4)
	ball.CFrame = CFrame.new(payload.position)
	ball.Color = COLOR.AccentBright
	ball.Material = Enum.Material.Neon
	decorate(ball)
	TweenService:Create(ball, TweenInfo.new(0.32, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(radius * 2, radius * 2, radius * 2),
		Transparency = 1,
	}):Play()
	Debris:AddItem(ball, 0.4)

	--[[ No light flash. AtmosphereService owns the round's brightness and has a
	     pulse for exactly this, but it lives on the SERVER — calling it from here
	     would do nothing, and a second client-side brightness system would fight
	     the one that is already driving the sky. If an airstrike should light the
	     street, the flash belongs in the Airstrike module beside the explosion it
	     is lighting. ]]
end

-- ── lifecycle ───────────────────────────────────────────────────────────────

function AbilityEffects:init()
	folder = Instance.new("Folder")
	folder.Name = "FL_AbilityEffects"
	folder.Parent = Workspace
	trove:add(folder)
end

function AbilityEffects:start()
	trove:connect(Remotes.Event.AbilityEvent.OnClientEvent, function(payload: any)
		if typeof(payload) ~= "table" then
			return
		end
		--[[ Wrapped, because this is the one place in the client where a
		     malformed broadcast could stop every LATER effect from drawing.

		     The kinds with no branch here — ShieldUp, TurretUp and their downs —
		     are not missing. Those two abilities are real Instances the server
		     already made and Roblox already replicated, and drawing them a second
		     time is what would be wrong. ]]
		local kind = payload.kind
		local ok, err = pcall(function()
			if kind == "TurretShot" then
				turretShot(payload)
			elseif kind == "Heal" then
				healPulse(payload)
			elseif kind == "Cryo" then
				cryoField(payload)
			elseif kind == "Marker" then
				marker(payload)
			elseif kind == "Explosion" then
				blast(payload)
			end
		end)
		if not ok then
			warn("[AbilityEffects] " .. tostring(kind) .. " failed: " .. tostring(err))
		end
	end)
end

function AbilityEffects:destroy()
	trove:destroy()
end

Registry.register("AbilityEffects", AbilityEffects)

return AbilityEffects
