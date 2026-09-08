# Backlog

Captured 2026-08-20, reviewed 2026-09-06. Roughly ordered by how broken each one
is rather than how big — a thing that traps the mouse is worse than a thing that
is merely missing.

> **2026-09-06 was a bug-fixing day and it has its own section at the bottom.**
> Three player reports went in and eleven defects came out, because every one of
> the three turned out to be a symptom of something other than what it looked
> like. If you read one thing from it, read *What kept going wrong* — the same
> mistake is behind most of them.

Six of the original nine are built. They are kept at the bottom rather than
deleted, because "we tried that" is worth more than a shorter file, and because
each one names where the answer ended up.

---

## Still open

### 1. Jump does not work on iPad

Reported by a real player on an iPad. The jump button was reworked on
2026-08-20 (bigger, moved to the bottom row, Roblox's duplicate suppressed), so
**re-test before investigating** — this report predates that change.

Two of the three suspects have since been ruled out by reading rather than by
testing, so if it reproduces, start at the third:

- **Not the pad being hidden on a tablet.** `TouchController` gates on
  `InputController:isTouchScheme()`, which is the scheme rather than the device
  class, so an iPad with no keyboard gets the pad like any phone.
- **Not a `Device.pick` table that forgot `Tablet`.** Every call site in the
  codebase lists it, and `CHEAPER_THAN` covers one that did not.
- **Still unexamined: the suppression itself.** `suppressRobloxJump` hides
  Roblox's own JumpButton and re-hides it whenever it comes back. If Roblox
  draws a differently-named button on iPadOS, ours would be the only one on
  screen — which is the working case — but if the geometry differs, ours may be
  landing off the safe area. That is the thing to photograph first.

### 2. An Apex boss is not actually any bigger

Found on 2026-09-05 while sizing the Metallic, and **left alone on purpose** —
fixing it changes how the finale looks, which is a design decision rather than a
repair.

`EliteTiers.Apex` asks for `scale = 1.12`, and `RigUtil.scaleRig` applies scale
by writing the Humanoid's `BodyHeightScale` and friends. `PlaceholderFactory`'s
`adoptRig` deletes exactly those NumberValues from every template, deliberately,
so that spawning cannot scale a rig a second time on top of the geometry pass it
already did. So the Apex's health and damage land and its size silently does not.

Whoever picks this up has to decide what an Apex should be. If it should be
visibly bigger, the scaling has to happen the way `scaleRigGeometry` does it —
on the parts, at spawn, on the clone rather than the template. If a tougher Tank
of the same size is fine, then `EliteTiers.scale` is a field that lies and should
go, and the tier's outline colour is doing the "this one is different" job on its
own. Say which in the tier's comment either way.

### 3. Difficulty only changes incoming damage

`SettingsConfig.Difficulty` is one knob — `incomingDamage` at 1.0 / 0.7 / 0.45.
Every difficulty kills zombies equally fast.

Wanted: a harder setting where infected are harder to KILL, not just hitting
harder. That is a second knob, and the decision it needs is which one, because
difficulty is a PER-PLAYER setting and per-player infected health does not exist
on a shared server.

The cheap answer is a per-player `outgoingDamage` multiplier: the same zombie
takes more shots from a player who asked for that, needs no shared state, and
reads as "harder to kill" from the only seat that matters. The honest answer is
promoting difficulty out of personal settings into a lobby vote, which is a
bigger change and makes the whole team agree. **Decide before building.**

---

## Gore

### 4. Shoot limbs off properly

Dismemberment exists (`GoreConfig.Dismemberment`, `Severable`) but the ask is
for it to read as real: legs and arms coming off from concentrated fire on that
limb, rather than as a threshold effect.

### 5. Vital organs

Repeated hits to the same vital area should be able to kill on their own.
`GameConfig` already maps rig part names onto hit regions for the headshot rule,
so the region vocabulary exists — this is a new accumulator per region rather
than a new system.

---

## Built since this list was written

### The pogo, on this game's terms — **built**

The pack's own movement tech, and the only reason it is not a re-upload of
Roblox's classics. Shooting a surface throws you off it: the slingshot stomps
down and goes up, the rocket shoves you away from wherever it landed.

**It needed no remote at all**, and that is the whole design. The standalone
pack needs one because a classic Tool has no server-side shot to hang off — the
client says "I aimed there" and the server can only re-cast the ray and hope
they agree; half of `packs/BrickbattlersPack/PogoServer.lua` is that defence.
None of it applies here. `BallisticsService` has already validated the shooter,
checked the claimed origin against their real head, generated the cone from a
shared seed, and cast the pellets itself. The launch point is not a claim, it is
where the **server's own raycast landed**. An exploiter cannot pogo without
firing, and the rate limit is the weapon's rate of fire and the rounds in it.

The hook sits **outside** the pellet loop, unlike the blast hook beside it. A
blast per pellet is a hypothetical multi-pellet launcher exploding once per
pellet, which is arguably right; a launch per pellet is a shotgun-shaped pogo
weapon throwing its user into orbit for one trigger pull, which is not.

### The cap is the point, and it is nine jumps high

`maxUpSpeed` exists in `PogoCore` for the standalone pack and is off there —
1600 studs a second at twelve stacks IS brickbattle. Here it is 160, and the
reason is specific: `SpawnPlacement` puts hordes ahead of the team using a flow
window, and `LevelService:getFlowDistance` answers it by projecting a position
onto a polyline. A survivor two hundred studs above the map projects somewhere
meaningless, so the Director stops aiming at them and starts aiming at nothing.
Unbounded flight does not just let one player leave a level — it quietly stops
the round working for everyone else on the server.

160 is about 65 studs of height against a survivor's own 7.2-stud jump. Nine
jumps. A rooftop.

The stacking is also tamer than the pack's, and honestly so: hanging the pogo
off a real weapon's rate of fire means the slingshot's 75rpm leaves eight tenths
of a second between shots, so you are already falling when the next lands and
the pack's compounding never gets going. The stack became a bonus for a quick
follow-up rather than a ladder. That is the right shape for this game.

### Two things caught while writing it

**A guard that waved everyone through.** The pin check was written as
`typeof(survivors.isUpright) == "function" and not survivors:isUpright(player)`
— and there is no `isUpright` method. A missing method makes the whole condition
false, so the guard did not merely fail to protect: it let *every* pinned player
pogo, silently, in the exact shape that looks careful. It asks `getState` now.

**And the ownership problem again.** The server writes velocity to a root the
player's own client owns — the same thing the Tongue's drag got wrong. An
impulse survives that better than per-frame position writes did, which is
exactly why it was tempting to skip; it is still a coin flip under latency, and
a pogo that silently does nothing one time in five is worse than half a second
of server simulation every time. Taken and handed back like `Support.launch`
does for a boss throw, tokened so chaining does not hand the root back
mid-flight.


### The pack goes through the pipeline, not around it — **decided**

The question was whether Brickbattler's Pack becomes real `WeaponConfig` weapons
going through `BallisticsService`, or stays classic Roblox tools doing their own
damage in their own lane.

**It goes through the pipeline, and the second option was never actually
available.** Not worse — broken. `DamageService` is what feeds `StatsService`,
which feeds `ProgressionService` and `EconomyService`. A tool calling
`Humanoid:TakeDamage()` directly means a paying player's kills earn them **no
XP, no quest progress, no Dollars, and no place on the scoreboard**. They would
also miss `headshotAlwaysKills` — the rule `WeaponConfig`'s own header calls
"the game: what makes a horde readable instead of spongy" — so a Common would
survive a headshot from the pack and die to every other gun in the roster.

Somebody pays a hundred Robux and gets weapons that feel wrong and pay nothing.
That settles it.

### Four of the seven, and the other three are not weapons

The pack is seven tools; four are weapons in the sense this game means. Forcing
the rest into a weapon block would be the wrong shape rather than a shortcut:

| | |
|---|---|
| **Timebomb** | A throwable. That pipeline exists — ProjectileService, a map family, an inventory slot — and it is where a planted bomb belongs, beside the pipe bomb it is a cousin of. |
| **Superball** | A thrown bouncing projectile with no barrel and no magazine. Same pipeline, different fuse. |
| **Trowel** | Builds geometry. Not a weapon in any sense; it wants the barricade system, not the ballistics one. |

`PassConfig.grants` says four, because selling four and describing seven is a
lie a storefront should not tell.

### Translated, not transplanted, and deliberately sidegrades

The pack's own numbers — 5, 8, 25 — are brickbattle numbers against a
hundred-health *player*. A Common here has fifty health and `damage` reads as a
shots-to-kill count, so a literal port makes the paintball gun a ten-shot kill.
What is preserved is the relationship between them: the paintball sprays and
barely stings, the slingshot is one flat precise shot, the sword is fast and
close, the rocket removes a doorway.

Every one is a **sidegrade**, and that is a fairness rule rather than a taste
one. The paintball gun trades the MP7A1's damage for rate; the slingshot trades
the Magnum's punch for a dead-flat trajectory and no recoil; the sword trades
the Machete's reach for speed; the rocket is a smaller RPG-7 that does not
delete a Tank. A hundred Robux buys **variety**, not a way past the Dollars
economy — the RPG-7 costs ten won rounds and would be worth nothing the day a
cheaper one could be bought with money. `placeable = false` on all four.

### Ownership is merged, never stored

`profile.owned` is the Dollars economy's set and `serialise` writes it to a
DataStore. Merging pass grants into it would put Robux entitlements in a save
file, where a failed write or a reset key takes away something somebody paid
for. So `unlockedSet` derives the union at every read — the `ProfileSynced`
payload and the three `sanitise` call sites — and `serialise` still writes the
stored set alone. Every screen that asks "do I own this" sees the merged answer
without learning there are two currencies.

`LoadoutConfig.candidates` needed no change at all: it already appended anything
in `WeaponConfig` the catalogue does not list, *"so a weapon that is somehow not
for sale is still equippable."*

### And `audit.py` learned a third way to own a weapon

Check 16 knew two: bought, or `floorOnly`. A pass-gated weapon is neither, and
the check correctly called all four unreachable. It knows `passOnly` now — and
does not take the flag on trust. It reads `PassConfig.grantsWeapons` and fails
in **both** directions: a weapon claiming `passOnly` that no pass grants, and a
pass granting something the roster does not have. Both were tested by breaking
them on purpose before the check was trusted.


### Nobody was ever told who won a Versus match — **fixed**

`_onRoundEnded` computed the match winner at the end of the final half and then
dropped it on the floor. The local was assigned, compared, and never read: scores
reset, sides kept, next match began, and no player was told anything. selene had
been flagging it as an unused variable the whole time, which is what an unused
variable usually means — not a spare name, a line that was meant to do something.

The per-HALF result was never broken: `_scoreHalf` records it and the payout
services read it through `wonLastRound`. The hole was only the verdict, which is
the part players came for.

It is announced per player rather than broadcast, because `SIDE_A` / `SIDE_B` are
`"A"` and `"B"` — internal names that never reach a client. The only side a player
knows about is their own, so the message is written from where they were standing:
**MATCH WON**, **MATCH LOST**, or **MATCH DRAWN**, with the scoreline either way.
It goes down the existing `Subtitle` channel that RoundService already uses for
"That's it. We held.", at six seconds rather than a wave callout's 3.2 — the end
of a two-half match earns more than a wave does.


### The Tongue's drag never had the physics to do it — **fixed**

The Smoker's whole creature is the drag: it grabs somebody out of a group from
a hundred and sixty studs and hauls them out of the fight. `stepReel` performed
that as a per-frame `victimRoot.CFrame` write — **on a root the victim's own
client owns**. The Charger already knew what that costs and says so in its own
words at `takeOwnership`: *"Nothing the server does to a character's velocity or
CFrame survives otherwise."* The Charger takes network ownership before its
carry. The Tongue never did. Its victim kept simulating from their own state and
replicated back over the top, so the reel was a tug-of-war it does not win, and
the likely end of every grab was `REEL_TIMEOUT` — six seconds, then let go.

The reel now seizes the root at `beginReel` and hands it back in `release`, the
one exit every phase already went through. Two details that are not tidiness:

- **Ownership is held for the whole pin, not just the drag.** Handing it back
  when the reel arrives is the tidier shape and it is the riskier one — the
  victim's client has spent seconds receiving positions it did not simulate, and
  its own last-owned state is from before the grab, so giving it authority back
  mid-pin invites a yank to where they were standing when the tongue landed.
  Nothing in the hold moves them, so there is nothing to buy.
- **The velocity kill is horizontal, with the Y clamped at zero.** Zeroing all
  three is the obvious way to write "drop the sprint they were carrying" and it
  is wrong: the reel only ever moves them in XZ, so a victim with no downward
  velocity *floats* across the gap they were dragged over. Gravity keeps what it
  earns; the clamp is what stops a jump being a counter this creature was never
  meant to have.

`SurvivorService:_clearPinFields` also hands the root back now, unconditionally,
because neither special's own release path covers the case where the special is
**despawned rather than killed** — `InfectedService:despawn` does not run
`onDeath`. The pin itself was already safe there (the heartbeat drops a pin whose
owner has gone); the ownership was not, and a survivor left server-simulated for
the rest of a round has no symptom except feeling bad. Same argument
`releaseLedge` makes ten lines up: one place that lets the body go without
something having to remember to.

### The line you were supposed to break was invisible — **fixed**

`Tongue.lua`'s header promises two counters, and `lineHolds` genuinely enforces
both on every frame of the reel and the hold: break line of sight, *or* put your
own body between the tongue and your friend. Nothing drew the line. A survivor
was dragged across a street by nothing at all, and the play the header describes
was one no player could see to make.

There is a beam now, from the creature's mouth to the victim's root, alive for
exactly as long as the pin. It is **dead straight on purpose** — `lineHolds`
tests a straight raycast, so a beam that sagged prettily would draw a line nobody
is playing against: a teammate steps into the curve, breaks nothing, and
reasonably concludes the counter is broken. What is drawn is the ray.

### Three of the four pins killed you in silence — **fixed**

A pinned survivor cannot free themselves. That is the design, and it makes the
rescue somebody else's job — which means the pin has to be findable by ear.

The Jockey already knew this: `stepRide` has a `RIDE_CACKLE_INTERVAL` and
vocalises the whole way. `Hunter.stepPin`, `Charger.stepPummel` and
`Tongue.stepHold` dealt exactly the same repeating damage and made no sound at
all, so a teammate two rooms away had a HUD marker and nothing to turn toward.
All three now carry the Jockey's pattern on their own existing vocal clock — a
Hunter cannot be stalking and pinning at once, so it is one creature to one voice
rather than a second timer each. `HunterClaw`, `ChargerPummel` and `TongueDrag`
are priority 8 in `AudioConfig`, above every idle: a call for help must not be
the sound the voice budget drops mid-horde.


### Mobile has no button for interacting — **fixed**

There was a USE button, contextual, in the bottom-right corner. It worked and
almost nobody found it: the thing that tells you an action exists was in the
middle of the screen and the thing that performs it was two hundred pixels away,
and a thumb goes to what it is reading.

**The prompt is the button now.** On touch it draws itself as a panel and takes
the tap — press holds `Interact`, lift releases it, so a tap picks a gun up and a
held thumb revives a teammate with the bar filling under the finger doing it. The
corner button stays, and still swaps to PING when there is nothing to use.

### Controllers were told to press E — **fixed**

Interact is bound to a keyboard key and a face button; `PromptController` walked
the bound keys and took the first one in the ASCII letter range, so it always
found E. Every console player in the game was told to press a key their machine
does not have, for a verb that did have a button.

The scheme-aware lookup HudController already had is now `UI/Glyph`, and both
callers use it. Interact also moved from **Y to X**, where Left 4 Dead 2 and
every console shooter since put it; Reload took Y. `audit.py` check 32 fails the
build on two verbs sharing a key, or on an essential verb with no pad button.

### Wiped-out screen traps the mouse on PC — **fixed**

Was the worst thing on this list. It had two halves and only the first was
originally understood.

`CameraController` writes `CameraMaxZoomDistance = 0.5` for any survivor who is
not Dead or Spectating, and Roblox forces first person — and a pinned cursor —
at that zoom whatever `CameraMode` says. A team wipe leaves everyone
*Incapacitated* rather than Dead, so the results screen came up over a 0.5 zoom.
`UI/FreeCursor` is the fix for that half: one owner for the rule, `restore`
tables per screen so they can nest.

The second half is that CameraController re-asserted first person on every
change of the player's state attribute, whether or not a screen was open — so
the round resetting state after the wipe took the mouse straight back. Three
controllers each carried a deferred re-take racing that handler, and the map
vote had none at all. FreeCursor now counts its holders and `applyCameraMode`
stands down while any screen holds the mouse.

### Map vote is at the wrong moment — **built**

`MapVoteService:_maybeOpenIdleVote` runs the same vote on a fresh server before
the first round, gated on `MapConfig.Vote.OnFreshServer` and on somebody having
actually claimed a mode — "the round state is Lobby" is true from boot, so the
naive version threw a vote over a player still reading the mode list.

### Countdown after choosing a game mode — **built**

The lobby waits for a mode to be claimed before it starts counting, and
`UI/LobbyClock` draws the remaining time above the shop and the loadout screen
(`UITheme.DisplayOrder.LobbyClock`) precisely so a player spending their dollars
can see how long they have.

### Bodies should last 35 seconds — **built, then reported again, then fixed properly**

The lifetime was never the thing to change: `GameConfig.Corpses.MaxRagdolls` is
a COUNT and at 26 it recycled every body within seconds of a horde landing.
`GoreService` now anchors a ragdoll once it has settled, so a corpse past its
first second costs draw calls and no physics or physics replication — which is
what made raising the ceiling to 48 affordable. `corpseLifetime` is 35 for a
Common. Not device-scaled, deliberately: corpses are replicated instances every
client shares, so one player's hardware must not decide how many bodies everyone
else sees.

**And it was reported again on 2026-09-06, with a completely different cause.**
Worth recording because the second investigation nearly went the same way as the
first: three of four angles came back with "the corpse ring is fine", and it
was — the bodies were never being created. An ordinary headshot on a Common
*gibbed*, and `gib()` deletes the model.

Two gates fired, both because a Common has 50 health and a head hit is
multiplied by four. Any gun doing 24 damage or more overkills it by 46 on a
headshot — 24 of the 35 weapons, including the UMP-45 every player spawns with —
and its `gibThreshold` of 45 read as "past which the body comes apart" while
meaning "any headshot". Meanwhile `overkillRatio` was uncapped, so on the
smallest body in the game it sat between 0.9 and 6.6, drowning the weapon,
region and range terms that total at most 1.5. Now 200 and capped at 0.5, which
cuts the Common's gib cases from 199 to 105 across the whole roster.

The lesson both times is the same and is why this entry is long: **a symptom
about bodies disappearing is not evidence about corpse lifetimes.** Twice the
number in the config named after the symptom was innocent.

### Ledge hanging was built and unreachable — **fixed**

Raised 2026-09-05, closed the same day. `SurvivorService:ledgeHang` was a
complete feature — the state, the pull-up prompt, the drain, the countdown, the
HUD line, the crosshair and ability lockouts, all three config numbers — that
nothing anywhere called, so no survivor had ever hung off anything.

The missing piece was a trigger, and `Level/LedgeService` is it: a designer tags
a part `FL_LedgeCatch` along a lip and anything falling through it is caught.
Two things about the build worth keeping:

- **It is arithmetic, not a raycast.** The obvious version is an invisible part
  you raycast against, and it is a trap: an invisible part a ray can hit is one a
  bullet can hit, so the feature would have hung an invisible wall in front of
  every marked drop. Testing the box in Lua lets the volumes be `CanQuery = false`
  and untouchable by anything in the physics world.
- **Being inside the box is not enough — you have to be below the lip.** A catch
  volume laid along an edge overlaps the walkway beside it, and an eighth of a
  second after a jump you are descending fast enough to pass the falling gate
  while still entirely on the ledge. Modelling it showed hopping near an edge
  grabbed you; one comparison fixed it.

### Bosses were a schedule you could memorise — **built**

Two days on the bosses, 2026-09-04 into 2026-09-05. The Metallic exists
(`Specials/Metallic`), the Tank no longer plays the same every time, and which
boss a wave sends is a roll rather than a row in a table. `docs/BOSSES.md` is the
whole of it; `GameModeConfig.rollBosses` is the one function that decides what
walks in.

The size problem turned out to be the interesting part. `scale` is a multiplier
on whatever the artist built, which is fine for a roster of standard humanoid
rigs and meaningless for a boss delivered at whatever size seemed right — the
number that makes a normal rig into a Tank makes an already-giant rig into
something that cannot follow a team indoors. Definitions can now state a
`targetHeight` instead and the pipeline measures and solves for it, so the
Metallic is seventeen studs regardless of what lands in the folder. The boot line
prints every boss's finished size and warns by name if one stands more than 1.35
times a Tank — a ratio rather than a clearance in studs, because the first
absolute written there was arithmetic on the grey-box rigs and fired on the Tank
itself the first time it ran on a real place.

---

## The 2026-09-06 pass

Three reports from playing the game: a pipe bomb that could not be thrown,
zombies that vanished when shot, and audio that broke around adrenaline. None of
the three was what it looked like.

### What kept going wrong

**A number was measured against the wrong thing, and prose was believed instead
of code.** Nearly every defect below is one of those two.

- The boss clearance check fired on the Tank, because 15 x 8 was arithmetic on
  the grey-box rigs and every real rig is an artist's. It is a ratio against a
  measured Tank now.
- The Metallic was sized "a third taller than a Tank" against a Tank that does
  not exist. 14 studs was x1.03 of a real one — the same size, which is the one
  thing a second boss must not be. Now 17.
- The Common's `gibThreshold` of 45 read as "past which the body comes apart"
  and meant "any headshot", because nobody checked 45 against 50 health and a
  4x head multiplier.
- `overkillRatio` was unbounded, so on the smallest body in the game it was a
  constant rather than a variable. `GoreService`'s own `CUT_PRECEDENCE` note had
  **noticed** this and routed around it rather than fixing it.
- Five map-item warnings fired on every boot because a comment asserted that
  services register after `init()`. They register before it.
- `MapItemService`'s header said dying leaves your items in the world. It
  destroys them.
- `InventoryService.pickup`'s comment promised nothing is ever silently
  destroyed while ignoring the return value that says whether it was.
- `dismemberable` answered two questions at once, so the Boomer — three comments
  call bursting its whole identity — was the only special that could not burst.

### Fixed

| | |
|---|---|
| Throwables | the fire button throws, aimed down the camera; controller and touch get a throw for the first time |
| Bodies | ordinary kills ragdoll instead of gibbing — Common gib cases 199 → 105 |
| Boomer | can burst at all, which it never could |
| Adrenaline | no longer kills an in-flight reload; sprint footsteps read the right flag |
| Audio | reloads, gunshots and melee swings no longer reach the player who made them twice |
| Map items | spawn points refill after a throw, a teammate heal, a defib and a death |
| Medkits | a pickup whose drop cannot be built is refused rather than eating your kit |
| Bosses | measured against a Tank, like against like, width reported and not asserted |
| Versus | the spawn button passes the chosen kind, so it stops asking for a Metallic-sized hole |
| Menu | the backdrop is an image id, and `ImageCheck` can now tell an image from a decal |
| M1A EBR | reaches cut precedence, which `0.95 - 0.45 < 0.5` had been quietly denying it |

### The eight-area hunt

Run after the fixes above, across service lifecycle, remotes and attributes,
state machines, the Director, the interface, economy and progression, combat
edges, and half-wired features. Forty-seven findings; the seven ranked highest
were all real, and one of them was a bug this same day's work had introduced.

Worth keeping from it, because it is the same lesson twice more:

- **A phantom survivor blocked every team wipe.** Leaving the match only cleared
  the survivor record while a round was *running* — and Victory, TeamWipe and
  Lobby all report it is not, which is exactly when the results screen fires it.
  Records outlive rounds. Treating "a round is running" as "a record exists" is
  what did it.
- **The wave boss was dropped forever** on a failed placement, under a comment
  saying something else would re-offer it. That something returns on its first
  line in wave mode.
- **`dismemberable` was answering two questions**, so the Boomer — three comments
  call bursting its whole identity — was the only special that could not burst.
- **The M1A EBR missed cut precedence by 6e-17**, because `0.95 - 0.45` is not
  `0.5` in binary.

Twenty of the forty-seven were stale comments, and four of the morning's bugs
had been *described accurately by a comment* and shipped anyway. That is the
single strongest argument in this file for treating prose as code.

### Still open

- **`InfectedPoseController`** holds its cull and stride bands as literals, and
  duplicates the desktop defaults between module scope and `adoptDeviceBands`.
- **The ammo-crate broadcast has no consumer.** The server sends which crate
  went, its index and its respawn time to everybody; the only handler reads one
  field for one player. A burned crate is information the team needs, and the
  wire already carries it.
- **Three audio cues are defined with real ids and never played** —
  `UI.MenuPage`, `WeaponReload.Bolt`, `Gore.Squelch`.
- **Two files are near Luau's 200-locals-per-scope ceiling** — `MainMenuController`
  at 181 and `ViewmodelController` at 167. Both compile. The fix is splitting
  them, not shaving names, and it is a job on its own.

### The second half of the day, and its own pattern

The morning's theme was a number measured against the wrong thing. The
afternoon's was narrower and stranger: **a system reading back its own
assumption and reporting it as a measurement.** Four separate bugs, one shape.

- **The invented muzzle answered the facing question.** Every weapon is
  guaranteed a `Muzzle`, invented at the model's -Z end when the art ships none.
  The facing check looks for a muzzle first, found that one, and concluded the
  barrel runs down -Z. So no supplied model without a hand-placed muzzle was
  **ever** straightened, and the warning that would have said so could not fire
  either. A shotgun modelled barrel-up was held barrel-up, silently, for weeks.
- **`BorderBright` was byte-for-byte `Accent`,** with a comment calling it "the
  accent, used as a rule". Four screens used the pair as a ladder — the hotbar,
  the map vote, the loadout, requisitions — so in every one of them two states
  the code believed were distinct rendered identically.
- **The boot banner's asset line was computed before the modules loaded,** so it
  reported what was in the folders while `PlaceholderFactory` four lines above
  reported what the game ended up with. Its own comment claimed the two "can
  never disagree". They disagreed by 22 viewmodels.
- **And the diagnostic written to catch the first of these had the same bug.**
  `ensureGrip` returns early for a model with its own `Grip`, before the line
  that records the verdict — so the report filed the *previous* weapon's answer
  under this one's name. Caught in the end-of-day sweep, before anybody trusted
  it. A diagnostic that confidently reports the wrong gun is worse than none.

The lesson is cheap to state and was expensive four times: **a thing you
generated is not evidence.** Mark it, or do not read it back.

### Also that afternoon

- The **bile jar** was retired — the hazardous waste replaced it rather than
  joining it — and **Boomer bile was found never to reach the screen at all**:
  `applyBile` set an attribute no client reads, and the only sender of the green
  wash was the jar's coat path. The Boomer's entire threat had never worked.
- A **console player fell through the floor on join**. Not streaming — network
  ownership: the client gets its character before it has the map, simulates a
  fall with no floor, and the server takes it because the client is the owner.
  The root is held until that client reports ready.
- **A PS5 touchpad click flipped the game to keyboard glyphs**, and forced
  gamepad selection fought the cursor. Both fixed.
- **Dual pistols became two guns in two hands**, in both views.
- **Every supplied gun was held by its geometric middle** — `ensureGrip`
  measured a 0.4-stud invented cube instead of the model, so both offsets
  collapsed to a tenth of a stud.
- **`scripts/remotes.py`** now checks all 84 remotes have both ends wired, and
  the config-key audit went from 3 modules to 15.
- **The UI's two failing contrasts were measured and fixed** — `TextDim` at
  2.73:1 and `Border` at 1.47:1 — and the panels got quarantine tape, dirtier
  surfaces and a frame you can see.

---

## Deleted rather than built

### The Director's ambush and fake-out — **config removed 2026-09-06**

Configured, tuned per temperament, and unreachable: `DirectorConfig.Ambush`
(seven fields), `DirectorConfig.Fakeout` (four), an `ambushChance` and a
`fakeoutChance` on all six temperaments, and `shouldAmbush` / `shouldFakeout` /
`rollFakeoutDelay` that nothing ever called. There was no dormant-spawn concept
anywhere in the Director for the first to drive, and no build-up to cancel for
the second.

It is deleted rather than wired up, and the argument it made is kept here
because it is a good one and whoever builds this should start from it:

> **AMBUSH** — a group placed silently ahead of the team, dormant until they are
> close, instead of walked in from behind. This is the single biggest thing the
> base pacing machine lacks. A trickle that always arrives from behind is
> learnable within one round; a crowd that was already waiting in the building
> you are about to enter is not, and it is how Left 4 Dead makes a corridor
> frightening on the second playthrough.
>
> **FAKE-OUT** — a build-up that deliberately does not deliver. The horde audio
> rises, the population ticks up, and then it stops — and lands thirty seconds
> later when the team has decided it was nothing. Used sparingly: a Director
> that cries wolf constantly just teaches players to ignore the cue.

The numbers it was tuned to, for the same reason: ambush groups of 6-16 placed
90-260 studs along the team's own direction of travel, waking inside 46 studs,
giving up after 75 seconds so a team that never goes that way does not leave a
frozen crowd in the level, one at a time. Fake-outs delayed 14-34 seconds, the
real one 1.25x harder for having been doubted, one per wave.

**Why deleted:** tuned constants for a feature with no code path are worse than
nothing. They read as a system that exists, they survive review because they
look considered, and the next person to touch the Director budgets around a
layer that has never once run. The two paths are a real feature and a real
piece of work; when somebody does it, this entry is the brief.

---

## Answered, no work needed

**Using a medkit on yourself, on keyboard:** press **4** to take the kit out,
then **H** to use it. `H` is `Action.UseItem` in `InputController`'s keymap.
Pressing **4 twice** also works — a consumable slot uses itself when selected
again — and as of 2026-08-20 both paths send the slot you asked for rather than
the one the server had last confirmed, which is what used to make a quick
"4 then H" do nothing.

This is not discoverable. Worth putting on the HUD next to the kit, or in the
settings keybind list, rather than leaving it to be found.
