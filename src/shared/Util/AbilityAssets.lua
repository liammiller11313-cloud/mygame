--!strict
--[[
	AbilityAssets — finding the model an ability draws itself with.

	    ReplicatedStorage/Assets/Abilities/<AbilityId>

	ReplicatedStorage specifically, and not ServerStorage as the rest of the
	asset tree allows. The turret's PLACEMENT GHOST is drawn on the client, and a
	client cannot see ServerStorage — a model kept there would work perfectly on
	the server and leave the player positioning an invisible turret. The server
	still checks ServerStorage as a courtesy, so a model in the wrong place
	deploys rather than grey-boxes; it just cannot be previewed.

	── EVERY ABILITY STILL WORKS WITHOUT ONE ───────────────────────────────────
	`find` returning nil is a normal answer, not a failure. Each ability builds
	its own procedural stand-in, the same way PlaceholderFactory grey-boxes a
	weapon nobody has uploaded — so the ability system is playable on a fresh
	place with an empty Assets folder, and a supplied model is an upgrade rather
	than a prerequisite.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local FOLDER = "Assets"
local SUBFOLDER = "Abilities"

local AbilityAssets = {}

local function lookIn(root: Instance?, id: string): Model?
	if not root then
		return nil
	end
	local assets = root:FindFirstChild(FOLDER)
	local abilities = if assets then assets:FindFirstChild(SUBFOLDER) else nil
	local found = if abilities then abilities:FindFirstChild(id) else nil
	--[[ A Model only. A Tool is accepted elsewhere in the asset tree because
	     Roblox hands weapons out as Tools; a deployable is never one, and
	     accepting whatever is there would put a Folder into the world. ]]
	return if found and found:IsA("Model") then found :: Model else nil
end

--[[ The template for an ability, or nil. Never cloned here — callers clone,
     because a caller that wants two turrets needs two clones and a caller that
     wants a ghost needs one it is going to mangle. ]]
function AbilityAssets.find(id: string): Model?
	local found = lookIn(ReplicatedStorage, id)
	if found then
		return found
	end
	--[[ The server's courtesy pass. See the header: this branch is why a model
	     in the wrong storage still deploys, and why it still cannot be
	     previewed. ]]
	if RunService:IsServer() then
		return lookIn(ServerStorage, id)
	end
	return nil
end

--[[
	A clone with nothing in it that can hurt anybody.

	Used for the placement ghost and for anything else that wants the SHAPE of a
	deployable without its behaviour. Collision, queries and touch are all off —
	a preview a player can walk into, shoot, or be blocked by is a preview that
	is part of the world, which is the one thing it must not be.
]]
function AbilityAssets.ghost(id: string, transparency: number, color: Color3?): Model?
	local template = AbilityAssets.find(id)
	if not template then
		return nil
	end
	local clone = template:Clone()
	for _, part in clone:GetDescendants() do
		if part:IsA("BasePart") then
			part.Anchored = true
			part.CanCollide = false
			part.CanQuery = false
			part.CanTouch = false
			part.CastShadow = false
			part.Transparency = transparency
			if color then
				part.Color = color
				--[[ Neon so the tint reads at the same strength whatever the
				     model's own materials were. A ghost tinted green over a dark
				     metal texture is a dark green nobody can tell from red. ]]
				part.Material = Enum.Material.Neon
			end
		elseif part:IsA("Decal") or part:IsA("Texture") then
			--[[ Stripped rather than faded. A decal on a tinted ghost is the one
			     thing that still shows its original colours through the tint. ]]
			part:Destroy()
		end
	end
	return clone
end

--[[
	Stands a model on a floor point, facing a direction.

	Shared by the turret's deploy and by the placement ghost that previews it,
	and that is the whole reason it lives here: two copies of this arithmetic
	drift, and when they drift the preview stops matching what deploys — which
	is a worse bug than no preview at all, because the player trusts it.

	Seated by BOUNDING BOX rather than by a part's centre. A supplied model can
	be any size and any of its parts can be the lowest one, so where its
	underside is has to be measured. Yaw only: `facing` is flattened, because a
	deployable tipped onto a ramp's slope reads as broken.
]]
function AbilityAssets.seat(model: Model, floor: Vector3, facing: Vector3)
	local flat = Vector3.new(facing.X, 0, facing.Z)
	local heading = if flat.Magnitude > 0.05 then flat.Unit else Vector3.zAxis
	model:PivotTo(CFrame.lookAt(floor, floor + heading))

	local box, size = model:GetBoundingBox()
	local bottom = box.Position.Y - size.Y * 0.5
	model:PivotTo(model:GetPivot() + Vector3.new(0, floor.Y - bottom, 0))
end

return AbilityAssets
