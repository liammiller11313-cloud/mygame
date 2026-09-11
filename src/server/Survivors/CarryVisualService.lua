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

	── THE ARM IS POSED ─────────────────────────────────────────────────────────
	This file used to carry a KNOWN GAP saying it was not. It is now: a looped
	idle at Action priority holds the shoulder against the walk cycle, per weapon
	class, with a shot and a reload layering over it. See setHoldPose and
	weaponTrack below, and AnimationConfig.Weapon for what plays.

	The gun is still welded a little forward of the hand so that at rest it reads
	as low-ready rather than as pointing at the floor.
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

--[[
	The slots whose contents are shown in the hands, and how.

	This table is the ONLY thing that decides whether a slot is visible, and it
	has now been the cause of the same bug twice. Melee was missed when it got a
	slot of its own. The throwables were missed too, and worse: buildKitModel
	below carries a whole branch for putting a molotov in somebody's fist, with a
	comment explaining why it matters — and nothing could ever reach it, because
	an unlisted slot resolves to "" and reads as empty hands.

	Both are listed now, along with the pills. "a bottle in a fist is not a read
	anybody needs at twenty studs" is what this used to say about those, and it
	was wrong in the way that only shows up in play: somebody standing still
	holding pills is about to be a second slower to react than you expect, and
	that is exactly the kind of thing the whole file exists to make visible.
]]
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
	     it costs nothing here: it is the same model, mounted somewhere else.

	     Its own kind rather than sharing "Held" below, and that is load-bearing:
	     wantedKeys decides whether the BACK is occupied by asking whether the
	     hands are showing a "Medkit". Give the pills that kind and selecting them
	     takes the kit off your back. ]]
	[Enums.Slot.Health] = "Medkit",
	--[[ Everything else you hold rather than wield. Same mount, same weld, same
	     sizing ceiling; they differ from a weapon only in having no torch and no
	     muzzle to hang one off. ]]
	[Enums.Slot.Pills] = "Held",
	[Enums.Slot.Throwable] = "Held",
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
--[[ The shot each player's pending pump belongs to. See playShot. ]]
local pumpTokens: { [Player]: number } = {}

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

--[[ How long after a hold pose starts before its Length is believed. An
     AnimationTrack does not report one the instant it is created, and a clip
     whose asset is still arriving reads zero exactly like an empty upload — so
     the measurement waits long enough that a fetch which is going to resolve
     has, and AnimationCache refuses to call it empty until the fetch is known to
     have succeeded anyway. See setHoldPose. ]]
local HOLD_MEASURE_DELAY = 2

--[[ One line per distinct problem, per server. These name an ASSET rather than
     a player, so a broken clip must not print once per survivor per pickup for
     the rest of the round. ]]
local warned: { [string]: boolean } = {}
local function warnOnce(key: string, message: string)
	if warned[key] then
		return
	end
	warned[key] = true
	warn("[CarryVisualService] " .. message)
end

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

--[[ The other hand, for a pair. Nil is not fatal here the way it is for the
     right: a rig with no left hand holds the pair one-handed rather than not at
     all, which is a worse-looking gun and still a gun. ]]
local function offHandAnchor(character: Model): BasePart?
	return character:FindFirstChild("LeftHand") :: BasePart?
		or character:FindFirstChild("Left Arm") :: BasePart?
end

--[[
	Where the hand actually is, in world space.

	Roblox rigs carry a RightGripAttachment on the limb for exactly this and it
	is the authored answer, so it wins. Without one the hand is assumed to be at
	the far end of the part, which is true of both rig types.
]]
local function handGrip(limb: BasePart): CFrame
	--[[ Either hand's authored grip point. A left limb carries
	     LeftGripAttachment and a right one RightGripAttachment; asking for the
	     right on a left hand finds nothing and silently falls through to the
	     geometric guess, which is a pistol held slightly wrong in one hand only
	     — the kind of asymmetry that reads as the model being broken. ]]
	local attachment = limb:FindFirstChild("LeftGripAttachment") or limb:FindFirstChild("RightGripAttachment")
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
			--[[ Belt and braces, and one line. Every caller does reach here with
			     an unanchored model today -- AmmoFactory builds its own parts and
			     CarryVisualService tames before it places -- but that is a
			     contract held three functions away and written down nowhere. An
			     anchored part silently ignores the weld below, so the invariant
			     belongs where the weld is made. audit.py check 39 agrees. ]]
			part.Anchored = false
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
	--[[ Cancels a pump this player's last shot had scheduled. The closure checks
	     this token before it plays, so clearing it is the cancel — and a pump on
	     a body that is already a ragdoll is exactly what it should stop. ]]
	pumpTokens[player] = nil
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

--[[ Refuses to put something enormous in a hand, and does nothing otherwise. A
     supplied prop is already the size its author meant it to be — this is only
     the ceiling, so a model built at map scale by mistake does not become a
     wardrobe on somebody's arm. ]]
local function fitToHand(model: Model)
	local longest = longestSide(model)
	if longest > KIT.CarryMaxSize then
		scaleModel(model, KIT.CarryMaxSize / math.max(longest, 0.01))
	end
end

--[[
	The prop for anything a survivor carries that is not a weapon: the map's
	medkit and pills, and the user's own throwable models.

	Nil is a normal answer and not an error. A map with no pills placed, a Health
	slot holding a defibrillator — which has no prop this file can reach — or a
	throwable nobody has supplied a model for, all have nothing to show, and no
	prop beats a wrong one.
]]
local function buildKitModel(itemId: string): Model?
	--[[ The Health slot holds a defibrillator as well as a medkit, and the only
	     prop this file can reach is the map's kit. Showing one for the other was
	     the actual behaviour until now, despite a comment claiming otherwise —
	     a defib on somebody's back that reads as a medkit is worse than a bare
	     back, because a teammate counts on that read to decide whether to push. ]]
	--[[
		A throwable in the hand, from the model the user supplied for it.

		Until now this returned nil for every throwable, so a survivor holding a
		molotov held nothing at all — and a teammate deciding whether to push a
		corridor could not tell a lit bottle from an empty hand. The floor pickup
		and the object in flight both had a model; the six seconds it spends in
		somebody's fist did not.

		Nil when nothing is supplied, which is unchanged behaviour for anyone who
		has not put a model in Assets.Throwables and is deliberately not warned
		about — see PlaceholderFactory.buildThrowableModel.
	]]
	if Enums.Throwable[itemId] then
		local factory = Registry.find("PlaceholderFactory")
		local thrown = factory
			and typeof(factory.buildThrowableModel) == "function"
			and factory:buildThrowableModel(itemId)
		if not thrown then
			return nil
		end
		tame(thrown)
		fitToHand(thrown)
		return thrown
	end

	--[[ Every item the MAP supplies, which is the medkit and both pills — see
	     MapConfig.MapItems. Asked of the config rather than named here, so a
	     fourth family is visible in a hand the day it is declared. ]]
	if not MapConfig.mapItemFor(itemId) then
		return nil
	end

	local mapItems: any = Registry.find("MapItemService")
	local template = mapItems and typeof(mapItems.getTemplate) == "function" and mapItems:getTemplate(itemId)
	if not template then
		return nil
	end

	local model = template:Clone()
	tame(model)

	--[[ The MEDKIT is the exception, and it is the only one. It is the one prop
	     here that spends most of its life on a BACK, built to be read across a
	     room from the floor, so it is shrunk by CarryScale before the ceiling is
	     even considered. A pill bottle or a molotov is already the size its
	     author meant a hand to hold, and shrinking it by another third makes it
	     something you cannot see at all. ]]
	if itemId == Enums.HealthItem.Medkit then
		local size = longestSide(model)
		local factor = KIT.CarryScale
		if size * factor > KIT.CarryMaxSize then
			factor = KIT.CarryMaxSize / math.max(size, 0.01)
		end
		scaleModel(model, factor)
	else
		fitToHand(model)
	end
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

--[[ What PlaceholderFactory names the two halves of a pair, and the attribute
     it marks the pair with. Read rather than re-derived: which gun is the left
     one is a geometry question that was already answered once, at boot, against
     the template — asking it again per equip could get a different answer for
     the same model. ]]
local DUAL_ATTRIBUTE = "FL_DualWield"
local DUAL_LEFT = "FL_Left"
local DUAL_RIGHT = "FL_Right"

--[[
	Mounts a pair: one gun in each hand.

	Not `place`, and the difference is the whole feature. `place` consolidates
	the model into ONE rigid body and welds it to ONE limb, which for a pair
	welds both pistols to the right hand and leaves the left one hanging in the
	air beside it. Each half is already its own assembly with its own Handle and
	its own Grip — see PlaceholderFactory.adoptDualWeapon — so each is posed and
	welded independently and the model itself is only a container.

	Falls back to the ordinary one-handed mount when anything is missing: a rig
	with no left hand, or a model that reached here without both halves. A pair
	held wrong is a bug worth seeing; a pair that does not appear is a player
	with no gun.
]]
local function placeDual(character: Model, right: BasePart, model: Model, mount: string): boolean
	local leftLimb = offHandAnchor(character)
	local leftHalf = model:FindFirstChild(DUAL_LEFT)
	local rightHalf = model:FindFirstChild(DUAL_RIGHT)
	if
		not leftLimb
		or not (leftHalf and leftHalf:IsA("Model") and leftHalf.PrimaryPart)
		or not (rightHalf and rightHalf:IsA("Model") and rightHalf.PrimaryPart)
	then
		return false
	end

	model.Name = mountName(mount)

	for limb, half in { [right] = rightHalf :: Model, [leftLimb] = leftHalf :: Model } do
		--[[ Each half against its OWN grip and its own hand. holdPose returns
		     where this model's pivot has to go for its Grip to land on the
		     target, so running it per half is what puts two guns in two places
		     rather than one gun twice. ]]
		half:PivotTo(holdPose(half, handGrip(limb)))
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = limb
		weld.Part1 = half.PrimaryPart
		weld.Parent = half.PrimaryPart
	end

	--[[ Parented last, like `place`, so neither half is ever a loose unanchored
	     body in the workspace for a physics step. ]]
	model.Parent = character
	return true
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
		--[[ A pair goes to two hands. Tried first and falling through on any
		     reason it cannot — no left hand on the rig, a model that reached
		     here without both halves — because a pair mounted one-handed is a
		     gun that looks wrong, and no mount at all is a player holding
		     nothing. ]]
		if model:GetAttribute(DUAL_ATTRIBUTE) == true and placeDual(character, limb, model, mount) then
			return model
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
			--[[
				A hold Roblox has REFUSED is worse than no hold at all: the caller
				stops on a failed id, so the arm keeps swinging as if nothing were
				in it. Roblox's own ToolNone below always loads, so a refused class
				pose falls back to the generic one rather than to nothing.

				── AND AN EMPTY ONE IS THE SAME FAILURE ─────────────────────────
				A clip published before any keyframes were saved fetches perfectly
				well and is zero seconds long. It loads, sits at Action priority
				over the walk cycle, and poses nothing — so it beats the generic
				ToolNone below by being present, and the arm swings anyway. That is
				not hypothetical here: the Shotgun idle is exactly this, so the one
				weapon that most needs a two-handed low-ready is the only one in the
				armoury with no hold pose at all.

				Gated on isLoaded, not on length alone. Length is also zero for a
				clip whose asset has not landed yet, and dropping one of those would
				take the hold away from every survivor in the first seconds of a
				round — so it only counts as empty once the fetch is known to have
				succeeded.
			]]
			local usable = set
				and set.idle
				and not AnimationCache.hasFailed(set.idle)
				and not AnimationCache.isEmpty(set.idle)
			if usable then
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

	--[[
		MEASURE IT ONCE, and if it turns out to be an empty upload, fall back.

		A clip published before any keyframes were saved fetches successfully and
		is zero seconds long. It loads, wins the shoulder at Action priority, and
		poses nothing — so it beats Roblox's generic ToolNone below by being
		present, and the arm swings as if the hands were empty. The Shotgun idle in
		this place is exactly that, which is why the one weapon most in need of a
		two-handed low-ready is the only one without a hold pose.

		Deferred, because Length is not populated the instant a track is created —
		and read through AnimationCache, which only believes a zero once the fetch
		has actually succeeded. So a clip that is merely still arriving is left
		alone; one that arrived empty is recorded server-wide, and holdIdleId then
		routes every survivor to SurvivorHold instead. That recursion terminates:
		the second pass cannot choose the same id.
	]]
	task.delay(HOLD_MEASURE_DELAY, function()
		local current = holding[player]
		if not current or current.track ~= track or not track.Parent then
			return
		end
		if AnimationCache.isEmpty(id) then
			return
		end
		AnimationCache.noteLength(id, track.Length)
		if not AnimationCache.isEmpty(id) then
			return
		end
		warnOnce(
			"emptyhold:" .. tostring(id),
			string.format(
				"animation %d is a hold pose with no keyframes in it — it fetched, but it is zero "
					.. "seconds long, so it posed nothing while outranking the generic hold. Falling "
					.. "back to SurvivorHold. Open it in the Animation Editor, check the timeline "
					.. "actually has poses on it, and publish again.",
				id
			)
		)
		track:Stop(0)
		holding[player] = nil
		setHoldPose(player, true)
	end)
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
--[[ Used only by a gun that declares a pump but no rpm, which is a config
     mistake rather than a state — a beat, so the clip still reads as following
     the shot rather than sharing it. ]]
local PUMP_FALLBACK_DELAY = 0.2

local WEAPON_PRIORITY: { [string]: Enum.AnimationPriority } = {
	equip = Enum.AnimationPriority.Action2,
	fire = Enum.AnimationPriority.Action3,
	--[[ The same tier as the shot, because that is what it is: the second half of
	     one event. They never overlap — the pump is scheduled for a point PAST the
	     shot — and giving it its own tier would only let it outrank a reload the
	     player started in between, which is a player who has decided they would
	     rather reload than admire the action. ]]
	pump = Enum.AnimationPriority.Action3,
	reload = Enum.AnimationPriority.Action4,
}

--[[ The track for one role on one player, built once and kept.

	Returns nil for everything that is legitimately absent — no character, no
	Animator, a class with no clips (melee), an id that will not fetch — because
	every one of those ends the same way: no animation, and a hold pose that still
	holds. None of them is worth a warning per shot. ]]
--[[ The definition of what this player is actually holding, or nil. Two callers
     need it now — which clip to play, and how long to wait before the pump — and
     asking InventoryService twice for one shot is one lookup too many. ]]
local function activeDefinition(player: Player): any
	local inventory = Registry.find("InventoryService")
	if not inventory or typeof(inventory.getActiveWeapon) ~= "function" then
		return nil
	end
	local ok, weaponId = pcall(inventory.getActiveWeapon, inventory, player)
	if not ok or typeof(weaponId) ~= "string" then
		return nil
	end
	return WeaponConfig.get(weaponId)
end

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

	local definition = activeDefinition(player)
	local set = definition and AnimationConfig.forWeaponClass(definition.class)
	local id = set and set[role]
	if not id then
		return nil
	end

	--[[ A clip Roblox has REFUSED — an id uploaded under a personal account in a
	     group-owned place — borrows the spare rather than playing nothing, so a
	     shotgun still moves when it fires. Only ever engages for an id preloading
	     has actually reported as failed, so the day those ids are re-uploaded this
	     goes quiet on its own. See AnimationConfig.WeaponFallback. ]]
	if AnimationCache.hasFailed(id) then
		local spare = AnimationConfig.WeaponFallback[role]
		if spare and spare ~= id and not AnimationCache.hasFailed(spare) then
			id = spare
		end
	end

	--[[ Keyed by ROLE AND ID, so switching from a rifle to a shotgun mid-fight
	     gets the shotgun's clip rather than the rifle's cached one. The two share
	     a reload id today and this costs nothing; it is what stops the sharing
	     from becoming an assumption.

	     It is the RESOLVED id, which matters: preloading answers asynchronously,
	     so the first track built for a broken id can be built before anything
	     knows it is broken. Once the failure lands the key changes and the next
	     ask builds the spare instead of returning the dead one forever. ]]
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

--[[
	A shot, and — for a gun with an action to work — the pump that follows it.

	The shot itself is restarted from zero rather than left to finish, because at
	any automatic rate of fire the previous one has not: a clip allowed to run its
	course would play once per burst instead of once per round.

	The pump is a SEPARATE clip at a LATER moment, which is the whole reason it is
	not part of `fire`. It lands at WeaponConfig.PumpPoint through the shot's
	cycle — the same instant the shooter's own viewmodel kicks and the pump sound
	plays, so what a teammate sees twenty studs away is in time with what the
	shooter feels.

	`pumpToken` is what makes a second shot cancel the first shot's pump. Without
	it, a player who fires again before the beat gets both pumps queued, and the
	hands work the action twice for one shell — worse than not animating it.
]]
local function playShot(player: Player)
	local track = weaponTrack(player, "fire")
	if track then
		track:Stop(0)
		track:Play(0.05)
	end

	local pump = weaponTrack(player, "pump")
	if not pump then
		pumpTokens[player] = nil
		return
	end

	local token = (pumpTokens[player] or 0) + 1
	pumpTokens[player] = token
	pump:Stop(0)

	local definition = activeDefinition(player)
	local rpm = if definition and typeof(definition.rpm) == "number" then definition.rpm else 0
	local delay = if rpm > 0 then (60 / rpm) * WeaponConfig.PumpPoint else PUMP_FALLBACK_DELAY

	task.delay(delay, function()
		if pumpTokens[player] ~= token then
			return -- fired again, or switched to something with no action to work
		end
		--[[ Re-resolved rather than captured. Between the shot and the beat the
		     player can respawn or swap weapons, and the track from the character
		     they had is attached to an Animator that no longer exists. Asking
		     again returns nil in exactly those cases. ]]
		local fresh = weaponTrack(player, "pump")
		if fresh then
			fresh:Play(0.05)
		end
	end)
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
		pumpTokens[player] = nil
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
