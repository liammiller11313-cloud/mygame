# Brickbattler's Pack — script fixes

Corrected versions of the tool scripts from Brickbattle Ultimate. The behaviour
and the tuning are unchanged; what changed is who is allowed to ask for it.

These are standalone Roblox Tool scripts. `check.sh` parses and lints them, but
`audit.py` does not look at them because they reference no game module.

**Four of the seven are now also real weapons in Fading Light**, rebuilt against
this game's own systems rather than dropped in as tools. These files stay as the
REFERENCE — what the originals actually do, in code — and the ledger at the
bottom of this file accounts for every behaviour in them one by one.

## Where each file goes

| File | Class | Parent |
|---|---|---|
| `PogoCore.lua` | ModuleScript | `ReplicatedStorage` |
| `PogoServer.lua` | Script | inside each pogo tool |
| `PogoClient.lua` | LocalScript | inside each pogo tool |
| `ServerLauncher.lua` | Script | inside `RocketLauncher` |
| `LocalLauncher.lua` | LocalScript | inside `RocketLauncher` |
| `WallMaker.lua` | Script | inside `ClassicTrowel` |
| `WallMakerClient.lua` | LocalScript | `ClassicTrowel` — replaces `Client` |
| `Slingshot.lua` | Script | `ClassicSlingshot` — replaces `Slingshot` |
| `SlingshotClient.lua` | LocalScript | `ClassicSlingshot` — replaces `Client` |
| `CannonScript.lua` | Script | `ClassicSuperball` — replaces `CannonScript` |
| `SuperballClient.lua` | LocalScript | `ClassicSuperball` — replaces `Client` |
| `PelletScript.lua` | Script (Disabled) | `ClassicSlingshot` — replaces `PelletScript` |
| `CannonBall.lua` | Script (Disabled) | `ClassicSuperball` — replaces `CannonBall` |
| `RocketScript.lua` | Script (Disabled) | `RocketLauncher` — replaces `RocketScript` |
| `Paintball.lua` | Script (Disabled) | `ClassicPaintballGun` — replaces `Paintball` |
| `Bomb.lua` | Script (Disabled) | `ClassicTimebomb` — replaces `Bomb` |
| `SwordScript.lua` | Script | `ClassicSword` — replaces `SwordScript` |

The last two stay **Disabled** in the tool. They are templates cloned into each
projectile and enabled there, which is why they are greyed out in Explorer.

Set a **`PogoProfile`** string attribute on each pogo tool: `Slingshot` on
`ClassicSlingshot`, `Rocket` on `RocketLauncher`. Unset falls back to `Rocket`.

`PogoCore` is one module rather than a copy per tool because the copies had
already drifted — the rocket's cooldown was `0.28` on the client and `0.25` on
the server, so the client's limit was decoration and the server's was the real
one.

The remotes (`PogoRequest`, `PogoVerdict`, `RocketFire`, `PlaceWall`) are
created by the server scripts if missing. Do not add them by hand.

**Delete afterwards:** `SlingshotPogo` (replaced by `PogoClient`), and the
`MouseLoc` RemoteFunction in all three of `ClassicTrowel`, `ClassicSlingshot`
and `ClassicSuperball`.

The slingshot and superball scripts are written against the **classic
free-model** versions, which is what those tools ship with — I have not seen
Brickbattle Ultimate's copies. The structural fix is the same either way; if the
weapons were retuned, the speed, size, colour and reload values are the labelled
constants at the top of each file and nothing else depends on them.

## What was wrong

**`PogoServer` never ran.** Its first line was
`tool:WaitForChild("PogoRequest")`, and no tool contained a `PogoRequest`.
`WaitForChild` with no timeout yields forever, so the script stopped on line two
and its `OnServerEvent` was never connected. `PogoClient` never fired a request
either, so both ends of the server path were disconnected and the only pogo
running was an unvalidated LocalScript.

**Anyone could fire everyone's rocket launcher.** `createEvent` did
`FindFirstChild` first, so every launcher in the game connected to a single
`ROBLOX_RocketFireEvent` sitting in `ReplicatedStorage` where any client can
reach it. `fire` then read `Tool.Parent` for the shooter instead of checking the
sender. One `FireServer` call fired every launcher on the server, at a chosen
point, tagged with somebody else's name. The 3-second cooldown lived in a
LocalScript an attacker is not running; there was no server cooldown at all.

**The pogo took the client's hit position on trust.** `canPogo` asked only
whether the point was 2–50 studs away. Not whether the player fired, not whether
the tool was equipped, not whether there was any geometry there. The remote
carries a *direction* now, and the server casts it against its own copy of the
world.

**`findBelowPoint` invented ground.** Its third fallback returned
`hrp.Position + Vector3.new(0, -10, 0)` when nothing was hit, so a shot at open
sky launched as well as a shot at a floor. With stacking that is unbounded
flight needing no map. A miss is now simply nothing.

**`MouseLoc:InvokeClient(player)`** yields the server thread until that client
answers, and a client need not. The trowel, the slingshot and the superball all
shipped one, and all three shipped a `Client` LocalScript whose only job was
answering it. All three pairs are now client→server RemoteEvents, and in every
one of the three the new client script **replaces** that `Client` rather than
joining it — an `OnClientInvoke` handler for a RemoteFunction nobody invokes any
more is dead code that still looks live.

That fix opens a door in the same motion, and it has to be closed at the same
time. The slingshot and superball were safe from the launcher's problem *by
accident*: they hung off `Tool.Activated`, which the engine only raises for the
character actually holding the tool, so there was no packet for anyone else to
send. Replacing that with a RemoteEvent creates exactly that hole. Both now
check that the sender is holding the tool and both keep the cooldown on the
server — `Tool.Enabled` is still set, because it greys the tool out and stops
the client sending, but a limit only the client enforces is not a limit.

**`brick:MakeJoints()`** welds each brick to whatever it touches — including a
character standing where the wall goes. The bricks are anchored instead.

Also: unvalidated `Vector3` arguments reaching `.Unit` (a NaN or zero vector puts
a part at an undefined CFrame), the debug `print`s in `SlingshotPogo`, and an
unbounded build loop that advanced `x` from the size of the brick it had just
made.

## Verified against the real projectile scripts

`BrickCleanup` turned out to be a plain `Debris:AddItem(script.Parent, 24)`, so
anchoring the wall bricks is safe — nothing in it depends on physics.

`PelletScript` reads nothing off the pellet but `Touched` and the `creator`
child, so the rewritten `Slingshot` is compatible with it. 8 damage, two second
life, half the bite per surface hit.

`CannonBall` was **not** compatible, and the break was mine: it calls
`Ball.Boing:Play()` on every bounce, and a ball built from a bare
`Instance.new("Part")` has no such child, so it errored on first touch and dealt
no damage at all. `CannonScript` now carries a `Boing` across into each ball,
found on the tool or in the Handle, with a silent empty Sound as the fallback —
a bounce nobody hears beats a projectile that does nothing.

### And a bug in `CannonBall` that predates all of this

```lua
while (humanoid:FindFirstChild("creator")) do
    humanoid:FindFirstChild("creator").Parent:Destroy()
end
```

`FindFirstChild("creator")` is the tag; its `.Parent` is the **humanoid**. That
line destroyed the Humanoid of anyone who already carried a creator tag — and
tags live one second, so that means anyone damaged by anybody in the last
second, which in a brickbattle is most of the time two people shoot the same
target.

Destroying a Humanoid is worse than killing the character: Roblox drives respawn
off `Humanoid.Died`, and a destroyed Humanoid never fires it. The `TakeDamage`
on the following line then runs against a destroyed instance.

`PelletScript` has the same loop written correctly — it clears the TAG — which
is how the difference shows up. `CannonBall.lua` here destroys the tag.

## The other three projectile scripts

`CannonBall`'s Humanoid-destroying tag loop turned out to be a **one-off, not a
pattern**. `RocketScript`, `Paintball` and `Bomb` all clone the creator tag
correctly. Each had something else.

**`RocketScript` — a landmine and a crash.** `error = position - shaft.Position`
with no `local` overwrote Lua's own `error()` for the whole script; nothing
called it, so it worked, and any line added later that tried to raise an error
would have tried to call a Vector3 instead. Renamed to `drift`. And
`part.Parent.Humanoid` threw on any part in the world named "Head" whose parent
has no Humanoid — an explosion radius finds one eventually, and it killed the
tagging for everyone else in the same blast.

Its 0.1s tag lifetime is unchanged and worth watching during testing: it assumes
the blast kills instantly, so anyone who survives a fifth of a second is a kill
that credits nobody.

**`Paintball` — the ball kept killing after it had hit you.** The `wait(2)` sat
*inside* the Touched handler and before the disconnect, so a ball that hit a
player stayed in the world, still connected, for two more seconds and could
damage somebody else. A ball that hit a wall died immediately; only the ones
that hit people lived on. It also called `untagHumanoid` after that wait, which
deleted whatever creator tag it found — not necessarily its own — so a player
shot by someone else in the meantime had *their* claim erased and the kill
credited nobody. The disconnect happens first now and the tag expires on Debris.

Left alone: the gun permanently repaints anything it hits under ~240 mass, with
no way back. That is either the point of a paintball gun or a way to redecorate
a map forever, and which one depends on the game rather than the code.

**`Bomb` — a tag that outlived the bomb.** Its comment read *"tag does not need
to expire iff all explosions lethal"*, and `untagHumanoid` sat directly beneath
it, never called from anywhere. The "iff" was load-bearing and untrue: anyone who
survived the blast wore the bomber's name permanently, so their next death — to
anything — credited the bomber. Same `part.Parent.Humanoid` crash as the rocket.

Both of the bomb's sound ids are legacy paths with backslashes
(`rbxasset://sounds\clickfast.wav`). Left exactly as they were, because guessing
replacement asset ids is inventing content. If the bomb ticks silently, that is
why, and it is two strings rather than a code problem.

## The sword

It needed no security work at all, which is worth recording. Alone in the pack
it has no RemoteEvent and no RemoteFunction — it runs off `Tool.Activated` and
`Handle.Touched`, both of which the engine raises only for the holder. There is
no packet to forge and no thread to park. It even checks the `RightGrip` weld
before it will damage anything, which the other six do not.

It had simply never dealt its slash damage.

```lua
if (Tick - LastAttack < 0.2) then Lunge() else Attack() end
LastAttack = Tick
--wait(0.5)
Damage = DamageValues.BaseDamage
```

`Attack()` sets `Damage` to `SlashDamage` and returns without yielding, and the
next line puts it straight back. The window where a slash is worth 10 was zero
frames wide, so **every slash this sword has landed did 5**, and
`DamageValues.SlashDamage` was dead config.

The commented-out `wait(0.5)` is the original, and restoring it fixes the slash
by breaking the lunge: `Tool.Enabled` stays false for its duration, and the
lunge needs a *second click inside 0.2 seconds* — impossible while disabled.
Whoever commented it out was fixing that and traded one bug for the other.

Both work now because the damage window stopped being the same thing as the
cooldown. Damage reverts on its own timer, tokened so a lunge begun during a
slash's window is not dropped back to 5 when that window expires. `Tool.Enabled`
returns immediately after a slash so the double-click still lands; the lunge
still holds the tool for its grip animation, which is where its cooldown always
was.

Also: the `Animation` objects were created at the **end** of `Activated`, after
the attack that wanted them — so `Tool:FindFirstChild("R15Slash")` was nil on the
first swing and every R15 player's opening slash played nothing. Built once at
load now.

## What is deliberately NOT capped

A full twelve-stack slingshot chain still throws you roughly 1600 studs/sec
upward, because `math.max(v.Y, 0) + boost` compounds on top of the velocity you
already have. That is the mechanic. `maxUpSpeed` exists in each profile and is
`0` — off — and is there only for a game that needs a ceiling for its own
reasons.

Fading Light is such a game: `SpawnPlacement` uses a flow window to put hordes
ahead of the team, and `LevelService:getFlowDistance` projects a position onto a
polyline. A player far above the map projects somewhere meaningless and the
Director aims at nothing. That is a decision for the integration, not a fix to
the pack.

## What this does not claim to do

None of it stops a determined exploiter from flying. It cannot: a player owns
their own `HumanoidRootPart` and can write its velocity whenever they like. What
it stops is these tools being the thing that *hands out* the launch.

## The ledger — every original behaviour, and where it went

The four weapons that became Fading Light weapons, checked line by line against
the scripts in this folder. Everything in the originals is in one of three
columns: carried over, translated into something this game already has, or
deliberately left out with the reason written down.

Nothing is listed as "carried over" on the strength of a comment. Each one was
read in the file it lives in.

### Classic Sword — `SwordScript.lua`

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

### Classic Slingshot — `Slingshot.lua`, `PelletScript.lua`

| The original | In the game |
|---|---|
| **`PELLET_SPEED = 100` — a part with a velocity** | **165 studs/s, a real travelling pellet.** This row used to say "every weapon here is hitscan, so nothing drops", which was true and was the problem: a hitscan slingshot does not sling anything. 165 rather than 100 is the optimisation — a hundred crosses a room in four tenths of a second, fine against a brickbattle opponent walking at 16 and not fine against a Common running at you |
| A BodyForce cancels gravity, so the pellet flies dead flat | `gravity = false`, which is now a real cancellation of a real drop rather than a property of having no flight. Deliberate: the classic is aimed down a mouse cursor sitting on the target, which hides the drop, and a centre-screen crosshair does not |
| 8 damage | 32 |
| `damage /= 2` on every surface until it is under 1 | `penetration = 3`, `penetrationFalloff = 0.5` — 32, then 16, then 8 through a line of Commons, and it SURVIVED the round becoming a projectile. ProjectileService spends the same two numbers over the flight instead of along a ray, adding each body to the round's own ignore list as it goes |
| It bounces off walls and halves | **not modelled.** Scenery spends the pellet. A reflection solver for a weapon nobody aims at walls on purpose is not worth it, and the alternative — carrying on through the wall — is worse than not modelling it |
| A black 1×1×1 ball | `Vector3.new(1, 1, 1)` and BrickColor 26, exactly, on the round itself |
| Two-second pellet life | two seconds. At 165 that is 330 studs, past this weapon's own 300 of range, so it is a backstop rather than a limit |
| No team check — the pellet hurts your own side | the game's own friendly fire, 0.25 |
| Pogo — shoot the floor, go up | the `pogo` block, `directional = false`, capped. See `PogoProfile`. It fires on the pellet's IMPACT now rather than on the trigger, which is both correct and what the classic does — the pellet has to actually reach the floor |
| **`RELOAD = 6` — one pellet every six seconds** | **75rpm with a 12-round magazine.** The single biggest optimisation in the pack. Six seconds between shots is a duel timing; against a horde it is a weapon nobody would carry. It is still the slowest-firing sidearm in the game by a distance |

### Classic Rocket Launcher — `ServerLauncher.lua`, `RocketScript.lua`

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
| The servo: velocity = 7 × how far it has fallen behind a point one stud further along its nose, every frame | **75 studs/s, straight.** The servo settles at about 60 studs/s (one stud per frame at 60fps), which is the classic's real speed and is measurably slow. 75 is the "optimised for the game" nudge, written down: a brickbattle opponent walked at 16 studs/s and a Charger here covers 30 |
| The wobble the servo's overshoot produces | **not modelled.** A per-frame correction loop for every round in the air, to buy a cosmetic. It tumbles gently instead |
| Rocket jump fires on the trigger (the client's `COOLDOWN`) | fires on the DETONATION. A rocket jump is the blast lifting you, and the blast is now a second downrange — firing it on the pull would launch you off a rocket still in the air |
| `Swoosh` looping in flight | not yet. There is flight to swoosh through now, which there was not before; the sound is not wired |

### Classic Paintball Gun — `Paintball.lua`

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
| **It paints PEOPLE too** — a limb is well under the mass limit | **deliberately not.** A special infected is told apart at six paces by its colour, and a team that cannot tell a Boomer from a Common has lost the fight that colour was warning them about |

### The other three

`ClassicTimebomb`, `ClassicSuperball` and `ClassicTrowel` are not sold and not
wired in. The pass grants four and says four. A timebomb and a superball are
throwables and belong in ProjectileService beside the pipe bomb; a trowel builds
geometry and wants the barricade system. They arrive when their pipelines do,
and until then describing seven and selling four would be the lie.
