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
