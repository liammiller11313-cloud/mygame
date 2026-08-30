# Decisions

Half the landmines found while surveying the codebase this game harvests from
were the same shape: one half of the code assumed X and the other half assumed
not-X, and nothing recorded which was meant. This file is the cheapest defence
against recreating that.

Every entry says what was decided, when, and — the part that matters in six
months — **why**, and what it would cost to change.

---

## D1 — Brickbattle Ultimate gets its own repository

**Decided 2026-08-30.**

The code this game harvests from (`liammiller11313-cloud/mygame`) is a Left 4
Dead 2-style co-op zombie shooter called Fading Light. That repository's default
branch *is* that game; it is not a neutral container. Rojo also builds one place
per project file, and its cross-reference auditor encodes that game's specific
service conventions, so two games in one tree means every check has to know
which game it is checking.

The genuine overlap turned out to be about 3–5k lines out of 77k, all of it
infrastructure. That is a copy-once-and-then-edit, not a shared library worth
keeping in sync.

**Cost to change:** low now, high later. Merging the two trees after either has
moved is a manual reconciliation of two divergent config layers.

## D2 — The new place lives in the OLD game's experience, not a new one

**Decided 2026-08-30.** This is the one decision here that cannot be undone.

`DataStoreService` is scoped per-experience. A brand-new experience cannot read
the old one's stores — not with a key, not with an id, not ever. Publishing new
would make every player's Tix, level, quest progress, weapon upgrades and
inventory unreachable permanently.

So a migration path from the old save schema into the new profile format is
**possible**, and it is the one piece of code that must exist and be correct
before the first player joins the new place. A version field is dispatched on
from the very first write; adding one after profiles exist is not cleanly
possible.

**Cost to change:** irreversible after publish. There is no recovery.

## D3 — Death is a timed respawn at your own team's spawn

**Decided 2026-08-30.**

Not instant, and not out-until-the-round-ends. The third option was costed and
rejected for now: being out until the round ends needs a spectator camera, a
scoreboard state, an input-suppression contract and a re-entry path, none of
which exist in anything being harvested.

Respawns go to the dead player's own team's spawn, never a shared one — the
failure this avoids is respawning in front of an enemy holding a rocket.

**Cost to change:** low for instant-respawn (a constant). High for
out-until-round-end (it is a feature, not a setting).

**Open:** the exact respawn delay in seconds. Needs the gameplay video.

## D4 — Friendly fire ON, players do NOT collide, rocket jump does NOT self-damage

**Decided 2026-08-30.** Three answers that each change code in more than one place.

- **Friendly fire is on.** You can damage your own teammates. Worth stating
  loudly because the inherited damage funnel blocks *100%* of player-on-player
  damage by default, and a blocked pipeline looks exactly like a broken one.
- **Players do not collide with each other.** Teammates walk through each other.
  So there are no per-team collision groups — one fewer moving part, and it
  removes the classic body-block-in-a-doorway grief vector.
- **Rocket jumping does not hurt you.** Radius damage, falloff and knockback all
  still apply to *other* players; the shooter takes the impulse without the
  damage. Rocket jumping is a movement tool here, not a trade.

**Cost to change:** low, all three. Each is a branch in one funnel plus a
collision-group registration at boot.

## D5 — The 2008 look means palette and typeface, not chrome

**Decided 2026-08-30.**

Right colours, right font, classic proportions — a config swap in `UITheme`.
Explicitly *not* the full classic chrome: bevels, gradients, image buttons and
rounded blue-grey frames would be new code rather than configuration, because
the widget layer being harvested has no image primitive at all, sets
`BorderSizePixel = 0` on everything, and fixes corner radius at 2.

**Cost to change:** moderate and it grows. Each screen drawn against the flat
widget set is a screen to revisit if we later want real chrome, so if the answer
is going to change, it should change before stage 3.

---

# Open questions

Nothing below is decided. Each one is here because guessing costs a rebuild.

| # | Question | Blocks | Why it cannot just be guessed |
|---|---|---|---|
| Q1 | **Attribute name prefix.** `BBU_` is currently a single constant in `Shared/Net/Attributes.lua`. | Nothing yet — deliberately | The old place runs HD Admin, a Realism Mod and a Slap Battles glove kit, any of which may already write attributes. A collision silently corrupts state rather than erroring. Grep the export for `SetAttribute` before locking it. Because it is one constant, the rename stays a one-line edit. |
| Q2 | **Max players per server.** | Round config, audio voice budget, projectile cap, spawn spacing | Sizes four separate tuning tables. The inherited projectile cap of 12 was sized for four co-op players; ten players with rocket launchers is a different game. |
| Q3 | **Does a dead body ragdoll, or break joints the classic way?** | Death presentation | ~450 lines of ragdoll to harvest versus deleting the file. Roughly the same effort either way, so it is worth asking rather than defaulting. Joint-break is Roblox's default, is free, and ragdoll can be added later without undoing it. |
| Q4 | **Is the classic hotbar custom UI or the built-in backpack reordered?** | One Rojo property, and whether the hotbar is built or left alone | The old place contains *both* a `ClassisHotbar.client.lua` and a `ClassicHotbarOrder`, which is genuinely ambiguous. `ResetPlayerGuiOnSpawn=false` is currently set (right for a persistent Tix counter), but the old LocalScripts were written under the default `true` and may assume they re-run every spawn. |
| Q5 | **Do the classic tools animate?** | Whether an AnimationConfig and a player-side animator are needed at all | Many 2008-era Tools just use `Tool.Grip` and Roblox's built-in `ToolSlash`. If so this is free; if not it is a config plus an animator, and it belongs in a stage budget rather than surfacing as a surprise. |
| Q6 | **Which maps in `ServerStorage.Maps` are still wanted, and does each stand alone?** | The map roster | The roster is closed by design — a model with no config entry is invisible to the vote forever. And if two maps are positioned relative to each other rather than each sitting at its own origin, cloning one into the world needs a pivot step. |
| Q7 | **Gamepass ids, and whether each grant is persistent or session-only.** | Every Robux path | There are *zero* MarketplaceService, GamePass, ProcessReceipt or PromptPurchase references in the 77k lines harvested from, so this is written from nothing, receipt idempotency included. A pass granting something permanent lands in the saved profile; a session-only one is a check on join. Different code, different failure modes. |
| Q8 | **Intended Tix click rate.** | The server-side throttle | The only economy number that is not recoverable from the old code, because it is a play behaviour rather than a constant. |
| Q9 | **Is macOS the only dev machine?** | Four launchd-only helper scripts | They are pure convenience and refuse to run elsewhere. If no Mac is in the loop they should be dropped rather than shipped dead. |
