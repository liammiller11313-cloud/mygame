# Ammo Models

**These are now built for you.** `AmmoFactory` generates every casing, magazine
and pickup at server start, proportioned from real cartridge dimensions — a 5.56
really is a slender bottleneck next to a 7.62, a .357 case really is that long and
thin, a 12 gauge hull really is a red tube on a brass head. You do not need to
model anything.

This document is here for when you want to **replace** one.

## How replacing works

Drop a model into the matching folder under the matching name and it wins. The
factory only ever fills gaps — it never overwrites or deletes anything you put
there. Delete yours and the generated one comes back on the next server start.

```
ReplicatedStorage/
└── Assets/
    └── Ammo/
        ├── Casings/      the brass that flies out when you shoot
        ├── Magazines/    the mag that drops when you reload
        └── Pickups/      ammo on the floor
```

## The names, by weapon type

| Ammo type | Which guns | Casing | Magazine |
|---|---|---|---|
| **Shotgun ammo** | Shotgun | `Casing_12ga` | `Round_12ga` |
| **Pistol ammo** | M1911A1 | `Casing_45ACP` | `Mag_Pistol` |
| **Revolver ammo** | .357 Magnum | `Casing_357` | `Speedloader_357` |
| **SMG ammo** | MP7A1, UMP-45, Kriss Vector | `Casing_9mm`, `Casing_45ACP` | `Mag_SMG` |
| **PPSh ammo** | PPSh-41 | `Casing_762` | `Mag_Drum` |
| **Rifle ammo** | M4A1, HK416A5, Mk 18 CQBR, Scoped Mk-18 | `Casing_556` | `Mag_STANAG` |
| **AK ammo** | AKM, AK-12, AKS-74U | `Casing_762`, `Casing_556` | `Mag_AK` |
| **Sniper ammo** | M1A EBR | `Casing_762` | `Mag_Marksman` |
| **Flare ammo** | Flare Gun | `Flare Shell (spent)` | `Flare Shell` |
| **Rocket** | RPG-7, Classic Rocket Launcher | — (no case) | `Rocket` |

> **`Round_12ga`, `Flare Shell` and `Rocket` are the three you actually SEE.**
> They are not dropped magazines — they are the round in the hand during a
> reload, held in front of the camera at arm's length. The shotgun and flare gun
> show one per shell; a launcher shows its rocket for the whole four seconds.
> Everything else on this list falls out of frame in under a second.

Floor pickups: `AmmoPile`, `AmmoBox`, `ShellBox`.

> **The flare pair is the one to get right.** The two names are one word apart
> and they go in different folders, because they are two different objects the
> player sees at two different moments:
>
> - `Magazines/Flare Shell` — the **live** round. Break-action guns load one at a
>   time, so this is the shell your hand carries to the breech, and watching it
>   go in *is* the reload.
> - `Casings/Flare Shell (spent)` — the **fired** case, tipped out when you break
>   the gun open. Scorched, not orange.
>
> Put either one in the other folder and you get a spent case going into a gun,
> or a live shell falling out of one. Both load fine and both look wrong.

## If you do replace one

- A `Part`, a `MeshPart`, or a `Model` with several parts all work. A multi-part
  Model needs a `PrimaryPart`; if it has none, the largest part is used and the
  rest are expected to be welded to it.
- **Point casings along Z**, long axis forward. Everything else is orientation
  agnostic.
- Keep roughly to scale. A stud is about 28cm, and the generated models run
  slightly over life size on purpose — a real 9mm case is three pixels at arm's
  length and vanishes the instant it leaves the frame.
- Don't include scripts. They are stripped, and that is a security measure rather
  than tidiness.

## Tuning

Sizes, eject speed, spin, lifetime and how far a magazine falls are all in
`src/shared/Config/AmmoConfig.lua`, one block per calibre and per magazine family.
The geometry is in `src/server/Assets/AmmoFactory.lua`, one builder per shape.

Adding a **new** calibre is: add a block to AmmoConfig, point a weapon at it, and
either add a builder or let it fall back to a correctly-sized stand-in.
