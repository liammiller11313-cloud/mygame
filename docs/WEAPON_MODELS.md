# Where your weapon models go

Every weapon in the game draws a **grey-box stand-in** until it finds a model of
yours. This is the contract for handing it one.

## The short version

Put the model in **`ServerStorage` → `Assets` → `Weapons`** and name it exactly
one of the names in the tables below. That is the whole thing. A `Model` or a
`Tool` both work — a Tool is what the toolbox gives you and what a free model
usually is, and it is accepted as-is.

```
ServerStorage
└── Assets
    └── Weapons
        ├── Machete
        ├── Fire Axe
        ├── Baseball Bat
        ├── Pipe
        └── Knife
```

> **A wrapper model is fine.** `Flare Gun` containing `SAIPH Flare Gun`
> containing the parts works exactly like parts sat directly in it — the
> pipeline collects them through `GetDescendants` and looks for a `Handle`
> recursively. Only the name of the OUTER entry has to match the table.
>
> The flare gun also wants **two ammo models**, and they are in a different
> place: see `docs/AMMO_MODELS.md`. `Flare Shell` (live) and
> `Flare Shell (spent)` (fired) go in `ReplicatedStorage/Assets/Ammo/Magazines`
> and `.../Casings` respectively — not in `Weapons`, and not in ServerStorage,
> because casings are a client-side effect and only ReplicatedStorage is
> searched for them.

You do **not** need a second copy for first person. One model is used for both
the weapon in your hands and the one everybody else sees you carrying. Add
`Assets/Viewmodels/<name>` only if you deliberately want a *different*,
first-person-only model — one posed for a hand, or lower-poly. That direction is
one-way: a Viewmodels entry is never used as the world model, because a prop
built for a camera a stud from your eye is the wrong thing to hang off somebody's
shoulder across the street.

`ReplicatedStorage.Assets.Weapons` works too, and saves the model being copied to
every client at boot. ServerStorage is the simpler place to keep things and the
difference is a few hundred kilobytes.

## Did it work?

Press Play and read the output. Two lines answer it:

```
[PlaceholderFactory] weapons 32 supplied / 5 grey-boxed · viewmodels 32 / 5 · ...
[PlaceholderFactory] 5 weapon(s) are drawn as grey-box stand-ins because no model
was found for them ... Machete (searched: Machete) · Knife (searched: Knife, Combat Knife) ...
```

The second line names every weapon still on a stand-in **and the exact spellings
it looked for**. If your machete is in the folder and still listed there, the name
does not match — that is almost always what has gone wrong. The match ignores
case, spaces, hyphens, underscores and dots, so `fire_axe` and `Fire Axe` are the
same name, but `Axe` on its own is not.

## Melee

```
ServerStorage → Assets → Weapons
```

| Weapon | Name the model one of these | Length it is fitted to |
|---|---|---|
| Machete | `Machete` | 1.6 studs |
| Fire Axe | `Fire Axe` · `FireAxe` | 2.0 studs |
| Baseball Bat | `Baseball Bat` · `BaseballBat` | 2.1 studs |
| Lead Pipe | `Pipe` · `LeadPipe` · `Lead Pipe` | 1.5 studs |
| Combat Knife | `Knife` · `Combat Knife` | 0.9 studs |

**About that length column.** A supplied model is measured along its longest axis
and scaled to the number shown, so it frames the same way whatever scale it was
built at. Anything already within about 45% of it is left exactly as you made it.
This is also why a knife is not a machete: they used to share one number, and a
combat knife was being blown up to a machete's size and drawn as a slab across
the bottom of the screen.

If your model comes out too big or too small, it is not this table you want —
build it near the right size and it will be left alone.

## Guns

Same folder, same rules.

| Slot | Weapon | Name the model one of these |
|---|---|---|
| Secondary | M1911A1 | `M1911` · `M1911A1` |
| Secondary | M9 | `M9` |
| Secondary | .357 Magnum | `.357 Magnum` · `Magnum357` |
| Secondary | Dual Pistols | `Dual Pistol` · `DualBerettas` |
| Secondary | Glock 18 | `Glock 18` · `Glock18` |
| Secondary | Sawn-Off | `Sawn-Off` · `SawnOff` |
| Secondary | RPG-7 | `RPG-7` · `RPG7` |
| Secondary | Flare Gun | `Flare Gun` · `FlareGun` |
| Primary | Shotgun | `Shotgun` |
| Primary | Tactical Shotty | `Tactical Shotty` · `TacticalShotty` |
| Primary | M1014 | `M1014` |
| Primary | DAO-12 | `DAO-12` · `DAO12` |
| Primary | PPSh-41 | `(71 Mag) PPSh-41` · `PPSh41` · `PPSh-41` |
| Primary | Kriss Vector .45 | `Kriss Vector .45` · `KrissVector` |
| Primary | MP7A1 | `MP7A1` |
| Primary | UMP-45 | `UMP-45` · `UMP45` |
| Primary | AKS-74U | `AKS-74U` · `AKS74U` |
| Primary | M4A1 | `M4A1` |
| Primary | HK416A5 | `HK416A5` |
| Primary | Mk 18 CQBR | `Mk 18 CQBR` · `Mk18CQBR` |
| Primary | AK-12 | `AK-12` · `AK12` |
| Primary | AKM | `AKM` |
| Primary | M16A4 | `M16A4` |
| Primary | HK416D | `HK416D` |
| Primary | HK417 | `HK417` |
| Primary | M249 | `M249` |
| Primary | M60E4 | `M60E4` |
| Primary | Scoped Mk-18 | `Scoped Mk-18` · `ScopedMk18` |
| Primary | M1A EBR | `M1A EBR` · `M1AEBR` |
| Primary | MK11 Mod 0 | `MK11 Mod 0` · `MK11` |
| Primary | M24 Sniper | `M24 Sniper` · `M24` |
| Primary | Flamethrower | `Flamethrower` |

## What happens to your model

It is never cloned into the world raw. A copy is prepared once at boot, and the
copy is what the game uses:

- **Scripts are stripped.** Nothing that ships inside a model gets to run.
- **Every part is anchored and made unqueryable**, so a weapon in your hands is
  not something bullets can hit or a zombie can walk into.
- **A `Muzzle` attachment is invented** at the front of the bounding box if the
  model does not carry one. Add your own named `Muzzle` and tracers and the flash
  come out of exactly where you put it — **and it is also what tells the game
  which way your gun points**, so it is the fix for the problem below.
- **A `Sight` or `AimPoint` attachment**, if present, is what gets put on the
  screen's centre line when you aim — so a scope's glass lines up with the
  crosshair instead of merely near it.
- **The pivot** is your `PrimaryPart` if you set one, then a part named `Handle`,
  then the biggest part in the model.

None of this is required. A bare model with no attachments and no PrimaryPart
works; the four bullets above are what you get for free and what to add if you
want it exact.

## If a gun comes out sideways — in either hand

The first-person pose assumes a weapon's barrel runs down its own **-Z**. A gun
modelled along X — a perfectly ordinary way to build one — used to be drawn lying
across the bottom of the screen pointing at the edge of it, and looked enormous
doing it, because you were seeing its whole length side-on instead of
foreshortened down the barrel.

The **world** model had the same problem from the other side: the grip that gets
invented for a weapon with no `Grip` attachment was a position and nothing else,
so the angle a survivor held it at was whatever rotation the `Handle` part
happened to have. A gun modelled along X came out of the fist at ninety degrees.

Both are now corrected automatically, by the same measurement: a model whose
barrel is more than 35° off forward is straightened. In first person that is the
pivot — which moves nothing and fixes the pose, the scale fit, the muzzle, the
sight and the arms in one go. In third person it is the grip's orientation. A
model that is already close to forward is left exactly as you made it, byte for
byte — a deliberate cant is yours to keep.

The barrel is found in one of two ways:

1. **A `Muzzle` attachment**, if the model has one. Exact, and the answer if you
   want to be certain.
2. Otherwise the **longest axis, pointed away from the grip** — the `Handle`, the
   `PrimaryPart`, or the biggest part, whichever it finds first.

So if a weapon still comes out pointing the wrong way, **put an Attachment called
`Muzzle` at the end of its barrel.** That settles it, and it improves where the
flash and the tracers come from at the same time.

**Boot tells you when it guessed.** Any model straightened on the longest-axis
reading is named in the output, with the same advice:

```
[PlaceholderFactory] the "Dual Pistol" model is not built barrel-down-Z, so it was
straightened from its longest axis — which is a guess. If it comes out of the hand
pointing the wrong way, add an Attachment called Muzzle...
```

A model already facing forward, or one carrying a `Muzzle`, says nothing.

**Dual-wield models are the shape most worth checking.** The longest axis is the
barrel for one gun and not necessarily for two: a pair of pistols is longest along
whichever way you arranged them, and nothing measurable from outside can tell
"end to end" from "side by side". One `Muzzle` on one of the two barrels is the
whole fix.

## Things Studio leaves in a model

`ThumbnailCamera` — a `Camera` left behind by whoever rendered the marketplace
icon — is stripped now, along with scripts, sounds, prompts and click detectors.
It is in more supplied models than not, and it was riding the clone into the
world, getting welded to the character with everything else, and sitting inside
the bounding box that the scale fit, the muzzle and the grip are all measured
from. You do not need to delete it yourself.
