--!nonstrict
--[[
	CheckAnimations — asks Roblox, for real, whether every animation this game
	declares will actually play in THIS place.

	── HOW TO RUN IT ───────────────────────────────────────────────────────────
	  1. Sync the place with Rojo first, so ReplicatedStorage.Shared exists.
	  2. Game Settings > Security > Allow Studio Access to API Services: ON.
	  3. View > Command Bar, paste this whole file in, press Enter.

	It creates nothing permanent. A temporary rig appears in Workspace for a
	second and is destroyed before the script returns, even if something errors.

	── WHY THIS EXISTS ─────────────────────────────────────────────────────────
	An animation Roblox refuses fails SILENTLY. LoadAnimation does not throw for
	an id that is private, deleted, moderated, or owned by another account — it
	returns a perfectly ordinary AnimationTrack that reports itself as playing,
	has a Length of zero, and moves nothing. Every pcall around it takes the
	success branch. The gun just does not animate, and you find out by watching.

	Roblox only plays an animation owned by the PLACE'S CREATOR or by Roblox
	itself. An id you uploaded under your personal account, in a game owned by a
	group, is the usual way this happens — the id is fine, your account owns it,
	and this place still cannot use it.

	── THE TWO THINGS IT CHECKS ────────────────────────────────────────────────
	  FETCH   ContentProvider reports the real asset status. This is the one that
	          catches an unauthorized id, and it is the one you care about.
	  LENGTH  A clip that fetched but is zero seconds long is an empty upload —
	          an animation that was published before any keyframes were saved.
	          It will "play" and do nothing, exactly like a refused one.

	What it CANNOT check is whether a clip addresses the joints your rigs
	actually have. An R6 clip on an R15 body loads, fetches, has a real length,
	and still moves nothing. If an id passes here and still does not show up in
	game, that is the next thing to suspect.
]]

local ContentProvider = game:GetService("ContentProvider")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local shared = ReplicatedStorage:FindFirstChild("Shared")
local configFolder = shared and shared:FindFirstChild("Config")
local module = configFolder and configFolder:FindFirstChild("AnimationConfig")
if not module then
	warn(
		"[CheckAnimations] ReplicatedStorage.Shared.Config.AnimationConfig is missing — sync with Rojo first."
	)
	return
end

local AnimationConfig = require(module)

--[[ Every declared id with a HUMAN LABEL, because "111410151816711 failed" is
     not actionable and "Pistol fire failed" is. Built from the same tables
     AnimationConfig.allIds walks, so a set added there shows up here too. ]]
local labels: { [number]: { string } } = {}
local order: { number } = {}

local function note(id: any, label: string)
	if typeof(id) ~= "number" or id <= 0 then
		return
	end
	if not labels[id] then
		labels[id] = {}
		table.insert(order, id)
	end
	table.insert(labels[id], label)
end

for class, set in AnimationConfig.Weapon do
	for role, id in set do
		note(id, string.format("%s %s", class, role))
	end
end
for role, id in AnimationConfig.WeaponFallback do
	note(id, string.format("fallback %s", role))
end
for rig, id in AnimationConfig.SurvivorHold do
	note(id, string.format("survivor hold (%s)", rig))
end
for rig, set in AnimationConfig.ByRig do
	for role, ids in set do
		if role ~= "rig" and typeof(ids) == "table" then
			for _, id in ids do
				note(id, string.format("infected %s %s", rig, role))
			end
		end
	end
end
for kind, set in AnimationConfig.Infected do
	for role, ids in set do
		if role ~= "rig" and typeof(ids) == "table" then
			for _, id in ids do
				note(id, string.format("%s %s", kind, role))
			end
		end
	end
end

if #order == 0 then
	warn("[CheckAnimations] nothing declared — that is itself the bug.")
	return
end

print(string.format("[CheckAnimations] asking Roblox about %d ids...", #order))

--[[ One Animation instance per id, kept parented for the whole check. A
     destroyed instance leaves its track unable to resolve the asset fetch,
     which would make this script reproduce the very bug it is looking for. ]]
local holder = Instance.new("Folder")
holder.Name = "FL_CheckAnimations"
holder.Parent = Workspace

local animations: { [number]: Animation } = {}
local pending: { Animation } = {}
for _, id in order do
	local animation = Instance.new("Animation")
	animation.Name = tostring(id)
	animation.AnimationId = "rbxassetid://" .. string.format("%d", id)
	animation.Parent = holder
	animations[id] = animation
	table.insert(pending, animation)
end

local fetched: { [string]: boolean } = {}
local reason: { [string]: string } = {}

local okPreload, preloadErr = pcall(function()
	ContentProvider:PreloadAsync(pending, function(contentString: string, status: any)
		fetched[contentString] = status == Enum.AssetFetchStatus.Success
		reason[contentString] = tostring(status)
	end)
end)

--[[ A rig to load the tracks onto. Length is only readable from a real
     AnimationTrack, and a track needs an Animator under a real Humanoid. ]]
local rig = Instance.new("Model")
rig.Name = "FL_CheckAnimationsRig"
local root = Instance.new("Part")
root.Name = "HumanoidRootPart"
root.Size = Vector3.new(2, 2, 1)
root.Anchored = true
root.CanCollide = false
root.Transparency = 1
root.CFrame = CFrame.new(0, -500, 0)
root.Parent = rig
rig.PrimaryPart = root
local humanoid = Instance.new("Humanoid")
humanoid.Parent = rig
local animator = Instance.new("Animator")
animator.Parent = humanoid
rig.Parent = Workspace

local lengths: { [number]: number } = {}
for _, id in order do
	local okLoad, track = pcall(animator.LoadAnimation, animator, animations[id])
	if okLoad and track then
		--[[ Length is populated asynchronously even after a successful fetch, so
		     it is worth a few frames rather than one read. A clip that is still
		     zero after this really is zero. ]]
		for _ = 1, 30 do
			if track.Length > 0 then
				break
			end
			task.wait()
		end
		lengths[id] = track.Length
		track:Destroy()
	end
end

rig:Destroy()
holder:Destroy()

if not okPreload then
	warn(string.format("[CheckAnimations] PreloadAsync itself failed: %s", tostring(preloadErr)))
	warn("[CheckAnimations] the usual cause is Studio Access to API Services being off.")
end

local broken, empty, good = {}, {}, 0

print("")
print("  status   id                 length   what it is")
print(
	"  ───────────────────────────────────────────────────────────────────"
)
for _, id in order do
	local key = "rbxassetid://" .. string.format("%d", id)
	local what = table.concat(labels[id], ", ")
	local length = lengths[id] or 0
	local status

	if fetched[key] == false then
		status = "REFUSED"
		table.insert(broken, string.format("%s (%s) — %s", tostring(id), what, reason[key] or "?"))
	elseif length <= 0 then
		status = "EMPTY  "
		table.insert(empty, string.format("%s (%s)", tostring(id), what))
	else
		status = "ok     "
		good += 1
	end

	print(string.format("  %s  %-18s %5.2fs   %s", status, tostring(id), length, what))
end

print("")
if #broken == 0 and #empty == 0 then
	print(string.format("[CheckAnimations] all %d ids load and have real clips behind them.", good))
else
	if #broken > 0 then
		warn(string.format("[CheckAnimations] %d id(s) THIS PLACE MAY NOT USE:", #broken))
		for _, line in broken do
			warn("    " .. line)
		end
		warn("    Re-upload these under the account or group that owns this PLACE.")
		warn("    An id uploaded under your personal account cannot be used by a")
		warn("    group-owned game, and vice versa. The id is not the problem — who")
		warn("    owns it is.")
	end
	if #empty > 0 then
		warn(string.format("[CheckAnimations] %d id(s) fetched but are zero seconds long:", #empty))
		for _, line in empty do
			warn("    " .. line)
		end
		warn("    These were published with no keyframes saved. Open each in the")
		warn("    Animation Editor, check it actually has poses on the timeline, and")
		warn("    publish again.")
	end
	print(string.format("[CheckAnimations] %d of %d are fine.", good, #order))
end
