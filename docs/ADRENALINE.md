# Adrenaline

Both pill items go in the same slot and are used with the same button. They are
not the same item, and the difference is the whole design.

| | Temp health | Drains at | Lasts | What it is |
|---|---|---|---|---|
| **Pain Pills** | 50 | 0.55/s (~90s) | — | time |
| **Adrenaline** | 25 | 1.4/s (~18s) | 15s of effect | a plan |

Pills are a buffer. You take them because you are about to be hurt and you would
like that to matter less. Adrenaline is the opposite: you take it because you
have decided to **do** something, and the fifteen seconds are the window to do
it in. The health is the least interesting thing it gives you.

## What it does

Everything below runs for fifteen seconds from the moment it goes in. Taking a
second shot refreshes the clock rather than stacking.

**You run.** Whatever your health is. This is the one that matters and the reason
people save one: a survivor on eight health normally limps at 12, and under
adrenaline they move at sprint speed like everyone else. It is what gets somebody
across open ground to a downed teammate.

**You don't run out of wind.** Sprinting spends no stamina while it is active, so
fifteen seconds means fifteen seconds. Without this the back half of the item is
spent walking, which is the one thing a person who took it did not want.

**Everything you do is 1.5× faster.** Not just healing — *every* hold-to-act in
the game goes through one code path, so all of these are quicker:

- healing yourself or a teammate
- reviving someone who is down
- pulling someone off a ledge
- using a defibrillator
- getting a teammate out of a rescue closet
- resupplying at an ammo crate

**You gain 25 temporary health**, which drains at 1.4 a second — mostly gone by
the time the effect is. It is a cushion for the fifteen seconds, not a heal.

**Your stamina refills** the instant it goes in, and a sprint lockout clears. You
come out of it with wind.

**The screen warms and sharpens** — more colour, slightly brighter, a push toward
the accent. Deliberately *not* a wash or a blur: the point of the item is that
everything gets easier to read, not harder.

**Your team hears it.** Adrenaline has its own cue and it carries further than
the pill bottle does (85 studs against 50). A teammate who hears a shot go in has
learned that somebody is about to move, which is worth knowing and is not what a
rattling bottle means.

## What it deliberately does not do

**Reloading is not faster.** It is not a "use" action, and it is not faster in
Left 4 Dead 2 either.

**It does not make you tougher.** No damage resistance, no stagger immunity. You
move faster and act faster while being exactly as fragile — running at something
on 8 health is meant to be a decision, not a free one.

**It does not heal.** The 25 is temporary and drains. If you need health you need
a kit; adrenaline is for when there is no time to use one.

## Where the numbers live

`GameConfig.Survivor` — `AdrenalineHealth`, `AdrenalineDecayPerSecond`,
`AdrenalineDuration`, `AdrenalineSpeedBonus`, `AdrenalineUseSpeedBonus`.

The behaviour is in `SurvivorService`: `applyPills` starts it, `_hasAdrenaline`
is the one test, `_baseWalkSpeed` is where the limp is lifted, and
`getUseSpeedMultiplier` is what every hold-to-act divides by.

> `_baseWalkSpeed` is shared between the speed calculation and the sprint
> detector on purpose. The detector decides you are sprinting by comparing your
> real velocity against what walking *should* look like, so two copies of that
> number are two things that can disagree — and they did, over adrenaline, in a
> way that deleted your sprint for the item's whole duration.
>
> A **third** copy was found later, in the line that publishes `IsSprinting`. It
> asked `_effective` directly, which knows about temporary health and nothing
> about adrenaline, so a hurt survivor with a shot in them ran at full speed
> while the game told everyone they were walking. `IsSprinting` has one consumer
> — the footsteps — so that is exactly what it sounded like, and the sample
> swapped mid-stride a few seconds later when the temporary health drained back
> under the line at no change in speed. Ask `_baseWalkSpeed`. Always.

## Models

Seven per map, in an `Adrenaline Shots` folder, named `Adrenaline Shot 1`
upward. See `docs/MAPS_AND_CRATES.md`.

## Audio

`AudioConfig.Survivor.AdrenalineUse` is a stand-in — the survivor's gasp, pitched
down, because this project has no injector sample. It is distinct from the pills
and it carries the right distance; it is not the right *sound*. See
`docs/AUDIO_NEEDED.md`.
