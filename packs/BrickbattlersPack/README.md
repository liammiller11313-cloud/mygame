# Brickbattler's Pack — script fixes

Corrected versions of the tool scripts from Brickbattle Ultimate. The behaviour
and the tuning are unchanged; what changed is who is allowed to ask for it.

Nothing here is wired into Fading Light yet — these are standalone Roblox Tool
scripts. `check.sh` parses and lints them, but `audit.py` does not look at them
because they reference no game module.

## Where each file goes

| File | Class | Parent |
|---|---|---|
| `PogoCore.lua` | ModuleScript | `ReplicatedStorage` |
| `PogoServer.lua` | Script | inside each pogo tool |
| `PogoClient.lua` | LocalScript | inside each pogo tool |
| `ServerLauncher.lua` | Script | inside `RocketLauncher` |
| `LocalLauncher.lua` | LocalScript | inside `RocketLauncher` |
| `WallMaker.lua` | Script | inside `ClassicTrowel` |
| `WallMakerClient.lua` | LocalScript | inside `ClassicTrowel` |
| `Slingshot.lua` | Script | `ClassicSlingshot` — replaces `Slingshot` |
| `SlingshotClient.lua` | LocalScript | `ClassicSlingshot` — replaces `Client` |
| `CannonScript.lua` | Script | `ClassicSuperball` — replaces `CannonScript` |
| `SuperballClient.lua` | LocalScript | `ClassicSuperball` — replaces `Client` |
| `PelletScript.lua` | Script (Disabled) | `ClassicSlingshot` — replaces `PelletScript` |
| `CannonBall.lua` | Script (Disabled) | `ClassicSuperball` — replaces `CannonBall` |
| `RocketScript.lua` | Script (Disabled) | `RocketLauncher` — replaces `RocketScript` |
| `Paintball.lua` | Script (Disabled) | `ClassicPaintballGun` — replaces `Paintball` |
| `Bomb.lua` | Script (Disabled) | `ClassicTimebomb` — replaces `Bomb` |

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
shipped one. All three are now client→server RemoteEvents.

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
