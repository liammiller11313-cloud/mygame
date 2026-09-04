# Random events

Something happens at a time nobody can predict, it lasts a minute or two, and
then it is over. **The game decides when and which. The map only provides the
objects an event needs.**

That split is the whole architecture. Adding a map costs nothing in the event
system; adding an event costs a row in `EventConfig` and a module in
`server/Events/Events`. `RandomEventDirector` never changes for either.

## What a map has to do

Nothing, to get most of it. Weather, the storm and the broadcast work on a bare
baseplate.

For the rest, one folder:

```
<AnyMap>
└── Events
    ├── Lights            every light a blackout may take
    ├── EmergencyLights   the few that come ON when it does
    └── SupplyDrops       parts marking where a drop can land
```

Names are matched forgivingly — case, spacing, punctuation and a trailing plural
are all folded away, the same contract the medkits, ammo crates, vault props and
barricades use. **A map missing a folder is not broken**: the events that need it
are simply never offered there. That is the point of the split.

- `Lights` / `EmergencyLights` — point them at fixtures. **They need actual
  `Light` objects in them** (PointLight, SpotLight, SurfaceLight) — only a Light
  can be switched, so a folder of glowing neon bricks gives you a blackout that
  announces itself and turns nothing off. That is the one silent failure this
  event has, so it warns by name at round start if it finds parts and no lights. What gets switched is
  the `Light` objects inside them, never the parts, so the lamp posts stay.
  Every light is recorded with the state it was *already* in and put back to
  that, not to "on" — a fixture you deliberately left dark stays dark.
- `SupplyDrops` — one part per possible drop site. **Name them well**: the part's
  name is read out to the team ("Drop is down near the *Rooftop*"), which is the
  only direction they get.

## The eight events

| | Weight | Runs for | Needs from the map | From wave |
|---|---|---|---|---|
| Heavy rain | 20 | 120 s | — | 1 |
| Dense fog | 15 | 105 s | — | 2 |
| Emergency broadcast | 15 | 30 s | — | 1 |
| Thunderstorm | 12 | 135 s | — | 3 |
| Zombie surge | 12 | 60 s | — | 3 |
| Blackout | 10 | 90 s | `Lights` | 3 |
| Supply drop | 8 | 150 s | `SupplyDrops` | 2 |
| Power failure | 8 | 120 s | `Lights` | 4 |

Weights are relative, not percentages — the pool changes every draw, so the same
weight is worth more in a round where fewer events qualify.

## Timing

```
round starts → wait 150-330 s → is anything eligible? → draw by weight → run it
     ↑                                                                     │
     └──────────────── wait 120-360 s ←────────────────────────────────────┘
```

Nothing is rolled per frame. One time is chosen and written down; the tick is two
number comparisons. That matters beyond cost: a per-frame probability produces a
geometric distribution — events clustering early, occasionally none at all — and
no tuning fixes the shape. Scheduling gives a flat distribution inside a band the
config states plainly.

Nothing starts after **15:00** of a 17-minute round. The finale is the hardest
part of the mode already.

### What that produces

Over 20,000 simulated rounds:

- **2.45 events per round**, first one at a median of 4:00 (never before 2:30,
  never after 5:30).
- **486 distinct event sequences**; the most common single one is 2.77% of
  rounds. There is no fixed order.
- Pick share tracks the weights: rain 22%, fog 17%, broadcast 16%, storm 12%,
  blackout 10%, surge 10%, drop 8%, power failure 6%.

## What it refuses

Eligibility is checked at the moment of the draw and never cached, because every
term in it can have changed since the last one:

- the round is running, with survivors up
- the event's time and wave windows contain now
- its own cooldown has expired
- a non-repeatable event has not already run this round
- the module says this map supports it
- **and it is not a second heavy event in a row** — two 0.8-intensity events back
  to back is a difficulty spike no configuration asked for

Empty pool → the draw is skipped and rescheduled. A round where nothing qualifies
is a legitimate round.

**One event at a time**, deliberately. Two at once is one confused thing rather
than two legible ones, and the banner can only say one name.

Which means a `conflicts` entry can never be a genuine overlap — so it means
**"may not immediately follow"** instead. Rain ending and a thunderstorm starting
straight after is one storm that appeared to restart; a blackout chased by a
power failure is the lights going out twice with an explanation in between. Both
are what somebody writing `ConflictsWith` wanted to prevent. Costs almost
nothing: 2.46 events per round with the rule, 2.45 without.

## What it reuses rather than rebuilds

| Event | Runs on |
|---|---|
| Rain / fog / storm | `AtmosphereService:setWeather` — a mood, like the boss mood |
| Zombie surge | `DirectorService:triggerPanicEvent` — the existing horde |
| Supply drop | `ItemPlacer:spawnPickup` — the existing pickups |
| Broadcast, drop callout | `RoundService:announce` — the existing subtitle voice |
| Every announcement | the banner, plus `AudioConfig.Event.Siren` |

**No weather event writes to Lighting.** `AtmosphereService` already recomputes
the whole look every tick from the round clock plus whatever moods are active, so
a weather event sets a mood and clears it — there is no old value to save and
none to lose. A module that errors mid-event, a round that ends mid-storm, a
server that hitches: all leave a blend between 0 and 1 that decays on its own.
Every grade still passes through the readability floor, so no event can make the
map unfightable.

## The banner

`🚨 RANDOM EVENT 🚨  HEAVY RAIN` appears directly under the round clock and wave
pips, with the siren, and is gone after four seconds. It asks `WaveController`
for the height of that block rather than hard-coding one.

It is the *announcement*, not a status bar — what is happening afterwards is the
weather, the dark and the noise.

## Sounds

| Key | Id | |
|---|---|---|
| `Event.Siren` | `121756878891042` | real |
| `Event.Thunder` | *(stand-in)* | the failure sting, low-pitched — passes for distant thunder |
| `Event.Radio` | *(stand-in)* | the objective blip — passes for a transmission opening |
| `Event.RainLoop` | *(silent)* | **no id yet** — there is no rain sample in this project, and a wrong loop running for two minutes is worse than none |

The three non-siren rows are one id each away from being real, and the rain loop
is already **wired**: the client plays it on the rain volume, guarded on the id
being non-empty. Drop an id into that row and rain has sound with no code change.

The siren is played by the client only, on the banner's remote. It was briefly
played from both ends — server per player *and* client on the remote — which is
two sirens a frame apart.

## Testing one

```lua
game:GetService("ServerScriptService")  -- from the server console
Registry.get("RandomEventDirector"):forceEvent("Blackout")
```

Skips the schedule and every eligibility rule, so a wave-6 event can be seen
without playing to wave six. It still refuses if a module has not claimed the id.

## Adding an event

1. A row in `EventConfig.Definitions` and an id in `EventConfig.Id`.
2. A module in `server/Events/Events` with `claims`, `supported`, `start`,
   `stop`, and optionally `update`.

That is all. The director loads the folder at boot, and warns by name about any
id in the config that no module claims.
