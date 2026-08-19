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
	fallback, which is a T-pose that looks exactly like the bug it replaced. Every
	entry names the rig it is built for and is skipped on anything else.

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
local ROBLOX_ZOMBIE: AnimationSet = {
	rig = "R6",
	idle = { 125750544, 125750618 },
	walk = { 125749145 },
	run = { 125749145 },
	jump = { 125750702 },
	fall = { 125750759 },
	climb = { 125750800 },
}

--[[ Applied to any kind with no entry of its own below. Every infected in the
     game is a zombie, so one default covers the roster and a kind only needs a
     row here when it should move differently. ]]
AnimationConfig.Default = ROBLOX_ZOMBIE

--[[
	Per-kind overrides, keyed by Enums.Infected.

	Empty on purpose. The Rusher is the one rig in the set built as R15, and it
	needs no row: the default declares itself R6, the rig check rejects it, and
	the Rusher falls through to the procedural poser — which is the right answer
	rather than a missing one.
]]
AnimationConfig.Infected = table.freeze({} :: { [string]: AnimationSet })

--[[ The set for a kind, or the default. Never nil, so the caller does not have
     to branch — an empty set simply loads no tracks. ]]
function AnimationConfig.forInfected(kind: string): AnimationSet
	return AnimationConfig.Infected[kind] or AnimationConfig.Default
end

--[[ "R6" or "R15", from the joints the model actually has rather than from
     Humanoid.RigType. A supplied rig frequently reports R6 while being built
     with R15 limb names, and it is the NAMES an animation addresses. ]]
function AnimationConfig.rigOf(model: Model): string
	return if model:FindFirstChild("UpperTorso") then "R15" else "R6"
end

return table.freeze(AnimationConfig)
