# Walrus PvP — ability prototype

Four standalone scripts you paste into Roblox Studio. No Rojo, no toolchain,
no project structure — copy the file contents into the right kind of object
in the right place and it runs.

## Where each script goes

| File | Goes in | Kind |
|---|---|---|
| `WalrusLeaderboard.lua` | ServerScriptService | **Script** |
| `AbilityServer.lua` | ServerScriptService | **Script** |
| `AbilityClient.lua` | StarterPlayer → StarterPlayerScripts | **LocalScript** |
| `EquipPad.lua` | inside a Part in the Workspace | **Script** |

Script vs LocalScript matters. A LocalScript's changes only exist on one
player's screen — nobody else would see them.

## How it fits together

The leaderboard is the source of truth. `WalrusLeaderboard` gives every player
a `leaderstats` folder holding **Equipped** (a StringValue) and **Kills** (an
IntValue), which is what Roblox draws as the Tab-key list.

An `EquipPad` is any Part with the script inside it. Clicking it writes its
`ABILITY_NAME` into that player's Equipped value, and that is the whole of
equipping — there is no inventory, no separate state to keep in sync.

`AbilityClient` fires a RemoteEvent when you press **E**. That is all it does.
It never says who it hit or how much damage to deal, so a modified client can
only ask to swing.

`AbilityServer` receives that, reads Equipped, looks the name up in its
`ABILITIES` table, checks the cooldown, and runs it.

    EquipPad (click) ──> leaderstats.Equipped ──┐
                                                 v
    AbilityClient (E) ──> RemoteEvent ──> AbilityServer ──> the ability runs

## Adding an ability

Two steps, and the names must match exactly — `"Tusk Charge"` and
`"tusk charge"` are different abilities.

1. Copy a block in the `ABILITIES` table in `AbilityServer` and rename the key.
2. Duplicate an EquipPad Part and set its `ABILITY_NAME` to that same key.

Get the spelling wrong and the Output window tells you, once, rather than the
ability silently doing nothing.

Return `false` from an `Activate` function to mean "couldn't run". The player
keeps their cooldown instead of paying for nothing.

## The abilities so far

| Name | Cooldown | What it does |
|---|---|---|
| `Basic` | 1s | Tusk swipe. 20 damage in a 130° cone, 12 studs, plus a shove. |
| `Charge` | 4s | A lunge forward. No damage — there as an example of a non-attack. |
| `Invisible` | 45s | 4 seconds hidden. Costs 25 health up front. |

Every number worth tuning is a named constant at the top of its ability.

## Things that are deliberate, not accidental

**Damage goes through `dealDamage`.** It applies the hit and credits the kill
in one place, so a new ability gets kill-counting for free instead of
remembering to add it.

**Attacks check line of sight.** Without the raycast in `canSee` you can swipe
people through walls, which reads as broken the first time it happens.

**Invisibility remembers each part's original transparency** rather than
resetting everything to 0. HumanoidRootPart is normally invisible, so a blind
reset would leave a grey block floating in your chest.

**Cooldowns use `workspace:GetServerTimeNow()`**, not `os.clock()`. It is the
same clock on the server and every client, which is how the HUD counts down in
step with the server without having to ask it.

**`setupPlayer` refuses to run twice.** PlayerAdded and the catch-up loop can
both reach the same person on a busy server, and two `leaderstats` folders
would break the leaderboard.

## Testing

Use **Test → Players: 2 → Start**. Most of this is invisible in single-player:
you need someone to hit, and you need a second window to confirm that an
invisible walrus really is invisible from the outside.

## Known limits

- Knockback is set on the victim's own character, which their client partly
  controls, so it can look inconsistent under lag.
- Kills only count from direct damage. Shoving someone off the map credits
  nobody.
- Nothing is saved. Equipped resets to `None` when a player rejoins.
