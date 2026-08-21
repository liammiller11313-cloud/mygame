# Backlog

Captured 2026-08-20, reviewed 2026-08-21. Roughly ordered by how broken each one
is rather than how big — a thing that traps the mouse is worse than a thing that
is merely missing.

Four of the original nine are built. They are kept at the bottom rather than
deleted, because "we tried that" is worth more than a shorter file, and because
each one names where the answer ended up.

---

## Still open

### 1. Jump does not work on iPad

Reported by a real player on an iPad. The jump button was reworked on
2026-08-20 (bigger, moved to the bottom row, Roblox's duplicate suppressed), so
**re-test before investigating** — this report predates that change.

If it is still broken on iPad specifically, suspect `Device`: an iPad now
classifies as `Tablet` rather than `Mobile`, and anything that gates the touch
pad on a `Mobile` comparison instead of `Device.isHandheld()` would hide it.
`InputController`'s `initialScheme` is a separate detection from `Device` and is
what decides whether the touch scheme is drawn at all — that is the first place
to look.

### 2. Mobile has no button for interacting

Reviving a teammate, opening an ammo crate and taking a medkit are all the
`Interact` verb, and the touch pad has a USE button for it — but it is
`CONTEXTUAL`, so it only appears when `PromptController` reports a target.

Worth confirming per case: does the prompt fire for a downed teammate, for a
crate, and for a kit? If any of those three does not raise a prompt, the button
never appears and that action is unreachable on a phone. Reviving is the one
that matters most: a mobile player who cannot revive is a liability to the team.

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
