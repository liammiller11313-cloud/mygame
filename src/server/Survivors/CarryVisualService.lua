--!nonstrict
--[[
	CarryVisualService — what a survivor is carrying, on the survivor.

	In Left 4 Dead the single most useful thing you know about a teammate is what
	they are holding, and you learn it by LOOKING at them. There is no menu, no
	roster panel, no callout — the kit is on their back and the shotgun is in
	their hands, and a glance down a corridor tells you whether the person in
	front of you can save you and what they can do about the horde behind you.
	That read is worth more than any HUD element could be, because it comes for
	free while you are already looking where you were going to look.

	So this service mirrors two slots onto the character:

	  BACK    the Health slot. Take a kit, it appears between your shoulder
	          blades. Spend it, drop it, or go down and lose it, and it is gone.
	  HANDS   whichever weapon is selected. Swap to your pistol and the rifle is
	          replaced by it, which is the only honest way to show a swap without
	          inventing a sling.

	Both live on the SERVER'S copy of the character, so they replicate like any
	other part of it: everybody sees the same thing at the same moment, including
	a dead player watching from the spectate camera.

	── WHY THE HANDS MOUNT IS WORTH THE PARTS ───────────────────────────────────
	It is not only decoration. ImpactController resolves another player's muzzle
	flash by searching their character for an attachment named "Muzzle" and falls
	back to guessing a point in front of their face when it finds none. Every
	world weapon model carries one, so the moment a gun is in somebody's hands
	their muzzle flash moves to its barrel with no change on the client at all.

	── WHY THE MODEL IS WELDED, NOT PARENTED ────────────────────────────────────
	A prop parented into a character and left alone falls off it: the parts are
	simulated, the character moves, and physics resolves the disagreement by
	putting the kit on the floor twenty studs back. Every part is welded to one
	root, that root is welded to the limb, and everything is made massless so a
	kit cannot change how a survivor moves. Massless matters more than it sounds:
	a supplied prop built at map scale can weigh more than the person wearing it.

	── WHY IT IS SIZED FROM THE MODEL ───────────────────────────────────────────
	The medkits are props built to be read from three studs away on the floor, not
	to be worn. Scaling by a fixed factor works for a kit that happens to be about
	the right size and turns a large one into a wardrobe, so anything over
	MapConfig.Medkits.CarryMaxSize is scaled to fit that instead. Weapons need
	none of this: PlaceholderFactory has already sized and welded them.

	── THE GRIP ─────────────────────────────────────────────────────────────────
	A weapon model is held by lining its "Grip" attachment up with the hand rather
	than by a table of per-weapon offsets. PlaceholderFactory stamps that
	attachment — at the model origin for a shape it authored, guessed from the
	handle's own box for one it was given — so this file never has to know what a
	particular gun looks like. See `ensureGrip` there.

	── KNOWN GAP ────────────────────────────────────────────────────────────────
	The arm is not posed. Survivors run Roblox's default animations, which swing
	the arms, and a welded gun swings with them; a real hold pose is a tool
	animation overlay and is the natural next step. The gun is welded a little
	forward of the hand so that at rest it reads as low-ready rather than as
	pointing at the floor, which is most of the difference.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local AnimationCache = require(Shared.Util.AnimationCache)
local AnimationConfig = require(Shared.Config.AnimationConfig)
local Attributes = require(Shared.Net.Attributes)
local Enums = require(Shared.Enums)
local GameConfig = require(Shared.Config.GameConfig)
local MapConfig = require(Shared.Config.MapConfig)
local Registry = require(Shared.Util.Registry)
local RigUtil = require(Shared.Util.RigUtil)
local Trove = require(Shared.Util.Trove)
local WeaponConfig = require(Shared.Config.WeaponConfig)

local KIT = MapConfig.Medkits
local LA = Attributes.Loadout
local TORCH = GameConfig.Flashlight

local CarryVisualService = {}

local serviceTrove = Trove.new()

--[[ The two places something can hang. Named rather than indexed because both
     the model's name and the bookkeeping key are built from this, and a mount
     appearing twice on one rig is the failure this prevents. ]]
local MOUNT = table.freeze({
	Back = "Back",
	Hands = "Hands",
})

local CARRY_NAME = "FL_Carried"

--[[
	Where a weapon sits relative to the hand.

	Forward of it and turned very slightly outward, so a rifle at rest reads as
	low-ready rather than as buried in the leg it would otherwise intersect.
	Rotation is deliberately near-identity: the limb already faces the way the
	survivor does, and every world model is authored barrel-down-Z, so a gripped
	weapon points where its owner is looking without any correction at all.

	These are art numbers, not balance numbers, which is why they are here rather
	than in a Config — the same split ViewmodelController's pose table makes.
]]
local HAND_OFFSET = CFrame.new(0, 0, -0.25) * CFrame.Angles(0, math.rad(-4), 0)

--[[ Fallback grip height when a limb carries no RightGripAttachment, as a
     fraction of its own length. R6 arms and R15 hands both put the hand at the
     far end of the part, so "most of the way down it" is right for both. ]]
local HAND_DROP = 0.5

--[[ The slots whose contents are shown in the hands, and how. Anything not in
     here is carried invisibly, which is the correct answer for pills — a bottle
     in a fist is not a read anybody needs at twenty studs. ]]
local HAND_SLOTS: { [string]: string } = {
	[Enums.Slot.Primary] = "Weapon",
	[Enums.Slot.Secondary] = "Weapon",
	--[[ Melee, which needs saying because this table is the ONLY thing that
	     decides whether a slot is visible. It was missed when melee got a slot of
	     its own, and the symptom was the worst kind: drawing a machete emptied
	     the survivor's hands and stopped the hold pose, because `wantedKeys`
	     resolves an unlisted slot to "" and `refresh` reads that as "holding
	     nothing". ]]
	[Enums.Slot.Melee] = "Weapon",
	--[[ A selected kit comes OFF the back and INTO the hands. That swap is the
	     single clearest tell in Left 4 Dead that somebody is about to heal, and
	     it costs nothing here: it is the same model, mounted somewhere else. ]]
	[Enums.Slot.Health] = "Medkit",
}

--[[ What is on each survivor right now, per mount. The `key` is what is being
     shown rather than the model itself, so a refresh that would rebuild the same
     thing can be skipped — and `refresh` is called for every slot change. ]]
type Worn = { model: Model, key: string }
local worn: { [Player]: { [string]: Worn } } = {}

--[[ The hold pose, per character rather than per player: the track belongs to
     an Animator that dies with the rig, and keeping it keyed by the model is
     what stops a respawn playing into a corpse. ]]
--[[
	The fire / reload / equip tracks, per player.

	Declared up here with the other per-player tables rather than beside the
	functions that fill it, because `removeAll` and `setHoldPose` — both several
	hundred lines above where it used to sit — clear it on death and on respawn.
	A Lua local is only in scope BELOW its declaration, so those two were reading
	a nil global and throwing on every death. selene caught it; the audit's own
	checks could not, because they only know Shared module names and Roblox
	service names.
]]
local weaponTracks: { [Player]: { character: Model, tracks: { [string]: AnimationTrack } } } = {}

--[[ `id` is what is CURRENTLY playing, so a weapon swap can tell "already the
     right pose" from "needs a different one" without reloading a track to find
     out. ]]
local holding: { [Player]: { character: Model, track: AnimationTrack?, id: number? } } = {}

--[[ Anything that would make the prop behave like a scripted object rather than
     like a decal you can see from across a room. Mirrors PlaceholderFactory's
     own list: a supplied model routinely arrives with a ProximityPrompt still on
     it, and a prompt on somebody's back is an interact target the player can
     never reach and the prompt system has to keep evaluating. ]]
local STRIPPED = { "LuaSourceContainer", "BodyMover", "ProximityPrompt", "ClickDetector", "Sound" }

--[[ The part to hang things off. R15 keeps the chest in UpperTorso and R6 calls
     the whole thing Torso; falling back to the root means an unusual rig gets a
     kit in roughly the right place rather than no kit at all. ]]
local function carryAnchor(character: Model): BasePart?
	return character:FindFirstChild("UpperTorso") :: BasePart?
		or character:FindFirstChild("Torso") :: BasePart?
		or RigUtil.getRoot(character)
end

--[[ The limb a weapon is held in. R15 ends the arm in RightHand and R6 has the
     whole thing as "Right Arm"; a rig with neither cannot hold anything, and
     returning nil is how that stays a missing gun rather than a gun welded to
     somebody's head. ]]
local function handAnchor(character: Model): BasePart?
	return character:FindFirstChild("RightHand") :: BasePart?
		or character:FindFirstChild("Right Arm") :: BasePart?
end

--[[
	Where the hand actually is, in world space.

	Roblox rigs carry a RightGripAttachment on the limb for exactly this and it
	is the authored answer, so it wins. Without one the hand is assumed to be at
	the far end of the part, which is true of both rig types.
]]
local function handGrip(limb: BasePart): CFrame
	local attachment = limb:FindFirstChild("RightGripAttachment")
	if attachment and attachment:IsA("Attachment") then
		return limb.CFrame * attachment.CFrame * HAND_OFFSET
	end
	return limb.CFrame * CFrame.new(0, -limb.Size.Y * HAND_DROP, 0) * HAND_OFFSET
end

local function strip(model: Model)
	for _, descendant in model:GetDescendants() do
		for _, className in STRIPPED do
			if descendant:IsA(className) then
				descendant:Destroy()
				break
			end
		end
	end
end

--[[ The longest side of a model's bounding box. What decides whether a supplied
     prop needs scaling down to something a person could wear. ]]
local function longestSide(model: Model): number
	local _, size = model:GetBoundingBox()
	return math.max(size.X, size.Y, size.Z)
end

--[[ Uniform scale about the model's own pivot. Roblox's Model:ScaleTo only
     exists for models with a scale-aware rig, so this does it the explicit way:
     every part's size and its offset from the pivot move together. ]]
local function scaleModel(model: Model, factor: number)
	if math.abs(factor - 1) < 0.01 then
		return
	end
	local origin = model:GetPivot()
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") then
			local offset = origin:ToObjectSpace(part.CFrame)
			part.Size *= factor
			part.CFrame = origin * CFrame.new(offset.Position * factor) * (offset - offset.Position)
		end
	end
end

--[[ Welds every part to one root and returns it, so the whole prop moves as a
     single rigid body. Done before the prop touches the character: welding
     across a reparent is what leaves one screw floating in the air. ]]
local function consolidate(model: Model): BasePart?
	local root = model.PrimaryPart
	if not root then
		for _, part in model:GetDescendants() do
			if part:IsA("BasePart") then
				root = part
				break
			end
		end
	end
	if not root then
		return nil
	end
	model.PrimaryPart = root

	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") and part ~= root then
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = root
			weld.Part1 = part
			weld.Parent = root
		end
	end
	return root
end

local function mountName(mount: string): string
	return CARRY_NAME .. mount
end

local function removeMount(player: Player, mount: string)
	local entry = worn[player]
	local current = entry and entry[mount]
	if current then
		if current.model then
			current.model:Destroy()
		end
		entry[mount] = nil
	end

	--[[ Also sweep the character itself. A respawn hands us a NEW character
	     model, so the table can be empty while an old prop is still parented to
	     a rig somewhere — and two kits on one back reads as a bug even though it
	     is only a leak. ]]
	local character = player.Character
	if character then
		for _, child in character:GetChildren() do
			if child.Name == mountName(mount) then
				child:Destroy()
			end
		end
	end
end

local function removeAll(player: Player)
	for _, mount in MOUNT do
		removeMount(player, mount)
	end
	worn[player] = nil
	--[[ Not stopped, dropped. removeAll runs on death, and the rig it would be
	     writing to is on its way to being a ragdoll or a corpse. The weapon
	     tracks go the same way and for the same reason — they belong to that
	     rig's Animator, and every other teardown path already clears all
	     three. ]]
	holding[player] = nil
	weaponTracks[player] = nil
end

--[[ Makes a prop safe to wear: no collisions, no ray hits, no weight, and no
     scripts. Called on everything that goes onto a survivor whatever built it. ]]
local function tame(model: Model)
	strip(model)
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") then
			part.Anchored = false
			part.CanCollide = false
			part.CanQuery = false
			part.CanTouch = false
			part.Massless = true
		end
	end
end

--[[
	The medkit prop, from whichever spot in the map still has its template.

	Nil is a normal answer and not an error: a map with no kits placed, or a
	Health slot holding anything that is not a kit, has no model to show — and no
	prop beats a wrong one.
]]
local function buildKitModel(itemId: string): Model?
	--[[ The Health slot holds a defibrillator as well as a medkit, and the only
	     prop this file can reach is the map's kit. Showing one for the other was
	     the actual behaviour until now, despite a comment claiming otherwise —
	     a defib on somebody's back that reads as a medkit is worse than a bare
	     back, because a teammate counts on that read to decide whether to push. ]]
	if itemId ~= Enums.HealthItem.Medkit then
		return nil
	end

	local medkits = Registry.find("MedkitService")
	local template = medkits and medkits:getCarryTemplate()
	if not template then
		return nil
	end

	local model = template:Clone()
	tame(model)

	local size = longestSide(model)
	local factor = KIT.CarryScale
	if size * factor > KIT.CarryMaxSize then
		factor = KIT.CarryMaxSize / math.max(size, 0.01)
	end
	scaleModel(model, factor)
	return model
end

--[[ The world weapon model. PlaceholderFactory answers with the user's model or
     a grey-box and never with nothing for a real weapon id, so a nil here means
     the id was not a weapon — which is what happens the frame a slot is cleared. ]]
local function buildWeaponModel(itemId: string): Model?
	if not WeaponConfig.get(itemId) then
		return nil
	end
	local factory = Registry.find("PlaceholderFactory")
	if not factory then
		return nil
	end
	local model = factory:buildWeaponModel(itemId)
	if not model then
		return nil
	end
	tame(model)
	return model
end

--[[
	The flashlight, on the weapon, for everybody else to see.

	Its own attachment rather than the Muzzle, for one reason: a supplied model's
	Muzzle attachment is copied from whatever the artist authored and its
	ROTATION is not guaranteed to follow the barrel-down-minus-Z convention this
	codebase grips every weapon by. Borrowing its POSITION is safe and useful —
	the beam should start at the barrel, not inside the receiver — and taking the
	handle's orientation keeps the beam pointing the same way the gun does.

	`NormalId.Front` is -Z, which is that convention. A model that ignores it
	points its barrel somewhere odd too, so the light and the gun stay wrong
	together rather than in different directions.
]]
local function addBeam(model: Model)
	if not TORCH.Enabled then
		return
	end
	local handle = model.PrimaryPart
	if not handle then
		return
	end

	local muzzlePosition = Vector3.zero
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("Attachment") and descendant.Name == "Muzzle" then
			local host = descendant.Parent
			if host and host:IsA("BasePart") then
				muzzlePosition = handle.CFrame:ToObjectSpace(host.CFrame * descendant.CFrame).Position
			end
			break
		end
	end

	local beam = Instance.new("Attachment")
	beam.Name = "FL_Beam"
	beam.CFrame = CFrame.new(muzzlePosition)
	beam.Parent = handle

	local light = Instance.new("SpotLight")
	light.Name = "FL_Torch"
	light.Angle = TORCH.Angle
	light.Brightness = TORCH.Brightness
	light.Range = TORCH.Range
	light.Color = TORCH.Color
	light.Face = Enum.NormalId.Front
	--[[ Four shadow-casting spotlights in a horde is the most expensive thing
	     this game could ask a phone to draw, and against fog this thick the
	     shadows are invisible anyway. ]]
	light.Shadows = false
	light.Parent = beam
end

--[[
	Puts `model` on the character and welds it there.

	The pose is applied BEFORE parenting, so the prop never exists for a frame at
	the world origin with a physics step in between — which is visible as a flash
	of gun at the middle of the map every time somebody swaps weapons.
]]
local function place(character: Model, anchor: BasePart, model: Model, pose: CFrame, mount: string): boolean
	local root = consolidate(model)
	if not root then
		model:Destroy()
		return false
	end

	model.Name = mountName(mount)
	model:PivotTo(pose)

	--[[ Welded BEFORE parenting, so the prop is never a loose unanchored body in
	     the workspace for even one physics step. Posing it first and parenting it
	     last means the frame it appears is the frame it is already in place and
	     already attached. ]]
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = anchor
	weld.Part1 = root
	weld.Parent = root

	model.Parent = character
	return true
end

--[[
	Where something has to be moved to for the hand to be holding it.

	Expressed as the rigid transform from the hold point's CURRENT world CFrame
	to the one we want, applied to the model's pivot — rather than as "put the
	primary part here". The grip does not have to live on the primary part: a
	supplied model that shipped its own RightGripAttachment has it wherever the
	artist put it, and pivoting to the primary part would then hold that gun by
	the wrong end of itself.

	Two hold points, and the fallback is not a safety net — it is the only one a
	medkit has:

	  1. A "Grip" attachment. PlaceholderFactory stamps one on every weapon it
	     hands out, so this is the path every gun takes.
	  2. The centre of the model's own bounding box. A medkit comes off the map
	     as a prop, not out of the weapon pipeline, and has no attachments at all
	     — refusing to mount it (which is what this did at first) meant a
	     survivor who selected their kit was left holding nothing.
]]
local function holdPose(model: Model, target: CFrame): CFrame
	local grip: Attachment? = nil
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("Attachment") and descendant.Name == "Grip" then
			grip = descendant
			break
		end
	end

	local host = grip and grip.Parent
	local hold: CFrame
	if grip and host and host:IsA("BasePart") then
		hold = host.CFrame * grip.CFrame
	else
		--[[ The box CENTRE, not the pivot: a prop's pivot is wherever the artist
		     left it and is routinely outside the object, while the middle of the
		     thing is always somewhere a hand could plausibly be. ]]
		hold = model:GetBoundingBox()
	end

	return (target * hold:Inverse()) * model:GetPivot()
end

--[[ Builds and mounts one thing. `kind` is what HAND_SLOTS names, or "Medkit"
     for the back. Returns false when there is nothing sensible to show, which is
     not an error — see buildKitModel. ]]
local function attach(player: Player, mount: string, kind: string, itemId: string): Model?
	local character = player.Character
	if not character or not character.Parent then
		return nil
	end

	if mount == MOUNT.Hands then
		local limb = handAnchor(character)
		if not limb then
			return nil
		end
		local model = if kind == "Weapon" then buildWeaponModel(itemId) else buildKitModel(itemId)
		if not model then
			return nil
		end
		--[[ Weapons only. The torch is on the GUN, so a survivor who has pulled
		     their medkit out has no beam for the length of the heal — which is
		     the correct read rather than a gap: they are not covering anybody
		     while they are patching themselves up, and their own view light is
		     unaffected, so nobody is ever left in the dark by it. ]]
		if kind == "Weapon" then
			addBeam(model)
		end
		local pose = holdPose(model, handGrip(limb))
		return if place(character, limb, model, pose, mount) then model else nil
	end

	local anchor = carryAnchor(character)
	if not anchor then
		return nil
	end
	local model = buildKitModel(itemId)
	if not model then
		return nil
	end
	local pose = anchor.CFrame * KIT.CarryOffset
	return if place(character, anchor, model, pose, mount) then model else nil
end

--[[
	The Animator for a character, created if the rig arrived without one.

	Roblox normally puts one under a player's Humanoid when the character loads,
	but "normally" is not "always" — a rig assembled by something other than the
	default character pipeline may arrive bare, and the answer used to be to
	silently not pose the arm. That is indistinguishable from the animation
	failing to load, which is the bug this whole path was chased for.
]]
local function animatorFor(character: Model?): Animator?
	if not character or not character.Parent then
		return nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return nil
	end
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end
	return animator
end

--[[
	Which idle pose a survivor should be in, given what is in their hands.

	A gun class that declares an `idle` gets it — a two-handed low-ready authored
	for this game. Everything else falls back to SurvivorHold, Roblox's generic
	ToolNone, which is the right answer for a machete and would look wrong on a
	rifle.

	Returns nil for empty hands, which is how the caller knows to stop.
]]
local function holdIdleId(player: Player, character: Model?): number?
	if not character then
		return nil
	end

	local inventory = Registry.find("InventoryService")
	if inventory and typeof(inventory.getActiveWeapon) == "function" then
		local ok, weaponId = pcall(inventory.getActiveWeapon, inventory, player)
		if ok and typeof(weaponId) == "string" then
			local definition = WeaponConfig.get(weaponId)
			local set = definition and AnimationConfig.forWeaponClass(definition.class)
			if set and set.idle then
				return set.idle
			end
		end
	end

	return AnimationConfig.SurvivorHold[AnimationConfig.rigOf(character)]
end

--[[
	The arm pose for a survivor holding something.

	Loaded on the server so it replicates to every client, which is the whole
	point: the swing this fixes is the one OTHER players see.

	The pose is now per weapon class rather than one clip for everything, so
	swapping a rifle for a machete swaps the pose with it. That is what `id` on
	the entry is for: a pose that is already the right one is left alone, and a
	pose that is not is crossfaded rather than stacked — two looped clips on one
	arm at the same priority reads as neither of them.

	Everything here is best-effort. A rig with no Animator, an id that will not
	load, a clip authored for the other build: all of them end with no pose and a
	gun that swings, which is exactly where this started. None of them is worth
	failing a mount over.
]]
local function setHoldPose(player: Player, wanted: boolean)
	local character = player.Character
	local entry = holding[player]

	--[[ A new character invalidates the old track outright. Stopping it would be
	     writing to an Animator inside a rig that is being destroyed. ]]
	if entry and entry.character ~= character then
		entry = nil
		holding[player] = nil
		weaponTracks[player] = nil
	end

	--[[ Stopped, not dropped. The entry stays so that picking the same weapon back
	     up replays the track it already has: LoadAnimation returns a NEW track on
	     every call, and clearing here would allocate one per empty-handed moment
	     for the rest of the round. ]]
	if not wanted then
		if entry and entry.track then
			entry.track:Stop(0.15)
		end
		return
	end

	local id = holdIdleId(player, character)
	if not id then
		return
	end

	if entry and entry.track then
		if entry.id == id then
			if not entry.track.IsPlaying then
				entry.track:Play(0.15)
			end
			return
		end
		--[[ The weapon changed to something that poses differently. The old clip
		     goes first: crossfading two loops that both key the right arm leaves
		     the arm somewhere between them for as long as both are playing. ]]
		entry.track:Stop(0.1)
	end

	local animator = animatorFor(character)
	if not animator then
		return
	end

	--[[ From the cache, which keeps the Animation instance alive for the life of
	     the server. Building one here and destroying it after LoadAnimation — as
	     this did — leaves the track unable to resolve its own asset fetch, so it
	     plays only when the id happened to be cached already. See
	     Shared/Util/AnimationCache. ]]
	local track = AnimationCache.load(animator, id)
	if not track then
		return
	end
	if AnimationCache.hasFailed(id) then
		--[[ A track for an unfetchable id is an ordinary track that never plays.
		     Not worth a warning here — the cache already named the id once — but
		     it is worth not pretending the pose is on. ]]
		return
	end
	--[[ Stated rather than inherited. Roblox's ToolNone ships at Action priority
	     and that is what makes it win the shoulder against the walk cycle, but an
	     idle authored in Studio defaults to Idle priority and would silently do
	     nothing under it. ]]
	track.Priority = Enum.AnimationPriority.Action
	track.Looped = true
	track:Play(0.15)

	holding[player] = { character = character, track = track, id = id }
end

--[[
	The two clips that play OVER the hold pose: a shot and a reload.

	Same reasoning as the pose itself — loaded on the server so they replicate,
	because what these are for is the survivor twenty studs ahead of you visibly
	working a bolt. The player doing it is in first person and will never see
	their own; ViewmodelController's procedural kick is their half of it.

	── ONE ANIMATOR, TWO CACHES ────────────────────────────────────────────────
	Tracks are cached per character rather than per play. A rifle at 700rpm fires
	twelve times a second, and LoadAnimation on every one of those would be twelve
	AnimationTracks a second per shooter — the exact allocation pattern
	AnimationCache exists to stop, one level up.

	The cache is dropped when the character is, which is the only lifetime that
	matters: a track belongs to an Animator, and an Animator belongs to a rig.
	The table itself is declared up with the other per-player state — see there
	for why it cannot live down here.
]]

--[[
	Priorities, and all four of them are used.

	The hold pose loops at Action, so everything one-shot sits above it or would
	be blended against a clip that never stops. Above that the order is what
	should win when two land together:

	    equip   Action2   the draw
	    fire    Action3   a shot the frame after a draw shows the shot
	    reload  Action4   a shot the frame a reload ends does not cut the reload

	Roblox blends equal priorities BY WEIGHT, which for two clips both keying the
	right arm reads as neither of them playing — so "they are different clips" is
	not enough on its own, they have to be different priorities.
]]
local WEAPON_PRIORITY: { [string]: Enum.AnimationPriority } = {
	equip = Enum.AnimationPriority.Action2,
	fire = Enum.AnimationPriority.Action3,
	reload = Enum.AnimationPriority.Action4,
}

--[[ The track for one role on one player, built once and kept.

	Returns nil for everything that is legitimately absent — no character, no
	Animator, a class with no clips (melee), an id that will not fetch — because
	every one of those ends the same way: no animation, and a hold pose that still
	holds. None of them is worth a warning per shot. ]]
local function weaponTrack(player: Player, role: string): AnimationTrack?
	local character = player.Character
	if not character or not character.Parent then
		return nil
	end

	local entry = weaponTracks[player]
	if entry and entry.character ~= character then
		entry = nil
		weaponTracks[player] = nil
	end

	local inventory = Registry.find("InventoryService")
	if not inventory or typeof(inventory.getActiveWeapon) ~= "function" then
		return nil
	end
	local ok, weaponId = pcall(inventory.getActiveWeapon, inventory, player)
	if not ok or typeof(weaponId) ~= "string" then
		return nil
	end
	local definition = WeaponConfig.get(weaponId)
	local set = definition and AnimationConfig.forWeaponClass(definition.class)
	local id = set and set[role]
	if not id then
		return nil
	end

	--[[ Keyed by ROLE AND ID, so switching from a rifle to a shotgun mid-fight
	     gets the shotgun's clip rather than the rifle's cached one. The two share
	     a reload id today and this costs nothing; it is what stops the sharing
	     from becoming an assumption. ]]
	local key = role .. ":" .. tostring(id)
	if entry and entry.tracks[key] then
		return entry.tracks[key]
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return nil
	end
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end

	local track = AnimationCache.load(animator, id)
	if not track or AnimationCache.hasFailed(id) then
		return nil
	end
	track.Priority = WEAPON_PRIORITY[role] or Enum.AnimationPriority.Action2
	track.Looped = false

	if not entry then
		entry = { character = character, tracks = {} }
		weaponTracks[player] = entry
	end
	entry.tracks[key] = track
	return track
end

--[[ A shot. Restarted from zero rather than left to finish, because at any
     automatic rate of fire the previous one has not: a clip allowed to run its
     course would play once per burst instead of once per round. ]]
local function playShot(player: Player)
	local track = weaponTrack(player, "fire")
	if not track then
		return
	end
	track:Stop(0)
	track:Play(0.05)
end

--[[
	The draw, when the weapon in hand changes.

	Fired from applyMount rather than from a slot-change signal, because what this
	animates is the model APPEARING in the hand — and a slot change that failed to
	build a model should not produce an arm bringing nothing up. Same rule the
	hold pose follows.

	Not played on the first mount of a life, which is a survivor spawning already
	holding their loadout rather than drawing it. Doing so is a draw animation
	every player watches at the start of every round, which is a cost with no
	information in it.
]]
local function playEquip(player: Player)
	local track = weaponTrack(player, "equip")
	if not track then
		return
	end
	track:Stop(0)
	track:Play(0.08)
end

--[[ A reload, driven by the attribute InventoryService already publishes rather
     than by a second signal. It is set for the whole sequence — including the
     shotgun's shell-by-shell one, which is one attribute over several seconds —
     so the clip runs while it is true and is cut when it goes false, whether that
     was a finished reload or one the player interrupted by firing. ]]
local function setReloading(player: Player, reloading: boolean)
	local track = weaponTrack(player, "reload")
	if not track then
		return
	end
	if reloading then
		track:Stop(0)
		track:Play(0.1)
	else
		track:Stop(0.15)
	end
end

--[[ One mount, brought in line with what it should be showing. Split out of
     refresh so the two mounts cannot drift apart in the handling of a rebuild. ]]
local function applyMount(player: Player, entry: { [string]: Worn }, mount: string, key: string)
	local current = entry[mount]
	if current and current.key == key then
		return
	end
	removeMount(player, mount)
	if key == "" then
		return
	end
	local kind, itemId = string.match(key, "^(%w+):(.+)$")
	if not kind then
		return
	end
	local model = attach(player, mount, kind, itemId)
	if model then
		entry[mount] = { model = model, key = key }
	end
end

--[[
	What each mount should be showing, as a key.

	One string per mount, built from the kind and the item, because that is
	exactly what has to change for a rebuild to be worth doing — and `refresh` is
	called on every slot change of every kind. An empty string means bare.
]]
local function wantedKeys(player: Player): (string, string)
	local inventory = Registry.find("InventoryService")
	if not inventory then
		return "", ""
	end
	local loadout = inventory:getLoadout(player)
	if not loadout then
		return "", ""
	end

	local health = loadout[Enums.Slot.Health]
	local healthId = health and health.itemId or ""

	local active = player:GetAttribute(LA.ActiveSlot)
	local activeSlot = if typeof(active) == "string" then active else Enums.Slot.Secondary
	local kind = HAND_SLOTS[activeSlot]
	local entry = loadout[activeSlot]
	local handsId = entry and entry.itemId or ""

	local hands = if kind and handsId ~= "" then kind .. ":" .. handsId else ""
	--[[ The kit is on the back UNLESS it is in the hands. Two mounts showing the
	     same object at once is the one arrangement that reads as broken. ]]
	local back = if healthId ~= "" and kind ~= "Medkit" then "Medkit:" .. healthId else ""
	return back, hands
end

--[[ Brings both mounts in line with the loadout. Cheap to call repeatedly:
     showing the same thing twice does nothing, which matters because `changed`
     fires for every slot and most of them move neither mount. ]]
function CarryVisualService:refresh(player: Player)
	local backKey, handsKey = wantedKeys(player)
	local entry = worn[player]
	if not entry then
		entry = {}
		worn[player] = entry
	end

	local heldBefore = entry[MOUNT.Hands]

	applyMount(player, entry, MOUNT.Back, backKey)
	applyMount(player, entry, MOUNT.Hands, handsKey)

	--[[ Keyed off what was actually MOUNTED rather than off what was wanted: a
	     weapon whose model failed to build leaves the hands empty, and posing an
	     empty arm as though it were holding a rifle is worse than not posing it. ]]
	local heldAfter = entry[MOUNT.Hands]
	setHoldPose(player, heldAfter ~= nil)

	--[[ A draw, but only for a SWAP — something was in the hands and now something
	     else is. Not for the first mount of a life: that is a survivor spawning
	     already holding their loadout, and animating it is a draw every player
	     watches at the start of every round for no information.

	     The pose is set first so the draw layers over the right idle rather than
	     over the one being replaced. ]]
	if heldBefore and heldAfter and heldBefore.key ~= heldAfter.key then
		playEquip(player)
	end
end

function CarryVisualService:init() end

function CarryVisualService:start()
	local inventory = Registry.find("InventoryService")
	if inventory and inventory.changed then
		--[[ Every slot, not just Health: the hands mount follows whichever slot is
		     selected, and a swap fires `changed` for the slot that gained focus.
		     refresh does the filtering, by key. ]]
		serviceTrove:add(inventory.changed:connect(function(player: Player)
			self:refresh(player)
		end))
	else
		warn("[CarryVisualService] no InventoryService; nothing will appear on anybody")
	end

	--[[
		The shot animation, off the server's own fire signal rather than off the
		WeaponFired remote beside it.

		The remote is addressed to everyone EXCEPT the shooter, which is right for
		a muzzle flash and wrong for this: the animation has to run on the shooter's
		character, and it is the server that owns that character. Listening to a
		remote the server sends would also mean this fired for the one client that
		does not need it and not for the eleven that do.
	]]
	local ballistics = Registry.find("BallisticsService")
	if ballistics and ballistics.fired then
		serviceTrove:add(ballistics.fired:connect(function(shooter: Player)
			playShot(shooter)
		end))
	else
		warn("[CarryVisualService] no BallisticsService.fired; nobody will animate a shot")
	end

	--[[
		A respawn replaces the character, and the new one arrives bare even though
		the slots never changed. CharacterAdded rather than a SurvivorService
		signal on purpose: the thing that invalidates a prop is the character model
		being swapped, which is exactly what this event means and nothing else does.

		The table entry is cleared first because the props it names belong to a rig
		that is on its way to being destroyed — leaving it would make refresh
		believe the right things are already on the right survivor.
	]]
	local function watch(player: Player)
		serviceTrove:connect(player.CharacterAdded, function()
			worn[player] = nil
			--[[ The loadout is restored a moment after the character exists, so
			     reading it on this frame gets the slots as they were mid-respawn.
			     One deferred pass, not a poll. ]]
			task.defer(function()
				if player.Parent then
					self:refresh(player)
				end
			end)
		end)

		--[[ The selected slot is an attribute rather than a signal — it moves far
		     too often for a remote — so the hands mount follows it directly. This
		     is the event that fires when somebody presses 1 or 2. ]]
		--[[ The reload clip follows the attribute InventoryService already
		     publishes. No new signal for it: the attribute is set for exactly the
		     span the reload occupies, including an interrupted one, which is
		     precisely the window the animation should cover. ]]
		serviceTrove:connect(player:GetAttributeChangedSignal(LA.IsReloading), function()
			setReloading(player, Attributes.get(player, LA.IsReloading, false) == true)
		end)

		serviceTrove:connect(player:GetAttributeChangedSignal(LA.ActiveSlot), function()
			self:refresh(player)
		end)
	end

	for _, player in Players:GetPlayers() do
		watch(player)
	end
	serviceTrove:connect(Players.PlayerAdded, watch)
	serviceTrove:connect(Players.PlayerRemoving, function(player: Player)
		worn[player] = nil
		holding[player] = nil
		weaponTracks[player] = nil
	end)

	local survivors = Registry.find("SurvivorService")
	if survivors and survivors.died then
		serviceTrove:add(survivors.died:connect(function(player: Player)
			removeAll(player)
		end))
	end
end

function CarryVisualService:destroy()
	for player in worn do
		removeAll(player)
	end
	serviceTrove:destroy()
end

Registry.register("CarryVisualService", CarryVisualService)

return CarryVisualService
