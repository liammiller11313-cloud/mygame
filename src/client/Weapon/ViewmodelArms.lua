--!nonstrict
--[[
	ViewmodelArms — the player's own arms, cloned onto a first-person weapon.

	Split out of ViewmodelController, which was at 167 top-level locals against
	Luau's hard limit of 200 per scope. This is the part of it that earns its own
	file rather than the part that was easiest to cut: every function here takes
	what it needs as an argument and returns instances. It reads no module state,
	writes none, and the only thing outside it that it touches is the local
	character it is handed — which is why it could move without anything having
	to be threaded through it. It does not even reach for the local player: every
	one of these takes the character to clone from as an argument.

	What stayed behind is everything that depends on the live viewmodel: which
	weapon is up, where the muzzle is, how the pair is arranged, the per-frame
	solve. Those are one object's state and splitting them would have meant
	passing that object around, which is a bigger file in two pieces rather than
	two smaller files.
]]

local ViewmodelArms = {}

-- ── arms ────────────────────────────────────────────────────────────────────

--[[
	First-person arms, cloned from the player's own avatar.

	These are the ACTUAL arm parts off the local character, not stand-ins: the
	same mesh, the same skin tone, the same shirt texture, the same accessories
	if any are welded to them. That is the whole point — a player should see their
	own hands, and a generic pair of blocks in front of a customised avatar reads
	as somebody else's arms.

	They are built as CHILDREN OF THE WEAPON MODEL rather than posed separately.
	That is what makes them cheap: the weapon is already moved once per frame with
	one PivotTo, and anything parented into it inherits every bit of the sway,
	bob, recoil kick and aim transition without a second line of maths. It also
	makes them correct by construction — hands welded to a gun cannot drift off
	it, which is exactly the failure mode of arms driven by their own IK.

	R6 and R15 both work and are handled separately, because they are genuinely
	different problems: R6 has one part per arm, so the whole limb is a single
	rigid piece placed at the grip. R15 has three (upper, lower, hand) and they
	are chained so the arm bends at the elbow.

	The shoulder end runs off the bottom of the frame on purpose. Nobody sees an
	elbow in a first-person shooter, and solving for one costs geometry for
	something the player will never look at.
]]

-- Where the hands sit on the weapon, as fractions of its own bounding box, so
-- the same numbers land correctly on a pistol and on a battle rifle.
local GRIP_BACK = 0.16 -- toward the shooter, along the weapon's length
local GRIP_DROP = 0.34 -- below the bore line: a grip hangs under the receiver
local SUPPORT_FORWARD = 0.28 -- the off hand, forward along the handguard
local SUPPORT_DROP = 0.22

-- Which way each arm runs back toward the camera. The right arm comes in tighter
-- than the left because the shooting hand sits behind the gun while the support
-- hand reaches across for it.
--[[
	Where the two guns of a pair sit, relative to where one gun would.

	SPREAD is sideways, so the two are far enough apart to read as two rather
	than as one gun with a doubling artefact. FORWARD pushes them out past where
	a single pistol sits, because two hands at the same depth crowd the middle of
	the frame and hide what the player is shooting at. CANT is the outward yaw —
	a few degrees each, which is the difference between "two pistols" and "one
	pistol mirrored", and it is what makes the pair look held rather than
	floating.

	Multiplied by the model's own size where that makes sense, so a pair of
	compacts and a pair of hand cannons both end up in frame.
]]

local RIGHT_RUN = Vector3.new(0.42, -0.34, 1.0)
local LEFT_RUN = Vector3.new(-0.58, -0.30, 1.0)

-- Fallback geometry, used only when the character has no arm to clone — which
-- happens for exactly as long as it takes an avatar to load.
local FALLBACK_HAND = Vector3.new(0.30, 0.30, 0.34)
local FALLBACK_THICKNESS = 0.27
local FALLBACK_LENGTH = 1.45
local FALLBACK_SKIN = Color3.fromRGB(198, 158, 122)
local FALLBACK_SLEEVE = Color3.fromRGB(64, 62, 58)

--[[ R15 arm chain, shoulder outward. Cloning the whole chain is what lets the
     arm bend rather than being one rigid stick. ]]
local R15_RIGHT = { "RightUpperArm", "RightLowerArm", "RightHand" }
local R15_LEFT = { "LeftUpperArm", "LeftLowerArm", "LeftHand" }

--[[ Strips a cloned avatar part down to something safe to weld onto a viewmodel:
     no physics, no queries, no scripts that came in on an accessory. ]]
--[[
	Strips a cloned avatar part down to something safe to weld onto a viewmodel.

	THE JOINTS MUST GO FIRST, AND ALL OF THEM.

	Roblox's clone semantics keep references that point OUTSIDE the cloned
	subtree. A limb cloned off a live character therefore arrives still carrying
	joints whose Part0 is the real body — so anchoring the clone anchors the
	whole assembly it is still attached to, and the player's actual avatar floats
	in the air rotating to follow the camera.

	Stripping Motor6D and Weld was not enough: accessories and layered clothing
	attach with WeldConstraint, and the older rigs use Snap and ManualWeld. So
	this removes every JointInstance, every WeldConstraint and every Constraint,
	and only then changes any property.
]]
local function prepareArmPart(part: BasePart)
	for _, descendant in part:GetDescendants() do
		if
			descendant:IsA("JointInstance")
			or descendant:IsA("WeldConstraint")
			or descendant:IsA("Constraint")
			or descendant:IsA("LuaSourceContainer")
			or descendant:IsA("BodyMover")
		then
			descendant:Destroy()
		end
	end

	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Massless = true
end

--[[ Clones one avatar part by name, or nil when the character has not loaded it
     yet. Everything about the original is kept: mesh, texture, colour, size. ]]
local function cloneAvatarPart(character: Model?, name: string): BasePart?
	if not character then
		return nil
	end
	local source = character:FindFirstChild(name)
	if not source or not source:IsA("BasePart") then
		return nil
	end
	local clone = source:Clone()
	prepareArmPart(clone)
	return clone
end

--[[
	Places one arm.

	`handAt` is where the hand goes, in the weapon's own frame. `run` is the
	direction the rest of the arm travels away from it. The chain is laid out by
	walking outward from the hand, each segment placed end to end, so an R15 arm
	comes out bent at roughly the angle a real one would be.
]]
local function buildAvatarArm(
	built: Model,
	character: Model?,
	origin: CFrame,
	handAt: Vector3,
	run: Vector3,
	chain: { string },
	r6Name: string
)
	local direction = origin:VectorToWorldSpace(run.Unit)
	local handWorld = origin * CFrame.new(handAt)

	-- R15 first: three parts, hand at the weapon, upper arm furthest away.
	local parts: { BasePart } = {}
	for index = #chain, 1, -1 do
		local part = cloneAvatarPart(character, chain[index])
		if part then
			table.insert(parts, part)
		end
	end

	if #parts > 0 then
		local cursor = 0
		-- parts[1] is the hand; each subsequent segment is pushed further back
		-- along `direction` by its own length.
		for _, part in parts do
			local length = math.max(part.Size.Y, part.Size.Z, 0.2)
			local centre = handWorld.Position + direction * (cursor + length * 0.5)
			-- Limb meshes are authored along their own Y axis, so the arm is
			-- aimed by pointing that axis down the run direction.
			part.CFrame = CFrame.lookAt(centre, centre + direction) * CFrame.Angles(math.pi / 2, 0, 0)
			part.Parent = built
			cursor += length * 0.92 -- slight overlap, so there is no seam at a joint
		end
		return
	end

	-- R6: one part for the entire arm, placed so its lower end is at the grip.
	local single = cloneAvatarPart(character, r6Name)
	if single then
		local length = math.max(single.Size.Y, 0.4)
		local centre = handWorld.Position + direction * (length * 0.42)
		single.CFrame = CFrame.lookAt(centre, centre + direction) * CFrame.Angles(math.pi / 2, 0, 0)
		single.Parent = built
		return
	end

	--[[ Nothing to clone. This is the window between spawning and the avatar
	     replicating, and it is short — but a weapon floating with no hands at all
	     during it looks far worse than a plain pair, so one is built. ]]
	local hand = Instance.new("Part")
	hand.Name = "FL_Hand"
	hand.Size = FALLBACK_HAND
	hand.Color = FALLBACK_SKIN
	hand.Material = Enum.Material.SmoothPlastic
	prepareArmPart(hand)
	hand.CFrame = handWorld
	hand.Parent = built

	local mid = handWorld.Position + direction * (FALLBACK_LENGTH * 0.5 - 0.1)
	local forearm = Instance.new("Part")
	forearm.Name = "FL_Forearm"
	forearm.Size = Vector3.new(FALLBACK_THICKNESS, FALLBACK_THICKNESS, FALLBACK_LENGTH)
	forearm.Color = FALLBACK_SLEEVE
	forearm.Material = Enum.Material.Fabric
	prepareArmPart(forearm)
	forearm.CFrame = CFrame.lookAt(mid, mid + direction)
	forearm.Parent = built
end

--[[
	Safety net for the one failure this system can produce that ruins a round.

	Cloning a limb off a LIVE character and anchoring the copy is only safe while
	every joint the copy carries has been removed — Roblox preserves references
	that point outside a cloned subtree, so a surviving joint anchors the real
	body through it, and the player floats in the air rotating to follow the
	camera. prepareArmPart strips every joint type there is, and this checks that
	it worked rather than trusting it.

	Cheap: a handful of parts, once per weapon swap. And it repairs rather than
	just complaining, because a player who cannot walk does not care whose fault
	it was.
]]
local function releaseCharacter(character: Model?)
	if not character then
		return
	end
	for _, part in character:GetDescendants() do
		if part:IsA("BasePart") and part.Anchored then
			part.Anchored = false
			warn(
				string.format(
					"[ViewmodelController] %s was left anchored by an arm clone and has been released. "
						.. "A joint type is getting past prepareArmPart.",
					part:GetFullName()
				)
			)
		end
	end
end

--[[ The offsets the two hands are placed at, in fractions of the weapon's own
     size. Exported because buildArms in ViewmodelController decides WHICH arms a
     weapon gets — a pistol has no support hand, a pair has two grips rather than
     a grip and a forestock — and that decision belongs with the weapon, not with
     the limb-cloning. ]]
ViewmodelArms.GripBack = GRIP_BACK
ViewmodelArms.GripDrop = GRIP_DROP
ViewmodelArms.SupportForward = SUPPORT_FORWARD
ViewmodelArms.SupportDrop = SUPPORT_DROP
ViewmodelArms.RightRun = RIGHT_RUN
ViewmodelArms.LeftRun = LEFT_RUN
ViewmodelArms.RightChain = R15_RIGHT
ViewmodelArms.LeftChain = R15_LEFT

ViewmodelArms.build = buildAvatarArm
ViewmodelArms.release = releaseCharacter

return ViewmodelArms
