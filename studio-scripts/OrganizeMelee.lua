--[[
	OrganizeMelee — paste into the Roblox Studio COMMAND BAR and press Enter.

	Takes the Workspace.Melee folder and puts the five weapons where the game
	loads them from, named the way WeaponConfig asks for.

	    Workspace/Melee/            ->  ReplicatedStorage/Assets/Weapons/
	        Baseball Bat                    Baseball Bat
	        Fire Axe                        Fire Axe
	        Knife                           Knife
	        Pipe                            Pipe
	        (Machete, if you add one)       Machete

	── WHAT IT DOES TO THEM ────────────────────────────────────────────────────
	Those are Tools, and the game does not want Tools — PlaceholderFactory wants a
	plain Model with a Handle. So each one is converted: a Model is created, the
	Tool's children move into it, and the Tool is removed.

	Every script inside them is DELETED, and that is deliberate rather than
	careless. Each of those weapons shipped with its own damage/hitbox/animation
	script, and running them would put five private combat systems next to the
	game's one — no friendly-fire protection, no gore, no personal difficulty, no
	Dollars, no hitmarker, and five different opinions about how much a zombie has
	left. MeleeService already does all of that for every melee at once. The
	models are the part worth keeping.

	(The game strips scripts on adoption anyway — see PlaceholderFactory's
	STRIPPED_CLASSES — so this only makes it visible in the explorer rather than
	silent at runtime.)

	Sounds, ProximityPrompts and ClickDetectors go with them, for the same reason:
	AudioConfig owns which sound a swing makes, and it now has a real sample for
	each of the five.

	── WHAT IT KEEPS ───────────────────────────────────────────────────────────
	Every BasePart, Mesh, Texture, Decal, Attachment, Weld and Motor6D. Anything
	named Handle stays named Handle and becomes the model's PrimaryPart, because
	that is the part the game welds to the survivor's hand.

	Animation instances are kept too. Nothing plays them today — the swing is a
	procedural viewmodel kick, not a played animation — but they cost nothing and
	deleting somebody's uploaded ids is not this script's decision to make.

	── SAFE TO RUN TWICE ───────────────────────────────────────────────────────
	Anything already in Assets/Weapons is left exactly as it is. One undo step
	(Ctrl+Z) puts everything back.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ChangeHistoryService = game:GetService("ChangeHistoryService")
local Workspace = game:GetService("Workspace")

--[[ Where each Tool ends up, by the name it currently has in Workspace. The
     right-hand side is WeaponConfig's `modelName` and has to match it exactly —
     that is the only string connecting a model to a weapon.

     Add a row here if you build another one; nothing else needs to change,
     because PlaceholderFactory looks the folder up by name at boot. ]]
local RENAMES: { [string]: string } = {
	["Baseball Bat"] = "Baseball Bat",
	["BaseballBat"] = "Baseball Bat",
	["Fire Axe"] = "Fire Axe",
	["FireAxe"] = "Fire Axe",
	["Knife"] = "Knife",
	["Pipe"] = "Pipe",
	["Lead Pipe"] = "Pipe",
	["Leadpipe"] = "Pipe",
	["Machete"] = "Machete",
}

--[[ Classes that do not survive the move. Scripts are the important one — see
     the header. The rest are things the game provides itself and that would
     otherwise fire twice. ]]
local STRIP = {
	"LuaSourceContainer",
	"Sound",
	"ProximityPrompt",
	"ClickDetector",
	"BodyMover",
	"Fire",
	"Smoke",
	"Sparkles",
}

local function folder(parent: Instance, name: string): Folder
	local existing = parent:FindFirstChild(name)
	if existing and existing:IsA("Folder") then
		return existing
	end
	local created = Instance.new("Folder")
	created.Name = name
	created.Parent = parent
	return created
end

--[[ Removes everything in STRIP and reports how much. Walked into a table first
     because destroying while iterating GetDescendants is how you miss half of
     them. ]]
local function strip(instance: Instance): number
	local doomed = {}
	for _, descendant in instance:GetDescendants() do
		for _, className in STRIP do
			if descendant:IsA(className) then
				table.insert(doomed, descendant)
				break
			end
		end
	end
	for _, victim in doomed do
		victim:Destroy()
	end
	return #doomed
end

--[[ The part the game welds to a hand.

     Prefers one actually named Handle, which is what a Tool has and what the
     factory looks for. Falls back to the largest part, because a model whose
     handle is called "Grip" or "Union" still has to work — the factory would
     otherwise pick one for you and it may not pick the one you meant. ]]
local function findHandle(model: Model): BasePart?
	local named = model:FindFirstChild("Handle")
	if named and named:IsA("BasePart") then
		return named
	end
	local best: BasePart? = nil
	local bestVolume = -1
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			local size = descendant.Size
			local volume = size.X * size.Y * size.Z
			if volume > bestVolume then
				best = descendant
				bestVolume = volume
			end
		end
	end
	return best
end

--[[ A Tool becomes a Model with the same contents. Done by moving children
     rather than by cloning, so nothing is duplicated and Ctrl+Z is one step. ]]
local function toModel(tool: Instance, name: string): Model
	local model = Instance.new("Model")
	model.Name = name
	for _, child in tool:GetChildren() do
		child.Parent = model
	end
	return model
end

local recording = ChangeHistoryService:TryBeginRecording("FL_OrganizeMelee", "Organize melee models")

local source = Workspace:FindFirstChild("Melee")
if not source then
	warn("[OrganizeMelee] no Workspace.Melee folder — nothing to do")
	if recording then
		ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Cancel)
	end
	return
end

local weapons = folder(folder(ReplicatedStorage, "Assets"), "Weapons")

local moved, skipped, unknown = 0, 0, {}
local stripped = 0

for _, child in source:GetChildren() do
	local target = RENAMES[child.Name]
	if not target then
		table.insert(unknown, child.Name)
		continue
	end
	if weapons:FindFirstChild(target) then
		skipped += 1
		print(string.format("[OrganizeMelee] %s is already in Assets/Weapons — left alone", target))
		continue
	end

	local model: Model
	if child:IsA("Tool") then
		model = toModel(child, target)
		child:Destroy()
	elseif child:IsA("Model") then
		model = child
		model.Name = target
	else
		table.insert(unknown, child.Name .. " (a " .. child.ClassName .. ", not a Tool or Model)")
		continue
	end

	stripped += strip(model)

	local handle = findHandle(model)
	if not handle then
		warn(string.format("[OrganizeMelee] %s has no parts at all — skipped", target))
		model:Destroy()
		continue
	end
	handle.Name = "Handle"
	model.PrimaryPart = handle

	--[[ Anchored parts do not follow a weld, so a weapon left anchored stays in
	     the middle of the map while the survivor walks away holding nothing. The
	     factory sets this too; doing it here means what you see in the explorer
	     is what the game will use. ]]
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = false
			descendant.CanCollide = false
		end
	end

	model.Parent = weapons
	moved += 1
	print(string.format("[OrganizeMelee] moved %s (%d parts)", target, #model:GetDescendants()))
end

if #source:GetChildren() == 0 then
	source:Destroy()
	print("[OrganizeMelee] Workspace.Melee was empty afterwards and has been removed")
end

print(
	string.format(
		"[OrganizeMelee] done — %d moved, %d already there, %d scripts and sounds stripped",
		moved,
		skipped,
		stripped
	)
)

if #unknown > 0 then
	warn(
		"[OrganizeMelee] left alone because nothing in RENAMES matches the name: "
			.. table.concat(unknown, ", ")
			.. "  — add a row to RENAMES at the top of this script pointing at the "
			.. "WeaponConfig modelName you want it to be."
	)
end

--[[ The one thing this script cannot check: whether the place has API access
     turned on. It has nothing to do with models, but a profile cannot load
     without it and every player would spawn with the default loadout. ]]
print("[OrganizeMelee] reminder: Game Settings > Security > Enable Studio Access to API Services")

if recording then
	ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
end
