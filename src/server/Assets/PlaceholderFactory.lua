--!nonstrict
--[[
	PlaceholderFactory — where every model in the game comes from.

	It answers one question, forty-six times inside a wave: "give me the model
	for X". The answer is the USER'S model when they have supplied one and a
	procedural grey-box when they have not, and no caller can tell the
	difference. Nothing in here ever errors on a missing asset — it warns once
	and grey-boxes, so a half-populated Assets folder still plays.

	── WHERE MODELS COME FROM ───────────────────────────────────────────────────
	    ReplicatedStorage/Assets/
	        Infected/<Kind>/         one or more rig variants
	        Weapons/<modelName>      third-person / world model
	        Viewmodels/<modelName>   first-person model
	        Throwables/<Id>          only for a throwable no map places; see below
	        Pickups/<Slot>_<ItemId>  optional; grey-boxed when absent

	A Model or a TOOL is accepted anywhere in that tree. Roblox hands you a weapon
	as a Tool and that is what most supplied props are; rejecting one was a silent
	grey-box over an asset the user had placed correctly.

	ServerStorage is searched as well, because somebody dropping models into a
	place puts them wherever is convenient and being fussy about which storage
	they picked is exactly the friction this module exists to remove.

	`<Kind>` is the `Enums.Infected` key verbatim. Weapons resolve by
	WeaponConfig's `modelName` FIRST, not by the enum key: the real models are
	called "(71 Mag) PPSh-41" and "Mk 18 CQBR", which are not Luau identifiers.
	The enum id and the displayName are tried after it, then the grey-box.

	── PREPARE ONCE, CLONE MANY ────────────────────────────────────────────────
	A supplied model is never cloned raw into the world. It is copied once into a
	template cache and there it is sanitised, welded, measured, scaled and
	verified; every spawn afterwards is a single :Clone(). A wave asks for
	forty-six rigs in a few seconds, so anything done per rig is done forty-six
	times at exactly the moment the game is trying to look its best. The variant
	LIST is cached too — a horde must not re-enumerate a thirteen-model folder
	once per zombie.

	── SANITISING IS SECURITY, NOT TIDINESS ────────────────────────────────────
	Every LuaSourceContainer is destroyed on the way into the cache. Free-model
	rigs routinely ship with a Script named after somebody's username, and on
	Roblox that is the classic shape of a backdoor: it would run on OUR server,
	with full server permissions, the first time a zombie spawns. Legacy
	BodyMovers go with them, because they fight the Humanoid for control of the
	rig and win.

	── THE RIGS ARE MIXED R6 AND R15 ───────────────────────────────────────────
	Commons, Hunter, Jockey and Tank are R6; the Charger is R15 MeshParts. Two
	consequences run through everything below:
	  * a Humanoid is NEVER looked up by name — the Charger's is called "Zombie"
	    — always FindFirstChildOfClass;
	  * part names are never assumed. GameConfig.PartRegions and
	    GoreConfig.Dismemberment.Severable both carry the R6 and the R15 naming,
	    and a rig that satisfies neither is reported by name at build time rather
	    than discovered later as "dismemberment stopped working on Chargers".

	── SILHOUETTE (the grey-box half) ──────────────────────────────────────────
	In a horde the silhouette is all a player gets: at twelve metres, in fog, you
	cannot read a texture and you certainly cannot read a health bar. So each
	archetype is shaped, not just tinted — the Tank is enormous and hunched, the
	Charger drags one absurd arm, the Jockey is small and folded, the Hunter is
	compact and crouched, the Witch is slight and pale. Those proportions are
	also what the real models are expected to honour.

	── PERFORMANCE ──────────────────────────────────────────────────────────────
	Rig limbs are massless and non-collidable; only the root has a physical
	footprint. A horde whose forty-six pairs of hands each collide with the world
	arrives as a slideshow, and limbs snagging on scenery is what makes a
	shambler look drunk.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attributes = require(Shared.Net.Attributes)
local Enums = require(Shared.Enums)
local AnimationConfig = require(Shared.Config.AnimationConfig)
local GameConfig = require(Shared.Config.GameConfig)
local GoreConfig = require(Shared.Config.GoreConfig)
local InfectedConfig = require(Shared.Config.InfectedConfig)
local MapConfig = require(Shared.Config.MapConfig)
local ModelFacing = require(Shared.Util.ModelFacing)
local Registry = require(Shared.Util.Registry)
local RigUtil = require(Shared.Util.RigUtil)
local UITheme = require(Shared.Config.UITheme)
local WeaponConfig = require(Shared.Config.WeaponConfig)

local PlaceholderFactory = {}

local ASSETS_FOLDER = "Assets"
local TEMPLATE_FOLDER = "FL_Templates"
local MAP_NAME = "FadingLight_TestMap"

local function V(x: number, y: number, z: number): Vector3
	return Vector3.new(x, y, z)
end

local variantRandom = Random.new()

-- How many of each category came from a real model versus a grey-box. Printed
-- once at the end of ensureAssets: "12 of 16 weapons are yours" is the single
-- most useful line in the output for somebody who has just dropped a folder of
-- models in and wants to know whether the game found them.
--[[ Which weapons fell back to a grey box, and what names were searched to get
     there. The counts below say HOW MANY grey-boxed; this says WHICH, and with
     what spelling — which is the only form of the answer a user can act on when
     the model is sitting in the folder under a name nothing matches. ]]
local greyBoxed: { [string]: { [string]: { string } } } = {
	Weapons = {},
	Viewmodels = {},
}

local resolved = {
	Weapons = { real = 0, grey = 0 },
	Viewmodels = { real = 0, grey = 0 },
	Infected = { real = 0, grey = 0 },
}

local warned: { [string]: boolean } = {}
local function warnOnce(key: string, message: string)
	if warned[key] then
		return
	end
	warned[key] = true
	warn("[PlaceholderFactory] " .. message)
end

-- ════════════════════════════════════════════════════════════════════════════
--  Asset resolution
-- ════════════════════════════════════════════════════════════════════════════

local function folderIn(parent: Instance, name: string): Folder
	local existing = parent:FindFirstChild(name)
	if existing and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = parent
	return folder
end

--[[ The private template cache. Deliberately NOT under Assets/, so a prepared
     copy can never be picked up by the next lookup and mistaken for something
     the user supplied — which is how one gun quietly becomes three. ]]
local function privateFolder(category: string): Folder
	return folderIn(folderIn(ServerStorage, TEMPLATE_FOLDER), category)
end

--[[
	Parks a finished template and returns it.

	Templates stay server-side by default. The server clones them into Workspace
	and Roblox replicates that clone on its own, so a second copy sitting in
	ReplicatedStorage is every mesh in the model duplicated for no reader.

	The exception is anything the CLIENT has to assemble for itself: the viewmodel
	it draws in first person, and the world model the shop spins in its preview.
	When the client has no way to reach the source — we grey-boxed the gun, or the
	user keeps their models in ServerStorage — the prepared template is published
	so both of those still have something to show. A user who keeps their models
	in ReplicatedStorage already has them on every client and nothing is copied.

	Publishing never takes a name that is already occupied: two children with one
	name makes FindFirstChild a coin toss for everybody downstream, and the user's
	own model has to win that name.
]]
local function park(category: string, name: string, model: Model, publish: boolean?): Model
	model.Name = name
	local public = if publish then folderIn(folderIn(ReplicatedStorage, ASSETS_FOLDER), category) else nil
	if public and not public:FindFirstChild(name) then
		model.Parent = public
	else
		model.Parent = privateFolder(category)
	end
	return model
end

--[[
	Every model an entry offers: itself when it is one, its model children when it
	is a folder of variants.

	── A TOOL COUNTS ───────────────────────────────────────────────────────────
	Roblox hands you a weapon as a Tool. That is what the toolbox gives you, what
	a free model of a molotov is, and what somebody who has built their own throws
	together — a Handle, some parts, a Sound or two. This used to accept only a
	Model, so a Tool dropped into the right folder with the right name was rejected
	SILENTLY and the game grey-boxed over the top of it, which is the worst
	possible outcome: the user has done everything right and there is no message
	saying otherwise.

	A Tool is a container of parts with a Handle, which is exactly what everything
	downstream of here wants. The only thing it is not is the class name this
	function was checking for.
]]
local function isSupplyContainer(instance: Instance): boolean
	return instance:IsA("Model") or instance:IsA("Tool")
end

--[[ Every name an infected kind's asset folder might be under: the definition's
     own `modelFolder` first, then the id.

     Built by hand rather than as { definition.modelFolder, kind }, because
     modelFolder is nil for every kind but one and a nil in slot 1 of a table
     constructor is a HOLE — a lookup that would have run zero passes, greyboxing
     the entire roster to add one folder alias. ]]
local function infectedNames(kind: string, definition): { string }
	local names = { kind }
	if definition and definition.modelFolder then
		table.insert(names, 1, definition.modelFolder)
	end
	return names
end

local function modelsIn(entry: Instance): { Instance }
	if isSupplyContainer(entry) then
		return { entry }
	end
	local models = {}
	for _, child in entry:GetChildren() do
		if isSupplyContainer(child) then
			table.insert(models, child)
		end
	end
	return models
end

--[[
	A supplied entry as a Model this module can own and take apart.

	Never the user's instance: everything past this point sanitises, welds,
	scales and reparents, and doing that to what is sitting in their Explorer
	would edit their asset out from under them.

	A Tool's contents are lifted into a fresh Model rather than the Tool being
	cloned as-is. A Tool parented into Workspace is a pickup Roblox itself will
	offer to anybody who touches it, it carries its own activation behaviour, and
	none of that survives contact with a game that owns its own carrying. The
	parts are all that was ever wanted.

	── EXCEPT THE GRIP, WHICH IS THE ONE THING WORTH KEEPING ───────────────────
	This used to throw the Tool's `Grip` away with the rest of it, and that was
	the reason every weapon out of a classic toolbox pack sat wrong in the fist.

	A purpose-built FPS model is authored barrel-down-Z and needs no correction,
	which is what ensureGrip's inference assumes. A classic Roblox tool is not
	built that way and never had to be: the artist modelled the handle at
	whatever angle was convenient and then wrote the correction into the Tool's
	Grip property. Throwing that away does not leave the model uncorrected — it
	leaves it corrected by a GUESS, taken from the longest axis of a mesh whose
	longest axis is a sword's blade or a launcher's tube.

	So the Grip comes across, as the attachment this pipeline already prefers
	over anything it works out for itself. The maths is the same identity from
	both ends: Roblox welds a tool with Handle.CFrame = Hand * C0 * Grip:Inverse,
	and holdPose places a model with Handle.CFrame = target * Grip:Inverse. Same
	CFrame, in the same space (the Handle's), so it transfers across unchanged.

	Strictly additive. A Model is not a Tool and never reaches this; a Tool whose
	Grip is identity — which is every tool nobody bothered to pose — is left to
	the inference exactly as before, because an identity Grip is not an answer,
	it is the absence of one.
]]
local function cloneAsModel(entry: Instance): Model?
	if entry:IsA("Model") then
		return entry:Clone()
	end
	if not entry:IsA("Tool") then
		return nil
	end
	local model = Instance.new("Model")
	model.Name = entry.Name
	for _, child in entry:GetChildren() do
		child:Clone().Parent = model
	end
	--[[ A Tool's Handle is its grip by definition, so it is the pivot every
	     caller here would otherwise have to guess at. ]]
	local handle = model:FindFirstChild("Handle")
	if handle and handle:IsA("BasePart") then
		model.PrimaryPart = handle

		--[[ Against the identity rather than against nothing: `~=` on two CFrames
		     is exact, and a pose somebody nudged to 1e-7 of identity is still not
		     a pose. The tolerance is per-component and deliberately loose. ]]
		local grip = (entry :: Tool).Grip
		local posed = grip.Position.Magnitude > 1e-3
			or math.abs(grip.RightVector:Dot(Vector3.xAxis) - 1) > 1e-3
			or math.abs(grip.UpVector:Dot(Vector3.yAxis) - 1) > 1e-3

		--[[ Searched here rather than through findAttachmentNamed, which is
		     declared two thousand lines below this and would be a forward
		     reference. The scan is the same one, over a model that was assembled
		     three lines ago and is as small as it will ever be. ]]
		local already = false
		for _, descendant in model:GetDescendants() do
			if descendant:IsA("Attachment") and descendant.Name == "Grip" then
				already = true
				break
			end
		end

		if posed and not already then
			local authored = Instance.new("Attachment")
			authored.Name = "Grip"
			authored.CFrame = grip
			authored.Parent = handle
		end
	end
	return model
end

--[[
	The first of `names` the user has supplied in this category, as a Model or as
	a Folder of variants. Name order is the priority order and beats storage
	order, so a `modelName` in ServerStorage still wins over an enum id in
	ReplicatedStorage.

	── AN EMPTY FOLDER IS NOT AN ANSWER ────────────────────────────────────────
	This used to return the first entry it FOUND rather than the first entry with
	anything in it, and that was survivable only because a folder nobody had
	filled generally did not exist.

	ensureAssetFolders changed that. It now guarantees a correctly named folder
	for every kind in ReplicatedStorage — which is the whole point of it, and
	which means anyone keeping their rigs in ServerStorage had an empty
	ReplicatedStorage folder created directly in front of theirs. Found first,
	returned, no models in it, kind grey-boxed. The feature meant to make
	supplying a rig easier would have quietly stopped an entire storage location
	from working.

	So the search keeps going until it finds something it can actually use, and
	an empty folder is just a folder waiting for a model.
]]
--[[ "Pipe Bomb", "pipe_bomb" and "PipeBomb" are the same answer to everyone
     except FindFirstChild. Folded to lowercase alphanumerics so a supplied model
     only has to be named RIGHT, not spelled the way an enum happens to. ]]
local function foldName(name: string): string
	return (string.gsub(string.lower(name), "[^%w]", ""))
end

local function suppliedEntry(category: string, names: { string }): Instance?
	local function usable(entry: Instance): boolean
		return (isSupplyContainer(entry) or entry:IsA("Folder")) and #modelsIn(entry) > 0
	end

	for _, name in names do
		for _, root in { ReplicatedStorage, ServerStorage } do
			local assets = root:FindFirstChild(ASSETS_FOLDER)
			local folder = assets and assets:FindFirstChild(category)
			local entry = folder and folder:FindFirstChild(name)
			if entry and usable(entry) then
				return entry
			end
		end
	end

	--[[
		Second pass, and only after an exact match failed: the same names compared
		loosely.

		The enum id for a pipe bomb is "PipeBomb"; the obvious thing to call the
		model you built is "Pipe Bomb". Those are the same answer to every person
		who has ever looked at them and different answers to FindFirstChild — so
		this grey-boxed a model sitting in the correct folder under a perfectly
		reasonable name, and said nothing about why.

		A scan rather than another FindFirstChild, because the entire point is that
		we do not know how they spelled it. One walk of one folder, only on a miss,
		and the result is cached in a template like everything else here.
	]]
	for _, name in names do
		if name and name ~= "" then
			local wanted = foldName(name)
			for _, root in { ReplicatedStorage, ServerStorage } do
				local assets = root:FindFirstChild(ASSETS_FOLDER)
				local folder = assets and assets:FindFirstChild(category)
				if folder then
					for _, child in folder:GetChildren() do
						if foldName(child.Name) == wanted and usable(child) then
							return child
						end
					end
				end
			end
		end
	end
	return nil
end

--[[
	Classes that never survive the trip into the template cache.

	LuaSourceContainer is the security line and it is not negotiable: a Script
	inside a downloaded zombie runs on OUR server with full permissions. The rest
	are things that would quietly take control of an asset away from the game — a
	BodyGyro out-steering the Humanoid, a ProximityPrompt offering the player a
	verb no system here implements, and a Sound the model plays for itself.

	That last one matters at horde scale: every noise in this game is played
	through AudioService, which enforces AudioConfig.Mix's voice limits. A rig
	that brings its own looping moan multiplies straight past that budget by
	forty-six.
]]
--[[
	How much bigger than a TANK a boss is allowed to be.

	── WHY THIS IS A RATIO AND NOT A NUMBER OF STUDS ───────────────────────────
	It was a number of studs — 15 tall by 8 across — and the first real boot it
	ever ran on fired it at the Tank, which is the creature it had been
	calibrated against. That is a check failing on its own reference case, and a
	warning that cries wolf about the thing it was built to measure is worse than
	no warning at all.

	The number was wrong because it was arithmetic on the GREY-BOX proportions in
	the SHAPES table below: a Tank laid out from those measures about 10.6 studs.
	Every rig in a real place is the artist's instead, and that Tank measures
	13.6. Nothing in this file can know an artist's units in advance, so any
	absolute here is a guess dressed as a constraint.

	A ratio cannot make that mistake. The Tank is the biggest thing this project
	ships and the biggest thing its maps are known to carry, so it is the honest
	yardstick — and it can never fail itself, because its own ratio is 1.

	── AND WHY THERE IS NO WIDTH RULE ANY MORE ─────────────────────────────────
	The width came from GetBoundingBox on the prepared template, and a template
	is in whatever pose the artist saved. The Tank's box is 14.2 across against
	13.6 tall: a ratio of 1.04, and a human's arm span is famously about equal to
	their height. That 14.2 is fingertip to fingertip on a T-POSE, and arms are
	not what catches on a doorway — they swing, and the animation puts them at
	the body's sides the moment it walks.

	A bounding box cannot recover shoulder width from an arbitrary saved pose.
	So the width is REPORTED, because it is worth seeing, and nothing is asserted
	from it.

	── WHAT IT STILL CATCHES ───────────────────────────────────────────────────
	The failure that actually happens: a model dropped in at the wrong scale.
	1.35 puts the ceiling at about eighteen studs against today's Tank, which
	passes the Metallic at seventeen and trips anything somebody forgot to size.

	The Apex Tank is NOT bigger than a plain one today, whatever its tier says:
	EliteTiers.Apex asks for x1.12 and RigUtil.scaleRig delivers it by writing
	the Humanoid's scale NumberValues — which adoptRig has already destroyed by
	then, on purpose, so that spawning cannot scale a rig a second time on top of
	the geometry pass. So the yardstick is the same Tank either way.

	Checked once at boot against the prepared template, because the answer is a
	product of an artist's units and a config multiplier and nothing earlier in
	the pipeline knows it.
]]
local BOSS_HEIGHT_RATIO = 1.35

local STRIPPED_CLASSES = table.freeze({
	"LuaSourceContainer",
	"BodyMover",
	"ProximityPrompt",
	"ClickDetector",
	"Sound",
	--[[ A Camera called ThumbnailCamera is what Studio leaves inside a model
	     somebody generated a marketplace icon for, and it is in more supplied
	     models than not. Harmless in a folder and not harmless in a weapon: it
	     rides the clone into the world, gets welded to the character with
	     everything else, and turns up in the bounding box every measurement in
	     this pipeline is taken from — the fit, the muzzle, the grip. ]]
	"Camera",
})

--[[
	Lifts every Animation id out of a rig into an inert Folder before sanitise()
	runs, because the ids live as CHILDREN of the Animate script and would be
	destroyed along with it.

	That mattered more than it looks: stripping scripts is a real security measure
	(a free-model rig with a `require(<id>)` in it runs with full server
	permissions), but doing it naively also threw away the walk cycle, which is
	why the horde slid around instead of walking.

	Roblox's own Animate script nests these as
	    Animate > <role StringValue> > <Animation>
	so the PARENT's name is the role — "walk", "run", "idle", "attack". Custom
	rigs put them in a Configuration or a plain Folder with the same shape, and
	this reads all of them the same way. The result is a Folder of Folders of
	Animations: no code, nothing to execute, safe to keep.
]]
local ANIMATION_FOLDER = "FL_Animations"

--[[
	Which animation source each prepared variant ended up on, for the boot summary.

	A rig that ships its own clips keeps them — it knows its own proportions
	better than a generic package does — and one that ships none gets this game's
	configured set. Both are correct, and from the outside they are
	indistinguishable: a folder of thirty-five Commons where some animate from
	their own clips and some from the built-in ones looks like the built-in ones
	being applied at random.

	So it says so. Named per variant rather than counted, because the answer a
	person needs is which MODEL to open.
]]
local animationSources: { own: { [string]: { string } }, config: { [string]: { string } } } = {
	own = {},
	config = {},
}

--[[ Which build each kind was judged to be. See the note where this is written:
     it is the single fact that decides which clip set a body gets, and getting
     it wrong is silent. ]]
local animationRig: { [string]: string } = {}

--[[ And WHY, for an R15 verdict: the name of the part that decided it. R6 is
     the absence of evidence and has none, so this stays empty for one. See
     RigUtil.rigTypeOf — printing the cause is what turns "but I built that as
     R6" into a part somebody can go and rename. ]]
local animationRigWhy: { [string]: string } = {}

--[[ Per kind, one line per VARIANT that has something wrong with its rig. See
     where this is filled: it is the answer to "which of my thirty-five models is
     the broken one", printed at boot instead of discovered by playing. ]]
local rigFaults: { [string]: { string } } = {}

--[[ Rigs that shipped with no Animator. The game adds one, so this is a note
     about the MODELS rather than a fault in the game — collected and printed as
     a single line, because it is routinely most of the roster. ]]
local missingAnimator: { string } = {}

local function harvestAnimations(model: Model): number
	--[[
		READ EVERYTHING FIRST, then rebuild. The order is the whole correctness
		of this function.

		It used to destroy any existing FL_Animations folder before scanning. That
		is fine for the case it was written for — a rig arriving with an Animate
		script, harvested once — and silently wrong for the obvious way to give a
		model clips by hand, which is to build an FL_Animations folder in the
		shape the animator already reads. Destroying it first deleted the
		Animations inside it, so the scan that followed found nothing and the rig
		fell back to the configured set. The folder simply vanished, with no error
		and no warning.

		Gathering the ids before touching anything makes a hand-authored folder a
		perfectly good SOURCE, and makes re-harvesting the same model idempotent
		rather than destructive.
	]]
	type Clip = { role: string, animation: Animation }
	local clips: { Clip } = {}

	for _, descendant in model:GetDescendants() do
		if not descendant:IsA("Animation") or descendant.AnimationId == "" then
			continue
		end
		local parent = descendant.Parent
		-- A bare Animation with no meaningful parent name still beats nothing;
		-- file it under "idle" so at least something plays.
		local role = if parent and parent ~= model then string.lower(parent.Name) else "idle"
		--[[ Cloned HERE, before anything is destroyed, which is what lets the
		     folder below be rebuilt from real instances rather than from
		     hand-built ones. AnimationCache's instances are shared for the whole
		     server and must not be reparented into a template. ]]
		table.insert(clips, { role = role, animation = descendant:Clone() })
	end

	--[[ Nothing found means nothing to rebuild, and the existing folder — if
	     there is one — was empty of usable ids anyway. Left alone rather than
	     destroyed: an empty folder is harmless and a person put it there. ]]
	if #clips == 0 then
		return 0
	end

	local existing = model:FindFirstChild(ANIMATION_FOLDER)
	if existing then
		existing:Destroy()
	end

	local store = Instance.new("Folder")
	store.Name = ANIMATION_FOLDER
	store.Parent = model

	local buckets: { [string]: Folder } = {}
	for _, clip in clips do
		local bucket = buckets[clip.role]
		if not bucket then
			bucket = Instance.new("Folder")
			bucket.Name = clip.role
			bucket.Parent = store
			buckets[clip.role] = bucket
		end

		clip.animation.Name = clip.role
		clip.animation.Parent = bucket
	end

	return #clips
end

local function sanitise(instance: Instance): number
	local removed = 0
	for _, descendant in instance:GetDescendants() do
		for _, className in STRIPPED_CLASSES do
			if descendant:IsA(className) then
				descendant:Destroy()
				removed += 1
				break
			end
		end
	end
	return removed
end

local function basePartsOf(instance: Instance): { BasePart }
	local parts = {}
	if instance:IsA("BasePart") then
		table.insert(parts, instance)
	end
	for _, descendant in instance:GetDescendants() do
		if descendant:IsA("BasePart") then
			table.insert(parts, descendant)
		end
	end
	return parts
end

local function largestPart(instance: Instance): BasePart?
	local best: BasePart? = nil
	local bestVolume = -1
	for _, part in basePartsOf(instance) do
		local size = part.Size
		local volume = size.X * size.Y * size.Z
		if volume > bestVolume then
			best, bestVolume = part, volume
		end
	end
	return best
end

--[[
	The extents of everything under `instance`, expressed in `frame`'s own space.

	Model:GetBoundingBox answers in the primary part's frame, and a user's gun
	model frequently has no primary part at all — so the corners are transformed
	by hand here. Eight corners per part, once per template, never per shot.
]]
local function extentsIn(instance: Instance, frame: CFrame): (Vector3, Vector3)
	local inverse = frame:Inverse()
	local min = V(math.huge, math.huge, math.huge)
	local max = V(-math.huge, -math.huge, -math.huge)
	for _, part in basePartsOf(instance) do
		local half = part.Size * 0.5
		local relative = inverse * part.CFrame
		for x = -1, 1, 2 do
			for y = -1, 1, 2 do
				for z = -1, 1, 2 do
					local corner = relative * V(half.X * x, half.Y * y, half.Z * z)
					min = min:Min(corner)
					max = max:Max(corner)
				end
			end
		end
	end
	if min.X == math.huge then
		return Vector3.zero, Vector3.zero
	end
	return min, max
end

-- ════════════════════════════════════════════════════════════════════════════
--  Part helpers
-- ════════════════════════════════════════════════════════════════════════════

--[[ A prop part: rendered, hittable, but never physical. Used for every piece of
     a grey-box rig, gun and pickup. Map geometry uses `mapBox` instead. ]]
local function prop(
	name: string,
	size: Vector3,
	cframe: CFrame,
	color: Color3,
	material: Enum.Material?
): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = cframe
	part.Color = color
	part.Material = material or Enum.Material.SmoothPlastic
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CastShadow = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Locked = true
	return part
end

--[[ Renders a part as an ellipsoid without changing what a bullet hits. A Ball
     shaped Part would round the COLLISION geometry too, quietly shrinking the
     head hitbox — and a head hitbox smaller than the head it draws is the worst
     possible bug in a game whose entire skill expression is the headshot. ]]
local function roundOff(part: BasePart)
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Sphere
	mesh.Parent = part
end

local function weldTo(anchor: BasePart, part: BasePart)
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = anchor
	weld.Part1 = part
	weld.Parent = part
end

--[[
	Scales a whole rig geometrically: sizes, joint sockets, attachment points and
	custom meshes together.

	This exists because RigUtil.scaleRig can only drive the Humanoid's R15 scale
	NumberValues, and four of the six supplied rigs are R6 and carry none — a
	Tank left at engine scale is Common-sized, which is not a cosmetic problem,
	it is the entire read of the archetype. So scale is applied here, once, at
	template time, and the NumberValues are removed on the way through so that
	InfectedService's RigUtil.scaleRig call stays a deliberate no-op rather than
	multiplying a 2.35x Tank by 2.35 again.

	Only a FileMesh SpecialMesh needs its Scale touched: every other MeshType
	already renders at the part's size, so scaling both would double the effect.
]]
local function scaleRigGeometry(model: Model, scale: number)
	if scale == 1 then
		return
	end
	local pivot = model:GetPivot()
	local inverse = pivot:Inverse()
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			local relative = inverse * descendant.CFrame
			descendant.Size *= scale
			descendant.CFrame = pivot * ((relative - relative.Position) + relative.Position * scale)
		elseif descendant:IsA("JointInstance") then
			descendant.C0 = (descendant.C0 - descendant.C0.Position) + descendant.C0.Position * scale
			descendant.C1 = (descendant.C1 - descendant.C1.Position) + descendant.C1.Position * scale
		elseif descendant:IsA("Attachment") then
			descendant.Position *= scale
		elseif descendant:IsA("SpecialMesh") and descendant.MeshType == Enum.MeshType.FileMesh then
			descendant.Scale *= scale
		end
	end
end

-- ════════════════════════════════════════════════════════════════════════════
--  Infected rigs
--
--  The joint names below are load-bearing for the GREY-BOX rigs. GoreService
--  looks a limb up by the name of the Motor6D's CHILD part and reads its
--  ragdoll limits from the Motor6D's own name; GoreConfig.Dismemberment.
--  per-joint ragdoll limits from the Motor6D's own name; GoreConfig.
--  Dismemberment.Severable lists the part names it may take off. All three
--  have to agree, so every rig — grey-box or supplied — is verified against
--  GoreConfig once, when its template is prepared.
-- ════════════════════════════════════════════════════════════════════════════

local RIG_JOINTS = table.freeze({
	{ joint = "Root", parent = "HumanoidRootPart", child = "LowerTorso" },
	{ joint = "Waist", parent = "LowerTorso", child = "UpperTorso" },
	{ joint = "Neck", parent = "UpperTorso", child = "Head" },
	{ joint = "LeftShoulder", parent = "UpperTorso", child = "LeftUpperArm" },
	{ joint = "LeftElbow", parent = "LeftUpperArm", child = "LeftLowerArm" },
	{ joint = "LeftWrist", parent = "LeftLowerArm", child = "LeftHand" },
	{ joint = "RightShoulder", parent = "UpperTorso", child = "RightUpperArm" },
	{ joint = "RightElbow", parent = "RightUpperArm", child = "RightLowerArm" },
	{ joint = "RightWrist", parent = "RightLowerArm", child = "RightHand" },
	{ joint = "LeftHip", parent = "LowerTorso", child = "LeftUpperLeg" },
	{ joint = "LeftKnee", parent = "LeftUpperLeg", child = "LeftLowerLeg" },
	{ joint = "LeftAnkle", parent = "LeftLowerLeg", child = "LeftFoot" },
	{ joint = "RightHip", parent = "LowerTorso", child = "RightUpperLeg" },
	{ joint = "RightKnee", parent = "RightUpperLeg", child = "RightLowerLeg" },
	{ joint = "RightAnkle", parent = "RightLowerLeg", child = "RightFoot" },
})

local LEFT_ARM = table.freeze({ "LeftUpperArm", "LeftLowerArm", "LeftHand", "@LeftElbow", "@LeftWrist" })
local RIGHT_ARM =
	table.freeze({ "RightUpperArm", "RightLowerArm", "RightHand", "@RightElbow", "@RightWrist" })
local UPPER_BODY = table.freeze({
	"UpperTorso",
	"Head",
	"@Waist",
	"@Neck",
	"@LeftShoulder",
	"@RightShoulder",
	"LeftUpperArm",
	"LeftLowerArm",
	"LeftHand",
	"@LeftElbow",
	"@LeftWrist",
	"RightUpperArm",
	"RightLowerArm",
	"RightHand",
	"@RightElbow",
	"@RightWrist",
})

--[[
	Proportions, in studs, BEFORE InfectedConfig's per-kind `scale` is applied.

	One entry per key in Enums.Infected and nothing else — this table is indexed
	by enum value at module scope, so a stale key here is not a missing model, it
	is `table index is nil` at require time and the whole server loses its asset
	factory.

	`hunch`, `armPitch`, `roll` and `headTilt` are degrees, and they are doing as
	much work as the sizes: a Common and a Hunter share most of their numbers and
	are still unmistakable from across a street, because one stands up and the
	other is folded almost double.
]]
local SHAPES = {
	[Enums.Infected.Common] = {
		head = V(0.90, 0.85, 0.90),
		neck = 0.10,
		upperTorso = V(1.70, 1.35, 0.95),
		lowerTorso = V(1.50, 0.55, 0.90),
		upperArm = V(0.62, 1.15, 0.62),
		lowerArm = V(0.55, 1.05, 0.55),
		hand = V(0.55, 0.42, 0.62),
		upperLeg = V(0.72, 1.25, 0.72),
		lowerLeg = V(0.66, 1.15, 0.66),
		foot = V(0.70, 0.35, 1.05),
		root = V(1.50, 1.40, 0.90),
		legSpread = 0.44,
		armDrop = 0.16,
		hunch = 14,
		armPitch = 18,
		roll = 0,
		headTilt = 10,
	},

	-- Folded into a crouch with arms that nearly touch the floor. Reads as
	-- "about to leap" from any angle, which is the only warning a lone survivor
	-- is going to get.
	[Enums.Infected.Hunter] = {
		head = V(0.78, 0.72, 0.78),
		neck = 0.05,
		upperTorso = V(1.45, 1.15, 0.85),
		lowerTorso = V(1.30, 0.50, 0.80),
		upperArm = V(0.55, 1.25, 0.55),
		lowerArm = V(0.50, 1.20, 0.50),
		hand = V(0.55, 0.50, 0.75),
		upperLeg = V(0.78, 0.95, 0.78),
		lowerLeg = V(0.70, 0.85, 0.70),
		foot = V(0.70, 0.35, 1.10),
		root = V(1.30, 1.20, 0.80),
		legSpread = 0.50,
		armDrop = 0.12,
		hunch = 58,
		armPitch = 52,
		roll = 0,
		headTilt = -30, -- looking up at you from under the hunch
	},

	-- Small, short-legged and folded almost flat, with arms far too long for it
	-- and a head far too big. Everything about the proportions says "this thing
	-- is going to end up on your shoulders", and at 0.82 scale it disappears
	-- into a crowd until it moves.
	[Enums.Infected.Jockey] = {
		head = V(0.88, 0.82, 0.88),
		neck = 0.02,
		upperTorso = V(1.20, 0.95, 0.78),
		lowerTorso = V(1.05, 0.45, 0.72),
		upperArm = V(0.46, 1.30, 0.46),
		lowerArm = V(0.42, 1.25, 0.42),
		hand = V(0.50, 0.45, 0.62),
		upperLeg = V(0.58, 0.80, 0.58),
		lowerLeg = V(0.52, 0.72, 0.52),
		foot = V(0.58, 0.30, 0.90),
		root = V(1.05, 1.00, 0.72),
		legSpread = 0.38,
		armDrop = 0.10,
		hunch = 46,
		armPitch = 40,
		roll = 0,
		headTilt = -18,
	},

	-- One arm the size of the rest of it, and enough mass behind it that the
	-- charge reads as a threat before you can see what it is. The asymmetry is
	-- the tell and it survives being seen for a quarter of a second down a
	-- corridor.
	[Enums.Infected.Charger] = {
		head = V(0.72, 0.62, 0.72),
		neck = 0.0,
		upperTorso = V(2.30, 1.60, 1.20),
		lowerTorso = V(1.80, 0.60, 1.00),
		upperArm = V(0.70, 1.40, 0.70),
		lowerArm = V(0.62, 1.30, 0.62),
		hand = V(0.60, 0.50, 0.70),
		upperLeg = V(0.95, 1.10, 0.95),
		lowerLeg = V(0.90, 1.00, 0.90),
		foot = V(0.90, 0.40, 1.20),
		root = V(1.80, 1.40, 1.00),
		legSpread = 0.58,
		armDrop = 0.20,
		hunch = 26,
		armPitch = 16,
		roll = -9, -- listing toward the heavy side
		headTilt = 8,
		leftArmScale = 0.50,
		rightArmScale = 2.20,
		rightArmLength = 1.35,
	},

	-- Slight, pale and still. She is the only thing in the game a player is
	-- supposed to walk around, so she must not read as a threat until she does.
	--[[
		── THE THREE THAT HAD NONE ──────────────────────────────────────────────
		Tongue, Boomer and Spitter shipped without a shape entry, and that was
		never a cosmetic gap: `buildRig` returns nil without one, the caller then
		has nothing to add to `prepared`, and the kind ends up with no template at
		all. Not a grey box — no creature. A misnamed or missing Assets.Infected
		folder for any of these three deleted them from the game and said one line
		about it.

		They are supplied models today and none of this is drawn. That is exactly
		when to write it: the fallback that only runs on the day something is
		wrong is the one nobody notices is absent.

		Each is built off the Common's proportions and then bent toward what the
		creature does, the same way the Hunter and Jockey above are — a silhouette
		has to be readable across a room before the animation starts.
	]]

	--[[ Thin, long-armed and stooped, with an oversized head: everything about
	     it is reach. It attacks from ninety studs and dies at close range, so the
	     silhouette has to say "far away" from far away. ]]
	[Enums.Infected.Tongue] = {
		head = V(0.95, 0.90, 0.95),
		neck = 0.12,
		upperTorso = V(1.45, 1.40, 0.80),
		lowerTorso = V(1.25, 0.55, 0.75),
		upperArm = V(0.50, 1.45, 0.50),
		lowerArm = V(0.46, 1.50, 0.46),
		hand = V(0.55, 0.55, 0.80),
		upperLeg = V(0.72, 1.10, 0.72),
		lowerLeg = V(0.66, 1.05, 0.66),
		foot = V(0.70, 0.35, 1.05),
		root = V(1.25, 1.30, 0.75),
		legSpread = 0.52,
		armDrop = 0.20,
		hunch = 26,
		armPitch = 14,
		roll = 0,
		headTilt = -12,
	},

	--[[ Enormous torso, tiny everything else. The whole read is a thing that is
	     about to come apart, and at 1.35 scale it is the widest silhouette in the
	     horde without being the tallest — which is what makes shooting it at
	     close range a decision. ]]
	[Enums.Infected.Boomer] = {
		head = V(0.80, 0.70, 0.80),
		neck = 0.04,
		upperTorso = V(2.30, 1.55, 1.90),
		lowerTorso = V(2.10, 0.75, 1.75),
		upperArm = V(0.60, 0.95, 0.60),
		lowerArm = V(0.55, 0.90, 0.55),
		hand = V(0.60, 0.55, 0.70),
		upperLeg = V(0.80, 0.75, 0.80),
		lowerLeg = V(0.72, 0.70, 0.72),
		foot = V(0.75, 0.35, 1.00),
		root = V(2.10, 1.40, 1.70),
		legSpread = 0.62,
		armDrop = 0.02,
		hunch = 8,
		armPitch = -6, -- arms pushed out by the belly rather than hanging
		roll = 0,
		headTilt = 8,
	},

	--[[ Narrow, hunched and neckless, with the head carried forward — it spits
	     from the front of a body angled at the floor, which is where the acid
	     goes. Slightest frame in the roster after the Jockey. ]]
	[Enums.Infected.Spitter] = {
		head = V(0.80, 0.75, 0.90),
		neck = 0.02,
		upperTorso = V(1.30, 1.30, 0.75),
		lowerTorso = V(1.15, 0.55, 0.70),
		upperArm = V(0.48, 1.10, 0.48),
		lowerArm = V(0.44, 1.05, 0.44),
		hand = V(0.50, 0.48, 0.66),
		upperLeg = V(0.70, 1.15, 0.70),
		lowerLeg = V(0.64, 1.10, 0.64),
		foot = V(0.66, 0.32, 1.00),
		root = V(1.15, 1.25, 0.70),
		legSpread = 0.46,
		armDrop = 0.16,
		hunch = 34,
		armPitch = 20,
		roll = 0,
		headTilt = -18,
	},

	[Enums.Infected.Witch] = {
		head = V(0.76, 0.74, 0.76),
		neck = 0.08,
		upperTorso = V(1.25, 1.15, 0.72),
		lowerTorso = V(1.10, 0.45, 0.66),
		upperArm = V(0.40, 1.20, 0.40),
		lowerArm = V(0.36, 1.15, 0.36),
		hand = V(0.50, 0.90, 0.70), -- claws
		upperLeg = V(0.55, 1.10, 0.55),
		lowerLeg = V(0.50, 1.00, 0.50),
		foot = V(0.55, 0.30, 0.85),
		root = V(1.10, 1.20, 0.66),
		legSpread = 0.34,
		armDrop = 0.12,
		hunch = 30,
		armPitch = 46,
		roll = 0,
		headTilt = 22,
		eyes = true,
	},

	-- The set piece. Shoulders wider than a doorway and a head you can barely
	-- find, so the answer is never "aim for the head", it is "everybody move".
	[Enums.Infected.Tank] = {
		head = V(0.70, 0.50, 0.70),
		neck = 0.0,
		upperTorso = V(2.60, 1.35, 1.50),
		lowerTorso = V(1.90, 0.55, 1.20),
		upperArm = V(1.10, 1.30, 1.10),
		lowerArm = V(1.00, 1.25, 1.00),
		hand = V(1.10, 0.75, 1.25),
		upperLeg = V(1.00, 0.85, 1.00),
		lowerLeg = V(0.95, 0.85, 0.95),
		foot = V(1.00, 0.40, 1.40),
		root = V(1.90, 1.40, 1.20),
		legSpread = 0.80,
		armDrop = 0.10,
		hunch = 30,
		armPitch = 14,
		roll = 0,
		headTilt = 12,
		shoulders = true,
	},

	--[[
		Not a body that got bigger — a machine. Everything here is chosen against
		the Tank standing next to it, because the whole point of a second boss is
		that a player can tell at fifty studs which one is walking at them.

		TALLER, NOT WIDER. The proportions sum to 5.70 against the Tank's 4.50, so
		at their respective scales it stands about 17 studs to the Tank's 10.6 —
		both GREY-BOX figures, which is the only comparison this table can make
		and is not the one the game ships (a supplied Tank measures 13.6; see
		BOSS_HEIGHT_RATIO for the mistake that came of confusing the two) —
		and its shoulders come out barely wider, because a thing that reads as
		big by being WIDE is a thing that gets stuck in the first doorway. It
		towers instead.

		UPRIGHT. Hunch 18 against the Tank's 30: a Tank lopes, this does not
		slouch, and standing straight is most of what makes it read as built
		rather than turned.

		THE ARMS ARE THE DRILLS. Long lower arms tapering into small hands, which
		at this scale is a drill barrel and its bit. That silhouette is the one
		thing a player has to recognise instantly, because it is what the charge
		is pointed with.

		This is the fallback, not the intent — the supplied rig under
		Assets/Infected/Metallic Boss is what should actually turn up. It exists
		because without a shape entry buildRig returns nil, and a kind with no
		grey box is a kind that silently fails to arrive on the two waves that
		ask for it.
	]]
	[Enums.Infected.Metallic] = {
		head = V(0.60, 0.45, 0.65),
		neck = 0.05,
		upperTorso = V(2.10, 1.55, 1.35),
		lowerTorso = V(1.55, 0.60, 1.10),
		upperArm = V(1.05, 1.45, 1.05),
		lowerArm = V(0.95, 1.70, 0.95),
		hand = V(0.80, 0.90, 0.80),
		upperLeg = V(1.05, 1.30, 1.05),
		lowerLeg = V(0.95, 1.30, 0.95),
		foot = V(1.10, 0.45, 1.50),
		root = V(1.55, 1.50, 1.10),
		legSpread = 0.72,
		armDrop = 0.06,
		hunch = 18,
		armPitch = 8,
		roll = 0,
		headTilt = 0,
		shoulders = true,
		eyes = true,
	},

	--[[
		The Bacteria Monster's fallback.

		Every VERTICAL dimension is the Metallic's, deliberately and to the
		decimal: 0.45 + 0.05 + 1.55 + 0.60 + 1.30 + 1.30 + 0.45 is 5.70 studs
		unscaled, which is the number InfectedConfig's `scale` of 2.11 was solved
		backwards from to reach a targetHeight of 12. Change a Y here and that
		arithmetic has to be redone.

		What differs is BULK and posture. It is wider than the Metallic at every
		joint and hunched twice as far — a swollen thing that grew rather than a
		machine that was built — and it has no shoulders and no eyes, because
		both are pieces of anatomy and this is supposed to read as a growth
		wearing the shape of a person.

		The supplied rig under Assets/Infected/Bacteria Monster is what should
		actually turn up. This exists because without a shape entry buildRig
		returns nil, and a kind with no grey box is a kind that silently fails to
		arrive on the one wave that asks for it.
	]]
	[Enums.Infected.BacteriaMonster] = {
		head = V(0.75, 0.45, 0.80),
		neck = 0.05,
		upperTorso = V(2.40, 1.55, 1.70),
		lowerTorso = V(1.90, 0.60, 1.40),
		upperArm = V(1.15, 1.45, 1.15),
		lowerArm = V(1.05, 1.70, 1.05),
		hand = V(0.95, 0.90, 0.95),
		upperLeg = V(1.20, 1.30, 1.20),
		lowerLeg = V(1.10, 1.30, 1.10),
		foot = V(1.25, 0.45, 1.60),
		root = V(1.90, 1.50, 1.40),
		legSpread = 0.86,
		armDrop = 0.10,
		hunch = 34,
		armPitch = 4,
		roll = 0,
		headTilt = 12,
		shoulders = false,
		eyes = false,
	},
}

--[[ Verifies once, per rig template, that every part GoreConfig is allowed to
     sever actually exists on this rig with a Motor6D behind it. A rig that
     quietly lacks a joint name would show up much later as "dismemberment
     stopped working on Chargers", which is a miserable thing to debug. ]]
local function verifySeverable(key: string, model: Model)
	--[[ One walk of the rig, resolving which end of each joint is the limb. Not
	     Part1: real models disagree about that in three different ways and
	     RigUtil.mapMotorChildren spells them out. Reading Part1 here reported a
	     rig's head joint missing when the neck was simply stored on the head. ]]
	local motors: { [string]: boolean } = {}
	for _, child in RigUtil.mapMotorChildren(model) do
		motors[child.Name] = true
	end

	-- GoreConfig's Severable list carries both namings. A rig only has to satisfy
	-- the one it actually uses, so the R6 aliases (the names with a space in them)
	-- are the checklist for an R6 rig and the rest are the checklist for an R15
	-- one. Holding a hand-made R6 model to the R15 list would report thirteen
	-- missing joints on a rig that is perfectly fine.
	local isR6 = model:FindFirstChild("UpperTorso", true) == nil
	local missing = {}
	for _, name in GoreConfig.Dismemberment.Severable do
		local isAlias = string.find(name, " ") ~= nil
		if isAlias == isR6 and name ~= "Head" and not motors[name] then
			table.insert(missing, name)
		end
	end
	if not motors.Head then
		table.insert(missing, "Head")
	end
	if #missing > 0 then
		--[[ What the rig DOES have, alongside what it does not.

		     "Missing Left Arm" on its own is a dead end — the natural reading is
		     that the limb is absent, when in practice the joint is there under a
		     name nobody standardised: "LeftArm", "Arm_L", "l_arm". Listing the
		     rig's actual Motor6D names turns the warning from a complaint into
		     the two-minute fix, which is either renaming the joint or adding its
		     name to GoreConfig.Dismemberment.Severable. ]]
		local present = {}
		for name in motors do
			table.insert(present, name)
		end
		table.sort(present)

		if #present == 0 then
			--[[ A rig with NO Motor6Ds is a different and much worse problem than
			     one missing a few, and "missing severable joints" buries it.
			     Nothing can animate a body with no joints: an AnimationTrack
			     drives Motor6Ds, and so does the client's procedural fallback,
			     which finds none and skips the body entirely. It will slide around
			     rigid and no amount of configuration will change that — the model
			     itself has to be rigged. ]]
			warnOnce(
				"nojoints:" .. key,
				string.format(
					"the %s rig template has NO Motor6D joints. If the model is welded rather "
						.. "than rigged then nothing can animate or dismember it and it will slide "
						.. "around rigid — open it in Studio and check its limbs are joined to the "
						.. "torso with Motor6D. If it is a legacy R6 model, this may be a false "
						.. "alarm: Roblox builds those joints when the body is parented into "
						.. "Workspace, which has not happened yet here. GoreService re-checks the "
						.. "real body on its first corpse and warns then if it is genuinely "
						.. "jointless.",
					key
				)
			)
		else
			warnOnce(
				"severable:" .. key,
				string.format(
					"the %s rig is missing severable joints: %s — GoreService will silently refuse to "
						.. "dismember those parts, and animation cannot move them either. The joints "
						.. "it does have are: %s. Rename one to match, or add its name to "
						.. "GoreConfig.Dismemberment.Severable.",
					key,
					table.concat(missing, ", "),
					table.concat(present, ", ")
				)
			)
		end
	end
end

--[[
	Reports, once per kind, anything a bullet can hit whose name GameConfig does
	not recognise. Those parts score as Torso (RigUtil's safe default), so the
	symptom is a rig that simply never takes a headshot — silent, and fatal to
	the one rule the whole combat loop is built on.
]]
--[[
	Makes cosmetic geometry non-queryable so shots pass through it.

	Anything named in GameConfig.PassThroughParts, plus every part inside an
	Accessory — Roblox calls those "Handle" too, and a rig assembled from Toolbox
	parts brings both kinds. Returns how many it changed.

	This has to run BEFORE auditHitRegions or the audit reports the very parts
	this just made unhittable.
]]
local function applyPassThrough(model: Model): number
	local changed = 0
	for _, descendant in model:GetDescendants() do
		if not descendant:IsA("BasePart") then
			continue
		end
		local cosmetic = GameConfig.PassThroughParts[descendant.Name] == true
			or descendant:FindFirstAncestorWhichIsA("Accoutrement") ~= nil
		if cosmetic and descendant.CanQuery then
			descendant.CanQuery = false
			descendant.CanTouch = false
			changed += 1
		end
	end
	return changed
end

local function auditHitRegions(kind: string, model: Model)
	local hasHead = false
	--[[ Distinct NAMES, with how many parts carry each. The list used to be one
	     entry per part and capped at eight, which on the rigs that actually have
	     this problem is the worst possible combination: a model with thirty
	     parts called "Part" spent the whole budget saying so and hid every other
	     name behind it. The name is the actionable thing — it is what goes in
	     GameConfig.PartRegions — and the count is only there to say how much of
	     the body is affected. ]]
	local counts: { [string]: number } = {}
	local order: { string } = {}
	for _, part in RigUtil.getBodyParts(model) do
		--[[ A part nothing can raycast against cannot score as anything, so it is
		     not a hit-region problem. Reporting it would be telling somebody to
		     name a part in PartRegions that will never be consulted. ]]
		if not part.CanQuery then
			continue
		end
		local region = GameConfig.PartRegions[part.Name]
		if region == Enums.HitRegion.Head then
			hasHead = true
		elseif not region then
			if not counts[part.Name] then
				counts[part.Name] = 0
				table.insert(order, part.Name)
			end
			counts[part.Name] += 1
		end
	end

	local unknown = {}
	table.sort(order)
	for _, name in order do
		if #unknown >= 8 then
			table.insert(unknown, string.format("and %d more name(s)", #order - 8))
			break
		end
		local count = counts[name]
		table.insert(unknown, if count > 1 then string.format("%s x%d", name, count) else name)
	end
	if not hasHead then
		warnOnce(
			"nohead:" .. kind,
			string.format(
				"the %s rig has no part named in GameConfig.PartRegions as a head; every shot on it "
					.. "will score as a torso hit and headshotAlwaysKills can never fire",
				kind
			)
		)
	end
	if #unknown > 0 then
		warnOnce(
			"regions:" .. kind,
			string.format(
				"%s rig parts are not in GameConfig.PartRegions and will score as Torso: %s",
				kind,
				table.concat(unknown, ", ")
			)
		)
	end
end

--[[
	The Hunter's rig carries a "FakeHead" mesh over its real "Head".

	Hit regions are resolved by part NAME (RigUtil.getHitRegion → the
	GameConfig.PartRegions table), which has no FakeHead entry, so a shot that
	lands on the visible head would score as a torso hit — on the one archetype
	players are most likely to be shooting at the head of, mid-pounce.

	The fix inside this module's remit is to take the fake head out of the
	raycast entirely so the ray reaches the real Head behind it, and to grow that
	real Head to the size of the mesh it is hiding under when it is invisible, so
	that what a player sees is what they hit. The clean fix is one line in
	GameConfig.PartRegions, which this module does not own — see the report.
]]
local function reconcileFakeHead(kind: string, model: Model)
	local head = model:FindFirstChild("Head", true)
	local fake = model:FindFirstChild("FakeHead", true)
	if not head or not fake or not head:IsA("BasePart") or not fake:IsA("BasePart") then
		return
	end

	fake.CanQuery = false
	fake.CanTouch = false
	if head.Transparency >= 1 then
		head.Size = V(
			math.max(head.Size.X, fake.Size.X),
			math.max(head.Size.Y, fake.Size.Y),
			math.max(head.Size.Z, fake.Size.Z)
		)
	end
	--[[ Only worth saying when the suggestion is still outstanding. PartRegions
	     has carried FakeHead for a while now, so this fired every boot telling
	     somebody to do a thing that was already done — which is how a log full of
	     real warnings stops being read. ]]
	if not GameConfig.PartRegions.FakeHead then
		warnOnce(
			"fakehead:" .. kind,
			string.format(
				"the %s rig has both Head and FakeHead; FakeHead is now non-queryable so hits pass "
					.. "through to the real head. Adding `FakeHead = Enums.HitRegion.Head` to "
					.. "GameConfig.PartRegions would make that unnecessary",
				kind
			)
		)
	end
end

--[[
	Lays out one archetype and joints it.

	The layout runs bottom-up in a neutral standing pose, then bends: arms pitch
	about their own shoulder, the head tilts about the neck, and the whole upper
	body hunches about the waist. Doing it in that order means a shape table only
	has to describe proportions and three angles, and the hunch lands correctly on
	arms that have already been posed.

	Joint sockets travel through the same transforms as the parts they connect, so
	`motor.C0` really is the socket. GoreService reads that CFrame to decide where
	a severed limb bleeds from, and a stump that bleeds from the middle of the arm
	that just left is a tell nobody can unsee.
]]
local function buildRig(kind: string): Model?
	local definition = InfectedConfig.get(kind)
	local shape = SHAPES[kind]
	if not definition or not shape then
		return nil
	end

	local scale = definition.scale
	local pose: { [string]: CFrame } = {}
	local sizes: { [string]: Vector3 } = {}

	local function place(name: string, size: Vector3, position: Vector3)
		sizes[name] = size * scale
		pose[name] = CFrame.new(position * scale)
	end
	local function socket(name: string, position: Vector3)
		pose["@" .. name] = CFrame.new(position * scale)
	end

	-- ── vertical stack, feet on y = 0 ───────────────────────────────────────
	local footTop = shape.foot.Y
	local kneeY = footTop + shape.lowerLeg.Y
	local hipY = kneeY + shape.upperLeg.Y
	local waistY = hipY + shape.lowerTorso.Y
	local shoulderTopY = waistY + shape.upperTorso.Y
	local shoulderY = shoulderTopY - shape.armDrop
	local headY = shoulderTopY + shape.neck + shape.head.Y * 0.5

	local spread = shape.legSpread
	for _, side in { -1, 1 } do
		local prefix = if side < 0 then "Left" else "Right"
		local x = side * spread
		place(prefix .. "Foot", shape.foot, V(x, shape.foot.Y * 0.5, -0.1))
		place(prefix .. "LowerLeg", shape.lowerLeg, V(x, footTop + shape.lowerLeg.Y * 0.5, 0))
		place(prefix .. "UpperLeg", shape.upperLeg, V(x, kneeY + shape.upperLeg.Y * 0.5, 0))
		socket(prefix .. "Ankle", V(x, footTop, 0))
		socket(prefix .. "Knee", V(x, kneeY, 0))
		socket(prefix .. "Hip", V(x, hipY, 0))
	end

	place("LowerTorso", shape.lowerTorso, V(0, hipY + shape.lowerTorso.Y * 0.5, 0))
	place("UpperTorso", shape.upperTorso, V(0, waistY + shape.upperTorso.Y * 0.5, 0))
	place("Head", shape.head, V(0, headY, 0))
	place("HumanoidRootPart", shape.root, V(0, hipY + shape.root.Y * 0.5, 0))
	socket("Root", V(0, hipY + shape.lowerTorso.Y * 0.5, 0))
	socket("Waist", V(0, waistY, 0))
	socket("Neck", V(0, shoulderTopY, 0))

	-- ── arms, per side, with the Charger's asymmetry baked in ────────────────
	for _, side in { -1, 1 } do
		local prefix = if side < 0 then "Left" else "Right"
		local thickness = if side < 0 then (shape.leftArmScale or 1) else (shape.rightArmScale or 1)
		local length = if side < 0
			then (shape.leftArmLength or shape.leftArmScale or 1)
			else (shape.rightArmLength or shape.rightArmScale or 1)

		local function limb(base: Vector3): Vector3
			return V(base.X * thickness, base.Y * length, base.Z * thickness)
		end

		local upper, lower, hand = limb(shape.upperArm), limb(shape.lowerArm), limb(shape.hand)
		local x = side * (shape.upperTorso.X * 0.5 + upper.X * 0.5)
		local elbowY = shoulderY - upper.Y
		local wristY = elbowY - lower.Y

		place(prefix .. "UpperArm", upper, V(x, shoulderY - upper.Y * 0.5, 0))
		place(prefix .. "LowerArm", lower, V(x, elbowY - lower.Y * 0.5, 0))
		place(prefix .. "Hand", hand, V(x, wristY - hand.Y * 0.5, 0))
		socket(prefix .. "Shoulder", V(x, shoulderY, 0))
		socket(prefix .. "Elbow", V(x, elbowY, 0))
		socket(prefix .. "Wrist", V(x, wristY, 0))
	end

	-- ── posing ──────────────────────────────────────────────────────────────
	local function bend(names, pivot: Vector3, rotation: CFrame)
		local at = CFrame.new(pivot * scale)
		local delta = at * rotation * at:Inverse()
		for _, name in names do
			local current = pose[name]
			if current then
				pose[name] = delta * current
			end
		end
	end

	-- Negative pitch about X leans toward -Z, which is the direction a rig faces.
	local pitch = function(degrees: number)
		return CFrame.Angles(-math.rad(degrees), 0, 0)
	end

	-- A pitch is a rotation about X, so only the pivot's height and depth matter;
	-- both shoulders swing about the same horizontal line through the chest.
	bend(LEFT_ARM, V(0, shoulderY, 0), pitch(shape.armPitch))
	bend(RIGHT_ARM, V(0, shoulderY, 0), pitch(shape.armPitch))
	bend({ "Head" }, V(0, shoulderTopY, 0), pitch(shape.headTilt))
	bend(UPPER_BODY, V(0, waistY, 0), pitch(shape.hunch))
	if shape.roll ~= 0 then
		bend(UPPER_BODY, V(0, hipY, 0), CFrame.Angles(0, 0, math.rad(shape.roll)))
	end

	-- ── instances ───────────────────────────────────────────────────────────
	local body = definition.bodyColor
	local accent = definition.accentColor
	-- Extremities in the accent colour: on a Common that is dried blood on the
	-- hands and feet, on the Witch it is the claws, and either way it breaks up
	-- an otherwise uniform silhouette so limbs read as limbs.
	local ACCENTED = table.freeze({
		LeftHand = true,
		RightHand = true,
		LeftFoot = true,
		RightFoot = true,
		LowerTorso = true,
	})

	local model = Instance.new("Model")
	model.Name = definition.displayName

	local parts: { [string]: BasePart } = {}
	for name, size in sizes do
		local color = if name == "Head"
			then body:Lerp(accent, 0.25)
			elseif ACCENTED[name] then accent
			else body
		local part = prop(name, size, pose[name], color)
		part.CastShadow = name == "UpperTorso" or name == "Head"
		part.Parent = model
		parts[name] = part
	end

	local root = parts.HumanoidRootPart
	root.Transparency = 1
	root.CastShadow = false
	model.PrimaryPart = root

	roundOff(parts.Head)

	-- Decoration that extends the silhouette stays queryable — a Tank's shoulders
	-- are part of the target. Decoration that sits ON a hit surface does not, or
	-- it would steal headshots by absorbing the ray meant for the head behind it.
	if shape.shoulders then
		for _, side in { -1, 1 } do
			local radius = shape.upperTorso.Y * 0.85
			local hump = prop(
				"ShoulderPad",
				V(radius, radius, radius) * scale,
				parts.UpperTorso.CFrame
					* CFrame.new(
						side * shape.upperTorso.X * 0.42 * scale,
						shape.upperTorso.Y * 0.3 * scale,
						0
					),
				body:Lerp(accent, 0.5)
			)
			roundOff(hump)
			hump.Parent = model
			weldTo(parts.UpperTorso, hump)
		end
	end
	if shape.eyes then
		local eyes = prop(
			"Eyes",
			V(shape.head.X * 0.62, shape.head.Y * 0.16, 0.08) * scale,
			parts.Head.CFrame * CFrame.new(0, 0, -shape.head.Z * 0.5 * scale),
			accent,
			Enum.Material.Neon
		)
		eyes.CanQuery = false
		eyes.Parent = model
		weldTo(parts.Head, eyes)
	end

	for _, spec in RIG_JOINTS do
		local part0, part1 = parts[spec.parent], parts[spec.child]
		local at = pose["@" .. spec.joint]
		if part0 and part1 and at then
			local motor = Instance.new("Motor6D")
			motor.Name = spec.joint
			motor.Part0 = part0
			motor.Part1 = part1
			motor.C0 = part0.CFrame:Inverse() * at
			motor.C1 = part1.CFrame:Inverse() * at
			-- Parented to the CHILD, matching Roblox's own rigs and matching what
			-- GoreService assumes when it severs a limb and expects the joint to
			-- leave with it.
			motor.Parent = part1
		end
	end

	local humanoid = Instance.new("Humanoid")
	humanoid.RigType = Enum.HumanoidRigType.R15
	-- The root's bottom face sits exactly at the hip, so the distance from it to
	-- the floor IS hipY. Measured from the built pose rather than assumed: every
	-- archetype has a different leg length, and a Tank floating a stud above the
	-- floor is exactly as wrong as a Jockey buried in it.
	humanoid.HipHeight = hipY * scale
	humanoid.Parent = model

	--[[
		NOTE (contract): the Humanoid deliberately carries NO BodyHeightScale /
		BodyWidthScale / BodyDepthScale / HeadScale NumberValues, which makes
		RigUtil.scaleRig a no-op on these rigs. InfectedConfig's `scale` is
		already baked into every size above, exactly as it is baked into a
		supplied rig by scaleRigGeometry. Scale is applied once, here, and never
		again downstream.
	]]

	return model
end

--[[
	Turns any rig — grey-box or supplied — into something the game can spawn.

	`scale` is 1 for the grey-box (which lays itself out pre-scaled) and
	definition.scale for a supplied rig. Everything else is identical for both,
	which is the point: a hand-modelled Tank and a box Tank have to behave the
	same way under fire or the grey-box stops being a useful stand-in.
]]
--[[
	How much to multiply a SUPPLIED rig by.

	Ordinarily the definition's `scale`, which is the right answer for anything
	standard-sized: every Common and every special is a humanoid rig, and 1.25
	means what it says on one of those.

	It stops meaning anything the moment a definition's size is load-bearing.
	The Metallic has to read as bigger than a Tank and still fit through the
	doors a Tank fits through, and neither of those is a fact about the units an
	artist happened to build in — a rig already modelled giant, multiplied by the
	number that makes a standard rig giant, is a boss that cannot follow anybody
	indoors. So a definition may state a `targetHeight` instead, and this
	measures what turned up and works out the rest.

	Clamped, because the measurement can be wrong: a rig that arrives as a single
	flat plate measures almost nothing tall and would ask for a multiplier in the
	hundreds. The clamp turns that into a visibly wrong body rather than a server
	that stops responding, and the warning says which rig did it.
]]
local SCALE_MIN = 0.2
local SCALE_MAX = 8

local function rigScale(kind: string, model: Model, definition): number
	local target = definition.targetHeight
	if not target or target <= 0 then
		return definition.scale
	end

	local _, size = model:GetBoundingBox()
	if size.Y < 0.05 then
		warnOnce(
			"flatrig:" .. kind,
			string.format(
				'the %s rig "%s" measures %.2f studs tall, which is not a height a '
					.. "targetHeight can be worked out from; falling back to scale %.2f",
				kind,
				model.Name,
				size.Y,
				definition.scale
			)
		)
		return definition.scale
	end

	local wanted = target / size.Y
	local clamped = math.clamp(wanted, SCALE_MIN, SCALE_MAX)
	if math.abs(clamped - wanted) > 0.001 then
		warnOnce(
			"scaleclamp:" .. kind,
			string.format(
				'the %s rig "%s" is %.2f studs tall and would need x%.2f to reach the %d '
					.. "studs its definition asks for, which is outside the sane range; "
					.. "clamped to x%.2f. Check the rig is not a stray part or a flat plate.",
				kind,
				model.Name,
				size.Y,
				wanted,
				target,
				clamped
			)
		)
	end
	return clamped
end

local function adoptRig(model: Model, kind: string, definition, scale: number): Model?
	-- Order matters: the ids have to be lifted out before the script holding them
	-- is destroyed.
	local harvested = harvestAnimations(model)
	sanitise(model)
	--[[
		A rig with no ids of its own is only a problem if nothing else can animate
		it.

		AnimationConfig supplies a complete set per rig type, so for every kind in
		the roster this is now the normal case rather than a fault — and the old
		warning told somebody to go and add an Animate script that would have been
		ignored in favour of the config anyway. It fires only when the config has
		nothing addressed to this rig's joints either, which is the case where the
		body really does fall through to the client's procedural poser.
	]]
	--[[ Which SOURCE this variant will animate from, recorded per model so the
	     boot summary can name the ones falling back. "Some of them use the
	     built-in clips instead of mine" is impossible to act on without knowing
	     WHICH, and nothing in the game was saying. ]]
	local sourceList = if harvested > 0 then animationSources.own else animationSources.config
	local bucket = sourceList[kind]
	if not bucket then
		bucket = {}
		sourceList[kind] = bucket
	end
	table.insert(bucket, model.Name)

	--[[ And which BUILD the game decided this rig is, because that is what picks
	     the clip set. An animation addresses named joints, so a rig judged wrong
	     here gets a set aimed at joints it does not have: the tracks load, report
	     themselves as playing, and move nothing — and the procedural poser stands
	     down because tracks are playing. Recorded per kind so the summary can say
	     "Tank: R15" rather than leaving it to be inferred. ]]

	local detectedRig, decidedBy = AnimationConfig.rigOf(model)
	--[[
		A VARIANT THAT DISAGREES WITH ITS OWN KIND is reported by name.

		animationRig is keyed by KIND, so with thirty-five Commons the last one
		prepared writes the verdict and the boot summary prints it against all
		thirty-five names. One model that reads R15 while the rest read R6 is
		therefore completely invisible there — and it is the single worst thing
		that can happen to a rig, because it is handed a clip set addressing joints
		it does not have, which loads, reports itself playing, and moves nothing.

		Cheap to catch: the first variant of a kind sets the expectation and any
		later one that differs says so.
	]]
	local expectedRig = animationRig[kind]
	if expectedRig and expectedRig ~= detectedRig then
		local list = rigFaults[kind]
		if not list then
			list = {}
			rigFaults[kind] = list
		end
		table.insert(
			list,
			string.format(
				"%s — reads as %s while the rest of this kind read as %s%s, so it is handed clips "
					.. "for joints it does not have",
				model.Name,
				detectedRig,
				expectedRig,
				if decidedBy then " (it has a part named " .. decidedBy .. ")" else ""
			)
		)
	end
	animationRig[kind] = detectedRig
	if decidedBy then
		animationRigWhy[kind] = decidedBy
	end

	if harvested == 0 and not AnimationConfig.forInfected(kind, AnimationConfig.rigOf(model)) then
		warnOnce(
			"noanims:" .. kind,
			string.format(
				"the %s rig carries no Animation ids and AnimationConfig has no set for an %s rig, "
					.. "so it falls through to the client's procedural gait. Add a set under "
					.. "AnimationConfig.ByRig, or give the rig an Animate script before importing it.",
				kind,
				AnimationConfig.rigOf(model)
			)
		)
	end

	-- NEVER by name. The Charger's Humanoid is called "Zombie".
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		warnOnce(
			"nohumanoid:" .. kind .. ":" .. model.Name,
			string.format('the %s rig "%s" has no Humanoid and cannot be spawned', kind, model.Name)
		)
		model:Destroy()
		return nil
	end

	-- Removed BEFORE the geometry is scaled: with these gone RigUtil.scaleRig is
	-- a no-op, so InfectedService's spawn-time call cannot scale a rig a second
	-- time on top of what happens below.
	for _, name in { "BodyDepthScale", "BodyHeightScale", "BodyWidthScale", "HeadScale" } do
		local value = humanoid:FindFirstChild(name)
		if value then
			value:Destroy()
		end
	end
	scaleRigGeometry(model, scale)
	humanoid.HipHeight *= scale

	--[[
		── FLATTEN THE RIG, AND THIS IS THE ONE THAT MATTERS MOST ──────────────
		Roblox resolves a character's rig by NAME AMONG THE HUMANOID'S SIBLINGS.
		Humanoid.RootPart is the child of THIS MODEL called HumanoidRootPart — not
		a descendant, a child. Group a rig's parts into a Folder or a sub-Model
		while assembling it in Studio, which is an entirely ordinary thing to do,
		and the Humanoid resolves no rig at all: RootPart is nil, the character
		never becomes a character, and the Animator drives nothing.

		Everything else about such a model looks perfect. The parts are there, the
		Motor6Ds are there and correctly wired, the names are right, the clips
		load and report themselves playing. Every diagnostic in this project said
		"fully jointed" about exactly these models, because they are.

		It also explains why it was SOME of the thirty-five Commons and not all of
		them: the discriminator is how each individual model happens to be
		organised in the explorer, and thirty-five models assembled by hand over
		time are a mix.

		So the rig is flattened here, once, at boot, on the template — every body
		of that kind is cloned from it afterwards. Accessories are left completely
		alone: their parts belong inside them, that is how Roblox expects an
		accessory, and pulling a Handle out would break the attachment welding it
		to the head. Emptied containers go, so the model does not keep a Folder
		that now holds nothing.
	]]
	local flattened = 0
	local movedNames: { string } = {}
	local emptied: { Instance } = {}
	for _, descendant in model:GetDescendants() do
		if descendant.Parent == model then
			continue
		end
		if not descendant:IsA("BasePart") and not descendant:IsA("Motor6D") then
			continue
		end
		if descendant:FindFirstAncestorWhichIsA("Accoutrement") then
			continue
		end
		--[[
			ONLY the parts Roblox's character resolution actually looks for.

			This moved anything nested, and the first real boot showed exactly what
			that costs: eleven Commons reported one nested part each, and the part
			was `Hair (was in Head)`. A hair mesh inside a head is an ordinary way
			to build a model. It has nothing to do with Humanoid.RootPart — which
			resolved fine on every one of those rigs, because HumanoidRootPart was
			already a direct child — so the repair fixed nothing, announced a fault
			that did not exist, and hoisted a cosmetic to the Model where
			getBodyParts counts it as a limb: the ragdoll then constrains it and
			dismemberment can blow it off.

			A nested HumanoidRootPart or Torso is a real fault and is still moved.
			A nested anything-else is the author's business.
		]]
		if descendant:IsA("BasePart") and not RigUtil.isStandardPart(descendant.Name) then
			continue
		end
		--[[ A Motor6D conventionally lives inside Part0 and is perfectly happy
		     there — it is reparented only when the part it lives in is itself
		     being moved, so the two stay together. ]]
		if descendant:IsA("Motor6D") and descendant.Parent and descendant.Parent:IsA("BasePart") then
			continue
		end
		local container = descendant.Parent
		--[[ Named, and named with where it came FROM. "kept 1 of its parts inside
		     a Folder" is true and useless — the part that matters is almost always
		     HumanoidRootPart, and knowing that turns a puzzle into a drag-and-drop. ]]
		table.insert(
			movedNames,
			string.format("%s (was in %s)", descendant.Name, if container then container.Name else "?")
		)
		descendant.Parent = model
		flattened += 1
		if container and container ~= model then
			table.insert(emptied, container)
		end
	end
	for _, container in emptied do
		if container.Parent and #container:GetChildren() == 0 then
			container:Destroy()
		end
	end
	if flattened > 0 then
		warnOnce(
			"nested:" .. kind .. ":" .. model.Name,
			string.format(
				"%s rig %q kept %d RIG part(s) inside a Folder or sub-Model: %s. Roblox resolves a "
					.. "character's rig by name among the HUMANOID'S SIBLINGS, so a body part down "
					.. "there is a body part the Humanoid cannot see — while every joint check calls "
					.. "the rig fully jointed, because it is. Moved up at boot. Drag them directly "
					.. "under the Model in Studio to fix it there, or run studio-scripts/RigDoctor "
					.. "in REPAIR mode to do it for you.",
				kind,
				model.Name,
				flattened,
				RigUtil.tally(movedNames)
			)
		)
	end

	local root = RigUtil.getRoot(model)
	if not root then
		warnOnce("noroot:" .. kind, string.format("the %s rig has no BasePart at all", kind))
		model:Destroy()
		return nil
	end
	model.PrimaryPart = root

	--[[
		The remaining way to have no Humanoid.RootPart, checked by NAME rather than
		by reading the property.

		Humanoid.RootPart is resolved by the engine and this template is sitting in
		ServerStorage, not Workspace — so reading it here would risk warning about
		every rig in the game on the strength of an implementation detail. The name
		is the thing that decides it and the name is checkable anywhere: Roblox
		looks for a sibling called exactly "HumanoidRootPart", and a rig whose root
		is called "Root", "HRP" or "Torso" does not have one however tidily its
		parts are arranged.
	]]
	if not model:FindFirstChild("HumanoidRootPart") then
		warnOnce(
			"norootpart:" .. kind .. ":" .. model.Name,
			string.format(
				"%s rig %q has no part called HumanoidRootPart directly under the Model — the "
					.. "nearest thing to a root is %q. Roblox resolves Humanoid.RootPart by that "
					.. "exact name among the Humanoid's siblings, and without it the body is not a "
					.. "character: it cannot walk, and nothing can animate it. Rename that part in "
					.. "Studio.",
				kind,
				model.Name,
				root.Name
			)
		)
	end

	humanoid.MaxHealth = definition.health
	humanoid.Health = definition.health
	humanoid.WalkSpeed = definition.walkSpeed
	humanoid.UseJumpPower = true
	humanoid.JumpPower = definition.jumpPower
	-- BreakJointsOnDeath would shatter the rig the instant health hits zero,
	-- before GoreService can decide whether this body ragdolls, loses a limb or
	-- comes apart entirely. RequiresNeck would kill it outright the moment a
	-- headshot severs the neck, which is a decapitation, not a bug.
	humanoid.BreakJointsOnDeath = false
	humanoid.RequiresNeck = false
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid.HealthDisplayDistance = 0
	humanoid.NameDisplayDistance = 0

	-- A rig that arrived with an Animate script lost it to sanitise(), so the
	-- Animator is put back: it costs nothing, and without one nothing can ever
	-- play a walk cycle on these bodies.
	if not humanoid:FindFirstChildOfClass("Animator") then
		local animator = Instance.new("Animator")
		animator.Parent = humanoid
		--[[ Collected rather than warned per model. It is worth knowing which of
		     your models ship without an Animator — without one a body cannot play
		     a single clip — but thirty-seven identical lines is not a report, it
		     is a wall, and the first boot that printed them buried the seven rigs
		     that had something the game could NOT fix. One line, at the end. ]]
		table.insert(missingAnimator, kind .. "/" .. model.Name)
	end

	local shadowCaster = largestPart(model)
	for _, part in basePartsOf(model) do
		part.Anchored = false
		part.Locked = true
		-- Only the root has a physical footprint. Forty-six rigs whose every limb
		-- collides is forty-six times more contact solving than the horde needs,
		-- and limbs snagging on scenery is what makes a shambler look drunk.
		part.CanCollide = part == root
		part.Massless = part ~= root
		-- One shadow per body, at most. Shadows are per-part work and a horde is
		-- the worst possible moment to pay for it twelve times per zombie.
		part.CastShadow = part == shadowCaster
	end

	-- Contract: infected never collide with each other. Set here so the clone
	-- starts correct; InfectedService sets it again at spawn, which is free.
	local ok, err = pcall(RigUtil.setCollisionGroup, model, "Infected")
	if not ok then
		warnOnce(
			"collisiongroup",
			string.format('could not use the "Infected" collision group: %s', tostring(err))
		)
	end

	reconcileFakeHead(kind, model)
	-- Before the audit: it reports parts that can be hit, and this is what
	-- decides which ones those are.
	applyPassThrough(model)
	auditHitRegions(kind, model)
	verifySeverable(kind, model)

	model:SetAttribute(Attributes.Infected.Kind, kind)
	-- Which of the thirteen commons this is. Purely diagnostic, and worth its
	-- keep the first time one variant turns out to be missing an arm joint.
	model:SetAttribute("FL_Variant", model.Name)

	--[[
		THE RIG DIAGNOSIS, LAST — after every repair this function performs.

		It ran near the top, which made it describe the model as SUPPLIED rather
		than as prepared, and the first real boot proved how badly that misleads:
		thirty-six of forty-three rigs were reported as having no Animator, by a
		check running two hundred lines before the code that creates one. Thirty-
		six lines of noise, in the one report whose whole job is to be the signal.

		Running it here means it lists what is STILL wrong once boot has done what
		it can — which is exactly the set that gets repaired again on every single
		body, forever, and therefore exactly the set worth fixing in Studio. The
		faults boot DOES fix announce themselves individually where they are fixed,
		so nothing is lost by leaving them out here.
	]]
	local faults = RigUtil.describeFaults(RigUtil.diagnose(model))
	if faults then
		local list = rigFaults[kind]
		if not list then
			list = {}
			rigFaults[kind] = list
		end
		table.insert(list, string.format("%s — %s", model.Name, faults))
	end

	return model
end

--[[
	Every prepared rig template for a kind, built on the first request.

	The LIST is what is cached, not just the models: picking a variant during a
	wave must be one array index and one :Clone(), never a folder walk. That
	random pick is the entire reason a horde of thirteen commons reads as a crowd
	instead of a clone army.
]]
local infectedVariants: { [string]: { Model } } = {}

local function variantsFor(kind: string): { Model }
	local cached = infectedVariants[kind]
	if cached then
		return cached
	end

	local prepared: { Model } = {}
	infectedVariants[kind] = prepared

	local definition = InfectedConfig.get(kind)
	if not definition then
		warnOnce("kind:" .. kind, string.format("no InfectedConfig entry for %q", kind))
		return prepared
	end

	local folder = folderIn(privateFolder("Infected"), kind)
	--[[ The definition's own folder name first, then the id. The same order the
	     weapon pipeline uses for modelName, and for the same reason: the folder
	     is called whatever the artist called it, and "Metallic Boss" holding a
	     rig named "Metallic" is an ordinary way to have organised one. ]]
	local supplied = suppliedEntry("Infected", infectedNames(kind, definition))
	if supplied then
		for _, source in modelsIn(supplied) do
			local copy = cloneAsModel(source)
			local rig = copy and adoptRig(copy, kind, definition, rigScale(kind, copy, definition))
			if rig then
				rig.Parent = folder
				table.insert(prepared, rig)
			end
		end
	end

	if #prepared > 0 then
		resolved.Infected.real += 1
		return prepared
	end

	resolved.Infected.grey += 1
	if supplied then
		warnOnce(
			"unusable:" .. kind,
			string.format("Assets.Infected.%s held nothing spawnable; grey-boxing that kind", kind)
		)
	end
	local grey = buildRig(kind)
	if grey then
		-- Scale 1: buildRig already laid itself out at definition.scale.
		local rig = adoptRig(grey, kind, definition, 1)
		if rig then
			rig.Parent = folder
			table.insert(prepared, rig)
		end
	end
	return prepared
end

--[[
	How tall a body of this kind ACTUALLY comes out, in studs, measured from the
	prepared template. Nil for a kind with no rig.

	The one honest answer to a question two other systems were each guessing at.
	SpawnVolume reserved space using the grey-box's 5.2 studs times the kind's
	`scale`, and InfectedBrain sized its pathfinding agent from 5.4 times the
	same — so both described a Tank as roughly twelve studs when the rig that
	actually spawns measures 13.6, and both described the Metallic from a `scale`
	that only ever builds its fallback. Nothing in any config can know an
	artist's units; this can, because it is holding the artist's model.

	HEIGHT ONLY, and that restriction is the whole lesson of the boss-clearance
	fix. A bounding box is honest about stature and lies about width: rigs are
	saved in a T-pose, so the X extent is fingertip-to-fingertip and a human body
	measures about as wide as it is tall. Callers that want a width derive it
	from proportions they choose; they do not read it from here, because it is
	not in here to read.

	Cached per kind. The measurement costs a bounding box on a template that is
	already built, and the answer cannot change for the life of the server.
]]
local measuredHeights: { [string]: number } = {}

function PlaceholderFactory:measuredHeight(kind: string): number?
	if typeof(kind) ~= "string" then
		return nil
	end
	local cached = measuredHeights[kind]
	if cached then
		return cached
	end
	local template = variantsFor(kind)[1]
	if not template then
		return nil
	end
	local _, size = template:GetBoundingBox()
	if size.Y <= 0 then
		return nil
	end
	measuredHeights[kind] = size.Y
	return size.Y
end

--[[ A finished, unparented rig for `kind`, or nil for an unknown kind. A
     SustainPeak horde asks for this 46 times, so it is a table index and a
     clone and nothing else. ]]
function PlaceholderFactory:buildInfectedRig(kind: string): Model?
	if typeof(kind) ~= "string" then
		return nil
	end
	local variants = variantsFor(kind)
	local count = #variants
	if count == 0 then
		return nil
	end
	local source = variants[if count == 1 then 1 else variantRandom:NextInteger(1, count)]
	local clone = source:Clone()
	clone.Name = kind
	return clone
end

-- ════════════════════════════════════════════════════════════════════════════
--  Weapons
--
--  The grey-box table is keyed by WeaponConfig's `class`, not by weapon id: six
--  shapes cover sixteen guns, and the seventeenth needs none. A stand-in only
--  has to answer "what am I holding" — pistol, SMG, rifle, marksman rifle,
--  shotgun, blade — and the real models answer everything past that.
--
--  Every gun is a short parts list in one local frame: the Handle sits at the
--  origin, the weapon points along -Z (a CFrame's LookVector), and +Y is up.
-- ════════════════════════════════════════════════════════════════════════════

-- Weapon greys. UITheme is the interface palette and these are the only place
-- its neutrals genuinely apply to geometry: a gun held against the HUD should
-- share the HUD's value range or it fights it.
local GUN = table.freeze({
	metal = UITheme.Color.Border,
	dark = UITheme.Color.Panel,
	polymer = UITheme.Color.PanelRaised,
	wood = UITheme.Color.AccentDim,
	optic = UITheme.Color.BorderBright,
})

-- { name, size, offset, colour key, optional rotation in degrees, optional shape }
local GUNS = {
	Pistol = {
		muzzle = V(0, 0.14, -1.70),
		parts = {
			{ "Handle", V(0.42, 1.00, 0.50), V(0, -0.50, 0.06), "polymer", V(-8, 0, 0) },
			{ "Receiver", V(0.42, 0.52, 1.55), V(0, 0.14, -0.50), "dark" },
			{ "Barrel", V(0.20, 0.20, 0.45), V(0, 0.14, -1.45), "metal" },
			{ "TriggerGuard", V(0.16, 0.30, 0.44), V(0, -0.22, -0.26), "dark" },
		},
	},

	SMG = {
		muzzle = V(0, 0.20, -2.45),
		parts = {
			{ "Handle", V(0.42, 0.95, 0.50), V(0, -0.48, 0.10), "polymer", V(-8, 0, 0) },
			{ "Receiver", V(0.50, 0.60, 2.00), V(0, 0.20, -0.60), "dark" },
			{ "Barrel", V(0.20, 0.20, 0.95), V(0, 0.20, -1.95), "metal" },
			{ "Magazine", V(0.30, 1.30, 0.55), V(0, -0.60, -0.55), "dark", V(6, 0, 0) },
			{ "Stock", V(0.34, 0.44, 0.90), V(0, 0.18, 0.78), "metal" },
			{ "Foregrip", V(0.26, 0.50, 0.30), V(0, -0.22, -1.55), "polymer" },
		},
	},

	Rifle = {
		muzzle = V(0, 0.20, -3.60),
		parts = {
			{ "Handle", V(0.42, 0.92, 0.50), V(0, -0.46, 0.22), "polymer", V(-8, 0, 0) },
			{ "Receiver", V(0.48, 0.66, 2.20), V(0, 0.22, -0.70), "dark" },
			{ "CarryHandle", V(0.22, 0.30, 1.00), V(0, 0.66, -0.70), "dark" },
			{ "Barrel", V(0.20, 0.20, 1.80), V(0, 0.20, -2.65), "metal" },
			{ "Magazine", V(0.32, 1.00, 0.62), V(0, -0.66, -0.50), "dark", V(8, 0, 0) },
			{ "Foregrip", V(0.30, 0.34, 1.20), V(0, 0.02, -2.05), "polymer" },
			{ "Stock", V(0.42, 0.62, 1.40), V(0, 0.10, 1.05), "polymer" },
		},
	},

	Marksman = {
		muzzle = V(0, 0.22, -4.60),
		parts = {
			{ "Handle", V(0.42, 0.90, 0.50), V(0, -0.44, 0.32), "wood", V(-12, 0, 0) },
			{ "Receiver", V(0.46, 0.60, 1.70), V(0, 0.22, -0.50), "metal" },
			{ "Barrel", V(0.20, 0.20, 3.20), V(0, 0.22, -2.95), "metal" },
			{ "Magazine", V(0.30, 0.50, 0.55), V(0, -0.44, -0.55), "metal" },
			{ "Stock", V(0.44, 0.86, 2.00), V(0, -0.06, 1.36), "wood", V(4, 0, 0) },
			{ "ScopeTube", V(0.32, 0.32, 1.60), V(0, 0.74, -0.70), "dark", V(0, 90, 0), "Cylinder" },
			{ "ScopeMountFront", V(0.14, 0.30, 0.16), V(0, 0.50, -1.20), "dark" },
			{ "ScopeMountRear", V(0.14, 0.30, 0.16), V(0, 0.50, -0.24), "dark" },
			{ "ScopeLens", V(0.26, 0.26, 0.06), V(0, 0.74, -1.51), "optic" },
		},
	},

	Shotgun = {
		muzzle = V(0, 0.28, -4.20),
		parts = {
			{ "Handle", V(0.42, 0.95, 0.52), V(0, -0.48, 0.18), "wood", V(-10, 0, 0) },
			{ "Receiver", V(0.50, 0.62, 1.40), V(0, 0.22, -0.55), "metal" },
			{ "Barrel", V(0.26, 0.28, 3.00), V(0, 0.30, -2.65), "metal" },
			{ "TubeMagazine", V(0.22, 0.22, 2.40), V(0, -0.02, -2.30), "metal" },
			{ "Pump", V(0.40, 0.42, 0.80), V(0, -0.02, -2.00), "wood" },
			{ "Stock", V(0.42, 0.76, 1.50), V(0, -0.06, 1.02), "wood", V(4, 0, 0) },
		},
	},

	-- No muzzle to speak of, but the attachment is built anyway so the effects
	-- code can ask any weapon where its business end is without a special case.
	Melee = {
		muzzle = V(0, 0.34, -2.90),
		parts = {
			{ "Handle", V(0.30, 1.00, 0.34), V(0, -0.50, 0), "dark" },
			{ "Guard", V(0.52, 0.14, 0.40), V(0, 0.04, 0), "metal" },
			{ "Blade", V(0.10, 0.56, 2.40), V(0, 0.34, -1.30), "metal" },
			{ "Tip", V(0.10, 0.32, 0.40), V(0, 0.22, -2.68), "metal" },
		},
	},
}

--[[ A Cylinder-shaped Part extends along its own X axis, so a barrel-shaped
     cylinder is authored with the length in X and rotated into place. ]]
local function buildGun(definition): Model?
	local spec = GUNS[definition.class]
	if not spec then
		warnOnce(
			"class:" .. tostring(definition.class),
			string.format("no grey-box shape for weapon class %q", tostring(definition.class))
		)
		return nil
	end

	local model = Instance.new("Model")
	model.Name = definition.id

	local barrel: BasePart? = nil
	for _, entry in spec.parts do
		local name, size, offset, colorKey, rotation, shape =
			entry[1], entry[2], entry[3], entry[4], entry[5], entry[6]
		local cframe = CFrame.new(offset)
		if rotation then
			cframe = cframe * CFrame.Angles(math.rad(rotation.X), math.rad(rotation.Y), math.rad(rotation.Z))
		end
		if shape == "Cylinder" then
			-- Authored as (length, diameter, diameter); the rotation in the table
			-- turns that length onto the barrel axis.
			size = V(size.Z, size.Y, size.X)
		end

		local part = prop(name, size, cframe, GUN[colorKey], Enum.Material.Metal)
		if shape then
			part.Shape = (Enum.PartType :: any)[shape]
		end
		part.Parent = model

		if name == "Barrel" or (name == "Blade" and not barrel) then
			barrel = part
		end
	end

	-- Effects hang off "Muzzle": the flash, the smoke, the tracer origin. It sits
	-- on the barrel so that moving the barrel moves the flash with it.
	local host = barrel or model:FindFirstChild("Handle")
	if host and host:IsA("BasePart") then
		local muzzle = Instance.new("Attachment")
		muzzle.Name = "Muzzle"
		muzzle.CFrame = host.CFrame:Inverse() * CFrame.new(spec.muzzle)
		muzzle.Parent = host
	end

	--[[
		Where the hand goes.

		Every shape in GUNS is authored around a grip at the origin with the
		barrel down -Z, which is the same convention a Roblox Tool uses — so the
		grip point IS the model origin, and this is the only place in the codebase
		that knows that for certain. Stamping it here means CarryVisualService can
		hold any weapon by lining one attachment up with a hand, without a table
		of per-class offsets that would have to be re-tuned every time a shape
		changed.

		`ensureGrip` fills this in for a SUPPLIED model, which has no such
		guarantee. Doing it here as well is not redundant: there the position has
		to be guessed from the geometry, and here it is known.
	]]
	local gripHost = model:FindFirstChild("Handle")
	if gripHost and gripHost:IsA("BasePart") then
		local grip = Instance.new("Attachment")
		grip.Name = "Grip"
		grip.CFrame = gripHost.CFrame:Inverse()
		grip.Parent = gripHost
	end

	return model
end

local function findAttachmentNamed(model: Model, name: string): Attachment?
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("Attachment") and descendant.Name == name then
			return descendant
		end
	end
	return nil
end

--[[
	Guarantees the model has a "Handle" to be welded, held and pivoted by.

	A supplied gun model almost never has one, and whatever its biggest part is,
	it is not the grip. An invisible node at the centre of the model's own
	extents is the one choice that behaves predictably for anything: the
	viewmodel poses about it, ItemPlacer rests a dropped gun on it, and it never
	buries the model in the floor the way a grip-shaped pivot would.

	── AND IT RETURNS WHETHER IT HAD TO INVENT ONE ─────────────────────────────
	Because the two cases are not interchangeable and ensureGrip was treating
	them as if they were. A real Handle is a grip-shaped part whose own box says
	where the hand goes; this one is a 0.4-stud cube that says nothing about the
	model at all. Measuring a grip offset off THAT box gives a tenth of a stud in
	each direction, which is the same as no offset — see ensureGrip.
]]
local INVENTED_HANDLE_SIZE = 0.4

local function ensureHandle(model: Model): (BasePart?, boolean)
	local existing = model:FindFirstChild("Handle", true)
	if existing and existing:IsA("BasePart") then
		return existing, false
	end

	local reference = model.PrimaryPart or largestPart(model)
	if not reference then
		return nil, false
	end

	local min, max = extentsIn(model, reference.CFrame)
	local size = INVENTED_HANDLE_SIZE
	local handle =
		prop("Handle", V(size, size, size), reference.CFrame * CFrame.new((min + max) * 0.5), GUN.dark)
	handle.Transparency = 1
	handle.CanQuery = false
	handle.Parent = model
	return handle, true
end

-- Parts whose name says "this end of the gun is the loud end".
local BARREL_NAMES = table.freeze({
	Barrel = true,
	Muzzle = true,
	MuzzleBrake = true,
	Suppressor = true,
	Tip = true,
	Blade = true,
})

--[[
	Guarantees a "Muzzle" attachment at the business end.

	A real gun model with no Muzzle means no muzzle flash and tracers leaving
	from the middle of the receiver, which reads to a player as "the gun is
	broken". Where the model does not say, the muzzle goes at the forward-most
	point of the extents along the handle's look vector (-Z), measured against a
	named barrel part when there is one and against the whole model when there is
	not.
]]
--[[
	Where a survivor's hand goes on this weapon.

	CarryVisualService lines this attachment up with the right hand, so a model
	without one cannot be held. Three sources, in descending order of how much
	they actually know:

	  1. An attachment the model already carries. `Grip` is ours; the other three
	     are what a Roblox Tool and the free models built around one ship with,
	     and copying the artist's point beats inventing one every time.
	  2. Nothing — because buildGun already stamped it at the model origin, which
	     for a shape we authored is exactly right.
	  3. A guess, for a supplied model that brought neither: the BOTTOM-REAR of
	     the handle's own box. That is where a hand is on a gun, and it is a far
	     better guess than the handle's centre — which on a model whose "Handle"
	     is the whole receiver puts the grip in the middle of the weapon.
]]
--[[ Weapons whose hold point this file had to invent, so ensureAssets can name
     them. Filled by adoptWeapon; read once at boot. ]]
local guessedGrips: { [string]: boolean } = {}

--[[ What ensureGrip last concluded about which way a model points, and whether
     it measured that or assumed it. Written there because that is where the
     answer is computed, read by adoptWeapon which is the only thing that knows
     the weapon's id, and reported once at boot. ]]
local lastFacing: { forward: Vector3?, guessed: boolean, straightened: boolean }? = nil
--[[ weaponId -> the sentence describing what was decided about its facing. World
     models only: a viewmodel is the same model measured the same way. ]]
local facingVerdicts: { [string]: string } = {}

--[[ Classes whose box extends well past the hand — a stock, a receiver, a
     barrel. A pistol and a melee weapon are the other shape: the hand is near
     the back of the model because the model is mostly grip. ]]
local LONG_GUN_CLASS = table.freeze({
	SMG = true,
	Rifle = true,
	Shotgun = true,
	LMG = true,
	Marksman = true,
	Launcher = true,
	Special = true,
})

local function ensureGrip(model: Model, handle: BasePart, invented: boolean, longGun: boolean): Attachment
	--[[ Cleared FIRST, before the early return below can skip past the place it
	     is set. A model that ships its own Grip leaves this function without
	     inferring anything, and recordFacing would otherwise read whatever the
	     PREVIOUS weapon concluded and file it under this one's name — a
	     diagnostic that confidently reports the wrong gun's answer is worse than
	     no diagnostic, and this one was written to be trusted. ]]
	lastFacing = nil

	local existing = findAttachmentNamed(model, "Grip")
	if existing then
		return existing
	end

	for _, alias in { "GripAttachment", "RightGripAttachment", "HandGrip" } do
		local found = findAttachmentNamed(model, alias)
		if found and found.Parent and found.Parent:IsA("BasePart") then
			local copy = Instance.new("Attachment")
			copy.Name = "Grip"
			copy.CFrame = found.CFrame
			copy.Parent = found.Parent
			return copy
		end
	end

	--[[
		Invented, and ORIENTED, which it was not.

		This used to be a position and nothing else: half the handle's height down
		and a third of its LENGTH back, where "length" meant the handle's Z. With
		an identity rotation the weapon's angle in the fist is then entirely the
		Handle part's own rotation — and CarryVisualService's own note says why
		that matters: "every world model is authored barrel-down-Z, so a gripped
		weapon points where its owner is looking without any correction at all".

		A gun modelled along X is an ordinary way to build one and breaks both
		halves of that at once: it came out of the survivor's fist at ninety
		degrees, and the grip point was measured down an axis that was not the
		barrel. ModelFacing answers which way it actually points; the offsets below
		are the same two the hand-written version used, taken along that answer
		rather than along Z.

		For a model already authored barrel-down-Z this produces the identical
		CFrame it always did — lookAt with forward = -Z is an identity rotation,
		and the reach and drop collapse to half the handle's Z and Y. A correct
		model is not touched, which is the property that makes this safe to ship
		across a roster somebody else built.
	]]
	local attachment = Instance.new("Attachment")
	attachment.Name = "Grip"

	local forward = ModelFacing.forwardOf(model, handle, model:GetPivot()) or -Vector3.zAxis
	--[[ Said out loud when the answer was a guess AND it changed anything. A gun
	     that was already facing forward is not worth a line, and one this
	     straightened on a longest-axis reading is: it is the case the reading can
	     be wrong about — a dual-wield pair is longest along whichever way the
	     artist arranged the two, which is not measurable from outside — and the
	     fix is one Muzzle attachment. See docs/WEAPON_MODELS.md. ]]
	--[[ Filed for the boot report whether or not anything was done about it.
	     The warning below only fires when the model WAS straightened, which
	     leaves the failing case — "decided it was already forward, and was
	     wrong" — completely silent. That is the case somebody is looking at when
	     a gun comes out sideways and the log says nothing. ]]
	lastFacing = {
		forward = forward,
		guessed = ModelFacing.LastWasGuess,
		straightened = not ModelFacing.isForward(forward),
	}

	if ModelFacing.LastWasGuess and not ModelFacing.isForward(forward) then
		--[[ model.Name, not the weapon id: adoptWeapon renames the model AFTER
		     this runs, so what is here is still what the artist called the folder
		     — which is the name they will be looking for in Studio. ]]
		warnOnce(
			"facing:" .. model.Name,
			string.format(
				"the %q model is not built barrel-down-Z, so it was straightened from its longest "
					.. "axis — which is a guess. If it comes out of the hand pointing the wrong way, "
					.. "add an Attachment called Muzzle at the end of its barrel and the answer "
					.. "becomes exact. See docs/WEAPON_MODELS.md",
				model.Name
			)
		)
	end
	--[[ Into the handle's own space, which is what an Attachment parented to it
	     is measured in. Up comes from the model's pivot rather than from the
	     world: the model is sitting in ServerStorage at whatever rotation it was
	     saved at, so world up means nothing here. ]]
	local pivot = model:GetPivot()
	local f = handle.CFrame:VectorToObjectSpace(pivot:VectorToWorldSpace(forward))
	local u = handle.CFrame:VectorToObjectSpace(pivot.UpVector)
	if math.abs(u:Dot(f)) > 0.95 then
		--[[ The barrel points along the model's own up. There is no roll left to
		     preserve, so any perpendicular will do and the handle's is nearest. ]]
		u = handle.CFrame:VectorToObjectSpace(pivot.RightVector)
	end

	--[[
		WHICH BOX TO MEASURE, AND THE BUG THAT WAS.

		The offsets below are "some of the way back along the barrel, and down".
		Back and down FROM WHAT is the whole question, and this measured the
		HANDLE's box for both cases.

		That is right for a model that shipped its own Handle: it is a
		grip-shaped part, and its box is a real statement about where the hand
		goes. It is meaningless for the one ensureHandle invents, which is a
		0.4-stud cube at the centre of the extents — `half` is 0.2 on every axis,
		so reach and drop came out around a tenth of a stud and the grip landed
		effectively AT the model's centre.

		Every supplied gun without a Handle part was therefore held by its
		geometric middle: the receiver in the palm, the stock through the
		forearm, the barrel out past where a hand could hold it. On a long
		weapon that reads exactly as "it does not fit in the hand".

		So when the handle was invented, measure the MODEL. Nothing about a
		model that brought its own Handle changes — which is also every grey-box
		this file builds, since those name their own.
	]]
	local half
	if invented then
		local min, max = extentsIn(model, handle.CFrame)
		half = (max - min) * 0.5
	else
		half = handle.Size * 0.5
	end
	local reach = math.abs(f.X) * half.X + math.abs(f.Y) * half.Y + math.abs(f.Z) * half.Z
	local drop = math.abs(u.X) * half.X + math.abs(u.Y) * half.Y + math.abs(u.Z) * half.Z

	--[[
		How far back, and how far down, as fractions of the model's own box.

		A pistol is nearly all grip: the hand sits well behind the middle and the
		butt is the back of the model. A long gun is not — the stock carries the
		box a long way past the hand, so the same fraction would hold a rifle by
		its buttplate. The class is the only thing that separates them and it is
		already on the definition, so it is passed in rather than guessed at from
		proportions, which a bullpup would defeat anyway.

		These are fractions of a HALF-extent, so 0.55 of a pistol's half-length
		is roughly a quarter of the whole gun behind centre. They are calibrated
		by reasoning about where a hand goes on a firearm rather than by looking
		at any particular model — which is exactly why a model that cares should
		ship a Grip attachment and skip all of this. See docs/WEAPON_MODELS.md.
	]]
	local backFraction = if longGun then 0.28 else 0.55
	local downFraction = if longGun then 0.62 else 0.42
	local position = -f * (reach * backFraction) - u * (drop * downFraction)

	attachment.CFrame = CFrame.lookAt(position, position + f, u)
	attachment.Parent = handle
	return attachment
end

--[[
	The hand-authored roll about the barrel, so third person agrees with first.

	Applied HERE rather than inside ensureGrip, and to whatever grip that
	returned — because ensureGrip hands back the ARTIST'S own attachment
	untouched when the model shipped one, and a roll that worked only on invented
	grips would be a setting that silently stopped applying the moment somebody
	improved their model.

	Negated for the same reason the viewmodel negates it: holdPose aligns this
	attachment TO the hand, so rolling the attachment by t rolls the model by -t.
	Both hands apply the negated angles and both rotate the gun the way
	WeaponConfig.modelRotation says.
]]
local function applyModelRotation(grip: Attachment?, rotation: Vector3?)
	if not grip or typeof(rotation) ~= "Vector3" or rotation.Magnitude == 0 then
		return
	end
	--[[ Negated on all three axes for the reason the single-axis version was:
	     holdPose aligns this attachment TO the hand, so rotating the attachment
	     by r rotates the model by -r. The config says what the MODEL should do
	     and this is what makes that true. ]]
	grip.CFrame = grip.CFrame
		* CFrame.Angles(math.rad(-rotation.X), math.rad(-rotation.Y), math.rad(-rotation.Z))
end

--[[
	Files what was decided about a model's facing, for the boot report.

	World models only. A viewmodel is the same model measured the same way, so
	reporting both would print every weapon twice and say nothing new.
]]
local function recordFacing(weaponId: string, viewmodel: boolean)
	if viewmodel then
		return
	end
	local facing = lastFacing
	lastFacing = nil
	if not facing then
		--[[ ensureGrip returned the artist's own Grip without inferring
		     anything, so there is no verdict to report and saying so is the
		     honest line: this model's orientation is whatever its author built,
		     which is the answer we most want and the one we cannot check. ]]
		facingVerdicts[weaponId] = "its own Grip attachment, nothing inferred"
		return
	end

	local direction = facing.forward
	local axis = "-Z"
	if direction then
		local x, y, z = math.abs(direction.X), math.abs(direction.Y), math.abs(direction.Z)
		if x >= y and x >= z then
			axis = if direction.X > 0 then "+X" else "-X"
		elseif y >= z then
			axis = if direction.Y > 0 then "+Y" else "-Y"
		else
			axis = if direction.Z > 0 then "+Z" else "-Z"
		end
	end

	if not facing.guessed then
		facingVerdicts[weaponId] = string.format("%s from its own Muzzle attachment", axis)
	elseif facing.straightened then
		facingVerdicts[weaponId] = string.format("%s guessed from its longest axis, STRAIGHTENED", axis)
	else
		--[[ The silent case, and the one worth reading. Nothing was measured and
		     nothing was changed: the model was assumed to be built the right way
		     round because its longest axis is already its Z, or because no axis
		     was long enough to argue with. If a gun looks wrong and this is what
		     the log says about it, the assumption is what is wrong. ]]
		facingVerdicts[weaponId] = "-Z ASSUMED, nothing measured"
	end
end

local function ensureMuzzle(model: Model, handle: BasePart): Attachment
	local existing = findAttachmentNamed(model, "Muzzle")
	if existing then
		return existing
	end

	-- Somebody else's naming for the same point; copy it rather than guess.
	for _, alias in { "MuzzlePoint", "FirePoint", "Fire", "Shoot" } do
		local found = findAttachmentNamed(model, alias)
		if found and found.Parent and found.Parent:IsA("BasePart") then
			local copy = Instance.new("Attachment")
			copy.Name = "Muzzle"
			copy.CFrame = found.CFrame
			copy.Parent = found.Parent
			return copy
		end
	end

	local subject: Instance = model
	for _, part in basePartsOf(model) do
		if BARREL_NAMES[part.Name] then
			subject = part
			break
		end
	end

	local min, max = extentsIn(subject, handle.CFrame)
	local centre = (min + max) * 0.5

	--[[
		The far end of the barrel, along the barrel — not along -Z.

		Placing it at the -Z face assumes the answer to the question the whole
		facing system exists to ask, and on a gun modelled barrel-up it put the
		muzzle on the SIDE of the receiver. Asked here, before the attachment
		exists, so ModelFacing is reading the model rather than reading this.

		Nil means it could not tell, which for a model whose longest axis is
		already Z is the same as "-Z" — so the old expression is the fallback and
		a correctly built gun is placed exactly where it always was.
	]]
	local forward = ModelFacing.forwardOf(model, handle, handle.CFrame)
	local point: Vector3
	if forward then
		local half = (max - min) * 0.5
		local reach = math.abs(forward.X) * half.X
			+ math.abs(forward.Y) * half.Y
			+ math.abs(forward.Z) * half.Z
		point = centre + forward * reach
	else
		point = Vector3.new(centre.X, centre.Y, min.Z)
	end

	local attachment = Instance.new("Attachment")
	attachment.Name = "Muzzle"
	attachment.CFrame = CFrame.new(point)
	--[[ Marked, so ModelFacing does not later mistake this for evidence about
	     which way the artist built the gun. See ModelFacing.InventedAttribute. ]]
	attachment:SetAttribute(ModelFacing.InventedAttribute, true)
	attachment.Parent = handle
	return attachment
end

--[[
	Turns any weapon model — grey-box or supplied — into something equippable.

	The whole model rides on the Handle: one weld each, one pivot, one place the
	effects code has to look. A viewmodel keeps its Handle anchored because it is
	driven by writing a CFrame every frame and must never be touched by physics;
	a world model is left loose so whoever equips it can weld it to a hand.
]]
--[[
	One rigid assembly: every part under `root` welded to `handle`, and nothing
	welded across to anything outside it.

	Split out of adoptWeapon because a dual-wield is TWO of these. Welding the
	pair into one body is what makes it impossible to put one in each hand
	afterwards, and it is what the single-handle path did to any model that
	happened to contain two guns.
]]
local function prepareAssembly(root: Instance, handle: BasePart, viewmodel: boolean)
	for _, part in basePartsOf(root) do
		part.CanCollide = false
		part.Locked = true
		if part ~= handle then
			part.Massless = true
			weldTo(handle, part)
		end
		if viewmodel then
			-- A viewmodel is drawn, never hit: it must not answer a raycast, cast
			-- a shadow into the world, or collide with anything.
			part.CanQuery = false
			part.CanTouch = false
			part.CastShadow = false
			part.Anchored = part == handle
		else
			part.Anchored = false
		end
	end
end

--[[
	The two halves of a dual-wield model, as { left, right }, or nil.

	What counts is a model containing two or more child Models that each carry
	their own Handle — which is exactly how a pair is built, because each half is
	a whole gun somebody modelled once and duplicated. Anything else is one
	weapon and takes the ordinary path.

	LEFT AND RIGHT ARE DECIDED BY GEOMETRY, not by Explorer order. A duplicated
	child arrives called "CZ-75(2)" and there is nothing in that name, or in the
	order Roblox returns children, that says which side the artist put it on.
	Their pivots do: the one further along the parent's -X is the left one. If
	they sit at the same X — stacked, or built one on top of the other — order is
	the only tiebreak left and it is at least stable.
]]
local function dualHalves(model: Model): { Model }?
	local halves: { Model } = {}
	for _, child in model:GetChildren() do
		if child:IsA("Model") then
			local handle = child:FindFirstChild("Handle", true)
			if handle and handle:IsA("BasePart") then
				table.insert(halves, child)
			end
		end
	end
	if #halves < 2 then
		return nil
	end

	local pivot = model:GetPivot()
	local a, b = halves[1], halves[2]
	local ax = pivot:PointToObjectSpace(a:GetPivot().Position).X
	local bx = pivot:PointToObjectSpace(b:GetPivot().Position).X
	if bx < ax then
		a, b = b, a
	end
	return { a, b }
end

--[[
	The names the two halves of a pair are found by, and the attribute that says
	a model is one at all.

	Renaming rather than tagging by position, because every consumer of this — the
	world model, the viewmodel, the muzzle flash — wants to ask for a specific
	side by name and none of them should have to redo the geometry test. Prefixed
	because they are this pipeline's names inside somebody else's model.
]]
local DUAL_LEFT = "FL_Left"
local DUAL_RIGHT = "FL_Right"
local DUAL_ATTRIBUTE = "FL_DualWield"

--[[
	Prepares a pair: two guns, two assemblies, two grips, two muzzles.

	Each half keeps its own Handle and is welded only to itself, which is the
	whole point — CarryVisualService welds one to each hand and the viewmodel
	poses an arm on each, and neither can do that with a single rigid body.

	The pair's PrimaryPart is the RIGHT half's handle. Something has to answer
	for the model as a whole — PivotTo, a dropped pickup resting on the floor,
	the fallback path in holdPose — and the right hand is the one that holds a
	weapon everywhere else in the game, so a pair that somehow reaches a
	one-handed path is at least holding the correct gun.
]]
local function adoptDualWeapon(model: Model, halves: { Model }, weaponId: string, viewmodel: boolean): Model?
	local left, right = halves[1], halves[2]
	left.Name = DUAL_LEFT
	right.Name = DUAL_RIGHT

	local primary: BasePart? = nil
	for index, half in { left, right } do
		local handle, invented = ensureHandle(half)
		if not handle then
			warnOnce(
				"nodualparts:" .. weaponId,
				string.format("half %d of the %s pair has no parts", index, weaponId)
			)
			model:Destroy()
			return nil
		end
		half.PrimaryPart = handle
		prepareAssembly(half, handle, viewmodel)
		--[[ Per half, and measured against that half rather than against the
		     pair. A pistol's own box is what says where its grip and its muzzle
		     are; the pair's box spans both guns and the gap between them, and
		     every number taken off it would be wrong for either. ]]
		ensureMuzzle(half, handle)
		local hadGrip = findAttachmentNamed(half, "Grip") ~= nil
		local pairDefinition = WeaponConfig.get(weaponId)
		applyModelRotation(
			ensureGrip(half, handle, invented, false),
			pairDefinition and pairDefinition.modelRotation
		)
		--[[ Reported for a pair too, and under the pair's id. ModelFacing's own
		     header calls a dual-wield the case its longest-axis guess is least
		     able to read — so it is the last weapon that should be missing from
		     the report, and it was. The right half wins the key: both halves are
		     the same gun measured the same way. ]]
		if half == right then
			recordFacing(weaponId, viewmodel)
		end
		--[[ Reported like any other guessed grip. A pair took the dual branch and
		     never reached the single path's bookkeeping, so a pair whose halves
		     carried neither a Handle nor a Grip was the one weapon in the game
		     that could be held wrong without saying so. ]]
		if invented and not hadGrip and not viewmodel then
			guessedGrips[weaponId] = true
		end
		if half == right then
			primary = handle
		end
	end

	model.PrimaryPart = primary
	model:SetAttribute(DUAL_ATTRIBUTE, true)
	model.Name = weaponId
	return model
end

local function adoptWeapon(model: Model, weaponId: string, viewmodel: boolean): Model?
	sanitise(model)

	local definition = WeaponConfig.get(weaponId)

	--[[
		A PAIR, HELD IN TWO HANDS.

		Only when the config says so. The geometry alone is not enough to decide
		it: a rifle whose scope was modelled as a child Model with a part called
		Handle in it would look identical from here, and turning that into a
		dual-wield would be a spectacular way to break one gun to fix another.
		WeaponConfig.dualWield is the declaration; this is the check that the art
		can actually do it.
	]]
	if definition and definition.dualWield then
		local halves = dualHalves(model)
		if halves then
			return adoptDualWeapon(model, halves, weaponId, viewmodel)
		end
		warnOnce(
			"nodual:" .. weaponId,
			string.format(
				"%s is configured as a dual-wield but its model is not two models with a Handle "
					.. "each, so it is being held as one weapon in one hand. See docs/WEAPON_MODELS.md",
				weaponId
			)
		)
	end

	local handle, invented = ensureHandle(model)
	if not handle then
		warnOnce("noparts:" .. weaponId, string.format("the %s weapon model has no parts", weaponId))
		model:Destroy()
		return nil
	end
	model.PrimaryPart = handle

	prepareAssembly(model, handle, viewmodel)

	ensureMuzzle(model, handle)
	--[[ On the viewmodel too. It costs one attachment and it means the two models
	     agree about where the weapon is held, which is what a future third-person
	     camera would need to line them up. ]]
	local class = definition and definition.class or ""
	local hadGrip = findAttachmentNamed(model, "Grip") ~= nil
	applyModelRotation(
		ensureGrip(model, handle, invented, LONG_GUN_CLASS[class] == true),
		definition and definition.modelRotation
	)
	recordFacing(weaponId, viewmodel)

	--[[ Named, once per weapon, when BOTH halves of where-to-hold-it were
	     guessed. A model that shipped either a Handle part or a Grip attachment
	     is being held where its author said; one that shipped neither is being
	     held where this file's proportions put it, which is a decent guess and
	     never a right answer. The list is the actionable half: it says which
	     models to add one attachment to. ]]
	if invented and not hadGrip and not viewmodel then
		guessedGrips[weaponId] = true
	end

	model.Name = weaponId
	return model
end

--[[
	The prepared template for one weapon in one category.

	Resolution order is modelName, then the enum id, then displayName. modelName
	comes first because that is what the artist's file is actually called; the
	enum id is what an earlier boot parked here; displayName is the last honest
	guess before the grey-box.
]]
local weaponTemplates: { [string]: Model } = {}
local viewmodelTemplates: { [string]: Model } = {}

local function weaponTemplate(definition, category: string, cache, build: () -> Model?): Model?
	local cached = cache[definition.id]
	if cached then
		return cached
	end

	local viewmodel = category == "Viewmodels"
	local names = { definition.modelName, definition.id, definition.displayName }
	local supplied = suppliedEntry(category, names)

	--[[
		A first-person model falls back to the world model.

		Somebody who has built a machete has built ONE machete. Asking them to put
		the same model in two folders before either hand can hold it is exactly the
		friction this module exists to remove — and the failure was silent: the
		world model was theirs, the first-person one grey-boxed, and nothing said
		why. "I gave you my melee models and I still cannot see them" is that bug
		reported from the only seat it is visible from.

		One direction only. A Viewmodels entry is somebody deliberately authoring a
		separate first-person model — usually lower-poly, or posed for a hand — and
		using that as the WORLD model everyone else sees would be substituting a
		prop built for a different camera.

		adoptWeapon already does the rest: it takes the same model and treats it
		differently per category, anchoring a viewmodel's Handle because it is
		driven by a CFrame every frame and leaving a world model loose to be welded
		to a hand.
	]]
	local borrowed = false
	if not supplied and viewmodel then
		supplied = suppliedEntry("Weapons", names)
		borrowed = supplied ~= nil
	end

	local prepared: Model? = nil

	if supplied then
		local candidates = modelsIn(supplied)
		local copy = candidates[1] and cloneAsModel(candidates[1])
		if copy then
			prepared = adoptWeapon(copy, definition.id, viewmodel)
		end
		if prepared then
			resolved[category].real += 1
		else
			warnOnce(
				"unusable:" .. category .. ":" .. definition.id,
				string.format("Assets.%s.%s is not a usable model; grey-boxing it", category, supplied.Name)
			)
		end
	end

	if not prepared then
		local built = build()
		if built then
			prepared = adoptWeapon(built, definition.id, viewmodel)
		end
		if prepared then
			resolved[category].grey += 1
			--[[ Deduped, because modelName and id are the same string for most of
			     the roster and "searched for Knife, Knife, Combat Knife" reads as
			     a bug in the message rather than as three spellings. ]]
			local seen, tried = {}, {}
			for _, name in { definition.modelName, definition.id, definition.displayName } do
				if typeof(name) == "string" and name ~= "" and not seen[name] then
					seen[name] = true
					table.insert(tried, name)
				end
			end
			greyBoxed[category][definition.id] = tried
		end
	end

	if not prepared then
		return nil
	end
	--[[
		Published only when the client would otherwise find nothing.

		Both categories now, not just viewmodels. The world model used to be
		server-only on the reasoning that a second copy in ReplicatedStorage is
		every mesh duplicated for no reader — and then the shop grew a rotating
		3D preview, which is that reader.

		The `reachable` test is what keeps the cost proportional. A user who put
		their own models in ReplicatedStorage.Assets.Weapons already has them on
		every client and the shop finds them by the same name lookup; only a
		grey-box, or a model kept in ServerStorage, is published — and a grey-box
		is a handful of Parts.
	]]
	--[[
		`borrowed` is why this is not just an IsDescendantOf test, and leaving it
		out is what made "I gave you my melee models and I still cannot see them"
		survive the fallback above.

		The shortcut says: don't publish a second copy, the client can already
		reach the user's own. True — but only for the folder the client actually
		SEARCHES. ViewmodelController looks in Assets.Viewmodels and nowhere else,
		so a machete supplied as Assets.Weapons.Machete inside ReplicatedStorage
		took the fallback, prepared a perfectly good first-person model, counted
		itself as real in the boot report, and then skipped publishing it — into
		the one folder the first-person code reads. Grey box, no warning, and a
		report line claiming the model had been found.

		A borrowed viewmodel is therefore always published. It is not a duplicate
		of anything the client can otherwise find: it is the only copy of that
		model prepared for a hand rather than for the world.
	]]
	--[[
		── AND A TOOL IS NOT REACHABLE EITHER ──────────────────────────────────
		The same bug as `borrowed`, one class along, and it had the whole
		Brickbattler's Pack in it.

		Those four are supplied as TOOLS, which is what a classic Roblox gear
		item is and exactly what `isSupplyContainer` was widened to accept —
		everything on the server side handles them, because `cloneAsModel` lifts
		a Tool's parts into a fresh Model before anything downstream sees it. So
		the world model works, the grip works, and the boot report counts them as
		real.

		The shortcut below then said: it lives in ReplicatedStorage, so don't
		publish a second copy, the client can already reach it. It can reach it.
		It cannot READ it. Both client-side lookups — ViewmodelController's
		asModel and WeaponPreview's findTemplate — resolve a Model or a Folder of
		variants and return nil for anything else, because until these four
		arrived nothing else was ever anything else.

		The visible half is the shop, which is the reader this whole publishing
		branch exists for: four weapons somebody paid Robux for, with an empty
		rotating preview and no warning anywhere. So `reachable` means what it
		always meant to mean, which is "the client can find AND use this", and a
		Tool gets its prepared Model published like anything else the client
		could not have read.
	]]
	local reachable = not borrowed
		and supplied ~= nil
		and supplied:IsA("Model")
		and supplied:IsDescendantOf(ReplicatedStorage)
	cache[definition.id] = park(category, definition.id, prepared, not reachable)
	return prepared
end

--[[ The world model: what a survivor is holding, seen by everybody else. ]]
function PlaceholderFactory:buildWeaponModel(weaponId: string): Model?
	if typeof(weaponId) ~= "string" then
		return nil
	end
	local definition = WeaponConfig.get(weaponId)
	if not definition then
		return nil
	end
	local source = weaponTemplate(definition, "Weapons", weaponTemplates, function()
		return buildGun(definition)
	end)
	return if source then source:Clone() else nil
end

--[[
	The first-person model.

	The grey-box is the same geometry at the same scale as the world model, on
	purpose: the Muzzle attachment then sits in the same place relative to the
	Handle in both, so a tracer that starts at the viewmodel's muzzle lines up
	with the one every other player sees leaving the world model.
]]
function PlaceholderFactory:buildViewmodel(weaponId: string): Model?
	if typeof(weaponId) ~= "string" then
		return nil
	end
	local definition = WeaponConfig.get(weaponId)
	if not definition then
		return nil
	end
	local source = weaponTemplate(definition, "Viewmodels", viewmodelTemplates, function()
		local model = buildGun(definition)
		if not model then
			return nil
		end
		local handle = model:FindFirstChild("Handle")
		if not handle or not handle:IsA("BasePart") then
			return model
		end

		-- Sleeved forearms, on the grey-box only. Without hands a stand-in reads
		-- as a floating prop; a supplied model is assumed to bring its own.
		for _, side in { -1, 1 } do
			local isRight = side > 0
			local arm = prop(
				if isRight then "RightArm" else "LeftArm",
				V(0.5, 0.5, 2.3),
				CFrame.new(side * 0.34, if isRight then -0.55 else -0.30, if isRight then 1.05 else -1.15)
					* CFrame.Angles(math.rad(if isRight then -6 else 14), math.rad(side * 8), 0),
				UITheme.Color.PanelRaised,
				Enum.Material.Fabric
			)
			arm.Parent = model
		end
		return model
	end)
	return if source then source:Clone() else nil
end

-- ════════════════════════════════════════════════════════════════════════════
--  Pickups
-- ════════════════════════════════════════════════════════════════════════════

local PICKUP_BUILDERS: { [string]: (Model) -> () } = {}

local function pickupPart(
	model: Model,
	name: string,
	size: Vector3,
	offset: Vector3,
	color: Color3,
	material: Enum.Material?
)
	local part = prop(name, size, CFrame.new(offset), color, material)
	part.Parent = model
	return part
end

--[[
	THERE IS NO GENERATED MEDKIT, deliberately.

	There used to be: a white case with a red cross, four parts. It was the only
	grey-box in this file competing with a model the game already had, because a
	medkit is a pickup the MAP supplies — MapItemService loads the designer's own
	per level and the carry visual already used them for the thing on a survivor's
	back. So a player saw their kit on the floor of the map, their kit on a
	teammate's back, and this one on an item pad.

	Pills and adrenaline are supplied the same way now and DO still have a
	generated version below, and the difference is deliberate. The medkit is
	strict — no map model, no medkit, because the whole point of that change was
	to remove ours. The pill builders stay as a fallback because a misnamed
	folder must not silently delete the Director's entire pills flow: a team that
	stops finding pills has no way to tell that from bad luck.

	buildPickup asks MapItemService for the map's template first either way. See
	it for how, and for why the answer is not cached.
]]

PICKUP_BUILDERS[Enums.HealthItem.Defibrillator] = function(model)
	pickupPart(model, "Case", V(2.0, 1.0, 1.4), V(0, 0.5, 0), UITheme.Color.Warning)
	pickupPart(model, "PaddleLeft", V(0.6, 0.5, 0.5), V(-0.6, 1.2, 0), UITheme.Color.Panel)
	pickupPart(model, "PaddleRight", V(0.6, 0.5, 0.5), V(0.6, 1.2, 0), UITheme.Color.Panel)
	pickupPart(
		model,
		"Readout",
		V(0.7, 0.4, 0.06),
		V(0, 0.6, -0.72),
		UITheme.Color.AccentBright,
		Enum.Material.Neon
	)
end

PICKUP_BUILDERS[Enums.PillItem.PainPills] = function(model)
	pickupPart(model, "Bottle", V(0.7, 1.0, 0.7), V(0, 0.5, 0), UITheme.Color.TextPrimary)
	pickupPart(model, "Cap", V(0.72, 0.24, 0.72), V(0, 1.1, 0), UITheme.Color.Danger)
	pickupPart(model, "Label", V(0.72, 0.44, 0.02), V(0, 0.5, -0.36), UITheme.Color.Accent)
end

PICKUP_BUILDERS[Enums.PillItem.Adrenaline] = function(model)
	pickupPart(model, "Barrel", V(0.34, 1.3, 0.34), V(0, 0.75, 0), UITheme.Color.TextPrimary)
	pickupPart(model, "Plunger", V(0.5, 0.16, 0.5), V(0, 1.46, 0), UITheme.Color.Accent)
	pickupPart(model, "Needle", V(0.1, 0.5, 0.1), V(0, 0.15, 0), UITheme.Color.BorderBright)
	pickupPart(
		model,
		"Fluid",
		V(0.24, 0.9, 0.24),
		V(0, 0.72, 0),
		UITheme.Color.AccentBright,
		Enum.Material.Neon
	)
end

PICKUP_BUILDERS[Enums.Throwable.PipeBomb] = function(model)
	pickupPart(model, "Pipe", V(0.5, 1.6, 0.5), V(0, 0.8, 0), UITheme.Color.BorderBright)
	pickupPart(model, "TapeLower", V(0.58, 0.3, 0.58), V(0, 0.4, 0), UITheme.Color.AccentDim)
	pickupPart(model, "TapeUpper", V(0.58, 0.3, 0.58), V(0, 1.2, 0), UITheme.Color.AccentDim)
	pickupPart(model, "Light", V(0.18, 0.18, 0.18), V(0, 1.68, 0), UITheme.Color.Danger, Enum.Material.Neon)
end

PICKUP_BUILDERS[Enums.Throwable.Molotov] = function(model)
	pickupPart(model, "Bottle", V(0.6, 1.2, 0.6), V(0, 0.6, 0), UITheme.Color.Warning)
	pickupPart(model, "Neck", V(0.28, 0.4, 0.28), V(0, 1.35, 0), UITheme.Color.Warning)
	pickupPart(
		model,
		"Rag",
		V(0.22, 0.5, 0.22),
		V(0, 1.75, 0),
		UITheme.Color.TextSecondary,
		Enum.Material.Fabric
	)
end

--[[ A squat drum, wide and low in chemical green with a band around it —
     nothing else a survivor can pick up has that silhouette, which is the only
     thing a grey-box has to work with in a dark room. Maps that supply their own
     "Hazardous Waste 1" never build this — see the map families in MapConfig. ]]
PICKUP_BUILDERS[Enums.Throwable.HazardousWaste] = function(model)
	pickupPart(model, "Drum", V(1.2, 1.3, 1.2), V(0, 0.65, 0), UITheme.Color.Hazard, Enum.Material.Neon)
	pickupPart(model, "Band", V(1.28, 0.22, 1.28), V(0, 0.85, 0), UITheme.Color.Border)
	pickupPart(model, "Cap", V(0.5, 0.22, 0.5), V(0, 1.36, 0), UITheme.Color.Border)
end

--[[
	Finishes any pickup — grey-box, dropped gun or a model the user supplied.

	The "Handle" is an invisible root at the centre of the model's own bounding
	box, and that is not cosmetic: ItemPlacer places a pickup by pivoting it to
	`ground + halfHeight`, which only rests the object on the floor if the pivot
	really is the middle of it. A grip-shaped Handle would bury every dropped gun.
]]
local function finishPickup(model: Model): Model?
	if not model:FindFirstChildWhichIsA("BasePart", true) then
		model:Destroy()
		return nil
	end

	local box, extents = model:GetBoundingBox()
	local handle = prop("Handle", V(0.4, 0.4, 0.4), CFrame.new(box.Position), UITheme.Outline.ItemColor)
	handle.Transparency = 1
	handle.CanQuery = false
	handle.Parent = model
	model.PrimaryPart = handle

	-- The marker ring, flat on the floor under the item. Non-queryable so it can
	-- never eat the interact ray aimed at the thing standing on it.
	local ring = prop(
		"Marker",
		V(2.6, 0.06, 2.6),
		CFrame.new(box.Position - Vector3.new(0, extents.Y * 0.5 - 0.04, 0)),
		UITheme.Outline.ItemColor,
		Enum.Material.Neon
	)
	ring.CanQuery = false
	ring.Transparency = 0.4
	ring.Parent = model

	local glow = Instance.new("PointLight")
	glow.Color = UITheme.Outline.ItemColor
	glow.Brightness = 1.1
	glow.Range = 10
	glow.Shadows = false
	glow.Parent = handle

	for _, part in basePartsOf(model) do
		-- Anchored: a pickup sitting where the level designer put it is worth far
		-- more than one that rolls under a car, and a few dozen anchored props
		-- cost nothing.
		part.Anchored = true
		part.CanCollide = false
		part.CastShadow = false
		part.Locked = true
		if part ~= handle then
			part.Massless = true
			weldTo(handle, part)
		end
		--[[ Queryable, and SET rather than left as it arrived. Both the ways the
		     prompt finds a pickup — the crosshair ray and the arm's-reach sweep —
		     skip a part with CanQuery off, so a supplied mesh that happens to have
		     it cleared is an item nobody can pick up with nothing on screen to say
		     why. The two parts this function added itself keep it off on purpose:
		     the invisible handle and the floor ring must never eat the ray aimed
		     at the thing standing on them. ]]
		if part ~= handle and part ~= ring then
			part.CanQuery = true
		end
	end
	return model
end

local throwableTemplates: { [string]: Model? } = {}

--[[ Which of those were built from the LIVE MAP rather than from an assets
     folder, and are therefore only good for as long as that map is loaded. An
     assets-folder throwable is prepared once for the life of the server, as
     everything else here is; a map one has to go when its map does. ]]
local mapSourcedThrowables: { [string]: boolean } = {}

--[[
	Throws away every template taken from the map that has just been unloaded.

	Called on a map swap. Without it the second round of a server hands out the
	first round's molotov: the prepared clone survives in ServerStorage long after
	the level it was copied from stopped existing, and nothing about it says which
	map it came from.

	Only the map-sourced ones. Rebuilding a throwable that came out of the assets
	folder would be work for an answer that cannot have changed.
]]
local function clearMapTemplates()
	for kind in mapSourcedThrowables do
		local template = throwableTemplates[kind]
		if template then
			(template :: Model):Destroy()
		end
		throwableTemplates[kind] = nil
	end
	table.clear(mapSourcedThrowables)
end

--[[
	The model a throwable is drawn as, or nil when the user has not supplied one.

	Nil is not a failure and is not warned about: the procedural pickup and the
	procedural projectile are both perfectly good, and a game with no throwable
	models in it should say nothing about the fact.

	── ONE MODEL, THREE PLACES ─────────────────────────────────────────────────
	A molotov is seen in a hand, on the floor, and turning over in the air, and
	before this each of those was answered separately: the floor could use a
	supplied model, the hand showed NOTHING for a throwable, and the thrown object
	was a hardcoded cylinder that never asked. So a user who supplied a molotov saw
	it in exactly one of the three places it appears.

	── AND THE MAP COMES FIRST ─────────────────────────────────────────────────
	Every throwable is placed by hand in the level now, in the folders
	MapConfig.MapItems names, and that is where its model comes from. The assets
	folder is still read for anything the map does not supply, which today is
	nothing — it is the escape hatch for the next throwable that has no family
	rather than a path anything currently takes.

	The map's answer is NOT cached across a map swap. Everything else in this file
	is prepared once and kept for the life of the server, which is correct for a
	thing that came out of an assets folder and wrong for a thing that came out of
	a level: caching Clinton's molotov would put Clinton's molotov in every map
	after it. See clearMapTemplates, and the same note above buildPickup.

	Prepared once per map, then. Welded to its own Handle so it travels as one
	object, and every part made non-queryable — a thrown bottle must never stop a
	bullet meant for the zombie behind it.
]]
function PlaceholderFactory:buildThrowableModel(kind: string): Model?
	if typeof(kind) ~= "string" then
		return nil
	end
	local source = throwableTemplates[kind]
	local fromMap = false
	if source == nil then
		--[[ The live map first. getTemplate hands back the pristine copy taken
		     before the model was dressed as a pickup, which is the same object the
		     player has been walking past all round. ]]
		local built: Model? = nil
		if MapConfig.mapItemFor(kind) then
			local mapItems: any = Registry.find("MapItemService")
			local template = mapItems
				and typeof(mapItems.getTemplate) == "function"
				and mapItems:getTemplate(kind)
			if template then
				built = (template :: Model):Clone()
				fromMap = true
			end
		end

		--[[ Then the assets folder, for a throwable no map places — and for
		     anybody who would rather supply one model than place thirteen. ]]
		if not built then
			local supplied = suppliedEntry("Throwables", { kind })
			local candidates = if supplied then modelsIn(supplied) else {}
			built = candidates[1] and cloneAsModel(candidates[1])
		end

		if not built then
			--[[
				A miss is remembered ONLY when it cannot change.

				The negative answer used to be cached unconditionally, so a kind
				with no model was looked up once per server rather than once per
				throw — a horde's worth of pipe bombs is a lot of folder walks for
				an answer that could not change. It can change now: a map-supplied
				throwable asked for before its map is standing has no template
				yet, and caching that would leave the kind permanently modelless
				for the life of the server, on every map after it.

				So an assets-folder kind's miss is still cached — nothing about
				that folder moves — and a map kind's is not, and pays one folder
				walk per throw for as long as its map really has none. Every
				throwable is a map kind today, so nothing is cached; the branch
				is what makes adding one that is not safe.
			]]
			if not MapConfig.mapItemFor(kind) then
				throwableTemplates[kind] = false :: any
			end
			return nil
		end
		sanitise(built)

		local anchor = built.PrimaryPart or built:FindFirstChildWhichIsA("BasePart", true)
		if not anchor then
			--[[ A model with no parts, which IS a fact about the model and not
			     about when it was asked for. Cached either way. ]]
			built:Destroy()
			throwableTemplates[kind] = false :: any
			return nil
		end
		built.PrimaryPart = anchor

		for _, part in basePartsOf(built) do
			part.Anchored = false
			part.CanCollide = false
			--[[ Never queryable. A bottle in flight that stops a bullet meant for
			     the Common behind it is the worst kind of bug: invisible, and it
			     costs a kill. ]]
			part.CanQuery = false
			part.CanTouch = false
			part.CastShadow = false
			part.Locked = true
			if part ~= anchor then
				part.Massless = true
				weldTo(anchor, part)
			end
		end

		source = park("Throwables", kind, built)
		throwableTemplates[kind] = source
		if fromMap then
			mapSourcedThrowables[kind] = true
		end
	end
	if not source then
		return nil
	end

	local clone = (source :: Model):Clone()
	clone.Name = kind
	return clone
end

local pickupTemplates: { [string]: Model } = {}

--[[ A small readable object, lying on the floor, glowing just enough to be
     found in a dark room without becoming a lamp. ]]
function PlaceholderFactory:buildPickup(slot: string, itemId: string): Model?
	if typeof(slot) ~= "string" or typeof(itemId) ~= "string" then
		return nil
	end

	--[[
		Medkits, pills and adrenaline are the MAP'S models, resolved BEFORE the
		cache.

		Not cached, and that is the whole reason this is up here rather than in
		the fallback chain below: the template belongs to whichever level is
		loaded, and a cache is forever. Caching Clinton's kit would put Clinton's
		kit on an item pad in every map after it.

		It also has to be ahead of the boot-time prewarm, which calls this for
		every pickup id before MapItemService has SCANNED a map. Not before it
		exists — it is registered by then, and reading those as the same thing is
		what produced five bogus warnings on every boot. See the guard below. Down in the chain, that call
		would have found no template, fallen through to the generic crate, and
		cached the CRATE as the medkit for the life of the server.
	]]
	local key = slot .. "_" .. itemId
	local family = MapConfig.mapItemFor(itemId)

	--[[ An explicit Assets/Pickups entry still wins, and is checked before the
	     map. Somebody who put a model there is deliberately saying the floor
	     version differs from the one lying around the level, and this was about
	     removing OUR models, not about overruling theirs. ]]
	if family and not suppliedEntry("Pickups", { key, itemId }) then
		local mapItems: any = Registry.find("MapItemService")
		local template = mapItems
			and typeof(mapItems.getTemplate) == "function"
			and mapItems:getTemplate(itemId)
		if template then
			local model = template:Clone()
			sanitise(model)
			local finished = finishPickup(model)
			if finished then
				finished.Name = itemId
				return finished
			end
		end

		--[[
			Only worth SAYING when somebody has actually LOOKED and found nothing.

			This used to ask whether the service exists, on the stated reasoning
			that the boot prewarm runs "before that service is registered at all".
			That premise is false, and the warning it guarded fired on every
			server ever booted, including one with a map full of items — which is
			how five of them turned up in a log from a stocked place.

			Every module is required, and so registers, before ANY module's init()
			runs. The prewarm is in PlaceholderFactory's init(). So MapItemService
			is registered by then and answers this test yes — but it does not scan
			the map until its start(), a phase later, so every getTemplate it can
			give is nil. The service existing and the service having looked are
			different facts and only the second one licenses a complaint.
		]]
		if mapItems and typeof(mapItems.hasScanned) == "function" and mapItems:hasScanned() then
			warnOnce(
				"nomapitem:" .. itemId,
				string.format(
					"a %s was asked for but the live map has none to copy. Put models named "
						.. "%q upward in a %q folder in the map.%s",
					itemId,
					family.modelName .. " 1",
					family.folderName,
					if itemId == Enums.HealthItem.Medkit
						then " No medkit will be placed anywhere in this map."
						else " Falling back to the built-in model for now."
				)
			)
		end

		--[[ The medkit and only the medkit stops here. Everything else falls
		     through to its builder below — see the note above PICKUP_BUILDERS for
		     why the two differ. ]]
		if itemId == Enums.HealthItem.Medkit then
			return nil
		end
	end

	local source = pickupTemplates[key]
	if not source then
		local built: Model? = nil

		local supplied = suppliedEntry("Pickups", { key, itemId })
		if supplied then
			local candidates = modelsIn(supplied)
			built = candidates[1] and cloneAsModel(candidates[1])
			if built then
				sanitise(built)
			end
		end

		--[[ A throwable's own model, so the bottle on the floor is the bottle you
		     are about to hold and throw. Below an explicit Pickups entry, which is
		     someone deliberately wanting the floor version to differ. ]]
		if not built then
			built = self:buildThrowableModel(itemId)
		end

		if not built and WeaponConfig.get(itemId) then
			-- A dropped gun is the gun, lying on its side. Nothing else reads as
			-- clearly as the silhouette the player is about to be holding. Pivoted
			-- as one model rather than part by part, because a supplied gun is
			-- welded together and rotating its parts individually would tear it up.
			local weapon = self:buildWeaponModel(itemId)
			if weapon then
				weapon:PivotTo(CFrame.Angles(0, 0, math.rad(90)))
				local grip = weapon:FindFirstChild("Handle", true)
				if grip then
					-- Freed for the pickup's own root; two Handles in one model is
					-- one Handle too many for everybody downstream.
					grip.Name = "Grip"
				end
				weapon.PrimaryPart = nil
				built = weapon
			end
		end

		if not built then
			built = Instance.new("Model")
			local builder = PICKUP_BUILDERS[itemId]
			if builder then
				builder(built)
			else
				-- An unknown id still has to become something a player can pick
				-- up: a plain crate is better than a nil return.
				pickupPart(
					built,
					"Crate",
					V(1.4, 1.2, 1.4),
					V(0, 0.6, 0),
					UITheme.Color.AccentDim,
					Enum.Material.WoodPlanks
				)
			end
		end

		local finished = finishPickup(built)
		if not finished then
			return nil
		end
		source = park("Pickups", key, finished)
		pickupTemplates[key] = source
	end

	local clone = source:Clone()
	clone.Name = itemId
	return clone
end

-- ════════════════════════════════════════════════════════════════════════════
--  The test level
--
--  A greybox map is not a placeholder for level design, it IS level design —
--  cover, elevation, choke points and sightlines are gameplay and they are worth
--  getting right before anybody models a brick. What follows is a full L4D-shaped
--  chapter: start safe room, a street, a warehouse, a checkpoint, a rail yard, an
--  overpass with a collapsed span, a generator courtyard that is the crescendo,
--  and an end safe room. Roughly 1800 studs of flow, which is deliberate — that
--  is long enough for DirectorConfig.Bosses to reach both its Witch window and
--  its Tank window, so the set pieces actually happen in a playtest.
--
--  Every gameplay-relevant thing here is a TAG. LevelService never learns a
--  coordinate from this file; it reads FL_FlowNode, FL_SpawnNode, FL_ItemSpawn,
--  FL_SafeRoom, FL_PanicTrigger and FL_BossZone out of CollectionService. That is
--  what lets a hand-built map replace all of this with zero code changes.
-- ════════════════════════════════════════════════════════════════════════════

-- Greybox surface colours. No config owns these: UITheme is the interface
-- palette, and painting geometry in its near-black panel greys would make the
-- level unreadable at ClockTime 4.25 with fog starting at 60 studs.
local MAP = table.freeze({
	Ground = Color3.fromRGB(38, 38, 34),
	Asphalt = Color3.fromRGB(52, 52, 56),
	Concrete = Color3.fromRGB(104, 101, 94),
	ConcreteDark = Color3.fromRGB(70, 68, 62),
	Brick = Color3.fromRGB(96, 64, 52),
	Metal = Color3.fromRGB(84, 88, 92),
	Rust = Color3.fromRGB(118, 76, 52),
	Wood = Color3.fromRGB(104, 78, 48),
	ContainerA = Color3.fromRGB(84, 96, 74),
	ContainerB = Color3.fromRGB(122, 78, 60),
	ContainerC = Color3.fromRGB(68, 84, 106),
	Fence = Color3.fromRGB(56, 58, 60),
})

local TAG_FLOW = "FL_FlowNode"
local TAG_SPAWN = "FL_SpawnNode"
local TAG_ITEM = "FL_ItemSpawn"
local TAG_SAFEROOM = "FL_SafeRoom"
local TAG_PANIC = "FL_PanicTrigger"
local TAG_BOSS = "FL_BossZone"
local TAG_CLOSET = "FL_RescueCloset" -- SurvivorService's tag; see its header

local ITEM_PAD_HEIGHT = 1.6

--[[ Solid level geometry. Collision group is left at Default deliberately — the
     Survivor/Infected/Debris/Gib groups are all defined to collide with the
     world, and putting the world in any of them would break that. ]]
local function mapBox(
	parent: Instance,
	name: string,
	center: Vector3,
	size: Vector3,
	color: Color3,
	material: Enum.Material?,
	shadow: boolean?
): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = CFrame.new(center)
	part.Color = color
	part.Material = material or Enum.Material.Concrete
	part.Anchored = true
	part.CanCollide = true
	part.CastShadow = shadow ~= false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Locked = true
	part.Parent = parent
	return part
end

--[[ An invisible tagged volume. CanQuery is off on every one of these: the
     Director ground-raycasts through candidate spawn points, and a boss zone or
     a panic trigger that answered that ray would look like a floor in mid-air. ]]
local function marker(parent: Instance, name: string, center: Vector3, size: Vector3, tag: string): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = CFrame.new(center)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Transparency = 1
	part.Locked = true
	part.Parent = parent
	CollectionService:AddTag(part, tag)
	return part
end

--[[ A shelf an item can sit on. `base` is the point the pad RESTS on, because
     ItemPlacer puts the pickup on the pad's top face. ]]
local function itemPad(parent: Instance, base: Vector3, slot: string?): Part
	local pad = mapBox(
		parent,
		"ItemPad",
		base + Vector3.new(0, ITEM_PAD_HEIGHT * 0.5, 0),
		V(4, ITEM_PAD_HEIGHT, 3),
		MAP.Metal,
		Enum.Material.DiamondPlate,
		false
	)
	CollectionService:AddTag(pad, TAG_ITEM)
	if slot then
		-- A pad that declares its slot is a designer's decision and ItemPlacer
		-- does not argue with it. The safe-room shelves use this for medkits.
		pad:SetAttribute("FL_Slot", slot)
	end
	return pad
end

local function spawnNode(parent: Instance, position: Vector3)
	marker(parent, "SpawnNode", position, V(4, 6, 4), TAG_SPAWN)
end

--[[ A block bridging two points: ramps, gantries, planks. The block's length
     runs along its local Z, which is what CFrame.lookAt orients. ]]
local function ramp(
	parent: Instance,
	name: string,
	from: Vector3,
	to: Vector3,
	width: number,
	color: Color3,
	material: Enum.Material?
): Part
	local delta = to - from
	local length = delta.Magnitude
	local part = mapBox(parent, name, (from + to) * 0.5, V(width, 1, length), color, material)
	part.CFrame = CFrame.lookAt((from + to) * 0.5, to)
	return part
end

local function pointLight(host: BasePart, color: Color3, range: number, brightness: number, shadows: boolean?)
	local light = Instance.new("PointLight")
	light.Color = color
	light.Range = range
	light.Brightness = brightness
	-- Shadow-casting lights are the single most expensive thing a level can add,
	-- and a horde is not the moment to spend that budget. Only the handful of
	-- fixtures that define a space get them.
	light.Shadows = shadows == true
	light.Parent = host
end

--[[ A street lamp: pole, head, a cone of light and a neon lens so the fixture
     itself reads from outside the light's range. ]]
local function lamp(parent: Instance, base: Vector3, height: number, color: Color3)
	mapBox(
		parent,
		"LampPole",
		base + Vector3.new(0, height * 0.5, 0),
		V(0.8, height, 0.8),
		MAP.Metal,
		Enum.Material.Metal,
		false
	)
	local head = mapBox(
		parent,
		"LampHead",
		base + Vector3.new(0, height, 0),
		V(3, 0.8, 3),
		color,
		Enum.Material.Neon,
		false
	)
	head.CanCollide = false
	local spot = Instance.new("SpotLight")
	spot.Color = color
	spot.Range = 46
	spot.Brightness = 2.2
	spot.Angle = 110
	spot.Face = Enum.NormalId.Bottom
	spot.Shadows = false
	spot.Parent = head
end

local function crate(parent: Instance, center: Vector3, size: number)
	mapBox(
		parent,
		"Crate",
		center + Vector3.new(0, size * 0.5, 0),
		V(size, size, size),
		MAP.Wood,
		Enum.Material.WoodPlanks
	)
end

local function barrier(parent: Instance, center: Vector3, rotation: number)
	local part = mapBox(parent, "Barrier", center + Vector3.new(0, 2, 0), V(10, 4, 2.4), MAP.Concrete)
	part.CFrame = CFrame.new(part.Position) * CFrame.Angles(0, math.rad(rotation), 0)
end

--[[ A wrecked car. Two blocks is enough: at this scale the read is "waist-high
     thing to crouch behind", and that is exactly what it needs to be. ]]
local function wreck(parent: Instance, center: Vector3, rotation: number)
	local turn = CFrame.new(center) * CFrame.Angles(0, math.rad(rotation), 0)
	local body = mapBox(parent, "Wreck", center, V(13, 3, 5.6), MAP.Rust, Enum.Material.CorrodedMetal)
	body.CFrame = turn * CFrame.new(0, 1.5, 0)
	local cabin = mapBox(parent, "WreckCabin", center, V(7, 2.6, 5), MAP.Rust, Enum.Material.CorrodedMetal)
	cabin.CFrame = turn * CFrame.new(-0.5, 4.3, 0)
end

local function container(parent: Instance, center: Vector3, color: Color3)
	mapBox(
		parent,
		"Container",
		center + Vector3.new(0, 5, 0),
		V(12, 10, 30),
		color,
		Enum.Material.CorrodedMetal
	)
end

--[[
	Four walls, a floor and an optional ceiling, with holes where you ask for
	them. `gaps` entries are { face = "+X" | "-X" | "+Z" | "-Z", offset, width,
	height } measured along the face from its centre.

	Returns the openings so a caller can drop a Door into one.
]]
local function enclosure(
	parent: Instance,
	name: string,
	center: Vector3,
	interior: Vector3,
	thickness: number,
	gaps: { any },
	color: Color3,
	material: Enum.Material?,
	ceiling: boolean?
): (Model, { any })
	local model = Instance.new("Model")
	model.Name = name
	model.Parent = parent

	local height = interior.Y
	local outerX, outerZ = interior.X + thickness * 2, interior.Z + thickness * 2

	mapBox(
		model,
		"Floor",
		center - Vector3.new(0, thickness * 0.5, 0),
		V(outerX, thickness, outerZ),
		color,
		material
	)
	if ceiling ~= false then
		mapBox(
			model,
			"Ceiling",
			center + Vector3.new(0, height + thickness * 0.5, 0),
			V(outerX, thickness, outerZ),
			color,
			material
		)
	end

	local openings = {}
	local faces = {
		{ id = "-X", axis = "X", sign = -1, span = outerZ },
		{ id = "+X", axis = "X", sign = 1, span = outerZ },
		{ id = "-Z", axis = "Z", sign = -1, span = outerX },
		{ id = "+Z", axis = "Z", sign = 1, span = outerX },
	}

	for _, face in faces do
		local onFace = {}
		for _, gap in gaps do
			if gap.face == face.id then
				table.insert(onFace, gap)
			end
		end
		table.sort(onFace, function(a, b)
			return a.offset < b.offset
		end)

		local isX = face.axis == "X"
		local wallOffset = (if isX then interior.X else interior.Z) * 0.5 + thickness * 0.5

		--[[ Places one wall slab, given where along the face it starts and ends
		     and how tall it is. Everything below is expressed in those terms so
		     the segment maths only has to be right once. ]]
		local function slab(from: number, to: number, bottom: number, top: number)
			local length, tall = to - from, top - bottom
			if length <= 0.01 or tall <= 0.01 then
				return
			end
			local along = (from + to) * 0.5
			local position = if isX
				then center + Vector3.new(face.sign * wallOffset, bottom + tall * 0.5, along)
				else center + Vector3.new(along, bottom + tall * 0.5, face.sign * wallOffset)
			local size = if isX then V(thickness, tall, length) else V(length, tall, thickness)
			mapBox(model, "Wall", position, size, color, material)
		end

		local cursor = -face.span * 0.5
		for _, gap in onFace do
			slab(cursor, gap.offset - gap.width * 0.5, 0, height)
			slab(gap.offset - gap.width * 0.5, gap.offset + gap.width * 0.5, gap.height, height)
			cursor = gap.offset + gap.width * 0.5

			local doorCenter = if isX
				then center + Vector3.new(face.sign * wallOffset, gap.height * 0.5, gap.offset)
				else center + Vector3.new(gap.offset, gap.height * 0.5, face.sign * wallOffset)
			table.insert(openings, {
				face = face.id,
				cframe = CFrame.new(doorCenter),
				size = if isX
					then V(thickness, gap.height, gap.width)
					else V(gap.width, gap.height, thickness),
				slide = if isX then V(0, 0, gap.width) else V(gap.width, 0, 0),
			})
		end
		slab(cursor, face.span * 0.5, 0, height)
	end

	return model, openings
end

--[[
	A safe room: an enclosure, a Door in the named opening, supply shelves and a
	warm light so it reads as shelter the moment it comes out of the fog.

	The Door is authored CLOSED and carries FL_OpenOffset — the local-space vector
	LevelService slides it along to open. Sideways into the wall rather than up
	through the ceiling, because a room only 18 studs tall has nowhere to put a
	14-stud door overhead.
]]
local function safeRoom(
	parent: Instance,
	index: number,
	name: string,
	center: Vector3,
	interior: Vector3,
	gaps: { any }
): Model
	local model, openings =
		enclosure(parent, name, center, interior, 2, gaps, MAP.ConcreteDark, Enum.Material.Concrete)
	CollectionService:AddTag(model, TAG_SAFEROOM)
	model:SetAttribute("FL_Index", index)

	local opening = openings[1]
	if opening then
		local door =
			mapBox(model, "Door", opening.cframe.Position, opening.size, MAP.Rust, Enum.Material.DiamondPlate)
		door:SetAttribute("FL_OpenOffset", opening.slide)
	end

	local light = mapBox(
		model,
		"CeilingLight",
		center + Vector3.new(0, interior.Y - 1, 0),
		V(6, 0.4, 6),
		UITheme.Color.Accent,
		Enum.Material.Neon,
		false
	)
	light.CanCollide = false
	--[[ 40, not 60, and the shadows stay on.

	     This is one of only three shadow-casting lights in the game and the
	     shadow-map volume goes with the CUBE of the range, so 60 -> 40 is about
	     3.4x less of it for a light that never needed to reach that far: the
	     farthest interior floor corner of a safe room is 37.4 studs away. 38 is
	     the hard floor — below that the corners of the room go unlit on desktop
	     too, and a safe room you cannot see the corners of is worse than a
	     cheaper one. ]]
	pointLight(light, UITheme.Color.Accent, 40, 2.6, true)

	return model
end

--[[ A rescue closet. SurvivorService pivots a rescued survivor to the model's
     own pivot, so the door face is what the model is built around. ]]
local function rescueCloset(parent: Instance, center: Vector3, name: string)
	local model = Instance.new("Model")
	model.Name = name
	model.Parent = parent

	mapBox(
		model,
		"Back",
		center + Vector3.new(0, 6, -3.5),
		V(8, 12, 1),
		MAP.Metal,
		Enum.Material.DiamondPlate
	)
	mapBox(
		model,
		"Left",
		center + Vector3.new(-3.5, 6, 0),
		V(1, 12, 8),
		MAP.Metal,
		Enum.Material.DiamondPlate
	)
	mapBox(
		model,
		"Right",
		center + Vector3.new(3.5, 6, 0),
		V(1, 12, 8),
		MAP.Metal,
		Enum.Material.DiamondPlate
	)
	mapBox(model, "Top", center + Vector3.new(0, 12, 0), V(8, 1, 8), MAP.Metal, Enum.Material.DiamondPlate)
	local face = mapBox(
		model,
		"Door",
		center + Vector3.new(0, 6, 3.6),
		V(7, 11, 0.4),
		MAP.Rust,
		Enum.Material.CorrodedMetal
	)
	face.Transparency = 0.35
	pointLight(face, UITheme.Color.Accent, 14, 1.4)

	model.WorldPivot = CFrame.new(center + Vector3.new(0, 0, 4))

	-- Tagged on BOTH the model and the face a player will be looking at:
	-- SurvivorService tests the tag on the exact instance the client sends, and a
	-- client that raycasts and sends the part it hit must still find a closet.
	CollectionService:AddTag(model, TAG_CLOSET)
	CollectionService:AddTag(face, TAG_CLOSET)
end

--[[
	The level spline, in order. LevelService projects a point onto this polyline
	to answer "how far through the map is the team", which is the single number
	the whole Director is steered by: what counts as ahead of the survivors, where
	a Tank is due, whether a spawn is in front of them or behind.

	It doubles back on itself on purpose — a U-shaped route buys 1800 studs of
	progress inside a footprint you can see across, which is how a chapter stays
	long enough for the boss windows without becoming a corridor to nowhere.
]]
local ROUTE = table.freeze({
	V(-100, 3, 0), -- start safe room
	V(-45, 3, 0),
	V(30, 3, 0),
	V(120, 3, 0),
	V(200, 3, 25), -- around the bus barricade
	V(265, 3, 0), -- warehouse door
	V(340, 3, 0),
	V(420, 3, 0),
	V(500, 3, 0),
	V(560, 3, 0), -- checkpoint
	V(630, 3, 20), -- rail yard
	V(680, 3, 110),
	V(690, 3, 210),
	V(690, 3, 320),
	V(660, 3, 430),
	V(620, 13, 490), -- up onto the overpass
	V(520, 13, 495),
	V(410, 13, 495),
	V(330, 13, 495),
	V(280, 3, 497), -- down into the courtyard
	V(200, 3, 505), -- crescendo
	V(120, 3, 502),
	V(55, 3, 500), -- end safe room
})

-- Places the horde comes FROM. Every one of these is behind cover, inside a
-- side room, or beyond a wall: DirectorConfig requires a spawn to be out of
-- sight, and a node list that ignores that just makes the search fail.
local SPAWN_NODES = table.freeze({
	-- street: inside the buildings, up the alley, behind the barricade
	V(-20, 4, -125),
	V(60, 4, -138),
	V(127, 4, -125),
	V(220, 4, -125),
	V(-10, 4, 125),
	V(120, 4, 125),
	V(225, 4, 125),
	V(212, 4, -30),
	-- warehouse: the office, the side door, the far corners of the hall
	V(310, 4, -50),
	V(300, 4, -90),
	V(400, 4, -62),
	V(430, 18, 66),
	V(470, 4, -55),
	V(470, 4, 60),
	-- rail yard: the lanes between container stacks and outside the fence
	V(596, 4, -32),
	V(596, 4, 32),
	V(700, 4, -30),
	V(600, 4, 60),
	V(750, 4, 90),
	V(605, 4, 180),
	V(752, 4, 210),
	V(600, 4, 300),
	V(750, 4, 330),
	V(618, 4, 440),
	-- overpass: all three UNDERNEATH it. The deck is a straight road with no
	-- cover on it, so there is no honest out-of-sight point up there; the horde
	-- comes up the ramps at either end instead.
	V(470, 4, 460),
	V(360, 4, 530),
	V(320, 4, 455),
	-- courtyard: the two horde mouths and the ground outside the walls
	V(145, 4, 412),
	V(215, 4, 598),
	V(95, 4, 430),
	V(272, 4, 575),
})

local function buildStreet(root: Instance)
	local folder = folderIn(root, "Street")

	mapBox(folder, "Road", V(97.5, -0.5, 0), V(335, 1, 80), MAP.Asphalt, Enum.Material.Asphalt)
	for _, side in { -1, 1 } do
		mapBox(folder, "Sidewalk", V(97.5, 0.75, side * 51.25), V(335, 1.5, 22.5), MAP.Concrete)
	end

	-- The corridor walls. Varying heights stop the street reading as a trench and
	-- give the fog something to eat at different distances.
	mapBox(folder, "Building", V(-7.5, 18, -85), V(125, 36, 45), MAP.Brick, Enum.Material.Brick)
	mapBox(folder, "Building", V(127, 21, -85), V(96, 42, 45), MAP.ConcreteDark)
	mapBox(folder, "Building", V(220, 16, -85), V(90, 32, 45), MAP.Brick, Enum.Material.Brick)
	mapBox(folder, "Building", V(-10, 20, 85), V(120, 40, 45), MAP.ConcreteDark)
	mapBox(folder, "Building", V(120, 15, 85), V(110, 30, 45), MAP.Brick, Enum.Material.Brick)
	mapBox(folder, "Building", V(225, 24, 85), V(80, 48, 45), MAP.ConcreteDark)

	-- The alley: a dead end off the main sightline, which is exactly where a
	-- player who wants the extra pickup has to walk away from their team.
	mapBox(folder, "AlleyFloor", V(67, -0.5, -103.75), V(24, 1, 82.5), MAP.Asphalt, Enum.Material.Asphalt)
	mapBox(folder, "AlleyWall", V(54, 14, -126), V(2, 28, 40), MAP.Brick, Enum.Material.Brick)
	mapBox(folder, "AlleyWall", V(80, 14, -126), V(2, 28, 40), MAP.Brick, Enum.Material.Brick)
	mapBox(folder, "AlleyEnd", V(67, 14, -145), V(28, 28, 2), MAP.Brick, Enum.Material.Brick)
	itemPad(folder, V(67, 0, -135))

	-- Cover, in a rhythm: something to break every long shot, nothing that turns
	-- the street into a maze.
	wreck(folder, V(10, 0, -20), 8)
	wreck(folder, V(75, 0, 18), -14)
	wreck(folder, V(150, 0, -25), 96)
	wreck(folder, V(240, 0, 12), 74)
	crate(folder, V(40, 0, 30), 5)
	crate(folder, V(45, 0, 25), 5)
	crate(folder, V(43, 5, 28), 4)
	crate(folder, V(120, 0, -32), 6)
	barrier(folder, V(95, 0, -8), 12)
	barrier(folder, V(102, 0, 8), -8)

	-- The choke. A bus across two thirds of the road: the team either funnels
	-- through the remaining gap together or splits up, and splitting up is how
	-- this game kills people.
	mapBox(folder, "Bus", V(195, 6, -13), V(8, 12, 54), MAP.Rust, Enum.Material.CorrodedMetal)
	itemPad(folder, V(186, 0, 30))

	for _, x in { -30, 40, 110, 180, 245 } do
		lamp(folder, V(x, 1.5, -45), 18, UITheme.Color.AccentBright)
	end
	itemPad(folder, V(20, 1.5, -48))
	itemPad(folder, V(160, 1.5, 50))
end

local function buildWarehouse(root: Instance)
	local folder = folderIn(root, "Warehouse")

	enclosure(folder, "Hall", V(382.5, 0, 0), V(235, 34, 140), 2, {
		{ face = "-X", offset = 0, width = 16, height = 16 },
		{ face = "+X", offset = 0, width = 16, height = 16 },
		{ face = "-Z", offset = -70, width = 12, height = 12 },
	}, MAP.ConcreteDark, Enum.Material.Concrete)

	-- Mezzanine. The elevation is the point: from up here the whole hall is a
	-- shooting gallery, and the price is that the stairs are the only way down.
	mapBox(folder, "Mezzanine", V(385, 15.5, 55), V(190, 1, 30), MAP.Metal, Enum.Material.DiamondPlate)
	mapBox(folder, "MezzanineRail", V(385, 18, 40.5), V(190, 4, 1), MAP.Metal, Enum.Material.Metal, false)
	ramp(folder, "MezzanineRamp", V(292, 0, 55), V(332, 16, 55), 12, MAP.Metal, Enum.Material.DiamondPlate)
	ramp(folder, "MezzanineStair", V(478, 16, 48), V(478, 0, 18), 10, MAP.Metal, Enum.Material.DiamondPlate)
	itemPad(folder, V(400, 16, 55))
	itemPad(folder, V(450, 16, 55))

	-- Racks sit clear of the office so the two never intersect; three rows deep
	-- means every angle across the hall is broken by something.
	for _, x in { 345, 405, 465 } do
		for _, z in { -20, 6, 32 } do
			mapBox(folder, "Rack", V(x, 2.5, z), V(18, 5, 6), MAP.Rust, Enum.Material.CorrodedMetal)
			mapBox(folder, "RackShelf", V(x, 9, z), V(18, 0.6, 6), MAP.Metal, Enum.Material.Metal, false)
			mapBox(
				folder,
				"RackPost",
				V(x - 8.5, 5, z),
				V(0.8, 10, 0.8),
				MAP.Metal,
				Enum.Material.Metal,
				false
			)
			mapBox(
				folder,
				"RackPost",
				V(x + 8.5, 5, z),
				V(0.8, 10, 0.8),
				MAP.Metal,
				Enum.Material.Metal,
				false
			)
		end
	end
	itemPad(folder, V(345, 5, -20))
	itemPad(folder, V(465, 5, 32))

	-- Side office: a room off the hall with the only rescue closet before the
	-- checkpoint, so a dead teammate is worth a detour.
	enclosure(
		folder,
		"Office",
		V(310, 0, -50),
		V(44, 12, 30),
		2,
		{ { face = "+Z", offset = 0, width = 10, height = 10 } },
		MAP.Concrete,
		Enum.Material.Concrete
	)
	rescueCloset(folder, V(296, 0, -60), "RescueCloset_Warehouse")
	itemPad(folder, V(322, 0, -58), Enums.Slot.Health)

	marker(folder, "BossZone", V(400, 6, 8), V(80, 14, 90), TAG_BOSS)

	for _, x in { 300, 360, 420, 480 } do
		local fixture = mapBox(
			folder,
			"HangingLight",
			V(x, 30, 0),
			V(5, 0.6, 5),
			UITheme.Color.AccentBright,
			Enum.Material.Neon,
			false
		)
		fixture.CanCollide = false
		pointLight(fixture, UITheme.Color.AccentBright, 70, 2.0)
	end
	for _, z in { -60, 60 } do
		local emergency = mapBox(
			folder,
			"EmergencyLight",
			V(495, 16, z),
			V(1, 1.4, 3),
			UITheme.Color.Danger,
			Enum.Material.Neon,
			false
		)
		emergency.CanCollide = false
		pointLight(emergency, UITheme.Color.Danger, 30, 1.6)
	end
end

local function buildRailYard(root: Instance)
	local folder = folderIn(root, "RailYard")

	mapBox(folder, "YardFloor", V(674, -0.5, 215), V(182, 1, 520), MAP.Ground, Enum.Material.Ground)
	mapBox(folder, "Corridor", V(519, -0.5, 0), V(38, 1, 26), MAP.Concrete)
	mapBox(folder, "CorridorWall", V(519, 9, -14), V(38, 18, 2), MAP.ConcreteDark)
	mapBox(folder, "CorridorWall", V(519, 9, 14), V(38, 18, 2), MAP.ConcreteDark)

	-- Perimeter fence, with the checkpoint door and the overpass ramp as its
	-- only two openings.
	mapBox(folder, "Fence", V(583, 10, -26), V(2, 20, 40), MAP.Fence, Enum.Material.Metal)
	mapBox(folder, "Fence", V(583, 10, 240.5), V(2, 20, 469), MAP.Fence, Enum.Material.Metal)
	mapBox(folder, "Fence", V(765, 10, 215), V(2, 20, 520), MAP.Fence, Enum.Material.Metal)
	mapBox(folder, "Fence", V(674, 10, -45), V(182, 20, 2), MAP.Fence, Enum.Material.Metal)
	mapBox(folder, "Fence", V(724, 10, 475), V(82, 20, 2), MAP.Fence, Enum.Material.Metal)
	mapBox(folder, "Fence", V(591, 10, 475), V(16, 20, 2), MAP.Fence, Enum.Material.Metal)

	-- Containers, stacked into lanes. Two levels of cover and two levels of
	-- sightline, which is most of what makes an open yard interesting.
	container(folder, V(620, 0, 40), MAP.ContainerA)
	container(folder, V(620, 10, 40), MAP.ContainerB)
	container(folder, V(700, 0, 20), MAP.ContainerC)
	container(folder, V(640, 0, 120), MAP.ContainerB)
	container(folder, V(700, 0, 150), MAP.ContainerA)
	container(folder, V(700, 10, 150), MAP.ContainerC)
	container(folder, V(620, 0, 210), MAP.ContainerC)
	container(folder, V(690, 0, 260), MAP.ContainerB)
	container(folder, V(690, 10, 260), MAP.ContainerA)
	container(folder, V(620, 0, 330), MAP.ContainerA)
	container(folder, V(700, 0, 350), MAP.ContainerB)
	container(folder, V(640, 0, 430), MAP.ContainerC)

	ramp(folder, "ContainerRamp", V(678, 0, 150), V(694, 10, 150), 10, MAP.Metal, Enum.Material.DiamondPlate)
	mapBox(folder, "Gantry", V(670, 21.5, 265), V(120, 1, 10), MAP.Metal, Enum.Material.DiamondPlate)
	mapBox(folder, "GantryRail", V(670, 24, 260), V(120, 4, 0.8), MAP.Metal, Enum.Material.Metal, false)
	mapBox(folder, "GantryRail", V(670, 24, 270), V(120, 4, 0.8), MAP.Metal, Enum.Material.Metal, false)
	ramp(folder, "GantryStair", V(613, 22, 265), V(592, 0, 292), 8, MAP.Metal, Enum.Material.DiamondPlate)

	itemPad(folder, V(620, 20, 40))
	itemPad(folder, V(700, 20, 150))
	itemPad(folder, V(742, 0, 100))
	itemPad(folder, V(670, 22, 265))

	marker(folder, "BossZone", V(655, 8, 195), V(60, 16, 80), TAG_BOSS)

	for _, base in { V(760, 0, 60), V(588, 0, 240), V(756, 0, 400) } do
		lamp(folder, base, 26, UITheme.Color.AccentBright)
	end
end

local function buildOverpass(root: Instance)
	local folder = folderIn(root, "Overpass")

	ramp(folder, "OverpassRamp", V(632, 0, 450), V(608, 10, 496), 26, MAP.Concrete)
	mapBox(folder, "Deck", V(497.5, 9.5, 495), V(235, 1, 44), MAP.Concrete)
	mapBox(folder, "Deck", V(331.5, 9.5, 495), V(73, 1, 44), MAP.Concrete)

	-- The collapsed span. A single plank across a twelve-stud hole turns a wide
	-- road into a one-at-a-time crossing, which is a free panic beat that costs
	-- nothing to build and reads instantly.
	mapBox(folder, "Plank", V(374, 9.9, 506), V(14, 0.6, 6), MAP.Wood, Enum.Material.WoodPlanks)

	for _, z in { 473.5, 516.5 } do
		mapBox(folder, "Guardrail", V(497.5, 12, z), V(235, 4, 1), MAP.Metal, Enum.Material.Metal, false)
		mapBox(folder, "Guardrail", V(331.5, 12, z), V(73, 4, 1), MAP.Metal, Enum.Material.Metal, false)
	end
	for _, x in { 340, 430, 520, 600 } do
		mapBox(folder, "Pillar", V(x, 4.5, 495), V(7, 9, 7), MAP.ConcreteDark)
	end

	wreck(folder, V(450, 10, 488), 4)
	wreck(folder, V(560, 10, 504), -172)
	barrier(folder, V(500, 10, 495), 88)
	itemPad(folder, V(470, 10, 480))

	rescueCloset(folder, V(540, 10, 478), "RescueCloset_Overpass")
	ramp(folder, "DescentRamp", V(300, 10, 495), V(268, 0, 495), 26, MAP.Concrete)

	for _, x in { 330, 420, 510, 590 } do
		lamp(folder, V(x, 10, 476), 16, UITheme.Color.AccentBright)
	end
end

local function buildCourtyard(root: Instance)
	local folder = folderIn(root, "Courtyard")

	enclosure(folder, "Yard", V(185, 0, 505), V(200, 26, 150), 2, {
		{ face = "+X", offset = -10, width = 30, height = 20 },
		{ face = "-X", offset = -5, width = 12, height = 14 },
		{ face = "-Z", offset = -40, width = 16, height = 14 },
		{ face = "+Z", offset = 30, width = 16, height = 14 },
	}, MAP.ConcreteDark, Enum.Material.Concrete, false)

	-- The generator. Starting it is the crescendo: a bounded, scripted horde on
	-- top of whatever the Director is already doing, arriving through two mouths
	-- in the walls that the team can see and still cannot cover at once.
	mapBox(folder, "GeneratorBase", V(185, 1, 505), V(12, 2, 9), MAP.Metal, Enum.Material.DiamondPlate)
	mapBox(folder, "GeneratorHousing", V(185, 5, 505), V(9, 6, 7), MAP.Rust, Enum.Material.CorrodedMetal)
	mapBox(folder, "GeneratorExhaust", V(189, 9, 505), V(1.4, 8, 1.4), MAP.Metal, Enum.Material.Metal, false)
	local panel = mapBox(
		folder,
		"GeneratorPanel",
		V(185, 5, 501.4),
		V(3, 1.8, 0.3),
		UITheme.Color.Accent,
		Enum.Material.Neon,
		false
	)
	panel.CanCollide = false
	pointLight(panel, UITheme.Color.Accent, 26, 2.4)

	marker(folder, "PanicTrigger", V(185, 6, 505), V(34, 14, 34), TAG_PANIC)

	barrier(folder, V(150, 0, 470), 20)
	barrier(folder, V(160, 0, 540), -30)
	barrier(folder, V(225, 0, 470), 70)
	barrier(folder, V(230, 0, 545), 110)
	crate(folder, V(120, 0, 520), 6)
	crate(folder, V(126, 0, 514), 6)
	wreck(folder, V(245, 0, 555), 40)

	itemPad(folder, V(120, 0, 462))
	itemPad(folder, V(252, 0, 560))
	itemPad(folder, V(140, 0, 548))

	for _, spot in { V(110, 0, 440), V(260, 0, 570) } do
		lamp(folder, spot, 22, UITheme.Color.AccentBright)
	end
	for _, spot in { V(145, 20, 434), V(215, 20, 576) } do
		local hazard =
			mapBox(folder, "HazardLight", spot, V(2, 1.2, 1), UITheme.Color.Danger, Enum.Material.Neon, false)
		hazard.CanCollide = false
		pointLight(hazard, UITheme.Color.Danger, 34, 2.0)
	end
end

--[[
	True when this place already has a real level in it.

	Two independent tests, because a map can be present before it is tagged:

	  * anything tagged FL_FlowNode or FL_SpawnNode that this module did not
	    build — those are the two tags nothing plays without, so either one is
	    proof a level is installed;
	  * a Workspace container called "Maps" with geometry in it, which is where
	    the hand-built map lives. This second test matters because the tagging
	    pass may not have run yet when assets are warmed: init() happens before
	    every start(), and building a grey-box street through the middle of
	    somebody's map is not a mistake that can be undone at runtime.

	Our own fallback is excluded from both, or it would count as evidence of
	itself and could never be rebuilt after a rebuild.
]]
local function hasRealLevel(): boolean
	local ours = Workspace:FindFirstChild(MAP_NAME)
	for _, tag in { TAG_FLOW, TAG_SPAWN } do
		for _, node in CollectionService:GetTagged(tag) do
			if node:IsDescendantOf(Workspace) and not (ours and node:IsDescendantOf(ours)) then
				return true
			end
		end
	end

	local maps = Workspace:FindFirstChild("Maps")
	if maps and maps ~= ours and maps:FindFirstChildWhichIsA("BasePart", true) then
		return true
	end

	--[[
		And the maps MapService owns.

		This check used to look only at Workspace, which was wrong the moment maps
		moved into storage: MapService's init runs first and relocates every map
		out of Workspace.Maps into ServerStorage.Maps, so by the time this ran the
		world looked empty and the grey-box chapter built itself on top of a place
		that had two perfectly good maps in it. Ask the service, not the world.
	]]
	local mapService = Registry.find("MapService")
	if mapService and #mapService:getAvailableIds() > 0 then
		return true
	end

	-- Direct fallback, for the window before MapService has registered.
	local stored = ServerStorage:FindFirstChild("Maps")
	if stored and stored:FindFirstChildWhichIsA("BasePart", true) then
		return true
	end

	return false
end

--[[
	FALLBACK ONLY — this is not the game's level.

	The real map is the user's own ("Zombieville", under Workspace.Maps). This
	grey-box chapter exists so that a place with NO tagged level in it is still
	playable end to end: it builds if, and only if, Workspace contains no
	FL_FlowNode or FL_SpawnNode geometry that this module did not build itself.
	It never overwrites a real map and it never duplicates itself — the moment
	the user's map is tagged, this returns nil and touches nothing.

	Everything gameplay-relevant in it is a TAG, not a coordinate: LevelService
	and the Director read FL_FlowNode, FL_SpawnNode, FL_ItemSpawn,
	FL_PanicTrigger and FL_BossZone out of CollectionService, which is exactly
	what lets a hand-built map replace all of this with zero code changes.
]]
function PlaceholderFactory:buildTestMap(): Model?
	local existing = Workspace:FindFirstChild(MAP_NAME)
	if existing and existing:IsA("Model") then
		return existing
	end
	if hasRealLevel() then
		print("[PlaceholderFactory] Workspace already has a level in it; the fallback map stays unbuilt")
		return nil
	end

	local root = Instance.new("Model")
	root.Name = MAP_NAME

	--[[
		Lighting is done entirely with fixtures — lamps, hanging lights, neon
		signs, hazard lamps — and never by touching the Lighting service. The
		project file already sets ClockTime 4.25, a near-black Ambient and fog
		from 60 to 620 studs, and an Atmosphere instance would silently OVERRIDE
		those FogStart/FogEnd values. So the map is lit to suit that setup rather
		than allowed to fight it: warm amber where the team is safe, red where
		something is about to go wrong, and long unlit stretches in between so the
		fog has somewhere to hide a horde.
	]]

	-- One ground plane under everything. Cheaper than patching floor into every
	-- pocket the spawn nodes sit in, and it means a survivor who walks off the
	-- level lands on dirt instead of falling out of the world.
	mapBox(root, "Ground", V(320, -2, 215), V(1100, 2, 900), MAP.Ground, Enum.Material.Ground)
	for _, wall in
		{
			{ V(320, 20, -235), V(1100, 40, 4) },
			{ V(320, 20, 665), V(1100, 40, 4) },
			{ V(-230, 20, 215), V(4, 40, 900) },
			{ V(870, 20, 215), V(4, 40, 900) },
		}
	do
		mapBox(root, "Perimeter", wall[1], wall[2], MAP.ConcreteDark)
	end

	local start = safeRoom(root, 1, "SafeRoom_Start", V(-100, 0, 0), V(56, 18, 36), {
		{ face = "+X", offset = 0, width = 12, height = 14 },
	})
	itemPad(start, V(-118, 0, -12), Enums.Slot.Health)
	itemPad(start, V(-118, 0, 12), Enums.Slot.Primary)
	itemPad(start, V(-92, 0, -14), Enums.Slot.Throwable)

	-- LoadCharacter needs somewhere to put a body before SurvivorService pivots
	-- it to the level's spawn CFrame; without this a joining player materialises
	-- at the origin for a frame, in the middle of the street.
	local spawnPoint = Instance.new("SpawnLocation")
	spawnPoint.Name = "StartSpawn"
	spawnPoint.Size = V(14, 1, 14)
	spawnPoint.CFrame = CFrame.new(-100, 0.5, 0)
	spawnPoint.Anchored = true
	spawnPoint.CanCollide = false
	spawnPoint.CanQuery = false
	spawnPoint.Transparency = 1
	spawnPoint.Neutral = true
	spawnPoint.Duration = 0
	spawnPoint.Parent = start

	buildStreet(root)
	buildWarehouse(root)

	local checkpoint = safeRoom(root, 2, "SafeRoom_Checkpoint", V(560, 0, 0), V(44, 18, 34), {
		{ face = "-X", offset = 0, width = 12, height = 14 },
		{ face = "+X", offset = 0, width = 12, height = 14 },
	})
	itemPad(checkpoint, V(546, 0, -13), Enums.Slot.Health)
	itemPad(checkpoint, V(572, 0, -13), Enums.Slot.Pills)
	itemPad(checkpoint, V(560, 0, 13), Enums.Slot.Primary)

	buildRailYard(root)
	buildOverpass(root)
	buildCourtyard(root)

	local finish = safeRoom(root, 3, "SafeRoom_End", V(55, 0, 500), V(56, 18, 36), {
		{ face = "+X", offset = 0, width = 12, height = 14 },
	})
	itemPad(finish, V(40, 0, 486), Enums.Slot.Health)
	itemPad(finish, V(70, 0, 486), Enums.Slot.Pills)

	local flow = folderIn(root, "Flow")
	for index, point in ROUTE do
		local node = marker(flow, string.format("FlowNode_%02d", index), point, V(3, 3, 3), TAG_FLOW)
		node:SetAttribute("FL_Order", index)
	end

	local nodes = folderIn(root, "SpawnNodes")
	for _, point in SPAWN_NODES do
		spawnNode(nodes, point)
	end

	root.Parent = Workspace
	return root
end

-- ════════════════════════════════════════════════════════════════════════════
--  Lifecycle
-- ════════════════════════════════════════════════════════════════════════════

--[[
	Prepares everything the round will ask for, before it asks.

	Idempotent: every template is cached by key and the fallback map refuses to
	build twice, so a second call is a handful of table lookups.

	Warming matters more than it looks. The first shot of a round would otherwise
	pay for preparing a gun, and the first horde would pay for sanitising,
	scaling and verifying thirteen rigs — both at exactly the moment the game is
	trying to convince somebody it feels good.

	It also prints what it found. Somebody who has just dropped a folder of
	models into a place needs one line telling them how many of them the game is
	actually using, and no way to get it other than this.
]]
--[[ Every throwable id, as a list. Order is whatever the enum iterates in and
     nothing here depends on it: the two callers want the SET. ]]
local function throwableIds(): { string }
	local ids: { string } = {}
	for _, id in Enums.Throwable do
		table.insert(ids, id)
	end
	table.sort(ids)
	return ids
end

function PlaceholderFactory:ensureAssets()
	for weaponId in WeaponConfig.all() do
		self:buildWeaponModel(weaponId)
		self:buildViewmodel(weaponId)
	end

	--[[ Per kind: how many rigs it has, and — for the ones running on a grey box
	     — WHICH they are. The count alone was fine when supplying a rig meant
	     making a folder; now that every folder exists from boot, an empty one is
	     the normal "not filled in yet" state and naming them is the difference
	     between a summary and a to-do list. ]]
	local rigs = {}
	local empty = {}
	local oversized = {}
	--[[ Every boss's measured extents, keyed by kind, and WHERE the body came
	     from. Filled in the walk below and judged after it, because the yardstick
	     is one of the entries — and because a supplied rig and a grey-boxed one
	     cannot be compared. See the judgement below. ]]
	local bossSize: { [string]: { size: Vector3, supplied: boolean } } = {}
	for kind, definition in InfectedConfig.all() do
		local variants = variantsFor(kind)
		table.insert(rigs, string.format("%s x%d", kind, #variants))

		--[[ Through the same name list the rigs were actually looked up with. It
		     used to ask for the id alone, which is a different question from the
		     one prepareInfected asks — so a kind supplying its models under a
		     folder alias was reported as having none, and the one line somebody
		     reads after dropping models into a place said the opposite of the
		     truth about them. ]]
		local supplied = suppliedEntry("Infected", infectedNames(kind, definition)) ~= nil
		if not supplied then
			table.insert(empty, kind)
		end

		--[[ And how big the thing actually came out, for the ones where that is a
		     question worth asking. A boss is the only kind whose size can stop
		     the encounter working — too tall and it cannot follow a team indoors
		     — and the size is a product of an artist's units and a multiplier, so
		     nothing before this point knows the answer. Measured from the prepared
		     template, which is the body that will actually spawn.

		     Collected rather than judged here: the yardstick is the Tank's own
		     height and this loop walks a dictionary, so the Tank may not have been
		     seen yet. See below. ]]
		if definition.isBoss and variants[1] then
			local _, size = variants[1]:GetBoundingBox()
			bossSize[kind] = { size = size, supplied = supplied }
		end
	end

	--[[
		Now that every boss has been measured, judge them against the Tank.

		Nothing happens without one. A place with no Tank rig has no yardstick,
		and inventing an absolute is exactly the mistake this replaced — see
		BOSS_HEIGHT_RATIO.

		── AND ONLY LIKE AGAINST LIKE ──────────────────────────────────────────
		A supplied rig and a grey-boxed one are not on the same ruler, and
		comparing them says more about which folders somebody has filled in than
		about either creature. The Metallic is the worked example: its scale is
		solved backwards from a targetHeight of 17, so the grey box builds a
		17-stud Metallic — while the grey-box Tank is 10.6, because nothing in
		SHAPES can know that a real Tank arrives at 13.6. Run those two against
		each other and the check reports x1.61 and warns, on a place where both
		bodies are exactly what this file itself built.

		So the ratio is only printed, and only asserted on, when both bodies came
		from the same place. Mixed pairs still get their studs — the measurement
		is real either way — with the ratio withheld rather than invented.
	]]
	local reference = bossSize[Enums.Infected.Tank]
	for kind, entry in bossSize do
		local size = entry.size
		local across = math.max(size.X, size.Z)
		local comparable = reference ~= nil and reference.supplied == entry.supplied
		if comparable then
			--[[ Reported with its ratio, because the ratio is the number somebody
			     tuning a targetHeight actually wants and the studs alone gave them
			     nothing to compare against. ]]
			table.insert(
				oversized,
				string.format("%s %.1fx%.1f (x%.2f)", kind, size.Y, across, size.Y / reference.size.Y)
			)
		else
			--[[ The tag earns its space: "Metallic 17.0x11.1" beside a Tank with a
			     ratio, and no ratio of its own, otherwise reads as a bug in the
			     line rather than as the one fact that explains it. ]]
			table.insert(
				oversized,
				string.format(
					"%s %.1fx%.1f (%s)",
					kind,
					size.Y,
					across,
					if entry.supplied then "supplied, no supplied Tank to compare" else "grey box"
				)
			)
		end

		if comparable and size.Y > reference.size.Y * BOSS_HEIGHT_RATIO then
			warnOnce(
				"bossfit:" .. kind,
				string.format(
					"the %s stands %.1f studs tall, %.2f times the Tank's %.1f. The Tank is the "
						.. "biggest thing this project's maps are known to carry, so past about "
						.. "%.1f it will hang up on doorways the Tank clears. Lower its "
						.. "targetHeight, or scale the rig down before importing it.",
					kind,
					size.Y,
					size.Y / reference.size.Y,
					reference.size.Y,
					reference.size.Y * BOSS_HEIGHT_RATIO
				)
			)
		end
	end

	table.sort(rigs)
	table.sort(empty)
	table.sort(oversized)

	for slot, ids in
		{
			[Enums.Slot.Health] = { Enums.HealthItem.Medkit, Enums.HealthItem.Defibrillator },
			[Enums.Slot.Pills] = { Enums.PillItem.PainPills, Enums.PillItem.Adrenaline },
			--[[ Read off the enum rather than listed, because the intent here is
			     "all of them" and a hand-written copy of a list is a list that
			     goes stale the first time somebody adds an item. This one had
			     three entries and the enum had four for exactly as long as it
			     took to notice. ]]
			[Enums.Slot.Throwable] = throwableIds(),
		}
	do
		for _, itemId in ids do
			self:buildPickup(slot, itemId)
		end
	end

	print(
		string.format(
			"[PlaceholderFactory] weapons %d supplied / %d grey-boxed · viewmodels %d / %d · "
				.. "infected %d kinds supplied / %d grey-boxed · bosses (tall x wide): %s · rigs: %s",
			resolved.Weapons.real,
			resolved.Weapons.grey,
			resolved.Viewmodels.real,
			resolved.Viewmodels.grey,
			resolved.Infected.real,
			resolved.Infected.grey,
			if #oversized > 0 then table.concat(oversized, ", ") else "none",
			table.concat(rigs, ", ")
		)
	)

	--[[
		WHICH weapons grey-boxed, and under what names they were looked for.

		The count on the line above has never been enough to act on. "viewmodels
		26 / 5" tells somebody who has just spent an evening building a machete
		that five weapons are stand-ins and not which five, so the next step is
		always to guess — and the usual answer, that the model is in the right
		folder under a name nothing matches, is invisible from a number.

		Printed for the first-person category only. A viewmodel falls back to the
		world model, so anything listed here has no model in EITHER folder; adding
		the world list as well would print most weapons twice and bury the one
		list that is complete.
	]]
	local missingModels = {}
	for weaponId, tried in greyBoxed.Viewmodels do
		table.insert(missingModels, string.format("%s (searched: %s)", weaponId, table.concat(tried, ", ")))
	end
	if #missingModels > 0 then
		table.sort(missingModels)
		print(
			string.format(
				"[PlaceholderFactory] %d weapon(s) are drawn as grey-box stand-ins because no model "
					.. "was found for them. Put yours in ServerStorage.Assets.Weapons (or "
					.. "ReplicatedStorage.Assets.Weapons) named EXACTLY one of the names in brackets — "
					.. "a Model or a Tool, either works. See docs/WEAPON_MODELS.md: %s",
				#missingModels,
				table.concat(missingModels, " · ")
			)
		)
	end

	--[[
		And the models that ARE supplied but said nothing about where to hold
		them.

		A different problem from the list above and easy to confuse with it:
		these models loaded fine. They have no Handle part and no Grip
		attachment, so the hold point is this file's proportions rather than the
		author's intent — which is a decent guess for a rifle-shaped thing and a
		poor one for anything unusual, a dual-wield pair worst of all, since
		where the two halves sit is not measurable from outside.

		Worth one line because it is silent otherwise: a gun held slightly wrong
		looks like an animation problem, and the fix is one attachment.
	]]
	local guessed = {}
	for weaponId in guessedGrips do
		table.insert(guessed, weaponId)
	end
	if #guessed > 0 then
		table.sort(guessed)
		print(
			string.format(
				"[PlaceholderFactory] %d supplied weapon model(s) carry no Handle part and no Grip "
					.. "attachment, so where the hand holds them was guessed from their proportions. "
					.. "Add an Attachment called Grip where the hand goes — and Muzzle at the barrel "
					.. "— to make it exact. See docs/WEAPON_MODELS.md: %s",
				#guessed,
				table.concat(guessed, " · ")
			)
		)
	end

	--[[
		WHICH WAY EACH SUPPLIED GUN WAS DECIDED TO POINT, AND ON WHAT EVIDENCE.

		Printed for every supplied model rather than only the ones that got
		changed, because the failure that costs a day is the SILENT one: a model
		the pipeline assumed was already built barrel-down-Z, was wrong about,
		and therefore said nothing at all about. A gun that comes out sideways
		with an empty log is a gun nobody can debug.

		Three verdicts, in descending order of how much they can be trusted:
		measured from an artist's own Muzzle, guessed from the longest axis and
		straightened, or assumed and left alone. If a weapon looks wrong in the
		hand, find it here first — the verdict says whether the pipeline made a
		decision about it or simply never looked.
	]]
	local facingLines = {}
	for weaponId, verdict in facingVerdicts do
		table.insert(facingLines, string.format("%s: %s", weaponId, verdict))
	end
	if #facingLines > 0 then
		table.sort(facingLines)
		print(
			string.format(
				"[PlaceholderFactory] which way each supplied weapon was taken to point — "
					.. "%q means measured, %q means changed, %q means neither. Override any of them "
					.. "with WeaponConfig.modelRotation. See docs/WEAPON_MODELS.md: %s",
				"from its own Muzzle attachment",
				"STRAIGHTENED",
				"ASSUMED",
				table.concat(facingLines, " · ")
			)
		)
	end

	--[[ Which rigs animate from their own clips and which fall back to this
	     game's set. Both are correct; only one of them is visible from Studio. ]]
	local usingConfig = {}
	for kind, variants in animationSources.config do
		table.sort(variants)
		table.insert(
			usingConfig,
			string.format(
				"%s [%s%s]: %s",
				kind,
				animationRig[kind] or "?",
				--[[ Only ever on an R15 line, and it is the line people argue
				     with: a rig built as R6 that reads R15 gets clips aimed at
				     joints it does not have, which plays and moves nothing. ]]
				if animationRigWhy[kind] then " — has a part named " .. animationRigWhy[kind] else "",
				table.concat(variants, ", ")
			)
		)
	end
	--[[
		And the block that answers the question directly: WHICH MODELS ARE BROKEN.

		One line per variant with something wrong, naming the fault rather than a
		symptom. A clean roster prints nothing at all, so this is silence when
		there is nothing to say and an exact list when there is.
	]]
	if #missingAnimator > 0 then
		table.sort(missingAnimator)
		warn(
			string.format(
				"[PlaceholderFactory] %d rig(s) ship with no Animator under their Humanoid, so they "
					.. "could not play a single clip on their own. One was added to each at boot, which "
					.. "costs nothing and fully fixes them — add an Animator in Studio if you would "
					.. "rather the models carried their own: %s",
				#missingAnimator,
				table.concat(missingAnimator, ", ")
			)
		)
	end

	local faultLines = {}
	for kind, variants in rigFaults do
		table.sort(variants)
		for _, line in variants do
			table.insert(faultLines, string.format("%s/%s", kind, line))
		end
	end
	if #faultLines > 0 then
		table.sort(faultLines)
		warn(
			string.format(
				"[PlaceholderFactory] %d rig(s) have something wrong that will stop or spoil their "
					.. "animation. Each is repaired per body at spawn, which costs work every time and "
					.. "guesses proportions — run studio-scripts/RigDoctor once to fix them in the "
					.. "models themselves:",
				#faultLines
			)
		)
		for _, line in faultLines do
			warn("    " .. line)
		end
	end

	if #usingConfig > 0 then
		table.sort(usingConfig)
		local ownCount = 0
		for _, variants in animationSources.own do
			ownCount += #variants
		end
		print(
			string.format(
				"[PlaceholderFactory] animating from the built-in clips because the model carries "
					.. "none of its own (%d other rig(s) use theirs) — %s",
				ownCount,
				table.concat(usingConfig, " · ")
			)
		)
	end

	if #empty > 0 then
		print(
			string.format(
				"[PlaceholderFactory] still grey-boxed, no model supplied yet: %s — drop one into "
					.. "Assets.Infected.<Kind> (several is fine, one is picked per body).",
				table.concat(empty, ", ")
			)
		)
	end

	self:buildTestMap()
end

--[[
	Creates an empty, correctly named folder for every kind the game knows about.

	Supplying a rig is "put a model in ReplicatedStorage.Assets.Infected.<Kind>",
	and every word of that has to be spelled the way Enums.Infected spells it —
	which means the single most common way to supply a rig and have nothing
	happen is a folder called "Boomers", or "Spitter " with a trailing space, or
	one that was never made because the kind is new and nobody knew it existed.
	None of those produce an error. They produce a grey box and a line in the
	boot summary that reads exactly like a kind nobody has got to yet.

	So the game makes them. Every folder is there, named right, on the first
	boot after a kind is added, and supplying a rig is drag-and-drop into a
	folder that already exists. An empty one is free — variantsFor greybox-es a
	kind whether the folder is missing or merely empty, so this changes nothing
	about behaviour and everything about discoverability.

	Only ever creates. A folder with models in it is left exactly alone.
]]
function PlaceholderFactory:ensureAssetFolders()
	local assets = folderIn(ReplicatedStorage, ASSETS_FOLDER)
	--[[
		A folder per throwable the MAP does not place.

		Molotovs and pipe bombs come out of the level now — see
		MapConfig.MapItems — so making them a home in here would be making a home
		nobody should put anything in, every boot, for the rest of the game's
		life. Worse than useless: an empty folder next to a full one reads as the
		place things go.

		Every throwable has a family today, so this makes nothing — which is the
		correct outcome and not a broken loop. It is here for the next throwable
		that has no family: it gets a home the boot it is added, without anybody
		remembering to make one.
	]]
	local madeThrowables = {}
	for _, kind in Enums.Throwable do
		if MapConfig.mapItemFor(kind) then
			continue
		end
		local throwables = folderIn(assets, "Throwables")
		if not throwables:FindFirstChild(kind) then
			folderIn(throwables, kind)
			table.insert(madeThrowables, kind)
		end
	end
	if #madeThrowables > 0 then
		table.sort(madeThrowables)
		print(
			string.format(
				"[PlaceholderFactory] made empty throwable folders for: %s — drop a model or a "
					.. "Tool into Assets.Throwables.<Id> and it is used in the hand, on the floor "
					.. "and in flight on the next run. The rest are placed in the map instead.",
				table.concat(madeThrowables, ", ")
			)
		)
	end

	local infected = folderIn(assets, "Infected")
	local made = {}
	for _, kind in Enums.Infected do
		--[[ FindFirstChild, not "is there a Folder called this". Supplying a rig
		     as a bare Model named after the kind — Assets.Infected.Hunter as a
		     Model rather than a folder holding one — is a supported layout, and
		     folderIn would happily create a SECOND child with the same name next
		     to it. Two children called "Hunter" and a FindFirstChild deciding
		     between them is not a thing anyone should have to debug. ]]
		if not infected:FindFirstChild(kind) then
			folderIn(infected, kind)
			table.insert(made, kind)
		end
	end
	if #made > 0 then
		table.sort(made)
		print(
			string.format(
				"[PlaceholderFactory] made empty rig folders for: %s — drop a model (or several, "
					.. "they are picked from at random) into Assets.Infected.<Kind> and it is used "
					.. "on the next run.",
				table.concat(made, ", ")
			)
		)
	end
end

function PlaceholderFactory:init()
	--[[ Folders first: they are where a user PUTS things, so they have to exist
	     before anything goes looking, and a kind added in code is a folder
	     waiting for a model on the very next boot. ]]
	self:ensureAssetFolders()

	-- Assets exist before any other service's start() runs, which is what lets
	-- LevelService index the map's tags in its own start() without waiting.
	self:ensureAssets()
end

--[[ A map arriving invalidates everything this file copied out of the last one.
     Connected in start() rather than init() because MapService registers itself
     in the same pass and may not exist yet when init() runs. ]]
function PlaceholderFactory:start()
	local mapService = Registry.find("MapService")
	if mapService and mapService.mapChanged then
		mapService.mapChanged:connect(clearMapTemplates)
	end
end

Registry.register("PlaceholderFactory", PlaceholderFactory)

return PlaceholderFactory
