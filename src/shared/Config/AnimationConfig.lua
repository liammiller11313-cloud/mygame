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
	SURVIVORS — one clip, and it is not a gait.

	Survivors run Roblox's own Animate script, which owns their walk, run, jump
	and idle and does a better job of it than anything here would. The one thing
	it will not do is pose the arm for something held, because that is the
	`toolnone` overlay it plays only for a real Tool — and this game's inventory
	is not built on Tools.

	The FALLBACK pose, for anything with no idle of its own in AnimationConfig
	.Weapon above — which today means melee, and anything added without a clip.

	These are Roblox's own ToolNone clips, one per rig build. Two properties make
	them the right answer rather than a hack:

	  * they key the RIGHT ARM and nothing else, so the legs keep walking, the
	    torso keeps leaning, and only the arm holding the gun is overridden;
	  * they are authored at Action priority, which is above Movement, so the
	    walk cycle does not fight them for the shoulder.

	Without one, a welded rifle swings from a running survivor's hand like a
	carried shopping bag. CarryVisualService plays it while the hands mount has
	something in it and stops it when the hands are empty.
]]
AnimationConfig.SurvivorHold = table.freeze({
	R6 = 182393478,
	R15 = 507768375,
})

--[[
	Weapon animations, by weapon CLASS rather than by weapon.

	Sixteen guns do not need sixteen reloads. What a reload looks like is decided
	by the magazine, not by the receiver — every box-fed gun in this roster is the
	same motion, the shotgun is the one that is not, and a pistol differs mainly
	in that one hand is doing it. Three sets cover the whole armoury and a new gun
	inherits the right one by declaring its class, which it already had to do.

	── WHERE THESE PLAY ────────────────────────────────────────────────────────
	On the CHARACTER, third-person, over the hold pose in SurvivorHold above —
	which is to say, on what your teammates see. They are not the first-person
	view: that is ViewmodelController, and it is procedural (springs and impulses,
	no assets), which is why a shot kicks the gun in your hands whether or not any
	of these ids resolve.

	That split is deliberate rather than an omission. A viewmodel wants to be
	frame-tight and weapon-specific and to never desync from the ammo counter; a
	third-person reload wants to read at twenty studs through smoke. Those are
	different problems and one clip cannot be good at both.

	── PRIORITY ────────────────────────────────────────────────────────────────
	The hold pose loops at Action. These layer above it: a shot at Action2, a
	reload at Action3, so a shot fired the instant a reload finishes cannot
	half-override the reload that is still playing out. Roblox blends equal
	priorities by weight, which for two clips both keying the right arm looks like
	neither of them.

	── NO RIG GATE, ON PURPOSE ─────────────────────────────────────────────────
	The infected sets above are checked against the rig before they are used,
	because an R6 clip on an R15 body loads, reports itself playing, and stands
	the procedural poser down — producing a T-pose. Nothing is standing down here:
	a weapon clip that addresses the wrong joints simply does not move the arm,
	and the hold pose underneath it still holds. So these are played and left to
	AnimationCache to report if an id is unfetchable.
]]
export type WeaponAnimationSet = {
	fire: number?,
	reload: number?,
	--[[ `idle` REPLACES SurvivorHold for anything that declares one — it is the
	     same job done better, by a clip authored for this game's guns rather than
	     Roblox's generic ToolNone. `equip` plays once when the weapon changes.
	     Both are absent for melee, which keeps the generic pose. ]]
	equip: number?,
	idle: number?,
	--[[ Working the action AFTER a shot, for a gun that has an action to work.
	     Only the pump shotgun declares one. It is not part of `fire` because it
	     does not happen at the shot: the blast comes first and the hand moves a
	     beat later, and WeaponConfig.PumpPoint is where that beat is — the same
	     number the viewmodel and the pump sound already use, so what a teammate
	     sees and what the shooter feels land together. ]]
	pump: number?,
}

--[[
	Long guns. Shoulder-fired, two hands on the weapon, a magazine that goes in
	from below — which is the same motion whether it is an M4 or a Kriss, and the
	reason the marksman rifles take this set too.
]]
local FIRE_RIFLE = 92973496780914
local RELOAD_RIFLE = 72025071063219
local IDLE_RIFLE = 136810265016214

--[[
	Sidearms, revolver included. The reason these are not the rifle's is the OFF
	HAND: a pistol is held out in front on one arm with the other supporting, and
	reloaded by bringing that support hand across. A rifle clip played on a
	sidearm puts an arm where the gun is not.
]]
local FIRE_PISTOL = 111683203514533
local RELOAD_PISTOL = 113615308493373
local IDLE_PISTOL = 132900418012706

local FIRE_SMG = 126130498796830
local RELOAD_SMG = 105560973486853

--[[
	The shotgun, which is the only gun here with four rather than three.

	Its reload is shell by shell — InventoryService drives it one shell at a time
	and firing mid-reload keeps whatever went in — so the clip covers the cycle
	and the per-shell sound carries the count. And it is the only gun with an
	ACTION to work, which is what `pump` is: not part of the shot, a beat after
	it. See WeaponConfig.PumpPoint.
]]
local FIRE_SHOTGUN = 99806949982450
local RELOAD_SHOTGUN = 121969592245205
local IDLE_SHOTGUN = 75535245272034
local PUMP_SHOTGUN = 126191920793940

--[[
	The draw, which every gun really does share: a hand goes to the weapon and the
	weapon comes up, and at the distance a teammate sees it that reads the same
	whether what came up is an M4 or a Kriss.

	The generic two-handed low-ready beside it is the SMG's, and nothing else's.
	Every other gun has a hold of its own now — a sidearm held out on one arm, a
	rifle across the chest and a shotgun at the shoulder are three different
	poses, and one clip for all of them was the compromise that made the pistols
	look wrong. It stays here rather than being renamed IDLE_SMG because it is
	also what any gun added without a hold inherits.

	Melee gets neither. It is one-handed, it is drawn differently, and the pose
	that suits a rifle across the chest is wrong for a machete — it keeps Roblox's
	generic ToolNone from SurvivorHold above.
]]
local IDLE_GUN = 117670476393944
local EQUIP_GUN = 125430658600847

AnimationConfig.Weapon = table.freeze({
	Rifle = table.freeze({
		fire = FIRE_RIFLE,
		reload = RELOAD_RIFLE,
		idle = IDLE_RIFLE,
		equip = EQUIP_GUN,
	}),

	--[[ The two marksman rifles take the rifle set. They are rifles — a scoped
	     Mk18 loads exactly like an unscoped one — and giving them their own row
	     would be two more places to edit for no visible difference. ]]
	Marksman = table.freeze({
		fire = FIRE_RIFLE,
		reload = RELOAD_RIFLE,
		idle = IDLE_RIFLE,
		equip = EQUIP_GUN,
	}),

	--[[ The submachine guns have their own pair now. They spent one commit on the
	     rifle's, which was right in shape and long in the arms. ]]
	SMG = table.freeze({
		fire = FIRE_SMG,
		reload = RELOAD_SMG,
		idle = IDLE_GUN,
		equip = EQUIP_GUN,
	}),

	--[[ The one genuinely different reload in the game — shell by shell, and
	     InventoryService drives it a shell at a time. The clip here covers the
	     whole sequence; the per-shell sound is what actually carries the count. ]]
	Shotgun = table.freeze({
		fire = FIRE_SHOTGUN,
		reload = RELOAD_SHOTGUN,
		idle = IDLE_SHOTGUN,
		pump = PUMP_SHOTGUN,
		equip = EQUIP_GUN,
	}),

	--[[ Covers the revolver as well. A .357 is loaded very differently from an
	     M1911 in life and identically here, because both are "the off hand comes
	     across" at the distance anybody sees it from. ]]
	Pistol = table.freeze({
		fire = FIRE_PISTOL,
		reload = RELOAD_PISTOL,
		idle = IDLE_PISTOL,
		equip = EQUIP_GUN,
	}),

	--[[ Melee has no fire or reload and wants none: the swing is MeleeService's
	     arc and the viewmodel's kick, and a clip keying the right arm would fight
	     both. It has no idle or equip either — see IDLE_GUN above. ]]
})

--[[
	What to play when a class's own clip cannot be fetched.

	Roblox refuses to play an animation that is not owned by the place's creator
	or by Roblox itself, and it refuses it SILENTLY — LoadAnimation returns a
	perfectly ordinary track that never moves anything. Four ids in this file
	were in that state at one point, which was four guns out of five with no
	visible shot and no visible reload in third person, and nothing in the log
	except one warning per id.

	All of them have since been re-uploaded, so as of now this engages for
	nothing. It stays because the failure it covers is silent and the ids above
	are supplied rather than derived: a re-upload under the wrong account, an
	asset moderated, a new gun given a borrowed id — any of those puts a class
	right back into that state, and borrowing the SMG's pair is a far better
	answer than a gun that does not move.

	The SMG's are the spares because they are the ids that have never once been
	refused; a fallback that might itself be refused is not a fallback.

	Deliberately no `pump` spare. A missing pump is a flourish that does not
	play. A missing shot is a gun that looks broken, and those are not the same
	thing to trade for.

	CarryVisualService consults AnimationCache.hasFailed, so this only ever
	engages for an id Roblox has actually refused.
]]
AnimationConfig.WeaponFallback = table.freeze({
	fire = FIRE_SMG,
	reload = RELOAD_SMG,
})

--[[ The set for a weapon class, or nil for one with no animations — which is
     melee, and is not an error. ]]
function AnimationConfig.forWeaponClass(class: string?): WeaponAnimationSet?
	if typeof(class) ~= "string" then
		return nil
	end
	return AnimationConfig.Weapon[class]
end

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

--[[
	Every animation id this game declares, once each.

	For preloading. An AnimationTrack whose asset has not arrived yet plays
	NOTHING — it reports itself as playing, its Length is zero, and nothing moves
	— so the first zombies of a fresh server animate only if the clips happen to
	already be in the content cache. That is exactly the shape of "sometimes my
	animations do not load".

	Enumerated here rather than in the animator because this file is the only
	place that knows what has been declared, and a set added below would
	otherwise have to be remembered in two places.
]]
function AnimationConfig.allIds(): { number }
	local seen: { [number]: boolean } = {}
	local out: { number } = {}

	local function take(value: any)
		if typeof(value) == "number" and not seen[value] then
			seen[value] = true
			table.insert(out, value)
		end
	end

	local function takeSet(set: any)
		if typeof(set) ~= "table" then
			return
		end
		for role, ids in set do
			if role ~= "rig" and typeof(ids) == "table" then
				for _, id in ids do
					take(id)
				end
			end
		end
	end

	for _, set in AnimationConfig.ByRig do
		takeSet(set)
	end
	for _, set in AnimationConfig.Infected do
		takeSet(set)
	end
	for _, id in AnimationConfig.SurvivorHold do
		take(id)
	end
	--[[ And the weapon clips, which matter here more than most: a reload is a
	     two-second animation the player is standing still for, and one that has
	     not arrived yet is two seconds of a survivor doing nothing visible while
	     their ammo count refills. ]]
	for _, set in AnimationConfig.Weapon do
		take(set.fire)
		take(set.reload)
		take(set.equip)
		take(set.idle)
		take(set.pump)
	end
	--[[ And the spares. They are the SMG's own ids today, so `take` dedupes them
	     away — but the moment they are not, an unpreloaded fallback would be a
	     fallback that also plays nothing. ]]
	for _, id in AnimationConfig.WeaponFallback do
		take(id)
	end

	return out
end

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
