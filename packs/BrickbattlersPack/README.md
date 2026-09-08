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

Set a **`PogoProfile`** string attribute on each pogo tool: `Slingshot` on
`ClassicSlingshot`, `Rocket` on `RocketLauncher`. Unset falls back to `Rocket`.

`PogoCore` is one module rather than a copy per tool because the copies had
already drifted — the rocket's cooldown was `0.28` on the client and `0.25` on
the server, so the client's limit was decoration and the server's was the real
one.

The remotes (`PogoRequest`, `PogoVerdict`, `RocketFire`, `PlaceWall`) are
created by the server scripts if missing. Do not add them by hand.

**Delete afterwards:** `SlingshotPogo` (replaced by `PogoClient`), and the
`MouseLoc` RemoteFunction in `ClassicTrowel`.

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
ship one. The trowel's is replaced by a client→server RemoteEvent; the other two
still have theirs.

**`brick:MakeJoints()`** welds each brick to whatever it touches — including a
character standing where the wall goes. The bricks are anchored instead.

Also: unvalidated `Vector3` arguments reaching `.Unit` (a NaN or zero vector puts
a part at an undefined CFrame), the debug `print`s in `SlingshotPogo`, and an
unbounded build loop that advanced `x` from the size of the brick it had just
made.

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
