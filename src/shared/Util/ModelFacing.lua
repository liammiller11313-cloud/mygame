--!nonstrict
--[[
	ModelFacing — which way a model somebody else built is pointing.

	── THE ASSUMPTION EVERY HOLDING SYSTEM MAKES ───────────────────────────────
	Both hands in this game assume a weapon's barrel runs down its own -Z.
	CarryVisualService says so in as many words — "every world model is authored
	barrel-down-Z, so a gripped weapon points where its owner is looking without
	any correction at all" — and ViewmodelController's pose table is built on the
	same assumption for the first-person copy.

	It is a perfectly reasonable convention and it is not enforceable. A gun
	modelled along X is an ordinary way to build one, and until this module both
	hands held it sideways: the viewmodel drew it lying across the bottom of the
	screen, and the world model came out of the survivor's fist at ninety degrees.

	So the assumption is now MEASURED rather than assumed, once, here, by both.

	── HOW IT DECIDES ──────────────────────────────────────────────────────────
	  1. A MUZZLE ATTACHMENT, if the model has one. Exact, and already this
	     game's documented convention — an artist whose gun comes out wrong fixes
	     it by putting one at the end of the barrel, which they may want anyway
	     so the flash and the tracers leave from the right place.
	  2. Otherwise the LONGEST AXIS, pointed away from the grip. A gun is longer
	     than it is wide, and the end furthest from the part you hold it by is the
	     end the rounds come out of.

	── AND THE SECOND ONE IS A GUESS, WHICH IT SAYS ────────────────────────────
	The longest axis is the barrel for one gun and is not necessarily the barrel
	for two. A DUAL-WIELD model is a pair of pistols with a gap between them, and
	which way that pair is longest depends entirely on how the artist arranged
	them — along their own barrels, or side by side across them. Measured from the
	outside there is no way to tell those apart.

	So the fallback sets LastWasGuess, and the callers that act on it say so at
	boot with the model's name. A player can then look at the gun once and know
	whether to do anything, and what to do is one instance: a Muzzle attachment at
	the end of a barrel makes the answer exact and takes this path out of it.

	Neither answer is trusted when it is marginal: a model already close to
	forward is left exactly as its author made it, because overruling a
	deliberate cant is worse than the bug this fixes.
]]

local ModelFacing = {}

--[[ The attachment names an artist might have used for the muzzle, in the order
     ViewmodelController already searched them. Kept here so both hands agree
     about what counts as one. ]]
ModelFacing.MuzzleNames = table.freeze({ "Muzzle", "MuzzlePoint", "MuzzleAttachment", "FirePoint", "Tip" })

--[[ How far off forward a model has to be before this overrules the artist.
     Thirty-five degrees is well past any deliberate cant and well short of the
     ninety a gun modelled on the wrong axis lands at. ]]
ModelFacing.Tolerance = math.cos(math.rad(35))

--[[ How much longer the longest axis has to be than the forward one before it is
     believed to be the barrel. A model 1.05 times as wide as it is long is not
     telling us anything. ]]
local AXIS_MARGIN = 1.3

--[[
	A model's own extents, measured in `frame` rather than in world axes.

	GetBoundingBox answers in world axes and so says nothing about which way the
	model itself is built — which is the entire question here. This walks the
	eight corners of every part through the frame's inverse, and that is the only
	measurement that survives a model having been saved at some arbitrary
	rotation in ServerStorage.
]]
function ModelFacing.extents(model: Model, frame: CFrame): (Vector3, Vector3)
	local inverse = frame:Inverse()
	local low = Vector3.new(math.huge, math.huge, math.huge)
	local high = -low
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") then
			local at = inverse * part.CFrame
			local half = part.Size * 0.5
			for _, sx in { -1, 1 } do
				for _, sy in { -1, 1 } do
					for _, sz in { -1, 1 } do
						local corner = at * Vector3.new(half.X * sx, half.Y * sy, half.Z * sz)
						low = low:Min(corner)
						high = high:Max(corner)
					end
				end
			end
		end
	end
	return low, high
end

local function muzzleIn(model: Model): Attachment?
	local best: Attachment? = nil
	local bestRank = math.huge
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("Attachment") then
			local rank = table.find(ModelFacing.MuzzleNames, descendant.Name)
			if rank and rank < bestRank then
				best, bestRank = descendant :: Attachment, rank
			end
		end
	end
	return best
end

--[[
	The barrel direction in `frame` space, or nil when it cannot tell.

	`grip` is the part the weapon is held by — a PrimaryPart, a Handle, or simply
	the biggest thing present. It is only used for the fallback, to decide which
	END of the longest axis is the muzzle.
]]
--[[ Set by forwardOf on the fallback path, so a caller that straightens a model
     can say which of the two answers it acted on. A Muzzle reading is exact and
     needs no comment; a longest-axis one is a guess and is worth naming. ]]
ModelFacing.LastWasGuess = false

function ModelFacing.forwardOf(model: Model, grip: BasePart?, frame: CFrame): Vector3?
	local inverse = frame:Inverse()
	local low, high = ModelFacing.extents(model, frame)
	local centre = (low + high) * 0.5

	ModelFacing.LastWasGuess = false

	local muzzle = muzzleIn(model)
	if muzzle then
		local delta = (inverse * muzzle.WorldPosition) - centre
		if delta.Magnitude > 0.05 then
			return delta.Unit
		end
	end

	if not grip then
		return nil
	end
	ModelFacing.LastWasGuess = true

	local size = high - low
	local axis, length = Vector3.zAxis, size.Z
	if size.X > length then
		axis, length = Vector3.xAxis, size.X
	end
	if size.Y > length then
		axis, length = Vector3.yAxis, size.Y
	end
	if axis == Vector3.zAxis or length < size.Z * AXIS_MARGIN then
		return nil
	end

	local held = ((inverse * grip.CFrame).Position - centre):Dot(axis)
	return if held > 0 then -axis else axis
end

--[[ Whether a forward reading is close enough to -Z that nothing should be done
     about it. The one place the tolerance is applied, so both hands agree about
     which models they leave alone. ]]
function ModelFacing.isForward(forward: Vector3?): boolean
	return forward == nil or forward.Z <= -ModelFacing.Tolerance
end

return ModelFacing
