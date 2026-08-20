# Backlog

Captured 2026-08-20, not yet built. Roughly ordered by how broken each one is
rather than how big — a thing that traps the mouse is worse than a thing that is
merely missing.

---

## 1. Wiped-out screen traps the mouse on PC

**Bug, and the worst one here.** On the game-over / wiped-out screen the cursor
stays locked and nothing can be clicked, so a desktop player cannot leave the
screen the game just put them on.

Almost certainly the same shape as the menu fix already in
`MainMenuController`: `CameraController` re-applies `LockFirstPerson` whenever
survivor state changes, and `LockFirstPerson` pins the cursor to the centre of
the screen. The menu solves it by dropping `player.CameraMode` to `Classic`
while it is open (`MainMenuController` around the `restore.cameraMode` lines);
the results screen evidently does not.

Check `NO_CHARACTER_STATES` in `CameraController` — it is `{Dead, Spectating}`,
and a team wipe may not put every player into one of those.

## 2. Jump does not work on iPad

Reported by a real player on an iPad. The jump button was reworked on
2026-08-20 (bigger, moved to the bottom row, Roblox's duplicate suppressed), so
**re-test before investigating** — this report predates that change.

If it is still broken on iPad specifically, suspect `Device`: an iPad now
classifies as `Tablet` rather than `Mobile`, and anything that gates the touch
pad on a `Mobile` comparison instead of `Device.isHandheld()` would hide it.
`InputController`'s `initialScheme` is a separate detection from `Device` and is
what decides whether the touch scheme is drawn at all — that is the first place
to look.

## 3. Mobile has no button for interacting

Reviving a teammate, opening an ammo crate and taking a medkit are all the
`Interact` verb, and the touch pad has a USE button for it — but it is
`CONTEXTUAL`, so it only appears when `PromptController` reports a target.

Worth confirming per case: does the prompt fire for a downed teammate, for a
crate, and for a kit? If any of those three does not raise a prompt, the button
never appears and that action is unreachable on a phone. Reviving is the one
that matters most: a mobile player who cannot revive is a liability to the team.

## 4. Difficulty only changes incoming damage

`SettingsConfig.Difficulty` is one knob — `incomingDamage` at 1.0 / 0.7 / 0.45.
Every difficulty kills zombies equally fast.

Wanted: a harder setting where infected are harder to KILL, not just hitting
harder. That is a second knob (outgoing damage, or infected health) and it needs
a decision first — this is a per-player setting, and per-player infected health
does not exist on a shared server. Options are per-player damage dealt, or
promoting difficulty from a personal setting to a lobby vote. **Decide before
building.**

## 5. Map vote is at the wrong moment

Today it runs at the end of a round. Wanted: after choosing a game mode and
landing in a **fresh** server, the vote happens there; an established server
keeps voting at the end of the round.

So the trigger is "this server has just been created for us" rather than "the
round ended", and `MatchmakingService` is what knows which of those happened.

## 6. Countdown after choosing a game mode

Choosing a mode currently matchmakes immediately. Wanted: a visible countdown
first, so matchmaking has time to find or create a server AND the player has
time to walk through the shop, loadout and gunsmith before it takes them.

Note this is in tension with the main menu's PLAY → mode → matchmake flow: the
countdown has to be cancellable, or opening the shop has to pause it, or players
will be pulled out of a menu they just opened.

---

## Gore

### 7. Shoot limbs off properly

Dismemberment exists (`GoreConfig.Dismemberment`, `Severable`) but the ask is
for it to read as real: legs and arms coming off from concentrated fire on that
limb, rather than as a threshold effect.

### 8. Vital organs

Repeated hits to the same vital area should be able to kill on their own.
`GameConfig` already maps rig part names onto hit regions for the headshot rule,
so the region vocabulary exists — this is a new accumulator per region rather
than a new system.

### 9. Bodies should last 35 seconds

Corpses currently go quickly. Wanted: **35 seconds** before a body disappears.

`GameConfig.Corpses.MaxRagdolls = 26` is a COUNT, not a time — the oldest is
recycled once 27 bodies exist. At a horde's kill rate 26 bodies is a few
seconds, so raising the time also means raising or rethinking that ceiling, and
that ceiling is there for the frame rate. On mobile this fights the work done on
2026-08-20 directly. Likely answer: a real lifetime, with the count as a
per-device ceiling underneath it (`Device.pick`), so desktop gets 35s and a
phone gets 35s-or-fewer-bodies.

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
