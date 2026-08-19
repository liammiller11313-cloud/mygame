--!strict
--[[
	AnimationConfig — animation ids the game supplies, per infected kind.

	There are three places an infected's movement can come from, and they are
	tried in this order:

	  1. Animations HARVESTED FROM THE RIG. PlaceholderFactory lifts any ids a
	     supplied model shipped with into an FL_Animations folder before it strips
	     the scripts. A rig that came with its own walk knows its own proportions
	     better than anything here does, so it wins.
	  2. THIS FILE. Ids supplied for the KIND, which is where an official Roblox
	     animation package goes.
	  3. Client/Effects/InfectedPoseController. Procedural, no assets, and the
	     fallback when the first two produce nothing.

	── WHY EACH ENTRY DECLARES ITS RIG ─────────────────────────────────────────
	A Roblox animation is a keyframe sequence addressed to NAMED JOINTS. An R6
	animation moves "Right Arm" and "Left Leg"; an R15 rig has no parts by those
	names, so the track loads, reports itself as playing, and animates precisely
	nothing.

	That failure is worse than doing nothing, because InfectedPoseController
	stands down for any rig with tracks playing — so an R6 clip on an R15 rig
	produces a body that is not animated by the clip AND not animated by the
	fallback, which is a T-pose that looks exactly like the bug it replaced.

	So the sets are keyed BY RIG rather than by kind, and a per-kind override is
	checked against the rig before it is used. There is a complete set for each
	build, so no body falls through to the procedural poser for want of a
	matching clip — that fallback is now for rigs that are neither.

	── OWNERSHIP ───────────────────────────────────────────────────────────────
	Roblox will only play an animation owned by the place's creator or by Roblox
	itself. The ids below are Roblox's own zombie package, so they load for
	anybody. An id from another user's account will silently fail to load, which
	is what the warning in InfectedAnimator is for.
]]

local AnimationConfig = {}

export type AnimationSet = {
	--[[ "R6" or "R15": the joint names this set's keyframes address. Checked
	     against the actual rig, not against Humanoid.RigType, because a
	     hand-built model routinely reports one and is built as the other. ]]
	rig: string,
	--[[ Each role holds a LIST. More than one id means the body picks one at
	     spawn and keeps it, which is free variety: two Commons standing in the
	     same doorway idle differently. ]]
	idle: { number }?,
	walk: { number }?,
	run: { number }?,
	attack: { number }?,
	death: { number }?,
	jump: { number }?,
	fall: { number }?,
	climb: { number }?,
}

--[[
	Roblox's own zombie package, supplied as the default for every kind.

	Notes on what is and is not in it:

	  * Walk and run are the SAME id. That is how the package ships — the zombie
	    has one gait — and it is fine here because InfectedAnimator scales
	    playback rate to the body's real speed, so a Common sprinting at 21 plays
	    the same clip faster rather than skating.
	  * There is no attack and no death. The attack telegraph is already a pose
	    change on the server (InfectedBrain:_setSwingPose), and death is a
	    ragdoll — GoreService replaces the Motor6Ds outright, so an animation
	    there would have nothing left to drive.
	  * The package's "toolnone" is deliberately absent. It is the idle arm pose
	    for a character holding no tool, an overlay from Roblox's own Animate
	    script; nothing in this game holds a tool and nothing would ever play it.
]]
--[[
	Roblox's own zombie package for R6 rigs.

	Walk and run are the SAME id. That is how the package ships — the zombie has
	one gait — and it works here because InfectedAnimator scales playback rate to
	the body's real speed, so a Common sprinting at 21 plays the same clip faster
	rather than skating.

	No attack and no death in this one; the R15 set below has both. An R6 rig
	therefore still telegraphs its swing with InfectedBrain's C0 pose, which is
	what that pose has always been for.
]]
local ZOMBIE_R6: AnimationSet = {
	rig = "R6",
	idle = { 125750544, 125750618 },
	walk = { 125749145 },
	run = { 125749145 },
	jump = { 125750702 },
	fall = { 125750759 },
	climb = { 125750800 },
}

--[[
	The R15 set. Richer than the R6 one: distinct walk and run clips, and a real
	attack swing — which InfectedBrain defers to, skipping its own C0 telegraph
	rather than rearing the same shoulders back twice.

	One idle rather than two. Both ids supplied were the same number, so listing
	it twice would have meant every body rolling between two identical clips and
	the variation being a lie.

	── THE DEATH CLIP IS DELIBERATELY ABSENT ───────────────────────────────────
	Id 3716468774, if it is ever wanted.

	It cannot play while gore is on, and gore is on. Every infected death goes
	through GoreService:ragdoll, which DISABLES every Motor6D in the rig and puts
	the Humanoid into Physics state — there is nothing left for a keyframe to
	drive, and the ragdoll is the death animation at that point. Loading it anyway
	would be a LoadAnimation per zombie at spawn for a track that can never be
	seen.

	It becomes the right answer the moment GoreConfig.Enabled is false: no
	ragdoll, and today the corpse simply stands there until Debris takes it. If
	that switch is ever flipped, add `death = { 3716468774 }` here and a
	playOnce("death") in InfectedService's kill path, ahead of the brain being
	destroyed — the animator goes down with it.
]]
local ZOMBIE_R15: AnimationSet = {
	rig = "R15",
	idle = { 3489171152 },
	walk = { 3489174223 },
	run = { 3489173414 },
	attack = { 3489169607 },
	jump = { 616161997 },
	fall = { 616157476 },
	climb = { 616156119 },
}

--[[
	Keyed by the rig, because that is what actually decides whether a clip can
	play at all. A kind only needs naming when it should move differently from
	every other zombie of the same build — and none of them do.
]]
AnimationConfig.ByRig = table.freeze({
	R6 = ZOMBIE_R6,
	R15 = ZOMBIE_R15,
})

--[[
	Per-kind overrides, keyed by Enums.Infected, consulted before ByRig.

	Empty on purpose: every kind is a zombie, and the rig it was built as is the
	only thing that changes which clips address its joints. A row here is for the
	day the Witch should idle differently from a Common, not for rig differences.
]]
AnimationConfig.Infected = table.freeze({} :: { [string]: AnimationSet })

--[[ "R6" or "R15", from the joints the model actually has rather than from
     Humanoid.RigType. A supplied rig frequently reports R6 while being built
     with R15 limb names, and it is the NAMES an animation addresses. ]]
function AnimationConfig.rigOf(model: Model): string
	return if model:FindFirstChild("UpperTorso") then "R15" else "R6"
end

--[[
	The set to use for a body: its kind's override if it has one, otherwise the
	set for the rig it was built as.

	Returns nil when nothing matches, which is not an error — it is the signal
	that this body belongs to the client's procedural poser.
]]
function AnimationConfig.forInfected(kind: string, rig: string): AnimationSet?
	local override = AnimationConfig.Infected[kind]
	if override then
		--[[ An override still has to address the right joints. A row written for
		     an R6 Witch, applied to a Witch someone later rebuilt as R15, would
		     load and animate nothing — so it is checked, not trusted. ]]
		return if override.rig == rig then override else nil
	end
	return AnimationConfig.ByRig[rig]
end

return table.freeze(AnimationConfig)
