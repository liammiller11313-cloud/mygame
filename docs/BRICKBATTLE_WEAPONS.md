# The Brickbattle weapons in Fading Light

Four weapons in this game come from Brickbattle Ultimate: the Classic Sword,
Slingshot, Rocket Launcher and Paintball Gun. This file is the record of what
each one does in the original, what it does here, and why the two differ where
they differ.

## There are no copies of the original scripts in this repository

There used to be. `packs/BrickbattlersPack/` held seventeen rewritten versions
of those tools' scripts, along with a table telling you which file to paste over
which script inside each Tool. That folder is gone, deliberately, and nothing
should recreate it.

The author has since put the real Brickbattle Ultimate Tools into
`ReplicatedStorage.Assets.Weapons`. Against those, a folder of "corrected"
copies is not a reference — it is a loaded gun pointed at the originals. Its own
instructions said **replaces** `RocketScript`, **replaces** `Paintball`,
**replaces** `SwordScript`. Following them would overwrite the author's own code
with somebody else's edit of an older copy, and the edit would look like the
original while not being it.

So the originals are the originals, and they live in Studio where the author put
them.

## Their scripts DO run, and that is the whole point

This section used to say the opposite, and it was true when it was written.

`adoptWeapon` destroys every `LuaSourceContainer` and every `Sound` in a
supplied asset, which is the right default — PlaceholderFactory's header calls
it "the security line and it is not negotiable: a Script inside a downloaded
model runs on OUR server with full permissions". For these four, that default
threw away the thing being asked for.

So there is a second path now, and only these four take it. A weapon marked
`nativeTool` in WeaponConfig never goes through the asset pipeline at all:
NativeToolService clones the author's Tool out of `Assets.Weapons` exactly as
it is — `ServerLauncher`, `LocalLauncher`, `PogoServer`, `PogoClient`,
`SwordScript`, `Slingshot`, `Client`, the disabled projectile templates, the
`Explosion` and `Swoosh` sounds, the `fire` and `MouseLoc` remotes — into the
player's Backpack, and equips it.

The difference from a downloaded model is not that these scripts are safe. It
is that they are the POINT, and that the author put them there: the same trust
boundary as the game's own source. The set is a closed list in WeaponConfig
rather than whatever happens to be sitting in a folder.

### What the game stops doing, so nothing happens twice

| Ordinarily | For a native tool |
|---|---|
| ViewmodelController draws a first-person weapon | nothing — the engine already welds the Tool's Handle into the hand you are looking down, so a viewmodel is a second copy of the same gun on different springs |
| CarryVisualService mounts a world model in the hand | nothing, same weld, same reason |
| WeaponController predicts the shot: flash, sound, tracer, ammo, recoil, remote | nothing. The Tool's own LocalScript is listening for that same click |
| BallisticsService resolves the shot | refused. Its Tool fires through its own remote |
| MeleeService resolves the swing (the Sword is `fireMode = "Melee"`) | refused. `SwordScript` owns the slash, the lunge and both samples |

### Fitted to the hand, without touching the code

Three properties are set on the clone. None of them is behaviour, and all three
are things a brickbattle tool never had to care about and this game does.

| Property | Why |
|---|---|
| `Massless = true` on every part | a Tool's Handle is welded into the arm and its mass adds to the character's. Walkspeed, jump height and the shove all read off that, so without this the movement changes depending on which weapon is out — and movement is not the Tool's to change |
| `CanCollide = false` on every part | an equipped Handle that collides is a solid object attached to your arm: it catches on door frames, shoves teammates and pushes the camera in first person. `Touched` still fires without it, which matters because `Touched` is exactly how `SwordScript` deals its damage |
| `CanBeDropped = false` on the Tool | Backspace drops a Tool on the floor. This game's inventory does not know the Tool exists, so a dropped one is a weapon gone from a slot that still claims it, and a live Tool lying in the map. The slot is chosen in this game's own UI and dropping is not one of the choices it offers |

`CanQuery` and `CanTouch` are deliberately left alone: their scripts raycast and
use `Touched`, and those are the two flags that would break if guessed at.

There is no viewmodel, so what you see in first person is the author's own model
welded to your own arm — which is what a classic Roblox tool has always looked
like down the camera.

### What it costs

**Ammo and reload do not apply.** The HUD's magazine counter does not describe
these four, and cannot: a brickbattle tool has no magazine. That is not a bug
waiting to be fixed.

**Kill credit needed bridging, and it is bridged.** Their scripts claim a kill
the classic way — an ObjectValue called `creator` parented onto the victim's
Humanoid — and nothing in this game reads that. Kills are credited off
`InfectedService.died` and its `ctx.attacker`, set inside `damage`, which these
weapons never reach.

The rig still dies correctly: InfectedService's `Humanoid.Died` connection was
written for exactly this case and its comment says so ("a stray
`Humanoid:TakeDamage`"). It just died with no attacker, which is worth nothing —
no stat, no XP, no quest, no leaderboard. So `InfectedService:creditPending`
takes a context from outside, NativeToolService turns the `creator` tag into
one, and every listener downstream sees the shape it always sees. First tag
wins, so a second shooter cannot steal the first one's claim.

## The tuning is frozen

**The numbers are not to be changed again.** Damage, rpm, magazine, reload,
projectile speed and the lunge window are settled. The ledger below records
where each came from and what it cost; it is a record now, not a working area.
Integration is still fair game — where the model sits in the hand, which way the
barrel points, which sound plays, whether the touch controls reach it — because
that is about fitting the author's asset into the game rather than about how the
weapon plays.

If a weapon feels wrong, the first question is whether the model imported
cleanly, not whether a number wants moving. The boot report's facing line
answers it: **"the Tool's own posed Grip, carried across, nothing inferred"**
means the pose came out of the Tool and nothing was guessed. "STRAIGHTENED" or
"ASSUMED" means the Tool had no pose to read and the pipeline fell back to the
longest axis of the mesh, which for a sword is the blade and for a launcher is
the tube.

## The ledger — every original behaviour, and where it went

The four weapons that became Fading Light weapons, checked line by line against
the scripts in this folder. Everything in the originals is in one of three
columns: carried over, translated into something this game already has, or
deliberately left out with the reason written down.

Nothing is listed as "carried over" on the strength of a comment. Each one was
read in the file it lives in.

### Classic Sword — its `SwordScript`

| The original | In the game |
|---|---|
| Slash: 10 on a click | 52 a swing at 280rpm. Was 240 at 140rpm — same 243 a second, arriving in smaller pieces, and a fast-clicking sword is the whole feel of the classic |
| Lunge: 30 on a second click within 0.2s | ×3 for 156, on a 0.30s window. **This row used to say 0.2 was unreachable and settle for 0.9, and 0.9 was not a compromise — it was broken.** MeleeService's floor at 140rpm is 0.364s, which is INSIDE 0.9, so holding the attack button lunged every single time and the ordinary slash barely existed. The fix is not the window alone: 280rpm drops that floor to 0.182s, which is what leaves 0.30 any room. The two taps must land 182–300ms apart — a desktop double-click is ~120ms and a thumb double-tap is 200–300ms, so the move exists on a phone, which it did not |
| Spam-clicking lunges | it still does. Not a bug left in: `if Tick - LastAttack < 0.2 then Lunge()` is exactly that |
| The lunge holds the tool for its grip animation | 0.8s lockout, which is the 0.2 + 0.6 that animation took. Was 1.2, guessed |
| Grip swings Up → Out → Up | the viewmodel drops the arc's left-right entirely and spends it on depth, because a thrust is not a swing |
| `SwordSlash` and `SwordLunge` — two samples | two, the same id re-pitched down and carrying further. See `AudioConfig.WeaponLunge` |
| Team and self checks | `FriendlyFireMeleeMultiplier` is 0 |
| Checks the RightGrip weld before damaging | the server validates the actor and the weapon in hand instead |
| **Base: 5 on `Handle.Touched`** — brushing somebody hurts them | **left out, and it cannot be ported.** Nothing in this game welds a world weapon model into a hand, so there is no blade in the world for anything to touch. Faking it with a proximity sweep would be inventing a mechanic rather than porting one, and at this game's scale a passive touch worth half a slash would be 120 damage for walking into a crowd |

### Classic Slingshot — its `Slingshot` and `PelletScript`

| The original | In the game |
|---|---|
| **`PELLET_SPEED = 100` — a part with a velocity** | **165 studs/s, a real travelling pellet.** This row used to say "every weapon here is hitscan, so nothing drops", which was true and was the problem: a hitscan slingshot does not sling anything. 165 rather than 100 is the optimisation — a hundred crosses a room in four tenths of a second, fine against a brickbattle opponent walking at 16 and not fine against a Common running at you |
| A BodyForce cancels gravity, so the pellet flies dead flat | `gravity = false`, which is now a real cancellation of a real drop rather than a property of having no flight. Deliberate: the classic is aimed down a mouse cursor sitting on the target, which hides the drop, and a centre-screen crosshair does not |
| 8 damage | 32 |
| `damage /= 2` on every surface until it is under 1 | `penetration = 3`, `penetrationFalloff = 0.5` — 32, then 16, then 8 through a line of Commons, and it SURVIVED the round becoming a projectile. ProjectileService spends the same two numbers over the flight instead of along a ray, adding each body to the round's own ignore list as it goes |
| It bounces off walls and halves | **its own.** Two bounces sharing the pierce chain's falloff were built here and then deleted, for the same reason as the servo: the slingshot runs its own Tool's scripts, so nothing ProjectileService does for it is reached. Whether a pellet bounces is `PelletScript`'s business now |
| A black 1×1×1 ball | `Vector3.new(1, 1, 1)` and BrickColor 26, exactly, on the round itself |
| Two-second pellet life | two seconds. At 165 that is 330 studs, past this weapon's own 300 of range, so it is a backstop rather than a limit |
| No team check — the pellet hurts your own side | the game's own friendly fire, 0.25 |
| Pogo — shoot the floor, go up | the `pogo` block, `directional = false`, capped. See `PogoProfile`. It fires on the pellet's IMPACT now rather than on the trigger, which is both correct and what the classic does — the pellet has to actually reach the floor |
| **`RELOAD = 6` — one pellet every six seconds** | **75rpm with a 12-round magazine.** The single biggest optimisation in the pack. Six seconds between shots is a duel timing; against a horde it is a weapon nobody would carry. It is still the slowest-firing sidearm in the game by a distance |

### Classic Rocket Launcher — its `ServerLauncher` and `RocketScript`

| The original | In the game |
|---|---|
| `COOLDOWN = 3` between shots | 30rpm, one in the tube, 3.4s reload, two in reserve |
| A default Roblox `Explosion` (BlastRadius 4) | `blastRadius = 16`. Four times, because a horde shooter needs a rocket that clears a doorway rather than a rocket that clears a doorframe |
| `DestroyJointRadiusPercent = 1` — everything in the radius comes apart | `GoreConfig.Scoring.ExplosiveAlwaysGibs`, read by both DamageService and GoreService |
| Blast pressure throws bodies | `knockback = 70` |
| It hurts whoever fired it | verified in code, not assumed: self-damage passes `applyDamage`'s friendly-fire gate where a teammate's is blocked, so a rocket at your own feet costs about 43 health on Normal |
| Rocket jump | the `pogo` block, `directional = true` — away from the blast, so shooting the wall behind you is the move |
| Explosion on contact | the blast is ProjectileService's, at the point the round actually reaches |
| **A travelling rocket, 10s of flight** | **a travelling rocket, 10s of flight.** This row used to read "hitscan, detonating where the shot lands" and called it a systems choice. It was not — it was a shotgun that made an explosion. A `projectile` block now puts the rocket in the air |
| The servo: velocity = 7 × how far it has fallen behind a point one stud further along its nose, every frame | **its own.** This was reimplemented here — gain 7, the wind-up off a dead stop, 90% of cruise at 0.32s, all measured — and then deleted, because the launcher is `nativeTool` and its own RocketScript flies the rocket. BallisticsService returns before ProjectileService is ever reached, so the reimplementation was unreachable code describing a round this game no longer spawns |
| Rocket jump fires on the trigger (the client's `COOLDOWN`) | fires on the DETONATION. A rocket jump is the blast lifting you, and the blast is now a second downrange — firing it on the pull would launch you off a rocket still in the air |
| `Swoosh` looping in flight | not yet. There is flight to swoosh through now, which there was not before; the sound is not wired |

### Classic Paintball Gun — its `Paintball`

| The original | In the game |
|---|---|
| 5 damage | 42 — two body shots on a Common. Was 13 at 1000rpm, which is the same 210-a-second on paper and a completely different weapon in the hand |
| **One ball per click, and the ball is a real object that crosses the room** | **one ball per click, and the ball is a real object that crosses the room.** This row used to say "Auto, 1000rpm, hitscan" — it was a Kriss Vector that painted things. 200 studs/s, a fifth of a second across a room, and a miss now costs a ball that has already left |
| The ball has gravity and drops | **it does not.** The one deliberate departure: the classic was aimed down a mouse cursor sitting on the target, which hides the drop. A centre-screen crosshair does not, and a ball that falls 24 studs over 100 makes it lie |
| Repaints anything under `1.2 * 200` mass | `PaintService`, the same 240 limit, for the same reason: it is a size rule wearing a mass rule's clothes |
| Three splat parts, growing to 4× and gone in two seconds | one splat per hit, from the pooled decal system. Three per shot would spend a 56-slot pool in a few seconds |
| Eight-second ball life | three, which at 200 studs/s is 600 studs — well past this weapon's 220 of range, so it is a backstop and not a limit |
| The creator tag expires on its own | the game's own kill credit |
| **The ball's single BrickColor** | **a six-colour palette, one drawn per shot from the shot seed.** A deliberate change: it reads as a paintball gun from across a room, and it makes two players painting the same corridor legible as two players |
| **It paints PEOPLE too** — a limb is well under the mass limit | **survivors yes, infected no.** Half of this row was right and the half that was right is the infected half: a special is told apart at six paces by its colour, and a team that cannot tell a Boomer from a Common has lost the fight that colour was warning them about. Painting your teammates carries none of that and is most of what a paintball gun is for, so it is back for them. Straight onto the part rather than through PaintService, whose `paintable` gate begins with `inLiveMap` and would refuse a limb — and would cache a verdict per limb, keyed by parts that are destroyed on every respawn. It wears off when they do |

### The other three

`ClassicTimebomb`, `ClassicSuperball` and `ClassicTrowel` are not sold and not
wired in. The pass grants four and says four. A timebomb and a superball are
throwables and belong in ProjectileService beside the pipe bomb; a trowel builds
geometry and wants the barricade system. They arrive when their pipelines do,
and until then describing seven and selling four would be the lie.

