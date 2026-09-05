# Backlog

Captured 2026-08-20, reviewed 2026-09-05. Roughly ordered by how broken each one
is rather than how big — a thing that traps the mouse is worse than a thing that
is merely missing.

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

### Bodies should last 35 seconds — **built**

The lifetime was never the thing to change: `GameConfig.Corpses.MaxRagdolls` is
a COUNT and at 26 it recycled every body within seconds of a horde landing.
`GoreService` now anchors a ragdoll once it has settled, so a corpse past its
first second costs draw calls and no physics or physics replication — which is
what made raising the ceiling to 48 affordable. `corpseLifetime` is 35 for a
Common. Not device-scaled, deliberately: corpses are replicated instances every
client shares, so one player's hardware must not decide how many bodies everyone
else sees.

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
Metallic is fourteen studs regardless of what lands in the folder. The boot line
prints every boss's finished size and warns by name if one is past the 15 × 8
the maps are laid out to pass.

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
