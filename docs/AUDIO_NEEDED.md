# Sound & Music Checklist

Every id in `src/shared/Config/AudioConfig.lua` is empty on purpose — audio asset
ids are account-specific and can't be guessed. Fill them in and the game wires
itself up; nothing else needs to change.

The game runs silent until then, warning once per missing id and then staying
quiet, so an unfinished bank never spams your output window during a playtest.

**Priority order.** If you're sourcing these a few at a time, this order buys the
most feel per sound:

---

## Tier 1 — do these first (the game feels broken without them)

### Weapon fire — `AudioConfig.WeaponFire`
By an enormous margin the sound you hear most. Eight sounds:

| Key | What it wants to be |
|---|---|
| `Pistol` | Sharp, dry crack. Not beefy — it's the fallback weapon. |
| `Magnum` | Enormous, slow, room-filling. Should feel like a mistake to fire indoors. |
| `SMG` | Light, fast, papery. It fires 900rpm, so anything heavy turns to mush. |
| `PumpShotgun` | Deep boom + the mechanical *chk-chk* of the pump as a separate layer. |
| `AutoShotgun` | Same body, faster, less pump. |
| `AssaultRifle` | Mid-weight, punchy, controlled. The all-rounder. |
| `HuntingRifle` | Loud, long tail, distinct crack. Should carry across the map. |
| `Machete` | A whoosh, not a gunshot. |

> Get 3–5 variations of each if you can and they'll pitch-shift automatically
> (`pitchMin`/`pitchMax` per weapon). A single unvaried gunshot at 900rpm is the
> fastest way to make an SMG sound like a buzzsaw.

### Flesh impact — `AudioConfig.Impact`
The confirmation that you connected. **`Flesh` and `Bone` are the two that
matter** — a headshot has to sound different from a body shot, or the 4× damage
multiplier has no audible existence at all.

- `Flesh` — wet thud
- `Bone` — sharper crack, used for headshots

### Gore — `AudioConfig.Gore`
The payoff. `Dismember`, `Gib`, `Decapitate`, `BodyFall`, `Squelch`.

---

## Tier 2 — the early-warning system

### Special infected — `AudioConfig.Infected`
In Left 4 Dead these aren't flavour, they're **how players survive**. A player who
knows the Hunter growl lives; one who doesn't, doesn't. Treat them as gameplay.

| Key | Role |
|---|---|
| `HunterIdle` | The growl before it leaps. Your only warning. |
| `HunterPounce` | The scream mid-air. |
| `SmokerIdle` | The wet cough. Audible well before you see him. |
| `SmokerTongue` | The tongue firing. |
| `BoomerIdle` | Wet gurgling burble. |
| `BoomerExplode` | The burst. Big. |
| `ChargerIdle` | Heavy grunting. |
| `ChargerCharge` | The bellow as it commits — this is the dodge cue. |
| `WitchCry` | Distant sobbing. Should be audible from very far away and be genuinely unsettling. |
| `WitchStartle` | The shriek. |
| `TankRoar` | The set-piece announcement. |
| `TankFootstep` | Heavy, ground-shaking, looping as it runs. |

### Common infected — `AudioConfig.Infected`
`CommonIdle`, `CommonAlert`, `CommonAttack`, `CommonDeath`. Get several variants
of each — you'll hear these forty times a minute and identical repeats destroy
the illusion of a crowd faster than anything else.

---

## Tier 3 — polish

### Reload mechanics — `AudioConfig.WeaponReload`
`MagOut`, `MagIn`, `Bolt`, `ShellInsert`, `Pump`, `DryFire`.
`DryFire` matters more than it sounds like it should: the player has to *feel*
empty before they read the number.

### Surface impacts — `AudioConfig.Impact`
`Concrete`, `Metal`, `Wood`, `Glass`, `Water`, `Dirt`. Material variety is most
of what makes a firefight feel like it's happening in a *place*.

### Survivor — `AudioConfig.Survivor`
`Hurt`, `Incap`, `Death`, `Revived`, `HealSelf`, `PillsUse`, `Breathing`
(looped, plays below the hurt threshold), `Footstep`.

### UI — `AudioConfig.UI`
`Pickup`, `PromptAppear`, `ObjectiveChange`, `WaveCleared`, `Hitmarker`,
`HeadshotMarker`. The two hitmarker sounds are worth real attention — a distinct
headshot tick is a huge part of why shooting feels good.

---

## Music — `AudioConfig.Music`

All looped and cross-faded by the Director, never cut. Each cue needs to survive
being faded in and out repeatedly, so avoid strong intros.

| Cue | When it plays | Character |
|---|---|---|
| `Ambient` | Between waves | Sparse, tense, barely there. Mostly texture. |
| `Buildup` | Wave incoming | Pulse starts, something is coming. |
| `Horde` | Wave active | Full drive. Percussion-led. |
| `TankTheme` | Tank alive | The big one. Everything else ducks under it. |
| `WitchTheme` | Near a Witch | Strings, unstable, wrong-sounding. |
| `WaveCleared` | Wave survived | Short release sting. |
| `Defeat` | Team wiped | One-shot. |
| `Victory` | Round survived | One-shot. |

---

## Where to put them

Upload in Studio (or find them in the Toolbox / Creator Store), then paste the id
into the matching field in `src/shared/Config/AudioConfig.lua`:

```lua
[Enums.Weapon.Pistol] = {
    id = "rbxassetid://YOUR_ID_HERE",   -- was ""
    volume = 0.7,
    ...
}
```

Volumes, pitch ranges, rolloff distances and voice priorities are already tuned in
that file — you only need to supply ids.
